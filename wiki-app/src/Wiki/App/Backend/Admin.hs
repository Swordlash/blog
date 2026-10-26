-- | What the administration asks of wherever the wiki is kept: its people
-- and their accounts, who of them administers it and who may create
-- spaces, and its groups with their members.
--
-- A class of its own beside 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.DemoUsers.MonadDemoUsers' is, since it is what the
-- administration panel needs and nothing else does; but unlike the demo's
-- switcher every backend has it: the in-memory one of the demo
-- ("Wiki.App.Backend.Mem"), the one over HTTP ("Wiki.App.Backend.Http",
-- through the API's @admin\/…@ endpoints) and the server's own storage.
-- They pass the same contract (@Wiki.App.Backend.Contract.Admin@ in
-- @wiki-app:contract@).
--
-- = Who may
--
-- Every method needs the global 'Wiki.Core.Permission.Administer': the
-- server's operator, who always holds it, or a user granted it. Anyone else
-- is refused with 'Forbidden' before anything they named is looked for, so
-- that whoever may not administer the wiki learns nothing from it, not
-- even which ids are someone's. After that the errors come as
-- "Wiki.App.Backend" orders them: 'NotFound' for an id that names nobody,
-- then 'Invalid'.
--
-- An administrator may take the global administer from themself: the
-- backend allows it, since the operator on the server's admin listener can
-- always give it back. The panel does not offer it (an administrator who
-- did it by mistake would be locked out of the panel at once), which is a
-- rule of the panel's and not of the backend's.
--
-- = What changes what
--
-- Marking and unmarking an administrator changes the user's own grant of
-- the global administer and nothing else; a grant of it to a group is left
-- alone. Letting a user create spaces, or no longer, is the same with the
-- global create-spaces. Deleting a group deletes its membership and every grant to it,
-- global and on spaces, so that a group made later is never handed another's
-- permissions. Adding a member who is in the group already, and removing
-- one who is not, change nothing and succeed. A group's name is not blank,
-- and no two groups have names that differ only in case.
--
-- = Accounts
--
-- A user made here signs in with a password, kept by the server as a hash
-- (decision 8). Their login follows 'Wiki.Core.User.checkLogin' and is no
-- other user's in any case ('Conflict' otherwise); a blank display name is
-- the login; a password follows 'Wiki.Core.User.checkPassword' ('Invalid'
-- otherwise). A new password, and disabling a login, end the user's
-- sessions; a disabled user cannot sign in, stays in the 'directory', and
-- keeps their pages and grants. The demo's backend has no passwords and
-- keeps only whether a user has one, which it checks as the server does,
-- so that its administration behaves alike; a disabled user is nobody
-- there, and is not offered to switch to.
--
-- = Whom the wiki lets in
--
-- The wiki's settings ('wikiSettings') say whether it is open or closed
-- ("Wiki.Core.Access") and whether an account someone makes themself may
-- create spaces from the start; changing them takes effect at the next
-- request. An invitation ('invite') is for an e-mail address, which is
-- checked ('Wiki.Api.Admin.checkEmail', 'Invalid' otherwise); inviting an
-- address that has an invitation already replaces it. Its link carries a
-- secret that is given back only when the invitation is made, and only
-- when it was not mailed; it lasts 'Wiki.Api.Admin.invitationLifetime'. A
-- revoked invitation is gone ('NotFound' if revoked again). The demo keeps
-- all of it in memory, mails nothing, and makes no account from a link:
-- that takes a server (the invited person's half is
-- "Wiki.App.Account"'s).
--
-- = Providers
--
-- A user may sign in with an account at a provider (WP3.6 of
-- docs/PLAN.md), which the 'directory' lists by the provider's name
-- ('Wiki.Api.Admin.Directory.identities'), and which an administrator may
-- disconnect. The demo signs in with no provider: its users have none.
--
-- = The server's own settings
--
-- The wiki's public address, its mail server and the providers people
-- sign in with (WP4.4 of docs/PLAN.md, "Wiki.Api.ServerSettings") are set
-- here and nowhere else, and take effect at the next request. Their
-- secrets (the mail account's password, each provider's client secret)
-- are written and never read back: 'serverSettings' says only whether
-- each is set. A change is checked as a whole
-- ('Wiki.Api.ServerSettings.checkServerSettings', 'Invalid' otherwise). A
-- provider may be asked how to sign in ('checkProvider') and a test mail
-- sent ('sendTestMail'), which only a server can do: the demo keeps the
-- settings for the tab's life and says that it cannot.
--
-- = Backups
--
-- The backups a server makes by itself (WP4.9 of docs/PLAN.md,
-- "Wiki.Api.Backups") are off until they are turned on here, and are set
-- here and nowhere else: when, how many are kept, and where they are
-- copied off the machine, with the @rclone@ configuration written and
-- never read back, as the server's other secrets. A change is checked as a
-- whole ('Wiki.Api.Backups.checkBackupSettings', 'Invalid' otherwise).
-- 'backUpNow' makes one at once, while they are on ('Invalid' otherwise),
-- which only the server itself does: the storage under it refuses, as it
-- refuses to ask a provider. The demo, whose wiki is in the browser, makes
-- none: its 'backups' say they are not available, and it refuses the rest.
--
-- = Activity and status
--
-- Every write of the administration's (grants, groups, accounts, settings,
-- invitations, deletions of spaces and pages, imports) is recorded in an
-- audit log ("Wiki.Core.Audit", WP4.10 of docs/PLAN.md), in the same
-- transaction as the write, which 'activity' lists a page at a time, the
-- newest first, everyone's or one actor's. The server's status
-- ('serverStatus': its version, its schema, its newest backup, the last
-- errors it logged) is the server's own. The demo keeps no log and has no
-- server: its 'activity' says it is not available, and its 'serverStatus'
-- is 'Nothing'.
module Wiki.App.Backend.Admin
  ( MonadAdmin (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Account (Account, NewAccount)
import Wiki.Api.Activity (Activity, ActivityQuery)
import Wiki.Api.Admin (Directory, Invitations, Invited, ServerStatus, WikiSettings)
import Wiki.Api.Backups (BackupSettingsChange, Backups)
import Wiki.Api.ServerSettings (MailTestResult, ProviderChange, ProviderCheck, ServerSettings, ServerSettingsChange)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (GroupId, InvitationId, UserId)
import Wiki.Core.User (Group)

-- | The wiki's people, as an administrator sees and changes them.
--
-- The methods have lifted defaults, as 'Wiki.App.Backend.MonadWiki''s do,
-- so that a component's handlers call them in 'HalogenM'.
class (Monad m) => MonadAdmin m where
  -- | Every user, by login, which of them is granted the global administer,
  -- and every group, by name, with its members.
  directory :: m (Either WikiError Directory)
  default directory :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Directory)
  directory = lift directory

  -- | Grant a user the global administer, or take it from them.
  setAdministrator :: UserId -> Bool -> m (Either WikiError ())
  default setAdministrator :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setAdministrator u = lift . setAdministrator u

  -- | Grant a user the global create-spaces, or take it from them.
  setCreateSpaces :: UserId -> Bool -> m (Either WikiError ())
  default setCreateSpaces :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setCreateSpaces u = lift . setCreateSpaces u

  -- | A new user, who signs in with the password given: their account.
  createUser :: NewAccount -> m (Either WikiError Account)
  default createUser :: (MonadTrans t, m ~ t n, MonadAdmin n) => NewAccount -> m (Either WikiError Account)
  createUser = lift . createUser

  -- | Give a user a new password, ending their sessions: their account.
  setPassword :: UserId -> Text -> m (Either WikiError Account)
  default setPassword :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Text -> m (Either WikiError Account)
  setPassword u = lift . setPassword u

  -- | Disable a user's login, ending their sessions, or enable it again:
  -- their account.
  setDisabled :: UserId -> Bool -> m (Either WikiError Account)
  default setDisabled :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError Account)
  setDisabled u = lift . setDisabled u

  -- | A new group, with this name and nobody in it.
  createGroup :: Text -> m (Either WikiError Group)
  default createGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError Group)
  createGroup = lift . createGroup

  -- | Give a group another name.
  renameGroup :: GroupId -> Text -> m (Either WikiError Group)
  default renameGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> Text -> m (Either WikiError Group)
  renameGroup g = lift . renameGroup g

  -- | Delete a group, its membership and the grants to it.
  deleteGroup :: GroupId -> m (Either WikiError ())
  default deleteGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> m (Either WikiError ())
  deleteGroup = lift . deleteGroup

  -- | Put a user in a group.
  addMember :: GroupId -> UserId -> m (Either WikiError ())
  default addMember :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> UserId -> m (Either WikiError ())
  addMember g = lift . addMember g

  -- | Take a user out of a group.
  removeMember :: GroupId -> UserId -> m (Either WikiError ())
  default removeMember :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> UserId -> m (Either WikiError ())
  removeMember g = lift . removeMember g

  -- | Whom the wiki lets in, and what a new account may do.
  wikiSettings :: m (Either WikiError WikiSettings)
  default wikiSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError WikiSettings)
  wikiSettings = lift wikiSettings

  -- | Change them: the settings as they then are.
  setWikiSettings :: WikiSettings -> m (Either WikiError WikiSettings)
  default setWikiSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => WikiSettings -> m (Either WikiError WikiSettings)
  setWikiSettings = lift . setWikiSettings

  -- | The invitations not yet used, the latest first, and whether they are
  -- mailed.
  invitations :: m (Either WikiError Invitations)
  default invitations :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Invitations)
  invitations = lift invitations

  -- | Invite an e-mail address: the invitation, and its link's secret if it
  -- was not mailed.
  invite :: Text -> m (Either WikiError Invited)
  default invite :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError Invited)
  invite = lift . invite

  -- | Revoke an invitation: its link makes no account any more.
  revokeInvitation :: InvitationId -> m (Either WikiError ())
  default revokeInvitation :: (MonadTrans t, m ~ t n, MonadAdmin n) => InvitationId -> m (Either WikiError ())
  revokeInvitation = lift . revokeInvitation

  -- | Disconnect a user's account at a provider (WP3.6 of docs/PLAN.md),
  -- by the provider's name: they no longer sign in with it, and their
  -- sessions end, as with a new password. 'NotFound' if they have none
  -- there. Unlike a user disconnecting their own, it may be their last way
  -- in.
  unlinkUserIdentity :: UserId -> Text -> m (Either WikiError ())
  default unlinkUserIdentity :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Text -> m (Either WikiError ())
  unlinkUserIdentity u = lift . unlinkUserIdentity u

  -- | Take a user's second factor away (WP4.11 of docs/PLAN.md), for one
  -- who has lost their authenticator and their recovery codes: they sign
  -- in with their password alone again. 'NotFound' if they have none.
  removeSecondFactor :: UserId -> m (Either WikiError ())
  default removeSecondFactor :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> m (Either WikiError ())
  removeSecondFactor = lift . removeSecondFactor

  -- | The server's own settings, each secret as whether it is set.
  serverSettings :: m (Either WikiError ServerSettings)
  default serverSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError ServerSettings)
  serverSettings = lift serverSettings

  -- | Replace them, each secret kept, replaced or cleared: the settings as
  -- they then are.
  setServerSettings :: ServerSettingsChange -> m (Either WikiError ServerSettings)
  default setServerSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => ServerSettingsChange -> m (Either WikiError ServerSettings)
  setServerSettings = lift . setServerSettings

  -- | Ask a provider how to sign in: the one of that name as it is set, or
  -- as given. 'NotFound' for a name no provider has when none is given.
  checkProvider :: Text -> Maybe ProviderChange -> m (Either WikiError ProviderCheck)
  default checkProvider :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> Maybe ProviderChange -> m (Either WikiError ProviderCheck)
  checkProvider name = lift . checkProvider name

  -- | Send a test mail to an address, through the mail server as set.
  -- 'Invalid' when there is none.
  sendTestMail :: Text -> m (Either WikiError MailTestResult)
  default sendTestMail :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError MailTestResult)
  sendTestMail = lift . sendTestMail

  -- | The backups: their settings, the configuration as whether it is set,
  -- the last made or tried, and whether one is under way.
  backups :: m (Either WikiError Backups)
  default backups :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Backups)
  backups = lift backups

  -- | Replace their settings, the configuration kept, replaced or cleared:
  -- the backups as they then are.
  setBackupSettings :: BackupSettingsChange -> m (Either WikiError Backups)
  default setBackupSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => BackupSettingsChange -> m (Either WikiError Backups)
  setBackupSettings = lift . setBackupSettings

  -- | Make a backup now: the backups once it is made, or, if it takes a
  -- while, with it still under way.
  backUpNow :: m (Either WikiError Backups)
  default backUpNow :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Backups)
  backUpNow = lift backUpNow

  -- | A page of the audit log, the newest first.
  activity :: ActivityQuery -> m (Either WikiError Activity)
  default activity :: (MonadTrans t, m ~ t n, MonadAdmin n) => ActivityQuery -> m (Either WikiError Activity)
  activity = lift . activity

  -- | How the server is: 'Nothing' where there is no server (the demo).
  serverStatus :: m (Either WikiError (Maybe ServerStatus))
  default serverStatus :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError (Maybe ServerStatus))
  serverStatus = lift serverStatus

-- | A component's handlers reach the backend through its monad.
instance (MonadAdmin m) => MonadAdmin (HalogenM st act slots output m)
