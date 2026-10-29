-- | The server's storage of the wiki: a database, PostgreSQL or SQLite,
-- plus the attachments' bytes in files on disk, named by their content
-- hash. It implements the application's backend interface, 'MonadWiki'.
--
-- The storage is written once, for both databases: its statements are
-- Beam's ("Wiki.Server.Storage.Rows"), and what differs between the
-- databases is a method of 'Backend' ("Wiki.Server.Storage.Backend"). The
-- one difference a user sees is the search: PostgreSQL's full-text search
-- on PostgreSQL, the demo's search on SQLite.
--
-- 'StoredWiki' is a 'MonadWiki' like the demo's in-memory backend, and
-- passes the same contract tests ("Wiki.App.Backend.Contract"). The
-- server's handlers call it as the application calls any backend, and get
-- the same answers as from the demo, including the same errors in the same
-- order. Every operation does what "Wiki.App.Backend.Mem.State" does for
-- the demo, with the same @wiki-core@ functions (the permission rules, the
-- orders, paths and slugs, the search), over database rows instead of a
-- map in memory.
--
-- = Who is asking
--
-- Every program runs as a 'Who', passed in when it is run and not stored
-- anywhere: a reader who has not signed in ('Anonymous'), one of the
-- wiki's users ('AsUser'), or 'Administrator', the server's operator (on
-- its loopback admin listener: decision 11 of docs/PLAN.md), who passes
-- every check. The server decides the 'Who' for each request; this module
-- knows nothing about requests.
--
-- = Transactions
--
-- Each operation is one transaction. It reads what it needs: every
-- space and grant, since every permission rule looks at a space's
-- ancestors, and the pages the operation is about. It then checks what the
-- class's Haddock says it checks, in that order, and only then writes. An
-- operation that fails writes nothing, and one that throws (on a full
-- disk, say) is rolled back. Every transaction runs in one bracket,
-- 'Wiki.Server.Storage.Backend.withTransaction', so that a connection goes
-- back to its pool with no transaction open, whatever happened.
--
-- = The permission context
--
-- The permission context is what a permission check reads: every space,
-- every grant, and the user asking with their groups. It is the same on
-- every read until a write changes it, so the storage keeps it in memory
-- ('Permissions'), for one generation at a time. The database bumps the
-- generation (@permissions_generation@) by itself, with triggers, in every
-- transaction that changes a space, a grant, a user or a group's members,
-- whoever makes the change. A read
-- transaction reads the generation first, and takes the permission
-- context from memory when the generation there is the same, and from
-- the database otherwise. A write always reads the permission context
-- from the database. Since the generation is a row of the database, a
-- change made by another process (the console's @wiki-server users …@)
-- is seen at the next read too.
--
-- The storage has two kinds of database connection. The writer is one
-- connection, used by one operation at a time. Every write runs on it, so
-- writes happen one after another, and the callbacks a write calls after
-- its commit ('publish', 'notify') are called in commit order. The readers
-- are a small pool of connections that only read ('readConnections' of
-- them). An operation that only reads takes a reader. It does not wait for
-- a write or for another read, and no write waits for it: a reader reads
-- the last committed state while the writer writes (SQLite is in WAL mode
-- for that; PostgreSQL does it always). A backup copies the database
-- through a connection of its own ('backUp'), so it holds neither the
-- writer nor a reader.
--
-- = The wiki's settings
--
-- The wiki's settings include whom the wiki lets in ("Wiki.Core.Access"),
-- which every request needs: the listener checks it, and every permission
-- rule sees it through the grants. So the storage keeps the settings in
-- memory. They are read when the storage opens, before any reader exists.
-- A change made through the storage updates that copy right after its
-- commit, before any other write may begin. A read transaction takes the
-- settings from memory, not from the database it reads. So for a moment
-- a read can see the settings from before a change with the rows from
-- after it, or the other way round. That is harmless: each half is what a
-- request a moment earlier or later would see. A change made by another
-- process would only be seen at the next start, but no other process
-- makes one.
--
-- The server's own settings ("Wiki.Server.Secret") are kept in memory the
-- same way: its public address, its mail server and its sign-in providers.
-- The server reads them on every request that signs someone in or sends
-- mail ('readServerSettings'), so a change in the administration takes
-- effect with the next such request.
module Wiki.Server.Storage
  ( -- * The storage
    Storage
  , Config (..)
  , defaultConfig
  , openStorage
  , closeStorage
  , withStorage
  , withStorageAside
  , Place (..)
  , inDataDir
  , Database (..)
  , PgDatabase (..)
  , postgresAt
  , writing
  , writingEither
  , reading
  , readConnections
  , storageDataDir
  , storagePlace
  , storageCapabilities
  , traceStatements
  , databaseBytes
  , DataDirInUse (..)

    -- * The wiki's settings
  , readSettings
  , readServerSettings

    -- * The backups
  , readBackups
  , readBackupSettings
  , readLastBackup
  , writeLastBackup
  , backUp

    -- * Who is asking
  , Who (..)
  , administratorId
  , administratorUser
  , userByLogin

    -- * The wiki
  , StoredWiki
  , runStoredWiki
  , runStoredWikiFrom
  , actorOf
  , attachmentFile
  , exportedPage
  , spacePages
  , sitemapPages
  , feedPosts
  , blobPath
  , spaceIconFile
  , mayReadPage
  , locatedFor
  , editorOf
  , threadsThen
  , uploadAttachmentFile
  , uploadSpaceIconFile

    -- * Accounts
  , PasswordLink (..)
  , passwordLinkFor

    -- * Whole wikis
  , importArchive
  , exportArchive
  , writeExport

    -- * The audit log
  , schemaVersionOf
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID (..))
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, setNumStripes, withResource)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Protolude
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removePathForcibly)
import Wiki.Api.Account (Account (..), InvitationToken (..), NewAccount (..), providerOnly)
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), UserPage (..), UserQuery (..), UserSummary (..), WikiSettings (..), checkUserQuery, invitationLifetime)
import Wiki.Api.Backups (BackupRecord, BackupSettingsChange, BackupSettingsOf (..), Backups (..), DestinationOf (..), Retention (..), applyBackupChange, checkBackupSettings, destinationText, scheduleText)
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Info (Capabilities)
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark, maxPeopleFound, searchable)
import Wiki.Api.Security (ResetToken (..), resetLifetime)
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsChange, ServerSettingsOf (..), applyChange, checkServerSettings, kindName, secretState, securityName)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), anonymous, anonymousIn, maxAttachmentSize)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Access (Access (..), accessName)
import Wiki.Core.Anchor (Anchor, checkAnchor)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..), parseFileName, uploadedMimeType)
import Wiki.Core.Audit (Actor (..))
import Wiki.Core.Audit qualified as Audit
import Wiki.Core.Blog (PostDetails (..), isPost)
import Wiki.Core.Blog qualified as Blog
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, checkCommentBody, formerAuthor, mayComment, mayDeleteComment, mayDeleteThread, mayEditComment)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Export (Archive (..), ArchiveFile (..), archiveFiles, threadsAmong)
import Wiki.Core.Export qualified as Export
import Wiki.Core.Export.Zip (ZipSource (..), ZipTooLarge (..), writeZipFile)
import Wiki.Core.Id
import Wiki.Core.Markdown.Ast (mentionsWhole)
import Wiki.Core.Notification (Happened (..), Notification (..), Occasion (..), PageLocation (..), Watch, WatchTarget (..), Watcher (..), effectiveMailMode, excerptOf, maxListed, mentionedIn, newlyMentioned, pageWatch, recipients, spaceWatch, withLocation)
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, childrenInOrder, nextPosition, orderName, renumber, reposition)
import Wiki.Core.Page (Page (..), PageSummary (..), pageTreeOrder)
import Wiki.Core.Path (ancestry, childrenOf, findChild, pathOf, resolvePath, resolvePathM)
import Wiki.Core.Permission
  ( GlobalGrant (..)
  , GlobalPermission (..)
  , Grants (..)
  , Principal (..)
  , SpaceAccess (..)
  , SpaceGrant (..)
  , SpacePermission (..)
  , Subject (..)
  , canAdministerSpace
  , canEdit
  , canView
  , hasGlobalPermission
  , isFor
  , mayCreateSpace
  , mayMovePage
  , mayMoveSpace
  )
import Wiki.Core.Permission qualified as Permission
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), Searchable (..), foldText, folded, queryWords, searchPlain, searchRanked)
import Wiki.Core.Slug (Slug, freshSlug, mkSlug, slugText, slugify)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..), checkIconUpload, checkProfile, homeBody, homeTitle, positionSpace, spaceTreeOrder, withProfile)
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Group (..), Login (..), Standing (..), User (..), checkNewPassword, parseEmail, parseLogin)
import Wiki.Core.Version (Author (..), Version (..), VersionInfo, VersionsQuery (..), maxVersionsPageSize, versionInfo)
import Wiki.Server.Password (hashPassword, newToken, tokenHash)
import Wiki.Server.Secret (Kept, Secret (..), hideSecrets)
import Wiki.Server.Storage.Audit (Recorded (..), insertAudit, loadActivity, loadAuditLog, restoreAudit)
import Wiki.Server.Storage.Backend (Backend (..), withTransaction, withTransactionEither)
import Wiki.Server.Storage.Backup (DataLock, KeptBackups, backupBlobs, backupFiles, backupInto, loadBackupSettings, loadLastBackup, lockDataDir, storeBackupSettings, storeLastBackup, unlockDataDir)
import Wiki.Server.Storage.Blobs (blobFile, collectBlobs, storeBlob, storeBlobFile)
import Wiki.Server.Storage.Comments qualified as Comments
import Wiki.Server.Storage.Layout (Database (..), PgDatabase (..), attachmentsDir, backupsDir, defaultDatabase, postgresAt, temporaryDir)
import Wiki.Server.Storage.Migrate (migrate, schemaVersion)
import Wiki.Server.Storage.Notifications qualified as Notifications
import Wiki.Server.Storage.Postgres (PgPrograms, defaultPgPrograms, holdDatabaseShared, openPostgres)
import Wiki.Server.Storage.Rows
import Wiki.Server.Storage.Sqlite (Access (..), openSqlite)

--------------------------------------------------------------------------------
-- The storage

-- | An open storage: the database's connections, the data directory the
-- attachments and the backups are in, and the settings kept in memory.
data Storage = Storage
  { engine :: Engine
  , place :: Place
  , config :: Config
  , settings :: IORef (Maybe WikiSettings)
  -- ^ The wiki's settings, read when the storage opens. Only the holder of
  -- the writer changes this, so settings read before a change can never
  -- overwrite the changed ones.
  , serverKept :: IORef (Maybe Kept)
  -- ^ The server's own settings, kept the same way.
  , tracer :: IORef (Maybe (Text -> IO ()))
  -- ^ The function each statement's SQL is given to before it runs, while
  -- 'traceStatements' runs; none otherwise.
  , permissions :: IORef (Maybe Permissions)
  -- ^ The permission context of the last generation a read transaction
  -- read from the database ('keptPermissions'); none until the first read.
  , lock :: Maybe DataLock
  -- ^ The data directory's lock. A storage opened with 'openStorage',
  -- which may delete files in the directory, holds it. A storage opened
  -- beside a running server ('withStorageAside') does not.
  , release :: IO ()
  -- ^ Release the database's lock: on PostgreSQL, every storage holds it
  -- shared while it is open, so that a restore, which takes it alone,
  -- cannot replace the database under it
  -- ('Wiki.Server.Storage.Postgres.holdDatabaseShared'). On SQLite this
  -- does nothing: the data directory's lock does the same there.
  }

-- | 'Engine' is the storage's connections to its database, of whichever
-- kind the database is ("Wiki.Server.Storage.Backend").
data Engine = forall be. (Backend be) => Engine (Pools be)

-- | 'Pools' is the storage's connections to a database of one kind. The
-- writer is one connection, used by one operation at a time. The readers
-- are 'readConnections' connections, each used by one operation at a
-- time. A connection that fails with an exception is closed and opened
-- again the next time one is needed, so a database server that restarts
-- costs the operations that were running on it, and no more.
data Pools be = Pools
  { writer :: Pool (Connection be)
  , readers :: Pool (Connection be)
  }

-- | 'Place' is where a storage keeps the wiki: its data directory (the
-- attachments, the backups, the temporary files, and the SQLite database
-- by default), its database, and the programs that back a PostgreSQL
-- database up and restore it.
data Place = Place
  { dataDir :: FilePath
  , database :: Database
  , programs :: PgPrograms
  }
  deriving stock (Show)

-- | A data directory with its database in it: SQLite, in @wiki.sqlite@.
inDataDir :: FilePath -> Place
inDataDir dir = Place {dataDir = dir, database = defaultDatabase dir, programs = defaultPgPrograms}

-- | What a storage is opened with besides its location.
data Config = Config
  { attachmentAddress :: Attachment -> Text
  -- ^ The URL a browser fetches a stored attachment's bytes from: the
  -- server's route for them, which serves 'attachmentFile'.
  , iconAddress :: Space -> Text
  -- ^ The URL a browser fetches a space's icon image from, for a space
  -- whose icon is an image: the server's route for it, which serves
  -- 'spaceIconFile'.
  , publish :: PageId -> PageEvent -> IO ()
  -- ^ The callback that reports what happens to a page to the server's
  -- live channel ("Wiki.Server.Events"): every change to the page's
  -- comments, and every save of the page. It is called once the change is
  -- committed, before any other write may begin, so it must not wait.
  , notify :: [(UserId, Notification)] -> IO ()
  -- ^ The callback that receives the notifications a write made
  -- ("Wiki.Core.Notification") and passes them to the users' tabs over the
  -- live channel, and to the thread that mails them. It is called as
  -- 'publish' is, and must not wait either.
  }

-- | A configuration with attachments at @\/api\/v1\/attachments\/\<id\>@,
-- and callbacks that do nothing.
defaultConfig :: Config
defaultConfig =
  Config
    { attachmentAddress = \a -> "/api/v1/attachments/" <> a.id.text
    , iconAddress = \s -> "/api/v1/spaces/" <> s.id.text <> "/icon"
    , publish = \_ _ -> pass
    , notify = \_ -> pass
    }

-- | Open the storage at a location, creating the data directory if
-- needed. The database is given this program's schema, or migrated to it
-- ("Wiki.Server.Storage.Migrate"). Attachment files that neither the
-- database nor any backup refers to are deleted
-- ("Wiki.Server.Storage.Blobs" says why at this point). A database that a
-- newer program has migrated, or one of an earlier wiki-server, is refused
-- with an exception, and nothing is changed.
--
-- The storage holds the data directory's lock while it is open
-- ('Wiki.Server.Storage.Backup.lockDataDir'). Opening a second storage on
-- the directory (a second server) is refused with 'DataDirInUse', and so
-- is a restore, since either would change the files under the open
-- storage.
openStorage :: Config -> Place -> IO Storage
openStorage = openWith True

