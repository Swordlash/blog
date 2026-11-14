{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE QuasiQuotes #-}

-- | The shell: the application's frame around whatever the route shows.
-- It has a header with the site's name, breadcrumbs, the search box
-- ("Wiki.App.View.Search"), a link to the administration for an
-- administrator, the signed-in user's starred pages
-- ("Wiki.App.View.Starred"), and the demo's user switcher; a sidebar; the
-- content of the route; a footer saying what the wiki is built with; and
-- the help button in a corner ("Wiki.App.View.Help").
--
-- The front page is the directory of spaces ("Wiki.App.View.Directory").
-- Inside a space (any route under @\/s\/\<space>@) the sidebar shows that
-- space alone, as Confluence does: its icon and name, a link back to the
-- directory and a menu of the other spaces to switch to, a link up to its
-- parent space, its home page and its list of pages, its pages as a tree,
-- the pages that link to the page shown, under "Linked from" (issue #189,
-- 'Wiki.App.Backend.pageBacklinks'), its templates
-- ('Wiki.Core.Page.template') apart from the tree, and its subspaces below
-- them. Elsewhere the sidebar lists the spaces. A space's
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
-- The administration ('Admin') is a page per section (WP5.25 of
-- docs/PLAN.md): the sidebar becomes the administration's navigation, an
-- entry per section with the current one marked, and the content is the
-- section's heading and its view, mounted alone, with its own loading and
-- errors. The address @\/admin\/@ names no section: it shows the first,
-- and the shell puts that section's address in its place. The wiki's data
-- as one file (export, import, the demo's reset) acts on the whole wiki and
-- on how the demo saves it, which the shell holds and reloads afterwards.
-- So those controls and their state stay here, and the "Backups and data"
-- section shows them under the backups.
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
-- unsaved changes: an editor's, or the ticks of a page's tasks not saved
-- yet ("Wiki.App.View.Page"). It asks the editor ('Editor.IsDirty') and
-- the view ('HasUnsaved') and, if something would be lost, asks the reader
-- in place whether to leave. By then the browser's address is already the new route's (a link
-- was followed, or the back button pressed). So staying goes back through
-- the session history to the editor's entry, by as many entries as lie in
-- between ('historyEntry' numbers them), as the browser's buttons would.
-- For the same reason a reload of the wiki or of the space that fails
-- while the content has unsaved changes does not put its failure in the
-- content's place, which would unmount it: the content stays, and a line
-- above it says the reload failed, with a button to try again ('stale').
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
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (inBrowser)
import Halogen.Query.Event.Window qualified as Window
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Api.Links (archiveExportUrl)
import Wiki.Api.ServerSettings (HomePage (showAnonymous, title))
import Wiki.App.Account (Accounts (..))
import Wiki.App.Assistant (MonadAssistant, announceSignIn, keysDroppedElsewhere, listenToOtherTabs)
import Wiki.App.Assistant.Sync (MonadVault)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), anonymous, sameAsking, shutOut)
import Wiki.App.Backend.Admin (MonadAdmin)
import Wiki.App.Backend.Comments (MonadComments)
import Wiki.App.Backend.Encrypted (MonadEncryption (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Backend.Stars (MonadStars)
import Wiki.App.Backend.WhatsNew (MonadWhatsNew)
import Wiki.App.Browser (download, historyEntry, historyGo, keepContents, keepHeights, redirectKeepingFragment, replacingEntry, revealFragment, setDocumentTitle, setFavicon, unzipFiles, zipFiles)
import Wiki.App.DemoUsers (Demo (..))
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, onPreviewEntry, pickedFiles, readPickedFile)
import Wiki.App.Favicon (Favicon (..), defaultFavicon, homeFavicon, spaceFavicon)
import Wiki.App.Head (Feeds (..), Head (..), Preview (..), PreviewImage (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Live (Feed (..), Live (..))
import Wiki.App.Offline (browserOnline, install, installAvailable, installChanges, offlineCopy)
import Wiki.App.Recent (rememberVisit)
import Wiki.App.Route (AdminSection, Route (..), adminSections, locationRoute, sectionName, sectionTitle, settledRoute)
import Wiki.App.Route qualified as R
import Wiki.App.Security (MonadSecurity)
import Wiki.App.Vault (forgetEveryUsersKeys, forgetUserKeys)
import Wiki.App.View.Access qualified as AccessView
import Wiki.App.View.Activity qualified as ActivityView
import Wiki.App.View.AssistantSettings qualified as AssistantSettingsView
import Wiki.App.View.Avatar qualified as AvatarView
import Wiki.App.View.Backups qualified as BackupsView
import Wiki.App.View.Bell qualified as BellView
import Wiki.App.View.Blog qualified as BlogView
import Wiki.App.View.Common
import Wiki.App.View.Directory qualified as DirectoryView
import Wiki.App.View.Editor qualified as Editor
import Wiki.App.View.EditorSettings qualified as EditorSettingsView
import Wiki.App.View.Encrypted qualified as EncryptedView
import Wiki.App.View.Groups qualified as GroupsView
import Wiki.App.View.Help qualified as HelpView
import Wiki.App.View.History qualified as HistoryView
import Wiki.App.View.Import qualified as ImportView
import Wiki.App.View.Invite qualified as InviteView
import Wiki.App.View.LivePreview qualified as LivePreviewView
import Wiki.App.View.NewPage qualified as NewPageView
import Wiki.App.View.NewSpace qualified as NewSpaceView
import Wiki.App.View.NotificationSettings qualified as NotificationSettingsView
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.PersonalSpace qualified as PersonalSpaceView
import Wiki.App.View.Popup (watchPopup)
import Wiki.App.View.Reset qualified as ResetView
import Wiki.App.View.Search qualified as SearchBox
import Wiki.App.View.SearchResults qualified as SearchResultsView
import Wiki.App.View.Security qualified as SecurityView
import Wiki.App.View.Server qualified as ServerView
import Wiki.App.View.SignIn qualified as SignInView
import Wiki.App.View.Slides qualified as SlidesView
import Wiki.App.View.Source qualified as SourceView
import Wiki.App.View.Space qualified as SpaceView
import Wiki.App.View.Starred qualified as StarredView
import Wiki.App.View.Status qualified as StatusView
import Wiki.App.View.Unsubscribe qualified as UnsubscribeView
import Wiki.App.View.UserSpaces qualified as UserSpacesView
import Wiki.App.View.Users qualified as UsersView
import Wiki.App.View.VerifyEmail qualified as VerifyEmailView
import Wiki.App.View.WhatsNew qualified as WhatsNewView
import Wiki.Core.Attachment (findAttachment)
import Wiki.Core.Backlink (Backlink (..))
import Wiki.Core.Blog (excerpt, firstImage)
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Export (Archive (..), readArchive, withoutHomeDocument, writeArchive)
import Wiki.Core.Id (PageId, SpaceId, UserId)
import Wiki.Core.Markdown (Destination (..), classifyDestination, parseMarkdown)
import Wiki.Core.Offered qualified as Offered
import Wiki.Core.Page (Page (attachments, body, id, title), PageSummary (id, title), summaryOf, templatePages, treePages)
import Wiki.Core.Path (PathError (..), findChild, resolvePath)
import Wiki.Core.Permission (GlobalPermission (Administer), canView, hasGlobalPermission, mayCreateSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Icon (..), Space (blog, description, encryption, icon, id, name, parent, personalContainer), containerName, pageAt, pagesAt, rootPage, subspacesOf)
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Login (..), User (..))

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
    '[ "editor" :-> H.Slot Editor.Query ViewOutput (SpaceId, [Slug])
     , "invite" :-> H.Slot (Const Void) InviteView.Output ()
     , "part" :-> H.Slot (Const Void) Void PartSlot
     , "reset" :-> H.Slot (Const Void) ResetView.Output ()
     , "signIn" :-> H.Slot SignInView.Query SignInView.Output ()
     , "view" :-> H.Slot ViewQuery ViewOutput ViewSlot
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
  | LivePreviewSlot
  | HistorySlot
  | SlidesSlot
  | NewSpaceSlot
  | NewPageSlot
  | SearchResultsSlot
  | ImporterSlot
  | AccessSlot
  | ServerSlot
  | EditorSettingsSlot
  | UsersSlot
  | GroupsSlot
  | StatusSlot
  | PersonalSpaceSlot
  | AvatarSlot
  | EncryptedSlot
  deriving stock (Eq, Ord)

-- | 'PartSlot' is the index of a child under the label "part". The output
-- type of these children is 'Void': the shell gets nothing from them.
data PartSlot
  = SearchBoxSlot
  | BellSlot
  | StarredSlot
  | HelpSlot
  | OfflineCopySlot
  | DemoAccountSlot
  | DemoNotificationsSlot
  | ActivitySlot
  | BackupsSlot
  | VerifyEmailSlot
  | UnsubscribeSlot
  | AssistantSettingsSlot
  | WhatsNewSlot
  | UserSpacesSlot
  deriving stock (Eq, Ord)

-- | The space the route is in, as far as it has been loaded.
data Here
  = NoSpace
  | LoadingSpace [Slug]
  | -- | The space's record, when it was read before its pages failed: it
    -- says whether the space is encrypted now, which the list of spaces
    -- may not say yet.
    SpaceFailed [Slug] (Maybe Space) WikiError
  | InSpace [Slug] Space [PageSummary]
  | -- | A page's permanent address ('PermanentLink'), whose page is being
    -- looked for ('Nothing'), or could not be found or reached: the
    -- reason. Once found, the page's own address replaces the permanent
    -- one ('followPermanent').
    Following PageId (Maybe WikiError)

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
  -- image, the wiki home's too.
  , avatars :: Map UserId Text
  -- ^ The URLs of the avatars of the signed-in user and of the demo's
  -- users, for those who have one: the header shows them.
  , home :: Maybe Space
  -- ^ The space behind the wiki's home page, whose icon is the wiki's
  -- ("Wiki.App.Favicon").
  , here :: Here
  , switcherOpen :: Bool
  -- ^ Whether the sidebar's menu of spaces to switch to is open.
  , switcherHolder :: H.RefLabel
  -- ^ The element that holds the space switcher's button and menu: a
  -- press outside it closes the menu ("Wiki.App.View.Popup").
  , switcherWatch :: Maybe H.SubscriptionId
  -- ^ The watch for a press outside the space switcher or Escape, while
  -- its menu is open.
  , sidebarFolded :: Bool
  , chosenWidth :: PageWidth
  -- ^ How wide pages are laid out, as this browser keeps it
  -- ('pageWidthKey').
  -- ^ Whether the sidebar is folded away on a wide screen, to give its
  -- width to the page (WP5.36 of docs/PLAN.md); the browser keeps it.
  , generation :: Int
  -- ^ The views' 'revision': how many times the wiki has been reloaded
  -- after a change.
  , menuOpen :: Bool
  -- ^ Whether the demo's menu of users is open.
  , menuHolder :: H.RefLabel
  -- ^ The element that holds the demo's user button and menu: a press
  -- outside it closes the menu.
  , menuWatch :: Maybe H.SubscriptionId
  -- ^ The watch for a press outside the user menu or Escape, while it is
  -- open.
  , demoAccountOpen :: Bool
  -- ^ Whether the demo's account panel (its one session, and the server's
  -- features shown disabled) is open.
  , panel :: Panel
  -- ^ What the administration's section on the wiki's data shows.
  , kept :: Bool
  -- ^ Whether the demo's changes are saved in the browser ('demoKept').
  , settled :: Bool
  , leaving :: Maybe (Route, Unsaved)
  -- ^ A route followed away from unsaved changes, about which the reader
  -- is being asked, and whose changes they are.
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
  , keysLooked :: Bool
  -- ^ Whether this page start has looked whether nobody is signed in, to
  -- let go of every user's keys: once a page start.
  -- ^ When the page shown was stored, if the service worker served it
  -- offline from its stored copy; kept until the reader navigates
  -- elsewhere.
  , installable :: Bool
  -- ^ Whether the browser offers to install the wiki.
  , shown :: Maybe Page
  -- ^ The page the page view last said it shows ('Showing'), with its
  -- body: the head's preview describes the page with it. The space's list
  -- of pages has no bodies.
  , backlinks :: Maybe (PageId, [Backlink])
  -- ^ The pages that link to the page the route shows, with that page's
  -- id ('backlinksOf'), for the sidebar's "Linked from"; empty when they
  -- could not be read. Loaded with the space ('loadBacklinks'), and again
  -- after every change, since a save of another page changes them.
  , seen :: Maybe Int
  -- ^ The number of the newest changelog entry the reader has seen on the
  -- page "What's new?", as this browser keeps it ('whatsNewSeenKey'): 0
  -- when they never opened it. 'Nothing' until the shell has read it,
  -- after its first render, since a page the server prerendered cannot
  -- know it; and always natively, where there is no reader's browser.
  , stale :: Maybe WikiError
  -- ^ Why the last reload of the wiki or of the space failed, when it
  -- failed while what is shown had changes not saved ('unsavedShown'):
  -- what is shown then stays, since showing the failure in its place
  -- would unmount it and lose them, and a line above it says so. The
  -- next reload that succeeds clears it.
  , droppedUnsaved :: Bool
  -- ^ Whether changes not saved to a page of an encrypted space were
  -- taken off the screen with the space ('sealScreen'): said once, until
  -- the reader dismisses it. The text is kept nowhere.
  }

