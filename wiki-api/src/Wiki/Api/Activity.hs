{-# LANGUAGE TemplateHaskell #-}

-- | The administration's "Activity" (WP4.10 of docs/PLAN.md): the audit
-- log ("Wiki.Core.Audit"), newest first, a page at a time, filtered by who
-- acted. @GET \/api\/v1\/admin\/activity?actor=\<user id>&offset=\<n>@
-- answers 'Activity'.
module Wiki.Api.Activity
  ( Activity (..)
  , ActivityQuery (..)
  , firstPage
  , activityPageSize
  )
where

import Protolude
import Wiki.Core.Audit (Actor, AuditEntry)
import Wiki.Core.Id (UserId)
import Wiki.Core.Json (defaultOptions, deriveValueJSON)

-- | Which entries to list: whose (everyone's for 'Nothing'), from how many
-- of the newest on.
data ActivityQuery = ActivityQuery
  { actor :: Maybe UserId
  , offset :: Int
  }
  deriving stock (Eq, Ord, Show)

deriveValueJSON defaultOptions ''ActivityQuery

-- | The newest entries, everyone's: what the section opens on.
firstPage :: ActivityQuery
firstPage = ActivityQuery {actor = Nothing, offset = 0}

-- | How many entries a page has.
activityPageSize :: Int
activityPageSize = 50

-- | A page of the log.
data Activity = Activity
  { available :: Bool
  -- ^ Whether the backend keeps a log at all: the demo's does not.
  , entries :: [AuditEntry]
  -- ^ At most 'activityPageSize', the newest first.
  , more :: Bool
  -- ^ Whether there are older entries after these.
  , actors :: [Actor]
  -- ^ Everyone the log has an entry of, by login: whom it can be filtered
  -- by.
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''Activity
