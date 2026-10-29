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

    -- * The users, a page at a time
  , UserQuery (..)
  , firstUsers
  , userQueryOf
  , userPageSizes
  , maxUserPageSize
  , checkUserQuery
  , UserSummary (..)
  , UserPage (..)
  , userMatches
  , userOrder
  , summaryOf
  , pageOfDirectory

    -- * Whom the wiki lets in
  , WikiSettings (..)
  , defaultSettings
  , Invitation (..)
  , Invitations (..)
  , NewInvitation (..)
  , Invited (..)
  , invitationLifetime
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime)
import Protolude
import Wiki.Api.Account (InvitationToken)
import Wiki.Api.Security (AccountEmail)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (GroupId, InvitationId, UserId)
import Wiki.Core.User (Email, Group (..), Login (..), Membership, User (..))

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
  , guide :: Bool
  -- ^ Whether the wiki has its guide, the space at @/guide@ (WP5.29 of
  -- docs/PLAN.md). Where it has none, the Overview offers to install it
  -- (@POST \/api\/v1\/admin\/guide@).
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
  , adminCreatesPasswordAccounts :: Bool
  -- ^ The wiki setting of the same name ('WikiSettings'): whether the
  -- administration may create accounts with a password. When it is off,
  -- the panel shows a note in place of its form for a new user. The
  -- directory carries it so that the panel shows the users from one read.
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

