{-# LANGUAGE QuasiQuotes #-}

-- | The application's frame, around whatever the route shows: a header with
-- the site's name, breadcrumbs, the search box ("Wiki.App.View.Search"), a
-- link to the administration for an administrator, and the demo's user
-- switcher; a sidebar with the tree of spaces, the current space's pages
-- under it; the content of the route; and a footer saying what the wiki is
-- built with.
--
-- The shell holds what every view needs and loads it itself: who is signed
-- in, the tree of spaces, and the space the route is in with its pages
-- (through 'getSpace' and 'listPages', so that a space the user may not see
-- is refused in place). The views are child components ("Wiki.App.View.*"):
-- a space, a page, a page's source, the forms for a new space and a new page,
-- the editor. They are handed that context,
-- and they tell the shell when they have changed the wiki ('Changed'), which
-- it then reloads, counting up the context's revision so that they reload
-- what they hold as well, and goes where the change leads.
--
-- The administration page ('Admin') is the shell's own rather than a view's:
-- what its first section does (export, import, reset) acts on the whole wiki
-- and on how the demo keeps it, which the shell holds and reloads after, so
-- those controls and their state stay here and the page is only where they
-- are shown. It is laid out as a heading per section, the wiki's data the
-- first; the sections on the wiki's people (its users and groups) follow,
-- a view of their own ("Wiki.App.View.Admin").
--
-- Over a backend that answers at once (the demo's), the shell loads all of
-- that with its initial state, so that its first render is the page the
-- prerender shows. Over one that would wait (the server's), it starts with
-- what that backend has kept, if anything, and otherwise with the frame
-- alone, the same at every address (no breadcrumbs, no spaces, "Loading…"),
-- which is what the server's pages are prerendered as, and loads the rest
-- in its initializer ("Loading" in "Wiki.App.Backend"). What could not be
-- loaded because the server could not be reached says so, with a button
-- to try again.
--
-- The demo's controls (its users to switch between, and its content to
-- reset, export and import) come with the input ('Demo'), over the
-- backend that has them; without them the header says who is signed in,
-- with the way to sign in or out over a backend where people do
-- ('Accounts', "Wiki.App.View.SignIn"), after which, or after a session
-- ends by itself, the shell reloads everything as the new reader;
-- and the administration's section on the wiki's data offers the
-- server's export and, over a backend that merges an archive into what it
-- has, the import ("Wiki.App.View.Import"), which brings the demo's pages
-- into the server.
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
import Data.Text qualified as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Wiki.Api (ArchiveApi (..), WikiApi (..))
import Wiki.Api.Links (links)
import Wiki.App.Account (Accounts (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), anonymous)
import Wiki.App.Backend.Admin (MonadAdmin)
import Wiki.App.Browser (download, historyEntry, historyGo, setDocumentTitle, unzipFiles, zipFiles)
import Wiki.App.DemoUsers (Demo (..))
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles, readPickedFile)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Admin qualified as AdminView
import Wiki.App.View.Common
import Wiki.App.View.Editor qualified as Editor
import Wiki.App.View.History qualified as HistoryView
import Wiki.App.View.Import qualified as ImportView
import Wiki.App.View.NewPage qualified as NewPageView
import Wiki.App.View.NewSpace qualified as NewSpaceView
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.Search qualified as SearchBox
import Wiki.App.View.SearchResults qualified as SearchResultsView
import Wiki.App.View.SignIn qualified as SignInView
import Wiki.App.View.Source qualified as SourceView
import Wiki.App.View.Space qualified as SpaceView
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Id (SpaceId, UserId)
import Wiki.Core.Page (Page (attachments, id, title))
import Wiki.Core.Path (PathError (..), childrenOf, findChild, resolvePath)
import Wiki.Core.Permission (GlobalPermission (Administer), hasGlobalPermission, mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, name, pageOrder, public, slug), subspacesOf)
import Wiki.Core.User (User (..))

