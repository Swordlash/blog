{-# LANGUAGE DeriveAnyClass #-}

-- | A page's history: every save of a page is a version of it, kept for as
-- long as the page is.
--
-- A version is named by the page and the time it was saved at, which is the
-- page's @updatedAt@ as that version: every save makes it later, so no two
-- versions of a page share one, and it is the very time a save of the page
-- is checked against (and, over HTTP, the page's @ETag@). The page as it is
-- now is its latest version, so a page's history is never empty: it starts
-- with the page as it was made, or, for a page that came in whole (from an
-- export archive, or from before the history was kept), as it was then.
--
-- The history is never rewritten. Going back to an earlier version is a
-- save of its title and body as a new version, which keeps everything in
-- between.
--
-- In JSON (the server's API) a version is an object with the record's
-- field names. Versions are not part of an export (docs/export.md): an
-- archive is the wiki's content, and a page's history can be many times its
-- size.
module Wiki.Core.Version
  ( VersionInfo (..)
  , Version (..)
  , Author (..)
  , versionInfo
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id

-- | Who saved a version, as a reader of the history sees them.
data Author = Author
  { id :: UserId
  , name :: Text
  -- ^ Their display name; for someone who is no longer one of the wiki's
  -- users, their id, which is all that is left of them.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One version of a page as its history lists it: when, by whom, and under
-- what title. The body is fetched by itself, since a history lists many
-- versions and shows one at a time.
data VersionInfo = VersionInfo
  { page :: PageId
  , updatedAt :: UTCTime
  -- ^ The page's @updatedAt@ as this version: its name among the page's.
  , title :: Text
  , author :: Maybe Author
  -- ^ 'Nothing' when nobody is known to have saved it: a page that came
  -- in whole, as an import does.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | One version of a page, whole.
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

-- | What a history lists of a version.
versionInfo :: Version -> VersionInfo
versionInfo v = VersionInfo {page = v.page, updatedAt = v.updatedAt, title = v.title, author = v.author}
