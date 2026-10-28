-- | A deck rendered: each slide's title, body and notes as HTML of their
-- own, rendered as one document.
module Test.Markdown.Slides (spec) where

import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Markdown
import Wiki.Core.Math (Macros (..))
import Wiki.Core.Slides

rendered :: Options page w i -> Text -> [RenderedSlide w i]
rendered opts source = either (panic . show) (renderDeck opts . deckOf) (parseMarkdown source)

spec :: Spec
spec = describe "Slides.renderDeck" $ do
  it "renders each slide's title as its heading, its body and its notes apart" $ do
    let slides = rendered defaultOptions "## One\n\nFirst.\n\n::: notes\nSay it.\n:::\n\n---\n\n# Two\n\nSecond."
    length slides `shouldBe` 2
    for slides (\s -> (,,) <$> renderHtml s.title <*> renderHtml s.body <*> renderHtml s.notes)
      `shouldReturn` [ ("<h2 id=\"one\">One<a aria-label=\"Link to this section\" class=\"heading-anchor\" href=\"#one\"></a></h2>", "<p>First.</p>", "<p>Say it.</p>")
                     , ("<h1 id=\"two\">Two<a aria-label=\"Link to this section\" class=\"heading-anchor\" href=\"#two\"></a></h1>", "<p>Second.</p>", "")
                     ]

  it "gives the islands of every slide keys unique in the deck" $ do
    let keyed k = HH.i_ [HH.text (T.strip k.source <> show k.occurrence)]
        opts = defaultOptions {codeBlock = \k _ _ -> keyed k, mathInline = \k _ _ -> keyed k}
        slides = rendered opts "$x$\n\n```\ncode\n```\n\n---\n\n$x$ and $x$\n\n::: notes\n```\ncode\n```\n:::"
    for slides (\s -> (,) <$> renderHtml s.body <*> renderHtml s.notes)
      `shouldReturn` [ ("<p><i>x0</i></p><i>code0</i>", "")
                     , ("<p><i>x1</i> and <i>x2</i></p>", "<i>code1</i>")
                     ]

  it "sets a formula with the macros defined on the slides before it" $ do
    let opts = defaultOptions {mathInline = \_ (Macros ms) tex -> HH.text (tex <> ":" <> show (length ms))}
        slides = rendered opts "$\\newcommand{\\R}{\\mathbb{R}}$\n\n---\n\n$\\R$"
    traverse (\s -> renderHtml s.body) slides
      `shouldReturn` ["<p>\\newcommand{\\R}{\\mathbb{R}}:0</p>", "<p>\\R:1</p>"]

  it "numbers footnotes across the deck and shows each on its slide" $ do
    let slides = rendered defaultOptions "A[^a].\n\n---\n\nB[^b].\n\n[^a]: Note a.\n\n[^b]: Note b.\n"
    bodies <- traverse (\s -> renderHtml s.body) slides
    bodies
      `shouldBe` [ "<p>A<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>.</p>"
                     <> "<section class=\"footnotes\"><ol><li id=\"fn-1\"><p>Note a. <a class=\"footnote-back\" href=\"#fnref-1\">↩</a></p></li></ol></section>"
                 , "<p>B<sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\">2</a></sup>.</p>"
                     <> "<section class=\"footnotes\"><ol start=\"2\"><li id=\"fn-2\"><p>Note b. <a class=\"footnote-back\" href=\"#fnref-2\">↩</a></p></li></ol></section>"
                 ]

  it "renders a slide's steps in place, the later ones in the class that hides them" $ do
    let deck = either (panic . show) deckOf (parseMarkdown "One\n\n. . .\n\n::: incremental\n- a\n- b\n:::\n")
        shown k = deck {slides = map (showingStep k) deck.slides}
    traverse (\s -> renderHtml s.body) (renderDeck defaultOptions (shown 1))
      `shouldReturn` [ "<p>One</p><div class=\"slide-step slide-step-later\"><div class=\"incremental\"><ul>"
                         <> "<li>a</li><li>b<div class=\"slide-step-item slide-step-later\"></div></li></ul></div></div>"
                     ]
    traverse (\s -> renderHtml s.body) (renderDeck defaultOptions (shown 3))
      `shouldReturn` [ "<p>One</p><div class=\"slide-step\"><div class=\"incremental\"><ul>"
                         <> "<li>a</li><li>b<div class=\"slide-step-item\"></div></li></ul></div></div>"
                     ]
