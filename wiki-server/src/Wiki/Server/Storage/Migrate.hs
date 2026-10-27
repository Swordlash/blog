{-# LANGUAGE TemplateHaskell #-}
-- The migrations are embedded from a directory ('embedDir'), and GHC only
-- knows the files it found there when it last compiled this module: a file
-- added later would not trigger a recompilation, and the program would
-- carry the schema without it. cabal does see the new file (the package's
-- extra-source-files lists the directory) and rebuilds the package, so this
-- module is recompiled whenever the package is, which is cheap; the
-- modules that use it are recompiled only if its exports changed.
{-# OPTIONS_GHC -fforce-recomp #-}

-- | The database's schema migrations: numbered SQL files applied in order.
--
-- Each file of @wiki-server/migrations@ is named @NNNN-what-it-does.sql@
-- and is one step from the previous schema to the next. The files are
-- embedded into the program when it is compiled, so the deployed binary
-- carries the schema it needs. A database records the steps applied to it
-- in @schema_version@, one row per step, and 'migrate' applies the missing
-- ones, in order and in one transaction: a database is at one version or
-- the next, never halfway, and a step that fails leaves it unchanged. A
-- step once released is never edited: a change to the schema is a new
-- file.
module Wiki.Server.Storage.Migrate
  ( Migration (..)
  , migrations
  , migrate
  , applyMigrations
  , schemaVersion
  , SchemaTooNew (..)
  )
where

import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Connection (..), Only (..), execute, execute_, query_, withImmediateTransaction)
import Database.SQLite3 qualified as SQLite
import Protolude
import System.FilePath (takeBaseName, takeExtension)
import Wiki.Server.Storage.Rows (Stamp (..))

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

-- | Every step this program knows, in order, from the files it was
-- compiled with.
migrations :: [Migration]
migrations =
  sortOn
    (\m -> m.version)
    [ Migration {version, name = T.pack file, statements = decodeUtf8 contents}
    | (file, contents) <- $(makeRelativeToProject "migrations" >>= embedDir)
    , takeExtension file == ".sql"
    , let version = fromMaybe (panic ("a migration not named NNNN-….sql: " <> T.pack file)) (number file)
    ]
  where
    number file = readMaybe (takeWhile isDigit (takeBaseName file))

-- | Migrate a database to this program's schema. The result is the
-- versions applied, none for a database that was already up to date.
migrate :: Connection -> IO [Int]
migrate = applyMigrations migrations

-- | Apply the steps a database has not had yet, in one transaction. A
-- database at a version this program does not know (one a newer program
-- has migrated) is refused with an exception that says so, and left alone.
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

-- | A database's schema version: the last step applied to it, 0 for none.
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
