{-# LANGUAGE DeriveAnyClass #-}

-- | Drafts: text a user has written in the editor and not yet saved,
-- stored for that user only.
--
-- The editor saves a draft of the page's title and body a few seconds after
-- the user stops typing, so that the work survives a closed tab or a
-- crash. Saving the page itself is still the author's decision. A draft is
-- private to its author: nobody else sees it, readers of the page
-- included. It is not part of an export: it is one person's work in
-- progress, and an archive holds the wiki's content, which anyone who
-- imports the archive can read.
--
-- A user has at most one draft of a page. The draft records the version of
-- the page it was started from ('base', the page's @updatedAt@ at the
-- time). With it the editor tells two cases apart. If the page has not
-- been saved since, the editor resumes the draft. If someone has saved the
-- page since, the editor only offers the draft, because saving it would
-- undo the changes of that later save.
--
-- In JSON (the server's API) a draft is an object with the record's field
-- names. It is never part of an archive, so "Wiki.Core.Export" has no
-- record format for it.
module Wiki.Core.Draft
  ( Draft (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id

-- | 'Draft': a user's unsaved work on a page.
data Draft = Draft
  { page :: PageId
  , author :: UserId
  , title :: Text
  -- ^ As typed. It may be blank, since it is not yet saved as the page's title.
  , body :: Text
  , base :: UTCTime
  -- ^ The @updatedAt@ of the page version the work started from: the
  -- version a save of the draft is checked against.
  , savedAt :: UTCTime
  -- ^ When the draft was last saved.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
