-- | The markup each construct renders to.
module Test.Markdown.Render (spec) where

import Data.Row (Empty, type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Markdown
import Wiki.Core.Math (Macros (..))

shows' :: Text -> Text -> Expectation
shows' source expected = markdown source `shouldReturn` expected

showsWith :: Options page (H.ComponentSlot Empty MemDOM Void) Void -> Text -> Text -> Expectation
showsWith opts source expected = markdownWith opts source `shouldReturn` expected

spec :: Spec
spec = describe "Markdown.Render" $ do
  describe "text" $ do
    it "writes a paragraph's text as one text node" $
      "Hello, *world* & `code`." `shows'` "<p>Hello, <em>world</em> &amp; <code>code</code>.</p>"
    it "keeps soft breaks and writes hard ones as br" $
      "a\nb  \nc" `shows'` "<p>a\nb<br>\nc</p>"
    it "writes strong emphasis and strikethrough" $
      "**a** ~~b~~" `shows'` "<p><strong>a</strong> <del>b</del></p>"
    it "writes emoji with their shortcode as a title" $
      ":tada:" `shows'` "<p><span class=\"emoji\" title=\":tada:\">🎉</span></p>"
    it "writes a block quote and a thematic break" $
      "> q\n\n---" `shows'` "<blockquote><p>q</p></blockquote><hr>"

  describe "mentions" $ do
    let people = defaultOptions {resolveMention = \login -> if login == "ada" then Just MentionTarget {href = "/search/?q=%40ada", name = "Ada Lovelace"} else Nothing}
    it "links a mention of a user known to the options, titled with their name" $
      showsWith people "Ask @ada." "<p>Ask <a class=\"mention\" href=\"/search/?q=%40ada\" title=\"Ada Lovelace\">@ada</a>.</p>"
    it "writes a mention of nobody known as its text" $ do
      showsWith people "Ask @nobody." "<p>Ask @nobody.</p>"
      "Ask @ada." `shows'` "<p>Ask @ada.</p>"
    it "writes a mention in a link's text, and in code, as text" $
      showsWith people "[ask @ada](x) `@ada`" "<p><a href=\"x\">ask @ada</a> <code>@ada</code></p>"

  describe "headings" $ do
    it "writes the level and the id" $
      "## Getting started" `shows'` "<h2 id=\"getting-started\">Getting started</h2>"
    it "writes an id and classes given in braces" $
      "# Intro {#start .lead}" `shows'` "<h1 class=\"lead\" id=\"start\">Intro</h1>"
    it "writes no attribute other than id and class" $
      "# Intro {onclick=\"x()\"}" `shows'` "<h1 id=\"intro\">Intro</h1>"

  describe "lists" $ do
    it "writes a tight list's items without paragraphs" $
      "- a\n- b" `shows'` "<ul><li>a</li><li>b</li></ul>"
    it "writes a loose list's items as paragraphs" $
      "- a\n\n- b" `shows'` "<ul><li><p>a</p></li><li><p>b</p></li></ul>"
    it "writes where a numbered list starts, unless at 1" $ do
      "1. a" `shows'` "<ol><li>a</li></ol>"
      "3. a" `shows'` "<ol start=\"3\"><li>a</li></ol>"
    it "writes a task list with disabled checkboxes" $
      "- [ ] todo\n- [x] done"
        `shows'` ( "<ul class=\"task-list\">"
                     <> "<li class=\"task-list-item\"><input disabled type=\"checkbox\"> todo</li>"
                     <> "<li class=\"task-list-item\"><input checked disabled type=\"checkbox\"> done</li>"
                     <> "</ul>"
                 )
    it "puts a loose task's checkbox in its paragraph" $
      "- [x] done\n\n  more"
        `shows'` "<ul class=\"task-list\"><li class=\"task-list-item\"><p><input checked disabled type=\"checkbox\"> done</p><p>more</p></li></ul>"

  describe "tables"
    $ it "writes the header, the rows and each column's alignment"
    $ "| a | b | c |\n|---|:-:|--:|\n| 1 | 2 | 3 |"
      `shows'` ( "<table><thead><tr><th>a</th><th style=\"text-align: center\">b</th><th style=\"text-align: right\">c</th></tr></thead>"
                   <> "<tbody><tr><td>1</td><td style=\"text-align: center\">2</td><td style=\"text-align: right\">3</td></tr></tbody></table>"
               )

  describe "islands, by default" $ do
    it "writes code in a pre, with its language as a class" $ do
      "```haskell\nx = 1\n```" `shows'` "<pre><code class=\"language-haskell\">x = 1\n</code></pre>"
      "```\nx\n```" `shows'` "<pre><code>x\n</code></pre>"
    it "writes a Mermaid diagram's source in a pre.mermaid" $
      "```mermaid\ngraph TD; A-->B\n```" `shows'` "<pre class=\"mermaid\">graph TD; A--&gt;B\n</pre>"
    it "writes a TikZ picture's source in a pre.tikz, in either form" $ do
      "```tikz\n\\draw (0,0) -- (1,1);\n```" `shows'` "<pre class=\"tikz\">\\draw (0,0) -- (1,1);\n</pre>"
      "```tikz\n\\begin{tikzpicture}\n\\draw (0,0) circle (1);\n\\end{tikzpicture}\n```"
        `shows'` "<pre class=\"tikz\">\\begin{tikzpicture}\n\\draw (0,0) circle (1);\n\\end{tikzpicture}\n</pre>"
    it "writes inline math in a span" $
      "So $x^2$ holds." `shows'` "<p>So <span class=\"math inline\">x^2</span> holds.</p>"
    it "writes display math in a div, out of the paragraph" $
      "Then $$a+b$$ ends." `shows'` "<p>Then</p><div class=\"math display\">a+b</div><p>ends.</p>"
    it "writes math between LaTeX's delimiters as it writes math between dollars" $ do
      "So \\(x^2\\) holds." `shows'` "<p>So <span class=\"math inline\">x^2</span> holds.</p>"
      "Then \\[a+b\\] ends." `shows'` "<p>Then</p><div class=\"math display\">a+b</div><p>ends.</p>"
      "\\[\n\\int f\n\\]" `shows'` "<div class=\"math display\">\n\\int f\n</div>"

  describe "islands, by callback" $ do
    let keyed = \key -> show key.occurrence :: Text
        opts =
          defaultOptions
            { codeBlock = \key lang code -> HH.span [HP.title (keyed key)] [HH.text (fromMaybe "-" lang <> ":" <> code)]
            , mathInline = \key _ tex -> HH.span [HP.title (keyed key)] [HH.text ("i:" <> tex)]
            , mathDisplay = \key _ tex -> HH.span [HP.title (keyed key)] [HH.text ("d:" <> tex)]
            , mermaid = \key src -> HH.span [HP.title (keyed key)] [HH.text ("m:" <> src)]
            , tikz = \key src -> HH.span [HP.title (keyed key)] [HH.text ("t:" <> src)]
            }
    it "hands each island its source"
      $ showsWith opts "```js\nx\n```\n\n```mermaid\ny\n```\n\n$z$ $$w$$\n\n```tikz\nv\n```\n\n```tikz\n\\begin{tikzpicture}u\\end{tikzpicture}\n```"
      $ "<span title=\"0\">js:x\n</span><span title=\"0\">m:y\n</span>"
        <> "<p><span title=\"0\">i:z</span></p><span title=\"0\">d:w</span>"
        <> "<span title=\"0\">t:v\n</span><span title=\"0\">t:\\begin{tikzpicture}u\\end{tikzpicture}\n</span>"
    it "counts islands with the same source, of any kind, so that each key is unique"
      $ showsWith opts "$x$ $x$ $y$\n\n```\nx\n```\n\n```math\nx\n```"
      $ "<p><span title=\"0\">i:x</span> <span title=\"1\">i:x</span> <span title=\"0\">i:y</span></p>"
        <> "<span title=\"0\">-:x\n</span><span title=\"1\">d:x\n</span>"
    it "hands each formula the formulas before it that define macros, in the document's order" $ do
      let defined (Macros blocks) = T.intercalate "|" blocks
          withMacros =
            defaultOptions
              { mathInline = \_ earlier tex -> HH.span [HP.title (defined earlier)] [HH.text tex]
              , mathDisplay = \_ earlier tex -> HH.div [HP.title (defined earlier)] [HH.text tex]
              }
      showsWith withMacros "$\\newcommand{\\a}{1}$ $x$\n\n| $\\def\\b{2}$ |\n|---|\n\n$$\\a\\b$$\n\n```math\n\\renewcommand{\\a}{3}\n```\n\nLast $y$[^1]\n\n[^1]: $z$" $
        "<p><span title=\"\">\\newcommand{\\a}{1}</span> <span title=\"\\newcommand{\\a}{1}\">x</span></p>"
          <> "<table><thead><tr><th><span title=\"\\newcommand{\\a}{1}\">\\def\\b{2}</span></th></tr></thead></table>"
          <> "<div title=\"\\newcommand{\\a}{1}|\\def\\b{2}\">\\a\\b</div>"
          <> "<div title=\"\\newcommand{\\a}{1}|\\def\\b{2}\">\\renewcommand{\\a}{3}\n</div>"
          <> "<p>Last <span title=\"\\newcommand{\\a}{1}|\\def\\b{2}|\\renewcommand{\\a}{3}\n\">y</span>"
          <> "<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup></p>"
          <> "<section class=\"footnotes\"><ol><li id=\"fn-1\"><p><span title=\"\\newcommand{\\a}{1}|\\def\\b{2}|\\renewcommand{\\a}{3}\n\">z</span>"
          <> " <a class=\"footnote-back\" href=\"#fnref-1\">↩</a></p></li></ol></section>"

    it "renders islands as child components in slots indexed by their keys" $ do
      let child :: H.Component H.VoidF Text Void MemDOM
          child =
            H.mkComponent
              H.ComponentSpec
                { initialState = pure
                , render = \src -> HH.span [HP.class_ (HH.ClassName "island")] [HH.text src]
                , eval = H.mkEval H.defaultEval
                }
          islands :: Options Text (H.ComponentSlot ("island" .== H.Slot H.VoidF Void IslandKey) MemDOM Void) Void
          islands = defaultOptions {mermaid = \key src -> HH.slot_ "island" key child src}
      html <- renderHtml =<< renderMarkdownOr islands "```mermaid\nA\n```\n\n```mermaid\nA\n```\n\n```mermaid\nB\n```"
      html `shouldBe` "<span class=\"island\">A\n</span><span class=\"island\">A\n</span><span class=\"island\">B\n</span>"

  describe "links" $ do
    it "writes an external link with rel=noopener and its title" $
      "[x](https://example.com \"T\")" `shows'` "<p><a href=\"https://example.com\" rel=\"noopener\" title=\"T\">x</a></p>"
    it "writes autolinks" $
      "<https://a.example> www.b.example" `shows'` "<p><a href=\"https://a.example\" rel=\"noopener\">https://a.example</a> <a href=\"http://www.b.example\" rel=\"noopener\">www.b.example</a></p>"
    it "writes a fragment as it is, without rel" $
      "[up](#top)" `shows'` "<p><a href=\"#top\">up</a></p>"
    it "writes a page through pageHref" $ do
      showsWith wiki "[the guide](guide)" "<p><a href=\"/wiki/guide\">the guide</a></p>"
      showsWith wiki "[[eng/setup|Setting up]]" "<p><a class=\"wikilink\" href=\"/wiki/eng/setup\">Setting up</a></p>"
    it "writes a path as it is by default" $
      "[setup](../setup)" `shows'` "<p><a href=\"../setup\">setup</a></p>"
    it "writes an unresolved link as a span with the destination as its title" $
      showsWith wiki "[gone](nowhere)" "<p><span class=\"link-unresolved\" title=\"nowhere\">gone</span></p>"
    it "writes an attachment as a download link" $
      showsWith wiki "[the spec](attachment:spec.pdf)" "<p><a download=\"spec.pdf\" href=\"/files/spec.pdf\">the spec</a></p>"
    it "finds an attachment whose name has an escaped space" $
      showsWith wiki "[notes](attachment:my%20file.txt)" "<p><a download=\"my file.txt\" href=\"/files/my%20file.txt\">notes</a></p>"
    it "drops a javascript: link to its text" $ do
      "[click *me*](javascript:alert(1)) now" `shows'` "<p>click <em>me</em> now</p>"
      "[x](JavaScript:alert(1))" `shows'` "<p>x</p>"
      "[x](data:text/html,hi)" `shows'` "<p>x</p>"
    it "drops an attachment whose URL is not safe to its text" $
      showsWith wiki "[x](attachment:evil) ![y](attachment:evil)" "<p>x y</p>"
    it "writes no attribute other than id and class from braces" $
      "[x](#a){#l .c onmouseover=\"x()\"}" `shows'` "<p><a class=\"c\" href=\"#a\" id=\"l\">x</a></p>"

  describe "embeds" $ do
    it "writes an image with its caption as alt" $
      "![A *cat*](cat.png \"Tom\")" `shows'` "<p><img alt=\"A cat\" src=\"cat.png\" title=\"Tom\"></p>"
    it "writes a URL of a video's or an audio file's extension as a player" $ do
      "![Talk](https://example.com/talk.mp4)" `shows'` "<p><video aria-label=\"Talk\" controls src=\"https://example.com/talk.mp4\"></video></p>"
      "![](https://example.com/a.mp3)" `shows'` "<p><audio controls src=\"https://example.com/a.mp3\"></audio></p>"
    it "writes a URL of an unknown extension as an image" $
      "![x](https://example.com/render?id=3)" `shows'` "<p><img alt=\"x\" src=\"https://example.com/render?id=3\"></p>"
    it "writes an attachment by its media type" $ do
      showsWith wiki "![Demo](attachment:demo.mp4)" "<p><video aria-label=\"Demo\" controls src=\"/files/demo.mp4\"></video></p>"
      showsWith wiki "![Team](attachment:team)" "<p><img alt=\"Team\" src=\"/files/team\"></p>"
      showsWith wiki "![](attachment:song)" "<p><audio controls src=\"/files/song\"></audio></p>"
    it "writes an embedded page as a link to it" $
      showsWith wiki "![The guide](guide)" "<p><a href=\"/wiki/guide\">The guide</a></p>"
    it "writes an attachment of another type as a download link" $ do
      showsWith wiki "![The spec](attachment:spec.pdf)" "<p><a download=\"spec.pdf\" href=\"/files/spec.pdf\">The spec</a></p>"
      showsWith wiki "![](attachment:notes.txt)" "<p><a download=\"notes.txt\" href=\"/files/notes.txt\">notes.txt</a></p>"
    it "writes an attachment of no known type by its name's extension" $
      showsWith wiki "![](attachment:clip.webm)" "<p><video controls src=\"blob:https://wiki.example/1\"></video></p>"
    it "writes an unresolved attachment as a span" $
      showsWith wiki "![Gone](attachment:missing.png)" "<p><span class=\"embed-unresolved\" title=\"attachment:missing.png\">Gone</span></p>"
    it "leaves attachments unresolved by default" $
      "![x](attachment:a.png)" `shows'` "<p><span class=\"embed-unresolved\" title=\"attachment:a.png\">x</span></p>"
    it "writes width and height in pixels, and nothing else" $
      "![](a.png){width=300 height=50% onerror=\"x()\" .wide}" `shows'` "<p><img alt=\"\" class=\"wide\" src=\"a.png\" width=\"300\"></p>"
    it "drops an unsafe source to the caption" $
      "![pic](javascript:alert(1)) ![pic2](data:image/png;base64,AA)" `shows'` "<p>pic pic2</p>"

  describe "footnotes" $ do
    it "links references and notes both ways" $
      "A[^n] B[^n].\n\n[^n]: Note."
        `shows'` ( "<p>A<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"
                     <> " B<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\">1</a></sup>.</p>"
                     <> "<section class=\"footnotes\"><ol><li id=\"fn-1\"><p>Note. <a class=\"footnote-back\" href=\"#fnref-1\">↩</a></p></li></ol></section>"
                 )
    it "puts the link back after a note that does not end in a paragraph" $
      "A[^n]\n\n[^n]:\n    ```\n    x\n    ```"
        `shows'` ( "<p>A<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup></p>"
                     <> "<section class=\"footnotes\"><ol><li id=\"fn-1\"><pre><code>x\n</code></pre><a class=\"footnote-back\" href=\"#fnref-1\">↩</a></li></ol></section>"
                 )

  describe "boxes" $ do
    it "writes an alert with its title" $
      "> [!WARNING]\n> Hot." `shows'` "<div class=\"alert alert-warning\"><p class=\"alert-title\">Warning</p><p>Hot.</p></div>"
    it "writes a fenced div with its class" $
      "::: summary\nShort.\n:::" `shows'` "<div class=\"summary\"><p>Short.</p></div>"

  it "renders nothing for an empty page" $
    "" `shows'` ""

  it "writes a page without two text nodes in a row" $ do
    html <- markdown "a &amp; b\\* c :x: d\n[e](#e) f"
    html `shouldNotSatisfy` T.isInfixOf "<!---->"
