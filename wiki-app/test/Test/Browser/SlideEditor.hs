{-# LANGUAGE TemplateHaskell #-}

-- | The editor of a presentation (WP5.97 of docs/PLAN.md), in a browser,
-- in the shell, over the demo's wiki with its "Hello, world" made a
-- presentation: slide by slide, every slide folded but the cursor's when
-- the editor opens, one opened at a time by its button and more with
-- Ctrl; the switch to the raw Markdown and back, which the browser keeps
-- and which changes no byte, of a text with carriage returns too; a slide
-- moved by Alt+Up and Alt+Down and by its handle, before or after the
-- slide it is dropped on, as one edit that one undo takes back; a new slide; and the preview, which shows the cursor's
-- slide, or the whole deck.
module Test.Browser.SlideEditor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), decodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.IORef (IORef)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startOn, startWith)
import Test.Browser.Text (editorHost, editorText, inputsSeen, insertText, markdown, problemsMarked, selectText, setMarkdown, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Editor.Browser (foldedLines)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page (Page (id, updatedAt))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Slides (moveSlide)
import Wiki.Core.Space (Space (id))

$( browserJS
     ["jsbits/test-slides.js"]
     [ ("js_ctrl_click", "wiki_test_ctrl_click", Safe, [t|JSText -> Int -> IO Bool|])
     , ("js_slide_fits", "wiki_test_slide_fits", Safe, [t|IO JSText|])
     , ("js_fit_log_start", "wiki_test_fit_log_start", Safe, [t|IO ()|])
     , ("js_fit_log", "wiki_test_fit_log", Safe, [t|IO JSText|])
     , ("js_slide_cut", "wiki_test_slide_cut", Safe, [t|Int -> IO JSText|])
     , ("js_fit_hold", "wiki_test_fit_hold", Safe, [t|Bool -> IO ()|])
     , ("js_viewport_rules", "wiki_test_viewport_rules", Safe, [t|IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "folds every slide but the cursor's as the editor opens, and opens one at a time by its button, more with Ctrl" $ runPage $ do
    -- The slides measured late, as on a slow machine: the controls found
    -- before are the ones there after.
    unsafeIOToPageM (js_fit_hold True)
    (ui, _) <- openDeck deck
    host <- editorHost ui
    -- The cursor starts under the title line, on the title slide.
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- Each slide has its button; each but the title slide its handle.
    found <- eventually $ do
      buttons <- findAll ui ".editor-cm .cm-wiki-slide-toggle"
      length buttons `shouldBe` 4
      pure buttons
    length <$> findAll ui ".editor-cm .cm-wiki-slide-handle:not([hidden])" `shouldReturn` 3
    editorFits `shouldReturn` replicate 4 "unmeasured"
    unsafeIOToPageM (js_fit_hold False)
    eventually $ editorFits `shouldReturn` replicate 4 "fits"
    traverse isAttached found `shouldReturn` replicate 4 True
    watchEditor ui
    traverse_ click (atMay found 2)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    unsafeIOToPageM (js_ctrl_click (toJSText ".editor-cm .cm-wiki-slide-toggle") 3) `shouldReturn` True
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7)]
    -- An open slide's button closes it.
    toggles ui >>= traverse_ click . (`atMay` 3)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    -- Folds change what is shown, never the text.
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck

  it "opens one slide and closes the others by its fold's mark and by the keys too, keeps them open with Ctrl, and leaves them as they are when an edit opens one" $ runPage $ do
    (ui, _) <- openDeck deck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- The marks of "One", "Two" and "Three", in the order of the text.
    findAll ui ".editor-cm .cm-wiki-folded" >>= traverse_ click . (`atMay` 1)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    -- Now the title slide's, "One"'s and "Three"'s: Ctrl on the click on
    -- "Three"'s keeps "Two" open.
    unsafeIOToPageM (js_ctrl_click (toJSText ".editor-cm .cm-wiki-folded") 2) `shouldReturn` True
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7)]
    -- The key that unfolds the cursor's line.
    selectText ui (lineStart deck 5) (lineStart deck 5)
    press "Control+Shift+BracketRight"
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (9, 11), (13, 15)]
    -- Backspace at the start of the line after "Two" joins it to the
    -- hidden last line: an edit opens the fold, and the others stay.
    selectText ui (lineStart deck 12) (lineStart deck 12)
    press "Backspace"
    eventually $ markdown ui `shouldReturn` T.replace "Second.\n\n" "Second.\n" deck
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (12, 14)]
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "switches to the raw Markdown and back, which the browser keeps, changing no byte, of a text with carriage returns and no final line break too" $ runPage $ do
    (ui, wiki) <- openDeck deck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    watchEditor ui
    modeButton ui "Raw" >>= click
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    eventually $ length <$> findAll ui ".editor-cm .cm-wiki-slide-toggle" `shouldReturn` 0
    modeButton ui "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck
    -- The browser keeps the mode: the editor opened again is in it.
    again <- startOn m wiki helloEditor
    againHost <- editorHost again
    modeButton again "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    unsafeIOToPageM (foldedLines againHost) `shouldReturn` []
    modeButton again "Slides" >>= click
    eventually $ unsafeIOToPageM (foldedLines againHost) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    markdown again `shouldReturn` deck
    -- A text with carriage returns has no slides to fold or move: the
    -- editor says so, and either mode leaves every byte as it is.
    let returns = T.replace "\n" "\r\n" deck
    setMarkdown again returns
    watchEditor again
    find again ".editor-slides-note" >>= (`shouldHaveText` "This text has carriage returns, so its slides cannot be folded or moved here.")
    eventually $ length <$> findAll again ".editor-cm .cm-wiki-slide-toggle" `shouldReturn` 0
    modeButton again "Raw" >>= click
    modeButton again "Slides" >>= click
    unsafeIOToPageM (foldedLines againHost) `shouldReturn` []
    inputsSeen again `shouldReturn` 0
    markdown again `shouldReturn` returns

  it "moves the cursor's slide with Alt+Up and Alt+Down as one edit that one undo takes back, the title slide staying first" $ runPage $ do
    (ui, _) <- openDeck deck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    selectText ui (lineStart deck 9) (lineStart deck 9)
    press "Alt+ArrowUp"
    let moved = moveSlide 2 1 deck
    eventually $ markdown ui `shouldReturn` moved
    moved `shouldBe` T.intercalate "\n" ["# Deck", "", "By me.", "", "## Two", "", "Second.", "", "## One", "", "First.", "", "## Three", "", "Third."]
    -- The slides folded before ("One" and "Three") are folded at their new
    -- places; the slide moved is open, with the cursor in it, and the
    -- title slide, open before, is still.
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(9, 11), (13, 15)]
    -- Up again would put it before the title slide: no move.
    press "Alt+ArrowUp"
    markdown ui `shouldReturn` moved
    press "Alt+ArrowDown"
    eventually $ markdown ui `shouldReturn` deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` moved
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "moves a slide dragged by its handle onto another, and adds a new slide at the end, its title selected" $ runPage $ do
    (ui, _) <- openDeck deck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- Measured first: a mark that changes draws its line again.
    eventually $ editorFits >>= (`shouldSatisfy` notElem "unmeasured")
    -- Dropped on another slide's first line, the slide goes before it.
    handles <- findAll ui ".editor-cm .cm-wiki-slide-handle:not([hidden])"
    target <- lineWith ui "## Three"
    traverse_ (`dragTo` target) (head handles)
    eventually $ markdown ui `shouldReturn` moveSlide 1 2 deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    -- Dropped below a slide's first line, a slide goes after it. The
    -- controls of the slides the undo rewrote come back with the check of
    -- the text.
    eventually $ length <$> toggles ui `shouldReturn` 4
    toggles ui >>= traverse_ click . (`atMay` 3)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (9, 11)]
    eventually $ editorFits >>= (`shouldSatisfy` notElem "unmeasured")
    below <- lineWith ui "Third."
    findAll ui ".editor-cm .cm-wiki-slide-handle:not([hidden])" >>= traverse_ (`dragTo` below) . head
    eventually $ markdown ui `shouldReturn` moveSlide 1 3 deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    find ui ".editor-new-slide" >>= click
    eventually $ markdown ui `shouldReturn` (deck <> "\n\n## New slide\n")
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (9, 11), (13, 15)]
    editorText ui >>= (`typeText` "Four")
    markdown ui `shouldReturn` (deck <> "\n\n## Four\n")

  it "shows the cursor's slide in the preview, and in the raw Markdown the whole deck or one slide" $ runPage $ do
    (ui, _) <- openDeck deck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    find ui ".editor-side-by-side" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck"]
    selectText ui (lineStart deck 9) (lineStart deck 9)
    eventually $ cardTitles ui `shouldReturn` ["Two"]
    find ui ".editor-preview .slide-frame:not(.slide-offstage) .slide-number" >>= (`shouldHaveText` "3 / 4")
    modeButton ui "Raw" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    find ui ".editor-one-slide" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Two"]

  it "renders the deck whole for one slide's preview: a macro of an earlier slide, a footnote's number, the same slide in every view" $ runPage $ do
    (ui, wiki) <- openDeck macros
    find ui ".editor-side-by-side" >>= click
    -- The cursor on "Use", which uses the macro "Define" defines.
    selectText ui (lineStart macros 9) (lineStart macros 9)
    eventually $ cardTitles ui `shouldReturn` ["Use"]
    eventually $ length <$> findAll ui ".editor-preview .slide-frame:not(.slide-offstage) .wiki-math .katex" `shouldReturn` 1
    length <$> findAll ui ".editor-preview .slide-frame:not(.slide-offstage) .katex-error" `shouldReturn` 0
    problemsMarked ui `shouldReturn` []
    oneUse <- bodyText ui "Use"
    selectText ui (lineStart macros 13) (lineStart macros 13)
    eventually $ cardTitles ui `shouldReturn` ["Later"]
    oneLater <- bodyText ui "Later"
    -- The second footnote is the second wherever its slide is shown.
    oneLater `shouldSatisfy` T.isInfixOf "2"
    modeButton ui "Raw" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Macros", "Define", "Use", "Later"]
    bodyText ui "Use" `shouldReturn` oneUse
    bodyText ui "Later" `shouldReturn` oneLater
    unmount ui
    shown <- startOn m wiki (PageSlides (slugs ["blog"]) (slugs ["hello-world"]) 4 1)
    eventually $ find shown ".slides-view .slide-frame.current .slide-body" >>= textContent >>= (`shouldBe` oneLater)

  it "marks a formula KaTeX cannot read on a slide the preview does not show, with the preview hidden" $ runPage $ do
    let broken = T.intercalate "\n" ["# Deck", "", "## One", "", "Fine.", "", "## Two", "", "Half: $\\frac{1}$ here.", "", "## Three", "", "Fine."]
    (ui, _) <- openDeck broken
    eventually $ do
      marked <- problemsMarked ui
      [a >= lineStart broken 9 && b <= lineStart broken 10 | (a, b, _) <- marked] `shouldBe` [True]

  it "marks whether each slide fits, grey until measured, beside its handle, on its card and among the problems" $ runPage $ do
    let fitting = T.intercalate "\n\n" (["# Deck", "## Short", "One line."] <> ["## Long"] <> replicate 30 "A paragraph of its own, one line long.")
    (ui, _) <- openDeck fitting
    eventually $ editorFits `shouldReturn` ["fits", "fits", "overflowing"]
    length <$> findAll ui ".editor-cm .cm-wiki-fit-overflowing" `shouldReturn` 1
    length <$> findAll ui ".editor-preview .slide-frame.slide-fit-overflowing" `shouldReturn` 1
    eventually $ do
      marked <- problemsMarked ui
      [(a, message) | (a, _, message) <- marked] `shouldSatisfy` \case
        [(a, message)] -> a == lineStart fitting 7 && "This slide is cut when presented" `T.isPrefixOf` message
        _ -> False
    -- A slide changed is grey until it is measured again; the others keep
    -- their marks.
    selectText ui (lineStart fitting 5) (lineStart fitting 5)
    editorText ui >>= (`typeText` "Still ")
    eventually $ editorFits `shouldReturn` ["fits", "fits", "overflowing"]
    -- A change that leaves every card laid out as it was (a blank line in
    -- a slide, the look's line naming the default theme) is measured
    -- again too: the marks come back, and the problem with them.
    -- Each edit moves the long slide down: its problem is marked on its
    -- new lines once the edit is measured.
    let longAt text = maybe [] (\n -> [lineStart text n]) (head [n | (n, l) <- zip [1 ..] (T.splitOn "\n" text), l == "## Long"])
        measuredAgain = do
          text <- markdown ui
          eventually $ do
            marked <- problemsMarked ui
            [a | (a, _, _) <- marked] `shouldBe` longAt text
            editorFits `shouldReturn` ["fits", "fits", "overflowing"]
    before <- markdown ui
    insertText ui (lineStart before 4) "\n"
    measuredAgain
    -- A look, then the theme changed from light to dark: the same layout,
    -- the cards' classes changed.
    insertText ui (lineStart before 2) "\n[[!style]]{theme=light}\n"
    _ <- find ui ".editor-preview .slides-theme-light"
    measuredAgain
    markdown ui >>= setMarkdown ui . T.replace "theme=light" "theme=dark"
    _ <- find ui ".editor-preview .slides-theme-dark"
    measuredAgain

  it "never shows a slide as fitting that the slides view cuts at 1024, 1280 or 1920 pixels wide, a measure taken before a diagram draws followed by the right one" $ runPage $ do
    for_ [("beamer", "16:9"), ("light", "4:3"), ("dark", "16:9"), ("beamer", "4:3"), ("light", "16:9"), ("dark", "4:3")] $ \(theme, aspect) -> do
      unsafeIOToPageM js_fit_log_start
      let text = fitDeck theme aspect
      (ui, wiki) <- openDeck text
      -- Every slide measured, with its diagram drawn.
      fits <- eventually $ do
        found <- previewFits ui
        length found `shouldBe` 24
        found `shouldSatisfy` notElem "unmeasured"
        length <$> findAll ui ".editor-preview .wiki-mermaid svg" `shouldReturn` 1
        log' <- fitLog
        -- The last measure of the diagram's slide is with the diagram.
        [d.drawn | d <- log', d.diagrams > 0] `shouldSatisfy` maybe False (> 0) . lastMay
        pure found
      -- A measure was taken before the diagram was drawn, and the slide
      -- is marked as the drawn diagram makes it.
      log' <- fitLog
      [() | d <- log', d.diagrams > 0, d.drawn == 0] `shouldSatisfy` (not . null)
      lastMay fits `shouldBe` Just "overflowing"
      -- A title slide whose title runs below the slide, and a slide whose
      -- heading leaves its body no room, with nothing below the body's
      -- own room to tell it.
      (atMay fits 20, atMay fits 22) `shouldBe` (Just "overflowing", Just "overflowing")
      -- Nothing in a slide's layout depends on the window: no length in
      -- the viewport's units, no media query on the window's size.
      unsafeIOToPageM (fromJSText <$> js_viewport_rules) `shouldReturn` "[]"
      unmount ui
      shown <- startOn m wiki (PageSlides (slugs ["blog"]) (slugs ["hello-world"]) 1 1)
      againstSlidesView (theme <> " " <> aspect) False fits
      unmount shown

  it "marks a slide of the guide's presentation only where the slides view cuts it at 1024 pixels wide, so none, its table of keys close to its foot among them" $ runPage $ do
    -- The guide's own page, as the demo has it: a fixture for both
    -- directions of the marks.
    let guideDeck = slugs ["markdown-guide", "presentations"]
    (ui, wiki) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) guideDeck)
    _ <- editorText ui
    fits <- eventually $ do
      -- Every slide measured, with its diagram and its formulas drawn.
      _ <- find ui ".editor-preview .wiki-mermaid svg"
      _ <- find ui ".editor-preview .wiki-math-display .katex"
      found <- previewFits ui
      found `shouldSatisfy` (\f -> length f >= 9 && notElem "unmeasured" f)
      -- Measured with the diagram drawn: no slide is marked, in the
      -- preview or among the problems.
      found `shouldSatisfy` all (== "fits")
      marked <- problemsMarked ui
      [message | (_, _, message) <- marked, "This slide" `T.isPrefixOf` message] `shouldBe` []
      pure found
    unmount ui
    shown <- startOn m wiki (PageSlides (slugs ["docs"]) guideDeck 1 1)
    againstSlidesView "the guide" True fits
    unmount shown

  it "leaves out a slide's speaker notes, however long, from whether the slide fits" $ runPage $ do
    let noted = T.intercalate "\n\n" ["# Deck", "## Noted", "One line.", "[[!notes]]\n" <> T.intercalate "\n\n" (replicate 40 "A paragraph of the notes, one line long.") <> "\n[[/notes]]"]
    (ui, _) <- openDeck noted
    eventually $ previewFits ui `shouldReturn` ["fits", "fits"]
    eventually $ problemsMarked ui `shouldReturn` []

  it "measures a slide whose image fails to load: it is not left unmeasured" $ runPage $ do
    let failing = T.intercalate "\n\n" ["# Deck", "## Lost", "Above it.", "![Lost](data:image/png;base64,AAAA){width=600 height=600}"]
    (_, _) <- openDeck failing
    eventually $ do
      found <- editorFits
      length found `shouldBe` 2
      found `shouldSatisfy` notElem "unmeasured"

  it "measures a deck of fifty slides, and a slide again after a keystroke" $ runPage $ do
    let fifty = T.intercalate "\n\n" ("# Fifty" : concat [["## Slide " <> show n, "A first paragraph.", "A second one.", "$x^" <> show n <> "$"] | n <- [1 .. 49 :: Int]])
    unsafeIOToPageM js_fit_log_start
    start <- unsafeIOToPageM getCurrentTime
    (ui, _) <- openDeck fifty
    eventually $ do
      found <- editorFits
      length found `shouldBe` 50
      found `shouldSatisfy` notElem "unmeasured"
    measured <- unsafeIOToPageM getCurrentTime
    -- A keystroke on the second slide: its card shows it, measured again.
    selectText ui (lineStart fifty 5) (lineStart fifty 5)
    typed <- unsafeIOToPageM getCurrentTime
    editorText ui >>= (`typeText` "x")
    eventually $ do
      findAll ui ".editor-preview .slide-frame[data-slide='2'].slide-fit-fits .slide-body" >>= traverse textContent >>= (`shouldSatisfy` any (T.isInfixOf "xA first paragraph."))
      editorFits >>= (`shouldSatisfy` notElem "unmeasured")
    again <- unsafeIOToPageM getCurrentTime
    times <- fitTimes
    unsafeIOToPageM . putStrLn @Text $
      "Measuring fifty slides: first marks after "
        <> show (diffUTCTime measured start)
        <> " from the editor's mount, marks again "
        <> show (diffUTCTime again typed)
        <> " after a keystroke's change; "
        <> show (length times)
        <> " measures of every card, the longest "
        <> show (maximum (0 : times))
        <> " ms, on average "
        <> show (sum times / fromIntegral (max 1 (length times)))
        <> " ms."
    diffUTCTime again typed `shouldSatisfy` (< 5)

  it "starts with the slide the cursor starts on open and in the preview, when the first slide follows the title line" $ runPage $ do
    let early = T.intercalate "\n" ["# Deck", "", "## One", "", "First.", "", "## Two", "", "Second."]
    (ui, _) <- openDeck early
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(7, 9)]
    find ui ".editor-side-by-side" >>= click
    eventually $ cardTitles ui `shouldReturn` ["One"]
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

    -- The slides view open on a deck's first slide, each slide in turn
    -- checked against its fit as the editor's preview measured it, at
    -- 1024, 1280 and 1920 pixels wide: a slide cut at any width is never
    -- shown as fitting; one marked cut is cut at 1024; and, both ways, one
    -- marked at all (cut, or may be cut) is cut at 1024.
    againstSlidesView :: forall s. Text -> Bool -> [Text] -> PageM s ()
    againstSlidesView deckName bothWays fits = do
      for_ (zip [1 :: Int ..] fits) $ \(n, fit) -> do
        for_ [1024, 1280, 1920 :: Int] $ \width -> do
          seen <- eventually $ do
            c <- slideCut width
            (c.ready, c.slide) `shouldBe` (True, n)
            pure c
          seen.width `shouldSatisfy` (>= fromIntegral width - 0.5)
          -- Cut there: never shown as fitting.
          when seen.cut $ (deckName, n, width, fit) `shouldSatisfy` (\(_, _, _, f) -> f /= "fits")
          -- Marked as cut: cut at 1024.
          when (width == 1024 && fit == "overflowing") $ (deckName, n, seen.cut) `shouldSatisfy` (\(_, _, c) -> c)
          -- Marked at all: cut at 1024.
          when (bothWays && width == 1024 && fit /= "fits") $ (deckName, n, fit, seen.cut) `shouldSatisfy` (\(_, _, _, c) -> c)
        -- To the next slide, through the steps of this one: a later step's
        -- content is laid out, hidden, from the first step on, so the cut
        -- is the same at every step.
        when (n < length fits) . eventually $ do
          c <- slideCut 1024
          when (c.slide == n) (press "ArrowRight")
          after <- slideCut 1024
          after.slide `shouldBe` n + 1

    -- The demo's "Hello, world", made a presentation with the deck as its
    -- text, open in the editor.
    openDeck :: forall s. Text -> PageM s (Mounted s Shell.Query Void m, IORef MemState)
    openDeck text = do
      (opener, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
      -- One shell at a time: the editor's, which a route followed moves.
      unmount opener
      unsafeIOToPageM . runMemWiki wiki $ do
        blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
        hello <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
        made <- either (panic . show) identity <$> setPageKind hello.id Kind.Presentation
        void (either (panic . show) identity <$> savePage made.id made.updatedAt "Deck" text)
      ui <- startOn m wiki helloEditor
      _ <- editorText ui
      pure (ui, wiki)

-- | The presentation the tests edit: a title slide and three others,
-- with no line break at the end.
deck :: Text
deck = T.intercalate "\n" ["# Deck", "", "By me.", "", "## One", "", "First.", "", "## Two", "", "Second.", "", "## Three", "", "Third."]

-- | A deck to measure: its look, a title slide, slides of 1, 3, … 29
-- paragraphs, a slide with an image 600 pixels wide, one with an @html@
-- frame taller than the slide, one with formulas, one with a block of
-- each other kind, a title slide whose title runs below the slide, a
-- heading of one unbroken word, a heading that leaves its body no room,
-- and one with a diagram
-- that, under three paragraphs, the slide cannot hold.
fitDeck :: Text -> Text -> Text
fitDeck theme aspect =
  T.intercalate "\n\n" $
    ["# Fits", "[[!style]]{theme=" <> theme <> " aspect=" <> aspect <> "}"]
      <> concat [("## Paragraphs " <> show k) : replicate k "A paragraph of its own, one line long." | k <- [1, 3 .. 29 :: Int]]
      <> ["## Image", "Above it.", "![A picture](attachment:none.png){width=600 height=600}"]
      <> ["## Frame", "```html\n<div style=\"height: 2000px\">Tall</div>\n```"]
      <> ["## Formulas", "$$\\sum_{i=1}^{n} i = \\frac{n(n+1)}{2}$$", "$$\\int_0^1 x^2 \\, dx = \\frac{1}{3}$$", "$$\\prod_{k=1}^{n} k = n!$$"]
      <> ["## Kinds", "```haskell\nmain = pure ()\n```", "| a | b |\n|---|---|\n| 1 | 2 |", "> Quoted.", "> [!NOTE]\n> A box.", "- one\n- two", "`code` and **strong**"]
      <> ["# " <> T.unwords (replicate 60 "Section"), "Under the title."]
      <> ["## " <> T.replicate 120 "W", "Text."]
      <> ["## " <> T.unwords (replicate 60 "Heading"), "A paragraph of its own, one line long.", "A paragraph of its own, one line long.", "A paragraph of its own, one line long.", "A paragraph of its own, one line long."]
      <> ["## Diagram", "Above it.", "And more.", "And more still.", "```mermaid\ngraph TD\n" <> T.intercalate "\n" ["  N" <> show i <> " --> N" <> show (i + 1) | i <- [1 .. 12 :: Int]] <> "\n```"]

