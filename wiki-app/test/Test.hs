module Main (main) where

import Protolude
import Test.Backend.Mem qualified as Mem
import Test.Backend.Persist qualified as Persist
import Test.Demo qualified as Demo
import Test.Hspec (hspec)
import Test.Hydrate qualified as Hydrate
import Test.Islands qualified as Islands
import Test.Link qualified as Link
import Test.Route qualified as Route
import Test.Shell qualified as Shell

main :: IO ()
main = hspec $ do
  Islands.spec
  Mem.spec
  Persist.spec
  Demo.spec
  Route.spec
  Link.spec
  Shell.spec
  Hydrate.spec
