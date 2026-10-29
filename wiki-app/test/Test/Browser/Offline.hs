{-# LANGUAGE TemplateHaskell #-}

-- | Reading offline and installing (WP4.17 of docs/PLAN.md), as the
-- application shows them: a page the service worker served from what it
-- kept says so and since when, with the offline notice, until the reader
-- goes elsewhere, over the server's backend only; "Install" is in the
-- header where the browser offers to install the wiki, and asks the browser
-- when pressed; and signing out lets go of the pages and answers kept.
--
-- The service worker itself is JavaScript (web/src/sw.js), tested in a real
-- browser against a real server by the smoke test
-- (toolchain/smoke-test-server.mjs), which goes offline and reloads. Here
-- the page is given what the worker and the browser would give it
-- (test/jsbits/test-offline.js): the mark in its head, the offer, and the
-- caches.
module Test.Browser.Offline (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.User (Standing (..))

$( browserJS
     ["jsbits/test-offline.js"]
     [ ("js_offline_copy", "wiki_test_offline_copy", Unsafe, [t|JSText -> IO ()|])
     , ("js_navigator_online", "wiki_test_navigator_online", Unsafe, [t|Int -> IO ()|])
     , ("js_offer_install", "wiki_test_offer_install", Unsafe, [t|JSText -> IO ()|])
     , ("js_install_prompts", "wiki_test_install_prompts", Unsafe, [t|IO Int|])
     , ("js_keep_reads", "wiki_test_keep_reads", Safe, [t|IO ()|])
     , ("js_kept_kinds", "wiki_test_kept_kinds", Safe, [t|IO JSText|])
     , ("js_forget_kept", "wiki_test_forget_kept", Safe, [t|IO ()|])
     ]
 )

-- | The page as the worker serves it offline: kept at this time, with the
-- browser offline; or, given 'Nothing', from the network, online.
servedOffline :: Maybe Text -> PageM s ()
servedOffline at = unsafeIOToPageM $ do
  js_offline_copy (toJSText (fromMaybe "" at))
  -- -1: as the browser says; 0: offline.
  js_navigator_online (maybe (-1) (const 0) at)

-- | The browser's offer to install the wiki, answered so; or withdrawn.
offerInstall :: Maybe Text -> PageM s ()
offerInstall = unsafeIOToPageM . js_offer_install . toJSText . fromMaybe ""

keptKinds :: PageM s Text
keptKinds = unsafeIOToPageM (fromJSText <$> (evaluate =<< js_kept_kinds))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  describe "a page the service worker kept" $ do
    it "says it is an offline copy and since when, with the offline notice, until the reader goes elsewhere" $ runPage $ do
      serverStarts
      serveDemo
      servedOffline (Just "2026-10-20T08:30:00Z")
      ui <- startServer m (SpacePages (slugs ["docs"]))
      line <- find ui ".wiki-content > .offline-copy"
      textContent line >>= (`shouldSatisfy` (T.isPrefixOf "You are reading an offline copy from " . T.strip))
      -- The reader's time: an island, as every time the wiki shows.
      (findIn line ".wiki-time" >>= (`getAttribute` "datetime")) `shouldReturn` Just "2026-10-20T08:30:00Z"
      find ui ".offline-notice" >>= (`shouldHaveText` "You are offline: the wiki cannot be reached until the connection is back.")
      find ui ".wiki-brand" >>= click
      find ui ".directory h1" >>= (`shouldHaveText` "Spaces")
      length <$> findAll ui ".offline-copy" `shouldReturn` 0
      unmount ui
      servedOffline Nothing
      serverStops

    it "says nothing of it for a page from the network" $ runPage $ do
      serverStarts
      serveDemo
      ui <- startServer m Home
      find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
      length <$> findAll ui ".offline-copy" `shouldReturn` 0
      length <$> findAll ui ".offline-notice" `shouldReturn` 0
      unmount ui
      serverStops

    it "says nothing of it in the demo, whose wiki is in the browser" $ runPage $ do
      servedOffline (Just "2026-10-20T08:30:00Z")
      ui <- start m Nothing Home
      _ <- find ui ".wiki-footer"
      length <$> findAll ui ".offline-copy" `shouldReturn` 0
      length <$> findAll ui ".offline-notice" `shouldReturn` 0
      unmount ui
      servedOffline Nothing

  describe "installing" $ do
    it "offers Install in the header where the browser does, and asks the browser when it is pressed" $ runPage $ do
      serverStarts
      serveDemo
      ui <- startServer m Home
      find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
      length <$> findAll ui ".install-app" `shouldReturn` 0
      offerInstall (Just "accepted")
      find ui ".wiki-header .install-app" >>= click
      eventually (unsafeIOToPageM js_install_prompts `shouldReturn` 1)
      -- The offer is spent, whatever the answer.
      eventually (length <$> findAll ui ".install-app" `shouldReturn` 0)
      unmount ui
      serverStops

    it "offers it in the demo too, from an offer made before the program started" $ runPage $ do
      offerInstall (Just "dismissed")
      ui <- start m Nothing Home
      _ <- find ui ".wiki-header .install-app"
      offerInstall Nothing
      eventually (length <$> findAll ui ".install-app" `shouldReturn` 0)
      unmount ui

  describe "signing out" $
    it "lets go of the pages and the API's answers kept for reading offline, and keeps the application" $
      runPage $ do
        serverStarts
        serveDemo
        unsafeIOToPageM (evaluate =<< js_keep_reads)
        keptKinds `shouldReturn` "answers app pages"
        answerWith "DELETE" "api/v1/session" 200 SessionInfo {user = Nothing, groups = mempty, grants = mempty, standing = NotSignedIn, providers = [], exports = [], boxes = []}
        ui <- startServer m Home
        find ui ".account .sign-out" >>= click
        _ <- find ui ".sign-in-toggle"
        map (\r -> r.url) . filter (\r -> r.method == "DELETE") <$> asked `shouldReturn` ["api/v1/session"]
        eventually (keptKinds `shouldReturn` "app")
        unmount ui
        unsafeIOToPageM (evaluate =<< js_forget_kept)
        serverStops
