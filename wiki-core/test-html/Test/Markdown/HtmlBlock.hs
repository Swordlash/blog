-- | An html fence as it is written into a page (WP5.89 of docs/PLAN.md):
-- by default its source as a listing; with a frame, as the application
-- shows it, its document in the frame's @srcdoc@ attribute and nowhere
-- else, through the allowlist widened by styles, with its links resolved.
-- Also the fences that are no longer listings (@latex@) and those that
-- @norender@ keeps listings.
module Test.Markdown.HtmlBlock (spec) where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Text.HTML.TagSoup (Tag (..), parseTags)
import Wiki.Core.Markdown
import Wiki.Core.Markdown.Frame (frameDocument, frameSandbox)

shows' :: Text -> Text -> Expectation
shows' source expected = markdown source `shouldReturn` expected

-- | The test wiki's options ('wiki'), with an html fence shown as the
-- application shows it: a frame, its sandbox and its document attributes.
framed :: Options Text (H.ComponentSlot Empty MemDOM Void) Void
framed =
  wiki
    { htmlBlock = \_ _ document ->
        HH.iframe [HP.attr (HH.AttrName "sandbox") frameSandbox, HP.attr (HH.AttrName "srcdoc") document]
    }

-- | The markup of an html fence holding this HTML, in a frame.
inFrame :: Text -> IO Text
inFrame html = markdownWith framed ("```html\n" <> html <> "\n```\n")

-- | The document a page's one frame holds, read from its markup as a
-- browser reads the attribute; the test fails if the markup is anything
-- but the frame.
srcdocOf :: Text -> IO Text
srcdocOf markup = case parseTags markup of
  [TagOpen "iframe" attrs, TagClose "iframe"]
    | Just (_, document) <- find ((== "srcdoc") . fst) attrs -> pure document
  other -> expectationFailure ("not one frame: " <> show other) >> pure ""

-- | The document the frame of an html fence holding this HTML shows, with
-- this content.
holding :: Text -> Text -> Expectation
holding html content = (srcdocOf =<< inFrame html) `shouldReturn` frameDocument content

