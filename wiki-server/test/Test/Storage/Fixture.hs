-- | Storages for the tests: each made afresh in a temporary directory,
-- with the demo's wiki in it, and deleted with the directory afterwards.
module Test.Storage.Fixture
  ( withStorageIn
  , withDemo
  , demoArchive
  , whoFor
  , ok
  , path
  , tableRows
  )
where

import Data.Text qualified as T
import Database.SQLite.Simple (Connection, Only (..), SQLData, query_)
import Database.SQLite.Simple qualified as SQLite
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit (assertFailure)
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Export (Archive)
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.User (User (..))
import Wiki.Server.Storage

-- | A storage opened in a temporary directory of its own, which is gone
-- once the action is done.
withStorageIn :: (FilePath -> Storage -> IO a) -> IO a
withStorageIn action =
  withSystemTempDirectory "wiki-server-test" $ \dir ->
    withStorage defaultConfig dir (action dir)

-- | A storage with the demo's wiki in it, as the contract wants it.
withDemo :: (Storage -> IO a) -> IO a
withDemo action = withStorageIn $ \_ st -> do
  importArchive st demoArchive >>= either (\e -> assertFailure ("the demo does not import: " <> toS e)) pure
  action st

-- | The demo's wiki, as the export writes it.
demoArchive :: Archive
demoArchive = toArchive demoNow "wiki-server-test" (demoState demoNow)

-- | Who someone of the contract is in a storage: nobody, or the user with
-- that login, who must be there.
whoFor :: Storage -> As -> IO Who
whoFor st = \case
  Contract.Anonymous -> pure Wiki.Server.Storage.Anonymous
  As login -> userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) (\u -> pure (AsUser u.id))

-- | The value of a 'Right', or a failed test that says what the 'Left' was.
ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

-- | A path written as text.
path :: (HasCallStack) => Text -> [Slug]
path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)

-- | Every row of every table of a database (but SQLite's own), table by
-- table, each table's in the order of all its columns: what two databases
-- holding the same compare equal by.
tableRows :: Connection -> IO [(Text, [[SQLData]])]
tableRows c = do
  tables <- map fromOnly <$> query_ c "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
  for tables $ \t -> do
    columns <- map (\(_ :: Int, name, _ :: Text, _ :: Int, _ :: SQLData, _ :: Int) -> name) <$> query_ c (SQLite.Query ("PRAGMA table_info(\"" <> t <> "\")"))
    rows <- query_ c (SQLite.Query ("SELECT * FROM \"" <> t <> "\" ORDER BY " <> T.intercalate ", " columns))
    pure (t, rows)
