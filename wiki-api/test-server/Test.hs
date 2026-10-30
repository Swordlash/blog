-- | The API served, natively: golden files of its JSON, and a server of its
-- type with stub handlers.
module Main (main) where

import Protolude
import Test.Golden qualified as Golden
import Test.Hspec (hspec, parallel)
import Test.Server qualified as Server

main :: IO ()
main = hspec . parallel $ do
  Golden.spec
  Server.spec
