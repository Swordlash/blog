-- | The domain's ids and slugs in an address, as the API's paths and
-- parameters carry them.
module Test.Url (spec) where

import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Web.HttpApiData (FromHttpApiData, ToHttpApiData, parseUrlPiece, toUrlPiece)
import Wiki.Core.Id
import Wiki.Core.Slug (Slug, slugText)

readsBack :: forall a. (Eq a, Show a, ToHttpApiData a, FromHttpApiData a) => Text -> Gen a -> Spec
readsBack name gen = prop (toS name <> " reads back from its URL piece") $ forAll gen $ \x ->
  parseUrlPiece (toUrlPiece x) === Right x

spec :: Spec
spec = describe "URL pieces" $ do
  readsBack "SpaceId" genSpaceId
  readsBack "PageId" genPageId
  readsBack "AttachmentId" genAttachmentId
  readsBack "Slug" genSlug

  prop "writes an id and a slug as their bare text" $ forAll ((,) <$> genSpaceId <*> genSlug) $ \(s, slug) ->
    (toUrlPiece s, toUrlPiece slug) === (s.text, slugText slug)

  it "refuses a piece that is not a slug" $ do
    (parseUrlPiece "Not A Slug" :: Either Text Slug) `shouldSatisfy` isLeft
    (parseUrlPiece "" :: Either Text Slug) `shouldSatisfy` isLeft
