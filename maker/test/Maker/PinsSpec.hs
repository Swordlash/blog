module Maker.PinsSpec (spec) where

import Data.Either (isLeft)
import Maker.Pins
import Test.Hspec

spec :: Spec
spec = describe "pins" $ do
  it "reads the repository's toolchain/pins.env" $ do
    pins <- readPins ".."
    pins.ghcVersion `shouldBe` "9.14.1"
    pins.nodeMinMajor `shouldBe` 24
    pins.ghcMinVersion `shouldBe` "9.10"
    pins.libsodiumVersion `shouldBe` "1.0.22"
  it "refuses a line that is not KEY=VALUE, naming its number" $
    parsePins "# a comment\n\nGHC_VERSION = 9.14.1\n" `shouldBe` Left "toolchain/pins.env, line 3: not KEY=VALUE: GHC_VERSION = 9.14.1"
  it "names a key that is missing" $
    parsePins "GHC_VERSION=9.14.1\n" `shouldSatisfy` isLeft
