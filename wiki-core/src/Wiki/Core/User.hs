{-# LANGUAGE DeriveAnyClass #-}

-- | Users, groups and group membership. Nothing secret is stored here:
-- password hashes and sessions belong to the server (@wiki-server@).
module Wiki.Core.User
  ( User (..)
  , Standing (..)
  , SignInProvider (..)
  , Group (..)
  , Membership
  , groupsOf

    -- * Accounts
  , checkLogin
  , checkPassword
  , minimumPasswordLength
  , maximumPasswordLength
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Core.Id

-- | 'User': an account that can sign in.
data User = User
  { id :: UserId
  , login :: Text
  -- ^ The name they sign in with; unique.
  , displayName :: Text
  -- ^ The name pages show for them.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

-- | A login as it is stored, or why it is invalid. It is trimmed of white
-- space, at most 64 characters, with no white space or control character
-- inside, and does not start with @~@, which marks the server's own
-- principals (its operator is @~administrator@). Every backend creates
-- users with this rule, so that a login the demo accepts the server
-- accepts too.
checkLogin :: Text -> Either Text Text
checkLogin raw
  | T.null login = Left "A login cannot be blank."
  | T.length login > 64 = Left "A login has at most 64 characters."
  | T.any (\ch -> isSpace ch || isControl ch) login = Left "A login cannot have a blank in it."
  | "~" `T.isPrefixOf` login = Left "A login cannot start with ~."
  | otherwise = Right login
  where
    login = T.strip raw

-- | The password, or why it is invalid: shorter than
-- 'minimumPasswordLength' characters, or longer than
-- 'maximumPasswordLength'. The server hashes a valid password. The demo,
-- which has no passwords, checks them all the same, so that its
-- administration refuses what the server's would.
checkPassword :: Text -> Either Text Text
checkPassword p
  | T.length p < minimumPasswordLength = Left ("A password needs at least " <> show minimumPasswordLength <> " characters.")
  | T.length p > maximumPasswordLength = Left ("A password has at most " <> show maximumPasswordLength <> " characters.")
  | otherwise = Right p

-- | The shortest password a backend accepts: NIST's minimum for a password
-- chosen by its user (SP 800-63B).
minimumPasswordLength :: Int
minimumPasswordLength = 8

-- | The longest password: long enough for any passphrase, short enough that
-- hashing one cannot be used to keep the server busy.
maximumPasswordLength :: Int
maximumPasswordLength = 1024
