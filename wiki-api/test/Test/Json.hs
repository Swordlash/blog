-- | Every type the API sends as JSON reads back as it was written.
module Test.Json (spec) where

import Data.Aeson (FromJSON, ToJSON, decode, encode, object, toJSON, (.=))
import Data.Text qualified as T
import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Api.Account (Credentials (..), NewAccount (..), NewPassword (..))
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
  roundTrips "Credentials" genCredentials
  roundTrips "NewAccount" genNewAccount
  roundTrips "NewPassword" genNewPassword
  roundTrips "AccountDisabled" genAccountDisabled
  roundTrips "Account" genAccount
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
  roundTrips "VersionInfo" genVersionInfo
  roundTrips "Version" genVersion
  roundTrips "ImportPlan" genImportPlan
  roundTrips "ImportChoices" genImportChoices
  roundTrips "ImportSummary" genImportSummary

  it "writes a body of one field as an object, not as the bare value" $
    toJSON (SpaceName "Team") `shouldBe` object ["name" .= ("Team" :: Text)]

  it "writes an error as its constructor, with its text when it has one" $ do
    toJSON NotFound `shouldBe` object ["error" .= ("NotFound" :: Text)]
    toJSON (Conflict "saved since") `shouldBe` object ["error" .= ("Conflict" :: Text), "message" .= ("saved since" :: Text)]

  it "never shows a password, so that none ends up in a log" $ do
    let shown :: Text
        shown =
          show (Credentials "ada" "hunter2")
            <> show (NewAccount "ada" "Ada" "hunter2")
            <> show (NewPassword "hunter2")
    shown `shouldSatisfy` (not . T.isInfixOf "hunter2")
    shown `shouldSatisfy` T.isInfixOf "\"ada\""

  it "refuses an error it does not know, and one without the text it needs" $ do
    decode "{\"error\":\"Teapot\"}" `shouldBe` (Nothing :: Maybe ApiError)
    decode "{\"error\":\"Invalid\"}" `shouldBe` (Nothing :: Maybe ApiError)
    (decode "{\"error\":\"Forbidden\",\"message\":\"ignored\"}" :: Maybe ApiError) `shouldBe` Just Forbidden
