-- | The API's types, on every target: the browser's WebAssembly reads and
-- writes them as much as the server does. What needs a server
-- (servant-server) or the file system is in @wiki-api-server-test@, natively.
module Main (main) where

import Protolude
import Test.Backups qualified as Backups
import Test.Error qualified as Error
import Test.Events qualified as Events
import Test.Hspec (hspec)
import Test.Info qualified as Info
import Test.Json qualified as Json
import Test.Links qualified as Links
import Test.ServerSettings qualified as ServerSettings
import Test.Upload qualified as Upload
import Test.Url qualified as Url
import Test.Version qualified as Version

main :: IO ()
main = hspec $ do
  Info.spec
  Json.spec
  Error.spec
  Version.spec
  Url.spec
  Upload.spec
  Links.spec
  ServerSettings.spec
  Events.spec
  Backups.spec
