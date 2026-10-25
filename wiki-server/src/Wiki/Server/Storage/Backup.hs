-- | Copies of the database set aside, as the deploy script takes one before
-- it starts a new server (decision 15 of docs/PLAN.md).
--
-- A copy is made with SQLite's own @VACUUM INTO@, never by copying the file:
-- the server may be running and writing, and @VACUUM INTO@ reads one
-- consistent state of the database through SQLite (the database is in WAL
-- mode, so it waits for no writer and holds none up) into a new file that is
-- a database on its own, without the WAL beside it. The copies go into
-- @\<data\>/backups/\<time\>.sqlite@, named by the time in UTC so that their
-- names sort as their times do, and only the last few are kept.
--
-- Attachments are not copied: their files never change, and none is deleted
-- while a backup kept still names it ("Wiki.Server.Storage.Blobs"), so a
-- backup restored in place of the database finds every file it refers to.
--
-- The server also backs itself up, once an administrator has turned that
-- on (WP4.9 of docs/PLAN.md, "Wiki.Server.Backups"): what it is set to do
-- and what it last did are rows of the @settings@ table, kept here
-- ('loadBackupSettings', 'loadLastBackup'), and each backup it makes is
-- checked ('checkedBackup') and the old ones pruned by its retention
-- ('pruneRetained').
--
-- A backup is put back with 'restore' (@wiki-server restore@), into a data
-- directory no server has open: a server holds the directory's lock file
-- while it runs ('lockDataDir'), which the operating system lets go when
-- the process ends, however it ends.
module Wiki.Server.Storage.Backup
  ( -- * Backups
    backup
  , backupInto
  , backupFiles
  , backupTime
  , pruneBackups
  , defaultKeep
  , freshName

    -- * Backups the server makes
  , KeptBackups
  , loadBackupSettings
  , storeBackupSettings
  , loadLastBackup
  , storeLastBackup
  , checkedBackup
  , integrityProblems
  , pruneRetained

    -- * What a database refers to
  , referencedBlobs
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

import Data.Aeson (decodeStrict', encode)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime, parseTimeM)
import Database.SQLite.Simple (Connection, Only (..), SQLError, execute, execute_, query_, withConnection)
import GHC.IO.Handle.Lock (LockMode (..), hTryLock, hUnlock)
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getFileSize, listDirectory, removeFile, renameFile)
import System.FilePath (takeFileName, (</>))
import System.IO (hClose)
import System.IO.Error (isAlreadyInUseError)
import Wiki.Api.Backups (BackupRecord, BackupSettingsOf (..), DestinationOf (..), Retention (..), Schedule (..), defaultBackupSettings, retained)
import Wiki.Core.Id (BlobId (..))
import Wiki.Core.Space (Icon (..))
import Wiki.Server.Secret (Secret (..), revealed)
import Wiki.Server.Storage.Blobs (blobFile, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir, databaseFile)
import Wiki.Server.Storage.Migrate (Migration (..), migrations, schemaVersion)

-- | How many backups are kept unless asked otherwise: a week of daily
-- deploys and a few more.
defaultKeep :: Int
defaultKeep = 10

-- | Back up the database of a data directory into its backups, and delete
-- all but the last @keep@ of them (never the one just made). What is given
-- back is the new backup's path, or 'Nothing' when there is no database to
-- back up yet (the first deploy).
backup :: FilePath -> Int -> IO (Maybe FilePath)
backup dataDir keep =
  ifM
    (not <$> doesFileExist (databaseFile dataDir))
    (pure Nothing)
    ( do
        let dir = backupsDir dataDir
        createDirectoryIfMissing True dir
        target <- freshName dir =<< getCurrentTime
        withConnection (databaseFile dataDir) $ \c -> do
          execute_ c "PRAGMA busy_timeout = 10000"
          backupInto c target
        _ <- pruneBackups dir (max 1 keep)
        pure (Just target)
    )

-- | Write a copy of the database a connection is open on into a new file.
backupInto :: Connection -> FilePath -> IO ()
backupInto c target = execute c "VACUUM INTO ?" (Only (T.pack target))

-- | The time a backup was made, from its name ('freshName').
backupTime :: FilePath -> Maybe UTCTime
backupTime file = T.stripSuffix "Z.sqlite" (T.pack (takeFileName file)) >>= parseTimeM False defaultTimeLocale "%Y%m%dT%H%M%S%Q" . T.unpack

-- | A backup's name for a time, a millisecond later if one has that name
-- already: @20261024T153000.123Z.sqlite@.
freshName :: FilePath -> UTCTime -> IO FilePath
freshName dir t = do
  let millis = diffTimeToPicoseconds (utctDayTime t) `div` 1000000000 `mod` 1000
      name = formatTime defaultTimeLocale "%Y%m%dT%H%M%S" t <> "." <> T.unpack (T.justifyRight 3 '0' (show millis)) <> "Z.sqlite"
      file = dir </> name
  ifM (doesFileExist file) (freshName dir (addUTCTime 0.001 t)) (pure file)

-- | The backups in a directory, oldest first: the files named as 'backup'
-- names them, and nothing else that is there.
backupFiles :: FilePath -> IO [FilePath]
backupFiles dir =
  ifM
    (doesDirectoryExist dir)
    (map (dir </>) . sort . filter isBackup <$> listDirectory dir)
    (pure [])
  where
    isBackup f = case T.stripSuffix "Z.sqlite" (T.pack f) of
      Just stem -> T.length stem == 19 && T.all (\ch -> isDigit ch || ch == 'T' || ch == '.') stem
      Nothing -> False

-- | Delete all but the newest @keep@ backups in a directory; what is given
-- back is the files deleted.
pruneBackups :: FilePath -> Int -> IO [FilePath]
pruneBackups dir keep = do
  files <- backupFiles dir
  let old = take (length files - keep) files
  traverse_ removeFile old
  pure old

--------------------------------------------------------------------------------
-- Backups the server makes

-- | The settings as kept: the @rclone@ configuration, if any, in clear, as
-- the server's other secrets are ("Wiki.Server.Secret").
type KeptBackups = BackupSettingsOf (Maybe Secret)

-- | The settings, each from its row of the @settings@ table, or its default
-- ('defaultBackupSettings': off) for one that has none or that this
-- program cannot read. The rows, all absent until the administration
-- writes them:
--
-- > backup-enabled         1 | 0
-- > backup-schedule        daily 03:00 | every 6
-- > backup-keep-daily      7
-- > backup-keep-weekly     4
-- > backup-directory       /mnt/backup/wiki      (a destination, or)
-- > backup-rclone          b2:bucket/wiki        (another)
-- > backup-rclone-config   the text of an rclone.conf
-- > backup-last            the last backup made or tried, as JSON
loadBackupSettings :: Connection -> IO KeptBackups
loadBackupSettings c = do
  rows :: [(Text, Text)] <- query_ c "SELECT key, value FROM settings WHERE key LIKE 'backup-%'"
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

-- | Keep the settings, in place of those kept before (the last backup's
-- row is left as it is).
storeBackupSettings :: Connection -> KeptBackups -> IO ()
storeBackupSettings c s = do
  execute_ c "DELETE FROM settings WHERE key LIKE 'backup-%' AND key <> 'backup-last'"
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
  for_ rows $ \(key :: Text, value :: Text) -> execute c "INSERT INTO settings (key, value) VALUES (?, ?)" (key, value)
  where
    twoDigits n = T.justifyRight 2 '0' (show n)

-- | The last backup made or tried, if any is known.
loadLastBackup :: Connection -> IO (Maybe BackupRecord)
loadLastBackup c = do
  rows :: [Only Text] <- query_ c "SELECT value FROM settings WHERE key = 'backup-last'"
  pure (head rows >>= \(Only t) -> decodeStrict' (encodeUtf8 t))

-- | Keep the last backup made or tried, in place of the one before.
storeLastBackup :: Connection -> BackupRecord -> IO ()
storeLastBackup c r =
  execute c "INSERT INTO settings (key, value) VALUES ('backup-last', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value" (Only (decodeUtf8 (toS (encode r)) :: Text))

-- | Make a backup in a directory of backups, named for a time, by an action
-- that writes the copy into the file it is given ('backupInto' on an open
-- connection), and check it: its path and size, or why there is none. A
-- copy that fails its check, or that could not be finished, is deleted:
-- a backup that cannot be restored must not be counted as one, nor be
-- kept in place of a good one.
checkedBackup :: (FilePath -> IO ()) -> FilePath -> UTCTime -> IO (Either Text (FilePath, Integer))
checkedBackup copy dir t = do
  createDirectoryIfMissing True dir
  target <- freshName dir t
  let discard = whenM (doesFileExist target) (removeFile target)
  made <- try @SomeException (copy target)
  case made of
    Left e -> do
      discard
      pure (Left ("The database could not be copied: " <> show e))
    Right () ->
      integrityProblems target >>= \case
        [] -> Right . (target,) <$> getFileSize target
        problems -> do
          discard
          pure (Left ("The copy failed SQLite's integrity check, and was deleted: " <> T.intercalate "; " (take 5 problems)))

-- | What SQLite's @PRAGMA integrity_check@ finds wrong with a database, none
-- if it finds it sound, or that it cannot be opened as one.
integrityProblems :: FilePath -> IO [Text]
integrityProblems file =
  try @SomeException (withConnection file (\c -> query_ c "PRAGMA integrity_check")) <&> \case
    Left e -> ["it cannot be read as a database: " <> show e]
    Right [Only "ok"] -> []
    Right rows -> map fromOnly rows

-- | Delete the backups in a directory that a retention does not keep
-- ('Wiki.Api.Backups.retained'), never this one: what is given back is
-- the files deleted. A file named as a backup is but whose time cannot be
-- read is left alone.
pruneRetained :: FilePath -> Retention -> FilePath -> IO [FilePath]
pruneRetained dir r newest = do
  files <- backupFiles dir
  let timed = [(f, t) | f <- files, Just t <- [backupTime f]]
      keep = retained r (map snd timed)
      gone = [f | (f, t) <- timed, not (t `Set.member` keep), takeFileName f /= takeFileName newest]
  traverse_ removeFile gone
  pure gone

--------------------------------------------------------------------------------
-- What a database refers to

-- | The attachments' files a database refers to: its attachments', and the
-- images its spaces are pictured with. A backup taken before spaces had
-- icons has no column for them, and refers to no image.
referencedBlobs :: Connection -> IO (Set BlobId)
referencedBlobs d = do
  attached <- map (BlobId . fromOnly) <$> query_ d "SELECT DISTINCT blob FROM attachments WHERE blob IS NOT NULL"
  icons <- query_ d "SELECT icon FROM spaces WHERE icon IS NOT NULL" `catch` \(_ :: SQLError) -> pure []
  pure (Set.fromList (attached <> [b | Only t <- icons, Just (IconImage b _) <- [decodeStrict' (encodeUtf8 (t :: Text))]]))

--------------------------------------------------------------------------------
-- The data directory's lock

-- | The lock a server holds on its data directory while it runs.
newtype DataLock = DataLock Handle

-- | Take a data directory's lock (@\<data>/wiki.lock@), or say that
-- something else holds it. The lock is the operating system's (@flock@),
-- held by the open file: it goes with the process however that ends, so a
-- server that crashed leaves nothing to clean up. Within one process the
-- file cannot be opened twice for writing, which says the same.
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

-- | Let a data directory's lock go.
unlockDataDir :: DataLock -> IO ()
unlockDataDir (DataLock h) = hUnlock h `finally` hClose h

--------------------------------------------------------------------------------
-- Restoring

-- | @wiki-server restore BACKUP --data DIR [--attachments DIR]@.
data Restore = Restore
  { backupFile :: FilePath
  -- ^ The backup to put back: one of @data\/backups@, or one copied off
  -- the machine.
  , dataDir :: FilePath
  -- ^ The data directory to put it into, which no server may have open; a
  -- new one is made.
  , attachments :: Maybe FilePath
  -- ^ A copy of the attachments' files (an off-site copy's
  -- @attachments@), to bring into the data directory's those it lacks.
  }
  deriving stock (Eq, Show)

-- | Put a backup back as a data directory's database: the lines to show,
-- or why nothing was done.
--
-- The backup is checked first (a sound SQLite database, of a wiki, at a
-- version of the schema this program knows), and the directory's lock is
-- taken, so that a server running on it, or one started meanwhile, is
-- refused. The database it replaces is not deleted: it is moved, with its
-- @-wal@ and @-shm@, into @replaced\/\<time>\/@ beside it, as it is, so
-- that a restore by mistake can itself be undone, even of a database too
-- damaged to be read. The backup is copied in (it is not moved: it stays
-- among the backups), and the server brings it up to its schema when it
-- next starts. Attachments' files the restored database refers to and
-- the directory lacks are named, so that the operator knows to bring them.
restore :: Restore -> IO (Either Text [Text])
restore r = runExceptT $ do
  present <- liftIO (doesFileExist r.backupFile)
  unless present $ throwError ("There is no file " <> toS r.backupFile <> ".")
  problems <- liftIO (integrityProblems r.backupFile)
  unless (null problems) $ throwError ("The backup " <> toS r.backupFile <> " is not sound: " <> T.intercalate "; " (take 5 problems))
  version <- liftIO (withConnection r.backupFile schemaVersion)
  let known = maybe 0 (\m -> m.version) (lastMay migrations)
  when (version == 0) $ throwError ("The file " <> toS r.backupFile <> " is a database, but not a wiki's.")
  when (version > known) $ throwError ("The backup is at version " <> show version <> " of the schema, newer than this program's " <> show known <> ": restore it with a newer wiki-server.")
  for_ r.attachments $ \dir -> unlessM (liftIO (doesDirectoryExist dir)) $ throwError ("There is no directory " <> toS dir <> " to bring attachments from.")
  lock <- ExceptT (lockDataDir r.dataDir)
  flip finally' (unlockDataDir lock) $ do
    now <- liftIO getCurrentTime
    let database = databaseFile r.dataDir
        aside = r.dataDir </> "replaced" </> formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now
        files = [database, database <> "-wal", database <> "-shm"]
    existing <- liftIO (filterM doesFileExist files)
    unless (null existing) $ liftIO $ do
      createDirectoryIfMissing True aside
      for_ existing $ \f -> renameFile f (aside </> takeFileName f)
    liftIO $ do
      copyFile r.backupFile (database <> ".restoring")
      renameFile (database <> ".restoring") database
    brought <- liftIO (maybe (pure 0) (copyBlobs (attachmentsDir r.dataDir)) r.attachments)
    wanted <- liftIO (withConnection database referencedBlobs)
    stored <- liftIO (storedBlobs (attachmentsDir r.dataDir))
    let missing = Set.size (wanted `Set.difference` stored)
    pure
      ( ["Restored " <> toS r.backupFile <> " as " <> toS database <> "; the server brings it up to its schema when it starts."]
          <> ["The database it replaced is kept in " <> toS aside <> "." | not (null existing)]
          <> ["Brought " <> show brought <> " attachments' files from " <> toS dir <> "." | Just dir <- [r.attachments]]
          <> [ "Warning: "
                 <> show missing
                 <> " of the attachments' files it refers to are not in "
                 <> toS (attachmentsDir r.dataDir)
                 <> ": bring them with --attachments DIR (a copy's attachments directory), or those attachments will be missing."
             | missing > 0
             ]
      )
  where
    finally' :: ExceptT Text IO a -> IO () -> ExceptT Text IO a
    finally' body after = ExceptT (runExceptT body `finally` after)

-- | Copy into a directory of blobs the files of another that it lacks (a
-- blob's file never changes, so one that is there is the right one): how
-- many were copied. Each is written beside its place and moved there, so
-- that an interrupted copy leaves no half of a file under a hash.
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
                -- writing, so that one left behind is collected.
                incoming = shard </> ("incoming-" <> T.unpack b.text)
            createDirectoryIfMissing True shard
            copyFile source incoming
            renameFile incoming target
            pure (1 :: Int)
        )
    _ -> pure 0
  pure (sum copied)
