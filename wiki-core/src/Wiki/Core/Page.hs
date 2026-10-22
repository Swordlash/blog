{-# LANGUAGE DeriveAnyClass #-}

-- | Pages: Markdown in a tree within a space.
module Wiki.Core.Page
  ( Page (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Id
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Slug

-- | A page. Pages form a tree within one space, so a page's parent, and the
-- lookups "Wiki.Core.Path" is given for pages, are among the pages of its own
-- space only.
data Page = Page
  { id :: PageId
  , space :: SpaceId
  -- ^ The space the page is in.
  , parent :: Maybe PageId
  -- ^ The page it is a child of, in the same space, or 'Nothing' for one
  -- of the space's top-level pages.
  , title :: Text
  , slug :: Slug
  -- ^ Its segment of an address, unique among its siblings.
  , body :: Text
  -- ^ The Markdown source, which is what is stored; the rendered page is
  -- made from it wherever it is shown.
  , attachments :: [Attachment]
  , createdAt :: UTCTime
  -- ^ Set by the backend when the page is created.
  , updatedAt :: UTCTime
  -- ^ Set by the backend on every save.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Page where
  type NodeId Page = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug
