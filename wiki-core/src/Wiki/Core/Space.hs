{-# LANGUAGE DeriveAnyClass #-}

-- | Spaces: the tree that holds the wiki's pages, and the unit permissions
-- are granted on.
module Wiki.Core.Space
  ( Space (..)
  , positionSpace
  , subspaceOrderOf
  , subspacesOf
  , spaceTreeOrder
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Slug

-- | A space, or a subspace of another.
data Space = Space
  { id :: SpaceId
  , name :: Text
  -- ^ What the space is called where it is shown.
  , slug :: Slug
  -- ^ Its segment of an address, unique among its siblings.
  , parent :: Maybe SpaceId
  -- ^ The space it is a subspace of, or 'Nothing' for a top-level space.
  , public :: Bool
  -- ^ Whether anyone may read it, signed in or not; its subspaces inherit
  -- that as they inherit any grant (see "Wiki.Core.Permission").
  , mathMacros :: Text
  -- ^ TeX macros for the formulas of its pages and of its subspaces' pages,
  -- as @\\newcommand@ lines (or any definitions KaTeX reads); empty for
  -- none. A subspace's own come after its parent's, so that a macro it
  -- defines again is its own ("Wiki.Core.Math").
  , createdAt :: UTCTime
  -- ^ Set by the backend when the space is made.
  , position :: Int
  -- ^ Where it was put among its siblings by hand, for a parent that
  -- orders its subspaces 'ByHand' ("Wiki.Core.Order").
  , subspaceOrder :: ChildOrder
  -- ^ The order its subspaces are listed in.
  , pageOrder :: ChildOrder
  -- ^ The order its pages are listed in, and the pages under each page.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Space where
  type NodeId Space = SpaceId
  nodeId s = s.id
  nodeParent s = s.parent
  nodeSlug s = s.slug

instance Sibling Space where
  siblingName s = s.name
  siblingCreatedAt s = s.createdAt
  siblingPosition s = s.position

-- | The order the subspaces of a parent ('Nothing' for the top level) are
-- listed in, among the spaces given: the parent's 'subspaceOrder'. The
-- top-level spaces have no parent to choose one, and are listed by name.
subspaceOrderOf :: [Space] -> Maybe SpaceId -> ChildOrder
subspaceOrderOf spaces = \case
  Nothing -> ByName
  Just p -> maybe ByName (\s -> s.subspaceOrder) (find (\s -> s.id == p) spaces)

-- | The subspaces of a parent ('Nothing' for the top level), in the order
-- it lists them ('subspaceOrderOf'): what every list of spaces shows.
subspacesOf :: [Space] -> Maybe SpaceId -> [Space]
subspacesOf spaces parent = childrenInOrder (subspaceOrderOf spaces parent) spaces parent

-- | All the spaces as one list, each followed by its subspaces, each
-- space's subspaces in its order ('Wiki.Core.Order.treeOrder').
spaceTreeOrder :: [Space] -> [Space]
spaceTreeOrder spaces = treeOrder (subspaceOrderOf spaces) spaces

-- | The space at another position among its siblings. (A function, since a
-- record update of @position@ cannot tell a space's from a page's where
-- both are in scope.)
positionSpace :: Int -> Space -> Space
positionSpace position s = s {position}