-- | The router, a route the home page invites a newcomer to (the demo's
-- tour), if there is one, the demo's controls, over a backend that has
-- them, the import into a server, over one that has it, and signing in
-- and out, over one where people do.
data Input m = Input
  { router :: Router Route
  , welcome :: Maybe Route
  , demo :: Maybe (Demo m)
  , migration :: Maybe (ImportView.Migration m)
  , accounts :: Maybe (Accounts m)
  }

-- | Whether the shell has loaded everything the route shows; when it has,
-- the document's title for it. The prerender waits for this before it
-- takes the page's HTML.
data Query a = Settled (Maybe Text -> a)

type Slots =
  ("space" .== H.Slot (Const Void) ViewOutput ())
    .+ ("page" .== H.Slot (Const Void) ViewOutput ())
    .+ ("source" .== H.Slot (Const Void) ViewOutput ())
    .+ ("history" .== H.Slot (Const Void) ViewOutput ())
    .+ ("newSpace" .== H.Slot (Const Void) ViewOutput ())
    .+ ("newPage" .== H.Slot (Const Void) ViewOutput ())
    .+ ("editor" .== H.Slot Editor.Query ViewOutput [Slug])
    .+ ("searchBox" .== H.Slot (Const Void) Void ())
    .+ ("searchResults" .== H.Slot (Const Void) ViewOutput ())
    .+ ("importer" .== H.Slot (Const Void) ViewOutput ())
    .+ ("people" .== H.Slot (Const Void) ViewOutput ())
    .+ ("signIn" .== H.Slot SignInView.Query SignInView.Output ())

-- | The space the route is in, as far as it has been loaded.
data Here
  = NoSpace
  | LoadingSpace [Slug]
  | SpaceFailed [Slug] WikiError
  | InSpace [Slug] Space [Page]

-- | Whether what every route shows (who is signed in, the tree of spaces)
-- has been loaded.
data World
  = WorldLoading
  | WorldFailed WikiError
  | WorldReady
  deriving stock (Eq)

data State m = State
  { router :: Router Route
  , welcome :: Maybe Route
  , demo :: Maybe (Demo m)
  , migration :: Maybe (ImportView.Migration m)
  , accounts :: Maybe (Accounts m)
  , world :: World
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
  , panel :: Panel
  -- ^ What the administration's section on the wiki's data shows.
  , kept :: Bool
  -- ^ Whether the demo's changes are kept in the browser ('demoKept').
  , settled :: Bool
  , leaving :: Maybe Route
  -- ^ A route followed away from an editor with unsaved changes, which the
  -- reader is being asked about.
  , entry :: Int
  -- ^ The number of the session history's entry for the route shown
  -- ('historyEntry'), which staying in the editor goes back to.
  }

-- | What the administration's section on the wiki's data shows.
data Panel
  = -- | What can be done with the demo's content, under what the last
    -- export or import did, if anything.
    Actions (Maybe Told)
  | ConfirmingReset
  | -- | An archive read and checked, from the file of this name, waiting to
    -- replace the wiki.
    ConfirmingImport Text Archive

-- | What an export or an import did, or why it did nothing.
data Told = Told
  { refused :: Bool
  , message :: Text
  }

data Action
  = Initialize
  | Arrived Route
  | Followed (Follow Route)
  | Toggle SpaceId
  | ToggleMenu
  | SwitchTo (Maybe UserId)
  | AskReset
  | ResetDemo
  | Export
  | ImportChosen Event
  | ConfirmImport
  | CancelPanel
  | FromView ViewOutput
  | Leave
  | Stay
  | RetryWorld
  | RetryHere
  | FromAccount SignInView.Output
  | SessionChanged Session

