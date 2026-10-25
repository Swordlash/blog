{-# LANGUAGE DeriveAnyClass #-}

-- | Users, groups and who is in which group. Nothing secret lives here:
-- password hashes and sessions are the server's (@wiki-server@).
module Wiki.Core.User
  ( User (..)
  , Standing (..)
  , Group (..)
  , Membership
  , groupsOf
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
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
-- loopback admin listener, or anyone on a network the server trusts) is
-- the administrator without having signed in, so neither applies.
data Standing
  = -- | Nobody has signed in.
    NotSignedIn
  | -- | A user who signed in, with a session.
    SignedIn
  | -- | The server's operator, who is the administrator by where they ask
    -- from.
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
