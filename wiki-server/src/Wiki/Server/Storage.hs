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
  , writingTelling
  , writingThen
  , publishing
  , reading
  , readConnections
  , storageDataDir
  , storagePlace
  , storageMigrated
  , storageCapabilities
  , traceStatements
  , databaseBytes
  , DataDirInUse (..)

    -- * Migrating and checking the database by hand
  , Migrated (..)
  , migrateDatabase
  , withDatabase
  , CheckProblem (..)
  , Checked (..)
  , TableRead (..)
  , checkDatabase
  , checkConnection

    -- * The wiki's settings
  , readSettings
  , readServerSettings
  , cacheServerSettings

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
  , avatarFile
  , setAvatarFile
  , mayReadPage
  , locatedFor
  , editorOf
  , threadsThen
  , uploadAttachmentFile
  , uploadSpaceIconFile

    -- * Encrypted spaces
  , spaceEncryption
  , encryptSpace
  , createEncryptedSubspace
  , createSealedHome
  , grantSpaceKey
  , rotationInfo
  , rotateSpaceKey
  , sealedThreads
  , openSealedThread
  , sealedReply
  , sealedEditComment
  , uploadSealedAttachmentFile
  , sealedPages
  , sealedContents
  , sealedPageAt
  , createSealedPage
  , saveSealedPage
  , sealedVersions
  , sealedVersionAt

    -- * Encrypting a space that has pages, and turning encryption off
  , conversionInfo
  , startEncrypting
  , startDecrypting
  , stageSealed
  , stagePlain
  , stageBytesFile
  , stagedPage
  , commitConverted
  , reverseConversion
  , setSpaceEntry

    -- * Accounts
  , PasswordLink (..)
  , passwordLinkFor
  , createUserWithRecord
  , setPasswordRecord
  , recordHere
  , serverSetup
  , storageStretch

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
import Crypto.OPAQUE (ServerSetup)
import Crypto.Random (getRandomBytes)
import Data.Aeson (encode)
import Data.ByteArray.Encoding (Base (Base16, Base64URLUnpadded), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Containers.ListUtils (nubOrdOn)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Pool (Pool, defaultPoolConfig, destroyAllResources, newPool, setNumStripes, withResource)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Type.Equality (type (~))
import Data.UUID.Types qualified as UUID
import Protolude
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize, removePathForcibly)
import Wiki.Api.Account (Account (..), InvitationToken (..), NewAccount (..), providerOnly)
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), UserPage (..), UserQuery (..), UserSummary (..), WikiSettings (..), checkUserQuery, invitationLifetime, macroUsesIn)
import Wiki.Api.Backups (BackupRecord, BackupSettingsChange, BackupSettingsOf (..), Backups (..), DestinationOf (..), Retention (..), applyBackupChange, checkBackupSettings, destinationText, scheduleText)
-- Imported without their fields, which pages' and spaces' share; the
-- qualified import brings the fields.
import Wiki.Api.Encrypted (EncryptSpace (..), NewEncryptedSubspace (..), NewGrants, NewSealedComment (..), NewSealedPage, NewSealedThread (..), PendingMember (PendingMember), RotatedPage (..), Rotation (..), RotationInfo (RotationInfo), RotationPage (RotationPage), SealedAttachment (..), SealedCommentEdit (..), SealedCommentInfo (..), SealedEdit, SealedPage (SealedPage), SealedSummary (SealedSummary), SealedThread (..), SealedThreads (..), SealedVersion (SealedVersion), SealedVersionInfo (SealedVersionInfo), SpaceEncryption (SpaceEncryption), maxRotatedGrants, maxRotatedKeys)
import Wiki.Api.Encrypted qualified as E
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Info (Capabilities)
import Wiki.Api.Links (interactiveForm)
import Wiki.Api.Notifications (FeedAddress (..), NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark, feedAddressOf, maxPeopleFound, searchable)
import Wiki.Api.Opaque (NewAccountRecord (..), PasswordRecord (..), Stretch)
import Wiki.Api.Security (ResetToken (..), resetLifetime)
import Wiki.Api.ServerSettings (HomePage, MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsChange, ServerSettingsOf (..), applyChange, checkHomePage, checkServerSettings, defaultHomePage, kindName, secretState, securityName)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.Api.Stars (StarredPage (StarredPage), maxStars)
import Wiki.Api.Stars qualified as Star
import Wiki.Api.Upload (SealedUpload (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), UrlOwner (..), WikiError (..), anonymous, anonymousIn, maxAttachmentSize)
import Wiki.App.Backend qualified as B
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Backlinks (counted)
import Wiki.Core.Access (Access (..), accessName)
import Wiki.Core.Anchor (Anchor (..), checkAnchor)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..), parseFileName, uploadedMimeType)
import Wiki.Core.Audit (Actor (..))
import Wiki.Core.Audit qualified as Audit
import Wiki.Core.Backlink (Backlink (..), backlinkOrder)
import Wiki.Core.Blog (PostDetails (..), isPost)
import Wiki.Core.Blog qualified as Blog
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, checkCommentBody, formerAuthor, mayComment, mayDeleteComment, mayDeleteThread, mayEditComment)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Encrypted (Encapsulated (..), KeyGrant (KeyGrant), PageKey (..), SealedAnchor (..), SealedComment (..), SealedContent (..), SealedMeta (..), VersionTag (..), chainAfter, encapsulatedBytes, firstChain, headingOf, keyIdBytes, maxAnchorCiphertext, maxBodyCiphertext, maxCommentCiphertext, maxMetaCiphertext, maxTitleCiphertext, nonceBytes, sealedKeyBytes)
import Wiki.Core.Encrypted qualified as CE
import Wiki.Core.Export (Archive (..), ArchiveFile (..), archiveFiles, checkLogins, rootedArchive, threadsAmong, withoutHomeDocument)
import Wiki.Core.Export qualified as Export
import Wiki.Core.Export.Zip (ZipSource (..), ZipTooLarge (..), writeZipFile)
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Id
import Wiki.Core.Markdown.Ast (mentionsWhole)
import Wiki.Core.Markdown.Box (numberingName)
import Wiki.Core.Markdown.Frame (framesInteractively)
import Wiki.Core.Notification (Happened (..), Notification (..), Occasion (..), PageLocation (..), Watch, WatchTarget (..), Watcher (..), effectiveMailMode, excerptOf, maxListed, mentionedIn, newlyMentioned, pageWatch, recipients, spaceWatch, withLocation)
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, childrenInOrder, nextPosition, orderName, renumber, reposition)
import Wiki.Core.Page (Page (..), PageSummary (..), pageTreeOrder, savedAs)
import Wiki.Core.PageKind (PageKind (..), knownKinds, pageKindName)
import Wiki.Core.Path (NodeId, TreeNode, ancestry, childrenOf, findChild, resolvePath, resolveUnderM)
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
  , canEditPage
  , canView
  , hasGlobalPermission
  , isFor
  , mayCreateSpace
  , mayMovePage
  , mayMoveSpace
  , publicTo
  )
import Wiki.Core.Permission qualified as Permission
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), Searchable (..), foldText, folded, queryWords, searchPlain, searchRanked)
import Wiki.Core.Slug (Slug, freshSlug, mkSlug, slugText, slugify)
import Wiki.Core.Space (BoxNumbering (..), Conversion (..), Entry (..), Icon (..), Space (..), SpaceProfile (..), checkAvatarUpload, checkIconUpload, checkProfile, containerName, containerSlug, hasHome, homeDeleteRefusal, homeMoveRefusal, homeTitle, isHomeBody, isPersonal, ownProfile, parentOrRoot, personalName, positionSpace, rootPage, spaceTreeOrder, strayRoots, withHome, withMathMacros, withName, withOwnerAvatar, withProfile)
import Wiki.Core.Space qualified as Space
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Avatar (..), Email (..), Group (..), Login (..), Password, Standing (..), User (..), checkNewPassword, parseEmail, parseLogin)
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), Sealed (..), WrappedKey (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo, VersionsQuery (..), authorOf, maxVersionsPageSize, namedAuthor, versionInfo)
import Wiki.Server.HomePage (importHomeDocument)
import Wiki.Server.Opaque (defaultStretch, loadServerSetup, registerHere, setupFromText, setupKey, storedRecordOf)
import Wiki.Server.Password (newToken, tokenHash)
import Wiki.Server.Secret (Kept, Secret (..), hideSecrets)
import Wiki.Server.Sha256 (sha256)
import Wiki.Server.Storage.Audit (Recorded (..), insertAudit, loadActivity, loadAuditLog, restoreAudit)
import Wiki.Server.Storage.Backend (Backend (..), withTransaction, withTransactionEither)
import Wiki.Server.Storage.Backup (DataLock, KeptBackups, backupBlobs, backupFiles, backupInto, loadBackupSettings, loadLastBackup, lockDataDir, storeBackupSettings, storeLastBackup, unlockDataDir)
import Wiki.Server.Storage.Blobs (blobFile, collectBlobs, storeBlob, storeBlobFile)
import Wiki.Server.Storage.Check (TableRead (..), readEveryTable)
import Wiki.Server.Storage.Comments qualified as Comments
import Wiki.Server.Storage.Conversion
import Wiki.Server.Storage.Layout (Database (..), PgDatabase (..), PgPrograms, attachmentsDir, backupsDir, defaultDatabase, defaultPgPrograms, postgresAt, temporaryDir)
import Wiki.Server.Storage.Migrate (databaseVersion, knownVersion, migrateSaying, schemaVersion)
import Wiki.Server.Storage.Notifications qualified as Notifications
import Wiki.Server.Storage.Renewal (noticeRenewals, readersIn, renewalDue)
import Wiki.Server.Storage.Rows
import Wiki.Server.Storage.Schema (StagedPlain (..))
import Wiki.Server.Storage.Sealed (currentPublicKeys, deleteGrantsOfSpace, deleteSpaceGrants, grantsOfKey, insertGrant, insertPageKey, insertSealedAttachment, insertSealedComment, insertSealedThread, insertSealedVersion, loadPageKey, loadPageKeys, loadSealedAnchors, loadSealedComments, loadSealedLatest, loadSealedMetas, loadSealedVersion, loadSpaceAllPageKeys, replacePageKeys, replaceSealedComment, setSpaceKey, spaceKind)
import Wiki.Server.Storage.Sqlite (Access (..), openSqlite)
import Wiki.Server.Storage.Stars qualified as Stars
import Wiki.Server.WaysIn (AccountWays (..), WaysIn, brokenCredentials, brokenLogins, waysIn)
import Wiki.Server.WebAuthn (fromBase64Url)
#ifdef WIKI_POSTGRES
import Wiki.Server.Storage.Postgres (holdDatabaseShared, openPostgres)
#else
import System.IO.Error (userError)
import Wiki.Server.Storage.Layout (withoutPostgres)
#endif

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
  , newestGeneration :: IORef (Maybe Int64)
  -- ^ The newest generation of the permission context this process has
  -- seen, in a write or a read ('noticeGeneration'). A newer one calls the
  -- 'Config' @permissionsChanged@ callback.
  , lock :: Maybe DataLock
  -- ^ The data directory's lock. A storage opened with 'openStorage',
  -- which may delete files in the directory, holds it. A storage opened
  -- beside a running server ('withStorageAside') does not.
  , migrated :: [Text]
  -- ^ The lines the migration as the storage opened has to tell
  -- ('Wiki.Server.Storage.Migrate.migrateSaying'): a login step 15
  -- renamed. None when no step was pending, and for most steps. The
  -- server writes them to its log.
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
  , avatarAddress :: UserId -> Avatar -> Text
  -- ^ The URL a browser fetches a user's avatar from: the server's route
  -- for it, which serves 'avatarFile'.
  , publish :: PageId -> PageEvent -> IO ()
  -- ^ The callback that reports what happens to a page to the server's
  -- live channel ("Wiki.Server.Events"): every change to the page's
  -- comments, and every save of the page. It is called once the change is
  -- committed, before any other write may begin, so it must not wait.
  , passwordStretch :: Stretch
  -- ^ The Argon2id new OPAQUE records are stretched with, which the
  -- server tells the browser at each registration ("Wiki.Server.Opaque"):
  -- 'defaultStretch', or less in the tests.
  , notify :: [(UserId, Notification)] -> IO ()
  -- ^ The callback that receives the notifications a write made
  -- ("Wiki.Core.Notification") and passes them to the users' tabs over the
  -- live channel, and to the thread that mails them. It is called as
  -- 'publish' is, and must not wait either.
  , permissionsChanged :: IO ()
  -- ^ The callback that tells the live channel that who may read which
  -- page may have changed, so that it checks its subscribers again
  -- ("Wiki.Server.Events"). It is called once the change is committed and
  -- kept in memory: after a write that changed the permission context
  -- (its generation went up), moved or deleted a page, or changed the
  -- settings a permission check reads; and when a read finds a generation
  -- newer than any seen before (a change the console made in another
  -- process). It may be called for a change that narrowed nothing. It
  -- must not wait.
  }

-- | A configuration with attachments at @\/api\/v1\/attachments\/\<id\>@,
-- and callbacks that do nothing.
defaultConfig :: Config
defaultConfig =
  Config
    { attachmentAddress = \a -> "/api/v1/attachments/" <> a.id.text
    , iconAddress = \s -> "/api/v1/spaces/" <> s.id.text <> "/icon"
    , avatarAddress = \u a -> "/api/v1/users/" <> u.text <> "/avatar/" <> a.blob.text
    , passwordStretch = defaultStretch
    , publish = \_ _ -> pass
    , notify = \_ -> pass
    , permissionsChanged = pass
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
      PostgresAt pg -> holdPostgres pg
    flip onException release $ do
      engine <- case place.database of
        SqliteFile file -> Engine <$> pools (openSqlite ReadWrite file) (openSqlite ReadOnly file)
        PostgresAt pg -> openPostgresEngine pg
      flip onException (closeEngine engine) $ do
        (settings, serverKept, newestGeneration, migrated) <- case engine of
          Engine p -> withResource p.writer $ \c -> do
            (_, said) <- migrateSaying c
            -- The links are filled, and the pages' search text made
            -- again, if this version did not fill or make them, in the
            -- same transaction ("Wiki.Server.Storage.Rows", "Links").
            withTransaction True c (runDb c (ensureHomeDocument >> void ensureLinks >> resolvePendingLinks >> void ensureSearchText))
            when collect $ do
              collectGarbage c place.dataDir
              -- Uploads and exports left by a server that stopped: nothing
              -- is writing them now.
              removePathForcibly (temporaryDir place.dataDir)
            -- The settings are read here, on the writer, before any reader
            -- is used. A reader then always finds them in memory, and never
            -- writes the in-memory copy. So is the generation of the
            -- permission context, so that the first read does not take it
            -- for a change.
            (,,,said) <$> (newIORef . Just =<< runDb c loadSettings) <*> (newIORef . Just =<< runDb c loadServerSettings) <*> (newIORef =<< runDb c permissionsGeneration)
        tracer <- newIORef Nothing
        permissions <- newIORef Nothing
        pure Storage {engine, place, config, settings, serverKept, tracer, permissions, newestGeneration, lock, release, migrated}

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

-- | Take a PostgreSQL database's lock, shared, for as long as a storage
-- has it open. The result releases the lock. A database that a restore
-- holds alone is refused with 'DataDirInUse'.
holdPostgres :: PgDatabase -> IO (IO ())

-- | Open the pools of connections to a PostgreSQL database.
openPostgresEngine :: PgDatabase -> IO Engine

#ifdef WIKI_POSTGRES
holdPostgres pg = holdDatabaseShared pg >>= maybe (throwIO (DataDirInUse "The PostgreSQL database is being restored (wiki-server restore holds its lock): start the server once the restore has ended.")) pure

openPostgresEngine pg = Engine <$> pools (openPostgres pg) (openPostgres pg)
#else
-- A wiki-server built without PostgreSQL refuses the database. The
-- options refuse it first ("Wiki.Server.Options"); this refusal is for a
-- program that opens a storage on a place it made itself.
holdPostgres _ = throwIO (userError (toS withoutPostgres))

openPostgresEngine _ = throwIO (userError (toS withoutPostgres))
#endif

-- | The error for a data directory that another storage has open, or that
-- a restore is writing into.
newtype DataDirInUse = DataDirInUse Text
  deriving stock (Show)

instance Exception DataDirInUse where
  displayException (DataDirInUse why) = toS why

-- | The database of a place and nothing else of the storage: the data
-- directory's lock held (and on PostgreSQL the database's shared lock), one
-- connection to the database for the action, all released afterwards. It
-- neither migrates nor deletes an attachment's file, as 'openStorage'
-- does: @wiki-server migrate@ and @wiki-server check@ run on it, the deploy
-- with the service stopped.
withDatabase :: Place -> (forall be. (Backend be) => Connection be -> IO a) -> IO a
withDatabase place act = do
  createDirectoryIfMissing True place.dataDir
  lock <- lockDataDir place.dataDir >>= either (throwIO . DataDirInUse) pure
  flip finally (unlockDataDir lock) $ do
    release <- case place.database of
      SqliteFile _ -> pure pass
      PostgresAt pg -> holdPostgres pg
    flip finally release $ do
      engine <- case place.database of
        SqliteFile file -> Engine <$> pools (openSqlite ReadWrite file) (openSqlite ReadOnly file)
        PostgresAt pg -> openPostgresEngine pg
      flip finally (closeEngine engine) $ case engine of
        Engine p -> withResource p.writer act

-- | 'Migrated' is what @wiki-server migrate@ did: the version of the schema
-- the database was at, and the one it is at now (the same when no step was
-- pending).
data Migrated = Migrated
  { from :: Int
  , to :: Int
  , said :: [Text]
  -- ^ The lines the steps applied have to tell
  -- ('Wiki.Server.Storage.Migrate.CodeStep'): a login step 15 renamed.
  }
  deriving stock (Eq, Show)

-- | Apply the steps of the schema the database has not had, as the server
-- does when it starts ("Wiki.Server.Storage.Migrate"), and nothing else.
-- The deploy runs it with the new program before it starts the new server,
-- then 'checkDatabase', so that a migration that fails, or leaves a row the
-- program cannot read, is found while the backup taken before it can still
-- be restored. A database of an earlier wiki-server ('OldSchema') or of a
-- newer one ('Wiki.Server.Storage.Migrate.SchemaTooNew') is refused, as the
-- server refuses it. It also fills the table of links if this version of
-- how links are read did not ('ensureLinks'), and makes every page's
-- search text again if this version of how it is made did not
-- ('ensureSearchText'), as opening the storage would: the deploy's
-- migration then takes that time, before the new server must answer, and
-- the check reads the table filled.
migrateDatabase :: Place -> IO Migrated
migrateDatabase place = withDatabase place $ \c -> do
  before <- databaseVersion c
  (applied, said) <- migrateSaying c
  withTransaction True c (runDb c (void ensureLinks >> resolvePendingLinks >> void ensureSearchText))
  pure Migrated {from = before, to = fromMaybe before (lastMay applied), said}

-- | 'CheckProblem' is why @wiki-server check@ failed.
data CheckProblem
  = -- | The database is not at this program's version of the schema: at
    -- the first, this program knows the second. Migrate it first.
    NotMigrated Int Int
  | -- | Some tables did not read: every table as the check read it.
    UnreadableTables [TableRead]
  | -- | Every row read, but the wiki's records built from them did not:
    -- why.
    UnreadableRecords Text
  | -- | Every record read, but some break a rule the wiki keeps: a line
    -- for each. A space whose pages have a second root, a page with no
    -- parent beside the space's home page (WP5.78 of docs/PLAN.md), is one;
    -- an account whose stored password no sign-in can use (WP5.85,
    -- 'Wiki.Server.WaysIn.brokenCredentials') is another, and an account
    -- whose login breaks the rules of a login (WP5.87,
    -- 'Wiki.Server.WaysIn.brokenLogins') a third.
    BrokenRecords [Text]
  deriving stock (Eq, Show)

-- | 'Checked' is what a check that passed found: every table with the
-- rows it read, and how the accounts sign in ("Wiki.Server.WaysIn").
data Checked = Checked
  { tables :: [TableRead]
  , ways :: WaysIn
  }
  deriving stock (Eq, Show)

-- | Read the whole database as this program reads it, and change nothing:
-- every row of every table through the storage's row decoders
-- ('readEveryTable'), then the wiki's records an export builds from them
-- (users, groups, grants, spaces, pages and their versions, comments, the
-- audit log, the settings), and the accounts' passwords, identities and
-- passkeys. The result is every table with the rows it read, and how the
-- accounts sign in ('Checked'); a database not at this program's version of the schema is
-- not read at all. What the deploy runs after 'migrateDatabase': a row the
-- migration left that the new program cannot read is found then, not by
-- the first reader to open the page that holds it.
checkDatabase :: Place -> IO (Either CheckProblem Checked)
checkDatabase place = withDatabase place checkConnection

-- | 'checkConnection' is 'checkDatabase' on a connection the caller has
-- open, in the caller's transaction if it has begun one. The copy of a
-- database to another one ("Wiki.Server.Storage.Copy") checks its target
-- this way before it commits, and its source before it copies.
checkConnection :: (Backend be) => Connection be -> IO (Either CheckProblem Checked)
checkConnection c = do
  at <- databaseVersion c
  let known = knownVersion (schemaSuffix c)
  if at /= known
    then pure (Left (NotMigrated at known))
    else do
      tables <- readEveryTable c
      if any (isLeft . (\t -> t.rows)) tables
        then pure (Left (UnreadableTables tables))
        else
          try @SomeException (runDb c records) <&> \case
            Left e -> Left (UnreadableRecords (toS (displayException e)))
            Right ([], ways) -> Right Checked {tables, ways}
            Right (broken, _) -> Left (BrokenRecords broken)
  where
    -- Each record forced whole (through its Show), so that a value the
    -- conversion from a row cannot make fails here and not later. The
    -- shown text is consumed as it is made, never held: the records are in
    -- memory as an export holds them, and no more.
    --
    -- What is read is then checked against the rules the wiki keeps, and a
    -- line says what breaks each. The accounts' password columns, their
    -- identities and passkeys, and the providers the settings name give
    -- the accounts' rule and how they sign in.
    records :: (Backend be) => Db be ([Text], WaysIn)
    records = do
      forced =<< loadUsers
      forced =<< loadGroups
      forced =<< loadMembership
      forced =<< loadGrants
      spaces <- loadSpaces
      forced spaces
      pages <- loadAllPages
      forced pages
      forced =<< Comments.loadAllThreads commentAuthor
      forced =<< loadAuditLog
      forced =<< loadSettings
      kept <- loadServerSettings
      forced kept.homePage
      identities <- loadIdentityProviders
      passkeys <- loadPasskeyOwners
      columns <- loadPasswordColumns
      let accounts =
            [ AccountWays {id = u, login, disabled, password, providers = Map.findWithDefault [] u identities, passkey = Set.member u passkeys}
            | (u, login, disabled, password) <- columns
            ]
      links <- loadLinkEnds
      pure (rootProblems spaces pages <> kindProblems spaces pages <> linkProblems pages links <> brokenCredentials accounts <> brokenLogins accounts, waysIn (providerNames kept) accounts)
    -- Each space with a home page has that page as the only one with no
    -- parent.
    rootProblems spaces pages =
      [ "The space " <> s.name <> " (" <> s.id.text <> ") has pages with no parent beside its home page: " <> T.intercalate ", " [p.title <> " (" <> p.id.text <> ")" | p <- stray] <> "."
      | s <- Map.elems spaces
      , let stray = strayRoots s [p | p <- pages, p.space == s.id]
      , not (null stray)
      ]
    -- Each page is of a kind this program knows ("Wiki.Core.PageKind"),
    -- which a page of another kind (a newer program's, or a plugin's this
    -- one lacks) is not: it would be shown as a document. And each
    -- space's home page is a document.
    kindProblems spaces pages =
      [ "The page " <> p.title <> " (" <> p.id.text <> ") is of a kind this program does not know: " <> pageKindName p.kind <> "."
      | p <- pages
      , p.kind `notElem` knownKinds
      ]
        <> [ "The page " <> p.title <> " (" <> p.id.text <> ") is the home page of the space " <> s.name <> " and a " <> pageKindName p.kind <> ": a home page is a document."
           | p <- pages
           , p.kind /= Document
           , p.kind `elem` knownKinds
           , Just s <- [Map.lookup p.space spaces]
           , s.homePage == Just p.id
           ]
    -- Each link is on a page there is, and leads to a page there is or to
    -- none, and none is left pending ("Wiki.Server.Storage.Rows", "Links").
    linkProblems pages links =
      let there = Set.fromList (map (\p -> p.id) pages)
       in [ "The link " <> show ordinal <> " of the page " <> source.text <> " " <> problem <> "."
          | (source, ordinal, target, pending) <- links
          , problem <-
              ["is on no page there is" | Set.notMember source there]
                <> ["leads to the page " <> t.text <> ", which is not there" | Just t <- [target], Set.notMember t there]
                <> ["is still waiting to be followed" | pending]
          ]
    forced :: (Show a, MonadIO m) => a -> m ()
    forced a = liftIO (void (evaluate (length (show a :: [Char]))))

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
writingEither st action = writingEitherThen st action (const pass)

