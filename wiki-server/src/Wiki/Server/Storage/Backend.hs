{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE UndecidableSuperClasses #-}

-- | 'Backend' is a database the storage can keep the wiki in: SQLite or
-- PostgreSQL. The storage is written once, against this class, and runs on
-- either (WP5.22 of docs/PLAN.md).
--
-- A query of the storage is Beam's, typed: a function of type
-- @'Backend' be => … -> 'Db' be a@ is portable, and compiles for both
-- databases. What only one database can do is a method of the class,
-- which each instance implements in its own module with that database's
-- own types ("Wiki.Server.Storage.Sqlite", "Wiki.Server.Storage.Postgres").
-- So the compiler checks that every database does it, with the means it
-- has: the search is PostgreSQL's full-text search on PostgreSQL, and the
-- folded-text search of "Wiki.Core.Search" on SQLite.
--
-- The superclasses are what the portable queries need of a database:
-- running Beam's statements, and reading, writing and comparing the
-- column types of "Wiki.Server.Storage.Schema" ('Column').
module Wiki.Server.Storage.Backend
  ( Backend (..)
  , Column
  , Capabilities (..)
  , SearchKind (..)
  , Sqlite
  , Postgres
  )
where

import Data.Time (UTCTime)
import Database.Beam (FromBackendRow, HasQBuilder, HasSqlEqualityCheck, MonadBeam)
import Database.Beam.Backend.SQL (BeamSqlBackend, BeamSqlBackendCanSerialize, BeamSqlBackendIsString, SqlNull)
import Database.Beam.Backend.SQL.BeamExtensions (BeamHasInsertOnConflict)
import Database.Beam.Postgres (Pg, Postgres, runBeamPostgres, runBeamPostgresDebug)
import Database.Beam.Sqlite (Sqlite, SqliteM, runBeamSqlite, runBeamSqliteDebug)
import Database.PostgreSQL.Simple qualified as Pg
import Database.SQLite.Simple qualified as Sqlite
import Protolude
import Wiki.Api.Info (Capabilities (..), SearchKind (..))
import Wiki.Server.Storage.Postgres (beginPostgres, closePostgres, commitPostgres, postgresSearch, postgresSize, postgresTables, retryablePostgres, rollbackPostgres, runPostgresScript)
import Wiki.Server.Storage.Schema (PageNodes)
import Wiki.Server.Storage.Sqlite (beginSqlite, closeSqlite, commitSqlite, rollbackSqlite, runSqliteScript, sqliteObjects, sqliteSearch)

-- | What a database must do with a column type of the schema: write a
-- value of it, read one back, and compare two with @=@.
type Column be a = (BeamSqlBackendCanSerialize be a, FromBackendRow be a, HasSqlEqualityCheck be a)

-- | A database the storage keeps the wiki in.
class
  ( BeamSqlBackend be
  , HasQBuilder be
  , BeamHasInsertOnConflict be
  , MonadBeam be (Db be)
  , MonadIO (Db be)
  , BeamSqlBackendIsString be Text
  , BeamSqlBackendCanSerialize be SqlNull
  , FromBackendRow be SqlNull
  , Column be Text
  , Column be Int32
  , Column be Int64
  , Column be Bool
  , Column be UTCTime
  , Column be (Maybe Text)
  , Column be (Maybe Int64)
  , Column be (Maybe UTCTime)
  ) =>
  Backend be
  where
  -- | The monad Beam's statements run in on this database.
  type Db be = (m :: Type -> Type) | m -> be

  -- | A connection to this database.
  type Connection be = (c :: Type) | c -> be

  -- | Run statements on a connection.
  runDb :: Connection be -> Db be a -> IO a

  -- | Run statements on a connection, and give each statement's SQL to the
  -- function first: what a test or the bench reads to see which statements
  -- an operation runs.
  runDbTraced :: (Text -> IO ()) -> Connection be -> Db be a -> IO a

  -- | Close a connection.
  closeConnection :: Connection be -> IO ()

  -- | Begin a transaction on a connection: one that writes (@True@), or
  -- one that only reads, and sees one state of the database throughout.
  begin :: Bool -> Connection be -> IO ()

  commitTransaction :: Connection be -> IO ()
  rollbackTransaction :: Connection be -> IO ()

  -- | Whether a transaction that failed with this exception may succeed if
  -- it is run again, because it failed only for another transaction run
  -- beside it.
  retryable :: Connection be -> SomeException -> Bool

  -- | Run a schema file ("Wiki.Server.Storage.Migrate"), in the running
  -- transaction.
  runScript :: Connection be -> Text -> IO ()

  -- | Which schema files are this database's: the suffix of their names
  -- before @.sql@ (@sqlite@ or @postgres@).
  schemaSuffix :: Connection be -> Text

  -- | The names of the tables the database holds.
  tableNames :: Db be [Text]

  -- | How many bytes the database takes, when the database says
  -- ('Nothing' on SQLite, whose files the storage measures itself).
  databaseSize :: Db be (Maybe Integer)

  -- | What this database can do that the other cannot, as the API tells
  -- the application ("Wiki.Api.Info").
  capabilities :: Connection be -> Capabilities

  -- | The pages of these spaces that the query finds, templates only if
  -- asked for, with the text a hit's snippet is cut from. The words are
  -- the query's, folded ('Wiki.Core.Search.queryWords'), and the text is
  -- the whole query folded. With a rank for each, the best first, at most
  -- the limit given, when the database ranks them; without one, every
  -- page that has all the words, which "Wiki.Core.Search" then ranks.
  searchMatches :: [Text] -> Bool -> [Text] -> Text -> Int -> Db be [(PageNodes Identity, Text, Maybe Double)]

instance Backend Sqlite where
  type Db Sqlite = SqliteM
  type Connection Sqlite = Sqlite.Connection
  runDb = runBeamSqlite
  runDbTraced tracer = runBeamSqliteDebug (tracer . toS)
  closeConnection = closeSqlite
  begin = beginSqlite
  commitTransaction = commitSqlite
  rollbackTransaction = rollbackSqlite
  retryable _ _ = False
  runScript = runSqliteScript
  schemaSuffix _ = "sqlite"
  tableNames = sqliteObjects
  databaseSize = pure Nothing
  capabilities _ = Capabilities {database = "sqlite", search = FoldedText}
  searchMatches spaces templates ws _ _ = map (\(n, t) -> (n, t, Nothing)) <$> sqliteSearch spaces templates ws

instance Backend Postgres where
  type Db Postgres = Pg
  type Connection Postgres = Pg.Connection
  runDb = runBeamPostgres
  runDbTraced tracer = runBeamPostgresDebug (tracer . toS)
  closeConnection = closePostgres
  begin = beginPostgres
  commitTransaction = commitPostgres
  rollbackTransaction = rollbackPostgres
  retryable _ = retryablePostgres
  runScript = runPostgresScript
  schemaSuffix _ = "postgres"
  tableNames = postgresTables
  databaseSize = Just . fromIntegral <$> postgresSize
  capabilities _ = Capabilities {database = "postgres", search = FullText}
  searchMatches spaces templates _ folded most = map (\(n, t, r) -> (n, t, Just r)) <$> postgresSearch spaces templates folded most
