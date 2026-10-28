module Main (main) where

import Protolude
import Test.Database (backingName, withBackings)
import Test.Hspec (describe, hspec)
import Test.Storage.Contract qualified as Contract

main :: IO ()
main = withBackings $ \backings -> hspec $ for_ backings $ \b -> describe (backingName b) (Contract.spec b)
