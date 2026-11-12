-- | 'Backing' is a database the tests run the storage on: SQLite, or
-- PostgreSQL (WP5.22 of docs/PLAN.md). Local runs cover each backing.
-- CI sets @WIKI_TEST_GROUP@ to @unit@, @sqlite@ or @postgres@: unit tests
-- need no database, and each database group runs only its own backing.
-- An explicit postgres group requires @WIKI_TEST_DATABASE_URL@.
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
-- passed. Each example gets a database of its own, dropped afterwards.
-- Several runs may share one server (one container serves every session
-- on a machine, toolchain/ci-postgres.sh), so every name a run makes
-- starts with a namespace of the run's own ('namespaceFor'): when it began
-- and eight random letters. A killed run's databases are dropped by a
-- later run once they are six hours old ('sweepOnce').
-- 'withPlace' copies it from a template database that the program's own
-- 'migrate' brought to the current schema once per run, so that an example
-- does not pay for every migration again. The copy needs PostgreSQL 15 or
-- newer (CI runs 17). 'withEmptyPlace' makes it from
-- nothing, for the examples about migrations, schema versions and
-- restores, which need a database with no schema in it.
--
-- PostgreSQL's programs refuse to run as root, so a test run as root runs
-- them as the user @postgres@ (with @su@), in a directory that user owns.
--
-- A wiki-server built without PostgreSQL (the cabal flag @postgres@ off)
-- has no PostgreSQL backing: its tests run on SQLite alone, and the
-- @postgres@ group runs nothing. Either way a note on the standard error
-- says that the PostgreSQL tests were left out, and why.
module Test.Database
  ( TestGroup (..)
  , testGroup
  , Backing (..)
  , PgServer (..)
  , backingName
  , withBackings
  , withPlace
  , withEmptyPlace
  , databaseUrl
  , namespaceFor
  , namespaceBegan
  , namesUnitSpec
  , choiceOf
  , placeOptionsOf
  , withConnectionTo
  , forgetStep
  )
where

import Data.IORef (IORef)
import Data.Text qualified as T
import Protolude
import System.Environment (lookupEnv)
import System.IO.Error (userError)
import Test.Hspec (Spec, describe, it, pendingWith, shouldBe, shouldSatisfy)
import Wiki.Server.Options (DatabaseChoice (..), PlaceOptions (..))
import Wiki.Server.Storage (Database (..), PgDatabase (..), Place (..), inDataDir)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Layout (PgPrograms (..))
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, openSqlite)
#ifdef WIKI_POSTGRES
import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.PostgreSQL.Simple qualified as Pg
import Database.PostgreSQL.Simple.Types (Query (..))
import System.Directory (doesFileExist, findExecutable, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (createTempDirectory, getCanonicalTemporaryDirectory)
import System.Posix.Signals (Handler (..), installHandler, sigTERM)
import System.Posix.User (getEffectiveUserID)
import System.Process (callProcess, readProcessWithExitCode)
import Wiki.Server.Storage (postgresAt)
import Wiki.Server.Storage.Layout (defaultPgPrograms)
import Wiki.Server.Storage.Migrate (migrate)
import Wiki.Server.Storage.Postgres (closePostgres, openPostgres)
#else
import Wiki.Server.Storage.Layout (withoutPostgres)
#endif

-- | One native CI job's tests. Local runs include every group by default.
data TestGroup = AllTests | UnitTests | SqliteTests | PostgresTests
  deriving (Eq)

-- | Select tests before starting a database. Unknown values fail rather
-- than silently dropping part of the suite.
testGroup :: IO TestGroup
testGroup =
  lookupEnv "WIKI_TEST_GROUP" >>= \case
    Nothing -> pure AllTests
    Just "all" -> pure AllTests
    Just "unit" -> pure UnitTests
    Just "sqlite" -> pure SqliteTests
    Just "postgres" -> pure PostgresTests
    Just _ -> ioError (userError "WIKI_TEST_GROUP must be all, unit, sqlite or postgres")

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
  , template :: MVar Bool
  -- ^ Whether the template database ('templateName') is made yet. The
  -- first example that needs it makes it, under this lock, so that
  -- examples running at once make it only once.
  , namespace :: Text
  -- ^ The start of every database name this run makes ('namespaceFor').
  , swept :: MVar Bool
  -- ^ Whether this run has dropped the databases dead runs left
  -- ('sweepOnce'), which it does before it makes its first.
  }

