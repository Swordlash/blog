{-# LANGUAGE TemplateHaskell #-}

-- | The editor marks what does not render (WP5.65 of docs/PLAN.md), in a
-- browser, in the shell, over the demo's wiki: a Mermaid fence that does
-- not parse, marked on the fence's lines once the preview has drawn it and
-- no longer once it is fixed; a formula KaTeX cannot parse, marked again
-- when the text is undone back to what a hidden preview shows; a spoiler that
-- is not closed, which the parser finds without the preview; and the count
-- beside the buttons, which moves to the next problem at each click; and
-- the box a problem's mark opens, and the completion's list, readable in
-- the light and the dark scheme.
--
-- A TikZ picture's failure goes the same way as a diagram's, through the
-- islands' script's event; TeX runs in a worker and takes long, so it is
-- tested on the island alone ("Test.Browser.Islands"), not here.
module Test.Browser.Problems (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (decodeStrict, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startWith)
import Test.Browser.Text (editorHost, editorSelection, editorText, insertText, markdown, problemsMarked, setMarkdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Editor.Browser (showProblems)
import Wiki.App.Editor.Problems (ProblemRange (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-tooltips.js"]
     [ ("js_dark_scheme", "wiki_test_dark_scheme", Safe, [t|Bool -> IO Bool|])
     , ("js_hover", "wiki_test_hover", Safe, [t|JSText -> IO Bool|])
     , ("js_contrast", "wiki_test_contrast", Safe, [t|JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "marks a diagram Mermaid cannot parse on the fence's lines, and no longer once it is fixed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    let broken = "# Hello, world\n\nA diagram:\n\n```mermaid\ngraph LR\n  a -->\n```\n\nAfter."
    setMarkdown ui broken
    -- Mermaid's bundle is fetched the first time a diagram is drawn.
    _ <- eventuallyWithin 15000 (find ui ".editor-preview .wiki-mermaid .wiki-island-error")
    (start, end, message) <- eventuallyWithin 5000 $ do
      marked <- problemsMarked ui
      length marked `shouldBe` 1
      pure (fromMaybe (0, 0, "") (head marked))
    (start, end) `shouldBe` linesOf broken 5 8
    message `shouldSatisfy` (not . T.null)
    -- Underlined in the text, with a mark in the gutter.
    underlined <- T.concat <$> (findAll ui ".editor-cm .cm-lintRange-error" >>= traverse textContent)
    underlined `shouldSatisfy` T.isInfixOf "graph LR"
    _ <- find ui ".editor-cm .cm-gutter-lint .cm-lint-marker-error"
    find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")
    -- Fixed by typing inside the marked lines, which CodeMirror's mark
    -- keeps covering: the problem goes once the text is checked again, its
    -- island's source being another.
    insertText ui (snd (linesOf broken 7 7)) " b"
    eventuallyWithin 15000 $ problemsMarked ui `shouldReturn` []
    eventually $ length <$> findAll ui ".editor-problems" `shouldReturn` 0
    length <$> findAll ui ".editor-cm .cm-lintRange-error" `shouldReturn` 0

  -- WP5.108: a publication of the problems computes on the page's thread
  -- in slices, and the author may type meanwhile; its marks are of the
  -- text it read. Given to the editor after a keystroke, they are not
  -- taken, and the marks CodeMirror mapped through the typing stay.
  it "takes problems' marks only for the text it holds, keeping its own mapped through the typing for any other" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let broken = "# Hello, world\n\n[[!nothing]]\n\nAfter."
    setMarkdown ui broken
    marked <- eventuallyWithin 15000 $ do
      found <- problemsMarked ui
      length found `shouldBe` 1
      pure found
    -- Two characters typed before the marker: the mark moves with it.
    insertText ui (T.length "# Hello, world\n\n") "ab"
    let moved = [(a + 2, b + 2, message) | (a, b, message) <- marked]
    problemsMarked ui `shouldReturn` moved
    host <- editorHost ui
    let range = ProblemRange {from = 0, to = 3, kind = "marker", severity = "error", message = "Of the text before."}
    -- Ranges of the text before the keystroke: not taken.
    unsafeIOToPageM (showProblems host broken [range]) `shouldReturn` False
    problemsMarked ui `shouldReturn` moved
    -- Ranges of the text the editor holds: taken. (What is marked then
    -- is not compared: the check after the keystroke's pause marks the
    -- text again.)
    now <- markdown ui
    unsafeIOToPageM (showProblems host now [range]) `shouldReturn` True

  it "marks a formula KaTeX cannot parse on its line, with KaTeX's message, and the preview still shows it in red" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    let broken = "# Hello, world\n\nFirst line.\nHalf: $\\frac{1}$ here."
    setMarkdown ui broken
    _ <- find ui ".editor-preview .wiki-math-inline .katex-error"
    marked <- eventually $ do
      found <- problemsMarked ui
      length found `shouldBe` 1
      pure found
    [(start, end) | (start, end, _) <- marked] `shouldBe` [linesOf broken 4 4]
    [message | (_, _, message) <- marked] `shouldSatisfy` all (T.isPrefixOf "KaTeX parse error")
    insertText ui (fst (linesOf broken 4 4) + T.length "Half: $\\frac{1}") "{2}"
    eventually $ problemsMarked ui `shouldReturn` []

  it "marks a formula's failure again once the text is undone back to what the hidden preview still shows" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    let broken = "# Hello, world\n\nFirst line.\nHalf: $\\frac{1}$ here."
        formula = (linesOf broken 4 4, "KaTeX parse error")
        markedAs = map (\(start, end, message) -> ((start, end), T.take 17 message))
    setMarkdown ui broken
    _ <- find ui ".editor-preview .wiki-math-inline .katex-error"
    eventually $ markedAs <$> problemsMarked ui `shouldReturn` [formula]
    -- The preview hidden keeps the text it drew, the broken formula in it.
    find ui ".editor-side-by-side" >>= click
    find ui ".editor-side-by-side" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "false"
    -- An escaped dollar: the formula is text, and the check marks nothing.
    insertText ui (fst (linesOf broken 4 4) + T.length "Half: ") "\\"
    eventually $ problemsMarked ui `shouldReturn` []
    eventually $ length <$> findAll ui ".editor-problems" `shouldReturn` 0
    -- Undone, the text is the one the preview shows, and the formula's
    -- failure is marked again, though its island never reported it again.
    press "Control+z"
    eventually $ markdown ui `shouldReturn` broken
    eventually $ markedAs <$> problemsMarked ui `shouldReturn` [formula]
    -- Shown again, the preview has nothing new to draw, and the mark stays.
    sideBySide ui
    find ui ".editor-preview .wiki-math-inline .katex-error" >>= (`shouldHaveText` "\\frac{1}")
    markedAs <$> problemsMarked ui `shouldReturn` [formula]
    find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")

  it "marks a spoiler that is not closed, without the preview, until it is closed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let broken = "# Hello, world\n\n[[!spoiler]]{answer}(The answer)\nForty-two."
    setMarkdown ui broken
    eventually $ problemsMarked ui `shouldReturn` [(fst (linesOf broken 3 3), snd (linesOf broken 3 3), "Spoiler “answer” is not closed: add [[/spoiler]]{answer}")]
    find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")
    insertText ui (T.length broken) "\n[[/spoiler]]{answer}"
    eventually $ problemsMarked ui `shouldReturn` []

  it "counts the problems, and goes to the next one at each click on the count" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let text = "# Hello, world\n\n> [!]\n> Not a box.\n\nBetween.\n\n[[!nothing]]\n\nAfter."
    setMarkdown ui text
    eventually $ find ui ".editor-problems" >>= (`shouldHaveText` "2 problems")
    eventually $ length <$> problemsMarked ui `shouldReturn` 2
    find ui ".editor-problems" >>= click
    eventually $ editorSelection ui `shouldReturn` linesOf text 3 3
    find ui ".editor-problems" >>= click
    eventually $ editorSelection ui `shouldReturn` linesOf text 8 8
    -- After the last, the first again.
    find ui ".editor-problems" >>= click
    eventually $ editorSelection ui `shouldReturn` linesOf text 3 3

  it "draws the box of a warning and of an error, and the completion's list, in colours that can be read, in the light and the dark scheme" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    -- A marker only a presentation reads, in a document, is a warning; a
    -- spoiler not closed is an error.
    let text = "# Hello, world\n\n[[!pause]]\n\n[[!spoiler]]{answer}(The answer)\nForty-two."
    for_ [False, True] $ \dark -> do
      setMarkdown ui text
      eventually $ length <$> problemsMarked ui `shouldReturn` 2
      unsafeIOToPageM (js_dark_scheme dark) `shouldReturn` True
      -- The box each mark in the text opens when hovered.
      for_ ["warning", "error"] $ \severity -> do
        -- The mark, then one move over it: each move starts CodeMirror's
        -- wait for a resting mouse again.
        _ <- find ui (".editor-cm .cm-content .cm-lintRange-" <> severity)
        unsafeIOToPageM (js_hover (toJSText (".cm-content .cm-lintRange-" <> severity))) `shouldReturn` True
        _ <- find ui (".cm-tooltip-hover .cm-tooltip-lint .cm-diagnostic-" <> severity)
        readable (".cm-tooltip-hover .cm-tooltip-lint .cm-diagnostic-" <> severity <> " .cm-diagnosticText")
      -- The box a mark in the gutter opens, a tooltip of its own.
      unsafeIOToPageM (js_hover (toJSText (".cm-gutter-lint .cm-lint-marker-warning" :: Text))) `shouldReturn` True
      _ <- find ui ".cm-tooltip.cm-tooltip-lint .cm-diagnostic-warning"
      readable ".cm-tooltip.cm-tooltip-lint .cm-diagnostic-warning .cm-diagnosticText"
      -- The completion's list: the entry Enter would choose, and another.
      markdown ui >>= \now -> insertText ui (T.length now) "\n\n"
      editorText ui >>= (`typeText` ":ta")
      _ <- find ui ".cm-tooltip.cm-tooltip-autocomplete li[aria-selected] .cm-completionLabel"
      readable ".cm-tooltip-autocomplete li[aria-selected] .cm-completionLabel"
      readable ".cm-tooltip-autocomplete li:not([aria-selected]) .cm-completionLabel"
      press "Escape"
      eventually $ length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

-- | That the text of the first element the selector finds in the editor
-- has a contrast ratio of at least 4.5 against what is drawn behind it
-- (WCAG's AA for text), as test/jsbits/test-tooltips.js computes it.
readable :: Text -> PageM s ()
readable selector = eventually $ do
  json <- unsafeIOToPageM (fromJSText <$> js_contrast (toJSText selector))
  case decodeStrict (encodeUtf8 json) >>= parseMaybe (withObject "Contrast" (.: "ratio")) of
    Just (ratio :: Double) | ratio >= 4.5 -> pass
    _ -> expectationFailure (toS (selector <> " is not readable: " <> json))

-- | Turn the side by side preview on, so that the preview, and its
-- islands, follow the typing.
sideBySide :: Mounted s q o m -> PageM s ()
sideBySide ui = do
  find ui ".editor-side-by-side" >>= click
  find ui ".editor-side-by-side" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "true"
  find ui ".editor-preview" >>= shouldBeVisible

-- | Where lines of a text run, from the start of the first to the end of
-- the last, in UTF-16 units (the texts here are ASCII but for the title).
linesOf :: Text -> Int -> Int -> (Int, Int)
linesOf text opening closing =
  let ls = T.splitOn "\n" text
      startOf n = sum (map ((+ 1) . T.length) (take (n - 1) ls))
   in (startOf opening, startOf closing + maybe 0 T.length (head (drop (closing - 1) ls)))
