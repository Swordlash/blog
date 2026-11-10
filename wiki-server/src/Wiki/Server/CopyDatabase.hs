-- | @wiki-server copy-database@: copy the wiki's database into another,
-- empty one, such as a wiki in SQLite into PostgreSQL (WP5.80a of
-- docs/PLAN.md, issue #203).
--
-- > wiki-server copy-database --data DIR [DATABASE] --to-database URL [--to-database-password-file FILE]
-- > wiki-server copy-database --data DIR [DATABASE] --to-sqlite FILE
--
-- DATABASE names the database to copy, as for every command ("Wiki.Server.Options"):
-- by default the SQLite file @DIR\/wiki.sqlite@. The copy itself, and what
-- it checks, is "Wiki.Server.Storage.Copy"'s. This module finds the two
-- databases, makes sure nothing else has them open, and says what
-- happened.
--
-- No server may run on the database to copy, nor on the target: the
-- command takes the data directory's lock (@DIR\/wiki.lock@, which a
-- running server holds), and on PostgreSQL the database's lock alone, as
-- a restore does, which a server or a console of any data directory holds
-- shared while it has the database open. The attachments' files are not
-- copied: they stay in @DIR\/attachments@, which a server on the copy uses
-- with the same @--data DIR@.
--
-- A SQLite target (@--to-sqlite FILE@) is a new file: the command makes
-- it exclusively, before anything else that can fail, and refuses a file
-- that is there already. When the copy fails it deletes that file, and
-- only that one: a file another process put at the path meanwhile is left
-- alone. A PostgreSQL target is never dropped or emptied: the copy's
-- transaction is rolled back, and the database holds nothing of the copy.
--
-- The program ends with 0 when the copy is made and checked; 4 when the
-- database to copy is not at this program's version of the schema
-- (migrate it first, as @wiki-server check@ ends with 4 then); 5 when it
-- does not read whole; 6 when the copy was refused before anything was
-- written (a server has a database open, the target is not empty, the
-- database to copy is not there); 1 when the copy failed. The target is
-- left as it was in every case but 0.
module Wiki.Server.CopyDatabase
  ( CopyOptions (..)
  , copyParser
  , CopyOutcome (..)
  , runCopy

    -- * A SQLite target
  , Reserved
  , reserve
  , release
  )
where

