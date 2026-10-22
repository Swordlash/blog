{-# LANGUAGE DeriveAnyClass #-}

-- | Spaces: the tree that holds the wiki's pages, and the unit permissions
-- are granted on.
module Wiki.Core.Space
  ( Space (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Wiki.Core.Id
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
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Space where
  type NodeId Space = SpaceId
  nodeId s = s.id
  nodeParent s = s.parent
  nodeSlug s = s.slug
