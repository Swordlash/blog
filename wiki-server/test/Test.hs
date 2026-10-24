module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Server.Api qualified as Api
import Test.Server.Import qualified as Import
import Test.Server.Options qualified as Options
import Test.Server.Static qualified as Static
import Test.Storage qualified as Storage
import Test.Storage.Backup qualified as Backup
import Test.Storage.Contract qualified as Contract
import Test.Storage.Migrate qualified as Migrate

main :: IO ()
main = hspec $ do
  Contract.spec
  Storage.spec
  Migrate.spec
  Backup.spec
  Options.spec
  Api.spec
  Static.spec
  Import.spec
