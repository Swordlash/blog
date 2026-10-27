-- | Paths: addresses made of slugs, and the trees they lead through.
--
-- Spaces form a tree, and so do the pages of one space. A node is addressed
-- by the slugs from the root of its tree down to it: the space @b@ inside
-- @a@ is @a\/b@, and a page is its space's path together with the page
-- slugs from the space's top-level pages (@a\/b@ and @p\/q@). Slugs are
-- unique among siblings, so such a path names exactly one node.
--
-- This module knows trees, not storage: 'resolvePath' takes a function
-- that finds a node's child by slug, and 'ancestry' one that finds a node
-- by id. Both backends (in memory and over HTTP) and the router use the
-- same functions with their own lookups.
module Wiki.Core.Path
  ( -- * Trees
    TreeNode (..)
  , findChild
  , childrenOf

    -- * From a path to the nodes
  , PathError (..)
  , resolvePath
  , resolvePathM

    -- * From a node to its path
  , ancestry
  , pathOf

    -- * Paths as text
  , renderPath
  , parsePath
  )
where

import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Core.Slug

-- | 'TreeNode': a node in a tree of slugged nodes, either a space or a page.
class TreeNode a where
  -- | The type of a node's id, which also identifies its parent.
  type NodeId a

  nodeId :: a -> NodeId a

  -- | The node's parent, or 'Nothing' at the root of the tree.
  nodeParent :: a -> Maybe (NodeId a)

  -- | The node's own path segment.
  nodeSlug :: a -> Slug

-- | The child of a parent ('Nothing' for the top level) with this slug,
-- among the nodes of one tree. This is the lookup 'resolvePath' needs, for
-- a backend that holds its nodes in a list or a map. A backend also uses it
-- to check that a slug is free before giving it to a new node.
findChild :: (TreeNode a, Eq (NodeId a), Foldable f) => f a -> Maybe (NodeId a) -> Slug -> Maybe a
findChild nodes parent slug =
  find (\n -> nodeParent n == parent && nodeSlug n == slug) nodes

-- | The children of a parent ('Nothing' for the top level), in the order
-- of the given nodes.
childrenOf :: (TreeNode a, Eq (NodeId a), Foldable f) => f a -> Maybe (NodeId a) -> [a]
childrenOf nodes parent = filter (\n -> nodeParent n == parent) (toList nodes)

-- | 'PathError': a path that leads nowhere. It holds the nodes the path
-- went through, root first, and the first slug that matches no node.
data PathError a = PathError
  { resolved :: [a]
  , missing :: Slug
  }
  deriving stock (Eq, Show)

-- | The nodes a path goes through, root first. The last one is the node the
-- path names, and the list is the chain of ancestors that breadcrumbs show
-- and permission rules check. The empty path resolves to no nodes: the
-- root of the tree, which is not a node itself.
resolvePath
  :: (TreeNode a)
  => (Maybe (NodeId a) -> Slug -> Maybe a)
  -- ^ Finds the child of a parent with a slug.
  -> [Slug]
  -> Either (PathError a) [a]
resolvePath child = runIdentity . resolvePathM (\p s -> Identity (child p s))

-- | 'resolvePath' with a lookup that runs in a monad, for a backend that
-- fetches one level at a time.
resolvePathM
  :: (Monad m, TreeNode a)
  => (Maybe (NodeId a) -> Slug -> m (Maybe a))
  -> [Slug]
  -> m (Either (PathError a) [a])
resolvePathM child = go Nothing []
  where
    go _ acc [] = pure (Right (reverse acc))
    go parent acc (slug : rest) =
      child parent slug >>= \case
        Nothing -> pure (Left PathError {resolved = reverse acc, missing = slug})
        Just node -> go (Just (nodeId node)) (node : acc) rest

-- | A node and its ancestors, root first: the nodes 'resolvePath' returns
-- for the node's path. 'Nothing' when the node, or one of its ancestors,
-- is not found, or when the parents form a cycle, which a bad move could
-- create and which would otherwise loop forever.
ancestry :: (TreeNode a, Ord (NodeId a)) => (NodeId a -> Maybe a) -> NodeId a -> Maybe [a]
ancestry byId = go Set.empty []
  where
    go seen acc i
      | i `Set.member` seen = Nothing
      | otherwise = do
          node <- byId i
          case nodeParent node of
            Nothing -> Just (node : acc)
            Just parent -> go (Set.insert i seen) (node : acc) parent

-- | The path of a node, from its id: the slugs of its 'ancestry'.
pathOf :: (TreeNode a, Ord (NodeId a)) => (NodeId a -> Maybe a) -> NodeId a -> Maybe [Slug]
pathOf byId i = map nodeSlug <$> ancestry byId i

-- | A path as written in an address: its slugs separated by slashes, with
-- no slash at either end: @a\/b@.
renderPath :: [Slug] -> Text
renderPath = T.intercalate "/" . map slugText

-- | The slugs of a path written as 'renderPath' writes it. A slash at
-- either end is allowed and ignored, so @\/a\/b\/@ is also @a\/b@, and the
-- empty text (or a lone slash) is the empty path. The text between two
-- slashes must be a slug, so @a\/\/b@ is an error.
parsePath :: Text -> Either SlugError [Slug]
parsePath t = case dropEnds t of
  "" -> Right []
  inner -> traverse mkSlug (T.splitOn "/" inner)
  where
    dropEnds = dropEnd . dropStart
    dropStart s = fromMaybe s (T.stripPrefix "/" s)
    dropEnd s = fromMaybe s (T.stripSuffix "/" s)
