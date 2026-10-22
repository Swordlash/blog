-- | The islands in a browser, drawn by the page's islands.js: each fills its
-- element with what its library makes, and draws again when its source
-- changes.
module Test.Browser.Islands (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Protolude hiding (find)
import Test.Hspec.Halogen
import Wiki.App.Islands (Island (..), MonadIslands)
import Wiki.App.Islands qualified as Islands

spec :: forall m -> (MonadBrowserTest m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  describe "MathInline" $ do
    it "is set by KaTeX, in the line" $ runPage $ do
      ui <- mount m harness (MathInline "x^2")
      island <- find ui "span.wiki-math-inline"
      _ <- findIn island ".katex .katex-html"
      countIn island ".katex-display" `shouldReturn` 0
      -- KaTeX's MathML copy carries the source, for screen readers.
      findIn island "annotation" >>= (`shouldHaveText` "x^2")

    it "is set again when its TeX changes" $ runPage $ do
      ui <- mount m harness (MathInline "x^2")
      island <- find ui "span.wiki-math-inline"
      findIn island "annotation" >>= (`shouldHaveText` "x^2")
      changeTo ui (MathInline "y_1")
      findIn island "annotation" >>= (`shouldHaveText` "y_1")
      find ui "span.wiki-math-inline" >>= (`shouldBeSameElement` island)

    it "shows what KaTeX cannot parse as an error in its place" $ runPage $ do
      ui <- mount m harness (MathInline "\\frac{")
      find ui "span.wiki-math-inline .katex-error" >>= (`shouldHaveText` "\\frac{")

  describe "MathDisplay" $
    it "is set by KaTeX, on its own" $
      runPage $ do
        ui <- mount m harness (MathDisplay "\\int_0^1 x \\, dx")
        _ <- find ui "div.wiki-math-display .katex-display .katex-html"
        pure ()

  describe "Mermaid" $ do
    it "is drawn as an SVG" $ runPage $ do
      ui <- mount m harness (Mermaid "graph LR\n  first --> second")
      diagram <- waitForDiagram ui
      outerHTML diagram >>= (`shouldSatisfy` T.isInfixOf "first")

    it "is drawn again when its source changes" $ runPage $ do
      ui <- mount m harness (Mermaid "graph LR\n  first --> second")
      waitForDiagram ui >>= outerHTML >>= (`shouldSatisfy` T.isInfixOf "second")
      changeTo ui (Mermaid "graph LR\n  first --> third")
      eventuallyWithin 15000 $ do
        diagram <- waitForDiagram ui
        outerHTML diagram >>= (`shouldSatisfy` T.isInfixOf "third")
      count ui "div.wiki-mermaid svg" `shouldReturn` 1

    it "shows a source Mermaid cannot parse as an error in its place" $ runPage $ do
      ui <- mount m harness (Mermaid "graph LR\n  first -->")
      _ <- eventuallyWithin 15000 (find ui "div.wiki-mermaid .wiki-island-error")
      count ui "div.wiki-mermaid svg" `shouldReturn` 0

  describe "CodeBlock" $ do
    it "is highlighted by highlight.js" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "haskell") "main :: IO ()\nmain = pure ()")
      code <- find ui "pre.wiki-code > code.hljs.language-haskell"
      _ <- findIn code "span.hljs-type"
      code `shouldHaveText` "main :: IO ()\nmain = pure ()"

    it "is highlighted again when its code changes" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "haskell") "main :: IO ()")
      _ <- find ui "pre.wiki-code code.language-haskell"
      changeTo ui (CodeBlock (Just "javascript") "const x = 1;")
      code <- find ui "pre.wiki-code code.language-javascript"
      _ <- findIn code "span.hljs-keyword"
      code `shouldHaveText` "const x = 1;"
      count ui "pre.wiki-code code" `shouldReturn` 1

    it "shows code in a language it does not know as plain text" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "no-such-language") "a <b> c")
      code <- find ui "pre.wiki-code > code.hljs"
      code `shouldHaveText` "a <b> c"
      countIn code "span" `shouldReturn` 0
      classes code `shouldReturn` ["hljs"]

  describe "an island whose kind changes" $
    it "is drawn as the new kind" $
      runPage $ do
        ui <- mount m harness (CodeBlock Nothing "x^2")
        _ <- find ui "pre.wiki-code code"
        changeTo ui (MathInline "x^2")
        _ <- find ui "span.wiki-math-inline .katex"
        count ui "pre" `shouldReturn` 0
  where
    changeTo ui island = void (query ui (H.mkTell (SetIsland island)))
    count ui selector = length <$> findAll ui selector
    countIn element selector = length <$> findAllIn element selector
    -- Mermaid's bundle is fetched the first time a diagram is drawn, which
    -- can take longer than find's two seconds.
    waitForDiagram ui = eventuallyWithin 15000 (find ui "div.wiki-mermaid > svg")

-- | A parent for one island, whose input a test changes with 'SetIsland', as
-- a page re-rendered with a new source would.
data Query a = SetIsland Island a

type Slots = ("island" .== H.Slot (Const Void) Void ())

harness :: forall m. (MonadIslands m, MonadUUID m) => H.Component Query Island Void m
harness =
  H.mkComponent
    H.ComponentSpec
      { initialState = pure
      , render
      , eval = H.mkEval H.defaultEval {H.handleQuery = handleQuery}
      }
  where
    render :: Island -> H.ComponentHTML Void Slots m
    render island = HH.div_ [HH.slot_ "island" () Islands.component island]

    handleQuery :: Query a -> H.HalogenM Island Void Slots Void m (Maybe a)
    handleQuery (SetIsland island next) = put island $> Just next
