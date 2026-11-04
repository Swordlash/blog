{-# LANGUAGE TemplateHaskell #-}

-- | Spoilers and listings that scroll in a page, in a browser (WP5.62 of
-- docs/PLAN.md, issue #152), over the demo's wiki: an inline spoiler
-- blurred until a click or Enter shows it, and hidden again by a second
-- click; a block spoiler closed until its summary is clicked, nested ones
-- each on their own, and the open ones open again when the page is shown
-- again in this browser; a spoiler that wraps a section opened by its
-- entry in the page's contents and by a link to its heading, and marked
-- in the contents as the section read only while it is open
-- (jsbits/toc.js); and a code
-- block with @rows=3@ three lines high, scrolling inside. The behaviour is
-- the islands' script's (web/src/islands.js), which the test page loads.
module Test.Browser.Spoilers (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, startChanged, startChangedAgain)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), insertPage)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Space qualified as Core

-- How the style sheet draws an element (test/jsbits/test-style.js), and a
-- code block's heights (test/jsbits/test-layout.js).
$( browserJS
     ["jsbits/test-style.js", "jsbits/test-layout.js"]
     [ ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_listing", "wiki_test_listing", Safe, [t|JSText -> IO JSText|])
     , ("js_scroll_into_viewPromise", "wiki_test_scroll_into_view", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_scroll_toPromise", "wiki_test_scroll_to", Safe, [t|Int -> IO (Promise ())|])
     ]
 )

js_scroll_to :: Int -> IO ()
js_scroll_to a1 = if inBrowser then wait =<< js_scroll_toPromise a1 else pure inert

js_scroll_into_view :: JSText -> IO ()
js_scroll_into_view a1 = if inBrowser then wait =<< js_scroll_into_viewPromise a1 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = describe "spoilers and listings in a page" $ do
  it "blurs an inline spoiler until a click shows it, hides it on a second, and shows it on Enter" $ runPage $ do
    ui <- page m "Before ||the butler|| did it."
    spoiler <- find ui ".page-body span.spoiler"
    spoiler `shouldHaveText` "the butler"
    computedStyle ".page-body span.spoiler" "filter" >>= (`shouldSatisfy` T.isInfixOf "blur")
    computedStyle ".page-body span.spoiler" "user-select" `shouldReturn` "none"
    click spoiler
    eventually $ getAttribute spoiler "class" `shouldReturn` Just "spoiler shown"
    -- The blur fades out, and the computed style follows the transition.
    eventually $ computedStyle ".page-body span.spoiler" "filter" `shouldReturn` "none"
    click spoiler
    eventually $ getAttribute spoiler "class" `shouldReturn` Just "spoiler"
    -- The clicks gave it the focus, as a button has it.
    press "Enter"
    eventually $ getAttribute spoiler "class" `shouldReturn` Just "spoiler shown"
    press "Space"
    eventually $ getAttribute spoiler "class" `shouldReturn` Just "spoiler"

  it "keeps a block spoiler closed until its summary is clicked, nested ones each on their own, and remembers the open ones" $ runPage $ do
    let body = "[[spoiler]]{answer}(The answer)\nForty-two.\n[[/spoiler]]{answer}\n\n[[spoiler]]{outer}(Outer)\nAround.\n[[spoiler]]{inner}(Inner)\nDeep.\n[[/spoiler]]{inner}\n[[/spoiler]]{outer}\n"
        opened ui name = find ui (".page-body details.spoiler[data-spoiler='" <> name <> "']") >>= (`getAttribute` "open")
        summary ui name = find ui (".page-body details.spoiler[data-spoiler='" <> name <> "'] > summary")
    ui <- page m body
    summary ui "answer" >>= (`shouldHaveText` "The answer")
    opened ui "answer" `shouldReturn` Nothing
    find ui ".page-body details.spoiler[data-spoiler='answer'] > p" >>= shouldBeHidden
    summary ui "answer" >>= click
    eventually $ opened ui "answer" `shouldReturn` Just ""
    find ui ".page-body details.spoiler[data-spoiler='answer'] > p" >>= shouldBeVisible
    summary ui "outer" >>= click
    eventually $ opened ui "outer" `shouldReturn` Just ""
    opened ui "inner" `shouldReturn` Nothing
    summary ui "inner" >>= click
    eventually $ opened ui "inner" `shouldReturn` Just ""
    -- The page shown again in this browser: the three open.
    reloaded <- again m body
    eventually $ for_ ["answer", "outer", "inner"] $ \name -> ((\o -> (name, o)) <$> opened reloaded name) `shouldReturn` (name, Just "")
    -- Closed again, and shown again: closed.
    summary reloaded "answer" >>= click
    eventually $ opened reloaded "answer" `shouldReturn` Nothing
    third <- again m body
    eventually $ opened third "outer" `shouldReturn` Just ""
    opened third "answer" `shouldReturn` Nothing

  it "opens a spoiler that wraps a section for its entry in the contents, and for a link to its heading" $ runPage $ do
    let body = "## Intro\n\nText.\n\n[[spoiler]]{solutions}(The solutions)\n## Solutions\n\nThe answer.\n\n### Details\n\nMore.\n[[/spoiler]]{solutions}\n\n## After\n\nSee [the solutions](#solutions)."
        opened ui = find ui ".page-body details.spoiler[data-spoiler='solutions']" >>= (`getAttribute` "open")
    ui <- page m body
    opened ui `shouldReturn` Nothing
    -- The section is in the contents, under its own heading.
    entries <- traverse textContent =<< findAll ui ".page-contents nav a"
    entries `shouldSatisfy` (\es -> "Solutions" `elem` es && "Details" `elem` es)
    find ui ".page-contents nav a[href='#solutions']" >>= click
    eventually $ opened ui `shouldReturn` Just ""
    find ui ".page-body h2#solutions" >>= shouldBeVisible
    find ui ".page-body details.spoiler > summary" >>= click
    eventually $ opened ui `shouldReturn` Nothing
    find ui ".page-body p a[href='#solutions']" >>= click
    eventually $ opened ui `shouldReturn` Just ""

  it "marks a section a spoiler wraps as the one read once it is open and scrolled to, and not while it is closed" $ runPage $ do
    let long = T.intercalate "\n\n" (replicate 30 "A paragraph of text, to take room on the page.")
        -- The spoiler's summary near the top of the window, where it is
        -- clicked; enough after it for its heading to be scrolled to the
        -- top.
        body = "## Intro\n\nA short introduction.\n\n[[spoiler]]{results}(The results)\n## Results\n\n" <> long <> "\n[[/spoiler]]{results}\n\n## After\n\n" <> long
        current ui = do
          marked <- findAll ui ".toc-list a[data-current]"
          ordNub . catMaybes <$> traverse (`getAttribute` "href") marked
        opened ui = find ui ".page-body details.spoiler" >>= (`getAttribute` "open")
    ui <- page m body
    eventually $ current ui `shouldReturn` ["#intro"]
    find ui ".page-body details.spoiler > summary" >>= click
    eventually $ opened ui `shouldReturn` Just ""
    unsafeIOToPageM (evaluate =<< js_scroll_into_view (toJSText ("#results" :: Text)))
    eventually $ current ui `shouldReturn` ["#results"]
    -- Closed, its heading is not read, wherever the window is.
    unsafeIOToPageM (evaluate =<< js_scroll_to 0)
    find ui ".page-body details.spoiler > summary" >>= click
    eventually $ opened ui `shouldReturn` Nothing
    eventually $ current ui `shouldReturn` ["#intro"]
    unsafeIOToPageM (evaluate =<< js_scroll_into_view (toJSText ("#after" :: Text)))
    eventually $ current ui `shouldReturn` ["#after"]

  it "shows three lines of a listing with rows=3, and scrolls inside it" $ runPage $ do
    ui <- page m "```haskell {rows=3}\none = 1\ntwo = 2\nthree = 3\nfour = 4\nfive = 5\nsix = 6\n```"
    _ <- find ui ".page-body pre.code-scroll code"
    measured <- eventually $ do
      found <- listing ".page-body pre.code-scroll"
      case mapMaybe (readMaybe . T.unpack) (T.words found) :: [Double] of
        [content, line, scroll, client] -> do
          scroll `shouldSatisfy` (> client)
          pure (content, line)
        other -> expectationFailure ("no listing measured: " <> show other) >> pure (0, 0)
    let (content, line) = measured
    abs (content - 3 * line) `shouldSatisfy` (<= 2)

-- | The demo's Projects space with a page of this text, shown to an
-- administrator.
page
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> PageM s (Mounted s Shell.Query Void m)
page m body = startChanged m (withPage "Spoilers" body) (Just "user-admin") spoilersPage

-- | 'page' shown again in this browser, keeping its local storage.
again
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> PageM s (Mounted s Shell.Query Void m)
again m body = startChangedAgain m (withPage "Spoilers" body) (Just "user-admin") spoilersPage

-- | The page the tests write, under the demo's Projects space.
spoilersPage :: Route
spoilersPage = Page (slugs ["team", "projects"]) (slugs ["spoilers"])

-- | The demo with a page of this title and text in its Projects space.
withPage :: Text -> Text -> MemState -> MemState
withPage title body st = case head (filter (\s -> s.name == "Projects") (Map.elems st.spaces)) of
  Just (s :: Core.Space) -> fst (insertPage s.id Nothing title body demoNow st)
  Nothing -> panic "the demo has no space Projects"

-- | A property the style sheet gives the first element a selector finds.
computedStyle :: Text -> Text -> PageM s Text
computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))

-- | A code block's heights ('wiki_test_listing').
listing :: Text -> PageM s Text
listing selector = unsafeIOToPageM (fromJSText <$> js_listing (toJSText selector))
