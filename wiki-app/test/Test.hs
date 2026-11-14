module Main (main) where

import Protolude
import Test.Assistant qualified as Assistant
import Test.Backend.Http qualified as Http
import Test.Backend.Mem qualified as Mem
import Test.Backend.Persist qualified as Persist
import Test.Bell qualified as Bell
import Test.BellDom qualified as BellDom
import Test.Blog qualified as Blog
import Test.DecryptedExport qualified as DecryptedExport
import Test.Demo qualified as Demo
import Test.Entries qualified as Entries
import Test.Export qualified as Export
import Test.Favicon qualified as Favicon
import Test.Guide qualified as Guide
import Test.Help qualified as Help
import Test.Hspec (around_, parallel)
import Test.Hspec.Runner (Config (..), defaultConfig, hspecWith)
import Test.Hydrate qualified as Hydrate
import Test.Import qualified as Import
import Test.Islands qualified as Islands
import Test.Latest qualified as Latest
import Test.Licence qualified as Licence
import Test.Link qualified as Link
import Test.Live qualified as Live
import Test.Manifest qualified as Manifest
import Test.Passwords qualified as Passwords
import Test.Policy qualified as Policy
import Test.Problems qualified as Problems
import Test.Readme qualified as Readme
import Test.Rect qualified as Rect
import Test.Route qualified as Route
import Test.Server qualified as Server
import Test.Shell qualified as Shell
import Test.Threads qualified as Threads
import Test.Ticking qualified as Ticking
import Test.Users qualified as Users

main :: IO ()
main = do
  -- Most components use detached documents and independent backends. The
  -- page-size and assistant examples need the process's native stores alone.
  -- The views mounted in the process's document ("Test.Harness.MemDom")
  -- take it one at a time, beside everything else.
  permits <- newQSemN maxBound
  let holding n = bracket_ (waitQSemN permits n) (signalQSemN permits n)
  hspecWith defaultConfig {configConcurrentJobs = Just 4} . parallel $ do
    around_ (holding 1) $ do
      Islands.spec
      Mem.spec
      Http.spec
      Persist.spec
      Demo.spec
      Entries.spec
      Guide.spec
      Help.spec
      Export.spec
      DecryptedExport.spec
      Favicon.spec
      Route.spec
      Rect.spec
      Link.spec
      Live.spec
      Ticking.spec
      Bell.spec
      Threads.spec
      BellDom.spec
      Users.spec
      Latest.spec
      Shell.spec
      Server.spec
      Passwords.spec
      Blog.spec
      Hydrate.spec
      Import.spec
      Manifest.spec
      Policy.spec
      Problems.spec
      Licence.spec
      Readme.spec
    around_ (holding maxBound) $ do
      Hydrate.storageSpec
      Assistant.spec
