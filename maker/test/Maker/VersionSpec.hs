module Maker.VersionSpec (spec) where

import Maker.Version
import Test.Hspec

spec :: Spec
spec = describe "versions" $ do
  it "reads a version's numbers, a part by its leading digits" $ do
    numbers "9.14.1" `shouldBe` [9, 14, 1]
    numbers "9.14.1-rc1" `shouldBe` [9, 14, 1]
    numbers "x" `shouldBe` []
  it "compares with a floor as the bootstrap does, a missing number counting as 0" $ do
    "9.12.2" `atLeast` "9.12" `shouldBe` True
    "9.12" `atLeast` "9.12.0" `shouldBe` True
    "9.10.3" `atLeast` "9.12" `shouldBe` False
    "9.14.1" `atLeast` "9.10" `shouldBe` True
    "3.16.1.0" `atLeast` "3.12" `shouldBe` True
    "3.10.3.0" `atLeast` "3.12" `shouldBe` False
    "" `atLeast` "9.10" `shouldBe` False
  it "reads Node's major version from what node --version prints" $ do
    nodeMajor "v24.21.0" `shouldBe` Just 24
    nodeMajor "v18.1.0" `shouldBe` Just 18
    nodeMajor "24.21.0" `shouldBe` Nothing
    nodeMajor "" `shouldBe` Nothing
