{-# LANGUAGE QuasiQuotes #-}

-- | What the shell's views share: the context the shell hands each of them,
-- what they tell it back, the permission questions they ask of the context,
-- and a few pieces of HTML they all render.
module Wiki.App.View.Common
  ( -- * From the shell to a view, and back
    Context (..)
  , ViewOutput (..)

    -- * Permissions, as the client hides what they forbid
  , principalOf
  , grantsOf
  , chainOf
  , mayView
  , mayEdit
  , mayAdminister

    -- * Paths
  , spacePathOf
  , pagePathOf
  , findSpace
  , descendsFrom

    -- * HTML
  , errorView
  , errorMessage
  , pageTree
  , moveButtons
  , button
  , textField
  , attr
  , ariaBool
  , fileSize
  )
where

import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Numeric.Natural (Natural)
import Protolude
import Wiki.App.Backend (Session (grants), WikiError (..), sessionPrincipal)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Order (ChildOrder, Shift (..))
import Wiki.Core.Page (Page (id, slug, title), childPages)
import Wiki.Core.Path (ancestry, childrenOf, findChild, resolvePath)
import Wiki.Core.Permission (Grants, Principal, canAdministerSpace, canEdit, canView, spaceChain)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, slug))

-- | What the shell knows that every view needs: the router, who is asking,
-- and the tree of spaces ('Wiki.App.Backend.listSpaces'), with a revision
-- that the shell counts up whenever it has reloaded them because something
-- changed (a write, another user), so that a view knows to reload what it
-- holds too.
data Context = Context
  { router :: Router Route
  , session :: Session
  , spaces :: [Space]
  , revision :: Int
  }

-- | What a view tells the shell.
data ViewOutput
  = -- | The wiki has changed: reload what is shown, and go to this route if
    -- there is one (where a new, moved or renamed thing now is, or where a
    -- deleted one was).
    Changed (Maybe Route)
  | -- | The view has loaded what it shows.
    Loaded

principalOf :: Context -> Maybe Principal
principalOf ctx = sessionPrincipal ctx.session

-- | The grants that concern the current user.
grantsOf :: Context -> Grants
grantsOf ctx = ctx.session.grants

-- | A space's chain, from its top-level ancestor down, as the rules want it.
chainOf :: Context -> SpaceId -> [Space]
chainOf ctx = spaceChain ctx.spaces

mayView, mayEdit, mayAdminister :: Context -> SpaceId -> Bool
mayView ctx sid = canView (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)
mayEdit ctx sid = canEdit (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)
mayAdminister ctx sid = canAdministerSpace (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)

-- | A space's path, among the spaces given; empty if it is not there.
spacePathOf :: [Space] -> SpaceId -> [Slug]
spacePathOf spaces sid = map (\s -> s.slug) (spaceChain spaces sid)

-- | A page's path, among the pages of its space; empty if it is not there.
pagePathOf :: [Page] -> PageId -> [Slug]
pagePathOf pages pid = maybe [] (map (\p -> p.slug)) (ancestry (\i -> find (\p -> p.id == i) pages) pid)

-- | The space at a path, with its chain, if there is one.
findSpace :: [Space] -> [Slug] -> Maybe [Space]
findSpace spaces path = case resolvePath (findChild spaces) path of
  Right chain@(_ : _) -> Just chain
  _ -> Nothing

-- | Whether the space is the other one or under it.
descendsFrom :: [Space] -> SpaceId -> SpaceId -> Bool
descendsFrom spaces ancestor sid = any (\s -> s.id == ancestor) (spaceChain spaces sid)

-- | What went wrong, said in place of what could not be shown or done.
errorView :: WikiError -> HH.HTML w i
errorView e = [hh|<div class="error {{ errorClass e }}" role="alert">{{ errorMessage e }}</div>|]
  where
    errorClass :: WikiError -> Text
    errorClass = \case
      NotFound -> "error-not-found"
      Forbidden -> "error-forbidden"
      Conflict _ -> "error-conflict"
      Invalid _ -> "error-invalid"

