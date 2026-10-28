module Main (main) where

import Protolude
import Test.Database (backingName, withBackings)
import Test.Hspec (describe, hspec)
import Test.Storage qualified as Storage
import Test.Storage.Accounts qualified as StorageAccounts
import Test.Storage.Audit qualified as Audit
import Test.Storage.Backup qualified as Backup
import Test.Storage.Contract qualified as Contract
import Test.Storage.Migrate qualified as Migrate
import Test.Storage.Scale qualified as Scale

main :: IO ()
main = withBackings $ \backings -> hspec $ for_ backings $ \b -> describe (backingName b) $ do
  Contract.spec b
  Storage.spec b
  Migrate.spec b
  Scale.spec b
  Backup.spec b
  StorageAccounts.spec b
  Audit.spec b