-- | A deck where a slide uses a macro an earlier one defines, and two
-- slides refer to footnotes.
macros :: Text
macros =
  T.intercalate
    "\n"
    ["# Macros", "", "## Define", "", "$\\newcommand{\\Rplus}{\\mathbb{R}^{+}}$ defined.", "", "## Use", "", "$x \\in \\Rplus$ and a note[^n].", "", "## Later", "", "Another note[^m].", "", "[^n]: First.", "", "[^m]: Second."]

-- | The fits the editor marks beside its slides' handles.
editorFits :: PageM s [Text]
editorFits = do
  json <- unsafeIOToPageM (fromJSText <$> js_slide_fits)
  pure (fromMaybe [] (decodeStrict (encodeUtf8 json)))

-- | The fits the editor's preview shows on its cards ("fits", "tight",
-- "overflowing" or "unmeasured"), every slide's in the order of the deck:
-- the preview's own classes, which it sets from its measures.
previewFits :: Mounted s q o m -> PageM s [Text]
previewFits ui = do
  frames <- findAll ui ".editor-preview .slides-preview .slide-frame"
  traverse (fmap (fromMaybe "" . head . mapMaybe (T.stripPrefix "slide-fit-")) . classes) frames

-- | A measure of the preview's cards, as the log keeps it.
data Measure = Measure {diagrams :: Int, drawn :: Int}

