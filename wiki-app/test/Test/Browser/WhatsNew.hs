{-# LANGUAGE TemplateHaskell #-}

-- | The page "What's new?" in a browser (WP5.66 of docs/PLAN.md), over a
-- server that has it: the link at the very bottom of the sidebar, the page
-- with the server's version, its build date and the entries, newest first,
-- each headed by a link to its pull request and rendered as a page is (a
-- listing highlighted, a spoiler hidden); the dot on the link while the
-- server has an entry newer than the newest the reader has seen, which
-- opening the page clears; no link where the server's page is off; and the
-- demo's page, the changelog compiled into the application (WP5.71). A
-- link in an entry to a place on the page, or a footnote's reference to
-- its note, scrolls there and stays on the page, and each entry's ids start
-- with its number, so two entries with the same sections have no id in
-- common.
module Test.Browser.WhatsNew (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (answerWith, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Api (WikiApi (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.WhatsNew (WhatsNew (..), WhatsNewEntry (..), newestEntry, pullRequestUrl)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..), Session (..))
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Demo.WhatsNew (demoWhatsNew)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (UserId (..))

-- The address's fragment and where an element is in the window
-- (test/jsbits/test-location.js, test/jsbits/test-layout.js).
$( browserJS
     ["jsbits/test-location.js", "jsbits/test-layout.js"]
     [ ("js_location_hash", "wiki_test_location_hash", Safe, [t|IO JSText|])
     , ("js_box", "wiki_test_box", Safe, [t|JSText -> IO JSText|])
     ]
 )

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  it "links to the page at the very bottom of the sidebar, on the front page and in a space" $ runPage $ do
    serving m (Just 0) news
    ui <- startServer m Home
    newsLink <- find ui "nav.wiki-sidebar > .sidebar-whats-new:last-child > a.whats-new-link"
    newsLink `shouldHaveText` "What's new?"
    getAttribute newsLink "href" >>= (`shouldSatisfy` maybe False (T.isInfixOf "/whats-new/"))
    find ui ".space-card-link[href$='#/s/docs/']" >>= click
    eventually (find ui "nav.space-sidebar > .sidebar-whats-new:last-child > a.whats-new-link" >>= (`shouldHaveText` "What's new?"))

  it "shows the server's version and build date, then the entries newest first, each linking to its pull request" $ runPage $ do
    serving m (Just 0) news
    ui <- startServer m WhatsNewPage
    find ui ".whats-new h1" >>= (`shouldHaveText` "What's new?")
    find ui ".whats-new-version" >>= (`shouldHaveText` "v0.3.0-12-gc728d7f")
    built <- find ui ".whats-new-built"
    built `shouldHaveText` "5 November 2026"
    getAttribute built "datetime" `shouldReturn` Just "2026-11-05T12:00:00Z"
    titles <- findAll ui ".whats-new-entry .whats-new-title a"
    traverse textContent titles `shouldReturn` ["#158 A copy button on code blocks", "#157 A deploy that checks its TeX once"]
    traverse (`getAttribute` "href") titles `shouldReturn` [Just (pullRequestUrl 158), Just (pullRequestUrl 157)]
    newest <- find ui ".whats-new-entry[data-pr=\"158\"]"
    findIn newest "h3" >>= (`shouldHaveText` "New features")
    -- Rendered as a page is: the listing is the islands', highlighted, with
    -- its copy button; the spoiler hidden until clicked.
    _ <- findIn newest ".code-block > pre.wiki-code > code.hljs span"
    _ <- findIn newest ".code-block > button.code-copy"
    findIn newest "span.spoiler" >>= (`shouldHaveText` "the butler")
    find ui ".whats-new-entry[data-pr=\"157\"] h3" >>= (`shouldHaveText` "Bug fixes")
    -- The link in the sidebar is the current page's, and has no dot.
    newsLink <- find ui "a.whats-new-link"
    getAttribute newsLink "aria-current" `shouldReturn` Just "page"
    getAttribute newsLink "data-unseen" `shouldReturn` Nothing

  it "follows a link to a place in an entry on the page, to that entry's own heading" $ runPage $ do
    serving m (Just 0) news
    ui <- startServer m WhatsNewPage
    -- Both entries have a "Bug fixes" section, each with an id of its own.
    _ <- find ui ".whats-new-entry[data-pr=\"158\"] h3#pr-158-bug-fixes"
    _ <- find ui ".whats-new-entry[data-pr=\"157\"] h3#pr-157-bug-fixes"
    length <$> findAll ui "#bug-fixes" `shouldReturn` 0
    toFixes <- find ui ".whats-new-entry[data-pr=\"158\"] a[href='#pr-158-bug-fixes']"
    toFixes `shouldHaveText` "the fixes"
    click toFixes
    -- Still the page "What's new?", under the test's router (which keeps
    -- the route in the fragment), not the front page the page's <base
    -- href> would have led to, and the heading is in the window.
    find ui ".whats-new h1" >>= (`shouldHaveText` "What's new?")
    unsafeIOToPageM (fromJSText <$> js_location_hash) `shouldReturn` "#/whats-new/"
    eventually $ do
      box <- unsafeIOToPageM (fromJSText <$> js_box (toJSText "#pr-158-bug-fixes"))
      case mapMaybe (readMaybe . T.unpack) (T.words box) :: [Double] of
        [top, bottom, height] -> (top >= 0 && bottom <= height) `shouldBe` True
        _ -> expectationFailure ("no box for the heading: " <> box)

  -- Under the test's router the fragment is the route's, so a note gets no
  -- history entry of its own there ('Wiki.App.Browser.followNote'); what is
  -- checked is that the reference, whose id has its entry's prefix, is
  -- taken for one and leads to its own entry's note.
  it "follows a footnote's reference in an entry to that entry's own note" $ runPage $ do
    serving m (Just 0) news
    ui <- startServer m WhatsNewPage
    reference <- find ui ".whats-new-entry[data-pr=\"157\"] sup.footnote-ref a"
    getAttribute reference "href" `shouldReturn` Just "#pr-157-fn-1"
    getAttribute reference "id" `shouldReturn` Just "pr-157-fnref-1"
    _ <- find ui ".whats-new-entry[data-pr=\"157\"] #pr-157-fn-1"
    click reference
    find ui ".whats-new h1" >>= (`shouldHaveText` "What's new?")
    unsafeIOToPageM (fromJSText <$> js_location_hash) `shouldReturn` "#/whats-new/"
    eventually $ do
      box <- unsafeIOToPageM (fromJSText <$> js_box (toJSText "#pr-157-fn-1"))
      case mapMaybe (readMaybe . T.unpack) (T.words box) :: [Double] of
        [top, bottom, height] -> (top >= 0 && bottom <= height) `shouldBe` True
        _ -> expectationFailure ("no box for the note: " <> box)

  it "marks the link while the server has an entry newer than the newest the reader has seen, and opening the page clears it" $ runPage $ do
    -- Seen up to #157: #158 is new.
    serving m (Just 157) news
    ui <- startServer m Home
    newsLink <- find ui "a.whats-new-link"
    eventually (getAttribute newsLink "data-unseen" `shouldReturn` Just "true")
    click newsLink
    find ui ".whats-new h1" >>= (`shouldHaveText` "What's new?")
    eventually (seenNow m `shouldReturn` Just (Right 158))
    find ui ".wiki-brand" >>= click
    _ <- find ui ".directory .space-card"
    find ui "a.whats-new-link" >>= \l -> getAttribute l "data-unseen" `shouldReturn` Nothing

  it "marks the link for a reader who never opened the page, and not once they have seen the newest" $ runPage $ do
    serving m Nothing news
    ui <- startServer m Home
    eventually (find ui "a.whats-new-link" >>= \l -> getAttribute l "data-unseen" `shouldReturn` Just "true")
    unmount ui
    serving m (Just 158) news
    again <- startServer m Home
    find again "a.whats-new-link" >>= \l -> getAttribute l "data-unseen" `shouldReturn` Nothing

  it "has no link, and the page is not found, where the server's page is off" $ runPage $ do
    serverStarts
    serveDemo
    ui <- startServer m Home
    length <$> findAll ui ".whats-new-link" `shouldReturn` 0
    unmount ui
    answerWith "GET" (endpointUrl (\e -> e.whatsNew)) 404 ("not found" :: Text)
    off <- startServer m WhatsNewPage
    eventually (find off ".not-found h1" >>= (`shouldHaveText` "Not found"))

  it "links in the demo too, to the changelog compiled into the application, newest first" $ runPage $ do
    ui <- start m Nothing Home
    find ui "nav.wiki-sidebar > .sidebar-whats-new:last-child > a.whats-new-link" >>= click
    find ui ".whats-new h1" >>= (`shouldHaveText` "What's new?")
    titles <- findAll ui ".whats-new-entry .whats-new-title a"
    traverse textContent titles `shouldReturn` ["#" <> show e.pr <> " " <> e.title | e <- demoWhatsNew.entries]
    length titles `shouldSatisfy` (\n -> n > 0 && n <= 12)
  where
    news =
      WhatsNew
        { version = "v0.3.0-12-gc728d7f"
        , built = UTCTime (fromGregorian 2026 11 5) 43200
        , entries =
            [ WhatsNewEntry
                { pr = 158
                , url = pullRequestUrl 158
                , title = "A copy button on code blocks"
                , markdown = "### New features\n\n- A button copies the code:\n\n  ```haskell\n  main :: IO ()\n  main = pure ()\n  ```\n\n- The murderer is ||the butler||.\n- See [the fixes](#bug-fixes).\n\n### Bug fixes\n\n- The button no longer copies the line numbers."
                }
            , WhatsNewEntry {pr = 157, url = pullRequestUrl 157, title = "A deploy that checks its TeX once", markdown = "### Bug fixes\n\n- The deploy no longer hangs.[^1]\n\n[^1]: It waited on a question no one saw."}
            ]
        }

-- | A server with the demo's wiki that has the page "What's new?" with
-- these entries, to a reader whose browser has seen up to this entry
-- ('Nothing': never opened the page).
serving :: forall m -> (Specs m) => Maybe Int -> WhatsNew -> PageM s ()
serving m seen answered = do
  unsafeIOToPageM . runTest $ case seen of
    Nothing -> Storage.removeItem LocalStorage seenKey :: m ()
    Just n -> Storage.setItem LocalStorage seenKey n
  serverStarts
  serveDemo
  me <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki session
  answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing, providers = [], exports = [], boxes = [], homePage = me.homePage, mathMacros = Nothing, assistantServices = [], whatsNew = Just (newestEntry answered)}
  answerWith "GET" (endpointUrl (\e -> e.whatsNew)) 200 answered

-- | What the reader's browser keeps as the newest entry seen.
seenNow :: forall m -> (Specs m) => PageM s (Maybe (Either Text Int))
seenNow m = unsafeIOToPageM (runTest (Storage.getItem LocalStorage seenKey :: m (Maybe (Either Text Int))))

-- | The key the shell keeps it under.
seenKey :: Text
seenKey = "whats-new-seen"
