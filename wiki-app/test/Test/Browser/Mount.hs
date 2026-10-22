-- | Mounting the application for a browser test: over a fresh copy of the
-- demo, as one of its users or nobody, at a route, with a router of its own
-- that keeps the route in the fragment ('Router.newHashRouter'), so that a
-- test navigating does not move the test page itself to another path.
module Test.Browser.Mount
  ( start
  , startWith
  , startChanged
  , adopt
  , startKept
  , startKeptWith
  , clickButton
  , slugs
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef, modifyIORef')
import Data.NT (type (~>) (..))
import Halogen qualified as H
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database, MonadIndexedDB)
import Wiki.App (component, input)
import Wiki.App.Backend.Mem (Opened (..), newMemWiki, openMemWiki, runMemWiki, runMemWikiWith, switchUser)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
#if defined(wasm32_HOST_ARCH)
import Halogen.VDom.DOM.Monad (runBrowserDOM)
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.App.Route (route)
#endif
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Slug (Slug, mkSlug)

-- | The shell, mounted over a fresh demo as someone (by user id, or nobody),
-- at a route, with nothing in the browser's local storage.
start
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m)
  => Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
start m who at = fst <$> startWith m who at

-- | 'start', and the wiki it runs over, for a test to read what the
-- application wrote, or to write behind its back.
startWith
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m)
  => Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m, IORef MemState)
startWith m who at = do
  (wiki, router) <- prepare who at
  ui <- mount m (H.hoist (NT (runMemWiki wiki)) component) (input router)
  pure (ui, wiki)

-- | 'start', over the demo changed first: for a test that needs content
-- of its own (a space with macros, a page with formulas).
startChanged
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m)
  => (MemState -> MemState)
  -> Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
startChanged m change who at = do
  (wiki, router) <- prepare who at
  unsafeIOToPageM (modifyIORef' wiki change)
  mount m (H.hoist (NT (runMemWiki wiki)) component) (input router)

-- | 'start', in a container that holds the shell's HTML for the route
-- already ('htmlContainer'), as a prerendered page does: the shell adopts
-- it ('hydrate').
adopt
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m)
  => Element s
  -> Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
adopt m page who at = do
  (wiki, router) <- prepare who at
  hydrate m page (H.hoist (NT (runMemWiki wiki)) component) (input router)

-- | A fresh demo, as someone, and a router at the route, with nothing in
-- the browser's local storage.
prepare :: Maybe Text -> Route -> PageM s (IORef MemState, Router Route)
prepare who at = do
  wiki <- unsafeIOToPageM (newMemWiki ((demoState demoNow) {current = UserId <$> who}))
  router <- unsafeIOToPageM testRouter
  unsafeIOToPageM forgetStorage
  unsafeIOToPageM (Router.redirect router at)
  pure (wiki, router)

-- | The shell mounted as the demo's page mounts it: over the wiki kept in
-- a database (read back, or the demo written out into it), writing through
-- to it, as someone (by user id), or as the demo starts, at a route. Two of
-- these on one database are a page and the same page reloaded.
startKept
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => Database
  -> Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
startKept m db who at = fst <$> startKeptWith m db who at

-- | 'startKept', and the wiki it runs over, for a test to read it.
startKeptWith
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => Database
  -> Maybe Text
  -> Route
  -> PageM s (Mounted s Shell.Query Void m, Opened)
startKeptWith m db who at = do
  opened <- unsafeIOToPageM (runTest (openMemWiki db (demoState demoNow) :: m Opened))
  for_ who $ \login -> unsafeIOToPageM (runMemWiki opened.wiki (switchUser (Just (UserId login))))
  router <- unsafeIOToPageM testRouter
  unsafeIOToPageM forgetStorage
  unsafeIOToPageM (Router.redirect router at)
  ui <- mount m (H.hoist (NT (runMemWikiWith opened.store opened.wiki)) component) (input router)
  pure (ui, opened)

-- | A router that keeps the route in the test page's fragment. Natively
-- there is no browser to make one in, and the suite only reports that it
-- skipped.
testRouter :: IO (Router Route)
#if defined(wasm32_HOST_ARCH)
testRouter = runBrowserDOM (Router.newHashRouter Unknown route)
#else
testRouter = panic "the shell's browser tests run in a browser"
#endif

-- | Forget what the application keeps in the browser's local storage (the
-- editor's choice of a preview side by side), which outlives a test's page,
-- so that each test starts as a new reader would.
forgetStorage :: IO ()
#if defined(wasm32_HOST_ARCH)
forgetStorage = runBrowserDOM (Storage.clear LocalStorage)
#else
forgetStorage = pass
#endif

-- | Click the button among those matching a selector that says this.
clickButton :: Mounted s q o m -> Text -> Text -> PageM s ()
clickButton ui selector label = do
  buttons <- findAll ui selector
  labelled <- filterM (fmap (== label) . textContent) buttons
  case labelled of
    b : _ -> click b
    [] -> expectationFailure ("no " <> selector <> " says " <> label)

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)
