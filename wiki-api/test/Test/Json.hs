-- | Every type the API sends as JSON reads back as it was written.
module Test.Json (spec) where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, toJSON, (.=))
import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Types (SpaceName (..))

-- | A property that values of a type, as the generator makes them, come
-- back from their JSON unchanged.
roundTrips :: forall a. (Eq a, Show a, ToJSON a, FromJSON a) => Text -> Gen a -> Spec
roundTrips name gen = prop (toS name <> " reads back what it writes") $ forAll gen $ \x ->
  decode (encode x) === Just x

spec :: Spec
spec = describe "JSON" $ do
  roundTrips "ApiError" genApiError
  roundTrips "SessionInfo" genSessionInfo
  roundTrips "NewSpace" genNewSpace
  roundTrips "SpaceName" genSpaceName
  roundTrips "SpacePublic" genSpacePublic
  roundTrips "SpaceMathMacros" genSpaceMathMacros
  roundTrips "SpaceOrder" genSpaceOrder
  roundTrips "SpaceMove" genSpaceMove
  roundTrips "NewPage" genNewPage
  roundTrips "PageEdit" genPageEdit
  roundTrips "PageMove" genPageMove
  roundTrips "ShiftBy" genShiftBy
  roundTrips "DraftEdit" genDraftEdit
  roundTrips "Draft" genDraft
  roundTrips "ImportPlan" genImportPlan
  roundTrips "ImportChoices" genImportChoices
  roundTrips "ImportSummary" genImportSummary

  it "writes a body of one field as an object, not as the bare value" $
    toJSON (SpaceName "Team") `shouldBe` object ["name" .= ("Team" :: Text)]

  it "writes an error as its constructor, with its text when it has one" $ do
    toJSON NotFound `shouldBe` object ["error" .= ("NotFound" :: Text)]
    toJSON (Conflict "saved since") `shouldBe` object ["error" .= ("Conflict" :: Text), "message" .= ("saved since" :: Text)]

  it "refuses an error it does not know, and one without the text it needs" $ do
    decode "{\"error\":\"Teapot\"}" `shouldBe` (Nothing :: Maybe ApiError)
    decode "{\"error\":\"Invalid\"}" `shouldBe` (Nothing :: Maybe ApiError)
    (decode "{\"error\":\"Forbidden\",\"message\":\"ignored\"}" :: Maybe ApiError) `shouldBe` Just Forbidden
