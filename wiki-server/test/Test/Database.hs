-- | 'Backing' is a database the tests run the storage on: SQLite, or
-- PostgreSQL (WP5.22 of docs/PLAN.md). Every suite that uses the storage
-- runs on each ("Test"), through one parameter of its fixtures.
--
-- The PostgreSQL the tests use is the one @WIKI_TEST_DATABASE_URL@ names
-- (a URL to a database of a server the tests may create databases on, as
-- CI's container), with the @pg_dump@ and @pg_restore@ that
-- @WIKI_TEST_PG_DUMP@ and @WIKI_TEST_PG_RESTORE@ name (else those on the
-- PATH, which must be of the server's major version or newer), or else a cluster of its own that the tests
-- start in a temporary directory with @initdb@ and @pg_ctl@, found on the
-- @PATH@ or in the @bin@ directory of a version under
-- @\/usr\/lib\/postgresql@, and stop at the end.
-- Without either, every PostgreSQL example is pending ("not run"), never
-- passed. Each example gets a database of its own, made from nothing and
-- dropped afterwards.
--
-- PostgreSQL's programs refuse to run as root, so a test run as root runs
-- them as the user @postgres@ (with @su@), in a directory that user owns.
module Test.Database
  ( Backing (..)
  , PgServer (..)
  , backingName
  , withBackings
  , withPlace
  , databaseUrl
  , choiceOf
  , placeOptionsOf
  , withConnectionTo
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Text qualified as T
import Database.PostgreSQL.Simple qualified as Pg
import Database.PostgreSQL.Simple.Types (Query (..))
import Network.Socket qualified as Socket
import Protolude
import System.Directory (doesFileExist, findExecutable, listDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Posix.Signals (Handler (..), installHandler, sigTERM)
import System.Posix.User (getEffectiveUserID)
import System.Process (callProcess, readProcessWithExitCode)
import Test.Hspec (pendingWith)
import Wiki.Server.Options (DatabaseChoice (..), PlaceOptions (..))
import Wiki.Server.Storage (Database (..), PgDatabase (..), Place (..), inDataDir, postgresAt)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Postgres (PgPrograms (..), closePostgres, defaultPgPrograms, openPostgres)
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, openSqlite)

-- | A database the tests run on.
data Backing
  = -- | SQLite, in a file of the example's data directory.
    OnSqlite
  | -- | PostgreSQL, a database of this server for each example.
    OnPostgres PgServer
  | -- | PostgreSQL, which is not at hand, for this reason.
    PostgresNotRun Text

-- | A PostgreSQL server the tests may make databases on: the URL of one of
-- its databases, to connect to while making and dropping the others, and
-- a count to name new databases by.
data PgServer = PgServer
  { url :: Text
  , made :: IORef Int
  , programs :: PgPrograms
  -- ^ The @pg_dump@ and @pg_restore@ of the server's version: those of
  -- the cluster's own installation, or those on the PATH.
  }

-- | How a suite's title names a backing.
backingName :: Backing -> [Char]
backingName = \case
  OnSqlite -> "on SQLite"
  OnPostgres _ -> "on PostgreSQL"
  PostgresNotRun _ -> "on PostgreSQL"

-- | Run the tests with the backings there are: SQLite, and PostgreSQL if
-- it is at hand (see the module's comment).
withBackings :: ([Backing] -> IO a) -> IO a
withBackings act =
  lookupEnv "WIKI_TEST_DATABASE_URL" >>= \case
    Just url -> do
      made <- newIORef 0
      dump <- fromMaybe defaultPgPrograms.dump <$> lookupEnv "WIKI_TEST_PG_DUMP"
      restore <- fromMaybe defaultPgPrograms.restore <$> lookupEnv "WIKI_TEST_PG_RESTORE"
      act [OnSqlite, OnPostgres PgServer {url = T.pack url, made, programs = PgPrograms {dump, restore}}]
    Nothing ->
      findPostgres >>= \case
        Nothing -> act [OnSqlite, PostgresNotRun "PostgreSQL is not at hand: set WIKI_TEST_DATABASE_URL, or put initdb and pg_ctl on the PATH"]
        Just bin -> stoppedByTerm . withCluster bin $ \url -> do
          made <- newIORef 0
          act [OnSqlite, OnPostgres PgServer {url, made, programs = PgPrograms {dump = bin </> "pg_dump", restore = bin </> "pg_restore"}}]

-- | Run an action that a SIGTERM (what @timeout@ sends) interrupts as a
-- Ctrl-C would, so that the cluster it started is stopped and deleted
-- rather than left running.
stoppedByTerm :: IO a -> IO a
stoppedByTerm act = do
  main <- myThreadId
  previous <- installHandler sigTERM (Catch (throwTo main UserInterrupt)) Nothing
  act `finally` installHandler sigTERM previous Nothing

-- | The directory of PostgreSQL's programs, if they are installed: where
-- @pg_ctl@ is on the PATH, or the @bin@ directory of the newest version
-- under @\/usr\/lib\/postgresql@.
findPostgres :: IO (Maybe FilePath)
findPostgres =
  findExecutable "pg_ctl" >>= \case
    Just ctl -> pure (Just (reverse (drop 1 (dropWhile (/= '/') (reverse ctl)))))
    Nothing -> do
      let root = "/usr/lib/postgresql"
      versions <- either (const []) identity <$> try @SomeException (listDirectory root)
      found <- filterM (\v -> doesFileExist (root </> v </> "bin" </> "pg_ctl")) (sortOn (Down . (readMaybe :: [Char] -> Maybe Int)) versions)
      pure ((\v -> root </> v </> "bin") <$> head found)

-- | Run something with a PostgreSQL cluster of its own, in a temporary
-- directory, listening on a socket there and nowhere else, which trusts
-- every connection. The action is given the URL of its @postgres@
-- database. The cluster is stopped and deleted afterwards.
withCluster :: FilePath -> (Text -> IO a) -> IO a
withCluster bin act = do
  root <- getEffectiveUserID <&> (== 0)
  tmp <- getCanonicalTemporaryDirectory
  bracket (createTempDirectory tmp "wiki-pg") remove $ \dir -> do
    when root (callProcess "chown" ["postgres", dir])
    port <- freePort
    let run :: FilePath -> [[Char]] -> IO ()
        run program args
          | root = callProcess "su" ["postgres", "-s", "/bin/sh", "-c", unwords' ((bin </> program) : args)]
          | otherwise = callProcess (bin </> program) args
        unwords' = intercalate " " . map (\a -> "'" <> a <> "'")
    run "initdb" ["-D", dir </> "data", "-A", "trust", "-U", "wiki", "--no-sync"]
    run "pg_ctl" ["-D", dir </> "data", "-o", "-k " <> dir <> " -p " <> show port <> " -c listen_addresses= -c fsync=off", "-l", dir </> "log", "-w", "start"]
    act ("postgres://wiki@/postgres?host=" <> T.pack dir <> "&port=" <> show port)
      `finally` run "pg_ctl" ["-D", dir </> "data", "-m", "immediate", "stop"]
  where
    remove dir = void (readProcessWithExitCode "rm" ["-rf", dir] "")

-- | A port nobody listens on now, for the cluster's socket's name.
freePort :: IO Int
freePort = do
  s <- Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol
  Socket.bind s (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
  port <- Socket.socketPort s
  Socket.close s
  pure (fromIntegral port)

-- | The URL of another database of the same server: the same URL with
-- the database's name in place of the one it has.
databaseUrl :: Text -> Text -> Text
databaseUrl base name =
  let (scheme, rest) = T.breakOnEnd "://" base
      (authority, pathAndQuery) = T.breakOn "/" rest
      query = T.dropWhile (/= '?') pathAndQuery
   in scheme <> authority <> "/" <> name <> query

-- | A place for an example's wiki in a data directory: on SQLite, the
-- directory's own file; on PostgreSQL, a database made for the example and
-- dropped afterwards. Pending, for PostgreSQL that is not at hand.
withPlace :: Backing -> FilePath -> (Place -> IO a) -> IO a
withPlace backing dir act = case backing of
  OnSqlite -> act (inDataDir dir)
  PostgresNotRun why -> pendingWith (toS why) >> panic "pendingWith returned"
  OnPostgres server -> do
    n <- atomicModifyIORef' server.made (\k -> (k + 1, k + 1))
    let name = "wiki_test_" <> show n
        admin = BC.pack (toS server.url)
        statement q = bracket (Pg.connectPostgreSQL admin) Pg.close (\c -> void (Pg.execute_ c (Query (encodeUtf8 q))))
    bracket_ (statement ("CREATE DATABASE " <> name)) (statement ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)")) $
      act Place {dataDir = dir, database = postgresAt (encodeUtf8 (databaseUrl server.url name)), programs = server.programs}

-- | The command line's choice of a database, for a place: what a test
-- gives a server or a console command to find the place's database.
choiceOf :: Database -> DatabaseChoice
choiceOf = \case
  SqliteFile file -> SqliteChosen file
  PostgresAt db -> PostgresChosen (decodeUtf8 db.url) Nothing

-- | The console's options for a place.
placeOptionsOf :: Place -> PlaceOptions
placeOptionsOf at = PlaceOptions {dataDir = at.dataDir, database = choiceOf at.database, programs = at.programs}

-- | A connection of its own to a place's database, outside any storage:
-- for a test that looks at the database as the storage leaves it, or
-- prepares one for the storage to find.
withConnectionTo :: Place -> (forall be. (Backend be) => Connection be -> IO a) -> IO a
withConnectionTo at act = case at.database of
  SqliteFile file -> bracket (openSqlite ReadWrite file) closeSqlite act
  PostgresAt db -> bracket (openPostgres db) closePostgres act
