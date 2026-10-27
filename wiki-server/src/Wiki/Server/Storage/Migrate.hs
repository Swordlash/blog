{-# LANGUAGE TemplateHaskell #-}
-- The migrations are embedded from a directory ('embedDir'), and GHC only
-- knows the files it found there when it last compiled this module: a file
-- added later would not make it compile again, and the program would carry
-- the schema without it. cabal does see the new file (the package's
-- extra-source-files has the directory) and builds the package again, so
-- this module is compiled whenever the package is, which is cheap; the
-- modules that use it are compiled again only if what it exports changed.
{-# OPTIONS_GHC -fforce-recomp #-}

-- | The database's schema, as numbered SQL files applied in order.
--
-- Each file of @wiki-server/migrations@ is named @NNNN-what-it-does.sql@ and
-- is one step from the schema before it to the next; the files are embedded
-- into the program when it is compiled, so the binary that is deployed
-- carries the schema it needs. A database records the steps it has had in
-- @schema_version@, one row per step, and 'migrate' applies the ones it has
-- not, in order and all in one transaction: a database is at one version or
-- the next, never half-way, and a step that fails leaves it as it was. A
-- step once released is never edited: a change to the schema is a new file.
--
-- PostgreSQL has a branch of its own (WP5.7 of docs/PLAN.md, a spike):
-- @migrations/postgresql@ holds, for every step, a file of the same name
-- that makes the same schema in PostgreSQL's SQL ('postgresMigrations'),
-- applied by 'migrateSql' through persistent. The two lists are numbered
-- alike, and a step is written in both or in neither.
module Wiki.Server.Storage.Migrate
  ( Migration (..)
  , migrations
  , postgresMigrations
  , migrate
  , applyMigrations
  , migrateSql
  , schemaVersion
  , SchemaTooNew (..)
  )
where

import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Persist.Sql (PersistValue (..), Single (..), rawExecute, rawSql, toPersistValue)
import Database.SQLite.Simple (Connection (..), Only (..), execute, execute_, query_, withImmediateTransaction)
import Database.SQLite3 qualified as SQLite
import Protolude
import System.FilePath (splitDirectories, takeBaseName, takeExtension)
import Wiki.Server.Storage.Rows (Sql, Stamp (..))

-- | One step of the schema.
data Migration = Migration
  { version :: Int
  -- ^ Its number, from its file's name: 1 for the first.
  , name :: Text
  -- ^ Its file's name, for a person to read.
  , statements :: Text
  -- ^ The SQL it runs, any number of statements.
  }
  deriving stock (Eq, Show)

-- | Every step this program knows, in order, from the files it was compiled
-- with: SQLite's, those at the top of the directory.
migrations :: [Migration]
migrations = stepsIn []

-- | Every step in PostgreSQL's SQL, in order: the files of
-- @migrations/postgresql@.
postgresMigrations :: [Migration]
postgresMigrations = stepsIn ["postgresql"]

-- | The steps in a directory under @migrations@, from the files the program
-- was compiled with ('embedDir' embeds the subdirectories' too).
stepsIn :: [FilePath] -> [Migration]
stepsIn dir =
  sortOn
    (\m -> m.version)
    [ Migration {version, name = T.pack (takeBaseName file <> ".sql"), statements = decodeUtf8 contents}
    | (file, contents) <- embedded
    , takeExtension file == ".sql"
    , take (length dir) (splitDirectories file) == dir
    , length (splitDirectories file) == length dir + 1
    , let version = fromMaybe (panic ("a migration not named NNNN-….sql: " <> T.pack file)) (number file)
    ]
  where
    number file = readMaybe (takeWhile isDigit (takeBaseName file))

embedded :: [(FilePath, ByteString)]
embedded = $(makeRelativeToProject "migrations" >>= embedDir)

-- | Bring a database up to this program's schema; what is given back is the
-- versions it applied, none for a database that was up to date already.
migrate :: Connection -> IO [Int]
migrate = applyMigrations migrations

-- | Apply the steps a database has not had yet, in one transaction. A
-- database at a version this program does not know (one a newer program has
-- migrated) is refused with an exception that says so, and left alone.
applyMigrations :: [Migration] -> Connection -> IO [Int]
applyMigrations steps c = withImmediateTransaction c $ do
  execute_ c "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY NOT NULL, applied_at TEXT NOT NULL)"
  current <- versionIn c
  let known = maybe 0 (\m -> m.version) (lastMay steps)
  when (current > known) $
    throwIO SchemaTooNew {found = current, known}
  let pending = filter (\m -> m.version > current) steps
  for_ pending $ \m -> do
    SQLite.exec c.connectionHandle m.statements
    now <- getCurrentTime
    execute c "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)" (m.version, Stamp now)
  pure (map (\m -> m.version) pending)

-- | 'applyMigrations' through persistent, for PostgreSQL: the steps a
-- database has not had yet, in the transaction the caller runs it in
-- ('Database.Persist.Sql.runSqlConn'), which on PostgreSQL holds the
-- tables' changes too. Each step is sent whole, as one string of
-- statements; postgresql-simple would take a question mark in it for a
-- parameter, so the files have none (a test says so).
migrateSql :: [Migration] -> Sql [Int]
migrateSql steps = do
  rawExecute "CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY NOT NULL, applied_at TEXT NOT NULL)" []
  current <- maybe 0 unSingle . head <$> rawSql "SELECT coalesce(max(version), 0) FROM schema_version" []
  let known = maybe 0 (\m -> m.version) (lastMay steps)
  when (current > known) $
    liftIO (throwIO SchemaTooNew {found = current, known})
  let pending = filter (\m -> m.version > current) steps
  for_ pending $ \m -> do
    rawExecute m.statements []
    now <- liftIO getCurrentTime
    rawExecute "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)" [PersistInt64 (fromIntegral m.version), toPersistValue (Stamp now)]
  pure (map (\m -> m.version) pending)

-- | A database at a version of the schema this program does not know: a
-- newer program has migrated it, and this one cannot tell what it holds.
data SchemaTooNew = SchemaTooNew
  { found :: Int
  , known :: Int
  }
  deriving stock (Eq, Show)

instance Exception SchemaTooNew where
  displayException e =
    "The database is at version " <> show e.found <> " of the schema, newer than this program's " <> show e.known <> ": a newer wiki-server has written it."

-- | The version a database is at: the last step it has had, 0 for none.
schemaVersion :: Connection -> IO Int
schemaVersion c = do
  tables <- query_ c "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'"
  case tables of
    [Only (1 :: Int)] -> versionIn c
    _ -> pure 0

versionIn :: Connection -> IO Int
versionIn c = do
  rows <- query_ c "SELECT coalesce(max(version), 0) FROM schema_version"
  pure (maybe 0 fromOnly (head rows))
