-- | The wiki's own blocks between marker lines (WP5.77 of docs/PLAN.md):
-- @[[!notes]]@, @[[!incremental]]@ and @[[!div]]@ … @[[/name]]@, and the
-- lines @[[!style]]@, @[[!pause]]@ and @[[!toc]]@, as the parser reads
-- them; the lines it shows in red; and @:::@, @. . .@ and the forms
-- without the exclamation mark, which are text and links now. Spoilers,
-- which share the markers, have "Test.Markdown.Spoiler". These run on
-- both backends.
module Test.Markdown.Markers (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Problems (Problem (..), parserProblems)
import Wiki.Core.Markdown.Problems qualified as Problems

parses :: Text -> [Block] -> Expectation
parses source expected = parseMarkdown source `shouldBe` Right expected

-- | A page's blocks; a page that does not parse fails the test.
blocksOf :: Text -> [Block]
blocksOf = either (panic . show) identity . parseMarkdown

-- | Every line of a page shown in red, nested ones too: as written, and
-- why.
errors :: [Block] -> [(Text, Text)]
errors = concatMap $ \case
  MarkerError written why -> [(written, why)]
  Div _ bs -> errors bs
  Spoiler _ bs -> errors bs
  BlockQuote bs -> errors bs
  List _ items -> concat [errors bs | ListItem _ bs <- items]
  _ -> []

wikilink :: Text -> [Inline] -> Inline
wikilink = \dest label -> Link [("class", "wikilink")] dest "" label

spec :: Spec
spec = describe "the wiki's own blocks, [[!name]] … [[/name]]" $ do
  describe "blocks between two markers" $ do
    it "reads notes and incremental as a box with their name as its class" $ do
      "[[!notes]]\nSay it.\n[[/notes]]" `parses` [Div [("class", "notes")] [Para [Str "Say it."]]]
      "[[!incremental]]\n- a\n- b\n[[/incremental]]"
        `parses` [Div [("class", "incremental")] [List BulletList [ListItem Nothing [Plain [Str "a"]], ListItem Nothing [Plain [Str "b"]]]]]
    it "reads a div with the attributes in its braces, and none without" $ do
      "[[!div]]{.summary}\nShort.\n[[/div]]" `parses` [Div [("class", "summary")] [Para [Str "Short."]]]
      "[[!div]]{#box .a .b key=value}\nIn.\n[[/div]]"
        `parses` [Div [("id", "box"), ("class", "a"), ("class", "b"), ("key", "value")] [Para [Str "In."]]]
      "[[!div]]\nIn.\n[[/div]]" `parses` [Div [] [Para [Str "In."]]]
      "[[!notes]]{.extra}\nx\n[[/notes]]" `parses` [Div [("class", "notes"), ("class", "extra")] [Para [Str "x"]]]
    it "tolerates indentation and spaces before the braces" $
      "   [[!div]] {.summary}\nx\n  [[/div]]  " `parses` [Div [("class", "summary")] [Para [Str "x"]]]
    it "holds any blocks, and nests, an end marker ending the innermost block" $
      "[[!notes]]\n[[!div]]{.a}\n```\ncode\n```\n[[/div]]\n> q\n[[/notes]]"
        `parses` [Div [("class", "notes")] [Div [("class", "a")] [CodeBlock [] Nothing "code\n"], BlockQuote [Para [Str "q"]]]]
    it "nests spoilers and other blocks inside one another" $
      case blocksOf "[[!spoiler]]{s}(S)\n[[!incremental]]\n- a\n[[/incremental]]\n[[/spoiler]]" of
        [Spoiler h [Div [("class", "incremental")] [List {}]]] -> h.problem `shouldBe` Nothing
        other -> expectationFailure (show other)
    it "is read in quotations and list items, and ends with them" $ do
      "> [[!div]]{.x}\n> a\n> [[/div]]" `parses` [BlockQuote [Div [("class", "x")] [Para [Str "a"]]]]
      "- [[!notes]]\n  a\n  [[/notes]]" `parses` [List BulletList [ListItem Nothing [Div [("class", "notes")] [Para [Str "a"]]]]]
    it "does not read an end marker in code" $
      "[[!div]]\n```\n[[/div]]\n```\n[[/div]]" `parses` [Div [] [CodeBlock [] Nothing "[[/div]]\n"]]
    it "reads an end marker on the line after indented code, which that line ends" $ do
      "[[!div]]{.summary}\n    code\n[[/div]]" `parses` [Div [("class", "summary")] [CodeBlock [] Nothing "code\n"]]
      "[[!notes]]\n    code\n\n[[/notes]]" `parses` [Div [("class", "notes")] [CodeBlock [] Nothing "code\n"]]
      "[[!incremental]]\n    code\n[[/incremental]]\nafter" `parses` [Div [("class", "incremental")] [CodeBlock [] Nothing "code\n"], Para [Str "after"]]
      "- [[!div]]{.x}\n      code\n  [[/div]]" `parses` [List BulletList [ListItem Nothing [Div [("class", "x")] [CodeBlock [] Nothing "code\n"]]]]
      "- [[!notes]]\n      code\n  [[/notes]]" `parses` [List BulletList [ListItem Nothing [Div [("class", "notes")] [CodeBlock [] Nothing "code\n"]]]]
      "- [[!incremental]]\n      code\n  [[/incremental]]" `parses` [List BulletList [ListItem Nothing [Div [("class", "incremental")] [CodeBlock [] Nothing "code\n"]]]]
      "[[!div]]\n    [[/div]]\n[[/div]]" `parses` [Div [] [CodeBlock [] Nothing "[[/div]]\n"]]
      "[[!div]]\n- a\n\n      code\n[[/div]]" `parses` [Div [] [List BulletList [ListItem Nothing [Para [Str "a"], CodeBlock [] Nothing "code\n"]]]]
    it "reads an end marker on the line after a block of HTML of one line" $
      "[[!div]]\n<pre>x</pre>\n[[/div]]" `parses` [Div [] [RawHtmlBlock "<pre>x</pre>\n"]]
    it "reads an end marker on the line that ends the list item of a block inside, which is not closed" $
      "[[!notes]]\n- [[!div]]\n  x\n[[/notes]]"
        `parses` [ Div
                     [("class", "notes")]
                     [ List
                         BulletList
                         [ ListItem
                             Nothing
                             [ MarkerError "[[!div]]" "the [[!div]] block is not closed: add [[/div]] after its last line"
                             , Div [("class", "spoiler-unclosed")] [Para [Str "x"]]
                             ]
                         ]
                     ]
                 ]
    it "does not read an end marker in a fenced code block not closed or a block of HTML" $ do
      "[[!div]]\n```\n[[/div]]\n"
        `parses` [ MarkerError "[[!div]]" "the [[!div]] block is not closed: add [[/div]] after its last line"
                 , Div [("class", "spoiler-unclosed")] [CodeBlock [] Nothing "[[/div]]\n"]
                 ]
      "[[!div]]\n- ```\n  [[/div]]\n  ```\n[[/div]]" `parses` [Div [] [List BulletList [ListItem Nothing [CodeBlock [] Nothing "[[/div]]\n"]]]]
      "[[!notes]]\n<div>\n[[/notes]]\n</div>\n\n[[/notes]]" `parses` [Div [("class", "notes")] [RawHtmlBlock "<div>\n[[/notes]]\n</div>\n"]]
    it "gives a div's written id to the page's ids, which no heading then takes" $
      blocksOf "[[!div]]{#intro}\nx\n[[/div]]\n\n# Intro\n"
        `shouldBe` [Div [("id", "intro")] [Para [Str "x"]], Heading 1 [("id", "intro-2")] [Str "Intro"]]

  describe "markers of one line" $ do
    it "reads a presentation's look, with braces or without, and no longer the old name" $ do
      "[[!style]]{theme=dark aspect=4:3}" `parses` [Div [("class", styleClass), ("theme", "dark"), ("aspect", "4:3")] []]
      "[[!style]]" `parses` [Div [("class", styleClass)] []]
      [why | MarkerError _ why <- blocksOf "[[!slides]]"] `shouldBe` ["“slides” is not a name of the wiki's blocks, which are spoiler, notes, incremental, div, style, pause, toc, in lower case"]
    it "reads a pause at the top level, in boxes, spoilers, quotations and list items" $ do
      "> a\n>\n> [[!pause]]" `parses` [BlockQuote [Para [Str "a"], Pause]]
      "a\n\n[[!pause]]\n\nb" `parses` [Para [Str "a"], Pause, Para [Str "b"]]
      "a\n[[!pause]]\nb" `parses` [Para [Str "a"], Pause, Para [Str "b"]]
      "[[!incremental]]\n[[!pause]]\n[[/incremental]]" `parses` [Div [("class", "incremental")] [Pause]]
      [() | Alert _ _ [Pause] <- blocksOf "> [!TIP]\n> [[!pause]]"] `shouldBe` [()]
      "- a\n\n  [[!pause]]\n" `parses` [List BulletList [ListItem Nothing [Para [Str "a"], Pause]]]
      [() | Spoiler _ [Pause] <- blocksOf "[[!spoiler]]{s}(S)\n[[!pause]]\n[[/spoiler]]"] `shouldBe` [()]
    it "reads a pause among a paragraph's words, or a list item's, at its place" $ do
      "First [[!pause]] then" `parses` [Para [Str "First ", InlinePause 1 7, Str " then"]]
      -- At the start of a line with words after it, a pause starts the
      -- paragraph's words: it is no marker line.
      "[[!pause]] then" `parses` [Para [InlinePause 1 1, Str " then"]]
      "- a [[!pause]] b" `parses` [List BulletList [ListItem Nothing [Plain [Str "a ", InlinePause 1 5, Str " b"]]]]
      "> x [[!pause]] y" `parses` [BlockQuote [Para [Str "x ", InlinePause 1 5, Str " y"]]]
    it "shows a pause among words where none is read in red: in emphasis, a link, a heading, a table, a footnote" $ do
      let why = "a pause is read only between the words of a paragraph or of a list item's text, not inside emphasis, a link, a heading, a table, a box's title or a footnote"
      "*a [[!pause]] b*" `parses` [Para [Emph [Str "a ", MisplacedPause 1 4 why, Str " b"]]]
      "[a [[!pause]] b](x)" `parses` [Para [Link [] "x" "" [Str "a ", MisplacedPause 1 4 why, Str " b"]]]
      [xs | Heading 2 _ xs <- blocksOf "## A [[!pause]] B"] `shouldBe` [[Str "A ", MisplacedPause 1 6 why, Str " B"]]
      [rows | Table _ _ rows <- blocksOf "| a |\n| - |\n| x [[!pause]] |\n"] `shouldBe` [[[[Str "x ", MisplacedPause 3 5 why]]]]
      [bs | Footnotes [Footnote _ _ bs] <- blocksOf "A[^1].\n\n[^1]: b [[!pause]] c\n"] `shouldBe` [[Para [Str "b ", MisplacedPause 3 9 why, Str " c"]]]
    it "shows a pause in a footnote in red" $
      [why | Footnotes [Footnote _ _ [MarkerError _ why]] <- blocksOf "A[^1].\n\n[^1]: [[!pause]]\n"]
        `shouldBe` ["a pause is not read in a footnote, which a presentation shows whole"]
    it "reads the table of contents' place" $ do
      "[[!toc]]" `parses` [TableOfContents]
      "> [[!toc]]" `parses` [BlockQuote [TableOfContents]]

  describe "what is no longer read" $ do
    it "leaves ::: and . . . the text they are" $ do
      "::: notes\nSay it.\n:::" `parses` [Para [Str "::: notes", SoftBreak, Str "Say it.", SoftBreak, Str ":::"]]
      "a\n\n. . .\n\nb" `parses` [Para [Str "a"], Para [Str ". . ."], Para [Str "b"]]
    it "leaves the names without the exclamation mark wiki links" $ do
      "[[notes]]" `parses` [Para [wikilink "notes" [Str "notes"]]]
      "[[pause]]" `parses` [Para [wikilink "pause" [Str "pause"]]]
      "[[toc]]" `parses` [Para [wikilink "toc" [Str "toc"]]]
      "[[TOC]]" `parses` [Para [wikilink "TOC" [Str "TOC"]]]
      "[[spoiler]]{a}(b)" `parses` [Para [wikilink "spoiler" [Str "spoiler"], Str "{a}(b)"]]
      "[[notes|Notes]]" `parses` [Para [wikilink "notes" [Str "Notes"]]]
    it "reads an end marker with no block of its name open as the text it is" $ do
      errors (blocksOf "[[/notes]]") `shouldBe` []
      [() | Para _ <- blocksOf "[[/notes]]"] `shouldBe` [()]
      [() | Para _ <- blocksOf "[[!div]]\na\n[[/div]]\n[[/div]]"] `shouldBe` [()]

  describe "lines shown in red" $ do
    let reasons source = map snd (errors (blocksOf source))
    it "shows a name the wiki does not have, and one not in lower case" $ do
      reasons "[[!unknown]]" `shouldBe` ["“unknown” is not a name of the wiki's blocks, which are spoiler, notes, incremental, div, style, pause, toc, in lower case"]
      reasons "[[!Notes]]\nx\n[[/notes]]" `shouldBe` ["“Notes” is not a name of the wiki's blocks, which are spoiler, notes, incremental, div, style, pause, toc, in lower case"]
    it "shows parentheses on a name that takes none, braces that are no attributes, and text after a marker" $ do
      reasons "[[!div]]{.a}(Title)" `shouldBe` ["only a spoiler takes a description in parentheses, as in [[!spoiler]]{name}(Description)"]
      reasons "[[!div]]{summary}" `shouldBe` ["the braces after [[!div]] hold attributes, #id, .class or key=value, as in [[!div]]{.summary}"]
      reasons "[[!notes]] more" `shouldBe` ["nothing may follow [[!notes]] and its braces on its line"]
      reasons "[[!toc]]{.x}" `shouldBe` ["nothing may follow [[!toc]] on its line"]
      reasons "[[!style]]{dark}" `shouldBe` ["the braces after [[!style]] hold a presentation's look, as in [[!style]]{theme=dark aspect=4:3}"]
      reasons "[[!div]]\nx\n[[/div]] more" `shouldBe` ["the [[!div]] block is not closed: add [[/div]] after its last line", "nothing may follow [[/div]] on its line"]
    it "shows an end marker that crosses another open block, which ends nothing" $ do
      let doc = blocksOf "[[!notes]]\n[[!div]]\nx\n[[/notes]]\n[[/div]]\n[[/notes]]"
      reasons "[[!notes]]\n[[!div]]\nx\n[[/notes]]\n[[/div]]\n[[/notes]]" `shouldBe` ["the innermost open block is [[!div]]: end it first with [[/div]]"]
      [() | [Div [("class", "notes")] [Div [] _]] <- [doc]] `shouldBe` [()]
      reasons "[[!div]]\n[[!spoiler]]{s}(S)\nx\n[[/div]]\n[[/spoiler]]\n[[/div]]" `shouldBe` ["the innermost open spoiler is “s”: end it first"]
      reasons "[[!notes]]\n> [[/notes]]\n[[/notes]]" `shouldBe` ["an end marker ends its block only outside the quotations and boxes inside the block"]
    it "shows a block never closed as its marker in red, then its blocks in red" $
      "Before\n\n[[!notes]]\nSay it.\n"
        `parses` [ Para [Str "Before"]
                 , MarkerError "[[!notes]]" "the [[!notes]] block is not closed: add [[/notes]] after its last line"
                 , Div [("class", "spoiler-unclosed")] [Para [Str "Say it."]]
                 ]
    it "gives the editor each red line as a problem of a block, a spoiler's as a spoiler's" $ do
      [(p.from, p.kind) | p <- parserProblems "[[!notes]]\nx\n\n[[!unknown]]\n\n[[!spoiler]]{x}\n"]
        `shouldBe` [(1, Problems.Marker), (4, Problems.Marker), (6, Problems.Spoiler)]

  describe "the markers the export reads"
    $ it "gives each marker line, with what it is"
    $ (\(_, _, ms, _) -> ms) <$> parseWithAllMarkers "[[!style]]\n[[!div]]{.a}\n[[!pause]]\n[[/div]]\n[[!toc]]\n[[!oops]]\n"
      `shouldBe` Right
        [ MarkerLine 1 1 SetsStyle
        , MarkerLine 2 1 (Opens [("class", "a")])
        , MarkerLine 3 1 Pauses
        , MarkerLine 4 1 (Ends 2)
        , MarkerLine 5 1 PlacesContents
        , MarkerLine 6 1 (Faulty "[[!oops]]" "“oops” is not a name of the wiki's blocks, which are spoiler, notes, incremental, div, style, pause, toc, in lower case")
        ]
