-- | The fourth part of the demo's smoke test: the demo as an application
-- (WP4.17). Its manifest and icons, its service worker taking over the
-- page, Chromium's own check that it can be installed, and the page read
-- again offline from what the worker kept, with the worker's offline page
-- for a page never read.
--
-- The page's context lets service workers in, as a reader's browser does,
-- and holds nothing back: a request a worker makes, or answers from its
-- cache, passes no route of the test's.
module Demo.Offline (spec) where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), Value, decodeStrict, object, withObject, (.:))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Demo.Site
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Network.URI (parseURI, parseURIReference, relativeTo)
import Wiki.Smoke.Demo

spec :: Site -> SpecWith Playwright
spec site =
  it "is installable under its base path, and reads offline what it read, with an offline page for the rest" $ \pw -> do
    -- What a browser reads to install it: the manifest, linked from the
    -- page, and its icons.
    (_, manifestBytes) <- fetch site "/manifest.webmanifest"
    manifest :: Manifest <- maybe (fail "manifest.webmanifest is not a manifest") pure (decodeStrict manifestBytes)
    manifest.display `shouldBe` "standalone"
    manifest.startUrl `shouldBe` "./"
    forM_ manifest.icons $ \icon -> do
      (status, _) <- fetch site ("/" <> icon)
      expect (status == 200) ("the manifest's icon " <> Text.unpack icon)
    withContext pw demoContext {serviceWorkers = True} $ \ctx -> do
      standIns ctx
      page <- newPage ctx
      withFailureContext page $ do
        visit page (address site.demo "/")
        waitQuiet page
        count (withText "Spaces" (locator page "#app .wiki-home .page-view h1")) `shouldReturn` 1
        getAttribute (locator page "head link[rel=\"manifest\"]") "href" `shouldReturn` Just "./manifest.webmanifest"
        -- The worker takes the page over: the browser's work, a condition.
        waitForFunction page "navigator.serviceWorker.controller !== null"
        settle page
        -- Installable where the page is served: the worker's scope is the
        -- site's base path, and Chromium reads the manifest from under it
        -- with no errors, its start and scope there too, and finds nothing
        -- that keeps the page from being installed.
        -- Page.getInstallabilityErrors is Chromium's own check, the one
        -- behind its "Install" offer.
        evaluate page "(async () => (await navigator.serviceWorker.getRegistration()).scope)()" `shouldReturn` address site.demo "/"
        read' :: AppManifest <- cdp page "Page.getAppManifest" (object [])
        read'.address `shouldBe` address site.demo "/manifest.webmanifest"
        read'.errors `shouldBe` []
        declared :: Declared <- maybe (fail ("the manifest Chromium read: " <> Text.unpack read'.text)) pure (decodeStrict (Text.encodeUtf8 read'.text))
        resolve read'.address declared.startUrl `shouldBe` Just (address site.demo "/")
        resolve read'.address declared.scope `shouldBe` Just (address site.demo "/")
        Installability blockers <- cdp page "Page.getInstallabilityErrors" (object [])
        blockers `shouldBe` []
        -- The worker keeps the page it did not serve (the one that
        -- installed it) when the page asks, and a page loaded while it
        -- serves the page as it comes: the worker's caches, conditions.
        let kept path = eventually page (evaluateWith page keptPage (address site.demo path) `shouldReturn` True)
        kept "/"
        visit page (address site.demo "/s/blog/p/hello-world/")
        waitQuiet page
        count (withText "Hello" (locator page "#app .wiki-content h1")) `shouldReturn` 1
        kept "/s/blog/p/hello-world/"
        -- Offline: the page again, from what the worker kept, and the
        -- program started on it from the application's files the worker
        -- kept. The demo's wiki is in the browser, so it says nothing of an
        -- offline copy.
        setOffline ctx True
        reload page
        waitStarted page
        waitQuiet page
        count (withText "Hello" (locator page "#app .wiki-content h1")) `shouldReturn` 1
        count (locator page "#app .offline-copy") `shouldReturn` 0
        -- A page never read here: the worker's offline page, which lists
        -- the pages it kept, and runs no program.
        goto page (address site.demo "/s/docs/")
        textContent (locator page ".offline-page h1") >>= (`shouldSatisfy` Text.isInfixOf "This page is not available offline")
        click (withText "Hello" (locator page ".offline-page .offline-pages a"))
        waitStarted page
        waitQuiet page
        count (withText "Hello" (locator page "#app .wiki-content h1")) `shouldReturn` 1
        setOffline ctx False
        visit page (address site.demo "/s/docs/")
        waitQuiet page
        textContent (locator page "#app .sidebar-space-name") `shouldReturn` "Docs"
        count (locator page ".offline-page") `shouldReturn` 0
        report ("the demo is installable under " <> basePath site.demo <> ", and reads offline what it read")
        -- Offline, what is not kept fails to load (the photograph from
        -- Wikimedia Commons); that is what offline is.
        nothingWrongBut ["ERR_INTERNET_DISCONNECTED", "Failed to load resource", "404"] page
  where
    -- An address of the manifest's, resolved against the manifest's own.
    resolve base relative = do
      b <- parseURI (Text.unpack base)
      r <- parseURIReference (Text.unpack relative)
      pure (Text.pack (show (r `relativeTo` b)))

-- | Whether one of the worker's caches of pages holds an address.
keptPage :: Text
keptPage =
  "async (address) => {\
  \  for (const name of await caches.keys()) {\
  \    if (name.startsWith('wiki-pages ') && (await (await caches.open(name)).match(address))) return true;\
  \  }\
  \  return false;\
  \}"

-- | What the suite reads of the manifest as served.
data Manifest = Manifest {display :: Text, startUrl :: Text, icons :: [Text]}

instance FromJSON Manifest where
  parseJSON = withObject "Manifest" $ \o -> do
    display <- o .: "display"
    startUrl <- o .: "start_url"
    icons <- o .: "icons" >>= mapM (withObject "icon" (.: "src"))
    pure Manifest {display, startUrl, icons}

-- | Its start and scope, as Chromium read them.
data Declared = Declared {startUrl :: Text, scope :: Text}

instance FromJSON Declared where
  parseJSON = withObject "Declared" $ \o -> Declared <$> o .: "start_url" <*> o .: "scope"

-- | Page.getAppManifest's answer: the manifest's address, its errors, and
-- its text.
data AppManifest = AppManifest {address :: Text, errors :: [Value], text :: Text}

instance FromJSON AppManifest where
  parseJSON = withObject "AppManifest" $ \o -> AppManifest <$> o .: "url" <*> o .: "errors" <*> (fromMaybe "" <$> o .: "data")

-- | Page.getInstallabilityErrors's answer.
newtype Installability = Installability [Value]

instance FromJSON Installability where
  parseJSON = withObject "Installability" $ \o -> Installability <$> o .: "installabilityErrors"
