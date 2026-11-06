-- | The previous deployment of a server kept beside the new one, and the
-- way back to it (WP5.73 of docs/PLAN.md). The maker is the oracle of an
-- upgrade: before the new files go into place it moves the old binary,
-- page, unit and state into @previous/@ under the deployment, with the
-- commit they were built from and a copy of the backup of the database the
-- deploy made just before (a copy, because the server's own backups prune
-- @data/backups@); after them it runs the new program's @wiki-server
-- migrate@ and @wiki-server check@. When either fails, or the new server
-- does not answer, the deploy puts the previous deployment back: the
-- database restored from that backup ('restoreDatabase'), the old files,
-- unit and state ('putBackFiles'), and the settings outside them
-- reconciled (Maker.Deploy.Apply's 'rollBackDeployment'). A successful upgrade keeps
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
  , restoreDatabase
  , putBackFiles
  )
where

import Control.Monad (forM_, unless, when)
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
-- replaced it, in @previous/@ (empty when there was no database yet), when
-- it was kept, whether its service was running when the deploy began, and
-- whether it had a unit (it has none after @--stop@), and whether its
-- PostgreSQL container was running. A rollback starts the service only if
-- it was running, removes the unit only if there was none, and stops the
-- container only if it was stopped. An @info@ written before these two were recorded counts as running
-- with a unit, which is what such a deploy required.
data Kept = Kept
  { commit :: String
  , backup :: FilePath
  , keptAt :: String
  , running :: Bool
  , unit :: Bool
  , dbRunning :: Bool
  }
  deriving (Eq, Show)

-- | Where a deployment keeps the one before it.
previousDir :: FilePath -> FilePath
previousDir dir = dir </> "previous"

-- | Move a server deployment's binary and page into @previous/@ under it,
-- with copies of its unit (when it has one) and state file, of the backup
-- (with the facts file a PostgreSQL backup has beside it), and what 'Kept'
-- records, in place of an older one kept there. Nothing is kept when the
-- directory holds no server binary (a first deploy, or a demo before). The
-- answer is whether a deployment was kept.
keepPrevious :: FilePath -> FilePath -> FilePath -> String -> Maybe FilePath -> Bool -> Bool -> IO Bool
keepPrevious dir unitFile stateFile commit backup running dbRunning = do
  let previous = previousDir dir
  removePathForcibly previous
  there <- doesFileExist (dir </> "bin" </> "wiki-server")
  when there $ do
    createDirectoryIfMissing True previous
    -- The owner's only, as data/ is: it holds a copy of the database.
    _ <- runInherit "chmod" ["700", previous]
    forM_ ["bin", "app"] $ \d -> do
      exists <- doesDirectoryExist (dir </> d)
      when exists (renameDirectory (dir </> d) (previous </> d))
    hasUnit <- doesFileExist unitFile
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
    let yesNo b = if b then "yes" else "no"
    writeFile
      (previous </> "info")
      ( unlines
          [ "commit=" <> (if null commit then "unknown" else commit)
          , "backup=" <> copied
          , "kept=" <> formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" now
          , "running=" <> yesNo running
          , "unit=" <> yesNo hasUnit
          , "db_running=" <> yesNo dbRunning
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
      length text `seq` pure (Just Kept {commit = value "commit", backup = value "backup", keptAt = value "kept", running = value "running" /= "no", unit = value "unit" /= "no", dbRunning = value "db_running" /= "no"})

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

-- | Restore the database of the kept deployment from the copy of the
-- backup made before the deployment that replaced it, with the kept
-- binary, which reads it. The service must be stopped. Nothing is done
-- when no backup was made (there was no database yet). The answer is
-- whether the database is back; a rollback that fails here stops, since
-- the old binary must not run on the migrated database.
restoreDatabase :: FilePath -> [String] -> Kept -> IO Bool
restoreDatabase dir placeArgs kept
  | null kept.backup = pure True
  | otherwise = do
      say ("restoring the database from " <> kept.backup)
      restored <- runInherit (previousDir dir </> "bin" </> "wiki-server") (["restore", kept.backup] <> placeArgs)
      unless (restored == ExitSuccess) $
        warn ("the restore of " <> kept.backup <> " failed (see above), so the rollback stopped there: the service is stopped, and the previous deployment is still in " <> previousDir dir)
      pure (restored == ExitSuccess)

-- | Put the kept deployment's files back in place of the current one's:
-- the binary and page moved back, the state file copied back, and the
-- unit copied back, or, for a deployment that had none (after @--stop@),
-- the new unit disabled and removed. @previous/@ goes, and systemd reloads
-- its units. The service is left stopped: the caller starts it if it was
-- running.
putBackFiles :: FilePath -> FilePath -> FilePath -> String -> Kept -> IO ()
putBackFiles dir unitFile stateFile service kept = do
  let previous = previousDir dir
  forM_ ["bin", "app"] $ \d -> do
    back <- doesDirectoryExist (previous </> d)
    when back $ do
      removePathForcibly (dir </> d)
      renameDirectory (previous </> d) (dir </> d)
  copyFile (previous </> "state") stateFile
  if kept.unit
    then copyFile (previous </> "unit") unitFile
    else do
      say ("removing the unit the deploy wrote: " <> service <> " had none before it (taken down with --stop)")
      _ <- runInherit "systemctl" ["--user", "disable", service]
      removePathForcibly unitFile
  removePathForcibly previous
  _ <- runInherit "systemctl" ["--user", "daemon-reload"]
  pure ()
