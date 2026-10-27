{-# LANGUAGE DeriveAnyClass #-}

-- | Administration API types: the server's status, the wiki's users, which
-- of them are administrators, its groups and their members, and the
-- request bodies that change them.
--
-- The administration panel (decision 11 of docs/PLAN.md) is served on the
-- server's loopback admin listener, where anyone who can reach the machine
-- is the administrator, and to administrators on the public listener too.
-- The status is what an operator checks after a deploy: which program is
-- running, where its data is, and how much data there is. The users and
-- groups are what the panel shows and changes: who is an administrator,
-- and who is in which group.
--
-- Who the wiki lets in (WP3.5 of docs/PLAN.md) is also an administration
-- setting ('WikiSettings'), together with the invitations an administrator
-- has created for a closed wiki ('Invitation').
module Wiki.Api.Admin
  ( -- * The server
    ServerStatus (..)
  , LoggedError (..)

    -- * The wiki's people
  , Directory (..)
  , AdministratorFlag (..)
  , CreateSpacesFlag (..)
  , GroupName (..)

    -- * Whom the wiki lets in
  , WikiSettings (..)
  , defaultSettings
  , Invitation (..)
  , Invitations (..)
  , NewInvitation (..)
  , Invited (..)
  , checkEmail
  , invitationLifetime
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime)
import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Api.Security (AccountEmail)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (InvitationId, UserId)
import Wiki.Core.User (Group, Membership, User)

-- | 'ServerStatus': the response to @GET \/api\/v1\/admin\/status@.
data ServerStatus = ServerStatus
  { version :: Text
  -- ^ The server program and its version, @wiki-server 0.1.0.0@.
  , startedAt :: UTCTime
  -- ^ When this server started.
  , dataDir :: Text
  -- ^ The directory the database and the attachments are stored in.
  , spaces :: Int
  , pages :: Int
  , attachments :: Int
  -- ^ The number of attachments of all pages, including those stored
  -- elsewhere on the web.
  , users :: Int
  , backups :: Int
  -- ^ The number of database backups stored in the data directory.
  , schemaVersion :: Int
  -- ^ The version of the database schema: its last migration.
  , lastBackup :: Maybe UTCTime
  -- ^ When the newest backup in the data directory was made (by the
  -- server's schedule, by hand or by a deploy); 'Nothing' if there is none.
  , connections :: Int
  -- ^ The number of open live channels (WebSockets).
  , errors :: [LoggedError]
  -- ^ The last errors the server logged since it started, newest first, at
  -- most twenty (WP4.10 of docs/PLAN.md). They are kept in memory only.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LoggedError': an error the server logged. It holds when it happened;
-- where (the route pattern of the request, such as
-- @\/api\/v1\/pages\/:page@, never the URL with its ids and secrets; or the
-- part of the server, such as @backup-scheduler@); and the message as the
-- log has it, which never contains a secret.
data LoggedError = LoggedError
  { at :: UTCTime
  , route :: Text
  , message :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Directory': the response to @GET \/api\/v1\/admin\/directory@. It
-- holds all of the wiki's users and groups as the administration shows
-- them, in one response, since the panel shows users and groups side by
-- side and offers the users as members of each group.
--
-- An administrator here is a user granted the global
-- 'Wiki.Core.Permission.Administer' directly, which is the grant that
-- marking and unmarking an administrator changes. A space creator is a
-- user granted the global 'Wiki.Core.Permission.CreateSpaces' directly. A
-- grant of either to a group also applies to its members, by the rules of
-- "Wiki.Core.Permission", but such members are not listed here.
data Directory = Directory
  { users :: [User]
  -- ^ Every user, by login, including disabled users.
  , administrators :: Set UserId
  -- ^ The users granted the global administer permission directly.
  , creators :: Set UserId
  -- ^ The users granted the global create-spaces permission directly.
  , disabled :: Set UserId
  -- ^ The users whose account is disabled: they cannot sign in, and keep
  -- their pages, versions and grants.
  , withPassword :: Set UserId
  -- ^ The users who have a password to sign in with. A user from an
  -- imported wiki, or one created on the console without a password, has
  -- none until one is set.
  , identities :: Map UserId [Text]
  -- ^ The sign-in providers each user may sign in with instead of a
  -- password (WP3.6 of docs/PLAN.md), by their names in the server's
  -- configuration. A user with none may be missing.
  , providerOnly :: Set UserId
  -- ^ The users who cannot have a password (WP5.6 of docs/PLAN.md,
  -- 'Wiki.Api.Account.providerOnly'): they have none, and sign in with a
  -- provider the server has. A user whose providers are all gone, removed
  -- from the server or disconnected, is not in this set: they have no way
  -- to sign in, and may be given a password. The server computes the set,
  -- so that the panel does not have to work it out from provider names it
  -- may not know.
  , secondFactor :: Set UserId
  -- ^ The users who have a second factor (WP4.11 of docs/PLAN.md), which
  -- an administrator may remove for a user who has lost it.
  , emails :: Map UserId AccountEmail
  -- ^ The users' e-mail addresses, and whether each is verified. A user
  -- with no address is missing.
  , mailing :: Bool
  -- ^ Whether the server sends mail. Only then can a new user's address be
  -- verified.
  , groups :: [Group]
  -- ^ Every group, by name.
  , membership :: Membership
  -- ^ The members of each group, by group id. A group without members may
  -- be missing.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @PUT \/api\/v1\/admin\/users\/\<id>\/administrator@:
-- whether the user should hold the global administer permission.
newtype AdministratorFlag = AdministratorFlag {administrator :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @PUT \/api\/v1\/admin\/users\/\<id>\/create-spaces@:
-- whether the user should hold the global create-spaces permission.
newtype CreateSpacesFlag = CreateSpacesFlag {createSpaces :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @POST \/api\/v1\/admin\/groups@ and of @PUT
-- \/api\/v1\/admin\/groups\/\<id>\/name@: the group's name.
newtype GroupName = GroupName {name :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'WikiSettings': the wiki's own settings, @GET@ and @PUT \/api\/v1\/admin\/settings@.
data WikiSettings = WikiSettings
  { access :: Access
  -- ^ Who the wiki lets in ("Wiki.Core.Access").
  , newAccountsCreateSpaces :: Bool
  -- ^ Whether an account a user creates for themselves (in an open wiki,
  -- or with an invitation) may create spaces from the start, by being
  -- granted the global create-spaces permission. Otherwise a new account
  -- has no grant until an administrator gives it one.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A wiki's settings before anyone has changed them: open, and new
-- accounts cannot create spaces. A wiki created before these settings
-- existed keeps working as before.
defaultSettings :: WikiSettings
defaultSettings = WikiSettings {access = Open, newAccountsCreateSpaces = False}

-- | 'Invitation': an invitation an administrator has created, as the
-- administration lists it. Its link's secret is not included: the server
-- stores only its hash.
data Invitation = Invitation
  { id :: InvitationId
  , email :: Text
  -- ^ The address it was created for.
  , createdAt :: UTCTime
  , expiresAt :: UTCTime
  , expired :: Bool
  -- ^ Whether it had expired when it was listed. Its link can no longer
  -- create an account, and it stays listed until it is revoked or the
  -- address is invited again.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Invitations': the response to @GET \/api\/v1\/admin\/invitations@.
-- The unused invitations, latest first, and whether the server sends them
-- by mail (it has an SMTP server) or the panel shows their links to copy.
data Invitations = Invitations
  { mailing :: Bool
  , invitations :: [Invitation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @POST \/api\/v1\/admin\/invitations@: invite someone, by
-- their e-mail address. An address that already has an invitation gets a
-- new one, which replaces it.
newtype NewInvitation = NewInvitation {email :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Invited': a new invitation, and how it reaches the invited person.
data Invited = Invited
  { invitation :: Invitation
  , token :: Maybe Text
  -- ^ The secret of its link, for the panel to show the link to copy. It
  -- is given when the invitation was not sent by mail (the server sends no
  -- mail, or sending failed), and only in this response, since the server
  -- stores only its hash.
  , mailError :: Maybe Text
  -- ^ Why sending it by mail failed, if it was to be sent.
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show Invited where
  showsPrec _ i rest = "Invited {invitation = " <> show i.invitation <> ", token = " <> (if isJust i.token then "<hidden>" else "Nothing") <> ", mailError = " <> show i.mailError <> "}" <> rest

-- | An e-mail address as it is stored, or why it is invalid: trimmed of
-- white space, at most 254 characters, with one @\@@ that has text on
-- each side, a dot in the domain, and no white space inside. Not a full
-- check of the address's syntax, which only the receiving mail server can
-- make, but enough to catch a typo.
checkEmail :: Text -> Either Text Text
checkEmail raw
  | T.null address = Left "An e-mail address cannot be blank."
  | T.length address > 254 = Left "An e-mail address has at most 254 characters."
  | T.any (\c -> isSpace c || isControl c) address = Left "An e-mail address cannot have a blank in it."
  | [mailbox, domain] <- T.splitOn "@" address
  , not (T.null mailbox)
  , "." `T.isInfixOf` T.dropEnd 1 (T.drop 1 domain) =
      Right address
  | otherwise = Left "This is not an e-mail address."
  where
    address = T.strip raw

-- | How long an invitation's link can create an account: a week, long
-- enough for someone away for a few days, short enough that a link
-- forgotten in a mailbox does not stay valid.
invitationLifetime :: NominalDiffTime
invitationLifetime = 7 * 24 * 60 * 60
