{-# LANGUAGE DeriveAnyClass #-}

-- | Users, groups and who is in which group. Nothing secret lives here:
-- password hashes and sessions are the server's (@wiki-server@).
module Wiki.Core.User
  ( User (..)
  , Standing (..)
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

-- | Someone who can sign in.
data User = User
  { id :: UserId
  , login :: Text
  -- ^ What they sign in with, unique.
  , displayName :: Text
  -- ^ What pages show them as.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How whoever is asking came to be who they are, which decides whether
-- they may sign in or out: someone nobody has signed in as may sign in,
-- someone signed in may sign out, and the server's operator (on its
-- loopback admin listener) is the administrator without having signed
-- in, so neither applies.
data Standing
  = -- | Nobody has signed in.
    NotSignedIn
  | -- | A user who signed in, with a session.
    SignedIn
  | -- | The server's operator, who is the administrator by where they ask
    -- from: the server's loopback admin listener.
    Operator
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A set of users that permissions can be granted to at once.
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

-- | A login as it is kept, or why it cannot be one: without the blanks
-- around it, at most 64 characters, with no blank or control character
-- inside, and not starting with @~@, which names the server's own
-- principals (its operator is @~administrator@). Every backend makes users
-- by this rule, so that a login the demo takes the server takes too.
checkLogin :: Text -> Either Text Text
checkLogin raw
  | T.null login = Left "A login cannot be blank."
  | T.length login > 64 = Left "A login has at most 64 characters."
  | T.any (\ch -> isSpace ch || isControl ch) login = Left "A login cannot have a blank in it."
  | "~" `T.isPrefixOf` login = Left "A login cannot start with ~."
  | otherwise = Right login
  where
    login = T.strip raw

-- | Why a password cannot be one, if it cannot: shorter than
-- 'minimumPasswordLength' characters, or longer than
-- 'maximumPasswordLength'. The server hashes what passes; the demo, which
-- has no passwords, checks it all the same, so that its administration
-- refuses what the server's would.
checkPassword :: Text -> Either Text Text
checkPassword p
  | T.length p < minimumPasswordLength = Left ("A password needs at least " <> show minimumPasswordLength <> " characters.")
  | T.length p > maximumPasswordLength = Left ("A password has at most " <> show maximumPasswordLength <> " characters.")
  | otherwise = Right p

-- | The shortest password a backend takes: NIST's minimum for a password
-- chosen by its user (SP 800-63B).
minimumPasswordLength :: Int
minimumPasswordLength = 8

-- | The longest: long enough for any passphrase, short enough that hashing
-- one is not a way to keep the server busy.
maximumPasswordLength :: Int
maximumPasswordLength = 1024
