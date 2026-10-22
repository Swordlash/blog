{-# LANGUAGE QuasiQuotes #-}

-- | The application's frame, around whatever the route shows: a header with
-- the site's name, breadcrumbs, the search box ("Wiki.App.View.Search") and
-- the demo's user switcher; a sidebar with the tree of spaces, the current space's
-- pages under it; and the content of the route.
--
-- The shell holds what every view needs and loads it itself: who is signed
-- in, the tree of spaces, and the space the route is in with its pages
-- (through 'getSpace' and 'listPages', so that a space the user may not see
-- is refused in place). The views are child components ("Wiki.App.View.*"):
-- a space, a page, the form for a new space. They are handed that context,
-- and they tell the shell when they have changed the wiki ('Changed'), which
-- it then reloads, counting up the context's revision so that they reload
-- what they hold as well, and goes where the change leads.
--
-- The route is the router's ('Router.current' at the start, then
-- 'Router.changes'), so links, the back and forward buttons and a reload all
-- arrive at the same place.
--
-- The one route the shell does not simply follow is one away from an editor
-- with unsaved changes: it asks the editor ('Editor.IsDirty') and, if the
-- draft would be lost, asks the reader in place whether to leave. By then
-- the browser's address is the new route's already (a link was followed, or
-- the back button pressed), so staying goes back to the editor's entry of
-- the session history, by as many entries as lie between ('historyEntry'
-- numbers them), as the browser's buttons would.
module Wiki.App.Shell
  ( Input (..)
  , Query (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.+), type (.==))
