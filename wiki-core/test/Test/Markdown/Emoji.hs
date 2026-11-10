-- | The search of emoji names the editor's list and the toolbar's menu
-- show ("Wiki.Core.Markdown.Emoji"), and that every name it can offer is
-- one the wiki's Markdown shows as an emoji. These run on both backends:
-- the browser searches too.
module Test.Markdown.Emoji (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast (Block (..), Inline (..), parseMarkdown)
import Wiki.Core.Markdown.Emoji

names :: Text -> [Text]
names = map fst . emojiMatches

spec :: Spec
spec = describe "Markdown.Emoji" $ do
  describe "emojiMatches" $ do
    it "offers the name typed first, then the names that start with it, then those with a word that does" $ do
      take 3 (names "heart") `shouldBe` ["heart", "heart_eyes", "heart_eyes_cat"]
      let found = names "heart"
          firstInside = length (takeWhile ("heart" `T.isPrefixOf`) found)
      found `shouldSatisfy` elem "broken_heart"
      drop firstInside found `shouldSatisfy` all (not . ("heart" `T.isPrefixOf`))
      all ("heart" `T.isPrefixOf`) (take firstInside found) `shouldBe` True

    it "keeps each group in the list's order" $ do
      let (starting, inside) = break (not . ("smil" `T.isPrefixOf`)) (names "smil")
          inOrder found = found `shouldBe` filter (`elem` found) (map fst allEmoji)
      take 2 starting `shouldBe` ["smiley", "smile"]
      inside `shouldSatisfy` elem "slightly_smiling_face"
      inOrder starting
      inOrder inside

    it "finds the names with + and -" $ do
      take 1 (names "+1") `shouldBe` ["+1"]
      take 1 (names "-1") `shouldBe` ["-1"]
      names "t-r" `shouldBe` ["t-rex"]
      names "rex" `shouldSatisfy` elem "t-rex"

    it "does not find letters inside a word of a name" $ do
      names "30" `shouldBe` []
      names "ada" `shouldNotSatisfy` elem "tada"

    it "offers at most emojiLimit" $ do
      length (names "s") `shouldBe` emojiLimit
      length (names "a") `shouldBe` emojiLimit

    it "reads capitals as small letters and a space as an underscore" $ do
      names "Check Mark" `shouldBe` names "check_mark"
      names "check mark" `shouldSatisfy` elem "white_check_mark"
      take 1 (names "TADA") `shouldBe` ["tada"]

    it "offers the common ones before a letter is typed" $ do
      emojiMatches "" `shouldBe` commonEmoji
      emojiMatches "  " `shouldBe` commonEmoji
      map fst commonEmoji `shouldSatisfy` \ns -> "tada" `elem` ns && "+1" `elem` ns
      length commonEmoji `shouldSatisfy` (<= emojiLimit)

  describe "the names it offers" $ do
    it "are each an emoji in the wiki's Markdown, :name:" $
      for_ (allEmoji <> commonEmoji) $ \(name, emoji) ->
        (name, parseMarkdown (":" <> name <> ":")) `shouldBe` (name, Right [Para [Emoji name emoji]])

    it "are each offered when typed in full, first" $
      for_ allEmoji $ \(name, emoji) ->
        (name, take 1 (emojiMatches name)) `shouldBe` (name, [(name, emoji)])

    it "are made of the characters the editor's list reads as a name's" $
      for_ allEmoji $ \(name, _) ->
        (name, T.all isEmojiNameChar name && not (T.null name)) `shouldBe` (name, True)
