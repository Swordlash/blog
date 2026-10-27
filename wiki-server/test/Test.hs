module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Server.Access qualified as Access
import Test.Server.Accounts qualified as Accounts
import Test.Server.Api qualified as Api
import Test.Server.Backups qualified as Backups
import Test.Server.Comments qualified as Comments
import Test.Server.Export qualified as Export
import Test.Server.Feed qualified as Feed
import Test.Server.Http qualified as Http
import Test.Server.Hygiene qualified as Hygiene
import Test.Server.Import qualified as Import
import Test.Server.Mail qualified as Mail
import Test.Server.Metrics qualified as Metrics
import Test.Server.Notifications qualified as Notifications
import Test.Server.Observability qualified as Observability
import Test.Server.Oidc qualified as Oidc
import Test.Server.Options qualified as Options
import Test.Server.Presence qualified as Presence
import Test.Server.Render qualified as Render
import Test.Server.Settings qualified as Settings
import Test.Server.Static qualified as Static
import Test.Server.Totp qualified as Totp
import Test.Storage qualified as Storage
import Test.Storage.Accounts qualified as StorageAccounts
import Test.Storage.Audit qualified as Audit
import Test.Storage.Backup qualified as Backup
import Test.Storage.Contract qualified as Contract
import Test.Storage.Migrate qualified as Migrate
import Test.Storage.Persistent qualified as Persistent

main :: IO ()
main = hspec $ do
  Contract.spec
  Http.spec
  Storage.spec
  Migrate.spec
  Persistent.spec
  Backup.spec
  StorageAccounts.spec
  Options.spec
  Api.spec
  Static.spec
  Render.spec
  Feed.spec
  Import.spec
  Accounts.spec
  Access.spec
  Comments.spec
  Presence.spec
  Mail.spec
  Settings.spec
  Backups.spec
  Oidc.spec
  Export.spec
  Totp.spec
  Hygiene.spec
  Audit.spec
  Metrics.spec
  Observability.spec
  Notifications.spec
