{-# LANGUAGE DeriveAnyClass #-}

-- | Page versions: a page's history. Every save of a page creates a
-- version of it, kept as long as the page exists.
--
-- A version is identified by the page and the time it was saved, which is
-- the page's @updatedAt@ in that version. Every save makes @updatedAt@
-- later, so no two versions of a page share one, and a save is checked
-- against that same time (over HTTP, it is also the page's @ETag@). The
-- current page is its latest version, so a page's history is never empty.
-- It starts with the page as it was created, or, for a page that was
-- imported whole (from an export archive, or from before history was
-- kept), as it was then.
--
-- The history is never rewritten. Restoring an earlier version saves its
-- title and body as a new version, which keeps every version in between.
--
-- In JSON (the server's API) a version is an object with the record's
-- field names. Versions are not part of an export (docs/export.md): an
-- archive holds the wiki's content, and a page's history can be many
-- times its size.
--
-- A history is listed a page of versions at a time ('VersionsQuery'), the
-- latest first, since a page saved thousands of times has a history too
-- long to send whole. Each version carries its number, counted from the
-- first, so a page of the history can say which versions it shows.
module Wiki.Core.Version
  ( VersionInfo (..)
  , Version (..)
  , Author (..)
  , versionInfo
  , VersionsQuery (..)
  , latestVersions
  , versionsPageSize
  , maxVersionsPageSize
  , versionsPage
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id

-- | 'Author': who saved a version, as the history shows them.
data Author = Author
  { id :: UserId
  , name :: Text
  -- ^ Their display name; for a user who no longer exists in the wiki,
  -- their id, which is the only thing left of them.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'VersionInfo': one version of a page as its history lists it: when it
-- was saved, by whom, and under what title. The body is fetched
-- separately, since a history lists many versions and shows one at a time.
data VersionInfo = VersionInfo
  { page :: PageId
  , updatedAt :: UTCTime
  -- ^ The page's @updatedAt@ in this version: the version's identifier.
  , title :: Text
  , author :: Maybe Author
  -- ^ 'Nothing' when nobody is known to have saved it: a page that was
  -- imported whole.
  , number :: Int
  -- ^ Its place in the page's history: 1 for the first version, and the
  -- number of versions for the latest. Versions are never deleted, so a
  -- version keeps its number.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Version': one version of a page, with its body.
data Version = Version
  { page :: PageId
  , updatedAt :: UTCTime
  , title :: Text
  , body :: Text
  -- ^ The Markdown as it was saved.
  , author :: Maybe Author
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The part of a version a history lists, given its number.
versionInfo :: Int -> Version -> VersionInfo
versionInfo number v = VersionInfo {page = v.page, updatedAt = v.updatedAt, title = v.title, author = v.author, number}

-- | 'VersionsQuery' says which page of a history to list: at most 'limit'
-- versions, the latest first, of those saved before 'before' (of every
-- version, for 'Nothing'). The next page of a history is the one before
-- the oldest version listed so far.
data VersionsQuery = VersionsQuery
  { before :: Maybe UTCTime
  , limit :: Int
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The first page of a history: its 'versionsPageSize' latest versions.
latestVersions :: VersionsQuery
latestVersions = VersionsQuery {before = Nothing, limit = versionsPageSize}

-- | How many versions a page of a history lists, unless asked for another
-- number.
versionsPageSize :: Int
versionsPageSize = 50

-- | The most versions one page of a history lists, whatever is asked for.
maxVersionsPageSize :: Int
maxVersionsPageSize = 500

-- | The page of a history a query asks for, from the whole history, the
-- latest first: for a backend that holds the whole history at hand. A
-- limit below one, or above 'maxVersionsPageSize', counts as the nearest
-- of the two.
versionsPage :: VersionsQuery -> [VersionInfo] -> [VersionInfo]
versionsPage q = take (max 1 (min maxVersionsPageSize q.limit)) . filter (\v -> maybe True (v.updatedAt <) q.before)
