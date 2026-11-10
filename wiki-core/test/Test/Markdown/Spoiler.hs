-- | Spoilers and scrolling listings (WP5.62 of docs/PLAN.md, issue #152),
-- as the parser reads them: inline spoilers, @||hidden||@; block spoilers
-- between @[[!spoiler]]{name}(Description)@ and @[[/spoiler]]{name}@, with
-- the lines the page shows in red and the rule that a spoiler does not
-- cut across sections; heading spoilers, @## [[!spoiler]] Question@, which
-- hide the heading's section (WP5.64); and a fence's @rows=N@. These run
-- on both backends.
module Test.Markdown.Spoiler (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Toc (anchors, tableOfContents)
import Wiki.Core.Search (bodyText)
import Wiki.Core.Slides (Deck (..), Slide (..), SlideTitle (..), deckOf, isDeck)

parses :: Text -> [Block] -> Expectation
parses source expected = parseMarkdown source `shouldBe` Right expected

-- | A page's blocks; a page that does not parse fails the test.
blocksOf :: Text -> [Block]
blocksOf = either (panic . show) identity . parseMarkdown

-- | Every block spoiler of a page, nested ones too, in the page's order:
-- its name and its problem, if any.
spoilers :: [Block] -> [(Text, Maybe SpoilerProblem)]
spoilers = concatMap $ \case
  Spoiler h bs -> (h.name, h.problem) : spoilers bs
  BlockQuote bs -> spoilers bs
  List _ items -> concat [spoilers bs | ListItem _ bs <- items]
  _ -> []

-- | Every line of a page shown in red, nested ones too: as written, and
-- why.
errors :: [Block] -> [(Text, Text)]
errors = concatMap $ \case
  MarkerError written why -> [(written, why)]
  Spoiler _ bs -> errors bs
  BlockQuote bs -> errors bs
  _ -> []

-- | Some blocks as a short text each, to compare their shape: a heading
-- as @h2 Text@, a paragraph as its text, and a block that holds blocks
-- with them in braces (a spoiler after its name).
shape :: [Block] -> [Text]
shape = map $ \case
  Heading level _ xs -> "h" <> show level <> " " <> plainText xs
  Para xs -> plainText xs
  Plain xs -> plainText xs
  Spoiler h bs -> h.name <> " {" <> inside bs <> "}"
  BlockQuote bs -> "> {" <> inside bs <> "}"
  Div _ bs -> "div {" <> inside bs <> "}"
  List _ items -> "- {" <> T.intercalate " | " [inside bs | ListItem _ bs <- items] <> "}"
  other -> show other
  where
    inside = T.intercalate ", " . shape

-- | A heading spoiler's head as the parser makes it, after its name or
-- its heading's id.
onHeading :: Text -> Text -> Int -> SpoilerHead
onHeading name marker line = SpoilerHead {name, description = [], marker, line, problem = Nothing, kind = OnHeading}

-- | A spoiler's head as the parser makes it: right, on this line.
headOf :: Text -> [Inline] -> Text -> Int -> SpoilerHead
headOf name description marker line = SpoilerHead {name, description, marker, line, problem = Nothing, kind = BetweenMarkers}

spec :: Spec
spec = describe "Markdown spoilers and listings" $ do
  describe "inline spoilers, ||hidden||" $ do
    it "reads text between two pairs of bars as a spoiler" $
      "a ||secret|| b" `parses` [Para [Str "a ", Hidden [Str "secret"], Str " b"]]
    it "holds formatting, code and math, and is held by them" $ do
      "||**bold** and `code` and $x$||" `parses` [Para [Hidden [Strong [Str "bold"], Str " and ", Code [] "code", Str " and ", Math InlineMath "x"]]]
      "*an ||aside||*" `parses` [Para [Emph [Str "an ", Hidden [Str "aside"]]]]
    it "leaves a lone bar, bars between spaces and bars that pair with none text" $ do
      "a | b" `parses` [Para [Str "a | b"]]
      "a || b" `parses` [Para [Str "a || b"]]
      "x ||y" `parses` [Para [Str "x ||y"]]
    it "leaves a table's bars the table's, and wiki links' bars theirs" $ do
      "| a | b |\n|---|---|\n| 1 | 2 |" `parses` [Table [AlignDefault, AlignDefault] [[Str "a"], [Str "b"]] [[[Str "1"], [Str "2"]]]]
      "[[tour|the tour]]" `parses` [Para [Link [("class", "wikilink")] "tour" "" [Str "the tour"]]]
    it "keeps its text in the plain text" $
      (concatMap (\case Para xs -> [plainText xs]; _ -> []) (blocksOf "Ends ||badly||.")) `shouldBe` ["Ends badly."]

  describe "block spoilers" $ do
    it "holds any blocks, code and lists among them, with Markdown in its description" $
      "[[!spoiler]]{solution}(What the *answer* is)\n```haskell\nmain = pure ()\n```\n\n- a\n- b\n[[/spoiler]]{solution}\n"
        `parses` [ Spoiler
                     (headOf "solution" [Str "What the ", Emph [Str "answer"], Str " is"] "[[!spoiler]]{solution}(What the *answer* is)" 1)
                     [CodeBlock [] (Just "haskell") "main = pure ()\n", List BulletList [ListItem Nothing [Plain [Str "a"]], ListItem Nothing [Plain [Str "b"]]]]
                 ]
    it "tolerates spaces between the parts, indentation, and parentheses in the description" $
      "   [[!spoiler]] {hint} ( A hint (or two) )\nx\n[[/spoiler]]{hint}"
        `parses` [Spoiler (headOf "hint" [Str "A hint (or two)"] "[[!spoiler]] {hint} ( A hint (or two) )" 1) [Para [Str "x"]]]
    it "nests, an end marker ending the innermost spoiler" $
      "[[!spoiler]]{outer}(Outer)\na\n[[!spoiler]]{inner}(Inner)\nb\n[[/spoiler]]{inner}\nc\n[[/spoiler]]{outer}\n"
        `parses` [ Spoiler
                     (headOf "outer" [Str "Outer"] "[[!spoiler]]{outer}(Outer)" 1)
                     [Para [Str "a"], Spoiler (headOf "inner" [Str "Inner"] "[[!spoiler]]{inner}(Inner)" 3) [Para [Str "b"]], Para [Str "c"]]
                 ]
    it "shows an end marker of another name in red, ends nothing, and the outer spoiler still ends" $ do
      let doc = blocksOf "[[!spoiler]]{outer}(Outer)\na\n[[/spoiler]]{other}\nb\n[[/spoiler]]{outer}\n"
      spoilers doc `shouldBe` [("outer", Nothing)]
      errors doc `shouldBe` [("[[/spoiler]]{other}", "no open spoiler of this name")]
    it "says which spoiler is innermost when an end marker names an outer one" $ do
      let doc = blocksOf "[[!spoiler]]{a}(A)\n[[!spoiler]]{b}(B)\nx\n[[/spoiler]]{a}\n[[/spoiler]]{b}\n[[/spoiler]]{a}\n"
      spoilers doc `shouldBe` [("a", Nothing), ("b", Nothing)]
      map snd (errors doc) `shouldBe` ["the innermost open spoiler is “b”: end it first"]
      -- With no spoiler open, an end marker is the text it is.
      errors (blocksOf "text\n\n[[/spoiler]]{a}") `shouldBe` []
    it "shows a start marker without its name, with a bad name, or without its description in red, and opens nothing" $ do
      let reasons source = map snd (errors (blocksOf source))
      reasons "[[!spoiler]](Description)\ntext" `shouldBe` ["a spoiler needs its name in braces after [[!spoiler]], as in [[!spoiler]]{name}(Description)"]
      reasons "[[!spoiler]]{my name}(Description)" `shouldBe` ["a spoiler's name is one word of letters, digits, - and _"]
      reasons "[[!spoiler]]{x}" `shouldBe` ["a spoiler needs a description in parentheses after its name, as in [[!spoiler]]{name}(Description)"]
      reasons "[[!spoiler]]{x}(  )" `shouldBe` ["a spoiler needs a description in its parentheses, as in [[!spoiler]]{name}(Description)"]
      reasons "[[!spoiler]]{x}(D) more" `shouldBe` ["nothing may follow the description's closing parenthesis"]
      reasons "[[!spoiler]]{x} words (D)" `shouldBe` ["a spoiler needs a description in parentheses after its name, as in [[!spoiler]]{name}(Description)"]
      spoilers (blocksOf "[[!spoiler]](Description)\ntext") `shouldBe` []
      blocksOf "[[!spoiler]](D)\ntext" `shouldBe` [MarkerError "[[!spoiler]](D)" "a spoiler needs its name in braces after [[!spoiler]], as in [[!spoiler]]{name}(Description)", Para [Str "text"]]
    it "ends a spoiler with an end marker without a name, and shows one with more after it in red" $ do
      let doc = blocksOf "[[!spoiler]]{x}(D)\na\n[[/spoiler]]{x} more\n[[/spoiler]]\n"
      map snd (errors doc) `shouldBe` ["nothing may follow an end marker's name"]
      spoilers doc `shouldBe` [("x", Nothing)]
    it "reads {#name} as the same name as {name}, in the start, the end and a heading's marker" $ do
      "[[!spoiler]]{#x}(D)\na\n[[/spoiler]]{x}\n" `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{#x}(D)" 1) [Para [Str "a"]]]
      spoilers (blocksOf "[[!spoiler]]{x}(D)\na\n[[/spoiler]]{#x}\n") `shouldBe` [("x", Nothing)]
      shape (blocksOf "## [[!spoiler]]{#q} Question\n\nx\n") `shouldBe` ["q {h2 Question, x}"]
    it "takes no class and no other attribute in a spoiler's braces" $
      map snd (errors (blocksOf "[[!spoiler]]{.x}(D)\n")) `shouldBe` ["a spoiler's braces hold its name alone, with no class or other attribute, as in [[!spoiler]]{name}(Description)"]
    it "makes a spoiler not closed by the end of the page hold everything after its marker" $
      "Before\n\n[[!spoiler]]{x}(D)\na\n\n# Later\n\nb\n"
        `parses` [ Para [Str "Before"]
                 , Spoiler
                     (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 3) {problem = Just NotClosed}
                     [Para [Str "a"], Heading 1 [("id", "later")] [Str "Later"], Para [Str "b"]]
                 ]
    it "ends a spoiler not closed in a quotation or a list item with them" $ do
      blocksOf "> [[!spoiler]]{x}(D)\n> a\n\nafter\n"
        `shouldBe` [BlockQuote [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) {problem = Just NotClosed} [Para [Str "a"]]], Para [Str "after"]]
      spoilers (blocksOf "- [[!spoiler]]{x}(D)\n  a\n- next\n") `shouldBe` [("x", Just NotClosed)]
      spoilers (blocksOf "> [[!spoiler]]{x}(D)\n> a\n> [[/spoiler]]{x}\n") `shouldBe` [("x", Nothing)]
    it "does not read an end marker in code" $
      "[[!spoiler]]{x}(D)\n```\n[[/spoiler]]{x}\n```\n[[/spoiler]]{x}\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [CodeBlock [] Nothing "[[/spoiler]]{x}\n"]]
    it "reads an end marker on the line after indented code, which that line ends" $ do
      "[[!spoiler]]{x}(D)\n    code\n[[/spoiler]]{x}\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [CodeBlock [] Nothing "code\n"]]
      "[[!spoiler]]{x}(D)\n    code\n[[/spoiler]]\nafter\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [CodeBlock [] Nothing "code\n"], Para [Str "after"]]
      "- [[!spoiler]]{x}(D)\n      code\n  [[/spoiler]]{x}\n"
        `parses` [List BulletList [ListItem Nothing [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [CodeBlock [] Nothing "code\n"]]]]
    it "reads an end marker on the line after a block of HTML of one line" $
      "[[!spoiler]]{x}(D)\n<pre>x</pre>\n[[/spoiler]]\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [RawHtmlBlock "<pre>x</pre>\n"]]
    it "reads an end marker on the line that ends the list item of a block inside, which is not closed" $
      spoilers (blocksOf "[[!spoiler]]{x}(D)\n- [[!div]]\n  y\n[[/spoiler]]{x}\n") `shouldBe` [("x", Nothing)]
    it "does not read an end marker in a fenced code block not closed or a block of HTML" $ do
      spoilers (blocksOf "[[!spoiler]]{x}(D)\n```\n[[/spoiler]]{x}\n") `shouldBe` [("x", Just NotClosed)]
      "[[!spoiler]]{x}(D)\n<div>\n[[/spoiler]]{x}\n</div>\n\n[[/spoiler]]{x}\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[!spoiler]]{x}(D)" 1) [RawHtmlBlock "<div>\n[[/spoiler]]{x}\n</div>\n"]]
    it "leaves the marker without its exclamation mark, a marker in a line's middle and an escaped marker as they were" $ do
      "[[spoiler]]{x}(D)" `parses` [Para [Link [("class", "wikilink")] "spoiler" "" [Str "spoiler"], Str "{x}(D)"]]
      [() | Para _ <- blocksOf "See [[!spoiler]] here"] `shouldBe` [()]
      "\\[[!spoiler]]{x}(D)" `parses` [Para [Str "[[!spoiler]]{x}(D)"]]
    it "keeps a spoiler's description and blocks in the plain text" $
      bodyText "[[!spoiler]]{x}(The answer)\nForty-two.\n[[/spoiler]]{x}\n" `shouldBe` "The answer Forty-two."
    it "gives the export each marker line, with what it is" $
      (\(_, _, ms, _) -> ms) <$> parseWithAllMarkers "[[!spoiler]]{x}(D)\n> [[/spoiler]]{y}\n[[/spoiler]]{x}\n"
        `shouldBe` Right
          [ MarkerLine 1 1 (Starts "x" "D")
          , MarkerLine 2 3 (Faulty "[[/spoiler]]{y}" "no open spoiler of this name")
          , MarkerLine 3 1 (Ends 1)
          ]

    it "gives the export where each inline spoiler's bars are, and none for bars that are text" $
      (\(_, _, ms, _) -> ms) <$> parseWithAllMarkers "a ||b|| c \\|\\|d\\|\\| `||e||`\n> ||f\n> g||\n\n[[!spoiler]]{x}(A ||b||)\nc\n[[/spoiler]]{x}\n"
        `shouldBe` Right
          [ MarkerLine 1 3 (InlineBars 1 6)
          , MarkerLine 2 3 (InlineBars 3 4)
          , MarkerLine 5 1 (Starts "x" "A ||b||")
          , MarkerLine 5 19 (InlineBars 5 22)
          , MarkerLine 7 1 (Ends 5)
          ]

  describe "spoilers and sections" $ do
    it "accepts a spoiler within a section, without a heading" $
      spoilers (blocksOf "## A\n\n[[!spoiler]]{x}(D)\ntext\n[[/spoiler]]{x}\n\nmore\n") `shouldBe` [("x", Nothing)]
    it "accepts a spoiler that wraps a whole section, its subsections and up to the next heading of its level" $ do
      let section = "## A\n\n[[!spoiler]]{s}(D)\n## B\n\nb\n\n### B1\n\nc\n[[/spoiler]]{s}\n"
      spoilers (blocksOf (section <> "\n## C\n")) `shouldBe` [("s", Nothing)]
      spoilers (blocksOf (section <> "\n# Higher\n")) `shouldBe` [("s", Nothing)]
      spoilers (blocksOf section) `shouldBe` [("s", Nothing)]
      -- Two sections in a row, each in a spoiler of its own.
      spoilers (blocksOf (section <> "[[!spoiler]]{t}(E)\n## C\n\nc\n[[/spoiler]]{t}\n")) `shouldBe` [("s", Nothing), ("t", Nothing)]
    it "accepts a spoiler that wraps a subsection inside one that wraps its section" $
      spoilers (blocksOf "[[!spoiler]]{s}(D)\n## B\n\nb\n\n[[!spoiler]]{t}(E)\n### B1\n\nc\n[[/spoiler]]{t}\n[[/spoiler]]{s}\n")
        `shouldBe` [("s", Nothing), ("t", Nothing)]
    it "refuses a heading after the spoiler's first block" $
      spoilers (blocksOf "[[!spoiler]]{s}(D)\ntext\n\n## B\n[[/spoiler]]{s}\n") `shouldBe` [("s", Just CutsSection)]
    it "refuses a heading inside of the section's own level or higher" $
      spoilers (blocksOf "[[!spoiler]]{s}(D)\n## B\n\n## C\n[[/spoiler]]{s}\n") `shouldBe` [("s", Just CutsSection)]
    it "refuses a spoiler that ends before its section does" $ do
      spoilers (blocksOf "[[!spoiler]]{s}(D)\n## B\n\nb\n[[/spoiler]]{s}\n\nmore text\n") `shouldBe` [("s", Just CutsSection)]
      spoilers (blocksOf "[[!spoiler]]{s}(D)\n## B\n\nb\n[[/spoiler]]{s}\n\n### Deeper\n") `shouldBe` [("s", Just CutsSection)]
    it "leaves the table of contents and the plain text as they are without the markers" $ do
      let marked = "# Page\n\n## A\n\na\n\n[[!spoiler]]{s}(Hidden part)\n## B\n\nb\n\n### B1\n\nc\n[[/spoiler]]{s}\n\n## C\n"
          plain = "# Page\n\n## A\n\na\n\n## B\n\nb\n\n### B1\n\nc\n\n## C\n"
      tableOfContents (blocksOf marked) `shouldBe` tableOfContents (blocksOf plain)
      T.replace "Hidden part " "" (bodyText marked) `shouldBe` bodyText plain

  describe "heading spoilers, ## [[!spoiler]] Question" $ do
    it "hides a heading's section under its heading, the marker out of the heading's text, with a name or without" $ do
      "## [[!spoiler]]{q1} What is *X*?\n\nAn answer.\n"
        `parses` [ Spoiler
                     (onHeading "q1" "[[!spoiler]]{q1}" 1)
                     [Heading 2 [("id", "what-is-x")] [Str "What is ", Emph [Str "X"], Str "?"], Para [Str "An answer."]]
                 ]
      -- Without a name, the heading's id is its name.
      "### [[!spoiler]] What is Y?\n\nAnother.\n"
        `parses` [Spoiler (onHeading "what-is-y" "[[!spoiler]]" 1) [Heading 3 [("id", "what-is-y")] [Str "What is Y?"], Para [Str "Another."]]]
    it "gives a heading spoiler the id the heading would have, a written one or a fresh one" $ do
      shape (blocksOf "## Intro\n\n## [[!spoiler]] Intro\n\nx\n") `shouldBe` ["h2 Intro", "intro-2 {h2 Intro, x}"]
      [attribute "id" attrs | Spoiler _ (Heading _ attrs _ : _) <- blocksOf "## Intro\n\n## [[!spoiler]] Intro\n"] `shouldBe` [Just "intro-2"]
      shape (blocksOf "## [[!spoiler]] Question {#faq-1}\n\nx\n") `shouldBe` ["faq-1 {h2 Question, x}"]
      shape (blocksOf "## [[!spoiler]]{named} Question {#faq-1}\n\nx\n") `shouldBe` ["named {h2 Question, x}"]
    it "ends the section before the next heading of the same or a higher level, at every level" $
      for_ [1 .. 5] $ \level -> do
        let hashes n = T.replicate n "#"
            same = hashes level <> " [[!spoiler]]{s} Q\n\na\n\n" <> hashes (level + 1) <> " Deeper\n\nb\n\n" <> hashes level <> " Next\n\nc\n"
        (level, shape (blocksOf same)) `shouldBe` (level, ["s {h" <> show level <> " Q, a, h" <> show (level + 1) <> " Deeper, b}", "h" <> show level <> " Next", "c"])
        when (level > 1) $
          (level, shape (blocksOf (hashes level <> " [[!spoiler]]{s} Q\n\na\n\n" <> hashes (level - 1) <> " Up\n")))
            `shouldBe` (level, ["s {h" <> show level <> " Q, a}", "h" <> show (level - 1) <> " Up"])
    it "ends the section at the end of the document, before the footnotes" $ do
      shape (blocksOf "# Page\n\n## [[!spoiler]]{s} Q\n\na\n\n- b\n") `shouldBe` ["h1 Page", "s {h2 Q, a, - {b}}"]
      case blocksOf "## [[!spoiler]]{s} Q\n\na[^1]\n\n[^1]: A note.\n" of
        [Spoiler _ [Heading {}, Para _], Footnotes _] -> pass
        other -> expectationFailure ("the footnotes in the section: " <> show other)
    it "ends the section at the end of the marker pair, div or quotation the heading is in" $ do
      shape (blocksOf "[[!spoiler]]{p}(P)\n## [[!spoiler]]{s} Q\n\na\n[[/spoiler]]{p}\n\n## Next\n") `shouldBe` ["p {s {h2 Q, a}}", "h2 Next"]
      spoilers (blocksOf "[[!spoiler]]{p}(P)\n## [[!spoiler]]{s} Q\n\na\n[[/spoiler]]{p}\n\n## Next\n") `shouldBe` [("p", Nothing), ("s", Nothing)]
      shape (blocksOf "[[!div]]{.note}\n## [[!spoiler]]{s} Q\n\na\n[[/div]]\n\nafter\n") `shouldBe` ["div {s {h2 Q, a}}", "after"]
      shape (blocksOf "> ## [[!spoiler]]{s} Q\n>\n> a\n\nafter\n") `shouldBe` ["> {s {h2 Q, a}}", "after"]
    it "nests, a deeper heading spoiler hiding its own subsection" $
      shape (blocksOf "## [[!spoiler]]{a} A\n\nx\n\n### [[!spoiler]]{b} B\n\ny\n\n### C\n\nz\n\n## D\n")
        `shouldBe` ["a {h2 A, x, b {h3 B, y}, h3 C, z}", "h2 D"]
    it "takes a marker pair in its section whole, and the pair that crosses the section's end cuts a section" $ do
      let crossing = blocksOf "## [[!spoiler]]{a} A\n\nx\n\n[[!spoiler]]{p}(P)\ny\n\n## B\n\nz\n[[/spoiler]]{p}\n"
      spoilers crossing `shouldBe` [("a", Nothing), ("p", Just CutsSection)]
      shape crossing `shouldBe` ["a {h2 A, x, p {y, h2 B, z}}"]
      let outer = blocksOf "[[!spoiler]]{p}(P)\nx\n\n## [[!spoiler]]{a} A\n\ny\n[[/spoiler]]{p}\n\nz\n"
      spoilers outer `shouldBe` [("p", Just CutsSection), ("a", Nothing)]
      shape outer `shouldBe` ["p {x, a {h2 A, y}}", "z"]
      -- A pair around a whole heading spoiler wraps its section, and must
      -- end where the section ends.
      spoilers (blocksOf "[[!spoiler]]{p}(P)\n## [[!spoiler]]{a} A\n\ny\n[[/spoiler]]{p}\n\nz\n") `shouldBe` [("p", Just CutsSection), ("a", Nothing)]
    it "leaves a marker that is not at the start of the heading's text, or not whole, or without its exclamation mark, a link" $ do
      let wikilink = Link [("class", "wikilink")] "!spoiler" "" [Str "!spoiler"]
      "## See [[!spoiler]] here" `parses` [Heading 2 [("id", "see-spoiler-here")] [Str "See ", wikilink, Str " here"]]
      "## [[!spoiler]]" `parses` [Heading 2 [("id", "spoiler")] [wikilink]]
      "## [[!spoiler]]{bad name} Q" `parses` [Heading 2 [("id", "spoilerbad-name-q")] [wikilink, Str "{bad name} Q"]]
      "## [[!spoiler]]{q}Q" `parses` [Heading 2 [("id", "spoilerqq")] [wikilink, Str "{q}Q"]]
      "## [[!spoiler]]{q}" `parses` [Heading 2 [("id", "spoilerq")] [wikilink, Str "{q}"]]
      "## *[[!spoiler]]* Q" `parses` [Heading 2 [("id", "spoiler-q")] [Emph [wikilink], Str " Q"]]
      "## \\[[!spoiler]] Q" `parses` [Heading 2 [("id", "spoiler-q")] [Str "[[!spoiler]] Q"]]
      "## [[spoiler]] Q" `parses` [Heading 2 [("id", "spoiler-q")] [Link [("class", "wikilink")] "spoiler" "" [Str "spoiler"], Str " Q"]]
      -- A setext heading's first line is a marker pair's line.
      spoilers (blocksOf "[[!spoiler]] Q\n---\n") `shouldBe` []
    it "reads the heading without the marker in the contents, the anchors, the plain text and the search text" $ do
      let marked = "# Page\n\n## [[!spoiler]]{a} What is X?\n\nx\n\n### [[!spoiler]] Why?\n\ny\n\n## After\n"
          plain = "# Page\n\n## What is X?\n\nx\n\n### Why?\n\ny\n\n## After\n"
      tableOfContents (blocksOf marked) `shouldBe` tableOfContents (blocksOf plain)
      anchors (blocksOf marked) `shouldBe` anchors (blocksOf plain)
      bodyText marked `shouldBe` bodyText plain
      [plainText xs | Spoiler _ (Heading _ _ xs : _) <- blocksOf marked] `shouldBe` ["What is X?"]
    it "gives the export where the marker is and where the heading's text starts" $
      (\(_, _, ms, _) -> ms) <$> parseWithAllMarkers "# T\n\n## [[!spoiler]]{q1} Q ||x||\n\n>  ### [[!spoiler]]\tR\n"
        `shouldBe` Right
          [ MarkerLine 3 4 (HeadingMarker 21)
          , MarkerLine 3 23 (InlineBars 3 26)
          , MarkerLine 5 8 (HeadingMarker 21)
          ]
    it "starts the spoiler on its heading's line, for the editor's preview" $
      map fst <$> parseWithLines "## [[!spoiler]] Q\n\na\n\nb\n\n## B\n" `shouldBe` Right [Just 1, Just 7]
    it "is its section as written on a slide, so the deck's breaks and titles stay" $ do
      let deck = deckOf (blocksOf "## [[!spoiler]] Q\n\na\n\n---\n\n## [[!spoiler]]{r} R\n\nb\n")
      isDeck (blocksOf "## [[!spoiler]] Q\n\na\n\n---\n\nb\n") `shouldBe` True
      [(plainText . (.text) <$> s.title, shape s.body) | s <- deck.slides] `shouldBe` [(Just "Q", ["a"]), (Just "R", ["b"])]

  describe "listings that scroll, {rows=N}" $ do
    let rowsOf source = [codeRows attrs | CodeBlock attrs _ _ <- blocksOf source]
        languageOf source = [lang | CodeBlock _ lang _ <- blocksOf source]
    it "reads rows after a language, or among attributes with a class" $ do
      rowsOf "```haskell {rows=20}\nx\n```" `shouldBe` [Just 20]
      languageOf "```haskell {rows=20}\nx\n```" `shouldBe` [Just "haskell"]
      rowsOf "```{.haskell rows=3}\nx\n```" `shouldBe` [Just 3]
      languageOf "```{.haskell rows=3}\nx\n```" `shouldBe` [Just "haskell"]
      rowsOf "``` {rows=5}\nx\n```" `shouldBe` [Just 5]
    it "ignores rows that are not a whole number above zero, and rows without a value" $ do
      for_ ["rows=0", "rows=-1", "rows=abc", "rows=2.5", "rows=\"\""] $ \attr ->
        (attr, rowsOf ("```haskell {" <> attr <> "}\nx\n```")) `shouldBe` (attr, [Nothing])
      rowsOf "```haskell {rows}\nx\n```" `shouldBe` [Nothing]
      rowsOf "```haskell\nx\n```" `shouldBe` [Nothing]

  describe "numbered listings, {.numbered}" $ do
    let numberedOf source = [(codeNumbered attrs, lang, codeRows attrs) | CodeBlock attrs lang _ <- blocksOf source]
    it "reads the class after a language, with rows, and among attributes alone" $ do
      numberedOf "```haskell {.numbered}\nx\n```" `shouldBe` [(True, Just "haskell", Nothing)]
      numberedOf "```haskell {.numbered rows=3}\nx\n```" `shouldBe` [(True, Just "haskell", Just 3)]
      numberedOf "```{.haskell .numbered rows=5}\nx\n```" `shouldBe` [(True, Just "haskell", Just 5)]
      numberedOf "```haskell\nx\n```" `shouldBe` [(False, Just "haskell", Nothing)]
    it "never takes the class for the language" $ do
      numberedOf "```{.numbered}\nx\n```" `shouldBe` [(True, Nothing, Nothing)]
      numberedOf "```{.numbered .haskell}\nx\n```" `shouldBe` [(True, Just "haskell", Nothing)]
      [() | Mermaid _ <- blocksOf "```{.numbered .mermaid}\ngraph TD\n```"] `shouldBe` [()]
    it "leaves the plain text and the search text as they are" $
      bodyText "```haskell {.numbered}\nmain = pure ()\n```" `shouldBe` bodyText "```haskell\nmain = pure ()\n```"
