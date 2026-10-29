-- | Mentions, @\@login@: what the scanner takes for one, and where the
-- parser looks for them (WP4.13 of docs/PLAN.md).
module Test.Markdown.Mention (spec) where

import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Mention

parses :: Text -> [Block] -> Expectation
parses source expected = parseMarkdown source `shouldBe` Right expected

spec :: Spec
spec = describe "Markdown mentions" $ do
  describe "splitMentions" $ do
    it "finds a login after an @ that starts a word" $ do
      splitMentions "@ada" `shouldBe` [Right "ada"]
      splitMentions "Ask @ada, or (@grace)." `shouldBe` [Left "Ask ", Right "ada", Left ", or (", Right "grace", Left ")."]
    it "takes dots, hyphens and underscores inside a login, not at its end" $ do
      splitMentions "thanks @ada.lovelace." `shouldBe` [Left "thanks ", Right "ada.lovelace", Left "."]
      splitMentions "@grace-h- and @x_" `shouldBe` [Right "grace-h", Left "- and ", Right "x_"]
    it "takes letters of any script" $
      splitMentions "@zoë and @łucja" `shouldBe` [Right "zoë", Left " and ", Right "łucja"]
    it "leaves an @ inside a word, an address or a path alone" $ do
      splitMentions "ada@example" `shouldBe` [Left "ada@example"]
      splitMentions "a.b@c d+e@f /x/@g @@h" `shouldBe` [Left "a.b@c d+e@f /x/@g @@h"]
    it "leaves an @ with no login after it, or another @ right after the login, alone" $ do
      splitMentions "@ and @. and @-" `shouldBe` [Left "@ and @. and @-"]
      splitMentions "@ada@example.org" `shouldBe` [Left "@ada@example.org"]
    it "does not mention twice in a row without a break" $
      splitMentions "@ada@grace" `shouldBe` [Left "@ada@grace"]
    prop "gives the text back when its pieces are written out" $
      forAll (T.pack <$> listOf (elements "ab.@-_ (/+é")) $ \t ->
        mconcat (map (either identity ("@" <>)) (splitMentions t)) === t
    prop "never gives an empty or a split text" $
      forAll (T.pack <$> listOf (elements "ab.@- ")) $ \t ->
        let pieces = splitMentions t
         in all (either (not . T.null) (not . T.null)) pieces && not (any (\(a, b) -> isLeft a && isLeft b) (zip pieces (drop 1 pieces)))

  describe "mentionsWhole" $ do
    it "holds for a login a mention reads whole" $
      map mentionsWhole ["ada", "ada.lovelace", "grace-h", "x_", "zoë", "Łukasz"] `shouldBe` replicate 6 True
    it "fails for a login a mention reads less of, or not at all" $
      map mentionsWhole ["anna-", "ada.", "ada lovelace", "ada@example.org", "a+b", "", "@ada"] `shouldBe` replicate 7 False
    it "fails for a login Markdown reads as something else around a shorter login" $
      map mentionsWhole ["_anna_", "anna*", "*anna*", "anna`x`"] `shouldBe` replicate 4 False
    it "holds for a login with a dot or an underscore inside" $
      map mentionsWhole ["a.b", "a_b", "anna"] `shouldBe` replicate 3 True
  describe "the parser" $ do
    it "makes a mention in a paragraph, in emphasis and in a heading" $ do
      "Hi @ada!" `parses` [Para [Str "Hi ", Mention "ada", Str "!"]]
      "*see @ada*" `parses` [Para [Emph [Str "see ", Mention "ada"]]]
      "# For @ada" `parses` [Heading 1 [("id", "for-ada")] [Str "For ", Mention "ada"]]
    it "makes none in code, in a link's text or in a code block" $ do
      "`@ada`" `parses` [Para [Code [] "@ada"]]
      "[@ada](x)" `parses` [Para [Link [] "x" "" [Str "@ada"]]]
      "```\n@ada\n```" `parses` [CodeBlock [] Nothing "@ada\n"]
    it "leaves an e-mail address the autolink it is" $
      "Write to ada@example.org." `parses` [Para [Str "Write to ", Link [] "mailto:ada@example.org" "" [Str "ada@example.org"], Str "."]]
    it "finds mentions in lists, quotes and tables" $
      mentions <$> parseMarkdown "- @ada\n\n> @grace\n\n| a |\n|---|\n| @rita |"
        `shouldBe` Right (Set.fromList ["ada", "grace", "rita"])
    it "counts no mention in a link" $
      mentions <$> parseMarkdown "[@ada](x) and @grace" `shouldBe` Right (Set.fromList ["grace"])
    it "reads a mention's text as written" $
      plainText [Str "Hi ", Mention "ada"] `shouldBe` "Hi @ada"
