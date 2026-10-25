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
import Wiki.Core.Markdown (defaultOptions, renderMarkdown)

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

  describe "renderedText" $ do
    it "is the text of the rendered page, joined with nothing between blocks" $ do
      let doc = either (panic . show) identity (renderMarkdown defaultOptions "# Title\n\nA *b* [c](d).\n\n- one\n- two")
      renderedText doc `shouldBe` "TitleA b c.onetwo"

    it "leaves out what a child component (an island) draws" $ do
      let doc = [HH.p_ [HH.text "before "], Core.widget (), HH.p_ [HH.text "after"]] :: [HH.HTML () ()]
      renderedText doc `shouldBe` "before after"

-- | A text of words and a range of it that has something to read in it.
textAndRange :: Gen (Text, Range)
textAndRange = do
  n <- choose (1, 6)
  ws <- replicateM n (elements ["the", "page", "a", "wiki", "note", "Note", ".", ",", " ", "\n"])
  let text = T.concat ws <> "x"
  start <- choose (0, T.length text - 1)
  end <- choose (start + 1, T.length text)
  pure (text, Range start end)
