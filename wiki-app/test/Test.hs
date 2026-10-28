module Main (main) where

import Protolude
import Test.Assistant qualified as Assistant
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
import Test.Live qualified as Live
import Test.Manifest qualified as Manifest
import Test.Passwords qualified as Passwords
import Test.Readme qualified as Readme
import Test.Route qualified as Route
import Test.Server qualified as Server
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
  Live.spec
  Shell.spec
  Server.spec
  Passwords.spec
  Blog.spec
  Hydrate.spec
  Import.spec
  Manifest.spec
  Licence.spec
  Readme.spec
  Assistant.spec
