{-# LANGUAGE MultiWayIf #-}

-- | The backups the server makes by itself (WP4.9 of docs/PLAN.md,
-- "Wiki.Api.Backups"), once an administrator has turned them on in the
-- administration; until then, none. No systemd timer and no option: a
-- thread of the server ('runScheduler') reads the settings the
-- administration keeps in the database, and backs up when they say a
-- backup is due ('Wiki.Api.Backups.nextBackup') or when an administrator
-- asks ('requestBackup').
--
-- A backup is the deploy's ("Wiki.Server.Storage.Backup"): the database
-- copied with @VACUUM INTO@ into @data\/backups\/\<time>.sqlite@, the
-- storage's connection held for the copy alone, so that requests wait for
-- no more than that; then, with nothing held, the copy checked with
-- @PRAGMA integrity_check@ (and deleted if it fails), the old backups
-- pruned to the retention, and, if a destination is set, the new one and
-- the attachments' files copied off the machine ('copyOffSite'). What it
-- came to is kept as the last backup, which the administration shows.
--
-- The thread survives what goes wrong: a failed backup is a backup that
-- failed, kept as such and logged, and an error of the thread's own (the
-- database unreadable for a moment) is logged and tried again a minute
-- later. It waits a minute at most between looks, so a change of the
-- clock costs no more than that, and it is woken at once by a change of
-- the settings ('settingsChanged') and by "Back up now".
module Wiki.Server.Backups
  ( BackupService
  , newBackupService
  , runScheduler
  , currentBackups
  , requestBackup
  , settingsChanged

    -- * Copies off the machine
  , copyOffSite
  , rcloneArgs
  , remotePath
  )
where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar, readTVarIO, registerDelay, writeTVar)
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, listDirectory, removeDirectoryRecursive, renameFile)
import System.FilePath (takeFileName, (</>))
import System.Posix.Files (setFileMode)
import System.Posix.Temp (mkdtemp)
import System.Process (proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)
import Wiki.Api.Backups
import Wiki.App.Backend (WikiError (..))
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Secret (Secret, revealed)
import Wiki.Server.Storage (Storage, Who, copyDatabase, readBackupSettings, readBackups, readLastBackup, storageDataDir, writeLastBackup)
import Wiki.Server.Storage.Backup (KeptBackups, checkedBackup, copyBlobs, pruneRetained)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir)

-- | The thread that backs the server up, and what it is doing.
data BackupService = BackupService
  { storage :: Storage
  , logger :: Logger
  , rclone :: FilePath
  -- ^ The @rclone@ program: its name, found on the path, or its path.
  , doing :: TVar Doing
  }

-- | What the thread is doing, and what it has been asked.
data Doing = Doing
  { requested :: Bool
  -- ^ An administrator has asked for a backup that has not started.
  , running :: Bool
  , finished :: Int
  -- ^ How many backups it has made or tried since the server started,
  -- which whoever asked for one waits to see go up.
  , changes :: Int
  -- ^ How many times the settings have changed, which wakes it.
  }

-- | The service for a storage, which backs up nothing until its thread
-- runs ('runScheduler'), copying off the machine with this @rclone@.
newBackupService :: Logger -> FilePath -> Storage -> IO BackupService
newBackupService logger rclone storage = do
  doing <- newTVarIO Doing {requested = False, running = False, finished = 0, changes = 0}
  pure BackupService {storage, logger, rclone, doing}

-- | The backups as the server answers them: as the storage keeps them, as
-- someone may read them (an administrator), with whether one is under way
-- and when the next is due while they are on.
currentBackups :: BackupService -> Who -> IO (Either WikiError Backups)
currentBackups svc who =
  readBackups svc.storage who >>= \case
    Left e -> pure (Left e)
    Right b -> do
      doing <- readTVarIO svc.doing
      now <- getCurrentTime
      let due = nextBackup b.settings.schedule ((\r -> r.startedAt) <$> b.last) now
      pure
        ( Right
            Backups
              { available = True
              , settings = b.settings
              , last = b.last
              , running = doing.running || doing.requested
              , next = if b.settings.enabled then Just (max now due) else Nothing
              , kept = b.kept
              }
        )

-- | Ask for a backup now, as someone (an administrator), while backups are
-- on: the backups once it is made, or after twenty seconds with it under
-- way. A backup asked for while one is under way is that one.
requestBackup :: BackupService -> Who -> IO (Either WikiError Backups)
requestBackup svc who =
  currentBackups svc who >>= \case
    Left e -> pure (Left e)
    Right b
      | not b.settings.enabled -> pure (Left (Invalid "Backups are off: turn them on first."))
      | otherwise -> do
          before <- atomically $ do
            doing <- readTVar svc.doing
            unless (doing.running || doing.requested) $ writeTVar svc.doing doing {requested = True}
            pure doing.finished
          timer <- registerDelay 20_000_000
          atomically $ do
            doing <- readTVar svc.doing
            late <- readTVar timer
            check (late || doing.finished > before)
          currentBackups svc who

