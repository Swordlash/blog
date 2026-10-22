-- | Addresses made of slugs, and the trees they walk.
--
-- Spaces form a tree, and so do the pages of one space. A node is addressed by
-- the slugs on the way to it from the root of its tree: the space @b@ inside
-- @a@ is @a\/b@, and a page is its space's path together with the page slugs
-- from the space's top-level pages (@a\/b@ and @p\/q@). Slugs are unique among
-- siblings, which is what makes such a path name one node.
--
-- This module knows trees, not storage: 'resolvePath' is handed a lookup of a
-- node's child by slug, 'ancestry' a lookup by id, and both backends (in
-- memory and over HTTP) and the router use the same functions over their own
-- lookups.
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

-- | Something that sits in a tree of slugged nodes: a space, or a page.
class TreeNode a where
  -- | What names a node in its tree, and what its parent is given as.
  type NodeId a

  nodeId :: a -> NodeId a

  -- | The node's parent, or 'Nothing' at the root of the tree.
  nodeParent :: a -> Maybe (NodeId a)

  -- | The node's own segment of a path.
  nodeSlug :: a -> Slug

-- | The child of a parent ('Nothing' for the roots) with this slug, among the
-- nodes of one tree. This is the lookup 'resolvePath' wants, for a backend
-- that holds its nodes in a list or a map; it is also how a backend checks
-- that a slug is free before it gives it to a new node.
findChild :: (TreeNode a, Eq (NodeId a), Foldable f) => f a -> Maybe (NodeId a) -> Slug -> Maybe a
findChild nodes parent slug =
  find (\n -> nodeParent n == parent && nodeSlug n == slug) nodes

-- | The children of a parent ('Nothing' for the roots), in the order the
-- nodes are given.
childrenOf :: (TreeNode a, Eq (NodeId a), Foldable f) => f a -> Maybe (NodeId a) -> [a]
childrenOf nodes parent = filter (\n -> nodeParent n == parent) (toList nodes)

-- | A path that leads nowhere: the nodes it went through, root first, and
-- the first slug that has no node.
data PathError a = PathError
  { resolved :: [a]
  , missing :: Slug
  }
  deriving stock (Eq, Show)

-- | The nodes a path goes through, root first, so that the last one is the
-- node the path names and the list is the chain of ancestors that
-- breadcrumbs show and permission rules ask about. The empty path resolves
-- to no nodes: the root of the tree, which is not a node itself.
resolvePath
  :: (TreeNode a)
  => (Maybe (NodeId a) -> Slug -> Maybe a)
  -- ^ The child of a parent with a slug.
  -> [Slug]
  -> Either (PathError a) [a]
resolvePath child = runIdentity . resolvePathM (\p s -> Identity (child p s))

-- | 'resolvePath' with a lookup that has effects, for a backend that asks
-- for one level at a time.
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

-- | A node and its ancestors, root first: the nodes 'resolvePath' gives for
-- the node's path. 'Nothing' when the node, or one of its ancestors, is not
-- found, or when the parents go round in a circle, which a bad move could
-- make and which would otherwise never end.
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

-- | A path as it is written in an address, its slugs between slashes and
-- none around them: @a\/b@.
renderPath :: [Slug] -> Text
renderPath = T.intercalate "/" . map slugText

-- | The slugs of a path written as 'renderPath' writes it. A slash at either
-- end is allowed and ignored, so @\/a\/b\/@ is @a\/b@ too, and the empty text
-- (or a lone slash) is the empty path; anything between two slashes must be a
-- slug, so @a\/\/b@ is an error.
parsePath :: Text -> Either SlugError [Slug]
parsePath t = case dropEnds t of
  "" -> Right []
  inner -> traverse mkSlug (T.splitOn "/" inner)
  where
    dropEnds = dropEnd . dropStart
    dropStart s = fromMaybe s (T.stripPrefix "/" s)
    dropEnd s = fromMaybe s (T.stripSuffix "/" s)
