-- | Paths: addresses made of slugs, and the trees they lead through.
--
-- Spaces form a tree, and so do the pages of one space. A node is addressed
-- by the slugs from the root of its tree down to it: the space @b@ inside
-- @a@ is @a\/b@, and a page is its space's path together with the page
-- slugs from the space's top-level pages (@a\/b@ and @p\/q@). Slugs are
-- unique among siblings, so such a path names exactly one node.
--
-- A space's pages have one root, its home page, which has no segment of
-- its own ('pathUnder', 'resolveUnder'): the page @p@ above is a page under
-- the home page, and the space's own path is the home page's.
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

    -- * Trees with a root that has no segment
  , pathUnder
  , resolveUnder
  , resolveUnderM
  , resolveFromRoot

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
resolvePathM child = walkFrom child Nothing

-- | The nodes a path goes through from a parent ('Nothing' for the top of
-- the tree), the parent left out.
walkFrom :: (Monad m, TreeNode a) => (Maybe (NodeId a) -> Slug -> m (Maybe a)) -> Maybe (NodeId a) -> [Slug] -> m (Either (PathError a) [a])
walkFrom child = go []
  where
    go acc _ [] = pure (Right (reverse acc))
    go acc parent (slug : rest) =
      child parent slug >>= \case
        Nothing -> pure (Left PathError {resolved = reverse acc, missing = slug})
        Just node -> go (node : acc) (Just (nodeId node)) rest

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

--------------------------------------------------------------------------------
-- Trees with a root that has no segment

-- | 'pathUnder' is the path of a node in a tree whose root has no segment
-- of its own: a space's pages, where the root is the space's home page
-- (WP5.78 of docs/PLAN.md) and the space's own address is the home page's.
-- The root's path is empty, and every other node's path is the slugs of
-- its 'ancestry' without the root's. A tree with no root ('Nothing', an
-- encrypted space's pages) has every slug, as 'pathOf' gives them. So does
-- a node whose top ancestor is not the root, which a tree with a root does
-- not have.
pathUnder :: (TreeNode a, Ord (NodeId a)) => Maybe (NodeId a) -> (NodeId a -> Maybe a) -> NodeId a -> Maybe [Slug]
pathUnder root byId i = withoutRoot <$> ancestry byId i
  where
    withoutRoot = \case
      top : rest | Just (nodeId top) == root -> map nodeSlug rest
      chain -> map nodeSlug chain

-- | The nodes a path goes through in a tree whose root has no segment
-- ('pathUnder'), the root first. The path starts under the root, so the
-- empty path is the root alone. With no root, it is 'resolvePath'.
--
-- So that the addresses of the time before the root lost its segment
-- still lead somewhere, a path that names nothing as written, and whose
-- first segment is the root's slug, is read again without that segment,
-- once. When that names nothing either, the error is the one of the path
-- as written.
resolveUnder :: (TreeNode a) => Maybe a -> (Maybe (NodeId a) -> Slug -> Maybe a) -> [Slug] -> Either (PathError a) [a]
resolveUnder root child = runIdentity . resolveUnderM root (\p s -> Identity (child p s))

-- | 'resolveUnder' with a lookup that runs in a monad, for a backend that
-- fetches one level at a time.
resolveUnderM :: (Monad m, TreeNode a) => Maybe a -> (Maybe (NodeId a) -> Slug -> m (Maybe a)) -> [Slug] -> m (Either (PathError a) [a])
resolveUnderM Nothing child path = resolvePathM child path
resolveUnderM (Just root) child path =
  under path >>= \case
    Left e
      | top : rest <- path
      , top == nodeSlug root ->
          either (const (Left e)) Right <$> under rest
    found -> pure found
  where
    under p = bimap (\e -> PathError {resolved = root : e.resolved, missing = e.missing}) (root :) <$> walkFrom child (Just (nodeId root)) p

-- | The nodes a path goes through in a tree whose root has no segment
-- ('pathUnder'), the root first, read exactly as written: 'resolveUnder'
-- without its rule for old addresses. What compares a path with another,
-- or matches one page with another by path, reads it so: an old address
-- is for a person who typed it, and could name another page than the one
-- the path is now. With no root, it is 'resolvePath'.
resolveFromRoot :: (TreeNode a) => Maybe a -> (Maybe (NodeId a) -> Slug -> Maybe a) -> [Slug] -> Either (PathError a) [a]
resolveFromRoot Nothing child path = resolvePath child path
resolveFromRoot (Just root) child path =
  bimap (\e -> PathError {resolved = root : e.resolved, missing = e.missing}) (root :) (runIdentity (walkFrom (\p s -> Identity (child p s)) (Just (nodeId root)) path))

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
