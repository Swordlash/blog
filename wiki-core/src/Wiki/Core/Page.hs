{-# LANGUAGE DeriveAnyClass #-}

-- | Pages: Markdown in a tree within a space.
module Wiki.Core.Page
  ( Page (..)
  , treePages
  , templatePages
  , childPages
  , positionPage
  , pageTreeOrder
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder, Sibling (..), childrenInOrder, treeOrder)
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
  , position :: Int
  -- ^ Where it was put among its siblings by hand, for a space that orders
  -- its pages 'Wiki.Core.Order.ByHand'.
  , template :: Bool
  -- ^ Whether it is one of its space's templates ("Wiki.Core.Template"):
  -- a page like any other (it has a history, comments and the space's
  -- permissions), listed under the space's "Templates" rather than in its
  -- tree, left out of a search that does not ask for templates, and
  -- offered as the start of a new page.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Page where
  type NodeId Page = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

instance Sibling Page where
  siblingName p = p.title
  siblingCreatedAt p = p.createdAt
  siblingPosition p = p.position

-- | The pages a space's tree shows: all but its templates, which are
-- listed apart ('templatePages'). A page under a template is a template's
-- part and is left out with it.
treePages :: [Page] -> [Page]
treePages pages = [p | p <- pages, not (underTemplate p)]
  where
    byId = Map.fromList [(p.id, p) | p <- pages]
    underTemplate p = p.template || maybe False underTemplate (p.parent >>= (`Map.lookup` byId))

-- | A space's templates, among its pages, by title.
templatePages :: [Page] -> [Page]
templatePages pages = sortOn (\p -> p.title) [p | p <- pages, p.template]

-- | The pages under a page ('Nothing' for the space's top level), among the
-- pages of its space, in the space's page order
-- ('Wiki.Core.Space.pageOrder'): what every list of pages shows.
childPages :: ChildOrder -> [Page] -> Maybe PageId -> [Page]
childPages = childrenInOrder

-- | All the pages of a space as one list, each followed by the pages under
-- it, in the space's page order.
pageTreeOrder :: ChildOrder -> [Page] -> [Page]
pageTreeOrder order = treeOrder (const order)

-- | The page at another position among its siblings. (A function, since a
-- record update of @position@ cannot tell a page's from a space's where
-- both are in scope.)
positionPage :: Int -> Page -> Page
positionPage position p = p {position}
