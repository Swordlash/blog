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
module Wiki.Server.Storage.Backup
  ( backup
  , backupInto
  , backupFiles
  , pruneBackups
  , defaultKeep
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, defaultTimeLocale, diffTimeToPicoseconds, formatTime, getCurrentTime)
import Database.SQLite.Simple (Connection, Only (..), execute, execute_, withConnection)
import Protolude
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile)
import System.FilePath ((</>))
import Wiki.Server.Storage.Layout (backupsDir, databaseFile)

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
