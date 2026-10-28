{-# LANGUAGE QuasiQuotes #-}

-- | The shell: the application's frame around whatever the route shows.
-- It has a header with the site's name, breadcrumbs, the search box
-- ("Wiki.App.View.Search"), a link to the administration for an
-- administrator, and the demo's user switcher; a sidebar; the content of
-- the route; and a footer saying what the wiki is built with.
--
-- The front page is the directory of spaces ("Wiki.App.View.Directory").
-- Inside a space (any route under @\/s\/\<space>@) the sidebar shows that
-- space alone, as Confluence does: its icon and name, a link back to the
-- directory and a menu of the other spaces to switch to, a link up to its
-- parent space, its home page and its list of pages, its pages as a tree,
-- its templates ('Wiki.Core.Page.template') apart from the tree, and its
-- subspaces below them. Elsewhere the sidebar lists the spaces. A space's
-- own route shows its home page, if it has one
-- ('Wiki.Core.Space.homePage'), and otherwise its list of pages. A space
-- shown as a blog shows its posts instead, under its home page
-- ("Wiki.App.View.Blog"). Every space shown is recorded as recently
-- visited ("Wiki.App.Recent").
--
-- The shell holds, and loads itself, the context every view needs: who is
-- signed in, the tree of spaces, and the space the route is in with its
-- pages. It loads the space through 'getSpace' and 'listPages', so that a
-- space the user may not see is refused in place. The views are child
-- components ("Wiki.App.View.*"): a space, a page, a page's source, its
-- history and its slides, the forms for a new space and a new page, and
-- the editor. They get that context, and tell the shell when they have
-- changed the wiki ('Changed'). The shell then reloads the context,
-- increments its revision so that the views reload their own data too,
-- and navigates to where the change leads.
--
-- The administration page ('Admin') belongs to the shell rather than to a
-- view. Its first section (export, import, reset) acts on the whole wiki
-- and on how the demo saves it, which the shell holds and reloads
-- afterwards. So those controls and their state stay here, and the page
-- only shows them. The page has a heading per section, the wiki's data
-- first. The sections on the wiki's users and groups follow, in a view of
-- their own ("Wiki.App.View.Admin").
--
-- When the backend answers at once (the demo's in-memory backend), the
-- shell loads all of that in its initial state, so that its first render
-- is the page the prerender shows. When the backend would wait (the HTTP
-- backend), the shell starts with what that backend has cached, if
-- anything. Otherwise it starts with the bare frame, the same at every
-- address (no breadcrumbs, no spaces, "Loading…"), which is how the
-- server's pages are prerendered, and loads the rest in its initializer
-- (see "Loading" in "Wiki.App.Backend"). Anything that could not be loaded
-- because the server could not be reached says so, with a button to try
-- again.
--
-- The demo's controls (its users to switch between, and its content to
-- reset, export and import) come with the input ('Demo'), on the backend
-- that has them. Without them, the header says who is signed in, with a
-- way to sign in or out on a backend where people do ('Accounts',
-- "Wiki.App.View.SignIn"). After someone signs in or out, or a session
-- ends by itself, the shell reloads everything as the new user. Without
-- the demo's controls, the administration's section on the wiki's data
-- offers the server's export and, on a backend that merges an archive into
-- its content, the import ("Wiki.App.View.Import"), which brings the
-- demo's pages into the server.
--
-- A closed wiki ("Wiki.Core.Access") shows someone who has not signed in
-- only the way to sign in, at every route ('shutOut'): the header with the
-- wiki's name and "Sign in" (or the demo's switcher), and a line saying
-- why. The exception is an invitation's page ('Invite'), which is meant
-- for them. Nothing else is read for them, so that the server, which
-- prerenders the same page, is never asked for something it would refuse.
--
-- On a backend with a live channel ("Wiki.App.Live", the HTTP backend's),
-- the shell asks it for the tab's feed once, and hands the feed to the
-- page view and to the editor. The page view listens on it for its page's
-- comments, who is editing the page, and its saves. The editor announces
-- on it that it is editing its page. The WebSocket is opened when the
-- first page is watched, and opened again as the new user after signing in
-- or out, or after a session ends by itself.
--
-- The route comes from the router ('Router.current' at the start, then
-- 'Router.changes'), so links, the back and forward buttons and a reload
-- all arrive at the same place.
--
-- On the HTTP backend, which needs the network, the shell listens for the
-- browser going offline and online ("Halogen.Query.Event.Window"'s
-- 'Window.online'). While the browser is offline, a notice says that the
-- wiki cannot be reached, before any request has failed. Once it is back
-- online, whatever the shell could not load is loaded again. The demo
-- keeps its wiki in the browser, so it shows no such notice. A page the
-- service worker served from its offline copy, because there was no
-- network ("Wiki.App.Offline"), says so too, with the copy's time: "You
-- are reading an offline copy from …", until the reader navigates
-- elsewhere. Where the browser offers to install the wiki as an
-- application, the header has an "Install" button.
--
-- The one route change the shell does not simply follow is one away from
-- an editor with unsaved changes. It asks the editor ('Editor.IsDirty')
-- and, if the draft would be lost, asks the reader in place whether to
-- leave. By then the browser's address is already the new route's (a link
-- was followed, or the back button pressed). So staying goes back through
-- the session history to the editor's entry, by as many entries as lie in
-- between ('historyEntry' numbers them), as the browser's buttons would.
module Wiki.App.Shell
  ( Input (..)
  , Query (..)
  , component
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row.Internal (LT (..), Row (R))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Query.Event.Window qualified as Window
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Wiki.Api (ArchiveApi (..), WikiApi (..))
import Wiki.Api.Links (links)
import Wiki.App.Account (Accounts (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), anonymous, shutOut)
import Wiki.App.Backend.Admin (MonadAdmin)
import Wiki.App.Backend.Comments (MonadComments)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (download, historyEntry, historyGo, keepContents, keepHeights, setDocumentTitle, unzipFiles, zipFiles)
import Wiki.App.DemoUsers (Demo (..))
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles, readPickedFile)
import Wiki.App.Head (Feeds (..), Head (..), Preview (..), PreviewImage (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Live (Feed (..), Live (..))
import Wiki.App.Offline (browserOnline, install, installAvailable, installChanges, offlineCopy)
import Wiki.App.Recent (rememberVisit)
import Wiki.App.Route (Route (..))
import Wiki.App.Security (MonadSecurity)
import Wiki.App.View.Access qualified as AccessView
import Wiki.App.View.Activity qualified as ActivityView
import Wiki.App.View.Admin qualified as AdminView
import Wiki.App.View.AssistantSettings qualified as AssistantSettingsView
import Wiki.App.View.Bell qualified as BellView
import Wiki.App.View.Blog qualified as BlogView
import Wiki.App.View.Common
import Wiki.App.View.Directory qualified as DirectoryView
import Wiki.App.View.Editor qualified as Editor
import Wiki.App.View.History qualified as HistoryView
import Wiki.App.View.Import qualified as ImportView
import Wiki.App.View.Invite qualified as InviteView
import Wiki.App.View.NewPage qualified as NewPageView
import Wiki.App.View.NewSpace qualified as NewSpaceView
import Wiki.App.View.NotificationSettings qualified as NotificationSettingsView
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.Reset qualified as ResetView
import Wiki.App.View.Search qualified as SearchBox
import Wiki.App.View.SearchResults qualified as SearchResultsView
import Wiki.App.View.Security qualified as SecurityView
import Wiki.App.View.Server qualified as ServerView
import Wiki.App.View.SignIn qualified as SignInView
import Wiki.App.View.Slides qualified as SlidesView
import Wiki.App.View.Source qualified as SourceView
import Wiki.App.View.Space qualified as SpaceView
import Wiki.App.View.Unsubscribe qualified as UnsubscribeView
import Wiki.App.View.VerifyEmail qualified as VerifyEmailView
import Wiki.Core.Attachment (findAttachment)
import Wiki.Core.Blog (excerpt, firstImage)
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Id (SpaceId, UserId)
import Wiki.Core.Markdown (Destination (..), classifyDestination, parseMarkdown)
import Wiki.Core.Page (Page (attachments, body, id, title), PageSummary (id, title), templatePages, treePages)
import Wiki.Core.Path (PathError (..), findChild, resolvePath)
import Wiki.Core.Permission (GlobalPermission (Administer), canView, hasGlobalPermission, mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Icon (..), Space (blog, description, icon, id, name, pageOrder, parent), subspacesOf)
import Wiki.Core.User (User (..))

-- | The shell's input: the router; a route the home page invites a
-- newcomer to (the demo's tour), if any; the demo's controls, on a backend
-- that has them; the import into a server, on a backend that has it; and
-- signing in and out, on a backend where people do.
data Input m = Input
  { router :: Router Route
  , welcome :: Maybe Route
  , demo :: Maybe (Demo m)
  , migration :: Maybe (ImportView.Migration m)
  , accounts :: Maybe (Accounts m)
  , live :: Maybe (Live m)
  }

-- | Whether the shell has loaded everything the route shows, and once it
-- has, what the page says about itself (its title, and for a public page
-- what a link preview shows, "Wiki.App.Head"). The prerender and the
-- server wait for this before they take the page's HTML.
data Query a = Settled (Maybe Head -> a)

-- | 'Slots' is the row type of the shell's child components. Each label
-- holds one kind of child: its query type, its output type and the type of
-- its index.
--
-- Children with the same query type and output type share a label, and the
-- index ('ViewSlot', 'PartSlot') says which child it is. Each index is always
-- used with the same component. So Halogen keeps a child, or replaces it,
-- exactly as it did when each child had a label of its own.
--
-- The row is written as a sorted list of labels, with the constructors of
-- "Data.Row.Internal", and not with row-types' operators @.+@ and @.==@.
-- The operators are type families, and 'Slots' is a type synonym. The
-- compiler expands the synonym at every 'HH.slot', 'H.tell' and
-- 'H.queryAll', and reduces the type families there again. The compiled code
-- keeps a proof of each reduction (a coercion), and the simplifier works
-- through every copy. With the 27 labels the shell once had, written with
-- the operators, those coercions took almost nine tenths of this module's
-- compile time. The list stays sorted by label, the order the operators produce, so
-- the row is the same type the operators would build. A new label goes in at
-- its place in alphabetical order.
type Slots =
  R
    '[ "editor" :-> H.Slot Editor.Query ViewOutput [Slug]
     , "invite" :-> H.Slot (Const Void) InviteView.Output ()
     , "part" :-> H.Slot (Const Void) Void PartSlot
     , "reset" :-> H.Slot (Const Void) ResetView.Output ()
     , "signIn" :-> H.Slot SignInView.Query SignInView.Output ()
     , "view" :-> H.Slot (Const Void) ViewOutput ViewSlot
     ]

-- | 'ViewSlot' is the index of a child under the label "view". These
-- children are the views whose output is 'ViewOutput': each tells the shell
-- when it has loaded and when it has changed the wiki.
data ViewSlot
  = DirectorySlot
  | SpaceSlot
  | PageSlot
  | BlogSlot
  | SourceSlot
  | HistorySlot
  | SlidesSlot
  | NewSpaceSlot
  | NewPageSlot
  | SearchResultsSlot
  | ImporterSlot
  | AccessSlot
  | ServerSlot
  | PeopleSlot
  deriving stock (Eq, Ord)

-- | 'PartSlot' is the index of a child under the label "part". The output
-- type of these children is 'Void': the shell gets nothing from them.
data PartSlot
  = SearchBoxSlot
  | BellSlot
  | OfflineCopySlot
  | DemoAccountSlot
  | DemoNotificationsSlot
  | ActivitySlot
  | VerifyEmailSlot
  | UnsubscribeSlot
  | AssistantSettingsSlot
  deriving stock (Eq, Ord)

-- | The space the route is in, as far as it has been loaded.
data Here
  = NoSpace
  | LoadingSpace [Slug]
  | SpaceFailed [Slug] WikiError
  | InSpace [Slug] Space [PageSummary]

-- | Whether the context every route shows (who is signed in, the tree of
-- spaces) has been loaded.
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
  , live :: Maybe (Live m)
  , feed :: Maybe Feed
  -- ^ The tab's live channel, from 'live'.
  , world :: World
  , route :: Route
  , session :: Session
  , users :: [User]
  , spaces :: [Space]
  , icons :: Map SpaceId Text
  -- ^ The URLs of the spaces' icon images, for spaces whose icon is an
  -- image.
  , here :: Here
  , switcherOpen :: Bool
  -- ^ Whether the sidebar's menu of spaces to switch to is open.
  , generation :: Int
  -- ^ The views' 'revision': how many times the wiki has been reloaded
  -- after a change.
  , menuOpen :: Bool
  , demoAccountOpen :: Bool
  -- ^ Whether the demo's account panel (its one session, and the server's
  -- features shown disabled) is open.
  , panel :: Panel
  -- ^ What the administration's section on the wiki's data shows.
  , kept :: Bool
  -- ^ Whether the demo's changes are saved in the browser ('demoKept').
  , settled :: Bool
  , leaving :: Maybe Route
  -- ^ A route followed away from an editor with unsaved changes, about
  -- which the reader is being asked.
  , entry :: Int
  -- ^ The number of the session history entry for the route shown
  -- ('historyEntry'), which staying in the editor goes back to.
  , offline :: Bool
  -- ^ Whether the browser has said it went offline, and not yet that it
  -- is back. It starts online. It is set when the shell starts if the
  -- browser says it is offline, or if the page is an offline copy: a page
  -- the service worker served offline was loaded without a network, and no
  -- event reports that.
  , offlineCopy :: Maybe UTCTime
  -- ^ When the page shown was stored, if the service worker served it
  -- offline from its stored copy; kept until the reader navigates
  -- elsewhere.
  , installable :: Bool
  -- ^ Whether the browser offers to install the wiki.
  , shown :: Maybe Page
  -- ^ The page the page view last said it shows ('Showing'), with its
  -- body: the head's preview describes the page with it. The space's list
  -- of pages has no bodies.
  }

-- | What the administration's section on the wiki's data shows.
data Panel
  = -- | What can be done with the demo's content, under the result of the
    -- last export or import, if any.
    Actions (Maybe Told)
  | ConfirmingReset
  | -- | An archive, read and checked, from the file of this name, waiting
    -- for confirmation to replace the wiki.
    ConfirmingImport Text Archive

-- | The result of an export or an import, or the reason it did nothing.
data Told = Told
  { refused :: Bool
  , message :: Text
  }

data Action
  = Initialize
  | Arrived Route
  | Followed (Follow Route)
  | ToggleSwitcher
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
  | OpenSignIn
  | FromInvite InviteView.Output
  | FromReset ResetView.Output
  | ToggleDemoAccount
  | Online Bool
  | InstallChanged
  | Install

component
  :: forall output m
   . (MonadLoad m, MonadAdmin m, MonadComments m, MonadNotifications m, MonadSecurity m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m)
  => H.Component Query (Input m) output m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded here rather than in 'Initialize', so that the first render
        -- is the page as the prerender left it, after its initializers:
        -- that is the HTML 'Halogen.VDom.Driver.hydrateUI' adopts, and a
        -- first render of the empty state would tear it all down, only for
        -- the initializer to build it again.
        -- On a backend that would wait, it is loaded in 'Initialize'
        -- instead, unless the backend has it cached.
        initialState = \Input {router, welcome, demo, migration, accounts, live} -> do
          route <- Router.current router
          -- The tab's live channel, made before any view: a page shown from
          -- the first render watches its page from its own initializer,
          -- which runs before the shell's.
          feed <- traverse (\l -> l.liveFeed) live
          loaded <- atOnce $ do
            world <- fetchWorld demo
            here <- if shutOut world.asking then pure NoSpace else maybe (pure NoSpace) fetchHere (spaceOfRoute route)
            pure (world, here)
          let (Around signedIn users spaces icons kept, here) = fromMaybe (Around anonymous [] [] mempty False, NoSpace) loaded
          pure
            State
              { router
              , welcome
              , demo
              , migration
              , accounts
              , live
              , feed
              , world = if isJust loaded then WorldReady else WorldLoading
              , route
              , session = signedIn
              , users
              , spaces
              , icons
              , here
              , switcherOpen = False
              , generation = 0
              , menuOpen = False
              , demoAccountOpen = False
              , panel = Actions Nothing
              , kept
              , settled = False
              , leaving = Nothing
              , entry = 0
              , offline = False
              , offlineCopy = Nothing
              , installable = False
              , shown = Nothing
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
    render st
      | isShut st = closedFrame st
      | otherwise =
          [hh|
        <div class="wiki">
          {{ header st }}
          <div class="wiki-body">
            {{ sidebar st }}
            <main class="wiki-content">
              {{ offlineCopyLine st }}
              {% if isJust st.leaving %}
                {{ leaveConfirm }}
              {% end %}
              {{ content st }}
            </main>
          </div>
          {{ footer }}
          {% if st.offline && overNetwork st %}
            {{ offlineNotice }}
          {% end %}
        </div>
      |]

    -- Last in the frame, so that showing or hiding it moves nothing else
    -- in the frame; the stylesheet puts it in a corner of the window.
    offlineNotice :: H.ComponentHTML Action Slots m
    offlineNotice =
      [hh|<p class="offline-notice" role="alert">You are offline: the wiki cannot be reached until the connection is back.</p>|]

    -- Above what the route shows, while it shows a page from the service
    -- worker's offline copy: the copy's time. The time is shown in the
    -- reader's time zone (an island, like every time the wiki shows).
    offlineCopyLine :: State m -> Maybe (H.ComponentHTML Action Slots m)
    offlineCopyLine st = case st.offlineCopy of
      Just at
        | overNetwork st ->
            Just
              [hh|
                <p class="offline-copy" role="status">
                  You are reading an offline copy from {{ HH.slot_ "part" OfflineCopySlot Islands.component (Islands.LocalTime at) }}.
                </p>
              |]
      _ -> Nothing

    -- A closed wiki, to someone who has not signed in: its name, the way to
    -- sign in, and why there is nothing else.
    closedFrame :: State m -> H.ComponentHTML Action Slots m
    closedFrame st =
      [hh|
        <div class="wiki wiki-closed">
          <header class="wiki-header">
            <a class="wiki-brand" {{ Router.linkProps st.router Followed Home }}>Wiki</a>
            {{ whoIsAsking st }}
          </header>
          <div class="wiki-body">
            <main class="wiki-content">
              <section class="closed">
                <h1>Sign in to read this wiki</h1>
                <p>This wiki is open to its members only. {{ how }}</p>
                {% if isJust st.accounts %}
                  <button type="button" class="primary closed-sign-in" onClick={{ const OpenSignIn }}>Sign in</button>
                {% end %}
              </section>
            </main>
          </div>
          {{ footer }}
        </div>
      |]
      where
        how :: Text
        how
          | isJust st.demo = "Choose who you are at the top right."
          | otherwise = "Sign in to see its spaces and pages; to become a member, ask one of its administrators for an invitation."

    header :: State m -> H.ComponentHTML Action Slots m
    header st =
      [hh|
        <header class="wiki-header">
          <a class="wiki-brand" {{ Router.linkProps st.router Followed Home }}>Wiki</a>
          {{ breadcrumbs st }}
          {{ searchBox }}
          {{ adminLink st }}
          {{ installButton st }}
          {{ bell st }}
          {{ whoIsAsking st }}
        </header>
      |]
      where
        searchBox = HH.slot_ "part" SearchBoxSlot SearchBox.component SearchBox.Input {context = context st}

    breadcrumbs :: State m -> H.ComponentHTML Action Slots m
    breadcrumbs st =
      [hh|
        <nav class="breadcrumbs" aria-label="Breadcrumbs">
          <ol>
            {% for (label, target, final) in marked (trail st) %}
              <li>{{ crumb label target final }}</li>
            {% end %}
          </ol>
        </nav>
      |]
      where
        -- Each crumb, and whether it is the last one: the route itself,
        -- which is not a link.
        marked cs = zipWith (\n (label, target) -> (label, target, n == length cs)) [1 :: Int ..] cs
        -- The last crumb names the route shown. A crumb before it is a
        -- link, unless the user may not go there.
        crumb label target final = case target of
          _ | final -> [hh|<span aria-current="page">{{ label }}</span>|]
          Just r -> [hh|<a {{ Router.linkProps st.router Followed r }}>{{ label }}</a>|]
          Nothing -> [hh|<span class="unviewable">{{ label }}</span>|]

    -- The link to the administration, for someone who may administer the
    -- wiki; nobody else sees it.
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

    -- The button to install the wiki as an application, where the browser
    -- offers it (WP4.17 of docs/PLAN.md), beside the user's name.
    installButton :: State m -> Maybe (H.ComponentHTML Action Slots m)
    installButton st =
      guard st.installable
        $> [hh|<button type="button" class="install-app" title="Install the wiki as an application" onClick={{ const Install }}>Install</button>|]

    -- The signed-in user's notifications (WP4.13 of docs/PLAN.md), beside
    -- their name, once who is asking is known.
    bell :: State m -> Maybe (H.ComponentHTML Action Slots m)
    bell st =
      guard (st.world == WorldReady && notified (context st))
        $> HH.slot_ "part" BellSlot BellView.component BellView.Input {context = context st, feed = st.feed}

    -- Who is signed in: the demo's menu to switch between its users, or,
    -- where people do not switch, their name, once it is known, with a
    -- way to sign in or out where people do.
    whoIsAsking :: State m -> Maybe (H.ComponentHTML Action Slots m)
    whoIsAsking st = case st.demo of
      Just _ -> Just (userSwitcher st)
      Nothing
        | st.world /= WorldReady -> Nothing
        | Just accounts <- st.accounts ->
            Just (HH.slot "signIn" () SignInView.component SignInView.Input {accounts, session = st.session, here = Router.href st.router st.route, router = st.router} FromAccount)
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
              {% if isJust st.session.user %}
                <li class="user-menu-account">
                  <button type="button" class="demo-account-toggle" onClick={{ const ToggleDemoAccount }}>Your account…</button>
                </li>
                <li class="user-menu-assistant">
                  <a class="assistant-settings-entry" {{ Router.linkProps st.router Followed AssistantSettings }}>Assistant</a>
                </li>
              {% end %}
            </ul>
          {% end %}
          {% if st.demoAccountOpen && isJust st.session.user %}
            <section class="account-panel demo-account-panel" aria-label="Your account">
              <h2>Your account</h2>
              <p class="account-note">The demo has no passwords: you switch between its users above.</p>
              {{ HH.slot_ "part" DemoAccountSlot SecurityView.component () }}
              <section class="account-notifications" aria-label="Notifications">
                <h3>Notifications</h3>
                {{ HH.slot_ "part" DemoNotificationsSlot NotificationSettingsView.component () }}
              </section>
              <div class="actions">
                <button type="button" onClick={{ const ToggleDemoAccount }}>Close</button>
              </div>
            </section>
          {% end %}
        </div>
      |]

    -- The administration of the wiki, for someone who may administer it.
    -- Anyone else is told whom it is for, and in the demo how to become
    -- one.
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
              {{ HH.slot "view" AccessSlot AccessView.component AccessView.Input {context = context st} FromView }}
              {{ HH.slot "view" ServerSlot ServerView.component ServerView.Input {context = context st} FromView }}
              {{ HH.slot "view" PeopleSlot AdminView.component AdminView.Input {context = context st} FromView }}
              {{ HH.slot_ "part" ActivitySlot ActivityView.component ActivityView.Input {context = context st} }}
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
    -- downloads under the file name the server gives, and the import, which
    -- merges another wiki's pages into it, from an export or from the
    -- demo's data in this browser.
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
        importer migration = HH.slot "view" ImporterSlot ImportView.component ImportView.Input {migration} FromView

    -- The demo's content as a whole: whether it is saved, exporting it,
    -- importing one, and resetting it; the last two ask for confirmation
    -- first, in place.
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

    -- Inside a space, that space alone; elsewhere, the spaces.
    sidebar :: State m -> H.ComponentHTML Action Slots m
    sidebar st = case st.here of
      InSpace _ space pages -> spaceSidebar st space pages
      _ -> spacesSidebar st

    spacesSidebar :: State m -> H.ComponentHTML Action Slots m
    spacesSidebar st =
      [hh|
        <nav class="wiki-sidebar" aria-label="Spaces">
          <h2>Spaces</h2>
          <ul class="sidebar-spaces">
            {% for x in subspacesOf st.spaces Nothing %}
              <li>{{ spaceEntry st x }}</li>
            {% end %}
          </ul>
          {{ newSpace st "new-space-link" }}
        </nav>
      |]

    -- A space in a list of spaces, with its icon: a link to it, unless the
    -- user may not view it.
    spaceEntry :: State m -> Space -> H.ComponentHTML Action Slots m
    spaceEntry st x
      | mayView (context st) x.id =
          [hh|<a class="space-link" {{ Router.linkProps st.router Followed (Space (spacePathOf st.spaces x.id)) }}>{{ spaceIcon st.icons x }}<span>{{ x.name }}</span></a>|]
      | otherwise =
          [hh|<span class="space-link unviewable" title="You can see only a subspace of this space">{{ spaceIcon st.icons x }}<span>{{ x.name }}</span></span>|]

    -- The space the route is in, and nothing else of the wiki except links
    -- to the rest of it.
    spaceSidebar :: State m -> Space -> [PageSummary] -> H.ComponentHTML Action Slots m
    spaceSidebar st space pages =
      [hh|
        <nav class="wiki-sidebar space-sidebar" aria-label="Space">
          <div class="space-switcher">
            <a class="all-spaces" {{ Router.linkProps st.router Followed Home }}>All spaces</a>
            <button
              type="button"
              class="space-switcher-toggle"
              aria-expanded={{ ariaBool st.switcherOpen }}
              aria-label="Switch to another space"
              onClick={{ const ToggleSwitcher }}
            >
              Switch space
            </button>
            {% if st.switcherOpen %}
              <ul class="space-switcher-menu">
                {% for x in switchable %}
                  <li>
                    <a
                      class="space-switcher-option"
                      {{ [attr "aria-current" "true" | Just x.id == ((\t -> t.id) <$> top)] }}
                      {{ Router.linkProps st.router Followed (Space (spacePathOf st.spaces x.id)) }}
                    >
                      {{ spaceIcon st.icons x }}<span>{{ pathName x }}</span>
                    </a>
                  </li>
                {% end %}
              </ul>
            {% end %}
          </div>
          <a class="sidebar-space" {{ [attr "aria-current" "page" | entering] }} {{ Router.linkProps st.router Followed (Space path) }}>
            {{ spaceIcon st.icons space }}<span class="sidebar-space-name">{{ space.name }}</span>
          </a>
          {% for up in maybeToList above %}
            <a class="sidebar-up" {{ Router.linkProps st.router Followed (Space (spacePathOf st.spaces up.id)) }}>{{ "Up to " <> up.name }}</a>
          {% end %}
          <ul class="sidebar-links">
            {% for h in maybeToList (homeOf space pages) %}
              <li><a class="space-home-link" {{ [attr "aria-current" "page" | entering] }} {{ Router.linkProps st.router Followed (Space path) }}>{{ h.title }}</a></li>
            {% end %}
            <li><a class="space-pages-link" {{ [attr "aria-current" "page" | st.route == SpacePages path] }} {{ Router.linkProps st.router Followed (SpacePages path) }}>Pages and settings</a></li>
          </ul>
          <h2>Pages</h2>
          {% if null tree %}
            <p class="empty">No pages yet.</p>
          {% else %}
            {{ pageTree st.router Followed path space.pageOrder tree ((\p -> p.id) <$> currentPage st) (\_ _ _ -> []) }}
          {% end %}
          {% if not (null templates) %}
            <h2>Templates</h2>
            <ul class="sidebar-templates">
              {% for t in templates %}
                <li class="page-node{% if Just t.id == here %} current{% end %}">
                  <a {{ [attr "aria-current" "page" | Just t.id == here] }} {{ Router.linkProps st.router Followed (Page path (pagePathOf pages t.id)) }}>{{ t.title }}</a>
                </li>
              {% end %}
            </ul>
          {% end %}
          {% if not (null subspaces) %}
            <h2>Subspaces</h2>
            <ul class="sidebar-subspaces">
              {% for x in subspaces %}<li>{{ spaceEntry st x }}</li>{% end %}
            </ul>
          {% end %}
        </nav>
      |]
      where
        ctx = context st
        path = spacePathOf st.spaces space.id
        entering = st.route == Space path || isPosts st.route
        isPosts = \case
          Posts p _ -> p == path
          _ -> False
        subspaces = subspacesOf st.spaces (Just space.id)
        -- The space's templates are listed apart from its tree.
        tree = treePages pages
        templates = templatePages pages
        here = (\p -> p.id) <$> currentPage st
        -- The space this one is under, if the user may go there.
        above = space.parent >>= \p -> find (\x -> x.id == p && mayView ctx x.id) st.spaces
        -- The spaces to switch to: each space the user may view that is
        -- under no space they may view. Those are the top-level spaces,
        -- except where the user sees only a subspace.
        switchable = [x | x <- subspacesInTree, mayView ctx x.id, not (any (mayView ctx . (\a -> a.id)) (drop 1 (reverse (chainOf ctx x.id))))]
        subspacesInTree = concatMap (\r -> r : descendants r) (subspacesOf st.spaces Nothing)
        descendants x = concatMap (\c -> c : descendants c) (subspacesOf st.spaces (Just x.id))
        top = find (\x -> descendsFrom st.spaces x.id space.id) switchable
        pathName x = mconcat (intersperse " / " (map (\c -> c.name) (chainOf ctx x.id)))

    -- A link to a new space at the top level, for someone who may make one.
    newSpace :: State m -> Text -> Maybe (H.ComponentHTML Action Slots m)
    newSpace st cls =
      guard (mayCreateSpace (principalOf (context st)) st.session.grants Nothing)
        $> [hh|<a class="{{ cls }}" {{ Router.linkProps st.router Followed (NewSpace Nothing) }}>New space</a>|]

    content :: State m -> H.ComponentHTML Action Slots m
    content st = case (st.world, st.route) of
      (WorldLoading, _) -> loading
      (WorldFailed e, _) -> failureView e RetryWorld
      (WorldReady, route) -> routeContent st route

    routeContent :: State m -> Route -> H.ComponentHTML Action Slots m
    routeContent st = \case
      Home -> HH.slot "view" DirectorySlot DirectoryView.component DirectoryView.Input {context = context st, welcome = st.welcome} FromView
      Unknown -> notFound st
      Admin -> admin st
      NewSpace parent -> HH.slot "view" NewSpaceSlot NewSpaceView.component NewSpaceView.Input {context = context st, parent} FromView
      Search text space subspaces ->
        HH.slot "view" SearchResultsSlot SearchResultsView.component SearchResultsView.Input {context = context st, text, space, subspaces} FromView
      Invite token -> HH.slot "invite" () InviteView.component InviteView.Input {accounts = st.accounts, token, session = st.session, home = Router.href st.router Home} FromInvite
      ResetPassword token -> HH.slot "reset" () ResetView.component ResetView.Input {accounts = st.accounts, token, session = st.session} FromReset
      VerifyEmail token -> HH.slot_ "part" VerifyEmailSlot VerifyEmailView.component VerifyEmailView.Input {accounts = st.accounts, token}
      Unsubscribe token -> HH.slot_ "part" UnsubscribeSlot UnsubscribeView.component UnsubscribeView.Input {token}
      AssistantSettings -> HH.slot_ "part" AssistantSettingsSlot AssistantSettingsView.component AssistantSettingsView.Input {context = context st}
      _ -> case st.here of
        NoSpace -> notFound st
        LoadingSpace _ -> loading
        SpaceFailed _ e -> failureView e RetryHere
        InSpace _ space pages -> case st.route of
          -- Entering a blog shows its posts, at the requested page of them.
          Space _ | space.blog -> blogView space pages 1
          Posts _ n | space.blog -> blogView space pages n
          -- Entering a space shows its home page, if it has one, at any
          -- requested page of posts.
          Space _ | Just home <- homeOf space pages -> pageView space pages (pagePathOf pages home.id)
          Posts _ _ | Just home <- homeOf space pages -> pageView space pages (pagePathOf pages home.id)
          Page _ path -> pageView space pages path
          PageSource _ path -> HH.slot "view" SourceSlot SourceView.component SourceView.Input {context = context st, space, path} FromView
          PageHistory _ path version against ->
            HH.slot "view" HistorySlot HistoryView.component HistoryView.Input {context = context st, space, path, version, against} FromView
          PageSlides _ path slide ->
            HH.slot "view" SlidesSlot SlidesView.component SlidesView.Input {context = context st, space, pages, path, slide} FromView
          -- One editor per page edited: another page's editor is a
          -- separate component, with its own draft.
          EditPage _ path -> HH.slot "editor" path Editor.component Editor.Input {context = context st, space, pages, path, feed = st.feed} FromView
          NewPage _ parent -> HH.slot "view" NewPageSlot NewPageView.component NewPageView.Input {context = context st, space, pages, parent} FromView
          _ -> HH.slot "view" SpaceSlot SpaceView.component SpaceView.Input {context = context st, space, pages} FromView
      where
        pageView space pages path = HH.slot "view" PageSlot PageView.component PageView.Input {context = context st, space, pages, path, feed = st.feed} FromView
        blogView space pages page = HH.slot "view" BlogSlot BlogView.component BlogView.Input {context = context st, space, pages, page} FromView

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
        -- Made in 'H.liftEffect', before anything here waits, so that the
        -- shell listens to the browser from the moment it has started.
        whenM (gets overNetwork) $ do
          connection <- H.liftEffect Window.online
          void $ H.subscribe (Online <$> connection)
          -- A page the service worker served from its stored copy was served
          -- that way because the wiki could not be reached, whatever the
          -- browser says about its network.
          copy <- H.liftEffect offlineCopy
          online <- H.liftEffect browserOnline
          modify (\st -> st {offlineCopy = copy, offline = isJust copy || not online})
        installs <- H.liftEffect installChanges
        void $ H.subscribe (InstallChanged <$ installs)
        handleAction InstallChanged
        router <- gets (\st -> st.router)
        void $ H.subscribe (Arrived <$> Router.changes router)
        gets (\st -> st.accounts) >>= traverse_ (\a -> lift a.sessionChanges >>= void . H.subscribe . fmap SessionChanged)
        entry <- H.liftEffect historyEntry
        modify (\st -> st {entry})
        -- The bars that stick under the header need its height, and the
        -- lists of a page's headings highlight the section being read.
        H.liftEffect keepHeights
        H.liftEffect keepContents
        -- What the route shows was loaded in the initial state, unless the
        -- backend would have waited for it.
        gets (\st -> st.world) >>= \case
          WorldReady -> announce
          _ -> loadEverything
      RetryWorld -> do
        modify (\st -> st {world = WorldLoading})
        loadEverything
      RetryHere -> loadHere True
      Online False -> modify (\st -> st {offline = True})
      -- Back online: whatever failed to load because the server could not
      -- be reached is loaded again, as "Try again" would. A view whose own
      -- load failed keeps its own button.
      Online True -> do
        modify (\st -> st {offline = False})
        st <- get
        case (st.world, st.here) of
          (WorldFailed (Unreachable _), _) -> handleAction RetryWorld
          (WorldReady, SpaceFailed _ (Unreachable _)) -> handleAction RetryHere
          _ -> pass
      InstallChanged -> do
        installable <- H.liftEffect installAvailable
        modify (\st -> st {installable})
      -- The browser asks the reader; its offer is used up either way.
      Install -> do
        void install
        handleAction InstallChanged
      Arrived r -> do
        now <- H.liftEffect historyEntry
        before <- gets (\st -> st.route)
        if r == before
          then -- The route shown, at an entry of its own: one the shell
          -- pushed itself after a change ('reload'), or the editor's entry,
          -- gone back to after staying.
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
        -- The address is that of the route not followed. Going back to the
        -- editor's entry leaves the history as the browser's buttons
        -- would, with the route not followed ahead of it; the router
        -- announces the route already shown. Without a number for that
        -- entry (there is none natively), the editor's address replaces
        -- the other.
        now <- H.liftEffect historyEntry
        if st.entry /= now
          then H.liftEffect (historyGo (st.entry - now))
          else Router.redirect st.router st.route
      Followed f -> gets (\st -> st.router) >>= (`Router.follow` f)
      ToggleSwitcher -> modify (\st -> st {switcherOpen = not st.switcherOpen})
      ToggleMenu -> modify (\st -> st {menuOpen = not st.menuOpen})
      -- The questions and results about the wiki's data were for the user
      -- one was before switching, so they are cleared.
      SwitchTo user -> withDemo $ \demo -> do
        modify (\st -> st {menuOpen = False, demoAccountOpen = False, panel = Actions Nothing, settled = False})
        lift (demo.switchTo user)
        reload Nothing
      AskReset -> modify (\st -> st {panel = ConfirmingReset})
      CancelPanel -> modify (\st -> st {panel = Actions Nothing})
      -- The route stays on the administration, which says what was done,
      -- since nothing else there shows it.
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
      -- The file is read and checked in full before anything is asked:
      -- what cannot be imported is refused here, with the reason.
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
      FromView (Showing page) -> modify (\st -> st {shown = Just page})
      -- Someone signed in or out: reload everything, as the new user.
      FromAccount (SignInView.AccountChanged s) -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        restartFeed
        reload Nothing
      -- The session ended by itself (or changed elsewhere): reload
      -- everything as the current user, and if that is nobody, show the way
      -- to sign in again, saying why.
      SessionChanged s -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        restartFeed
        reload Nothing
        when (isNothing s.user) $
          H.tell "signIn" () (SignInView.Prompt "Your session has ended. Sign in again to go on.")
      OpenSignIn -> H.tell "signIn" () (SignInView.Prompt "Sign in with your login and password.")
      -- An invitation created its account and signed the new user in: the
      -- wiki as them, from its front page.
      FromInvite (InviteView.Accepted s) -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        restartFeed
        reload (Just Home)
      -- A password set through a reset link: the sign-in form, to use it.
      FromReset ResetView.SignInWanted -> H.tell "signIn" () (SignInView.Prompt "Sign in with your new password.")
      ToggleDemoAccount -> modify (\st -> st {demoAccountOpen = not st.demoAccountOpen, menuOpen = False})

    -- Open the live channel again, as the current user.
    restartFeed :: H.HalogenM (State m) Action Slots output m ()
    restartFeed = gets (\st -> st.feed) >>= traverse_ (\f -> H.liftEffect (liftIO f.restart))

    -- Run something only the demo has, which nothing offers without it.
    withDemo :: (Demo m -> H.HalogenM (State m) Action Slots output m ()) -> H.HalogenM (State m) Action Slots output m ()
    withDemo f = gets (\st -> st.demo) >>= traverse_ f

    -- Load everything the route shows, which the initial state could not
    -- have without waiting.
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
      -- Before the new route renders: its views fetch the page content
      -- they show, rather than read what the server prerendered the first
      -- route with.
      lift endPreload
      -- The questions and results about the wiki's data are not shown
      -- again on coming back to the administration.
      modify (\st -> st {route = r, settled = False, menuOpen = False, switcherOpen = False, panel = Actions Nothing, leaving = Nothing, entry, offlineCopy = Nothing})
      loadHere False

    -- After a change: reload everything, and every view's own data too.
    reload :: Maybe Route -> H.HalogenM (State m) Action Slots output m ()
    reload next = do
      -- Going to another route after the change ends the preload, as
      -- 'arrive' does.
      when (isJust next) (lift endPreload)
      loadWorld
      modify (\st -> st {generation = st.generation + 1})
      for_ next $ \r -> modify (\st -> st {route = r, settled = False, leaving = Nothing})
      loadHere True
      -- The router is told last, so that the route it announces is the one
      -- already shown, which 'Arrived' ignores.
      router <- gets (\st -> st.router)
      for_ next (Router.navigate router)

    -- Load who is signed in and the tree of spaces, on a worker thread. If
    -- they cannot be loaded, the route's content says why, with a button
    -- to try again.
    loadWorld :: H.HalogenM (State m) Action Slots output m ()
    loadWorld = do
      demo <- gets (\st -> st.demo)
      lift (attempt (fetchWorld demo)) >>= \case
        Right w -> modify (\st -> st {session = w.asking, users = w.users, spaces = w.spaces, icons = w.icons, kept = w.kept, world = WorldReady})
        Left e -> modify (\st -> st {world = WorldFailed e})

    -- Load the space the route is in, unless it is the one loaded already
    -- (or even then, if forced).
    loadHere :: Bool -> H.HalogenM (State m) Action Slots output m ()
    loadHere again = do
      st <- get
      case spaceOfRoute st.route of
        _ | shutOut st.session -> modify (\s -> s {here = NoSpace})
        Nothing -> modify (\s -> s {here = NoSpace})
        Just path
          | not again, hereIs path st.here -> pass
          | otherwise -> do
              -- Reloading the space being shown keeps it on screen
              -- meanwhile.
              unless (hereIs path st.here) $ modify (\s -> s {here = LoadingSpace path})
              result <- fetchHere path
              -- Unless the route has moved to another space meanwhile.
              now <- gets (\s -> s.route)
              when (spaceOfRoute now == Just path) $
                modify (\s -> s {here = result})
      announce

    -- Set the document's title for what is shown, and say whether all of
    -- it has loaded. A page's view, or the editor, says when it has loaded
    -- the page, and the search results when they have arrived; everything
    -- else is loaded by now.
    announce :: H.HalogenM (State m) Action Slots output m ()
    announce = do
      st <- get
      H.liftEffect (setDocumentTitle (documentTitle st))
      -- A space shown counts as visited, for the directory to offer again.
      case st.here of
        InSpace _ space _ -> H.liftEffect (rememberVisit space.id)
        _ -> pass
      unless (waitsForPage st) settle

    settle :: H.HalogenM (State m) Action Slots output m ()
    settle = modify (\st -> st {settled = True})

    handleQuery :: Query a -> H.HalogenM (State m) Action Slots output m (Maybe a)
    handleQuery (Settled reply) = do
      st <- get
      pure (Just (reply (if st.settled then Just (headOf st) else Nothing)))

-- | The context every route shows: who is signed in, who else one may be
-- in the demo, the tree of spaces, the URLs of the spaces' icon images,
-- and whether the demo saves its changes.
data Around = Around
  { asking :: Session
  , users :: [User]
  , spaces :: [Space]
  , icons :: Map SpaceId Text
  , kept :: Bool
  }

-- | Load 'Around'.
--
-- A closed wiki has no spaces to show someone who has not signed in, so
-- they are not requested.
fetchWorld :: (MonadWiki n) => Maybe (Demo n) -> n Around
fetchWorld demo = do
  asking <- session
  users <- maybe (pure []) (\d -> d.listUsers) demo
  spaces <- if shutOut asking then pure [] else listSpaces
  icons <- Map.fromList <$> sequence [(x.id,) <$> spaceIconUrl x | x <- spaces, Just (IconImage _ _) <- [x.icon]]
  kept <- maybe (pure False) (\d -> d.demoKept) demo
  pure Around {asking, users, spaces, icons, kept}

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

-- | Whether the wiki is reached over the network: true on the HTTP
-- backend, which is the one people sign in to, and false on the demo's,
-- which keeps its wiki in the browser.
overNetwork :: State m -> Bool
overNetwork st = isJust st.accounts

-- | Whether the shell shows the closed wiki's frame: the wiki is closed to
-- the current user, and the route is not the page of a mailed link.
isShut :: State m -> Bool
isShut st = st.world == WorldReady && shutOut st.session && not (isMailedLink st.route)

-- | Whether a route is the page of a link mailed to someone who may not be
-- able to sign in yet: an invitation, a password reset, an address
-- verification, or a notification mail's unsubscribe link. A closed wiki
-- shows them all the same.
isMailedLink :: Route -> Bool
isMailedLink = \case
  Invite _ -> True
  ResetPassword _ -> True
  VerifyEmail _ -> True
  Unsubscribe _ -> True
  _ -> False

-- | Whether the user may administer the wiki as a whole, and so is shown
-- the administration.
isAdministrator :: State m -> Bool
isAdministrator st = hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer
  where
    ctx = context st

context :: State m -> Context
context st = Context {router = st.router, session = st.session, spaces = st.spaces, icons = st.icons, revision = st.generation}

spaceOfRoute :: Route -> Maybe [Slug]
spaceOfRoute = \case
  Space path -> Just path
  Posts path _ -> Just path
  SpacePages path -> Just path
  Page path _ -> Just path
  EditPage path _ -> Just path
  PageSource path _ -> Just path
  PageHistory path _ _ _ -> Just path
  PageSlides path _ _ -> Just path
  NewPage path _ -> Just path
  _ -> Nothing

hereIs :: [Slug] -> Here -> Bool
hereIs path = \case
  InSpace p _ _ -> p == path
  SpaceFailed p _ -> p == path
  LoadingSpace p -> p == path
  NoSpace -> False

waitsForPage :: State m -> Bool
waitsForPage st = case (st.route, st.here) of
  -- The closed frame shows no view that could report having loaded.
  _ | isShut st -> False
  -- The directory says when it has counted the spaces' pages.
  (Home, _) -> st.world == WorldReady
  -- A space's own route shows its posts, if it is a blog, or its home
  -- page, if it has one.
  (Space _, InSpace _ space pages) -> space.blog || isJust (homeOf space pages)
  (Posts _ _, InSpace _ space pages) -> space.blog || isJust (homeOf space pages)
  (Page _ _, InSpace {}) -> True
  (EditPage _ _, InSpace {}) -> True
  (PageSource _ _, InSpace {}) -> True
  (PageHistory {}, InSpace {}) -> True
  (PageSlides {}, InSpace {}) -> True
  (Search {}, _) -> True
  _ -> False

currentPageOf :: [PageSummary] -> [Slug] -> Maybe PageSummary
currentPageOf pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

currentPage :: State m -> Maybe PageSummary
currentPage st = case (st.route, st.here) of
  (Space _, InSpace _ space pages) -> homeOf space pages
  (Posts _ _, InSpace _ space pages) -> homeOf space pages
  (Page _ path, InSpace _ _ pages) -> currentPageOf pages path
  (EditPage _ path, InSpace _ _ pages) -> currentPageOf pages path
  (PageSource _ path, InSpace _ _ pages) -> currentPageOf pages path
  (PageHistory _ path _ _, InSpace _ _ pages) -> currentPageOf pages path
  (PageSlides _ path _, InSpace _ _ pages) -> currentPageOf pages path
  _ -> Nothing

-- | The breadcrumbs: inside a space, the directory of spaces first, then
-- 'crumbs'.
trail :: State m -> [(Text, Maybe Route)]
trail st = [("Spaces", Just Home) | isJust (spaceOfRoute st.route), st.world == WorldReady, not (isShut st)] <> crumbs st

-- | The title for the route, as far as it has been loaded.
crumbs :: State m -> [(Text, Maybe Route)]
crumbs st = case st.route of
  -- The same at every address until there is something to name.
  _ | st.world /= WorldReady -> []
  _ | isShut st -> [("Sign in", Nothing)]
  Invite _ -> [("Invitation", Nothing)]
  ResetPassword _ -> [("New password", Nothing)]
  VerifyEmail _ -> [("E-mail address", Nothing)]
  Unsubscribe _ -> [("Notification mail", Nothing)]
  Home -> []
  Space path -> spaceCrumbs path
  Posts path n -> spaceCrumbs path <> [("Page " <> show n, Nothing)]
  SpacePages path -> spaceCrumbs path <> [("Pages and settings", Nothing)]
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
  PageSlides path pagePath _ ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("Slides", Nothing) | not (null page)]
  NewPage path parent -> spaceCrumbs path <> foldMap (pageCrumbs path) parent <> [("New page", Nothing)]
  NewSpace parent -> foldMap spaceCrumbs parent <> [("New space", Nothing)]
  Unknown -> [("Not found", Nothing)]
  Search {} -> [("Search", Nothing)]
  Admin -> [("Administration", Nothing)]
  AssistantSettings -> [("Writing assistant", Nothing)]
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
  -- A space that cannot be shown has no name to show either: the content
  -- in its place says why.
  [] -> case st.here of
    SpaceFailed _ Forbidden -> "Private · Wiki"
    SpaceFailed _ NotFound -> "Not found · Wiki"
    _ -> "Wiki"
  names -> mconcat (intersperse " · " (take 2 names)) <> " · Wiki"

