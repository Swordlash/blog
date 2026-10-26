{-# LANGUAGE DeriveAnyClass #-}

-- | What a server says about itself: the first type the client and the server
-- share, and the pattern the rest of the API's types follow. Each is plain
-- data with aeson instances derived from its 'Generic' representation, so the
-- JSON's field names are the record's, and both sides read and write it with
-- the same code.
module Wiki.Api.Info
  ( ServerInfo (..)
  , Health (..)
  , apiVersion
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude

-- | The answer to @GET \/api\/v1\/info@.
data ServerInfo = ServerInfo
  { name :: Text
  -- ^ The wiki's name, as its pages title it.
  , apiVersion :: Int
  -- ^ The version of the API the server speaks, 'apiVersion' for this one.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The API version these types describe, the @v1@ in its paths.
apiVersion :: Int
apiVersion = 1

-- | The answer to @GET \/healthz@, at the root of either listener, for a
-- health check (Docker's, a monitor's) to ask without signing in: whether
-- the server answers and its database with it, the version of the
-- database's schema, and how long ago the newest backup kept was made.
-- Nothing in it says anything of the wiki's content or people.
data Health = Health
  { status :: Text
  -- ^ @ok@, or @failing@ when the database could not be read (with a
  -- 503).
  , schemaVersion :: Int
  , lastBackupAgeSeconds :: Maybe Int
  -- ^ How long ago the newest backup in the data directory was made, in
  -- seconds; @null@ when there is none.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