-- | How a suite's title names a backing.
backingName :: Backing -> [Char]
backingName = \case
  OnSqlite -> "on SQLite"
  OnPostgres _ -> "on PostgreSQL"
  PostgresNotRun _ -> "on PostgreSQL"

-- | Start only the databases the selected group needs. An explicit
-- PostgreSQL group requires a server URL and cannot pass as pending.
-- The default local run may start its own cluster, as before.
withBackings :: TestGroup -> ([Backing] -> IO a) -> IO a
withBackings selection act = case selection of
  UnitTests -> act []
  SqliteTests -> act [OnSqlite]
  _ -> withPostgresBackings selection (\pg -> act ([OnSqlite | selection == AllTests] <> pg))

-- | The PostgreSQL backing of a group that has one ('AllTests' or
-- 'PostgresTests'), as a list: one backing, or none in a wiki-server built
-- without PostgreSQL.
withPostgresBackings :: TestGroup -> ([Backing] -> IO a) -> IO a

-- | A place on a PostgreSQL server: a database made for the example in
-- the data directory, and dropped afterwards. The database is a copy of
-- the template ('templateName'), so it is at the program's current schema
-- and holds what the migrations put there, as if a storage had migrated
-- it but never opened it.
withPostgresPlace :: PgServer -> FilePath -> (Place -> IO a) -> IO a

-- | A place on a PostgreSQL server whose database is empty: made from
-- nothing for the example, with no schema and no tables, and dropped
-- afterwards. This is for an example that needs a database no program has
-- migrated: one about migrations or schema versions, one that restores a
-- backup into the database, or one that checks how a database with no
-- wiki is treated.
withEmptyPostgresPlace :: PgServer -> FilePath -> (Place -> IO a) -> IO a

-- | A connection of its own to a PostgreSQL database.
withPostgresConnection :: PgDatabase -> (forall be. (Backend be) => Connection be -> IO a) -> IO a

#ifdef WIKI_POSTGRES
withPostgresBackings selection act' = do
  let run pg = act' [pg]
  configured <- lookupEnv "WIKI_TEST_DATABASE_URL"
  when (selection == PostgresTests && maybe True (T.null . T.strip . T.pack) configured) $
    ioError (userError "The postgres test group requires WIKI_TEST_DATABASE_URL")
  case configured of
    Just url -> do
      dump <- fromMaybe defaultPgPrograms.dump <$> lookupEnv "WIKI_TEST_PG_DUMP"
      restore <- fromMaybe defaultPgPrograms.restore <$> lookupEnv "WIKI_TEST_PG_RESTORE"
      server <- newPgServer (T.pack url) PgPrograms {dump, restore}
      -- The server outlives the run, so the template is dropped at the
      -- end, if an example made it. A run that made none (one with
      -- --dry-run, or with no PostgreSQL example matched) never connects,
      -- so the server need not be up for it. A cluster of the tests' own
      -- is deleted whole instead.
      run (OnPostgres server) `finally` dropTemplate server
    Nothing ->
      findPostgres >>= \case
        Nothing -> run (PostgresNotRun "PostgreSQL is not at hand: set WIKI_TEST_DATABASE_URL, or put initdb and pg_ctl on the PATH")
        Just bin -> stoppedByTerm . withCluster bin $ \url ->
          run . OnPostgres =<< newPgServer url PgPrograms {dump = bin </> "pg_dump", restore = bin </> "pg_restore"}

