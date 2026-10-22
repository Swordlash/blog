module Test.Slug (spec) where

import Data.Aeson (Value (String), eitherDecode, toJSON)
import Protolude
import Test.Gen (genSlug, genText)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
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

  describe "slugify" $ do
    -- Test names stay ASCII: hspec prints them in the locale's encoding,
    -- which need not be UTF-8.
    let slugifies title slug = it ("gives " <> toS slug) $ slugText <$> slugify title `shouldBe` Just slug
    describe "folds Polish letters to ASCII" $ do
      slugifies "Zażółć gęślą jaźń" "zazolc-gesla-jazn"
      slugifies "Łódź" "lodz"
      slugifies "ŻÓŁW I ŹRÓDŁO" "zolw-i-zrodlo"
      slugifies "Źródła i materiały" "zrodla-i-materialy"
      slugifies "Ćwiczenia, część 2" "cwiczenia-czesc-2"
    describe "folds other European letters" $ do
      slugifies "Crème brûlée" "creme-brulee"
      slugifies "Straße" "strasse"
      slugifies "Ærøskøbing" "aeroskobing"
      slugifies "Dvořák" "dvorak"
    it "drops combining accents, so decomposed text folds as composed text does" $
      slugText <$> slugify "Cafe\x0301 Zo\x0301\x0142w" `shouldBe` Just "cafe-zolw"
    describe "lowercases and turns everything else into single dashes" $ do
      slugifies "Release Notes" "release-notes"
      slugifies "  Release notes, v2.0!  " "release-notes-v2-0"
      slugifies "a -- b / c_d" "a-b-c-d"
      slugifies "C++ & Haskell" "c-haskell"
    it "drops apostrophes inside words" $ do
      slugText <$> slugify "Mateusz's notes" `shouldBe` Just "mateuszs-notes"
      slugText <$> slugify "Mateusz\x2019s notes" `shouldBe` Just "mateuszs-notes"
    it "keeps what folds out of a title in another script" $
      slugText <$> slugify "Привет, world" `shouldBe` Just "world"
    describe "gives nothing when nothing is left, for"
      $ for_
        [ ("the empty title", "")
        , ("spaces", "   ")
        , ("punctuation", "!?!")
        , ("dashes", "---")
        , ("Cyrillic", "Привет")
        , ("Japanese", "日本語")
        ]
      $ \(name, t) -> it name $ slugify t `shouldBe` Nothing
    prop "leaves a slug as it is" $
      forAll genSlug $
        \s -> slugify (slugText s) === Just s
    prop "is idempotent" $
      forAll genText $
        \t -> (slugify . slugText =<< slugify t) === slugify t

  describe "freshSlug" $ do
    let s t = either (panic . show) identity (mkSlug t)
    it "keeps a free slug" $
      freshSlug (const False) (s "notes") `shouldBe` s "notes"
    it "numbers a taken one from 2" $
      freshSlug (== s "notes") (s "notes") `shouldBe` s "notes-2"
    it "skips the numbers that are taken too" $
      freshSlug (`elem` map s ["notes", "notes-2", "notes-3"]) (s "notes") `shouldBe` s "notes-4"

  describe "JSON" $ do
    it "writes a slug as its text" $
      toJSON <$> mkSlug "release-notes" `shouldBe` Right (String "release-notes")
    it "reads a slug back" $
      rightToMaybe (eitherDecode "\"release-notes\"") `shouldBe` rightToMaybe (mkSlug "release-notes")
    it "refuses text that breaks the rules" $
      (eitherDecode "\"Release Notes\"" :: Either [Char] Slug) `shouldSatisfy` isLeft
