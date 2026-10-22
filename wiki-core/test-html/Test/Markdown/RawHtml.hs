-- | Raw HTML in a page as it is written into the page: what the allowlist
-- keeps ("Test.Markdown.Allowlist" tests the tree), among the Markdown, with
-- its links and sources resolved as the Markdown's are.
module Test.Markdown.RawHtml (spec) where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.Markdown.Html
import Test.QuickCheck (Gen, elements, forAll, frequency, ioProperty, listOf, (===))
import Wiki.Core.Markdown
import Wiki.Core.Markdown.Html (parseHtml)

shows' :: Text -> Text -> Expectation
shows' source expected = markdown source `shouldReturn` expected

showsWith :: Options page (H.ComponentSlot Empty MemDOM Void) Void -> Text -> Text -> Expectation
showsWith opts source expected = markdownWith opts source `shouldReturn` expected

spec :: Spec
spec = describe "Markdown.Render, raw HTML" $ do
  describe "among the text" $ do
    it "renders tags with what is between them" $
      "Press <kbd>Ctrl</kbd>+<kbd>C</kbd>, H<sub>2</sub>O, E = mc<sup>2</sup>."
        `shows'` "<p>Press <kbd>Ctrl</kbd>+<kbd>C</kbd>, H<sub>2</sub>O, E = mc<sup>2</sup>.</p>"
    it "keeps the Markdown between tags as Markdown" $
      "<mark>a *b* `c`</mark> <u>[d](https://example.com)</u>"
        `shows'` "<p><mark>a <em>b</em> <code>c</code></mark> <u><a href=\"https://example.com\" rel=\"noopener\">d</a></u></p>"
    it "drops event handlers and keeps the element" $
      "a <b onclick=\"x()\">b</b>" `shows'` "<p>a <b>b</b></p>"
    it "drops a script and what is in it" $
      "a <script>alert(1)</script> b" `shows'` "<p>a  b</p>"
    it "drops an image's onerror" $
      "a <img src=\"x.png\" onerror=\"alert(1)\"> b" `shows'` "<p>a <img src=\"x.png\"> b</p>"
    it "drops a javascript: link's href and keeps its text" $
      "<a href=\"javascript:alert(1)\">click</a>" `shows'` "<p><a>click</a></p>"
    it "closes a tag left open at the end of the paragraph" $
      "a <b>b *c\n\nd" `shows'` "<p>a <b>b *c</b></p><p>d</p>"
    it "closes a tag left open at the end of the emphasis it is in" $
      "*a <b>b* c</b>" `shows'` "<p><em>a <b>b</b></em> c</p>"
    it "drops a block element among the text and keeps what is in it" $
      "a <div>b</div> c" `shows'` "<p>a b c</p>"
    it "renders an island between tags, with its key" $ do
      let opts = defaultOptions {mathInline = \key _ tex -> HH.span [HP.title (show key.occurrence)] [HH.text tex]}
      showsWith opts "<mark>$x$</mark> $x$" "<p><mark><span title=\"0\">x</span></mark> <span title=\"1\">x</span></p>"
    it "makes no link inside a link" $ do
      "<a href=\"https://a.example\">x [y](https://b.example)</a>"
        `shows'` "<p><a href=\"https://a.example\" rel=\"noopener\">x y</a></p>"
      "[x <a href=\"https://b.example\">y</a>](https://a.example)"
        `shows'` "<p><a href=\"https://a.example\" rel=\"noopener\">x y</a></p>"
    it "renders in headings and table cells" $ do
      "# A <small>b</small>" `shows'` "<h1 id=\"a-b\">A <small>b</small></h1>"
      "| a |\n|---|\n| <kbd>k</kbd> |" `shows'` "<table><thead><tr><th>a</th></tr></thead><tbody><tr><td><kbd>k</kbd></td></tr></tbody></table>"
    it "drops HTML comments" $
      "a <!-- note --> b\n\n<!-- block -->" `shows'` "<p>a  b</p>"

  describe "a block" $ do
    it "renders a block as one document" $
      "<details open>\n<summary>More</summary>\nHidden *text*\n</details>"
        `shows'` "<details open=\"\">\n<summary>More</summary>\nHidden *text*\n</details>"
    it "does not read the Markdown inside a block" $
      "<div>\n**not bold**\n</div>" `shows'` "<div>\n**not bold**\n</div>"
    it "reads Markdown between blocks, which close where each block ends" $
      "<div class=\"note\">\n\n*Markdown*\n\n</div>"
        `shows'` "<div class=\"note\">\n</div><p><em>Markdown</em></p>"
    it "renders a heading block, and drops a heading among the text to its text" $ do
      "<h2 id=\"intro\" onclick=\"x()\">Intro</h2>" `shows'` "<h2 id=\"intro\">Intro</h2>"
      "a <h2>b</h2> c" `shows'` "<p>a b c</p>"
    it "drops a script block" $
      "<script>alert(1)</script>" `shows'` ""
    it "drops an svg with its onload" $
      "<svg onload=\"alert(1)\"><circle r=\"5\"></circle></svg>" `shows'` "<p></p>"
    it "renders a table with the tbody a browser gives it" $
      "<table>\n<tr><td colspan=\"2\">a</td></tr>\n</table>"
        `shows'` "<table><tbody><tr><td colspan=\"2\">a</td></tr></tbody></table>"
    it "writes a pre so that it reads back the same" $
      "<pre>\n\nx</pre>" `shows'` "<pre>\n\nx</pre>"
    it "renders lists, definitions and figures" $
      "<ol start=\"3\"><li>a<li>b</ol>\n<dl><dt>t<dd>d</dl>\n<figure><img src=\"https://example.com/a.png\" alt=\"A\" width=\"200\"><figcaption>c</figcaption></figure>"
        `shows'` ( "<ol start=\"3\"><li>a</li><li>b</li></ol>\n<dl><dt>t</dt><dd>d</dd></dl>\n"
                     <> "<figure><img alt=\"A\" src=\"https://example.com/a.png\" width=\"200\"><figcaption>c</figcaption></figure>"
                 )
    it "renders media with their controls and sources" $
      "<video controls poster=\"https://example.com/p.png\" width=\"320\"><source src=\"https://example.com/v.webm\"></video>"
        `shows'` "<p><video controls=\"\" poster=\"https://example.com/p.png\" width=\"320\"><source src=\"https://example.com/v.webm\"></video></p>"

  describe "links and sources" $ do
    it "resolves a link to a page as the Markdown's" $
      showsWith wiki "<a href=\"guide\">the guide</a>" "<p><a href=\"/wiki/guide\">the guide</a></p>"
    it "resolves an attachment: link to a download" $
      showsWith wiki "<a href=\"attachment:spec.pdf\">spec</a>" "<p><a download=\"spec.pdf\" href=\"/files/spec.pdf\">spec</a></p>"
    it "resolves a relative link that names no page as an attachment" $
      showsWith wiki "<a href=\"notes.txt\">notes</a>" "<p><a download=\"notes.txt\" href=\"/files/notes.txt\">notes</a></p>"
    it "resolves a source as an attachment, with or without the scheme" $ do
      showsWith wiki "<img src=\"team\" alt=\"Team\">" "<img alt=\"Team\" src=\"/files/team\">"
      showsWith wiki "<img src=\"attachment:team\">" "<img src=\"/files/team\">"
      showsWith wiki "<video controls><source src=\"clip.webm\"></video>" "<p><video controls=\"\"><source src=\"blob:https://wiki.example/1\"></video></p>"
    it "uses a relative source as it is when nothing resolves it" $
      "<img src=\"pics/a.png\">" `shows'` "<img src=\"pics/a.png\">"
    it "gives an external link rel=noopener, and a fragment none" $ do
      "<a href=\"https://example.com\">x</a> <a href=\"#top\">y</a>"
        `shows'` "<p><a href=\"https://example.com\" rel=\"noopener\">x</a> <a href=\"#top\">y</a></p>"
      "<a href=\"mailto:me@example.com\">m</a>" `shows'` "<p><a href=\"mailto:me@example.com\" rel=\"noopener\">m</a></p>"
    it "marks a link that resolves to nothing as unresolved, without an href" $ do
      showsWith wiki "<a href=\"nowhere\">gone</a>" "<p><a class=\"link-unresolved\">gone</a></p>"
      showsWith wiki "<a class=\"x\" href=\"nowhere\">gone</a>" "<p><a class=\"x link-unresolved\">gone</a></p>"
    it "drops a source that resolves to nothing, or to a URL that is not safe" $ do
      showsWith wiki "<img src=\"attachment:missing\" alt=\"m\">" "<img alt=\"m\">"
      showsWith wiki "<img src=\"attachment:evil\" alt=\"e\">" "<img alt=\"e\">"
      showsWith wiki "<a href=\"attachment:evil\">e</a>" "<p><a class=\"link-unresolved\">e</a></p>"
      showsWith wiki "<img src=\"guide\" alt=\"g\">" "<img alt=\"g\">"
    it "drops data: and javascript: sources" $
      "<img src=\"data:image/png;base64,AAAA\" alt=\"d\"><video poster=\"javascript:x\"></video>"
        `shows'` "<p><img alt=\"d\"><video></video></p>"

  it "renders a block on its own through renderRawHtml" $ do
    html <- renderHtml (renderRawHtml defaultOptions "<p>a<b>b<script>c</script>")
    html `shouldBe` "<p>a<b>b</b></p>"
    T.null <$> renderHtml (renderRawHtml defaultOptions "<!-- only a comment -->") `shouldReturn` True

  -- The prerender writes the tree as markup, and the browser reads that
  -- markup back to adopt it: if it read a different tree, hydration would
  -- have to repair the page. Reading it back here, by the same rules the
  -- tree was built by, is the nearest a native test gets to the browser.
  prop "writes markup that reads back as the same tree" $
    forAll tangle $ \raw -> ioProperty $ do
      written <- renderHtml (renderRawHtml defaultOptions raw)
      pure (parseHtml written === parseHtml raw)

-- | HTML of the allowed elements, nested and misnested, closed and not.
tangle :: Gen Text
tangle = T.concat <$> listOf piece
  where
    piece =
      frequency
        [ (4, (\n -> "<" <> n <> ">") <$> name)
        , (3, (\n -> "</" <> n <> ">") <$> name)
        , (3, elements ["a", " ", "\n", "\n\n", "&lt;", "x y"])
        ]
    name = elements ["b", "i", "a", "p", "div", "pre", "ul", "ol", "li", "dl", "dt", "dd", "table", "thead", "tbody", "tr", "td", "th", "caption", "details", "summary", "br", "hr", "img", "span", "font", "script"]
