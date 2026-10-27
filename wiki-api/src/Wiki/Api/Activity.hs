{-# LANGUAGE DeriveAnyClass #-}

-- | Activity API (WP4.10 of docs/PLAN.md): the administration's
-- "Activity" page. It shows the audit log ("Wiki.Core.Audit"), newest
-- first, one page at a time, filtered by who acted.
-- @GET \/api\/v1\/admin\/activity?actor=\<user id>&offset=\<n>@ responds
-- with 'Activity'.
module Wiki.Api.Activity
  ( Activity (..)
  , ActivityQuery (..)
  , firstPage
  , activityPageSize
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Wiki.Core.Audit (Actor, AuditEntry)
import Wiki.Core.Id (UserId)

-- | 'ActivityQuery': which entries to list: whose (everyone's for
-- 'Nothing'), and how many of the newest to skip.
data ActivityQuery = ActivityQuery
  { actor :: Maybe UserId
  , offset :: Int
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The newest entries of everyone: the query the page starts with.
firstPage :: ActivityQuery
firstPage = ActivityQuery {actor = Nothing, offset = 0}

-- | The number of entries per page.
activityPageSize :: Int
activityPageSize = 50

-- | 'Activity': one page of the log.
data Activity = Activity
  { available :: Bool
  -- ^ Whether the backend keeps a log at all: the demo's backend does not.
  , entries :: [AuditEntry]
  -- ^ At most 'activityPageSize' entries, newest first.
  , more :: Bool
  -- ^ Whether there are older entries after these.
  , actors :: [Actor]
  -- ^ Every actor that has an entry in the log, by login: the actors the
  -- log can be filtered by.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
