module Test.Slug (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Slug

spec :: Spec
spec = describe "Slug" $ do
  describe "mkSlug accepts" $
    for_ ["a", "7", "onboarding", "release-notes", "v2-0-1", "2026"] $ \t ->
      it (toS t) $ slugText <$> mkSlug t `shouldBe` Right t

  describe "mkSlug rejects" $ do
    it "the empty string" $
      mkSlug "" `shouldBe` Left SlugEmpty
    it "uppercase letters" $
      mkSlug "Onboarding" `shouldBe` Left (SlugBadCharacter 'O')
    it "spaces" $
      mkSlug "release notes" `shouldBe` Left (SlugBadCharacter ' ')
    it "letters outside ASCII" $
      mkSlug "zażółć" `shouldBe` Left (SlugBadCharacter 'ż')
    it "punctuation" $
      mkSlug "a_b" `shouldBe` Left (SlugBadCharacter '_')
    it "a slash, so a slug is one segment of a path" $
      mkSlug "space/page" `shouldBe` Left (SlugBadCharacter '/')
    it "a leading dash" $
      mkSlug "-draft" `shouldBe` Left SlugEdgeDash
    it "a trailing dash" $
      mkSlug "draft-" `shouldBe` Left SlugEdgeDash
    it "a lone dash" $
      mkSlug "-" `shouldBe` Left SlugEdgeDash
    it "a double dash" $
      mkSlug "release--notes" `shouldBe` Left SlugDoubleDash

  it "reports the first character that breaks the rules" $
    mkSlug "a B?" `shouldBe` Left (SlugBadCharacter ' ')
