-- | 'Maker.Deploy.Move' is @deploy-local.sh --move-to-postgres@ (WP5.80b of
-- docs/PLAN.md, issue #203): it moves the wiki of a deployment on SQLite
-- into PostgreSQL, the PostgreSQL in Docker the deploy runs for a wiki
-- there, and switches the deployment to it. The deployment must be at this
-- checkout's commit, the maker's own version: the move copies the wiki
-- with this checkout's wiki-server, which reads only its own version of
-- the schema.
--
-- The steps, in order, and what a failure at each leaves:
--
-- 1. The checks: a server deployment this script made, with its unit, on
--    SQLite, at this checkout's commit, with its @data\/wiki.sqlite@, a
--    unit that names that file as the deploy writes it, and Docker. A
--    failure changes nothing.
-- 2. The toolchain and the build: @toolchain/check-native.sh@ with
--    PostgreSQL, the bootstrap, and wiki-server built with the flag
--    @postgres@ (a SQLite deployment is built without it). A failure
--    changes nothing of the deployment.
-- 3. PostgreSQL: its files and its container started, as a deploy on
--    PostgreSQL makes them, and its database @wiki@ checked to hold no
--    table. A failure, or a database that holds a wiki, leaves the
--    container as it was found (stopped again when it was stopped).
-- 4. The service stops, and the wiki is backed up into @data\/backups@.
-- 5. @wiki-server copy-database@ copies the SQLite wiki into PostgreSQL,
--    in one transaction that checks every table before it commits.
-- 6. @wiki-server rehearse --move-to-database@ compares the wiki on the
--    two backends with the upgrade's checks, on scratch copies, since the
--    checks write. A failure at 4, 5 or 6 starts the service again on
--    SQLite, as it was, and empties the PostgreSQL database again when
--    this move had filled it.
-- 7. The switch: the SQLite files are set aside into
--    @data\/replaced\/\<time>\/@ (never deleted), the deployment is kept in
--    @previous\/@ for @--rollback@ ("Maker.Deploy.Upgrade"), and the new
--    binary, the console, the unit and the state name PostgreSQL.
-- 8. The service starts, and must answer. A failure at 7 or 8 switches
--    back: the files of @previous\/@ and the SQLite file go back, the
--    PostgreSQL database is emptied again, and the service starts on
--    SQLite.
--
-- The SQLite file is never written: the copy and the comparison only read
-- it, and the switch moves it. The older deployment @previous\/@ held is
-- set aside during the switch and comes back with a switch back; a move
-- that succeeds replaces it with the deployment on SQLite.
module Maker.Deploy.Move
  ( Move (..)
  , moveToPostgres
  , replaceOnce
  , tablesQuery
  )
where

import Control.Exception (SomeException, displayException, finally, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Char (isSpace)
import Data.IORef
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Maker.Deploy.Apply (Place (..), Settings (..), answersWithin, deploymentUrl, pgDown, rollBackDeployment, settingsOf, startAgain, urlAnswers)
import Maker.Deploy.Layout (markedFor, markerName)
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (dockerReady, pgCompose, pgComposeOutput, pgFiles, pgRunning, serverBuildNative, serverCabalOutput)
import Maker.Deploy.Rehearse (rehearsalDatabase)
import Maker.Deploy.State (stateGet, stateReplace)
import Maker.Deploy.Unit (consoleWrapper, databaseWords, dbUrl)
import Maker.Deploy.Upgrade (keepPrevious, previousDir, putAsideBack, readKept, setAside)
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorString, isUserError)
import Text.Read (readMaybe)

-- | 'Move' is what the deploy's front ("Maker.Deploy.Front") gives the
-- move: the checkout, the deployment's places, the checkout's commit
-- (@unknown@ outside a git checkout), PostgreSQL's port (checked already),
-- the build semaphore's choice, and the steps that make the toolchain
-- ready for the build, which run once the checks have passed.
data Move = Move
  { root :: FilePath
  , name :: String
  , prefix :: FilePath
  , adoptable :: Bool
  , stateDir :: FilePath
  , stateFile :: FilePath
  , unitFile :: FilePath
  , checkout :: String
  , dbPort :: String
  , semaphore :: String
  , toolchain :: IO ()
  }

-- | The query that counts the tables of a PostgreSQL database outside
-- PostgreSQL's own schemas: 0 for the empty database the copy needs.
tablesQuery :: String
tablesQuery = "SELECT count(*) FROM pg_catalog.pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"

-- | A text with the one occurrence of a part replaced, or 'Nothing' when
-- the part occurs not exactly once. The move finds the unit's SQLite
-- words this way.
replaceOnce :: String -> String -> String -> Maybe String
replaceOnce from to text = case breakOn text of
  Just (before, after) | Nothing <- breakOn after -> Just (before <> to <> after)
  _ -> Nothing
  where
    breakOn = go ""
    go seen rest
      | from `isPrefixOf` rest = Just (reverse seen, drop (length from) rest)
      | otherwise = case rest of
          c : more -> go (c : seen) more
          [] -> Nothing

-- | Move the deployment's wiki into PostgreSQL, as the module's
-- documentation says.
moveToPostgres :: Move -> IO ()
moveToPostgres m = do
  let prev k = stateGet k m.stateFile
      service = m.name <> ".service"
      pgDir = m.stateDir </> (m.name <> ".postgres")
      named = m.name <> (if null m.prefix then "" else " under " <> m.prefix)
      prefixArg = if null m.prefix then "" else " --prefix " <> m.prefix
      nameArg = if m.name == "wiki-demo" then "" else " --name " <> m.name
      deployCommand = "sh toolchain/deploy-local.sh" <> nameArg <> prefixArg
  stateThere <- doesFileExist m.stateFile
  dir <- prev "dir"
  mode <- prev "mode"
  db <- prev "db"
  commit <- prev "git_commit"

  -- 1. The checks, before anything changes.
  unless (stateThere && mode == "server" && not (null dir)) $
    die ("there is no wiki's server deployed under the name " <> named <> " to move: --move-to-postgres moves a deployment of the wiki's server that this script made")
  when m.adoptable $
    die ("the deployment " <> m.name <> " was made before --prefix, and its state is still in the home directory: deploy it under the prefix first (" <> deployCommand <> "), which adopts it, then move it")
  marked <- markedFor dir m.name
  binary <- doesFileExist (dir </> "bin" </> "wiki-server")
  unless (marked && binary) $
    die (dir <> " does not hold a deployment of the wiki's server that this script made (its " <> markerName <> " and bin/wiki-server): nothing was changed")
  unit <- doesFileExist m.unitFile
  unless unit $
    die (service <> " is not installed (taken down with --stop): deploy it again first (" <> deployCommand <> "), then move it")
  case db of
    "sqlite" -> pure ()
    "postgres" -> die ("the wiki of " <> m.name <> " is in PostgreSQL already (the volume " <> m.name <> "_wiki-db): there is nothing to move")
    _ -> die ("the wiki of " <> m.name <> " is a data/wiki.sqlite of a wiki-server from before PostgreSQL: deploy this checkout with --sqlite first (" <> deployCommand <> " --sqlite --fresh moves that file aside; export the wiki first), then move it")
  when (m.checkout == "unknown") $
    die ("this checkout (" <> m.root <> ") is not a git checkout, so its commit cannot be compared with the deployment's: the move copies the wiki with this checkout's wiki-server, which must be the deployment's own version. Move it from a git checkout of the commit it was deployed from")
  when (null commit || commit == "unknown") $
    die ("the commit " <> m.name <> " was deployed from is not known (its state says " <> (if null commit then "nothing" else commit) <> "), so the move cannot tell that it is this checkout's version, " <> m.checkout <> ". Deploy it from this checkout first (" <> deployCommand <> "), then move it")
  when (commit /= m.checkout) $
    die ("the deployment " <> m.name <> " runs commit " <> commit <> ", and this checkout is at " <> m.checkout <> ": the move copies the wiki with this checkout's wiki-server, which must be the deployment's own version. Deploy this checkout first (" <> deployCommand <> "), or check out " <> commit <> ", then move it")
  let dataDir = dir </> "data"
      sqlite = dataDir </> "wiki.sqlite"
      dbPort = m.dbPort
  sqliteThere <- doesFileExist sqlite
  unless sqliteThere $
    die ("there is no " <> sqlite <> " to move: the deployment's wiki is not where the deploy keeps it")
  unitText <- readStrict m.unitFile
  newUnit <- case replaceOnce (databaseWords "sqlite" dir "" pgDir) (databaseWords "postgres" dir dbPort pgDir) unitText of
    Just t -> pure t
    Nothing -> die (m.unitFile <> " does not run wiki-server on " <> sqlite <> " as the deploy writes it: deploy this checkout first (" <> deployCommand <> "), then move it")
  docker <- dockerReady
  unless docker $
    die "the wiki moves into PostgreSQL in Docker (docker compose), and Docker is not installed here or does not answer (docker info): install Docker and its compose plugin first; nothing was changed"

  -- 2. The toolchain and the build: nothing of the deployment changes.
  say ("moving the wiki of " <> m.name <> " from " <> sqlite <> " into PostgreSQL")
  m.toolchain
  let plan = set "root" m.root . set "name" m.name . set "db" "postgres" . set "db_port" dbPort . set "opt_semaphore" m.semaphore $ parsePlan ""
  say "building wiki-server with PostgreSQL at -O2 (cabal-native-opt.project)"
  serverBuildNative plan
  (listed, found) <- serverCabalOutput plan "list-bin" ["-v0"]
  let newBin = takeWhile (/= '\n') found
  usable <- if listed && not (null newBin) then doesFileExist newBin else pure False
  unless usable (die "the build of wiki-server with PostgreSQL left no program (cabal list-bin), so nothing was changed")

  -- 3. PostgreSQL, as a deploy on PostgreSQL brings it up.
  dbWasRunning <- pgRunning m.name pgDir
  pgFiles plan pgDir
  let leaveDb = unless dbWasRunning (pgDown m.name pgDir dbPort)
      psqlIn database statement = do
        code <- pgCompose m.name pgDir dbPort ["exec", "-T", "postgres", "psql", "--quiet", "--username=wiki", "--dbname=" <> database, "--command", statement]
        pure (code == ExitSuccess)
  say ("starting PostgreSQL in Docker (the compose project " <> m.name <> ", on 127.0.0.1:" <> dbPort <> ") and waiting for it")
  up <- pgCompose m.name pgDir dbPort ["up", "--detach", "--wait", "postgres"]
  unless (up == ExitSuccess) $ do
    leaveDb
    die "PostgreSQL did not start (see above): if the port is taken, choose another with --db-port. The wiki was not touched: it runs on SQLite as it did"
  (asked, answer) <- pgComposeOutput m.name pgDir dbPort ["exec", "-T", "postgres", "psql", "--quiet", "--username=wiki", "--dbname=wiki", "--tuples-only", "--no-align", "--command", tablesQuery]
  case (asked, readMaybe (trim answer) :: Maybe Int) of
    (True, Just 0) -> pure ()
    (True, Just tables) -> do
      leaveDb
      die
        ( "PostgreSQL's database wiki of "
            <> m.name
            <> " holds a wiki already ("
            <> show tables
            <> " tables, in the volume "
            <> m.name
            <> "_wiki-db): one this deployment kept there before it moved to SQLite, or one a move left before a --rollback. It is left as it is, and nothing was changed. To move this wiki there instead, keep what you need of that one (an export, with a server on it), then delete the volume: docker compose --project-name "
            <> m.name
            <> " rm --stop --force postgres && docker volume rm "
            <> m.name
            <> "_wiki-db"
        )
    _ -> do
      leaveDb
      die "PostgreSQL's database wiki could not be read (see above), so the move cannot tell that it is empty. The wiki was not touched: it runs on SQLite as it did"

  -- 4. From here the running deployment changes.
  wasRunning <- succeeds "systemctl" ["--user", "is-active", "--quiet", service]
  node <- findExecutable "node"
  let answers = urlAnswers node
      emptyAgain = do
        say "emptying PostgreSQL's database wiki again, which this move filled"
        dropped <- psqlIn "postgres" "DROP DATABASE wiki"
        made <- if dropped then psqlIn "postgres" "CREATE DATABASE wiki" else pure False
        unless made $
          warn ("PostgreSQL's database wiki could not be emptied again (see above): it holds the copy, and a next --move-to-postgres refuses it until the volume " <> m.name <> "_wiki-db is deleted")
      onSqliteAgain = do
        if wasRunning
          then do
            url <- deploymentUrl m.stateFile
            started <- startAgain service answers url
            if started
              then say (service <> " runs again on SQLite and answers on " <> url)
              else warn (service <> " does not answer on " <> url <> " after it started again on SQLite; see journalctl --user -u " <> m.name)
          else say (service <> " is left stopped, as it was before the move")
      beforeSwitch filled why = do
        when filled emptyAgain
        leaveDb
        onSqliteAgain
        die (why <> ". The wiki stays on SQLite, as it was; " <> sqlite <> " was not changed")
  say ("stopping " <> service)
  _ <- runInherit "systemctl" ["--user", "stop", service]
  say ("backing the wiki up into " <> dataDir </> "backups")
  backedUp <- runInherit (dir </> "bin" </> "wiki-server") ["backup", "--data", dataDir, "--sqlite", sqlite]
  unless (backedUp == ExitSuccess) $
    beforeSwitch False ("the backup of " <> sqlite <> " failed (see above), so the move stopped before it copied anything")

  -- 5. The copy.
  say "copying the wiki into PostgreSQL (wiki-server copy-database), in one transaction that checks every table"
  copied <- runInherit newBin ["copy-database", "--data", dataDir, "--sqlite", sqlite, "--to-database", dbUrl dbPort, "--to-database-password-file", pgDir </> "db-password"]
  case copied of
    ExitSuccess -> pure ()
    ExitFailure 4 -> beforeSwitch False ("the wiki is at another version of the schema than this checkout's wiki-server copies (see above): deploy this checkout first (" <> deployCommand <> "), then move it")
    ExitFailure 5 -> beforeSwitch False ("some of the wiki does not read whole (see above; " <> dir </> "bin" </> "wiki check --data " <> dataDir <> " says more), so it was not copied")
    ExitFailure 6 -> beforeSwitch False "the copy was refused before anything was written (see above)"
    ExitFailure _ -> beforeSwitch False "the copy failed (see above), and PostgreSQL's database is empty, as it was"

  -- 6. The comparison, on copies of both: the checks write.
  say "comparing the wiki in PostgreSQL with the wiki in SQLite (wiki-server rehearse --move-to-database, on scratch copies)"
  let scratch = m.stateDir </> (m.name <> ".rehearsal")
      scratchUrl = "postgres://wiki@127.0.0.1:" <> dbPort <> "/" <> rehearsalDatabase
      dropScratch = psqlIn "wiki" ("DROP DATABASE IF EXISTS " <> rehearsalDatabase)
  removePathForcibly scratch
  ready <- (&&) <$> dropScratch <*> psqlIn "wiki" ("CREATE DATABASE " <> rehearsalDatabase)
  unless ready $
    beforeSwitch True ("the comparison's scratch database " <> rehearsalDatabase <> " could not be made (see above)")
  compared <-
    runInherit newBin ["rehearse", "--old", newBin, "--data", dataDir, "--sqlite", sqlite, "--scratch", scratch, "--move-to-database", scratchUrl, "--move-to-database-password-file", pgDir </> "db-password"]
      `finally` (removePathForcibly scratch >> dropScratch)
  case compared of
    ExitSuccess -> say "the comparison passed: the wiki reads the same in PostgreSQL as in SQLite"
    ExitFailure 6 -> beforeSwitch True "the wiki does not read the same in PostgreSQL as in SQLite (see above)"
    ExitFailure _ -> beforeSwitch True "the comparison of the wiki in PostgreSQL with the wiki in SQLite could not be made (see above)"

  -- 7. The switch. What is done is noted, so that a failure undoes it.
  let olderPrevious = dir </> "previous.before-move"
  hadPrevious <- doesDirectoryExist (previousDir dir)
  aside <- newIORef Nothing
  switched <- try @SomeException $ do
    removePathForcibly olderPrevious
    when hadPrevious (renameDirectory (previousDir dir) olderPrevious)
    moved <- setAside dir
    writeIORef aside moved
    case moved of
      Just at -> say ("moved " <> sqlite <> " aside into " <> at <> ", where it is kept")
      Nothing -> throwIO (userError (sqlite <> " was not there to set aside"))
    kept <- keepPrevious dir m.unitFile m.stateFile commit Nothing wasRunning dbWasRunning (fromMaybe "" moved) ""
    unless kept (throwIO (userError "the deployment could not be kept in previous/"))
    _ <- runInherit "cp" ["-R", previousDir dir </> "app", dir </> "app"]
    createDirectoryIfMissing True (dir </> "bin")
    copyFile newBin (dir </> "bin" </> "wiki-server")
    setPermissions (dir </> "bin" </> "wiki-server") . setOwnerExecutable True =<< getPermissions (dir </> "bin" </> "wiki-server")
    writeFile (dir </> "bin" </> "wiki") (consoleWrapper m.name dir "postgres" dbPort pgDir)
    setPermissions (dir </> "bin" </> "wiki") . setOwnerExecutable True =<< getPermissions (dir </> "bin" </> "wiki")
    writeFile (m.unitFile <> ".tmp") newUnit
    renameFile (m.unitFile <> ".tmp") m.unitFile
    stateReplace [("db", "postgres"), ("db_port", dbPort)] m.stateFile
    reloaded <- runInherit "systemctl" ["--user", "daemon-reload"]
    unless (reloaded == ExitSuccess) (throwIO (userError "systemctl --user daemon-reload failed (see above)"))
  let switchBack why = do
        warn (why <> "; switching " <> m.name <> " back to SQLite")
        _ <- runInherit "systemctl" ["--user", "stop", service]
        emptyAgain
        mk <- readKept dir
        case mk of
          Just k -> do
            old <- settingsOf (previousDir dir </> "state")
            let place = Place {name = m.name, dir = dir, unitFile = m.unitFile, stateFile = m.stateFile, stateDir = m.stateDir, pgDir = pgDir, noFirewall = True}
                now = Settings {rulePort = old.rulePort, servePort = old.servePort, db = "postgres", dbPort = dbPort}
            restored <- rollBackDeployment place Nothing now k
            unless restored $
              die (why <> "; the switch back stopped before the files went back (see above): the deployment on SQLite is in " <> previousDir dir <> ", and --rollback puts it back once the cause is fixed")
          Nothing -> do
            -- The deployment was not kept whole: what moved goes back.
            forM_ ["bin", "app"] $ \d -> do
              keptThere <- doesDirectoryExist (previousDir dir </> d)
              here <- doesDirectoryExist (dir </> d)
              when (keptThere && not here) (renameDirectory (previousDir dir </> d) (dir </> d))
            removePathForcibly (previousDir dir)
            readIORef aside >>= mapM_ (putAsideBack dir)
        when hadPrevious $ do
          removePathForcibly (previousDir dir)
          renameDirectory olderPrevious (previousDir dir)
        when dbWasRunning $ do
          _ <- pgCompose m.name pgDir dbPort ["up", "--detach", "--wait", "postgres"]
          pure ()
        onSqliteAgain
        die (why <> ": switched back to SQLite, as it was before the move, " <> sqlite <> " unchanged")
  case switched of
    Left e -> switchBack ("the switch to PostgreSQL failed (" <> reason e <> ")")
    Right () -> pure ()

  -- 8. The start.
  say ("starting " <> service <> " on PostgreSQL")
  restarted <- runInherit "systemctl" ["--user", "restart", service]
  unless (restarted == ExitSuccess) $
    switchBack ("systemctl --user restart " <> service <> " failed (see above)")
  url <- deploymentUrl m.stateFile
  started <- answersWithin service answers url
  unless started $ do
    _ <- runInherit "systemctl" ["--user", "status", service, "--no-pager"]
    switchBack (service <> " does not answer on " <> url <> " on PostgreSQL; see journalctl --user -u " <> m.name)
  removePathForcibly olderPrevious
  say (service <> " answers on " <> url <> ", on PostgreSQL")
  adminPort <- stateGet "admin_port" m.stateFile
  admin <- answers ("http://127.0.0.1:" <> adminPort <> "/admin/api/v1/admin/status")
  unless admin $ warn ("its admin listener does not answer on http://127.0.0.1:" <> adminPort <> "/admin/; see journalctl --user -u " <> m.name)
  movedTo <- fromMaybe "" <$> readIORef aside
  putStr $
    unlines
      [ ""
      , "The wiki of " <> m.name <> " is in PostgreSQL now, in Docker (docker compose --project-name " <> m.name <> " ps), on"
      , "127.0.0.1:" <> dbPort <> ", its data in the volume " <> m.name <> "_wiki-db; its password is in " <> pgDir <> "/db-password."
      , "Every deploy from now on builds and runs wiki-server with PostgreSQL."
      , "The SQLite file is kept in " <> movedTo <> ", and its backup from just before the move"
      , "in " <> dataDir </> "backups" <> ". --rollback goes back to the wiki on SQLite: what is written"
      , "in PostgreSQL meanwhile is not in it, and stays in the volume."
      ]

-- | Why a step of the switch failed, in words: the message of a failure
-- the switch raised itself, or the exception as it shows.
reason :: SomeException -> String
reason e = case fromException e of
  Just io | isUserError io -> ioeGetErrorString io
  _ -> displayException e

-- | A text without the spaces around it.
trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | A file's text, read whole before it is used.
readStrict :: FilePath -> IO String
readStrict file = do
  text <- readFile file
  length text `seq` pure text
