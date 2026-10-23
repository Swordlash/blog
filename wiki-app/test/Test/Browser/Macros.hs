-- | Math macros in a browser, set by KaTeX: the built-in ones, a space's
-- inherited by its subspaces and overridden in them, a page's own used in a
-- later formula (in a page and in the editor's preview), mhchem's @\\ce@,
-- and the space's settings where a block is edited, with KaTeX's error for
-- one it cannot read.
--
-- A macro KaTeX does not know it shows in place, as itself in its error
-- colour, so a formula that uses one and shows none was set with it; what
-- it was set with shows in KaTeX's MathML copy (@mathvariant@s).
module Test.Browser.Macros (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Backend.Mem.State (MemState (..), insertPage, setMathMacros)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (Island (..), Macros (..), MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (Route (..))
import Wiki.Core.Space qualified as Core

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  describe "a formula" $ do
    it "is set with the built-in macros" $ runPage $ do
      ui <- mount m (island (MathInline mempty "\\abs{x} + \\norm{v} + \\Q + \\E[X]")) ()
      set <- find ui ".wiki-math .katex"
      withoutError set
      outerHTML set >>= (`shouldSatisfy` T.isInfixOf "<mi mathvariant=\"double-struck\">Q</mi>")

    it "is set with the blocks it is handed, a nearer one's \\newcommand replacing a farther one's" $ runPage $ do
      let blocks = Macros ["\\newcommand{\\vect}[1]{\\mathbf{#1}}", "\\newcommand{\\vect}[1]{\\mathsf{#1}}\\newcommand{\\abs}[1]{|#1|}"]
      ui <- mount m (island (MathInline blocks "\\vect{v} + \\abs{x}")) ()
      set <- find ui ".wiki-math .katex"
      withoutError set
      html <- outerHTML set
      html `shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">v</mi>"
      html `shouldSatisfy` (not . T.isInfixOf "mathvariant=\"bold\"")

    it "is drawn, with what a block KaTeX cannot read defined before its error" $ runPage $ do
      let blocks = Macros ["\\newcommand{\\a}{a}\\newcommand{\\b}{\\frac{"]
      ui <- mount m (island (MathInline blocks "\\a")) ()
      set <- find ui ".wiki-math .katex"
      withoutError set

    it "has the definitions of a display formula before it that is tagged, without its tag" $ runPage $ do
      ui <- mount m (island (MathDisplay (Macros ["x \\tag{1} \\newcommand{\\after}{\\mathsf{A}}"]) "\\after")) ()
      set <- find ui ".wiki-math-display .katex-display"
      withoutError set
      countIn set ".tag" `shouldReturn` 0
      outerHTML set >>= (`shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">A</mi>")

    it "keeps its own definitions to itself" $ runPage $ do
      ui <- mount m (island (MathInline mempty "\\newcommand{\\own}{o}\\own")) ()
      _ <- find ui ".wiki-math .katex"
      other <- mount m (island (MathInline mempty "\\own")) ()
      find other ".wiki-math .katex" >>= hasError

    it "writes chemistry with \\ce, and quantities with \\pu" $ runPage $ do
      ui <- mount m (island (MathDisplay mempty "\\ce{2 H2 + O2 -> 2 H2O} \\quad \\pu{123 kJ/mol}")) ()
      set <- find ui ".wiki-math-display .katex-display"
      withoutError set
      textContent set >>= (`shouldSatisfy` T.isInfixOf "H2O")

  describe "a page" $ do
    it "sets every formula of the demo's Mathematics page: built-in, space, page macros and \\ce" $ runPage $ do
      ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide", "mathematics"]))
      find ui ".page-body h1" >>= (`shouldHaveText` "Mathematics")
      formulas <- eventually $ do
        set <- findAll ui ".page-body .wiki-math .katex"
        length set `shouldSatisfy` (>= 20)
        pure set
      traverse_ withoutError formulas
      -- Docs' \eps, over the built-in \varepsilon.
      html <- T.concat <$> traverse outerHTML formulas
      html `shouldSatisfy` T.isInfixOf "<mi>ϵ</mi>"

    it "holds a formula's definition in the formulas after it, and not before" $ runPage $ do
      let body = "Before: $\\later$.\n\n$$\\newcommand{\\later}{\\mathsf{L}}\\later$$\n\nAfter: $\\later$, and $\\newcommand{\\abs}[1]{\\mathsf{A}}\\abs{x}$, then $\\abs{y}$."
      ui <- startChanged m (withPage "Projects" "Order" body) (Just "user-admin") (Page (slugs ["team", "projects"]) (slugs ["order"]))
      formulas <- eventually $ do
        set <- findAll ui ".page-body .wiki-math"
        length set `shouldBe` 5
        pure set
      eventually $ for_ formulas (\f -> countIn f ".katex" `shouldReturn` 1)
      errors <- traverse erroneous formulas
      errors `shouldBe` [True, False, False, False, False]
      last' <- outerHTML (fromMaybe (panic "no formula") (lastMay formulas))
      last' `shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">A</mi>"

    it "of a subspace has its space's macros and its parent's, its own winning" $ runPage $ do
      let change =
            withPage "Projects" "Vectors" "$\\vect{v}^\\T$"
              . withMacros "Team" "\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\newcommand{\\T}{\\top}"
              . withMacros "Projects" "\\newcommand{\\T}{\\mathsf{T}}"
      ui <- startChanged m change (Just "user-admin") (Page (slugs ["team", "projects"]) (slugs ["vectors"]))
      set <- find ui ".page-body .wiki-math .katex"
      withoutError set
      html <- outerHTML set
      html `shouldSatisfy` T.isInfixOf "<mi mathvariant=\"bold\">v</mi>"
      html `shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">T</mi>"
      html `shouldSatisfy` (not . T.isInfixOf "⊤")

    it "sets the editor's preview as the page will be: its space's macros, and a definition in a later formula once typed" $ runPage $ do
      ui <- start m (Just "user-admin") (NewPage (slugs ["docs"]) Nothing)
      find ui ".new-page-title" >>= (`typeText` "Macros")
      find ui ".new-page-view button.primary" >>= click
      find ui ".editor-side-by-side input" >>= click
      text <- find ui ".editor-text"
      typeText text "First $\\vect{v} + \\twice{x}$"
      early <- find ui ".editor-preview .wiki-math .katex"
      hasError early
      -- \vect is Docs'; \twice is defined later, so not yet here.
      outerHTML early >>= (`shouldSatisfy` T.isInfixOf "\\twice")
      typeText text " then $\\newcommand{\\twice}[1]{2#1}\\twice{y}$ and $\\twice{z} \\vect{w}$"
      formulas <- eventually $ do
        set <- findAll ui ".editor-preview .wiki-math .katex"
        length set `shouldBe` 3
        pure set
      errors <- traverse erroneous formulas
      errors `shouldBe` [True, False, False]
      outerHTML (fromMaybe (panic "no formula") (lastMay formulas)) >>= (`shouldSatisfy` T.isInfixOf "<mi mathvariant=\"bold-italic\">w</mi>")

  describe "a space's settings" $ do
    it "show KaTeX's error for a block it cannot read, and do not save it" $ runPage $ do
      ui <- start m (Just "user-admin") (Space (slugs ["blog"]))
      clickButton ui ".space-view .actions button" "Math macros"
      source <- find ui ".macros-form textarea.macros-source"
      typeText source "\\newcommand{\\half}{\\frac{1}{2}"
      find ui ".macros-form .macros-error" >>= (`shouldHaveText'` "KaTeX parse error")
      find ui ".macros-form button.primary" >>= click
      _ <- find ui ".macros-form .macros-error"
      count ui ".space-view .space-macros" `shouldReturn` 0
      typeText source "}"
      eventually (count ui ".macros-form .macros-error" `shouldReturn` 0)

    it "try a block on a formula, and save it for the space's pages" $ runPage $ do
      ui <- startChanged m (withPage "Blog" "Halves" "$\\half$") (Just "user-admin") (Space (slugs ["blog"]))
      clickButton ui ".space-view .actions button" "Math macros"
      find ui ".macros-form textarea.macros-source" >>= (`typeText` "\\newcommand{\\half}{\\mathsf{H}}")
      find ui ".macros-form .macros-sample input" >>= (`typeText` "\\half + \\abs{x}")
      tried <- find ui ".macros-preview .wiki-math .katex"
      withoutError tried
      outerHTML tried >>= (`shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">H</mi>")
      find ui ".macros-form button.primary" >>= click
      find ui ".space-view .space-macros pre" >>= (`shouldHaveText` "\\newcommand{\\half}{\\mathsf{H}}")
      find ui ".space-view .page-tree a" >>= click
      set <- find ui ".page-body .wiki-math .katex"
      withoutError set
      outerHTML set >>= (`shouldSatisfy` T.isInfixOf "<mi mathvariant=\"sans-serif\">H</mi>")
  where
    -- KaTeX shows a formula it cannot parse in a .katex-error, and a
    -- control sequence it does not know as itself, in its error colour.
    erroneous element = do
      errors <- countIn element ".katex-error"
      html <- outerHTML element
      pure (errors > 0 || "#cc0000" `T.isInfixOf` html)
    withoutError element = erroneous element `shouldReturn` False
    hasError element = erroneous element `shouldReturn` True
    count ui selector = length <$> findAll ui selector
    countIn element selector = length <$> findAllIn element selector
    shouldHaveText' element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | The demo with a page added to a space, by the space's name.
withPage :: Text -> Text -> Text -> MemState -> MemState
withPage spaceName title body st = case spaceNamed spaceName st of
  Just s -> fst (insertPage s.id Nothing title body demoNow st)
  Nothing -> panic ("the demo has no space " <> spaceName)

-- | The demo with a space's math macros set, by the space's name.
withMacros :: Text -> Text -> MemState -> MemState
withMacros spaceName macros st = case spaceNamed spaceName st of
  Just s -> setMathMacros s.id macros st
  Nothing -> panic ("the demo has no space " <> spaceName)

spaceNamed :: Text -> MemState -> Maybe Core.Space
spaceNamed name st = head (filter (\s -> s.name == name) (Map.elems st.spaces))

-- | One island, as a page renders it.
island :: forall m. (MonadIslands m, MonadUUID m) => Island -> H.Component (Const Void) () Void m
island shown =
  H.mkComponent
    H.ComponentSpec
      { initialState = pure
      , render
      , eval = H.mkEval H.defaultEval
      }
  where
    render :: () -> H.ComponentHTML Void ("island" .== H.Slot (Const Void) Void ()) m
    render () = HH.div_ [HH.slot_ "island" () Islands.component shown]
