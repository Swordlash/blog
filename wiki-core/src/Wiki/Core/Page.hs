{-# LANGUAGE DeriveAnyClass #-}

-- | Pages: Markdown in a tree within a space.
module Wiki.Core.Page
  ( Page (..)
  , PageSummary (..)
  , summaryOf
  , treePages
  , templatePages
  , childPages
  , positionPage
  , pageTreeOrder
  , savedAs
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, addUTCTime)
import Data.Type.Equality (type (~))
import Protolude
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder, Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Slug

-- | 'Page': a page. Pages form a tree within one space, so a page's parent,
-- and the lookups "Wiki.Core.Path" is given for pages, are among the pages
-- of its own space only.
data Page = Page
  { id :: PageId
  , space :: SpaceId
  -- ^ The space the page is in.
  , parent :: Maybe PageId
  -- ^ The page it is a child of, in the same space, or 'Nothing' for a
  -- top-level page of the space.
  , title :: Text
  , slug :: Slug
  -- ^ Its address segment, unique among its siblings.
  , body :: Text
  -- ^ The Markdown source, which is what is stored; the page is rendered
  -- from it wherever it is shown.
  , attachments :: [Attachment]
  , createdAt :: UTCTime
  -- ^ Set by the backend when the page is created.
  , updatedAt :: UTCTime
  -- ^ Set by the backend on every save.
  , position :: Int
  -- ^ Its position among its siblings, set by hand, for a space that
  -- orders its pages 'Wiki.Core.Order.ByHand'.
  , template :: Bool
  -- ^ Whether it is one of its space's templates ("Wiki.Core.Template").
  -- A template is a page like any other (it has a history, comments and
  -- the space's permissions), but it is listed under the space's
  -- "Templates" rather than in its tree, left out of a search that does
  -- not ask for templates, and offered as the start of a new page.
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

-- | 'PageSummary' is a page without its Markdown body and its
-- attachments. A list of a space's pages holds summaries
-- ('Wiki.App.Backend.listPages'). The sidebar's tree, the space's view,
-- the blog's list of posts and the editor's choice of a parent need only
-- these fields. The body is fetched with the page alone
-- ('Wiki.App.Backend.getPage'), so a list stays small however long the
-- pages are.
data PageSummary = PageSummary
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , title :: Text
  , slug :: Slug
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  , position :: Int
  , template :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode PageSummary where
  type NodeId PageSummary = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

instance Sibling PageSummary where
  siblingName p = p.title
  siblingCreatedAt p = p.createdAt
  siblingPosition p = p.position

-- | The summary of a page: the page without its body and attachments.
summaryOf :: Page -> PageSummary
summaryOf p =
  PageSummary
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title = p.title
    , slug = p.slug
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position = p.position
    , template = p.template
    }

-- | The pages a space's tree shows: all except its templates, which are
-- listed separately ('templatePages'). A page under a template belongs to
-- the template and is left out with it.
treePages :: [PageSummary] -> [PageSummary]
treePages pages = [p | p <- pages, not (underTemplate p)]
  where
    byId = Map.fromList [(p.id, p) | p <- pages]
    underTemplate p = p.template || maybe False underTemplate (p.parent >>= (`Map.lookup` byId))

-- | A space's templates, among its pages, by title.
templatePages :: [PageSummary] -> [PageSummary]
templatePages pages = sortOn (\p -> p.title) [p | p <- pages, p.template]

-- | The pages under a page ('Nothing' for the space's top level), among the
-- pages of its space, in the space's page order
-- ('Wiki.Core.Space.pageOrder'). Every list of pages uses it.
childPages :: (Sibling p, NodeId p ~ PageId) => ChildOrder -> [p] -> Maybe PageId -> [p]
childPages = childrenInOrder

-- | All the pages of a space as one list, each followed by the pages under
-- it, in the space's page order.
pageTreeOrder :: (Sibling p, NodeId p ~ PageId) => ChildOrder -> [p] -> [p]
pageTreeOrder order = treeOrder (const order)

-- | The page at another position among its siblings. (A function, since a
-- record update of @position@ cannot tell a page's field from a space's
-- or a summary's where they are in scope. The page is built field by field
-- for the same reason.)
positionPage :: Int -> Page -> Page
positionPage position p =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title = p.title
    , slug = p.slug
    , body = p.body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position
    , template = p.template
    }

-- | A page saved with a new title and text at a time: its new version. The
-- version is later than the one it replaces even if the clock says
-- otherwise, so that no two versions of a page have the same time and an
-- editor open on the page sees that it has changed. A save, an import
-- that takes the imported page, and the guide's update all make a new
-- version this way.
savedAs :: UTCTime -> Text -> Text -> Page -> Page
savedAs time title body p =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title
    , slug = p.slug
    , body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = if time > p.updatedAt then time else addUTCTime 0.000001 p.updatedAt
    , position = p.position
    , template = p.template
    }
