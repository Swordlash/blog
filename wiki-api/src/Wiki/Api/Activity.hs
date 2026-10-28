{-# LANGUAGE DeriveAnyClass #-}

-- | Activity API (WP4.10 of docs/PLAN.md): the administration's
-- "Activity" page. It shows the audit log ("Wiki.Core.Audit"), newest
-- first, one page at a time, filtered by who acted.
-- @GET \/api\/v1\/admin\/activity?actor=\<user id>&before=\<entry id>@
-- responds with 'Activity': the entries logged before the one named, the
-- oldest entry of the page before. @offset=\<n>@ instead skips the @n@
-- newest entries, which costs the server more the further it skips.
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
-- 'Nothing'), and where to start. A page starts after the entry 'before'
-- names (the oldest entry of the page before it), if one is named: the
-- next page is found through the log's index, however far back it is.
-- Otherwise it starts after the 'offset' newest entries, which the server
-- has to count off one by one.
data ActivityQuery = ActivityQuery
  { actor :: Maybe UserId
  , offset :: Int
  , before :: Maybe Text
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The newest entries of everyone: the query the page starts with.
firstPage :: ActivityQuery
firstPage = ActivityQuery {actor = Nothing, offset = 0, before = Nothing}

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
