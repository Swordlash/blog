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
  , setAside
  , asideName
  , putAsideBack
  , unadopt
  )
where

import Control.Monad (forM_, unless, when)
import Data.List (sort, (\\))
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Maker.Deploy.Plan
import Maker.Deploy.State (stateSet)
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, takeFileName, (</>))

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
--
-- Two more fields are for an upgrade that started an empty wiki (a switch
-- between SQLite and PostgreSQL, or @--fresh@), and for an adoption under
-- @--prefix@. 'aside' is the directory under @data/replaced/@ the upgrade
-- moved the old @wiki.sqlite@ into (empty when it moved none): the
-- rollback moves it back, and there is no backup to restore then, since
-- the backup was taken of the new, empty wiki. 'adoptedFrom' is the state
-- file the deployment had before the adoption (empty when there was
-- none): the rollback moves the state, and the PostgreSQL directory kept
-- in @previous/postgres@, back beside it.
data Kept = Kept
  { commit :: String
  , backup :: FilePath
  , keptAt :: String
  , running :: Bool
  , unit :: Bool
  , dbRunning :: Bool
  , aside :: FilePath
  , adoptedFrom :: FilePath
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
-- answer is whether a deployment was kept. The last two arguments are
-- 'aside' and 'adoptedFrom' of 'Kept'.
keepPrevious :: FilePath -> FilePath -> FilePath -> String -> Maybe FilePath -> Bool -> Bool -> FilePath -> FilePath -> IO Bool
keepPrevious dir unitFile stateFile commit backup running dbRunning aside adoptedFrom = do
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
          , "aside=" <> aside
          , "adopted_from=" <> adoptedFrom
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
      length text `seq` pure (Just Kept {commit = value "commit", backup = value "backup", keptAt = value "kept", running = value "running" /= "no", unit = value "unit" /= "no", dbRunning = value "db_running" /= "no", aside = value "aside", adoptedFrom = value "adopted_from"})

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

-- | The SQLite files of a wiki: the database and the two files SQLite
-- keeps beside it while it runs in WAL mode.
sqliteFiles :: [FilePath]
sqliteFiles = ["wiki.sqlite", "wiki.sqlite-wal", "wiki.sqlite-shm"]

-- | Move a deployment's @data/wiki.sqlite@ (with its @-wal@ and @-shm@)
-- into a new directory under @data/replaced/@, named by the time. The
-- answer is that directory, or 'Nothing' when there was no
-- @wiki.sqlite@ to move. Nothing is deleted: the files are kept there for
-- whoever wants them back.
setAside :: FilePath -> IO (Maybe FilePath)
setAside dir = do
  let dataDir = dir </> "data"
  present <- doesFileExist (dataDir </> "wiki.sqlite")
  if not present
    then pure Nothing
    else do
      now <- getCurrentTime
      let replaced = dataDir </> "replaced"
      there <- doesDirectoryExist replaced
      taken <- if there then listDirectory replaced else pure []
      let aside = replaced </> asideName taken (formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" now)
      createDirectoryIfMissing True aside
      forM_ sqliteFiles $ \file -> do
        exists <- doesFileExist (dataDir </> file)
        when exists (renameFile (dataDir </> file) (aside </> file))
      pure (Just aside)

-- | The name of a new directory under @data/replaced/@: the time, or the
-- time with @-2@, @-3@ and so on when a directory of that name is there
-- already. An upgrade and its rollback can set a wiki aside within the
-- same second, and the second must not land on the first.
asideName :: [FilePath] -> String -> FilePath
asideName taken stamp = case [n | n <- stamp : [stamp <> "-" <> show i | i <- [2 :: Int ..]], n `notElem` taken] of
  n : _ -> n
  [] -> stamp

-- | Move the SQLite files an upgrade set aside back into the deployment's
-- @data/@, and remove their directory under @data/replaced/@ when nothing
-- else is in it. The caller has set aside what was in their place.
putAsideBack :: FilePath -> FilePath -> IO ()
putAsideBack dir aside = do
  there <- doesDirectoryExist aside
  when there $ do
    forM_ sqliteFiles $ \file -> do
      exists <- doesFileExist (aside </> file)
      when exists (renameFile (aside </> file) (dir </> "data" </> file))
    left <- listDirectory aside
    when (null left) (removeDirectory aside)
    say ("put the wiki set aside in " <> aside <> " back into " <> dir </> "data")
  -- previous/info stops naming the directory once the files are back, so
  -- that a --rollback retried after this point does not set the restored
  -- wiki aside again as if it were the one the upgrade started.
  infoThere <- doesFileExist (previousDir dir </> "info")
  when infoThere (stateSet "aside" "" (previousDir dir </> "info"))

-- | Undo an adoption under @--prefix@ before the rollback puts the files
-- back: the PostgreSQL directory kept in @previous/postgres@ moves back
-- beside the state file the deployment had before ('adoptedFrom'), and
-- the copy the adoption made under the prefix goes. The state file itself
-- is moved by the caller, with the other files.
unadopt :: FilePath -> String -> FilePath -> Kept -> IO ()
unadopt dir name newPgDir kept = do
  let oldStateDir = takeDirectory kept.adoptedFrom
      oldPgDir = oldStateDir </> (name <> ".postgres")
      keptPg = previousDir dir </> "postgres"
  createDirectoryIfMissing True oldStateDir
  moved <- doesDirectoryExist keptPg
  when moved $ do
    removePathForcibly oldPgDir
    -- mv, not rename(2): the prefix may be on another filesystem than the
    -- home directory, as when the adoption copied it.
    _ <- runInherit "mv" [keptPg, oldPgDir]
    pure ()
  oldThere <- doesDirectoryExist oldPgDir
  when (oldThere && newPgDir /= oldPgDir) (removePathForcibly newPgDir)
  say ("moving " <> name <> "'s state back to " <> oldStateDir <> ", where it was before the adoption under the prefix")
