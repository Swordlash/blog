-- | The administration's backend interface: 'MonadAdmin' is every read
-- and write the administration panel makes. It covers the wiki's users and
-- their accounts, which users administer the wiki and which may create
-- spaces, and the groups with their members.
--
-- It is a separate class from 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.DemoUsers.MonadDemoUsers' is, because only the administration
-- panel needs it. Unlike the demo's user switcher, every backend
-- implements it: the in-memory backend of the demo ("Wiki.App.Backend.Mem"),
-- the HTTP backend ("Wiki.App.Backend.Http", through the API's
-- @admin\/…@ endpoints) and the server's storage. They pass the same
-- contract tests (@Wiki.App.Backend.Contract.Admin@ in
-- @wiki-app:contract@).
--
-- = Who may
--
-- Every method needs the global 'Wiki.Core.Permission.Administer', held
-- by the server's operator always, or by a user granted it. Anyone else is
-- refused with 'Forbidden' before anything they named is looked up, so
-- that someone who may not administer the wiki learns nothing from the
-- refusal, not even which ids belong to someone. After that the errors
-- come in "Wiki.App.Backend"'s order: 'NotFound' for an id that names
-- nobody, then 'Invalid'.
--
-- An administrator may take the global administer away from themself.
-- The backend allows it, since the operator on the server's admin listener
-- can always give it back. The panel does not offer it (an administrator
-- who did it by mistake would be locked out of the panel at once); that is
-- a rule of the panel, not of the backend.
--
-- = What changes what
--
-- Making a user an administrator, or no longer one, changes the user's own
-- grant of the global administer and nothing else; a grant of it to a
-- group is left alone. Letting a user create spaces, or no longer, works
-- the same with the global create-spaces. Deleting a group deletes its
-- membership and every grant to it, global and on spaces, so that a group
-- made later never inherits another's permissions. Adding a member who is
-- in the group already, and removing one who is not, change nothing and
-- succeed. A group's name is not blank, and no two groups have names that
-- differ only in case.
--
-- = Accounts
--
-- A user created here signs in with a password, which the server stores
-- as a hash (decision 8 of the plan). Their login follows
-- 'Wiki.Core.User.checkLogin' and differs from every other user's,
-- ignoring case ('Conflict' otherwise). A blank display name becomes the
-- login. A password follows 'Wiki.Core.User.checkNewPassword' ('Invalid'
-- otherwise). Setting a new password, and disabling a login, end the
-- user's sessions. A disabled user cannot sign in, stays in the
-- 'directory', and keeps their pages and grants. A user who signs in with
-- one of the server's providers and has no password has none to set (WP5.6
-- of docs/PLAN.md): 'setPassword' refuses them. Where the backend sends
-- mail, an administrator can mail a user with a verified address the same
-- link that "Forgot your password?" mails ('sendPasswordLink'), instead of
-- typing a password for them. The demo's backend has no passwords and
-- stores only whether a user has one, which it checks as the server does,
-- so that its administration behaves the same. A disabled user counts as
-- nobody there, and is not offered in the user switcher.
--
-- = Whom the wiki lets in
--
-- The wiki's settings ('wikiSettings') say whether the wiki is open or
-- closed ("Wiki.Core.Access"), and whether an account someone creates for
-- themself may create spaces from the start. A change takes effect at the
-- next request. An invitation ('invite') is for an e-mail address, which
-- is checked ('Wiki.Api.Admin.checkEmail', 'Invalid' otherwise). Inviting
-- an address that already has an invitation replaces it. The invitation's
-- link carries a secret, which is returned only when the invitation is
-- made, and only if it was not mailed. The invitation lasts
-- 'Wiki.Api.Admin.invitationLifetime'. A revoked invitation is deleted
-- ('NotFound' if revoked again). The demo stores all of this in memory,
-- mails nothing, and creates no account from a link: that needs a server
-- (the invited person's side is in "Wiki.App.Account").
--
-- = Providers
--
-- A user may sign in with an account at a provider (WP3.6 of
-- docs/PLAN.md). The 'directory' lists those accounts by the provider's
-- name ('Wiki.Api.Admin.Directory.identities'), and an administrator may
-- disconnect them. The demo has no providers, so its users have no such
-- accounts.
--
-- = The server's own settings
--
-- The wiki's public address, its mail server and the sign-in providers
-- (WP4.4 of docs/PLAN.md, "Wiki.Api.ServerSettings") are set here and
-- nowhere else, and take effect at the next request. Their secrets (the
-- mail account's password, each provider's client secret) are written and
-- never read back: 'serverSettings' says only whether each is set. A
-- change is checked as a whole
-- ('Wiki.Api.ServerSettings.checkServerSettings', 'Invalid' otherwise). A
-- provider may be asked how to sign in ('checkProvider') and a test mail
-- sent ('sendTestMail'); only a server can do either. The demo stores the
-- settings for the tab's life and says that it cannot do those.
--
-- = Backups
--
-- The backups a server makes by itself (WP4.9 of docs/PLAN.md,
-- "Wiki.Api.Backups") are off until they are turned on here, and are set
-- here and nowhere else: when they run, how many are kept, and where they
-- are copied off the machine. The @rclone@ configuration is written and
-- never read back, like the server's other secrets. A change is checked as
-- a whole ('Wiki.Api.Backups.checkBackupSettings', 'Invalid' otherwise).
-- 'backUpNow' makes a backup at once, while backups are on ('Invalid'
-- otherwise). Only the server itself does that: the storage under it
-- refuses, as it refuses to ask a provider. The demo, whose wiki is in the
-- browser, makes none: its 'backups' say they are not available, and it
-- refuses the rest.
--
-- = Activity and status
--
-- Every write the administration makes (grants, groups, accounts,
-- settings, invitations, deletions of spaces and pages, imports) is
-- recorded in an audit log ("Wiki.Core.Audit", WP4.10 of docs/PLAN.md), in
-- the same transaction as the write. 'activity' lists the log one page at
-- a time, the newest first, for everyone or for one actor. The server's
-- status ('serverStatus': its version, its schema, its newest backup, the
-- last errors it logged) comes from the server itself. The demo keeps no
-- log and has no server: its 'activity' says it is not available, and its
-- 'serverStatus' is 'Nothing'.
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
import Wiki.Api.Admin (Directory, Invitations, Invited, ServerStatus, UserPage, UserQuery, WikiSettings)
import Wiki.Api.Backups (BackupSettingsChange, Backups)
import Wiki.Api.ServerSettings (MailTestResult, ProviderChange, ProviderCheck, ServerSettings, ServerSettingsChange)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (GroupId, InvitationId, UserId)
import Wiki.Core.User (Group, Password (..))

-- | 'MonadAdmin' is the administration's backend interface: the wiki's
-- users, groups and settings, as an administrator sees and changes them.
--
-- Every method has a default that lifts it through a monad transformer,
-- as 'Wiki.App.Backend.MonadWiki''s do, so that a component's handlers
-- call them in 'HalogenM'.
class (Monad m) => MonadAdmin m where
  -- | Every user, by login, which of them hold the global administer, and
  -- every group, by name, with its members.
  directory :: m (Either WikiError Directory)
  default directory :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Directory)
  directory = lift directory

  -- | One page of the users ('Wiki.Api.Admin.UserQuery'), in the order and
  -- with the matching 'Wiki.Api.Admin.pageOfDirectory' defines: the
  -- administration's table of users reads the users this way, so that a
  -- wiki of thousands of users is never read whole. A query
  -- 'Wiki.Api.Admin.checkUserQuery' refuses is 'Invalid'.
  userPage :: UserQuery -> m (Either WikiError UserPage)
  default userPage :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserQuery -> m (Either WikiError UserPage)
  userPage = lift . userPage

  -- | Grant a user the global administer, or take it from them.
  setAdministrator :: UserId -> Bool -> m (Either WikiError ())
  default setAdministrator :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setAdministrator u = lift . setAdministrator u

  -- | Grant a user the global create-spaces, or take it from them.
  setCreateSpaces :: UserId -> Bool -> m (Either WikiError ())
  default setCreateSpaces :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setCreateSpaces u = lift . setCreateSpaces u

  -- | Create a user, who signs in with the given password. The result is
  -- their account.
  createUser :: NewAccount -> m (Either WikiError Account)
  default createUser :: (MonadTrans t, m ~ t n, MonadAdmin n) => NewAccount -> m (Either WikiError Account)
  createUser = lift . createUser

  -- | Give a user a new password, ending their sessions. The result is
  -- their account. 'Invalid' for a user who has no password to set: one
  -- who signs in with one of the server's providers
  -- ('Wiki.Api.Admin.Directory.providerOnly').
  setPassword :: UserId -> Password -> m (Either WikiError Account)
  default setPassword :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Password -> m (Either WikiError Account)
  setPassword u = lift . setPassword u

  -- | Mail a user, at their verified address, the link to choose a new
  -- password that "Forgot your password?" mails (WP5.6 of docs/PLAN.md).
  -- 'Invalid', with the reason, when nothing is mailed: the backend sends
  -- no mail (the demo, and the storage under a server, whose API does the
  -- mailing); the user has no verified address, is disabled, or has no
  -- password to set; or a link was mailed to them less than a minute ago.
  sendPasswordLink :: UserId -> m (Either WikiError ())
  default sendPasswordLink :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> m (Either WikiError ())
  sendPasswordLink = lift . sendPasswordLink

  -- | Disable a user's login, ending their sessions, or enable it again.
  -- The result is their account.
  setDisabled :: UserId -> Bool -> m (Either WikiError Account)
  default setDisabled :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError Account)
  setDisabled u = lift . setDisabled u

  -- | Remove a user's account (WP5.25 of docs/PLAN.md). Only a disabled
  -- login is removed ('Conflict' otherwise), and never one's own
  -- ('Invalid'). What belongs to the account goes with it: grants,
  -- memberships, sessions, sign-in providers' accounts, second factor,
  -- passkeys and vault, watches, notifications and drafts. The pages,
  -- versions and comments the user wrote stay, kept by their login
  -- ('Wiki.Core.Comment.formerAuthor'), so that they still say who wrote
  -- them, and the login may be taken again.
  removeUser :: UserId -> m (Either WikiError ())
  default removeUser :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> m (Either WikiError ())
  removeUser = lift . removeUser

  -- | Create a group with this name and nobody in it.
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

  -- | The wiki's settings: whom the wiki lets in, and what a new account
  -- may do.
  wikiSettings :: m (Either WikiError WikiSettings)
  default wikiSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError WikiSettings)
  wikiSettings = lift wikiSettings

  -- | Change the wiki's settings. The result is the new settings.
  setWikiSettings :: WikiSettings -> m (Either WikiError WikiSettings)
  default setWikiSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => WikiSettings -> m (Either WikiError WikiSettings)
  setWikiSettings = lift . setWikiSettings

  -- | The invitations not yet used, the latest first, and whether the
  -- backend mails them.
  invitations :: m (Either WikiError Invitations)
  default invitations :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Invitations)
  invitations = lift invitations

  -- | Invite an e-mail address. The result is the invitation, and its
  -- link's secret if it was not mailed.
  invite :: Text -> m (Either WikiError Invited)
  default invite :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError Invited)
  invite = lift . invite

  -- | Revoke an invitation: its link no longer creates an account.
  revokeInvitation :: InvitationId -> m (Either WikiError ())
  default revokeInvitation :: (MonadTrans t, m ~ t n, MonadAdmin n) => InvitationId -> m (Either WikiError ())
  revokeInvitation = lift . revokeInvitation

  -- | Disconnect a user's account at a provider (WP3.6 of docs/PLAN.md),
  -- by the provider's name: they no longer sign in with it, and their
  -- sessions end, as with a new password. 'NotFound' if they have no
  -- account there. Unlike a user disconnecting their own account, this may
  -- remove their last way to sign in.
  unlinkUserIdentity :: UserId -> Text -> m (Either WikiError ())
  default unlinkUserIdentity :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Text -> m (Either WikiError ())
  unlinkUserIdentity u = lift . unlinkUserIdentity u

  -- | Remove a user's second factor (WP4.11 of docs/PLAN.md), for someone
  -- who has lost their authenticator and their recovery codes: they then
  -- sign in with their password alone. 'NotFound' if they have none.
  removeSecondFactor :: UserId -> m (Either WikiError ())
  default removeSecondFactor :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> m (Either WikiError ())
  removeSecondFactor = lift . removeSecondFactor

  -- | The server's own settings, with each secret shown only as whether it
  -- is set.
  serverSettings :: m (Either WikiError ServerSettings)
  default serverSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError ServerSettings)
  serverSettings = lift serverSettings

  -- | Replace the server's settings, each secret kept, replaced or
  -- cleared. The result is the new settings.
  setServerSettings :: ServerSettingsChange -> m (Either WikiError ServerSettings)
  default setServerSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => ServerSettingsChange -> m (Either WikiError ServerSettings)
  setServerSettings = lift . setServerSettings

  -- | Ask a provider how to sign in with it: the provider stored under
  -- that name, or the one given. 'NotFound' when no provider has that name
  -- and none is given.
  checkProvider :: Text -> Maybe ProviderChange -> m (Either WikiError ProviderCheck)
  default checkProvider :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> Maybe ProviderChange -> m (Either WikiError ProviderCheck)
  checkProvider name = lift . checkProvider name

  -- | Send a test mail to an address, through the configured mail server.
  -- 'Invalid' when there is none.
  sendTestMail :: Text -> m (Either WikiError MailTestResult)
  default sendTestMail :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError MailTestResult)
  sendTestMail = lift . sendTestMail

  -- | The backups: their settings (with only whether the configuration is
  -- set), the last backup made or tried, and whether one is running.
  backups :: m (Either WikiError Backups)
  default backups :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Backups)
  backups = lift backups

  -- | Replace the backups' settings, the configuration kept, replaced or
  -- cleared. The result is the backups' new state.
  setBackupSettings :: BackupSettingsChange -> m (Either WikiError Backups)
  default setBackupSettings :: (MonadTrans t, m ~ t n, MonadAdmin n) => BackupSettingsChange -> m (Either WikiError Backups)
  setBackupSettings = lift . setBackupSettings

  -- | Make a backup now. The result is the backups' state once it is made,
  -- or, if it takes a while, with it still running.
  backUpNow :: m (Either WikiError Backups)
  default backUpNow :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Backups)
  backUpNow = lift backUpNow

  -- | A page of the audit log, the newest first.
  activity :: ActivityQuery -> m (Either WikiError Activity)
  default activity :: (MonadTrans t, m ~ t n, MonadAdmin n) => ActivityQuery -> m (Either WikiError Activity)
  activity = lift . activity

  -- | The server's status: 'Nothing' where there is no server (the demo).
  serverStatus :: m (Either WikiError (Maybe ServerStatus))
  default serverStatus :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError (Maybe ServerStatus))
  serverStatus = lift serverStatus

-- | A component's handlers reach the backend through its monad.
instance (MonadAdmin m) => MonadAdmin (HalogenM st act slots output m)
