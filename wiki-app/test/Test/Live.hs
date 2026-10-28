-- | How long the live channel waits before it opens its socket again
-- ("Wiki.App.Live"): the pause changed by up to 30 % either way, at random.
module Test.Live (spec) where

import Protolude
import Test.Hspec
import Test.QuickCheck (Positive (..), property)
import Wiki.App.Live (jittered)

spec :: Spec
spec = describe "the live channel's wait before it connects again" $ do
  it "is the pause give or take up to 30 %" $
    property $ \random (Positive pause) ->
      let waited = jittered random pause
       in pause * 7 `div` 10 <= waited && waited <= pause * 13 `div` 10

  it "spreads from 70 % to 130 % of the pause" $
    map (`jittered` 1000) [0, 300, 600, 601] `shouldBe` [700, 1000, 1300, 700]
