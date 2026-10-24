-- | Errors and the statuses they travel with.
module Test.Error (spec) where

import Protolude
import Test.Gen (genApiError)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Api.Error

spec :: Spec
spec = describe "Wiki.Api.Error" $ do
  it "answers each error with its status" $
    map errorStatus [NotFound, Forbidden, Conflict "c", Invalid "i"] `shouldBe` [404, 403, 409, 400]

  prop "reads an error's own status back as that error, given its text" $ forAll genApiError $ \e ->
    let text = case e of
          Conflict t -> t
          Invalid t -> t
          _ -> ""
     in errorForStatus (errorStatus e) text === Just e

  it "reads the statuses the server's routing and proxies answer with" $ do
    errorForStatus 405 "Method Not Allowed" `shouldBe` Just (Invalid "Method Not Allowed")
    errorForStatus 413 "too large" `shouldBe` Just (Invalid "too large")
    errorForStatus 412 "" `shouldBe` Just (Conflict "")
    errorForStatus 401 "" `shouldBe` Just Forbidden

  it "does not take a failure of the server for a refusal" $ do
    errorForStatus 500 "" `shouldBe` Nothing
    errorForStatus 502 "" `shouldBe` Nothing
    errorForStatus 200 "" `shouldBe` Nothing
