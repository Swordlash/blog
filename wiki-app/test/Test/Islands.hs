-- | The islands as "Halogen.Static" renders them: with no JavaScript to draw
-- them, each element holds its source as text, which is what a prerendered
-- page shows until the program has loaded. In a browser,
-- @Test.Browser.Islands@ checks the drawing.
module Test.Islands (spec) where

import Halogen.Static (renderToHtml)
import Protolude
import Test.Hspec
import Wiki.App.Islands (Island (..))
import Wiki.App.Islands qualified as Islands

spec :: Spec
spec = describe "Wiki.App.Islands, prerendered" $ do
  it "shows inline mathematics as its TeX, in a span" $
    renderToHtml Islands.component (MathInline mempty "x^2")
      `shouldReturn` "<span class=\"wiki-math wiki-math-inline\">x^2</span>"

  it "shows displayed mathematics as its TeX, in a div" $
    renderToHtml Islands.component (MathDisplay mempty "\\frac{1}{2}")
      `shouldReturn` "<div class=\"wiki-math wiki-math-display\">\\frac{1}{2}</div>"

  it "shows a diagram as its Mermaid source" $
    renderToHtml Islands.component (Mermaid "graph LR\n  a --> b")
      `shouldReturn` "<div class=\"wiki-mermaid\">graph LR\n  a --&gt; b</div>"

  it "shows a TikZ picture as its source, as written" $
    renderToHtml Islands.component (Tikz "\\draw (0,0) -- (1,1) node {$a<b$};")
      `shouldReturn` "<div class=\"wiki-tikz\">\\draw (0,0) -- (1,1) node {$a&lt;b$};</div>"

  it "shows code as plain text, escaped" $
    renderToHtml Islands.component (CodeBlock (Just "haskell") "x < y && y > z")
      `shouldReturn` "<pre class=\"wiki-code\">x &lt; y &amp;&amp; y &gt; z</pre>"