-- | A server of the tests, for a run: with a namespace of the run's own,
-- made of the time it began and eight random letters and digits.
newPgServer :: Text -> PgPrograms -> IO PgServer
newPgServer url programs = do
  made <- newIORef 0
  template <- newMVar False
  swept <- newMVar False
  began <- round <$> getPOSIXTime
  bytes <- getRandomBytes 8
  let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
      random = T.pack [T.index letters (fromIntegral b `mod` T.length letters) | b <- BS.unpack bytes]
  pure PgServer {url, made, programs, template, namespace = namespaceFor began random, swept}

-- The copy is made with the strategy FILE_COPY, which copies the
-- template's files as they are, rather than the default WAL_LOG, which
-- writes every block of the template to the write-ahead log. On this
-- small template FILE_COPY made the PostgreSQL tests about 5% faster.
-- STRATEGY needs PostgreSQL 15 or newer.
withPostgresPlace server dir act = do
  ensureTemplate server
  withDatabaseMade server (" TEMPLATE " <> templateName server <> " STRATEGY FILE_COPY") dir act

withEmptyPostgresPlace server dir = withDatabaseMade server "" dir

-- | A place whose database is made with @CREATE DATABASE@ and these
-- options, and dropped afterwards whatever is still connected to it. Its
-- name is the run's namespace and a count.
withDatabaseMade :: PgServer -> Text -> FilePath -> (Place -> IO a) -> IO a
withDatabaseMade server options dir act = do
  sweepOnce server
  n <- atomicModifyIORef' server.made (\k -> (k + 1, k + 1))
  let name = server.namespace <> show n
  bracket_ (adminStatement server ("CREATE DATABASE " <> name <> options)) (adminStatement server ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)")) $
    act Place {dataDir = dir, database = postgresAt (encodeUtf8 (databaseUrl server.url name)), programs = server.programs}

-- | The name of the database the run's examples' databases are copied
-- from. Each run has its own: a run's template is at that run's program's
-- schema, and another run may drop or copy it at any moment.
templateName :: PgServer -> Text
templateName server = server.namespace <> "template"

-- | Make the template database, if no example has made it yet: a new
-- database that the program's own 'migrate' brings to the current schema.
-- Nothing else is written to it: opening a storage writes more (the home
-- document), and each example's storage does that on its own copy.
--
-- PostgreSQL copies a database only while nobody is connected to it. The
-- connection that migrates the template is closed before any copy, and the
-- template then refuses connections, so a test that connected to it by
-- mistake would fail at once rather than make another example's copy
-- fail. When making it fails, the lock is given back as it was, so the
-- next example tries again and reports the same failure.
ensureTemplate :: PgServer -> IO ()
ensureTemplate server = modifyMVar_ server.template $ \ready -> do
  unless ready $ do
    sweepOnce server
    adminStatement server ("DROP DATABASE IF EXISTS " <> templateName server <> " WITH (FORCE)")
    adminStatement server ("CREATE DATABASE " <> templateName server)
    withPostgresConnection PgDatabase {url = encodeUtf8 (databaseUrl server.url (templateName server)), password = Nothing} (void . migrate)
    adminStatement server ("ALTER DATABASE " <> templateName server <> " WITH ALLOW_CONNECTIONS false")
  pure True

-- | Drop the template database at the end of a run, if an example made
-- it. A run that made none never connects to the server.
dropTemplate :: PgServer -> IO ()
dropTemplate server = do
  made <- readMVar server.template
  when made $ adminStatement server ("DROP DATABASE IF EXISTS " <> templateName server <> " WITH (FORCE)")

