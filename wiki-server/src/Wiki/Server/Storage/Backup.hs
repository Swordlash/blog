{-# LANGUAGE DeriveAnyClass #-}

-- | Database backups: copies of the database set aside, such as the one
-- the deploy script takes before it starts a new server (decision 15 of
-- docs/PLAN.md), and the ones the server makes on its own once an
-- administrator has turned that on (WP4.9, "Wiki.Server.Backups").
--
-- A copy is made with the database's own means, never by copying its
-- files, while the server may be running and writing:
--
-- * On SQLite, @VACUUM INTO@ reads one consistent state of the database
--   (in WAL mode it waits for no writer and blocks none) into a new file
--   that is a complete database: @\<data\>/backups/\<time\>.sqlite@. It is
--   checked with SQLite's @PRAGMA integrity_check@.
-- * On PostgreSQL, @pg_dump@ writes one consistent state into
--   @\<data\>/backups/\<time\>.pgdump@, in its custom format, which
--   @pg_restore@ reads; the dump is checked by listing it. Beside it,
--   @\<time\>.pgdump.json@ says which version of the schema the dump has and
--   which attachments' files it refers to, read in the very snapshot the
--   dump reads, since the dump itself cannot be read without restoring it.
--
-- The copies are named by the time in UTC so that their names sort in time
-- order, and only the last few are kept.
--
-- Attachments are not copied: their files never change, and none is
-- deleted while a kept backup still refers to it
-- ("Wiki.Server.Storage.Blobs", 'backupBlobs'). So a backup restored in
-- place of the database finds every file it refers to.
--
-- The backups' settings and the result of the last backup are rows of the
-- @settings@ table ('loadBackupSettings', 'loadLastBackup').
--
-- A backup is restored with 'restore' (@wiki-server restore@), into a data
-- directory no server has open: a running server holds the directory's
-- lock file ('lockDataDir'), which the operating system releases when the
-- process ends, however it ends. On PostgreSQL that is not enough, since
-- servers on other data directories may use the same database: every
-- open storage also holds the database's advisory lock shared, and a
-- restore takes it alone ('withDatabaseAlone'), so it refuses to run while
-- any server or console has the database open. PostgreSQL releases that
-- lock when the connection that holds it ends.
module Wiki.Server.Storage.Backup
  ( -- * Backups
    backupInto
  , backupNow
  , backupFiles
  , backupTime
  , pruneBackups
  , defaultKeep
  , freshName
  , backupBlobs

    -- * Backups the server makes
  , KeptBackups
  , loadBackupSettings
  , storeBackupSettings
  , loadLastBackup
  , storeLastBackup
  , pruneRetained

    -- * Files of attachments
  , copyBlobs

    -- * The data directory's lock
  , DataLock
  , lockDataDir
  , unlockDataDir

    -- * Restoring
  , Restore (..)
  , restore
  )
where

import Data.Aeson (FromJSON, ToJSON, decodeStrict', eitherDecodeFileStrict', encode, encodeFile)
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime, parseTimeM)
import GHC.IO.Handle.Lock (LockMode (..), hTryLock, hUnlock)
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getFileSize, listDirectory, removeFile, renameFile)
import System.FilePath (takeFileName, (</>))
import System.IO (hClose)
import System.IO.Error (isAlreadyInUseError, userError)
import Wiki.Api.Backups (BackupRecord, BackupSettingsOf (..), DestinationOf (..), Retention (..), Schedule (..), defaultBackupSettings, retained)
import Wiki.Core.Id (BlobId (..))
import Wiki.Server.Secret (Secret (..), revealed)
import Wiki.Server.Storage.Backend (Backend (..), withTransaction)
import Wiki.Server.Storage.Blobs (blobFile, storedBlobs)
import Wiki.Server.Storage.Layout (Database (..), PgDatabase, attachmentsDir)
import Wiki.Server.Storage.Migrate (Migration (..), databaseVersion, migrationsFor, schemaVersion)
import Wiki.Server.Storage.Postgres (PgPrograms, checkDump, closePostgres, dumpPostgres, exportSnapshot, openPostgres, restorePostgres, withDatabaseAlone)
import Wiki.Server.Storage.Rows (deleteSettingsLike, referencedBlobs, settingValue, settingsLike, storeSetting)
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, integrityProblems, openSqlite, vacuumInto)

-- | How many backups are kept unless configured otherwise: a week of
-- daily deploys and a few more.
defaultKeep :: Int
defaultKeep = 10

