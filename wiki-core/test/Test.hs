module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Slug qualified as Slug

main :: IO ()
main = hspec $ do
  Slug.spec
