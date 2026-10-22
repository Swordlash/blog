module Main (main) where

import Protolude
import Test.Hello qualified as Hello
import Test.Hspec (hspec)
import Test.Islands qualified as Islands

main :: IO ()
main = hspec $ do
  Hello.spec
  Islands.spec