instance FromJSON Measure where
  parseJSON = withObject "Measure" $ \o -> Measure <$> o .: "diagrams" <*> o .: "drawn"

-- | The measures of the preview's cards since the log started.
fitLog :: PageM s [Measure]
fitLog = do
  json <- unsafeIOToPageM (fromJSText <$> js_fit_log)
  pure (maybe [] fst (decodeStrict (encodeUtf8 json) >>= parseMaybe (\o -> (,) <$> o .: "log" <*> (o .: "times" :: Parser [Double]))))

-- | How long each measure of every card took, in milliseconds.
fitTimes :: PageM s [Double]
fitTimes = do
  json <- unsafeIOToPageM (fromJSText <$> js_fit_log)
  pure (maybe [] snd (decodeStrict (encodeUtf8 json) >>= parseMaybe (\o -> (,) <$> (o .: "log" :: Parser [Measure]) <*> o .: "times")))

-- | The slide the slides view shows, at a width, as 'js_slide_cut' finds
-- it.
data Cut = Cut {ready :: Bool, cut :: Bool, width :: Double, slide :: Int}

instance FromJSON Cut where
  parseJSON = withObject "Cut" $ \o -> Cut <$> o .: "ready" <*> (fromMaybe False <$> o .:? "cut") <*> (fromMaybe 0 <$> o .:? "width") <*> (fromMaybe 0 <$> o .:? "slide")