-- | Open the storage while a server may be running on the same location
-- (the console's @wiki-server users …@). The database is migrated as
-- 'openStorage' does, but no attachment file is deleted, since the server
-- may be writing one that its database does not name yet. A write waits
-- for the server's writes, instead of failing at once.
withStorageAside :: Place -> (Storage -> IO a) -> IO a
withStorageAside at = bracket (openWith False defaultConfig at) closeStorage

openWith :: Bool -> Config -> Place -> IO Storage
openWith collect config place = do
  createDirectoryIfMissing True place.dataDir
  lock <- if collect then Just <$> (lockDataDir place.dataDir >>= either (throwIO . DataDirInUse) pure) else pure Nothing
  flip onException (traverse_ unlockDataDir lock) $ do
    release <- case place.database of
      SqliteFile _ -> pure pass
      PostgresAt pg -> holdDatabaseShared pg >>= maybe (throwIO (DataDirInUse "The PostgreSQL database is being restored (wiki-server restore holds its lock): start the server once the restore has ended.")) pure
    flip onException release $ do
      engine <- case place.database of
        SqliteFile file -> Engine <$> pools (openSqlite ReadWrite file) (openSqlite ReadOnly file)
        PostgresAt pg -> Engine <$> pools (openPostgres pg) (openPostgres pg)
      flip onException (closeEngine engine) $ do
        (settings, serverKept) <- case engine of
          Engine p -> withResource p.writer $ \c -> do
            _ <- migrate c
            when collect $ do
              collectGarbage c place.dataDir
              -- Uploads and exports left by a server that stopped: nothing
              -- is writing them now.
              removePathForcibly (temporaryDir place.dataDir)
            -- The settings are read here, on the writer, before any reader
            -- is used. A reader then always finds them in memory, and never
            -- writes the in-memory copy.
            (,) <$> (newIORef . Just =<< runDb c loadSettings) <*> (newIORef . Just =<< runDb c loadServerSettings)
        tracer <- newIORef Nothing
        permissions <- newIORef Nothing
        pure Storage {engine, place, config, settings, serverKept, tracer, permissions, lock, release}

-- | The pools of a database's connections: one writer, and the readers.
-- A connection unused for ten minutes is closed.
pools :: (Backend be) => IO (Connection be) -> IO (Connection be) -> IO (Pools be)
pools openWriter openReader = do
  writer <- newPool (setNumStripes (Just 1) (defaultPoolConfig openWriter closeConnection 600 1))
  readers <- newPool (setNumStripes (Just 1) (defaultPoolConfig openReader closeConnection 600 readConnections))
  pure Pools {writer, readers}

-- | The number of readers a storage opens at most: four. A read waits for
-- a reader only while four other reads run. Each connection costs memory
-- (on SQLite, its page cache of about 2 MB; on PostgreSQL, a server
-- process), so more readers use more of it.
readConnections :: Int
readConnections = 4

closeEngine :: Engine -> IO ()
closeEngine (Engine p) = destroyAllResources p.readers >> destroyAllResources p.writer

-- | The error for a data directory that another storage has open, or that
-- a restore is writing into.
newtype DataDirInUse = DataDirInUse Text
  deriving stock (Show)

instance Exception DataDirInUse where
  displayException (DataDirInUse why) = toS why

-- | Close the storage's database, and release its directory's lock.
closeStorage :: Storage -> IO ()
closeStorage st = closeEngine st.engine `finally` st.release `finally` traverse_ unlockDataDir st.lock

-- | Run something with the storage open, and close it afterwards.
withStorage :: Config -> Place -> (Storage -> IO a) -> IO a
withStorage config at = bracket (openStorage config at) closeStorage

-- | Run statements on the writer, in a transaction of their own: committed
-- if they return, rolled back if they throw. No other write runs
-- meanwhile; reads go on, on the readers. This is for what the wiki's
-- interface does not do: accounts and sessions ("Wiki.Server.Accounts"),
-- the console, maintenance, and tests that look into the database.
writing :: Storage -> (forall be. (Backend be) => Db be a) -> IO a
writing st action = either absurd identity <$> writingEither st (Right <$> action)

-- | 'writing', committed only if the result is a 'Right': a 'Left' rolls
-- the transaction back, as an exception does.
writingEither :: Storage -> (forall be. (Backend be) => Db be (Either e a)) -> IO (Either e a)
writingEither st action = case st.engine of
  Engine p -> retrying p.writer $ \c -> withTransactionEither True c $ do
    tracer <- tracedBegin st True
    runTraced tracer c action

-- | Run statements on a reader, in a transaction that sees one state of
-- the database throughout. A write there fails.
reading :: Storage -> (forall be. (Backend be) => Db be a) -> IO a
reading st action = case st.engine of
  Engine p -> withResource p.readers $ \c -> withTransaction False c $ do
    tracer <- tracedBegin st False
    runTraced tracer c action

-- | Run a transaction on a connection of a pool, and run it again, up to
-- three times in all, when it failed only because of another transaction
-- beside it ('retryable': on PostgreSQL, another process's write). The
-- transaction is rolled back before it runs again ('withTransaction'), so
-- the same connection is used again.
--
-- Any other exception leaves 'withResource' as an exception, so that the
-- pool closes the connection instead of handing it to the next operation:
-- after a failure the connection may be broken (the database server
-- restarted, or the rollback failed too).
retrying :: (Backend be) => Pool (Connection be) -> (Connection be -> IO a) -> IO a
retrying pool body = go (3 :: Int)
  where
    go n =
      withResource pool (\c -> tryJust (\e -> if n > 1 && retryable c e then Just () else Nothing) (body c)) >>= \case
        Right a -> pure a
        Left () -> go (n - 1)

-- | The function a transaction's statements are traced with, while
-- 'traceStatements' runs, called first thing in a transaction that
-- 'withTransaction' has begun. The transaction's beginning is traced too:
-- @BEGIN@ for one that reads, @BEGIN IMMEDIATE@ for one that writes, as
-- SQLite would say it.
tracedBegin :: Storage -> Bool -> IO (Maybe (Text -> IO ()))
tracedBegin st writes = do
  tracer <- readIORef st.tracer
  for_ tracer ($ if writes then "BEGIN IMMEDIATE" else "BEGIN")
  pure tracer

-- | Run statements on a connection, traced if a tracer is given.
runTraced :: (Backend be) => Maybe (Text -> IO ()) -> Connection be -> Db be a -> IO a
runTraced = maybe runDb runDbTraced

-- | Run an action, and give the SQL of each statement the storage runs
-- meanwhile, on any of its connections, to a function: what the tests of
-- the storage at scale and the bench count and look into. One action at a
-- time may be traced.
traceStatements :: Storage -> (Text -> IO ()) -> IO a -> IO a
traceStatements st f act = bracket_ (writeIORef st.tracer (Just f)) (writeIORef st.tracer Nothing) act

-- | The data directory a storage was opened in.
storageDataDir :: Storage -> FilePath
storageDataDir st = st.place.dataDir

-- | Where a storage was opened.
storagePlace :: Storage -> Place
storagePlace st = st.place

-- | What the storage's database can do, as the API says it
-- ("Wiki.Api.Info").
-- They follow from the kind of database alone, so no connection is used:
-- the application asks for them on every page it loads.
storageCapabilities :: Storage -> IO Capabilities
storageCapabilities st = case st.engine of
  Engine p -> pure (capabilitiesOf p)
  where
    capabilitiesOf :: forall be. (Backend be) => Pools be -> Capabilities
    capabilitiesOf _ = capabilities (Proxy @be)

-- | The wiki's settings as they are now, from memory.
readSettings :: Storage -> IO WikiSettings
readSettings st = readIORef st.settings >>= maybe (writing st loadSettings) pure

-- | The server's own settings as they are now, with their secrets, from
-- memory.
readServerSettings :: Storage -> IO Kept
readServerSettings st = readIORef st.serverKept >>= maybe (writing st loadServerSettings) pure

-- | Delete the attachments' files that nothing refers to: not the database,
-- and not one of the backups kept, which a restore would bring back. A
-- backup that cannot be read might refer to any of them, so then nothing is
-- deleted. Space icon images are such files too.
collectGarbage :: (Backend be) => Connection be -> FilePath -> IO ()
collectGarbage c dataDir = do
  live <- runDb c referencedBlobs
  kept <- traverse (try @SomeException . backupBlobs) =<< backupFiles (backupsDir dataDir)
  case sequence kept of
    Left _ -> pass
    Right fromBackups -> void (collectBlobs (attachmentsDir dataDir) (Set.unions (live : fromBackups)))

-- | The version of the database's schema: its last migration.
schemaVersionOf :: Storage -> IO Int
schemaVersionOf st = case st.engine of
  Engine p -> withResource p.readers schemaVersion

-- | How many bytes the database takes: its files on SQLite (with the
-- write-ahead log), and what PostgreSQL says of the database.
databaseBytes :: Storage -> IO Integer
databaseBytes st = case st.place.database of
  SqliteFile file -> sum <$> traverse sizeOf [file, file <> "-wal"]
  PostgresAt _ -> case st.engine of
    Engine p -> withResource p.readers $ \c -> fromMaybe 0 <$> runDb c databaseSize
  where
    sizeOf f = ifM (doesFileExist f) (getFileSize f) (pure 0)

--------------------------------------------------------------------------------
-- Who is asking

-- | Who an operation is run as.
data Who
  = -- | A reader who has not signed in: they see the public spaces.
    Anonymous
  | -- | One of the wiki's users, with what is granted to them and to their
    -- groups. An id that belongs to no user, or to a disabled user, is
    -- treated as 'Anonymous'.
    AsUser UserId
  | -- | The server's operator, who passes every check, as a holder of the
    -- global 'Administer' does. The operator is not a user of the wiki, and
    -- the application sees them as 'administratorUser'.
    Administrator
  deriving stock (Eq, Ord, Show)

-- | The user id of the operator ('Administrator'), where an id is needed:
-- their drafts are stored under it, and the versions they save name it.
-- No user has it (users' ids are UUIDs, or an imported wiki's
-- @user-N@).
administratorId :: UserId
administratorId = UserId "~administrator"

-- | The administrator as the application sees them: signed in, holding the
-- global 'Administer'.
administratorUser :: User
administratorUser = User {id = administratorId, login = Login "administrator", displayName = "Administrator"}

-- | The user with a login.
userByLogin :: Storage -> Text -> IO (Maybe User)
userByLogin st login = reading st (loadUserByLogin login)

--------------------------------------------------------------------------------
-- Transactions

-- | What an operation knows as it runs: the connection, every space and
-- grant as the transaction began, and who is asking.
data Ctx = Ctx
  { conn :: Conn
  , blobs :: FilePath
  , spaces :: Map SpaceId Space
  , grants :: Grants
  -- ^ The wiki's grants, plus, for the administrator, a global
  -- 'Administer' grant.
  , principal :: Maybe Principal
  -- ^ Who is asking, as the rules see them.
  , user :: Maybe User
  -- ^ Who is asking, as the application sees them.
  , author :: Maybe UserId
  -- ^ The id their drafts and the versions they save are kept under.
  , creator :: Maybe UserId
  -- ^ The user granted administration of a space this caller creates:
  -- nobody for the administrator, who needs no grant.
  , wiki :: WikiSettings
  -- ^ The wiki's settings as the transaction began.
  , server :: Kept
  -- ^ The server's own settings as the transaction began.
  , address :: Text
  -- ^ Where the request came from, as the audit log records it: a
  -- network address, @console@, or empty where it is not known.
  , told :: IORef [(UserId, Notification)]
  -- ^ The notifications the transaction made, sent once it commits.
  }

-- | 'Conn' is the connection a transaction runs on, to a database of
-- either kind.
data Conn = forall be. (Backend be) => Conn (Maybe (Text -> IO ())) (Connection be)

-- | Run statements on a transaction's connection.
viaConn :: Conn -> (forall be. (Backend be) => Db be a) -> IO a
viaConn (Conn tracer c) action = runTraced tracer c action

-- | An operation, in a transaction: what it finds wrong ends it with a
-- 'WikiError', and the transaction is rolled back.
newtype Tx a = Tx (ReaderT Ctx (ExceptT WikiError IO) a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader Ctx, MonadError WikiError)

-- | Whether a transaction writes, and which connection it runs on.
data Mode
  = -- | It only reads, on a reader.
    Reads
  | -- | It writes, on the writer. It takes the database's write lock as it
    -- begins, so that what it read is still true when it writes.
    Writes
  | -- | It only reads, but on the writer, so that no write can commit
    -- between its read and the action run after it ('transactThen'). The
    -- live channel subscribes this way ('threadsThen'): every change
    -- committed after the read is reported after the answer, and no change
    -- committed before the read is reported as new (decision 23 of
    -- docs/PLAN.md).
    ReadsOnWriter
  deriving stock (Eq)

-- | Run an operation as someone, in a transaction of its own: committed if
-- it succeeds, rolled back if it fails or throws.
transact :: Storage -> Who -> Mode -> Tx a -> IO (Either WikiError a)
transact st who = transactFrom st who ""

-- | 'transact', for a request from an address, which the audit log records.
transactFrom :: Storage -> Who -> Text -> Mode -> Tx a -> IO (Either WikiError a)
transactFrom st who address mode body = transactThenFrom st who address mode body (const pass)

-- | 'transact', then an action on the result, run after the commit. For a
-- transaction on the writer ('Writes', 'ReadsOnWriter') the action runs
-- before any other write may begin.
transactThen :: Storage -> Who -> Mode -> Tx a -> (a -> IO ()) -> IO (Either WikiError a)
transactThen st who = transactThenFrom st who ""

-- | 'transactThen', for a request from an address.
transactThenFrom :: Storage -> Who -> Text -> Mode -> Tx a -> (a -> IO ()) -> IO (Either WikiError a)
transactThenFrom st who address mode (Tx body) committed = case st.engine of
  Engine p -> retrying (if mode == Reads then p.readers else p.writer) $ \c -> do
    outcome <- withTransactionEither (mode == Writes) c $ do
      tracer <- tracedBegin st (mode == Writes)
      ctx <- context st (mode == Writes) (Conn tracer c) who address
      fmap (ctx,) <$> runExceptT (runReaderT body ctx)
    -- Committed: the action and the notifications come after the commit,
    -- still on the connection, so before any other write may begin.
    for_ outcome $ \(ctx, a) -> do
      committed a
      made <- readIORef ctx.told
      unless (null made) (st.config.notify (reverse made))
    pure (snd <$> outcome)

-- | The context an operation starts from. Its grants include whom the wiki
-- is open to, because the permission rules read that from the grants.
--
-- A transaction that writes reads its permission context from the
-- database. It then decides on the spaces and grants as its own snapshot
-- holds them, and on PostgreSQL the rows it read join its serializable
-- check: if another process changes one of them at the same time, one of
-- the two transactions is run again ('retrying'), rather than a write
-- going through on a permission already taken away. Writes are few, so
-- the reads cost little. A transaction that only reads takes the
-- permission context from memory when it is still the database's
-- ('keptPermissions').
context :: Storage -> Bool -> Conn -> Who -> Text -> IO Ctx
context st writes c who address
  | writes = do
      spaces <- viaConn c loadSpaces
      rows <- viaConn c loadGrants
      contextWith st c who address spaces rows (activeUser c)
  | otherwise = do
      kept <- keptPermissions st c
      contextWith st c who address kept.spaces kept.grants (keptUser st c kept)

-- | 'context', with the spaces and the grants it holds given (every one,
-- or only those some rules need: 'readWithin'), and the function that
-- finds a user who may act, with their groups.
contextWith :: Storage -> Conn -> Who -> Text -> Map SpaceId Space -> Grants -> (UserId -> IO (Maybe (User, Set GroupId))) -> IO Ctx
contextWith st c who address spaces rows activeAs = do
  -- The settings come from memory. The database is read only when memory
  -- has none, which does not happen once 'openWith' has filled it.
  wiki <- readIORef st.settings >>= maybe (viaConn c loadSettings) pure
  server <- readIORef st.serverKept >>= maybe (viaConn c loadServerSettings) pure
  told <- newIORef []
  let stored = Grants {global = rows.global, spaces = rows.spaces, access = wiki.access}
  let ctx grants principal user author creator = Ctx {conn = c, blobs = attachmentsDir st.place.dataDir, spaces, grants, principal, user, author, creator, wiki, server, address, told}
  case who of
    Anonymous -> pure (ctx stored Nothing Nothing Nothing Nothing)
    AsUser u ->
      activeAs u >>= \case
        Nothing -> pure (ctx stored Nothing Nothing Nothing Nothing)
        Just (found, groups) -> pure (ctx stored (Just Principal {user = u, groups}) (Just found) (Just u) (Just u))
    Administrator ->
      pure
        ( ctx
            (stored <> Grants {global = [GlobalGrant {subject = SubjectUser administratorId, permission = Administer}], spaces = [], access = Open})
            (Just Principal {user = administratorId, groups = mempty})
            (Just administratorUser)
            (Just administratorId)
            Nothing
        )

-- | A user who may act (not one whose login is disabled), with their
-- groups, from the database; 'Nothing' for a user who may not, or who does
-- not exist.
activeUser :: Conn -> UserId -> IO (Maybe (User, Set GroupId))
activeUser c u = viaConn c (loadActiveUser u) >>= traverse (\found -> (found,) <$> viaConn c (loadGroupsOf u))

--------------------------------------------------------------------------------
-- The permission context in memory

-- | 'Permissions' is the permission context of one generation, as the
-- storage keeps it in memory: every space and grant, and the users that
-- read transactions of that generation asked as, each with their groups
-- ('Nothing' for a user who may not act). The generation is the number in
-- the database's @permissions_generation@ ('permissionsGeneration'), which
-- the database's triggers bump in every transaction that changes the
-- permission context (the migration @0002-permissions-generation@).
--
-- So a read transaction reads the generation, one statement, and when it
-- is the one kept here, the spaces, the grants and the user come from
-- memory: the database holds the same, in the state the transaction reads.
-- A page view that read every space, every grant, the user and their
-- groups in each of its transactions reads them once per generation. A
-- change made by another process (the console) bumps the generation in
-- the database too, so the next read sees it.
data Permissions = Permissions
  { generation :: Maybe Int64
  -- ^ 'Nothing' for a permission context read without a generation, which
  -- is never kept.
  , spaces :: Map SpaceId Space
  , grants :: Grants
  -- ^ The grants as the database has them, without whom the wiki is open
  -- to, which comes from the settings ('contextWith').
  , users :: Map UserId (Maybe (User, Set GroupId))
  -- ^ At most 'maxKeptUsers' users.
  }

-- | The most users whose permission context the storage keeps in memory
-- for one generation. A user beyond them is read from the database in each
-- read transaction, as every user was before WP5.24. A new generation
-- starts with none kept.
maxKeptUsers :: Int
maxKeptUsers = 500

-- | The permission context of the generation the database has now, in a
-- read transaction: the one in memory if it is that generation's, else
-- the spaces and grants read from the database, which are then kept. The
-- copy is the process's, shared by every reader, so a new generation is
-- read once for the whole process; only reads that find it at the same
-- moment (at most 'readConnections') each read it, and the newer
-- generation is kept.
--
-- Without the generation's row (deleted by hand) there is no generation to
-- trust, and a copy kept under any number could be served after the
-- permission context changed: then it is read from the database and
-- nothing is kept, in every read until the row is back.
keptPermissions :: Storage -> Conn -> IO Permissions
keptPermissions st c =
  viaConn c permissionsGeneration >>= \case
    Nothing -> fresh Nothing
    Just generation ->
      readIORef st.permissions >>= \case
        Just kept | kept.generation == Just generation -> pure kept
        _ -> do
          read' <- fresh (Just generation)
          atomicModifyIORef' st.permissions $ \case
            Just kept | kept.generation >= Just generation -> (Just kept, ())
            _ -> (Just read', ())
          pure read'
  where
    fresh generation = do
      spaces <- viaConn c loadSpaces
      grants <- viaConn c loadGrants
      pure Permissions {generation, spaces, grants, users = mempty}

-- | A user who may act, with their groups, in a read transaction of the
-- generation of the permission context given: from memory if a read of
-- that generation found them, else from the database, and then kept.
keptUser :: Storage -> Conn -> Permissions -> UserId -> IO (Maybe (User, Set GroupId))
keptUser st c kept u = case Map.lookup u kept.users of
  Just found -> pure found
  Nothing -> do
    found <- activeUser c u
    let remember held
          | isJust kept.generation && held.generation == kept.generation && Map.size held.users < maxKeptUsers = Permissions {generation = held.generation, spaces = held.spaces, grants = held.grants, users = Map.insert u found held.users}
          | otherwise = held
    atomicModifyIORef' st.permissions (\held -> (remember <$> held, ()))
    pure found

-- | A read about one thing in one space, on a reader: an attachment's
-- bytes, which every image of a page asks for. @locate@ finds the space
-- the thing is in, and whatever the read needs of it; 'Nothing' is
-- 'NotFound'. The permission context is the one in memory
-- ('keptPermissions'), read from the database and kept when the
-- generation has changed, so that the images of a page after a change
-- read it once between them. The operation must not look at any other
-- space than the one found.
readWithin :: Storage -> Who -> (forall be. (Backend be) => Db be (Maybe (SpaceId, b))) -> (SpaceId -> b -> Tx a) -> IO (Either WikiError a)
readWithin st who locate body = case st.engine of
  Engine p -> withResource p.readers $ \c -> withTransaction False c $ do
    tracer <- tracedBegin st False
    let conn = Conn tracer c
    runTraced tracer c locate >>= \case
      Nothing -> pure (Left NotFound)
      Just (sid, found) -> do
        -- The permission context is read only when the attachment
        -- exists, so a request for a missing one costs no read of it.
        kept <- keptPermissions st conn
        ctx <- contextWith st conn who "" kept.spaces kept.grants (keptUser st conn kept)
        let Tx tx = body sid found
        runExceptT (runReaderT tx ctx)

-- | Run statements on the transaction's connection.
db :: (forall be. (Backend be) => Db be a) -> Tx a
db action = asks (\x -> x.conn) >>= \c -> liftIO (viaConn c action)

failWith :: WikiError -> Tx a
failWith = throwError

invalid :: Text -> Tx a
invalid = failWith . Invalid

-- | 'Forbidden' unless the condition holds.
require :: Bool -> Tx ()
require ok = unless ok (failWith Forbidden)

-- | A space's chain from the top level, or none if it is not there.
chainOf :: Ctx -> SpaceId -> [Space]
chainOf ctx sid = fromMaybe [] (ancestry (`Map.lookup` ctx.spaces) sid)

-- | Whether a chain goes through the given space.
within :: SpaceId -> [Space] -> Bool
within sid = any (\s -> s.id == sid)

-- | A space by id, with its chain.
findSpace :: SpaceId -> Tx (Space, [Space])
findSpace sid = do
  ctx <- ask
  maybe (failWith NotFound) (\s -> pure (s, chainOf ctx sid)) (Map.lookup sid ctx.spaces)

-- | A page by id, as a node.
findNode :: PageId -> Tx PageNode
findNode pid = db (pageNode pid) >>= maybe (failWith NotFound) pure

-- | A page by id, whole.
findPage :: PageId -> Tx Page
findPage pid = db (loadPage pid) >>= maybe (failWith NotFound) pure

-- | The chain of a page's space.
chainOfPage :: PageNode -> Tx [Space]
chainOfPage p = asks (`chainOf` p.space)

-- | 'NotFound' unless the caller may view the last space of the chain. A
-- space the caller may not view answers exactly as a space that does not
-- exist, and so does everything in it: its pages, their attachments,
-- comments, versions and drafts, its watches and its subspaces. Otherwise
-- a 'Forbidden' would tell anyone that the space, or a page in it, exists.
-- Every transaction that names a space or a page checks this first, and
-- only then whether the caller may do what is asked ('requireEdit',
-- 'requireAdminister'), which is 'Forbidden' when they may not.
requireView :: [Space] -> Tx ()
requireView c = ask >>= \x -> unless (canView x.principal x.grants c) (failWith NotFound)

requireEdit :: [Space] -> Tx ()
requireEdit c = requireView c >> ask >>= \x -> require (canEdit x.principal x.grants c)

requireAdminister :: [Space] -> Tx ()
requireAdminister c = requireView c >> ask >>= \x -> require (canAdministerSpace x.principal x.grants c)

-- | A name or title with the blanks around it trimmed, or 'Invalid' if
-- nothing is left.
nonBlank :: Text -> Text -> Tx Text
nonBlank what t = case T.strip t of
  "" -> invalid (what <> " cannot be blank.")
  stripped -> pure stripped

-- | A new id: a UUID.
newId :: Tx Text
newId = liftIO (UUID.toText <$> generateV4)

-- | The time now, to the microsecond ('micro'): a time the storage makes
-- is written to the database and compared with what comes back, so it
-- must be no finer than a database keeps.
now :: Tx UTCTime
now = liftIO (micro <$> getCurrentTime)

-- | A slug for a name with nothing a slug can be made of.
fallbackSlug :: Text -> Slug
fallbackSlug t = either (\e -> panic ("not a slug: " <> t <> ", " <> show e)) identity (mkSlug t)

-- | Record an administration write in the audit log (WP4.10 of
-- docs/PLAN.md), in this transaction, with who asked and from which
-- address: what was done, to what, and what changed, never a secret.
record :: Text -> Audit.Subject -> [(Text, Text)] -> Tx ()
record action subject detail = do
  ctx <- ask
  let actor = maybe nobody (\u -> Actor {id = u.id, login = u.login}) ctx.user
  db (insertAudit Recorded {actor, action, subject, detail, address = ctx.address})
  where
    nobody = Actor {id = UserId "~anonymous", login = Login "anonymous"}

-- | How an audit log entry names a space, a user, a group or settings.
spaceSubject :: Space -> Audit.Subject
spaceSubject sp = Audit.Subject {kind = "space", id = Just sp.id.text, name = sp.name}

userSubject :: User -> Audit.Subject
userSubject u = Audit.Subject {kind = "user", id = Just u.id.text, name = u.login.text}

groupSubject :: GroupId -> Text -> Audit.Subject
groupSubject g name = Audit.Subject {kind = "group", id = Just g.text, name}

settingsSubject :: Text -> Audit.Subject
settingsSubject name = Audit.Subject {kind = "settings", id = Nothing, name}

-- | A space's path, as a person reads it: @docs/guides@.
spacePathText :: [Space] -> Text
spacePathText = T.intercalate "/" . map (\sp -> slugText sp.slug)

yesNo :: Bool -> Text
yesNo b = if b then "yes" else "no"

--------------------------------------------------------------------------------
-- The wiki

-- | 'StoredWiki' is the 'MonadWiki' backend over a storage, run as a
-- 'Who'. It works over any base monad that does IO, so that a program in
-- another monad (a component the server prerenders) can run over it.
newtype StoredWiki m a = StoredWiki (ReaderT Env m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO)

data Env = Env
  { storage :: Storage
  , who :: Who
  , address :: Text
  -- ^ Where the request came from, for the audit log.
  }

instance (MonadUUID m) => MonadUUID (StoredWiki m) where
  generateV4 = StoredWiki (lift generateV4)

-- | Run a program against the wiki in a storage, as a 'Who', with no
-- request address. This is for the server's prerender, which writes
-- nothing, so the audit log needs no address.
runStoredWiki :: Storage -> Who -> StoredWiki m a -> m a
runStoredWiki storage who = runStoredWikiFrom storage who ""

-- | Run a program as a 'Who' asking from an address. The audit log records
-- the address for each administration write the program makes.
runStoredWikiFrom :: Storage -> Who -> Text -> StoredWiki m a -> m a
runStoredWikiFrom storage who address (StoredWiki program) = runReaderT program Env {storage, who, address}

-- | How the audit log names a 'Who': a user by their login, the operator
-- as @administrator@, a reader who has not signed in as @anonymous@.
actorOf :: Storage -> Who -> IO Actor
actorOf st who = case who of
  Anonymous -> pure Actor {id = UserId "~anonymous", login = Login "anonymous"}
  Administrator -> pure Actor {id = administratorId, login = administratorUser.login}
  AsUser u -> maybe Actor {id = u, login = Login u.text} (\found -> Actor {id = found.id, login = found.login}) <$> reading st (loadUser u)

run :: (MonadIO m) => Mode -> Tx a -> StoredWiki m (Either WikiError a)
run mode tx = StoredWiki $ do
  env <- ask
  liftIO (transactFrom env.storage env.who env.address mode tx)

-- | A read that returns no @Either@: on an error, it returns the fallback.
answer :: (MonadIO m) => a -> Tx a -> StoredWiki m a
answer fallback tx = fromRight fallback <$> run Reads tx

instance (MonadIO m) => MonadWiki (StoredWiki m) where
  session = answer anonymous sessionTx
  listSpaces = answer [] listSpacesTx
  getSpace = run Reads . getSpaceTx
  createSpace parent = run Writes . createSpaceTx parent
  renameSpace sid = run Writes . renameSpaceTx sid
  setSpacePublic sid = run Writes . setSpacePublicTx sid
  setSpaceMathMacros sid macros = run Writes (adjustSpace sid (\s -> pure s {mathMacros = trimLines macros}))
  setSpaceProfile sid = run Writes . setSpaceProfileTx sid
  uploadSpaceIcon sid mediaType bytes = run Writes (uploadSpaceIconTx sid mediaType (fromIntegral (BS.length bytes)) (`storeBlob` bytes))
  spaceIconUrl s = case s.icon of
    Just (IconImage _ _) -> StoredWiki (asks (\env -> env.storage.config.iconAddress s))
    _ -> pure ""
  pageCounts = answer mempty pageCountsTx
  spaceAccess = run Reads . spaceAccessTx
  setSpaceGrant sid subject permission = run Writes . setSpaceGrantTx sid subject permission
  moveSpace sid = run Writes . moveSpaceTx sid
  deleteSpace = run Writes . deleteSpaceTx
  setSpaceOrder sid kind = run Writes . setSpaceOrderTx sid kind
  shiftSpace sid = run Writes . shiftSpaceTx sid
  shiftPage pid = run Writes . shiftPageTx pid
  listPages = run Reads . listPagesTx
  postDetails = run Reads . postDetailsTx
  getPage sid = run Reads . getPageTx sid
  createPage sid parent title = run Writes . createPageTx sid parent title
  savePage pid base title = saving . savePageTx pid base title
  movePage pid sid = run Writes . movePageTx pid sid
  setPageTemplate pid = run Writes . setPageTemplateTx pid
  deletePage = run Writes . deletePageTx
  uploadAttachment pid name mediaType bytes = run Writes (uploadAttachmentTx pid name mediaType (fromIntegral (BS.length bytes)) (`storeBlob` bytes))
  deleteAttachment = run Writes . deleteAttachmentTx
  attachmentUrl a = case a.source of
    SourceUrl url -> pure url.text
    SourceBlob _ -> do
      address <- StoredWiki (asks (\env -> env.storage.config.attachmentAddress))
      answer "" (maybe "" (const (address a)) <$> db (loadAttachment a.id))
  searchPages = answer [] . searchPagesTx
  getDraft = run Reads . getDraftTx
  saveDraft pid base title = run Writes . saveDraftTx pid base title
  discardDraft = run Writes . discardDraftTx
  listVersions pid = run Reads . listVersionsTx pid
  getVersion pid = run Reads . getVersionTx pid
  restoreVersion pid at = saving . restoreVersionTx pid at

-- | The administration operations, as the class's Haddock describes them
-- ("Wiki.App.Backend.Admin"). Each operation is one transaction that
-- first checks that the caller holds the global administer: the
-- administrator always does, and a user does through a grant.
instance (MonadIO m) => MonadAdmin (StoredWiki m) where
  directory = run Reads directoryTx
  userPage = run Reads . userPageTx
  setAdministrator u = run Writes . setGlobalGrantTx Administer u
  setCreateSpaces u = run Writes . setGlobalGrantTx CreateSpaces u

  -- A password is checked and hashed before the transaction that keeps
  -- it, since hashing takes tens of milliseconds the database should not
  -- wait for; and only for an administrator whom the wiki's settings let
  -- create accounts, so that nobody else can make the server spend that
  -- time. The transaction checks both again.
  createUser new =
    run Reads requireAccountCreator >>= \case
      Left e -> pure (Left e)
      Right () -> case (,) <$> parseLogin new.login <*> checkNewPassword new.password of
        Left why -> pure (Left (Invalid why))
        Right (login, password) -> do
          phc <- liftIO (hashPassword password)
          uid <- liftIO (UUID.toText <$> generateV4)
          let name = case T.strip new.displayName of
                "" -> login.text
                n -> n
          run Writes $ do
            requireAccountCreator
            db (insertAccount (UserId uid) login name (Just phc)) >>= \case
              Left taken -> failWith (Conflict ("There is a user with the login " <> taken.text <> " already."))
              Right account -> do
                record "user.create" (userSubject account.user) [("login", login.text), ("name", name)]
                pure account
  setPassword u password =
    run Reads (requireAdministrator >> findUser u >>= requirePasswordToSet) >>= \case
      Left e -> pure (Left e)
      Right _ -> case checkNewPassword password of
        Left why -> pure (Left (Invalid why))
        Right p -> do
          phc <- liftIO (hashPassword p)
          -- The audit log records that the password changed, never the
          -- password.
          run Writes $ do
            requireAdministrator
            findUser u >>= requirePasswordToSet
            changeAccountTx "user.password" [] u (updatePasswordHash u phc >> deleteSessionsOf u)

  -- Sending mail needs the server, not the storage: the server's API
  -- mails the link that 'passwordLinkFor' makes.
  sendPasswordLink u = run Reads (requireAdministrator >> findUser u >> failWith (Invalid "Only the server's API sends mail."))
  setDisabled u disabled =
    run Writes $
      changeAccountTx
        (if disabled then "user.disable" else "user.enable")
        []
        u
        (updateDisabled u disabled >> when disabled (deleteSessionsOf u))
  createGroup = run Writes . createGroupTx
  renameGroup g = run Writes . renameGroupTx g
  deleteGroup = run Writes . deleteGroupTx
  addMember g = run Writes . setMemberTx True g
  removeMember g = run Writes . setMemberTx False g
  wikiSettings = run Reads (requireAdministrator >> asks (\x -> x.wiki))

  -- The settings kept in memory are the new ones as soon as they are
  -- committed, before any other write may begin.
  setWikiSettings new = StoredWiki $ do
    env <- ask
    liftIO (transactThenFrom env.storage env.who env.address Writes (setWikiSettingsTx new) (writeIORef env.storage.settings . Just))

  -- The storage sends no mail. Whether the server does, the server's API
  -- says itself ("Wiki.Server.Api").
  invitations = run Reads invitationsTx
  invite email = liftIO (InvitationToken <$> newToken) >>= run Writes . inviteTx email
  revokeInvitation = run Writes . revokeInvitationTx
  unlinkUserIdentity u = run Writes . unlinkUserIdentityTx u
  removeSecondFactor = run Writes . removeSecondFactorTx
  removeUser = run Writes . removeUserTx

  -- The server's own settings: kept in memory as soon as they are
  -- committed, as the wiki's are, and never returned with their secrets.
  serverSettings = run Reads (requireAdministrator >> asks (\x -> hideSecrets x.server))
  setServerSettings change = StoredWiki $ do
    env <- ask
    fmap hideSecrets <$> liftIO (transactThenFrom env.storage env.who env.address Writes (setServerSettingsTx change) (writeIORef env.storage.serverKept . Just))

  -- Asking a provider and sending mail need the server, not the storage:
  -- the server's API does both ("Wiki.Server.Api"), with the settings the
  -- storage keeps ('readServerSettings').
  checkProvider _ _ = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API asks a provider."))
  sendTestMail _ = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API sends mail."))

  -- The backups as the storage records them: their settings and the last
  -- backup made. Only the server knows whether a backup is running and
  -- when the next is due ("Wiki.Server.Backups"), and only the server
  -- makes one; its API answers with both.
  backups = StoredWiki (ask >>= \env -> liftIO (readBackups env.storage env.who))
  setBackupSettings change = StoredWiki $ do
    env <- ask
    liftIO (transactFrom env.storage env.who env.address Writes (setBackupSettingsTx change)) >>= \case
      Left e -> pure (Left e)
      Right _ -> liftIO (readBackups env.storage env.who)
  backUpNow = run Reads (requireAdministrator >> failWith (Invalid "Only the server makes a backup."))

  -- The audit log, as the storage keeps it. The server's status (its
  -- errors, its connections) belongs to the server, and the server's API
  -- answers for it ("Wiki.Server.Api").
  activity q = run Reads (requireAdministrator >> db (loadActivity q))
  serverStatus = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API says how the server is."))

-- | The backups, for an administrator: their settings (with only whether
-- the configuration is set, not the configuration), the last backup made
-- or tried, and how many backups the data directory holds. It always says
-- that no backup is running and none is due next, since only the server
-- knows those ('Wiki.Server.Backups').
readBackups :: Storage -> Who -> IO (Either WikiError Backups)
readBackups st who =
  transact st who Reads (requireAdministrator >> db ((,) <$> loadBackupSettings <*> loadLastBackup)) >>= \case
    Left e -> pure (Left e)
    Right (settings, lastMade) -> do
      kept <- length <$> backupFiles (backupsDir st.place.dataDir)
      pure (Right Backups {available = True, settings = secretState <$> settings, last = lastMade, running = False, next = Nothing, kept})

-- | The backup settings, with the configuration itself, for the server
-- that makes the backups.
readBackupSettings :: Storage -> IO KeptBackups
readBackupSettings st = reading st loadBackupSettings

-- | The last backup made or tried, for the server that makes the backups.
readLastBackup :: Storage -> IO (Maybe BackupRecord)
readLastBackup st = reading st loadLastBackup

-- | Store the outcome of the last backup.
writeLastBackup :: Storage -> BackupRecord -> IO ()
writeLastBackup st r = writing st (storeLastBackup r)

-- | Make a backup of the database into the data directory's backups,
-- named for a time, and check it ('Wiki.Server.Storage.Backup.backupInto').
-- The copy is made through a connection opened for it alone, which reads
-- the last committed state as a reader does: neither reads nor writes wait
-- for it, however long it takes. The result is the backup's file and its
-- size, or why there is none.
backUp :: Storage -> UTCTime -> IO (Either Text (FilePath, Integer))
backUp st = backupInto st.place.programs st.place.database (backupsDir st.place.dataDir)

-- | Whether a 'Who' may read a page that exists. The live channel checks
-- this before it sends them events about the page ("Wiki.Server.Events").
-- It runs on a reader, so the checks of many tabs run side by side and no
-- write waits for them.
mayReadPage :: Storage -> Who -> PageId -> IO Bool
mayReadPage st who pid = isRight <$> transact st who Reads (findNode pid >>= chainOfPage >>= requireView)

-- | A user's notification, updated with where its page is now, if the user
-- may still read the page. The thread that mails notifications checks this
-- before it mails one ("Wiki.Server.Notifier").
locatedFor :: Storage -> UserId -> Notification -> IO (Maybe Notification)
locatedFor st u n = fromRight Nothing <$> transact st (AsUser u) Reads (locatedTx n)

-- | The 'Author' the live channel shows for someone editing a page, if
-- they may edit it ('Nothing' if they may not, if the page does not exist,
-- or if they have not signed in). The live channel checks this before it
-- tells anyone that this person is editing the page.
editorOf :: Storage -> Who -> PageId -> IO (Maybe Author)
editorOf st who pid =
  rightToMaybe
    <$> transact
      st
      who
      Reads
      ( do
          p <- findNode pid
          requireEdit =<< chainOfPage p
          asks (\x -> x.user) >>= maybe (failWith Forbidden) (\u -> pure Author {id = u.id, name = u.displayName})
      )

-- | A page's threads, if the 'Who' may read them ('Left' if they may not,
-- or the page does not exist), and an action run on them before any write
-- can commit. The live channel subscribes with this ("Wiki.Server.Events"):
-- every change after the read is sent after the threads, and no change can
-- fall between the read and the subscription unsent.
--
-- This is the one read that runs on the writer ('ReadsOnWriter'), not on a
-- reader. The guarantee needs the read and the subscription to happen
-- before any write commits, and only the writer can promise that: a write
-- runs its callbacks ('publish') on the writer too, so a write that
-- commits after the read reports its change after the subscription.
threadsThen :: Storage -> Who -> PageId -> ([Thread] -> IO ()) -> IO (Either WikiError [Thread])
threadsThen st who pid = transactThen st who ReadsOnWriter (listThreadsTx pid)

-- | The comment operations, as the class's Haddock describes them
-- ("Wiki.App.Backend.Comments"). Each operation is one transaction, and
-- each write is reported through 'publish' once it is committed.
instance (MonadIO m) => MonadComments (StoredWiki m) where
  listThreads = run Reads . listThreadsTx
  openThread pid anchor = commenting . openThreadTx pid anchor
  reply pid tid = commenting . replyTx pid tid
  editComment pid tid cid = commenting . editCommentTx pid tid cid
  deleteComment pid tid = commenting . deleteCommentTx pid tid
  deleteThread pid = commenting . deleteThreadTx pid
  setResolved pid tid = commenting . setResolvedTx pid tid

-- | Run a write to a page's comments, which returns its event on the page,
-- and publish that event once the write is committed.
commenting :: (MonadIO m) => Tx (a, PageId, PageEvent) -> StoredWiki m (Either WikiError a)
commenting tx = StoredWiki $ do
  env <- ask
  liftIO $
    fmap (\(a, _, _) -> a)
      <$> transactThen env.storage env.who Writes tx (\(_, page, event) -> env.storage.config.publish page event)

-- | Run a save of a page, and publish it once it is committed, so that a
-- tab showing the page fetches it again.
saving :: (MonadIO m) => Tx Page -> StoredWiki m (Either WikiError Page)
saving tx = StoredWiki $ do
  env <- ask
  liftIO (transactThen env.storage env.who Writes tx (\p -> env.storage.config.publish p.id (PageChanged p.updatedAt)))

-- | An attachment, if the 'Who' may view its page, with the file its bytes
-- are in when the storage holds them ('Nothing' for an attachment that
-- lives on the web). The server's route for an attachment's bytes serves
-- this.
--
-- It reads the attachment and its page's space in one query, and the
-- permission context from memory, read once per generation ('readWithin'):
-- a page with many images asks for each of them.
attachmentFile :: (MonadIO m) => AttachmentId -> StoredWiki m (Either WikiError (Attachment, Maybe FilePath))
attachmentFile aid = StoredWiki . ReaderT $ \env -> liftIO . readWithin env.storage env.who (loadAttachmentIn aid) $ \sid a -> do
  requireView =<< asks (`chainOf` sid)
  dir <- asks (\x -> x.blobs)
  pure
    ( a
    , case a.source of
        SourceBlob b -> blobFile dir b
        SourceUrl _ -> Nothing
    )

-- | The pages of a space, with their bodies and attachments, in the
-- space's page order, if the 'Who' may view the space. A space's export
-- reads this ('spacePagesTx'). A blog's feed reads only its posts
-- ('feedPosts').
spacePages :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError [Page])
spacePages = run Reads . spacePagesTx