component
  :: forall output m
   . (MonadLoad m, MonadAdmin m, MonadIslands m, MonadUUID m, MonadBrowserDOM m, MonadIO m)
  => H.Component Query (Input m) output m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded here rather than in 'Initialize', so that the first render
        -- is the page as the prerender left it, after its initializers:
        -- that is the HTML 'Halogen.VDom.Driver.hydrateUI' adopts, and a
        -- first render of the empty state would take it all apart, only for
        -- the initializer to build it again.
        -- Over a backend that would wait, it is loaded in 'Initialize'
        -- instead, unless the backend has kept it.
        initialState = \Input {router, welcome, demo, migration, accounts} -> do
          route <- Router.current router
          loaded <- atOnce $ do
            world <- fetchWorld demo
            here <- maybe (pure NoSpace) fetchHere (spaceOfRoute route)
            pure (world, here)
          let ((signedIn, users, spaces, kept), here) = fromMaybe ((anonymous, [], [], False), NoSpace) loaded
          pure
            State
              { router
              , welcome
              , demo
              , migration
              , accounts
              , world = if isJust loaded then WorldReady else WorldLoading
              , route
              , session = signedIn
              , users
              , spaces
              , here
              , collapsed = mempty
              , generation = 0
              , menuOpen = False
              , panel = Actions Nothing
              , kept
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
    render :: State m -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <div class="wiki">
          {{ header st }}
          <div class="wiki-body">
            {{ sidebar st }}
            <main class="wiki-content">
              {% if isJust st.leaving %}
                {{ leaveConfirm }}
              {% end %}
              {{ content st }}
            </main>
          </div>
          {{ footer }}
        </div>
      |]

    header :: State m -> H.ComponentHTML Action Slots m
    header st =
      [hh|
        <header class="wiki-header">
          <a class="wiki-brand" {{ Router.linkProps st.router Followed Home }}>Wiki</a>
          {{ breadcrumbs st }}
          {{ searchBox }}
          {{ adminLink st }}
          {{ whoIsAsking st }}
        </header>
      |]
      where
        searchBox = HH.slot_ "searchBox" () SearchBox.component SearchBox.Input {context = context st}

    breadcrumbs :: State m -> H.ComponentHTML Action Slots m
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
          Just r -> [hh|<a {{ Router.linkProps st.router Followed r }}>{{ label }}</a>|]
          Nothing -> [hh|<span class="unviewable">{{ label }}</span>|]

    -- The way to the administration, for someone who may administer the
    -- wiki; nobody else is shown it.
    adminLink :: State m -> Maybe (H.ComponentHTML Action Slots m)
    adminLink st =
      guard (isAdministrator st)
        $> [hh|
          <a
            class="admin-link"
            {{ [attr "aria-current" "page" | st.route == Admin] }}
            {{ Router.linkProps st.router Followed Admin }}
          >
            Administration
          </a>
        |]

    -- Who is signed in: the demo's menu to switch between its users, or,
    -- where people do not switch, their name, once it is known, with the
    -- way to sign in or out where people do.
    whoIsAsking :: State m -> Maybe (H.ComponentHTML Action Slots m)
    whoIsAsking st = case st.demo of
      Just _ -> Just (userSwitcher st)
      Nothing
        | st.world /= WorldReady -> Nothing
        | Just accounts <- st.accounts ->
            Just (HH.slot "signIn" () SignInView.component SignInView.Input {accounts, session = st.session} FromAccount)
        | otherwise -> Just [hh|<span class="user-name">{{ maybe "Not signed in" (\u -> u.displayName) st.session.user }}</span>|]

    -- The demo's menu of who one is: nobody, or one of its users.
    userSwitcher :: State m -> H.ComponentHTML Action Slots m
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

    -- The administration of the wiki, for someone who may administer it;
    -- anyone else is told whom it is for, and how to become one in the demo.
    admin :: State m -> H.ComponentHTML Action Slots m
    admin st
      | isAdministrator st =
          [hh|
            <section class="admin-view">
              <h1>Administration</h1>
              <section class="admin-section admin-data">
                <h2>Wiki data</h2>
                <p class="admin-intro">{{ dataIntro }}</p>
                {{ dataControls st }}
              </section>
              {{ HH.slot "people" () AdminView.component AdminView.Input {context = context st} FromView }}
            </section>
          |]
      | otherwise =
          [hh|
            <section class="admin-view">
              <h1>Administration</h1>
              <div class="error error-forbidden" role="alert">{{ refusal }}</div>
            </section>
          |]
      where
        dataIntro :: Text
        dataIntro
          | isJust st.demo = "The whole wiki as one file: export it to keep a copy or to take it to another browser, or import one to replace everything here."
          | otherwise = "The whole wiki as one file: export it to keep a copy, or import the pages of another into this one, choosing what to bring in."
        refusal :: Text
        refusal
          | isJust st.demo
          , isNothing st.session.user =
              "This page is for the wiki's administrators, and you are not signed in. To sign in as one, choose who you are at the top right."
          | isJust st.demo = "This page is for the wiki's administrators, which you are not. Switch to one at the top right."
          | isJust st.accounts
          , isNothing st.session.user =
              "This page is for the wiki's administrators, and you are not signed in. If you are one, sign in at the top right."
          | otherwise = "This page is for the wiki's administrators, which you are not."

    -- What can be done with the wiki's data: the demo's, or the server's.
    dataControls :: State m -> H.ComponentHTML Action Slots m
    dataControls st = maybe (serverControls st) (const (demoControls st)) st.demo

    -- The server's content as a whole: its export, which the browser
    -- downloads as the file the server names, and the import, which merges
    -- another wiki's pages into it, from an export or from the demo's data
    -- in this browser.
    serverControls :: State m -> H.ComponentHTML Action Slots m
    serverControls st =
      [hh|
        <div class="demo-controls server-controls">
          <div class="actions">
            <a class="button demo-export" href={{ links.archive.export }} download>Export the wiki</a>
          </div>
          {{ importer <$> st.migration }}
        </div>
      |]
      where
        importer migration = HH.slot "importer" () ImportView.component ImportView.Input {migration} FromView

    -- The demo's content as a whole: whether it is kept, exporting it,
    -- importing one, and resetting it, the last two asking first, in place.
    demoControls :: State m -> H.ComponentHTML Action Slots m
    demoControls st = case st.panel of
      ConfirmingReset ->
        [hh|
          <div class="confirm demo-confirm demo-reset-confirm" role="alertdialog">
            <p>Put the demo back as it was at the start? Every change made to it in this browser is lost.</p>
            <button type="button" class="danger" onClick={{ const ResetDemo }}>Reset</button>
            <button type="button" onClick={{ const CancelPanel }}>Cancel</button>
          </div>
        |]
      ConfirmingImport name archive ->
        [hh|
          <div class="confirm demo-confirm demo-import-confirm" role="alertdialog">
            <p>Replace everything in this wiki with {{ name }}, which holds {{ archiveSummary archive }}? What is in the wiki now is lost.</p>
            <button type="button" class="danger" onClick={{ const ConfirmImport }}>Replace</button>
            <button type="button" onClick={{ const CancelPanel }}>Cancel</button>
          </div>
        |]
      Actions told ->
        [hh|
          <div class="demo-controls">
            {% for t in maybeToList told %}
              <p class="demo-told{% if t.refused %} demo-refused{% end %}" role="status">{{ t.message }}</p>
            {% end %}
            <p class="demo-kept">{{ keptNote }}</p>
            <div class="actions">
              <button type="button" class="demo-export" onClick={{ const Export }}>Export the wiki</button>
              <label class="button demo-import">
                Import a wiki…
                <input type="file" accept=".zip,application/zip" onChange={{ ImportChosen }}>
              </label>
              <button type="button" class="demo-reset-ask" onClick={{ const AskReset }}>Reset the demo content…</button>
            </div>
          </div>
        |]
      where
        keptNote :: Text
        keptNote
          | st.kept = "Changes to the demo are kept in this browser."
          | otherwise = "This browser keeps nothing for the demo: changes last until the page is closed."

    sidebar :: State m -> H.ComponentHTML Action Slots m
    sidebar st =
      [hh|
        <nav class="wiki-sidebar" aria-label="Spaces">
          <h2>Spaces</h2>
          {{ spaceLevel st Nothing }}
          {{ newSpace st "new-space-link" }}
        </nav>
      |]

    -- A link to a new space at the top level, for someone who may make one.
    newSpace :: State m -> Text -> Maybe (H.ComponentHTML Action Slots m)
    newSpace st cls =
      guard (mayCreateSpace (principalOf (context st)) st.session.grants Nothing)
        $> [hh|<a class="{{ cls }}" {{ Router.linkProps st.router Followed (NewSpace Nothing) }}>New space</a>|]

    spaceLevel :: State m -> Maybe SpaceId -> H.ComponentHTML Action Slots m
    spaceLevel st parent = [hh|<ul class="space-tree">{{ map (spaceNode st) (subspacesOf st.spaces parent) }}</ul>|]

    spaceNode :: State m -> Space -> H.ComponentHTML Action Slots m
    spaceNode st s =
      [hh|
        <li class="space-node{% if current %} current{% end %}">
          <div class="space-row">
            {% if hasChildren %}
              {{ toggle }}
            {% end %}
            {{ spaceLabel }}
          </div>
          {{ pagesHere }}
          {% if hasChildren && open %}
            {{ spaceLevel st (Just s.id) }}
          {% end %}
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
              [hh|
                <a
                  class="space-link"
                  {{ [attr "aria-current" "page" | current && isSpaceRoute st.route] }}
                  {{ Router.linkProps st.router Followed (Space path) }}
                >
                  {{ s.name }}
                </a>
              |]
          | otherwise =
              [hh|<span class="unviewable" title="You do not have permission to see this space">{{ s.name }}</span>|]
        pagesHere = case st.here of
          InSpace _ here pages | here.id == s.id, not (null pages) -> Just (pageTree st.router Followed path here.pageOrder pages ((\p -> p.id) <$> currentPage st) (\_ _ _ -> []))
          _ -> Nothing

    content :: State m -> H.ComponentHTML Action Slots m
    content st = case (st.world, st.route) of
      (WorldLoading, _) -> loading
      (WorldFailed e, _) -> failureView e RetryWorld
      (WorldReady, route) -> routeContent st route

    routeContent :: State m -> Route -> H.ComponentHTML Action Slots m
    routeContent st = \case
      Home -> home st
      Unknown -> notFound st
      Admin -> admin st
      NewSpace parent -> HH.slot "newSpace" () NewSpaceView.component NewSpaceView.Input {context = context st, parent} FromView
      Search text space subspaces ->
        HH.slot "searchResults" () SearchResultsView.component SearchResultsView.Input {context = context st, text, space, subspaces} FromView
      _ -> case st.here of
        NoSpace -> notFound st
        LoadingSpace _ -> loading
        SpaceFailed _ e -> failureView e RetryHere
        InSpace _ space pages -> case st.route of
          Page _ path -> HH.slot "page" () PageView.component PageView.Input {context = context st, space, pages, path} FromView
          PageSource _ path -> HH.slot "source" () SourceView.component SourceView.Input {context = context st, space, path} FromView
          PageHistory _ path version against ->
            HH.slot "history" () HistoryView.component HistoryView.Input {context = context st, space, path, version, against} FromView
          -- One editor per page edited: another page's is a component of
          -- its own, with a draft of its own.
          EditPage _ path -> HH.slot "editor" path Editor.component Editor.Input {context = context st, space, pages, path} FromView
          NewPage _ parent -> HH.slot "newPage" () NewPageView.component NewPageView.Input {context = context st, space, pages, parent} FromView
          _ -> HH.slot "space" () SpaceView.component SpaceView.Input {context = context st, space, pages} FromView

    loading :: H.ComponentHTML Action Slots m
    loading = [hh|<p class="loading">Loading…</p>|]

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

    home :: State m -> H.ComponentHTML Action Slots m
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
            <p class="welcome">New here? <a {{ Router.linkProps st.router Followed r }}>Take the tour</a>.</p>
          {% end %}
          <h2>Spaces</h2>
          {{ spaceList }}
          {{ newSpace st "button" }}
        </section>
      |]
      where
        spaceList = case subspacesOf st.spaces Nothing of
          [] -> [hh|<p class="empty">There are no spaces you can see.</p>|]
          roots -> [hh|<ul class="space-list">{{ map (rootSpace st) roots }}</ul>|]

    rootSpace :: State m -> Space -> H.ComponentHTML Action Slots m
    rootSpace st s
      | mayView (context st) s.id =
          [hh|
            <li>
              <a {{ Router.linkProps st.router Followed (Space [s.slug]) }}>{{ s.name }}</a>
              <span class="badge {{ if s.public then "badge-public" else "badge-private" :: Text }}">{{ if s.public then "Public" else "Private" :: Text }}</span>
            </li>
          |]
      | otherwise =
          [hh|<li><span class="unviewable" title="You can see only a subspace of this space">{{ s.name }}</span></li>|]

    notFound :: State m -> H.ComponentHTML Action Slots m
    notFound st =
      [hh|
        <section class="not-found">
          <h1>Not found</h1>
          <p>There is nothing at this address.</p>
          <a class="button" {{ Router.linkProps st.router Followed Home }}>Go to the front page</a>
        </section>
      |]

    -- One line at the foot of every page, the prerendered ones too.
    footer :: H.ComponentHTML Action Slots m
    footer =
      [hh|
        <footer class="wiki-footer">Built with <a href="https://github.com/Swordlash/haskell-halogen">haskell-halogen</a></footer>
      |]

    handleAction :: Action -> H.HalogenM (State m) Action Slots output m ()
    handleAction = \case
      Initialize -> do
        router <- gets (\st -> st.router)
        void $ H.subscribe (Arrived <$> Router.changes router)
        gets (\st -> st.accounts) >>= traverse_ (\a -> lift a.sessionChanges >>= void . H.subscribe . fmap SessionChanged)
        entry <- H.liftEffect historyEntry
        modify (\st -> st {entry})
        -- What the route shows was loaded with the initial state, unless
        -- the backend would have waited for it.
        gets (\st -> st.world) >>= \case
          WorldReady -> announce
          _ -> loadEverything
      RetryWorld -> do
        modify (\st -> st {world = WorldLoading})
        loadEverything
      RetryHere -> loadHere True
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
      -- What was asked or told about the wiki's data was asked of, or told
      -- to, the user one was.
      SwitchTo user -> withDemo $ \demo -> do
        modify (\st -> st {menuOpen = False, panel = Actions Nothing, settled = False})
        lift (demo.switchTo user)
        reload Nothing
      AskReset -> modify (\st -> st {panel = ConfirmingReset})
      CancelPanel -> modify (\st -> st {panel = Actions Nothing})
      -- The route stays, the administration, and says what was done, since
      -- nothing else there shows it.
      ResetDemo -> withDemo $ \demo -> do
        modify (\st -> st {panel = Actions Nothing, settled = False})
        lift demo.resetDemo
        reload Nothing
        report False "The demo's content is back as it was at the start."
      Export -> withDemo $ \demo -> do
        archive <- lift demo.exportDemo
        let name = "wiki-" <> toS (formatTime defaultTimeLocale "%Y-%m-%d" archive.createdAt) <> ".zip"
        download name "application/zip" =<< zipFiles (writeArchive archive)
        report False ("Exported the wiki as " <> name <> ".")
      -- The file is read and checked whole before anything is asked: what
      -- cannot be imported is refused here, with the reason.
      ImportChosen ev -> do
        picked <- H.liftEffect (chosenFiles ev >>= pickedFiles)
        for_ (head picked) $ \file -> do
          bytes <- readPickedFile file
          unzipped <- first (\why -> "It is not a zip file the wiki can read (" <> why <> ").") <$> unzipFiles bytes
          case unzipped >>= readArchive of
            Left why -> report True ("Not imported: " <> file.name <> ". " <> why)
            Right archive -> modify (\st -> st {panel = ConfirmingImport file.name archive})
      ConfirmImport ->
        gets (\st -> st.panel) >>= \case
          ConfirmingImport name archive -> withDemo $ \demo ->
            lift (demo.importDemo archive) >>= \case
              Left why -> report True ("Not imported: " <> name <> ". " <> why <> ".")
              Right () -> do
                modify (\st -> st {settled = False})
                reload Nothing
                report False ("Imported " <> name <> ": " <> archiveSummary archive <> ".")
          _ -> pass
      FromView (Changed next) -> reload next
      FromView Loaded -> settle
      -- Someone signed in or out: everything again, as them.
      FromAccount (SignInView.AccountChanged s) -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        reload Nothing
      -- The session ended by itself (or changed elsewhere): everything
      -- again, as whoever is asking now, and if that is nobody, the way to
      -- sign in again, saying why.
      SessionChanged s -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        reload Nothing
        when (isNothing s.user) $
          H.tell "signIn" () (SignInView.Prompt "Your session has ended. Sign in again to go on.")

    -- Something only the demo does, which nothing offers without it.
    withDemo :: (Demo m -> H.HalogenM (State m) Action Slots output m ()) -> H.HalogenM (State m) Action Slots output m ()
    withDemo f = gets (\st -> st.demo) >>= traverse_ f

    -- Everything the route shows, which the initial state could not have
    -- at once.
    loadEverything :: H.HalogenM (State m) Action Slots output m ()
    loadEverything = do
      loadWorld
      gets (\st -> st.world) >>= \case
        WorldReady -> loadHere True
        _ -> pass

    -- Say in the administration what an export, an import or a reset did.
    report :: Bool -> Text -> H.HalogenM (State m) Action Slots output m ()
    report refused message = modify (\st -> st {panel = Actions (Just Told {refused, message})})

    arrive :: Route -> Int -> H.HalogenM (State m) Action Slots output m ()
    arrive r entry = do
      -- What was asked or told about the wiki's data is not shown again on
      -- coming back to the administration.
      modify (\st -> st {route = r, settled = False, menuOpen = False, panel = Actions Nothing, leaving = Nothing, entry})
      loadHere False

    -- After a change: everything again, and every view's own data too.
    reload :: Maybe Route -> H.HalogenM (State m) Action Slots output m ()
    reload next = do
      loadWorld
      modify (\st -> st {generation = st.generation + 1})
      for_ next $ \r -> modify (\st -> st {route = r, settled = False, leaving = Nothing})
      loadHere True
      -- The router is told last, so that the route it announces is the one
      -- already shown, which 'Arrived' leaves alone.
      router <- gets (\st -> st.router)
      for_ next (Router.navigate router)

    -- Who is signed in and the tree of spaces, on a worker. If they cannot
    -- be loaded, the route's content is why, with a button to try again.
    loadWorld :: H.HalogenM (State m) Action Slots output m ()
    loadWorld = do
      demo <- gets (\st -> st.demo)
      lift (attempt (fetchWorld demo)) >>= \case
        Right (s, us, ss, kept) -> modify (\st -> st {session = s, users = us, spaces = ss, kept, world = WorldReady})
        Left e -> modify (\st -> st {world = WorldFailed e})

    -- The space the route is in, unless it is the one loaded already
    -- (or even so, if forced).
    loadHere :: Bool -> H.HalogenM (State m) Action Slots output m ()
    loadHere again = do
      st <- get
      case spaceOfRoute st.route of
        Nothing -> modify (\s -> s {here = NoSpace})
        Just path
          | not again, hereIs path st.here -> pass
          | otherwise -> do
              -- Reloading the space being shown keeps it on screen meanwhile.
              unless (hereIs path st.here) $ modify (\s -> s {here = LoadingSpace path})
              result <- fetchHere path
              -- Unless the route has moved on to another space meanwhile.
              now <- gets (\s -> s.route)
              when (spaceOfRoute now == Just path) $
                modify (\s -> s {here = result})
      announce

    -- Title the document for what is shown, and say whether that is all of
    -- it. A page's view, or the editor, says when it has loaded the page,
    -- and the results of a search when they have come; everything else is
    -- loaded by now.
    announce :: H.HalogenM (State m) Action Slots output m ()
    announce = do
      st <- get
      H.liftEffect (setDocumentTitle (documentTitle st))
      unless (waitsForPage st) settle

    settle :: H.HalogenM (State m) Action Slots output m ()
    settle = modify (\st -> st {settled = True})

    handleQuery :: Query a -> H.HalogenM (State m) Action Slots output m (Maybe a)
    handleQuery (Settled reply) = do
      st <- get
      pure (Just (reply (if st.settled then Just (documentTitle st) else Nothing)))

