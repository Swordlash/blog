-- | The bracket every transaction of the storage runs in
-- ('Wiki.Server.Storage.Backend.withTransaction', WP5.24 of
-- docs/PLAN.md). A transaction whose body throws, whose body returns a
-- 'Left', or whose commit throws is rolled back, and its connection is
-- left with no transaction open. The tests check that two ways: a @BEGIN@
-- right after succeeds (SQLite refuses a @BEGIN@ inside a transaction),
-- and on PostgreSQL the server shows the connection as @idle@, not as
-- @idle in transaction@ (PostgreSQL only warns of a @BEGIN@ inside a
-- transaction).
--
-- A commit is made to fail with a foreign key that is checked only at the
-- commit (@DEFERRABLE INITIALLY DEFERRED@): the body inserts a row that
-- breaks it, and the commit refuses it. On SQLite the failed commit leaves
-- the transaction open, so only the bracket's rollback closes it; on
-- PostgreSQL the failed commit ends it.
module Test.Storage.Transactions (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Database.PostgreSQL.Simple qualified as Pg
import Protolude
import Test.Database (Backing)
import Test.Hspec
import Test.Storage.Fixture (withPlaceIn)
import Wiki.Server.Storage (Database (..), Place (..))
import Wiki.Server.Storage.Backend (Backend (..), withTransaction, withTransactionEither)
import Wiki.Server.Storage.Postgres (closePostgres, openPostgres)
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, openSqlite)

-- | The exception a test's body throws.
data Boom = Boom
  deriving stock (Eq, Show)

instance Exception Boom

spec :: Backing -> Spec
spec backing = describe "a transaction" $ do
  it "whose body throws is rolled back, and leaves no transaction open" $
    onConnection backing $ \c idle -> do
      withTransaction True c (runScript c "CREATE TABLE made (x INTEGER); INSERT INTO made VALUES (1);" >> throwIO Boom) `shouldThrow` (== Boom)
      noTransactionOpen c idle
      tableThere c "made" `shouldReturn` False

  it "whose statement fails is rolled back, and leaves no transaction open" $
    onConnection backing $ \c idle -> do
      withTransaction True c (runScript c "CREATE TABLE made (x INTEGER); INSERT INTO nowhere VALUES (1);") `shouldThrow` anyException
      noTransactionOpen c idle
      tableThere c "made" `shouldReturn` False

  it "whose commit fails is rolled back, and leaves no transaction open" $
    onConnection backing $ \c idle -> do
      runScript c "CREATE TABLE parent (id INTEGER PRIMARY KEY); CREATE TABLE child (parent INTEGER REFERENCES parent (id) DEFERRABLE INITIALLY DEFERRED);"
      bodyEnded <- newIORef False
      withTransaction True c (runScript c "CREATE TABLE made (x INTEGER); INSERT INTO child VALUES (1);" >> writeIORef bodyEnded True) `shouldThrow` anyException
      -- The body ran to its end, so what failed was the commit.
      readIORef bodyEnded `shouldReturn` True
      noTransactionOpen c idle
      tableThere c "made" `shouldReturn` False
      -- The connection works on: a transaction that keeps the foreign key
      -- commits.
      withTransaction True c (runScript c "INSERT INTO parent VALUES (1); INSERT INTO child VALUES (1);")
      noTransactionOpen c idle

  it "whose body returns a Left is rolled back, and leaves no transaction open" $
    onConnection backing $ \c idle -> do
      withTransactionEither True c (runScript c "CREATE TABLE made (x INTEGER);" $> Left ("refused" :: Text)) `shouldReturn` (Left "refused" :: Either Text ())
      noTransactionOpen c idle
      tableThere c "made" `shouldReturn` False

  it "whose body returns is committed, and leaves no transaction open" $
    onConnection backing $ \c idle -> do
      withTransaction True c (runScript c "CREATE TABLE made (x INTEGER);" $> (7 :: Int)) `shouldReturn` 7
      withTransactionEither True c (runScript c "CREATE TABLE also (x INTEGER);" $> (Right 8 :: Either Text Int)) `shouldReturn` Right 8
      noTransactionOpen c idle
      tableThere c "made" `shouldReturn` True
      tableThere c "also" `shouldReturn` True

-- | Run a test on a connection of its own to a new, empty database of the
-- backing's, with the check that the server sees the connection idle: on
-- PostgreSQL, through @pg_stat_activity@ from a second connection; on
-- SQLite, which has no server, nothing.
onConnection :: Backing -> (forall be. (Backend be) => Connection be -> IO () -> IO a) -> IO a
onConnection backing act = withPlaceIn backing $ \at -> case at.database of
  SqliteFile file -> bracket (openSqlite ReadWrite file) closeSqlite (\c -> act c pass)
  PostgresAt db -> bracket (openPostgres db) closePostgres $ \c -> do
    pid <-
      Pg.query_ c "SELECT pg_backend_pid()" >>= \case
        [Pg.Only p] -> pure (p :: Int)
        _ -> panic "no backend pid"
    let idle =
          bracket (openPostgres db) closePostgres $ \other ->
            Pg.query other "SELECT state FROM pg_stat_activity WHERE pid = ?" (Pg.Only pid) `shouldReturn` [Pg.Only ("idle" :: Text)]
    act c idle

-- | Check that a connection has no transaction open: the server sees it
-- idle, and a new transaction begins on it.
noTransactionOpen :: (Backend be) => Connection be -> IO () -> IO ()
noTransactionOpen c idle = do
  idle
  begin True c
  rollbackTransaction c

-- | Whether the database has a table of this name.
tableThere :: (Backend be) => Connection be -> Text -> IO Bool
tableThere c name = elem name <$> runDb c tableNames
