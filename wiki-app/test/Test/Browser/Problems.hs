-- | The editor marks what does not render (WP5.65 of docs/PLAN.md), in a
-- browser, in the shell, over the demo's wiki: a Mermaid fence that does
-- not parse, marked on the fence's lines once the preview has drawn it and
-- no longer once it is fixed; a formula KaTeX cannot parse; a spoiler that
-- is not closed, which the parser finds without the preview; and the count
-- beside the buttons, which moves to the next problem at each click.
--
-- A TikZ picture's failure goes the same way as a diagram's, through the
-- islands' script's event; TeX runs in a worker and takes long, so it is
-- tested on the island alone ("Test.Browser.Islands"), not here.
module Test.Browser.Problems (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startWith)
import Test.Browser.Text (editorSelection, problemsMarked, setMarkdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

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
    setMarkdown ui "# Hello, world\n\nA diagram:\n\n```mermaid\ngraph LR\n  a --> b\n```\n\nAfter."
    eventuallyWithin 15000 $ problemsMarked ui `shouldReturn` []
    length <$> findAll ui ".editor-problems" `shouldReturn` 0
    length <$> findAll ui ".editor-cm .cm-lintRange-error" `shouldReturn` 0

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
    setMarkdown ui "# Hello, world\n\nFirst line.\nHalf: $\\frac{1}{2}$ here."
    eventually $ problemsMarked ui `shouldReturn` []

  it "marks a spoiler that is not closed, without the preview, until it is closed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let broken = "# Hello, world\n\n[[spoiler]]{answer}(The answer)\nForty-two."
    setMarkdown ui broken
    eventually $ problemsMarked ui `shouldReturn` [(fst (linesOf broken 3 3), snd (linesOf broken 3 3), "Spoiler “answer” is not closed: add [[/spoiler]]{answer}")]
    find ui ".editor-problems" >>= (`shouldHaveText` "1 problem")
    setMarkdown ui (broken <> "\n[[/spoiler]]{answer}")
    eventually $ problemsMarked ui `shouldReturn` []

  it "counts the problems, and goes to the next one at each click on the count" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let text = "# Hello, world\n\n> [!]\n> Not a box.\n\nBetween.\n\n[[/spoiler]]{nothing}\n\nAfter."
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
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

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
