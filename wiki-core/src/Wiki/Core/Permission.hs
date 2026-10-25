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
-- Whom a public space is public to is the wiki's to say ("Wiki.Core.Access"),
-- and the rules take it with the grants ('Grants'): in an open wiki everyone,
-- in a closed one only those who have signed in, so that there someone who
-- has not sees nothing at all ('publicTo').
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
  , SpaceAccess (..)

    -- * Who is asking
  , Principal (..)
  , principal
  , isFor
  , publicTo

    -- * Rules
  , hasGlobalPermission
  , hasSpacePermission
  , spacePermissions
  , canCreateSpaces
  , canView
  , canEdit
  , canAdministerSpace

    -- * Rules for writes
    -- $writes
  , spaceChain
  , mayCreateSpace
  , mayMoveSpace
  , mayMovePage
  , keepsAdministering
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Set qualified as Set
import Protolude
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id
import Wiki.Core.Path (ancestry)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group, Membership, User, groupsOf)

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
--
-- With them, whom the wiki's public spaces are public to ('access'): not a
-- grant to anyone, but what a space's being public grants, and so where the
-- rules find it. A backend sets it from the wiki's setting wherever it
-- reads the grants, and a session carries it to the client, which so knows
-- before anyone signs in whether the wiki is closed to them.
data Grants = Grants
  { global :: [GlobalGrant]
  , spaces :: [SpaceGrant]
  , access :: Access
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Both grants, in a wiki that is closed if either says so: adding grants
-- never opens a wiki that was closed.
instance Semigroup Grants where
  a <> b = Grants {global = a.global <> b.global, spaces = a.spaces <> b.spaces, access = max a.access b.access}

-- | No grant, in an open wiki.
instance Monoid Grants where
  mempty = Grants {global = [], spaces = [], access = Open}

-- | Who may do what on a space, as whoever administers it sees it: the
-- grants on the space itself and on each of its ancestors, which it
-- inherits (each grant names the space it is on), and the users and groups
-- a grant may be given to, so that someone who administers a space but not
-- the wiki can choose among them. Global grants are not here: they are the
-- administration's.
data SpaceAccess = SpaceAccess
  { grants :: [SpaceGrant]
  -- ^ The grants on the space and its ancestors, the space's own first,
  -- then its parent's, and so on up.
  , users :: [User]
  -- ^ Every user, by login.
  , groups :: [Group]
  -- ^ Every group, by name.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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

-- | Whether a grant to this subject is a grant to this principal: it names
-- them, or one of the groups they are in. A backend uses it to pick out the
-- grants that concern the current user, which is all the client is told.
isFor :: Principal -> Subject -> Bool
isFor p = \case
  SubjectUser u -> u == p.user
  SubjectGroup g -> g `Set.member` p.groups

-- | Whether a public space is public to someone, in a wiki of this access:
-- in an open wiki to everyone, in a closed one to those who have signed in
-- only. This is the rule that decides what a reader nobody has signed in
-- as may see: the public spaces of an open wiki, and nothing of a closed
-- one, since nothing else is ever granted to them.
publicTo :: Access -> Maybe Principal -> Bool
publicTo Open _ = True
publicTo Closed who = isJust who

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
-- where only 'Administer' gives anything. A public space in the chain gives
-- 'View' to whomever it is public to ('publicTo').
spacePermissions :: Maybe Principal -> Grants -> [Space] -> Set SpacePermission
spacePermissions who grants chain
  | hasGlobalPermission who grants Administer = Set.fromList [minBound .. maxBound]
  | otherwise = Set.fromList (concatMap implied granted)
  where
    implied held = filter (spaceImplies held) [minBound .. maxBound]
    granted = publicView <> fromGrants
    publicView = [View | any (\s -> s.public) chain, publicTo grants.access who]
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

--------------------------------------------------------------------------------
-- Rules for writes

-- $writes
-- Which permissions, on which spaces, creating or moving a space takes, where
-- the rules above leave the combination open. The rest of what can be
-- written is one rule each: renaming, deleting and making a space public or
-- private, and choosing the order it lists its subspaces and pages in, is
-- 'canAdministerSpace' on it; everything done to pages and attachments is
-- 'canEdit' on their space, and so is moving a child of a space up or down
-- its list by hand (a page, or a subspace: 'canEdit' on the space whose
-- list it is, which for a subspace is its parent). The server enforces these and the
-- client hides what they forbid, so they live here rather than in either.

-- | The chain of a space, from its top-level ancestor down to the space
-- itself, among the spaces given (a backend's @listSpaces@ gives enough for
-- every space it lists). Empty when the space or one of its ancestors is not
-- among them.
spaceChain :: [Space] -> SpaceId -> [Space]
spaceChain spaces sid = fromMaybe [] (ancestry (\i -> find (\s -> s.id == i) spaces) sid)

-- | Whether someone may create a space under a parent (given by its chain),
-- or at the top level ('Nothing'). The top level takes the global
-- 'CreateSpaces'; a subspace takes that or 'AdministerSpace' on the parent,
-- which has to be one they can see.
mayCreateSpace :: Maybe Principal -> Grants -> Maybe [Space] -> Bool
mayCreateSpace who grants = \case
  Nothing -> canCreateSpaces who grants
  Just parent ->
    canView who grants parent
      && (canCreateSpaces who grants || canAdministerSpace who grants parent)

-- | Whether someone may move the space at the end of the first chain under
-- the space at the end of the second, or to the top level ('Nothing'): they
-- administer the space, and they may put a space where it goes, which is
-- 'CreateSpaces' for the top level and 'AdministerSpace' on a new parent.
mayMoveSpace :: Maybe Principal -> Grants -> [Space] -> Maybe [Space] -> Bool
mayMoveSpace who grants space destination =
  canAdministerSpace who grants space && case destination of
    Nothing -> canCreateSpaces who grants
    Just parent -> canAdministerSpace who grants parent

-- | Whether someone may move a page from the space at the end of the first
-- chain to the space at the end of the second (the same one, for a move
-- within a space): they edit both.
mayMovePage :: Maybe Principal -> Grants -> [Space] -> [Space] -> Bool
mayMovePage who grants source target = canEdit who grants source && canEdit who grants target

-- | Whether someone who may administer the space at the end of the chain
-- still would once this grant is revoked: what an administrator of a space
-- is not offered to take from themself, as the wiki's administrator is not
-- offered to give up the global 'Administer', since doing so by mistake
-- would lock them out of the very form that could undo it. Someone who
-- does not administer the space now is not kept from anything ('True').
keepsAdministering :: Maybe Principal -> Grants -> [Space] -> SpaceGrant -> Bool
keepsAdministering who grants chain revoked =
  not (canAdministerSpace who grants chain) || canAdministerSpace who without chain
  where
    without = grants {spaces = filter (/= revoked) grants.spaces}
