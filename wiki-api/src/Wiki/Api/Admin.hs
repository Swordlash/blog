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
module Wiki.Api.Admin
  ( -- * The server
    ServerStatus (..)

    -- * The wiki's people
  , Directory (..)
  , AdministratorFlag (..)
  , GroupName (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id (UserId)
import Wiki.Core.User (Group, Membership, User)

-- | The answer to @GET \/api\/v1\/admin\/status@.
data ServerStatus = ServerStatus
  { version :: Text
  -- ^ The server program and its version, @wiki-server 0.1.0.0@.
  , startedAt :: UTCTime
  -- ^ When this server started.
  , dataDir :: Text
  -- ^ The directory the database and the attachments are kept in.
  , trustNetwork :: Bool
  -- ^ Whether everyone who reaches the public listener is taken for the
  -- administrator (@--trust-network@).
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
-- unmarking one changes. A grant of it to a group makes its members
-- administrators too, by the rules of "Wiki.Core.Permission", but nothing
-- here grants one, and they are not listed as such.
data Directory = Directory
  { users :: [User]
  -- ^ Every user, by login.
  , administrators :: Set UserId
  -- ^ The users granted the global administer themselves.
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

-- | The body of @POST \/api\/v1\/admin\/groups@ and of @PUT
-- \/api\/v1\/admin\/groups\/\<id>\/name@: the group's name.
newtype GroupName = GroupName {name :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