import Data.Text qualified as T
import Database.SQLite.Simple qualified as Sqlite
import Options.Applicative
import Protolude
import System.Directory (doesFileExist, removeFile)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (deviceID, fileID, getFdStatus, getFileStatus)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd)
import Wiki.Server.Options (DatabaseChoice (..), PlaceOptions (..), databaseUrl, placeOptions, resolvePlace)
import Wiki.Server.Storage (Place (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Backup (lockDataDir, unlockDataDir)
import Wiki.Server.Storage.Copy (CopyProblem (..), TableCopied (..), copyDatabase)
import Wiki.Server.Storage.Layout (Database (..), PgDatabase (..), withoutPassword)
import Wiki.Server.Storage.Migrate (OldSchema)
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, openSqlite)
#ifdef WIKI_POSTGRES
import Database.PostgreSQL.Simple qualified as Pg
import Wiki.Server.Storage.Postgres (closePostgres, openPostgres, withDatabaseAlone)
#else
import Wiki.Server.Storage.Layout (withoutPostgres)
#endif

-- | @wiki-server copy-database@'s options: where the wiki is, and the
-- database to copy it into.
data CopyOptions = CopyOptions
  { place :: PlaceOptions
  , target :: DatabaseChoice
  -- ^ 'PostgresChosen' or 'SqliteChosen': the command line names it.
  }
  deriving stock (Eq, Show)

-- | The options of @wiki-server copy-database@.
copyParser :: Parser CopyOptions
copyParser = CopyOptions <$> placeOptions <*> (postgres <|> sqlite)
  where
    postgres =
      PostgresChosen
        <$> option (databaseUrl "put the password in --to-database-password-file FILE") (long "to-database" <> metavar "URL" <> help "Copy into this PostgreSQL database, postgres://USER@HOST:PORT/NAME, without its password: an empty one, as createdb makes it")
        <*> optional (strOption (long "to-database-password-file" <> metavar "FILE" <> help "The file that holds that database's password"))
    sqlite = SqliteChosen <$> strOption (long "to-sqlite" <> metavar "FILE" <> help "Copy into this SQLite file instead, a new one: the copy makes it, and refuses a file that is there already")

-- | How @wiki-server copy-database@ ended, and so how the program ends
-- (the module's documentation lists the exit codes).
data CopyOutcome
  = -- | Copied and checked: the lines to show.
    Copied [Text]
  | -- | The database to copy is not at this program's version of the schema.
    CopyNotMigrated Text
  | -- | The database to copy does not read whole: what did not read.
    CopyUnreadable [Text]
  | -- | Refused before anything was written: why.
    CopyRefused Text
  | -- | The copy failed, and the target is as it was: why.
    CopyFailed Text
  deriving stock (Eq, Show)

-- | Copy the database, as the module's documentation says.
runCopy :: CopyOptions -> IO CopyOutcome
runCopy o =
  either identity identity
    <$> runExceptT
      ( do
          origin <- ExceptT (first CopyRefused <$> resolvePlace o.place.dataDir o.place.database o.place.programs)
          into <- ExceptT (first CopyRefused <$> resolvePlace o.place.dataDir o.target o.place.programs)
          case origin.database of
            SqliteFile file -> unlessM (liftIO (doesFileExist file)) $ throwError (CopyRefused ("There is no database " <> toS file <> " to copy."))
            PostgresAt _ -> pass
          when (origin.database == into.database) $ throwError (CopyRefused "The database to copy and the database to copy into are the same.")
          -- A SQLite target is a new file, which this invocation makes before
          -- anything else that can fail, so that a failure deletes only the
          -- file this invocation made.
          made <- case into.database of
            SqliteFile file -> Just <$> ExceptT (reserve file)
            PostgresAt _ -> pure Nothing
          outcome <- liftIO (copyInto origin into `onException` traverse_ release made)
          liftIO $ case outcome of
            Copied _ -> traverse_ keep made
            _ -> traverse_ release made
          pure outcome
      )

-- | 'Reserved' is a SQLite file this invocation made: its path, and the
-- file itself, held open until the copy is done. While it is held open its
-- inode cannot be given to another file, so a file at the path with the
-- same device and inode is this one ('release').
data Reserved = Reserved
  { file :: FilePath
  , held :: Fd
  }

-- | Make a new, empty SQLite file for the copy, readable by its owner
-- only, as the database is. It is made exclusively (@O_EXCL@): a file of
-- that name that is there already, or made by another process at the same
-- moment, is refused, and never taken over. The files SQLite keeps beside
-- a database must not be there either, since SQLite would read them as the
-- new file's.
reserve :: FilePath -> IO (Either CopyOutcome Reserved)
reserve file = do
  beside <- filterM doesFileExist [file <> "-wal", file <> "-shm", file <> "-journal"]
  if not (null beside)
    then pure (Left (CopyRefused ("There are files of a SQLite database at " <> toS file <> " already (" <> T.intercalate ", " (map toS beside) <> "): --to-sqlite names a new file.")))
    else
      try (openFd file WriteOnly defaultFileFlags {exclusive = True, creat = Just 0o600}) <&> \case
        Left e
          | isAlreadyExistsError e -> Left (CopyRefused ("There is a file " <> toS file <> " already: --to-sqlite names a new file, which the copy makes."))
          | otherwise -> Left (CopyRefused ("The file " <> toS file <> " cannot be made: " <> show e))
        Right held -> Right Reserved {file, held}

-- | Delete a SQLite file this invocation made, with the files SQLite made
-- beside it, if the path still names that file; a file another process
-- put at the path is left alone. Then let the file go.
release :: Reserved -> IO ()
release r = flip finally (closeFd r.held) $ do
  mine <- getFdStatus r.held
  there <- try @IOException (getFileStatus r.file)
  case there of
    Right s
      | deviceID s == deviceID mine && fileID s == fileID mine ->
          for_ [r.file <> "-wal", r.file <> "-shm", r.file <> "-journal", r.file] $ \f -> whenM (doesFileExist f) (removeFile f)
    _ -> pass

-- | Keep a SQLite file this invocation made, the copy in it: let it go.
keep :: Reserved -> IO ()
keep r = closeFd r.held

-- | Copy a place's database into another's, once both are found: the
-- source's data directory locked, each database opened alone, and the copy
-- made.
copyInto :: Place -> Place -> IO CopyOutcome
copyInto origin into =
  lockDataDir origin.dataDir >>= \case
    Left held -> pure (CopyRefused held)
    Right lock -> do
      result <-
        try @SomeException (withAlone ReadOnly origin.database (\source -> withAlone ReadWrite into.database (\target -> copyDatabase source target)))
          `finally` unlockDataDir lock
      pure $ case result of
        Left e
          | Just old <- fromException @OldSchema e -> CopyNotMigrated (toS (displayException old))
          | otherwise -> CopyFailed ("The copy failed, and " <> describe into.database <> " is as it was: " <> toS (displayException e))
        Right (Left inUse) -> CopyRefused inUse
        Right (Right (Left inUse)) -> CopyRefused inUse
        Right (Right (Right (Left problem))) -> explain origin.database into.database problem
        Right (Right (Right (Right tables))) -> Copied (report origin into tables)

-- | What a successful copy says: each table with its rows, and what to do
-- next.
report :: Place -> Place -> [TableCopied] -> [Text]
report origin into tables =
  [ t.table <> ": " <> rowsText t.rows <> (if t.timesCut > 0 then ", " <> show t.timesCut <> " of them with a time cut to the microsecond" else "")
  | t <- tables
  ]
    <> [ "Copied "
           <> describe origin.database
           <> " into "
           <> describe into.database
           <> ": "
           <> rowsText (sum (map (\t -> t.rows) tables))
           <> " in "
           <> show (length tables)
           <> " tables. Each table of the copy holds what the source holds, and the copy reads whole as this program reads a database."
       , "The source is unchanged. The attachments' files stay in " <> toS origin.dataDir <> "/attachments: serve the copy with --data " <> toS origin.dataDir <> " and " <> option' into.database <> "."
       ]
  where
    option' = \case
      SqliteFile file -> "--sqlite " <> toS file
      PostgresAt db -> "--database " <> decodeUtf8 (withoutPassword db.url) <> maybe "" (const " and its password file") db.password
    rowsText n = show n <> (if n == 1 then " row" else " rows")

-- | What a copy that did not happen says, and how the program ends.
explain :: Database -> Database -> CopyProblem -> CopyOutcome
explain origin into = \case
  SourceNotMigrated at known ->
    CopyNotMigrated (capitalised (describe origin) <> " is at version " <> show at <> " of the schema, and this program copies version " <> show known <> ": run wiki-server migrate on it first.")
  SourceUnreadable lines' -> CopyUnreadable (("Some of " <> describe origin <> " does not read as this program reads it (wiki-server check says more); nothing was copied:") : lines')
  TablesUnknown tables -> CopyRefused ("These tables are not ones this program copies: " <> T.intercalate ", " tables <> ". Nothing was copied; copy the database with the wiki-server it belongs to.")
  TargetNotEmpty tables -> CopyRefused (capitalised (describe into) <> " is not empty (it holds " <> T.intercalate ", " (take 5 tables) <> (if length tables > 5 then ", …" else "") <> "): copy into an empty database, one createdb has just made.")
  RowRefused table row e ->
    CopyFailed (capitalised (describe into) <> " refused " <> maybe ("a row of the table " <> table) (\r -> "the row " <> r <> " of the table " <> table) row <> ": " <> refusal e <> ". Nothing was copied, and the database is as it was.")
  TextNotKept table row ->
    CopyFailed ("The row " <> row <> " of the table " <> table <> " holds a text with the character NUL, which " <> describe into <> " cannot keep. Nothing was copied.")
  CopyDiffers table why -> CopyFailed ("The table " <> table <> " did not read back from " <> describe into <> " as it was copied (" <> why <> "). Nothing was copied, and the database is as it was.")
  TargetUnreadable lines' -> CopyFailed ("The copy does not read whole as this program reads a database, so it was not kept: " <> T.intercalate "; " lines')

