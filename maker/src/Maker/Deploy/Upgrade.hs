-- | The previous deployment of a server kept beside the new one, and the
-- way back to it (WP5.73 of docs/PLAN.md). The maker is the oracle of an
-- upgrade: before the new files go into place it moves the old binary,
-- page, unit and state into @previous/@ under the deployment, with the
-- commit they were built from and a copy of the backup of the database the
-- deploy made just before (a copy, because the server's own backups prune
-- @data/backups@); after them it runs the new program's @wiki-server
-- migrate@ and @wiki-server check@. When either fails, or the new server
-- does not answer, the deploy puts the previous deployment back
-- ('restorePrevious'): the database restored from that backup, the old
-- files, unit and state, the service restarted. A deployment is kept only
-- when the upgrade changes nothing outside these files (the database's
-- kind and port, the listening address, the way HTTPS is served), so that
-- putting the files back puts the whole deployment back. A successful upgrade keeps
-- @previous/@ too, since what broke may show only later; @deploy-local.sh
-- --rollback@ goes back to it by hand. The next upgrade replaces it with
-- the deployment it replaces, so one deployment back is kept.
module Maker.Deploy.Upgrade
  ( Kept (..)
  , previousDir
  , keepPrevious
  , readKept
  , newBackup
  , migrateAndCheck
  , restorePrevious
  )
where

import Control.Monad (forM_, when)
import Data.List (sort, (\\))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Maker.Deploy.Plan
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (takeFileName, (</>))

-- | 'Kept' is what @previous/info@ says of the deployment kept there: the
-- commit it was built from (@unknown@ when the deploy did not know it),
-- the copy of the backup of the database made before the deployment that
-- replaced it, in @previous/@ (empty when there was no database yet), and
-- when it was kept.
data Kept = Kept
  { commit :: String
  , backup :: FilePath
  , keptAt :: String
  }
  deriving (Eq, Show)

-- | Where a deployment keeps the one before it.
previousDir :: FilePath -> FilePath
previousDir dir = dir </> "previous"

-- | Move a server deployment's binary and page into @previous/@ under it,
-- with copies of its unit and state file, of the backup (with the facts
-- file a PostgreSQL backup has beside it), and what 'Kept' records, in
-- place of an older one kept there. Nothing is kept when the directory
-- holds no server binary (a first deploy, or a demo before) or the unit is
-- gone (after --stop). The answer
-- is whether a deployment was kept.
keepPrevious :: FilePath -> FilePath -> FilePath -> String -> Maybe FilePath -> IO Bool
keepPrevious dir unitFile stateFile commit backup = do
  -- A deployment whose unit is gone (taken down with --stop) is not kept:
  -- the deploy writes a new unit, which a rollback could not undo.
  let previous = previousDir dir
  removePathForcibly previous
  server <- doesFileExist (dir </> "bin" </> "wiki-server")
  unit <- doesFileExist unitFile
  when (server && not unit) $
    say "the deployment it replaces is not kept for a rollback: its unit is gone (taken down with --stop), and the new one could not be undone"
  let there = server && unit
  when there $ do
    createDirectoryIfMissing True previous
    -- The owner's only, as data/ is: it holds a copy of the database.
    _ <- runInherit "chmod" ["700", previous]
    forM_ ["bin", "app"] $ \d -> do
      exists <- doesDirectoryExist (dir </> d)
      when exists (renameDirectory (dir </> d) (previous </> d))
    forM_ [(unitFile, "unit"), (stateFile, "state")] $ \(from, to) -> do
      exists <- doesFileExist from
      when exists (copyFile from (previous </> to))
    copied <- case backup of
      Nothing -> pure ""
      Just file -> do
        let to = previous </> takeFileName file
        copyFile file to
        facts <- doesFileExist (file <> ".json")
        when facts (copyFile (file <> ".json") (to <> ".json"))
        pure to
    now <- getCurrentTime
    writeFile
      (previous </> "info")
      ( unlines
          [ "commit=" <> (if null commit then "unknown" else commit)
          , "backup=" <> copied
          , "kept=" <> formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" now
          ]
      )
    say ("kept the previous deployment (" <> (if null commit then "unknown" else commit) <> ") in " <> previous <> ", for a rollback")
  pure there

