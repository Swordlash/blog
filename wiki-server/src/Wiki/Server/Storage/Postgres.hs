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
  , connectionString
  , closePostgres

    -- * The database's lock
  , holdDatabaseShared
  , withDatabaseAlone

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
  , splitPassword
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List qualified as List
import Data.Text qualified as T
import Data.Time (UTCTime)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Generic, Table (..), TableEntity, all_, customExpr_, defaultDbSettings, desc_, filter_, guard_, in_, limit_, orderBy_, select, val_, (==.))
import Database.Beam qualified as Beam
import Database.Beam.Postgres (Pg, Postgres, TsQuery, TsVector, (@@))
import Database.PostgreSQL.Simple (Connection, Only (..), SqlError (..), close, connectPostgreSQL, execute_)
import Database.PostgreSQL.Simple qualified as Pg
import Database.PostgreSQL.Simple.Transaction (IsolationLevel (..), ReadWriteMode (..), TransactionMode (..), beginMode, commit, isSerializationError, rollback)
import Database.PostgreSQL.Simple.Types (Query (..))
import Network.HTTP.Types.URI (urlDecode)
import Protolude hiding (Generic)
import System.Environment (getEnvironment)
import System.IO (hClose)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import Text.Printf (printf)
import Wiki.Server.Secret (Secret (..))
import Wiki.Server.Storage.Layout (PgDatabase (..))
import Wiki.Server.Storage.Schema (PageNodes (..))

--------------------------------------------------------------------------------
-- Connections

-- | Open a connection to a database ('PgDatabase': a libpq connection
-- string or URL, @postgres:\/\/user\@host\/database@, and its password
-- when that is kept apart).
openPostgres :: PgDatabase -> IO Connection
openPostgres = connectPostgreSQL . connectionString

-- | The text libpq connects with: the database's URL or connection
-- string, with its password added when that is kept apart. This text is
-- given to libpq and to nothing else, since it holds the password.
connectionString :: PgDatabase -> ByteString
connectionString db = case db.password of
  Nothing -> db.url
  Just (Secret p)
    | "://" `BS.isInfixOf` db.url ->
        db.url <> (if "?" `BC.isInfixOf` db.url then "&" else "?") <> "password=" <> percentEncoded (encodeUtf8 p)
    | otherwise -> db.url <> " password='" <> BC.concatMap escaped (encodeUtf8 p) <> "'"
  where
    -- A libpq URL's parameter is percent-decoded and nothing else (a +
    -- stays a +), so every byte but the unreserved ones is percent-encoded.
    percentEncoded = BC.concatMap $ \ch ->
      if isAsciiUpper ch || isAsciiLower ch || isDigit ch || ch `elem` ("-._~" :: [Char])
        then BC.singleton ch
        else BC.pack (printf "%%%02X" (ord ch))
    -- A quoted value of a connection string escapes quotes and backslashes.
    escaped ch = if ch == '\'' || ch == '\\' then BC.pack ['\\', ch] else BC.singleton ch

closePostgres :: Connection -> IO ()
closePostgres = close

--------------------------------------------------------------------------------
-- The database's lock

-- | The key of the advisory lock that says who has the database open
-- ('holdDatabaseShared', 'withDatabaseAlone'): the bytes of "wiki-ser". An
-- advisory lock belongs to one database, so wikis in other databases of
-- the same PostgreSQL server do not share it.
databaseLockKey :: Int64
databaseLockKey = 0x77696b692d736572

-- | Take the database's lock shared, as one of the storages that have the
-- database open (a server, the console), on a connection of its own that
-- holds the lock until it is closed. The data directory's lock does not
-- do this on PostgreSQL: two data directories may name one database. The
-- result is the action that releases the lock, or 'Nothing' when a
-- restore holds it ('withDatabaseAlone').
holdDatabaseShared :: PgDatabase -> IO (Maybe (IO ()))
holdDatabaseShared db = do
  c <- openPostgres db
  took <- tryLock c "pg_try_advisory_lock_shared" `onException` close c
  if took then pure (Just (close c)) else close c $> Nothing

-- | Run an action with the database's lock taken alone, as a restore
-- does: no storage has the database open while the action runs, and none
-- can open it. The result is 'Nothing', and the action is not run, when a
-- storage has the database open.
withDatabaseAlone :: PgDatabase -> IO a -> IO (Maybe a)
withDatabaseAlone db act = bracket (openPostgres db) close $ \c ->
  ifM (tryLock c "pg_try_advisory_lock") (Just <$> act) (pure Nothing)