-- | A database as the messages name it, without a password.
describe :: Database -> Text
describe = \case
  SqliteFile file -> "the SQLite database " <> toS file
  PostgresAt db -> "the PostgreSQL database " <> decodeUtf8 (withoutPassword db.url)

-- | A text with its first letter a capital, to start a sentence.
capitalised :: Text -> Text
capitalised t = maybe t (\(c, rest) -> T.cons (toUpper c) rest) (T.uncons t)

-- | Why a database refused a statement: its own message, without the
-- detail PostgreSQL adds, which shows the row's values.
refusal :: SomeException -> Text
refusal e
  | Just s <- fromException @Sqlite.SQLError e = Sqlite.sqlErrorDetails s
  | Just why <- postgresRefusal e = why
  | otherwise = toS (displayException e)

-- | PostgreSQL's message, when the exception is PostgreSQL's.
postgresRefusal :: SomeException -> Maybe Text
#ifdef WIKI_POSTGRES
postgresRefusal e = decodeUtf8 . Pg.sqlErrorMsg <$> fromException @Pg.SqlError e
#else
postgresRefusal _ = Nothing
#endif

-- | Run an action on a connection of its own to a database, held alone:
-- on PostgreSQL with the database's lock taken alone, so that no server or
-- console has it open meanwhile; on SQLite the data directory's lock,
-- taken by the caller, does that. The result is why not, when another
-- holds the lock.
withAlone :: Access -> Database -> (forall be. (Backend be) => Connection be -> IO a) -> IO (Either Text a)
withAlone access database act = case database of
  SqliteFile file -> Right <$> bracket (openSqlite access file) closeSqlite act
#ifdef WIKI_POSTGRES
  PostgresAt db ->
    maybe (Left (capitalised (describe database) <> " is open in a running server or console (of this data directory or another): stop it, and copy again.")) Right
      <$> withDatabaseAlone db (bracket (openPostgres db) closePostgres act)
#else
  PostgresAt _ -> pure (Left withoutPostgres)
#endif