-- | Whose changes a route followed away would lose ('leaving'): what the
-- question before leaving names.
data Unsaved
  = -- | An editor's text.
    EditorChanges
  | -- | The ticks of a page's tasks, made in the page view and not saved.
    PageTicks

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
  | KeysDropped
  | Followed (Follow Route)
  | ToggleSwitcher
  | CloseSwitcher
  | FoldSidebar Bool
  | ToggleMenu
  | CloseMenu
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
  | RetryStale
  | DismissDropped
  | SigningOut
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
   . (Typeable m, MonadLoad m, MonadAdmin m, MonadComments m, MonadNotifications m, MonadStars m, MonadWhatsNew m, MonadSecurity m, MonadIslands m, MonadAssistant m, MonadVault m, MonadEncryption m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m)
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
          route <- settledRoute <$> Router.current router
          -- The tab's live channel, made before any view: a page shown from
          -- the first render watches its page from its own initializer,
          -- which runs before the shell's.
          feed <- traverse (\l -> l.liveFeed) live
          loaded <- atOnce $ do
            world <- fetchWorld demo
            here <-
              if
                | shutOut world.asking && not (publicHomeRoute world.asking route) -> pure NoSpace
                | PermanentLink pid _ <- route -> lookingFor pid <$> pageLocation pid
                | otherwise -> maybe (pure NoSpace) fetchHere (spaceOfRoute route)
            pure (world, here)
          let (Around signedIn users spaces home icons avatars kept, here) = fromMaybe (Around anonymous [] [] Nothing mempty mempty False, NoSpace) loaded
          switcherHolder <- H.newRefLabel "space-switcher"
          menuHolder <- H.newRefLabel "user-switcher"
          let begun =
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
                  , home
                  , icons
                  , avatars
                  , here
                  , switcherOpen = False
                  , switcherHolder
                  , switcherWatch = Nothing
                  , sidebarFolded = False
                  , chosenWidth = Compact
                  , generation = 0
                  , menuOpen = False
                  , menuHolder
                  , menuWatch = Nothing
                  , demoAccountOpen = False
                  , panel = Actions Nothing
                  , kept
                  , settled = False
                  , leaving = Nothing
                  , entry = 0
                  , offline = False
                  , offlineCopy = Nothing
                  , keysLooked = False
                  , installable = False
                  , shown = Nothing
                  , backlinks = Nothing
                  , seen = Nothing
                  , stale = Nothing
                  , droppedUnsaved = False
                  }
          -- The page's backlinks too, if the backend has them at once, so
          -- that the sidebar's first render is the prerendered one; else
          -- 'Initialize' loads them.
          backlinks <- for (guard (isJust loaded) *> backlinksOf begun) $ \pid -> fmap (pid,) <$> atOnce (listedBacklinks pid)
          -- Made whole here, before the first render: left to the render,
          -- the demo's backend would follow every page's links in the
          -- middle of adopting the page, after the header already answers
          -- and before the page's view does.
          pure $! begun {backlinks = forced (join backlinks)}
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
          <div class="wiki-body{% if st.sidebarFolded %} sidebar-folded{% end %}">
            {{ sidebar st }}
            <button
              type="button"
              class="sidebar-fold"
              aria-label={{ if st.sidebarFolded then "Show the sidebar" else "Hide the sidebar" :: Text }}
              title={{ if st.sidebarFolded then "Show the sidebar" else "Hide the sidebar" :: Text }}
              aria-expanded={{ ariaBool (not st.sidebarFolded) }}
              onClick={{ const (FoldSidebar (not st.sidebarFolded)) }}
            >
              {{ if st.sidebarFolded then "»" else "«" :: Text }}
            </button>
            <main class="wiki-content">
              {{ offlineCopyLine st }}
              {% for why in maybeToList (conversionNotice st) %}
                <p class="conversion-notice" role="status">{{ why }}</p>
              {% end %}
              {% for e in maybeToList st.stale %}{{ staleNotice e RetryStale }}{% end %}
              {% if st.droppedUnsaved %}
                <div class="error dropped-unsaved" role="alert">
                  <p>Unsaved changes to a page of an encrypted space were dropped when its keys were let go (a sign-out, here or in another tab, or the space closed). Drafts of encrypted pages are not kept.</p>
                  <button type="button" class="dismiss" onClick={{ const DismissDropped }}>Dismiss</button>
                </div>
              {% end %}
              {% for (_, unsaved) in maybeToList st.leaving %}
                {{ leaveConfirm unsaved }}
              {% end %}
              {{ content st }}
            </main>
          </div>
          {{ HH.slot_ "part" HelpSlot HelpView.component HelpView.Input {context = context st} }}
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
          {{ starredList st }}
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
            {{ [attr "aria-current" "page" | isAdminRoute st.route] }}
            {{ Router.linkProps st.router Followed (Admin R.Overview) }}
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

    -- The signed-in user's starred pages (WP5.44 of docs/PLAN.md), beside
    -- the bell, for whoever has notifications: a user of the wiki.
    starredList :: State m -> Maybe (H.ComponentHTML Action Slots m)
    starredList st =
      guard (st.world == WorldReady && notified (context st))
        $> HH.slot_ "part" StarredSlot StarredView.component StarredView.Input {context = context st}

    -- Who is signed in: the demo's menu to switch between its users, or,
    -- where people do not switch, their name, once it is known, with a
    -- way to sign in or out where people do.
    whoIsAsking :: State m -> Maybe (H.ComponentHTML Action Slots m)
    whoIsAsking st = case st.demo of
      Just _ -> Just (userSwitcher st)
      Nothing
        | st.world /= WorldReady -> Nothing
        | Just accounts <- st.accounts ->
            Just (HH.slot "signIn" () SignInView.component SignInView.Input {accounts, session = st.session, avatar = ownAvatar st, here = Router.href st.router st.route, router = st.router} FromAccount)
        | Just u <- st.session.user -> Just [hh|<span class="user-name">{{ avatar SmallAvatar (ownAvatar st) u.displayName }}{{ u.displayName }}</span>|]
        | otherwise -> Just [hh|<span class="user-name">Not signed in</span>|]

    -- The URL of the signed-in user's avatar, if they have one.
    ownAvatar :: State m -> Maybe Text
    ownAvatar st = st.session.user >>= \u -> Map.lookup u.id st.avatars

    -- The demo's menu of who one is: nobody, or one of its users.
    userSwitcher :: State m -> H.ComponentHTML Action Slots m
    userSwitcher st =
      [hh|
        <div class="user-switcher" {{ HP.ref st.menuHolder }}>
          <button type="button" class="user-switcher-toggle" aria-expanded={{ ariaBool st.menuOpen }} onClick={{ const ToggleMenu }}>
            {% for u in maybeToList st.session.user %}{{ avatar SmallAvatar (ownAvatar st) u.displayName }}{% end %}
            {{ maybe "Not signed in" (\u -> u.displayName) st.session.user }}
          </button>
          {% if st.menuOpen %}
            <ul class="user-menu">
              {% for candidate in Nothing : map Just st.users %}
                <li>
                  <button
                    type="button"
                    class="user-option"
                    data-login={{ maybe "" (\u -> u.login.text) candidate }}
                    aria-pressed={{ ariaBool (((\u -> u.id) <$> candidate) == ((\u -> u.id) <$> st.session.user)) }}
                    onClick={{ const (SwitchTo ((\u -> u.id) <$> candidate)) }}
                  >
                    {{ maybe "Nobody (not signed in)" (\u -> u.displayName <> " (" <> u.login.text <> ")") candidate }}
                  </button>
                </li>
              {% end %}
              {% if isJust st.session.user %}
                <li class="user-menu-account">
                  <button type="button" class="demo-account-toggle" onClick={{ const ToggleDemoAccount }}>Your account…</button>
                </li>
                <li class="user-menu-personal">
                  {{ HH.slot "view" PersonalSpaceSlot PersonalSpaceView.component PersonalSpaceView.Input {user = (\u -> u.id) <$> st.session.user} FromView }}
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
              <section class="account-avatar" aria-label="Avatar">
                <h3>Avatar</h3>
                {{ HH.slot "view" AvatarSlot AvatarView.component AvatarView.Input {user = st.session.user} FromView }}
              </section>
              {{ HH.slot_ "part" DemoAccountSlot SecurityView.component Nothing }}
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

    -- The administration of the wiki, for someone who may administer it:
    -- the section's heading and the section, each section's view mounted
    -- alone. Anyone else is told whom it is for, and in the demo how to
    -- become one.
    admin :: State m -> AdminSection -> H.ComponentHTML Action Slots m
    admin st section
      | isAdministrator st =
          [hh|
            <section class="admin-view admin-page-{{ sectionName section }}">
              <h1>{{ sectionTitle section }}</h1>
              {{ sectionView st section }}
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

    -- A section of the administration: its view, or for "Backups and data"
    -- the backups' view and the wiki's data as one file.
    sectionView :: State m -> AdminSection -> H.ComponentHTML Action Slots m
    sectionView st = \case
      R.Overview -> HH.slot "view" StatusSlot StatusView.component StatusView.Input {context = ctx} FromView
      R.Users listing -> HH.slot "view" UsersSlot UsersView.component UsersView.Input {context = ctx, listing} FromView
      R.Groups -> HH.slot "view" GroupsSlot GroupsView.component GroupsView.Input {context = ctx} FromView
      R.Permissions -> HH.slot "view" AccessSlot AccessView.component AccessView.Input {context = ctx} FromView
      R.Server -> HH.slot "view" ServerSlot ServerView.component ServerView.Input {context = ctx} FromView
      R.EditorSettings -> HH.slot "view" EditorSettingsSlot EditorSettingsView.component EditorSettingsView.Input {context = ctx} FromView
      R.Backups ->
        [hh|
          <div class="admin-backups-and-data">
            {{ HH.slot_ "part" BackupsSlot BackupsView.component BackupsView.Input {context = ctx} }}
            <section class="admin-section admin-data">
              <h2>The wiki as one file</h2>
              <p class="admin-intro">{{ dataIntro }}</p>
              {{ dataControls st }}
            </section>
          </div>
        |]
      R.Activity -> HH.slot_ "part" ActivitySlot ActivityView.component ActivityView.Input {context = ctx}
      where
        ctx = context st
        dataIntro :: Text
        dataIntro
          | isJust st.demo = "Export the whole wiki to keep a copy or to take it to another browser, or import one to replace everything here."
          | otherwise = "Export the whole wiki to keep a copy, or import the pages of another into this one, choosing what to bring in."

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
            <a class="button demo-export" href={{ archiveExportUrl }} download>Export the wiki</a>
          </div>
          {% if not (null sealed) %}
            <p class="export-leaves-out" role="note">{{ leftOutLine }}</p>
          {% end %}
          {{ importer <$> st.migration }}
        </div>
      |]
      where
        -- The server writes the file, and cannot read an encrypted space:
        -- the file leaves every one out, which is said here, before it is
        -- downloaded.
        sealed = [x.name | x <- st.spaces, isJust x.encryption]
        leftOutLine =
          show (length sealed)
            <> (if length sealed == 1 then " encrypted space is" else " encrypted spaces are")
            <> " not in this file: "
            <> T.intercalate ", " sealed
            <> ". Each is exported from its own list of pages, decrypted in a browser that holds its key."
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

    -- The browser's key for whether the sidebar is folded.
    sidebarFoldedKey :: Text
    sidebarFoldedKey = "sidebar-folded"

    -- The key of local storage that keeps the number of the newest entry
    -- the reader has seen on the page "What's new?".
    whatsNewSeenKey :: Text
    whatsNewSeenKey = "whats-new-seen"

    -- On the page "What's new?", every entry the backend has is seen, once
    -- the shell has read what the reader had seen ('seen').
    whatsNewSeen :: H.HalogenM (State m) Action Slots output m ()
    whatsNewSeen = do
      st <- get
      case (st.session.whatsNew, st.seen) of
        (Just newest, Just before)
          | st.route == WhatsNewPage
          , before < newest -> do
              modify (\s -> s {seen = Just newest})
              H.liftEffect (Storage.setItem LocalStorage whatsNewSeenKey newest)
        _ -> pass

    -- The key of local storage that keeps how wide pages are laid out:
    -- @"compact"@ or @"full"@.
    pageWidthKey :: Text
    pageWidthKey = "page-width"

    -- Inside a space, that space alone; elsewhere, the spaces.
    sidebar :: State m -> H.ComponentHTML Action Slots m
    sidebar st = case (st.route, st.here) of
      (Admin section, _) | st.world == WorldReady && isAdministrator st -> adminSidebar st section
      (_, InSpace _ space pages) | not (homeSpace (context st) space.id) -> spaceSidebar st space pages
      _ -> spacesSidebar st

    -- The administration's navigation, in the sidebar's place: an entry per
    -- section, the current one marked. On a narrow screen the stylesheet
    -- turns it into a row of tabs above the section.
    adminSidebar :: State m -> AdminSection -> H.ComponentHTML Action Slots m
    adminSidebar st current =
      [hh|
        <nav class="wiki-sidebar admin-sidebar" aria-label="Administration">
          <h2>Administration</h2>
          <ul class="admin-nav">
            {% for s in adminSections %}
              <li>
                <a
                  class="admin-nav-link"
                  data-section={{ sectionName s }}
                  {{ [attr "aria-current" "page" | sectionName s == sectionName current] }}
                  {{ Router.linkProps st.router Followed (Admin s) }}
                >
                  {{ sectionTitle s }}
                </a>
              </li>
            {% end %}
          </ul>
        </nav>
      |]

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
          {{ whatsNewLink st }}
        </nav>
      |]

    -- The link to the page "What's new?", at the very bottom of the
    -- sidebar, where the backend has the page. It is marked (a dot, drawn
    -- by the stylesheet from data-unseen) while the backend has an entry
    -- newer than the newest the reader has seen there. The mark is set
    -- after the first render, once the shell has read what the reader has
    -- seen ('seen'), and never on the page itself, which marks everything
    -- seen.
    whatsNewLink :: State m -> Maybe (H.ComponentHTML Action Slots m)
    whatsNewLink st =
      st.session.whatsNew <&> \newest ->
        [hh|
          <div class="sidebar-whats-new">
            <a
              class="whats-new-link"
              {{ [attr "aria-current" "page" | st.route == WhatsNewPage] }}
              {{ [attr "data-unseen" "true" | st.route /= WhatsNewPage, maybe False (< newest) st.seen] }}
              {{ Router.linkProps st.router Followed WhatsNewPage }}
            >
              What's new?
            </a>
          </div>
        |]

    -- A space in a list of spaces, with its icon: a link to it, unless the
    -- user may not view it. The container "User subspaces" is a link to the
    -- finder of user spaces while the reader may open a personal space,
    -- with the reader's own under it while it is on.
    spaceEntry :: State m -> Space -> H.ComponentHTML Action Slots m
    spaceEntry st x
      | x.personalContainer
      , not (null (openPersonalSpaces (context st))) =
          [hh|
            <div class="sidebar-user-spaces">
            <a
              class="space-link user-spaces-link"
              {{ [attr "aria-current" "page" | st.route == UserSpaces] }}
              {{ Router.linkProps st.router Followed UserSpaces }}
            >
              {{ spaceIcon st.icons x }}<span>{{ x.name }}</span>
            </a>
            {% for own in toList (ownSpace (context st)) %}
              <ul class="sidebar-own-space">
                <li>
                  <a class="space-link own-space-link" {{ Router.linkProps st.router Followed (Space (spacePathOf st.spaces own.id)) }}>Your personal space</a>
                </li>
              </ul>
            {% end %}
            </div>
          |]
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
          <div class="space-switcher" {{ HP.ref st.switcherHolder }}>
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
            <li><a class="space-pages-link" {{ [attr "aria-current" "page" | st.route == SpacePages path] }} {{ Router.linkProps st.router Followed (SpacePages path) }}>Space settings</a></li>
          </ul>
          <h2>Pages</h2>
          {% if all (\p -> Just p.id == rootPage space) tree %}
            <p class="empty">No pages yet.</p>
          {% else %}
            {{ pageTree st.router Followed path space tree ((\p -> p.id) <$> currentPage st) (\_ _ _ -> []) }}
          {% end %}
          {% if not (null linkedFrom) %}
            <h2>Linked from</h2>
            <ul class="sidebar-backlinks">
              {% for b in linkedFrom %}
                <li><a {{ Router.linkProps st.router Followed (locationRoute b.location Nothing) }}>{{ b.title }}</a></li>
              {% end %}
            </ul>
          {% end %}
          {% if not (null templates) %}
            <h2>Templates</h2>
            <ul class="sidebar-templates">
              {% for t in templates %}
                <li class="page-node{% if Just t.id == here %} current{% end %}">
                  <a {{ [attr "aria-current" "page" | Just t.id == here] }} {{ Router.linkProps st.router Followed (pageRouteOf st.spaces space pages t.id) }}>{{ t.title }}</a>
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
          {{ whatsNewLink st }}
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
        -- The pages that link to the page shown, once they are its: none
        -- shows nothing, as no templates or no subspaces do.
        linkedFrom = case st.backlinks of
          Just (pid, listed) | Just pid == here -> listed
          _ -> []
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
      Unknown -> notFound st
      Admin section -> admin st section
      NewSpace parent -> HH.slot "view" NewSpaceSlot NewSpaceView.component NewSpaceView.Input {context = context st, parent} FromView
      Search text space subspaces ->
        HH.slot "view" SearchResultsSlot SearchResultsView.component SearchResultsView.Input {context = context st, text, space, subspaces} FromView
      Invite token -> HH.slot "invite" () InviteView.component InviteView.Input {accounts = st.accounts, token, session = st.session, home = Router.href st.router Home} FromInvite
      ResetPassword token -> HH.slot "reset" () ResetView.component ResetView.Input {accounts = st.accounts, token, session = st.session} FromReset
      VerifyEmail token -> HH.slot_ "part" VerifyEmailSlot VerifyEmailView.component VerifyEmailView.Input {accounts = st.accounts, token}
      Unsubscribe token -> HH.slot_ "part" UnsubscribeSlot UnsubscribeView.component UnsubscribeView.Input {token}
      AssistantSettings -> HH.slot_ "part" AssistantSettingsSlot AssistantSettingsView.component AssistantSettingsView.Input {context = context st}
      WhatsNewPage -> HH.slot_ "part" WhatsNewSlot WhatsNewView.component WhatsNewView.Input {context = context st}
      UserSpaces -> HH.slot_ "part" UserSpacesSlot UserSpacesView.component UserSpacesView.Input {context = context st}
      Home -> homeContent st
      -- Until the page is found, and then its own route is shown. A page
      -- that is not found, or that the reader may not view, is not found
      -- as a page at a path is.
      PermanentLink {} -> case st.here of
        Following _ (Just e) -> failureView e RetryHere
        _ -> loading
      _ -> case st.here of
        NoSpace -> notFound st
        LoadingSpace _ -> loading
        -- Left from a permanent address, until the space is asked for.
        Following _ _ -> loading
        SpaceFailed path read' e
          -- An encrypted space whose pages this browser cannot read now
          -- says why, and offers to unlock the user's keys.
          | Just space <- read' <|> (findSpace (context st).spaces path >>= lastMay)
          , isJust space.encryption ->
              HH.slot "view" EncryptedSlot EncryptedView.component EncryptedView.Input {context = context st, space, problem = e} FromView
          | otherwise -> failureView e RetryHere
        InSpace _ space pages ->
          let homePath = fromMaybe [] (pagePathOf space pages . (\p -> p.id) =<< homeOf space pages)
              -- A page's path as it is now, for one asked for at an old
              -- address (with the home page's slug first): the views
              -- number, link and show breadcrumbs from it.
              here' = canonicalPath space pages
           in case st.route of
                EditHome -> HH.slot "editor" (space.id, homePath) Editor.component Editor.Input {context = context st, space, pages, path = homePath, feed = st.feed, home = True} FromView
                HomeSource -> HH.slot "view" SourceSlot SourceView.component SourceView.Input {context = context st, space, path = homePath} FromView
                HomeHistory version against -> HH.slot "view" HistorySlot HistoryView.component HistoryView.Input {context = context st, space, path = homePath, version, against} FromView
                HomeSlides slide step -> HH.slot "view" SlidesSlot SlidesView.component SlidesView.Input {context = context st, space, pages, path = homePath, slide, step} FromView
                -- Entering a blog shows its posts, at the requested page of them.
                Space _ | space.blog -> blogView space pages 1
                Posts _ n | space.blog -> blogView space pages n
                -- Entering a space shows its home page, if it has one, at any
                -- requested page of posts.
                Space _ | isJust (homeOf space pages) -> pageView space pages homePath
                Posts _ _ | isJust (homeOf space pages) -> pageView space pages homePath
                Page _ path -> pageView space pages (here' path)
                PageSource _ path -> HH.slot "view" SourceSlot SourceView.component SourceView.Input {context = context st, space, path = here' path} FromView
                LivePreview _ path -> HH.slot "view" LivePreviewSlot LivePreviewView.component LivePreviewView.Input {context = context st, space, pages, path = here' path} FromView
                PageHistory _ path version against ->
                  HH.slot "view" HistorySlot HistoryView.component HistoryView.Input {context = context st, space, path = here' path, version, against} FromView
                PageAtVersion _ path version -> pageViewOf space pages (here' path) (Just version)
                PageSlides _ path slide step ->
                  HH.slot "view" SlidesSlot SlidesView.component SlidesView.Input {context = context st, space, pages, path = here' path, slide, step} FromView
                -- One editor per page edited: another page's editor is a
                -- separate component, with its own draft.
                EditPage _ path -> let path' = here' path in HH.slot "editor" (space.id, path') Editor.component Editor.Input {context = context st, space, pages, path = path', feed = st.feed, home = False} FromView
                NewPage _ parent -> HH.slot "view" NewPageSlot NewPageView.component NewPageView.Input {context = context st, space, pages, parent} FromView
                _ -> HH.slot "view" SpaceSlot SpaceView.component SpaceView.Input {context = context st, space, pages} FromView
      where
        pageView space pages path = pageViewOf space pages path Nothing
        -- A version of a page is shown with no live channel: nothing
        -- happens to a version.
        pageViewOf space pages path version = HH.slot "view" PageSlot PageView.component PageView.Input {context = context st, space, pages, path, version, feed = if shutOut st.session || isJust version then Nothing else st.feed} FromView
        blogView space pages page = HH.slot "view" BlogSlot BlogView.component BlogView.Input {context = context st, space, pages, page, feed = if shutOut st.session then Nothing else st.feed} FromView

    -- The front page: its page, and under it the spaces and the ones
    -- visited last ("Wiki.App.View.Directory"). The directory stays mounted
    -- while the page loads again (after a change of user, or coming back
    -- from the editor), so that a click on a space's card made meanwhile is
    -- not lost with a directory taken down and made again, and the cards
    -- do not go away and come back.
    --
    -- The page, its loading note or its error sits in a holder element of
    -- its own ("home-document"). Without the holder, a change from the
    -- page to "Loading…" and back changes the first child of "wiki-home",
    -- and the renderer moves the directory's element out of the tree and
    -- back in to keep the children in order. A press on a space's card
    -- while that render runs (it can run in the press's own pointerdown,
    -- whose listeners call into the program) then has its element taken
    -- away under it, and the browser sends no click.
    homeContent :: State m -> H.ComponentHTML Action Slots m
    homeContent st = case st.here of
      NoSpace -> notFound st
      here ->
        HH.div
          [HP.class_ "wiki-home"]
          [ HH.div
              [HP.class_ "home-document"]
              [ case here of
                  InSpace _ space pages ->
                    let path = fromMaybe [] (pagePathOf space pages . (\p -> p.id) =<< homeOf space pages)
                     in HH.slot "view" PageSlot PageView.component PageView.Input {context = context st, space, pages, path, version = Nothing, feed = if shutOut st.session then Nothing else st.feed} FromView
                  SpaceFailed _ _ e -> failureView e RetryHere
                  _ -> loading
              ]
          , HH.slot "view" DirectorySlot DirectoryView.component DirectoryView.Input {context = context st, welcome = st.welcome} FromView
          ]

    loading :: H.ComponentHTML Action Slots m
    loading = [hh|<p class="loading">Loading…</p>|]

    -- Asked when a route is followed away from unsaved changes ('leaving').
    leaveConfirm :: Unsaved -> H.ComponentHTML Action Slots m
    leaveConfirm unsaved =
      [hh|
        <div class="confirm leave-confirm" role="alertdialog">
          <p>{{ question }}</p>
          <button type="button" class="danger" onClick={{ const Leave }}>Leave</button>
          <button type="button" onClick={{ const Stay }}>Stay</button>
        </div>
      |]
      where
        question :: Text
        question = case unsaved of
          EditorChanges -> "This page has changes that are not saved. Leave the editor and lose them?"
          PageTicks -> "This page has ticked tasks that are not saved. Leave the page and lose them?"

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
        -- After the first render, which a prerendered page shows unfolded.
        folded <- H.liftEffect (Storage.getItem LocalStorage sidebarFoldedKey)
        when (folded == Just (Right True)) $ modify (\st -> st {sidebarFolded = True})
        -- And how wide pages are, which a prerendered page shows compact.
        wide <- H.liftEffect (Storage.getItem LocalStorage pageWidthKey)
        when (wide == Just (Right ("full" :: Text))) $ modify (\st -> st {chosenWidth = FullWidth})
        -- And the newest entry of "What's new?" the reader has seen, which
        -- a prerendered page does not mark. Only in a browser: natively
        -- this is the server's prerender, whose storage is the process's
        -- and nobody's.
        when inBrowser $ do
          seen <- H.liftEffect (Storage.getItem LocalStorage whatsNewSeenKey)
          modify (\st -> st {seen = Just (fromMaybe 0 (seen >>= rightToMaybe))})
          whatsNewSeen
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
        -- Another tab's sign-out lets go of the keys there: this tab lets
        -- go of what it opened with them.
        H.liftEffect (liftIO listenToOtherTabs)
        dropped <- H.liftEffect keysDroppedElsewhere
        void $ H.subscribe (KeysDropped <$ dropped)
        handleAction InstallChanged
        router <- gets (\st -> st.router)
        void $ H.subscribe (Arrived <$> Router.changes router)
        canonicalAdmin
        gets (\st -> st.accounts) >>= traverse_ (\a -> lift a.sessionChanges >>= void . H.subscribe . fmap SessionChanged)
        entry <- H.liftEffect historyEntry
        modify (\st -> st {entry})
        -- The bars that stick under the header need its height, and the
        -- lists of a page's headings highlight the section being read.
        H.liftEffect keepHeights
        H.liftEffect keepContents
        -- What the route shows was loaded in the initial state, unless the
        -- backend would have waited for it.
        -- A permanent address found in the initial state is followed now,
        -- since the initial state cannot change the address.
        gets (\st -> (st.world, st.here)) >>= \case
          (WorldReady, Following _ Nothing) -> loadHere True
          (WorldReady, _) -> do
            whenM (gets (\st -> isNothing st.backlinks)) loadBacklinks
            announce
          _ -> loadEverything
      RetryWorld -> do
        modify (\st -> st {world = WorldLoading})
        loadEverything
      RetryHere -> loadHere True
      RetryStale -> reload Nothing
      DismissDropped -> modify (\st -> st {droppedUnsaved = False})
      -- This tab's sign-out, before its request: what is shown of
      -- encrypted spaces goes at once, whether the request then succeeds
      -- or not (offline, it does not).
      SigningOut -> do
        lift forgetEncrypted
        sealScreen
      Online False -> modify (\st -> st {offline = True})
      -- Back online: whatever failed to load because the server could not
      -- be reached is loaded again, as "Try again" would. A view whose own
      -- load failed keeps its own button.
      Online True -> do
        modify (\st -> st {offline = False})
        st <- get
        case (st.world, st.here) of
          (WorldFailed (Unreachable _), _) -> handleAction RetryWorld
          (WorldReady, SpaceFailed _ _ (Unreachable _)) -> handleAction RetryHere
          (WorldReady, Following _ (Just (Unreachable _))) -> handleAction RetryHere
          _ -> pass
      InstallChanged -> do
        installable <- H.liftEffect installAvailable
        modify (\st -> st {installable})
      -- The browser asks the reader; its offer is used up either way.
      Install -> do
        void install
        handleAction InstallChanged
      -- Another tab let go of the user's keys (a sign-out there): nothing
      -- of an encrypted space stays open here, and the session is asked
      -- for again, with everything shown.
      KeysDropped -> do
        lift forgetEncrypted
        sealScreen
        reload Nothing
      Arrived r -> do
        now <- H.liftEffect historyEntry
        before <- gets (\st -> st.route)
        if r == before
          then do
            -- The route shown, at an entry of its own: one the shell
            -- pushed itself after a change ('reload'), the editor's entry,
            -- gone back to after staying, or a place on the page, such as
            -- a footnote's reference that Back returns to
            -- ('Wiki.App.Browser.followArticleLink'), which is scrolled to.
            modify (\st -> st {entry = now})
            H.liftEffect revealFragment
          else do
            unsaved <- unsavedShown
            case unsaved of
              Just what -> do
                shut <- shutMenu
                modify (shut . \st -> st {leaving = Just (r, what)})
              Nothing -> arrive r now
      Leave -> do
        now <- H.liftEffect historyEntry
        gets (\st -> st.leaving) >>= traverse_ ((`arrive` now) . fst)
      Stay -> do
        st <- get
        modify (\s -> s {leaving = Nothing})
        -- The address is that of the route not followed. Going back to the
        -- entry of the route shown (the editor's, or the page's with its
        -- ticks) leaves the history as the browser's buttons would, with
        -- the route not followed ahead of it; the router announces the
        -- route already shown. Without a number for that entry (there is
        -- none natively), the shown route's address replaces the other.
        now <- H.liftEffect historyEntry
        if st.entry /= now
          then H.liftEffect (historyGo (st.entry - now))
          else H.liftEffect (Router.redirect st.router st.route)
      Followed f -> gets (\st -> st.router) >>= (`Router.follow` f)
      ToggleSwitcher ->
        gets (\st -> st.switcherOpen) >>= \case
          True -> shutSwitcher >>= modify
          False -> do
            modify (\st -> st {switcherOpen = True})
            watch <- gets (\st -> st.switcherHolder) >>= (`watchPopup` CloseSwitcher)
            modify (\st -> st {switcherWatch = watch})
      CloseSwitcher -> whenM (gets (\st -> st.switcherOpen)) (shutSwitcher >>= modify)
      FoldSidebar folded -> do
        modify (\st -> st {sidebarFolded = folded})
        H.liftEffect (Storage.setItem LocalStorage sidebarFoldedKey folded)
      ToggleMenu ->
        gets (\st -> st.menuOpen) >>= \case
          True -> shutMenu >>= modify
          False -> do
            modify (\st -> st {menuOpen = True})
            watch <- gets (\st -> st.menuHolder) >>= (`watchPopup` CloseMenu)
            modify (\st -> st {menuWatch = watch})
      CloseMenu -> whenM (gets (\st -> st.menuOpen)) (shutMenu >>= modify)
      -- The questions and results about the wiki's data were for the user
      -- one was before switching, so they are cleared.
      SwitchTo user -> withDemo $ \demo -> do
        shut <- shutMenu
        modify (shut . \st -> st {demoAccountOpen = False, panel = Actions Nothing, settled = False})
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
      FromView (ChoseWidth width) -> do
        modify (\st -> st {chosenWidth = width})
        H.liftEffect (Storage.setItem LocalStorage pageWidthKey (case width of Compact -> "compact" :: Text; FullWidth -> "full"))
      FromView (Showing page) -> modify (\st -> st {shown = Just page})
      FromView Entered -> do
        now <- H.liftEffect historyEntry
        modify (\st -> st {entry = now})
      -- Someone signed in or out: reload everything, as the new user.
      FromAccount SignInView.SigningOut -> handleAction SigningOut
      FromAccount (SignInView.AccountChanged s) -> do
        forgetFormer s
        -- A sign-in completed: a tab about to let go of every user's keys
        -- lets go of none.
        when (isJust s.user) (H.liftEffect (liftIO announceSignIn))
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        restartFeed
        reload Nothing
      -- The user turned their personal space on or off, or changed their
      -- avatar.
      FromAccount SignInView.SpacesChanged -> reload Nothing
      -- The session ended by itself (or changed elsewhere): reload
      -- everything as the current user ('sessionEnded'). Unless it is the
      -- same user, with the same rights, whose own record changed
      -- (their avatar, from the account panel): only what shows the user
      -- is read again, with the spaces (a personal space shows its owner's
      -- avatar).
      SessionChanged s
        | Just _ <- s.user ->
            gets (\st -> sameAsking st.session s) >>= \case
              -- (The generation, unchanged, tells the record updated: a
              -- view's context has a session too.)
              True -> modify (\st -> st {session = s, generation = st.generation}) >> loadWorld
              False -> sessionEnded s
        | otherwise -> sessionEnded s
      OpenSignIn -> H.tell "signIn" () (SignInView.Prompt "Sign in with your login and password.")
      -- An invitation created its account and signed the new user in: the
      -- wiki as them, from its front page.
      FromInvite (InviteView.Accepted s) -> do
        modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
        restartFeed
        reload (Just Home)
      -- A password set through a reset link: the sign-in form, to use it.
      FromReset ResetView.SignInWanted -> H.tell "signIn" () (SignInView.Prompt "Sign in with your new password.")
      ToggleDemoAccount -> do
        shut <- shutMenu
        modify (shut . \st -> st {demoAccountOpen = not st.demoAccountOpen})

    -- The address of an administration's route as the router writes it,
    -- in place of the one the route was read from: @\/admin\/@ becomes the
    -- first section's address. Where the two are the same, nothing
    -- happens; the router then announces the route already shown, which
    -- 'Arrived' ignores.
    --
    -- A view's initializer runs before the shell's, and so before the shell
    -- listens to the router. The users section's may already have put
    -- another address in place of the one the shell started with (a page
    -- number back in range). Then the shell goes to the route the address
    -- names now, rather than writing back the route it started with.
    --
    -- The address is read and written on the loop ('H.liftEffect'), in the
    -- step that compares it, as every write of the shell's to the address
    -- is ('announce', 'Stay'): through 'liftIO' the write came on a thread
    -- of its own, after whatever ran meanwhile, and could take the reader
    -- back from a route followed since.
    canonicalAdmin :: H.HalogenM (State m) Action Slots output m ()
    canonicalAdmin = do
      st <- get
      now <- H.liftEffect (Router.current st.router)
      if
        | now /= st.route -> handleAction (Arrived now)
        | isAdminRoute st.route -> H.liftEffect (Router.redirect st.router st.route)
        | otherwise -> pass

    -- The session ended by itself, or changed elsewhere: everything is
    -- reloaded as the current user, and if that is nobody, the way to sign
    -- in again is shown, saying why.
    sessionEnded :: Session -> H.HalogenM (State m) Action Slots output m ()
    sessionEnded s = do
      sealScreen
      forgetFormer s
      modify (\st -> st {session = s, settled = False, panel = Actions Nothing})
      restartFeed
      reload Nothing
      when (isNothing s.user) $
        H.tell "signIn" () (SignInView.Prompt "Your session has ended. Sign in again to go on.")

    -- The user who was signed in is no longer: their vault key and private
    -- key leave this device, in every tab ('Wiki.App.Vault.forgetUserKeys').
    forgetFormer :: Session -> H.HalogenM (State m) Action Slots output m ()
    forgetFormer s = do
      before <- gets (\st -> st.session.user)
      for_ before $ \u -> when (((\x -> x.id) <$> s.user) /= Just u.id) (lift (forgetUserKeys u.id))

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
    -- The demo's user menu closed: its watch ended now, and the change to
    -- the state, for the caller to make together with its own.
    shutMenu :: H.HalogenM (State m) Action Slots output m (State m -> State m)
    shutMenu = do
      gets (\st -> st.menuWatch) >>= traverse_ H.unsubscribe
      pure (\st -> st {menuOpen = False, menuWatch = Nothing})

    -- The space switcher's menu closed, as 'shutMenu'.
    shutSwitcher :: H.HalogenM (State m) Action Slots output m (State m -> State m)
    shutSwitcher = do
      gets (\st -> st.switcherWatch) >>= traverse_ H.unsubscribe
      pure (\st -> st {switcherOpen = False, switcherWatch = Nothing})

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
      shut <- (.) <$> shutMenu <*> shutSwitcher
      -- A gate closed: the views' revision moves on, so that the header's
      -- bell and stars forget the titles they show decrypted of the space.
      closed <- gatesAt (settledRoute r)
      -- A gate left: the space behind it goes from the screen at once, as
      -- its keys do ('sealScreen').
      when closed sealScreen
      modify (shut . \st -> st {route = settledRoute r, settled = False, panel = Actions Nothing, leaving = Nothing, entry, offlineCopy = Nothing})
      -- The route left keeps no title of its own in the tab, nor in the
      -- history's entry, until the route arrived at sets its title
      -- ('announce').
      H.liftEffect (setDocumentTitle bareTitle)
      canonicalAdmin
      whatsNewSeen
      loadHere False

    -- Tell the backend where the reader is now, before the route reads
    -- anything: a space that asks for a passkey or the password each time
    -- it is opened asks again once the reader has left it
    -- ('Wiki.App.Backend.Encrypted.readerAt'). Only the backend's memory
    -- changes, so nothing waits. A path not in the list of spaces yet (a
    -- space made just now) counts as its nearest space listed.
    gatesAt :: Route -> H.HalogenM (State m) Action Slots output m Bool
    gatesAt r = case routeSpace r of
      Nothing -> pure False
      Just path -> do
        spaces <- gets (\st -> st.spaces)
        let nearest p = listToMaybe [x.id | n <- reverse [1 .. length p], Just chain <- [findSpace spaces (take n p)], Just x <- [lastMay chain]]
        lift (readerAt spaces (path >>= nearest))

    -- Take what is shown of an encrypted space off the screen, at once,
    -- before anything waits: the keys were let go (a sign-out, here or in
    -- another tab, the session ended or changed user). The space shown, if
    -- it is encrypted, is unmounted with every view in it (the page, the
    -- editor and its preview, the history, the source, the slides, the
    -- comments, a dialog over them), changes not saved with it: they are
    -- dropped, and said so once ('droppedUnsaved'). The bell, the stars
    -- and the search's results see a new revision, which names encrypted
    -- pages as the server does and searches again. Nothing here waits on
    -- the network, so nothing decrypted stays on the screen when a request
    -- then fails.
    sealScreen :: H.HalogenM (State m) Action Slots output m ()
    sealScreen = do
      st <- get
      let encrypted path = maybe False (any (\x -> isJust x.encryption)) (findSpace st.spaces path)
      case st.here of
        InSpace path _ _ | encrypted path -> do
          dirty <- isJust <$> unsavedShown
          modify (\s -> s {here = LoadingSpace path, shown = Nothing, stale = Nothing, leaving = Nothing, droppedUnsaved = s.droppedUnsaved || dirty})
        _ -> pass
      modify (\s -> s {generation = s.generation + 1})
      -- The tab's title, and the history's entry, named what was shown
      -- (a page's title, decrypted): the wiki's bare name until the
      -- reload sets the title again ('announce').
      H.liftEffect (setDocumentTitle bareTitle)

    -- After a change: reload everything, and every view's own data too.
    reload :: Maybe Route -> H.HalogenM (State m) Action Slots output m ()
    reload next = do
      -- Going to another route after the change ends the preload, as
      -- 'arrive' does.
      when (isJust next) (lift endPreload)
      loadWorld
      void (gatesAt =<< maybe (gets (\st -> st.route)) (pure . settledRoute) next)
      modify (\st -> st {generation = st.generation + 1})
      for_ next $ \r -> modify (\st -> st {route = settledRoute r, settled = False, leaving = Nothing})
      loadHere True
      -- The router is told last, so that the route it announces is the one
      -- already shown, which 'Arrived' ignores. From the editor's preview
      -- shown alone (Save and close there), the next route takes the
      -- preview's entry of the history, which "Show preview" pushed, so
      -- that Back from it returns to the editor's own entry, as from the
      -- editor shown with its text.
      router <- gets (\st -> st.router)
      fromPreview <- H.liftEffect onPreviewEntry
      for_ next (if fromPreview then H.liftEffect . replacingEntry . Router.redirect router else H.liftEffect . Router.navigate router)

    -- Load who is signed in and the tree of spaces, on a worker thread. If
    -- they cannot be loaded, the route's content says why, with a button
    -- to try again.
    loadWorld :: H.HalogenM (State m) Action Slots output m ()
    loadWorld = do
      demo <- gets (\st -> st.demo)
      lift (attempt (fetchWorld demo)) >>= \case
        Right w -> do
          modify (\st -> st {session = w.asking, users = w.users, spaces = w.spaces, home = w.home, icons = w.icons, avatars = w.avatars, kept = w.kept, world = WorldReady, stale = Nothing})
          -- The server says nobody is signed in in this browser: no user's
          -- keys stay on the device, as after a sign-out, even when the
          -- session ended with no tab open. Not from a copy kept offline,
          -- which may be older than a sign-in since, nor in the demo, whose
          -- users are its own.
          copy <- gets (\st -> st.offlineCopy)
          network <- gets overNetwork
          looked <- gets (\st -> st.keysLooked)
          modify (\st -> st {keysLooked = True})
          -- Once a page start, and on a fork of its own, so that nothing
          -- shown waits on it. The fork looks again: a session with a user
          -- by then (signed in here meanwhile) lets go of nothing, and nor
          -- does a sign-in in another tab ('announceSignIn').
          when (not looked && isNothing w.asking.user && network && isNothing copy && inBrowser) . void . H.fork $
            whenM (gets (\st -> isNothing st.session.user)) (lift forgetEveryUsersKeys)
          -- A session loaded now may name a newer entry than the page
          -- shown has marked seen.
          whatsNewSeen
        Left e -> do
          -- A reload that fails while what is shown has unsaved changes
          -- keeps it ('stale').
          keep <- (&&) <$> gets (\st -> st.world == WorldReady) <*> (isJust <$> unsavedShown)
          modify (\st -> if keep then st {stale = Just e} else st {world = WorldFailed e})

    -- Whose changes not saved the content shown holds, if any: an
    -- editor's, or a page view's ticks. Asked before a route away
    -- ('leaving'), and when a reload fails ('stale').
    unsavedShown :: H.HalogenM (State m) Action Slots output m (Maybe Unsaved)
    unsavedShown = do
      editing <- or <$> H.queryAll "editor" (Editor.IsDirty identity)
      ticked <- or <$> H.queryAll "view" (HasUnsaved identity)
      pure $
        if
          | editing -> Just EditorChanges
          | ticked -> Just PageTicks
          | otherwise -> Nothing

    -- Load the space the route is in, unless it is the one loaded already
    -- (or even then, if forced).
    loadHere :: Bool -> H.HalogenM (State m) Action Slots output m ()
    loadHere again = do
      st <- get
      case spaceOfRoute st.route of
        _ | shutOut st.session && not (publicHomeRoute st.session st.route) -> modify (\s -> s {here = NoSpace})
        _ | PermanentLink pid version <- st.route -> followPermanent pid version
        Nothing -> modify (\s -> s {here = NoSpace})
        Just path
          | not again, hereIs path st.here -> pass
          | otherwise -> do
              -- Reloading the space being shown keeps it on screen
              -- meanwhile.
              unless (hereIs path st.here) $ modify (\s -> s {here = LoadingSpace path})
              result <- fetchHere path
              -- Unless the route has moved to another space meanwhile. A
              -- reload of the space shown that fails while it has unsaved
              -- changes keeps it ('stale').
              now <- gets (\s -> s.route)
              keep <- case result of
                SpaceFailed _ _ e | hereIs path st.here -> unsavedShown >>= \u -> pure (e <$ u)
                _ -> pure Nothing
              when (spaceOfRoute now == Just path) $
                modify (\s -> maybe s {here = result} (\e -> s {stale = Just e}) keep)
      -- Loaded again, or loaded for the first time, as for the server's
      -- prerender: the backlinks are part of what settles. Otherwise
      -- the route has moved within what was shown, and is announced
      -- without waiting for them.
      if again then loadBacklinks >> announce else announce >> loadBacklinks

    -- Load the backlinks of the page the route shows ('backlinksOf'), or
    -- forget those of another. Unless the route has moved to another page
    -- meanwhile.
    loadBacklinks :: H.HalogenM (State m) Action Slots output m ()
    loadBacklinks =
      gets backlinksOf >>= \case
        Nothing -> modify (\s -> s {backlinks = Nothing})
        Just pid -> do
          listed <- lift (listedBacklinks pid)
          now <- get
          when (backlinksOf now == Just pid) $
            modify (\s -> s {backlinks = forced (Just (pid, listed))})

    -- Ask where the page of a permanent address is, and go there: its own
    -- address replaces the permanent one in the history, so that Back
    -- does not come back to it, and the address's fragment is kept for the
    -- page to scroll to. A page not found leaves the permanent address in
    -- place, so that signing in, which loads the route again, asks again.
    followPermanent :: PageId -> Maybe UTCTime -> H.HalogenM (State m) Action Slots output m ()
    followPermanent pid version = do
      modify (\s -> s {here = Following pid Nothing})
      result <- lift (pageLocation pid)
      st <- get
      -- The redirect runs on the component's loop ('H.liftEffect'), as the
      -- other redirects that keep the entry's number do. The router's
      -- 'Arrived' is then handled inside the redirect, while
      -- 'replacingEntry' still holds the entry's number. A bare 'liftIO'
      -- runs it on a worker thread instead, beside the loop, which could
      -- handle that 'Arrived' at the wrong moment and give the entry a new
      -- number: the history's numbers then skip one, and Stay in the editor
      -- goes to an entry that does not exist. Nothing is done if the route
      -- has moved on meanwhile.
      when (st.route == PermanentLink pid version) $ case result of
        Right l -> H.liftEffect (redirectKeepingFragment st.router (locationRoute l version))
        Left e -> modify (\s -> s {here = Following pid (Just e)})

    -- Set the document's title for what is shown, and say whether all of
    -- it has loaded. A page's view, or the editor, says when it has loaded
    -- the page, and the search results when they have arrived; everything
    -- else is loaded by now.
    announce :: H.HalogenM (State m) Action Slots output m ()
    announce = do
      before <- get
      case before.here of
        InSpace path space _
          | not (null path)
          , homeSpace (context before) space.id -> do
              let target = documentRoute (context before) space.id before.route
                  canonical = if target == before.route then Home else target
              H.liftEffect (Router.redirect before.router canonical)
        _ -> pass
      st <- get
      H.liftEffect (setDocumentTitle (documentTitle st))
      let icon = faviconOf st
      H.liftEffect (setFavicon icon.href icon.mediaType)
      -- A space shown counts as visited, for the directory to offer again.
      case st.here of
        InSpace _ space _ | not (homeSpace (context st) space.id) -> H.liftEffect (rememberVisit space.id)
        _ -> pass
      unless (waitsForPage st) settle

    settle :: H.HalogenM (State m) Action Slots output m ()
    settle = modify (\st -> st {settled = True})

    handleQuery :: Query a -> H.HalogenM (State m) Action Slots output m (Maybe a)
    handleQuery (Settled reply) = do
      st <- get
      pure (Just (reply (if st.settled then Just (headOf st) else Nothing)))

-- | The context every route shows: who is signed in, who else one may be
-- in the demo, the tree of spaces, the space behind the wiki's home page,
-- the URLs of the spaces' icon images, and whether the demo saves its
-- changes.
data Around = Around
  { asking :: Session
  , users :: [User]
  , spaces :: [Space]
  , home :: Maybe Space
  , icons :: Map SpaceId Text
  , avatars :: Map UserId Text
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
  -- The home's space is not among the spaces listed. Its icon is the
  -- wiki's favicon away from the spaces (WP5.45 of docs/PLAN.md).
  home <- if shutOut asking then pure Nothing else either (const Nothing) (Just . fst) <$> getHomeDocument
  icons <- Map.fromList <$> sequence [(x.id,) <$> spaceIconUrl x | x <- spaces <> toList home, Just (IconImage _ _) <- [x.icon]]
  avatars <- avatarUrls [(u.id, u.avatar) | u <- toList asking.user <> users]
  kept <- maybe (pure False) (\d -> d.demoKept) demo
  pure Around {asking, users, spaces, home, icons, avatars, kept}

-- | The space at a path, with its pages, or why it cannot be shown.
fetchHere :: (MonadWiki n) => [Slug] -> n Here
fetchHere [] = either (SpaceFailed [] Nothing) (\(space, page) -> InSpace [] space [summaryOf page]) <$> getHomeDocument
fetchHere path =
  getSpace path >>= \case
    Left e -> pure (SpaceFailed path Nothing e)
    Right space -> either (SpaceFailed path (Just space)) (InSpace path space) <$> listPages space.id

-- | What the shell shows for a permanent address after asking where its
-- page is: the refusal, or, for a page found, the look for it, which
-- 'followPermanent' finishes by going there.
lookingFor :: PageId -> Either WikiError a -> Here
lookingFor pid = \case
  Left e -> Following pid (Just e)
  Right _ -> Following pid Nothing

-- | Whether the wiki is reached over the network: true on the HTTP
-- backend, which is the one people sign in to, and false on the demo's,
-- which keeps its wiki in the browser.
overNetwork :: State m -> Bool
overNetwork st = isJust st.accounts

-- | Whether the shell shows the closed wiki's frame: the wiki is closed to
-- the current user, and the route is not the page of a mailed link.
isShut :: State m -> Bool
isShut st = st.world == WorldReady && shutOut st.session && not (isMailedLink st.route) && not (publicHomeRoute st.session st.route)

-- | Only the root's reader routes may be public in a closed wiki.
publicHomeRoute :: Session -> Route -> Bool
publicHomeRoute s r =
  s.homePage.showAnonymous && case r of
    Home -> True
    HomeSource -> True
    HomeHistory {} -> True
    HomeSlides {} -> True
    _ -> False

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

-- | Whether a route is one of the administration's sections.
isAdminRoute :: Route -> Bool
isAdminRoute = \case
  Admin _ -> True
  _ -> False

-- | Whether the user may administer the wiki as a whole, and so is shown
-- the administration.
isAdministrator :: State m -> Bool
isAdministrator st = hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer
  where
    ctx = context st

context :: State m -> Context
context st = Context {router = st.router, session = st.session, spaces = available, icons = st.icons, revision = st.generation, pageWidth = st.chosenWidth}
  where
    available =
      st.spaces <> case st.here of
        InSpace [] space _ -> [space]
        _ -> []

spaceOfRoute :: Route -> Maybe [Slug]
spaceOfRoute = \case
  Home -> Just []
  EditHome -> Just []
  HomeSource -> Just []
  HomeHistory {} -> Just []
  HomeSlides {} -> Just []
  Space path -> Just path
  Posts path _ -> Just path
  SpacePages path -> Just path
  Page path _ -> Just path
  EditPage path _ -> Just path
  PageSource path _ -> Just path
  LivePreview path _ -> Just path
  PageHistory path _ _ _ -> Just path
  PageSlides path _ _ _ -> Just path
  PageAtVersion path _ _ -> Just path
  NewPage path _ -> Just path
  _ -> Nothing

hereIs :: [Slug] -> Here -> Bool
hereIs path = \case
  InSpace p _ _ -> p == path
  SpaceFailed p _ _ -> p == path
  LoadingSpace p -> p == path
  NoSpace -> False
  Following _ _ -> False

waitsForPage :: State m -> Bool
waitsForPage st = case (st.route, st.here) of
  -- The closed frame shows no view that could report having loaded.
  _ | isShut st -> False
  -- The directory says when it has counted the spaces' pages.
  (Home, InSpace {}) -> st.world == WorldReady
  (EditHome, InSpace {}) -> True
  (HomeSource, InSpace {}) -> True
  (HomeHistory {}, InSpace {}) -> True
  (HomeSlides {}, InSpace {}) -> True
  -- A space's own route shows its posts, if it is a blog, or its home
  -- page, if it has one.
  (Space _, InSpace _ space pages) -> space.blog || isJust (homeOf space pages)
  (Posts _ _, InSpace _ space pages) -> space.blog || isJust (homeOf space pages)
  (Page _ _, InSpace {}) -> True
  (EditPage _ _, InSpace {}) -> True
  (PageSource _ _, InSpace {}) -> True
  (LivePreview _ _, InSpace {}) -> True
  (PageHistory {}, InSpace {}) -> True
  (PageSlides {}, InSpace {}) -> True
  (PageAtVersion {}, InSpace {}) -> True
  (Search {}, _) -> True
  _ -> False

-- | The page at a path in a space, among its pages: from under its home
-- page, or at an old address ('Wiki.Core.Space.pageAt').
currentPageOf :: Space -> [PageSummary] -> [Slug] -> Maybe PageSummary
currentPageOf = pageAt

-- | A page's path as it is now ('Wiki.Core.Space.pagePath'), for a path
-- that names it, at an old address too ('currentPageOf'); the path as
-- given when it names no page.
canonicalPath :: Space -> [PageSummary] -> [Slug] -> [Slug]
canonicalPath space pages path = fromMaybe path (currentPageOf space pages path >>= \p -> pagePathOf space pages p.id)

-- | The page whose backlinks the sidebar shows: the page the route shows
-- in a space the sidebar shows alone, which the wiki's front page's space
-- is not.
backlinksOf :: State m -> Maybe PageId
backlinksOf st = case st.here of
  InSpace _ space _ | not (homeSpace (context st) space.id) -> (\p -> p.id) <$> currentPage st
  _ -> Nothing

-- | The backlinks loaded, made whole: each entry and its title. The
-- demo's backend answers with a list made as it is read, and a list left
-- to the render would be made in the middle of it.
forced :: Maybe (PageId, [Backlink]) -> Maybe (PageId, [Backlink])
forced loaded = foldr (\b rest -> b.page `seq` b.title `seq` b.location `seq` rest) () (foldMap snd loaded) `seq` loaded

-- | A page's backlinks, none when they cannot be read: the sidebar leaves
-- the section out then, as for a page nothing links to.
listedBacklinks :: (MonadWiki n) => PageId -> n [Backlink]
listedBacklinks pid = fromRight [] <$> pageBacklinks pid

currentPage :: State m -> Maybe PageSummary
currentPage st = case (st.route, st.here) of
  (r, InSpace [] space pages) | spaceOfRoute r == Just [] -> homeOf space pages
  (Space _, InSpace _ space pages) -> homeOf space pages
  (Posts _ _, InSpace _ space pages) -> homeOf space pages
  (Page _ path, InSpace _ space pages) -> currentPageOf space pages path
  (EditPage _ path, InSpace _ space pages) -> currentPageOf space pages path
  (PageSource _ path, InSpace _ space pages) -> currentPageOf space pages path
  (LivePreview _ path, InSpace _ space pages) -> currentPageOf space pages path
  (PageHistory _ path _ _, InSpace _ space pages) -> currentPageOf space pages path
  (PageSlides _ path _ _, InSpace _ space pages) -> currentPageOf space pages path
  (PageAtVersion _ path _, InSpace _ space pages) -> currentPageOf space pages path
  _ -> Nothing

-- | The breadcrumbs: inside a space, the directory of spaces first, then
-- 'crumbs'.
trail :: State m -> [(Text, Maybe Route)]
trail st = [("Spaces", Just Home) | maybe False (not . null) (spaceOfRoute st.route), st.world == WorldReady, not (isShut st)] <> crumbs st

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
  EditHome -> [(st.session.homePage.title, Just Home), ("Edit", Nothing)]
  HomeSource -> [(st.session.homePage.title, Just Home), ("Source", Nothing)]
  HomeHistory {} -> [(st.session.homePage.title, Just Home), ("History", Nothing)]
  HomeSlides {} -> [(st.session.homePage.title, Just Home), ("Slides", Nothing)]
  Space path -> spaceCrumbs path
  Posts path n -> spaceCrumbs path <> [("Page " <> show n, Nothing)]
  SpacePages path -> spaceCrumbs path <> [("Space settings", Nothing)]
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
  LivePreview path pagePath ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("Preview", Nothing) | not (null page)]
  PageAtVersion path pagePath _ ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("Version", Nothing) | not (null page)]
  PageSlides path pagePath _ _ ->
    let page = spaceCrumbs path <> pageCrumbs path pagePath
     in page <> [("Slides", Nothing) | not (null page)]
  NewPage path parent -> spaceCrumbs path <> foldMap (pageCrumbs path) parent <> [("New page", Nothing)]
  NewSpace parent -> foldMap spaceCrumbs parent <> [("New space", Nothing)]
  Unknown -> [("Not found", Nothing)]
  PermanentLink {} -> []
  Search {} -> [("Search", Nothing)]
  Admin section -> [("Administration", Just (Admin R.Overview)), (sectionTitle section, Nothing)]
  AssistantSettings -> [("Writing assistant", Nothing)]
  WhatsNewPage -> [("What's new?", Nothing)]
  UserSpaces -> [(containerName, Nothing)]
  where
    -- A crumb links to its space, or for the container of personal spaces,
    -- which nobody may view, to the finder of user spaces.
    spaceCrumbs path =
      [ (s.name, crumbRoute s)
      | s <- either (\e -> e.resolved) identity (resolvePath (findChild st.spaces) path)
      ]
    crumbRoute s
      | mayView (context st) s.id = Just (Space (spacePathOf st.spaces s.id))
      | s.personalContainer = Just UserSpaces
      | otherwise = Nothing
    -- The pages above the page, and the page, from under the space's home
    -- page: the space's crumb stands for the home page.
    pageCrumbs _ pagePath = case st.here of
      InSpace _ space pages ->
        [ (p.title, Just (pageRouteOf st.spaces space pages p.id))
        | p <- either (\e -> e.resolved) identity (pagesAt space pages pagePath)
        , Just p.id /= rootPage space
        ]
      _ -> []

-- | The tab's title while nothing of a route is shown yet: the wiki's bare
-- name.
bareTitle :: Text
bareTitle = "Wiki"

documentTitle :: State m -> Text
documentTitle st | st.route == Home && not (isShut st) && st.session.homePage.title /= "Spaces" = st.session.homePage.title <> " · Wiki"
-- A page of a space that asks for a passkey or the password each time it
-- is opened is titled by its space alone: the browser keeps a page's
-- title in its history and its tabs' lists after the reader has left the
-- space, where nothing of the space is to stay decrypted.
documentTitle st
  | InSpace _ space _ <- st.here
  , isJust (Space.gateOf st.spaces space.id) =
      space.name <> " · Wiki"
documentTitle st = case reverse (map fst (crumbs st)) of
  -- A space that cannot be shown has no name to show either: the content
  -- in its place says why.
  [] -> case st.here of
    SpaceFailed _ _ Forbidden -> "Private · Wiki"
    SpaceFailed _ _ NotFound -> "Not found · Wiki"
    Following _ (Just NotFound) -> "Not found · Wiki"
    _ -> "Wiki"
  names -> mconcat (intersperse " · " (take 2 names)) <> " · Wiki"

-- | What the page says about itself ("Wiki.App.Head"): its title; for a
-- public page in a space (the space's own route, a page of its posts, or a
-- page), what a link preview shows; and on every page of a public blog,
-- where its feeds are.
headOf :: State m -> Head
headOf st = Head {title = documentTitle st, preview, feeds, icon = faviconOf st}
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
      (Home, InSpace [] space pages) | public space, Just p <- homeOf space pages >>= shownPage -> Just (ofPage space p (href Home))
      _ | isShut st -> Nothing
      (Space path, InSpace _ space pages) | public space -> Just (ofSpace path space pages)
      (Posts path _, InSpace _ space pages) | public space -> Just (ofSpace path space pages)
      (Page path pagePath, InSpace _ space pages)
        | public space
        , Just p <- currentPageOf space pages pagePath >>= shownPage ->
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

-- | The tab's icon for what is shown ("Wiki.App.Favicon", WP5.45 of
-- docs/PLAN.md): a space's own on its routes, and the wiki's elsewhere.
-- A closed wiki shows its logo to someone who has not signed in: the home's
-- icon is not theirs to fetch.
faviconOf :: State m -> Favicon
faviconOf st
  | isShut st = defaultFavicon
  | otherwise = case st.here of
      InSpace _ space _ | not (homeSpace ctx space.id) -> spaceFavicon st.icons space
      _ -> homeFavicon st.icons st.home
  where
    ctx = context st

-- | How much an archive holds, in words for a person to read.
archiveSummary :: Archive -> Text
archiveSummary a =
  T.intercalate
    ", "
    [ counted (length a.users) "user" "users"
    , counted (length (withoutHomeDocument a).spaces) "space" "spaces"
    , counted (length a.pages) "page" "pages"
    , counted (sum [length p.attachments | p <- a.pages]) "attachment" "attachments"
    , counted (sum [length t.comments | ts <- Map.elems a.threads, t <- ts]) "comment" "comments"
    ]
  where
    counted :: Int -> Text -> Text -> Text
    counted n singular plural = show n <> " " <> if n == 1 then singular else plural

-- | The space a route is in, by its path, for the gates of encrypted spaces
-- ('Wiki.App.Backend.Encrypted.readerAt'): 'Just' 'Nothing' for a route
-- outside every space, and 'Nothing' for a page's permanent address, which
-- leads on to the page's own route without leaving where the reader was.
routeSpace :: Route -> Maybe (Maybe [Slug])
routeSpace = \case
  Space p -> inside p
  Posts p _ -> inside p
  SpacePages p -> inside p
  Page p _ -> inside p
  EditPage p _ -> inside p
  PageSource p _ -> inside p
  LivePreview p _ -> inside p
  NewPage p _ -> inside p
  PageHistory p _ _ _ -> inside p
  PageSlides p _ _ _ -> inside p
  PageAtVersion p _ _ -> inside p
  NewSpace p -> Just p
  Search _ p _ -> Just p
  PermanentLink _ _ -> Nothing
  Home -> outside
  EditHome -> outside
  HomeSource -> outside
  HomeHistory _ _ -> outside
  HomeSlides _ _ -> outside
  Unknown -> outside
  Admin _ -> outside
  Invite _ -> outside
  ResetPassword _ -> outside
  VerifyEmail _ -> outside
  Unsubscribe _ -> outside
  AssistantSettings -> outside
  WhatsNewPage -> outside
  UserSpaces -> outside
  where
    inside = Just . Just
    outside = Just Nothing

-- | Why nothing can be written in the space shown, while a conversion of
-- it runs ('Wiki.Core.Offered.refusalOf'): the views draw no control that
-- writes then ("Wiki.App.View.Common"'s 'writable'), and this says why,
-- above them.
conversionNotice :: State m -> Maybe Text
conversionNotice st = case st.here of
  InSpace _ space _ -> Offered.refusalOf Offered.Write (chainOf (context st) space.id)
  _ -> Nothing
