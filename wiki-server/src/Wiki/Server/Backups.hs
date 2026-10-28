{-# LANGUAGE MultiWayIf #-}

-- | The server's own backups (WP4.9 of docs/PLAN.md, "Wiki.Api.Backups"),
-- once an administrator has turned them on in the administration; until
-- then, none. There is no systemd timer and no option. A thread of the
-- server ('runScheduler') reads the settings the administration stores in
-- the database, and backs up when they say a backup is due
-- ('Wiki.Api.Backups.nextBackup') or when an administrator asks
-- ('requestBackup').
--
-- A backup is the same as the deploy's ("Wiki.Server.Storage.Backup"):
-- the database copied with @VACUUM INTO@ into
-- @data\/backups\/\<time>.sqlite@, with the storage's connection held only
-- for the copy, so that requests wait no longer than that. Then, with
-- nothing held, the copy is checked with @PRAGMA integrity_check@ (and
-- deleted if it fails), the old backups are deleted according to the
-- retention rules, and, if a destination is set, the new backup and the
-- attachment files are copied off the machine ('copyOffSite'). The result
-- is stored as the last backup, which the administration shows.
--
-- The thread survives failures. A failed backup is recorded as failed and
-- logged, and an error of the thread's own (the database unreadable for a
-- moment) is logged and retried a minute later. It waits at most a minute
-- between checks, so a change of the clock costs no more than that, and it
-- is woken at once by a change of the settings ('settingsChanged') and by
-- "Back up now".
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
import Wiki.Server.Storage (Storage, Who, readBackupSettings, readBackups, readLastBackup, storageDataDir, writeLastBackup)
import Wiki.Server.Storage qualified as Storage
import Wiki.Server.Storage.Backup (KeptBackups, copyBlobs, pruneRetained)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir)

-- | The backup thread, and its current state.
data BackupService = BackupService
  { storage :: Storage
  , logger :: Logger
  , rclone :: FilePath
  -- ^ The @rclone@ program: its name, looked up on the path, or its path.
  , doing :: TVar Doing
  }

-- | What the thread is doing, and what it has been asked to do.
data Doing = Doing
  { requested :: Bool
  -- ^ An administrator has requested a backup that has not started.
  , running :: Bool
  , finished :: Int
  -- ^ How many backups it has made or tried since the server started;
  -- whoever requested one waits for this to go up.
  , changes :: Int
  -- ^ How many times the settings have changed, which wakes the thread.
  }

-- | The service for a storage, which backs up nothing until its thread
-- runs ('runScheduler'), copying off the machine with this @rclone@.
newBackupService :: Logger -> FilePath -> Storage -> IO BackupService
newBackupService logger rclone storage = do
  doing <- newTVarIO Doing {requested = False, running = False, finished = 0, changes = 0}
  pure BackupService {storage, logger, rclone, doing}

-- | The backups as the server reports them: as the storage records them,
-- for someone who may read them (an administrator), with whether one is
-- running and, while backups are on, when the next is due.
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

-- | Request a backup now, as an administrator, while backups are on. The
-- result is the backups' state once it is made, or after twenty seconds
-- with it still running. A request while a backup is running waits for
-- that one.
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

