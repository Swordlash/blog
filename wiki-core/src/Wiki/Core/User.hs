{-# LANGUAGE DeriveAnyClass #-}

-- | Users, groups and who is in which group. Nothing secret lives here:
-- password hashes and sessions are the server's (Phase 3).
module Wiki.Core.User
  ( User (..)
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