-- | 'writingEither' for a transaction that makes notifications outside a
-- 'Tx' (a password reset, the console): they are published once it is
-- committed (the storage's @notify@), as a 'Tx''s are.
writingTelling :: Storage -> (forall be. (Backend be) => Db be (Either e (a, [(UserId, Notification)]))) -> IO (Either e a)
writingTelling st action = fmap fst <$> writingEitherThen st action (\(_, told) -> unless (null told) (st.config.notify told))

-- | Commit a successful transaction, then update its cache before another write.
writingEitherThen :: Storage -> (forall be. (Backend be) => Db be (Either e a)) -> (a -> IO ()) -> IO (Either e a)
writingEitherThen st action committed = case st.engine of
  Engine p -> retrying p.writer $ \c -> do
    outcome <- withTransactionEither True c $ do
      tracer <- tracedBegin st True
      runTraced tracer c (withGeneration action)
    either (pure . Left) (\(a, generation) -> Right a <$ (committed a >> noticeGeneration st generation)) outcome

-- | 'writing', then, once the transaction is committed and before any
-- other write may begin, the given action on its result, as a save
-- publishes its change ('Config' @publish@). The guide's update reports
-- the pages it rewrote this way ("Wiki.Server.Guide").
writingThen :: Storage -> (forall be. (Backend be) => Db be a) -> (a -> IO ()) -> IO a
writingThen st action committed = case st.engine of
  Engine p -> retrying p.writer $ \c -> do
    outcome <- withTransactionEither True c $ do
      tracer <- tracedBegin st True
      runTraced tracer c (withGeneration (Right <$> action))
    either absurd (\(a, generation) -> a <$ (committed a >> noticeGeneration st generation)) outcome

-- | A write's statements, then its pending links followed
-- ('resolvePendingLinks'), then the generation of the permission context
-- they leave, read in the same transaction: the triggers have bumped it if
-- the write changed the permission context. Nothing is read for a write
-- that is rolled back.
withGeneration :: (Backend be) => Db be (Either e a) -> Db be (Either e (a, Maybe Int64))
withGeneration action = action >>= traverse (\a -> resolvePendingLinks >> (a,) <$> permissionsGeneration)

-- | Tell the live channel that who may read which page may have changed
-- ('Config' @permissionsChanged@) if this generation of the permission
-- context is newer than any this process has seen. Writes call it after
-- their commit, and reads when they read the generation, which is how a
-- change the console made in another process is noticed.
noticeGeneration :: Storage -> Maybe Int64 -> IO ()
noticeGeneration st = traverse_ $ \generation -> do
  newer <- atomicModifyIORef' st.newestGeneration $ \seen ->
    if Just generation > seen then (Just generation, True) else (seen, False)
  when newer st.config.permissionsChanged

-- | The callback that reports a change of a page to the server's live
-- channel ('Config' @publish@), for a write made with 'writingThen'.
publishing :: Storage -> PageId -> PageEvent -> IO ()
publishing st = st.config.publish

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

-- | What the migration as the storage opened has to tell, a line each: a
-- login step 15 of the schema renamed. None when no step was pending.
storageMigrated :: Storage -> [Text]
storageMigrated st = st.migrated

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

-- | Publish server settings after their transaction commits, before another write.
-- A permission check reads two of them: whether someone not signed in may
-- read the wiki's home page, and which space that page is in
-- ('requireView'). A change of either is told to the live channel
-- ('Config' @permissionsChanged@) once the new settings are in memory.
cacheServerSettings :: Storage -> Kept -> IO ()
cacheServerSettings st new = do
  old <- readIORef st.serverKept
  writeIORef st.serverKept (Just new)
  when (fmap readRule old /= Just (readRule new)) st.config.permissionsChanged
  where
    readRule k = (k.homePage.showAnonymous, k.homePage.document)

-- | Keep the wiki's settings in memory after their transaction commits,
-- before another write. Whom the wiki is open to is part of every
-- permission check, so a change of it is told to the live channel
-- ('Config' @permissionsChanged@) once the new settings are in memory.
keepSettings :: Storage -> WikiSettings -> IO ()
keepSettings st new = do
  old <- readIORef st.settings
  writeIORef st.settings (Just new)
  when (fmap (\s -> s.access) old /= Just new.access) st.config.permissionsChanged

-- | The server's own settings as they are now, with their secrets, from memory.
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
administratorUser = User {id = administratorId, login = Login "administrator", displayName = "Administrator", avatar = Nothing}

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
  -- ^ The spaces as they are stored: a personal space's icon is its own,
  -- not its owner's avatar, which 'shown' adds where a space is answered.
  , avatars :: Map UserId Avatar
  -- ^ The avatars of the owners of personal spaces who have one.
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
  , moved :: IORef Bool
  -- ^ Set by a write that moved or deleted a page ('pagesMoved'). Who may
  -- read a page depends on its space, and the pages' rows are not part of
  -- the permission context's generation, so the live channel is told of
  -- such a write by this flag once it commits.
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
      let conn = Conn tracer c
      ctx <- context st (mode == Writes) conn who address
      result <- runExceptT (runReaderT body ctx)
      -- A write that succeeded follows its pending links and reads the
      -- generation it leaves, as 'withGeneration' does.
      generation <- if mode == Writes && isRight result then viaConn conn (resolvePendingLinks >> permissionsGeneration) else pure Nothing
      pure ((ctx,generation,) <$> result)
    -- Committed: the action and the notifications come after the commit,
    -- still on the connection, so before any other write may begin. The
    -- live channel hears of a change to who may read what last, once the
    -- action has kept any new settings in memory, so that the checks it
    -- then makes read them.
    for_ outcome $ \(ctx, generation, a) -> do
      committed a
      made <- readIORef ctx.told
      unless (null made) (st.config.notify (reverse made))
      noticeGeneration st generation
      whenM (readIORef ctx.moved) st.config.permissionsChanged
    pure ((\(_, _, a) -> a) <$> outcome)

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
      (spaces, avatars) <- viaConn c loadSpacesWithAvatars
      rows <- viaConn c loadGrants
      contextWith st c who address (spaces, avatars) rows (activeUser c)
  | otherwise = do
      kept <- keptPermissions st c
      contextWith st c who address (kept.spaces, kept.avatars) kept.grants (keptUser st c kept)

-- | 'context', with the spaces and the grants it holds given (every one,
-- or only those some rules need: 'readWithin'), and the function that
-- finds a user who may act, with their groups.
contextWith :: Storage -> Conn -> Who -> Text -> (Map SpaceId Space, Map UserId Avatar) -> Grants -> (UserId -> IO (Maybe (User, Set GroupId))) -> IO Ctx
contextWith st c who address (spaces, avatars) rows activeAs = do
  -- The settings come from memory. The database is read only when memory
  -- has none, which does not happen once 'openWith' has filled it.
  wiki <- readIORef st.settings >>= maybe (viaConn c loadSettings) pure
  server <- readIORef st.serverKept >>= maybe (viaConn c loadServerSettings) pure
  told <- newIORef []
  moved <- newIORef False
  let stored = Grants {global = rows.global, spaces = rows.spaces, access = wiki.access}
  let ctx grants principal user author creator = Ctx {conn = c, blobs = attachmentsDir st.place.dataDir, spaces, avatars, grants, principal, user, author, creator, wiki, server, address, told, moved}
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
  , avatars :: Map UserId Avatar
  -- ^ The avatars of the owners of personal spaces, which those with no
  -- icon of their own are shown with.
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
    Just generation -> do
      noticeGeneration st (Just generation)
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
      (spaces, avatars) <- viaConn c loadSpacesWithAvatars
      grants <- viaConn c loadGrants
      pure Permissions {generation, spaces, avatars, grants, users = mempty}

-- | A user who may act, with their groups, in a read transaction of the
-- generation of the permission context given: from memory if a read of
-- that generation found them, else from the database, and then kept.
keptUser :: Storage -> Conn -> Permissions -> UserId -> IO (Maybe (User, Set GroupId))
keptUser st c kept u = case Map.lookup u kept.users of
  Just found -> pure found
  Nothing -> do
    found <- activeUser c u
    let remember held
          | isJust kept.generation && held.generation == kept.generation && Map.size held.users < maxKeptUsers = Permissions {generation = held.generation, spaces = held.spaces, avatars = held.avatars, grants = held.grants, users = Map.insert u found held.users}
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
        ctx <- contextWith st conn who "" (kept.spaces, kept.avatars) kept.grants (keptUser st conn kept)
        let Tx tx = body sid found
        runExceptT (runReaderT tx ctx)

-- | Run statements on the transaction's connection.
db :: (forall be. (Backend be) => Db be a) -> Tx a
db action = asks (\x -> x.conn) >>= \c -> liftIO (viaConn c action)

-- | Mark the transaction as one that moved or deleted pages ('Ctx'
-- @moved@), so that once it commits the live channel checks again who may
-- read the pages it shows.
pagesMoved :: Tx ()
pagesMoved = asks (\x -> x.moved) >>= \flag -> liftIO (writeIORef flag True)

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

-- | A space as the application is shown it: a personal space with no icon
-- of its own shows its owner's avatar ('withOwnerAvatar'). Applied to the
-- spaces the class answers with, and nowhere else, so that what is
-- written back and exported is the icon the space has stored.
shown :: Space -> Tx Space
shown s = asks (\x -> withOwnerAvatar ((s.owner >>= (`Map.lookup` x.avatars)) <|> (x.user >>= \u -> guard (s.owner == Just u.id) >> u.avatar)) s)

-- | A page as the class answers with it: with who wrote it
-- ('Page.createdBy', 'Page.updatedBy'), its first and latest versions'
-- authors, named as a history names them.
withWriters :: Page -> Tx Page
withWriters p = do
  (first', latest) <- db (pageWriters p.id p.updatedAt)
  pure p {createdBy = first' >>= \r -> (versionOf p.id r).author, updatedBy = latest >>= \r -> (versionOf p.id r).author}

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
requireView c =
  ask >>= \x ->
    unless
      (canView x.principal x.grants c || (x.server.homePage.showAnonymous && any (\s -> Home.isHomeSpace x.server.homePage s.id) c))
      (failWith NotFound)

-- | What writing in a space asks: to edit it. While a conversion of the
-- space runs, nothing but the conversion is written in it
-- ('requireNoConversion').
requireEdit :: [Space] -> Tx ()
requireEdit c = do
  requireView c
  x <- ask
  require
    ( if any (\s -> Home.isHomeSpace x.server.homePage s.id) c
        then hasGlobalPermission x.principal x.grants Administer
        else canEdit x.principal x.grants c
    )
  requireNoConversion c

-- | 'requireEdit' for a write that changes this page: saving it (which
-- renames it too), restoring a version, its drafts, its attachments, and
-- saying on the live channel that one edits it. The space's home page is
-- its administrators' to change ('canEditPage'). The wiki's front page
-- keeps its own rule, a wiki administrator, which 'requireEdit' checks.
requireEditPage :: [Space] -> PageId -> Tx ()
requireEditPage c pid = do
  requireEdit c
  x <- ask
  unless (any (\s -> Home.isHomeSpace x.server.homePage s.id) c) $
    require (canEditPage x.principal x.grants c pid)

-- | What creating a page in a space asks of the caller, by the plain route
-- and by the encrypted one alike: to edit the space, which is not the
-- wiki's front page.
requireCreatePage :: SpaceId -> [Space] -> Tx ()
requireCreatePage sid c = requireEdit c >> requireOrdinary sid

-- | What saving a page asks of the caller, by the plain route and by the
-- encrypted one alike ('requireEditPage'): a space's home page is its
-- administrators' to change (decision 68). A restore is a save, and
-- asks the same; so does a rename, which a save of the title is.
requireSavePage :: [Space] -> PageId -> Tx ()
requireSavePage = requireEditPage

-- | What attaching a file to a page, replacing one or deleting one asks of
-- the caller, by the plain routes and by the encrypted upload alike
-- ('requireEditPage'): the attachments of a space's home page are its
-- administrators' to change, as the page is.
requireAttachTo :: [Space] -> PageId -> Tx ()
requireAttachTo = requireEditPage

-- | What creating a space under another asks of the caller, by the plain
-- route and by the encrypted subspace's alike: to view the parent, which
-- is not the wiki's front page's space, and to be let make spaces there.
-- The parent's chain, if there is a parent.
requireCreateSpace :: Maybe SpaceId -> Tx (Maybe [Space])
requireCreateSpace parent = do
  ctx <- ask
  parentChain <- traverse (fmap snd . findSpace) parent
  traverse_ requireView parentChain
  traverse_ requireOrdinary parent
  traverse_ requireNoConversion parentChain
  require (mayCreateSpace ctx.principal ctx.grants parentChain)
  pure parentChain

-- | Root documents cannot be restructured through the ordinary space APIs.
requireOrdinary :: SpaceId -> Tx ()
requireOrdinary sid =
  asks (\x -> Home.isHomeSpace x.server.homePage sid) >>= \home ->
    when home (invalid "The wiki home is a singleton; its space and page cannot be restructured.")

-- | Refuse a write that leaves a page with no parent in a space beside its
-- home page ('strayRootsOf'): nothing but the home page, the root of the
-- space's pages, has none (WP5.78 of docs/PLAN.md). Creating and moving a
-- page put one asked for at the top level under the home page
-- ('parentOrRoot'), so this holds unless something else is wrong.
requireOneRoot :: SpaceId -> Tx ()
requireOneRoot sid = do
  (s, _) <- findSpace sid
  stray <- db (strayRootsOf s)
  unless (null stray) $
    invalid ("Nothing but " <> s.name <> "'s home page may be at the top of its pages.")

requireAdminister :: [Space] -> Tx ()
requireAdminister c = requireView c >> ask >>= \x -> require (canAdministerSpace x.principal x.grants c) >> traverse_ (requireOrdinary . (\s -> s.id)) c

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
  getHomeDocument = run Reads $ do
    home <- asks (\x -> x.server.homePage)
    d <- maybe (failWith NotFound) pure home.document
    (space, c) <- findSpace d.space
    requireView c
    page <- findPage d.page
    (,) <$> shown space <*> withWriters page
  listSpaces = answer [] (listSpacesTx >>= traverse shown)
  getSpace = run Reads . (shown <=< getSpaceTx)
  createSpace parent = run Writes . (shown <=< createSpaceTx parent)
  renameSpace sid = run Writes . (shown <=< renameSpaceTx sid)
  setSpacePublic sid = run Writes . (shown <=< setSpacePublicTx sid)
  setSpaceSealed sid = run Writes . (shown <=< setSpaceSealedTx sid)
  personalSpace = run Reads (personalSpaceTx >>= traverse shown)
  setPersonalSpace = run Writes . (shown <=< setPersonalSpaceTx)
  setAvatar mediaType bytes = run Writes (setAvatarTx mediaType (fromIntegral (BS.length bytes)) (`storeBlob` bytes))
  removeAvatar = run Writes removeAvatarTx
  avatarUrl u a = StoredWiki (asks (\env -> env.storage.config.avatarAddress u a))

  -- Whoever may edit the whole space may set its macros (WP5.41 of
  -- docs/PLAN.md), from the editor as from the space's page.
  setSpaceMathMacros sid macros = run Writes $ do
    (s, c) <- findSpace sid
    requireEdit c
    let s' = withMathMacros (trimLines macros) s
    db (updateSpace s')
    shown s'

  setSpaceProfile sid = run Writes . (shown <=< setSpaceProfileTx sid)
  uploadSpaceIcon sid mediaType bytes = run Writes (uploadSpaceIconTx sid mediaType (fromIntegral (BS.length bytes)) (`storeBlob` bytes) >>= shown)
  spaceIconUrl s = case s.icon of
    Just (IconImage _ _) -> StoredWiki (asks (\env -> env.storage.config.iconAddress s))
    _ -> pure ""
  pageCounts = answer mempty pageCountsTx
  spaceAccess = run Reads . spaceAccessTx
  setSpaceGrant sid subject permission = run Writes . setSpaceGrantTx sid subject permission
  moveSpace sid = run Writes . (shown <=< moveSpaceTx sid)
  deleteSpace = run Writes . deleteSpaceTx
  setSpaceOrder sid kind = run Writes . (shown <=< setSpaceOrderTx sid kind)
  shiftSpace sid = run Writes . (shown <=< shiftSpaceTx sid)
  shiftPage pid = run Writes . (withWriters <=< shiftPageTx pid)
  listPages = run Reads . listPagesTx
  postDetails = run Reads . postDetailsTx
  getPage sid = run Reads . (withWriters <=< getPageTx sid)
  pageLocation = run Reads . pageLocationTx
  pageBacklinks = run Reads . backlinksTx
  createPage sid parent title = run Writes . (withWriters <=< createPageTx Document sid parent title)
  createPageOf kind sid parent title = run Writes . (withWriters <=< createPageTx kind sid parent title)
  savePage pid base title = saving . (withWriters <=< savePageTx pid base title)
  movePage pid sid = run Writes . (withWriters <=< movePageTx pid sid)
  setPageTemplate pid = run Writes . (withWriters <=< setPageTemplateTx pid)
  setPageKind pid = run Writes . (withWriters <=< setPageKindTx pid)
  deletePage = run Writes . deletePageTx
  uploadAttachment pid name mediaType bytes = run Writes (uploadAttachmentTx pid name mediaType (fromIntegral (BS.length bytes)) (`storeBlob` bytes))
  deleteAttachment = run Writes . deleteAttachmentTx
  attachmentUrl _ a = case a.source of
    SourceUrl url -> pure url.text
    SourceBlob _ -> do
      address <- StoredWiki (asks (\env -> env.storage.config.attachmentAddress))
      answer "" (maybe "" (const (address a)) <$> db (loadAttachment a.id))

  -- The interactive form of an SVG the server stores: its address with
  -- ?interactive, as the HTTP backend writes it, so that the page the
  -- server prerenders and the page the program renders have the same frame.
  attachmentFrameUrl a = case a.source of
    SourceBlob _ | framesInteractively a.mediaType.text -> (\url -> if T.null url then Nothing else Just (interactiveForm url)) <$> attachmentUrl (UrlOwner 0) a
    _ -> pure Nothing

  -- The server sends a download itself, by the attachment's disposition.
  attachmentDownloadUrl _ _ = pure Nothing

  -- The server's addresses are its own: no view owns them.
  newUrlOwner = pure (UrlOwner 0)
  releaseUrls _ = pass
  searchPages = answer [] . searchPagesTx
  getDraft = run Reads . getDraftTx
  saveDraft pid base title = run Writes . saveDraftTx pid base title
  discardDraft = run Writes . discardDraftTx
  listVersions pid = run Reads . listVersionsTx pid
  getVersion pid = run Reads . getVersionTx pid
  restoreVersion pid at = saving . (withWriters <=< restoreVersionTx pid at)

  -- A document is made by the server's API, which runs pandoc and the TeX
  -- engine ("Wiki.Server.Export") and reads the page through this backend.
  fetchExport _ _ = pure (Left (Invalid "Only the server's API makes documents."))

-- | The administration operations, as the class's Haddock describes them
-- ("Wiki.App.Backend.Admin"). Each operation is one transaction that
-- first checks that the caller holds the global administer: the
-- administrator always does, and a user does through a grant.
instance (MonadIO m) => MonadAdmin (StoredWiki m) where
  directory = run Reads directoryTx
  userPage = run Reads . userPageTx
  setAdministrator u = run Writes . setGlobalGrantTx Administer u
  setCreateSpaces u = run Writes . setGlobalGrantTx CreateSpaces u

  -- A password given here is registered through OPAQUE with both sides
  -- in this process ("Wiki.Server.Opaque"), before the transaction that
  -- keeps its record, since the stretching takes a while the database
  -- should not wait for; and only for an administrator whom the wiki's
  -- settings let create accounts, so that nobody else can make the server
  -- spend that time. The transaction checks both again. The server's API
  -- receives a record the browser made instead ('createUserWithRecord',
  -- 'setPasswordRecord').
  createUser new =
    run Reads requireAccountCreator >>= \case
      Left e -> pure (Left e)
      Right () -> case (,) <$> parseLogin new.login <*> checkNewPassword new.password of
        Left why -> pure (Left (Invalid why))
        Right (login, password) -> do
          uid <- liftIO (UserId . UUID.toText <$> generateV4)
          st <- StoredWiki (asks (\x -> x.storage))
          liftIO (recordHere st uid password) >>= \case
            Left why -> pure (Left (Invalid why))
            Right stored -> insertUserTx uid login new.displayName stored
  setPassword u password =
    run Reads (requireAdministrator >> findUser u >>= requirePasswordToSet) >>= \case
      Left e -> pure (Left e)
      Right _ -> case checkNewPassword password of
        Left why -> pure (Left (Invalid why))
        Right p -> do
          st <- StoredWiki (asks (\x -> x.storage))
          liftIO (recordHere st u p) >>= \case
            Left why -> pure (Left (Invalid why))
            Right stored -> setRecordTx u stored

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
    liftIO (transactThenFrom env.storage env.who env.address Writes (setWikiSettingsTx new) (keepSettings env.storage))

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
  setHomePage change = StoredWiki $ do
    env <- ask
    fmap (\s -> s.homePage) <$> liftIO (transactThenFrom env.storage env.who env.address Writes (setHomePageTx change) (cacheServerSettings env.storage))
  serverSettings = run Reads (requireAdministrator >> asks (\x -> hideSecrets x.server))
  macroUses names = run Reads (requireAdministrator >> macroUsesIn names <$> db loadAllPages)
  setServerSettings change = StoredWiki $ do
    env <- ask
    fmap hideSecrets <$> liftIO (transactThenFrom env.storage env.who env.address Writes (setServerSettingsTx change) (cacheServerSettings env.storage))

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
  texEngine = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API tries the TeX engine."))
  checkTexEngine = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API tries the TeX engine."))
  installGuide = run Reads (requireAdministrator >> failWith (Invalid "Only the server's API and its console install the guide (Wiki.Server.Guide)."))

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
          c <- chainOfPage p
          requireEditPage c pid
          asks (\x -> x.user) >>= maybe (failWith Forbidden) (pure . authorOf)
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
--
-- With the threads comes who is reading, as the live channel names them
-- ('authorOf'): the signed-in user asking, or 'Nothing' for anyone else.
threadsThen :: Storage -> Who -> PageId -> (([Thread], Maybe Author) -> IO ()) -> IO (Either WikiError ([Thread], Maybe Author))
threadsThen st who pid = transactThen st who ReadsOnWriter $ do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  home <- asks (\x -> Home.isHomePage x.server.homePage pid)
  -- A page of an encrypted space has its threads encrypted: the browser
  -- reads them from their own route, and is told only that they changed
  -- ('ThreadsChanged'). Its subscription answers with none.
  sealed <- maybe (pure False) (`pageReadsSealed` pid) (lastMay c)
  threads <- if home || sealed then pure [] else listThreadsTx pid
  readingAs <- asks (\x -> x.user) <&> \u -> authorOf <$> mfilter (\v -> v.id /= administratorId) u
  pure (threads, readingAs)

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
  liftIO
    $ fmap (fmap fst)
    $ transactThen
      env.storage
      env.who
      Writes
      ( do
          p <- tx
          server <- asks (\x -> x.server)
          let updated =
                if Home.isHomePage server.homePage p.id
                  then Just server {SS.homePage = server.homePage {Home.title = p.title, Home.body = p.body}}
                  else Nothing
          pure (p, updated)
      )
      (\(p, server) -> traverse_ (cacheServerSettings env.storage) server >> env.storage.config.publish p.id (PageChanged p.updatedAt))

-- | The encrypted space's key as the caller sees it: its id, their grant,
-- and who waits for one ("Wiki.Api.Encrypted"'s 'SpaceEncryption').
spaceEncryption :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError SpaceEncryption)
spaceEncryption = run Reads . spaceEncryptionTx

-- | Turn a private space with nothing written in it encrypted.
encryptSpace :: (MonadIO m) => SpaceId -> EncryptSpace -> StoredWiki m (Either WikiError Space)
encryptSpace sid = run Writes . (shown <=< encryptSpaceTx sid)

-- | A subspace of an encrypted space, made encrypted.
createEncryptedSubspace :: (MonadIO m) => SpaceId -> NewEncryptedSubspace -> StoredWiki m (Either WikiError Space)
createEncryptedSubspace parent = run Writes . (shown <=< createEncryptedSubspaceTx parent)

-- | The home page of an encrypted space that has none.
createSealedHome :: (MonadIO m) => SpaceId -> NewSealedPage -> StoredWiki m (Either WikiError SealedPage)
createSealedHome sid = run Writes . createSealedHomeTx sid

-- | Grant an encrypted space's key to readers waiting for it.
grantSpaceKey :: (MonadIO m) => SpaceId -> NewGrants -> StoredWiki m (Either WikiError ())
grantSpaceKey sid = run Writes . grantSpaceKeyTx sid

-- | What a rotation of an encrypted space's key needs, for one of its
-- administrators.
rotationInfo :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError RotationInfo)
rotationInfo = run Reads . rotationInfoTx

-- | Give an encrypted space a new key ('Wiki.Api.Encrypted.Rotation').
rotateSpaceKey :: (MonadIO m) => SpaceId -> Rotation -> StoredWiki m (Either WikiError ())
rotateSpaceKey sid = run Writes . rotateSpaceKeyTx sid

-- | The threads of a page of an encrypted space, encrypted.
sealedThreads :: (MonadIO m) => PageId -> StoredWiki m (Either WikiError SealedThreads)
sealedThreads pid = run Reads $ do
  threads <- sealedThreadsTx pid
  pageKeys <- db (loadPageKeys pid)
  pure SealedThreads {pageKeys, threads}

-- | A new thread of a page of an encrypted space, published once committed.
openSealedThread :: (MonadIO m) => PageId -> NewSealedThread -> StoredWiki m (Either WikiError SealedThread)
openSealedThread pid = commenting . openSealedThreadTx pid

-- | A reply in a thread of a page of an encrypted space.
sealedReply :: (MonadIO m) => PageId -> CommentThreadId -> NewSealedComment -> StoredWiki m (Either WikiError SealedCommentInfo)
sealedReply pid tid = commenting . sealedReplyTx pid tid

-- | A comment of a page of an encrypted space written again.
sealedEditComment :: (MonadIO m) => PageId -> CommentThreadId -> CommentId -> SealedCommentEdit -> StoredWiki m (Either WikiError SealedCommentInfo)
sealedEditComment pid tid cid = commenting . sealedEditCommentTx pid tid cid

-- | An attachment of a page of an encrypted space, its encrypted bytes in a
-- file, as 'uploadAttachmentFile'.
uploadSealedAttachmentFile :: (MonadIO m) => PageId -> SealedUpload -> FilePath -> StoredWiki m (Either WikiError SealedAttachment)
uploadSealedAttachmentFile pid up file = do
  size <- liftIO (getFileSize file)
  run Writes (uploadSealedAttachmentTx pid up size (\dir -> fst <$> storeBlobFile dir file))

-- | A space's conversion ('E.ConversionInfo').
conversionInfo :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError E.ConversionInfo)
conversionInfo = run Reads . conversionInfoTx

-- | Start encrypting a space that has pages.
startEncrypting :: (MonadIO m) => SpaceId -> E.StartEncrypting -> StoredWiki m (Either WikiError E.ConversionInfo)
startEncrypting sid = run Writes . startEncryptingTx sid

-- | Start turning a space's encryption off.
startDecrypting :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError E.ConversionInfo)
startDecrypting = run Writes . startDecryptingTx

-- | Stage ciphertexts of a page while its space is encrypted.
stageSealed :: (MonadIO m) => PageId -> E.StagedSealed -> StoredWiki m (Either WikiError ())
stageSealed pid = run Writes . stageSealedTx pid

-- | Stage a page's texts, decrypted, while its encryption is turned off.
stagePlain :: (MonadIO m) => PageId -> E.StagedPlain -> StoredWiki m (Either WikiError ())
stagePlain pid = run Writes . stagePlainTx pid

-- | Stage an attachment's bytes, from a file of an upload.
stageBytesFile :: (MonadIO m) => PageId -> AttachmentId -> FilePath -> StoredWiki m (Either WikiError ())
stageBytesFile pid aid file = do
  size <- liftIO (getFileSize file)
  run Writes (stageBytesTx pid aid size (\dir -> fst <$> storeBlobFile dir file))

-- | What is staged of a page.
stagedPage :: (MonadIO m) => PageId -> StoredWiki m (Either WikiError E.StagedPage)
stagedPage = run Reads . stagedPageTx

-- | Commit a page of a conversion. Then, on SQLite, the write-ahead log is
-- moved into the database file and emptied, so that the plain text the
-- commit took out of the database is in neither file ('checkpoint'); and
-- once the conversion has ended, the files of the blob store nothing
-- refers to any more are deleted ('collectGarbage'): the plain bytes of
-- the attachments encrypted, unless a backup kept names them.
commitConverted :: (MonadIO m) => PageId -> E.ConversionCommit -> StoredWiki m (Either WikiError E.ConversionProgress)
commitConverted pid commit = do
  result <- run Writes (commitConvertedTx pid commit)
  st <- StoredWiki (asks (\env -> env.storage))
  for_ result $ \(_, ended) -> liftIO $ case st.engine of
    Engine p -> withResource p.writer $ \c -> do
      void (checkpoint c)
      when (ended && isJust st.lock) (collectGarbage c st.place.dataDir)
  pure (fst <$> result)

-- | Turn a conversion round.
reverseConversion :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError E.ConversionInfo)
reverseConversion = run Writes . reverseConversionTx

