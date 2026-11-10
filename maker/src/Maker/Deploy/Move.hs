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
-- 4. The service stops (and must be stopped), and the wiki is backed up
--    into @data\/backups@.
-- 5. @wiki-server copy-database@ copies the SQLite wiki into PostgreSQL,
--    in one transaction that checks every table before it commits.
-- 6. @wiki-server rehearse --move-to-database@ compares the wiki on the
--    two backends with the upgrade's checks, on scratch copies, since the
--    checks write. A failure at 4, 5 or 6 starts the service again on
--    SQLite, as it was, and empties the PostgreSQL database again when
--    this move had filled it (it was empty before the copy). An exception
--    in these steps is handled the same way, so the service is never left
--    stopped by one.
-- 7. The switch, step by step: the deployment @previous\/@ held moved to
--    @previous.before-move@; the SQLite files set aside into
--    @data\/replaced\/\<time>\/@ (never deleted); the deployment kept in
--    @previous\/@ for @--rollback@ ("Maker.Deploy.Upgrade"); the page
--    copied back from there, and the new binary, the console, the unit and
--    the state on PostgreSQL.
-- 8. The service starts, and must answer. A failure at 7 or 8 switches
--    back. A journal notes each step of 7 once it is done, and the switch
--    back undoes exactly those, the last first: the files this run kept in
--    @previous\/@ go back, the SQLite files come back from where this run
--    set them aside, the deployment @previous\/@ held before comes back.
--    A step that was not done is not undone, so a deployment kept by an
--    earlier deploy is never restored by a move. Then the PostgreSQL
--    database is emptied again and the service starts on SQLite.
--
-- The SQLite file is never written: the copy and the comparison only read
-- it, and the switch moves it. A move that succeeds replaces the
-- deployment @previous\/@ held with the deployment on SQLite. A move
-- killed during the switch leaves @previous.before-move@, which the next
-- move refuses until someone has looked at it.
module Maker.Deploy.Move
  ( Move (..)
  , moveToPostgres
  , replaceOnce
  , tablesQuery
  )
where