-- | Tell the thread that the settings have changed: it looks at them at
-- once, rather than within the minute.
settingsChanged :: BackupService -> IO ()
settingsChanged svc = atomically (modifyTVar' svc.doing (\d -> d {changes = d.changes + 1}))

-- | The thread: until it is cancelled (the server stopping), back up when
-- a backup is due or asked for, and otherwise wait.
runScheduler :: BackupService -> IO ()
runScheduler svc = do
  orSay "backup-cleanup" (removeLeftovers (storageDataDir svc.storage))
  forever $ do
    seen <- (\d -> d.changes) <$> readTVarIO svc.doing
    waited <- trying (step svc seen)
    case waited of
      Right () -> pass
      Left e -> do
        logWith svc.logger Error [("event", "backup-scheduler"), ("error", show e)]
        sleepOrWake svc seen 60
  where
    orSay event act = trying act >>= either (\e -> logWith svc.logger Warning [("event", event), ("error", show e)]) pure

-- | One look: a backup if one is due or asked for, otherwise a wait until
-- the next is due (a minute at most), or until the thread is woken.
step :: BackupService -> Int -> IO ()
step svc seen = do
  settings <- readBackupSettings svc.storage
  lastMade <- readLastBackup svc.storage
  now <- getCurrentTime
  asked <- (\d -> d.requested) <$> readTVarIO svc.doing
  let due = nextBackup settings.schedule ((\r -> r.startedAt) <$> lastMade) now
  if
    | asked -> backUp svc Manual settings
    | settings.enabled && due <= now -> backUp svc OnSchedule settings
    | otherwise -> sleepOrWake svc seen (if settings.enabled then min 60 (realToFrac (diffUTCTime due now)) else 60)

-- | Wait so many seconds, or until a backup is asked for or the settings
-- change.
sleepOrWake :: BackupService -> Int -> Double -> IO ()
sleepOrWake svc seen seconds = do
  timer <- registerDelay (max 1 (round (seconds * 1_000_000)))
  atomically $ do
    doing <- readTVar svc.doing
    late <- readTVar timer
    check (late || doing.requested || doing.changes /= seen)

-- | Make a backup, and keep what it came to.
backUp :: BackupService -> Trigger -> KeptBackups -> IO ()
backUp svc trigger settings = do
  atomically (modifyTVar' svc.doing (\d -> d {requested = False, running = True}))
  flip finally (atomically (modifyTVar' svc.doing (\d -> d {running = False, finished = d.finished + 1}))) $ do
    let dataDir = storageDataDir svc.storage
    startedAt <- getCurrentTime
    made <- checkedBackup (copyDatabase svc.storage) (backupsDir dataDir) startedAt
    (file, size, failure, offSite) <- case made of
      Left why -> pure (Nothing, Nothing, Just why, Nothing)
      Right (target, bytes) -> do
        pruned <- trying (pruneRetained (backupsDir dataDir) settings.keep target)
        case pruned of
          Left e -> logWith svc.logger Warning [("event", "backup-prune"), ("error", show e)]
          Right gone -> for_ gone $ \f -> logWith svc.logger Info [("event", "backup-pruned"), ("file", toS (takeFileName f))]
        copied <- for settings.destination (copyOffSite svc.rclone dataDir target)
        pure (Just (toS (takeFileName target)), Just bytes, Nothing, copied)
    finishedAt <- getCurrentTime
    let record = BackupRecord {startedAt, finishedAt, trigger, file, size, failure, offSite}
    writeLastBackup svc.storage record
    logWith
      svc.logger
      (if isJust failure || isJust (offSite >>= \o -> o.problem) then Error else Info)
      ( [("event", "backup"), ("trigger", case trigger of OnSchedule -> "schedule"; Manual -> "by-hand")]
          <> [("file", f) | Just f <- [file]]
          <> [("bytes", show b) | Just b <- [size]]
          <> [("error", why) | Just why <- [failure]]
          <> [("off-site", o.to) | Just o <- [offSite]]
          <> [("off-site-error", why) | Just why <- [offSite >>= \o -> o.problem]]
      )

--------------------------------------------------------------------------------
-- Copies off the machine

-- | Copy a backup just made, and the attachments' files, to a destination
-- off the machine: what it came to. The destination is laid out as a data
-- directory is, @backups\/\<time>.sqlite@ and @attachments\/@, so that
-- @wiki-server restore@ takes a copy from there as it takes one from the
-- data directory. Nothing is ever deleted there: what the destination
-- keeps, and for how long, is its own business (a server that has gone
-- wrong cannot then take the copies with it).
--
-- An attachment's file never changes, so only those the destination lacks
-- are copied. A directory must be there already: a disk that is not
-- mounted leaves only an empty mount point, and a copy into it would
-- quietly fill the machine's own disk.
copyOffSite :: FilePath -> FilePath -> FilePath -> DestinationOf (Maybe Secret) -> IO OffSite
copyOffSite rclone dataDir file destination = do
  result <- trying $ case destination of
    ToDirectory dir -> toDirectory (toS dir)
    ToRclone remote config -> toRclone remote config
  pure OffSite {to = destinationText destination, problem = either (Just . show) identity result}
  where
    blobs = attachmentsDir dataDir
    toDirectory dir =
      ifM
        (not <$> doesDirectoryExist dir)
        (pure (Just ("The directory " <> toS dir <> " is not there: is the disk it is on mounted?")))
        ( do
            let into = dir </> "backups"
                incoming = into </> ("incoming-" <> takeFileName file)
            createDirectoryIfMissing True into
            copyFile file incoming
            renameFile incoming (into </> takeFileName file)
            _ <- copyBlobs (dir </> "attachments") blobs
            pure Nothing
        )
    toRclone remote config = withConfig config $ \configFile -> do
      present <- doesDirectoryExist blobs
      let runs = rcloneArgs configFile remote file (if present then Just blobs else Nothing)
      foldlM (\problem args -> maybe (runRclone rclone args) (pure . Just) problem) Nothing runs
    -- The configuration in a file only this user may read, in a
    -- directory only this user may enter, deleted as soon as it has been
    -- used.
    withConfig :: Maybe Secret -> (Maybe FilePath -> IO a) -> IO a
    withConfig = \case
      Nothing -> ($ Nothing)
      Just secret -> \use ->
        bracket (mkdtemp (dataDir </> ".rclone-")) removeDirectoryRecursive $ \dir -> do
          let f = dir </> "rclone.conf"
          writeFile f ""
          setFileMode f 0o600
          writeFile f (revealed secret)
          use (Just f)

-- | The arguments of each run of @rclone@ that copies a backup, and the
-- attachments' files if there are any: the backup to
-- @\<remote>\/backups\/\<name>@, the files to @\<remote>\/attachments@,
-- skipping those there already (@copy@, never @sync@, which would delete).
rcloneArgs :: Maybe FilePath -> Text -> FilePath -> Maybe FilePath -> [[[Char]]]
rcloneArgs configFile remote file blobs =
  [ withConfig ["copyto", file, toS (remotePath remote ("backups/" <> toS (takeFileName file)))]
  ]
    <> [withConfig ["copy", dir, toS (remotePath remote "attachments"), "--ignore-existing"] | Just dir <- [blobs]]
  where
    withConfig args = maybe [] (\c -> ["--config", c]) configFile <> args

-- | A path under a remote: @b2:bucket/wiki@ and @backups@ make
-- @b2:bucket/wiki/backups@, @drive:@ and @backups@ make @drive:backups@.
remotePath :: Text -> Text -> Text
remotePath remote path
  | any (`T.isSuffixOf` remote) [":", "/"] = remote <> path
  | otherwise = remote <> "/" <> path

-- | Run @rclone@ once: nothing if it did what it was asked, or why not. An
-- hour at most; @rclone@ not installed is a failure like another.
runRclone :: FilePath -> [[Char]] -> IO (Maybe Text)
runRclone rclone args =
  try (timeout (3600 * 1_000_000) (readCreateProcessWithExitCode (proc rclone args) "")) <&> \case
    Left (e :: IOException) -> Just ("rclone could not be run (" <> toS rclone <> "): " <> show e)
    Right Nothing -> Just "rclone took more than an hour, and was stopped."
    Right (Just (ExitSuccess, _, _)) -> Nothing
    Right (Just (ExitFailure code, _, err)) -> Just ("rclone failed (exit " <> show code <> "): " <> T.takeEnd 500 (T.strip (toS err)))

-- | Delete what a backup that was cut short left: the directories its
-- @rclone@ configuration was written to.
removeLeftovers :: FilePath -> IO ()
removeLeftovers dataDir = do
  entries <- listDirectory dataDir
  for_ [e | e <- entries, ".rclone-" `isPrefixOf` e] $ \e -> removeDirectoryRecursive (dataDir </> e)

-- | Run something, and give back what it threw (but not what was thrown to
-- the thread to stop it, which goes on).
trying :: IO a -> IO (Either SomeException a)
trying act =
  try act >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other
