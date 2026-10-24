{-# LANGUAGE DeriveAnyClass #-}

-- | What the server says about itself to its operator: the administration
-- API's first answer, its status.
--
-- The administration panel (decision 11 of docs/PLAN.md) is served on the
-- server's loopback admin listener, where whoever can reach the machine is
-- the administrator, and from Phase 3 to administrators on the public one
-- too. Its content comes with Phase 3; what is here from the start is the
-- status an operator checks after a deploy: which program is running, where
-- its data is, and how much of it there is.
module Wiki.Api.Admin
  ( ServerStatus (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude

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
