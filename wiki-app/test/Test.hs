module Main (main) where

import Protolude
import Test.Assistant qualified as Assistant
import Test.Backend.Http qualified as Http
import Test.Backend.Mem qualified as Mem
import Test.Backend.Persist qualified as Persist
import Test.Blog qualified as Blog
import Test.Demo qualified as Demo
import Test.Export qualified as Export
import Test.Guide qualified as Guide
import Test.Hspec (around_, parallel)
import Test.Hspec.Runner (Config (..), defaultConfig, hspecWith)
import Test.Hydrate qualified as Hydrate
import Test.Import qualified as Import
import Test.Islands qualified as Islands
import Test.Licence qualified as Licence
import Test.Link qualified as Link
import Test.Live qualified as Live
import Test.Manifest qualified as Manifest
import Test.Passwords qualified as Passwords
import Test.Policy qualified as Policy
import Test.Readme qualified as Readme
import Test.Route qualified as Route
import Test.Server qualified as Server
import Test.Shell qualified as Shell

main :: IO ()
main = do
  -- Most components use detached documents and independent backends. The
  -- page-size and assistant examples need the process's native stores alone.
  permits <- newQSemN maxBound
  let holding n = bracket_ (waitQSemN permits n) (signalQSemN permits n)
  hspecWith defaultConfig {configConcurrentJobs = Just 4} . parallel $ do
    around_ (holding 1) $ do
      Islands.spec
      Mem.spec
      Http.spec
      Persist.spec
      Demo.spec
      Guide.spec
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
      Policy.spec
      Licence.spec
      Readme.spec
    around_ (holding maxBound) $ do
      Hydrate.storageSpec
      Assistant.spec
