{-# LANGUAGE TemplateHaskell #-}

-- | The editor of a presentation (WP5.97 and WP5.103 of docs/PLAN.md), in
-- a browser, in the shell, over the demo's wiki with its "Hello, world"
-- made a presentation: slide by slide, a list of rows, the cursor's open as
-- the editor opens, each opened and closed by its header and several open
-- at once, each open row an editor of its own over one text with one
-- history (an undo in one row of a change in another opens that row and
-- closes the row left); rows split and joined as headings are typed and
-- taken away; a row's problems, fits and spoilers' folds; the headers
-- before CodeMirror is there, and the Markdown without it; the switch to
-- the raw Markdown and back, which the browser keeps and which changes no
-- byte, of a text with carriage returns too; and the preview, which shows
-- the cursor's slide, or the whole deck.
module Test.Browser.SlideEditor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), decodeStrict, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.IORef (IORef)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, startOn, startWith)
import Test.Browser.Text (completing, editorText, inputsSeen, insertText, markdown, problemsMarked, proposeText, selectText, setMarkdown, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page (Page (id, updatedAt))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.SlideRows (Row (..), RowKey (..), Rows (..), assemble, cutRows, deleteRow, newRow)
import Wiki.Core.Slides (moveSlide)
import Wiki.Core.Space (Space (id))

$( browserJS
     ["jsbits/test-slides.js", "jsbits/test-files.js"]
     [ ("js_slide_fits", "wiki_test_slide_fits", Safe, [t|IO JSText|])
     , ("js_slide_focus", "wiki_test_slide_focus", Safe, [t|IO JSText|])
     , ("js_mermaid", "wiki_test_mermaid", Safe, [t|JSText -> IO ()|])
     , ("js_stall_start", "wiki_test_stall_start", Safe, [t|IO ()|])
     , ("js_master_problems", "wiki_test_master_problems", Safe, [t|IO ()|])
     , ("js_stall", "wiki_test_stall", Safe, [t|IO Int|])
     , ("js_row_cursor_seen", "wiki_test_slide_row_cursor_seen", Safe, [t|Int -> IO Bool|])
     , ("js_drop_filePromise", "wiki_test_drop_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     , ("js_pastePromise", "wiki_test_paste", Safe, [t|JSText -> JSText -> JSText -> JSText -> JSText -> IO (Promise Bool)|])
     , ("js_row_text", "wiki_test_slide_row_text", Safe, [t|Int -> IO JSText|])
     , ("js_row_select", "wiki_test_slide_row_select", Safe, [t|Int -> Int -> Int -> IO Bool|])
     , ("js_rows_late", "wiki_test_rows_late", Safe, [t|Int -> IO ()|])
     , ("js_row_selection", "wiki_test_slide_row_selection", Safe, [t|Int -> IO JSText|])
     , ("js_row_focused", "wiki_test_slide_row_focused", Safe, [t|Int -> IO Bool|])
     , ("js_stale_rows", "wiki_test_stale_rows", Safe, [t|JSText -> IO JSText|])
     , ("js_editor_script", "wiki_test_editor_script", Safe, [t|JSText -> IO ()|])
     , ("js_fit_log_start", "wiki_test_fit_log_start", Safe, [t|IO ()|])
     , ("js_fit_log", "wiki_test_fit_log", Safe, [t|IO JSText|])
     , ("js_slide_cut", "wiki_test_slide_cut", Safe, [t|Int -> IO JSText|])
     , ("js_fit_hold", "wiki_test_fit_hold", Safe, [t|Bool -> IO ()|])
     , ("js_viewport_rules", "wiki_test_viewport_rules", Safe, [t|IO JSText|])
     ]
 )

js_drop_file :: JSText -> JSText -> JSText -> JSText -> IO ()
js_drop_file a1 a2 a3 a4 = if inBrowser then wait =<< js_drop_filePromise a1 a2 a3 a4 else pure inert

js_paste :: JSText -> JSText -> JSText -> JSText -> JSText -> IO Bool
js_paste a1 a2 a3 a4 a5 = if inBrowser then wait =<< js_pastePromise a1 a2 a3 a4 a5 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "lists the slides as rows, the cursor's open as the editor opens, each opened and closed by its header, several at once" $ runPage $ do
    -- The slides measured late, as on a slow machine: the headers found
    -- before are the ones there after.
    unsafeIOToPageM (js_fit_hold True)
    (ui, _) <- openDeck deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    (findAll ui ".editor-slides .slide-row-number" >>= traverse textContent) `shouldReturn` ["1.", "2.", "3.", "4."]
    -- The cursor starts under the title line, in the title slide's row.
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    headers <- findAll ui ".editor-slides .slide-row-toggle"
    editorFits `shouldReturn` replicate 4 "unmeasured"
    unsafeIOToPageM (js_fit_hold False)
    eventually $ editorFits `shouldReturn` replicate 4 "fits"
    traverse isAttached headers `shouldReturn` replicate 4 True
    watchEditor ui
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowHeader ui "Two" >>= (`getAttribute` "aria-expanded") >>= (`shouldBe` Just "true")
    rowHeader ui "Deck" >>= click
    eventually $ openTitles ui `shouldReturn` ["Two"]
    length <$> findAll ui ".editor-slides .cm-editor" `shouldReturn` 1
    rowHeader ui "Deck" >>= (`getAttribute` "aria-expanded") >>= (`shouldBe` Just "false")
    -- Rows change what is shown, never the text.
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck

  it "switches to the raw Markdown and back, which the browser keeps, changing no byte and opening the rows open before, of a text with carriage returns too" $ runPage $ do
    (ui, wiki) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    watchEditor ui
    modeButton ui "Raw" >>= click
    eventually $ length <$> findAll ui ".editor-slides" `shouldReturn` 0
    editorText ui >>= shouldBeVisible
    modeButton ui "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck
    -- The browser keeps the mode: the editor opened again is in it.
    again <- startOn m wiki helloEditor
    _ <- editorText again
    modeButton again "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    length <$> findAll again ".editor-slides" `shouldReturn` 0
    unmount again
    -- Back slide by slide: the rows open before open again.
    modeButton ui "Slides" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    markdown ui `shouldReturn` deck
    -- A text with carriage returns is cut into rows too, and either mode
    -- leaves every byte of it as it is.
    let returns = T.replace "\n" "\r\n" deck
    setMarkdown ui returns
    watchEditor ui
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    modeButton ui "Raw" >>= click
    modeButton ui "Slides" >>= click
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` returns

  it "completes in the raw Markdown after a visit to the rows, and in a row slide by slide, one list in each mode" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    modeButton ui "Raw" >>= click
    editorText ui >>= shouldBeVisible
    selectText ui (lineEnd deck 7) (lineEnd deck 7)
    editorText ui >>= (`typeText` " :smi")
    eventually $ completing ui `shouldReturn` "active"
    length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 1
    press "Escape"
    modeButton ui "Slides" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    text <- markdown ui
    rowSelect 1 (T.length (rowTextOf text 1)) (T.length (rowTextOf text 1))
    rowContent ui "One" >>= (`typeText` " :smi")
    eventually $ length <$> findAll ui ".editor-slides .cm-tooltip-autocomplete" `shouldReturn` 1
    length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 1
    completing ui `shouldReturn` ""

  it "has one history: Ctrl+Z in a row takes back a change in another, which opens, and the row left closes; the others stay" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    -- Typed at the end of "First.".
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "x")
    let typed = T.replace "First." "First.x" deck
    markdown ui `shouldReturn` typed
    -- From row "Three", Ctrl+Z: the change in "One" is undone there, which
    -- takes the focus, "Three" closes, and "Deck" stays open.
    rowHeader ui "Three" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One", "Three"]
    rowSelect 3 2 2
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    eventually $ rowFocused 1 `shouldReturn` True
    -- An undo inside the row with the focus closes nothing.
    rowContent ui "One" >>= (`typeText` "y")
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    openTitles ui `shouldReturn` ["Deck", "One"]
    -- To a row that is closed: it opens, with the focus and the cursor at
    -- the change.
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "z")
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowSelect 0 2 2
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ openTitles ui `shouldReturn` ["One"]
    eventually $ rowFocused 0 `shouldReturn` False
    rowSelection 1 `shouldReturn` (14, 14)
    -- The assistant writing in another row opens it, and closes none.
    proposeText ui (lineStart deck 15) (lineStart deck 15) "Proposed. "
    eventually $ openTitles ui `shouldReturn` ["One", "Three"]
    rowFocused 1 `shouldReturn` True
    -- Ctrl+Z on a header is the history's too.
    rowHeader ui "One" >>= focus
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "splits a row where a heading is typed and joins it again when the heading goes, after a pause, the editor with the focus kept, past an emoji" $ runPage $ do
    let titled = T.replace "# Deck" "# Deck 😀" deck
    (ui, _) <- openDeck titled
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck 😀", "One"]
    editor <- find ui ".editor-slides > li:nth-child(2) .cm-editor"
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "\n## Mid")
    let split = T.replace "First." "First.\n## Mid" titled
    markdown ui `shouldReturn` split
    eventually $ rowTitles ui `shouldReturn` ["Deck 😀", "One", "Mid", "Two", "Three"]
    -- The part above the cursor is a new row, open; the cursor's part has
    -- the editor it was typed in, still with the focus.
    eventually $ openTitles ui `shouldReturn` ["Deck 😀", "One", "Mid"]
    find ui ".editor-slides > li:nth-child(3) .cm-editor" >>= (`shouldBeSameElement` editor)
    rowFocused 2 `shouldReturn` True
    rowText 2 `shouldReturn` "## Mid\n"
    -- Undone: the heading goes, and the rows join, in the same editor.
    replicateM_ 4 (press "Control+z")
    eventually $ markdown ui `shouldReturn` titled
    eventually $ rowTitles ui `shouldReturn` ["Deck 😀", "One", "Two", "Three"]
    find ui ".editor-slides > li:nth-child(2) .cm-editor" >>= (`shouldBeSameElement` editor)
    -- The row above went from the list: the editor kept the focus.
    eventually $ rowFocused 1 `shouldReturn` True

  it "keeps the rows below a row that leaves a code block, a spoiler or an HTML comment open, their editors and cursors, and says the presentation takes them in" $ runPage $ do
    (ui, _) <- openDeck deck
    for_ ["One", "Two", "Three"] $ \title -> rowHeader ui title >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    two <- find ui ".editor-slides > li:nth-child(3) .cm-editor"
    three <- find ui ".editor-slides > li:nth-child(4) .cm-editor"
    rowSelect 3 3 5
    for_ ["```", "[[!spoiler]]{x}(Q)", "<!--"] $ \block -> do
      rowSelect 1 14 14
      rowContent ui "One" >>= (`typeText` ("\n\n" <> block))
      eventually $ (findAll ui ".editor-slides .slide-row-part" >>= traverse textContent) `shouldReturn` ["part of slide 2", "part of slide 2"]
      rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
      find ui ".editor-slides > li:nth-child(3) .cm-editor" >>= (`shouldBeSameElement` two)
      find ui ".editor-slides > li:nth-child(4) .cm-editor" >>= (`shouldBeSameElement` three)
      rowText 2 `shouldReturn` rowTextOf deck 2
      rowText 3 `shouldReturn` rowTextOf deck 3
      rowSelection 3 `shouldReturn` (3, 5)
      markdown ui `shouldReturn` T.replace "First." ("First.\n\n" <> block) deck
      -- Marked on the line that opens the block, and there alone.
      let typed = T.replace "First." ("First.\n\n" <> block) deck
          opening = T.length (fst (T.breakOn block typed))
          openingEnd = opening + T.length (T.takeWhile (/= '\n') block)
      eventually $ do
        marked <- problemsMarked ui
        [(a, b) | (a, b, message) <- marked, "A code block, a box or an HTML block on this slide is not closed" `T.isPrefixOf` message] `shouldBe` [(opening, openingEnd)]
      replicateM_ 3 (press "Control+z")
      eventually $ markdown ui `shouldReturn` deck
      eventually $ length <$> findAll ui ".editor-slides .slide-row-part" `shouldReturn` 0

  it "has one history in both modes: Ctrl+Z in the raw Markdown takes back a change made in a row, and in a row one made in the raw Markdown" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "x")
    markdown ui `shouldReturn` T.replace "First." "First.x" deck
    modeButton ui "Raw" >>= click
    editorText ui >>= shouldBeVisible
    selectText ui 0 0
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    selectText ui (lineEnd deck 11) (lineEnd deck 11)
    editorText ui >>= (`typeText` "y")
    markdown ui `shouldReturn` T.replace "Second." "Second.y" deck
    modeButton ui "Slides" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 3 3
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "drops a cut of an older text and keeps the typing, the next cut coming after it" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "x")
    -- A cut of the text before the keystroke, arriving late: not taken.
    unsafeIOToPageM (fromJSText <$> js_stale_rows (toJSText deck)) `shouldReturn` "[false,false]"
    let typed = T.replace "First." "First.x" deck
    markdown ui `shouldReturn` typed
    rowContent ui "One" >>= (`typeText` "\n## Late")
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Late", "Two", "Three"]
    markdown ui `shouldReturn` T.replace "First." "First.x\n## Late" deck

  it "counts a row's problems on its header, and takes the cursor to a problem in a closed row, which opens, past an emoji" $ runPage $ do
    let broken = T.intercalate "\n" ["# Deck 😀", "", "## One", "", "Fine.", "", "## Two", "", "Half: $\\frac{1}$ here.", "", "## Three", "", "Fine."]
    (ui, _) <- openDeck broken
    eventually $ (findAll ui ".editor-slides .slide-row-problems" >>= traverse textContent) `shouldReturn` ["1 problem"]
    -- The cursor starts in "One", under the title line.
    eventually $ openTitles ui `shouldReturn` ["One"]
    find ui ".editor-problems" >>= click
    eventually $ openTitles ui `shouldReturn` ["One", "Two"]
    eventually $ rowFocused 2 `shouldReturn` True
    (a, b) <- rowSelection 2
    shown <- rowText 2
    T.take (b - a) (T.drop a shown) `shouldSatisfy` T.isInfixOf "frac"

  it "folds a spoiler's section and a block spoiler in an open row, and unfolds them" $ runPage $ do
    let quiz = T.intercalate "\n" ["# Deck", "", "## Quiz", "", "### [[!spoiler]] Question", "", "Hidden answer.", "", "[[!spoiler]]{a}(The answer)", "Forty-two.", "[[/spoiler]]{a}", "", "## Next", "", "Text."]
    (ui, _) <- openDeck quiz
    -- The cursor starts in "Quiz", which is open.
    eventually $ openTitles ui `shouldReturn` ["Quiz"]
    let markers = eventually $ do
          found <- findAll ui ".editor-slides .cm-foldGutter .cm-wiki-fold-open"
          length found `shouldBe` 2
          pure found
    -- The block spoiler, by its marker, and open again by its mark.
    markers >>= traverse_ click . (`atMay` 1)
    eventually $ length <$> findAll ui ".editor-slides .cm-wiki-folded" `shouldReturn` 1
    eventually $ rowContent ui "Quiz" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "Forty-two."))
    find ui ".editor-slides .cm-wiki-folded" >>= click
    eventually $ length <$> findAll ui ".editor-slides .cm-wiki-folded" `shouldReturn` 0
    -- The heading spoiler's section.
    markers >>= traverse_ click . head
    eventually $ rowContent ui "Quiz" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "Hidden answer."))
    find ui ".editor-slides .cm-wiki-folded" >>= click
    eventually $ rowContent ui "Quiz" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Hidden answer.")
    markdown ui `shouldReturn` quiz

  it "draws the rows' headers before CodeMirror is there, not to be opened, and without the editor's script shows the Markdown with a note" $ runPage $ do
    unsafeIOToPageM (js_editor_script (toJSText "hold"))
    (ui, wiki) <- openDeckWith False deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    (findAll ui ".editor-slides .slide-row-toggle" >>= traverse (`getProperty` "disabled")) `shouldReturn` replicate 4 "true"
    unsafeIOToPageM (js_editor_script (toJSText "as-is"))
    eventually $ (findAll ui ".editor-slides .slide-row-toggle" >>= traverse (`getProperty` "disabled")) `shouldReturn` replicate 4 "false"
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    unmount ui
    unsafeIOToPageM (js_editor_script (toJSText "absent"))
    bare <- startOn m wiki helloEditor
    find bare ".editor-slides-note" >>= (`shouldHaveText` "Slide by slide needs the editor's script, which this page has not loaded: the presentation is shown as its Markdown.")
    length <$> findAll bare ".editor-slides" `shouldReturn` 0
    find bare ".editor-text" >>= shouldBeVisible
    unsafeIOToPageM (js_editor_script (toJSText "as-is"))

  it "shows the cursor's slide in the preview, and in the raw Markdown the whole deck or one slide" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    find ui ".editor-side-by-side" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck"]
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowSelect 2 1 1
    eventually $ cardTitles ui `shouldReturn` ["Two"]
    find ui ".editor-preview .slide-frame:not(.slide-offstage) .slide-number" >>= (`shouldHaveText` "3 / 4")
    modeButton ui "Raw" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    find ui ".editor-one-slide" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Two"]

  it "disables the toolbar's commands while no row is open, and runs them in the row with the cursor" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowHeader ui "Deck" >>= click
    eventually $ openTitles ui `shouldReturn` []
    bold <- find ui ".editor-toolbar button.tool[aria-label=\"Bold\"]"
    getProperty bold "disabled" `shouldReturn` "true"
    rowHeader ui "Two" >>= click
    eventually $ getProperty bold "disabled" `shouldReturn` "false"
    rowSelect 2 8 15
    click bold
    eventually $ markdown ui `shouldReturn` T.replace "Second." "**Second.**" deck
    rowText 2 `shouldReturn` "## Two\n\n**Second.**\n"

  it "moves a slide with Alt+Up and Alt+Down from its header and from its text, one step each that one undo takes back, the editors, cursors and focus kept, the title slide staying first" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    -- From the header.
    rowHeader ui "Two" >>= focus
    press "Alt+ArrowUp"
    let up = moveSlide 2 1 deck
    eventually $ markdown ui `shouldReturn` up
    eventually $ rowTitles ui `shouldReturn` ["Deck", "Two", "One", "Three"]
    openTitles ui `shouldReturn` ["Deck", "Two"]
    eventually $ status ui `shouldReturn` "Slide 2, 'Two' moved to 2 of 4"
    -- Up again would put it above the title slide: no move.
    press "Alt+ArrowUp"
    markdown ui `shouldReturn` up
    press "Alt+ArrowDown"
    eventually $ markdown ui `shouldReturn` deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` up
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    -- From the text, with "Three" open below: the moved row keeps its
    -- editor, its cursor and the focus, and so does the other.
    rowHeader ui "Three" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two", "Three"]
    two <- find ui ".editor-slides > li:nth-child(3) .cm-editor"
    three <- find ui ".editor-slides > li:nth-child(4) .cm-editor"
    rowSelect 3 2 4
    rowSelect 2 3 5
    press "Alt+ArrowDown"
    let down = moveSlide 2 3 deck
    eventually $ markdown ui `shouldReturn` down
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three", "Two"]
    find ui ".editor-slides > li:nth-child(4) .cm-editor" >>= (`shouldBeSameElement` two)
    find ui ".editor-slides > li:nth-child(3) .cm-editor" >>= (`shouldBeSameElement` three)
    eventually $ rowFocused 3 `shouldReturn` True
    rowSelection 3 `shouldReturn` (3, 5)
    rowSelection 2 `shouldReturn` (2, 4)
    -- Undone in the row: back, the same editors.
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    find ui ".editor-slides > li:nth-child(3) .cm-editor" >>= (`shouldBeSameElement` two)
    -- And redone from the raw Markdown's history.
    modeButton ui "Raw" >>= click
    selectText ui 0 0
    press "Control+y"
    eventually $ markdown ui `shouldReturn` down
    modeButton ui "Slides" >>= click
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three", "Two"]

  it "moves a slide dragged by its handle before or after the row it is dropped on, and gives no handle to the title slide" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    handles <- eventually $ do
      found <- findAll ui ".editor-slides .slide-row-handle"
      length found `shouldBe` 3
      pure found
    -- Dropped on the upper half of a header: before that row.
    target <- rowHeader ui "Three"
    traverse_ (`dragTo` target) (head handles)
    eventually $ markdown ui `shouldReturn` moveSlide 1 2 deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    -- Dropped low on a row: after it.
    below <- find ui ".editor-slides > li:nth-child(4) .slide-row-add"
    findAll ui ".editor-slides .slide-row-handle" >>= traverse_ (`dragTo` below) . head
    eventually $ markdown ui `shouldReturn` moveSlide 1 3 deck
    length <$> findAll ui ".editor-slides .drop-before, .editor-slides .drop-after" `shouldReturn` 0

  it "deletes a slide without asking, one step: the next row's header takes the focus, and Ctrl+Z brings the row back, open as it was" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowDelete ui "Two" >>= click
    let cut = fst (cutRows (RowKey 0) deck)
        deleted = maybe deck (assemble . fst) (deleteRow 2 cut)
    eventually $ markdown ui `shouldReturn` deleted
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    eventually $ status ui `shouldReturn` "Slide 3, 'Two' deleted. Ctrl+Z brings it back."
    -- The focus on "Three"'s header: Ctrl+Z there.
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    -- The title slide has no delete button.
    length <$> findAll ui ".editor-slides .slide-row-delete" `shouldReturn` 3

  it "adds a slide after the row last typed in, and at the end by a row's +, open with its title selected and the focus in it" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 3 3
    find ui ".editor-new-slide" >>= click
    let cut = fst (cutRows (RowKey 0) deck)
        added = assemble (fst (newRow (RowKey 9) "New slide" 2 cut))
    eventually $ markdown ui `shouldReturn` added
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "New slide", "Two", "Three"]
    eventually $ openTitles ui `shouldReturn` ["Deck", "One", "New slide"]
    eventually $ rowFocused 2 `shouldReturn` True
    eventually $ status ui `shouldReturn` "Slide 3, 'New slide' added."
    openRowContent ui >>= (`typeText` "Mine")
    markdown ui `shouldReturn` T.replace "## New slide" "## Mine" added
    press "Control+z"
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    -- At the end, by the last row's "+".
    find ui ".editor-slides > li:nth-child(4) .slide-row-add" >>= click
    eventually $ markdown ui `shouldReturn` assemble (fst (newRow (RowKey 9) "New slide" 4 cut))
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three", "New slide"]

  it "says in its live region where an undo took the cursor" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "x")
    rowSelect 0 2 2
    press "Control+z"
    eventually $ status ui `shouldReturn` "Undo in slide 2, 'One'"

  it "keeps a draft through a reopened editor in either mode" $ runPage $ do
    (ui, wiki) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 14 14
    rowContent ui "One" >>= (`typeText` "x")
    let typed = T.replace "First." "First.x" deck
    keepDraft ui
    again <- startOn m wiki helloEditor
    eventually $ markdown again `shouldReturn` typed
    eventually $ rowTitles again `shouldReturn` ["Deck", "One", "Two", "Three"]
    modeButton again "Raw" >>= click
    selectText again (lineEnd typed 11) (lineEnd typed 11)
    editorText again >>= (`typeText` "y")
    let both = T.replace "Second." "Second.y" typed
    keepDraft again
    third <- startOn m wiki helloEditor
    eventually $ markdown third `shouldReturn` both
    modeButton third "Slides" >>= click
    eventually $ rowTitles third `shouldReturn` ["Deck", "One", "Two", "Three"]
    rowHeader third "Two" >>= click
    eventually $ rowText 2 `shouldReturn` "## Two\n\nSecond.y\n"

  it "mounts no row's editor for sixty slides but the one the cursor starts in, and one more for each header clicked" $ runPage $ do
    let sixty = T.intercalate "\n\n" ("# Sixty" : concat [["## Slide " <> show n, "Text " <> show n <> "."] | n <- [1 .. 59 :: Int]])
    (ui, _) <- openDeck sixty
    eventually $ length <$> rowTitles ui `shouldReturn` 60
    eventually $ openTitles ui `shouldReturn` ["Slide 1"]
    length <$> findAll ui ".editor-slides .cm-editor" `shouldReturn` 1
    length <$> findAll ui ".editor-form .cm-editor" `shouldReturn` 2
    rowHeader ui "Slide 1" >>= click
    eventually $ length <$> findAll ui ".editor-slides .cm-editor" `shouldReturn` 0
    rowHeader ui "Slide 40" >>= click
    eventually $ length <$> findAll ui ".editor-slides .cm-editor" `shouldReturn` 1

  it "keeps the title line's mark in the first row" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowSelect 0 0 0
    press "Backspace"
    press "Delete"
    press "Delete"
    eventually $ markdown ui >>= (`shouldSatisfy` T.isPrefixOf "# ")
    rowText 0 >>= (`shouldSatisfy` T.isPrefixOf "# ")

  it "keeps the title line's mark in the row that starts the text, whichever row that is after a split or a join, and nowhere else" $ runPage $ do
    -- The rows' editors come late, as on a slow machine: a row is shown
    -- open before its CodeMirror is there to select in.
    unsafeIOToPageM (js_rows_late 300)
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    -- A heading typed under the title: after the pause the editor it was
    -- typed in holds the new slide, which no longer starts the text.
    rowSelect 0 14 14
    rowContent ui "Deck" >>= (`typeText` "\n## New")
    eventually $ rowTitles ui `shouldReturn` ["Deck", "New", "One", "Two", "Three"]
    eventually $ rowFocused 1 `shouldReturn` True
    openRowContent ui >>= (`typeText` "s")
    eventually $ markdown ui `shouldReturn` T.replace "By me." "By me.\n## News" deck
    unsafeIOToPageM (js_rows_late 0)
    unmount ui
    -- "One" joined to the title slide, its heading taken away in its own
    -- editor, which then starts the text and keeps the mark.
    (joined, _) <- openDeck deck
    rowHeader joined "Deck" >>= click
    rowHeader joined "One" >>= click
    eventually $ openTitles joined `shouldReturn` ["One"]
    editor <- find joined ".editor-slides > li:nth-child(2) .cm-editor"
    rowSelect 1 0 7
    press "Backspace"
    eventually $ rowTitles joined `shouldReturn` ["Deck", "Two", "Three"]
    find joined ".editor-slides > li:nth-child(1) .cm-editor" >>= (`shouldBeSameElement` editor)
    rowSelect 0 0 0
    press "Backspace"
    press "Delete"
    press "Delete"
    eventually $ markdown joined >>= (`shouldSatisfy` T.isPrefixOf "# ")
    rowText 0 >>= (`shouldSatisfy` T.isPrefixOf "# ")

  it "leaves a file dropped or pasted in a row to the editor, which attaches it at the cursor, and puts in neither the file's text nor its name; names the row's text by its slide's title" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowSelect 0 14 14
    -- CodeMirror would read the dropped file, put its text where it was
    -- dropped and select it, and the editor's link would take its place
    -- there, not at the cursor.
    unsafeIOToPageM (dropFile ".editor-slides .slide-row.open .cm-content" "notes.txt" "text/plain" "aGVsbG8K")
    let dropped = T.replace "By me." "By me.[notes.txt](attachment:notes.txt)" deck
    eventually $ markdown ui `shouldReturn` dropped
    settle
    markdown ui `shouldReturn` dropped
    prevented <- unsafeIOToPageM (pasteFile ".editor-slides .slide-row.open .cm-content" "pasted.txt" "pasted.txt" "text/plain" "aGVsbG8K")
    prevented `shouldBe` True
    let pasted = T.replace "By me." "By me.[notes.txt](attachment:notes.txt)[pasted.txt](attachment:pasted.txt)" deck
    eventually $ markdown ui `shouldReturn` pasted
    settle
    markdown ui `shouldReturn` pasted
    named <- find ui ".editor-slides .slide-row.open .cm-content" >>= (`getAttribute` "aria-labelledby")
    find ui ("#" <> fromMaybe "none" named) >>= (`shouldHaveText` "Deck")

  it "marks in a row without the focus the editor's selection, the one the assistant is given, and not a selection the row kept from before" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    let kept = T.concat <$> (findAll ui ".editor-slides .cm-wiki-kept-selection" >>= traverse textContent)
    rowSelect 0 2 6
    find ui ".editor-new-slide" >>= focus
    eventually $ kept `shouldReturn` "Deck"
    -- Selected in "One" since: "Deck" keeps its own selection, which is
    -- no longer the editor's.
    rowSelect 1 8 14
    find ui ".editor-new-slide" >>= focus
    eventually $ kept `shouldReturn` "First."
    -- In the text again, the browser shows the selection itself.
    rowSelect 1 8 14
    eventually $ kept `shouldReturn` ""

  it "takes back a selection with Ctrl+U in a row, from the one history, and indents with Tab" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowSelect 0 8 8
    rowSelect 0 10 12
    press "Control+u"
    eventually $ rowSelection 0 `shouldReturn` (8, 8)
    press "Tab"
    eventually $ markdown ui `shouldReturn` T.replace "By me." "  By me." deck
    rowFocused 0 `shouldReturn` True

  it "scrolls to the cursor of the row an undo takes it to, the editor's own text being hidden" $ runPage $ do
    let long = T.intercalate "\n\n" ("# Long" : concat [["## S" <> show i, T.intercalate "\n\n" (replicate 8 "A paragraph of its own.")] | i <- [1 .. 30 :: Int]])
    (ui, _) <- openDeck long
    rowHeader ui "S30" >>= click
    eventually $ openTitles ui `shouldReturn` ["S1", "S30"]
    end <- T.length <$> eventually (rowText 30 >>= \t -> t <$ (t `shouldSatisfy` (not . T.null)))
    rowSelect 30 end end
    openRowContent ui >>= (`typeText` "x")
    eventually $ markdown ui `shouldReturn` long <> "x"
    rowContent ui "S1" >>= click
    eventually $ rowCursorSeen 30 `shouldReturn` False
    press "Control+z"
    eventually $ markdown ui `shouldReturn` long
    eventually $ rowCursorSeen 30 `shouldReturn` True

  it "gives the focus to the row an undo or a redo takes the cursor to when it takes away the row the focus was in, its text when open and its header when closed" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    rowSelect 1 3 3
    find ui ".editor-new-slide" >>= click
    let added = ["Deck", "One", "New slide", "Two", "Three"]
    eventually $ rowTitles ui `shouldReturn` added
    eventually $ slideFocus `shouldReturn` "text 2"
    -- From the keyboard alone: each key reaches the history.
    press "Control+z"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    eventually $ slideFocus `shouldReturn` "text 1"
    press "Control+y"
    eventually $ rowTitles ui `shouldReturn` added
    slideFocus >>= (`shouldSatisfy` T.isPrefixOf "text ")
    press "Control+z"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    eventually $ markdown ui `shouldReturn` deck
    slideFocus >>= (`shouldSatisfy` T.isPrefixOf "text ")
    -- The redo of a delete, with the focus in the deleted row's text: the
    -- row the cursor goes to is closed, and its header takes the focus.
    rowHeader ui "One" >>= click
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowDelete ui "Two" >>= click
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    press "Control+z"
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowContent ui "Two" >>= click
    press "Control+y"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    eventually $ slideFocus >>= (`shouldSatisfy` T.isPrefixOf "header ")
    press "Control+z"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]

  it "brings a slide deleted open back open through any number of undos and redos, and back closed when it was closed as it went" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowDelete ui "Two" >>= click
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    for_ [1 :: Int, 2, 3] $ \_ -> do
      press "Control+z"
      eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
      press "Control+y"
      eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    press "Control+z"
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    -- Closed, then taken away by the redo: it comes back closed.
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    press "Control+y"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Three"]
    press "Control+z"
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    openTitles ui `shouldReturn` ["Deck"]

  it "shows the textarea until CodeMirror is in place, the typing there cut into rows, and the Markdown with the note when CodeMirror's module fails to load" $ runPage $ do
    unsafeIOToPageM (js_editor_script (toJSText "hold"))
    (ui, wiki) <- openDeckWith False deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    area <- find ui ".editor-text"
    shouldBeVisible area
    focus area
    press "Control+End"
    typeText area "\n\n## Four"
    unsafeIOToPageM (js_editor_script (toJSText "as-is"))
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three", "Four"]
    markdown ui `shouldReturn` deck <> "\n\n## Four"
    unmount ui
    unsafeIOToPageM (js_editor_script (toJSText "fail"))
    failed <- startOn m wiki helloEditor
    eventually $ find failed ".editor-slides-note" >>= (`shouldHaveText` "Slide by slide needs the editor's script, which this page has not loaded: the presentation is shown as its Markdown.")
    length <$> findAll failed ".editor-slides" `shouldReturn` 0
    find failed ".editor-text" >>= shouldBeVisible
    unsafeIOToPageM (js_editor_script (toJSText "as-is"))

  it "opens a closed row that an undo or a toolbar command takes the cursor to, though its text had the focus last" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowSelect 2 15 15
    openRowContent ui >>= (`typeText` "x")
    eventually $ markdown ui `shouldReturn` T.replace "Second." "Second.x" deck
    -- Closed by its header, which keeps the focus: Ctrl+Z there.
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    eventually $ rowFocused 2 `shouldReturn` True
    -- Selected, closed, and made bold from the toolbar.
    rowSelect 2 8 15
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    find ui ".editor-toolbar button.tool[aria-label=\"Bold\"]" >>= click
    eventually $ markdown ui `shouldReturn` T.replace "Second." "**Second.**" deck
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]

  it "opens a closed row that the next problem is in, though its text had the focus last" $ runPage $ do
    let broken = T.intercalate "\n" ["# Deck", "", "## One", "", "Fine.", "", "## Two", "", "Half: $\\frac{1}$ here.", "", "## Three", "", "Fine."]
    (ui, _) <- openDeck broken
    eventually $ openTitles ui `shouldReturn` ["One"]
    eventually $ find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["One", "Two"]
    rowSelect 2 0 0
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["One"]
    find ui ".editor-problems" >>= click
    eventually $ openTitles ui `shouldReturn` ["One", "Two"]
    eventually $ rowFocused 2 `shouldReturn` True

  it "counts on its row a diagram's failure that comes after the slides were measured, and no longer once the diagram is fixed" $ runPage $ do
    let drawn = T.intercalate "\n" ["# Deck", "", "## One", "", "```mermaid", "graph LR", "  a -->", "```", "", "## Two", "", "Second."]
        rowProblems ui = findAll ui ".editor-slides .slide-row-problems" >>= traverse textContent
    unsafeIOToPageM (js_mermaid (toJSText "hold"))
    (ui, _) <- openDeck drawn
    eventually $ editorFits >>= (`shouldSatisfy` \fits -> length fits == 3 && all (/= "unmeasured") fits)
    rowProblems ui `shouldReturn` []
    unsafeIOToPageM (js_mermaid (toJSText "as-is"))
    -- Mermaid's bundle is fetched the first time a diagram is drawn.
    eventuallyWithin 15000 $ find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")
    eventually $ rowProblems ui `shouldReturn` ["1 problem"]
    -- Fixed in its row.
    eventually $ openTitles ui `shouldReturn` ["One"]
    rowSelect 1 35 35
    openRowContent ui >>= (`typeText` " b")
    eventually $ markdown ui `shouldReturn` T.replace "  a -->" "  a --> b" drawn
    eventuallyWithin 15000 $ rowProblems ui `shouldReturn` []
    length <$> findAll ui ".editor-problems" `shouldReturn` 0

  it "puts every key typed through a split and a join where the caret is, keys coming as the rows are cut again" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowSelect 0 14 14
    -- Each key after a pause about as long as the one after which the
    -- rows are cut again, so that some arrive while a cut is on its way.
    let paced keys = for_ (zip keys (cycle [150_000, 190_000, 200_000, 210_000, 230_000, 260_000])) $ \(key, pause) -> do
          unsafeIOToPageM (threadDelay pause)
          press key
    paced ["Enter", "#", "#", " ", "M", "i", "d", "a", "b", "c", "d", "e", "f"]
    let split = T.replace "By me." "By me.\n## Midabcdef" deck
    eventually $ markdown ui `shouldReturn` split
    eventually $ rowTitles ui `shouldReturn` ["Deck", "Midabcdef", "One", "Two", "Three"]
    -- Taken away again, key by key: the rows join. The last Backspace
    -- comes at the start of the row before the rows have joined, and
    -- takes the line break above it all the same.
    paced (replicate 13 "Backspace")
    eventually $ markdown ui `shouldReturn` deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    -- Delete at a row's end takes the line break after it.
    rowHeader ui "One" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "One"]
    end <- T.length <$> eventually (rowText 1 >>= \t -> t <$ (t `shouldSatisfy` (not . T.null)))
    rowSelect 1 end end
    press "Delete"
    eventually $ markdown ui `shouldReturn` T.replace "First.\n\n## Two" "First.\n## Two" deck

  it "changes nothing when the mode already chosen is chosen again, and makes two slides of a double click on New slide" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    modeButton ui "Slides" >>= click
    settle
    openTitles ui `shouldReturn` ["Deck", "Two"]
    modeButton ui "Raw" >>= click
    eventually $ length <$> findAll ui ".editor-slides" `shouldReturn` 0
    modeButton ui "Raw" >>= click
    settle
    modeButton ui "Slides" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    -- Two slides, each with a key of its own.
    newSlide <- find ui ".editor-new-slide"
    click newSlide
    click newSlide
    eventually $ length <$> findAll ui ".editor-slides .slide-row" `shouldReturn` 6
    keys <- findAll ui ".editor-slides .slide-row" >>= traverse (`getAttribute` "data-row-key")
    length (ordNub keys) `shouldBe` 6

  it "writes nothing at the cursor while no row is open: the toolbar's buttons and menus disabled, saying why, and the shortcuts on a header" $ runPage $ do
    (ui, _) <- openDeck deck
    eventually $ openTitles ui `shouldReturn` ["Deck"]
    rowHeader ui "Deck" >>= click
    eventually $ openTitles ui `shouldReturn` []
    let writing = ["Bold", "Italic", "Link to a page", "Image or attachment", "Colour", "Emoji", "Box", "HTML"]
    for_ writing $ \label -> do
      control <- find ui (".editor-toolbar button.tool[aria-label=\"" <> label <> "\"]")
      eventually $ getProperty control "disabled" `shouldReturn` "true"
      getAttribute control "title" >>= (`shouldSatisfy` maybe False (T.isSuffixOf "open a slide to write in it"))
    -- The math macros write the page's block, at its own place: not
    -- disabled.
    find ui ".editor-toolbar .editor-macros-toggle" >>= (`getProperty` "disabled") >>= (`shouldBe` "false")
    -- A shortcut on a header is the browser's.
    header <- rowHeader ui "Two"
    focus header
    for_ ["Control+b", "Control+i", "Control+k", "Control+e", "Control+Shift+K", "Control+Shift+7", "Tab"] press
    settle
    markdown ui `shouldReturn` deck
    openTitles ui `shouldReturn` []
    -- A row open again: the menus write in it.
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Two"]
    rowSelect 2 8 15
    find ui ".editor-toolbar button.tool[aria-label=\"HTML\"]" >>= click
    find ui ".toolbar-menu [role=menuitem]" >>= click
    eventually $ markdown ui >>= (`shouldSatisfy` (/= deck))

  it "stays responsive while a row leaves a fence open with 500 lines after it" $ runPage $ do
    let code = T.intercalate "\n" (["# Deck", "", "## Code", "", "```haskell"] <> ["x = " <> show k | k <- [1 .. 500 :: Int]] <> ["```", "", "## After", "", "Text."])
    (ui, _) <- openDeck code
    -- The cursor starts in "Code", under the title line.
    eventually $ openTitles ui `shouldReturn` ["Code"]
    shown <- eventually (rowText 1 >>= \t -> t <$ (t `shouldSatisfy` T.isInfixOf "x = 500"))
    -- The closing fence taken away: the fence is left open, and takes in
    -- "After".
    let (before, _) = T.breakOnEnd "\n```" shown
    rowSelect 1 (T.length before - 3) (T.length before)
    -- The page's thread is held for about half a second after the pause
    -- (the check, the preview of a long code block, the measures); the
    -- line of the block left open, found by parsing the row again for
    -- each of its lines, held it for twenty seconds. The bound leaves room
    -- for a slow machine.
    unsafeIOToPageM js_stall_start
    press "Backspace"
    eventually $ (findAll ui ".editor-slides .slide-row-problems" >>= traverse textContent) `shouldReturn` ["1 problem"]
    unsafeIOToPageM (threadDelay 1_000_000)
    stalled <- unsafeIOToPageM js_stall
    stalled `shouldSatisfy` (< 5000)
    -- A keystroke in the open fence, and the pause after it.
    unsafeIOToPageM js_stall_start
    openRowContent ui >>= (`typeText` "y")
    unsafeIOToPageM (threadDelay 1_000_000)
    typed <- unsafeIOToPageM js_stall
    typed `shouldSatisfy` (< 5000)

  it "takes the emoji or the mention chosen with the arrows in a row, though the hidden editor changes before Enter, with another row open" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    let chooseIn typed = do
          rowSelect 0 14 14
          openRowContent ui >>= (`typeText` ("\n\n" <> typed))
          eventually $ length <$> findAll ui ".editor-slides .cm-tooltip-autocomplete" `shouldReturn` 1
          -- The list takes keys only once it has been shown a moment (the
          -- library's interactionDelay).
          unsafeIOToPageM (threadDelay 200_000)
          press "ArrowDown"
          eventually $ (findAll ui ".editor-slides .cm-tooltip-autocomplete li[aria-selected]" >>= traverse (`getAttribute` "id")) >>= (`shouldSatisfy` ((== 1) . length))
          settle
          -- The check's problems, told to the hidden editor after a pause.
          unsafeIOToPageM js_master_problems
          settle
          press "Enter"
          eventually $ length <$> findAll ui ".editor-slides .cm-tooltip-autocomplete" `shouldReturn` 0
          T.takeWhile (/= '\n') . snd . T.breakOnEnd "By me.\n\n" <$> markdown ui
    -- One letter: Enter chooses an emoji only once the arrows moved.
    emoji <- chooseIn ":s"
    emoji `shouldSatisfy` (\line -> T.length line > 3 && ":" `T.isPrefixOf` line && ":" `T.isSuffixOf` line)
    mention <- chooseIn "@ad"
    mention `shouldSatisfy` (\line -> T.length line > 3 && "@" `T.isPrefixOf` line && " " `T.isSuffixOf` line)
    openTitles ui `shouldReturn` ["Deck", "Two"]

  it "opens no mention's list in a link whose label another slide defines, in a row as in the raw Markdown" $ runPage $ do
    let linked = T.intercalate "\n" ["# Deck", "", "## One", "", "First.", "", "[ref]: https://example.com", "", "## Two", "", "[x][ref] and [y][ref] here."]
    (ui, _) <- openDeck linked
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["One", "Two"]
    -- In the row: after the bracket of [x][ref].
    rowSelect 2 9 9
    openRowContent ui >>= (`typeText` "@ad")
    unsafeIOToPageM (threadDelay 1_000_000)
    length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    press "Enter"
    eventually $ markdown ui `shouldReturn` T.replace "[x]" "[@ad\nx]" linked
    -- In the raw Markdown: after the bracket of [y][ref].
    modeButton ui "Raw" >>= click
    editorText ui >>= shouldBeVisible
    typedRow <- markdown ui
    let at = T.length (fst (T.breakOn "[y]" typedRow)) + 1
    selectText ui at at
    editorText ui >>= (`typeText` "@ad")
    unsafeIOToPageM (threadDelay 1_000_000)
    length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    press "Enter"
    eventually $ markdown ui `shouldReturn` T.replace "[y]" "[@ad\ny]" typedRow
    -- A list does open there where no slide defines the label.
    modeButton ui "Slides" >>= click
    eventually $ openTitles ui `shouldReturn` ["One", "Two"]
    rowSelect 2 0 0
    rowText 2 >>= \t -> rowSelect 2 (T.length t) (T.length t)
    openRowContent ui >>= (`typeText` " [@ad][nowhere]")
    rowText 2 >>= \t -> rowSelect 2 (T.length t - 10) (T.length t - 10)
    unsafeIOToPageM (threadDelay 300_000)
    openRowContent ui >>= (`typeText` "m")
    eventually $ length <$> findAll ui ".editor-slides .cm-tooltip-autocomplete" `shouldReturn` 1

  it "opens no mention's list in a row that a fence left open above takes into its code" $ runPage $ do
    (ui, _) <- openDeck deck
    rowHeader ui "Two" >>= click
    eventually $ openTitles ui `shouldReturn` ["Deck", "Two"]
    rowSelect 0 14 14
    openRowContent ui >>= (`typeText` "\n\n```")
    eventually $ (findAll ui ".editor-slides .slide-row-part" >>= traverse textContent) >>= (`shouldSatisfy` (not . null))
    end <- T.length <$> rowText 2
    rowSelect 2 end end
    openRowContent ui >>= (`typeText` " @ad")
    unsafeIOToPageM (threadDelay 1_000_000)
    length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0

  it "hands the focus from the textarea to the cursor's row when CodeMirror arrives, nothing typed lost, the caret after it" $ runPage $ do
    unsafeIOToPageM (js_editor_script (toJSText "hold"))
    (ui, _) <- openDeckWith False deck
    eventually $ rowTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    area <- find ui ".editor-text"
    focus area
    press "Control+End"
    typeText area "\n\nAbc"
    unsafeIOToPageM (js_editor_script (toJSText "as-is"))
    -- Typing on at once, as the editor arrives.
    traverse_ press ["d", "e", "f"]
    let typed = deck <> "\n\nAbcdef"
    eventually $ markdown ui `shouldReturn` typed
    eventually $ slideFocus `shouldReturn` "text 3"
    let end = T.length (rowTextOf typed 3)
    rowSelection 3 `shouldReturn` (end, end)
    press "g"
    eventually $ markdown ui `shouldReturn` typed <> "g"

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

  it "marks whether each slide fits, grey until measured, on its row, on its card and among the problems" $ runPage $ do
    let fitting = T.intercalate "\n\n" (["# Deck", "## Short", "One line."] <> ["## Long"] <> replicate 30 "A paragraph of its own, one line long.")
    (ui, _) <- openDeck fitting
    eventually $ editorFits `shouldReturn` ["fits", "fits", "overflowing"]
    length <$> findAll ui ".editor-slides .slide-row-fit.slide-fit-overflowing" `shouldReturn` 1
    length <$> findAll ui ".editor-preview .slide-frame.slide-fit-overflowing" `shouldReturn` 1
    eventually $ do
      marked <- problemsMarked ui
      [(a, message) | (a, _, message) <- marked] `shouldSatisfy` \case
        [(a, message)] -> a == lineStart fitting 7 && "This slide is cut when presented" `T.isPrefixOf` message
        _ -> False
    -- A slide changed is grey until it is measured again; the others keep
    -- their marks.
    selectText ui (lineStart fitting 5) (lineStart fitting 5)
    openRowContent ui >>= (`typeText` "Still ")
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
    openRowContent ui >>= (`typeText` "x")
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
    eventually $ openTitles ui `shouldReturn` ["One"]
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
    openDeck = openDeckWith True

    -- The same, waiting for CodeMirror or not.
    openDeckWith :: forall s. Bool -> Text -> PageM s (Mounted s Shell.Query Void m, IORef MemState)
    openDeckWith waiting text = do
      (opener, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
      -- One shell at a time: the editor's, which a route followed moves.
      unmount opener
      unsafeIOToPageM . runMemWiki wiki $ do
        blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
        hello <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
        made <- either (panic . show) identity <$> setPageKind hello.id Kind.Presentation
        void (either (panic . show) identity <$> savePage made.id made.updatedAt "Deck" text)
      ui <- startOn m wiki helloEditor
      when waiting (void (editorText ui))
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

-- | What the rows' live region says last.
status :: Mounted s q o m -> PageM s Text
status ui = find ui ".editor-slides-status" >>= textContent

-- | The delete button of the row with this title.
rowDelete :: Mounted s q o m -> Text -> PageM s (Element s)
rowDelete ui title = eventually $ do
  rows <- findAll ui ".editor-slides .slide-row"
  named <- filterM (\r -> (== title) <$> (findIn r ".slide-row-title" >>= textContent)) rows
  maybe (expectationFailure ("no row " <> title)) (`findIn` ".slide-row-delete") (head named)

-- | Cancel, and keep the draft: the editor goes, its work kept as a draft.
keepDraft :: Mounted s q o m -> PageM s ()
keepDraft ui = do
  find ui ".editor-cancel" >>= click
  buttons <- eventually (findAll ui ".editor-cancel-confirm button")
  named <- filterM (fmap (T.isInfixOf "Keep the draft") . textContent) buttons
  maybe (expectationFailure "no Keep the draft") click (head named)
  eventually $ length <$> findAll ui ".editor-form" `shouldReturn` 0

-- | The rows' titles, in the order of the rows; and the open rows'.
rowTitles :: Mounted s q o m -> PageM s [Text]
rowTitles ui = findAll ui ".editor-slides .slide-row-title" >>= traverse textContent

openTitles :: Mounted s q o m -> PageM s [Text]
openTitles ui = findAll ui ".editor-slides .slide-row.open .slide-row-title" >>= traverse textContent

-- | The header of the row with this title.
rowHeader :: Mounted s q o m -> Text -> PageM s (Element s)
rowHeader ui title = eventually $ do
  rows <- findAll ui ".editor-slides .slide-row"
  named <- filterM (\r -> (== title) <$> (findIn r ".slide-row-title" >>= textContent)) rows
  maybe (expectationFailure ("no row " <> title)) (`findIn` ".slide-row-toggle") (head named)

-- | What one types into in the open row with this title.
rowContent :: Mounted s q o m -> Text -> PageM s (Element s)
rowContent ui title = eventually $ do
  rows <- findAll ui ".editor-slides .slide-row.open"
  named <- filterM (\r -> (== title) <$> (findIn r ".slide-row-title" >>= textContent)) rows
  maybe (expectationFailure ("no open row " <> title)) (`findIn` ".cm-content") (head named)

-- | What one types into in the open row whose editor has the focus.
openRowContent :: Mounted s q o m -> PageM s (Element s)
openRowContent ui = find ui ".editor-slides .cm-editor.cm-focused .cm-content"

-- | The text of the row at an index ("" when it is closed), its
-- selection, and whether it has the focus; select in it, in characters.
rowText :: Int -> PageM s Text
rowText i = unsafeIOToPageM (fromJSText <$> js_row_text i)

-- A row shown open gets its CodeMirror a moment later: the selection waits
-- until the row's editor is there to take it, so that what is typed next
-- goes where the test means. (The editor may move it: the title line's
-- guard keeps it out of the "# ".)
rowSelect :: Int -> Int -> Int -> PageM s ()
rowSelect i anchor h = do
  eventually $ unsafeIOToPageM (js_row_select i anchor h) `shouldReturn` True
  settle

rowSelection :: Int -> PageM s (Int, Int)
rowSelection i = do
  json <- unsafeIOToPageM (fromJSText <$> js_row_selection i)
  pure $ case decodeStrict (encodeUtf8 json) of
    Just [a, b] -> (a, b)
    _ -> (-1, -1)

rowFocused :: Int -> PageM s Bool
rowFocused i = unsafeIOToPageM (js_row_focused i)

-- | Whether the cursor of the row at an index can be seen.
rowCursorSeen :: Int -> PageM s Bool
rowCursorSeen i = unsafeIOToPageM (js_row_cursor_seen i)

-- | Where the focus is in the rows' list (test-slides.js's
-- wiki_test_slide_focus).
slideFocus :: PageM s Text
slideFocus = unsafeIOToPageM (fromJSText <$> js_slide_focus)

-- | A drop of a file on the element a selector finds; a paste of a file
-- with a text beside it, and whether its default was prevented.
dropFile :: Text -> Text -> Text -> Text -> IO ()
dropFile selector name mediaType base64 = evaluate =<< js_drop_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)

