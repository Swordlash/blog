-- | The database's connection as two libraries speak it (WP5.7 of
-- docs/PLAN.md, a spike): @sqlite-simple@, which the storage was written
-- with and most of it still is, and @persistent@'s 'SqlBackend', which the
-- users, groups and grants are read and written through
-- ("Wiki.Server.Storage.Entities"), so that the same code runs on
-- PostgreSQL.
--
-- Both are the one SQLite connection: the 'SqlBackend' is made over the
-- very handle sqlite-simple opened ('wrapSqlite'), so a statement of either
-- runs in the transaction the storage began with the other, and sees what
-- the other wrote. That needs persistent-sqlite's internals (the handle's
-- constructor, outside the PVP), and one SQLite in the program: both
-- packages carry its source, and the static link keeps one copy, which both
-- bindings then call. Which one is the link's choice: in the server and its
-- tests, persistent-sqlite's (3.43.1), not direct-sqlite's (3.45.0) that
-- the server had before. Both built with their systemlib flag would make it
-- the system's SQLite, chosen, at the cost of a library the binary needs.
module Wiki.Server.Storage.Sql
  ( Sql
  , Db (..)
  , openDb
  , closeDb
  , runSql
  , wrapSqlite
  , releaseSqlite
  )
where

import Data.IORef (newIORef)
import Database.Persist.Sql (SqlBackend, close')
import Database.Persist.SqlBackend.Internal (SqlBackend (..))
import Database.Persist.Sqlite (SqliteConnectionInfo, fkEnabled, mkSqliteConnectionInfo, walEnabled, wrapConnectionInfo)
import Database.SQLite.Simple (Connection (..), close)
import Database.SQLite3.Direct (Database (..))
import Database.Sqlite.Internal qualified as Persistent
import Foreign.Ptr (castPtr)
import Protolude

-- | A read or write of the ported part: against whatever database
-- persistent speaks to, and nothing else.
type Sql a = ReaderT SqlBackend IO a

-- | An open database: the connection, and the same connection as
-- persistent's backend.
data Db = Db
  { conn :: Connection
  , backend :: SqlBackend
  }

-- | The database a connection sqlite-simple opened is, for both.
openDb :: Connection -> IO Db
openDb conn = Db conn <$> wrapSqlite conn

-- | Close a database: persistent's statements first, then the connection.
closeDb :: Db -> IO ()
closeDb d = releaseSqlite d.backend `finally` close d.conn

-- | Run a read or write of the ported part on a database, in whatever
-- transaction it is in: persistent begins and commits none of its own
-- here ('Database.Persist.Sql.runSqlConn' would).
runSql :: Db -> Sql a -> IO a
runSql d q = runReaderT q d.backend

-- | persistent's backend over a connection sqlite-simple opened. It sets
-- no pragma (the storage has, "Wiki.Server.Storage"), and closing it
-- ('releaseSqlite') leaves the connection to sqlite-simple, which opened
-- it and closes it.
wrapSqlite :: Connection -> IO SqlBackend
wrapSqlite c = do
  let Database pointer = c.connectionHandle
  -- Whether the connection is open, which persistent-sqlite asks before it
  -- resets a statement: it is, for as long as the backend is used.
  active <- newIORef True
  backend <- wrapConnectionInfo noPragmas (Persistent.Connection active (Persistent.Connection' (castPtr pointer))) (\_ _ _ _ -> pass)
  pure backend {connClose = pass}
  where
    noPragmas :: SqliteConnectionInfo
    noPragmas = set walEnabled False (set fkEnabled False (mkSqliteConnectionInfo ""))
    -- A van Laarhoven lens's setter, which persistent-sqlite's settings are.
    set l v = runIdentity . l (const (Identity v))

-- | Let go of what persistent holds on a connection: the statements it
-- prepared and keeps, which SQLite will not close a connection under.
releaseSqlite :: SqlBackend -> IO ()
releaseSqlite = close'
