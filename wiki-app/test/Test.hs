module Main (main) where

import Protolude
import Test.Hello qualified as Hello
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Hello.spec
