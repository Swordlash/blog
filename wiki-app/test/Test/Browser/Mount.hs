-- | Mounting the application for a browser test: over a fresh copy of the
-- demo, as one of its users or nobody, at a route, with a router of its own
-- that keeps the route in the fragment ('Router.newHashRouter'), so that a
-- test navigating does not move the test page itself to another path.
module Test.Browser.Mount
  ( start
  , startWith
  , clickButton
  , slugs
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.NT (type (~>) (..))
import Halogen qualified as H
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Hspec.Halogen
import Wiki.App (component, input)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
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
  wiki <- unsafeIOToPageM (newMemWiki ((demoState demoNow) {current = UserId <$> who}))
  router <- unsafeIOToPageM testRouter
  unsafeIOToPageM forgetStorage
  unsafeIOToPageM (Router.redirect router at)
  ui <- mount m (H.hoist (NT (runMemWiki wiki)) component) (input router)
  pure (ui, wiki)

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
