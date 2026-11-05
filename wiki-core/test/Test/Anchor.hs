-- | Inline comments' anchors: a quote taken from a page's text and found
-- again as the page changes (found where it was, moved by an edit
-- elsewhere, told apart from a copy of it by its context, orphaned when it
-- is gone or cannot be told apart), and the rendered text quotes are taken
-- from. These run on both backends: the browser finds quotes too.
module Test.Anchor (spec) where

import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Core qualified as Core
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, elements, forAll, (===))
import Wiki.Core.Anchor
import Wiki.Core.Markdown (Options (..), defaultOptions, renderMarkdown)

-- | The anchor of the first occurrence of a phrase in a text.
quoting :: Text -> Text -> Anchor
quoting phrase text = case T.breakOn phrase text of
  (ahead, rest) | not (T.null rest) -> anchorAt text (Range (T.length ahead) (T.length ahead + T.length phrase))
  _ -> panic ("no " <> phrase <> " in " <> text)

-- | Where a phrase is found, as the text it covers.
foundText :: Text -> Located -> Maybe Text
foundText text = \case
  Found r -> Just (T.take (r.end - r.start) (T.drop r.start text))
  Orphaned -> Nothing

page :: Text
page = "The wiki keeps pages in spaces. Every page is written in Markdown, and every page has a history."