-- | Set whether readers of an encrypted space confirm each time they open
-- it ('Wiki.Core.Space.Entry'), as its administrators do.
setSpaceEntry :: (MonadIO m) => SpaceId -> Space.Entry -> StoredWiki m (Either WikiError Space)
setSpaceEntry sid e = run Writes (setSpaceEntryTx sid e >>= shown)

-- | The pages of an encrypted space, with their encrypted titles.
sealedPages :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError [SealedSummary])
sealedPages = run Reads . sealedPagesTx

-- | The pages of an encrypted space, with their latest versions encrypted.
sealedContents :: (MonadIO m) => SpaceId -> StoredWiki m (Either WikiError [SealedPage])
sealedContents = run Reads . sealedContentsTx

-- | A page of an encrypted space by its path.
sealedPageAt :: (MonadIO m) => SpaceId -> [Slug] -> StoredWiki m (Either WikiError SealedPage)
sealedPageAt sid = run Reads . sealedPageAtTx sid

-- | A new page of an encrypted space.
createSealedPage :: (MonadIO m) => SpaceId -> NewSealedPage -> StoredWiki m (Either WikiError SealedPage)
createSealedPage sid = run Writes . createSealedPageTx sid

-- | A new version of a page of an encrypted space, published once it is
-- committed so that a tab showing the page fetches it again, as a plain
-- save is ('saving').
saveSealedPage :: (MonadIO m) => PageId -> UTCTime -> SealedEdit -> StoredWiki m (Either WikiError SealedPage)
saveSealedPage pid base edit = StoredWiki $ do
  env <- ask
  liftIO (transactThen env.storage env.who Writes (saveSealedPageTx pid base edit) (\p -> env.storage.config.publish p.id (PageChanged p.updatedAt)))

-- | A page of a page's history, encrypted.
sealedVersions :: (MonadIO m) => PageId -> VersionsQuery -> StoredWiki m (Either WikiError [SealedVersionInfo])
sealedVersions pid = run Reads . sealedVersionsTx pid

-- | One version of a page of an encrypted space.
sealedVersionAt :: (MonadIO m) => PageId -> UTCTime -> StoredWiki m (Either WikiError SealedVersion)
sealedVersionAt pid = run Reads . sealedVersionTx pid

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
  let viewable = [sid | sid <- Map.keys ctx.spaces, not (Home.isHomeSpace ctx.server.homePage sid), canView ctx.principal ctx.grants (chainOf ctx sid)]
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
  requirePlain "A feed" c
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
  c <- chainOfPage =<< findNode pid
  requireView c
  requirePlain "An export" c
  findPage pid

-- | The file that holds a blob's bytes, if the blob id names one. An export
-- reads images from it. This checks no permission: the caller must already
-- have checked that the reader may see the page that has the blob.
blobPath :: Storage -> BlobId -> Maybe FilePath
blobPath st = blobFile (attachmentsDir st.place.dataDir)

-- | A space's icon image, if the 'Who' may view the space: its media type
-- and its file. The image is looked up by its blob id, which is part of
-- its URL, so a replaced image gets a new URL. The server's route for
-- space icons serves this. A blob that is not the space's image (its own,
-- or its owner's avatar it is shown with) is 'NotFound'.
spaceIconFile :: (MonadIO m) => SpaceId -> BlobId -> StoredWiki m (Either WikiError (MimeType, FilePath))
spaceIconFile sid blob = run Reads $ do
  (stored, c) <- findSpace sid
  requireView c
  dir <- asks (\x -> x.blobs)
  -- A personal space with no icon of its own shows its owner's avatar,
  -- at the space's icon's address like any other image.
  s <- shown stored
  case s.icon of
    Just (IconImage b mediaType) | b == blob, Just file <- blobFile dir b -> pure (mediaType, file)
    _ -> failWith NotFound

--------------------------------------------------------------------------------
-- Reads

sessionTx :: Tx Session
sessionTx = do
  ctx <- ask
  pure $ case (,) <$> ctx.user <*> ctx.principal of
    -- Someone not signed in sets formulas with the built-in macros too: a
    -- public page's formulas use them.
    Nothing ->
      (anonymousIn ctx.grants.access)
        { B.homePage = if ctx.grants.access == Closed && not ctx.server.homePage.showAnonymous then defaultHomePage else ctx.server.homePage
        , B.mathMacros = ctx.server.mathMacros
        , B.assistantServices = ctx.server.assistantServices
        }
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
        , -- Nor the kinds of box, which are the server's settings: the
          -- API adds them as well.
          boxes = []
        , homePage = ctx.server.homePage
        , -- The built-in macros are the server's settings too, but no
          -- secret: every session has them, whoever asks.
          mathMacros = ctx.server.mathMacros
        , -- The assistant's services, as every session has them.
          assistantServices = ctx.server.assistantServices
        , -- Nor whether the page "What's new?" is on, which is the
          -- server's option: the API adds it.
          whatsNew = Nothing
        }

listSpacesTx :: Tx [Space]
listSpacesTx = do
  ctx <- ask
  let visible = filter (canView ctx.principal ctx.grants) (map (chainOf ctx) [sid | sid <- Map.keys ctx.spaces, not (Home.isHomeSpace ctx.server.homePage sid)])
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
        , not (Home.isHomeSpace ctx.server.homePage sid)
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
  -- While a space is converted, the pages that read plain are listed
  -- plain; the others are listed by the encrypted route.
  if isJust s.conversion
    then do
      listed <- db (loadPageSummaries sid)
      sealed <- Set.fromList <$> sealedAmong s (map (\p -> p.id) listed) identity
      pure (pageTreeOrder s.pageOrder [p | p <- listed, Set.notMember p.id sealed])
    else do
      requirePlain "Listing its pages as plain text" c
      pageTreeOrder s.pageOrder <$> db (loadPageSummaries sid)

-- | The pages of a space with their bodies and attachments, in the space's
-- page order, for someone who may view the space. The API's list of pages
-- carries summaries only ('listPagesTx'); the server's own work on a whole
-- space (a space's export) needs the bodies.
spacePagesTx :: SpaceId -> Tx [Page]
spacePagesTx sid = do
  (s, c) <- findSpace sid
  requireView c
  requirePlain "An export" c
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
  requirePlain "A blog's list of posts" c
  pages <- db (loadPageSummaries sid)
  firsts <- Map.fromList <$> db (loadFirstVersions sid)
  counts <- Map.fromList <$> db (loadCommentCounts sid)
  bodies <- Map.fromList <$> db (loadPostBodies sid (rootPage s))
  let details p =
        PostDetails
          { author = (Map.lookup p.id firsts >>= \r -> (versionOf p.id r).author)
          , comments = Map.findWithDefault 0 p.id counts
          , -- Only a post is listed with its excerpt: parsing every page
            -- of a large space for nothing would slow the answer down.
            excerpt = if isPost s p then maybe "" Blog.excerptOf (Map.lookup p.id bodies) else ""
          }
  pure (Map.fromList [(p.id, details p) | p <- pages])

-- | A page by its path in a space, from under the space's home page, the
-- root of its pages ('Wiki.Core.Space.pagesAt'): the empty path is the
-- home page, and an old address that starts with the home page's slug is
-- read again without it. The path is followed one slug at a time, each
-- step one query through the index of siblings' slugs ('childPage'), so
-- the reads grow with the path's length, not with the size of the space.
getPageTx :: SpaceId -> [Slug] -> Tx Page
getPageTx sid path = do
  (s, c) <- findSpace sid
  requireView c
  unless (isJust s.conversion) (requirePlain "Reading a page as plain text" c)
  root <- maybe (pure Nothing) (\r -> db (pageNode r)) (rootPage s)
  resolveUnderM root (\parent slug -> db (childPage sid parent slug)) path >>= \case
    Right ps | Just p <- lastMay ps -> requirePlainPage "Reading a page as plain text" c p.id >> findPage p.id
    _ -> failWith NotFound

-- | Where a page is now, by its id ('Wiki.App.Backend.pageLocation'): its
-- space's path and its own. The permission to view the page's space is
-- checked before anything else about the page is read, so a page the
-- caller may not view is 'NotFound' as an id no page has. An encrypted
-- space's page is answered too: its path is made of random slugs, and the
-- browser reads the page itself.
pageLocationTx :: PageId -> Tx PageLocation
pageLocationTx pid = do
  p <- findNode pid
  (_, c) <- findSpace p.space
  when (null c) (failWith NotFound)
  requireView c
  home <- asks (\x -> Home.isHomeSpace x.server.homePage p.space)
  if home
    then pure PageLocation {space = [], page = []}
    else do
      nodes <- lineageOf p.id
      spaces <- asks (\x -> x.spaces)
      maybe (failWith NotFound) (\path -> pure PageLocation {space = map (\x -> x.slug) c, page = path}) (pathIn spaces p.space (`Map.lookup` nodes) p.id)

-- | The pages that link to a page ('Wiki.App.Backend.pageBacklinks'), as
-- @page_links@ holds them ("Wiki.Server.Storage.Rows", "Links"). The
-- page is checked as 'pageLocationTx' checks it, before anything else is
-- read. Of the pages that link to it, only those in a space the caller may
-- view are read further, and listed.
--
-- The table follows each link among every space. A reader's click follows
-- it among the spaces whose paths the reader can see ('listSpacesTx'),
-- and that differs for one kind of link only: a path from the top whose
-- longer part names a space hidden from the reader, which the reader
-- reads as a page of the space above it. So the paths from the top named
-- as this page ('Wiki.App.Route.linkName') that lead nowhere, or into a
-- space the caller may not view, are followed again among the caller's
-- spaces, and those that lead here are listed too. Otherwise the list
-- would leave out a link the reader's click follows here, and tell them
-- that a space they may not see is there.
backlinksTx :: PageId -> Tx [Backlink]
backlinksTx pid = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  when (null c) (failWith NotFound)
  requireView c
  ctx <- ask
  if not (counted ctx.server.homePage s)
    then pure []
    else do
      stored <- db (linkingPages pid)
      let viewable sid = let chain = chainOf ctx sid in not (null chain) && canView ctx.principal ctx.grants chain && all (counted ctx.server.homePage) (lastMay chain)
      named <- db (fromTopNamed (slugText p.slug))
      ends <- Map.fromList . map (\n -> (n.id, n.space)) <$> db (pageNodesWithIds [t | (_, _, Just t) <- named])
      visible <- listSpacesTx
      let elsewhere =
            [ (source, destination)
            | (source, destination, target) <- named
            , source /= pid
            , maybe True (\t -> maybe True (not . viewable) (Map.lookup t ends)) target
            ]
      followed <- db (followAmong visible elsewhere)
      let here = [source | (source, Just t) <- followed, t == pid]
      nodes <- db (pageNodesWithIds (ordNub ([source | (source, sid) <- stored, viewable sid] <> here)))
      above <- withAncestors nodes
      pure . backlinkOrder $
        [ Backlink {page = n.id, title = n.title, location = PageLocation {space = map (\x -> x.slug) (chainOf ctx n.space), page = path}}
        | n <- nodes
        , viewable n.space
        , Just path <- [pathIn ctx.spaces n.space (`Map.lookup` above) n.id]
        ]

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
          -- An encrypted space is not searched: its pages' titles and
          -- texts are empty here, and the browser searches them itself.
          (\c -> wanted c && not (any (\s -> Home.isHomeSpace ctx.server.homePage s.id || isJust s.encryption) c) && canView ctx.principal ctx.grants c)
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
            , Just pagePath <- [pathIn ctx.spaces n.space (`Map.lookup` nodes) n.id]
            ]
      -- A database that ranks its matches (PostgreSQL) has found the
      -- best; one that does not (SQLite) has found every page with every
      -- word somewhere in its fold, which the matcher checks and ranks.
      pure $ case traverse (\(rank, c) -> (,c) <$> rank) candidates of
        Just ranked | not (null ranked) -> searchRanked q ranked
        _ -> searchPlain q (map snd candidates)

-- | A page's path in its space ('Wiki.Core.Space.pagePath'), among the
-- pages the lookup finds: from under the space's home page. 'Nothing' for
-- a space or a page that is not there.
pathIn :: (TreeNode p, NodeId p ~ PageId) => Map SpaceId Space -> SpaceId -> (PageId -> Maybe p) -> PageId -> Maybe [Slug]
pathIn spaces sid byId pid = Map.lookup sid spaces >>= \s -> Space.pagePath s byId pid

-- | These pages and every page above them, by id: what 'pathOf' needs to
-- find each one's path. The pages above are read one level at a time, all
-- of a level in one query, so the reads grow with the depth of the tree,
-- not with the size of a space.
withAncestors :: [PageNode] -> Tx (Map PageId PageNode)
withAncestors = go mempty
  where
    -- GHC 9.10 and 9.12 need this signature to infer the types; GHC 9.14 does not.
    go :: Map PageId PageNode -> [PageNode] -> Tx (Map PageId PageNode)
    go found nodes = do
      let more = found <> Map.fromList [(n.id, n) | n <- nodes]
          missing = ordNub [p | n <- nodes, Just p <- [n.parent], Map.notMember p more]
      if null missing then pure more else db (pageNodesWithIds missing) >>= go more

--------------------------------------------------------------------------------
-- Spaces

createSpaceTx :: Maybe SpaceId -> Text -> Tx Space
createSpaceTx parent name = do
  ctx <- ask
  _ <- requireCreateSpace parent
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
          , sealed = False
          , encryption = Nothing
          , conversion = Nothing
          , entry = EnterAtOnce
          , owner = Nothing
          , active = True
          , personalContainer = False
          , mathMacros = ""
          , createdAt = time
          , position = nextPosition (childrenOf others parent)
          , subspaceOrder = ByName
          , pageOrder = ByName
          , homePage = Nothing
          , icon = Nothing
          , description = ""
          , blog = False
          , boxNumbering = InPage
          }
  db (insertSpace space)
  -- A plain space under an encrypted one is refused: a subspace of an
  -- encrypted space is made encrypted ('createEncryptedSubspaceTx').
  requireEncryptionRule space.id
  for_ ctx.creator $ \u ->
    db (insertGrants Grants {global = [], spaces = [SpaceGrant {space = space.id, subject = SubjectUser u, permission = AdministerSpace}], access = Open})
  withHomePage time space

-- | Give a space just inserted its home page ('insertHomePage'), created
-- as if the space's creator had created it.
withHomePage :: UTCTime -> Space -> Tx Space
withHomePage time space = do
  author <- asks (\x -> x.author)
  db (insertHomePage author time space)

