{-# LANGUAGE DeriveAnyClass #-}

-- | What a server says about itself: the first type the client and the server
-- share, and the pattern the rest of the API's types follow. Each is plain
-- data with aeson instances derived from its 'Generic' representation, so the
-- JSON's field names are the record's, and both sides read and write it with
-- the same code.
module Wiki.Api.Info
  ( ServerInfo (..)
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
