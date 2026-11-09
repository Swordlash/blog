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
-- schema: numbered steps, applied in order. Most steps are SQL files; a
-- step that SQL alone cannot make is written in Haskell
-- ("Wiki.Server.Storage.Migrate.Code"). SQL is written by hand here, and in
-- those steps, and nowhere else in the storage.
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
-- A step in code ('CodeStep') takes a number of the same sequence, which no
-- file has, and is applied and recorded in the same way ('Step'). The
-- numbers of the files and of the steps in code together must be 1, 2, 3
-- and so on, each once, for each database: a program whose steps are not is
-- refused before it touches a database ('StepsMisnumbered'), and a test of
-- the server checks the program's own steps.
--
-- The numbering began again at 0001 with WP5.22 of docs/PLAN.md, when the
-- storage came to run on PostgreSQL too. A database of an earlier
-- wiki-server is not migrated: it is refused ('OldSchema'), with what to do
-- instead, since its content moves by an export and an import.
module Wiki.Server.Storage.Migrate
  ( Migration (..)
  , migrationsFor
  , Step (..)
  , CodeStep (..)
  , stepNumber
  , stepsFor
  , arrange
  , misnumbered
  , knownVersion
  , migrate
  , applySteps
  , applyMigrations
  , schemaVersion
  , databaseVersion
  , SchemaTooNew (..)
  , OldSchema (..)
  , StepsMisnumbered (..)
  )
where

import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.List ((\\))
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (aggregate_, all_, insert, insertValues, max_, runInsert, runSelectReturningOne, select)
import Protolude
import System.FilePath (dropExtension, takeBaseName, takeExtension)
import Wiki.Server.Storage.Backend (Backend (..), withTransaction)
import Wiki.Server.Storage.Migrate.Code (CodeStep (..), codeSteps)
import Wiki.Server.Storage.Schema (SchemaDb (..), WikiSchema (..), schemaDb)

-- | One schema file, a step of the schema on one database.
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

-- | The schema files of one database (by the suffix of their names,
-- @sqlite@ or @postgres@), in order. These are the steps in SQL only: the
-- database's steps are 'stepsFor'.
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

-- | 'Step' is one step of the schema on one database: a schema file, or a
-- step written in Haskell, which runs on both databases.
data Step
  = InSql Migration
  | InCode CodeStep

-- | A step's number.
stepNumber :: Step -> Int
stepNumber = \case
  InSql m -> m.version
  InCode s -> s.version

-- | A step's name, for a person to read.
stepName :: Step -> Text
stepName = \case
  InSql m -> m.name
  InCode s -> s.name <> " (in code)"

-- | Every step of one database, its schema files and the steps in code, in
-- order.
stepsFor :: Text -> [Step]
stepsFor suffix = arrange (migrationsFor suffix) codeSteps

-- | Schema files and steps in code, in the order of their numbers. Tests
-- give steps of their own here.
arrange :: [Migration] -> [CodeStep] -> [Step]
arrange sql code = sortOn stepNumber (map InSql sql <> map InCode code)

-- | Why steps are not numbered 1, 2, 3 and so on, each number once: the
-- numbers two steps share, with the steps' names, and the numbers no step
-- has. 'Nothing' when they are.
misnumbered :: [Step] -> Maybe Text
misnumbered steps
  | null problems = Nothing
  | otherwise = Just (T.intercalate "; " problems)
  where
    numbers = sort (map stepNumber steps)
    problems =
      [ "step " <> show n <> " is both " <> T.intercalate " and " [stepName s | s <- steps, stepNumber s == n]
      | n : _ : _ <- group numbers
      ]
        <> ["no step is numbered " <> show n | n <- [1 .. fromMaybe 0 (lastMay numbers)] \\ numbers]
        <> ["a step is numbered " <> show n <> ", below 1" | n <- ordNub numbers, n < 1]

-- | The version of the schema this program migrates a database to: the
-- last of its steps, SQL or code, for the database of this suffix.
knownVersion :: Text -> Int
knownVersion suffix = maybe 0 stepNumber (lastMay (stepsFor suffix))

-- | Migrate a database to this program's schema. The result is the
-- versions applied, none for a database that was already up to date.
migrate :: (Backend be) => Connection be -> IO [Int]
migrate c = applySteps (stepsFor (schemaSuffix c)) c

-- | Apply the schema files a database has not had yet, as 'applySteps'
-- does: for steps that are all SQL.
applyMigrations :: (Backend be) => [Migration] -> Connection be -> IO [Int]
applyMigrations = applySteps . map InSql

-- | Apply the steps a database has not had yet, in one transaction, in the
-- order of their numbers, and record each. The numbers must be 1, 2, 3 and
-- so on, each once; steps that are not are refused ('StepsMisnumbered')
-- before the database is touched. A database at a version this program does not know (one a
-- newer program has migrated) is refused with an exception that says so,
-- and so is one that holds tables but no version of this schema
-- ('OldSchema'); either is left alone.
applySteps :: (Backend be) => [Step] -> Connection be -> IO [Int]
applySteps given c = do
  let steps = sortOn stepNumber given
  for_ (misnumbered steps) (throwIO . StepsMisnumbered)
  withTransaction True c $ do
    current <- versionOf c
    let known = maybe 0 stepNumber (lastMay steps)
    when (current > known) $
      throwIO SchemaTooNew {found = current, known}
    let pending = filter (\s -> stepNumber s > current) steps
    for_ pending $ \s -> do
      case s of
        InSql m -> runScript c m.statements
        InCode CodeStep {run} -> run c
      now <- getCurrentTime
      runDb c (runInsert (insert schemaDb.wiki_schema (insertValues [SchemaRow {version = fromIntegral (stepNumber s), applied_at = now}])))
    pure (map stepNumber pending)

-- | The error for steps of the schema whose numbers are not 1, 2, 3 and so
-- on, each once: a step in code given a number a schema file has, or a
-- number left out. It is a fault of the program, not of the database,
-- which is left alone.
newtype StepsMisnumbered = StepsMisnumbered Text
  deriving stock (Eq, Show)

instance Exception StepsMisnumbered where
  displayException (StepsMisnumbered why) =
    "This program's steps of the schema are misnumbered (" <> toS why <> "): the database was not touched. The program is faulty; deploy another build."

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