-- | 'UserQuery' is one page of the wiki's users, as the administration
-- asks for it: @GET \/api\/v1\/admin\/users@ with the parameters
-- @offset@, @limit@, @q@, @administrators@ and @disabled@. The users are in
-- the order 'userOrder' gives, and the page starts at 'offset' in that
-- order. A user is on it when they match every part of the query that is
-- set: 'search' (see 'userMatches'), being an administrator, being
-- disabled.
data UserQuery = UserQuery
  { offset :: Int
  -- ^ How many matching users come before the page, from 0.
  , limit :: Int
  -- ^ How many users the page holds at most, from 1 to 'maxUserPageSize'.
  , search :: Text
  -- ^ Words to find in the login or the display name; empty for everyone.
  , administrators :: Bool
  -- ^ Only the users granted the global administer directly.
  , disabled :: Bool
  -- ^ Only the users whose account is disabled.
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The first page of every user, at the page size the server answers
-- when none is asked for (25).
firstUsers :: UserQuery
firstUsers = UserQuery {offset = 0, limit = 25, search = "", administrators = False, disabled = False}

-- | The query @GET \/api\/v1\/admin\/users@ names with its parameters:
-- @offset@ (0 if missing), @limit@ (25 if missing), @q@ (everyone if
-- missing), and the flags @administrators@ and @disabled@.
userQueryOf :: Maybe Int -> Maybe Int -> Maybe Text -> Bool -> Bool -> UserQuery
userQueryOf offset limit q administrators disabled =
  UserQuery
    { offset = fromMaybe firstUsers.offset offset
    , limit = fromMaybe firstUsers.limit limit
    , search = fromMaybe "" q
    , administrators
    , disabled
    }

-- | The page sizes the administration offers. The first is the default,
-- and the last is 'maxUserPageSize'.
userPageSizes :: [Int]
userPageSizes = [25, 50, 100]

-- | The largest page of users a backend answers, so that one request
-- never reads a whole large wiki's users.
maxUserPageSize :: Int
maxUserPageSize = 100

-- | 'checkUserQuery' refuses a query no backend answers: an offset below
-- 0, or a limit outside 1 to 'maxUserPageSize'. The reason is a sentence
-- for the person who asked.
checkUserQuery :: UserQuery -> Either Text UserQuery
checkUserQuery q
  | q.offset < 0 = Left "The offset of a page of users is 0 or more."
  | q.limit < 1 || q.limit > maxUserPageSize = Left ("A page of users holds from 1 to " <> show maxUserPageSize <> " users.")
  | otherwise = Right q

-- | 'userMatches' says whether a user matches the words searched for:
-- every word is found, ignoring case, in their login or in their display
-- name. No words match everyone.
--
-- The server's storage matches in SQL, with @LIKE@. There a @%@, a @_@ or a
-- backslash in a word matches any one character, so the server may find a
-- few more users than this function for such words. SQLite ignores the
-- case of ASCII letters only, so a display name with other letters is
-- matched there only in the case typed.
userMatches :: Text -> User -> Bool
userMatches search u = all found (T.words (T.toLower search))
  where
    found w = w `T.isInfixOf` T.toLower u.login.text || w `T.isInfixOf` T.toLower u.displayName

-- | 'userOrder' is the order of the users in a page: by login ignoring
-- case, then by login, then by id. Logins are unique ignoring case, so the
-- first key is enough in practice; the others make the order total. The
-- server's storage lowers the login in SQL, which on SQLite lowers ASCII
-- letters only: there a login with other capital letters may sort apart
-- from where this function puts it.
userOrder :: User -> (Text, Text, UserId)
userOrder u = (T.toLower u.login.text, u.login.text, u.id)

-- | 'UserSummary' is one user as the administration's table of users and
-- its "Manage" dialog show them: the user, their direct global grants, how
-- they sign in, their address, and their groups.
data UserSummary = UserSummary
  { user :: User
  , administrator :: Bool
  -- ^ Granted the global administer directly.
  , createsSpaces :: Bool
  -- ^ Granted the global create-spaces directly.
  , disabled :: Bool
  , hasPassword :: Bool
  , identities :: [Text]
  -- ^ The sign-in providers they may sign in with, by name.
  , providerOnly :: Bool
  -- ^ They cannot have a password ('Directory.providerOnly').
  , secondFactor :: Bool
  , email :: Maybe AccountEmail
  , groups :: [GroupId]
  -- ^ The groups they are in.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'UserPage': the response to @GET \/api\/v1\/admin\/users@. It holds
-- the users of the page, how many users match the query in all, and what
-- the dialog of one user needs besides the user: every group (to add the
-- user to one), whether the server sends mail (for a password link), and
-- whether the administration may create accounts with a password (for the
-- form for a new user).
data UserPage = UserPage
  { users :: [UserSummary]
  , total :: Int
  -- ^ How many users match the query, on every page.
  , offset :: Int
  -- ^ The query's offset: the place of the page's first user, from 0.
  , groups :: [Group]
  -- ^ Every group, by name.
  , mailing :: Bool
  , adminCreatesPasswordAccounts :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'summaryOf' is one user's summary, from the directory of every user.
summaryOf :: Directory -> User -> UserSummary
summaryOf d u =
  UserSummary
    { user = u
    , administrator = u.id `Set.member` d.administrators
    , createsSpaces = u.id `Set.member` d.creators
    , disabled = u.id `Set.member` d.disabled
    , hasPassword = u.id `Set.member` d.withPassword
    , identities = Map.findWithDefault [] u.id d.identities
    , providerOnly = u.id `Set.member` d.providerOnly
    , secondFactor = u.id `Set.member` d.secondFactor
    , email = Map.lookup u.id d.emails
    , groups = [g.id | g <- d.groups, u.id `Set.member` Map.findWithDefault mempty g.id d.membership]
    }

-- | 'pageOfDirectory' answers a query from the directory of every user.
-- It is the meaning of 'UserQuery': the demo's backend answers with it,
-- and the server's storage, which reads one page from the database, must
-- answer the same.
pageOfDirectory :: UserQuery -> Directory -> UserPage
pageOfDirectory q d =
  UserPage
    { users = map (summaryOf d) (take q.limit (drop q.offset matching))
    , total = length matching
    , offset = q.offset
    , groups = d.groups
    , mailing = d.mailing
    , adminCreatesPasswordAccounts = d.adminCreatesPasswordAccounts
    }
  where
    matching =
      sortOn
        userOrder
        [ u
        | u <- d.users
        , userMatches q.search u
        , not q.administrators || u.id `Set.member` d.administrators
        , not q.disabled || u.id `Set.member` d.disabled
        ]

-- | 'WikiSettings': the wiki's own settings, @GET@ and @PUT \/api\/v1\/admin\/settings@.
data WikiSettings = WikiSettings
  { access :: Access
  -- ^ Who the wiki lets in ("Wiki.Core.Access").
  , newAccountsCreateSpaces :: Bool
  -- ^ Whether an account a user creates for themselves (in an open wiki,
  -- or with an invitation) may create spaces from the start, by being
  -- granted the global create-spaces permission. Otherwise a new account
  -- has no grant until an administrator gives it one.
  , adminCreatesPasswordAccounts :: Bool
  -- ^ Whether the administration may create accounts with a password
  -- (WP5.18 of docs/PLAN.md). When it is off, @POST
  -- \/api\/v1\/admin\/users@ is refused, and accounts with a password are
  -- made only on the server's console, with @wiki-server users add@. It
  -- does not affect the console, invitations, accounts people make
  -- themselves in an open wiki, sign-in providers, or a password link
  -- sent to an existing user.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A wiki's settings before anyone has changed them: open, new accounts
-- cannot create spaces, and the administration may create accounts with a
-- password. A wiki created before these settings existed keeps working as
-- before.
defaultSettings :: WikiSettings
defaultSettings = WikiSettings {access = Open, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True}

-- | 'Invitation': an invitation an administrator has created, as the
-- administration lists it. Its link's secret is not included: the server
-- stores only its hash.
data Invitation = Invitation
  { id :: InvitationId
  , email :: Email
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
-- The address is the text typed; the backend checks it with
-- 'Wiki.Core.User.parseEmail'.
newtype NewInvitation = NewInvitation {email :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Invited': a new invitation, and how it reaches the invited person.
data Invited = Invited
  { invitation :: Invitation
  , token :: Maybe InvitationToken
  -- ^ The secret of its link, for the panel to show the link to copy. It
  -- is given when the invitation was not sent by mail (the server sends no
  -- mail, or sending failed), and only in this response, since the server
  -- stores only its hash.
  , mailError :: Maybe Text
  -- ^ Why sending it by mail failed, if it was to be sent.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How long an invitation's link can create an account: a week, long
-- enough for someone away for a few days, short enough that a link
-- forgotten in a mailbox does not stay valid.
invitationLifetime :: NominalDiffTime
invitationLifetime = 7 * 24 * 60 * 60