--------------------------------------------------------------------------------
-- Backups

-- | What is known of a PostgreSQL backup without restoring it, kept beside
-- it (@\<time\>.pgdump.json@): the version of the schema it has, and the
-- attachments' files it refers to.
data DumpFacts = DumpFacts
  { schema :: Int
  , blobs :: [Text]
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The file that holds a PostgreSQL backup's 'DumpFacts'.
factsFile :: FilePath -> FilePath
factsFile dump = dump <> ".json"

-- | Make a backup of a database in a directory of backups, named for a
-- time, and check it. The result is its path and size, or why there is
-- none. A copy that fails its check, or could not be finished, is deleted:
-- a backup that cannot be restored must not count as one, nor be kept in
-- place of a good one.
--
-- The copy is made through a connection opened for it alone, which reads
-- the last committed state as a reader does: neither reads nor writes wait
-- for it, however long it takes.
backupInto :: PgPrograms -> Database -> FilePath -> UTCTime -> IO (Either Text (FilePath, Integer))
backupInto programs database dir t = do
  createDirectoryIfMissing True dir
  target <- freshName dir t (extensionOf database)
  let discard = for_ [target, factsFile target] $ \f -> whenM (doesFileExist f) (removeFile f)
  made <- try @SomeException (copy target)
  case made of
    Left e -> discard $> Left ("The database could not be copied: " <> show e)
    Right (Left why) -> discard $> Left ("The database could not be copied: " <> why)
    Right (Right ()) ->
      problemsOf target >>= \case
        [] -> Right . (target,) <$> getFileSize target
        problems -> discard $> Left ("The copy failed its check, and was deleted: " <> T.intercalate "; " (take 5 problems))
  where
    copy target = case database of
      SqliteFile file -> Right <$> bracket (openSqlite ReadWrite file) closeSqlite (`vacuumInto` target)
      PostgresAt db -> dumpWithFacts programs db target
    problemsOf target
      | ".pgdump" `T.isSuffixOf` T.pack target = either (: []) (const []) <$> checkDump programs target
      | otherwise = integrityProblems target

-- | Dump a PostgreSQL database into a file, with its facts beside it
-- ('factsFile'): a backup, or the database a restore replaces, which can
-- then be restored as a backup is.
dumpWithFacts :: PgPrograms -> PgDatabase -> FilePath -> IO (Either Text ())
dumpWithFacts programs db target = bracket (openPostgres db) closePostgres $ \c -> do
  -- A read-only transaction whose snapshot the dump reads: the facts
  -- kept beside the dump are read in the same snapshot. The transaction
  -- only reads, so its commit changes nothing.
  withTransaction False c $ do
    snapshot <- runDb c exportSnapshot
    facts <- DumpFacts <$> schemaVersion c <*> (map (\b -> b.text) . Set.toList <$> runDb c referencedBlobs)
    dumped <- dumpPostgres programs db (Just snapshot) target
    for_ dumped (\() -> encodeFile (factsFile target) facts)
    pure dumped

-- | Back up a database into a data directory's backups, and delete all
-- but the last @keep@ of them (never the one just made): what the deploy
-- scripts run before they start a new server (@wiki-server backup@). The
-- result is the new backup's path, 'Nothing' when there is no wiki to back
-- up yet (the first deploy), or why it failed. A database of an earlier
-- wiki-server, whose schema this one does not read, is refused with the
-- exception 'Wiki.Server.Storage.Migrate.OldSchema'.
backupNow :: PgPrograms -> Database -> FilePath -> Int -> IO (Either Text (Maybe FilePath))
backupNow programs database dataDir keep = do
  there <- case database of
    SqliteFile file -> ifM (doesFileExist file) (bracket (openSqlite ReadOnly file) closeSqlite (fmap (> 0) . databaseVersion)) (pure False)
    PostgresAt db -> bracket (openPostgres db) closePostgres (fmap (> 0) . databaseVersion)
  if not there
    then pure (Right Nothing)
    else do
      let dir = dataDir </> "backups"
      now <- getCurrentTime
      backupInto programs database dir now >>= \case
        Left why -> pure (Left why)
        Right (file, _) -> pruneBackups dir (max 1 keep) $> Right (Just file)

-- | The ending of a backup's file name on a database.
extensionOf :: Database -> Text
extensionOf = \case
  SqliteFile _ -> "sqlite"
  PostgresAt _ -> "pgdump"

-- | The time a backup was made, from its name ('freshName').
backupTime :: FilePath -> Maybe UTCTime
backupTime file = stemOf (T.pack (takeFileName file)) >>= parseTimeM False defaultTimeLocale "%Y%m%dT%H%M%S%Q" . T.unpack

-- | A backup's file name without its @Z.sqlite@ or @Z.pgdump@.
stemOf :: Text -> Maybe Text
stemOf name = T.stripSuffix "Z.sqlite" name <|> T.stripSuffix "Z.pgdump" name

-- | A backup's file name for a time, a millisecond later if that name
-- exists already: @20261024T153000.123Z.sqlite@ (or @.pgdump@).
freshName :: FilePath -> UTCTime -> Text -> IO FilePath
freshName dir t extension = do
  let millis = diffTimeToPicoseconds (utctDayTime t) `div` 1000000000 `mod` 1000
      name = formatTime defaultTimeLocale "%Y%m%dT%H%M%S" t <> "." <> T.unpack (T.justifyRight 3 '0' (show millis)) <> "Z." <> T.unpack extension
      file = dir </> name
  ifM (doesFileExist file) (freshName dir (addUTCTime 0.001 t) extension) (pure file)

-- | The backups in a directory, oldest first: the files named as
-- 'freshName' names them, and nothing else in it.
backupFiles :: FilePath -> IO [FilePath]
backupFiles dir =
  ifM
    (doesDirectoryExist dir)
    (map (dir </>) . sortOn takeFileName . filter isBackup <$> listDirectory dir)
    (pure [])
  where
    isBackup f = case stemOf (T.pack f) of
      Just stem -> T.length stem == 19 && T.all (\ch -> isDigit ch || ch == 'T' || ch == '.') stem
      Nothing -> False

-- | Delete a backup, and what is kept beside it.
removeBackup :: FilePath -> IO ()
removeBackup f = do
  removeFile f
  whenM (doesFileExist (factsFile f)) (removeFile (factsFile f))

-- | Delete all but the newest @keep@ backups in a directory. The result is
-- the files deleted.
pruneBackups :: FilePath -> Int -> IO [FilePath]
pruneBackups dir keep = do
  files <- backupFiles dir
  let old = take (length files - keep) files
  traverse_ removeBackup old
  pure old

-- | The attachments' files a backup refers to: read from the copy itself
-- on SQLite, and from the facts kept beside it on PostgreSQL. A backup
-- that cannot be read is an exception.
backupBlobs :: FilePath -> IO (Set BlobId)
backupBlobs file
  | ".pgdump" `T.isSuffixOf` T.pack file =
      eitherDecodeFileStrict' @DumpFacts (factsFile file) >>= \case
        Left e -> throwIO (userError ("The facts of the backup " <> file <> " cannot be read: " <> e))
        Right facts -> pure (Set.fromList (map BlobId facts.blobs))
  | otherwise = bracket (openSqlite ReadOnly file) closeSqlite (`runDb` referencedBlobs)

--------------------------------------------------------------------------------
-- Backups the server makes

-- | The backup settings as stored: the @rclone@ configuration, if any, in
-- clear text, like the server's other secrets ("Wiki.Server.Secret").
type KeptBackups = BackupSettingsOf (Maybe Secret)

-- | The backup settings, each from its row of the @settings@ table, or its
-- default ('defaultBackupSettings': off) for a setting that has no row or
-- that this program cannot read. The rows, all absent until the
-- administration writes them:
--
-- > backup-enabled         1 | 0
-- > backup-schedule        daily 03:00 | every 6
-- > backup-keep-daily      7
-- > backup-keep-weekly     4
-- > backup-directory       /mnt/backup/wiki      (a destination, or)
-- > backup-rclone          b2:bucket/wiki        (another)
-- > backup-rclone-config   the text of an rclone.conf
-- > backup-last            the last backup made or tried, as JSON
loadBackupSettings :: (Backend be) => Db be KeptBackups
loadBackupSettings = do
  rows <- settingsLike "backup-"
  let valueOf key = mfilter (not . T.null) (snd <$> find ((== key) . fst) rows)
      number key = valueOf key >>= readMaybe
      d = defaultBackupSettings :: KeptBackups
  pure
    BackupSettings
      { enabled = valueOf "backup-enabled" == Just "1"
      , schedule = fromMaybe d.schedule (valueOf "backup-schedule" >>= readSchedule)
      , keep = Retention {daily = fromMaybe d.keep.daily (number "backup-keep-daily"), weekly = fromMaybe d.keep.weekly (number "backup-keep-weekly")}
      , destination =
          (ToDirectory <$> valueOf "backup-directory")
            <|> ((\remote -> ToRclone remote (Secret <$> valueOf "backup-rclone-config")) <$> valueOf "backup-rclone")
      }
  where
    readSchedule t = case T.words t of
      ["daily", hm] | [h, m] <- T.splitOn ":" hm, Just hour <- readMaybe h, Just minute <- readMaybe m -> Just (DailyAt hour minute)
      ["every", n] -> EveryHours <$> readMaybe n
      _ -> Nothing

-- | Store the backup settings, replacing those stored before (the last
-- backup's row is left as it is).
storeBackupSettings :: (Backend be) => KeptBackups -> Db be ()
storeBackupSettings s = do
  deleteSettingsLike "backup-" ["backup-last"]
  let rows =
        [ ("backup-enabled", if s.enabled then "1" else "0")
        ,
          ( "backup-schedule"
          , case s.schedule of
              DailyAt h m -> "daily " <> twoDigits h <> ":" <> twoDigits m
              EveryHours n -> "every " <> show n
          )
        , ("backup-keep-daily", show s.keep.daily)
        , ("backup-keep-weekly", show s.keep.weekly)
        ]
          <> case s.destination of
            Nothing -> []
            Just (ToDirectory path) -> [("backup-directory", path)]
            Just (ToRclone remote config) -> ("backup-rclone", remote) : [("backup-rclone-config", revealed x) | Just x <- [config]]
  traverse_ (uncurry storeSetting) rows
  where
    twoDigits n = T.justifyRight 2 '0' (show n)

-- | The last backup made or tried, if any is known.
loadLastBackup :: (Backend be) => Db be (Maybe BackupRecord)
loadLastBackup = (>>= decodeStrict' . encodeUtf8) <$> settingValue "backup-last"

-- | Store the last backup made or tried, replacing the one before.
storeLastBackup :: (Backend be) => BackupRecord -> Db be ()
storeLastBackup r = storeSetting "backup-last" (decodeUtf8 (BSL.toStrict (encode r)))

-- | Delete the backups in a directory that a retention does not keep
-- ('Wiki.Api.Backups.retained'), never this one. The result is the files
-- deleted. A file named like a backup but whose time cannot be read is
-- left alone.
pruneRetained :: FilePath -> Retention -> FilePath -> IO [FilePath]
pruneRetained dir r newest = do
  files <- backupFiles dir
  let timed = [(f, t) | f <- files, Just t <- [backupTime f]]
      keep = retained r (map snd timed)
      gone = [f | (f, t) <- timed, not (t `Set.member` keep), takeFileName f /= takeFileName newest]
  traverse_ removeBackup gone
  pure gone

--------------------------------------------------------------------------------
-- The data directory's lock

-- | The lock a server holds on its data directory while it runs.
newtype DataLock = DataLock Handle

-- | Take a data directory's lock (@\<data>/wiki.lock@), or report that
-- something else holds it. The lock is the operating system's (@flock@),
-- held by the open file: it is released with the process however that
-- ends, so a server that crashed leaves nothing to clean up. Within one
-- process the file cannot be opened twice for writing, which has the same
-- effect.
lockDataDir :: FilePath -> IO (Either Text DataLock)
lockDataDir dataDir = do
  createDirectoryIfMissing True dataDir
  let file = dataDir </> "wiki.lock"
      held = "A server is running on " <> toS dataDir <> " (it holds " <> toS file <> "): stop it first."
  try (openFile file ReadWriteMode) >>= \case
    Left e
      | isAlreadyInUseError e -> pure (Left held)
      | otherwise -> pure (Left ("The lock file " <> toS file <> " cannot be opened: " <> show e))
    Right h ->
      hTryLock h ExclusiveLock >>= \case
        True -> pure (Right (DataLock h))
        False -> hClose h $> Left held

-- | Release a data directory's lock.
unlockDataDir :: DataLock -> IO ()
unlockDataDir (DataLock h) = hUnlock h `finally` hClose h

--------------------------------------------------------------------------------
-- Restoring

-- | @wiki-server restore BACKUP --data DIR [--attachments DIR]@, with the
-- database the data directory's server uses.
data Restore = Restore
  { backupFile :: FilePath
  -- ^ The backup to restore: one from @data\/backups@, or one copied off
  -- the machine.
  , dataDir :: FilePath
  -- ^ The data directory to restore it into, which no server may have
  -- open; a new one is created.
  , database :: Database
  -- ^ The database to restore it into: a backup of SQLite into SQLite, a
  -- backup of PostgreSQL into PostgreSQL.
  , programs :: PgPrograms
  -- ^ @pg_dump@ and @pg_restore@, for PostgreSQL.
  , attachments :: Maybe FilePath
  -- ^ A copy of the attachment files (an off-site copy's @attachments@),
  -- from which the data directory gets the files it lacks.
  }
  deriving stock (Show)

-- | Restore a backup as a data directory's database. The result is the
-- lines to show, or why nothing was done.
--
-- The backup is checked first (a sound copy, of a wiki, at a schema
-- version this program knows, of the same kind of database), and the
-- directory's lock is taken, so that a server running on it, or one
-- started meanwhile, is refused. On PostgreSQL the database's lock is
-- taken too, which refuses a server or console on any data directory.
--
-- The database it replaces is not deleted: a SQLite file is moved as it
-- is, with its @-wal@ and @-shm@ files, into @replaced\/\<time>\/@ beside
-- the data, and a PostgreSQL database is dumped there first, with its
-- facts as a backup has them, so that a restore made by mistake can itself
-- be undone with 'restore'. The backup stays among the backups. The
-- attachment files the restored database refers to and the directory
-- lacks are listed, so that the operator knows to bring them.
restore :: Restore -> IO (Either Text [Text])
restore r = runExceptT $ do
  present <- liftIO (doesFileExist r.backupFile)
  unless present $ throwError ("There is no file " <> toS r.backupFile <> ".")
  for_ r.attachments $ \dir -> unlessM (liftIO (doesDirectoryExist dir)) $ throwError ("There is no directory " <> toS dir <> " to bring attachments from.")
  let ofPostgres = ".pgdump" `T.isSuffixOf` T.pack r.backupFile
  (wanted, steps) <- case (ofPostgres, r.database) of
    (False, SqliteFile file) -> restoreSqlite r file
    (True, PostgresAt db) -> restorePostgresDump r db
    (False, PostgresAt _) -> throwError "This is a backup of a wiki on SQLite, and the database is PostgreSQL's: export the wiki from a server on that backup, and import the archive into this one."
    (True, SqliteFile _) -> throwError "This is a backup of a wiki on PostgreSQL, and the database is a SQLite file: give the PostgreSQL database to restore it into (--database), or export the wiki from a server on that backup and import the archive."
  brought <- liftIO (maybe (pure 0) (copyBlobs (attachmentsDir r.dataDir)) r.attachments)
  stored <- liftIO (storedBlobs (attachmentsDir r.dataDir))
  let missing = Set.size (wanted `Set.difference` stored)
  pure
    ( steps
        <> ["Brought " <> show brought <> " attachments' files from " <> toS dir <> "." | Just dir <- [r.attachments]]
        <> [ "Warning: "
               <> show missing
               <> " of the attachments' files it refers to are not in "
               <> toS (attachmentsDir r.dataDir)
               <> ": bring them with --attachments DIR (a copy's attachments directory), or those attachments will be missing."
           | missing > 0
           ]
    )

-- | The schema version the steps of a database end at.
knownVersion :: Text -> Int
knownVersion suffix = maybe 0 (\m -> m.version) (lastMay (migrationsFor suffix))

-- | Check a schema version of a backup against this program's.
checkVersion :: FilePath -> Text -> Int -> ExceptT Text IO ()
checkVersion file suffix version = do
  let known = knownVersion suffix
  when (version == 0) $ throwError ("The file " <> toS file <> " is a database, but not a wiki's of this wiki-server: a backup of an earlier one is restored with that one, and its wiki exported and imported.")
  when (version > known) $ throwError ("The backup is at version " <> show version <> " of the schema, newer than this program's " <> show known <> ": restore it with a newer wiki-server.")

-- | Take the data directory's lock for the time of a restore.
withLock :: FilePath -> ExceptT Text IO a -> ExceptT Text IO a
withLock dataDir body = do
  lock <- ExceptT (lockDataDir dataDir)
  ExceptT (runExceptT body `finally` unlockDataDir lock)

-- | Where a restore keeps what it replaced.
-- The directory is named by the time, and is a new one: a second restore
-- in the same second (one that undoes the first, from what the first set
-- aside) gets a name with a number after it, and never writes over the
-- file it restores.
asideIn :: FilePath -> IO FilePath
asideIn dataDir = do
  now <- getCurrentTime
  let base = dataDir </> "replaced" </> formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now
      free n = do
        let dir = if n == 1 then base else base <> "-" <> show n
        ifM (doesDirectoryExist dir) (free (n + 1)) (pure dir)
  free (1 :: Int)

restoreSqlite :: Restore -> FilePath -> ExceptT Text IO (Set BlobId, [Text])
restoreSqlite r database = do
  problems <- liftIO (integrityProblems r.backupFile)
  unless (null problems) $ throwError ("The backup " <> toS r.backupFile <> " is not sound: " <> T.intercalate "; " (take 5 problems))
  version <- liftIO (bracket (openSqlite ReadOnly r.backupFile) closeSqlite schemaVersion)
  checkVersion r.backupFile "sqlite" version
  withLock r.dataDir $ liftIO $ do
    aside <- asideIn r.dataDir
    let files = [database, database <> "-wal", database <> "-shm"]
    existing <- filterM doesFileExist files
    unless (null existing) $ do
      createDirectoryIfMissing True aside
      for_ existing $ \f -> renameFile f (aside </> takeFileName f)
    copyFile r.backupFile (database <> ".restoring")
    renameFile (database <> ".restoring") database
    wanted <- backupBlobs database
    pure
      ( wanted
      , ["Restored " <> toS r.backupFile <> " as " <> toS database <> "; the server brings it up to its schema when it starts."]
          <> ["The database it replaced is kept in " <> toS aside <> "." | not (null existing)]
      )

restorePostgresDump :: Restore -> PgDatabase -> ExceptT Text IO (Set BlobId, [Text])
restorePostgresDump r db = do
  ExceptT (checkDump r.programs r.backupFile)
  facts <- ExceptT (first (\e -> "The facts kept beside the backup cannot be read (" <> toS (factsFile r.backupFile) <> "): " <> T.pack e) <$> eitherDecodeFileStrict' @DumpFacts (factsFile r.backupFile))
  checkVersion r.backupFile "postgres" facts.schema
  -- The data directory's lock keeps a server off this directory; the
  -- database's lock, taken alone, keeps every server and console off the
  -- database, whatever directory they run on.
  withLock r.dataDir $ ExceptT $ fmap (fromMaybe (Left inUse)) $ withDatabaseAlone db $ runExceptT $ do
    aside <- liftIO (asideIn r.dataDir)
    had <- liftIO (bracket (openPostgres db) closePostgres (\c -> not . null <$> runDb c tableNames))
    when had $ do
      liftIO (createDirectoryIfMissing True aside)
      ExceptT (first ("The database to be replaced could not be set aside: " <>) <$> dumpWithFacts r.programs db (aside </> "wiki.pgdump"))
    ExceptT (first ("The backup could not be restored, and the database is as it was: " <>) <$> restorePostgres r.programs db r.backupFile)
    pure
      ( Set.fromList (map BlobId facts.blobs)
      , ["Restored " <> toS r.backupFile <> " into the PostgreSQL database; the server brings it up to its schema when it starts."]
          <> ["The database it replaced is kept, dumped, in " <> toS (aside </> "wiki.pgdump") <> ", which wiki-server restore takes as it takes a backup." | had]
      )
  where
    inUse = "The PostgreSQL database is open in a running server or console (from this data directory or another): stop it, and restore again."

-- | Copy into a directory of blobs the files of another that it lacks (a
-- blob's file never changes, so one that is there is the right one). The
-- result is how many were copied. Each is written next to its final place
-- and then moved there, so that an interrupted copy leaves no partial file
-- under a hash.
copyBlobs :: FilePath -> FilePath -> IO Int
copyBlobs into copies = do
  blobs <- Set.toList <$> storedBlobs copies
  copied <- for blobs $ \b -> case (blobFile copies b, blobFile into b) of
    (Just source, Just target) ->
      ifM
        (doesFileExist target)
        (pure 0)
        ( do
            let shard = into </> T.unpack (T.take 2 b.text)
                -- Named as "Wiki.Server.Storage.Blobs" names a file it is
                -- writing, so that one left behind is cleaned up.
                incoming = shard </> ("incoming-" <> T.unpack b.text)
            createDirectoryIfMissing True shard
            copyFile source incoming
            renameFile incoming target
            pure (1 :: Int)
        )
    _ -> pure 0
  pure (sum copied)
