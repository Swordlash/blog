-- | A space's profile: its icon, its description and its home page, as
-- "Wiki.Core.Space" checks them, and where a space sits among others.
module Test.Space (spec) where

import Data.Aeson (decode, encode, object, toJSON, (.=))
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Gen (genIcon)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space

space :: Text -> Text -> Maybe Text -> Space
space i name parent =
  Space
    { id = SpaceId i
    , name
    , slug = either (panic . show) identity (mkSlug i)
    , parent = SpaceId <$> parent
    , public = False
    , mathMacros = ""
    , createdAt = UTCTime (fromGregorian 2026 1 1) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    }

profile :: Text -> Maybe Icon -> Maybe PageId -> SpaceProfile
profile description icon homePage = SpaceProfile {description, icon, homePage}

none :: SpaceProfile
none = profile "" Nothing Nothing

withIcon :: Icon -> Space -> Space
withIcon i s = withProfile (profile s.description (Just i) s.homePage) s

home, other :: PageId
home = PageId "home"
other = PageId "elsewhere"

spec :: Spec
spec = describe "Wiki.Core.Space" $ do
  describe "Icon" $ do
    prop "reads back what it writes" $ forAll genIcon $ \i -> decode (encode i) === Just i
    it "is written as an object with a field per kind" $ do
      toJSON (IconEmoji "📘") `shouldBe` object ["emoji" .= ("📘" :: Text)]
      toJSON (IconColour "teal") `shouldBe` object ["colour" .= ("teal" :: Text)]
      toJSON (IconImage (BlobId "b1") "image/png") `shouldBe` object ["image" .= ("b1" :: Text), "mediaType" .= ("image/png" :: Text)]
    it "refuses an object of two kinds" $
      (decode "{\"emoji\":\"x\",\"colour\":\"teal\"}" :: Maybe Icon) `shouldBe` Nothing

  describe "defaultColour" $ do
    it "is one of the colours, the same every time for an id" $ do
      defaultColour (SpaceId "space-1") `shouldSatisfy` (`elem` iconColours)
      defaultColour (SpaceId "space-1") `shouldBe` defaultColour (SpaceId "space-1")
    it "differs for some ids" $
      length (ordNub (map (\n -> defaultColour (SpaceId ("space-" <> show n))) [1 :: Int .. 20])) `shouldSatisfy` (> 3)
    it "is what a space without a colour of its own is drawn in" $ do
      colourOf (space "a" "A" Nothing) `shouldBe` defaultColour (SpaceId "a")
      colourOf (withIcon (IconColour "red") (space "a" "A" Nothing)) `shouldBe` "red"
      colourOf (withIcon (IconColour "chartreuse") (space "a" "A" Nothing)) `shouldBe` defaultColour (SpaceId "a")

  describe "iconLetter" $ do
    it "is the name's first letter, upper-cased" $ iconLetter "docs" `shouldBe` "D"
    it "skips what is not a letter or a digit" $ iconLetter "  “Team”" `shouldBe` "T"
    it "is the first character of a name without letters" $ iconLetter "!!" `shouldBe` "!"
    it "is a question mark for a blank name" $ iconLetter " " `shouldBe` "?"

  describe "checkIconUpload" $ do
    it "takes the images a browser shows, by their media type" $ do
      checkIconUpload "image/png" 100 `shouldBe` Right "image/png"
      checkIconUpload " IMAGE/JPEG; q=1" 100 `shouldBe` Right "image/jpeg"
    it "refuses SVG, which may run scripts, and anything else" $ do
      checkIconUpload "image/svg+xml" 100 `shouldSatisfy` isLeft
      checkIconUpload "text/html" 100 `shouldSatisfy` isLeft
    it "refuses an empty file and one over the limit" $ do
      checkIconUpload "image/png" 0 `shouldSatisfy` isLeft
      checkIconUpload "image/png" (maxIconSize + 1) `shouldSatisfy` isLeft
      checkIconUpload "image/png" maxIconSize `shouldBe` Right "image/png"

  describe "checkProfile" $ do
    let s = space "docs" "Docs" Nothing
        checked = checkProfile s [home]
    it "trims the description" $
      checked (profile "  How we work \n" Nothing Nothing) `shouldBe` Right (profile "How we work" Nothing Nothing)
    it "refuses a description too long" $
      checked (profile (T.replicate (maxDescriptionLength + 1) "x") Nothing Nothing) `shouldSatisfy` isLeft
    it "takes a short emoji, trimmed" $
      checked (profile "" (Just (IconEmoji " 📘 ")) Nothing) `shouldBe` Right (profile "" (Just (IconEmoji "📘")) Nothing)
    it "refuses a blank emoji, one with spaces in it, and a long one" $ do
      checked (profile "" (Just (IconEmoji "  ")) Nothing) `shouldSatisfy` isLeft
      checked (profile "" (Just (IconEmoji "a b")) Nothing) `shouldSatisfy` isLeft
      checked (profile "" (Just (IconEmoji (T.replicate 17 "x"))) Nothing) `shouldSatisfy` isLeft
    it "takes a colour of the palette and refuses any other" $ do
      checked (profile "" (Just (IconColour "teal")) Nothing) `shouldBe` Right (profile "" (Just (IconColour "teal")) Nothing)
      checked (profile "" (Just (IconColour "#ff0000")) Nothing) `shouldSatisfy` isLeft
    it "keeps the image the space has, and refuses one it has not" $ do
      let image = IconImage (BlobId "b1") "image/png"
      checkProfile (withIcon image s) [] (profile "" (Just image) Nothing) `shouldBe` Right (profile "" (Just image) Nothing)
      checked (profile "" (Just image) Nothing) `shouldSatisfy` isLeft
    it "takes one of the space's pages as its home page, and no other" $ do
      checked (profile "" Nothing (Just home)) `shouldBe` Right (profile "" Nothing (Just home))
      checked (profile "" Nothing (Just other)) `shouldSatisfy` isLeft
    it "takes no icon and no home page" $
      checked none `shouldBe` Right none
    it "is what profileOf gives back for a space" $ do
      let p = profile "x" (Just (IconColour "red")) (Just home)
      profileOf (withProfile p s) `shouldBe` p
      checked (profileOf (withProfile p s)) `shouldBe` Right p

  describe "homeBody" $
    it "names the space and invites whoever made it to write" $ do
      homeBody "  Team notes " `shouldSatisfy` T.isInfixOf "**Team notes**"
      homeTitle `shouldBe` "Home"

  describe "topLevelOf" $ do
    let spaces = [space "a" "A" Nothing, space "b" "B" (Just "a"), space "c" "C" (Just "b")]
    it "is the space itself at the top level" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "a")) `shouldBe` Just (SpaceId "a")
    it "is the top-level ancestor of a subspace" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "c")) `shouldBe` Just (SpaceId "a")
    it "is nothing for a space that is not there" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "z")) `shouldBe` Nothing