pasteFile :: Text -> Text -> Text -> Text -> Text -> IO Bool
pasteFile selector text name mediaType base64 = evaluate =<< js_paste (toJSText selector) (toJSText text) (toJSText name) (toJSText mediaType) (toJSText base64)

-- | The text of a row of a text's fresh cut.
rowTextOf :: Text -> Int -> Text
rowTextOf text i = maybe "" (\r -> r.text) (atMay (fst (cutRows (RowKey 0) text)).rows i)

-- | Where a line of a text ends.
lineEnd :: Text -> Int -> Int
lineEnd text n = lineStart text n + maybe 0 T.length (atMay (T.splitOn "\n" text) (n - 1))

-- | One of the two buttons of the switch between slide by slide and the
-- raw Markdown, by its text.
modeButton :: Mounted s q o m -> Text -> PageM s (Element s)
modeButton ui label = eventually $ do
  buttons <- findAll ui ".editor-slides-mode button"
  named <- filterM (fmap (== label) . textContent) buttons
  maybe (expectationFailure ("no button " <> label)) pure (head named)

-- | The titles of the slides the preview shows.
cardTitles :: Mounted s q o m -> PageM s [Text]
cardTitles ui = findAll ui ".editor-preview .slides-preview .slide-frame:not(.slide-offstage) .slide-title" >>= traverse textContent

-- | Where a line of a text starts, in characters (the text is ASCII, so
-- characters are UTF-16 units).
lineStart :: Text -> Int -> Int
lineStart text n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" text)))
