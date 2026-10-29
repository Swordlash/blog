{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE TemplateHaskell #-}
-- The schema files are embedded from a directory ('embedDir'), and GHC only
-- knows the files it found there when it last compiled this module: a file
-- added later would not trigger a recompilation, and the program would
-- carry the schema without it. cabal does see the new file (the package's
-- extra-source-files lists the directory) and rebuilds the package, so this
-- module is recompiled whenever the package is, which is cheap; the
-- modules that use it are recompiled only if its exports changed.
{-# OPTIONS_GHC -fforce-recomp #-}

-- | 'Wiki.Server.Storage.Migrate' makes and versions the database's
-- schema: numbered SQL files, applied in order. SQL is written by hand
-- here and nowhere else in the storage.
--
-- Each file of @wiki-server/migrations@ is named
-- @NNNN-what-it-does.\<database>.sql@, one step from the previous schema to
-- the next on one database (@sqlite@ or @postgres@), and each step exists
-- for both. The files are embedded into the program when it is compiled,
-- so the deployed binary carries the schema it needs. A database records
-- the steps applied to it in @wiki_schema@, one row per step (the first
-- step makes that table), and 'migrate' applies the missing ones, in order
-- and in one transaction: a database is at one version or the next, never
-- halfway, and a step that fails leaves it unchanged. A step once released
-- is never edited: a change to the schema is a new file.
--
-- The numbering began again at 0001 with WP5.22 of docs/PLAN.md, when the
-- storage came to run on PostgreSQL too. A database of an earlier
-- wiki-server is not migrated: it is refused ('OldSchema'), with what to do
-- instead, since its content moves by an export and an import.
module Wiki.Server.Storage.Migrate
  ( Migration (..)
  , migrationsFor
  , migrate
  , applyMigrations
  , schemaVersion
  , databaseVersion
  , SchemaTooNew (..)
  , OldSchema (..)
  )
where

import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (aggregate_, all_, insert, insertValues, max_, runInsert, runSelectReturningOne, select)
import Protolude
import System.FilePath (dropExtension, takeBaseName, takeExtension)
import Wiki.Server.Storage.Backend (Backend (..), withTransaction)
import Wiki.Server.Storage.Schema (SchemaDb (..), WikiSchema (..), schemaDb)

-- | One step of the schema, on one database.
data Migration = Migration
  { version :: Int
  -- ^ Its number, from its file's name: 1 for the first.
  , name :: Text
  -- ^ Its file's name, for a person to read.
  , statements :: Text
  -- ^ The SQL it runs, any number of statements.
  }
  deriving stock (Eq, Show)

-- | Every schema file this program was compiled with, by name.
files :: [(FilePath, ByteString)]
files = $(makeRelativeToProject "migrations" >>= embedDir)

-- | The steps of one database (by the suffix of its files' names, @sqlite@
-- or @postgres@), in order.
migrationsFor :: Text -> [Migration]
migrationsFor suffix =
  sortOn
    (\m -> m.version)
    [ Migration {version, name = T.pack file, statements = decodeUtf8 contents}
    | (file, contents) <- files
    , takeExtension file == ".sql"
    , T.pack (takeExtension (dropExtension file)) == "." <> suffix
    , let version = fromMaybe (panic ("a schema file not named NNNN-….<database>.sql: " <> T.pack file)) (number file)
    ]
  where
    number file = readMaybe (takeWhile isDigit (takeBaseName file))

-- | Migrate a database to this program's schema. The result is the
-- versions applied, none for a database that was already up to date.
migrate :: (Backend be) => Connection be -> IO [Int]
migrate c = applyMigrations (migrationsFor (schemaSuffix c)) c

-- | Apply the steps a database has not had yet, in one transaction. A
-- database at a version this program does not know (one a newer program
-- has migrated) is refused with an exception that says so, and so is one
-- that holds tables but no version of this schema ('OldSchema'); either is
-- left alone.
applyMigrations :: (Backend be) => [Migration] -> Connection be -> IO [Int]
applyMigrations steps c =
  withTransaction True c $ do
    current <- versionOf c
    let known = maybe 0 (\m -> m.version) (lastMay steps)
    when (current > known) $
      throwIO SchemaTooNew {found = current, known}
    let pending = filter (\m -> m.version > current) steps
    for_ pending $ \m -> do
      runScript c m.statements
      now <- getCurrentTime
      runDb c (runInsert (insert schemaDb.wiki_schema (insertValues [SchemaRow {version = fromIntegral m.version, applied_at = now}])))
    pure (map (\m -> m.version) pending)

-- | The error for a database at a schema version this program does not
-- know: a newer program has migrated it, and this one cannot tell what it
-- holds.
data SchemaTooNew = SchemaTooNew
  { found :: Int
  , known :: Int
  }
  deriving stock (Eq, Show)

instance Exception SchemaTooNew where
  displayException e =
    "The database is at version " <> show e.found <> " of the schema, newer than this program's " <> show e.known <> ": a newer wiki-server has written it."

-- | The error for a database that holds tables but no version of this
-- schema: a wiki of a wiki-server from before WP5.22 of docs/PLAN.md
-- (which kept its version in @schema_version@), or something else
-- altogether. Its tables are named.
newtype OldSchema = OldSchema [Text]
  deriving stock (Eq, Show)

instance Exception OldSchema where
  displayException (OldSchema tables)
    | "schema_version" `elem` tables =
        "The database holds a wiki of an earlier wiki-server, whose schema this one does not read or migrate. "
          <> "Export the wiki with the earlier server (Administration, Wiki data, Export the wiki), "
          <> "start this one on an empty database, and import the archive there (Administration, Wiki data, Import)."
    | otherwise =
        "The database holds tables that are not a wiki's ("
          <> toS (T.intercalate ", " (take 5 tables))
          <> "): give wiki-server an empty database, or one of its own."

-- | A database's schema version: the last step applied to it, 0 for none.
schemaVersion :: (Backend be) => Connection be -> IO Int
schemaVersion c = do
  tables <- runDb c tableNames
  if "wiki_schema" `elem` tables
    then runDb c lastVersion
    else pure 0

-- | 'schemaVersion', refusing a database that holds tables but none of
-- this schema's version with 'OldSchema': what a backup before a deploy
-- asks, so that a deploy over the database of an earlier wiki-server
-- stops before anything is changed.
databaseVersion :: (Backend be) => Connection be -> IO Int
databaseVersion = versionOf

versionOf :: (Backend be) => Connection be -> IO Int
versionOf c = do
  tables <- runDb c tableNames
  if
    | "wiki_schema" `elem` tables -> runDb c lastVersion
    | null tables -> pure 0
    | otherwise -> throwIO (OldSchema tables)

lastVersion :: (Backend be) => Db be Int
lastVersion = maybe 0 fromIntegral . join <$> runSelectReturningOne (select (aggregate_ (\v -> max_ v.version) (all_ schemaDb.wiki_schema)))