import Data.Set qualified as Set
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), anonymous)
import Wiki.App.Browser (historyEntry, historyGo, setDocumentTitle)
import Wiki.App.DemoUsers (MonadDemoUsers (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.App.View.Editor qualified as Editor
import Wiki.App.View.NewSpace qualified as NewSpaceView
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.Search qualified as SearchBox
import Wiki.App.View.SearchResults qualified as SearchResultsView
import Wiki.App.View.Space qualified as SpaceView
import Wiki.Core.Id (SpaceId, UserId)
import Wiki.Core.Page (Page (id, title))
import Wiki.Core.Path (PathError (..), childrenOf, findChild, resolvePath)
import Wiki.Core.Permission (mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name, public, slug))
import Wiki.Core.User (User (..))

-- | The router, and a route the home page invites a newcomer to (the
-- demo's tour), if there is one.
data Input = Input
  { router :: Router Route
  , welcome :: Maybe Route
  }

-- | Whether the shell has loaded everything the route shows; when it has,
-- the document's title for it. The prerender waits for this before it
-- takes the page's HTML.
data Query a = Settled (Maybe Text -> a)

type Slots =
  ("space" .== H.Slot (Const Void) ViewOutput ())
    .+ ("page" .== H.Slot (Const Void) ViewOutput ())
    .+ ("newSpace" .== H.Slot (Const Void) ViewOutput ())
    .+ ("editor" .== H.Slot Editor.Query ViewOutput Editor.Target)
    .+ ("searchBox" .== H.Slot (Const Void) Void ())
    .+ ("searchResults" .== H.Slot (Const Void) ViewOutput ())

-- | The space the route is in, as far as it has been loaded.
data Here
  = NoSpace
  | LoadingSpace [Slug]
  | SpaceFailed [Slug] WikiError
  | InSpace [Slug] Space [Page]

data State = State
  { router :: Router Route
  , welcome :: Maybe Route
  , route :: Route
  , session :: Session
  , users :: [User]
  , spaces :: [Space]
  , here :: Here
  , collapsed :: Set SpaceId
  , generation :: Int
  -- ^ The views' 'revision': how many times the wiki has been reloaded
  -- after a change.
  , menuOpen :: Bool
  , settled :: Bool
  , leaving :: Maybe Route
  -- ^ A route followed away from an editor with unsaved changes, which the
  -- reader is being asked about.
  , entry :: Int
  -- ^ The number of the session history's entry for the route shown
  -- ('historyEntry'), which staying in the editor goes back to.
  }

data Action
  = Initialize
  | Arrived Route
  | Followed (Follow Route)
  | Toggle SpaceId
  | ToggleMenu
  | SwitchTo (Maybe UserId)
  | FromView ViewOutput
  | Leave
  | Stay

component
  :: forall output m
   . (MonadWiki m, MonadDemoUsers m, MonadIslands m, MonadUUID m, MonadIO m)
  => H.Component Query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \Input {router, welcome} -> do
          route <- Router.current router
          pure
            State
              { router
              , welcome
              , route
              , session = anonymous
              , users = []
              , spaces = []
              , here = NoSpace
              , collapsed = mempty
              , generation = 0
              , menuOpen = False
              , settled = False
              , leaving = Nothing
              , entry = 0
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.initialize = Just Initialize
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <div class="wiki">
          {{ header st }}
          <div class="wiki-body">
            {{ sidebar st }}
            <main class="wiki-content">{% if isJust st.leaving %}{{ leaveConfirm }}{% end %}{{ content st }}</main>
          </div>
        </div>
      |]

    header :: State -> H.ComponentHTML Action Slots m
    header st =
      [hh|
        <header class="wiki-header">{{ brand }}{{ breadcrumbs st }}{{ searchBox }}{{ userSwitcher st }}</header>
      |]
      where
        brand = Router.link st.router Followed Home [HP.class_ "wiki-brand"] [HH.text "Wiki"]
        searchBox = HH.slot_ "searchBox" () SearchBox.component SearchBox.Input {context = context st}

    breadcrumbs :: State -> H.ComponentHTML Action Slots m
    breadcrumbs st =
      [hh|
        <nav class="breadcrumbs" aria-label="Breadcrumbs">
          <ol>
            {% for (label, target, final) in marked (crumbs st) %}
              <li>{{ crumb label target final }}</li>
            {% end %}
          </ol>
        </nav>
      |]
      where
        -- Each crumb, and whether it is the last one: the route itself,
        -- which is not a link.
        marked cs = zipWith (\n (label, target) -> (label, target, n == length cs)) [1 :: Int ..] cs
        -- The last crumb names the route shown; one on the way is a link,
        -- unless the user may not go there.
        crumb label target final = case target of
          _ | final -> [hh|<span aria-current="page">{{ label }}</span>|]
          Just r -> Router.link st.router Followed r [] [HH.text label]
          Nothing -> [hh|<span class="unviewable">{{ label }}</span>|]

    -- The demo's menu of who one is: nobody, or one of its users.
    userSwitcher :: State -> H.ComponentHTML Action Slots m
    userSwitcher st =
      [hh|
        <div class="user-switcher">
          <button type="button" class="user-switcher-toggle" aria-expanded={{ ariaBool st.menuOpen }} onClick={{ const ToggleMenu }}>
            {{ maybe "Not signed in" (\u -> u.displayName) st.session.user }}
          </button>
          {% if st.menuOpen %}
            <ul class="user-menu">
              {% for candidate in Nothing : map Just st.users %}
                <li>
                  <button
                    type="button"
                    class="user-option"
                    data-login={{ maybe "" (\u -> u.login) candidate }}
                    aria-pressed={{ ariaBool (((\u -> u.id) <$> candidate) == ((\u -> u.id) <$> st.session.user)) }}
                    onClick={{ const (SwitchTo ((\u -> u.id) <$> candidate)) }}
                  >
                    {{ maybe "Nobody (not signed in)" (\u -> u.displayName <> " (" <> u.login <> ")") candidate }}
                  </button>
                </li>
              {% end %}
            </ul>
          {% end %}
        </div>
      |]

    sidebar :: State -> H.ComponentHTML Action Slots m
    sidebar st =
      [hh|
        <nav class="wiki-sidebar" aria-label="Spaces">
          <h2>Spaces</h2>
          {{ spaceLevel st Nothing }}{{ newSpace st "new-space-link" }}
        </nav>
      |]

    -- A link to a new space at the top level, for someone who may make one.
    newSpace :: State -> Text -> Maybe (H.ComponentHTML Action Slots m)
    newSpace st cls =
      guard (mayCreateSpace (principalOf (context st)) st.session.grants Nothing)
        $> Router.link st.router Followed (NewSpace Nothing) [HP.class_ (HH.ClassName cls)] [HH.text "New space"]

    spaceLevel :: State -> Maybe SpaceId -> H.ComponentHTML Action Slots m
    spaceLevel st parent = [hh|<ul class="space-tree">{{ map (spaceNode st) (childrenOf st.spaces parent) }}</ul>|]

    spaceNode :: State -> Space -> H.ComponentHTML Action Slots m
    spaceNode st s =
      [hh|
        <li class="space-node{% if current %} current{% end %}">
          <div class="space-row">{% if hasChildren %}{{ toggle }}{% end %}{{ spaceLabel }}</div>
          {{ pagesHere }}{% if hasChildren && open %}{{ spaceLevel st (Just s.id) }}{% end %}
        </li>
      |]
      where
        toggle =
          [hh|
            <button
              type="button"
              class="tree-toggle"
              aria-expanded={{ ariaBool open }}
              aria-label={{ (if open then "Collapse " else "Expand ") <> s.name }}
              onClick={{ const (Toggle s.id) }}
            >
              {{ if open then "▾" else "▸" :: Text }}
            </button>
          |]
        ctx = context st
        path = spacePathOf st.spaces s.id
        hasChildren = not (null (childrenOf st.spaces (Just s.id)))
        open = not (s.id `Set.member` st.collapsed)
        current = case st.here of
          InSpace _ here _ -> here.id == s.id
          _ -> False
        spaceLabel
          | mayView ctx s.id =
              Router.link st.router Followed (Space path) ([HP.class_ "space-link"] <> [attr "aria-current" "page" | current && isSpaceRoute st.route]) [HH.text s.name]
          | otherwise =
              [hh|<span class="unviewable" title="You do not have permission to see this space">{{ s.name }}</span>|]
        pagesHere = case st.here of
          InSpace _ here pages | here.id == s.id, not (null pages) -> Just (pageTree st.router Followed path pages ((\p -> p.id) <$> currentPage st))
          _ -> Nothing

    content :: State -> H.ComponentHTML Action Slots m
    content st = case st.route of
      Home -> home st
      Unknown -> notFound st
      NewSpace parent -> HH.slot "newSpace" () NewSpaceView.component NewSpaceView.Input {context = context st, parent} FromView
      Search text space subspaces ->
        HH.slot "searchResults" () SearchResultsView.component SearchResultsView.Input {context = context st, text, space, subspaces} FromView
      _ -> case st.here of
        NoSpace -> notFound st
        LoadingSpace _ -> [hh|<p class="loading">Loading…</p>|]
        SpaceFailed _ e -> errorView e
        InSpace _ space pages -> case st.route of
          Page _ path -> HH.slot "page" () PageView.component PageView.Input {context = context st, space, pages, path} FromView
          EditPage _ path -> editor (Editor.Existing path)
          NewPage _ parent -> editor (Editor.New parent)
          _ -> HH.slot "space" () SpaceView.component SpaceView.Input {context = context st, space, pages} FromView
          where
            -- One editor per page edited: another page's is a component
            -- of its own, with a draft of its own.
            editor target = HH.slot "editor" target Editor.component Editor.Input {context = context st, space, pages, target} FromView

    -- Asked when a route is followed away from unsaved changes ('leaving').
    leaveConfirm :: H.ComponentHTML Action Slots m
    leaveConfirm =
      [hh|
        <div class="confirm leave-confirm" role="alertdialog">
          <p>This page has changes that are not saved. Leave the editor and lose them?</p>
          <button type="button" class="danger" onClick={{ const Leave }}>Leave</button>
          <button type="button" onClick={{ const Stay }}>Stay</button>
        </div>
      |]

    home :: State -> H.ComponentHTML Action Slots m
    home st =
      [hh|
        <section class="home">
          <h1>Welcome to the wiki</h1>
          <p>
            Spaces hold pages written in Markdown, and spaces can hold other spaces. Who may
            read, edit or administer a space is up to its permissions; a public space is open to
            everyone.
          </p>
          {% for r in maybeToList st.welcome %}
            <p class="welcome">New here? {{ Router.link st.router Followed r [] [HH.text "Take the tour"] }}.</p>
          {% end %}
          <h2>Spaces</h2>
          {{ spaceList }}{{ newSpace st "button" }}
        </section>
      |]
      where
        spaceList = case childrenOf st.spaces Nothing of
          [] -> [hh|<p class="empty">There are no spaces you can see.</p>|]
          roots -> [hh|<ul class="space-list">{{ map (rootSpace st) roots }}</ul>|]

    rootSpace :: State -> Space -> H.ComponentHTML Action Slots m
    rootSpace st s
      | mayView (context st) s.id =
          [hh|
            <li>
              {{ Router.link st.router Followed (Space [s.slug]) [] [HH.text s.name] }}
              <span class="badge {{ if s.public then "badge-public" else "badge-private" :: Text }}">{{ if s.public then "Public" else "Private" :: Text }}</span>
            </li>
          |]
      | otherwise =
          [hh|<li><span class="unviewable" title="You can see only a subspace of this space">{{ s.name }}</span></li>|]

    notFound :: State -> H.ComponentHTML Action Slots m
    notFound st =
      [hh|
        <section class="not-found">
          <h1>Not found</h1>
          <p>There is nothing at this address.</p>
          {{ Router.link st.router Followed Home [HP.class_ "button"] [HH.text "Go to the front page"] }}
        </section>
      |]

    handleAction :: Action -> H.HalogenM State Action Slots output m ()
    handleAction = \case
      Initialize -> do
        router <- gets (\st -> st.router)
        void $ H.subscribe (Arrived <$> Router.changes router)
        entry <- H.liftEffect historyEntry
        modify (\st -> st {entry})
        loadWorld
        loadHere True
      Arrived r -> do
        now <- H.liftEffect historyEntry
        before <- gets (\st -> st.route)
        if r == before
          then -- The route shown, at an entry of its own: one the shell
          -- pushed itself after a change ('reload'), or the editor's gone
          -- back to after staying.
            modify (\st -> st {entry = now})
          else do
            dirty <- or <$> H.queryAll "editor" (Editor.IsDirty identity)
            if dirty
              then modify (\st -> st {leaving = Just r, menuOpen = False})
              else arrive r now
      Leave -> do
        now <- H.liftEffect historyEntry
        gets (\st -> st.leaving) >>= traverse_ (`arrive` now)
      Stay -> do
        st <- get
        modify (\s -> s {leaving = Nothing})
        -- The address is the one not followed. Going back to the editor's
        -- entry leaves the history as the browser's buttons would, with
        -- the route not followed ahead, where it was; the router announces
        -- the route already shown. Without a number for that entry (there
        -- is none natively) the editor's address replaces the other.
        now <- H.liftEffect historyEntry
        if st.entry /= now
          then H.liftEffect (historyGo (st.entry - now))
          else Router.redirect st.router st.route
      Followed f -> gets (\st -> st.router) >>= (`Router.follow` f)
      Toggle sid -> modify $ \st ->
        st {collapsed = if sid `Set.member` st.collapsed then Set.delete sid st.collapsed else Set.insert sid st.collapsed}
      ToggleMenu -> modify (\st -> st {menuOpen = not st.menuOpen})
      SwitchTo user -> do
        modify (\st -> st {menuOpen = False, settled = False})
        switchTo user
        reload Nothing
      FromView (Changed next) -> reload next
      FromView Loaded -> settle

    arrive :: Route -> Int -> H.HalogenM State Action Slots output m ()
    arrive r entry = do
      modify (\st -> st {route = r, settled = False, menuOpen = False, leaving = Nothing, entry})
      loadHere False

    -- After a change: everything again, and every view's own data too.
    reload :: Maybe Route -> H.HalogenM State Action Slots output m ()
    reload next = do
      loadWorld
      modify (\st -> st {generation = st.generation + 1})
      for_ next $ \r -> modify (\st -> st {route = r, settled = False, leaving = Nothing})
      loadHere True
      -- The router is told last, so that the route it announces is the one
      -- already shown, which 'Arrived' leaves alone.
      router <- gets (\st -> st.router)
      for_ next (Router.navigate router)

    loadWorld :: H.HalogenM State Action Slots output m ()
    loadWorld = do
      s <- session
      us <- listUsers
      ss <- listSpaces
      modify (\st -> st {session = s, users = us, spaces = ss})

    -- The space the route is in, unless it is the one loaded already
    -- (or even so, if forced).
    loadHere :: Bool -> H.HalogenM State Action Slots output m ()
    loadHere again = do
      st <- get
      case spaceOfRoute st.route of
        Nothing -> modify (\s -> s {here = NoSpace})
        Just path
          | not again, hereIs path st.here -> pass
          | otherwise -> do
              -- Reloading the space being shown keeps it on screen meanwhile.
              unless (hereIs path st.here) $ modify (\s -> s {here = LoadingSpace path})
              result <- runExceptT $ do
                space <- ExceptT (getSpace path)
                pages <- ExceptT (listPages space.id)
                pure (InSpace path space pages)
              -- Unless the route has moved on to another space meanwhile.
              now <- gets (\s -> s.route)
              when (spaceOfRoute now == Just path) $
                modify (\s -> s {here = either (SpaceFailed path) identity result})
      st' <- get
      H.liftEffect (setDocumentTitle (documentTitle st'))
      -- A page's view, or the editor, says when it has loaded the page, and
      -- the results of a search when they have come; everything else is
      -- loaded now.
      unless (waitsForPage st') settle

    settle :: H.HalogenM State Action Slots output m ()
    settle = modify (\st -> st {settled = True})

    handleQuery :: Query a -> H.HalogenM State Action Slots output m (Maybe a)
    handleQuery (Settled reply) = do
      st <- get
      pure (Just (reply (if st.settled then Just (documentTitle st) else Nothing)))

context :: State -> Context
context st = Context {router = st.router, session = st.session, spaces = st.spaces, revision = st.generation}

spaceOfRoute :: Route -> Maybe [Slug]
spaceOfRoute = \case
  Space path -> Just path
  Page path _ -> Just path
  EditPage path _ -> Just path
  NewPage path _ -> Just path
  _ -> Nothing

isSpaceRoute :: Route -> Bool
isSpaceRoute = \case
  Space _ -> True
  _ -> False

hereIs :: [Slug] -> Here -> Bool
hereIs path = \case
  InSpace p _ _ -> p == path
  SpaceFailed p _ -> p == path
  LoadingSpace p -> p == path
  NoSpace -> False

waitsForPage :: State -> Bool
waitsForPage st = case (st.route, st.here) of
  (Page _ _, InSpace {}) -> True
  (EditPage _ _, InSpace {}) -> True
  (NewPage _ _, InSpace {}) -> True
  (Search {}, _) -> True
  _ -> False

currentPageOf :: [Page] -> [Slug] -> Maybe Page
currentPageOf pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

currentPage :: State -> Maybe Page
currentPage st = case (st.route, st.here) of
  (Page _ path, InSpace _ _ pages) -> currentPageOf pages path
  (EditPage _ path, InSpace _ _ pages) -> currentPageOf pages path
  _ -> Nothing

-- | What the route is, as far as it has been loaded: a title for it.
crumbs :: State -> [(Text, Maybe Route)]
crumbs st = case st.route of
  Home -> []
  Space path -> spaceCrumbs path
  Page path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath
  EditPage path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath <> [("Edit", Nothing)]
  NewPage path parent -> spaceCrumbs path <> foldMap (pageCrumbs path) parent <> [("New page", Nothing)]
  NewSpace parent -> foldMap spaceCrumbs parent <> [("New space", Nothing)]
  Unknown -> [("Not found", Nothing)]
  Search {} -> [("Search", Nothing)]
  where
    spaceCrumbs path =
      [ (s.name, if mayView (context st) s.id then Just (Space (spacePathOf st.spaces s.id)) else Nothing)
      | s <- either (\e -> e.resolved) identity (resolvePath (findChild st.spaces) path)
      ]
    pageCrumbs path pagePath = case st.here of
      InSpace _ _ pages ->
        [ (p.title, Just (Page path (pagePathOf pages p.id)))
        | p <- either (\e -> e.resolved) identity (resolvePath (findChild pages) pagePath)
        ]
      _ -> []

documentTitle :: State -> Text
documentTitle st = case reverse (map fst (crumbs st)) of
  -- A space that cannot be shown has no name to show either: what is in
  -- its place says why.
  [] -> case st.here of
    SpaceFailed _ Forbidden -> "Private · Wiki"
    SpaceFailed _ NotFound -> "Not found · Wiki"
    _ -> "Wiki"
  names -> mconcat (intersperse " · " (take 2 names)) <> " · Wiki"