-- | What the page says about itself ("Wiki.App.Head"): its title; for a
-- public page in a space (the space's own route, a page of its posts, or a
-- page), what a link preview shows; and on every page of a public blog,
-- where its feeds are.
headOf :: State m -> Head
headOf st = Head {title = documentTitle st, preview, feeds}
  where
    ctx = context st
    public space = canView Nothing st.session.grants (chainOf ctx space.id)
    href = Router.href st.router
    feeds = case st.here of
      InSpace path space _
        | space.blog
        , public space
        , isJust (spaceOfRoute st.route) ->
            Just Feeds {address = href (Space path), name = space.name}
      _ -> Nothing
    preview = case (st.route, st.here) of
      _ | isShut st -> Nothing
      (Space path, InSpace _ space pages) | public space -> Just (ofSpace path space pages)
      (Posts path _, InSpace _ space pages) | public space -> Just (ofSpace path space pages)
      (Page path pagePath, InSpace _ space pages)
        | public space
        , Just p <- currentPageOf pages pagePath >>= shownPage ->
            Just (ofPage space p (href (Page path pagePath)))
      _ -> Nothing
    -- The page shown, with its body, if it is the page named.
    shownPage named = mfilter (\p -> p.id == named.id) st.shown
    -- A space's own route: a blog, or a space without a home page, is
    -- described by its description; a space that opens at its home page is
    -- described as that page, at the space's address, its description
    -- first.
    ofSpace path space pages = case homeOf space pages >>= shownPage of
      Just home
        | not space.blog ->
            let p = ofPage space home (href (Space path))
             in Preview
                  { title = space.name
                  , description = if T.null space.description then p.description else space.description
                  , url = p.url
                  , kind = "website"
                  , image = p.image
                  }
      _ ->
        Preview
          { title = space.name
          , description = space.description
          , url = href (Space path)
          , kind = "website"
          , image = spaceImage space
          }
    ofPage space p url =
      let blocks = either (const []) identity (parseMarkdown p.body)
          said = excerpt blocks
       in Preview
            { title = p.title
            , description = if T.null said then space.description else said
            , url
            , kind = "article"
            , image = (firstImage blocks >>= imageOf p) <|> spaceImage space
            }
    imageOf p destination = case classifyDestination destination of
      ToUrl url | "http://" `T.isPrefixOf` url || "https://" `T.isPrefixOf` url -> Just (WebImage url)
      ToAttachment name -> AttachedImage <$> findAttachment name p.attachments
      _ -> Nothing
    spaceImage space = case space.icon of
      Just (IconImage _ _) -> Just (SpaceImage space)
      _ -> Nothing

-- | How much an archive holds, in words for a person to read.
archiveSummary :: Archive -> Text
archiveSummary a =
  T.intercalate
    ", "
    [ counted (length a.users) "user" "users"
    , counted (length a.spaces) "space" "spaces"
    , counted (length a.pages) "page" "pages"
    , counted (sum [length p.attachments | p <- a.pages]) "attachment" "attachments"
    , counted (sum [length t.comments | ts <- Map.elems a.threads, t <- ts]) "comment" "comments"
    ]
  where
    counted :: Int -> Text -> Text -> Text
    counted n singular plural = show n <> " " <> if n == 1 then singular else plural