-- | Give a space a profile, checked. The profile has no home page: the
-- space keeps the one it has.
setSpaceProfileTx :: SpaceId -> SpaceProfile -> Tx Space
setSpaceProfileTx sid given = do
  (s, c) <- findSpace sid
  home <- requireIconAdminister sid c
  requireNoConversion c
  -- The wiki home's space takes only an icon: the rest is its own.
  -- The owner's avatar, which the settings show as the icon of a personal
  -- space with none of its own, is not taken for one ('ownProfile').
  avatar <- asks (\x -> s.owner >>= (`Map.lookup` x.avatars))
  let p = ownProfile avatar (if home then SpaceProfile {description = s.description, icon = given.icon, blog = s.blog, boxNumbering = s.boxNumbering} else given)
  checked <- either invalid pure (checkProfile s p)
  when (checked.blog && not s.blog) (requirePlain "A blog" c)
  let s' = withProfile checked s
  db (updateSpace s')
  -- The space's settings save the whole profile at once, so a save that
  -- changed nothing is not recorded in the audit log.
  let changed = profileChanges s s'
  unless (null changed) (record "space.profile" (spaceSubject s') changed)
  pure s'

-- | What a change of a space's profile changed, in words: the description
-- as it is now, the icon as what it is, the numbering of boxes by its name
-- (@with-section@).
profileChanges :: Space -> Space -> [(Text, Text)]
profileChanges old new =
  [("description", if T.null new.description then "none" else new.description) | old.description /= new.description]
    <> [("icon", maybe "the default" iconText new.icon) | old.icon /= new.icon]
    <> [("blog", yesNo new.blog) | old.blog /= new.blog]
    <> [("numbers of boxes", numberingName new.boxNumbering) | old.boxNumbering /= new.boxNumbering]
  where
    iconText = \case
      IconEmoji e -> e
      IconColour c -> "colour " <> c
      IconImage _ _ -> "an uploaded image"

-- | Set a space's icon to an image, its bytes stored under their hash as
-- an attachment's are. The previous image's file is left for the deletion
-- of unreferenced files ("Wiki.Server.Storage.Blobs"). The image is this
-- many bytes, which the last argument stores in the blob directory given
-- to it, after the checks.
uploadSpaceIconTx :: SpaceId -> Text -> Integer -> (FilePath -> IO BlobId) -> Tx Space
uploadSpaceIconTx sid mediaType size store = do
  (s, c) <- findSpace sid
  _ <- requireIconAdminister sid c
  requireNoConversion c
  mt <- either invalid pure (checkIconUpload mediaType (fromIntegral size))
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (store dir)
  let s' = withProfile SpaceProfile {description = s.description, icon = Just (IconImage blob mt), blog = s.blog, boxNumbering = s.boxNumbering} s
  db (updateSpace s')
  -- The icon is part of the profile; it has its own operation only
  -- because it carries bytes.
  record "space.profile" (spaceSubject s') [("icon", "an uploaded image")]
  pure s'

-- | Check that the caller may change a space's icon, and say whether the
-- space is the one behind the wiki's home page (WP5.45 of docs/PLAN.md).
-- An ordinary space's icon takes whoever administers the space. The home's
-- icon is the wiki's own, so it takes an administrator of the wiki, as the
-- home page's other settings do; the home is never restructured
-- otherwise ('requireOrdinary').
requireIconAdminister :: SpaceId -> [Space] -> Tx Bool
requireIconAdminister sid c =
  asks (\x -> Home.isHomeSpace x.server.homePage sid) >>= \case
    True -> requireView c >> requireAdministrator $> True
    False -> requireAdminister c $> False

-- | Change a space, as someone who administers it.
adjustSpace :: SpaceId -> (Space -> Tx Space) -> Tx Space
adjustSpace sid f = do
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
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
  requireNoConversion c
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
  noticeNow

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
  -- Neither an encrypted space nor a space whose readers an encrypted
  -- space below it shares is made public.
  requireEncryptionRule sid
  record "space.public" (spaceSubject s') [("public", yesNo public)]
  pure s'

-- | Make a space private from its parent, or not ('Wiki.Core.Space.sealed').
-- Whoever administers the space may, which its parent's administrators do
-- by inheritance; but sealing it cuts that inheritance, so an
-- administrator who would no longer administer the space afterwards is
-- granted 'AdministerSpace' on it, as its creator is: otherwise they could
-- not undo what they just did.
setSpaceSealedTx :: SpaceId -> Bool -> Tx Space
setSpaceSealedTx sid sealed = do
  ctx <- ask
  (_, c) <- findSpace sid
  s' <- adjustSpace sid (\s -> pure s {sealed})
  -- An encrypted space is opened to its parent's readers only where those
  -- read encrypted spaces alone; its readers who leave make a renewal of
  -- its key due, and those who come wait for it ('noticeNow').
  requireEncryptionRule sid
  let sealedChain = initSafe c <> [s']
  when (sealed && not (canAdministerSpace ctx.principal ctx.grants sealedChain)) $
    for_ ctx.creator $ \u ->
      db (insertGrants Grants {global = [], spaces = [SpaceGrant {space = sid, subject = SubjectUser u, permission = AdministerSpace}], access = Open})
  record "space.sealed" (spaceSubject s') [("sealed", yesNo sealed)]
  noticeNow
  pure s'

renameSpaceTx :: SpaceId -> Text -> Tx Space
renameSpaceTx sid name = adjustSpace sid $ \s -> do
  when (isPersonal s) $
    invalid "A personal space is named after its owner, and cannot be renamed."
  n <- nonBlank "A space's name" name
  pure
    Space
      { id = s.id
      , name = n
      , slug = s.slug
      , parent = s.parent
      , public = s.public
      , sealed = s.sealed
      , encryption = s.encryption
      , conversion = s.conversion
      , entry = s.entry
      , owner = s.owner
      , active = s.active
      , personalContainer = s.personalContainer
      , mathMacros = s.mathMacros
      , createdAt = s.createdAt
      , position = s.position
      , subspaceOrder = s.subspaceOrder
      , pageOrder = s.pageOrder
      , homePage = s.homePage
      , icon = s.icon
      , description = s.description
      , blog = s.blog
      , boxNumbering = s.boxNumbering
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
  requireNoConversion c
  traverse_ requireNoConversion destinationChain
  require (mayMoveSpace ctx.principal ctx.grants c destinationChain)
  requireOrdinary sid
  when (isPersonal s && destination /= s.parent) $
    invalid "A personal space stays among the users' spaces: it cannot be moved."
  traverse_ (requireOrdinary) destination
  when (maybe False (within sid) destinationChain) $
    invalid "A space cannot be moved into itself or one of its subspaces."
  let others = Map.elems (Map.delete sid ctx.spaces)
      (slug, position)
        | destination == s.parent = (s.slug, s.position)
        | otherwise = (freshSlug (isJust . findChild others destination) s.slug, nextPosition (childrenOf others destination))
      s' = respace destination slug position s
  db (updateSpace s')
  -- Moved, the space and those below it share their readers with other
  -- spaces: the rule of encrypted spaces holds after the move, and the
  -- administrators of an encrypted space whose readers left are told.
  requireEncryptionRule sid
  noticeNow
  pure s'

--------------------------------------------------------------------------------
-- Personal spaces

--------------------------------------------------------------------------------
-- Avatars

-- | Give the asking user an avatar: an image of this media type and size,
-- which the last argument stores in the blob directory given to it, after
-- the checks ('checkAvatarUpload'). The avatar it replaces is left for the
-- deletion of unreferenced files, as a space's replaced icon is
-- ("Wiki.Server.Storage.Blobs"). Someone not signed in, and the operator,
-- have no account: 'Forbidden'. The result is the user with the avatar.
setAvatarTx :: Text -> Integer -> (FilePath -> IO BlobId) -> Tx User
setAvatarTx mediaType size store = do
  user <- ownAccount
  mt <- either invalid pure (checkAvatarUpload mediaType (fromIntegral size))
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (store dir)
  let avatar = Avatar {blob, mediaType = mt}
  db (updateAvatar user.id (Just avatar))
  record "account.avatar" (userSubject user) [("avatar", "set")]
  pure User {id = user.id, login = user.login, displayName = user.displayName, avatar = Just avatar}

-- | Take the asking user's avatar away, refused as 'setAvatarTx' is. The
-- result is the user without it.
removeAvatarTx :: Tx User
removeAvatarTx = do
  user <- ownAccount
  when (isJust user.avatar) $ do
    db (updateAvatar user.id Nothing)
    record "account.avatar" (userSubject user) [("avatar", "removed")]
  pure User {id = user.id, login = user.login, displayName = user.displayName, avatar = Nothing}

-- | The asking user, who has an account: not someone who has not signed
-- in, nor the server's operator ('Forbidden').
ownAccount :: Tx User
ownAccount = do
  _ <- notified
  asks (\x -> x.user) >>= maybe (failWith Forbidden) pure

-- | 'setAvatar' with the image in a file, as 'uploadAttachmentFile'.
setAvatarFile :: (MonadIO m) => Text -> FilePath -> StoredWiki m (Either WikiError User)
setAvatarFile mediaType file = do
  size <- liftIO (getFileSize file)
  run Writes (setAvatarTx mediaType size (\dir -> fst <$> storeBlobFile dir file))

-- | A user's avatar, for whoever may read the wiki: its media type and its
-- file. The avatar is looked up by its blob id, which is part of its URL,
-- so a new picture gets a new URL. The server's route for avatars serves
-- this. A blob that is not the user's avatar, or a user who does not
-- exist, is 'NotFound'; so is any avatar to someone a closed wiki does not
-- let in ('publicTo', the rule a space's view applies), whom the server's
-- listener answers 401 before it asks.
avatarFile :: (MonadIO m) => UserId -> BlobId -> StoredWiki m (Either WikiError (MimeType, FilePath))
avatarFile u blob = run Reads $ do
  asks (\x -> publicTo x.grants.access x.principal) >>= (`unless` failWith NotFound)
  dir <- asks (\x -> x.blobs)
  db (loadUser u) >>= \case
    Just found | Just a <- found.avatar, a.blob == blob, Just file <- blobFile dir a.blob -> pure (a.mediaType, file)
    _ -> failWith NotFound

-- | The asking user's personal space, turned on or off, or 'Nothing' if
-- they have none. Someone not signed in, and the server's operator, who
-- is not a user, have none and may have none: 'Forbidden'.
personalSpaceTx :: Tx (Maybe Space)
personalSpaceTx = do
  u <- notified
  asks (\x -> find (\s -> s.owner == Just u) (Map.elems x.spaces))

-- | Turn the asking user's personal space on or off. The first time, it is
-- made: in the container of personal spaces, which is made too if no user
-- has had one yet, with the user's login as its slug, public, with a home
-- page, and administered by its owner. Turning it off hides it from
-- everyone and keeps its content; turning it on again shows it as it was.
-- Turning off a personal space the user does not have is 'NotFound'. The
-- result is the space.
setPersonalSpaceTx :: Bool -> Tx Space
setPersonalSpaceTx enabled = do
  u <- notified
  user <- asks (\x -> x.user) >>= maybe (failWith Forbidden) pure
  ctx <- ask
  let named s = withName (personalName user.displayName) s
  case find (\s -> s.owner == Just u) (Map.elems ctx.spaces) of
    Just s -> do
      let s' = named s {active = enabled}
      when (s.active /= enabled) $ do
        db (updateSpace s')
        record "space.personal" (spaceSubject s') [("active", yesNo enabled)]
      pure s'
    Nothing
      | not enabled -> failWith NotFound
      | otherwise -> do
          time <- now
          container <- maybe (makeContainer time) pure (find (\s -> s.personalContainer) (Map.elems ctx.spaces))
          i <- newId
          let others = Map.elems ctx.spaces
              parent = Just container.id
              space =
                Space
                  { id = SpaceId i
                  , name = personalName user.displayName
                  , slug = freshSlug (isJust . findChild others parent) (fromMaybe (fallbackSlug "user") (slugify user.login.text))
                  , parent
                  , public = True
                  , sealed = False
                  , encryption = Nothing
                  , conversion = Nothing
                  , entry = EnterAtOnce
                  , owner = Just u
                  , active = True
                  , personalContainer = False
                  , mathMacros = ""
                  , createdAt = time
                  , position = nextPosition (childrenOf others parent)
                  , subspaceOrder = ByName
                  , pageOrder = ByName
                  , homePage = Nothing
                  , icon = Nothing
                  , description = ""
                  , blog = False
                  , boxNumbering = InPage
                  }
          db (insertSpace space)
          db (insertGrants Grants {global = [], spaces = [SpaceGrant {space = space.id, subject = SubjectUser u, permission = AdministerSpace}], access = Open})
          made <- withHomePage time space
          record "space.personal" (spaceSubject made) [("active", yesNo True), ("path", spacePathText [container, made])]
          pure made
  where
    -- The container of personal spaces: a top-level space with no grants
    -- and no home page, which nobody may view itself.
    makeContainer time = do
      i <- newId
      others <- asks (\x -> Map.elems x.spaces)
      let container =
            Space
              { id = SpaceId i
              , name = containerName
              , slug = freshSlug (isJust . findChild others Nothing) containerSlug
              , parent = Nothing
              , public = False
              , sealed = False
              , encryption = Nothing
              , conversion = Nothing
              , entry = EnterAtOnce
              , owner = Nothing
              , active = True
              , personalContainer = True
              , mathMacros = ""
              , createdAt = time
              , position = nextPosition (childrenOf others Nothing)
              , subspaceOrder = ByName
              , pageOrder = ByName
              , homePage = Nothing
              , icon = Nothing
              , description = ""
              , blog = False
              , boxNumbering = InPage
              }
      db (insertSpace container)
      pure container

-- | Delete a space: its subspaces, their pages, the pages' versions,
-- attachments and drafts, and the grants on all of them go with it, as the
-- schema's foreign keys cascade.
deleteSpaceTx :: SpaceId -> Tx ()
deleteSpaceTx sid = do
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
  ctx <- ask
  let below = [sp | sp <- Map.elems ctx.spaces, sp.id /= sid, within sid (chainOf ctx sp.id)]
  -- Count what is deleted with it, before deleting it.
  counts <- for (sid : map (\sp -> sp.id) below) $ \x -> db (countPagesIn x)
  db (deleteSpaceRow sid)
  -- The grants of encrypted spaces' keys name their spaces by id only, so
  -- they are deleted here rather than by a foreign key.
  db (deleteSpaceGrants (sid : map (\sp -> sp.id) below))
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
    , sealed = s.sealed
    , encryption = s.encryption
    , conversion = s.conversion
    , entry = s.entry
    , owner = s.owner
    , active = s.active
    , personalContainer = s.personalContainer
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    , homePage = s.homePage
    , icon = s.icon
    , description = s.description
    , blog = s.blog
    , boxNumbering = s.boxNumbering
    }

--------------------------------------------------------------------------------
-- Order

setSpaceOrderTx :: SpaceId -> Children -> ChildOrder -> Tx Space
setSpaceOrderTx sid kind order = do
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
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
  requireNoConversion c
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
  requireOrdinary p.space
  unless (s.pageOrder == ByHand) $
    invalid (s.name <> " lists its pages " <> T.toLower (orderName s.pageOrder) <> ", not by hand.")
  nodes <- db (childPages p.space p.parent)
  placePages (reposition (\x -> x.id) how pid (childrenInOrder ByHand nodes p.parent))
  findPage pid

--------------------------------------------------------------------------------
-- Pages

-- | A new page of a kind. With no parent, it goes under the space's home
-- page ('Wiki.Core.Space.parentOrRoot'), since nothing but the home page
-- has no parent. Only a kind this program knows can be chosen.
createPageTx :: PageKind -> SpaceId -> Maybe PageId -> Text -> Text -> Tx Page
createPageTx kind sid asked title body = do
  requireKnownKind kind
  (s, c) <- findSpace sid
  let parent = parentOrRoot s asked
  parentPage <- traverse findNode parent
  requireCreatePage sid c
  requirePlain "Writing a page as plain text" c
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
          , kind
          , createdBy = Nothing
          , updatedBy = Nothing
          }
  author <- asks (\x -> x.author)
  db (insertPage page >> insertVersion page author)
  requireOneRoot sid
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
  c <- asks (`chainOf` p.space)
  requireSavePage c pid
  requirePlain "Writing a page as plain text" c
  t <- nonBlank "A page's title" title
  when (p.updatedAt /= base) $
    failWith (Conflict "The page has been saved by someone else since this edit began.")
  time <- now
  -- Later than the version saved over even if the clock says otherwise
  -- ('savedAs').
  let p' = savedAs time t body p
  author <- asks (\x -> x.author)
  db $ do
    updatePageText pid t body p'.updatedAt
    insertVersion p' author
    for_ author (deleteDraft pid)
  server <- asks (\x -> x.server)
  when (Home.isHomePage server.homePage pid) $
    db (storeServerSettings server {SS.homePage = server.homePage {Home.title = t, Home.body = body}})
  tellTx p'.id p'.space p'.title Nothing "" PageSaved (newlyMentioned p.body body)
  pure p'

-- | Move a page with the pages under it. A page moved to no parent goes
-- under the destination's home page ('Wiki.Core.Space.parentOrRoot').
movePageTx :: PageId -> SpaceId -> Maybe PageId -> Tx Page
movePageTx pid destination asked = do
  ctx <- ask
  p <- findNode pid
  (targetSpace, target) <- findSpace destination
  let parent = parentOrRoot targetSpace asked
  parentPage <- traverse findNode parent
  let source = chainOf ctx p.space
  requireView source
  requireView target
  require (mayMovePage ctx.principal ctx.grants source target)
  requireEdit source
  requireEdit target
  requireOrdinary p.space
  requireOrdinary destination
  -- The space's home page stays where it is, and stays the space's: so
  -- does a page that holds it, moved to another space.
  subtree <- db (subtreeIds pid)
  (s, _) <- findSpace p.space
  for_ (homeMoveRefusal s pid (Set.toList subtree) (destination /= p.space)) invalid
  -- A page moves within an encrypted space as it moves within a plain one:
  -- its key and ciphertexts name its space and its own id, not its parent
  -- ("Wiki.Core.Encrypted"), so they stay valid. Moving it to another
  -- space would need them encrypted again for that space, in a member's
  -- browser.
  when (destination /= p.space) $ do
    requirePlain "Moving a page in or out of an encrypted space" source
    requirePlain "Moving a page in or out of an encrypted space" target
  when (any (\q -> q.space /= destination) parentPage) $
    invalid "A page's parent has to be in the same space."
  when (any (`Set.member` subtree) parent) $
    invalid "A page cannot be moved under itself or a page under it."
  -- Its siblings at the destination: what a new slug and position are
  -- chosen among.
  others <- filter (\q -> q.id /= pid) <$> db (childPages destination parent)
  let (slug, position)
        | destination == p.space && parent == p.parent = (p.slug, p.position)
        | otherwise = (freshSlug (isJust . findChild others parent) p.slug, nextPosition (childrenOf others parent))
  db (movePages pid destination parent slug position subtree)
  requireOneRoot destination
  when (destination /= p.space) pagesMoved
  findPage pid

-- | Make a page one of its space's templates, or not. Not a save: nothing
-- else of the page changes, and no version is kept.
setPageTemplateTx :: PageId -> Bool -> Tx Page
setPageTemplateTx pid template = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireEdit c
  requireOrdinary p.space
  requirePlain "A template" c
  when (template && s.homePage == Just pid) $
    invalid "A space's home page cannot be a template."
  db (setPageTemplateRow pid template)
  findPage pid

-- | Give a page a kind ("Wiki.Core.PageKind"). Not a save, as for a
-- template: nothing else of the page changes, and no version is kept. A
-- space's home page is a document, since it opens the space. An encrypted
-- space's pages may be presentations: the kind is in the clear, and the
-- slides are made from the text in the reader's browser.
setPageKindTx :: PageId -> PageKind -> Tx Page
setPageKindTx pid kind = do
  requireKnownKind kind
  p <- findNode pid
  (s, c) <- findSpace p.space
  -- What a save of the page asks, in a plain space and an encrypted one
  -- alike: the kind is the page's, in the clear in both.
  requireSavePage c pid
  requireOrdinary p.space
  when (kind /= Document && s.homePage == Just pid) $
    invalid "A space's home page is a document."
  db (setPageKindRow pid kind)
  findPage pid

-- | Refuse a kind this program does not know: a page is made, or made
-- into, a document or a presentation only.
requireKnownKind :: PageKind -> Tx ()
requireKnownKind kind =
  unless (kind `elem` knownKinds) $
    invalid ("A page is a document or a presentation, not “" <> pageKindName kind <> "”.")

-- | Delete a page: the pages under it, and the versions, attachments and
-- drafts of all of them, go with it, as the schema's foreign keys cascade.
deletePageTx :: PageId -> Tx ()
deletePageTx pid = do
  p <- findNode pid
  c <- chainOfPage p
  requireEdit c
  requireOrdinary p.space
  gone <- db (subtreeIds pid)
  (s, _) <- findSpace p.space
  for_ (homeDeleteRefusal s pid (Set.toList gone)) invalid
  let under = Set.size gone - 1
  above <- lineageOf pid
  let path = maybe "" (T.intercalate "/" . map slugText) (Space.pagePath s (`Map.lookup` above) pid)
  db (deletePageRow pid)
  pagesMoved
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
  c <- chainOfPage p
  requireAttachTo c pid
  requirePlain "An attachment" c
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
  c <- chainOfPage p
  requireAttachTo c pid
  db (deleteAttachmentRow aid)

--------------------------------------------------------------------------------
-- Drafts

-- | Check that someone signed in may edit a page, and return the id their
-- drafts are stored under.
draftable :: PageId -> Tx UserId
draftable pid = do
  p <- findNode pid
  c <- chainOfPage p
  requireEditPage c pid
  requirePlain "A draft kept on the server" c
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
      | u == administratorId = namedAuthor u administratorUser.displayName
      | otherwise = maybe (absentAuthor u) (\n -> Author {id = u, name = n, avatar = r.authorAvatar}) r.authorName

-- | A page of a page's history, each version with its number: the first
-- of them is numbered with how many versions there are up to it, and the
-- next ones count down from there.
listVersionsTx :: PageId -> VersionsQuery -> Tx [VersionInfo]
listVersionsTx pid q = do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  requirePlainPage "Reading a page's history as plain text" c pid
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
  c <- chainOfPage p
  requireView c
  requirePlainPage "Reading a page's history as plain text" c pid
  findVersion pid at

-- | Restore a version: a save of its title and body, as any save, in this
-- transaction, against the version the restorer saw.
restoreVersionTx :: PageId -> UTCTime -> UTCTime -> Tx Page
restoreVersionTx pid at base = do
  p <- findNode pid
  c <- chainOfPage p
  requireSavePage c pid
  requirePlain "Restoring a version on the server" c
  v <- findVersion pid at
  savePageTx pid base v.title v.body

--------------------------------------------------------------------------------
-- Encrypted spaces

-- | 'Conflict' when the chain goes through an encrypted space: what the
-- server does with a page's plain title, text, comments, attachments or
-- drafts cannot be done there ("Wiki.Core.Encrypted"). Permissions are
-- checked first, so that a reader who may not see the space learns
-- nothing from the refusal.
requirePlain :: Text -> [Space] -> Tx ()
requirePlain what c = when (any (\s -> isJust s.encryption) c) (failWith (Conflict (encryptedRefusal what)))

-- | The reason a plain operation is refused in an encrypted space, as the
-- application shows it.
encryptedRefusal :: Text -> Text
encryptedRefusal what = what <> " is not possible in an encrypted space: its pages are encrypted in its members' browsers, and the server cannot read them."

-- | The current key of an encrypted space, or 'Conflict' for a space whose
-- pages are plain text.
requireEncrypted :: Space -> Tx KeyId
requireEncrypted s = maybe (failWith (Conflict "This space is not encrypted: its pages are read and written as plain text.")) pure s.encryption

-- | Whether base64url text holds exactly so many bytes.
holdsBytes :: Int -> Text -> Bool
holdsBytes n t = (BS.length <$> fromBase64Url t) == Just n

-- | Base64url text that holds at least so many bytes and is at most so
-- many characters long.
boundedBytes :: Int -> Int -> Text -> Bool
boundedBytes least most t = T.length t <= most && maybe False (\b -> BS.length b >= least) (fromBase64Url t)

-- | 'Invalid' unless a grant's parts are of their lengths.
checkGrantParts :: KeyId -> Encapsulated -> Ciphertext -> Tx ()
checkGrantParts k enc sealed =
  unless (holdsBytes keyIdBytes k.text && holdsBytes encapsulatedBytes enc.text && holdsBytes sealedKeyBytes sealed.text) $
    invalid "This is not a key this wiki keeps: a part of the grant is not of its length."

-- | 'Invalid' unless a page key and a version are of their lengths, and
-- the version is encrypted with that page key.
checkSealedParts :: PageKey -> SealedContent -> Tx ()
checkSealedParts pk c = do
  unless (all (holdsBytes keyIdBytes) [pk.keyId.text, pk.spaceKeyId.text, c.keyId.text, c.tag.text]) $
    invalid "This is not a page this wiki keeps: a key's id or the version's tag is not of its length."
  unless (all (holdsBytes nonceBytes) [pk.wrapped.nonce.text, c.title.nonce.text, c.body.nonce.text] && holdsBytes sealedKeyBytes pk.wrapped.key.text) $
    invalid "This is not a page this wiki keeps: a nonce or the page's key is not of its length."
  unless (boundedBytes 16 maxTitleCiphertext c.title.ciphertext.text && boundedBytes 16 maxBodyCiphertext c.body.ciphertext.text) $
    invalid "This is not a page this wiki keeps: its title or its text is empty or too long."
  unless (c.keyId == pk.keyId) $
    invalid "The version is not encrypted with the page's key."

-- | The readers of the space at the end of the chain who hold a grant
-- reaching it: the users granted 'View' or more on it, directly or through
-- a group, who are not disabled. A global administrator who may view
-- every space is not one of them unless a grant on the space names them:
-- an encrypted space's key goes to its members only.
readersOf :: [Space] -> Tx [UserId]
readersOf c = do
  ctx <- ask
  users <- db loadUsers
  (disabled, _) <- db loadAccountFlags
  membership <- db loadMembership
  pure (readersIn ctx.grants membership users disabled c)

-- | Whether a rotation of the space's key is due
-- ("Wiki.Server.Storage.Renewal"): a grant of its current key to someone
-- who can no longer read it, or to a public key that is no longer its
-- user's.
rotationDueTx :: SpaceId -> [Space] -> KeyId -> Tx Bool
rotationDueTx sid c k = readersOf c >>= \readers -> db (renewalDue sid k readers)

-- | 'Conflict' while a rotation of the space's key is due: nothing is
-- sealed under a key that someone who can no longer read the space holds.
requireNoRenewal :: SpaceId -> [Space] -> KeyId -> Tx ()
requireNoRenewal sid c k = whenM (rotationDueTx sid c k) (failWith (Conflict renewalRefusal))

-- | Why a write in an encrypted space is refused while its key must be
-- renewed, and who renews it.
renewalRefusal :: Text
renewalRefusal = "This space's key must be renewed before anything more is written in it: someone who held the key can no longer read the space. An administrator of the space who holds the key renews it by opening the space, and then this can be done again."

-- | Tell the administrators of the encrypted spaces whose keys must now be
-- renewed ("Wiki.Server.Storage.Renewal"'s 'noticeRenewals'): what a
-- write that may make a reader one no longer does at its end.
noticeNow :: Tx ()
noticeNow = do
  ctx <- ask
  for_ ctx.author $ \actor -> do
    time <- now
    made <- db (noticeRenewals (maybe (namedAuthor actor actor.text) authorOf ctx.user) time)
    -- Published after the commit, with the transaction's other
    -- notifications, as 'tellTx''s are.
    liftIO (modifyIORef' ctx.told (reverse made <>))

-- | An encrypted space's key as the caller sees it ('SpaceEncryption').
spaceEncryptionTx :: SpaceId -> Tx SpaceEncryption
spaceEncryptionTx sid = do
  (s, c) <- findSpace sid
  requireView c
  k <- requireEncrypted s
  me <- asks (\x -> x.author)
  grants <- db (grantsOfKey spaceKind sid.text k)
  readers <- readersOf c
  keys <- db (currentPublicKeys (ordNub (toList me <> readers)))
  due <- db (renewalDue sid k readers)
  let current u = fst <$> Map.lookup u keys
      granted u = any (\g -> g.recipient == u && Just g.recipientKeyId == current u) grants
      mine = me >>= \u -> find (\g -> g.recipient == u && Just g.recipientKeyId == current u) grants
  pure
    SpaceEncryption
      { keyId = k
      , grant = mine
      , pending = if isJust mine then [PendingMember {user = u, keyId = kid, publicKey = pk} | u <- readers, Just (kid, pk) <- [Map.lookup u keys], not (granted u)] else []
      , waiting = if isJust mine then [u | u <- readers, not (Map.member u keys)] else []
      , rotationDue = due
      }

-- | Turn a space encrypted ('Wiki.Api.EncryptedApi''s @encrypt@), with
-- its home page written and encrypted by the caller's browser in place of
-- the untouched plain one it was made with.
encryptSpaceTx :: SpaceId -> EncryptSpace -> Tx Space
encryptSpaceTx sid req = do
  ctx <- ask
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
  when (isJust s.encryption) $ failWith (Conflict "This space is encrypted already.")
  when (isJust s.owner || s.personalContainer || s.blog) $ failWith (Conflict "A personal space or a blog cannot be encrypted.")
  when (any (\x -> x.parent == Just sid) (Map.elems ctx.spaces)) $
    failWith (Conflict "A space with subspaces cannot be encrypted yet: only a space with nothing written in it can.")
  untouched <-
    nothingWrittenIn s
      >>= maybe (failWith (Conflict "Only a space with nothing written in it can be encrypted at once: one whose pages are plain text is encrypted page by page, by a conversion.")) pure
  me <- maybe (failWith Forbidden) pure ctx.author
  checkGrantParts req.keyId req.grant.enc req.grant.sealed
  keys <- db (currentPublicKeys [me])
  unless (req.grant.recipient == me && (fst <$> Map.lookup me keys) == Just req.grant.recipientKeyId) $
    invalid "The space's key must be sealed to your own current public key: open your keys in your account's security first."
  time <- now
  for_ untouched (\pid -> db (deletePageRow pid))
  db $ do
    setSpaceKey sid req.keyId
    insertGrant spaceKind sid.text time KeyGrant {keyId = req.keyId, recipient = me, recipientKeyId = req.grant.recipientKeyId, enc = req.grant.enc, sealed = req.grant.sealed}
  -- A top-level space is made private with it, so that a later move under
  -- another space keeps it so.
  let keyed = withHome Nothing s {encryption = Just req.keyId, sealed = s.sealed || isNothing s.parent}
  db (updateSpace keyed)
  home <- insertSealedHome keyed req.keyId req.homePage
  let s' = withHome (Just home) keyed
  db (updateSpace s')
  -- Only a space that shares its readers with encrypted spaces alone, none
  -- public, is encrypted: a subspace must be private from a plain parent.
  requireEncryptionRule sid
  record "space.encrypted" (spaceSubject s') [("key", req.keyId.text)]
  pure s'

-- | Whether a space has nothing written in it: 'Just' its untouched home
-- page, the page the space was created with ('withHomePage'), never
-- edited (the starter's title and text, one version, no attachment or
-- comment), or 'Just' 'Nothing' for a space with no page; 'Nothing' for a
-- space with anything else. Its version names the space's creator as
-- author, as a page they wrote would, so the text is what tells the two
-- apart: a page someone wrote and made the home page is not untouched,
-- even with one version.
nothingWrittenIn :: Space -> Tx (Maybe (Maybe PageId))
nothingWrittenIn s =
  db (pageNodes s.id) >>= \case
    [] -> pure (Just Nothing)
    [home] | s.homePage == Just home.id -> do
      (versions, _) <- db (loadVersionsPage home.id Nothing 1)
      page <- findPage home.id
      comments <- Map.findWithDefault 0 home.id . Map.fromList <$> db (loadCommentCounts s.id)
      let generated = page.title == homeTitle && isHomeBody page.body
      pure (if generated && versions == 1 && null page.attachments && comments == 0 then Just (Just home.id) else Nothing)
    _ -> pure Nothing

-- | A subspace of an encrypted space, made encrypted
-- ('Wiki.Api.EncryptedApi''s @subspace@): checked as 'createSpaceTx'
-- checks a subspace, with its own key, granted to the caller, and its home
-- page, both made in the caller's browser. It is open to its parent's
-- readers, who wait for its key until a member's browser shares it.
createEncryptedSubspaceTx :: SpaceId -> NewEncryptedSubspace -> Tx Space
createEncryptedSubspaceTx parent new = do
  ctx <- ask
  _ <- requireCreateSpace (Just parent)
  (p, _) <- findSpace parent
  _ <- requireEncrypted p
  requireUuid "A space" new.id.text
  when (Map.member new.id ctx.spaces) $ failWith (Conflict "A space with this id exists already.")
  n <- nonBlank "A space's name" new.name
  me <- maybe (failWith Forbidden) pure ctx.author
  checkGrantParts new.keyId new.grant.enc new.grant.sealed
  keys <- db (currentPublicKeys [me])
  unless (new.grant.recipient == me && (fst <$> Map.lookup me keys) == Just new.grant.recipientKeyId) $
    invalid "The space's key must be sealed to your own current public key: open your keys in your account's security first."
  time <- now
  let others = Map.elems ctx.spaces
      space =
        Space
          { id = new.id
          , name = n
          , slug = freshSlug (isJust . findChild others (Just parent)) (fromMaybe (fallbackSlug "space") (slugify n))
          , parent = Just parent
          , public = False
          , sealed = False
          , encryption = Just new.keyId
          , conversion = Nothing
          , entry = EnterAtOnce
          , owner = Nothing
          , active = True
          , personalContainer = False
          , mathMacros = ""
          , createdAt = time
          , position = nextPosition (childrenOf others (Just parent))
          , subspaceOrder = ByName
          , pageOrder = ByName
          , homePage = Nothing
          , icon = Nothing
          , description = ""
          , blog = False
          , boxNumbering = InPage
          }
  db $ do
    insertSpace space
    insertGrant spaceKind space.id.text time KeyGrant {keyId = new.keyId, recipient = me, recipientKeyId = new.grant.recipientKeyId, enc = new.grant.enc, sealed = new.grant.sealed}
  for_ ctx.creator $ \u ->
    db (insertGrants Grants {global = [], spaces = [SpaceGrant {space = space.id, subject = SubjectUser u, permission = AdministerSpace}], access = Open})
  home <- insertSealedHome space new.keyId new.homePage
  let s' = withHome (Just home) space
  db (updateSpace s')
  requireEncryptionRule s'.id
  record "space.created" (spaceSubject s') [("encrypted", "yes")]
  pure s'

-- | The home page of an encrypted space made before encrypted spaces had
-- home pages ('Wiki.Api.EncryptedApi''s @home@), written and encrypted by
-- the browser of one of its administrators: put at the top of its pages,
-- and every other page at the top moved under it, with its slug and its
-- place, so that every page keeps its address (a home page has no segment
-- in addresses).
createSealedHomeTx :: SpaceId -> NewSealedPage -> Tx SealedPage
createSealedHomeTx sid new = do
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
  k <- requireEncrypted s
  when (isJust s.homePage) $ failWith (Conflict "This space has a home page already.")
  requireNoRenewal sid c k
  tops <- filter (\x -> isNothing x.parent) <$> db (pageNodes sid)
  home <- insertSealedHome s k new
  db (updateSpace (withHome (Just home) s))
  for_ tops $ \x -> do
    subtree <- db (subtreeIds x.id)
    db (movePages x.id sid (Just home) x.slug x.position subtree)
  requireOneRoot sid
  findPage home >>= sealedPageOf

-- | A space's home page, written and encrypted in a browser, checked as
-- 'createSealedPageTx' checks a page: at the top of its pages, under the
-- space's key, the first of its chain of versions. The space's record is
-- the caller's to update. The result is the page's id.
insertSealedHome :: Space -> KeyId -> NewSealedPage -> Tx PageId
insertSealedHome s k new = do
  unless (isNothing new.parent) $ invalid "A space's home page is at the top of its pages."
  -- A home page is always a document ("Wiki.Core.PageKind").
  unless (new.kind == Document) $ invalid "A space's home page is a document."
  requireUuid "A page" new.id.text
  db (pageNode new.id) >>= traverse_ (\_ -> failWith (Conflict "A page with this id exists already."))
  checkSealedParts new.pageKey new.content
  unless (new.pageKey.spaceKeyId == k) $
    failWith (Conflict "The space's key has changed since: open the space again.")
  unless (new.content.chain == Just firstChain) $
    failWith (Conflict outOfChain)
  random <- T.take 12 . T.filter (/= '-') <$> newId
  time <- now
  siblings <- db (childPages s.id Nothing)
  let page =
        Page
          { id = new.id
          , space = s.id
          , parent = Nothing
          , title = ""
          , slug = freshSlug (isJust . findChild siblings Nothing) (fallbackSlug random)
          , body = ""
          , attachments = []
          , createdAt = time
          , updatedAt = time
          , position = 0
          , template = False
          , createdBy = Nothing
          , updatedBy = Nothing
          , kind = Document
          }
  author <- asks (\x -> x.author)
  db $ do
    insertPage page
    insertVersion page author
    insertPageKey page.id new.pageKey
    insertSealedVersion page.id page.updatedAt new.content
  pure page.id

-- | 'Conflict' with its reason when the rule of encrypted spaces
-- ("Wiki.Core.Permission"'s 'encryptionProblem') does not hold, as the
-- database is now, in the space given or in one below it: the spaces
-- whose chains a write to it changes.
requireEncryptionRule :: SpaceId -> Tx ()
requireEncryptionRule sid = do
  spaces <- db loadSpaces
  let byId i = Map.lookup i spaces
      chainTo i = fromMaybe [] (ancestry byId i)
      below = [x | x <- Map.elems spaces, any (\a -> a.id == sid) (chainTo x.id)]
  for_ (mapMaybe (Permission.encryptionProblem . chainTo . (\x -> x.id)) below) (failWith . Conflict)

-- | Grant a space's current key to readers waiting for it.
grantSpaceKeyTx :: SpaceId -> NewGrants -> Tx ()
grantSpaceKeyTx sid req = do
  (s, c) <- findSpace sid
  requireView c
  k <- requireEncrypted s
  me <- asks (\x -> x.author) >>= maybe (failWith Forbidden) pure
  when (length req.grants > maxGrantsAtOnce) $
    invalid ("At most " <> show maxGrantsAtOnce <> " grants are made at once.")
  unless (req.keyId == k) $
    failWith (Conflict "The space's key has changed since: open the space again.")
  requireNoRenewal sid c k
  grants <- db (grantsOfKey spaceKind sid.text k)
  keys <- db (currentPublicKeys (ordNub (me : map (\g -> g.recipient) req.grants)))
  let current u = fst <$> Map.lookup u keys
  -- Only a member who holds the key can have sealed it.
  require (any (\g -> g.recipient == me && Just g.recipientKeyId == current me) grants)
  readers <- readersOf c
  time <- now
  -- A grant sent twice in one request is made once: the second would
  -- repeat the first's row, which the table's key refuses.
  for_ (nubOrdOn (\g -> (g.recipient, g.recipientKeyId)) req.grants) $ \g -> do
    checkGrantParts k g.enc g.sealed
    unless (g.recipient `elem` readers) $
      invalid "A space's key is granted only to its readers."
    unless (current g.recipient == Just g.recipientKeyId) $
      failWith (Conflict "A reader's public key has changed since: open the space again.")
    unless (any (\x -> x.recipient == g.recipient && x.recipientKeyId == g.recipientKeyId) grants) $
      db (insertGrant spaceKind sid.text time KeyGrant {keyId = k, recipient = g.recipient, recipientKeyId = g.recipientKeyId, enc = g.enc, sealed = g.sealed})

-- | Why a version of a page of an encrypted space is refused when it does
-- not follow on the page's latest version in the chain of versions
-- ("Wiki.Core.Encrypted"): sent by a tab of a program from before the
-- chain, or built on a version that is no longer the latest.
outOfChain :: Text
outOfChain = "This version does not follow on the page's latest one: reload the page, and save again."

-- | What a rotation of the space's key needs ('rotationInfo'): its readers
-- with a public key, and every key of every page, with the title of the
-- page's latest version. For one who may administer the space: the only
-- ones who may rotate its key.
rotationInfoTx :: SpaceId -> Tx RotationInfo
rotationInfoTx sid = do
  (s, c) <- findSpace sid
  requireView c
  requireAdminister c
  k <- requireEncrypted s
  readers <- readersOf c
  keys <- db (currentPublicKeys readers)
  allKeys <- db (loadSpaceAllPageKeys sid)
  latest <- db (loadSealedLatest sid)
  pure
    RotationInfo
      { keyId = k
      , readers = [PendingMember {user = u, keyId = kid, publicKey = pk} | u <- readers, Just (kid, pk) <- [Map.lookup u keys]]
      , pages = [RotationPage {page = pid, keys = ks, latest = headingOf content} | (pid, ks) <- Map.toList allKeys, Just content <- [Map.lookup pid latest]]
      }

-- | Give an encrypted space a new key ('Wiki.Api.Encrypted.Rotation'):
-- sealed to every reader with a current public key, every key of every
-- page wrapped again with it, and a new key for every page, which its
-- next version is encrypted with. Every grant of an older key goes. Only
-- from one who may administer the space and holds its current key: a
-- rotation rewrites every page key's wrap and every grant at once, and
-- the server cannot check that a wrap opens, so it is taken only from
-- those who could delete the space anyway. A rotation that leaves out a
-- reader, a page or one of its keys, or names one there is not, is
-- refused; so is one larger than 'maxRotatedKeys' or 'maxRotatedGrants'.
rotateSpaceKeyTx :: SpaceId -> Rotation -> Tx ()
rotateSpaceKeyTx sid r = do
  ctx <- ask
  (s, c) <- findSpace sid
  requireAdminister c
  k <- requireEncrypted s
  me <- maybe (failWith Forbidden) pure ctx.author
  unless (r.from == k) $
    failWith (Conflict "The space's key has changed since: open the space again.")
  when (length r.grants > maxRotatedGrants || sum [1 + length p.rewrapped | p <- r.pages] > maxRotatedKeys) $
    invalid ("This space is too large for its key to be renewed in one request: at most " <> show maxRotatedGrants <> " readers and " <> show maxRotatedKeys <> " keys of pages.")
  grants <- db (grantsOfKey spaceKind sid.text k)
  mine <- db (currentPublicKeys [me])
  -- Only one who holds the current key: one who has read the space.
  require (any (\g -> g.recipient == me && Just g.recipientKeyId == (fst <$> Map.lookup me mine)) grants)
  unless (holdsBytes keyIdBytes r.keyId.text && r.keyId /= k) $
    invalid "The space's new key needs a new id of its length."
  -- Sealed to every reader with a current public key, once, and to nobody
  -- else.
  readers <- readersOf c
  keys <- db (currentPublicKeys readers)
  let expected = Map.fromList [(u, kid) | u <- readers, Just (kid, _) <- [Map.lookup u keys]]
      sent = Map.fromList [(g.recipient, g.recipientKeyId) | g <- r.grants]
  unless (length r.grants == Map.size sent && sent == expected) $
    failWith (Conflict "The space's readers, or their public keys, have changed since the new key was made: open the space again.")
  for_ r.grants $ \g -> checkGrantParts r.keyId g.enc g.sealed
  -- Every key of every page, wrapped again, and a new one for each page.
  stored <- db (loadSpaceAllPageKeys sid)
  let sentPages = Map.fromList [(p.page, p) | p <- r.pages]
  unless (length r.pages == Map.size sentPages && Map.keysSet sentPages == Map.keysSet stored) $
    failWith (Conflict "The space's pages have changed since the new key was made: open the space again.")
  for_ r.pages $ \p -> do
    let old = Map.findWithDefault [] p.page stored
        ids = map (\x -> x.keyId)
    unless (sort (ids p.rewrapped) == sort (ids old)) $
      failWith (Conflict "A page's keys have changed since the new key was made: open the space again.")
    unless (all (\x -> x.spaceKeyId == r.keyId) (p.current : p.rewrapped) && p.current.keyId `notElem` ids old) $
      invalid "Every key of a page is wrapped by the space's new key, and each page has a new one."
    for_ (p.current : p.rewrapped) $ \x ->
      unless (holdsBytes keyIdBytes x.keyId.text && holdsBytes nonceBytes x.wrapped.nonce.text && holdsBytes sealedKeyBytes x.wrapped.key.text) $
        invalid "This is not a key this wiki keeps: a part of a page's key is not of its length."
  time <- now
  db $ do
    for_ r.pages $ \p -> replacePageKeys p.page p.current p.rewrapped
    deleteGrantsOfSpace sid
    for_ r.grants $ \g -> insertGrant spaceKind sid.text time KeyGrant {keyId = r.keyId, recipient = g.recipient, recipientKeyId = g.recipientKeyId, enc = g.enc, sealed = g.sealed}
    setSpaceKey sid r.keyId
  record "space.key-renewed" (spaceSubject s) [("key", r.keyId.text), ("readers", show (length r.grants)), ("pages", show (length r.pages))]

-- | What a notification names a page of an encrypted space by, in the
-- bell, the feed and the mail: not its title, which the server cannot
-- read, but what it is.
encryptedTitle :: Text
encryptedTitle = CE.encryptedPageTitle

-- | The most grants one request makes.
maxGrantsAtOnce :: Int
maxGrantsAtOnce = 500

-- | A page of an encrypted space with its latest version, encrypted.
sealedPageOf :: Page -> Tx SealedPage
sealedPageOf p = do
  (s, _) <- findSpace p.space
  requireSealedPage s p.id
  pk <- db (loadPageKey p.id) >>= maybe (failWith (Conflict "This page has no key: it is not a page of an encrypted space.")) pure
  content <- db (loadSealedVersion p.id p.updatedAt) >>= maybe (failWith NotFound) pure
  pageKeys <- db (loadPageKeys p.id)
  metas <- db (loadSealedMetas p.id)
  w <- withWriters p
  pure
    SealedPage
      { id = p.id
      , space = p.space
      , parent = p.parent
      , slug = p.slug
      , createdAt = p.createdAt
      , updatedAt = p.updatedAt
      , position = p.position
      , pageKey = pk
      , content
      , createdBy = w.createdBy
      , updatedBy = w.updatedBy
      , pageKeys
      , attachments = [SealedAttachment {id = a.id, size = fromIntegral a.size, meta} | a <- p.attachments, Just meta <- [Map.lookup a.id metas]]
      , kind = p.kind
      }

-- | The pages of an encrypted space with their encrypted titles.
sealedPagesTx :: SpaceId -> Tx [SealedSummary]
sealedPagesTx sid = do
  (s, c) <- findSpace sid
  requireView c
  _ <- requireEncrypted s
  summaries <- (\xs -> sealedAmong s xs (\x -> x.id)) =<< db (loadPageSummaries sid)
  keys <- db (loadSpaceAllPageKeys sid)
  latest <- db (loadSealedLatest sid)
  pure
    [ SealedSummary {id = p.id, space = p.space, parent = p.parent, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, pageKey = pk, heading = headingOf content, pageKeys = all', kind = p.kind}
    | p <- sortOn (\x -> (x.createdAt, x.id)) summaries
    , Just all'@(pk : _) <- [Map.lookup p.id keys]
    , Just content <- [Map.lookup p.id latest]
    ]

-- | The pages of an encrypted space with their latest versions, encrypted.
sealedContentsTx :: SpaceId -> Tx [SealedPage]
sealedContentsTx sid = do
  (s, c) <- findSpace sid
  requireView c
  _ <- requireEncrypted s
  summaries <- (\xs -> sealedAmong s xs (\x -> x.id)) =<< db (loadPageSummaries sid)
  keys <- db (loadSpaceAllPageKeys sid)
  latest <- db (loadSealedLatest sid)
  pure
    [ SealedPage {id = p.id, space = p.space, parent = p.parent, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, pageKey = pk, content, createdBy = Nothing, updatedBy = Nothing, pageKeys = all', attachments = [], kind = p.kind}
    | p <- sortOn (\x -> (x.createdAt, x.id)) summaries
    , Just all'@(pk : _) <- [Map.lookup p.id keys]
    , Just content <- [Map.lookup p.id latest]
    ]

-- | A page of an encrypted space by its path.
sealedPageAtTx :: SpaceId -> [Slug] -> Tx SealedPage
sealedPageAtTx sid path = do
  (s, c) <- findSpace sid
  requireView c
  _ <- requireEncrypted s
  -- From under the space's home page, as a plain space's paths are; a space
  -- with none yet from the top of its pages.
  root <- maybe (pure Nothing) (\r -> db (pageNode r)) (rootPage s)
  resolveUnderM root (\parent slug -> db (childPage sid parent slug)) path >>= \case
    Right ps | Just p <- lastMay ps -> findPage p.id >>= sealedPageOf
    _ -> failWith NotFound

-- | A new page of an encrypted space: a page row with an empty title and
-- text and a random slug, its key, and its first version, encrypted.
createSealedPageTx :: SpaceId -> NewSealedPage -> Tx SealedPage
createSealedPageTx sid new = do
  requireKnownKind new.kind
  (s, c) <- findSpace sid
  -- A page asked for at the top goes under the space's home page, as a
  -- plain page does ('parentOrRoot'); a space with none yet keeps its
  -- pages at the top.
  let parent = parentOrRoot s new.parent
  parentPage <- traverse findNode parent
  requireCreatePage sid c
  k <- requireEncrypted s
  when (any (\p -> p.space /= sid) parentPage) $
    invalid "A page's parent has to be in the same space."
  when (isNothing (UUID.fromText new.id.text)) $
    invalid "A new page's id is a UUID."
  db (pageNode new.id) >>= traverse_ (\_ -> failWith (Conflict "A page with this id exists already."))
  checkSealedParts new.pageKey new.content
  unless (new.pageKey.spaceKeyId == k) $
    failWith (Conflict "The space's key has changed since: open the space again.")
  -- The first version of the chain ("Wiki.Core.Encrypted"): a browser of
  -- before versions were chained sends none, and is told to reload.
  unless (new.content.chain == Just firstChain) $
    failWith (Conflict outOfChain)
  requireNoRenewal sid c k
  nodes <- db (childPages sid parent)
  random <- T.take 12 . T.filter (/= '-') <$> newId
  time <- now
  let page =
        Page
          { id = new.id
          , space = sid
          , parent
          , title = ""
          , slug = freshSlug (isJust . findChild nodes parent) (fallbackSlug random)
          , body = ""
          , attachments = []
          , createdAt = time
          , updatedAt = time
          , position = nextPosition (childrenOf nodes parent)
          , template = False
          , kind = new.kind
          , createdBy = Nothing
          , updatedBy = Nothing
          }
  author <- asks (\x -> x.author)
  db $ do
    insertPage page
    insertVersion page author
    insertPageKey page.id new.pageKey
    insertSealedVersion page.id page.updatedAt new.content
  -- Whoever watches the space is told that a page was saved, by its id:
  -- with no title ('encryptedTitle' instead) and no excerpt, and no
  -- mentions, which the server cannot read.
  tellTx page.id sid encryptedTitle Nothing "" PageSaved mempty
  sealedPageOf page

-- | A new version of a page of an encrypted space, against the version
-- given, as 'savePageTx' for a plain page.
saveSealedPageTx :: PageId -> UTCTime -> SealedEdit -> Tx SealedPage
saveSealedPageTx pid base edit = do
  p <- findPage pid
  c <- asks (`chainOf` p.space)
  -- As a plain save asks: the space's home page is its administrators'.
  requireSavePage c pid
  s <- fst <$> findSpace p.space
  k <- requireEncrypted s
  requireSealedPage s pid
  requireNoRenewal p.space c k
  pk <- db (loadPageKey pid) >>= maybe (failWith (Conflict "This page has no key: it is not a page of an encrypted space.")) pure
  -- A version encrypted with an older key of the page's, from a tab that
  -- read the page before its space's key was renewed.
  when (edit.content.keyId /= pk.keyId) $
    failWith (Conflict "This page's key has changed since it was opened: the space's key was renewed. Open the page again.")
  checkSealedParts pk edit.content
  when (p.updatedAt /= base) $
    failWith (Conflict "The page has been saved by someone else since this edit began.")
  -- The version follows on the latest one in the chain
  -- ("Wiki.Core.Encrypted"): the next number, naming the latest's tag.
  latest <- db (loadSealedVersion pid p.updatedAt) >>= maybe (failWith NotFound) pure
  unless (edit.content.chain == Just (chainAfter latest.tag latest.chain)) $
    failWith (Conflict outOfChain)
  time <- now
  let p' = savedAs time "" "" p
  author <- asks (\x -> x.author)
  db $ do
    updatePageText pid "" "" p'.updatedAt
    insertVersion p' author
    insertSealedVersion pid p'.updatedAt edit.content
  tellTx p'.id p'.space encryptedTitle Nothing "" PageSaved mempty
  sealedPageOf p'

-- | A page of a page's history, encrypted, as 'listVersionsTx' lists a
-- plain page's.
sealedVersionsTx :: PageId -> VersionsQuery -> Tx [SealedVersionInfo]
sealedVersionsTx pid q = do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  s <- fst <$> findSpace p.space
  _ <- requireEncrypted s
  requireSealedPage s pid
  (before, rows) <- db (loadVersionsPage pid q.before (max 1 (min maxVersionsPageSize q.limit)))
  fmap catMaybes . for (zip [before, before - 1 ..] rows) $ \(n, r) -> do
    let v = versionOf pid r
    db (loadSealedVersion pid r.updatedAt) <&> fmap (\content -> SealedVersionInfo {page = pid, updatedAt = v.updatedAt, heading = headingOf content, author = v.author, number = n})

-- | One version of a page of an encrypted space, encrypted.
sealedVersionTx :: PageId -> UTCTime -> Tx SealedVersion
sealedVersionTx pid at = do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  s <- fst <$> findSpace p.space
  _ <- requireEncrypted s
  requireSealedPage s pid
  v <- findVersion pid at
  content <- db (loadSealedVersion pid at) >>= maybe (failWith NotFound) pure
  pure SealedVersion {page = pid, updatedAt = v.updatedAt, content, author = v.author}

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
  -- Disabling an account, or setting its password (which may retire its
  -- key pair), may make a reader of an encrypted space one no longer.
  noticeNow
  db (loadAccount u) >>= maybe (failWith NotFound) pure

-- | Create a user who signs in with an OPAQUE record, as an administrator
-- whom the wiki's settings let create accounts with a password: the
-- server's API's @createUser@, whose body carries the record the
-- administrator's browser made ("Wiki.Api.Opaque"). The new user's id is
-- the record's credential id.
createUserWithRecord :: (MonadIO m) => NewAccountRecord -> StoredWiki m (Either WikiError Account)
createUserWithRecord new =
  run Reads requireAccountCreator >>= \case
    Left e -> pure (Left e)
    Right () -> case parseLogin new.login of
      Left why -> pure (Left (Invalid why))
      Right login -> case UUID.fromText new.password.credential of
        Nothing -> pure (Left (Invalid "The password was prepared for no account: try again."))
        Just uuid -> do
          let uid = UserId (UUID.toText uuid)
          case storedRecordOf uid new.password of
            Left why -> pure (Left (Invalid why))
            Right stored -> insertUserTx uid login new.displayName stored

-- | Give a user the OPAQUE record the administrator's browser made, which
-- ends their sessions: the server's API's @setPassword@.
setPasswordRecord :: (MonadIO m) => UserId -> PasswordRecord -> StoredWiki m (Either WikiError Account)
setPasswordRecord u r =
  run Reads (requireAdministrator >> findUser u >>= requirePasswordToSet) >>= \case
    Left e -> pure (Left e)
    Right () -> case storedRecordOf u r of
      Left why -> pure (Left (Invalid why))
      Right stored -> setRecordTx u stored

-- | Insert a user with an OPAQUE record, as an administrator who may
-- create accounts, recorded in the audit log. A blank display name becomes
-- the login. An id another user has (a record's credential id used twice)
-- or a login another user has is a 'Conflict'.
insertUserTx :: (MonadIO m) => UserId -> Login -> Text -> StoredRecord -> StoredWiki m (Either WikiError Account)
insertUserTx uid login rawName stored = do
  let name = case T.strip rawName of
        "" -> login.text
        n -> n
  run Writes $ do
    requireAccountCreator
    db (loadAccount uid) >>= \case
      Just _ -> failWith (Conflict "The password was prepared for an account that exists already: try again.")
      Nothing -> pass
    db (insertAccount uid login name (Just stored)) >>= \case
      Left taken -> failWith (Conflict ("There is a user with the login " <> taken.text <> " already."))
      Right account -> do
        record "user.create" (userSubject account.user) [("login", login.text), ("name", name)]
        pure account

-- | Give a user an OPAQUE record as an administrator, which ends their
-- sessions and takes from their vault what only the old password
-- unlocked, as a reset link does ('replaceRecord'). The audit log records
-- that the password changed, never anything of it.
setRecordTx :: (MonadIO m) => UserId -> StoredRecord -> StoredWiki m (Either WikiError Account)
setRecordTx u stored = do
  at <- liftIO getCurrentTime
  run Writes $ do
    requireAdministrator
    findUser u >>= requirePasswordToSet
    changeAccountTx "user.password" [] u (replaceRecord at u stored)

-- | A password's OPAQUE record for a user, made with both sides in this
-- process ("Wiki.Server.Opaque"), with the stretching new records get:
-- for a password the server is given (the console, the storage's own
-- operations), which it registers and forgets.
recordHere :: Storage -> UserId -> Password -> IO (Either Text StoredRecord)
recordHere st u p = do
  setup <- serverSetup st
  registerHere setup (storageStretch st) u p

-- | The Argon2id new OPAQUE records are stretched with.
storageStretch :: Storage -> Stretch
storageStretch st = st.config.passwordStretch

-- | The server's OPAQUE secret ("Wiki.Server.Opaque"), read from the
-- settings table, and made and stored there the first time, in a write.
serverSetup :: Storage -> IO ServerSetup
serverSetup st =
  reading st (settingValue setupKey) >>= \case
    Just t | Just setup <- setupFromText t -> pure setup
    _ -> writing st loadServerSetup

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
  noticeNow

-- | Put a user in a group, or take them out; doing either twice changes
-- nothing.
setMemberTx :: Bool -> GroupId -> UserId -> Tx ()
setMemberTx member gid u = do
  requireAdministrator
  g <- findGroup gid
  user <- findUser u
  db ((if member then insertMember else deleteMember) gid u)
  record (if member then "group.member-add" else "group.member-remove") (groupSubject gid g.name) [("user", user.login.text)]
  noticeNow

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

-- | Change only the shared front page, preserving other server settings.
setHomePageTx :: HomePage -> Tx Kept
setHomePageTx change = do
  requireAdministrator
  old <- asks (\x -> x.server)
  checked <- either invalid pure (checkHomePage change)
  let homePage =
        old.homePage
          { Home.showSpaces = checked.showSpaces
          , Home.showRecent = checked.showRecent
          , Home.showAnonymous = checked.showAnonymous
          }
      new = old {SS.homePage = homePage}
  db (storeServerSettings new)
  record "settings.home-page" (settingsSubject "the home page") []
  pure new

-- | Check and store the server's settings.
setServerSettingsTx :: ServerSettingsChange -> Tx Kept
setServerSettingsTx change = do
  requireAdministrator
  old <- asks (\x -> x.server)
  checked <- either invalid pure (checkServerSettings isJust (applyChange Secret old change))
  let requested = checked.homePage
      home = old.homePage {Home.showSpaces = requested.showSpaces, Home.showRecent = requested.showRecent, Home.showAnonymous = requested.showAnonymous}
      new = checked {SS.homePage = home}
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
    <> [("built-in math macros", if isJust old.mathMacros then "changed" else "copied from the shipped ones") | old.mathMacros /= new.mathMacros]
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
-- the person; the login is then free for a new account. Their personal
-- space, if they have one, is deleted with the account.
removeUserTx :: UserId -> Tx ()
removeUserTx u = do
  requireAdministrator
  user <- findUser u
  self <- asks (\x -> (\p -> p.user) <$> x.principal)
  when (self == Just u) (failWith (Invalid "You cannot remove your own account."))
  account <- db (loadAccount u) >>= maybe (failWith NotFound) pure
  unless account.disabled (failWith (Conflict ("Disable " <> user.login.text <> "'s login before removing the account.")))
  -- Their personal space belongs to them, and goes with the account (the
  -- schema's foreign key cascades).
  personal <- asks (\x -> find (\s -> s.owner == Just u) (Map.elems x.spaces))
  db (deleteUserRows u (formerAuthor user.login.text))
  record "user.remove" (userSubject user) [("personal space", "deleted") | isJust personal]
  noticeNow

--------------------------------------------------------------------------------
-- Comments

-- | Who wrote a comment, as a reader sees them: the administrator, a user
-- by the display name and avatar the users table has for them, or, for an author who
-- is not a user here (one an import brought), as 'absentAuthor' names
-- them.
commentAuthor :: UserId -> Maybe Text -> Maybe Avatar -> Author
commentAuthor u name avatar
  | u == administratorId = namedAuthor u administratorUser.displayName
  | otherwise = maybe (absentAuthor u) (\n -> Author {id = u, name = n, avatar}) name

-- | Check that the current user may read a page, and return its space's
-- chain and its threads. Every comment operation starts with this, so its
-- checks come in the order the class's Haddock gives.
discussion :: PageId -> Tx ([Space], [Thread])
discussion pid = do
  (c, ts) <- discussionOf pid
  requirePlainPage "A comment" c pid
  pure (c, ts)

-- | 'discussion' for what carries no text of a comment (deleting one,
-- deleting or resolving a thread): in an encrypted space too.
discussionOf :: PageId -> Tx ([Space], [Thread])
discussionOf pid = do
  p <- findNode pid
  c <- chainOfPage p
  requireView c
  home <- asks (\x -> Home.isHomePage x.server.homePage pid)
  when home (failWith NotFound)
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
  requireNoConversion c
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
  findNode pid >>= chainOfPage >>= requireNoConversion
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
  (c, ts) <- discussionOf pid
  t <- threadIn ts tid
  old <- commentIn t cid
  ctx <- ask
  require (mayDeleteComment ctx.principal ctx.grants c old)
  requireNoConversion c
  case t.comments of
    opening : _ : _ | opening.id == cid -> invalid "The first comment of a thread with replies cannot be deleted: delete the thread instead."
    [_] -> db (Comments.deleteThreadRow tid) $> ((), pid, ThreadDeleted tid)
    _ -> db (Comments.deleteCommentRow cid) $> ((), pid, CommentDeleted tid cid)

deleteThreadTx :: PageId -> CommentThreadId -> Tx ((), PageId, PageEvent)
deleteThreadTx pid tid = do
  (c, ts) <- discussionOf pid
  t <- threadIn ts tid
  ctx <- ask
  require (mayDeleteThread ctx.principal ctx.grants c t)
  requireNoConversion c
  db (Comments.deleteThreadRow tid)
  pure ((), pid, ThreadDeleted tid)

setResolvedTx :: PageId -> CommentThreadId -> Bool -> Tx (Thread, PageId, PageEvent)
setResolvedTx pid tid resolved = do
  (c, ts) <- discussionOf pid
  t <- threadIn ts tid
  _ <- commenter c
  -- In an encrypted space the quote is encrypted, and the thread's row says
  -- only whether it has one.
  sealed <- maybe (pure False) (`pageReadsSealed` pid) (lastMay c)
  anchored <-
    if sealed
      then maybe False fst . Map.lookup tid <$> db (loadSealedAnchors pid)
      else pure (isJust t.anchor)
  unless anchored $
    invalid "A thread about the whole page is not resolved: only one about a quote of it is."
  db (Comments.updateResolved tid resolved)
  pure (Thread {id = t.id, page = t.page, anchor = t.anchor, resolved, createdAt = t.createdAt, comments = t.comments}, pid, ThreadResolved tid resolved)

--------------------------------------------------------------------------------
-- Encrypting a space that has pages, and turning encryption off

-- $conversion
-- A conversion ("Wiki.Core.Space"'s 'Conversion', item 4 of #213) turns a
-- space's plain pages into ciphertext, or back, one page at a time, in the
-- browser of one of its administrators who holds its key. It covers the
-- space and the spaces below it (every space below an encrypted space is
-- encrypted, 'Permission.encryptionProblem'). The space's key is set from
-- its start to the end of a decryption, so that the search, the exports,
-- the links and the import treat it as encrypted throughout.
--
-- For each page the browser stages what the page becomes: while a space is
-- encrypted, every version in the chained format, the threads' quotes, the
-- comments and the attachments, encrypted, in the encrypted tables
-- ("Wiki.Server.Storage.Sealed"), the attachments' bytes in
-- @sealed_attachments.staged_blob@; while its encryption is turned off,
-- the same decrypted, in @staged_plain@. It reads back what is staged
-- ('stagedPageTx'), opens or compares all of it, and commits the page
-- with the digest of what it read ('commitConvertedTx'). The commit checks
-- that everything of the page is staged, as read, and puts it in place in
-- one transaction: until then the page reads the way it did
-- ('Space.readsSealed'). The last page's commit ends the conversion.
--
-- Meanwhile every other write in the space is refused
-- ('requireNoConversion'), but for a renewal of its key, which a reader's
-- removal elsewhere may make due, and the sharing of its key with its
-- readers: the browser converting the space renews the key when it is due
-- and goes on, since staging an encrypted page is refused until then.

-- | Why a write in a space being converted is refused.
conversionRefusal :: Conversion -> Text
conversionRefusal c =
  "This space's pages are being "
    <> (case c of Encrypting -> "encrypted"; Decrypting -> "decrypted")
    <> " in the browser of one of its administrators, so nothing else can be written in it until that is done. An administrator of the space who holds its key continues it from the space's settings."

-- | 'Conflict' while a conversion of a space of the chain runs: every
-- write in it but the conversion's own is refused.
requireNoConversion :: [Space] -> Tx ()
requireNoConversion c = for_ (asum (map (\s -> s.conversion) c)) (failWith . Conflict . conversionRefusal)

-- | Whether a page of a space is read and written by the encrypted routes
-- now ('Space.readsSealed'): asked of the database only while the space
-- is being converted.
pageReadsSealed :: Space -> PageId -> Tx Bool
pageReadsSealed s pid = case s.conversion of
  Nothing -> pure (isJust s.encryption)
  Just _ -> Space.readsSealed s <$> db (pageConverted pid)

-- | 'requirePlain' for a read of one page: in a space being converted, a
-- page that reads plain may be read plain; any other page of an encrypted
-- space is refused.
requirePlainPage :: Text -> [Space] -> PageId -> Tx ()
requirePlainPage what c pid = case lastMay c of
  Just s | isJust s.conversion -> whenM (pageReadsSealed s pid) (failWith (Conflict (encryptedRefusal what)))
  _ -> requirePlain what c

-- | 'Conflict' for a read of a page by the encrypted routes while it reads
-- plain, with the reason the browser knows ('E.notConvertedYet').
requireSealedPage :: Space -> PageId -> Tx ()
requireSealedPage s pid =
  unlessM (pageReadsSealed s pid) $
    failWith (Conflict (E.notConvertedYet <> ": read it by the plain routes."))

-- | The pages of a space, among those given, that read by the encrypted
-- routes now.
sealedAmong :: Space -> [a] -> (a -> PageId) -> Tx [a]
sealedAmong s xs idOf = case s.conversion of
  Nothing -> pure (if isJust s.encryption then xs else [])
  Just _ -> do
    done <- db (convertedIn s.id)
    pure [x | x <- xs, Space.readsSealed s (Set.member (idOf x) done)]

-- | A space and the spaces below it, each before the spaces below it.
subtreeOf :: SpaceId -> Tx [Space]
subtreeOf sid = do
  ctx <- ask
  let spaces = Map.elems ctx.spaces
      below p = sortOn (\x -> x.id) [x | x <- spaces, x.parent == Just p]
      walk x = x : concatMap walk (below x.id)
  pure (maybe [] walk (Map.lookup sid ctx.spaces))

-- | The space a running conversion of a space started from: the space of
-- its chain nearest the top that the conversion covers.
conversionRootOf :: Space -> Tx Space
conversionRootOf s = do
  c <- asks (`chainOf` s.id)
  pure (fromMaybe s (find (\x -> isJust x.conversion) c))

-- | What a conversion's every request asks of the caller, for each of the
-- spaces it covers: to administer the space, and to hold its current key,
-- as a renewal of the key asks ('rotateSpaceKeyTx'). Only those could
-- delete the space anyway, and only a browser that holds the key can make
-- or read what is staged. The caller and the space's key.
requireConverter :: Space -> Tx (UserId, KeyId)
requireConverter s = do
  (_, c) <- findSpace s.id
  requireAdminister c
  k <- requireEncrypted s
  me <- asks (\x -> x.author) >>= maybe (failWith Forbidden) pure
  holding <- holdsKey s.id k me
  unless holding $
    failWith (Conflict ("You do not hold the key of " <> s.name <> ": open the space in your browser first, or ask an administrator who holds it."))
  pure (me, k)

-- | Whether a user holds a grant of a space's key to their current public
-- key.
holdsKey :: SpaceId -> KeyId -> UserId -> Tx Bool
holdsKey sid k u = do
  grants <- db (grantsOfKey spaceKind sid.text k)
  mine <- db (currentPublicKeys [u])
  pure (any (\g -> g.recipient == u && Just g.recipientKeyId == (fst <$> Map.lookup u mine)) grants)

-- | Why a space, with the spaces below it, cannot be encrypted now by the
-- caller: every reason, so that the dialog says all of them at once. None
-- when it can.
encryptRefusals :: Space -> [Space] -> [Space] -> Tx [Text]
encryptRefusals s c tree = do
  ctx <- ask
  let plainTree = filter (\x -> isNothing x.encryption) tree
      ids = map (\x -> x.id) plainTree
      chainTo i = fromMaybe [] (ancestry (`Map.lookup` ctx.spaces) i)
      -- The spaces as they would be once the conversion starts: each plain
      -- one of the subtree encrypted, the space itself made private when it
      -- is at the top, as 'encryptSpaceTx' makes it.
      started =
        Map.union
          (Map.fromList [(x.id, x {encryption = Just (KeyId "converting"), sealed = x.sealed || (x.id == s.id && isNothing x.parent)}) | x <- plainTree])
          ctx.spaces
      startedChain i = fromMaybe [] (ancestry (`Map.lookup` started) i)
      ruleProblems = ordNub (mapMaybe (Permission.encryptionProblem . startedChain) ids)
  templates <- db (templatesIn ids)
  drafts <- db (draftsIn ids)
  web <- db (webAttachmentsIn ids)
  pageSpace <- Map.fromList . map (\p -> (p.id, p.space)) . concat <$> traverse (\x -> db (pageNodes x)) ids
  let spaceOfPage p = maybe "" (\i -> maybe "" (shownName ctx) (Map.lookup i ctx.spaces)) (Map.lookup p pageSpace)
      others = [p | (p, u) <- drafts, Just u /= ctx.author]
  let administers = [(x, canAdministerSpace ctx.principal ctx.grants (chainTo x.id)) | x <- plainTree]
  pure $
    ["This space is encrypted already." | isJust s.encryption]
      <> [shownName ctx x <> " is being converted already." | x <- c <> tree, isJust x.conversion]
      <> [shownName ctx x <> " is a personal space, or holds the personal spaces: those are not encrypted." | x <- tree, isJust x.owner || x.personalContainer]
      <> [shownName ctx x <> " is a blog: a blog's pages are read by everyone it is shown to, and an encrypted space's only by its members." | x <- plainTree, x.blog]
      <> [shownName ctx x <> " is public: make it private first." | x <- plainTree, x.public]
      <> [shownName ctx x <> " holds the wiki's front page." | x <- plainTree, Home.isHomeSpace ctx.server.homePage x.id]
      <> ["You do not administer " <> shownName ctx x <> "." | (x, False) <- administers]
      <> [spaceOfPage p <> " has templates, which an encrypted space has none of: make them ordinary pages first." | p <- take 1 templates]
      <> ["A page of " <> spaceOfPage p <> " has an attachment on the web: an encrypted page keeps its attachments' bytes. Upload the file instead." | p <- take 1 web]
      <> ["Someone else is in the middle of editing a page of " <> spaceOfPage p <> " (a draft kept on the server): the conversion would delete it. Ask them to save or discard it first." | p <- take 1 others]
      <> ruleProblems

-- | Why the encryption of a space, with the spaces below it, cannot be
-- turned off now by the caller. None when it can.
decryptRefusals :: Space -> [Space] -> [Space] -> Tx [Text]
decryptRefusals s c tree = do
  ctx <- ask
  me <- asks (\x -> x.author)
  let chainTo i = fromMaybe [] (ancestry (`Map.lookup` ctx.spaces) i)
  checked <- for tree $ \x -> case x.encryption of
    Nothing -> pure [shownName ctx x <> " is not encrypted."]
    Just k -> do
      holding <- maybe (pure False) (holdsKey x.id k) me
      pure $
        ["You do not administer " <> shownName ctx x <> "." | not (canAdministerSpace ctx.principal ctx.grants (chainTo x.id))]
          <> ["You do not hold the key of " <> shownName ctx x <> ": open it in your browser first." | not holding]
  pure $
    ["This space is not encrypted." | isNothing s.encryption]
      <> [shownName ctx x <> " is being converted already." | x <- c <> tree, isJust x.conversion]
      <> [ "Its parent space " <> p.name <> " is encrypted, and every space below an encrypted space is encrypted: turn the encryption of " <> p.name <> " off instead."
         | p <- take 1 (reverse (filter (\x -> isJust x.encryption) (fromMaybe [] (initMay c))))
         ]
      <> concat checked

-- | A space's name in what the caller is told, or what it is when the
-- caller may not view it: a conversion covers the spaces below its space,
-- some of which may be private from those who see that one.
shownName :: Ctx -> Space -> Text
shownName ctx x
  | canView ctx.principal ctx.grants (chainOf ctx x.id) = x.name
  | otherwise = "A space below it that you may not see"

-- | A space's conversion as one who may view it sees it: of the spaces it
-- covers, and their pages left, only those the caller may view.
conversionInfoTx :: SpaceId -> Tx E.ConversionInfo
conversionInfoTx sid = do
  ctx <- ask
  (s, c) <- findSpace sid
  requireView c
  let viewable x = canView ctx.principal ctx.grants (chainOf ctx x.id)
  case s.conversion of
    Just running -> do
      root <- conversionRootOf s
      covered <- filter (\x -> isJust x.conversion) <$> subtreeOf root.id
      left <- db (unconvertedIn (map (\x -> x.id) (filter viewable covered)))
      pure E.ConversionInfo {running = Just running, root = (\x -> x.id) <$> mfilter viewable (Just root), spaces = map (\x -> x.id) (filter viewable covered), left = [E.ConversionPage {page, space} | (page, space) <- left], cannotEncrypt = [], cannotDecrypt = [], nothingWritten = False}
    Nothing -> do
      tree <- subtreeOf sid
      enc <- if isJust s.encryption then pure [] else encryptRefusals s c tree
      dec <- if isJust s.encryption then decryptRefusals s c tree else pure []
      untouched <- if isJust s.encryption || length tree > 1 then pure False else isJust <$> nothingWrittenIn s
      pure
        E.ConversionInfo
          { running = Nothing
          , root = Nothing
          , spaces = map (\x -> x.id) (filter viewable (if isJust s.encryption then tree else filter (\x -> isNothing x.encryption) tree))
          , left = []
          , cannotEncrypt = enc
          , cannotDecrypt = dec
          , nothingWritten = untouched
          }

-- | Start encrypting a space that has pages, and the plain spaces below
-- it, each with its new key, sealed to the caller ('E.StartEncrypting').
startEncryptingTx :: SpaceId -> E.StartEncrypting -> Tx E.ConversionInfo
startEncryptingTx sid req = do
  (s, c) <- findSpace sid
  requireAdminister c
  tree <- subtreeOf sid
  refusals <- encryptRefusals s c tree
  unless (null refusals) $ failWith (Conflict (T.unwords refusals))
  me <- asks (\x -> x.author) >>= maybe (failWith Forbidden) pure
  let plainTree = filter (\x -> isNothing x.encryption) tree
      sent = Map.fromList [(k.space, k) | k <- req.keys]
  -- A page that could not be encrypted would stop the conversion halfway:
  -- such a page is refused now, before anything starts, by its address.
  tooLarge <- db (oversizedIn (map (\x -> x.id) plainTree))
  unless (null tooLarge) $ do
    named <- for tooLarge $ \(pid, what) -> do
      p <- findNode pid
      (x, _) <- findSpace p.space
      pure ("The page " <> slugText p.slug <> " of " <> x.name <> " has " <> what <> ".")
    failWith (Conflict (T.unwords (named <> ["Shorten it, or delete the version, and encrypt the space then."])))
  unless (length req.keys == Map.size sent && Map.keysSet sent == Set.fromList (map (\x -> x.id) plainTree)) $
    failWith (Conflict "The spaces below this one have changed since the keys were made: open the space again.")
  unless (length (ordNub (map (\k -> k.keyId) req.keys)) == length req.keys) $
    invalid "Each space needs a key of its own."
  keys <- db (currentPublicKeys [me])
  for_ req.keys $ \k -> do
    checkGrantParts k.keyId k.grant.enc k.grant.sealed
    unless (k.grant.recipient == me && (fst <$> Map.lookup me keys) == Just k.grant.recipientKeyId) $
      invalid "The spaces' keys must be sealed to your own current public key: open your keys in your account's security first."
  time <- now
  for_ plainTree $ \x -> for_ (Map.lookup x.id sent) $ \k -> do
    db $ do
      setSpaceKey x.id k.keyId
      insertGrant spaceKind x.id.text time KeyGrant {keyId = k.keyId, recipient = me, recipientKeyId = k.grant.recipientKeyId, enc = k.grant.enc, sealed = k.grant.sealed}
      clearConverted x.id
      setConversion x.id (Just Encrypting)
    -- A top-level space is made private with it, as 'encryptSpaceTx'
    -- makes it, so that a later move under another space keeps it so.
    when (x.id == sid && isNothing x.parent && not x.sealed) $
      db (updateSpace x {sealed = True})
  requireEncryptionRule sid
  left <- db (unconvertedIn (map (\x -> x.id) plainTree))
  record "space.encryption-started" (spaceSubject s) [("spaces", show (length plainTree)), ("pages", show (length left))]
  pure E.ConversionInfo {running = Just Encrypting, root = Just sid, spaces = map (\x -> x.id) plainTree, left = [E.ConversionPage {page, space} | (page, space) <- left], cannotEncrypt = [], cannotDecrypt = [], nothingWritten = False}

-- | Start turning the encryption of a space, and of the spaces below it,
-- off.
startDecryptingTx :: SpaceId -> Tx E.ConversionInfo
startDecryptingTx sid = do
  (s, c) <- findSpace sid
  requireAdminister c
  tree <- subtreeOf sid
  refusals <- decryptRefusals s c tree
  unless (null refusals) $ failWith (Conflict (T.unwords refusals))
  for_ tree $ \x -> db (clearConverted x.id >> setConversion x.id (Just Decrypting))
  left <- db (unconvertedIn (map (\x -> x.id) tree))
  record "space.decryption-started" (spaceSubject s) [("spaces", show (length tree)), ("pages", show (length left))]
  pure E.ConversionInfo {running = Just Decrypting, root = Just sid, spaces = map (\x -> x.id) tree, left = [E.ConversionPage {page, space} | (page, space) <- left], cannotEncrypt = [], cannotDecrypt = [], nothingWritten = False}

-- | A page a conversion stages or commits, checked: its space is being
-- converted this way, the page is not converted yet, and the caller may
-- convert it ('requireConverter'). The page, its space and its chain, the
-- caller and the space's key.
convertingPage :: PageId -> Conversion -> Tx (PageNode, Space, [Space], UserId, KeyId)
convertingPage pid way = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireView c
  unless (s.conversion == Just way) $
    failWith (Conflict ("This page's space is not being " <> (case way of Encrypting -> "encrypted"; Decrypting -> "decrypted") <> " now."))
  (me, k) <- requireConverter s
  whenM (db (pageConverted pid)) $ failWith (Conflict "This page is converted already.")
  pure (p, s, c, me, k)

-- | 'checkSealedText' for a ciphertext staged by a conversion, which names
-- any key of the page's: one of before a renewal of the space's key made
-- while the page was staged stays valid.
checkStagedText :: [PageKey] -> KeyId -> Sealed -> Int -> Tx ()
checkStagedText keys k s most = do
  unless (any (\x -> x.keyId == k) keys) $
    invalid "This ciphertext names no key of the page's."
  unless (holdsBytes nonceBytes s.nonce.text && boundedBytes 16 most s.ciphertext.text) $
    invalid "This is not a ciphertext this wiki keeps: a nonce or a text is not of its length."

-- | Stage ciphertexts of a page while its space is encrypted
-- ('E.StagedSealed').
stageSealedTx :: PageId -> E.StagedSealed -> Tx ()
stageSealedTx pid req = do
  (_, s, c, _, k) <- convertingPage pid Encrypting
  requireNoRenewal s.id c k
  times <- db (pageVersionTimes pid)
  for_ req.pageKey $ \pk -> do
    unless (holdsBytes keyIdBytes pk.keyId.text && holdsBytes nonceBytes pk.wrapped.nonce.text && holdsBytes sealedKeyBytes pk.wrapped.key.text) $
      invalid "This is not a key this wiki keeps: a part of the page's key is not of its length."
    unless (pk.spaceKeyId == k) $
      failWith (Conflict "The space's key has changed since: open the space again.")
    -- A key comes with the page's latest version, so that no page has a
    -- key without one, which a renewal of the space's key reads.
    unless (any (\v -> Just (micro v.updatedAt) == lastMay times) req.versions) $
      invalid "A page's key is staged with its latest version."
    db (dropStagedSealed pid >> insertPageKey pid pk)
  keys <- db (loadPageKeys pid)
  when (null keys) $ invalid "This page's key is staged first, with its latest version."
  let known = Set.fromList times
  for_ req.versions $ \v -> do
    unless (Set.member (micro v.updatedAt) known) $ invalid "This is not a version of the page."
    when (isNothing v.content.chain) $ invalid "A version is staged in the chained format."
    key <- maybe (invalid "This version names no key of the page's.") pure (find (\x -> x.keyId == v.content.keyId) keys)
    checkSealedParts key v.content
    db (replaceSealedVersion pid v.updatedAt v.content)
  threads <- Map.fromList <$> db (pageThreads pid)
  for_ req.threads $ \t -> do
    quoted <- maybe (invalid "This is not a thread of the page.") pure (Map.lookup t.id threads)
    unless (quoted == isJust t.anchor) $ invalid "A thread about a quote is staged with its quote, and one about the whole page without."
    for_ t.anchor $ \a -> checkStagedText keys a.keyId a.anchor maxAnchorCiphertext
    db (replaceSealedThread t.id (maybe (fromMaybe k (head (map (\x -> x.keyId) keys))) (\a -> a.keyId) t.anchor) t.anchor)
  comments <- Set.fromList . map fst <$> db (pageComments pid)
  for_ req.comments $ \x -> do
    unless (Set.member x.id comments) $ invalid "This is not a comment of the page."
    checkStagedText keys x.content.keyId x.content.body maxCommentCiphertext
    unless (holdsBytes keyIdBytes x.content.tag.text) $ invalid "This is not a comment this wiki keeps: its tag is not of its length."
    db (replaceSealedComment x.id x.content)
  attachments <- db (pageAttachmentIds pid)
  for_ req.attachments $ \a -> do
    unless (a.id `elem` attachments) $ invalid "This is not an attachment of the page."
    checkStagedText keys a.meta.keyId a.meta.meta maxMetaCiphertext
    unless (holdsBytes nonceBytes a.meta.bytesNonce.text) $ invalid "This is not an attachment this wiki keeps: its nonce is not of its length."
    db (replaceSealedAttachment a.id a.meta)

-- | Stage a page's texts, decrypted, while its space's encryption is
-- turned off ('E.StagedPlain').
stagePlainTx :: PageId -> E.StagedPlain -> Tx ()
stagePlainTx pid req = do
  _ <- convertingPage pid Decrypting
  known <- Set.fromList <$> db (pageVersionTimes pid)
  for_ req.versions $ \v -> do
    unless (Set.member (micro v.updatedAt) known) $ invalid "This is not a version of the page."
    -- As the encrypted space held it: a conversion refuses none of what
    -- is there, which nothing else could turn plain.
    db (upsertStagedPlain (stagedRow pid "version" (versionItem v.updatedAt) (Just (micro v.updatedAt)) (Just v.title) (Just v.body) Nothing Nothing))
  anchors <- db (loadSealedAnchors pid)
  for_ req.threads $ \t -> do
    (anchored, _) <- maybe (invalid "This is not a thread of the page.") pure (Map.lookup t.id anchors)
    unless (anchored == isJust t.anchor) $ invalid "A thread about a quote is staged with its quote, and one about the whole page without."
    db (upsertStagedPlain (stagedRow pid "thread" t.id.text Nothing Nothing Nothing t.anchor Nothing))
  comments <- Set.fromList . map fst <$> db (pageComments pid)
  for_ req.comments $ \x -> do
    unless (Set.member x.id comments) $ invalid "This is not a comment of the page."
    db (upsertStagedPlain (stagedRow pid "comment" x.id.text Nothing Nothing (Just x.body) Nothing Nothing))
  attachments <- db (pageAttachmentIds pid)
  for_ req.attachments $ \a -> do
    unless (a.id `elem` attachments) $ invalid "This is not an attachment of the page."
    n <- either invalid pure (parseFileName a.name)
    db (upsertStagedPlain (stagedRow pid "attachment" a.id.text Nothing Nothing Nothing Nothing (Just (n.text, (uploadedMimeType a.mediaType).text))))

-- | A row of @staged_plain@ for an item of a page: a version's time,
-- title and text, a comment's text, a thread's quote, an attachment's name
-- and media type, as the item has them.
stagedRow :: PageId -> Text -> Text -> Maybe UTCTime -> Maybe Text -> Maybe Text -> Maybe Anchor -> Maybe (Text, Text) -> StagedPlain Identity
stagedRow pid kind item updated_at title body anchor file =
  StagedPlainRow
    { page_id = pid.text
    , kind
    , item
    , updated_at
    , title
    , body
    , quote = (\a -> a.exact) <$> anchor
    , prefix = (\a -> a.prefix) <$> anchor
    , suffix = (\a -> a.suffix) <$> anchor
    , name = fst <$> file
    , media_type = snd <$> file
    , blob = Nothing
    }

-- | How a version is named among the staged items: its time.
versionItem :: UTCTime -> Text
versionItem at = toS (iso8601Show (micro at))

-- | Stage an attachment's bytes, of this size, which the last argument
-- stores in the blob directory given to it: encrypted while its space is
-- encrypted, decrypted while its encryption is turned off. Its name and
-- media type are staged first.
stageBytesTx :: PageId -> AttachmentId -> Integer -> (FilePath -> IO BlobId) -> Tx ()
stageBytesTx pid aid size store = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireView c
  way <- maybe (failWith (Conflict "This page's space is not being converted now.")) pure s.conversion
  _ <- convertingPage pid way
  dir <- asks (\x -> x.blobs)
  case way of
    Encrypting -> do
      metas <- db (loadSealedMetas pid)
      unless (Map.member aid metas) $ invalid "An attachment's name and media type are staged before its bytes."
      when (size > fromIntegral maxAttachmentSize + 16) $
        invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB.")
      blob <- liftIO (store dir)
      db (setSealedStagedBlob aid blob)
    Decrypting -> do
      rows <- db (loadStagedPlain pid)
      unless (any (\r -> r.kind == "attachment" && r.item == aid.text) rows) $
        invalid "An attachment's name and media type are staged before its bytes."
      when (size > fromIntegral maxAttachmentSize) $
        invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB.")
      blob <- liftIO (store dir)
      db (setPlainStagedBlob pid aid blob)

-- | What is staged of a page, for the browser to read back before it
-- commits it.
stagedPageTx :: PageId -> Tx E.StagedPage
stagedPageTx pid = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireView c
  way <- maybe (failWith (Conflict "This page's space is not being converted now.")) pure s.conversion
  _ <- convertingPage pid way
  stagedPageOf pid way

-- | What is staged of a page, with the digest that names it.
stagedPageOf :: PageId -> Conversion -> Tx E.StagedPage
stagedPageOf pid way = do
  keys <- db (loadPageKeys pid)
  (sealed, plain, blobs) <- case way of
    Encrypting -> do
      rows <- db (loadStagedSealed pid)
      pure
        ( E.StagedSealed
            { pageKey = head keys
            , versions = [E.StagedVersion {updatedAt, content} | (updatedAt, content) <- rows.versions]
            , threads = [E.StagedAnchor {id = t, anchor} | (t, (_, anchor)) <- Map.toList rows.anchors]
            , comments = [E.StagedComment {id = x, content} | (x, content) <- Map.toList rows.comments]
            , attachments = [E.StagedMeta {id = a, meta} | (a, (meta, _)) <- Map.toList rows.metas]
            }
        , noPlain
        , [(a, b) | (a, (_, Just b)) <- Map.toList rows.metas]
        )
    Decrypting -> do
      rows <- db (loadStagedPlain pid)
      pure
        ( noSealed
        , E.StagedPlain
            { versions = sortOn (\v -> v.updatedAt) [E.PlainVersion {updatedAt = at, title = fromMaybe "" r.title, body = fromMaybe "" r.body} | r <- rows, r.kind == "version", Just at <- [r.updated_at]]
            , threads = [E.PlainAnchor {id = CommentThreadId r.item, anchor = Anchor <$> r.quote <*> Just (fromMaybe "" r.prefix) <*> Just (fromMaybe "" r.suffix)} | r <- rows, r.kind == "thread"]
            , comments = [E.PlainComment {id = CommentId r.item, body = fromMaybe "" r.body} | r <- rows, r.kind == "comment"]
            , attachments = [E.PlainMeta {id = AttachmentId r.item, name = fromMaybe "" r.name, mediaType = fromMaybe "" r.media_type} | r <- rows, r.kind == "attachment"]
            }
        , [(AttachmentId r.item, BlobId b) | r <- rows, r.kind == "attachment", Just b <- [r.blob]]
        )
  let unnamed = E.StagedPage {digest = "", pageKeys = keys, sealed, plain, blobs}
  pure E.StagedPage {digest = decodeUtf8 (convertToBase Base16 (sha256 (BSL.toStrict (encode unnamed))) :: ByteString), pageKeys = keys, sealed, plain, blobs}
  where
    noSealed = E.StagedSealed {pageKey = Nothing, versions = [], threads = [], comments = [], attachments = []}
    noPlain = E.StagedPlain {versions = [], threads = [], comments = [], attachments = []}

-- | Put what is staged of a page in place, in this transaction, if it is
-- what the browser read back ('E.ConversionCommit''s digest) and holds
-- everything of the page; and end the conversion with the last page.
--
-- While a space is encrypted, the page's plain title, text and search
-- text, and every version's, are blanked, and its links forgotten; it gets
-- a new random slug (its address spelled its title, and @/l/<id>@ keeps
-- leading to it); its threads' quotes and its comments' texts are
-- blanked; each attachment's row takes the staged blob of its encrypted
-- bytes and its id as its name; its drafts go; and its notifications are
-- made those of an encrypted page. While a space's encryption is turned
-- off, the page's plain columns are written from what is staged, with its
-- search text and links, and its ciphertexts and keys are deleted; it
-- keeps its random slug.
commitConvertedTx :: PageId -> E.ConversionCommit -> Tx (E.ConversionProgress, Bool)
commitConvertedTx pid commit = do
  p <- findNode pid
  (s, c) <- findSpace p.space
  requireView c
  way <- maybe (failWith (Conflict "This page's space is not being converted now.")) pure s.conversion
  (_, _, _, _, k) <- convertingPage pid way
  staged <- stagedPageOf pid way
  unless (staged.digest == commit.digest) $
    failWith (Conflict "What is staged of this page has changed since it was read back: it is read back again before its commit.")
  page <- findPage pid
  times <- db (pageVersionTimes pid)
  threads <- db (pageThreads pid)
  comments <- map fst <$> db (pageComments pid)
  attachments <- db (pageAttachmentIds pid)
  dir <- asks (\x -> x.blobs)
  let blobOf a = List.lookup a staged.blobs
      sizeOf b = maybe (pure 0) (\f -> fromIntegral <$> liftIO (getFileSize f)) (blobFile dir b)
      incomplete what = failWith (Conflict ("Not everything of this page is staged (" <> what <> "): it is staged again before its commit."))
  case way of
    Encrypting -> do
      requireNoRenewal s.id c k
      let versions = staged.sealed.versions
          chained = and (List.zipWith3 (\n v before -> v.content.chain == Just CE.Chain {number = n, previous = before}) [1 ..] versions (Nothing : map (\v -> Just v.content.tag) versions))
      when (null staged.pageKeys) $ incomplete "its key"
      unless (map (\v -> micro v.updatedAt) versions == map micro times) $ incomplete "its versions"
      unless chained $ invalid "The versions staged are not one chain from the first."
      unless (sort [t.id | t <- staged.sealed.threads] == sort (map fst threads) && and [maybe False (\t -> isJust t.anchor == quoted) (find (\t -> t.id == tid) staged.sealed.threads) | (tid, quoted) <- threads]) $
        incomplete "its threads"
      unless (sort [x.id | x <- staged.sealed.comments] == sort comments) $ incomplete "its comments"
      unless (all (isJust . blobOf) attachments && length staged.sealed.attachments == length attachments) $ incomplete "its attachments"
      random <- T.take 12 . T.filter (/= '-') <$> newId
      siblings <- db (childPages p.space p.parent)
      subtree <- db (subtreeIds pid)
      for_ attachments $ \a -> for_ (blobOf a) $ \b -> do
        size <- sizeOf b
        db (setAttachmentFile a a.text "application/octet-stream" size b >> clearSealedStagedBlob a)
      db $ do
        for_ times $ \at -> setVersionText pid at "" ""
        updatePageText pid "" "" page.updatedAt
        movePages pid p.space p.parent (freshSlug (isJust . findChild (filter (\x -> x.id /= pid) siblings) p.parent) (fallbackSlug random)) p.position subtree
        for_ threads $ \(tid, quoted) -> setThreadQuote tid (if quoted then Just ("", "", "") else Nothing)
        for_ comments $ \x -> setCommentBody x ""
        deletePageDrafts pid
        hideNotificationsOf pid encryptedTitle
        setPageConverted pid
    Decrypting -> do
      let plain = staged.plain
      unless (map (\v -> micro v.updatedAt) plain.versions == map micro times) $ incomplete "its versions"
      unless (sort [t.id | t <- plain.threads] == sort (map fst threads)) $ incomplete "its threads"
      unless (sort [x.id | x <- plain.comments] == sort comments) $ incomplete "its comments"
      unless (all (isJust . blobOf) attachments && length plain.attachments == length attachments) $ incomplete "its attachments"
      latest <- maybe (incomplete "its latest version") pure (lastMay plain.versions)
      for_ attachments $ \a -> for_ ((,) <$> blobOf a <*> find (\m -> m.id == a) plain.attachments) $ \(b, m) -> do
        size <- sizeOf b
        db (setAttachmentFile a m.name m.mediaType size b)
      db $ do
        for_ plain.versions $ \v -> setVersionText pid v.updatedAt v.title v.body
        updatePageText pid latest.title latest.body page.updatedAt
        for_ plain.threads $ \t -> setThreadQuote t.id ((\a -> (a.exact, a.prefix, a.suffix)) <$> t.anchor)
        for_ plain.comments $ \x -> setCommentBody x.id x.body
        dropSealedOf pid
        dropStagedPlain pid
        setPageConverted pid
  pagesMoved
  ended <- endIfConverted s
  pure (E.ConversionProgress {left = ended}, ended == 0)

-- | End the conversion a space is in when it has no page left: each space
-- it covers is unmarked, and, once its encryption is off, made plain, its
-- key's grants deleted. The pages left.
endIfConverted :: Space -> Tx Int
endIfConverted s = do
  root <- conversionRootOf s
  covered <- filter (\x -> isJust x.conversion) <$> subtreeOf root.id
  endIfDone (fromMaybe Encrypting root.conversion) root covered

-- | 'endIfConverted' for a conversion going this way over these spaces,
-- from that root: what a conversion turned back ends with, whose spaces
-- the transaction's context still shows going the other way.
endIfDone :: Conversion -> Space -> [Space] -> Tx Int
endIfDone way root covered = do
  left <- db (unconvertedIn (map (\x -> x.id) covered))
  when (null left) $ do
    for_ covered $ \x -> db $ do
      setConversion x.id Nothing
      clearConverted x.id
      when (way == Decrypting) $ do
        clearSpaceKey x.id
        deleteGrantsOfSpace x.id
    case way of
      Decrypting -> record "space.decrypted" (spaceSubject root) [("spaces", show (length covered))]
      Encrypting -> record "space.encrypted" (spaceSubject root) [("spaces", show (length covered))]
  pure (length left)

-- | Turn a conversion round ("Stop and turn back"): from now on it goes the
-- other way, over the pages converted so far, and the space ends as it
-- began. A page converted so far is converted back; a page not reached
-- yet stays as it is, and what was staged of it is dropped. A page
-- encrypted and turned back keeps the random address it got, since its
-- old one is not kept. Asked of an administrator of each of the spaces
-- who holds its key ('requireConverter'), at any point of the
-- conversion: a conversion that cannot go on can always be turned round.
-- | The setting is kept for an encrypted space only: the browser asks
-- before it decrypts, and a plain space has nothing to decrypt. A space
-- under one that asks is covered by it ('Wiki.Core.Space.gateOf').
setSpaceEntryTx :: SpaceId -> Space.Entry -> Tx Space
setSpaceEntryTx sid e = do
  (s, c) <- findSpace sid
  requireAdminister c
  requireNoConversion c
  when (isNothing s.encryption) (failWith (Conflict "Only an encrypted space asks for a passkey or the password each time it is opened."))
  when (s.entry /= e) $ do
    db (setEntry sid e)
    record "space.entry" (spaceSubject s) [("entry", Space.entryName e)]
  pure (Space.withEntry e s)

reverseConversionTx :: SpaceId -> Tx E.ConversionInfo
reverseConversionTx sid = do
  (s, c) <- findSpace sid
  requireView c
  way <- maybe (failWith (Conflict "No conversion of this space runs.")) pure s.conversion
  root <- conversionRootOf s
  covered <- filter (\x -> isJust x.conversion) <$> subtreeOf root.id
  for_ covered requireConverter
  let back = case way of Encrypting -> Decrypting; Decrypting -> Encrypting
  for_ covered $ \x -> do
    pages <- db (pageNodes x.id)
    done <- db (convertedIn x.id)
    for_ [p | p <- pages, Set.notMember p.id done] $ \p ->
      db (case way of Encrypting -> dropStagedSealed p.id; Decrypting -> dropStagedPlain p.id)
    db (flipConverted x.id >> setConversion x.id (Just back))
  record "space.conversion-reversed" (spaceSubject root) [("was", Space.conversionName way), ("spaces", show (length covered))]
  left <- db (unconvertedIn (map (\x -> x.id) covered))
  _ <- endIfDone back root covered
  pure E.ConversionInfo {running = if null left then Nothing else Just back, root = Just root.id, spaces = map (\x -> x.id) covered, left = [E.ConversionPage {page, space} | (page, space) <- left], cannotEncrypt = [], cannotDecrypt = [], nothingWritten = False}

--------------------------------------------------------------------------------
-- Comments and attachments in an encrypted space

-- | A page of an encrypted space for a write of a comment or an
-- attachment: its chain, its space's current key, checked not due for
-- renewal, and the page's current key, which what is written is encrypted
-- with.
sealedTarget :: PageId -> Tx ([Space], PageKey)
sealedTarget pid = do
  p <- findNode pid
  c <- chainOfPage p
  s <- fst <$> findSpace p.space
  k <- requireEncrypted s
  requireSealedPage s pid
  requireNoRenewal p.space c k
  pk <- db (loadPageKey pid) >>= maybe (failWith (Conflict "This page has no key: it is not a page of an encrypted space.")) pure
  pure (c, pk)

-- | 'Invalid' unless an id the browser chose is a UUID.
requireUuid :: Text -> Text -> Tx ()
requireUuid what i = when (isNothing (UUID.fromText i)) (invalid (what <> "'s id is a UUID."))

-- | 'Invalid' unless a ciphertext is encrypted with the page's current key
-- and is of its lengths.
checkSealedText :: PageKey -> KeyId -> Sealed -> Int -> Tx ()
checkSealedText pk k s most = do
  unless (k == pk.keyId) $
    failWith (Conflict "This page's key has changed since it was opened: the space's key was renewed. Open the page again.")
  unless (holdsBytes nonceBytes s.nonce.text && boundedBytes 16 most s.ciphertext.text) $
    invalid "This is not a ciphertext this wiki keeps: a nonce or a text is not of its length."

-- | A thread of a page of an encrypted space as the browser reads it: its
-- rows, its anchor and its comments' texts, encrypted.
sealedThreadOf :: Map CommentThreadId (Bool, Maybe SealedAnchor) -> Map CommentId SealedComment -> Thread -> Maybe SealedThread
sealedThreadOf anchors texts t = do
  (anchored, anchor) <- Map.lookup t.id anchors
  pure
    SealedThread
      { id = t.id
      , page = t.page
      , anchored
      , anchor
      , resolved = t.resolved
      , createdAt = t.createdAt
      , comments = [SealedCommentInfo {id = x.id, thread = t.id, author = x.author, createdAt = x.createdAt, editedAt = x.editedAt, content} | x <- t.comments, Just content <- [Map.lookup x.id texts]]
      }

-- | The threads of a page of an encrypted space, encrypted.
sealedThreadsTx :: PageId -> Tx [SealedThread]
sealedThreadsTx pid = do
  (c, ts) <- discussionOf pid
  s <- maybe (failWith (Conflict "This space is not encrypted.")) pure (mfilter (\x -> isJust x.encryption) (lastMay c))
  requireSealedPage s pid
  anchors <- db (loadSealedAnchors pid)
  texts <- db (loadSealedComments pid)
  pure (mapMaybe (sealedThreadOf anchors texts) ts)

-- | A thread of a page of an encrypted space, read again: the result of a
-- write.
sealedThreadNow :: PageId -> CommentThreadId -> Tx SealedThread
sealedThreadNow pid tid = sealedThreadsTx pid >>= maybe (failWith NotFound) pure . find (\t -> t.id == tid)

-- | A new thread of a page of an encrypted space, with its first comment.
-- Those told of it are told by the page's id, with no title, excerpt or
-- mention, which the server cannot read; the page's live channel hears
-- that its threads changed, and nothing of them.
openSealedThreadTx :: PageId -> NewSealedThread -> Tx (SealedThread, PageId, PageEvent)
openSealedThreadTx pid new = do
  (c, _) <- discussionOf pid
  u <- commenter c
  (_, pk) <- sealedTarget pid
  requireUuid "A thread" new.id.text
  requireUuid "A comment" new.comment.id.text
  db (Comments.threadPage new.id) >>= traverse_ (\_ -> failWith (Conflict "A thread with this id exists already."))
  whenM (db (Comments.commentExists new.comment.id)) (failWith (Conflict "A comment with this id exists already."))
  for_ new.anchor $ \a -> checkSealedText pk a.keyId a.anchor maxAnchorCiphertext
  checkSealedComment pk new.comment.content
  time <- now
  db $ do
    -- The thread's row has an empty quote when the thread has one, which
    -- is encrypted beside it: a thread about a quote may be resolved, and
    -- the row says so.
    Comments.insertThread new.id pid (Anchor {exact = "", prefix = "", suffix = ""} <$ new.anchor) time
    insertSealedThread new.id pk.keyId new.anchor
    Comments.insertComment new.comment.id new.id u "" time
    insertSealedComment new.comment.id new.comment.content
  t <- sealedThreadNow pid new.id
  p <- findNode pid
  tellTx pid p.space encryptedTitle (Just new.id) "" (CommentedIn new.id [u]) mempty
  pure (t, pid, ThreadsChanged)

-- | 'checkSealedText' for a comment, with its tag.
checkSealedComment :: PageKey -> SealedComment -> Tx ()
checkSealedComment pk x = do
  checkSealedText pk x.keyId x.body maxCommentCiphertext
  unless (holdsBytes keyIdBytes x.tag.text) $
    invalid "This is not a comment this wiki keeps: its tag is not of its length."

-- | A reply in a thread of a page of an encrypted space.
sealedReplyTx :: PageId -> CommentThreadId -> NewSealedComment -> Tx (SealedCommentInfo, PageId, PageEvent)
sealedReplyTx pid tid new = do
  (c, ts) <- discussionOf pid
  before <- threadIn ts tid
  u <- commenter c
  (_, pk) <- sealedTarget pid
  requireUuid "A comment" new.id.text
  whenM (db (Comments.commentExists new.id)) (failWith (Conflict "A comment with this id exists already."))
  checkSealedComment pk new.content
  time <- now
  db $ do
    Comments.insertComment new.id tid u "" time
    insertSealedComment new.id new.content
  made <- sealedThreadNow pid tid >>= maybe (failWith NotFound) pure . find (\x -> x.id == new.id) . (\t -> t.comments)
  p <- findNode pid
  tellTx pid p.space encryptedTitle (Just tid) "" (CommentedIn tid (ordNub (map (\x -> x.author.id) before.comments <> [u]))) mempty
  pure (made, pid, ThreadsChanged)

-- | A comment of a page of an encrypted space written again. Nobody is told:
-- an edit tells only of the mentions it adds, which the server cannot read.
sealedEditCommentTx :: PageId -> CommentThreadId -> CommentId -> SealedCommentEdit -> Tx (SealedCommentInfo, PageId, PageEvent)
sealedEditCommentTx pid tid cid edit = do
  (_, ts) <- discussionOf pid
  old <- threadIn ts tid >>= (`commentIn` cid)
  ctx <- ask
  require (mayEditComment ctx.principal old)
  findNode pid >>= chainOfPage >>= requireNoConversion
  (_, pk) <- sealedTarget pid
  checkSealedComment pk edit.content
  time <- now
  db $ do
    Comments.updateCommentBody cid "" time
    replaceSealedComment cid edit.content
  edited <- sealedThreadNow pid tid >>= maybe (failWith NotFound) pure . find (\x -> x.id == cid) . (\t -> t.comments)
  pure (edited, pid, ThreadsChanged)

-- | An attachment of a page of an encrypted space: its bytes, encrypted in
-- the browser, of this size, which the last argument stores in the blob
-- directory given to it; its name and media type, encrypted. Its row is
-- named by its id and of the type @application/octet-stream@: nothing of
-- the file is in it but its size. Each upload is encrypted under a new
-- nonce, so the blob store, which keeps one file for identical bytes,
-- keeps two uploads of one file as two files. The attachment it replaces
-- (one of the same name, which only the browser can tell) goes, if it is
-- one of the page's.
uploadSealedAttachmentTx :: PageId -> SealedUpload -> Integer -> (FilePath -> IO BlobId) -> Tx SealedAttachment
uploadSealedAttachmentTx pid up size store = do
  p <- findNode pid
  c <- chainOfPage p
  requireAttachTo c pid
  (_, pk) <- sealedTarget pid
  requireUuid "An attachment" up.id.text
  checkSealedText pk up.meta.keyId up.meta.meta maxMetaCiphertext
  unless (holdsBytes nonceBytes up.meta.bytesNonce.text) $
    invalid "This is not an attachment this wiki keeps: its nonce is not of its length."
  when (size > fromIntegral maxAttachmentSize + 16) $
    invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB.")
  page <- findPage pid
  when (any (\a -> a.id == up.id) page.attachments) $ failWith (Conflict "An attachment with this id exists already.")
  for_ up.replaces $ \old ->
    unless (any (\a -> a.id == old) page.attachments) $ invalid "The attachment replaced is not one of the page's."
  dir <- asks (\x -> x.blobs)
  blob <- liftIO (store dir)
  name <- either invalid pure (parseFileName up.id.text)
  let attachment = Attachment {id = up.id, name, mediaType = uploadedMimeType "application/octet-stream", size = fromIntegral size, source = SourceBlob blob}
  db $ do
    traverse_ deleteAttachmentRow up.replaces
    replaceAttachment pid attachment
    insertSealedAttachment up.id up.meta
  pure SealedAttachment {id = up.id, size = fromIntegral size, meta = up.meta}

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
        location = PageLocation {space = map (\x -> x.slug) chain, page = fromMaybe [] (pathIn ctx.spaces sid (`Map.lookup` nodes) pid)}
        actorAuthor = maybe (namedAuthor actor actor.text) authorOf ctx.user
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
    -- GHC 9.10 and 9.12 need this signature to infer the types; GHC 9.14 does not.
    go :: Map PageId PageNode -> PageId -> Tx (Map PageId PageNode)
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
          let path = pathIn ctx.spaces p.space (`Map.lookup` nodes) p.id
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
            [ withLocation (PageLocation (map (\x -> x.slug) (chainOf ctx p.space)) <$> pathIn ctx.spaces p.space (`Map.lookup` Map.findWithDefault mempty p.space known) p.id) n
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

-- | The address of the user's feed of notifications ("Wiki.Server.Feed"),
-- if they have made one: the feed's path with their secret.
feedAddressTx :: Tx FeedAddress
feedAddressTx = do
  u <- notified
  FeedAddress . fmap feedAddressOf <$> db (loadFeedToken u)

-- | Make the user's feed address, or a new one in place of the old: a
-- fresh secret, 32 random bytes as base64url, which the user keeps; the
-- old address answers nothing from now on.
renewFeedAddressTx :: Tx FeedAddress
renewFeedAddressTx = do
  u <- notified
  secret <- liftIO newFeedToken
  db (storeFeedToken u secret)
  pure FeedAddress {address = Just (feedAddressOf secret)}

-- | A secret for a feed of notifications: 32 random bytes as base64url,
-- which an address can carry as it is.
newFeedToken :: IO Text
newFeedToken = decodeUtf8 . convertToBase Base64URLUnpadded <$> (getRandomBytes 32 :: IO ByteString)

-- | The users with these logins who may sign in, for a caller who is
-- signed in. Only those logins are read, through the index on a user's
-- login, not every user.
mentionableTx :: [Text] -> Tx (Map Text Author)
mentionableTx logins =
  asks (\x -> x.user) >>= \case
    Just _ | not (null logins) -> do
      users <- db (loadActiveUsersByLogin logins)
      pure (Map.fromList [(u.login.text, authorOf u) | u <- users])
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
  feedAddress = run Reads feedAddressTx
  renewFeedAddress = run Writes renewFeedAddressTx
  unsubscribe token =
    run Writes (db (Notifications.unsubscribeUser token) >>= \found -> unless found (failWith NotFound))

--------------------------------------------------------------------------------
-- Stars

-- | The user's starred pages that exist and that they may view, in the
-- order they were starred, each with its title and where it is now. A
-- user has at most 'maxStars', each read by its id, so the cost does not
-- grow with the wiki.
starredTx :: Tx [StarredPage]
starredTx = do
  u <- notified
  pids <- db (Stars.loadStars u)
  catMaybes <$> traverse starredPageTx pids

-- | One starred page as the list shows it, if it is there and the user may
-- view it. A page the user may not view is left out without an error, and
-- its star is kept.
starredPageTx :: PageId -> Tx (Maybe StarredPage)
starredPageTx pid =
  db (pageNode pid) >>= \case
    Nothing -> pure Nothing
    Just p -> do
      chain <- chainOfPage p
      viewable <- (requireView chain $> True) `catchError` const (pure False)
      if not viewable
        then pure Nothing
        else do
          nodes <- lineageOf p.id
          spaces <- asks (\x -> x.spaces)
          pure $
            (\pagePath -> StarredPage {Star.page = p.id, Star.space = p.space, Star.title = p.title, Star.location = PageLocation {space = map (\x -> x.slug) chain, page = pagePath}})
              <$> pathIn spaces p.space (`Map.lookup` nodes) p.id

-- | Star a page the user may view, or take its star away, as the class's
-- Haddock says ("Wiki.App.Backend.Stars"). The result is the list after.
setStarredTx :: PageId -> Bool -> Tx [StarredPage]
setStarredTx pid wanted = do
  p <- findNode pid
  chainOfPage p >>= requireView
  u <- notified
  if wanted
    then do
      already <- db (Stars.hasStar u pid)
      unless already $ do
        count <- db (Stars.countStars u)
        when (count >= maxStars) $
          invalid ("You have starred " <> show maxStars <> " pages, the most there can be: take the star from one first.")
        db (Stars.insertStar u pid)
    else db (Stars.deleteStar u pid)
  starredTx

-- | The signed-in user's starred pages. Each operation is one transaction.
instance (MonadIO m) => MonadStars (StoredWiki m) where
  starred = run Reads starredTx
  setStarred pid = run Writes . setStarredTx pid

--------------------------------------------------------------------------------
-- Whole wikis

-- | Load a whole wiki from an export archive ("Wiki.Core.Export", already
-- checked by 'Wiki.Core.Export.readArchive') into an empty storage: its
-- people, groups, grants, spaces and pages with their ids, each page as
-- its first version, its pages' comments with their ids, and its
-- attachments' bytes stored under their hashes (so the blobs' ids are
-- hashes from then on). A comment's author is the archive's user with
-- the author's login, or the administrator for the administrator's login;
-- anyone else is kept by their name ('Wiki.Core.Comment.formerAuthor'). An
-- archive with a login the wiki refuses is refused
-- ('Wiki.Core.Export.checkLogins'). A storage that already
-- holds a wiki is refused and left unchanged: bringing one wiki into
-- another is a merge, which is the job of the import (WP2.8 of
-- docs/PLAN.md).
importArchive :: Storage -> Archive -> IO (Either Text ())
importArchive st incoming = fmap void (writingEitherThen st transaction (cacheServerSettings st))
  where
    -- An older archive's spaces may have several top-level pages: each
    -- space's home page becomes their root, as step 13 of the schema made
    -- it in the wiki's own database.
    a = rootedArchive (withoutHomeDocument incoming)
    transaction :: (Backend be) => Db be (Either Text Kept)
    transaction = do
      vacant <- wikiIsEmpty
      let unkept = [x | p <- incoming.pages, x <- p.attachments, SourceBlob b <- [x.source], Map.notMember b a.blobs]
          iconless = [sp | sp <- incoming.spaces, Just (IconImage b _) <- [sp.icon], Map.notMember b a.blobs]
      case (vacant, unkept, iconless, checkLogins a.users) of
        (False, _, _, _) -> pure (Left "The server has a wiki already: an archive is imported into an empty one only.")
        (_, x : _, _, _) -> pure (Left ("The archive has no bytes for the attachment " <> show x.id.text <> "."))
        (_, _, sp : _, _) -> pure (Left ("The archive has no bytes for the icon of the space " <> show sp.id.text <> "."))
        (_, _, _, Left why) -> pure (Left why)
        (True, [], [], Right ()) -> do
          insertUsers a.users
          traverse_ insertGroup a.groups
          insertMembers [(g, u) | (g, members) <- Map.toList a.membership, u <- Set.toList members]
          hashes <- liftIO (traverse (storeBlob (attachmentsDir st.place.dataDir)) a.blobs)
          -- An archive gives spaces and pages in any order, a child before its
          -- parent too, and a space names its home page before the page is
          -- there. Each is added after its parent, and the spaces' home pages
          -- once the pages are there, so that every foreign key holds at each
          -- step, as PostgreSQL checks them.
          -- A space comes in plain, whatever the archive says of its
          -- encryption: the archive holds no key and no ciphertext, only
          -- the plain pages it was exported with, and an encrypted space's
          -- mark would make the server refuse to read them.
          let spaces =
                [ (\x -> x {encryption = Nothing}) $ case sp.icon of
                    Just (IconImage b mt) -> withProfile SpaceProfile {description = sp.description, icon = Just (IconImage (Map.findWithDefault b b hashes) mt), blog = sp.blog, boxNumbering = sp.boxNumbering} sp
                    _ -> sp
                | sp <- parentsFirst (\x -> x.id) (\x -> x.parent) a.spaces
                ]
          insertSpaces [withHome Nothing sp | sp <- spaces]
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
          -- A space the archive gives no home page gets its default one,
          -- as a space made here would, with no author: an archive of an
          -- older wiki, where a space could have none.
          time <- liftIO (micro <$> getCurrentTime)
          traverse_ (insertHomePage Nothing time) [sp | sp <- spaces, hasHome sp, isNothing sp.homePage]
          -- Nothing but a space's home page has no parent ('rootedArchive'
          -- made it so). An archive whose home page is a page of another
          -- space, which no wiki writes, would leave a second.
          imported <- loadSpaces
          stray <- concat <$> traverse strayRootsOf (Map.elems imported)
          case stray of
            n : _ -> pure (Left ("The archive leaves the page " <> show n.id.text <> " with no parent beside its space's home page."))
            [] -> do
              traverse_ (traverse_ Comments.restoreThread) (threadsAmong (administratorUser : a.users) a)
              importHomeDocument (attachmentsDir st.place.dataDir) incoming
              restoreAudit a.audit
              Right <$> loadServerSettings

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
  (users, groups, membership, storedGrants, allSpaces, allPages, threads, audit, homePage, homeVersions) <-
    -- One read transaction, so that the records are of one state of the
    -- wiki.
    reading st $
      (,,,,,,,,,)
        <$> loadUsers
        <*> loadGroups
        <*> loadMembership
        <*> loadGrants
        <*> (Map.elems <$> loadSpaces)
        <*> loadAllPages
        <*> Comments.loadAllThreads commentAuthor
        <*> loadAuditLog
        <*> ((Just . (\s -> s.homePage)) <$> loadServerSettings)
        <*> ( do
                settings <- loadServerSettings
                case settings.homePage.document of
                  Nothing -> pure []
                  Just d -> do
                    (_, versions) <- loadVersionsPage d.page Nothing maxBound
                    catMaybes <$> traverse (\v -> fmap (versionOf d.page) <$> loadVersion d.page v.updatedAt) versions
            )
  let -- An encrypted space is left out of the archive, with its pages and
      -- grants: the server holds its pages' titles and texts only as
      -- ciphertext, under keys it does not have, and an archive of empty
      -- pages imported elsewhere would be a plain space that only looks
      -- like this one. An export decrypted in the browser is for later.
      encrypted = Set.fromList [sp.id | sp <- allSpaces, isJust sp.encryption]
      spaces = [sp | sp <- allSpaces, not (sp.id `Set.member` encrypted)]
      pages = [p | p <- allPages, not (p.space `Set.member` encrypted)]
      grants = Grants {global = storedGrants.global, spaces = [g | g <- storedGrants.spaces, not (g.space `Set.member` encrypted)], access = storedGrants.access}
      commentAuthors = [administratorUser | any (any (any (\x -> x.author.id == administratorId) . (\t -> t.comments))) threads]
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
  pure $ (\files -> (Archive {createdAt, app, users, groups, membership, grants, spaces, pages, threads, commentAuthors, blobs = mempty, audit, homePage, homeVersions}, Map.fromList files)) <$> sequence (attachments <> icons)

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
