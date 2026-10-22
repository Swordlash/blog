module Test.Json (spec) where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode, object, toJSON, (.=))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, forAll, (===))
import Wiki.Core.Id
import Wiki.Core.Permission
import Wiki.Core.Search
import Wiki.Core.Slug
import Wiki.Core.Space
import Wiki.Core.User (Membership)

roundTrips :: (Eq a, Show a, ToJSON a, FromJSON a) => Gen a -> Property
roundTrips gen = forAll gen $ \a -> eitherDecode (encode a) === Right a

spec :: Spec
spec = describe "JSON" $ do
  describe "reads back what it writes, for" $ do
    prop "Slug" $ roundTrips genSlug
    prop "SpaceId" $ roundTrips genSpaceId
    prop "PageId" $ roundTrips genPageId
    prop "AttachmentId" $ roundTrips genAttachmentId
    prop "BlobId" $ roundTrips genBlobId
    prop "UserId" $ roundTrips genUserId
    prop "GroupId" $ roundTrips genGroupId
    prop "Source" $ roundTrips genSource
    prop "Attachment" $ roundTrips genAttachment
    prop "Space" $ roundTrips genSpace
    prop "Page" $ roundTrips genPage
    prop "User" $ roundTrips genUser
    prop "Group" $ roundTrips genGroup
    prop "Membership" $ roundTrips genMembership
    prop "Subject" $ roundTrips genSubject
    prop "GlobalGrant" $ roundTrips genGlobalGrant
    prop "SpaceGrant" $ roundTrips genSpaceGrant
    prop "Grants" $ roundTrips genGrants
    prop "Principal" $ roundTrips genPrincipal
    prop "SearchQuery" $ roundTrips genSearchQuery
    prop "SearchHit" $ roundTrips genSearchHit

  describe "is written" $ do
    it "with an identifier as its bare text" $
      toJSON (SpaceId "s1") `shouldBe` toJSON ("s1" :: Text)
    it "with a record's field names, and a slug as its text" $ do
      let s = either (panic . show) identity (mkSlug "eng")
      toJSON Space {id = SpaceId "s1", name = "Engineering", slug = s, parent = Nothing, public = True}
        `shouldBe` object
          [ "id" .= ("s1" :: Text)
          , "name" .= ("Engineering" :: Text)
          , "slug" .= ("eng" :: Text)
          , "parent" .= (Nothing :: Maybe Text)
          , "public" .= True
          ]
    it "with membership as an object keyed by group" $
      toJSON (Map.fromList [(GroupId "devs", Set.fromList [UserId "bob"])] :: Membership)
        `shouldBe` object ["devs" .= ["bob" :: Text]]
    it "with a snippet as a list of pieces of text, each marked or not" $
      toJSON (Snippet [Piece "a " False, Piece "match" True])
        `shouldBe` toJSON [object ["text" .= ("a " :: Text), "match" .= False], object ["text" .= ("match" :: Text), "match" .= True]]
    it "with a permission as its name" $
      toJSON [View, Edit, AdministerSpace] `shouldBe` toJSON ["View", "Edit", "AdministerSpace" :: Text]

  it "refuses a space whose slug breaks the rules" $
    (eitherDecode "{\"id\":\"s1\",\"name\":\"E\",\"slug\":\"Not a slug\",\"parent\":null,\"public\":false}" :: Either [Char] Space)
      `shouldSatisfy` isLeft
