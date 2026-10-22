module Main (main) where

import Protolude
import Test.Backend.Mem qualified as Mem
import Test.Backend.Rules qualified as Rules
import Test.Demo qualified as Demo
import Test.Hello qualified as Hello
import Test.Hspec (hspec)
import Test.Islands qualified as Islands

main :: IO ()
main = hspec $ do
  Hello.spec
  Rules.spec
  Mem.spec
  Demo.spec
  Islands.spec
