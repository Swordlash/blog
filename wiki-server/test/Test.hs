-- | The server's tests. Those of the storage and of the server over HTTP
-- run once on each database ("Test.Database"): SQLite, and PostgreSQL when
-- one is at hand, else reported as not run. Those that touch no database
-- run once.
module Main (main) where

import Protolude
import Test.Database (backingName, withBackings)
import Test.Hspec (describe, hspec)
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
import Test.Storage.Scale qualified as Scale

main :: IO ()
main = withBackings $ \backings -> hspec $ do
  Presence.spec
  Totp.spec
  Metrics.spec
  for_ backings $ \b -> describe (backingName b) $ do
    Contract.spec b
    Http.spec b
    Storage.spec b
    Migrate.spec b
    Scale.spec b
    Backup.spec b
    StorageAccounts.spec b
    Options.spec b
    Api.spec b
    Static.spec b
    Render.spec b
    Feed.spec b
    Import.spec b
    Accounts.spec b
    Access.spec b
    Comments.spec b
    Mail.spec b
    Settings.spec b
    Backups.spec b
    Oidc.spec b
    Export.spec b
    Hygiene.spec b
    Audit.spec b
    Observability.spec b
    Notifications.spec b