-- | Tell the thread that the settings have changed: it reads them at
-- once, rather than within the minute.
settingsChanged :: BackupService -> IO ()
settingsChanged svc = atomically (modifyTVar' svc.doing (\d -> d {changes = d.changes + 1}))

-- | The thread: until it is cancelled (the server stopping), back up when
-- a backup is due or requested, and otherwise wait.
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

-- | One iteration: a backup if one is due or requested, otherwise a wait
-- until the next is due (a minute at most), or until the thread is woken.
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

-- | Wait so many seconds, or until a backup is requested or the settings
-- change.
sleepOrWake :: BackupService -> Int -> Double -> IO ()
sleepOrWake svc seen seconds = do
  timer <- registerDelay (max 1 (round (seconds * 1_000_000)))
  atomically $ do
    doing <- readTVar svc.doing
    late <- readTVar timer
    check (late || doing.requested || doing.changes /= seen)

-- | Make a backup, and store its result.
backUp :: BackupService -> Trigger -> KeptBackups -> IO ()
backUp svc trigger settings = do
  atomically (modifyTVar' svc.doing (\d -> d {requested = False, running = True}))
  flip finally (atomically (modifyTVar' svc.doing (\d -> d {running = False, finished = d.finished + 1}))) $ do
    let dataDir = storageDataDir svc.storage
    startedAt <- getCurrentTime
    made <- Storage.backUp svc.storage startedAt
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

-- | Copy a backup just made, and the attachment files, to a destination
-- off the machine. The result is the outcome. The destination is laid out
-- like a data directory, @backups\/\<time>.sqlite@ (or a PostgreSQL
-- backup's @\<time>.pgdump@ with the @.json@ kept beside it) and
-- @attachments\/@, so
-- that @wiki-server restore@ takes a copy from there as it takes one from
-- the data directory. Nothing is ever deleted there: what the destination
-- keeps, and for how long, is up to it (so a server that has gone wrong
-- cannot destroy the copies).
--
-- An attachment's file never changes, so only those the destination lacks
-- are copied. A directory destination must already exist: a disk that is
-- not mounted leaves only an empty mount point, and a copy into it would
-- silently fill the machine's own disk.
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
            createDirectoryIfMissing True into
            for_ (backupAndBeside file) $ \f -> do
              let incoming = into </> ("incoming-" <> takeFileName f)
              copyFile f incoming
              renameFile incoming (into </> takeFileName f)
            _ <- copyBlobs (dir </> "attachments") blobs
            pure Nothing
        )
    toRclone remote config = withConfig config $ \configFile -> do
      present <- doesDirectoryExist blobs
      let runs = rcloneArgs configFile remote file (if present then Just blobs else Nothing)
      foldlM (\problem args -> maybe (runRclone rclone args) (pure . Just) problem) Nothing runs
    -- The configuration is written to a file only this user may read, in
    -- a directory only this user may enter, and deleted as soon as it has
    -- been used.
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

-- | The arguments of each @rclone@ run that copies a backup, and the
-- attachment files if there are any: the backup to
-- @\<remote>\/backups\/\<name>@, the files to @\<remote>\/attachments@,
-- skipping those already there (@copy@, never @sync@, which would delete).
rcloneArgs :: Maybe FilePath -> Text -> FilePath -> Maybe FilePath -> [[[Char]]]
rcloneArgs configFile remote file blobs =
  [ withConfig ["copyto", f, toS (remotePath remote ("backups/" <> toS (takeFileName f)))]
  | f <- backupAndBeside file
  ]
    <> [withConfig ["copy", dir, toS (remotePath remote "attachments"), "--ignore-existing"] | Just dir <- [blobs]]
  where
    withConfig args = maybe [] (\c -> ["--config", c]) configFile <> args

-- | A backup's file, and the facts kept beside it if it is a PostgreSQL
-- backup ("Wiki.Server.Storage.Backup"): the files a copy of it takes.
backupAndBeside :: FilePath -> [FilePath]
backupAndBeside file = file : [file <> ".json" | ".pgdump" `isSuffixOf` file]

-- | A path under a remote: @b2:bucket/wiki@ and @backups@ make
-- @b2:bucket/wiki/backups@, @drive:@ and @backups@ make @drive:backups@.
remotePath :: Text -> Text -> Text
remotePath remote path
  | any (`T.isSuffixOf` remote) [":", "/"] = remote <> path
  | otherwise = remote <> "/" <> path

-- | Run @rclone@ once. The result is nothing if it succeeded, or why not.
-- An hour at most; @rclone@ not being installed is a failure like any
-- other.
runRclone :: FilePath -> [[Char]] -> IO (Maybe Text)
runRclone rclone args =
  try (timeout (3600 * 1_000_000) (readCreateProcessWithExitCode (proc rclone args) "")) <&> \case
    Left (e :: IOException) -> Just ("rclone could not be run (" <> toS rclone <> "): " <> show e)
    Right Nothing -> Just "rclone took more than an hour, and was stopped."
    Right (Just (ExitSuccess, _, _)) -> Nothing
    Right (Just (ExitFailure code, _, err)) -> Just ("rclone failed (exit " <> show code <> "): " <> T.takeEnd 500 (T.strip (toS err)))

-- | Delete what an interrupted backup left: the directories its @rclone@
-- configuration was written to.
removeLeftovers :: FilePath -> IO ()
removeLeftovers dataDir = do
  entries <- listDirectory dataDir
  for_ [e | e <- entries, ".rclone-" `isPrefixOf` e] $ \e -> removeDirectoryRecursive (dataDir </> e)

-- | Run something, and return what it threw (except what was thrown to
-- the thread to stop it, which propagates).
trying :: IO a -> IO (Either SomeException a)
trying act =
  try act >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other