import Control.Exception (SomeException, catch, displayException, finally, fromException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Control.Monad.Extra (whenM)
import Data.Char (isSpace)
import Data.IORef
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Maker.Deploy.Apply (answersWithin, deploymentUrl, pgDown, startAgain, urlAnswers)
import Maker.Deploy.Layout (markedFor, markerName)
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (dockerReady, pgCompose, pgComposeOutput, pgFiles, pgRunning, serverBuildNative, serverCabalOutput)
import Maker.Deploy.Rehearse (rehearsalDatabase)
import Maker.Deploy.State (stateGet, stateReplace)
import Maker.Deploy.Unit (consoleWrapper, databaseWords, dbUrl)
import Maker.Deploy.Upgrade (keepPrevious, previousDir, putBackFiles, readKept, setAside)
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
  halfway <- doesPathExist (dir </> "previous.before-move")
  when halfway $
    die (dir </> "previous.before-move" <> " is there, from a move that was stopped halfway: it is the deployment previous/ held before that move. Look at it, put it back as previous/ or remove it, then move again")
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
            <> "_wiki-db): one this deployment kept there before it moved to SQLite, or one a move left before a --rollback. It is left as it is, and nothing was changed. To move this wiki there instead, keep what you need of that one (an export, with a server on it), then delete the container and its volume: WIKI_DB_PASSWORD_FILE="
            <> pgDir
            <> "/db-password WIKI_DB_PORT="
            <> dbPort
            <> " docker compose --project-name "
            <> m.name
            <> " --file "
            <> pgDir
            <> "/docker-compose.yml --file "
            <> pgDir
            <> "/local.yml down --volumes"
        )
    _ -> do
      leaveDb
      die "PostgreSQL's database wiki could not be read (see above), so the move cannot tell that it is empty. The wiki was not touched: it runs on SQLite as it did"

  -- 4. From here the running deployment changes. 'filled' says whether
  -- PostgreSQL's database holds this move's copy, which a failure then
  -- empties again: it was empty before the copy, so emptying it touches
  -- nothing but what this run wrote.
  wasRunning <- succeeds "systemctl" ["--user", "is-active", "--quiet", service]
  node <- findExecutable "node"
  filled <- newIORef False
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
      beforeSwitch :: String -> IO b
      beforeSwitch why = do
        whenM (readIORef filled) (attempt "emptying PostgreSQL's database" emptyAgain)
        attempt "stopping PostgreSQL's container again" leaveDb
        attempt ("starting " <> service <> " again") onSqliteAgain
        die (why <> ". The wiki stays on SQLite, as it was; " <> sqlite <> " was not changed")
  say ("stopping " <> service)
  stopped <- runInherit "systemctl" ["--user", "stop", service]
  stillRunning <- succeeds "systemctl" ["--user", "is-active", "--quiet", service]
  when (stopped /= ExitSuccess || stillRunning) $
    beforeSwitch ("systemctl --user stop " <> service <> " did not stop it (see above), so the move stopped before it copied anything")
  -- Any other failure while the service is stopped (an exception, rather
  -- than a step that stops the move itself) is handled as a step's.
  guardedBy beforeSwitch $ do
    say ("backing the wiki up into " <> dataDir </> "backups")
    backedUp <- runInherit (dir </> "bin" </> "wiki-server") ["backup", "--data", dataDir, "--sqlite", sqlite]
    unless (backedUp == ExitSuccess) $
      beforeSwitch ("the backup of " <> sqlite <> " failed (see above), so the move stopped before it copied anything")

    -- 5. The copy.
    say "copying the wiki into PostgreSQL (wiki-server copy-database), in one transaction that checks every table"
    copied <- runInherit newBin ["copy-database", "--data", dataDir, "--sqlite", sqlite, "--to-database", dbUrl dbPort, "--to-database-password-file", pgDir </> "db-password"]
    case copied of
      ExitSuccess -> writeIORef filled True
      ExitFailure 4 -> beforeSwitch ("the wiki is at another version of the schema than this checkout's wiki-server copies (see above): deploy this checkout first (" <> deployCommand <> "), then move it")
      ExitFailure 5 -> beforeSwitch ("some of the wiki does not read whole (see above; " <> dir </> "bin" </> "wiki check --data " <> dataDir <> " says more), so it was not copied")
      ExitFailure 6 -> beforeSwitch "the copy was refused before anything was written (see above)"
      ExitFailure _ -> beforeSwitch "the copy failed (see above), and PostgreSQL's database is empty, as it was"

    -- 6. The comparison, on copies of both: the checks write.
    say "comparing the wiki in PostgreSQL with the wiki in SQLite (wiki-server rehearse --move-to-database, on scratch copies)"
    let scratch = m.stateDir </> (m.name <> ".rehearsal")
        scratchUrl = "postgres://wiki@127.0.0.1:" <> dbPort <> "/" <> rehearsalDatabase
        dropScratch = psqlIn "wiki" ("DROP DATABASE IF EXISTS " <> rehearsalDatabase)
        cleanUp = do
          attempt ("removing " <> scratch) (removePathForcibly scratch)
          dropped <- dropScratch
          unless dropped (warn ("the comparison's scratch database " <> rehearsalDatabase <> " could not be dropped (see above); the next move or upgrade drops it first"))
    removePathForcibly scratch
    ready <- (&&) <$> dropScratch <*> psqlIn "wiki" ("CREATE DATABASE " <> rehearsalDatabase)
    unless ready $
      beforeSwitch ("the comparison's scratch database " <> rehearsalDatabase <> " could not be made (see above)")
    compared <-
      runInherit newBin ["rehearse", "--old", newBin, "--data", dataDir, "--sqlite", sqlite, "--scratch", scratch, "--move-to-database", scratchUrl, "--move-to-database-password-file", pgDir </> "db-password"]
        `finally` cleanUp
    case compared of
      ExitSuccess -> say "the comparison passed: the wiki reads the same in PostgreSQL as in SQLite"
      ExitFailure 6 -> beforeSwitch "the wiki does not read the same in PostgreSQL as in SQLite (see above)"
      ExitFailure _ -> beforeSwitch "the comparison of the wiki in PostgreSQL with the wiki in SQLite could not be made (see above)"

  -- 7. The switch. Each step is noted in the journal once it is done, and
  -- a failure undoes exactly the steps noted, the last first: the recovery
  -- touches only what this run moved, made or kept.
  journal <- newIORef []
  let olderPrevious = dir </> "previous.before-move"
      note step = modifyIORef journal (step :)
  hadPrevious <- doesDirectoryExist (previousDir dir)
  switched <- try @SomeException $ do
    olderThere <- doesPathExist olderPrevious
    when olderThere (throwIO (userError (olderPrevious <> " is there already, from a move that was stopped halfway: look at it, and remove it, before moving again")))
    when hadPrevious $ do
      renameDirectory (previousDir dir) olderPrevious
      note OlderSetAside
    moved <- setAside dir
    case moved of
      Just at -> do
        note (SqliteSetAside at)
        say ("moved " <> sqlite <> " aside into " <> at <> ", where it is kept")
      Nothing -> throwIO (userError (sqlite <> " was not there to set aside"))
    -- previous/ is this run's from here, even if keeping fails halfway:
    -- the deployment it held was moved out of its way, or there was none.
    note PreviousStarted
    kept <- keepPrevious dir m.unitFile m.stateFile commit Nothing wasRunning dbWasRunning (fromMaybe "" moved) ""
    unless kept (throwIO (userError "the deployment could not be kept in previous/"))
    note DeploymentKept
    pageCopied <- runInherit "cp" ["-R", previousDir dir </> "app", dir </> "app"]
    unless (pageCopied == ExitSuccess) (throwIO (userError ("the page could not be copied back from " <> previousDir dir </> "app" <> " (see above)")))
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
  let switchBack :: String -> IO b
      switchBack why = do
        warn (why <> "; switching " <> m.name <> " back to SQLite")
        attempt ("stopping " <> service) (() <$ runInherit "systemctl" ["--user", "stop", service])
        steps <- readIORef journal
        forM_ steps $ \case
          DeploymentKept -> do
            -- What this run kept: the binary and the page moved back, the
            -- unit and the state copied back, previous/ removed.
            say ("putting back the deployment on SQLite this move kept in " <> previousDir dir)
            readKept dir >>= \case
              Just k -> attempt "putting back the files kept in previous/" (putBackFiles dir m.unitFile m.stateFile service k)
              Nothing -> warn ("the deployment this move kept in " <> previousDir dir <> " cannot be read back: put its bin/ and app/ back by hand")
          PreviousStarted -> do
            -- A keep that stopped halfway: what it moved goes back. Once
            -- the deployment was kept whole, putBackFiles has removed it.
            there <- doesDirectoryExist (previousDir dir)
            when there $ attempt ("putting back what was moved into " <> previousDir dir) $ do
              forM_ ["bin", "app"] $ \d -> do
                keptThere <- doesDirectoryExist (previousDir dir </> d)
                here <- doesDirectoryExist (dir </> d)
                when (keptThere && not here) (renameDirectory (previousDir dir </> d) (dir </> d))
              removePathForcibly (previousDir dir)
          SqliteSetAside at -> attempt ("putting " <> sqlite <> " back from " <> at) (putSqliteBack dir at)
          OlderSetAside -> attempt ("putting back the deployment " <> previousDir dir <> " held before the move") (renameDirectory olderPrevious (previousDir dir))
        _ <- runInherit "systemctl" ["--user", "daemon-reload"]
        whenM (readIORef filled) (attempt "emptying PostgreSQL's database" emptyAgain)
        attempt "stopping PostgreSQL's container again" leaveDb
        attempt ("starting " <> service <> " again") onSqliteAgain
        die (why <> ": switched back to SQLite, as it was before the move, " <> sqlite <> " unchanged")
  case switched of
    Left e -> switchBack ("the switch to PostgreSQL failed (" <> reason e <> ")")
    Right () -> pure ()

  -- 8. The start.
  guardedBy switchBack $ do
    say ("starting " <> service <> " on PostgreSQL")
    restarted <- runInherit "systemctl" ["--user", "restart", service]
    unless (restarted == ExitSuccess) $
      switchBack ("systemctl --user restart " <> service <> " failed (see above)")
    url <- deploymentUrl m.stateFile
    started <- answersWithin service answers url
    unless started $ do
      _ <- runInherit "systemctl" ["--user", "status", service, "--no-pager"]
      switchBack (service <> " does not answer on " <> url <> " on PostgreSQL; see journalctl --user -u " <> m.name)
    say (service <> " answers on " <> url <> ", on PostgreSQL")
  -- The move stands from here: what follows only cleans up and reports.
  attempt ("removing " <> olderPrevious <> ", the deployment previous/ held before the move") (removePathForcibly olderPrevious)
  adminPort <- stateGet "admin_port" m.stateFile
  admin <- answers ("http://127.0.0.1:" <> adminPort <> "/admin/api/v1/admin/status")
  unless admin $ warn ("its admin listener does not answer on http://127.0.0.1:" <> adminPort <> "/admin/; see journalctl --user -u " <> m.name)
  steps <- readIORef journal
  let movedTo = case [at | SqliteSetAside at <- steps] of
        at : _ -> at
        [] -> dataDir </> "replaced"
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

