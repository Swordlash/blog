-- | The API's types, on every target: the browser's WebAssembly reads and
-- writes them as much as the server does. What needs a server
-- (servant-server) or the file system is in @wiki-api-server-test@, natively.
module Main (main) where

import Protolude
import Test.Error qualified as Error
import Test.Hspec (hspec)
import Test.Info qualified as Info
import Test.Json qualified as Json
import Test.Links qualified as Links
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
