{-# LANGUAGE DeriveAnyClass #-}

-- | What the administration API speaks: the server's status, the wiki's
-- people (its users, who of them administers it, its groups and their
-- members), and the bodies of the requests that change them.
--
-- The administration panel (decision 11 of docs/PLAN.md) is served on the
-- server's loopback admin listener, where whoever can reach the machine is
-- the administrator, and to administrators on the public one too. The
-- status is what an operator checks after a deploy: which program is
-- running, where its data is, and how much of it there is. The people are
-- what the panel shows and changes: who is an administrator, and who is in
-- which group.
--
-- Whom the wiki lets in (WP3.5 of docs/PLAN.md) is a setting of the
-- administration's too ('WikiSettings'), with, for a closed wiki, the
-- invitations an administrator has made ('Invitation').
module Wiki.Api.Admin
  ( -- * The server
    ServerStatus (..)

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
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (InvitationId, UserId)
import Wiki.Core.User (Group, Membership, User)

-- | The answer to @GET \/api\/v1\/admin\/status@.
data ServerStatus = ServerStatus
  { version :: Text
  -- ^ The server program and its version, @wiki-server 0.1.0.0@.
  , startedAt :: UTCTime
  -- ^ When this server started.
  , dataDir :: Text
  -- ^ The directory the database and the attachments are kept in.
  , spaces :: Int
  , pages :: Int
  , attachments :: Int
  -- ^ How many attachments the pages have, those that live on the web
  -- included.
  , users :: Int
  , backups :: Int
  -- ^ How many backups of the database are kept in the data directory.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The answer to @GET \/api\/v1\/admin\/directory@: everyone the wiki
-- has, as the administration shows them, in one answer, since the panel
-- shows the users and the groups side by side and offers the users as
-- members of each group.
--
-- An administrator here is a user granted the global
-- 'Wiki.Core.Permission.Administer' themself, which is what marking and
-- unmarking one changes, and a creator of spaces one granted the global
-- 'Wiki.Core.Permission.CreateSpaces' themself. A grant of either to a
-- group gives it to its members too, by the rules of
-- "Wiki.Core.Permission", but nothing here grants one, and they are not
-- listed as such.
data Directory = Directory
  { users :: [User]
  -- ^ Every user, by login, a disabled one included.
  , administrators :: Set UserId
  -- ^ The users granted the global administer themselves.
  , creators :: Set UserId
  -- ^ The users granted the global create-spaces themselves.
  , disabled :: Set UserId
  -- ^ The users whose login is disabled: they cannot sign in, and keep
  -- their pages, versions and grants.
  , withPassword :: Set UserId
  -- ^ The users who have a password to sign in with. One brought in with
  -- an imported wiki, or made without one on the console, has none until
  -- one is set.
  , groups :: [Group]
  -- ^ Every group, by name.
  , membership :: Membership
  -- ^ The members of each group, by the group's id; a group without
  -- members may be left out.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @PUT \/api\/v1\/admin\/users\/\<id>\/administrator@:
-- whether the user is to hold the global administer.
newtype AdministratorFlag = AdministratorFlag {administrator :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @PUT \/api\/v1\/admin\/users\/\<id>\/create-spaces@:
-- whether the user is to hold the global create-spaces.
newtype CreateSpacesFlag = CreateSpacesFlag {createSpaces :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The body of @POST \/api\/v1\/admin\/groups@ and of @PUT
-- \/api\/v1\/admin\/groups\/\<id>\/name@: the group's name.
newtype GroupName = GroupName {name :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The wiki's own settings: @GET@ and @PUT \/api\/v1\/admin\/settings@.
data WikiSettings = WikiSettings
  { access :: Access
  -- ^ Whom the wiki lets in ("Wiki.Core.Access").
  , newAccountsCreateSpaces :: Bool
  -- ^ Whether an account someone makes themself (in an open wiki, or with
  -- an invitation) may create spaces from the start: it is granted the
  -- global create-spaces. Otherwise a new account holds no grant until an
  -- administrator gives it one.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A wiki's settings before anyone has changed them: open, and new
-- accounts create no spaces. So a wiki made before there were settings
-- goes on as it was.
defaultSettings :: WikiSettings
defaultSettings = WikiSettings {access = Open, newAccountsCreateSpaces = False}

-- | An invitation an administrator has made, as the administration lists
-- it. Its link's secret is not here: the server keeps only its hash.
data Invitation = Invitation
  { id :: InvitationId
  , email :: Text
  -- ^ The address it was made for.
  , createdAt :: UTCTime
  , expiresAt :: UTCTime
  , expired :: Bool
  -- ^ Whether it had expired when it was listed: its link no longer makes
  -- an account, and it stays listed until it is revoked or made again.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET \/api\/v1\/admin\/invitations@: the invitations not yet used, the
-- latest first, and whether the server mails them (it has an SMTP server
-- to mail through) or the panel is to show their links to copy.
data Invitations = Invitations
  { mailing :: Bool
  , invitations :: [Invitation]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST \/api\/v1\/admin\/invitations@: invite someone, by their e-mail
-- address. An address that has an invitation already is given a new one,
-- in its place.
newtype NewInvitation = NewInvitation {email :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | An invitation just made, and how it reaches the person invited.
data Invited = Invited
  { invitation :: Invitation
  , token :: Maybe Text
  -- ^ The secret of its link, for the panel to show the link to copy:
  -- given when the invitation was not mailed (the server mails nothing, or
  -- could not), and only now, since the server keeps no more than its
  -- hash.
  , mailError :: Maybe Text
  -- ^ Why it could not be mailed, if it was to be.
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show Invited where
  showsPrec _ i rest = "Invited {invitation = " <> show i.invitation <> ", token = " <> (if isJust i.token then "<hidden>" else "Nothing") <> ", mailError = " <> show i.mailError <> "}" <> rest

-- | An e-mail address as it is kept, or why it cannot be one: without the
-- blanks around it, at most 254 characters, with one @\@@ that has
-- something on each side, a dot in the domain, and no blank inside. Not a
-- full check of the address's syntax, which only the mail server it is
-- sent to can make, but enough to catch a slip.
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

-- | How long an invitation's link makes an account: a week, long enough for
-- someone away for a few days, short enough that a link forgotten in a
-- mailbox does not stay a way in.
invitationLifetime :: NominalDiffTime
invitationLifetime = 7 * 24 * 60 * 60
