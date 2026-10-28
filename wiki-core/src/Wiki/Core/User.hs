{-# LANGUAGE DeriveAnyClass #-}

-- | Users, groups and group membership. Nothing secret is stored here:
-- password hashes and sessions belong to the server (@wiki-server@).
module Wiki.Core.User
  ( User (..)
  , Login (..)
  , Password (..)
  , Email (..)
  , Standing (..)
  , SignInProvider (..)
  , Group (..)
  , Membership
  , groupsOf

    -- * Accounts
  , parseLogin
  , checkNewPassword
  , parseEmail
  , minimumPasswordLength
  , maximumPasswordLength
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import Wiki.Core.Id

-- | 'User': an account that can sign in.
data User = User
  { id :: UserId
  , login :: Login
  -- ^ The name they sign in with; unique.
  , displayName :: Text
  -- ^ The name pages show for them.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Login': the name a user signs in with, such as @ada@. It is unique
-- among the wiki's users, without regard to case. A new login must follow
-- the rules of 'parseLogin', the only function that checks them. The JSON
-- and URL instances do not check them: a login in a response or a
-- database row was checked when it was made, and a backend parses the
-- login in a request itself, so that a bad one is answered with its own
-- error message. The constructor is exported for those trusted sources.
newtype Login = Login {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'Password': a password as someone typed it, to sign in or to set. Its
-- 'Show' instance prints @Password <hidden>@ and never the password, so
-- that a password cannot reach a log through 'show', nor through the
-- 'Show' of a request that holds one. A 'Password' is not checked: a
-- password typed to sign in has no rules, and a wrong one is refused by
-- its hash. 'checkNewPassword' applies the rules for a new password. The
-- JSON is the bare text.
newtype Password = Password {text :: Text}
  deriving stock (Eq, Generic)
  deriving newtype (FromJSON, ToJSON)

instance Show Password where
  showsPrec _ _ rest = "Password <hidden>" <> rest

-- | 'Email': an e-mail address, such as @ada\@example.org@: a user's, an
-- invitation's, or one a sign-in provider gave. 'parseEmail' checks a new
-- one. The JSON is the bare text, and decoding it applies no rule, for
-- the same reason as 'Login''s. The server compares addresses without
-- regard to case.
newtype Email = Email {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | 'Standing': how the current requester is identified, which decides
-- whether they may sign in or out. A requester who is not signed in may
-- sign in, and a signed-in user may sign out. The server's operator (on
-- its loopback admin listener) is the administrator without signing in, so
-- neither applies.
data Standing
  = -- | Nobody has signed in.
    NotSignedIn
  | -- | A user who signed in, with a session.
    SignedIn
  | -- | The server's operator, who is the administrator because of where
    -- the request comes from: the server's loopback admin listener.
    Operator
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SignInProvider': a provider users may sign in with instead of a
-- password (OpenID Connect, WP3.6 of docs/PLAN.md), as the application
-- shows it. It holds the name from the server's configuration, which is
-- also its segment in the sign-in addresses (@auth\/\<name>\/start@), and
-- the label of its button ("Sign in with GitHub"). The client secret, and
-- all other settings for talking to the provider, stay on the server.
data SignInProvider = SignInProvider
  { name :: Text
  , label :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Group': a set of users that permissions can be granted to together.
data Group = Group
  { id :: GroupId
  , name :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The members of each group, as the backend stores them. In JSON, an
-- object keyed by group id.
type Membership = Map GroupId (Set UserId)

-- | The groups a user is a member of.
groupsOf :: Membership -> UserId -> Set GroupId
groupsOf membership user = Map.keysSet (Map.filter (Set.member user) membership)

--------------------------------------------------------------------------------
-- Accounts

-- | A new login as it is stored, or why it is invalid. It is trimmed of
-- white space, at most 64 characters, with no white space or control
-- character inside, and does not start with @~@, which marks the server's
-- own principals (its operator is @~administrator@). Every backend creates
-- users with this rule, so that a login the demo accepts the server
-- accepts too.
parseLogin :: Text -> Either Text Login
parseLogin raw
  | T.null login = Left "A login cannot be blank."
  | T.length login > 64 = Left "A login has at most 64 characters."
  | T.any (\ch -> isSpace ch || isControl ch) login = Left "A login cannot have a blank in it."
  | "~" `T.isPrefixOf` login = Left "A login cannot start with ~."
  | otherwise = Right (Login login)
  where
    login = T.strip raw

-- | A new password, or why it is invalid: shorter than
-- 'minimumPasswordLength' characters, or longer than
-- 'maximumPasswordLength'. The server hashes a valid password. The demo,
-- which has no passwords, checks them all the same, so that its
-- administration refuses what the server's would.
checkNewPassword :: Password -> Either Text Password
checkNewPassword (Password p)
  | T.length p < minimumPasswordLength = Left ("A password needs at least " <> show minimumPasswordLength <> " characters.")
  | T.length p > maximumPasswordLength = Left ("A password has at most " <> show maximumPasswordLength <> " characters.")
  | otherwise = Right (Password p)

-- | The shortest password a backend accepts: NIST's minimum for a password
-- chosen by its user (SP 800-63B).
minimumPasswordLength :: Int
minimumPasswordLength = 8

-- | The longest password: long enough for any passphrase, short enough that
-- hashing one cannot be used to keep the server busy.
maximumPasswordLength :: Int
maximumPasswordLength = 1024

-- | A new e-mail address as it is stored, or why it is invalid: trimmed of
-- white space, at most 254 characters, with one @\@@ that has text on
-- each side, a dot in the domain, and no white space inside. Not a full
-- check of the address's syntax, which only the receiving mail server can
-- make, but enough to catch a typo.
parseEmail :: Text -> Either Text Email
parseEmail raw
  | T.null address = Left "An e-mail address cannot be blank."
  | T.length address > 254 = Left "An e-mail address has at most 254 characters."
  | T.any (\c -> isSpace c || isControl c) address = Left "An e-mail address cannot have a blank in it."
  | [mailbox, domain] <- T.splitOn "@" address
  , not (T.null mailbox)
  , "." `T.isInfixOf` T.dropEnd 1 (T.drop 1 domain) =
      Right (Email address)
  | otherwise = Left "This is not an e-mail address."
  where
    address = T.strip raw
