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
    renderToHtml Islands.component (CodeBlock (Just "haskell") Nothing False "x < y && y > z")
      `shouldReturn` "<pre class=\"wiki-code\"><code>x &lt; y &amp;&amp; y &gt; z</code></pre>"

  it "shows numbered code with its gutter, an empty span for each line, before the code" $
    renderToHtml Islands.component (CodeBlock (Just "haskell") (Just 2) True "a\nb\nc")
      `shouldReturn` "<pre class=\"wiki-code numbered code-scroll\" style=\"max-height: 2lh; overflow: auto\"><span aria-hidden=\"true\" class=\"code-lines\"><span></span><span></span><span></span></span><code>a\nb\nc</code></pre>"

  it "shows an html fence's frame with its sandbox and its document in srcdoc, escaped, and nothing inside it" $
    renderToHtml Islands.component (HtmlFrame Nothing "<p title=\"&quot;\">a &amp; b</p></iframe><script>alert(1)</script>")
      `shouldReturn` ( "<iframe class=\"wiki-html\" sandbox=\"allow-same-origin allow-popups allow-popups-to-escape-sandbox\""
                         <> " srcdoc=\"&lt;p title=&quot;&amp;quot;&quot;&gt;a &amp;amp; b&lt;/p&gt;&lt;/iframe&gt;&lt;script&gt;alert(1)&lt;/script&gt;\""
                         <> " title=\"HTML block\"></iframe>"
                     )
