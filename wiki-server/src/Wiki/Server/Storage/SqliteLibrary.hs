-- | 'Wiki.Server.Storage.SqliteLibrary' is what the server knows of the
-- SQLite library it runs on, and whether it can run on it. wiki-server
-- links the operating system's SQLite (direct-sqlite with its flag
-- @systemlib@, in cabal.project), not a copy of its own, so the library
-- is whatever the machine has installed, and a machine may have one too
-- old for the wiki.
--
-- The server reads the library's version (@sqlite_version()@) and its
-- compile-time options (@PRAGMA compile_options@) once, on a database in
-- memory, the first time a SQLite database is opened. A library the wiki
-- cannot run on is refused there, before any file is touched
-- ('Wiki.Server.Storage.Sqlite.openSqlite'), so every command that opens a
-- SQLite database refuses it: @serve@, @migrate@, @check@, @backup@ and the
-- others. A wiki on PostgreSQL never opens one, and is never refused.
--
-- The oldest version the server runs on, 'oldestSqlite', is 3.32.0. What
-- the server's SQL needs, and since which version SQLite has it:
--
-- * @INSERT … ON CONFLICT@ (Beam's @insertOnConflict@): 3.24.0;
-- * @VACUUM INTO@, with which a backup copies the database: 3.27.0;
-- * up to 32766 parameters in one statement by default: 3.32.0. Before
--   it the default was 999, and the copy of a database writes 200 rows of
--   up to 20 columns with one statement ("Wiki.Server.Storage.Copy"), and
--   a group's members are put in 500 pairs at a time.
--
-- RETURNING (3.35.0), STRICT tables, JSON functions, window functions,
-- generated columns and full-text search are not used. 3.32.0 also lets
-- RHEL 9's SQLite (3.34.1) run the wiki.
--
-- Of the compile-time options, four would break the wiki without an error
-- at the statement that needs them, so they are refused here:
-- @THREADSAFE=0@ (no locks, and the server uses its connections from
-- several threads),
-- @OMIT_WAL@ (@journal_mode = WAL@ then leaves the database in its
-- rollback journal, and readers wait for the writer), @OMIT_FOREIGN_KEY@
-- (@foreign_keys = ON@ then does nothing, and a deletion no longer
-- cascades) and a @MAX_VARIABLE_NUMBER@ below 32766. The options
-- direct-sqlite's own copy was built with (full-text search, JSON, URI
-- file names, the @dbstat@ table) are not used by the wiki, and are not
-- checked.
module Wiki.Server.Storage.SqliteLibrary
  ( SqliteLibrary (..)
  , sqliteLibrary
  , readSqliteLibrary
  , oldestSqlite
  , sqliteRefusal
  , SqliteRefused (..)
  , refuseOldSqlite
  , sqliteLine
  )
where

import Data.Text qualified as T
import Database.SQLite.Simple (Only (..), query_, withConnection)
import Protolude
import System.IO.Unsafe (unsafePerformIO)

-- | The SQLite library the server runs on: its version (@3.45.1@) and
-- its compile-time options as @PRAGMA compile_options@ lists them, without
-- their @SQLITE_@ prefix (@THREADSAFE=1@, @ENABLE_FTS5@).
data SqliteLibrary = SqliteLibrary
  { version :: Text
  , options :: [Text]
  }
  deriving stock (Eq, Show)

-- | Read the library's version and options, on a database in memory.
readSqliteLibrary :: IO SqliteLibrary
readSqliteLibrary =
  withConnection ":memory:" $ \c -> do
    version <- maybe "" fromOnly . head <$> query_ c "SELECT sqlite_version()"
    options <- map fromOnly <$> query_ c "PRAGMA compile_options"
    pure SqliteLibrary {version, options}

-- | The library the process runs on, read once, the first time it is
-- needed: the library is linked into the program, so it cannot change
-- while the program runs. 'Left' says why it could not be read.
sqliteLibrary :: Either Text SqliteLibrary
sqliteLibrary = unsafePerformIO (first (\(e :: SomeException) -> toS (displayException e)) <$> try readSqliteLibrary)
{-# NOINLINE sqliteLibrary #-}

-- | The oldest SQLite the server runs on, as the module's documentation
-- says why.
oldestSqlite :: Text
oldestSqlite = "3.32.0"

-- | Why the server cannot run on a library; 'Nothing' when it can.
sqliteRefusal :: SqliteLibrary -> Maybe Text
sqliteRefusal l
  | maybe True (< numbers oldestSqlite) (versionNumbers l.version) =
      Just
        ( "wiki-server needs SQLite "
            <> oldestSqlite
            <> " or later, and the SQLite library on this machine is "
            <> (if T.null l.version then "of a version it does not say" else l.version)
            <> ": install a newer SQLite (Debian, Ubuntu: libsqlite3-0; RHEL, Fedora: sqlite-libs)."
        )
  | "THREADSAFE=0" `elem` l.options = Just (built "THREADSAFE=0, for programs with one thread, and the server uses its connections from several")
  | "OMIT_WAL" `elem` l.options = Just (built "OMIT_WAL, without the write-ahead log the server's readers read beside its writer with")
  | "OMIT_FOREIGN_KEY" `elem` l.options = Just (built "OMIT_FOREIGN_KEY, without the foreign keys the wiki's schema relies on")
  | Just n <- maxVariables, n < 32766 = Just (built ("MAX_VARIABLE_NUMBER=" <> show n <> ", below SQLite's default of 32766, which the server's statements of many rows rely on"))
  | otherwise = Nothing
  where
    numbers = fromMaybe [] . versionNumbers
    built why = "The SQLite library on this machine (" <> l.version <> ") was built with " <> why <> ": install one built with SQLite's defaults, as the distributions' are."
    maxVariables = head [n | o <- l.options, Just v <- [T.stripPrefix "MAX_VARIABLE_NUMBER=" o], Just n <- [readMaybe (T.unpack v) :: Maybe Int]]

-- | A version's numbers (@3.45.1@ is @[3, 45, 1]@); 'Nothing' for text
-- that is not a version.
versionNumbers :: Text -> Maybe [Int]
versionNumbers t = case traverse (\p -> readMaybe (T.unpack p) :: Maybe Int) (T.splitOn "." (T.strip t)) of
  Just ns@(_ : _) -> Just ns
  _ -> Nothing

-- | Why the server cannot run on the SQLite library it has.
newtype SqliteRefused = SqliteRefused Text
  deriving stock (Show)

instance Exception SqliteRefused where
  displayException (SqliteRefused why) = toS why

-- | Throw 'SqliteRefused' when the library the process runs on is one
-- the server cannot run on, or cannot be read.
refuseOldSqlite :: IO ()
refuseOldSqlite = case sqliteLibrary of
  Left why -> throwIO (SqliteRefused ("The SQLite library's version could not be read: " <> why))
  Right l -> traverse_ (throwIO . SqliteRefused) (sqliteRefusal l)

-- | The line that says which SQLite the server runs on, as @wiki-server
-- check@ prints it.
sqliteLine :: Text
sqliteLine = case sqliteLibrary of
  Left why -> "SQLite: its version could not be read: " <> why
  Right l -> "SQLite " <> l.version <> ", the system's library."
