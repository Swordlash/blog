-- | The rules each write of 'Wiki.App.Backend.MonadWiki' is checked by,
-- where "Wiki.Core.Permission" leaves the combination open: which
-- permissions, on which spaces, creating or moving a space takes. The rest is
-- one rule of "Wiki.Core.Permission" each: renaming, deleting and making a
-- space public or private is 'canAdministerSpace' on it, and everything done
-- to pages and attachments is 'canEdit' on their space.
--
-- Like the rules they are built on, these read no store: a backend uses them
-- to decide, and the client uses them with the 'Wiki.App.Backend.Session' it
-- has to hide what the current user cannot do. Chains of spaces are as
-- 'Wiki.Core.Path.ancestry' gives them, from a top-level space down to the
-- one asked about; 'spaceChain' makes one from a list of spaces.
module Wiki.App.Backend.Rules
  ( spaceChain
  , mayCreateSpace
  , mayMoveSpace
  , mayMovePage
  )
where

import Protolude
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Path (ancestry)
import Wiki.Core.Permission (Grants, Principal, canAdministerSpace, canCreateSpaces, canEdit, canView)
import Wiki.Core.Space (Space (..))

-- | The chain of a space, from its top-level ancestor down to the space
-- itself, among the spaces given ('Wiki.App.Backend.listSpaces' gives
-- enough for every space it lists). Empty when the space or one of its
-- ancestors is not among them.
spaceChain :: [Space] -> SpaceId -> [Space]
spaceChain spaces sid = fromMaybe [] (ancestry (\i -> find (\s -> s.id == i) spaces) sid)

-- | Whether someone may create a space under a parent (given by its chain),
-- or at the top level ('Nothing'). The top level takes the global
-- 'Wiki.Core.Permission.CreateSpaces'; a subspace takes that or
-- 'Wiki.Core.Permission.AdministerSpace' on the parent, which has to be one
-- they can see.
mayCreateSpace :: Maybe Principal -> Grants -> Maybe [Space] -> Bool
mayCreateSpace who grants = \case
  Nothing -> canCreateSpaces who grants
  Just parent ->
    canView who grants parent
      && (canCreateSpaces who grants || canAdministerSpace who grants parent)

-- | Whether someone may move the space at the end of the first chain under
-- the space at the end of the second, or to the top level ('Nothing'): they
-- administer the space, and they may put a space where it goes, which is
-- 'Wiki.Core.Permission.CreateSpaces' for the top level and
-- 'Wiki.Core.Permission.AdministerSpace' on a new parent.
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
