{-# LANGUAGE TemplateHaskell #-}

-- | Drafts: what someone has written in the editor and not yet saved, kept
-- for them alone.
--
-- The editor saves a draft of the page's title and body a few seconds after
-- the typing stops, so that work survives a closed tab or a crash; saving
-- the page itself is still the author's decision. A draft is private to its
-- author: nobody else sees it, readers of the page least of all, and it is
-- not part of an export (it is work in progress, one person's, and an
-- archive is the wiki's content, which whoever imports it reads).
--
-- A user has at most one draft of a page. It remembers the version of the
-- page it was written from ('base', the page's @updatedAt@ then), so that
-- the editor can tell a draft of the page as it still is, which it can take
-- up where it was left, from one of a version someone has saved over since,
-- which it only offers: saving that one would put back what the later save
-- changed.
--
-- In JSON (the server's API) a draft is an object with the record's field
-- names; it is never part of an archive, so "Wiki.Core.Export" has no
-- record format for it.
module Wiki.Core.Draft
  ( Draft (..)
  )
where

import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id
import Wiki.Core.Json (defaultOptions, deriveValueJSON)

-- | A user's unsaved work on a page.
data Draft = Draft
  { page :: PageId
  , author :: UserId
  , title :: Text
  -- ^ As typed: it may be blank, since it is not saved as the page's yet.
  , body :: Text
  , base :: UTCTime
  -- ^ The @updatedAt@ of the version of the page the work started from:
  -- what a save of it is made against.
  , savedAt :: UTCTime
  -- ^ When the draft was last saved.
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''Draft
