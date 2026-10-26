-- | Headings' ids, @[[toc]]@ and the table of contents made from a page's
-- headings (WP4.15 of docs/PLAN.md). These run on both backends: the
-- browser parses and lists as the server does.
module Test.Markdown.Toc (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf, (===))
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Toc
import Wiki.Core.Slug (freshName, headingSlug)

parsed :: Text -> [Block]
parsed = either (panic . show) identity . parseMarkdown

-- | The ids of a document's headings, at any depth, in document order.
ids :: Text -> [Text]
ids = concatMap headingIds . parsed
  where
    headingIds = \case
      Heading _ attrs _ -> maybeToList (attribute "id" attrs)
      BlockQuote bs -> concatMap headingIds bs
      List _ items -> concat [concatMap headingIds bs | ListItem _ bs <- items]
      Div _ bs -> concatMap headingIds bs
      _ -> []

entry :: Text -> Int -> Text -> [Entry] -> Entry
entry i level text below = Entry {id = i, level, text, below}

spec :: Spec
spec = describe "Markdown.Toc" $ do
  describe "headingSlug" $ do
    it "lowercases and makes blanks dashes" $
      headingSlug "Getting Started" `shouldBe` "getting-started"
    it "drops punctuation and symbols" $
      headingSlug "What's new? (2026, v2.0!)" `shouldBe` "whats-new-2026-v20"
    it "collapses and trims dashes" $
      headingSlug "  A – B -- C  " `shouldBe` "a-b-c"
    it "keeps letters of every alphabet, diacritics and all" $ do
      headingSlug "Zażółć gęślą jaźń" `shouldBe` "zażółć-gęślą-jaźń"
      headingSlug "Привет мир" `shouldBe` "привет-мир"
      headingSlug "日本語の見出し" `shouldBe` "日本語の見出し"
    it "keeps combining marks and underscores" $
      headingSlug "e\x301t\x301_e" `shouldBe` "e\x301t\x301_e"
    it "drops emoji" $
      headingSlug "Launch 🚀 day" `shouldBe` "launch-day"
    it "is section for a heading with nothing of that" $ do
      headingSlug "" `shouldBe` "section"
      headingSlug "?!" `shouldBe` "section"
    prop "is never empty, and never starts or ends with a dash" $
      forAll (T.pack <$> listOf (elements "aZ ż-_!?. 7\x301")) $ \t ->
        let s = headingSlug t
         in (T.null s, "-" `T.isPrefixOf` s, "-" `T.isSuffixOf` s, "--" `T.isInfixOf` s) === (False, False, False, False)
    prop "is its own slug" $
      forAll (T.pack <$> listOf (elements "aZ ż-_!?. 7")) $ \t ->
        headingSlug (headingSlug t) === headingSlug t

  describe "freshName" $ do
    it "keeps a free name" $
      freshName (const False) "intro" `shouldBe` "intro"
    it "counts from 2" $
      freshName (`elem` ["intro"]) "intro" `shouldBe` "intro-2"
    it "skips what is taken" $
      freshName (`elem` ["intro", "intro-2", "intro-3"]) "intro" `shouldBe` "intro-4"

  describe "heading ids" $ do
    it "come from the heading's text" $
      ids "# Getting started\n\n## Zażółć gęślą" `shouldBe` ["getting-started", "zażółć-gęślą"]
    it "are made unique with -2, -3, … in document order" $
      ids "# A\n\n## A\n\n### A\n\n# B" `shouldBe` ["a", "a-2", "a-3", "b"]
    it "keep an id written in braces" $
      ids "# Intro {#start}\n\n# Start" `shouldBe` ["start", "start-2"]
    it "stay clear of an id written in braces later in the page" $
      ids "# Setup\n\n# Install {#setup}" `shouldBe` ["setup-2", "setup"]
    it "stay clear of a fenced div's id" $
      ids "# Box\n\n::: {#box}\nInside.\n:::" `shouldBe` ["box-2"]
    it "are given to headings inside other blocks too, in document order" $
      ids "# A\n\n> # A\n\n- # A" `shouldBe` ["a", "a-2", "a-3"]
    it "are made from the text without its markup" $
      ids "# The *big* `run` [now](x)" `shouldBe` ["the-big-run-now"]
    it "are the same for the same source, wherever it is parsed" $
      parsed "# A\n\n# A" `shouldBe` parsed "# A\n\n# A"

  describe "[[toc]]" $ do
    it "on a line of its own is the table of contents" $
      parsed "# A\n\n[[toc]]\n\nText." `shouldBe` [Heading 1 [("id", "a")] [Str "A"], TableOfContents, Para [Str "Text."]]
    it "may be written in capitals" $
      parsed "[[TOC]]" `shouldBe` [TableOfContents]
    it "among other text is a wiki link to a page named toc" $
      parsed "See [[toc]] here." `shouldBe` [Para [Str "See ", Link [("class", "wikilink")] "toc" "" [Str "toc"], Str " here."]]
    it "with another label is a link" $
      parsed "[[toc|the contents]]" `shouldBe` [Para [Link [("class", "wikilink")] "toc" "" [Str "the contents"]]]
    it "in code is code" $
      parsed "`[[toc]]`" `shouldBe` [Para [Code [] "[[toc]]"]]
    it "is found by hasContentsMarker" $ do
      hasContentsMarker (parsed "# A\n\n[[toc]]") `shouldBe` True
      hasContentsMarker (parsed "# A\n\nSee [[toc]].") `shouldBe` False

  describe "tableOfContents" $ do
    it "nests headings by level" $
      tableOfContents (parsed "# A\n\n## B\n\n### C\n\n## D\n\n# E")
        `shouldBe` [ entry "a" 1 "A" [entry "b" 2 "B" [entry "c" 3 "C" []], entry "d" 2 "D" []]
                   , entry "e" 1 "E" []
                   ]
    it "nests a skipped level one level down" $
      tableOfContents (parsed "## A\n\n#### B\n\n### C")
        `shouldBe` [entry "a" 2 "A" [entry "b" 4 "B" [], entry "c" 3 "C" []]]
    it "lists headings that start deeper than they go on side by side" $
      tableOfContents (parsed "### A\n\n# B\n\n## C")
        `shouldBe` [entry "a" 3 "A" [], entry "b" 1 "B" [entry "c" 2 "C" []]]
    it "lists the headings with their ids, made unique" $
      map (\e -> e.id) (tableOfContents (parsed "# Notes\n\n# Notes {#n}\n\n# Notes")) `shouldBe` ["notes", "n", "notes-2"]
    it "leaves out headings inside other blocks" $
      tableOfContents (parsed "# A\n\n> ## Quoted\n\n- ## Listed") `shouldBe` [entry "a" 1 "A" []]
    it "counts every heading" $
      entryCount (tableOfContents (parsed "# A\n\n## B\n\n### C\n\n# D")) `shouldBe` 4

  describe "contentsPanel" $ do
    it "is shown for three headings or more" $
      contentsPanel (parsed "# A\n\n## B\n\n## C") `shouldSatisfy` isJust
    it "is not shown for fewer" $
      contentsPanel (parsed "# A\n\n## B\n\nText.") `shouldBe` Nothing
    it "is not shown when the page places the list itself" $
      contentsPanel (parsed "[[toc]]\n\n# A\n\n## B\n\n## C") `shouldBe` Nothing
    it "lists what [[toc]] would" $
      contentsPanel (parsed "# A\n\n## B\n\n## C") `shouldBe` Just (tableOfContents (parsed "# A\n\n## B\n\n## C"))

  describe "slugs and lists" $
    prop "every heading's id is unique, but for ids written out twice" $
      forAll (listOf heading) $ \hs ->
        let found = ids (T.intercalate "\n\n" ("# X {#a-2}" : "# Y {#b-3}" : hs))
         in length found === length (ordNub found)
  where
    heading :: Gen Text
    heading = elements ["# A", "## A", "# B", "# B", "# B-3", "### A b", "# a-b", "# Ząb", "# !"]