spec :: Spec
spec = describe "Markdown.Render, an html fence" $ do
  describe "by default, as a feed shows it"
    $ it "writes the source as an HTML listing"
    $ "```html\n<p style=\"color: red\">x</p>\n```" `shows'` "<pre><code class=\"language-html\">&lt;p style=\"color: red\"&gt;x&lt;/p&gt;\n</code></pre>"

  describe "in a frame" $ do
    it "writes the frame's document into its srcdoc, escaped, and nothing else" $
      inFrame "<p class=\"c-red\">Hi</p>"
        `shouldReturn` ( "<iframe sandbox=\"allow-same-origin allow-popups allow-popups-to-escape-sandbox\" srcdoc=\""
                           <> escaped (frameDocument "<p class=\"c-red\">Hi</p>")
                           <> "\"></iframe>"
                       )
    it "keeps the author's styles, attributes and style elements" $
      "<style>p > b { color: tomato }</style>\n<p style=\"margin: 0\"><b>x</b></p>"
        `holding` "<style>p > b { color: tomato }</style>\n<p style=\"margin: 0\"><b>x</b></p>"
    it "drops what the allowlist drops: scripts, handlers, frames, forms, meta, base, link" $
      "<script>alert(1)</script><img src=\"https://example.com/a.png\" onerror=\"alert(2)\"><iframe src=\"https://evil.example\"></iframe><form><button>go</button></form><meta http-equiv=\"refresh\" content=\"0;url=https://evil.example\"><base href=\"https://evil.example/\"><link rel=\"stylesheet\" href=\"https://evil.example/x.css\">"
        `holding` "<img src=\"https://example.com/a.png\">go\n"
    it "resolves links and sources as the page does, and opens links in a new tab" $
      "<a href=\"guide\">guide</a> <a href=\"attachment:spec.pdf\">spec</a> <a href=\"https://example.com\">out</a> <a href=\"nowhere\">gone</a> <img src=\"team\" alt=\"Team\">"
        `holding` ( "<a href=\"/wiki/guide\" target=\"_blank\" rel=\"noopener noreferrer\">guide</a> "
                      <> "<a href=\"/files/spec.pdf\" target=\"_blank\" rel=\"noopener noreferrer\">spec</a> "
                      <> "<a href=\"https://example.com\" target=\"_blank\" rel=\"noopener noreferrer\">out</a> "
                      <> "<a class=\"link-unresolved\">gone</a> "
                      <> "<img src=\"/files/team\" alt=\"Team\">"
                  )
    it "keeps the text of a link to a place in the page, which the frame cannot reach" $
      "<a href=\"#top\" class=\"x\">top</a>" `holding` "<a class=\"x\">top</a>"
    it "keeps a link to a page whose address is a fragment, as a router that keeps its routes there writes it" $ do
      let hashRouted = framed {pageHref = ("#/" <>)}
      markup <- markdownWith hashRouted "```html\n<a href=\"guide\">guide</a>\n```\n"
      srcdocOf markup `shouldReturn` frameDocument "<a href=\"#/guide\" target=\"_blank\" rel=\"noopener noreferrer\">guide</a>"

    describe "whatever the block holds, nothing of it lands outside the srcdoc" $ do
      let hostile =
            T.intercalate
              "\n"
              [ "<p title='\"><script>alert(1)</script>'>\"&gt;&lt;script&gt;alert(1)&lt;/script&gt; &lt;/iframe&gt; &quot; &amp;quot; &lt;/style&gt;&lt;script&gt;</p>"
              , "<style>&lt;/style&gt;&lt;script&gt;alert(2)&lt;/script&gt;</style>"
              , "<style>p { content: \"</style><script>alert(3)</script>\" }</style>"
              , "</iframe><script>alert(4)</script>\"><script>alert(5)</script>"
              ]
      it "writes the frame alone: its two tags are the only ones in the markup" $ do
        markup <- inFrame hostile
        T.count "<" markup `shouldBe` 2
        markup `shouldSatisfy` T.isPrefixOf "<iframe "
        markup `shouldSatisfy` T.isSuffixOf "\"></iframe>"
      it "writes each string escaped in the document, and a style's CSS as it is with </ made <\\/" $
        hostile
          `holding` T.intercalate
            "\n"
            [ "<p title=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\">&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt; &lt;/iframe&gt; &quot; &amp;quot; &lt;/style&gt;&lt;script&gt;</p>"
            , "<style><\\/style><script>alert(2)<\\/script></style>"
            , "<style>p { content: \"</style>&quot; }"
            , "&quot;&gt;\n"
            ]

  describe "latex and norender" $ do
    it "renders a latex fence as display math, as $$ and a math fence" $ do
      "```latex\na+b\n```" `shows'` "<div class=\"math display\">a+b\n</div>"
      "```math\na+b\n```" `shows'` "<div class=\"math display\">a+b\n</div>"
    it "renders a fence with norender as a listing of its language, without the class" $ do
      "```html {.norender}\n<b>x</b>\n```" `shows'` "<pre><code class=\"language-html\">&lt;b&gt;x&lt;/b&gt;\n</code></pre>"
      "```mermaid {.norender}\ngraph TD\n```" `shows'` "<pre><code class=\"language-mermaid\">graph TD\n</code></pre>"
      "```{.tikz .norender}\n\\draw;\n```" `shows'` "<pre><code class=\"language-tikz\">\\draw;\n</code></pre>"
      "```latex {.norender}\nx\n```" `shows'` "<pre><code class=\"language-latex\">x\n</code></pre>"
      "```math {.norender .numbered}\nx\n```" `shows'` "<pre class=\"numbered\"><span aria-hidden=\"true\" class=\"code-lines\"><span></span></span><code class=\"language-latex\">x\n</code></pre>"
  where
    -- An attribute's value as "Halogen.Static" writes it.
    escaped = T.replace "\"" "&quot;" . T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"
