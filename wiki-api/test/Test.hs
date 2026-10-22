module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Info qualified as Info

main :: IO ()
main = hspec $ do
  Info.spec
