-- | The layout of a data directory, and where the database is. The
-- server's files are one directory, given on its command line, so that
-- deploying it, backing it up and moving it all concern one path:
--
-- > <data>/wiki.sqlite                    the database on SQLite (with -wal and -shm beside it)
-- > <data>/attachments/<ab>/<abcd…>       attachments' bytes, by content hash
-- > <data>/backups/<time>.sqlite          copies of the database on SQLite
-- > <data>/backups/<time>.pgdump          copies of the database on PostgreSQL
-- > <data>/tmp/                           uploads as they arrive, and exports
--
-- The database is either that SQLite file (or another the command line
-- names), or a PostgreSQL database elsewhere ('Database').
module Wiki.Server.Storage.Layout
  ( Database (..)
  , defaultDatabase
  , databaseFile
  , attachmentsDir
  , backupsDir
  , temporaryDir
  , withoutPassword
  )
where

import Data.ByteString.Char8 qualified as BC
import GHC.Show qualified
import Protolude
import System.FilePath ((</>))

-- | 'Database' is where the wiki's database is: a SQLite file, or a
-- PostgreSQL database by its connection URL or libpq connection string.
-- The URL may hold a password, so its 'Show' hides it ('withoutPassword').
data Database
  = SqliteFile FilePath
  | PostgresAt ByteString
  deriving stock (Eq)

instance Show Database where
  showsPrec d = \case
    SqliteFile f -> GHC.Show.showParen (d > 10) (GHC.Show.showString "SqliteFile " . GHC.Show.showsPrec 11 f)
    PostgresAt url -> GHC.Show.showParen (d > 10) (GHC.Show.showString "PostgresAt " . GHC.Show.showsPrec 11 (withoutPassword url))

-- | The database a data directory has when nothing else is said: the
-- SQLite file in it ('databaseFile').
defaultDatabase :: FilePath -> Database
defaultDatabase = SqliteFile . databaseFile

-- | A connection URL with its password, if it has one, replaced by @***@,
-- for logs and messages: @postgres:\/\/wiki:***\@db\/wiki@.
withoutPassword :: ByteString -> ByteString
withoutPassword url = case BC.breakSubstring "://" url of
  (scheme, rest)
    | not (BC.null rest)
    , (authority, path) <- BC.break (== '/') (BC.drop 3 rest)
    , (credentials, host) <- BC.breakSubstring "@" authority
    , not (BC.null host)
    , (user, password) <- BC.break (== ':') credentials
    , not (BC.null password) ->
        scheme <> "://" <> user <> ":***" <> host <> path
  _ -> url

-- | The SQLite database a data directory has by default.
databaseFile :: FilePath -> FilePath
databaseFile dataDir = dataDir </> "wiki.sqlite"

-- | The attachments' bytes ("Wiki.Server.Storage.Blobs").
attachmentsDir :: FilePath -> FilePath
attachmentsDir dataDir = dataDir </> "attachments"

-- | The backups of the database ("Wiki.Server.Storage.Backup").
backupsDir :: FilePath -> FilePath
backupsDir dataDir = dataDir </> "backups"

-- | The server's temporary files: each upload as it arrives (an attachment,
-- an icon, an archive to import), and each export's zip file while it is
-- sent. A file there is deleted when its request ends, and the directory
-- when the storage is opened. It is in the data directory rather than the
-- system's, which is often in memory: an upload or an export of a large
-- wiki must cost disk, not memory.
temporaryDir :: FilePath -> FilePath
temporaryDir dataDir = dataDir </> "tmp"