-- | The pages of every space the 'Who' may view, by space, as the sitemap
-- lists them: without their titles or text, all in one query. A space
-- the 'Who' may view with no pages has an empty list; a space they may
-- not view is not there.
sitemapPages :: (MonadIO m) => StoredWiki m (Map SpaceId [SitemapNode])
sitemapPages = answer mempty $ do
  ctx <- ask
  let viewable = [sid | sid <- Map.keys ctx.spaces, canView ctx.principal ctx.grants (chainOf ctx sid)]
  -- SQLite would read every page for an empty @IN ()@.
  nodes <- if null viewable then pure [] else db (loadSitemapNodes viewable)
  pure (Map.fromListWith (<>) ([(sid, []) | sid <- viewable] <> [(n.space, [n]) | n <- nodes]))

-- | Some pages of a space, whole, each with the author of its first
-- version, if the 'Who' may view the space. A blog's feed reads the posts
-- it carries with this, and no other page's body. A page that is not in
-- the space, or not there at all, is left out.
feedPosts :: (MonadIO m) => SpaceId -> [PageId] -> StoredWiki m (Either WikiError [(Page, Maybe Author)])
feedPosts sid pids = run Reads $ do
  (_, c) <- findSpace sid
  requireView c
  fmap catMaybes . for pids $ \pid ->
    db (loadPage pid) >>= \case
      Just p | p.space == sid -> do
        made <- db (loadFirstVersion pid)
        pure (Just (p, made >>= \r -> (versionOf pid r).author))
      _ -> pure Nothing

