{-# LANGUAGE TemplateHaskell #-}

-- | A page presented as slides, in a browser, over the demo's wiki: offered
-- from a page written as a deck, one slide at a time, moved through by the
-- keys with the slide kept in the address, its islands drawn on the slide
-- shown, its notes and its overview opened and closed, its steps shown and
-- hidden in place, and left by its link back to the page.
module Test.Browser.Slides (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-location.js", "jsbits/test-keys.js"]
     [ ("js_location_hash", "wiki_test_location_hash", Unsafe, [t|IO JSText|])
     , ("js_dispatch_key", "wiki_test_dispatch_key", Unsafe, [t|JSText -> IO Bool|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "offers a deck from its page, shows one slide at a time, and goes back to the page" $ runPage $ do
    ui <- start m Nothing (Page docs presentations)
    find ui ".page-body h1" >>= (`shouldHaveText` "Presentations")
    actions <- traverse textContent =<< findAll ui ".page-view .actions > *"
    actions `shouldBe` ["View source", "History", "Present", "Comments (0)"]
    find ui ".page-view .actions a.page-present" >>= click
    _ <- find ui ".slides-view"
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Slides")
    frames <- findAll ui ".slide-frame"
    length frames `shouldBe` 9
    -- The first slide, a title slide, is the one shown; the rest are
    -- there, hidden.
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Presentations")
    find ui ".slide-frame.current .slide" >>= (`shouldHaveClass` "slide-title-page")
    find ui ".slide-frame.current .slide-number" >>= (`shouldHaveText` "1 / 9")
    find ui ".slide-frame.current .slide-footer-title" >>= (`shouldHaveText` "Presentations")
    visible <- traverse isVisible frames
    visible `shouldBe` (True : replicate 8 False)
    -- The notes are not on the slide.
    find ui ".slide-frame.current .slide-notes" >>= shouldBeHidden
    find ui ".slides-view a.slides-back" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Presentations")
    length <$> findAll ui ".slides-view" `shouldReturn` 0

  it "does not offer a page that is not a deck, which still shows as one slide" $ runPage $ do
    ui <- start m Nothing (PageSlides (slugs ["docs"]) (slugs ["tour"]) 1 1)
    length <$> findAll ui ".slide-frame" `shouldReturn` 1
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Tour")
    find ui ".slides-position" >>= (`shouldHaveText` "1 / 1")

  it "moves with the keys and the buttons, keeping the slide in the address" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 1 1)
    _ <- find ui ".slides-view"
    press "ArrowRight"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Slides")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=2"
    press " "
    press "PageDown"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "A diagram")
    press "ArrowLeft"
    find ui ".slides-position" >>= (`shouldHaveText` "3 / 9")
    press "End"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Themes")
    find ui ".slides-view button.slides-next" >>= (\b -> getProperty b "disabled") >>= (`shouldBe` "true")
    -- Onwards from the last stays there.
    press "ArrowRight"
    find ui ".slides-position" >>= (`shouldHaveText` "9 / 9")
    press "Home"
    find ui ".slides-position" >>= (`shouldHaveText` "1 / 9")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/"
    find ui ".slides-view button.slides-previous" >>= (\b -> getProperty b "disabled") >>= (`shouldBe` "true")
    find ui ".slides-view button.slides-next" >>= click
    find ui ".slides-position" >>= (`shouldHaveText` "2 / 9")
    find ui ".slides-view button.slides-previous" >>= click
    find ui ".slides-position" >>= (`shouldHaveText` "1 / 9")
    find ui ".slides-progress" >>= (\p -> getAttribute p "aria-valuenow") >>= (`shouldBe` Just "1")

  it "hears its keys anywhere on the page, keeps them from scrolling it, and stops when it goes" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 1 1)
    _ <- find ui ".slides-view"
    -- A key dispatched to the page's body, outside the view: heard, and
    -- its default prevented during the dispatch itself.
    dispatchKey "ArrowRight" `shouldReturn` True
    find ui ".slides-position" >>= (`shouldHaveText` "2 / 9")
    -- Not one of the slides' keys: left to the browser.
    dispatchKey "x" `shouldReturn` False
    find ui ".slides-view a.slides-back" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Presentations")
    -- The view is gone, and its listener with it.
    dispatchKey "ArrowRight" `shouldReturn` False
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/"

  it "comes back to the slide in its address" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 5 1)
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Code")

  it "brings a slide beyond the deck into it" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 40 1)
    find ui ".slides-position" >>= (`shouldHaveText` "9 / 9")

  it "draws the islands of the slide shown" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 3 1)
    _ <- find ui ".slide-frame.current .wiki-math-display .katex"
    _ <- find ui ".slide-frame.current .wiki-math-inline .katex"
    press "ArrowRight"
    eventuallyWithin 20000 $ void (find ui ".slide-frame.current .wiki-mermaid svg")
    press "ArrowRight"
    _ <- find ui ".slide-frame.current pre.wiki-code code.hljs"
    pass

  it "opens and closes the speaker's notes" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 2 1)
    notes <- find ui ".slide-frame.current .slide-notes"
    shouldBeHidden notes
    press "n"
    find ui ".slides-view" >>= (`shouldHaveClass` "notes-open")
    shouldBeVisible notes
    textContent notes >>= (`shouldSatisfy` T.isInfixOf "a page with no")
    find ui ".slides-view button.slides-notes-toggle" >>= (\b -> getAttribute b "aria-pressed") >>= (`shouldBe` Just "true")
    -- The next slide's notes, under it.
    press "ArrowRight"
    find ui ".slide-frame.current .slide-notes" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "macros")
    find ui ".slides-view button.slides-notes-toggle" >>= click
    find ui ".slides-view" >>= (`shouldNotHaveClass` "notes-open")
    find ui ".slide-frame.current .slide-notes" >>= shouldBeHidden

  it "shows every slide in the overview, and the one picked there" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 1 1)
    _ <- find ui ".slides-view"
    press "o"
    find ui ".slides-view" >>= (`shouldHaveClass` "overview")
    frames <- findAll ui ".slide-frame"
    traverse isVisible frames `shouldReturn` replicate 9 True
    find ui ".slide-frame[data-slide='6']" >>= click
    find ui ".slides-view" >>= (`shouldNotHaveClass` "overview")
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Presenting")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=6"
    -- Escape closes it, leaving the slide shown as it was.
    press "o"
    press "Escape"
    find ui ".slides-view" >>= (`shouldNotHaveClass` "overview")
    find ui ".slides-position" >>= (`shouldHaveText` "6 / 9")

  it "shows a slide's steps one at a time, in place, and keeps the step in the address" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 6 1)
    _ <- find ui ".slides-view"
    press "ArrowRight"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Steps")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=7"
    pieces <- findAll ui ".slide-frame.current .slide-step"
    length pieces `shouldBe` 2
    traverse isVisible pieces `shouldReturn` [False, False]
    lastAt <- traverse (`getProperty` "offsetTop") (lastMay pieces)
    -- The next step, not the next slide.
    press " "
    find ui ".slides-position" >>= (`shouldHaveText` "7 / 9")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=7&step=2"
    traverse isVisible pieces `shouldReturn` [True, False]
    press "PageDown"
    traverse isVisible pieces `shouldReturn` [True, True]
    -- Shown in the place it held while hidden.
    traverse (`getProperty` "offsetTop") (lastMay pieces) `shouldReturn` lastAt
    -- Past the last step, the next slide: an incremental list, its first
    -- item shown with what comes before it.
    press "ArrowRight"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "One item at a time")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=8"
    items <- findAll ui ".slide-frame.current .incremental li"
    traverse isVisible items `shouldReturn` [True, False, False]
    press "ArrowRight"
    traverse isVisible items `shouldReturn` [True, True, False]
    -- Back a step, then back to the slide before, whole.
    press "ArrowLeft"
    traverse isVisible items `shouldReturn` [True, False, False]
    press "PageUp"
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Steps")
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=7&step=3"
    traverse isVisible pieces `shouldReturn` [True, True]
    find ui ".slides-view button.slides-previous" >>= click
    location `shouldReturn` "#/s/docs/p/markdown-guide/presentations/slides/?slide=7&step=2"
    traverse isVisible pieces `shouldReturn` [True, False]
    -- The last slide is shown whole.
    press "End"
    find ui ".slides-position" >>= (`shouldHaveText` "9 / 9")

  it "comes back to the step in its address" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 8 2)
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "One item at a time")
    findAll ui ".slide-frame.current .incremental li" >>= traverse isVisible >>= (`shouldBe` [True, True, False])

  it "brings a step beyond the slide into it" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 8 40)
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "One item at a time")
    findAll ui ".slide-frame.current .incremental li" >>= traverse isVisible >>= (`shouldBe` [True, True, True])

  it "shows whole slides in the overview" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 7 1)
    find ui ".slide-frame.current .slide-title" >>= (`shouldHaveText` "Steps")
    length <$> findAll ui ".slide-frame.current .slide-step-later" `shouldReturn` 2
    press "o"
    find ui ".slides-view" >>= (`shouldHaveClass` "overview")
    length <$> findAll ui ".slide-step-later" `shouldReturn` 0
    press "Escape"
    length <$> findAll ui ".slide-frame.current .slide-step-later" `shouldReturn` 2

  it "prints each step on its own page only when asked, a copy of the slide at each step before it" $ runPage $ do
    ui <- start m Nothing (PageSlides docs presentations 1 1)
    _ <- find ui ".slides-view"
    length <$> findAll ui ".slide-step-copy" `shouldReturn` 0
    box <- find ui ".slides-print-steps input"
    getProperty box "checked" >>= (`shouldBe` "false")
    click box
    find ui ".slides-view" >>= (`shouldHaveClass` "print-steps")
    copies <- findAll ui ".slide-step-copy"
    traverse (`getAttribute` "data-step") copies `shouldReturn` map Just ["1", "2", "1", "2"]
    traverse isVisible copies `shouldReturn` replicate 4 False
    -- Each copy just before its slide, in the order they are printed.
    frames <- findAll ui ".slide-frame"
    traverse (`getAttribute` "data-slide") frames `shouldReturn` map (Just . show) ([1 .. 7 :: Int] <> [7, 7, 8, 8, 8, 9])
    copySteps <- for copies $ \c -> length <$> findAllIn c ".slide-step-later"
    copySteps `shouldBe` [2, 1, 2, 1]
    click box
    length <$> findAll ui ".slide-step-copy" `shouldReturn` 0

  it "says a page the reader may not read is not there, with no slides" $ runPage $ do
    ui <- start m (Just "user-reader") (PageSlides (slugs ["team"]) (slugs ["team-handbook"]) 1 1)
    find ui ".wiki-content .error-not-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "nothing here")
    length <$> findAll ui ".slides-view" `shouldReturn` 0
  where
    docs = slugs ["docs"]
    presentations = slugs ["markdown-guide", "presentations"]
    location = unsafeIOToPageM (fromJSText <$> js_location_hash)
    dispatchKey key = unsafeIOToPageM (js_dispatch_key (toJSText key))