-- | What every route shows around it: who is signed in, who else one may
-- be in the demo, the tree of spaces, and whether the demo keeps its
-- changes.
fetchWorld :: (MonadWiki n) => Maybe (Demo n) -> n (Session, [User], [Space], Bool)
fetchWorld demo =
  (,,,)
    <$> session
    <*> maybe (pure []) (\d -> d.listUsers) demo
    <*> listSpaces
    <*> maybe (pure False) (\d -> d.demoKept) demo

-- | The space at a path, with its pages, or why it cannot be shown.
fetchHere :: (MonadWiki n) => [Slug] -> n Here
fetchHere path =
  either (SpaceFailed path) identity
    <$> runExceptT
      ( do
          space <- ExceptT (getSpace path)
          pages <- ExceptT (listPages space.id)
          pure (InSpace path space pages)
      )

-- | Whether the user may administer the wiki as a whole: who is shown the
-- administration.
isAdministrator :: State m -> Bool
isAdministrator st = hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer
  where
    ctx = context st

context :: State m -> Context
context st = Context {router = st.router, session = st.session, spaces = st.spaces, revision = st.generation}

spaceOfRoute :: Route -> Maybe [Slug]
spaceOfRoute = \case
  Space path -> Just path
  Page path _ -> Just path
  EditPage path _ -> Just path
  PageSource path _ -> Just path
  PageHistory path _ _ _ -> Just path
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

