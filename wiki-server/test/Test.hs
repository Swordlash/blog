module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Server.Access qualified as Access
import Test.Server.Accounts qualified as Accounts
import Test.Server.Api qualified as Api
import Test.Server.Http qualified as Http
import Test.Server.Import qualified as Import
import Test.Server.Mail qualified as Mail
import Test.Server.Oidc qualified as Oidc
import Test.Server.Options qualified as Options
import Test.Server.Render qualified as Render
import Test.Server.Static qualified as Static
import Test.Storage qualified as Storage
import Test.Storage.Accounts qualified as StorageAccounts
import Test.Storage.Backup qualified as Backup
import Test.Storage.Contract qualified as Contract
import Test.Storage.Migrate qualified as Migrate

main :: IO ()
main = hspec $ do
  Contract.spec
  Http.spec
  Storage.spec
  Migrate.spec
  Backup.spec
  StorageAccounts.spec
  Options.spec
  Api.spec
  Static.spec
  Render.spec
  Import.spec
  Accounts.spec
  Access.spec
  Mail.spec
  Oidc.spec
