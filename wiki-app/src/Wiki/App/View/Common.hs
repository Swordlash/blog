{-# LANGUAGE QuasiQuotes #-}

-- | What the shell's views share: the 'Context' the shell gives each of
-- them, the 'ViewOutput' they send back, the permission checks they run on
-- the context, and a few pieces of HTML they all render.
module Wiki.App.View.Common
  ( -- * From the shell to a view, and back
    Context (..)
  , PageWidth (..)
  , ViewOutput (..)
  , ViewQuery (..)

    -- * Permissions, as the client hides what they forbid
  , principalOf
  , grantsOf
  , chainOf
  , mayView
  , mayEdit
  , mayEditPage
  , mayAdminister
  , notified
  , homeSpace
  , wikiMacrosOf
  , documentRoute

    -- * Paths
  , spacePathOf
  , pagePathOf
  , pageRouteOf
  , findSpace
  , descendsFrom

    -- * HTML
  , errorView
  , failureView
  , staleNotice
  , errorMessage
  , pageTree
  , spaceIcon
  , ownSpace
  , openPersonalSpaces
  , AvatarSize (..)
  , avatar
  , avatarOf
  , avatarUrls
  , homeOf
  , moveButtons
  , button
  , textField
  , attr
  , ariaBool
  , fileSize

    -- * Words
  , whoIs
  , dateOf
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Type.Equality (type (~))
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Numeric.Natural (Natural)
import Protolude
import Wiki.App.Backend (MonadWiki (avatarUrl), Session (grants, homePage, mathMacros, standing, user), WikiError (..), sessionPrincipal)
import Wiki.App.Route (Route (..), pageRoute)
import Wiki.Core.HomePage (HomePage (showAnonymous))
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Id (PageId, SpaceId, UserId)
import Wiki.Core.Math (Macros (..), wikiMacros)
import Wiki.Core.Order (Shift (..))
import Wiki.Core.Page (Page, PageSummary (id, title), childPages)
import Wiki.Core.Path (TreeNode (..), childrenOf, findChild, resolvePath)
import Wiki.Core.Permission (GlobalPermission (Administer), Grants, Principal, canAdministerSpace, canEdit, canEditPage, canView, hasGlobalPermission, spaceChain)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Icon (..), Space (active, homePage, icon, id, name, owner, pageOrder, personalContainer, slug), colourFor, colourOf, iconLetter, isPersonal, pagePath, rootPage)
import Wiki.Core.User (Avatar, Standing (..), User (id))
import Wiki.Core.Version (Author (..))

-- | 'Context': what the shell knows that every view needs. That is the
-- router, who is asking, and the tree of spaces
-- ('Wiki.App.Backend.listSpaces'), with the URLs of the spaces' icon images
-- ('Wiki.App.Backend.spaceIconUrl'). It also has a revision, which the
-- shell increments whenever it has reloaded them because something changed
-- (a write, another user), so that a view knows to reload its own data
-- too.
data Context = Context
  { router :: Router Route
  , session :: Session
  , spaces :: [Space]
  , icons :: Map SpaceId Text
  , revision :: Int
  , pageWidth :: PageWidth
  -- ^ How wide the page view lays a page out, as this browser chose it.
  }

-- | 'PageWidth' is how wide the page view lays a page out on a wide screen
-- (WP5.55 of docs/PLAN.md), as the reader chose it with the switch in the
-- page's bar of actions: 'Compact', the text at a reading width in the
-- middle, or 'FullWidth', the text as wide as the window lets it. The
-- shell keeps the choice in the browser's local storage, for every page.
data PageWidth = Compact | FullWidth
  deriving stock (Eq, Show)

-- | What a view sends back to the shell.
data ViewOutput
  = -- | The wiki has changed: reload what is shown, and navigate to this
    -- route if there is one (where a new, moved or renamed thing now is, or
    -- where a deleted one was).
    Changed (Maybe Route)
  | -- | The view has loaded what it shows.
    Loaded
  | -- | The view shows this page, body and all: the shell describes the
    -- page in the document's head with it (a link preview), since the
    -- space's list of pages has no bodies.
    Showing Page
  | -- | The view pushed an entry of the session history for the route
    -- shown (the editor's "Show preview"): the shell numbers it as the
    -- route's entry, the one to return to after staying ('historyEntry').
    Entered
  | -- | The reader chose how wide pages are laid out: the shell keeps it.
    ChoseWidth PageWidth

-- | What the shell asks a view. A view that does not answer is taken to
-- have nothing to say.
data ViewQuery a
  = -- | Whether leaving the view would lose changes the reader has not
    -- saved, which the shell then asks about before it follows a route
    -- away: the page view's unsaved ticks ("Wiki.App.View.Page").
    HasUnsaved (Bool -> a)

-- | The wiki's built-in math macros as the administration keeps them, as
-- the first block of a formula's macros, marked so that the islands read
-- them in place of the ones the wiki ships with ("Wiki.Core.Math"); none
-- while the administration keeps none, and the shipped ones hold.
wikiMacrosOf :: Session -> Macros
wikiMacrosOf s = Macros (maybe [] (pure . wikiMacros) s.mathMacros)

principalOf :: Context -> Maybe Principal
principalOf ctx = sessionPrincipal ctx.session

-- | The grants that apply to the current user.
grantsOf :: Context -> Grants
grantsOf ctx = ctx.session.grants

-- | A space's chain, from its top-level ancestor down, in the form the
-- permission rules take.
chainOf :: Context -> SpaceId -> [Space]
chainOf ctx = spaceChain ctx.spaces

mayView, mayEdit, mayAdminister :: Context -> SpaceId -> Bool
mayView ctx sid | homeSpace ctx sid, ctx.session.homePage.showAnonymous = True
mayView ctx sid = canView (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)
mayEdit ctx sid | homeSpace ctx sid = hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer
mayEdit ctx sid = canEdit (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)
mayAdminister ctx sid = canAdministerSpace (principalOf ctx) (grantsOf ctx) (chainOf ctx sid)

-- | Whether the user may change this page of the space: save it, rename
-- it, restore a version, keep a draft, attach files. That is 'mayEdit',
-- except for the space's home page, which only the space's administrators
-- change ('canEditPage'). The wiki's front page keeps its own rule, a
-- wiki administrator.
mayEditPage :: Context -> SpaceId -> PageId -> Bool
mayEditPage ctx sid _ | homeSpace ctx sid = mayEdit ctx sid
mayEditPage ctx sid pid = canEditPage (principalOf ctx) (grantsOf ctx) (chainOf ctx sid) pid

-- | Whether this is the real backing space of the wiki root.
homeSpace :: Context -> SpaceId -> Bool
homeSpace ctx = Home.isHomeSpace ctx.session.homePage

-- | Keep ordinary page features at the root's canonical addresses.
documentRoute :: Context -> SpaceId -> Route -> Route
documentRoute ctx sid r | not (homeSpace ctx sid) = r
documentRoute _ _ r = case r of
  Space {} -> Home
  Page {} -> Home
  EditPage {} -> EditHome
  PageSource {} -> HomeSource
  PageHistory _ _ v a -> HomeHistory v a
  PageSlides _ _ n k -> HomeSlides n k
  _ -> r

-- | Whether the reader gets notifications (WP4.13 of docs/PLAN.md): only a
-- signed-in user of the wiki. The server's operator is not a user, so not.
notified :: Context -> Bool
notified ctx = isJust ctx.session.user && ctx.session.standing /= Operator

-- | A space's path, among the spaces given; empty if it is not there.
spacePathOf :: [Space] -> SpaceId -> [Slug]
spacePathOf spaces sid = map (\s -> s.slug) (spaceChain spaces sid)

-- | A page's path, among the pages of its space (their summaries, or the
-- pages themselves): 'Wiki.Core.Space.pagePath', from under the space's
-- home page, whose own path is empty. 'Nothing' if it is not there.
pagePathOf :: (TreeNode page, NodeId page ~ PageId) => Space -> [page] -> PageId -> Maybe [Slug]
pagePathOf space pages = pagePath space (\i -> find (\p -> nodeId p == i) pages)

-- | The route of a page of a space, among its pages ('pagePathOf',
-- 'Wiki.App.Route.pageRoute'): the space's own route for its home page.
-- 'Unknown' for a page that is not among them.
pageRouteOf :: (TreeNode page, NodeId page ~ PageId) => [Space] -> Space -> [page] -> PageId -> Route
pageRouteOf spaces space pages pid = maybe Unknown (pageRoute (spacePathOf spaces space.id)) (pagePathOf space pages pid)

-- | The space at a path, with its chain, if there is one.
findSpace :: [Space] -> [Slug] -> Maybe [Space]
findSpace spaces path = case resolvePath (findChild spaces) path of
  Right chain@(_ : _) -> Just chain
  _ -> Nothing

-- | Whether the first space is the second one or under it.
descendsFrom :: [Space] -> SpaceId -> SpaceId -> Bool
descendsFrom spaces ancestor sid = any (\s -> s.id == ancestor) (spaceChain spaces sid)

-- | The error, shown in place of what could not be shown or done.
errorView :: WikiError -> HH.HTML w i
errorView e = [hh|<div class="error {{ errorClass e }}" role="alert">{{ errorMessage e }}</div>|]
  where
    errorClass :: WikiError -> Text
    errorClass = \case
      NotFound -> "error-not-found"
      Forbidden -> "error-forbidden"
      Conflict _ -> "error-conflict"
      Invalid _ -> "error-invalid"
      Unreachable _ -> "error-unreachable"

-- | What could not be loaded, and why: 'errorView', with a "Try again"
-- button when the backend could not be reached, which is the one error a
-- retry may fix.
failureView :: WikiError -> i -> HH.HTML w i
failureView e again = case e of
  Unreachable _ ->
    [hh|
      <div class="error error-unreachable" role="alert">
        {{ errorMessage e }}
        <button type="button" class="retry" onClick={{ const again }}>Try again</button>
      </div>
    |]
  _ -> errorView e

-- | The line above content kept on screen after its reload failed,
-- because it holds changes not saved (an editor's text, a page's ticks):
-- what failed, that the content stays, and a button to try again. A view
-- that mounts the page view or the editor shows it rather than replace
-- the content with 'failureView', which would unmount it and lose them.
staleNotice :: WikiError -> i -> HH.HTML w i
staleNotice e again =
  [hh|
    <div class="error stale-reload" role="alert">
      <p>{{ "The wiki could not be loaded again: " <> errorMessage e <> " What is shown stays, with the changes you have not saved." :: Text }}</p>
      <button type="button" class="retry" onClick={{ const again }}>Try again</button>
    </div>
  |]

errorMessage :: WikiError -> Text
errorMessage = \case
  NotFound -> "There is nothing here: it may have been moved or deleted."
  Forbidden -> "You do not have permission for this. Switch to someone who has, at the top right."
  Conflict why -> why
  Invalid why -> why
  Unreachable why -> "The wiki's server could not be reached (" <> why <> "). Check the connection, and try again."

-- | The pages of a space as a tree of links, in the space's page order,
-- with the current page marked. After each link comes what the function
-- returns for the page, given whether it is the first and the last of its
-- siblings (the space's view puts buttons there that move it). The tree
-- starts under the space's home page, the root of its pages
-- ('Wiki.Core.Space.rootPage'), which the space's own link stands for; in
-- a space with no home page it starts at the top level.
pageTree
  :: Router Route
  -> (Follow Route -> action)
  -> [Slug]
  -> Space
  -> [PageSummary]
  -> Maybe PageId
  -> (PageSummary -> Bool -> Bool -> [HH.HTML w action])
  -> HH.HTML w action
pageTree router onFollow spacePath space pages current controls = level (rootPage space)
  where
    order = space.pageOrder
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
    pageLink p here = Router.link router onFollow (maybe Unknown (pageRoute spacePath) (pagePathOf space pages p.id)) [attr "aria-current" "page" | here] [HH.text p.title]
    below p = [level (Just p.id) | not (null (childrenOf pages (Just p.id)))]

-- | A space's icon beside its name ('Wiki.Core.Space.Icon'): its emoji,
-- its image (from the URL the context gives), or the first letter of its
-- name on its colour. The container "User subspaces" has no icon of its
-- own, since nobody may change its settings, and shows a person (👤)
-- rather than its letter. Decoration only: the name is always beside it, so
-- a screen reader does not read it twice.
spaceIcon :: Map SpaceId Text -> Space -> HH.HTML w i
spaceIcon urls s = case s.icon of
  Just (IconEmoji e) -> emoji e
  Just (IconImage _ _)
    | Just url <- Map.lookup s.id urls
    , not (T.null url) ->
        [hh|<img class="space-icon space-icon-image" src={{ url }} alt="" aria-hidden="true">|]
  _
    | s.personalContainer -> emoji "\x1F464"
    | otherwise -> [hh|<span class="space-icon space-icon-{{ colourOf s }}" aria-hidden="true">{{ iconLetter s.name }}</span>|]
  where
    emoji :: Text -> HH.HTML w i
    emoji e = [hh|<span class="space-icon space-icon-emoji" aria-hidden="true">{{ e }}</span>|]

-- | The signed-in user's personal space, if it is turned on and listed.
ownSpace :: Context -> Maybe Space
ownSpace ctx = do
  u <- ctx.session.user
  find (\s -> s.owner == Just u.id && s.active) ctx.spaces

-- | The personal spaces the reader may open, their own among them, in the
-- order of the listed spaces. The container "User subspaces" leads
-- somewhere only while there is one: the reader's own, turned on, or
-- another user's that is public or shared with them.
openPersonalSpaces :: Context -> [Space]
openPersonalSpaces ctx = filter (\s -> isPersonal s && s.active && mayView ctx s.id) ctx.spaces

-- | How big a user's avatar is drawn: 'SmallAvatar' beside a name in a
-- line of text (the header, a comment, a byline, the readers of a page),
-- 'LargeAvatar' in the account panel.
data AvatarSize = SmallAvatar | LargeAvatar

-- | A user's avatar, round (WP5.55 of docs/PLAN.md): their picture, from
-- its URL, with their name as its text; or, for a user without one, a
-- circle with the first letter of their name, as a space's coloured icon
-- shows its name's ('Wiki.Core.Space.iconLetter'), on a colour picked from
-- the name ('Wiki.Core.Space.colourFor'), so that the same user always has
-- the same colour. Every place that shows a user's
-- avatar draws it with this.
avatar :: AvatarSize -> Maybe Text -> Text -> HH.HTML w i
avatar size url name = case mfilter (not . T.null) url of
  Just u -> [hh|<img class="avatar {{ sizeClass }}" src={{ u }} alt={{ name }}>|]
  -- The letter is drawn by the stylesheet from an attribute, so that the
  -- element holds no text: the text of whatever it is in (a name beside it,
  -- a comment's line) stays what it was.
  Nothing -> [hh|<span class="avatar {{ sizeClass }} avatar-initials avatar-{{ colourFor name }}" role="img" aria-label={{ name }} data-initials={{ iconLetter name }}></span>|]
  where
    sizeClass = case size of
      SmallAvatar -> "avatar-small" :: Text
      LargeAvatar -> "avatar-large"

-- | An author's avatar, from the URLs a view has ('avatarUrls').
avatarOf :: AvatarSize -> Map UserId Text -> Author -> HH.HTML w i
avatarOf size urls a = avatar size (Map.lookup a.id urls) a.name

-- | The URLs of the avatars of these people, by user, for the ones who
-- have one: what a view keeps to draw them ('avatarOf'). On the HTTP
-- backend the URL is made without a request, so a view can ask for them
-- in its initial state ('Wiki.App.Backend.atOnce').
avatarUrls :: (MonadWiki m) => [(UserId, Maybe Avatar)] -> m (Map UserId Text)
avatarUrls people = Map.fromList <$> traverse (\(u, a) -> (u,) <$> avatarUrl u a) [(u, a) | (u, Just a) <- people]

-- | The page a space opens at, if it has one among its pages.
homeOf :: Space -> [PageSummary] -> Maybe PageSummary
homeOf s pages = s.homePage >>= \h -> find (\p -> p.id == h) pages

-- | Buttons that move a child of a space by hand: to the top, up, down, to
-- the bottom. Given whether it is the first and the last of its siblings,
-- the buttons that would do nothing are disabled. Each names what it
-- moves, for a screen reader.
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

-- | A labelled text field, whose value the component keeps.
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

-- | A size in bytes, in the units people read.
fileSize :: Natural -> Text
fileSize n
  | n < 1024 = show n <> " bytes"
  | n < 1024 * 1024 = show (n `div` 1024) <> " KB"
  | otherwise = show (n `div` (1024 * 1024)) <> " MB"

-- | Some people named as the subject of a sentence, with its verb: "Ada
-- is", "Ada and Grace are", "Ada, Grace and Rita are". The reader (by
-- their id) is "you (in another tab)", since the live channel never
-- reports a tab to itself ("Wiki.Api.Events"): it must be the reader
-- editing elsewhere. Nobody gives "Nobody is".
whoIs :: Maybe UserId -> [Author] -> Text
whoIs me = \case
  [] -> "Nobody is"
  [a] | isMe a -> "You (in another tab) are"
  [a] -> a.name <> " is"
  people -> capitalised (listed (map nameOf people)) <> " are"
  where
    isMe a = Just a.id == me
    nameOf a = if isMe a then "you (in another tab)" else a.name
    listed names = case reverse names of
      final : others@(_ : _) -> T.intercalate ", " (reverse others) <> " and " <> final
      _ -> T.concat names
    capitalised t = T.toUpper (T.take 1 t) <> T.drop 1 t

-- | A day as people read it: @1 October 2026@.
dateOf :: UTCTime -> Text
dateOf = toS . formatTime defaultTimeLocale "%-d %B %Y"
