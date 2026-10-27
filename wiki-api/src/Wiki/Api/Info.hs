{-# LANGUAGE DeriveAnyClass #-}

-- | Server info: what a server says about itself. This was the first type
-- shared by the client and the server, and the rest of the API's types
-- follow its pattern. Each is plain data with aeson instances derived from
-- its 'Generic' representation, so the JSON field names are the record's,
-- and both sides encode and decode it with the same code.
module Wiki.Api.Info
  ( ServerInfo (..)
  , Health (..)
  , apiVersion
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude

-- | 'ServerInfo': the response to @GET \/api\/v1\/info@.
data ServerInfo = ServerInfo
  { name :: Text
  -- ^ The wiki's name, as its pages show it in their titles.
  , apiVersion :: Int
  -- ^ The API version the server implements: 'apiVersion' for this server.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The API version these types describe, the @v1@ in its paths.
apiVersion :: Int
apiVersion = 1

-- | 'Health': the response to @GET \/healthz@, at the root of either
-- listener, for a health check (Docker's, or a monitor's) without signing
-- in. It says whether the server responds and its database with it, the
-- version of the database schema, and how long ago the newest stored
-- backup was made. Nothing in it reveals the wiki's content or users.
data Health = Health
  { status :: Text
  -- ^ @ok@, or @failing@ when the database could not be read (with status
  -- 503).
  , schemaVersion :: Int
  , lastBackupAgeSeconds :: Maybe Int
  -- ^ How long ago the newest backup in the data directory was made, in
  -- seconds; @null@ when there is none.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