errorMessage :: WikiError -> Text
errorMessage = \case
  NotFound -> "There is nothing here: it may have been moved or deleted."
  Forbidden -> "You do not have permission for this. Switch to someone who has, at the top right."
  Conflict why -> why
  Invalid why -> why

-- | The pages of a space as a tree of links, in the space's page order, the
-- current page marked, and after each link what the function gives for the
-- page, told whether it is the first and the last of its siblings (the
-- space's view puts buttons there that move it).
pageTree
  :: Router Route
  -> (Follow Route -> action)
  -> [Slug]
  -> ChildOrder
  -> [Page]
  -> Maybe PageId
  -> (Page -> Bool -> Bool -> [HH.HTML w action])
  -> HH.HTML w action
pageTree router onFollow spacePath order pages current controls = level Nothing
  where
    level parent =
      let siblings = childPages order pages parent
          count = length siblings
       in [hh|
            <ul class="page-tree">
              {% for (n, p) in zip [1 :: Int ..] siblings %}{% let here = Just p.id == current %}
                <li class="page-node{% if here %} current{% end %}">{{ pageLink p here }}{{ controls p (n == 1) (n == count) }}{{ below p }}</li>
              {% end %}
            </ul>
          |]
    pageLink p here = Router.link router onFollow (Page spacePath (pagePathOf pages p.id)) [attr "aria-current" "page" | here] [HH.text p.title]
    below p = [level (Just p.id) | not (null (childrenOf pages (Just p.id)))]

-- | Buttons that move a child of a space by hand: to the top, up, down, to
-- the bottom, told whether it is the first and the last of its siblings
-- (where moving further that way does nothing, so the buttons are
-- disabled). Each says what it moves, for a screen reader.
moveButtons :: Text -> Bool -> Bool -> (Shift -> i) -> HH.HTML w i
moveButtons name atTop atBottom onShift =
  [hh|
    <span class="move-controls" role="group" aria-label={{ "Move " <> name }}>{{ move ShiftToTop atTop "move-top" "⤒" "to the top" }}{{ move ShiftUp atTop "move-up" "↑" "up" }}{{ move ShiftDown atBottom "move-down" "↓" "down" }}{{ move ShiftToBottom atBottom "move-bottom" "⤓" "to the bottom" }}</span>
  |]
  where
    move how atEnd cls arrow saying =
      [hh|<button type="button" class="move {{ cls }}" disabled={{ atEnd }} title={{ "Move " <> saying }} aria-label={{ "Move " <> name <> " " <> saying }} onClick={{ const (onShift how) }}>{{ arrow :: Text }}</button>|]

-- | A button that does one thing.
button :: Text -> i -> HH.HTML w i
button label action = [hh|<button type="button" onClick={{ const action }}>{{ label }}</button>|]

-- | A labelled text field, its value kept by the component.
textField :: Text -> Text -> (Text -> i) -> HH.HTML w i
textField label value onInput =
  [hh|
    <label class="field">
      <span>{{ label }}</span>
      <input type="text" value={{ value }} onValueInput={{ onInput }} required autofocus>
    </label>
  |]

-- | An attribute Halogen has no property for (@role@, @aria-*@).
attr :: Text -> Text -> HH.IProp r i
attr name = HP.attr (HH.AttrName name)

-- | A boolean ARIA state (@aria-expanded@, @aria-pressed@), as ARIA writes it.
ariaBool :: Bool -> Text
ariaBool b = if b then "true" else "false"

-- | A size in bytes, as people read it.
fileSize :: Natural -> Text
fileSize n
  | n < 1024 = show n <> " bytes"
  | n < 1024 * 1024 = show (n `div` 1024) <> " KB"
  | otherwise = show (n `div` (1024 * 1024)) <> " MB"
