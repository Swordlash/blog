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
  , PgDatabase (..)
  , postgresAt
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
import Wiki.Server.Secret (Secret)

-- | 'Database' is where the wiki's database is: a SQLite file, or a
-- PostgreSQL database ('PgDatabase').
data Database
  = SqliteFile FilePath
  | PostgresAt PgDatabase
  deriving stock (Eq, Show)

-- | 'PgDatabase' is a PostgreSQL database: its connection URL (or libpq
-- connection string), and its password when the password comes from a
-- file. The password is kept apart from the URL so that nothing that shows
-- the URL (the start-up log, an error, 'Show') can show it. It joins the
-- URL only where a connection is opened ("Wiki.Server.Storage.Postgres").
-- A URL given whole, with its password in it (@WIKI_DATABASE_URL@ may be),
-- is shown with the password replaced ('withoutPassword').
data PgDatabase = PgDatabase
  { url :: ByteString
  , password :: Maybe Secret
  }
  deriving stock (Eq)

instance Show PgDatabase where
  showsPrec d db =
    GHC.Show.showParen (d > 10) $
      GHC.Show.showString "PgDatabase {url = "
        . GHC.Show.showsPrec 0 (withoutPassword db.url)
        . GHC.Show.showString ", password = "
        . GHC.Show.showsPrec 0 db.password
        . GHC.Show.showString "}"

-- | The PostgreSQL database at a URL that needs no password apart from it.
postgresAt :: ByteString -> Database
postgresAt url = PostgresAt PgDatabase {url, password = Nothing}

-- | The database a data directory has when nothing else is said: the
-- SQLite file in it ('databaseFile').
defaultDatabase :: FilePath -> Database
defaultDatabase = SqliteFile . databaseFile

-- | A connection URL with its passwords replaced by @***@, for logs and
-- messages: the password of the URL's user part
-- (@postgres:\/\/wiki:***\@db\/wiki@), and the value of every
-- @password=@ parameter, in a URL's query (@?password=***@) or in a libpq
-- connection string (@password=***@).
withoutPassword :: ByteString -> ByteString
withoutPassword = parameters . userPart
  where
    userPart url = case BC.breakSubstring "://" url of
      (scheme, rest)
        | not (BC.null rest)
        , (authority, path) <- BC.break (== '/') (BC.drop 3 rest)
        , (credentials, host) <- BC.breakSubstring "@" authority
        , not (BC.null host)
        , (user, password) <- BC.break (== ':') credentials
        , not (BC.null password) ->
            scheme <> "://" <> user <> ":***" <> host <> path
      _ -> url
    -- Each "password=" with its value, up to the next parameter (an & in
    -- a URL, a space in a connection string), replaced. A quoted value in
    -- a connection string ends at its closing quote.
    parameters url = case BC.breakSubstring "password=" url of
      (before, found)
        | BC.null found -> url
        | otherwise ->
            let value = BC.drop (BC.length "password=") found
                rest
                  | "'" `BC.isPrefixOf` value = BC.drop 1 (quoted (BC.drop 1 value))
                  | otherwise = BC.dropWhile (\ch -> ch /= '&' && ch /= ' ') value
             in before <> "password=***" <> parameters rest
    -- The text from a quoted value's closing quote on, given the text
    -- after its opening quote. A backslash escapes the character after it.
    quoted v = case BC.uncons v of
      Just ('\\', more) -> quoted (BC.drop 1 more)
      Just ('\'', _) -> v
      Just (_, more) -> quoted more
      Nothing -> v

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