spec :: Spec
spec = describe "Anchor" $ do
  describe "anchorAt" $ do
    it "keeps the quote and up to 32 characters on each side" $ do
      let a = quoting "written in Markdown" page
      a.exact `shouldBe` "written in Markdown"
      a.prefix `shouldBe` " pages in spaces. Every page is "
      a.suffix `shouldBe` ", and every page has a history."

    it "keeps less context where the text starts or ends sooner" $ do
      let a = quoting "The wiki" page
      a.prefix `shouldBe` ""
      (quoting "a history." page).suffix `shouldBe` ""

  describe "locate" $ do
    it "finds a quote where it was" $ do
      let a = quoting "written in Markdown" page
      locate page a `shouldBe` Found (Range 46 65)
      foundText page (locate page a) `shouldBe` Just "written in Markdown"

    it "finds a quote the page has once wherever an edit elsewhere moved it" $ do
      let a = quoting "written in Markdown" page
          edited = "# Introduction\n\nThis wiki, unlike the old one, keeps pages in spaces. Each page is written in Markdown!"
      foundText edited (locate edited a) `shouldBe` Just "written in Markdown"

    it "tells a quote from a copy of it by its context" $ do
      let twice = "Click Save to save. Then click Save to publish."
      (anchorAt twice (Range 31 35)).exact `shouldBe` "Save"
      locate twice (anchorAt twice (Range 31 35)) `shouldBe` Found (Range 31 35)
      locate twice (anchorAt twice (Range 6 10)) `shouldBe` Found (Range 6 10)

    it "tells copies apart by context after the page around them changed" $ do
      let original = "Step one: run the tests. Step two: run the tests again."
          edited = "Before anything, step one: run the tests. Then step two: run the tests again, slowly."
          at text n = T.length (fst (fromMaybe (panic "too few") (atMay (T.breakOnAll "run the tests" text) n)))
          later = anchorAt original (Range (at original 1) (at original 1 + 13))
          first' = anchorAt original (Range (at original 0) (at original 0 + 13))
      locate edited later `shouldBe` Found (Range (at edited 1) (at edited 1 + 13))
      locate edited first' `shouldBe` Found (Range (at edited 0) (at edited 0 + 13))

    it "tells a copy at the very start of the text from one later on by the edge it shares" $ do
      let text = "Notes and more Notes"
      locate text (anchorAt text (Range 0 5)) `shouldBe` Found (Range 0 5)
      locate text (anchorAt text (Range 15 20)) `shouldBe` Found (Range 15 20)

    it "orphans a quote the page no longer has" $ do
      let a = quoting "written in Markdown" page
      locate "The wiki keeps pages in spaces. Every page is written in AsciiDoc." a `shouldBe` Orphaned

    it "orphans a quote the page has more than once with no context to choose between them" $ do
      let a = Anchor {exact = "page", prefix = "", suffix = ""}
      locate "page and page" (a {prefix = "xyz", suffix = "zyx"}) `shouldBe` Orphaned
      let copies = "A note. A note. A note."
      locate copies (Anchor {exact = "A note.", prefix = "xx", suffix = "yy"}) `shouldBe` Orphaned

    it "tells apart occurrences of a quote that overlap" $ do
      let text = " NoteNotenotenotex"
      locate text (anchorAt text Range {start = 10, end = 15}) `shouldBe` Found Range {start = 10, end = 15}
      locate text (anchorAt text Range {start = 6, end = 11}) `shouldBe` Found Range {start = 6, end = 11}

    it "orphans an empty quote" $
      locate page (Anchor "" "" "") `shouldBe` Orphaned

    -- Shorter than the context on either side, so that every anchor's
    -- context is the whole text around it, which no other place has.
    prop "finds any part of a short text taken as an anchor where it was taken, the text unchanged" $
      forAll textAndRange $ \(text, r) ->
        let a = anchorAt text r
         in locate text a === Found r

  describe "checkAnchor" $ do
    it "refuses a blank quote" $
      isLeft (checkAnchor (Anchor " \n " "a" "b")) `shouldBe` True
    it "refuses a quote longer than the limit" $
      isLeft (checkAnchor (Anchor (T.replicate (maxQuoteLength + 1) "x") "" "")) `shouldBe` True
    it "cuts the context to its length, keeping the side nearest the quote" $
      checkAnchor (Anchor "q" (T.replicate 40 "a" <> "b") ("c" <> T.replicate 40 "d"))
        `shouldBe` Right (Anchor "q" (T.replicate 31 "a" <> "b") ("c" <> T.replicate 31 "d"))

  describe "textFragment" $ do
    it "is the quote alone when the page has it once" $
      textFragment (oneBlock "The quick brown fox jumps.") (quoting "brown fox" "The quick brown fox jumps.") `shouldBe` ":~:text=brown%20fox"
    it "widens a quote to the words it starts and ends in" $
      textFragment (oneBlock "The quick brown fox jumps.") (quoting "ick brown fo" "The quick brown fox jumps.") `shouldBe` ":~:text=quick%20brown%20fox"
    it "adds the words before and after a quote the page has more than once" $ do
      let text = "One cat sat here. Then a cat sat there, by the door."
          again = anchorAt text (Range 25 32)
      textFragment (oneBlock text) again `shouldBe` ":~:text=here.%20Then%20a-,cat%20sat,-there%2C%20by%20the"
    it "counts a quote again in any case, as the browser does" $ do
      let text = "Note this. note that."
      textFragment (oneBlock text) (quoting "note" text) `shouldBe` ":~:text=Note%20this.-,note,-that."
    it "writes a long quote as its first and last words" $ do
      let text = "one two three four five six seven eight nine ten"
      textFragment (oneBlock text) (quoting "two three four five six seven eight nine ten" text) `shouldBe` ":~:text=two%20three%20four,eight%20nine%20ten"
    it "writes an orphaned quote as the anchor has it" $
      textFragment (oneBlock "Gone.") (Anchor "the old words" "" "") `shouldBe` ":~:text=the%20old%20words"

    it "takes a block's edge as a word's edge, at the start and the end of a paragraph" $ do
      let doc = blocksOf "# Title\n\nHello world.\n\nNext one."
      textFragment doc (quoting "Hello" doc.text) `shouldBe` ":~:text=Hello"
      textFragment doc (quoting "world." doc.text) `shouldBe` ":~:text=world."
      textFragment doc (quoting "Next" doc.text) `shouldBe` ":~:text=Next"
    it "writes a quote across two paragraphs as the first words of one and the last of the other" $ do
      let doc = blocksOf "# T\n\nOne two three.\n\nFour five six."
      textFragment doc (quoting "two three.Four five" doc.text) `shouldBe` ":~:text=two%20three.,Four%20five"
    it "takes the prefix and the suffix from the quote's own block" $ do
      let doc = blocksOf "# Cat\n\nA cat sat.\n\nThe cat sat."
      textFragment doc (quoting "cat sat" doc.text) `shouldBe` ":~:text=A-,cat%20sat,-."

    it "takes an island as a break the words around it do not cross" $ do
      -- "The formula $x$ is useful.", the formula an island.
      let doc = renderedBlocks ([HH.p_ [HH.text "The formula ", Core.widget (), HH.text " is useful."]] :: [HH.HTML () ()])
      doc.text `shouldBe` "The formula  is useful."
      textFragment doc (quoting "The formula  is useful." doc.text) `shouldBe` ":~:text=The%20formula,is%20useful."
      textFragment doc (quoting "formula " doc.text) `shouldBe` ":~:text=formula"
      textFragment doc (quoting " is use" doc.text) `shouldBe` ":~:text=is%20useful"
    it "widens a word only up to an island beside it" $ do
      let doc = renderedBlocks ([HH.p_ [HH.text "Area πr", Core.widget (), HH.text "ab today"]] :: [HH.HTML () ()])
      textFragment doc (quoting "π" doc.text) `shouldBe` ":~:text=%CF%80r"
      textFragment doc (quoting "b" doc.text) `shouldBe` ":~:text=ab"

    it "takes an image as a break, as an island" $ do
      let doc = blocksOf "See ![a dot](dot.png) here, and go."
      textFragment doc (quoting "See  here" doc.text) `shouldBe` ":~:text=See,here"
    it "takes a line break in a paragraph as a space, not a break" $ do
      let doc = blocksOf "# T\n\nOne two\nthree four."
      textFragment doc (quoting "two\nthree" doc.text) `shouldBe` ":~:text=two%20three"
    it "reads a footnote's number, inline code and a mention as the text they show" $ do
      let doc = blocksOf "A word[^n] in `code` by @ada.\n\n[^n]: The note."
      textFragment doc (quoting "word1 in code by @ada" doc.text) `shouldBe` ":~:text=word1%20in%20code%20by%20%40ada"
    it "takes a task's checkbox as a break" $ do
      let doc = blocksOf "- [x] done it"
      doc.text `shouldBe` " done it"
      textFragment doc (quoting "done" doc.text) `shouldBe` ":~:text=done"

  describe "renderedBlocks" $ do
    it "is the rendered text, with where each block starts and ends" $ do
      let doc = blocksOf "# Title\n\nA *b*.\n\n- one\n- two"
      doc.text `shouldBe` "TitleA b.onetwo"
      doc.breaks `shouldBe` [0, 5, 9, 12, 15]

  describe "encodeFragmentPart" $ do
    it "encodes as encodeURIComponent does, and the dash too" $
      encodeFragmentPart "a-b, c & d's (e)!*~._" `shouldBe` "a%2Db%2C%20c%20%26%20d's%20(e)!*~._"
    it "encodes each byte of a character outside ASCII" $
      encodeFragmentPart "zażółć ✓" `shouldBe` "za%C5%BC%C3%B3%C5%82%C4%87%20%E2%9C%93"
    it "encodes the fragment's own signs and the percent sign" $
      encodeFragmentPart "#:~:text=%" `shouldBe` "%23%3A~%3Atext%3D%25"

  describe "renderedText" $ do
    it "is the text of the rendered page, joined with nothing between blocks" $ do
      let doc = either (panic . show) identity (renderMarkdown defaultOptions "# Title\n\nA *b* [c](d).\n\n- one\n- two")
      renderedText doc `shouldBe` "TitleA b c.onetwo"

    it "has nothing of a code block's copy button, nor a break of its own" $ do
      let source = "Before.\n\n```haskell\nx = 1\n```\n\nAfter."
          copying = defaultOptions {copyButtons = True}
          doc = either (panic . show) identity (renderMarkdown copying source)
      renderedText doc `shouldBe` "Before.x = 1\nAfter."
      renderedText doc `shouldNotSatisfy` T.isInfixOf "Copy"
      renderedBlocks doc `shouldBe` blocksOf source

    it "leaves out what a child component (an island) draws" $ do
      let doc = [HH.p_ [HH.text "before "], Core.widget (), HH.p_ [HH.text "after"]] :: [HH.HTML () ()]
      renderedText doc `shouldBe` "before after"

-- | A text that is one block, as a text fragment reads it.
oneBlock :: Text -> BlockText
oneBlock text = BlockText {text, breaks = []}

-- | A page's text, with its blocks, as rendered.
blocksOf :: Text -> BlockText
blocksOf = renderedBlocks . either (panic . show) identity . renderMarkdown defaultOptions

-- | A text of words and a range of it that has something to read in it.
textAndRange :: Gen (Text, Range)
textAndRange = do
  n <- choose (1, 6)
  ws <- replicateM n (elements ["the", "page", "a", "wiki", "note", "Note", ".", ",", " ", "\n"])
  let text = T.concat ws <> "x"
  start <- choose (0, T.length text - 1)
  end <- choose (start + 1, T.length text)
  pure (text, Range start end)