-- | 'Step' is a step of the switch that is done, as its journal notes it:
-- the deployment previous/ held moved to previous.before-move, the SQLite
-- files set aside into this directory, previous/ begun by this run, and
-- the deployment kept there whole.
data Step = OlderSetAside | SqliteSetAside FilePath | PreviousStarted | DeploymentKept

-- | Run an action, and hand a failure of it (an exception, not the move
-- stopping itself) to the recovery given, with its reason.
guardedBy :: (String -> IO a) -> IO a -> IO a
guardedBy recover act =
  act `catch` \e -> case fromException e of
    Just (code :: ExitCode) -> throwIO code
    Nothing -> recover ("the move failed (" <> reason e <> ")")

-- | Run a step of a recovery, and warn when it fails, so that the steps
-- after it run all the same.
attempt :: String -> IO () -> IO ()
attempt what act =
  try act >>= \case
    Right () -> pure ()
    Left e -> case fromException e of
      Just (code :: ExitCode) -> throwIO code
      Nothing -> warn (what <> " failed (" <> reason e <> "); see that it is right by hand")

-- | Move the SQLite files the switch set aside back into the deployment's
-- @data\/@, and remove their directory once it is empty. A file of the same
-- name in @data\/@, which nothing of the move makes, is never overwritten:
-- the file set aside then stays where it is, and the move says so.
putSqliteBack :: FilePath -> FilePath -> IO ()
putSqliteBack dir at = do
  forM_ ["wiki.sqlite", "wiki.sqlite-wal", "wiki.sqlite-shm"] $ \file -> do
    kept <- doesFileExist (at </> file)
    taken <- doesPathExist (dir </> "data" </> file)
    when kept $
      if taken
        then warn (dir </> "data" </> file <> " is there, so " <> at </> file <> " was left where it is")
        else renameFile (at </> file) (dir </> "data" </> file)
  left <- listDirectory at
  when (null left) (removeDirectory at)
  say ("put the wiki set aside in " <> at <> " back into " <> dir </> "data")

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