-- | What @previous/info@ under a deployment says, if a deployment is kept
-- there with its binary.
readKept :: FilePath -> IO (Maybe Kept)
readKept dir = do
  let previous = previousDir dir
  info <- doesFileExist (previous </> "info")
  binary <- doesFileExist (previous </> "bin" </> "wiki-server")
  if not (info && binary)
    then pure Nothing
    else do
      text <- readFile (previous </> "info")
      let fields = mapMaybe field (lines text)
          field l = case break (== '=') l of
            (k, '=' : rest) -> Just (k, rest)
            _ -> Nothing
          value k = maybe "" id (lookup k fields)
      length text `seq` pure (Just Kept {commit = value "commit", backup = value "backup", keptAt = value "kept"})

-- | The backup a backup command made: the newest of the backups listed
-- after it that were not listed before it. A backup's name starts with its
-- time, so the newest sorts last.
newBackup :: [FilePath] -> [FilePath] -> Maybe FilePath
newBackup before after = listToMaybe (reverse (sort (filter isBackup (after \\ before))))
  where
    isBackup f = any (`endsWith` f) [".sqlite", ".pgdump"]
    endsWith suffix f = reverse suffix == take (length suffix) (reverse f)

-- | Run the new program's @migrate@, then its @check@, on the deployment's
-- database. The answer is why the database cannot be served by it, if it
-- cannot: the command that failed, whose output is on the terminal.
migrateAndCheck :: FilePath -> [String] -> IO (Maybe String)
migrateAndCheck serverBin placeArgs = do
  say "migrating the database to the new wiki-server's schema"
  migrated <- runInherit serverBin ("migrate" : placeArgs)
  if migrated /= ExitSuccess
    then pure (Just "the migration of the database (wiki-server migrate, above) failed")
    else do
      say "reading every table and record back with the new wiki-server"
      checked <- runInherit serverBin ("check" : placeArgs)
      pure $ case checked of
        ExitSuccess -> Nothing
        _ -> Just "the migrated database does not read back (wiki-server check, above)"

-- | Put the kept deployment back in place of the current one: the service
-- stopped, the database restored from the copy of the backup made before
-- the deployment that replaced it (by the kept binary, which reads it),
-- the binary and page moved back, the unit and state file copied back, the
-- service restarted. A restore that fails stops the rollback there, with
-- the service stopped and @previous/@ left as it is, since the old binary
-- must not run on the migrated database. The answer is whether the
-- rollback was made.
restorePrevious :: FilePath -> FilePath -> FilePath -> String -> [String] -> Kept -> IO Bool
restorePrevious dir unitFile stateFile service placeArgs kept = do
  let previous = previousDir dir
      oldBin = previous </> "bin" </> "wiki-server"
  say ("rolling back to the previous deployment (" <> kept.commit <> "), kept in " <> previous)
  _ <- runInherit "systemctl" ["--user", "stop", service]
  restored <-
    if null kept.backup
      then pure ExitSuccess
      else do
        say ("restoring the database from " <> kept.backup)
        runInherit oldBin (["restore", kept.backup] <> placeArgs)
  if restored /= ExitSuccess
    then do
      warn ("the restore of " <> kept.backup <> " failed (see above), so the rollback stopped there: " <> service <> " is stopped, and the previous deployment is still in " <> previous)
      pure False
    else do
      forM_ ["bin", "app"] $ \d -> do
        back <- doesDirectoryExist (previous </> d)
        when back $ do
          removePathForcibly (dir </> d)
          renameDirectory (previous </> d) (dir </> d)
      forM_ [("unit", unitFile), ("state", stateFile)] $ \(from, to) -> do
        exists <- doesFileExist (previous </> from)
        when exists (copyFile (previous </> from) to)
      removePathForcibly previous
      _ <- runInherit "systemctl" ["--user", "daemon-reload"]
      _ <- runInherit "systemctl" ["--user", "restart", service]
      pure True