-- | Drop, once per run and before the run makes its first database, the
-- databases of the tests' namespace that runs began more than six hours
-- ago. A run drops its databases as it goes, and its template when it
-- ends, so such databases are a killed run's. No run lasts six hours (the
-- whole PostgreSQL group takes about a quarter of an hour), so no live
-- run's database is dropped, while two runs at once never share a name
-- and a leftover never stands in the way. A database that cannot be
-- dropped is left for the next run: the sweep never fails a run. Names in
-- the shape of the tests' before the namespace (@wiki_test_template@,
-- @wiki_test_N@) are left alone: their age cannot be told, and a run of an
-- older checkout may be using them; @toolchain/ci-postgres.sh restart@
-- clears them.
sweepOnce :: PgServer -> IO ()
sweepOnce server = modifyMVar_ server.swept $ \done -> do
  unless done $ do
    now <- round <$> getPOSIXTime
    listed <- try @SomeException (bracket (Pg.connectPostgreSQL (BC.pack (toS server.url))) Pg.close (\c -> Pg.query_ c "SELECT datname FROM pg_database WHERE datname LIKE 'wiki\\_test\\_%'"))
    for_ [name | Pg.Only (name :: Text) <- either (const []) identity listed, Just began <- [namespaceBegan name], began < now - 6 * 3600] $ \name ->
      void (try @SomeException (adminStatement server ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)")))
  pure True

-- | Run one statement on the database of the server's URL, on a connection
-- of its own: how databases are made and dropped.
adminStatement :: PgServer -> Text -> IO ()
adminStatement server q =
  bracket (Pg.connectPostgreSQL (BC.pack (toS server.url))) Pg.close (\c -> void (Pg.execute_ c (Query (encodeUtf8 q))))

withPostgresConnection db act = bracket (openPostgres db) closePostgres act

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
    -- The cluster listens on no TCP port (listen_addresses is empty), only
    -- on a Unix socket in its own directory, which the port only names
    -- (.s.PGSQL.5432). No other cluster's socket is in that directory, so
    -- PostgreSQL's default port cannot collide.
    let port = 5432 :: Int
        run :: FilePath -> [[Char]] -> IO ()
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
#else
-- Without PostgreSQL there is no PostgreSQL backing to run: the note says
-- so, and the group runs on SQLite alone, or not at all.
withPostgresBackings _ act' = do
  hPutStrLn stderr ("The PostgreSQL tests are left out: " <> withoutPostgres)
  act' []

withPostgresPlace _ _ _ = ioError (userError (toS withoutPostgres))

withEmptyPostgresPlace _ _ _ = ioError (userError (toS withoutPostgres))

withPostgresConnection _ _ = ioError (userError (toS withoutPostgres))
#endif

-- | The URL of another database of the same server: the same URL with
-- the database's name in place of the one it has.
databaseUrl :: Text -> Text -> Text
databaseUrl base name =
  let (scheme, rest) = T.breakOnEnd "://" base
      (authority, pathAndQuery) = T.breakOn "/" rest
      query = T.dropWhile (/= '?') pathAndQuery
   in scheme <> authority <> "/" <> name <> query

-- | The start of every database name a run of the tests makes on a server
-- other runs may share: @wiki_test_<began>_<random>_@, with the seconds
-- since 1970 when the run began and eight random lower-case letters and
-- digits. A run's names are this and a count, or this and @template@.
-- toolchain/rehearse-ci.sh and toolchain/smoke-test-postgres.mjs make
-- their names in the same shape, so that 'sweepOnce' drops their
-- leftovers too.
namespaceFor :: Integer -> Text -> Text
namespaceFor began random = "wiki_test_" <> show began <> "_" <> random <> "_"

-- | When the run that made a database of the tests' namespace began, from
-- its name; 'Nothing' for a name of another shape.
namespaceBegan :: Text -> Maybe Integer
namespaceBegan name = do
  rest <- T.stripPrefix "wiki_test_" name
  let (digits, afterDigits) = T.span isDigit rest
  began <- readMaybe (T.unpack digits)
  random <- T.stripPrefix "_" afterDigits
  guard (T.length (T.takeWhile (/= '_') random) == 8 && "_" `T.isPrefixOf` T.drop 8 random)
  pure began

-- | The namespace's names: within PostgreSQL's 63 bytes, the longest
-- included (a count as large as an 'Int', and the scripts' longest
-- suffixes), and read back to the time their run began.
namesUnitSpec :: Spec
namesUnitSpec = describe "the PostgreSQL tests' database names" $ do
  it "fit in PostgreSQL's 63 bytes, the longest included" $ do
    let longest = namespaceFor 99999999999 "abcdefgh"
    for_ [show (maxBound :: Int), "template", "rehearsal_scratch", "smoke_restored"] $ \suffix ->
      T.length (longest <> suffix) `shouldSatisfy` (<= 63)
  it "tell when their run began, and nothing of names of another shape" $ do
    namespaceBegan (namespaceFor 1762800000 "k3x9q0az" <> "17") `shouldBe` Just 1762800000
    namespaceBegan (namespaceFor 1762800000 "k3x9q0az" <> "template") `shouldBe` Just 1762800000
    map namespaceBegan ["wiki_test_template", "wiki_test_17", "wiki_smoke_42", "wiki_test_1762800000_short_1", "postgres"] `shouldBe` replicate 5 Nothing

-- | A place for an example's wiki in a data directory: on SQLite, the
-- directory's own file, not there yet; on PostgreSQL, a database made for
-- the example, already at the current schema, and dropped afterwards.
-- Either way no storage has opened it yet, so it holds no wiki's content.
-- Pending, for PostgreSQL that is not at hand.
withPlace :: Backing -> FilePath -> (Place -> IO a) -> IO a
withPlace backing = placeWith backing withPostgresPlace

-- | A place whose database is empty: no schema, no tables. On SQLite this
-- is the same as 'withPlace', a file that is not there yet; on
-- PostgreSQL, a database made from nothing ('withEmptyPostgresPlace'). An
-- example that looks at a database before any program has migrated it, or
-- restores a backup into it, uses this one.
withEmptyPlace :: Backing -> FilePath -> (Place -> IO a) -> IO a
withEmptyPlace backing = placeWith backing withEmptyPostgresPlace

-- | A place on a backing, with this way of making a PostgreSQL database.
placeWith :: Backing -> (PgServer -> FilePath -> (Place -> IO a) -> IO a) -> FilePath -> (Place -> IO a) -> IO a
placeWith backing onPostgres dir act = case backing of
  OnSqlite -> act (inDataDir dir)
  PostgresNotRun why -> pendingWith (toS why) >> panic "pendingWith returned"
  OnPostgres server -> onPostgres server dir act

-- | The command line's choice of a database, for a place: what a test
-- gives a server or a console command to find the place's database.
choiceOf :: Database -> DatabaseChoice
choiceOf = \case
  SqliteFile file -> SqliteChosen file
  PostgresAt db -> PostgresChosen (decodeUtf8 db.url) Nothing

-- | The console's options for a place.
placeOptionsOf :: Place -> PlaceOptions
placeOptionsOf at = PlaceOptions {dataDir = at.dataDir, database = choiceOf at.database, programs = at.programs}

-- | Make a database forget one step of its schema, as if the step had
-- never been applied to it: the step's row in @wiki_schema@ goes, after
-- the statements given, which undo what the step made (none for a step
-- that made nothing). The next migration applies that step again, and only
-- that one ('Wiki.Server.Storage.Migrate' applies every step not
-- recorded), so the steps after it need no undoing: a new step costs a test
-- that forgets an older one nothing.
forgetStep :: (Backend be) => Int -> [Text] -> Connection be -> IO ()
forgetStep n undo c = do
  traverse_ (runScript c) undo
  runScript c ("DELETE FROM wiki_schema WHERE version = " <> show n <> ";")

-- | A connection of its own to a place's database, outside any storage:
-- for a test that looks at the database as the storage leaves it, or
-- prepares one for the storage to find.
withConnectionTo :: Place -> (forall be. (Backend be) => Connection be -> IO a) -> IO a
withConnectionTo at act = case at.database of
  SqliteFile file -> bracket (openSqlite ReadWrite file) closeSqlite act
  PostgresAt db -> withPostgresConnection db act
