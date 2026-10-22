-- | What the parser makes of each construct the wiki supports. These run on
-- both backends: the tree is what the browser builds too.
module Test.Markdown.Ast (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast

parses :: Text -> [Block] -> Expectation
parses source expected = parseMarkdown source `shouldBe` Right expected

para :: [Inline] -> [Block]
para xs = [Para xs]

spec :: Spec
spec = describe "Markdown.Ast" $ do
  describe "inlines" $ do
    it "merges text into one Str" $
      "Hello, world & more." `parses` para [Str "Hello, world & more."]
    it "decodes entities and escapes into text" $
      "a &amp; b &#65; \\*c\\*" `parses` para [Str "a & b A *c*"]
    it "keeps soft and hard breaks" $
      "one\ntwo  \nthree" `parses` para [Str "one", SoftBreak, Str "two", LineBreak, Str "three"]
    it "reads emphasis, strong emphasis and strikethrough" $
      "*a* **b** ~~c~~" `parses` para [Emph [Str "a"], Str " ", Strong [Str "b"], Str " ", Strikeout [Str "c"]]
    it "reads inline code" $
      "use `x <- y`" `parses` para [Str "use ", Code [] "x <- y"]
    it "reads inline code with attributes" $
      "`f x`{.haskell}" `parses` para [Code [("class", "haskell")] "f x"]
    it "reads emoji shortcodes" $
      ":tada:" `parses` para [Emoji "tada" "🎉"]

  describe "links" $ do
    it "keeps the destination and the title as written" $
      "[docs](../guide \"The guide\")" `parses` para [Link [] "../guide" "The guide" [Str "docs"]]
    it "reads attachment links" $
      "[the spec](attachment:spec.pdf)" `parses` para [Link [] "attachment:spec.pdf" "" [Str "the spec"]]
    it "reads a destination in angle brackets with spaces" $
      "[x](<attachment:my file.pdf>)" `parses` para [Link [] "attachment:my file.pdf" "" [Str "x"]]
    it "reads autolinks in angle brackets and bare" $
      "<https://a.example> and https://b.example/x"
        `parses` para
          [ Link [] "https://a.example" "" [Str "https://a.example"]
          , Str " and "
          , Link [] "https://b.example/x" "" [Str "https://b.example/x"]
          ]
    it "reads reference links" $
      "[a][ref]\n\n[ref]: https://example.com" `parses` para [Link [] "https://example.com" "" [Str "a"]]
    it "reads wiki links, with and without a label" $
      "[[Onboarding]] and [[eng/setup|Setting up]]"
        `parses` para
          [ Link [("class", "wikilink")] "Onboarding" "" [Str "Onboarding"]
          , Str " and "
          , Link [("class", "wikilink")] "eng/setup" "" [Str "Setting up"]
          ]

  describe "embeds" $ do
    it "reads an image with its caption and title" $
      "![A cat](cat.png \"Tom\")" `parses` para [Image [] "cat.png" "Tom" [Str "A cat"]]
    it "reads an attachment embed" $
      "![Demo](attachment:demo.mp4)" `parses` para [Image [] "attachment:demo.mp4" "" [Str "Demo"]]
    it "reads attributes after an embed" $
      "![](a.png){width=300 .wide}" `parses` para [Image [("width", "300"), ("class", "wide")] "a.png" "" []]

  describe "headings" $ do
    it "gets an id from its text" $
      "# Getting started" `parses` [Heading 1 [("id", "getting-started")] [Str "Getting started"]]
    it "keeps letters outside ASCII in its id" $
      "## Zażółć gęślą" `parses` [Heading 2 [("id", "zażółć-gęślą")] [Str "Zażółć gęślą"]]
    it "gets a numbered id when the text repeats" $
      "# A\n\n# A" `parses` [Heading 1 [("id", "a")] [Str "A"], Heading 1 [("id", "a-1")] [Str "A"]]
    it "keeps an id given in braces" $
      "### Intro {#start .lead}" `parses` [Heading 3 [("id", "start"), ("class", "lead")] [Str "Intro"]]
    it "reads setext headings" $
      "Title\n=====" `parses` [Heading 1 [("id", "title")] [Str "Title"]]

  describe "blocks" $ do
    it "reads a block quote" $
      "> quoted" `parses` [BlockQuote (para [Str "quoted"])]
    it "reads a thematic break" $
      "a\n\n---\n\nb" `parses` [Para [Str "a"], ThematicBreak, Para [Str "b"]]
    it "reads a fenced div with its class" $
      "::: warning\nCareful.\n:::" `parses` [Div [("class", "warning")] (para [Str "Careful."])]
    it "reads a GitHub alert" $
      "> [!NOTE]\n> Read this." `parses` [Alert Note (para [Str "Read this."])]
    it "keeps raw HTML as raw HTML, not as markup" $
      "<div onclick=\"x()\">hi</div>\n\ntext <b>bold</b>"
        `parses` [ RawHtmlBlock "<div onclick=\"x()\">hi</div>\n"
                 , Para [Str "text ", RawHtml "<b>", Str "bold", RawHtml "</b>"]
                 ]

  describe "code" $ do
    it "reads a fence's language and code" $
      "```haskell\nmain = pure ()\n```" `parses` [CodeBlock [] (Just "haskell") "main = pure ()\n"]
    it "takes the language from the first word of the info string" $
      "```js linenos\nx\n```" `parses` [CodeBlock [] (Just "js") "x\n"]
    it "reads a fence without a language" $
      "```\nplain\n```" `parses` [CodeBlock [] Nothing "plain\n"]
    it "reads indented code" $
      "    indented" `parses` [CodeBlock [] Nothing "indented\n"]
    it "takes the language from a class when the fence has attributes only" $
      "``` {.python}\nx\n```" `parses` [CodeBlock [("class", "python")] (Just "python") "x\n"]
    it "reads a mermaid fence as a diagram" $
      "```mermaid\ngraph TD; A-->B\n```" `parses` [Mermaid "graph TD; A-->B\n"]
    it "reads a math fence as display math" $
      "```math\nx^2\n```" `parses` [MathBlock "x^2\n"]

  describe "math" $ do
    it "reads inline math" $
      "Euler: $e^{i\\pi} + 1 = 0$." `parses` para [Str "Euler: ", Math InlineMath "e^{i\\pi} + 1 = 0", Str "."]
    it "reads a paragraph of display math as a block" $
      "$$\n\\int_0^1 x\\,dx\n$$" `parses` [MathBlock "\n\\int_0^1 x\\,dx\n"]
    it "splits a paragraph around display math" $
      "Before $$a+b$$ after." `parses` [Para [Str "Before"], MathBlock "a+b", Para [Str "after."]]
    it "keeps display math inline in a heading" $
      "# Sum $$x$$" `parses` [Heading 1 [("id", "sum-x")] [Str "Sum ", Math DisplayMath "x"]]
    it "leaves a lone dollar alone" $
      "It costs $5." `parses` para [Str "It costs $5."]

  describe "lists" $ do
    it "reads a tight bullet list" $
      "- a\n- b" `parses` [List BulletList [ListItem Nothing [Plain [Str "a"]], ListItem Nothing [Plain [Str "b"]]]]
    it "reads a loose list as paragraphs" $
      "- a\n\n- b" `parses` [List BulletList [ListItem Nothing (para [Str "a"]), ListItem Nothing (para [Str "b"])]]
    it "reads an ordered list with its start" $
      "3. c\n4. d" `parses` [List (OrderedList 3) [ListItem Nothing [Plain [Str "c"]], ListItem Nothing [Plain [Str "d"]]]]
    it "reads nested lists" $
      "- a\n  - b"
        `parses` [List BulletList [ListItem Nothing [Plain [Str "a"], List BulletList [ListItem Nothing [Plain [Str "b"]]]]]]
    it "reads a list item with a pipe in it as a list item" $
      "- a | b\n- c" `parses` [List BulletList [ListItem Nothing [Plain [Str "a | b"]], ListItem Nothing [Plain [Str "c"]]]]
    it "reads a task list" $
      "- [ ] todo\n- [x] done"
        `parses` [List BulletList [ListItem (Just False) [Plain [Str "todo"]], ListItem (Just True) [Plain [Str "done"]]]]

  describe "tables" $ do
    it "reads every row, the last one too" $
      "a | b\n--|--\n1 | 2\n3 | 4" `parses` [Table [AlignDefault, AlignDefault] [[Str "a"], [Str "b"]] [[[Str "1"], [Str "2"]], [[Str "3"], [Str "4"]]]]
    it "reads a table without a header row's pipes at the edges" $
      "a | b\n--|--\n1 | 2\n" `parses` [Table [AlignDefault, AlignDefault] [[Str "a"], [Str "b"]] [[[Str "1"], [Str "2"]]]]
    it "reads alignments, the header and the rows" $
      "| a | b | c | d |\n|---|:--|:-:|--:|\n| 1 | *2* | 3 | 4 |"
        `parses` [ Table
                     [AlignDefault, AlignLeft, AlignCenter, AlignRight]
                     [[Str "a"], [Str "b"], [Str "c"], [Str "d"]]
                     [[[Str "1"], [Emph [Str "2"]], [Str "3"], [Str "4"]]]
                 ]

  describe "footnotes" $ do
    it "reads references and the notes, numbered in the order they are defined" $
      "One[^a] two[^b] again[^a].\n\n[^b]: Bee.\n[^a]: Ay."
        `parses` [ Para [Str "One", FootnoteRef 2 "a", Str " two", FootnoteRef 1 "b", Str " again", FootnoteRef 2 "a", Str "."]
                 , Footnotes [Footnote 1 "b" (para [Str "Bee."]), Footnote 2 "a" (para [Str "Ay."])]
                 ]
    it "leaves a reference to no note as text" $
      "x[^nope]" `parses` para [Str "x[^nope]"]

  describe "reading the tree" $ do
    it "plainText drops the markup" $
      plainText [Str "a ", Emph [Str "b"], SoftBreak, Code [] "c", Str " ", Link [] "x" "" [Str "d"]] `shouldBe` "a b c d"
    it "classes gathers every class" $
      classes [("class", "a b"), ("id", "x"), ("class", "c")] `shouldBe` ["a", "b", "c"]
    it "attribute finds the first value" $
      attribute "id" [("class", "a"), ("id", "x"), ("id", "y")] `shouldBe` Just "x"
