-- | Spoilers and scrolling listings (WP5.62 of docs/PLAN.md, issue #152),
-- as the parser reads them: inline spoilers, @||hidden||@; block spoilers
-- between @[[spoiler]]{name}(Description)@ and @[[/spoiler]]{name}@, with
-- the lines the page shows in red and the rule that a spoiler does not
-- cut across sections; and a fence's @rows=N@. These run on both
-- backends.
module Test.Markdown.Spoiler (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Toc (tableOfContents)
import Wiki.Core.Search (bodyText)

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
  SpoilerError written why -> [(written, why)]
  Spoiler _ bs -> errors bs
  BlockQuote bs -> errors bs
  _ -> []

-- | A spoiler's head as the parser makes it: right, on this line.
headOf :: Text -> [Inline] -> Text -> Int -> SpoilerHead
headOf name description marker line = SpoilerHead {name, description, marker, line, problem = Nothing}

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
      "[[spoiler]]{solution}(What the *answer* is)\n```haskell\nmain = pure ()\n```\n\n- a\n- b\n[[/spoiler]]{solution}\n"
        `parses` [ Spoiler
                     (headOf "solution" [Str "What the ", Emph [Str "answer"], Str " is"] "[[spoiler]]{solution}(What the *answer* is)" 1)
                     [CodeBlock [] (Just "haskell") "main = pure ()\n", List BulletList [ListItem Nothing [Plain [Str "a"]], ListItem Nothing [Plain [Str "b"]]]]
                 ]
    it "tolerates spaces between the parts, indentation, and parentheses in the description" $
      "   [[spoiler]] {hint} ( A hint (or two) )\nx\n[[/spoiler]]{hint}"
        `parses` [Spoiler (headOf "hint" [Str "A hint (or two)"] "[[spoiler]] {hint} ( A hint (or two) )" 1) [Para [Str "x"]]]
    it "nests, an end marker ending the innermost spoiler" $
      "[[spoiler]]{outer}(Outer)\na\n[[spoiler]]{inner}(Inner)\nb\n[[/spoiler]]{inner}\nc\n[[/spoiler]]{outer}\n"
        `parses` [ Spoiler
                     (headOf "outer" [Str "Outer"] "[[spoiler]]{outer}(Outer)" 1)
                     [Para [Str "a"], Spoiler (headOf "inner" [Str "Inner"] "[[spoiler]]{inner}(Inner)" 3) [Para [Str "b"]], Para [Str "c"]]
                 ]
    it "shows an end marker of another name in red, ends nothing, and the outer spoiler still ends" $ do
      let doc = blocksOf "[[spoiler]]{outer}(Outer)\na\n[[/spoiler]]{other}\nb\n[[/spoiler]]{outer}\n"
      spoilers doc `shouldBe` [("outer", Nothing)]
      errors doc `shouldBe` [("[[/spoiler]]{other}", "no open spoiler of this name")]
    it "says which spoiler is innermost when an end marker names an outer one" $ do
      let doc = blocksOf "[[spoiler]]{a}(A)\n[[spoiler]]{b}(B)\nx\n[[/spoiler]]{a}\n[[/spoiler]]{b}\n[[/spoiler]]{a}\n"
      spoilers doc `shouldBe` [("a", Nothing), ("b", Nothing)]
      map snd (errors doc) `shouldBe` ["the innermost open spoiler is “b”: end it first"]
      map snd (errors (blocksOf "text\n\n[[/spoiler]]{a}")) `shouldBe` ["no spoiler is open here"]
    it "shows a start marker without its name, with a bad name, or without its description in red, and opens nothing" $ do
      let reasons source = map snd (errors (blocksOf source))
      reasons "[[spoiler]](Description)\ntext" `shouldBe` ["a spoiler needs its name in braces after [[spoiler]], as in [[spoiler]]{name}(Description)"]
      reasons "[[spoiler]]{my name}(Description)" `shouldBe` ["a spoiler's name is one word of letters, digits, - and _"]
      reasons "[[spoiler]]{x}" `shouldBe` ["a spoiler needs a description in parentheses after its name, as in [[spoiler]]{name}(Description)"]
      reasons "[[spoiler]]{x}(  )" `shouldBe` ["a spoiler needs a description in its parentheses, as in [[spoiler]]{name}(Description)"]
      reasons "[[spoiler]]{x}(D) more" `shouldBe` ["nothing may follow the description's closing parenthesis"]
      reasons "[[spoiler]]{x} words (D)" `shouldBe` ["a spoiler needs a description in parentheses after its name, as in [[spoiler]]{name}(Description)"]
      spoilers (blocksOf "[[spoiler]](Description)\ntext") `shouldBe` []
      blocksOf "[[spoiler]](D)\ntext" `shouldBe` [SpoilerError "[[spoiler]](D)" "a spoiler needs its name in braces after [[spoiler]], as in [[spoiler]]{name}(Description)", Para [Str "text"]]
    it "shows an end marker without its name, or with more after it, in red" $ do
      let doc = blocksOf "[[spoiler]]{x}(D)\na\n[[/spoiler]]{x} more\n[[/spoiler]]\n"
      map snd (errors doc) `shouldBe` ["nothing may follow an end marker's name", "an end marker needs the spoiler's name in braces, as in [[/spoiler]]{name}"]
      spoilers doc `shouldBe` [("x", Just NotClosed)]
    it "makes a spoiler not closed by the end of the page hold everything after its marker" $
      "Before\n\n[[spoiler]]{x}(D)\na\n\n# Later\n\nb\n"
        `parses` [ Para [Str "Before"]
                 , Spoiler
                     (headOf "x" [Str "D"] "[[spoiler]]{x}(D)" 3) {problem = Just NotClosed}
                     [Para [Str "a"], Heading 1 [("id", "later")] [Str "Later"], Para [Str "b"]]
                 ]
    it "ends a spoiler not closed in a quotation or a list item with them" $ do
      blocksOf "> [[spoiler]]{x}(D)\n> a\n\nafter\n"
        `shouldBe` [BlockQuote [Spoiler (headOf "x" [Str "D"] "[[spoiler]]{x}(D)" 1) {problem = Just NotClosed} [Para [Str "a"]]], Para [Str "after"]]
      spoilers (blocksOf "- [[spoiler]]{x}(D)\n  a\n- next\n") `shouldBe` [("x", Just NotClosed)]
      spoilers (blocksOf "> [[spoiler]]{x}(D)\n> a\n> [[/spoiler]]{x}\n") `shouldBe` [("x", Nothing)]
    it "does not read an end marker in code" $
      "[[spoiler]]{x}(D)\n```\n[[/spoiler]]{x}\n```\n[[/spoiler]]{x}\n"
        `parses` [Spoiler (headOf "x" [Str "D"] "[[spoiler]]{x}(D)" 1) [CodeBlock [] Nothing "[[/spoiler]]{x}\n"]]
    it "leaves wiki links, [[toc]] and an escaped marker as they were" $ do
      "[[toc]]" `parses` [TableOfContents]
      "See [[spoiler]] here" `parses` [Para [Str "See ", Link [("class", "wikilink")] "spoiler" "" [Str "spoiler"], Str " here"]]
      "\\[[spoiler]]{x}(D)" `parses` [Para [Str "[[spoiler]]{x}(D)"]]
    it "keeps a spoiler's description and blocks in the plain text" $
      bodyText "[[spoiler]]{x}(The answer)\nForty-two.\n[[/spoiler]]{x}\n" `shouldBe` "The answer Forty-two."
    it "gives the export each marker line, with what it is" $
      (\(_, _, ms) -> ms) <$> parseWithAllMarkers "[[spoiler]]{x}(D)\n> [[/spoiler]]{y}\n[[/spoiler]]{x}\n"
        `shouldBe` Right
          [ SpoilerMarker 1 1 (Starts "x" "D")
          , SpoilerMarker 2 3 (Faulty "[[/spoiler]]{y}" "no open spoiler of this name")
          , SpoilerMarker 3 1 (Ends 1)
          ]

  describe "spoilers and sections" $ do
    it "accepts a spoiler within a section, without a heading" $
      spoilers (blocksOf "## A\n\n[[spoiler]]{x}(D)\ntext\n[[/spoiler]]{x}\n\nmore\n") `shouldBe` [("x", Nothing)]
    it "accepts a spoiler that wraps a whole section, its subsections and up to the next heading of its level" $ do
      let section = "## A\n\n[[spoiler]]{s}(D)\n## B\n\nb\n\n### B1\n\nc\n[[/spoiler]]{s}\n"
      spoilers (blocksOf (section <> "\n## C\n")) `shouldBe` [("s", Nothing)]
      spoilers (blocksOf (section <> "\n# Higher\n")) `shouldBe` [("s", Nothing)]
      spoilers (blocksOf section) `shouldBe` [("s", Nothing)]
      -- Two sections in a row, each in a spoiler of its own.
      spoilers (blocksOf (section <> "[[spoiler]]{t}(E)\n## C\n\nc\n[[/spoiler]]{t}\n")) `shouldBe` [("s", Nothing), ("t", Nothing)]
    it "accepts a spoiler that wraps a subsection inside one that wraps its section" $
      spoilers (blocksOf "[[spoiler]]{s}(D)\n## B\n\nb\n\n[[spoiler]]{t}(E)\n### B1\n\nc\n[[/spoiler]]{t}\n[[/spoiler]]{s}\n")
        `shouldBe` [("s", Nothing), ("t", Nothing)]
    it "refuses a heading after the spoiler's first block" $
      spoilers (blocksOf "[[spoiler]]{s}(D)\ntext\n\n## B\n[[/spoiler]]{s}\n") `shouldBe` [("s", Just CutsSection)]
    it "refuses a heading inside of the section's own level or higher" $
      spoilers (blocksOf "[[spoiler]]{s}(D)\n## B\n\n## C\n[[/spoiler]]{s}\n") `shouldBe` [("s", Just CutsSection)]
    it "refuses a spoiler that ends before its section does" $ do
      spoilers (blocksOf "[[spoiler]]{s}(D)\n## B\n\nb\n[[/spoiler]]{s}\n\nmore text\n") `shouldBe` [("s", Just CutsSection)]
      spoilers (blocksOf "[[spoiler]]{s}(D)\n## B\n\nb\n[[/spoiler]]{s}\n\n### Deeper\n") `shouldBe` [("s", Just CutsSection)]
    it "leaves the table of contents and the plain text as they are without the markers" $ do
      let marked = "# Page\n\n## A\n\na\n\n[[spoiler]]{s}(Hidden part)\n## B\n\nb\n\n### B1\n\nc\n[[/spoiler]]{s}\n\n## C\n"
          plain = "# Page\n\n## A\n\na\n\n## B\n\nb\n\n### B1\n\nc\n\n## C\n"
      tableOfContents (blocksOf marked) `shouldBe` tableOfContents (blocksOf plain)
      T.replace "Hidden part " "" (bodyText marked) `shouldBe` bodyText plain

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