-- | A page by its id, if the 'Who' may read it. An export reads the page
-- with this ("Wiki.Server.Export"), and reads the rest (its space's pages,
-- the spaces) through 'MonadWiki', as the application does.
exportedPage :: (MonadIO m) => PageId -> StoredWiki m (Either WikiError Page)
exportedPage pid = run Reads $ do
  requireView =<< chainOfPage =<< findNode pid
  findPage pid

-- | The file that holds a blob's bytes, if the blob id names one. An export
-- reads images from it. This checks no permission: the caller must already
-- have checked that the reader may see the page that has the blob.
blobPath :: Storage -> BlobId -> Maybe FilePath
blobPath st = blobFile (attachmentsDir st.place.dataDir)

-- | A space's icon image, if the 'Who' may view the space: its media type
-- and its file. The image is looked up by its blob id, which is part of
-- its URL, so a replaced image gets a new URL. The server's route for
-- space icons serves this. A blob that is not the space's image is
-- 'NotFound'.
spaceIconFile :: (MonadIO m) => SpaceId -> BlobId -> StoredWiki m (Either WikiError (MimeType, FilePath))
spaceIconFile sid blob = run Reads $ do
  (s, c) <- findSpace sid
  requireView c
  dir <- asks (\x -> x.blobs)
  case s.icon of
    Just (IconImage b mediaType) | b == blob, Just file <- blobFile dir b -> pure (mediaType, file)
    _ -> failWith NotFound

--------------------------------------------------------------------------------
-- Reads

sessionTx :: Tx Session
sessionTx = do
  ctx <- ask
  pure $ case (,) <$> ctx.user <*> ctx.principal of
    Nothing -> anonymousIn ctx.grants.access
    Just (u, p) ->
      Session
        { user = Just u
        , groups = p.groups
        , grants =
            Grants
              { global = filter (\g -> isFor p g.subject) ctx.grants.global
              , spaces = filter (\g -> isFor p g.subject) ctx.grants.spaces
              , access = ctx.grants.access
              }
        , -- The administrator is the operator. Any other user is whoever
          -- signed in, since the server runs the request as that user.
          standing = if u.id == administratorId then Operator else SignedIn
        , -- The server's configuration names them, not the storage: the
          -- API adds them ("Wiki.Server.Api").
          providers = []
        , -- Nor the export formats: they depend on pandoc and on the
          -- machine, and the API adds them too.
          exports = []
        }

listSpacesTx :: Tx [Space]
listSpacesTx = do
  ctx <- ask
  let visible = filter (canView ctx.principal ctx.grants) (map (chainOf ctx) (Map.keys ctx.spaces))
      listed = Set.fromList (map (\s -> s.id) (concat visible))
  pure (spaceTreeOrder (Map.elems (Map.restrictKeys ctx.spaces listed)))

-- | The number of pages in each space the caller may view, not counting
-- templates.
pageCountsTx :: Tx (Map SpaceId Int)
pageCountsTx = do
  ctx <- ask
  byId <- db countPagesBySpace
  pure
    ( Map.fromList
        [ (sid, Map.findWithDefault 0 sid byId)
        | sid <- Map.keys ctx.spaces
        , canView ctx.principal ctx.grants (chainOf ctx sid)
        ]
    )

getSpaceTx :: [Slug] -> Tx Space
getSpaceTx path = do
  ctx <- ask
  case resolvePath (findChild (Map.elems ctx.spaces)) path of
    Right c | Just s <- lastMay c -> requireView c $> s
    _ -> failWith NotFound

listPagesTx :: SpaceId -> Tx [PageSummary]
listPagesTx sid = do
  (s, c) <- findSpace sid
  requireView c
  pageTreeOrder s.pageOrder <$> db (loadPageSummaries sid)

