{-# LANGUAGE DeriveAnyClass #-}

-- | Who may do what: the permission model, as data and pure rules.
--
-- There are two global permissions, 'Administer' (everything, everywhere) and
-- 'CreateSpaces', and three on a space, 'View', 'Edit' and 'AdministerSpace'
-- (its permissions, deleting it, moving it). Each is granted to a 'Subject',
-- a user or a group. A subspace inherits its parent's grants and may add its
-- own; it cannot take one away, so what someone may do in a space is what
-- they are granted on it or on any of its ancestors. A public space grants
-- 'View' to everyone, signed in or not, and since that is a grant like any
-- other, its subspaces are public too. There are no page-level permissions: a
-- page is as visible and as editable as its space.
--
-- The rules take everything they need as arguments and read no store, so the
-- server enforces them and the client uses the very same functions to hide
-- what the current user cannot do.
module Wiki.Core.Permission
  ( -- * Permissions
    GlobalPermission (..)
  , SpacePermission (..)
  , globalImplies
  , spaceImplies

    -- * Grants
  , Subject (..)
  , GlobalGrant (..)
  , SpaceGrant (..)
  , Grants (..)

    -- * Who is asking
  , Principal (..)
  , principal

    -- * Rules
  , hasGlobalPermission
  , hasSpacePermission
  , spacePermissions
  , canCreateSpaces
  , canView
  , canEdit
  , canAdministerSpace
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Set qualified as Set
import Protolude
import Wiki.Core.Id
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Membership, groupsOf)

-- | What can be granted on the wiki as a whole.
data GlobalPermission
  = -- | Everything: every global permission and every permission on every
    -- space.
    Administer
  | -- | Creating spaces.
    CreateSpaces
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What can be granted on a space, and so on its subspaces and pages.
data SpacePermission
  = -- | Reading its pages.
    View
  | -- | Creating, changing and deleting its pages; implies 'View'.
    Edit
  | -- | Changing its grants, deleting it and moving it; implies 'Edit'.
    AdministerSpace
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether holding the first global permission means holding the second.
globalImplies :: GlobalPermission -> GlobalPermission -> Bool
globalImplies Administer _ = True
globalImplies CreateSpaces p = p == CreateSpaces

-- | Whether holding the first space permission means holding the second.
spaceImplies :: SpacePermission -> SpacePermission -> Bool
spaceImplies AdministerSpace _ = True
spaceImplies Edit p = p == Edit || p == View
spaceImplies View p = p == View

-- | Who a grant is for.
data Subject
  = SubjectUser UserId
  | -- | Every member of the group, as membership is at the time of asking.
    SubjectGroup GroupId
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A global permission given to someone.
data GlobalGrant = GlobalGrant
  { subject :: Subject
  , permission :: GlobalPermission
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A permission on a space given to someone; it holds in the space's
-- subspaces too.
data SpaceGrant = SpaceGrant
  { space :: SpaceId
  , subject :: Subject
  , permission :: SpacePermission
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The grants the rules look at. The space grants may be all of the wiki's
-- or only those of the spaces asked about: a rule only counts the grants of
-- the spaces it is given.
data Grants = Grants
  { global :: [GlobalGrant]
  , spaces :: [SpaceGrant]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Semigroup Grants where
  a <> b = Grants {global = a.global <> b.global, spaces = a.spaces <> b.spaces}

instance Monoid Grants where
  mempty = Grants {global = [], spaces = []}

-- | A signed-in user, as the rules see them: who they are and which groups
-- they are in. Someone who is not signed in is 'Nothing' where a rule asks
-- for a @'Maybe' 'Principal'@.
data Principal = Principal
  { user :: UserId
  , groups :: Set GroupId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A user with the groups the membership puts them in.
principal :: Membership -> UserId -> Principal
principal membership user = Principal {user, groups = groupsOf membership user}

-- | Whether a grant to this subject is a grant to this principal.
isFor :: Principal -> Subject -> Bool
isFor p = \case
  SubjectUser u -> u == p.user
  SubjectGroup g -> g `Set.member` p.groups

-- | Whether someone holds a global permission. Nobody who is not signed in
-- does.
hasGlobalPermission :: Maybe Principal -> Grants -> GlobalPermission -> Bool
hasGlobalPermission Nothing _ _ = False
hasGlobalPermission (Just p) grants wanted =
  any (\g -> isFor p g.subject && g.permission `globalImplies` wanted) grants.global

-- | Everything someone may do in a space, given the chain of spaces from a
-- top-level one down to it ('Wiki.Core.Path.ancestry' or
-- 'Wiki.Core.Path.resolvePath' give it), closed under implication: holding
-- 'Edit' there means the set has 'View' too. The empty chain is no space,
-- where only 'Administer' gives anything.
spacePermissions :: Maybe Principal -> Grants -> [Space] -> Set SpacePermission
spacePermissions who grants chain
  | hasGlobalPermission who grants Administer = Set.fromList [minBound .. maxBound]
  | otherwise = Set.fromList (concatMap implied granted)
  where
    implied held = filter (spaceImplies held) [minBound .. maxBound]
    granted = publicView <> fromGrants
    publicView = [View | any (\s -> s.public) chain]
    inChain = Set.fromList (map (\s -> s.id) chain)
    fromGrants = case who of
      Nothing -> []
      Just p ->
        [ g.permission
        | g <- grants.spaces
        , g.space `Set.member` inChain
        , isFor p g.subject
        ]

-- | Whether someone may do this in the last space of the chain.
hasSpacePermission :: Maybe Principal -> Grants -> [Space] -> SpacePermission -> Bool
hasSpacePermission who grants chain wanted = wanted `Set.member` spacePermissions who grants chain

-- | Whether someone may create a space.
canCreateSpaces :: Maybe Principal -> Grants -> Bool
canCreateSpaces who grants = hasGlobalPermission who grants CreateSpaces

-- | Whether someone may read the pages of the last space of the chain.
canView :: Maybe Principal -> Grants -> [Space] -> Bool
canView who grants chain = hasSpacePermission who grants chain View

-- | Whether someone may create, change and delete the pages of the last space
-- of the chain.
canEdit :: Maybe Principal -> Grants -> [Space] -> Bool
canEdit who grants chain = hasSpacePermission who grants chain Edit

-- | Whether someone may change the grants of the last space of the chain,
-- delete it or move it.
canAdministerSpace :: Maybe Principal -> Grants -> [Space] -> Bool
canAdministerSpace who grants chain = hasSpacePermission who grants chain AdministerSpace
