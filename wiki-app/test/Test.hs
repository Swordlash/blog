module Main (main) where

import Protolude
import Test.Backend.Http qualified as Http
import Test.Backend.Mem qualified as Mem
import Test.Backend.Persist qualified as Persist
import Test.Blog qualified as Blog
import Test.Demo qualified as Demo
import Test.Export qualified as Export
import Test.Hspec (hspec)
import Test.Hydrate qualified as Hydrate
import Test.Import qualified as Import
import Test.Islands qualified as Islands
import Test.Licence qualified as Licence
import Test.Link qualified as Link
import Test.Manifest qualified as Manifest
import Test.Route qualified as Route
import Test.Shell qualified as Shell

main :: IO ()
main = hspec $ do
  Islands.spec
  Mem.spec
  Http.spec
  Persist.spec
  Demo.spec
  Export.spec
  Route.spec
  Link.spec
  Shell.spec
  Blog.spec
  Hydrate.spec
  Import.spec
  Manifest.spec
  Licence.spec
