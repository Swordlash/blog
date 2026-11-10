-- | A space's profile: its icon and its description, as "Wiki.Core.Space"
-- checks them; the home page a space is given; and where a space sits
-- among others.
module Test.Space (spec) where

import Data.Aeson (decode, encode, object, toJSON, (.=))
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Gen (genIcon)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space
import Wiki.Core.Vault (KeyId (..))

space :: Text -> Text -> Maybe Text -> Space
space i name parent =
  Space
    { id = SpaceId i
    , name
    , slug = either (panic . show) identity (mkSlug i)
    , parent = SpaceId <$> parent
    , public = False
    , sealed = False
    , encryption = Nothing
    , owner = Nothing
    , active = True
    , personalContainer = False
    , mathMacros = ""
    , createdAt = UTCTime (fromGregorian 2026 1 1) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    , boxNumbering = InPage
    }

profile :: Text -> Maybe Icon -> SpaceProfile
profile description icon = SpaceProfile {description, icon, blog = False, boxNumbering = InPage}

none :: SpaceProfile
none = profile "" Nothing

withIcon :: Icon -> Space -> Space
withIcon i s = withProfile (profile s.description (Just i)) s

home :: PageId
home = PageId "home"

-- | A slug written in a test, which must be one.
slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

spec :: Spec
spec = describe "Wiki.Core.Space" $ do
  describe "Icon" $ do
    prop "reads back what it writes" $ forAll genIcon $ \i -> decode (encode i) === Just i
    it "is written as an object with a field per kind" $ do
      toJSON (IconEmoji "📘") `shouldBe` object ["emoji" .= ("📘" :: Text)]
      toJSON (IconColour "teal") `shouldBe` object ["colour" .= ("teal" :: Text)]
      toJSON (IconImage (BlobId "b1") (MimeType "image/png")) `shouldBe` object ["image" .= ("b1" :: Text), "mediaType" .= ("image/png" :: Text)]
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
      checkIconUpload "image/png" 100 `shouldBe` Right (MimeType "image/png")
      checkIconUpload " IMAGE/JPEG; q=1" 100 `shouldBe` Right (MimeType "image/jpeg")
    it "refuses SVG, which may run scripts, and anything else" $ do
      checkIconUpload "image/svg+xml" 100 `shouldSatisfy` isLeft
      checkIconUpload "text/html" 100 `shouldSatisfy` isLeft
    it "refuses an empty file and one over the limit" $ do
      checkIconUpload "image/png" 0 `shouldSatisfy` isLeft
      checkIconUpload "image/png" (maxIconSize + 1) `shouldSatisfy` isLeft
      checkIconUpload "image/png" maxIconSize `shouldBe` Right (MimeType "image/png")

  describe "checkProfile" $ do
    let s = space "docs" "Docs" Nothing
        checked = checkProfile s
    it "trims the description" $
      checked (profile "  How we work \n" Nothing) `shouldBe` Right (profile "How we work" Nothing)
    it "refuses a description too long" $
      checked (profile (T.replicate (maxDescriptionLength + 1) "x") Nothing) `shouldSatisfy` isLeft
    it "takes a short emoji, trimmed" $
      checked (profile "" (Just (IconEmoji " 📘 "))) `shouldBe` Right (profile "" (Just (IconEmoji "📘")))
    it "refuses a blank emoji, one with spaces in it, and a long one" $ do
      checked (profile "" (Just (IconEmoji "  "))) `shouldSatisfy` isLeft
      checked (profile "" (Just (IconEmoji "a b"))) `shouldSatisfy` isLeft
      checked (profile "" (Just (IconEmoji (T.replicate 17 "x")))) `shouldSatisfy` isLeft
    it "takes a colour of the palette and refuses any other" $ do
      checked (profile "" (Just (IconColour "teal"))) `shouldBe` Right (profile "" (Just (IconColour "teal")))
      checked (profile "" (Just (IconColour "#ff0000"))) `shouldSatisfy` isLeft
    it "keeps the image the space has, and refuses one it has not" $ do
      let image = IconImage (BlobId "b1") (MimeType "image/png")
      checkProfile (withIcon image s) (profile "" (Just image)) `shouldBe` Right (profile "" (Just image))
      checked (profile "" (Just image)) `shouldSatisfy` isLeft
    it "takes no icon" $
      checked none `shouldBe` Right none
    it "is what profileOf gives back for a space" $ do
      let p = profile "x" (Just (IconColour "red"))
      profileOf (withProfile p s) `shouldBe` p
      checked (profileOf (withProfile p s)) `shouldBe` Right p
    it "leaves the space's home page as it is" $ do
      let p = profile "x" (Just (IconColour "red"))
      (withProfile p (withHome (Just home) s)).homePage `shouldBe` Just home
    it "reads a profile that still names a home page, and ignores it" $
      (decode "{\"description\": \"\", \"icon\": null, \"homePage\": \"p1\", \"blog\": true, \"boxNumbering\": \"in-page\"}" :: Maybe SpaceProfile)
        `shouldBe` Just SpaceProfile {description = "", icon = Nothing, blog = True, boxNumbering = InPage}

  describe "hasHome" $ do
    let s = space "docs" "Docs" Nothing
    it "holds for an ordinary space, a personal one and a blog" $ do
      hasHome s `shouldBe` True
      hasHome s {owner = Just (UserId "u1")} `shouldBe` True
      hasHome (withProfile SpaceProfile {description = "", icon = Nothing, blog = True, boxNumbering = InPage} s) `shouldBe` True
    it "does not hold for the container of personal spaces or an encrypted space" $ do
      hasHome s {personalContainer = True} `shouldBe` False
      hasHome s {encryption = Just (KeyId "k1")} `shouldBe` False

  describe "homeDeleteRefusal and homeMoveRefusal" $ do
    -- The home page under a page, as a space may have it from before
    -- every space had one.
    let s = withHome (Just home) (space "docs" "Docs" Nothing)
        above = PageId "above"
        other = PageId "other"
    it "refuse the home page itself" $ do
      homeDeleteRefusal s home [home] `shouldSatisfy` isJust
      homeMoveRefusal s home [home] False `shouldSatisfy` isJust
      homeMoveRefusal s home [home] True `shouldSatisfy` isJust
    it "refuse a page with the home page under it, deleted or moved to another space" $ do
      homeDeleteRefusal s above [above, home] `shouldSatisfy` isJust
      homeMoveRefusal s above [above, home] True `shouldSatisfy` isJust
    it "let a page with the home page under it move within the space" $
      homeMoveRefusal s above [above, home] False `shouldBe` Nothing
    it "let any other page go" $ do
      homeDeleteRefusal s other [other] `shouldBe` Nothing
      homeMoveRefusal s other [other] True `shouldBe` Nothing
      homeDeleteRefusal (space "plain" "Plain" Nothing) other [other] `shouldBe` Nothing

  describe "defaultHomePage" $ do
    let s = space "docs" "Team notes" Nothing
        time = UTCTime (fromGregorian 2026 11 10) 0
        made = defaultHomePage home time
    it "is a top-level page titled Home, whose text names the space and reads as untouched" $ do
      let p = made [] s
      (p.id, p.space, p.parent, p.title, p.template) `shouldBe` (home, s.id, Nothing, homeTitle, False)
      p.body `shouldBe` homeBody "Team notes"
      isHomeBody p.body `shouldBe` True
      (p.createdAt, p.updatedAt) `shouldBe` (time, time)
    it "is at home, position 0, in a space with no pages" $ do
      let p = made [] s
      (slugText p.slug, p.position) `shouldBe` ("home", 0)
    it "takes the next free slug, and a position before the space's top-level pages" $ do
      let p = made [(slug "home", 0), (slug "home-2", 3), (slug "notes", -2)] s
      (slugText p.slug, p.position) `shouldBe` ("home-3", -3)
    it "keeps home where the slug is free" $
      slugText (made [(slug "homes", 4)] s).slug `shouldBe` "home"

  describe "homeBody" $
    it "names the space and invites whoever made it to write" $ do
      homeBody "  Team notes " `shouldSatisfy` T.isInfixOf "**Team notes**"
      homeTitle `shouldBe` "Home"

  describe "topLevelOf" $ do
    let spaces = [space "a" "A" Nothing, space "b" "B" (Just "a"), space "c" "C" (Just "b")]
    it "is the space itself at the top level" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "a")) `shouldBe` Just (SpaceId "a")
    it "is the top-level ancestor of a subspace" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "c")) `shouldBe` Just (SpaceId "a")
    it "is nothing for a space that is not there" $ ((\x -> x.id) <$> topLevelOf spaces (SpaceId "z")) `shouldBe` Nothing
