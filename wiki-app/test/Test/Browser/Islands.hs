{-# LANGUAGE TemplateHaskell #-}

-- | The islands in a browser, drawn by the page's islands.js: each fills its
-- element with what its library makes, and draws again when its source
-- changes. The island is the one that tells its parent of its library's
-- failures ('Islands.reporting'): a formula, a diagram and a picture that
-- fail raise 'Islands.Failed' with the library's message, and the same
-- island drawn again without one raises 'Islands.Cleared'.
module Test.Browser.Islands (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Protolude hiding (find)
import Test.Hspec.Halogen
import Wiki.App.Islands (Island (..), MonadIslands)
import Wiki.App.Islands qualified as Islands

$( browserJS
     ["jsbits/test-resources.js"]
     [ ("js_fetched", "wiki_test_fetched", Safe, [t|JSText -> IO Int|])
     , ("js_font_loaded", "wiki_test_font_loaded", Safe, [t|JSText -> IO Bool|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  -- First, while nothing on the test page has drawn a TikZ picture: the
  -- page holds one document for the whole suite, and what it has fetched
  -- stays fetched.
  describe "a page without a TikZ picture" $
    it "never fetches TikZJax, whatever other islands it draws" $
      runPage $ do
        ui <- mount m harness (MathInline mempty "x^2")
        _ <- find ui "span.wiki-math-inline .katex"
        changeTo ui (Mermaid "graph LR\n  a --> b")
        _ <- waitForDiagram ui
        changeTo ui (CodeBlock (Just "haskell") Nothing False "main = pure ()")
        _ <- find ui "pre.wiki-code code.hljs"
        fetched "tikz" `shouldReturn` 0

  describe "Tikz" $ do
    it "is drawn as an SVG, with its labels set in TeX's fonts" $ runPage $ do
      ui <- mount m harness (Tikz "\\draw (0,0) -- (2,1) node[right] {label};")
      picture <- waitForPicture ui
      label <- findIn picture "text"
      textContent label >>= (`shouldSatisfy` (not . T.null))
      getAttribute label "font-family" `shouldReturn` Just "cmr10"
      eventuallyWithin 10000 $ fontLoaded "10px cmr10" `shouldReturn` True
      -- Fetched now, from the page's own origin. (TeX's own files are
      -- fetched by its worker, whose fetches the page's list does not show.)
      fetched "islands/tikz.js" `shouldReturn` 1
      fetched "tikzjax/fonts.css" `shouldReturn` 1

    it "draws black in the page's colour, and other colours as they are" $ runPage $ do
      ui <- mount m harness (Tikz "\\draw (0,0) -- (1,0);\n\\draw[red] (0,0) -- (0,1);")
      picture <- waitForPicture ui
      outerHTML picture >>= (`shouldSatisfy` T.isInfixOf "stroke=\"currentColor\"")
      outerHTML picture >>= (`shouldSatisfy` T.isInfixOf "stroke=\"#f00\"")
      outerHTML picture >>= (`shouldNotSatisfy'` T.isInfixOf "stroke=\"#000\"")

    it "draws a whole tikzpicture, and a tikz-cd diagram" $ runPage $ do
      ui <- mount m harness (Tikz "\\begin{tikzpicture}[scale=2]\n\\draw (0,0) circle (1);\n\\end{tikzpicture}")
      _ <- waitForPicture ui
      changeTo ui (Tikz "\\begin{tikzcd}\nA \\arrow[r, \"f\"] & B\n\\end{tikzcd}")
      eventuallyWithin 30000 $ do
        picture <- find ui "div.wiki-tikz > svg"
        texts <- traverse textContent =<< findAllIn picture "text"
        length texts `shouldSatisfy` (>= 3)
      count ui "div.wiki-tikz svg" `shouldReturn` 1

    it "shows TeX's error under the source of a picture TeX cannot draw" $ runPage $ do
      let source = "\\draw (0,0) -- (1,1);\n\\undefinedcommand"
      ui <- mount m harness (Tikz source)
      message <- eventuallyWithin 30000 (find ui "div.wiki-tikz > .wiki-island-error")
      message `shouldHaveText'` "Undefined control sequence"
      -- TeX's line, counted as the author's.
      message `shouldHaveText'` "l.2 \\undefinedcommand"
      find ui "div.wiki-tikz > pre.wiki-tikz-source" >>= (`shouldHaveText` source)
      count ui "div.wiki-tikz svg" `shouldReturn` 0
      -- The editor is told, with TeX's message.
      eventually $ failures ui >>= (`shouldSatisfy` any (T.isInfixOf "Undefined control sequence"))
      -- And the worker goes on to the next picture.
      changeTo ui (Tikz "\\draw (0,0) -- (1,1);")
      _ <- waitForPicture ui
      count ui "div.wiki-tikz .wiki-island-error" `shouldReturn` 0
      eventually $ lastOutput ui `shouldReturn` Just Islands.Cleared

  describe "MathInline" $ do
    it "is set by KaTeX, in the line" $ runPage $ do
      ui <- mount m harness (MathInline mempty "x^2")
      island <- find ui "span.wiki-math-inline"
      _ <- findIn island ".katex .katex-html"
      countIn island ".katex-display" `shouldReturn` 0
      -- KaTeX's MathML copy carries the source, for screen readers.
      findIn island "annotation" >>= (`shouldHaveText` "x^2")
      -- A formula that parses says nothing to its parent.
      outputs ui `shouldReturn` []

    it "is set again when its TeX changes" $ runPage $ do
      ui <- mount m harness (MathInline mempty "x^2")
      island <- find ui "span.wiki-math-inline"
      findIn island "annotation" >>= (`shouldHaveText` "x^2")
      changeTo ui (MathInline mempty "y_1")
      findIn island "annotation" >>= (`shouldHaveText` "y_1")
      find ui "span.wiki-math-inline" >>= (`shouldBeSameElement` island)

    it "shows what KaTeX cannot parse as an error in its place" $ runPage $ do
      ui <- mount m harness (MathInline mempty "\\frac{")
      find ui "span.wiki-math-inline .katex-error" >>= (`shouldHaveText` "\\frac{")
      -- KaTeX's message goes to the parent; the formula fixed clears it.
      failures ui >>= (`shouldSatisfy` \case [message] -> "KaTeX parse error" `T.isPrefixOf` message; _ -> False)
      changeTo ui (MathInline mempty "\\frac{1}{2}")
      _ <- find ui "span.wiki-math-inline .katex .mfrac"
      lastOutput ui `shouldReturn` Just Islands.Cleared
      -- Drawn again without a problem, it says nothing more.
      changeTo ui (MathInline mempty "\\frac{1}{3}")
      _ <- find ui "span.wiki-math-inline annotation"
      length <$> outputs ui `shouldReturn` 2

  describe "MathDisplay" $
    it "is set by KaTeX, on its own" $
      runPage $ do
        ui <- mount m harness (MathDisplay mempty "\\int_0^1 x \\, dx")
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
      -- Mermaid's message goes to the parent; the diagram fixed clears it.
      eventually $ failures ui >>= (`shouldSatisfy` ((== 1) . length))
      changeTo ui (Mermaid "graph LR\n  first --> second")
      _ <- waitForDiagram ui
      eventually $ lastOutput ui `shouldReturn` Just Islands.Cleared

  describe "CodeBlock" $ do
    it "is highlighted by highlight.js" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "haskell") Nothing False "main :: IO ()\nmain = pure ()")
      code <- find ui "pre.wiki-code > code.hljs.language-haskell"
      _ <- findIn code "span.hljs-type"
      code `shouldHaveText` "main :: IO ()\nmain = pure ()"

    it "is highlighted again when its code changes" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "haskell") Nothing False "main :: IO ()")
      _ <- find ui "pre.wiki-code code.language-haskell"
      changeTo ui (CodeBlock (Just "javascript") Nothing False "const x = 1;")
      code <- find ui "pre.wiki-code code.language-javascript"
      _ <- findIn code "span.hljs-keyword"
      code `shouldHaveText` "const x = 1;"
      count ui "pre.wiki-code code" `shouldReturn` 1

    it "keeps a numbered listing's gutter beside the code once highlighted, and gains and loses it with one code" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "haskell") Nothing False "a = 1\nb = 2")
      _ <- find ui "pre.wiki-code > code.hljs.language-haskell"
      count ui "pre.wiki-code > .code-lines" `shouldReturn` 0
      changeTo ui (CodeBlock (Just "haskell") Nothing True "a = 1\nb = 2\nc = 3")
      code <- find ui "pre.wiki-code.numbered > .code-lines + code.hljs.language-haskell"
      code `shouldHaveText` "a = 1\nb = 2\nc = 3"
      count ui "pre.wiki-code.numbered > .code-lines > span" `shouldReturn` 3
      count ui "pre.wiki-code code" `shouldReturn` 1
      changeTo ui (CodeBlock (Just "haskell") Nothing False "a = 1")
      eventually $ count ui "pre.wiki-code > .code-lines" `shouldReturn` 0
      find ui "pre.wiki-code:not(.numbered) > code.hljs.language-haskell" >>= (`shouldHaveText` "a = 1")
      count ui "pre.wiki-code code" `shouldReturn` 1

    it "highlights the languages added to highlight.js's common set" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "fortran") Nothing False "program hello\n  print *, 'Hello'\nend program hello")
      _ <- find ui "pre.wiki-code > code.hljs.language-fortran span.hljs-keyword"
      changeTo ui (CodeBlock (Just "matlab") Nothing False "function y = f(x)\n  y = x;\nend")
      _ <- find ui "pre.wiki-code > code.hljs.language-matlab span.hljs-keyword"
      pure ()

    it "knows a language by the names fences give it" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "c++") Nothing False "int main() { return 0; }")
      _ <- find ui "pre.wiki-code > code.hljs.language-c\\+\\+ span.hljs-type"
      changeTo ui (CodeBlock (Just "asm") Nothing False "mov eax, 1")
      _ <- find ui "pre.wiki-code > code.hljs.language-asm span.hljs-keyword"
      pure ()

    it "shows code in a language it does not know as plain text" $ runPage $ do
      ui <- mount m harness (CodeBlock (Just "no-such-language") Nothing False "a <b> c")
      code <- find ui "pre.wiki-code > code.hljs"
      code `shouldHaveText` "a <b> c"
      countIn code "span" `shouldReturn` 0
      classes code `shouldReturn` ["hljs"]

  describe "an island whose kind changes" $
    it "is drawn as the new kind" $
      runPage $ do
        ui <- mount m harness (CodeBlock Nothing Nothing False "x^2")
        _ <- find ui "pre.wiki-code code"
        changeTo ui (MathInline mempty "x^2")
        _ <- find ui "span.wiki-math-inline .katex"
        count ui "pre" `shouldReturn` 0
  where
    changeTo ui island = void (query ui (H.mkTell (SetIsland island)))
    failures ui = (\os -> [message | Islands.Failed message <- os]) <$> outputs ui
    lastOutput ui = lastMay <$> outputs ui
    count ui selector = length <$> findAll ui selector
    countIn element selector = length <$> findAllIn element selector
    -- Mermaid's bundle is fetched the first time a diagram is drawn, which
    -- can take longer than find's two seconds.
    waitForDiagram ui = eventuallyWithin 15000 (find ui "div.wiki-mermaid > svg")
    -- TikZJax's TeX, the first time, is 6 MB to fetch and inflate, and TeX
    -- then runs.
    waitForPicture ui = eventuallyWithin 30000 (find ui "div.wiki-tikz > svg")
    fetched part = unsafeIOToPageM (js_fetched (toJSText part))
    fontLoaded font = unsafeIOToPageM (js_font_loaded (toJSText font))
    shouldNotSatisfy' value p = value `shouldSatisfy` (not . p)
    shouldHaveText' element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | A parent for one island, whose input a test changes with 'SetIsland', as
-- a page re-rendered with a new source would.
data Query a = SetIsland Island a

type Slots = ("island" .== H.Slot (Const Void) Islands.Output ())

-- | Raises what its island raises.
harness :: forall m. (MonadIslands m, MonadUUID m) => H.Component Query Island Islands.Output m
harness =
  H.mkComponent
    H.ComponentSpec
      { initialState = pure
      , render
      , eval = H.mkEval H.defaultEval {H.handleQuery = handleQuery, H.handleAction = H.raise}
      }
  where
    render :: Island -> H.ComponentHTML Islands.Output Slots m
    render island = HH.div_ [HH.slot "island" () Islands.reporting island identity]

    handleQuery :: Query a -> H.HalogenM Island Islands.Output Slots Islands.Output m (Maybe a)
    handleQuery (SetIsland island next) = put island $> Just next
