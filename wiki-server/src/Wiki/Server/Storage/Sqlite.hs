{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Sqlite' is how the storage speaks to SQLite: it
-- opens and sets up a connection, begins and ends transactions, runs a
-- schema file, copies the database into a backup, and searches.
--
-- The queries of the storage are Beam's and run on either database
-- ("Wiki.Server.Storage.Backend"). What is here is what has no Beam
-- equivalent: the @PRAGMA@s every connection is set up with, the
-- transactions (@BEGIN IMMEDIATE@ takes SQLite's write lock as the
-- transaction begins), @VACUUM INTO@ for a backup and @PRAGMA
-- integrity_check@ for checking one. Each is a fixed statement of SQLite's
-- own, not a query, and they are all in this module.
module Wiki.Server.Storage.Sqlite
  ( -- * Connections
    Connection
  , openSqlite
  , closeSqlite
  , Access (..)

    -- * Transactions
  , beginSqlite
  , commitSqlite
  , rollbackSqlite

    -- * The schema
  , runSqliteScript
  , sqliteObjects

    -- * Backups
  , vacuumInto
  , integrityProblems

    -- * The search
  , sqliteSearch
  )
where

import Data.Text qualified as T
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Generic, Table (..), TableEntity, all_, defaultDbSettings, filter_, in_, like_, select, val_, (&&.), (==.))
import Database.Beam qualified as Beam
import Database.Beam.Sqlite (Sqlite, SqliteM)
import Database.SQLite.Simple (Connection (..), Only (..), close, execute, execute_, open, query_, withConnection)
import Database.SQLite3 qualified as SQLite
import Protolude hiding (Generic)
import Wiki.Server.Storage.Schema (PageNodes, Pages (..), WikiDb (..), nodeColumns, wikiDb)

-- | 'Access' is what a connection may do: write (the storage's one
-- writer, and a backup's copy), or only read (the storage's readers). A
-- reader is made read-only (@query_only@), so that a write on it by
-- mistake fails at once instead of running outside the writer's order.
data Access = ReadWrite | ReadOnly
  deriving stock (Eq, Show)

-- | Open a connection on a database file, set up the way every connection
-- of the storage needs: it waits up to ten seconds for another
-- connection's lock before it fails, and checks foreign keys. The database
-- is in WAL mode, which lets a reader read the last committed state while
-- the writer writes, with @synchronous = NORMAL@, which is safe in WAL
-- mode.
openSqlite :: Access -> FilePath -> IO Connection
openSqlite access file = do
  c <- open file
  flip onException (close c) $ do
    execute_ c "PRAGMA busy_timeout = 10000"
    execute_ c "PRAGMA foreign_keys = ON"
    case access of
      ReadWrite -> do
        -- This pragma returns a row, and execute_ refuses a statement
        -- that returns rows.
        _ <- query_ c "PRAGMA journal_mode = WAL" :: IO [Only Text]
        execute_ c "PRAGMA synchronous = NORMAL"
      ReadOnly -> execute_ c "PRAGMA query_only = ON"
  pure c

closeSqlite :: Connection -> IO ()
closeSqlite = close

-- | Begin a transaction: one that writes takes the database's write lock
-- at once (@BEGIN IMMEDIATE@), so that what it reads is still true when it
-- writes; one that reads sees one state of the database throughout.
beginSqlite :: Bool -> Connection -> IO ()
beginSqlite writes c = execute_ c (if writes then "BEGIN IMMEDIATE" else "BEGIN")

commitSqlite :: Connection -> IO ()
commitSqlite c = execute_ c "COMMIT"

rollbackSqlite :: Connection -> IO ()
rollbackSqlite c = execute_ c "ROLLBACK"

-- | Run a schema file: any number of statements, in the running
-- transaction.
runSqliteScript :: Connection -> Text -> IO ()
runSqliteScript c = SQLite.exec c.connectionHandle

-- | 'Master' is SQLite's own table of what a database holds
-- (@sqlite_master@), as far as the storage reads it: the name of each
-- table, index and other object, and which kind of object it is.
data Master f = MasterRow
  { name :: Columnar f Text
  , objectType :: Columnar f Text
  -- ^ The column @type@, which cannot be a field's name. Beam names the
  -- column of a field in camel case after its words but the first.
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Master where
  newtype PrimaryKey Master f = MasterKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = MasterKey r.name

newtype Catalog f = Catalog
  { sqlite_master :: f (TableEntity Master)
  }
  deriving stock (Generic)
  deriving anyclass (Database Sqlite)

catalog :: DatabaseSettings Sqlite Catalog
catalog = defaultDbSettings

-- | The names of the tables a database holds, but SQLite's own (whose
-- names start with @sqlite_@).
sqliteObjects :: SqliteM [Text]
sqliteObjects =
  filter (not . T.isPrefixOf "sqlite_")
    <$> Beam.runSelectReturningList (select (fmap (\o -> o.name) (filter_ (\o -> o.objectType ==. val_ "table") (all_ catalog.sqlite_master))))

-- | Write a copy of the database a connection is open on into a new file:
-- one consistent state of the database, read as a reader reads it, into
-- a complete database with no WAL file beside it.
vacuumInto :: Connection -> FilePath -> IO ()
vacuumInto c target = execute c "VACUUM INTO ?" (Only (T.pack target))

-- | The problems SQLite's @PRAGMA integrity_check@ finds in a database
-- file: none if it is sound, or that it cannot be opened as a database.
integrityProblems :: FilePath -> IO [Text]
integrityProblems file =
  try @SomeException (withConnection file (\c -> query_ c "PRAGMA integrity_check")) <&> \case
    Left e -> ["it cannot be read as a database: " <> show e]
    Right [Only "ok"] -> []
    Right rows -> map fromOnly rows

-- | The search on SQLite, the folded-text search: the pages of these
-- spaces whose fold (@search_fold@, "Wiki.Server.Storage.Rows") holds
-- every one of these words, already folded, as text anywhere in it.
-- Templates are left out unless asked for. Only the rows of the spaces
-- given are read, through the index on a page's space. A word is matched
-- with @LIKE@, whose @%@ and @_@ in a word match more than the word: the
-- search then folds and matches the rows found again
-- ('Wiki.Core.Search.searchPlain'), which keeps only the real matches.
sqliteSearch :: [Text] -> Bool -> [Text] -> SqliteM [(PageNodes Identity, Text)]
sqliteSearch spaces templates ws =
  Beam.runSelectReturningList . select . fmap (\p -> (nodeColumns p, p.search_text)) . filter_ matches $ all_ pagesOf.pages
  where
    pagesOf :: DatabaseSettings Sqlite WikiDb
    pagesOf = wikiDb
    matches p =
      foldr
        (&&.)
        (p.space_id `in_` map val_ spaces)
        ([p.template ==. val_ False | not templates] <> [p.search_fold `like_` val_ ("%" <> w <> "%") | w <- ws])