-- | The pages of a space with their bodies and attachments, in the space's
-- page order, for someone who may view the space. The API's list of pages
-- carries summaries only ('listPagesTx'); the server's own work on a whole
-- space (a space's export) needs the bodies.
spacePagesTx :: SpaceId -> Tx [Page]
spacePagesTx sid = do
  (s, c) <- findSpace sid
  requireView c
  pageTreeOrder s.pageOrder <$> db (loadPages sid)

-- | The details each page of a space is listed with as a blog post: the
-- author of its first version, how many comments it has, and its excerpt.
-- The first version is the one saved when the page was created
-- ('loadFirstVersions'): one version is read for each page, not every
-- version of the space. Only the bodies of the pages that can be posts
-- are read.
postDetailsTx :: SpaceId -> Tx (Map PageId PostDetails)
postDetailsTx sid = do
  (s, c) <- findSpace sid
  requireView c
  pages <- db (loadPageSummaries sid)
  firsts <- Map.fromList <$> db (loadFirstVersions sid)
  counts <- Map.fromList <$> db (loadCommentCounts sid)
  bodies <- Map.fromList <$> db (loadPostBodies sid)
  let details p =
        PostDetails
          { author = (Map.lookup p.id firsts >>= \r -> (versionOf p.id r).author)
          , comments = Map.findWithDefault 0 p.id counts
          , -- Only a post is listed with its excerpt: parsing every page
            -- of a large space for nothing would slow the answer down.
            excerpt = if isPost s p then maybe "" Blog.excerptOf (Map.lookup p.id bodies) else ""
          }
  pure (Map.fromList [(p.id, details p) | p <- pages])

-- | A page by its path in a space. The path is followed one slug at a
-- time, each step one query through the index of siblings' slugs
-- ('childPage'), so the reads grow with the path's length, not with the
-- size of the space.
getPageTx :: SpaceId -> [Slug] -> Tx Page
getPageTx sid path = do
  (_, c) <- findSpace sid
  requireView c
  resolvePathM (\parent slug -> db (childPage sid parent slug)) path >>= \case
    Right ps | Just p <- lastMay ps -> findPage p.id
    _ -> failWith NotFound

-- | The search over the pages the user may view in the spaces the query
-- asks for. The database picks the pages, of the spaces searched only
-- ('Backend.searchMatches'). On PostgreSQL, its full-text search finds the
-- pages whose words match and ranks them, and the best are made hits
-- ('searchRanked'). On SQLite, the pages whose stored fold has every word
-- of the query are found, and 'searchPlain' checks and ranks them, as the
-- demo's search does. Only the pages found have their titles and texts
-- folded again here, since a hit's marks and snippet need the fold of the
-- original text. So a search costs what its matches cost, not what the
-- whole wiki holds.
searchPagesTx :: SearchQuery -> Tx [SearchHit]
searchPagesTx q = do
  ctx <- ask
  let wanted c = case q.space of
        Nothing -> True
        Just sid
          | q.includeSubspaces -> within sid c
          | otherwise -> fmap (\s -> s.id) (lastMay c) == Just sid
      searched =
        Map.filter
          (\c -> wanted c && canView ctx.principal ctx.grants c)
          (Map.mapWithKey (\sid _ -> chainOf ctx sid) ctx.spaces)
      ws = queryWords q
  -- No words find nothing, and no space has nothing to find. SQLite would
  -- read every page for an empty @IN ()@.
  if null ws || Map.null searched
    then pure []
    else do
      rows <- db (searchMatches (map (\sid -> sid.text) (Map.keys searched)) q.templates ws (foldText q.text) q.limit)
      let found = [(nodeOf n, text, rank) | (n, text, rank) <- rows]
      nodes <- withAncestors (map (\(n, _, _) -> n) found)
      let candidates =
            [ ( rank
              , Candidate
                  { page = n.id
                  , space = n.space
                  , spacePath = map (\s -> s.slug) c
                  , pagePath
                  , text = Searchable {title = folded n.title, body = folded text}
                  }
              )
            | (n, text, rank) <- found
            , Just c <- [Map.lookup n.space searched]
            , Just pagePath <- [pathOf (`Map.lookup` nodes) n.id]
            ]
      -- A database that ranks its matches (PostgreSQL) has found the
      -- best; one that does not (SQLite) has found every page with every
      -- word somewhere in its fold, which the matcher checks and ranks.
      pure $ case traverse (\(rank, c) -> (,c) <$> rank) candidates of
        Just ranked | not (null ranked) -> searchRanked q ranked
        _ -> searchPlain q (map snd candidates)

-- | These pages and every page above them, by id: what 'pathOf' needs to
-- find each one's path. The pages above are read one level at a time, all
-- of a level in one query, so the reads grow with the depth of the tree,
-- not with the size of a space.
withAncestors :: [PageNode] -> Tx (Map PageId PageNode)
withAncestors = go mempty
  where
    go found nodes = do
      let more = found <> Map.fromList [(n.id, n) | n <- nodes]
          missing = ordNub [p | n <- nodes, Just p <- [n.parent], Map.notMember p more]
      if null missing then pure more else db (pageNodesWithIds missing) >>= go more

--------------------------------------------------------------------------------
-- Spaces

createSpaceTx :: Maybe SpaceId -> Text -> Tx Space
createSpaceTx parent name = do
  ctx <- ask
  parentChain <- traverse (fmap snd . findSpace) parent
  traverse_ requireView parentChain
  require (mayCreateSpace ctx.principal ctx.grants parentChain)
  n <- nonBlank "A space's name" name
  i <- newId
  time <- now
  let others = Map.elems ctx.spaces
      space =
        Space
          { id = SpaceId i
          , name = n
          , slug = freshSlug (isJust . findChild others parent) (fromMaybe (fallbackSlug "space") (slugify n))
          , parent
          , public = False
          , mathMacros = ""
          , createdAt = time
          , position = nextPosition (childrenOf others parent)
          , subspaceOrder = ByName
          , pageOrder = ByName
          , homePage = Nothing
          , icon = Nothing
          , description = ""
          , blog = False
          }
  db (insertSpace space)
  for_ ctx.creator $ \u ->
    db (insertGrants Grants {global = [], spaces = [SpaceGrant {space = space.id, subject = SubjectUser u, permission = AdministerSpace}], access = Open})
  -- Its home page, created as if the space's creator had created it, and
  -- then set as the space's home page, which requires the page to exist.
  j <- newId
  let home =
        Page
          { id = PageId j
          , space = space.id
          , parent = Nothing
          , title = homeTitle
          , slug = fromMaybe (fallbackSlug "page") (slugify homeTitle)
          , body = homeBody n
          , attachments = []
          , createdAt = time
          , updatedAt = time
          , position = 0
          , template = False
          }
      withHome = withProfile SpaceProfile {description = "", icon = Nothing, homePage = Just home.id, blog = False} space
  author <- asks (\x -> x.author)
  db (insertPage home >> insertVersion home author >> updateSpace withHome)
  pure withHome

-- | Give a space a profile, checked against its pages.
setSpaceProfileTx :: SpaceId -> SpaceProfile -> Tx Space
setSpaceProfileTx sid p = do
  (s, c) <- findSpace sid
  requireAdminister c
  nodes <- db (pageNodes sid)
  checked <- either invalid pure (checkProfile s (map (\n -> n.id) nodes) p)
  let s' = withProfile checked s
  db (updateSpace s')
  -- The space's settings save the whole profile at once, so a save that
  -- changed nothing is not recorded in the audit log.
  let changed = profileChanges nodes s s'
  unless (null changed) (record "space.profile" (spaceSubject s') changed)
  pure s'

-- | What a change of a space's profile changed, in words: the description
-- as it is now, the icon as what it is, the home page by its title.
profileChanges :: [PageNode] -> Space -> Space -> [(Text, Text)]
profileChanges nodes old new =
  [("description", if T.null new.description then "none" else new.description) | old.description /= new.description]
    <> [("icon", maybe "the default" iconText new.icon) | old.icon /= new.icon]
    <> [("home page", maybe "none" titleOf new.homePage) | old.homePage /= new.homePage]
    <> [("blog", yesNo new.blog) | old.blog /= new.blog]
  where
    iconText = \case
      IconEmoji e -> e
      IconColour c -> "colour " <> c
      IconImage _ _ -> "an uploaded image"
    titleOf pid = maybe pid.text (\n -> n.title) (find (\n -> n.id == pid) nodes)

-- | Set a space's icon to an image, its bytes stored under their hash as
-- an attachment's are. The previous image's file is left for the deletion
-- of unreferenced files ("Wiki.Server.Storage.Blobs"). The image is this
-- many bytes, which the last argument stores in the blob directory given
-- to it, after the checks.
uploadSpaceIconTx :: SpaceId -> Text -> Integer -> (FilePath -> IO BlobId) -> Tx Space
uploadSpaceIconTx sid mediaType size store = do
  (s, c) <- findSpace sid
  requireAdminister c
  mt <- either invalid pure (checkIconUpload mediaType (fromIntegral size))
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (store dir)
  let s' = withProfile SpaceProfile {description = s.description, icon = Just (IconImage blob mt), homePage = s.homePage, blog = s.blog} s
  db (updateSpace s')
  -- The icon is part of the profile; it has its own operation only
  -- because it carries bytes.
  record "space.profile" (spaceSubject s') [("icon", "an uploaded image")]
  pure s'

-- | Change a space, as someone who administers it.
adjustSpace :: SpaceId -> (Space -> Tx Space) -> Tx Space
adjustSpace sid f = do
  (s, c) <- findSpace sid
  requireAdminister c
  s' <- f s
  db (updateSpace s')
  pure s'

-- | Who may do what on a space, for whoever administers it.
spaceAccessTx :: SpaceId -> Tx SpaceAccess
spaceAccessTx sid = do
  (_, c) <- findSpace sid
  requireAdminister c
  -- The wiki's grants as stored, not the context's, which include the
  -- operator's grant of everything.
  stored <- db loadGrants
  users <- db loadUsers
  groups <- db loadGroups
  pure
    SpaceAccess
      { grants = [g | s <- reverse c, g <- stored.spaces, g.space == s.id]
      , users = sortOn (\u -> u.login) users
      , groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) groups
      }

-- | Give someone a permission on a space, or take it from them.
setSpaceGrantTx :: SpaceId -> Subject -> SpacePermission -> Bool -> Tx ()
setSpaceGrantTx sid subject permission granted = do
  (_, c) <- findSpace sid
  requireAdminister c
  when granted $ case subject of
    SubjectUser u -> db (loadUser u) >>= maybe (invalid "There is no such user.") (const pass)
    SubjectGroup g -> db loadGroups >>= maybe (invalid "There is no such group.") (const pass) . find (\x -> x.id == g)
  let grant = SpaceGrant {space = sid, subject, permission}
  db $
    if granted
      then insertGrants Grants {global = [], spaces = [grant], access = Open}
      else deleteSpaceGrant grant
  (sp, _) <- findSpace sid
  grantee <- case subject of
    SubjectUser u -> maybe ("user " <> u.text) (\x -> "user " <> x.login.text) <$> db (loadUser u)
    SubjectGroup g -> maybe ("group " <> g.text) (\x -> "group " <> x.name) . find (\x -> x.id == g) <$> db loadGroups
  record (if granted then "space.grant" else "space.revoke") (spaceSubject sp) [("to", grantee), ("permission", permissionText permission)]

-- | A permission on a space, as the log writes it.
permissionText :: SpacePermission -> Text
permissionText = \case
  View -> "view"
  Edit -> "edit"
  AdministerSpace -> "administer"

-- | Make a space public, or private again.
setSpacePublicTx :: SpaceId -> Bool -> Tx Space
setSpacePublicTx sid public = do
  s' <- adjustSpace sid (\s -> pure s {public})
  record "space.public" (spaceSubject s') [("public", yesNo public)]
  pure s'

renameSpaceTx :: SpaceId -> Text -> Tx Space
renameSpaceTx sid name = adjustSpace sid $ \s -> do
  n <- nonBlank "A space's name" name
  pure
    Space
      { id = s.id
      , name = n
      , slug = s.slug
      , parent = s.parent
      , public = s.public
      , mathMacros = s.mathMacros
      , createdAt = s.createdAt
      , position = s.position
      , subspaceOrder = s.subspaceOrder
      , pageOrder = s.pageOrder
      , homePage = s.homePage
      , icon = s.icon
      , description = s.description
      , blog = s.blog
      }

-- | Math macros as they are kept: as written, but for blank lines at the
-- ends.
trimLines :: Text -> Text
trimLines = T.intercalate "\n" . reverse . dropWhile blank . reverse . dropWhile blank . T.lines
  where
    blank = T.null . T.strip

moveSpaceTx :: SpaceId -> Maybe SpaceId -> Tx Space
moveSpaceTx sid destination = do
  ctx <- ask
  (s, c) <- findSpace sid
  destinationChain <- traverse (fmap snd . findSpace) destination
  requireView c
  traverse_ requireView destinationChain
  require (mayMoveSpace ctx.principal ctx.grants c destinationChain)
  when (maybe False (within sid) destinationChain) $
    invalid "A space cannot be moved into itself or one of its subspaces."
  let others = Map.elems (Map.delete sid ctx.spaces)
      (slug, position)
        | destination == s.parent = (s.slug, s.position)
        | otherwise = (freshSlug (isJust . findChild others destination) s.slug, nextPosition (childrenOf others destination))
      s' = respace destination slug position s
  db (updateSpace s')
  pure s'

-- | Delete a space: its subspaces, their pages, the pages' versions,
-- attachments and drafts, and the grants on all of them go with it, as the
-- schema's foreign keys cascade.
deleteSpaceTx :: SpaceId -> Tx ()
deleteSpaceTx sid = do
  (s, c) <- findSpace sid
  requireAdminister c
  ctx <- ask
  let below = [sp | sp <- Map.elems ctx.spaces, sp.id /= sid, within sid (chainOf ctx sp.id)]
  -- Count what is deleted with it, before deleting it.
  counts <- for (sid : map (\sp -> sp.id) below) $ \x -> db (countPagesIn x)
  db (deleteSpaceRow sid)
  record
    "space.delete"
    (spaceSubject s)
    ( [("path", spacePathText c), ("pages", show (sum counts))]
        <> [("subspaces", show (length below)) | not (null below)]
    )

-- | A space in another place in the tree, at a position there. Written out
-- in full, because a record update of fields that pages have too could not
-- tell which record it is.
respace :: Maybe SpaceId -> Slug -> Int -> Space -> Space
respace parent slug position s =
  Space
    { id = s.id
    , name = s.name
    , slug
    , parent
    , public = s.public
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    , homePage = s.homePage
    , icon = s.icon
    , description = s.description
    , blog = s.blog
    }

--------------------------------------------------------------------------------
-- Order

setSpaceOrderTx :: SpaceId -> Children -> ChildOrder -> Tx Space
setSpaceOrderTx sid kind order = do
  (s, c) <- findSpace sid
  requireAdminister c
  let old = case kind of
        ChildSpaces -> s.subspaceOrder
        ChildPages -> s.pageOrder
  -- Switched to by hand, the children are given the positions of the
  -- order they are shown in, so that the list stays as it was.
  when (order == ByHand && old /= ByHand) $ placeAsShown s kind
  let s' = case kind of
        ChildSpaces -> s {subspaceOrder = order}
        ChildPages -> s {pageOrder = order}
  db (updateSpace s')
  pure s'

-- | Give a space's children of one kind the positions of the order they
-- are shown in now: its subspaces, or each set of sibling pages in it.
placeAsShown :: Space -> Children -> Tx ()
placeAsShown s = \case
  ChildSpaces -> do
    ctx <- ask
    placeSpaces (childrenInOrder s.subspaceOrder (Map.elems ctx.spaces) (Just s.id))
  ChildPages -> do
    nodes <- db (pageNodes s.id)
    for_ (ordNub (map (\p -> p.parent) nodes)) $ \parent ->
      placePages (childrenInOrder s.pageOrder nodes parent)

-- | Number these spaces 0, 1, 2, … in the order given.
placeSpaces :: [Space] -> Tx ()
placeSpaces siblings = db $
  for_ (Map.toList (renumber (\x -> x.id) siblings)) $ \(sid, n) ->
    setSpacePosition sid n

-- | Number these pages 0, 1, 2, … in the order given.
placePages :: [PageNode] -> Tx ()
placePages siblings = db $
  for_ (Map.toList (renumber (\x -> x.id) siblings)) $ \(pid, n) ->
    setPagePosition pid n

shiftSpaceTx :: SpaceId -> Shift -> Tx Space
shiftSpaceTx sid how = do
  ctx <- ask
  (s, c) <- findSpace sid
  case s.parent of
    Nothing -> do
      requireView c
      invalid "The top-level spaces are listed by name, so they cannot be moved by hand."
    Just parentId -> do
      (parent, parentChain) <- findSpace parentId
      requireEdit parentChain
      unless (parent.subspaceOrder == ByHand) $
        invalid (parent.name <> " lists its subspaces " <> T.toLower (orderName parent.subspaceOrder) <> ", not by hand.")
      let moved = reposition (\x -> x.id) how sid (childrenInOrder ByHand (Map.elems ctx.spaces) (Just parentId))
      placeSpaces moved
      pure (maybe s (`positionSpace` s) (Map.lookup sid (renumber (\x -> x.id) moved)))

shiftPageTx :: PageId -> Shift -> Tx Page
shiftPageTx pid how = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireEdit c
  unless (s.pageOrder == ByHand) $
    invalid (s.name <> " lists its pages " <> T.toLower (orderName s.pageOrder) <> ", not by hand.")
  nodes <- db (childPages p.space p.parent)
  placePages (reposition (\x -> x.id) how pid (childrenInOrder ByHand nodes p.parent))
  findPage pid

--------------------------------------------------------------------------------
-- Pages

createPageTx :: SpaceId -> Maybe PageId -> Text -> Text -> Tx Page
createPageTx sid parent title body = do
  (_, c) <- findSpace sid
  parentPage <- traverse findNode parent
  requireEdit c
  when (any (\p -> p.space /= sid) parentPage) $
    invalid "A page's parent has to be in the same space."
  t <- nonBlank "A page's title" title
  -- Its siblings to be: what its slug and position are chosen among.
  nodes <- db (childPages sid parent)
  i <- newId
  time <- now
  let page =
        Page
          { id = PageId i
          , space = sid
          , parent
          , title = t
          , slug = freshSlug (isJust . findChild nodes parent) (fromMaybe (fallbackSlug "page") (slugify t))
          , body
          , attachments = []
          , createdAt = time
          , updatedAt = time
          , position = nextPosition (childrenOf nodes parent)
          , template = False
          }
  author <- asks (\x -> x.author)
  db (insertPage page >> insertVersion page author)
  -- Creating a page counts as a save: the people it mentions, and whoever
  -- watches its space, are notified.
  tellTx page.id sid page.title Nothing "" PageSaved (newlyMentioned "" body)
  pure page

-- | Save a page as a new version of it, if nobody has saved one since the
-- version given: the page's row and its prepared search text change, a
-- version is kept, and the saver's draft goes, all in this transaction.
savePageTx :: PageId -> UTCTime -> Text -> Text -> Tx Page
savePageTx pid base title body = do
  p <- findPage pid
  requireEdit =<< asks (`chainOf` p.space)
  t <- nonBlank "A page's title" title
  when (p.updatedAt /= base) $
    failWith (Conflict "The page has been saved by someone else since this edit began.")
  time <- now
  -- Later than the version saved over even if the clock says otherwise, so
  -- that no two versions of a page have the same time.
  let updatedAt = if time > p.updatedAt then time else addUTCTime 0.000001 p.updatedAt
      p' =
        Page
          { id = p.id
          , space = p.space
          , parent = p.parent
          , title = t
          , slug = p.slug
          , body
          , attachments = p.attachments
          , createdAt = p.createdAt
          , updatedAt
          , position = p.position
          , template = p.template
          }
  author <- asks (\x -> x.author)
  db $ do
    updatePageText pid t body updatedAt
    insertVersion p' author
    for_ author (deleteDraft pid)
  tellTx p'.id p'.space p'.title Nothing "" PageSaved (newlyMentioned p.body body)
  pure p'

movePageTx :: PageId -> SpaceId -> Maybe PageId -> Tx Page
movePageTx pid destination parent = do
  ctx <- ask
  p <- findNode pid
  (_, target) <- findSpace destination
  parentPage <- traverse findNode parent
  let source = chainOf ctx p.space
  requireView source
  requireView target
  require (mayMovePage ctx.principal ctx.grants source target)
  when (any (\q -> q.space /= destination) parentPage) $
    invalid "A page's parent has to be in the same space."
  subtree <- db (subtreeIds pid)
  when (any (`Set.member` subtree) parent) $
    invalid "A page cannot be moved under itself or a page under it."
  -- Its siblings at the destination: what a new slug and position are
  -- chosen among.
  others <- filter (\q -> q.id /= pid) <$> db (childPages destination parent)
  let (slug, position)
        | destination == p.space && parent == p.parent = (p.slug, p.position)
        | otherwise = (freshSlug (isJust . findChild others parent) p.slug, nextPosition (childrenOf others parent))
  db $ do
    placePage pid destination parent slug position
    setPageSpace destination (Set.toList (Set.delete pid subtree))
    -- A page that leaves its space is no longer its home page.
    when (destination /= p.space) $ clearHomePage (Set.toList subtree)
  findPage pid

-- | Make a page one of its space's templates, or not. Not a save: nothing
-- else of the page changes, and no version is kept.
setPageTemplateTx :: PageId -> Bool -> Tx Page
setPageTemplateTx pid template = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireEdit c
  when (template && s.homePage == Just pid) $
    invalid "A space's home page cannot be a template."
  db (setPageTemplateRow pid template)
  findPage pid

-- | Delete a page: the pages under it, and the versions, attachments and
-- drafts of all of them, go with it, as the schema's foreign keys cascade.
deletePageTx :: PageId -> Tx ()
deletePageTx pid = do
  p <- findNode pid
  c <- chainOfPage p
  requireEdit c
  under <- subtract 1 . Set.size <$> db (subtreeIds pid)
  above <- lineageOf pid
  let path = maybe "" (T.intercalate "/" . map slugText) (pathOf (`Map.lookup` above) pid)
  db (deletePageRow pid)
  record
    "page.delete"
    Audit.Subject {kind = "page", id = Just pid.text, name = p.title}
    ([("space", spacePathText c), ("path", path)] <> [("pages under it", show under) | under > 0])

--------------------------------------------------------------------------------
-- Attachments

-- | Attach a file, its bytes kept under their hash. The size is checked
-- before anything is hashed or written, so that a file too large costs
-- nothing but its reading.
-- | Attach a file to a page. The file is this many bytes, which the last
-- argument stores in the blob directory given to it, after the checks:
-- bytes in memory ('uploadAttachment') or a file on disk
-- ('uploadAttachmentFile').
uploadAttachmentTx :: PageId -> Text -> Text -> Integer -> (FilePath -> IO BlobId) -> Tx Attachment
uploadAttachmentTx pid name mediaType size store = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  n <- either invalid pure (parseFileName name)
  when (size > fromIntegral maxAttachmentSize) $
    invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB.")
  let mt = uploadedMimeType mediaType
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (store dir)
  i <- newId
  let attachment = Attachment {id = AttachmentId i, name = n, mediaType = mt, size = fromIntegral size, source = SourceBlob blob}
  -- One of the same name is replaced, in its place among the page's.
  db (replaceAttachment pid attachment)
  pure attachment

deleteAttachmentTx :: AttachmentId -> Tx ()
deleteAttachmentTx aid = do
  (pid, _) <- db (loadAttachment aid) >>= maybe (failWith NotFound) pure
  p <- findNode pid
  requireEdit =<< chainOfPage p
  db (deleteAttachmentRow aid)

--------------------------------------------------------------------------------
-- Drafts

-- | Check that someone signed in may edit a page, and return the id their
-- drafts are stored under.
draftable :: PageId -> Tx UserId
draftable pid = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  asks (\x -> x.author) >>= maybe (failWith Forbidden) pure

getDraftTx :: PageId -> Tx (Maybe Draft)
getDraftTx pid = draftable pid >>= \u -> db (loadDraft pid u)

saveDraftTx :: PageId -> UTCTime -> Text -> Text -> Tx Draft
saveDraftTx pid base title body = do
  u <- draftable pid
  savedAt <- now
  let draft = Draft {page = pid, author = u, title, body, base, savedAt}
  db (saveDraftRow draft)
  pure draft

discardDraftTx :: PageId -> Tx ()
discardDraftTx pid = do
  u <- draftable pid
  db (deleteDraft pid u)

--------------------------------------------------------------------------------
-- History

-- | A version as the class gives it, its author named: a user by their
-- display name, the administrator as 'administratorUser', and anyone else
-- (no longer a user, such as one whose account was removed) as
-- 'absentAuthor' names them.
versionOf :: PageId -> VersionRow -> Version
versionOf page r =
  Version {page, updatedAt = r.updatedAt, title = r.title, body = r.body, author = named <$> r.author}
  where
    named u
      | u == administratorId = Author {id = u, name = administratorUser.displayName}
      | otherwise = maybe (absentAuthor u) (\n -> Author {id = u, name = n}) r.authorName

-- | A page of a page's history, each version with its number: the first
-- of them is numbered with how many versions there are up to it, and the
-- next ones count down from there.
listVersionsTx :: PageId -> VersionsQuery -> Tx [VersionInfo]
listVersionsTx pid q = do
  p <- findNode pid
  requireView =<< chainOfPage p
  (before, rows) <- db (loadVersionsPage pid q.before (max 1 (min maxVersionsPageSize q.limit)))
  pure [versionInfo n (versionOf pid r) | (n, r) <- zip [before, before - 1 ..] rows]

-- | A version of a page someone may view (or, for a restore, edit): the
-- page's permission checked first, so that whoever may not see the page
-- learns nothing of its history.
findVersion :: PageId -> UTCTime -> Tx Version
findVersion pid at = db (loadVersion pid at) >>= maybe (failWith NotFound) (pure . versionOf pid)

getVersionTx :: PageId -> UTCTime -> Tx Version
getVersionTx pid at = do
  p <- findNode pid
  requireView =<< chainOfPage p
  findVersion pid at

-- | Restore a version: a save of its title and body, as any save, in this
-- transaction, against the version the restorer saw.
restoreVersionTx :: PageId -> UTCTime -> UTCTime -> Tx Page
restoreVersionTx pid at base = do
  p <- findNode pid
  requireEdit =<< chainOfPage p
  v <- findVersion pid at
  savePageTx pid base v.title v.body

--------------------------------------------------------------------------------
-- Administration

-- | Check that the caller holds the global administer. Administration
-- operations check this before looking up anything they are given.
requireAdministrator :: Tx ()
requireAdministrator = ask >>= \x -> require (hasGlobalPermission x.principal x.grants Administer)

-- | 'requireAccountCreator' refuses a caller who may not create accounts
-- with a password in the administration. That is anyone who does not
-- hold the global administer, and everyone when the wiki's setting
-- 'adminCreatesPasswordAccounts' is off. With the setting off, accounts
-- with a password are made only on the server's console, which creates
-- them through "Wiki.Server.Accounts" and is not checked here.
requireAccountCreator :: Tx ()
requireAccountCreator = do
  requireAdministrator
  asks (\x -> x.wiki.adminCreatesPasswordAccounts) >>= require

-- | A user by id; the administrator, who is no user, is not found.
findUser :: UserId -> Tx User
findUser u = db (loadUser u) >>= maybe (failWith NotFound) pure

-- | A group by id.
findGroup :: GroupId -> Tx Group
findGroup g = db loadGroups >>= maybe (failWith NotFound) pure . find (\x -> x.id == g)

directoryTx :: Tx Directory
directoryTx = do
  requireAdministrator
  users <- db loadUsers
  groups <- db loadGroups
  membership <- db loadMembership
  stored <- db loadGrants
  (disabled, withPassword) <- db loadAccountFlags
  identities <- db loadIdentityProviders
  secondFactor <- db loadSecondFactorUsers
  emails <- db loadEmails
  server <- asks (\x -> x.server)
  wiki <- asks (\x -> x.wiki)
  let ids = Set.fromList (map (\u -> u.id) users)
      holding p = Set.fromList [u | GlobalGrant (SubjectUser u) p' <- stored.global, p' == p, u `Set.member` ids]
  pure
    Directory
      { users = sortOn (\u -> u.login) users
      , administrators = holding Administer
      , creators = holding CreateSpaces
      , disabled
      , withPassword
      , identities = Map.restrictKeys identities ids
      , -- By the providers the server has now, as 'requirePasswordToSet'
        -- refuses them.
        providerOnly =
          Set.fromList
            [ u
            | u <- Set.toList ids
            , providerOnly (providerNames server) (u `Set.member` withPassword) (Map.findWithDefault [] u identities)
            ]
      , secondFactor = Set.intersection secondFactor ids
      , emails = Map.restrictKeys emails ids
      , -- As the server's mailer is made ("Wiki.Server.Mail"'s 'mailerFrom').
        mailing = isJust server.publicUrl && isJust server.mail
      , adminCreatesPasswordAccounts = wiki.adminCreatesPasswordAccounts
      , groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) groups
      , membership = Map.filter (not . Set.null) (Map.restrictKeys membership (Set.fromList (map (\g -> g.id) groups)))
      }

-- | One page of the users, read from the database a page at a time
-- ("Wiki.Server.Storage.Rows"' 'loadUserPage'), with the details of those
-- users alone. The answer is what 'Wiki.Api.Admin.pageOfDirectory' gives
-- for the directory of every user; the contract tests check that.
userPageTx :: UserQuery -> Tx UserPage
userPageTx q = do
  requireAdministrator
  checked <- either invalid pure (checkUserQuery q)
  global <- db loadGlobalGrants
  let holding p = [u | GlobalGrant (SubjectUser u) p' <- global, p' == p]
      administrators = Set.fromList (holding Administer)
      creators = Set.fromList (holding CreateSpaces)
  (total, listed) <- db (loadUserPage checked)
  details <- db (loadUsersDetails (map (\l -> l.user.id) listed))
  groups <- sortOn (\g -> (T.toCaseFold g.name, g.id)) <$> db loadGroups
  server <- asks (\x -> x.server)
  wiki <- asks (\x -> x.wiki)
  let byName = Map.fromList (zip (map (\g -> g.id) groups) [0 :: Int ..])
      summary l =
        let providers = Map.findWithDefault [] l.user.id details.identities
         in UserSummary
              { user = l.user
              , administrator = l.user.id `Set.member` administrators
              , createsSpaces = l.user.id `Set.member` creators
              , disabled = l.disabled
              , hasPassword = l.hasPassword
              , identities = providers
              , -- By the providers the server has now, as the directory says.
                providerOnly = providerOnly (providerNames server) l.hasPassword providers
              , secondFactor = l.user.id `Set.member` details.secondFactor
              , email = l.email
              , groups = sortOn (`Map.lookup` byName) (Map.findWithDefault [] l.user.id details.groups)
              }
  pure
    UserPage
      { users = map summary listed
      , total
      , offset = checked.offset
      , groups
      , -- As 'directoryTx' says it.
        mailing = isJust server.publicUrl && isJust server.mail
      , adminCreatesPasswordAccounts = wiki.adminCreatesPasswordAccounts
      }

-- | Grant a global permission to a user directly, or take it away: the
-- global administer (also from oneself, since the admin listener can
-- always give it back) or create-spaces.
setGlobalGrantTx :: GlobalPermission -> UserId -> Bool -> Tx ()
setGlobalGrantTx permission u granted = do
  requireAdministrator
  user <- findUser u
  let grant = GlobalGrant {subject = SubjectUser u, permission}
  db (setGlobalGrant granted grant)
  case permission of
    Administer -> record "user.administrator" (userSubject user) [("administrator", yesNo granted)]
    CreateSpaces -> record "user.create-spaces" (userSubject user) [("creates spaces", yesNo granted)]

-- | Change the account of a user who is there, as an administrator, and
-- give it back as it then is.
changeAccountTx :: Text -> [(Text, Text)] -> UserId -> (forall be. (Backend be) => Db be ()) -> Tx Account
changeAccountTx action detail u change = do
  requireAdministrator
  user <- findUser u
  db change
  record action (userSubject user) detail
  db (loadAccount u) >>= maybe (failWith NotFound) pure

-- | Refuse a password to a user who has none to set (WP5.6 of
-- docs/PLAN.md): one who signs in with a provider the server has, and has
-- no password.
requirePasswordToSet :: User -> Tx ()
requirePasswordToSet user = do
  configured <- asks (\x -> providerNames x.server)
  none <- db (noPasswordToSet configured user.id)
  when none (invalid (user.displayName <> " signs in with a provider, and has no password to set."))

-- | A link for choosing a password, which an administrator has mailed to
-- a user: to whom, at which address, and until when it works. The link's
-- secret is not in it: the caller made the secret and keeps it.
data PasswordLink = PasswordLink
  { user :: User
  , email :: Email
  , expiresAt :: UTCTime
  }

-- | Store a link for choosing a password, with this secret, for an
-- administrator to have mailed to a user (WP5.6 of docs/PLAN.md). It is
-- the same kind of link that "Forgot your password?" mails
-- ("Wiki.Server.Reset"): it works as long and as many times, and it is
-- recorded in the audit log. The checks come in this order: the caller
-- administers the wiki ('Forbidden'), the user exists ('NotFound'), then
-- 'Invalid' with the reason: the user has a password to set, the server
-- sends mail (the caller says whether), their login is enabled, and their
-- address is verified. The limits of "Forgot your password?" do not apply,
-- but a user who was given a link less than a minute ago gets none
-- ('Nothing'), so that a button clicked twice sends one mail.
passwordLinkFor :: (MonadIO m) => Bool -> UTCTime -> ResetToken -> UserId -> StoredWiki m (Either WikiError (Maybe PasswordLink))
passwordLinkFor mailing at token u = run Writes $ do
  requireAdministrator
  user <- findUser u
  requirePasswordToSet user
  unless mailing (invalid "The server sends no mail: set up its mail in the Server section, or type a password for them.")
  account <- db (loadAccount u) >>= maybe (failWith NotFound) pure
  when account.disabled (invalid (user.displayName <> "'s login is disabled: enable it first, or type a password for them."))
  verified <- db (verifiedEmail u)
  case verified of
    Just email -> do
      recent <- db (resetsSince u (addUTCTime (-60) at))
      if recent > 0
        then pure Nothing
        else do
          let expiresAt = addUTCTime resetLifetime at
          db (insertResetToken u (tokenHash token.text) at expiresAt)
          record "user.password-link" (userSubject user) []
          pure (Just PasswordLink {user, email, expiresAt})
    Nothing -> invalid (user.displayName <> " has no verified address: type a password for them.")

-- | A group's name, checked: not blank, and no other group's but for case.
groupNameTx :: Maybe GroupId -> Text -> Tx Text
groupNameTx self name = do
  n <- nonBlank "A group's name" name
  groups <- db loadGroups
  for_ (head [g | g <- groups, Just g.id /= self, T.toCaseFold g.name == T.toCaseFold n]) $ \g ->
    invalid ("There is a group called " <> g.name <> " already.")
  pure n

createGroupTx :: Text -> Tx Group
createGroupTx name = do
  requireAdministrator
  n <- groupNameTx Nothing name
  g <- (\i -> Group {id = GroupId i, name = n}) <$> newId
  db (insertGroup g)
  record "group.create" (groupSubject g.id n) []
  pure g

renameGroupTx :: GroupId -> Text -> Tx Group
renameGroupTx gid name = do
  requireAdministrator
  old <- findGroup gid
  n <- groupNameTx (Just gid) name
  db (renameGroupRow gid n)
  record "group.rename" (groupSubject gid n) [("was", old.name)]
  pure Group {id = gid, name = n}

deleteGroupTx :: GroupId -> Tx ()
deleteGroupTx gid = do
  requireAdministrator
  g <- findGroup gid
  db (deleteGroupRows gid)
  record "group.delete" (groupSubject gid g.name) []

-- | Put a user in a group, or take them out; doing either twice changes
-- nothing.
setMemberTx :: Bool -> GroupId -> UserId -> Tx ()
setMemberTx member gid u = do
  requireAdministrator
  g <- findGroup gid
  user <- findUser u
  db ((if member then insertMember else deleteMember) gid u)
  record (if member then "group.member-add" else "group.member-remove") (groupSubject gid g.name) [("user", user.login.text)]

--------------------------------------------------------------------------------
-- Whom the wiki lets in

setWikiSettingsTx :: WikiSettings -> Tx WikiSettings
setWikiSettingsTx new = do
  requireAdministrator
  db (storeSettings new)
  record
    "settings.wiki"
    (settingsSubject "whom the wiki lets in")
    [ ("access", accessName new.access)
    , ("new accounts create spaces", yesNo new.newAccountsCreateSpaces)
    , ("administration creates accounts with a password", yesNo new.adminCreatesPasswordAccounts)
    ]
  pure new

-- | The server's settings with a change written over them, checked
-- ('checkServerSettings') and kept.
setServerSettingsTx :: ServerSettingsChange -> Tx Kept
setServerSettingsTx change = do
  requireAdministrator
  old <- asks (\x -> x.server)
  new <- either invalid pure (checkServerSettings isJust (applyChange Secret old change))
  db (storeServerSettings new)
  record "settings.server" (settingsSubject "the server") (serverChanges old new)
  pure new

-- | The backups' settings with a change written over them, checked
-- ('checkBackupSettings') and kept.
setBackupSettingsTx :: BackupSettingsChange -> Tx KeptBackups
setBackupSettingsTx change = do
  requireAdministrator
  old <- db loadBackupSettings
  new <- either invalid pure (checkBackupSettings (applyBackupChange Secret old change))
  db (storeBackupSettings new)
  record "settings.backups" (settingsSubject "backups") (backupChanges old new)
  pure new

-- | What a change of the server's settings changed, in words: a secret as
-- changed or cleared, never what it is.
serverChanges :: Kept -> Kept -> [(Text, Text)]
serverChanges old new =
  [("public address", maybe "none" (\u -> u.text) new.publicUrl) | old.publicUrl /= new.publicUrl]
    <> mail
    <> concatMap provider (ordNub (map (\p -> p.name) (old.providers <> new.providers)))
  where
    mail = case (old.mail, new.mail) of
      (Just _, Nothing) -> [("mail", "removed")]
      (before, Just m) ->
        [("mail", m.host <> ":" <> show m.port <> " (" <> securityName m.security <> "), from " <> m.from) | fmap void before /= Just (void m)]
          <> [("mail password", secretChange (m.password)) | fmap (\b -> b.password) before /= Just m.password]
      (Nothing, Nothing) -> []
    provider name = case (find ((== name) . (\p -> p.name)) old.providers, find ((== name) . (\p -> p.name)) new.providers) of
      (Nothing, Just p) -> [("provider " <> name, "added (" <> kindName p.kind <> ")")]
      (Just _, Nothing) -> [("provider " <> name, "removed")]
      (Just a, Just b) ->
        [("provider " <> name, "changed") | void a /= void b]
          <> [("provider " <> name <> " secret", secretChange b.secret) | a.secret /= b.secret]
      (Nothing, Nothing) -> []

-- | A secret that is not what it was: changed, or cleared.
secretChange :: Maybe Secret -> Text
secretChange = maybe "cleared" (const "changed")

-- | What a change of the backups' settings changed, in words: the rclone
-- configuration as changed or cleared.
backupChanges :: KeptBackups -> KeptBackups -> [(Text, Text)]
backupChanges old new =
  [("on", yesNo new.enabled) | old.enabled /= new.enabled]
    <> [("schedule", scheduleText new.schedule) | old.schedule /= new.schedule]
    <> [("keep", show new.keep.daily <> " days, " <> show new.keep.weekly <> " weeks") | old.keep /= new.keep]
    <> [("copied to", maybe "nowhere" destinationText new.destination) | fmap void old.destination /= fmap void new.destination]
    <> [("rclone configuration", secretChange c) | ToRclone _ c <- maybeToList new.destination, configOf old.destination /= Just c]
  where
    configOf = \case
      Just (ToRclone _ c) -> Just c
      _ -> Nothing

invitationsTx :: Tx Invitations
invitationsTx = do
  requireAdministrator
  t <- now
  listed <- db (loadInvitations t)
  pure Invitations {mailing = False, invitations = listed}

-- | An invitation for an address, with this secret for its link, in place
-- of any the address had.
inviteTx :: Text -> InvitationToken -> Tx Invited
inviteTx raw token = do
  requireAdministrator
  email <- either invalid pure (parseEmail raw)
  i <- InvitationId <$> newId
  t <- now
  let invitation = Invitation {id = i, email, createdAt = t, expiresAt = addUTCTime invitationLifetime t, expired = False}
  db (insertInvitation invitation (tokenHash token.text))
  record "invitation.create" Audit.Subject {kind = "invitation", id = Just i.text, name = email.text} []
  pure Invited {invitation, token = Just token, mailError = Nothing}

revokeInvitationTx :: InvitationId -> Tx ()
revokeInvitationTx i = do
  requireAdministrator
  email <- db (deleteInvitation i) >>= maybe (failWith NotFound) pure
  record "invitation.revoke" Audit.Subject {kind = "invitation", id = Just i.text, name = email.text} []

-- | An administrator disconnects a user's account at a provider, even
-- their last way in (see 'MonadAdmin'), and ends the user's sessions, as
-- a new password does: one of them may have been started through that
-- provider.
unlinkUserIdentityTx :: UserId -> Text -> Tx ()
unlinkUserIdentityTx u provider = do
  requireAdministrator
  user <- findUser u
  gone <- db (deleteIdentity u provider)
  unless gone (failWith NotFound)
  db (deleteSessionsOf u)
  record "user.identity-remove" (userSubject user) [("provider", provider)]

-- | An administrator takes a user's second factor away, for one who has
-- lost it (WP4.11 of docs/PLAN.md).
removeSecondFactorTx :: UserId -> Tx ()
removeSecondFactorTx u = do
  requireAdministrator
  user <- findUser u
  had <- db (deleteSecondFactor u)
  unless had (failWith NotFound)
  record "user.second-factor-remove" (userSubject user) []

-- | An administrator removes a user's account (WP5.25 of docs/PLAN.md).
-- The login must be disabled first, so that removing an account is a
-- second, deliberate step after stopping it from signing in. Nobody
-- removes their own account here. 'deleteUserRows' deletes the account
-- and what belongs to it. The page versions and comments the user wrote
-- stay, kept under 'formerAuthor' with the login, so that they still name
-- the person; the login is then free for a new account.
removeUserTx :: UserId -> Tx ()
removeUserTx u = do
  requireAdministrator
  user <- findUser u
  self <- asks (\x -> (\p -> p.user) <$> x.principal)
  when (self == Just u) (failWith (Invalid "You cannot remove your own account."))
  account <- db (loadAccount u) >>= maybe (failWith NotFound) pure
  unless account.disabled (failWith (Conflict ("Disable " <> user.login.text <> "'s login before removing the account.")))
  db (deleteUserRows u (formerAuthor user.login.text))
  record "user.remove" (userSubject user) []

--------------------------------------------------------------------------------
-- Comments

-- | Who wrote a comment, as a reader sees them: the administrator, a user
-- by the display name the users table has for them, or, for an author who
-- is not a user here (one an import brought), as 'absentAuthor' names
-- them.
commentAuthor :: UserId -> Maybe Text -> Author
commentAuthor u name
  | u == administratorId = Author {id = u, name = administratorUser.displayName}
  | otherwise = maybe (absentAuthor u) (\n -> Author {id = u, name = n}) name

-- | Check that the current user may read a page, and return its space's
-- chain and its threads. Every comment operation starts with this, so its
-- checks come in the order the class's Haddock gives.
discussion :: PageId -> Tx ([Space], [Thread])
discussion pid = do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  ts <- db (Comments.loadThreads commentAuthor pid)
  pure (c, ts)

-- | A thread of the page's, which must be on it.
threadIn :: [Thread] -> CommentThreadId -> Tx Thread
threadIn ts tid = maybe (failWith NotFound) pure (find (\t -> t.id == tid) ts)

-- | A comment of the thread's, which must be in it.
commentIn :: Thread -> CommentId -> Tx Comment
commentIn t cid = maybe (failWith NotFound) pure (find (\x -> x.id == cid) t.comments)

-- | Whoever is asking, if they may comment on a page of the space at the
-- end of the chain: their id.
commenter :: [Space] -> Tx UserId
commenter c = do
  ctx <- ask
  require (mayComment ctx.principal ctx.grants c)
  maybe (failWith Forbidden) pure ctx.author

-- | A comment's Markdown, checked.
commentText :: Text -> Tx Text
commentText = either invalid pure . checkCommentBody

-- | A thread of the page, read again within the transaction: the result a
-- write returns.
threadNow :: PageId -> CommentThreadId -> Tx Thread
threadNow pid tid = db (Comments.loadThreads commentAuthor pid) >>= (`threadIn` tid)

listThreadsTx :: PageId -> Tx [Thread]
listThreadsTx pid = snd <$> discussion pid

openThreadTx :: PageId -> Maybe Anchor -> Text -> Tx (Thread, PageId, PageEvent)
openThreadTx pid anchor body = do
  (c, _) <- discussion pid
  u <- commenter c
  checked <- traverse (either invalid pure . checkAnchor) anchor
  text <- commentText body
  tid <- CommentThreadId <$> newId
  cid <- CommentId <$> newId
  time <- now
  db $ do
    Comments.insertThread tid pid checked time
    Comments.insertComment cid tid u text time
  t <- threadNow pid tid
  tellOfComment pid tid [u] text (mentionedIn text)
  pure (t, pid, ThreadOpened t)

replyTx :: PageId -> CommentThreadId -> Text -> Tx (Comment, PageId, PageEvent)
replyTx pid tid body = do
  (c, ts) <- discussion pid
  before <- threadIn ts tid
  u <- commenter c
  text <- commentText body
  cid <- CommentId <$> newId
  time <- now
  db (Comments.insertComment cid tid u text time)
  made <- threadNow pid tid >>= (`commentIn` cid)
  tellOfComment pid tid (ordNub (map (\x -> x.author.id) before.comments <> [u])) text (mentionedIn text)
  pure (made, pid, CommentAdded made)

editCommentTx :: PageId -> CommentThreadId -> CommentId -> Text -> Tx (Comment, PageId, PageEvent)
editCommentTx pid tid cid body = do
  (_, ts) <- discussion pid
  old <- threadIn ts tid >>= (`commentIn` cid)
  ctx <- ask
  require (mayEditComment ctx.principal old)
  text <- commentText body
  time <- now
  db (Comments.updateCommentBody cid text time)
  edited <- threadNow pid tid >>= (`commentIn` cid)
  p <- findNode pid
  tellTx pid p.space p.title (Just tid) (excerptOf text) (EditedIn tid) (newlyMentioned old.body text)
  pure (edited, pid, CommentEdited edited)

-- | Delete a comment. The first comment of a thread stands for the
-- thread: deleting it deletes the thread, if nobody has replied.
deleteCommentTx :: PageId -> CommentThreadId -> CommentId -> Tx ((), PageId, PageEvent)
deleteCommentTx pid tid cid = do
  (c, ts) <- discussion pid
  t <- threadIn ts tid
  old <- commentIn t cid
  ctx <- ask
  require (mayDeleteComment ctx.principal ctx.grants c old)
  case t.comments of
    opening : _ : _ | opening.id == cid -> invalid "The first comment of a thread with replies cannot be deleted: delete the thread instead."
    [_] -> db (Comments.deleteThreadRow tid) $> ((), pid, ThreadDeleted tid)
    _ -> db (Comments.deleteCommentRow cid) $> ((), pid, CommentDeleted tid cid)

deleteThreadTx :: PageId -> CommentThreadId -> Tx ((), PageId, PageEvent)
deleteThreadTx pid tid = do
  (c, ts) <- discussion pid
  t <- threadIn ts tid
  ctx <- ask
  require (mayDeleteThread ctx.principal ctx.grants c t)
  db (Comments.deleteThreadRow tid)
  pure ((), pid, ThreadDeleted tid)

setResolvedTx :: PageId -> CommentThreadId -> Bool -> Tx (Thread, PageId, PageEvent)
setResolvedTx pid tid resolved = do
  (c, ts) <- discussion pid
  t <- threadIn ts tid
  _ <- commenter c
  when (isNothing t.anchor) $
    invalid "A thread about the whole page is not resolved: only one about a quote of it is."
  db (Comments.updateResolved tid resolved)
  pure (t {resolved}, pid, ThreadResolved tid resolved)

--------------------------------------------------------------------------------
-- Notifications

-- | Notify the users that the rules of "Wiki.Core.Notification" name of
-- what the caller did to a page. Each gets a notification, which is
-- stored, queued for mail if the user gets mail, and sent once the
-- transaction commits. The server's operator is not a user, so they get
-- no notifications, but others are notified of what the operator does.
tellTx :: PageId -> SpaceId -> Text -> Maybe CommentThreadId -> Text -> Occasion -> Set Text -> Tx ()
tellTx pid sid title thread excerpt occasion logins = do
  ctx <- ask
  for_ ctx.author $ \actor -> do
    maker <- db (Notifications.pageMaker pid)
    let chain = chainOf ctx sid
        commenters = case occasion of
          CommentedIn _ people -> people
          _ -> []
    -- Only the users the rules could name are read, not every user.
    (telling, membership) <-
      db (Notifications.loadAudience Notifications.Audience {page = pid, spaces = map (\x -> x.id) chain, named = toList maker <> commenters, mentioned = Set.toList logins})
    nodes <- lineageOf pid
    let byLogin = Map.fromList [(t.user.login.text, t.user.id) | t <- telling]
        -- The grants the transaction began with. For the administrator they
        -- hold one more grant, to the administrator, who is never one of
        -- the users told.
        grants = Grants {global = ctx.grants.global, spaces = ctx.grants.spaces, access = ctx.wiki.access}
        watchers = [Watcher {principal = Permission.principal membership t.user.id, watchOwn = t.watchOwn, marks = t.marks} | t <- telling]
        mailed = Set.fromList [t.user.id | t <- telling, t.mailing]
        happened =
          Happened
            { actor
            , page = pid
            , maker
            , chain
            , occasion
            , mentioned = Set.fromList (mapMaybe (`Map.lookup` byLogin) (Set.toList logins))
            }
        location = PageLocation {space = map (\x -> x.slug) chain, page = fromMaybe [] (pathOf (`Map.lookup` nodes) pid)}
        actorAuthor = maybe Author {id = actor, name = actor.text} (\u -> Author {id = u.id, name = u.displayName}) ctx.user
    time <- now
    for_ (recipients grants watchers happened) $ \(u, kind) -> do
      i <- NotificationId <$> newId
      let n = Notification {id = i, kind, page = pid, thread, actor = actorAuthor, title, excerpt, createdAt = time, read = False, location = Just location}
      db (Notifications.insertNotification u n (Set.member u mailed))
      liftIO (modifyIORef' ctx.told ((u, n) :))

-- | A page's node and the nodes of the pages above it, by id: what
-- 'pathOf' needs to find the page's path. Each node is read by its id, so
-- the cost grows with the page's depth, not with the size of its space.
lineageOf :: PageId -> Tx (Map PageId PageNode)
lineageOf = go mempty
  where
    go found pid
      -- A page already found means a loop, which a page tree never has.
      | Map.member pid found = pure found
      | otherwise =
          db (pageNode pid) >>= \case
            Nothing -> pure found
            Just n -> do
              let more = Map.insert pid n found
              maybe (pure more) (go more) n.parent

-- | Notify of a comment in a thread whose comments so far are by these
-- users.
tellOfComment :: PageId -> CommentThreadId -> [UserId] -> Text -> Set Text -> Tx ()
tellOfComment pid tid people body logins = do
  p <- findNode pid
  tellTx pid p.space p.title (Just tid) (excerptOf body) (CommentedIn tid people) logins

-- | The user asking, who must be one of the wiki's: the server's operator,
-- who is not, has no notifications or watches.
notified :: Tx UserId
notified =
  asks (\x -> x.user) >>= \case
    Just u | u.id /= administratorId -> pure u.id
    _ -> failWith Forbidden

-- | A notification with where its page is now, if its user may still read
-- it.
locatedTx :: Notification -> Tx (Maybe Notification)
locatedTx n = do
  ctx <- ask
  db (pageNode n.page) >>= \case
    Nothing -> pure Nothing
    Just p -> do
      let chain = chainOf ctx p.space
      if canView ctx.principal ctx.grants chain
        then do
          nodes <- lineageOf p.id
          let path = pathOf (`Map.lookup` nodes) p.id
          pure (Just (withLocation (PageLocation (map (\x -> x.slug) chain) <$> path) n))
        else pure Nothing

-- | A user's notifications for the bell: the 'maxListed' newest of those
-- about pages the user may still read, each with where its page is now,
-- and how many unread notifications the user has about such pages. The
-- unread ones are counted in SQL by space, so the cost does not grow with
-- the number of notifications kept.
notificationsTx :: Tx Notifications
notificationsTx = do
  u <- notified
  ctx <- ask
  let readable sid = canView ctx.principal ctx.grants (chainOf ctx sid)
  counts <- db (Notifications.unreadBySpace u)
  items <- newestLocated u readable
  pure Notifications {unread = sum [n | (sid, n) <- counts, readable sid], items}

-- | The 'maxListed' newest of a user's notifications about pages in spaces
-- the user may read, each with where its page is now. The notifications
-- are read 'maxListed' at a time, the newest first, until enough are found
-- or none are left; usually one read is enough. Each space's pages are
-- read once, for the paths of every notification about a page in it.
newestLocated :: UserId -> (SpaceId -> Bool) -> Tx [Notification]
newestLocated u readable = go 0 mempty []
  where
    go offset spaces found = do
      ctx <- ask
      (rows, batch) <- db (Notifications.loadNewest u maxListed offset)
      nodes <- Map.fromList . catMaybes <$> for (ordNub (map (\n -> n.page) batch)) (\pid -> fmap (pid,) <$> db (pageNode pid))
      let wanted = ordNub [p.space | p <- Map.elems nodes, readable p.space, Map.notMember p.space spaces]
      more <- for wanted $ \sid -> (sid,) . Map.fromList . map (\x -> (x.id, x)) <$> db (pageNodes sid)
      let known = spaces <> Map.fromList more
          located =
            [ withLocation (PageLocation (map (\x -> x.slug) (chainOf ctx p.space)) <$> pathOf (`Map.lookup` Map.findWithDefault mempty p.space known) p.id) n
            | n <- batch
            , Just p <- [Map.lookup n.page nodes]
            , readable p.space
            ]
          now' = found <> located
      if length now' >= maxListed || rows < maxListed
        then pure (take maxListed now')
        else go (offset + maxListed) known now'

markReadTx :: ReadMark -> Tx Notifications
markReadTx m = do
  u <- notified
  time <- now
  db (Notifications.markNotificationsRead u time m)
  notificationsTx

-- | A page or a space to watch, which the asker may view: its chain, and
-- the page if it is one.
watchedTx :: WatchTarget -> Tx ([Space], Maybe PageId)
watchedTx = \case
  WatchPage pid -> do
    p <- findNode pid
    c <- chainOfPage p
    requireView c
    pure (c, Just pid)
  WatchSpace sid -> do
    (_, c) <- findSpace sid
    requireView c
    pure (c, Nothing)

watchingTx :: WatchTarget -> Tx Watch
watchingTx target = do
  (chain, page) <- watchedTx target
  u <- notified
  marks <- db (Notifications.loadMarksOn u page (map (\s -> s.id) chain))
  case page of
    Nothing -> pure (spaceWatch marks chain)
    Just pid -> do
      choices <- db (Notifications.loadChoices u)
      maker <- db (Notifications.pageMaker pid)
      pure (pageWatch (maybe True (\x -> x.watchOwn) choices) maker u marks chain pid)

setWatchingTx :: WatchTarget -> Bool -> Tx Watch
setWatchingTx target w = do
  _ <- watchedTx target
  u <- notified
  db (Notifications.storeMark u target w)
  watchingTx target

notificationSettingsTx :: Tx NotificationSettings
notificationSettingsTx = do
  u <- notified
  server <- asks (\x -> x.server)
  db (Notifications.loadChoices u) >>= \case
    Nothing -> failWith Forbidden
    Just cs ->
      pure
        NotificationSettings
          { mail = effectiveMailMode cs.verified cs.mail
          , watchOwn = cs.watchOwn
          , verifiedEmail = cs.verified
          , -- As the server's mailer is made ("Wiki.Server.Mail"'s 'mailerFrom').
            mailing = isJust server.publicUrl && isJust server.mail
          }

setNotificationSettingsTx :: NotificationSettingsChange -> Tx NotificationSettings
setNotificationSettingsTx change = do
  u <- notified
  db (Notifications.storeChoices u change.mail change.watchOwn)
  notificationSettingsTx

-- | The users with these logins who may sign in, for a caller who is
-- signed in. Only those logins are read, through the index on a user's
-- login, not every user.
mentionableTx :: [Text] -> Tx (Map Text Author)
mentionableTx logins =
  asks (\x -> x.user) >>= \case
    Just _ | not (null logins) -> do
      users <- db (loadActiveUsersByLogin logins)
      pure (Map.fromList [(u.login.text, Author {id = u.id, name = u.displayName}) | u <- users])
    _ -> pure mempty

-- | The users whose login or display name starts with some letters, and
-- whose login a mention can name, for someone signed in
-- ('loadUsersStartingWith'); nobody for anyone else, or for too few
-- letters ('searchable').
mentionCandidatesTx :: Text -> Tx [User]
mentionCandidatesTx letters =
  asks (\x -> x.user) >>= \case
    Just _ | searchable letters -> db (loadUsersStartingWith (\u -> mentionsWhole u.login.text) letters maxPeopleFound)
    _ -> pure []

-- | Mentions, watches and notifications, as the class's Haddock describes
-- them ("Wiki.App.Backend.Notifications"). Each operation is one
-- transaction.
instance (MonadIO m) => MonadNotifications (StoredWiki m) where
  mentionable = answer mempty . mentionableTx
  mentionCandidates = run Reads . mentionCandidatesTx
  notifications = run Reads notificationsTx
  markRead = run Writes . markReadTx
  watching = run Reads . watchingTx
  setWatching target = run Writes . setWatchingTx target
  notificationSettings = run Reads notificationSettingsTx
  setNotificationSettings = run Writes . setNotificationSettingsTx
  unsubscribe token =
    run Writes (db (Notifications.unsubscribeUser token) >>= \found -> unless found (failWith NotFound))

--------------------------------------------------------------------------------
-- Whole wikis

-- | Load a whole wiki from an export archive ("Wiki.Core.Export", already
-- checked by 'Wiki.Core.Export.readArchive') into an empty storage: its
-- people, groups, grants, spaces and pages with their ids, each page as
-- its first version, its pages' comments with their ids, and its
-- attachments' bytes stored under their hashes (so the blobs' ids are
-- hashes from then on). A comment's author is the archive's user with
-- the author's login, or the administrator for the administrator's login;
-- anyone else is kept by their name ('Wiki.Core.Comment.formerAuthor'). A storage that already
-- holds a wiki is refused and left unchanged: bringing one wiki into
-- another is a merge, which is the job of the import (WP2.8 of
-- docs/PLAN.md).
importArchive :: Storage -> Archive -> IO (Either Text ())
importArchive st a = writingEither st $ do
  vacant <- wikiIsEmpty
  let unkept = [x | p <- a.pages, x <- p.attachments, SourceBlob b <- [x.source], Map.notMember b a.blobs]
      iconless = [sp | sp <- a.spaces, Just (IconImage b _) <- [sp.icon], Map.notMember b a.blobs]
  case (vacant, unkept, iconless) of
    (False, _, _) -> pure (Left "The server has a wiki already: an archive is imported into an empty one only.")
    (_, x : _, _) -> pure (Left ("The archive has no bytes for the attachment " <> show x.id.text <> "."))
    (_, _, sp : _) -> pure (Left ("The archive has no bytes for the icon of the space " <> show sp.id.text <> "."))
    (True, [], []) -> do
      insertUsers a.users
      traverse_ insertGroup a.groups
      insertMembers [(g, u) | (g, members) <- Map.toList a.membership, u <- Set.toList members]
      hashes <- liftIO (traverse (storeBlob (attachmentsDir st.place.dataDir)) a.blobs)
      -- An archive gives spaces and pages in any order, a child before its
      -- parent too, and a space names its home page before the page is
      -- there. Each is added after its parent, and the spaces' home pages
      -- once the pages are there, so that every foreign key holds at each
      -- step, as PostgreSQL checks them.
      let spaces =
            [ case sp.icon of
                Just (IconImage b mt) -> withProfile SpaceProfile {description = sp.description, icon = Just (IconImage (Map.findWithDefault b b hashes) mt), homePage = sp.homePage, blog = sp.blog} sp
                _ -> sp
            | sp <- parentsFirst (\x -> x.id) (\x -> x.parent) a.spaces
            ]
      insertSpaces [withProfile SpaceProfile {description = sp.description, icon = sp.icon, homePage = Nothing, blog = sp.blog} sp | sp <- spaces]
      -- A grant on a space names the space, so the grants come after.
      insertGrants a.grants
      for_ (parentsFirst (\x -> x.id) (\x -> x.parent) a.pages) $ \p -> do
        insertPage p
        insertVersion p Nothing
        for_ (zip [0 ..] p.attachments) $ \(ordinal, x) ->
          let source = case x.source of
                SourceBlob b -> maybe x.source SourceBlob (Map.lookup b hashes)
                url -> url
           in insertAttachment p.id ordinal x {source}
      traverse_ updateSpace [sp | sp <- spaces, isJust sp.homePage]
      traverse_ (traverse_ Comments.restoreThread) (threadsAmong (administratorUser : a.users) a)
      restoreAudit a.audit
      pure (Right ())

-- | Records in an order where each comes after its parent: those with no
-- parent among them first, then those whose parent has come, and so on.
-- A record whose parent never comes (a loop) comes last.
parentsFirst :: (Ord k) => (a -> k) -> (a -> Maybe k) -> [a] -> [a]
parentsFirst key parentOf = go Set.empty
  where
    go _ [] = []
    go seen xs =
      let ids = Set.fromList (map key xs)
          ready x = maybe True (\p -> Set.member p seen || Set.notMember p ids) (parentOf x)
          (now', later) = List.partition ready xs
       in if null now' then later else now' <> go (seen <> Set.fromList (map key now')) later

-- | The whole wiki as an export archive, written now by this program
-- (@app@ names it), with every blob's bytes in memory. The tests compare
-- it with what an import brings back; "Export the wiki" writes a zip file
-- with 'writeExport' instead, which never holds the blobs in memory. An
-- attachment whose file is missing makes it fail, saying which, rather
-- than leave the attachment out of an archive meant to be the whole wiki.
exportArchive :: Storage -> Text -> IO (Either Text Archive)
exportArchive st app =
  exportRecords st app >>= \case
    Left e -> pure (Left e)
    Right (a, files) -> do
      bytes <- for (Map.toList files) (\(b, file) -> (b,) <$> BS.readFile file)
      pure (Right a {Export.blobs = Map.fromList bytes})

-- | Write the whole wiki as the zip file of its export archive at this
-- path, as 'exportArchive' would give it, and say when the archive was
-- made. The zip file is written one file at a time ("Wiki.Core.Export.Zip"),
-- and each attachment's and icon's bytes are copied from their blob's file
-- in chunks. So memory holds the wiki's records (users, spaces, pages with
-- their bodies, comments) but never the attachments, whatever their size.
-- It fails as 'exportArchive' does, and also for a wiki that a zip file
-- without ZIP64 cannot hold (4 GiB or more, or 65,535 files or more).
writeExport :: Storage -> Text -> FilePath -> IO (Either Text UTCTime)
writeExport st app target =
  exportRecords st app >>= \case
    Left e -> pure (Left e)
    Right (a, files) -> do
      let source = \case
            FileBytes bytes -> ZipBytes bytes
            FileBlob b -> maybe (ZipBytes "") ZipFile (Map.lookup b files)
      written <- try (writeZipFile target a.createdAt [(path, source file) | (path, file) <- archiveFiles a])
      pure $ case written of
        Left (ZipTooLarge why) -> Left ("The wiki is too large for a zip file without ZIP64: " <> why <> ".")
        Right () -> Right a.createdAt

-- | The whole wiki as an export archive without the bytes of its blobs
-- (its 'blobs' is empty), and the file of each blob it names. An
-- attachment or an icon whose file is missing makes it fail, saying which.
-- The comments' authors are the users, and the administrator, who has no
-- row among the users, is named among the archive's comment authors when
-- they wrote any.
exportRecords :: Storage -> Text -> IO (Either Text (Archive, Map BlobId FilePath))
exportRecords st app = do
  createdAt <- getCurrentTime
  (users, groups, membership, grants, spaces, pages, threads, audit) <-
    -- One read transaction, so that the records are of one state of the
    -- wiki.
    reading st $
      (,,,,,,,)
        <$> loadUsers
        <*> loadGroups
        <*> loadMembership
        <*> loadGrants
        <*> (Map.elems <$> loadSpaces)
        <*> loadAllPages
        <*> Comments.loadAllThreads commentAuthor
        <*> loadAuditLog
  let commentAuthors = [administratorUser | any (any (any (\x -> x.author.id == administratorId) . (\t -> t.comments))) threads]
      dir = attachmentsDir st.place.dataDir
      -- A blob's file, if it is there.
      fileOf b = case blobFile dir b of
        Nothing -> pure Nothing
        Just file -> (\there -> if there then Just file else Nothing) <$> doesFileExist file
  attachments <- for [(x, b) | p <- pages, x <- p.attachments, SourceBlob b <- [x.source]] $ \(x, b) ->
    maybe (Left ("The file of the attachment " <> show x.id.text <> " (" <> x.name.text <> ") is missing.")) (Right . (b,))
      <$> fileOf b
  icons <- for [(sp, b) | sp <- spaces, Just (IconImage b _) <- [sp.icon]] $ \(sp, b) ->
    maybe (Left ("The image of the icon of the space " <> show sp.id.text <> " (" <> sp.name <> ") is missing.")) (Right . (b,))
      <$> fileOf b
  pure $ (\files -> (Archive {createdAt, app, users, groups, membership, grants, spaces, pages, threads, commentAuthors, blobs = mempty, audit}, Map.fromList files)) <$> sequence (attachments <> icons)

-- | 'uploadAttachment' with the bytes in a file: an upload the server
-- received into a temporary file. The file is copied into the blob store
-- in chunks ('storeBlobFile'), never read into memory whole, and is left
-- where it is.
uploadAttachmentFile :: (MonadIO m) => PageId -> Text -> Text -> FilePath -> StoredWiki m (Either WikiError Attachment)
uploadAttachmentFile pid name mediaType file = do
  size <- liftIO (getFileSize file)
  run Writes (uploadAttachmentTx pid name mediaType size (\dir -> fst <$> storeBlobFile dir file))

-- | 'uploadSpaceIcon' with the image in a file, as 'uploadAttachmentFile'.
uploadSpaceIconFile :: (MonadIO m) => SpaceId -> Text -> FilePath -> StoredWiki m (Either WikiError Space)
uploadSpaceIconFile sid mediaType file = do
  size <- liftIO (getFileSize file)
  run Writes (uploadSpaceIconTx sid mediaType size (\dir -> fst <$> storeBlobFile dir file))