slideCut :: Int -> PageM s Cut
slideCut width = do
  json <- unsafeIOToPageM (fromJSText <$> js_slide_cut width)
  maybe (expectationFailure ("no slide: " <> json)) pure (decodeStrict (encodeUtf8 json))

-- | The text of the body of the preview's card with this title.
bodyText :: Mounted s q o m -> Text -> PageM s Text
bodyText ui title = eventually $ do
  frames <- findAll ui ".editor-preview .slide-frame:not(.slide-offstage)"
  titled <- filterM (\f -> (== title) <$> (findIn f ".slide-title" >>= textContent)) frames
  maybe (expectationFailure ("no card " <> title)) (\f -> findIn f ".slide-body" >>= textContent) (head titled)

-- | The slides' buttons, in the order of the text.
toggles :: Mounted s q o m -> PageM s [Element s]
toggles ui = findAll ui ".editor-cm .cm-wiki-slide-toggle"

-- | One of the two buttons of the switch between slide by slide and the
-- raw Markdown, by its text.
modeButton :: Mounted s q o m -> Text -> PageM s (Element s)
modeButton ui label = eventually $ do
  buttons <- findAll ui ".editor-slides-mode button"
  named <- filterM (fmap (== label) . textContent) buttons
  maybe (expectationFailure ("no button " <> label)) pure (head named)

-- | The editor's line shown with this text.
lineWith :: Mounted s q o m -> Text -> PageM s (Element s)
lineWith ui text = eventually $ do
  lines' <- findAll ui ".editor-cm .cm-line"
  named <- filterM (fmap (T.isInfixOf text) . textContent) lines'
  maybe (expectationFailure ("no line with " <> text)) pure (head named)

-- | The titles of the slides the preview shows.
cardTitles :: Mounted s q o m -> PageM s [Text]
cardTitles ui = findAll ui ".editor-preview .slides-preview .slide-frame:not(.slide-offstage) .slide-title" >>= traverse textContent

-- | Where a line of a text starts, in characters (the text is ASCII, so
-- characters are UTF-16 units).
lineStart :: Text -> Int -> Int
lineStart text n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" text)))
