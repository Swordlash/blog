module Main (main) where

import Protolude
import Test.Hspec (hspec)
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
