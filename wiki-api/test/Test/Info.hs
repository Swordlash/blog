module Test.Info (spec) where

import Data.Aeson (decode, encode, object, toJSON, (.=))
import Protolude
import Test.Hspec
import Wiki.Api.Info

spec :: Spec
spec = describe "ServerInfo" $ do
  let info = ServerInfo {name = "Wiki", apiVersion}

  it "is written with the record's field names" $
    toJSON info `shouldBe` object ["name" .= ("Wiki" :: Text), "apiVersion" .= (1 :: Int)]

  it "reads back what it writes" $
    decode (encode info) `shouldBe` Just info