-- | Try to take the database's lock with one of PostgreSQL's functions
-- for it, which answers whether it took the lock.
tryLock :: Connection -> ByteString -> IO Bool
tryLock c function = (== [Only True]) <$> Pg.query c (Query ("SELECT " <> function <> "(?)")) (Only databaseLockKey)

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
dumpPostgres :: PgPrograms -> PgDatabase -> Maybe Text -> FilePath -> IO (Either Text ())
dumpPostgres programs db snapshot target =
  withFile target WriteMode $ \out ->
    runProgram programs.dump (Just db) (["--format=custom", "--no-owner", "--no-privileges"] <> ["--snapshot=" <> s | Just s <- [snapshot]]) Nothing (Just out)

-- | Restore a dump into a database, in one transaction: every object of
-- the wiki is dropped and made again from the dump. The result is why it
-- failed, if it did; then the database is as it was.
restorePostgres :: PgPrograms -> PgDatabase -> FilePath -> IO (Either Text ())
restorePostgres programs db dumpFile =
  withFile dumpFile ReadMode $ \input ->
    runProgram programs.restore (Just db) ["--clean", "--if-exists", "--no-owner", "--no-privileges", "--single-transaction", "--exit-on-error"] (Just input) Nothing

-- | Whether a file is a dump @pg_restore@ can read: it lists the dump's
-- contents, and fails for anything else.
checkDump :: PgPrograms -> FilePath -> IO (Either Text ())
checkDump programs dumpFile =
  withFile dumpFile ReadMode $ \input ->
    runProgram programs.restore Nothing ["--list"] (Just input) Nothing

-- | Run a program with these arguments, its input from a handle and its
-- output into one when given. Its error output is the reason given when
-- it fails. A database, when one is given, is added as @--dbname@ without
-- its password, and the password goes to the program in @PGPASSWORD@:
-- every user of the machine can read a process's arguments, but not its
-- environment. Without a password of the database's own, the program
-- keeps the @PGPASSWORD@ the server has, which libpq reads as the server's
-- connections do.
runProgram :: FilePath -> Maybe PgDatabase -> [Text] -> Maybe Handle -> Maybe Handle -> IO (Either Text ())
runProgram program db args input output = do
  inherited <- getEnvironment
  let (bare, fromUrl) = maybe ("", Nothing) (splitPassword . (.url)) db
      password = ((\(Secret p) -> encodeUtf8 p) <$> (db >>= (.password))) <|> fromUrl
      dbname = ["--dbname=" <> decodeUtf8 bare | isJust db]
      env = case password of
        Just p -> ("PGPASSWORD", BC.unpack p) : filter ((/= "PGPASSWORD") . fst) inherited
        Nothing -> inherited
  ran <- try @SomeException
    $ withCreateProcess
      (proc program (map toS (args <> dbname)))
        { std_in = maybe NoStream UseHandle input
        , env = Just env
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

-- | A connection URL without its password, and the password, decoded as
-- libpq decodes it (percent-decoding only: a + stays a +): the password of
-- the URL's user part (@postgres:\/\/user:password\@host\/db@) or of its
-- @password@ parameter (@?password=…@), as a URL given whole may have. A
-- libpq connection string that is no URL is given back whole.
splitPassword :: ByteString -> (ByteString, Maybe ByteString)
splitPassword url = case BC.breakSubstring "://" url of
  (scheme, rest)
    | not (BS.null rest) ->
        let (authority, pathAndQuery) = BC.break (== '/') (BS.drop 3 rest)
            (fromUser, host) = case BC.breakSubstring "@" authority of
              (credentials, at) | not (BS.null at) -> case BC.break (== ':') credentials of
                (user, colon) | not (BS.null colon) -> (Just (urlDecode False (BS.drop 1 colon)), user <> at)
                _ -> (Nothing, authority)
              _ -> (Nothing, authority)
            (path, query) = BC.break (== '?') pathAndQuery
            parameters = filter (not . BS.null) (BC.split '&' (BS.drop 1 query))
            (passwords, others) = List.partition ("password=" `BS.isPrefixOf`) parameters
            fromQuery = urlDecode False . BS.drop (BS.length "password=") <$> head passwords
            kept = if null others then "" else "?" <> BS.intercalate "&" others
         in (scheme <> "://" <> host <> path <> kept, fromUser <|> fromQuery)
  _ -> (url, Nothing)