waitsForPage :: State m -> Bool
waitsForPage st = case (st.route, st.here) of
  (Page _ _, InSpace {}) -> True
  (EditPage _ _, InSpace {}) -> True
  (PageSource _ _, InSpace {}) -> True
  (PageHistory {}, InSpace {}) -> True
  (Search {}, _) -> True
  _ -> False

currentPageOf :: [Page] -> [Slug] -> Maybe Page
currentPageOf pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

currentPage :: State m -> Maybe Page
currentPage st = case (st.route, st.here) of
  (Page _ path, InSpace _ _ pages) -> currentPageOf pages path
  (EditPage _ path, InSpace _ _ pages) -> currentPageOf pages path
  (PageSource _ path, InSpace _ _ pages) -> currentPageOf pages path
  (PageHistory _ path _ _, InSpace _ _ pages) -> currentPageOf pages path
  _ -> Nothing

-- | What the route is, as far as it has been loaded: a title for it.
crumbs :: State m -> [(Text, Maybe Route)]
crumbs st = case st.route of
  -- The same at every address until there is something to name.
  _ | st.world /= WorldReady -> []
  Home -> []
  Space path -> spaceCrumbs path
  Page path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath
  EditPage path pagePath -> spaceCrumbs path <> pageCrumbs path pagePath <> [("Edit", Nothing)]
  -- The source of a page in a space that cannot be shown is not named
  -- either, so that its title says why, as the page's would.
  PageSource path pagePath ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("Source", Nothing) | not (null page)]
  PageHistory path pagePath _ _ ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("History", Nothing) | not (null page)]
  NewPage path parent -> spaceCrumbs path <> foldMap (pageCrumbs path) parent <> [("New page", Nothing)]
  NewSpace parent -> foldMap spaceCrumbs parent <> [("New space", Nothing)]
  Unknown -> [("Not found", Nothing)]
  Search {} -> [("Search", Nothing)]
  Admin -> [("Administration", Nothing)]
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

documentTitle :: State m -> Text
documentTitle st = case reverse (map fst (crumbs st)) of
  -- A space that cannot be shown has no name to show either: what is in
  -- its place says why.
  [] -> case st.here of
    SpaceFailed _ Forbidden -> "Private · Wiki"
    SpaceFailed _ NotFound -> "Not found · Wiki"
    _ -> "Wiki"
  names -> mconcat (intersperse " · " (take 2 names)) <> " · Wiki"

-- | How much an archive holds, for a person to read.
archiveSummary :: Archive -> Text
archiveSummary a =
  T.intercalate
    ", "
    [ counted (length a.users) "user" "users"
    , counted (length a.spaces) "space" "spaces"
    , counted (length a.pages) "page" "pages"
    , counted (sum [length p.attachments | p <- a.pages]) "attachment" "attachments"
    ]
  where
    counted :: Int -> Text -> Text -> Text
    counted n singular plural = show n <> " " <> if n == 1 then singular else plural
