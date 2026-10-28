{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Postgres' is how the storage speaks to
-- PostgreSQL: it opens a connection, begins and ends transactions, runs a
-- schema file, searches with PostgreSQL's full-text search, and backs the
-- database up and restores it with PostgreSQL's own programs.
--
-- The storage's queries are Beam's and run on either database
-- ("Wiki.Server.Storage.Backend"). The queries here are typed 'Postgres':
-- they use what only PostgreSQL has (a @tsvector@ column, @@\@\@@@, and
-- 'pg_export_snapshot'), so the compiler refuses them on SQLite.
--
-- = Transactions
--
-- A write runs at @SERIALIZABLE@: within one server the writes already run
-- one at a time on one connection, and a write from another process (the
-- console's @wiki-server users …@) that conflicts with one of them fails
-- with a serialization error instead of writing over what the other read.
-- The storage runs such a write again ('retryable'). A read runs at
-- @REPEATABLE READ@, read-only: it sees one state of the database
-- throughout, as a read on SQLite does.
module Wiki.Server.Storage.Postgres
  ( -- * Connections
    Connection
  , openPostgres
  , closePostgres

    -- * Transactions
  , beginPostgres
  , commitPostgres
  , rollbackPostgres
  , retryablePostgres

    -- * The schema
  , runPostgresScript
  , postgresTables
  , postgresSize

    -- * The search
  , postgresSearch

    -- * Backups
  , exportSnapshot
  , PgPrograms (..)
  , defaultPgPrograms
  , dumpPostgres
  , restorePostgres
  , checkDump
  )
where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Generic, Table (..), TableEntity, all_, customExpr_, defaultDbSettings, desc_, filter_, guard_, in_, limit_, orderBy_, select, val_, (==.))
import Database.Beam qualified as Beam
import Database.Beam.Postgres (Pg, Postgres, TsQuery, TsVector, (@@))
import Database.PostgreSQL.Simple (Connection, SqlError (..), close, connectPostgreSQL, execute_)
import Database.PostgreSQL.Simple.Transaction (IsolationLevel (..), ReadWriteMode (..), TransactionMode (..), beginMode, commit, isSerializationError, rollback)
import Database.PostgreSQL.Simple.Types (Query (..))
import Protolude hiding (Generic)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import Wiki.Server.Storage.Schema (PageNodes (..))

--------------------------------------------------------------------------------
-- Connections

-- | Open a connection to a database, given as a libpq connection string
-- or URL (@postgres:\/\/user\@host\/database@).
openPostgres :: ByteString -> IO Connection
openPostgres = connectPostgreSQL

closePostgres :: Connection -> IO ()
closePostgres = close

--------------------------------------------------------------------------------
-- Transactions

-- | Begin a transaction that writes, or one that only reads (see the
-- module's comment).
beginPostgres :: Bool -> Connection -> IO ()
beginPostgres writes =
  beginMode
    ( if writes
        then TransactionMode {isolationLevel = Serializable, readWriteMode = ReadWrite}
        else TransactionMode {isolationLevel = RepeatableRead, readWriteMode = ReadOnly}
    )

commitPostgres :: Connection -> IO ()
commitPostgres = commit

rollbackPostgres :: Connection -> IO ()
rollbackPostgres = rollback

-- | Whether a transaction failed only because another one ran beside it,
-- so that running it again may succeed: a serialization failure, or a
-- deadlock PostgreSQL broke by failing this one.
retryablePostgres :: SomeException -> Bool
retryablePostgres e = case fromException e of
  Just sql -> isSerializationError sql || sqlState sql == "40P01"
  Nothing -> False

--------------------------------------------------------------------------------
-- The schema

-- | Run a schema file: any number of statements, in the running
-- transaction.
runPostgresScript :: Connection -> Text -> IO ()
runPostgresScript c script = void (execute_ c (Query (encodeUtf8 script)))

-- | 'PgTables' is PostgreSQL's view of the tables of every schema
-- (@pg_tables@), as far as the storage reads it.
data PgTables f = PgTableRow
  { schemaname :: Columnar f Text
  , tablename :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PgTables where
  data PrimaryKey PgTables f = PgTableKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PgTableKey r.schemaname r.tablename

newtype Catalog f = Catalog
  { pg_tables :: f (TableEntity PgTables)
  }
  deriving stock (Generic)
  deriving anyclass (Database Postgres)

catalog :: DatabaseSettings Postgres Catalog
catalog = defaultDbSettings

-- | The names of the tables of the schema the connection works in (the
-- first of its search path that exists, @current_schema()@).
postgresTables :: Pg [Text]
postgresTables =
  Beam.runSelectReturningList . select $ do
    t <- all_ catalog.pg_tables
    guard_ (t.schemaname ==. currentSchema)
    pure t.tablename
  where
    currentSchema = customExpr_ ("current_schema()" :: (IsString a) => a)

-- | How many bytes the database takes on the server's disk
-- (@pg_database_size@, a function Beam has no combinator for).
postgresSize :: Pg Int64
postgresSize = fromMaybe 0 <$> Beam.runSelectReturningOne (select (pure (Beam.as_ @Int64 (customExpr_ ("pg_database_size(current_database())" :: (IsString a) => a)))))

--------------------------------------------------------------------------------
-- The search

-- | 'WordsOfPages' is the table of pages as PostgreSQL's search reads it:
-- the columns of a page's place and the text a hit shows, and
-- @search_words@, the @tsvector@ the database makes from the page's fold,
-- which SQLite's table does not have.
data WordsOfPages f = WordsRow
  { id :: Columnar f Text
  , space_id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , title :: Columnar f Text
  , slug :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , template :: Columnar f Bool
  , search_text :: Columnar f Text
  , search_words :: Columnar f TsVector
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table WordsOfPages where
  newtype PrimaryKey WordsOfPages f = WordsKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = WordsKey r.id

newtype SearchDb f = SearchDb
  { pages :: f (TableEntity WordsOfPages)
  }
  deriving stock (Generic)
  deriving anyclass (Database Postgres)

searchDb :: DatabaseSettings Postgres SearchDb
searchDb = defaultDbSettings

-- | A page's place, from the search's table.
nodesOf :: WordsOfPages f -> PageNodes f
nodesOf p = PageNodeCols {id = p.id, space_id = p.space_id, parent = p.parent, title = p.title, slug = p.slug, created_at = p.created_at, position = p.position, template = p.template}

-- | The search on PostgreSQL: the pages of these spaces whose words match
-- a query in the syntax of a web search engine (@websearch_to_tsquery@:
-- words, @"a phrase"@, @-word@, @or@), already folded as the pages' text
-- is, the best first by PostgreSQL's ranking (@ts_rank@, a match in the
-- title above one in the text alone), at most so many, with each one's
-- rank. Templates are left out unless asked for. The pages are found
-- through the index on their words, not by reading each page.
--
-- Two functions have no Beam combinator, @websearch_to_tsquery@ and
-- @ts_rank@; each is written once here with 'customExpr_', typed.
postgresSearch :: [Text] -> Bool -> Text -> Int -> Pg [(PageNodes Identity, Text, Double)]
postgresSearch spaces templates folded most =
  Beam.runSelectReturningList . select . limit_ (fromIntegral most) . orderBy_ (\(_, _, rank) -> desc_ rank) $ do
    p <- filter_ (\p -> p.space_id `in_` map val_ spaces) (all_ searchDb.pages)
    unless templates (guard_ (p.template ==. val_ False))
    let q = websearch (val_ folded)
    guard_ (p.search_words @@ q)
    pure
      ( nodesOf p
      , p.search_text
      , rankOf p.search_words q
      )
  where
    websearch :: Beam.QGenExpr ctx Postgres s Text -> Beam.QGenExpr ctx Postgres s TsQuery
    websearch = customExpr_ (\t -> "websearch_to_tsquery('simple', " <> t <> ")")
    rankOf :: Beam.QGenExpr ctx Postgres s TsVector -> Beam.QGenExpr ctx Postgres s TsQuery -> Beam.QGenExpr ctx Postgres s Double
    rankOf = customExpr_ (\v q -> "ts_rank(" <> v <> ", " <> q <> ")")

--------------------------------------------------------------------------------
-- Backups

-- | Export the snapshot of the running transaction, so that another
-- connection (@pg_dump --snapshot@) reads exactly what this one reads.
-- The transaction must be @REPEATABLE READ@ and stay open until the other
-- has started.
exportSnapshot :: Pg Text
exportSnapshot =
  fromMaybe "" <$> Beam.runSelectReturningOne (select (pure (Beam.as_ @Text (customExpr_ ("pg_export_snapshot()" :: (IsString a) => a)))))

-- | 'PgPrograms' are the programs a backup and a restore run: @pg_dump@
-- and @pg_restore@ by default, found on the path. A deployment whose
-- PostgreSQL runs in a container gives programs that run them there
-- (@toolchain/deploy-local.sh@ does), since @pg_dump@ refuses a server of
-- a newer major version than its own.
data PgPrograms = PgPrograms
  { dump :: FilePath
  , restore :: FilePath
  }
  deriving stock (Eq, Show)

defaultPgPrograms :: PgPrograms
defaultPgPrograms = PgPrograms {dump = "pg_dump", restore = "pg_restore"}

-- | Dump a database, as one consistent state, into a file in
-- @pg_dump@'s custom format, which @pg_restore@ reads. With a snapshot
-- ('exportSnapshot'), the dump reads the state that snapshot saw. The
-- dump is written to the program's output, so that a program that runs
-- @pg_dump@ somewhere else (in a container) can hand it over. The result
-- is why it failed, if it did.
dumpPostgres :: PgPrograms -> ByteString -> Maybe Text -> FilePath -> IO (Either Text ())
dumpPostgres programs url snapshot target =
  withFile target WriteMode $ \out ->
    runProgram programs.dump (["--format=custom", "--no-owner", "--no-privileges", "--dbname=" <> decodeUtf8 url] <> ["--snapshot=" <> s | Just s <- [snapshot]]) Nothing (Just out)

-- | Restore a dump into a database, in one transaction: every object of
-- the wiki is dropped and made again from the dump. The result is why it
-- failed, if it did; then the database is as it was.
restorePostgres :: PgPrograms -> ByteString -> FilePath -> IO (Either Text ())
restorePostgres programs url dumpFile =
  withFile dumpFile ReadMode $ \input ->
    runProgram programs.restore ["--clean", "--if-exists", "--no-owner", "--no-privileges", "--single-transaction", "--exit-on-error", "--dbname=" <> decodeUtf8 url] (Just input) Nothing

-- | Whether a file is a dump @pg_restore@ can read: it lists the dump's
-- contents, and fails for anything else.
checkDump :: PgPrograms -> FilePath -> IO (Either Text ())
checkDump programs dumpFile =
  withFile dumpFile ReadMode $ \input ->
    runProgram programs.restore ["--list"] (Just input) Nothing

-- | Run a program with these arguments, its input from a handle and its
-- output into one when given. Its error output is the reason given when
-- it fails.
runProgram :: FilePath -> [Text] -> Maybe Handle -> Maybe Handle -> IO (Either Text ())
runProgram program args input output = do
  ran <- try @SomeException $
    withCreateProcess
      (proc program (map toS args))
        { std_in = maybe NoStream UseHandle input
        , std_out = maybe CreatePipe UseHandle output
        , std_err = CreatePipe
        }
      $ \_ out err process -> do
        -- What the program writes when no handle takes it is not wanted
        -- (pg_restore --list), but must be read for it to finish.
        drained <- async (traverse_ BS.hGetContents out)
        complaint <- maybe (pure "") BS.hGetContents err
        traverse_ hClose err
        code <- waitForProcess process
        wait drained
        pure (code, complaint)
  pure $ case ran of
    Left e -> Left (T.pack program <> " could not be run: " <> show e)
    Right (ExitSuccess, _) -> Right ()
    Right (ExitFailure n, complaint) -> Left (T.pack program <> " failed (exit code " <> show n <> "): " <> T.strip (decodeUtf8 complaint))
