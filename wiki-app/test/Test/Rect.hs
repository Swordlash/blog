-- | The starting square of the avatar's crop ('Wiki.App.Web.Rect.centredSquare'):
-- the largest square inside the part of a picture that lies within the
-- cropper's canvas, centred, a whole pixel smaller than fits.
module Test.Rect (spec) where

import Protolude
import Test.Hspec
import Wiki.App.Web.Rect (Box (..), centredSquare)

spec :: Spec
spec = describe "Wiki.App.Web.Rect.centredSquare" $ do
  let canvas = Box {left = 100, top = 50, right = 548, bottom = 498}
  it "fits a wide picture's height, centred, a pixel smaller" $
    -- 448 wide, 224 high, centred in a square canvas of 448.
    centredSquare canvas Box {left = 100, top = 162, right = 548, bottom = 386} `shouldBe` Just (112.5, 112.5, 223)
  it "fits a tall picture's width" $
    centredSquare canvas Box {left = 212, top = 50, right = 436, bottom = 498} `shouldBe` Just (112.5, 112.5, 223)
  it "keeps to the part of a picture larger than the canvas that the canvas shows" $
    centredSquare canvas Box {left = 0, top = 0, right = 700, bottom = 600} `shouldBe` Just (0.5, 0.5, 447)
  it "has no square for a picture with no size, or outside the canvas" $ do
    centredSquare canvas Box {left = 0, top = 0, right = 0, bottom = 0} `shouldBe` Nothing
    centredSquare canvas Box {left = 600, top = 600, right = 700, bottom = 700} `shouldBe` Nothing
