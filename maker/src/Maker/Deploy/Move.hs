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
-- 3. PostgreSQL, looked at before anything is written: the deployment's
--    container (found by its compose labels, running or not, and the port
--    it is set up on), its volume, and the bytes of PostgreSQL's files. A
--    container set up on another port than the move's is refused,
--    untouched. A container that runs is asked whether its database
--    @wiki@ is empty before anything is written. Otherwise the files are
--    written and the container started as a deploy on PostgreSQL does,
--    and a database that holds a wiki, or any failure, puts back exactly
--    what was found: the files' bytes (or no file, or no directory), a
--    container stopped again or removed, a volume removed when the move
--    made it.
-- 4. The service stops (and must be stopped), and the wiki is backed up
--    into @data\/backups@.
-- 5. @wiki-server copy-database@ copies the SQLite wiki into PostgreSQL,
--    in one transaction that checks every table before it commits.
-- 6. @wiki-server rehearse --move-to-database@ compares the wiki on the
--    two backends with the upgrade's checks, on scratch copies, since the
--    checks write. A failure at 4, 5 or 6 starts the service again on
--    SQLite, as it was, empties the PostgreSQL database again when this
--    move had filled it (it was empty before the copy), and puts
--    PostgreSQL back as step 3 found it. An exception
--    in these steps is handled the same way, so the service is never left
--    stopped by one.
-- 7. The switch. First the wiki's SQLite files are recorded, by size
--    and SHA-256. Then, step by step: the deployment @previous\/@ held
--    moved to @previous.before-move@; the SQLite files set aside into
--    @data\/replaced\/\<time>\/@ (never deleted); the deployment kept in
--    @previous\/@ for @--rollback@ (its binary and page moved there, its
--    unit and state copied, its @info@ written last); the page copied back
--    from there, and the new binary, the console, the unit and the state on
--    PostgreSQL. A journal notes each step before its first operation, and
--    the undo of each is right whatever part of it was done: none, some or
--    all of its operations.
-- 8. The service starts, and must answer. A failure at 7 or 8 switches
--    back, in two phases. Phase one puts back, by copies, what the
--    journal's steps moved, the last first: the binary, page, unit and
--    state this run kept in @previous\/@ (or what a keep that stopped
--    halfway had moved), the SQLite files it set aside. It deletes nothing
--    that was saved, so a step that was not done is not undone and a
--    deployment kept by an earlier deploy is never restored. When a step
--    of phase one fails, the switch back stops there with the service
--    stopped, and everything saved is where the message says
--    (@previous\/@, the SQLite files, @previous.before-move@), for
--    @--rollback@. Then a guard that does not rely on the journal: the
--    files at @data\/@ must be the bytes recorded at 7. If they are not,
--    nothing is started, deleted or emptied, and the message names the
--    directory of the files set aside. Phase two runs only when phase one
--    and the guard have passed: 'discardSaved', the one function that
--    deletes what the move saved, removes this run's @previous\/@ and the
--    SQLite files set aside and puts back the deployment @previous\/@ held
--    before. Only then is the PostgreSQL database emptied, PostgreSQL put
--    back as step 3 found it, and the service started on SQLite.
--
-- The invariant: after a move that did not succeed, either the service
-- runs on exactly the SQLite database the move began the switch with, or it
-- is stopped and every copy is still there (the SQLite files, at @data\/@
-- or set aside, the deployment on SQLite in @previous\/@, and PostgreSQL's
-- copy), and @--rollback --yes@ finishes. Every file operation of the move
-- goes through "Maker.Deploy.Operations", which counts it, and the deploy's
-- tests fail the move at each of them in turn and check the invariant.
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
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.Extra (whenM)
import Data.ByteString qualified as BS
import Data.Char (isSpace)
import Data.IORef
import Data.List (intercalate, isPrefixOf)
import Data.Maybe (fromMaybe, isJust)
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Maker.Deploy.Apply (answersWithin, deploymentUrl, startAgain, urlAnswers)
import Maker.Deploy.Layout (markedFor, markerName)
import Maker.Deploy.Operations (Operations, operations)
import Maker.Deploy.Operations qualified as Op
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (dockerReady, pgCompose, pgFiles, serverBuildNative, serverCabalOutput)
import Maker.Deploy.Rehearse (rehearsalDatabase)
import Maker.Deploy.State (stateGet, stateReplace)
import Maker.Deploy.Unit (consoleWrapper, databaseWords, dbUrl)
import Maker.Deploy.Upgrade (Kept (..), asideName, previousDir, readKept, renderKept, sqliteFiles)
import System.Directory (Permissions, doesDirectoryExist, doesFileExist, doesPathExist, emptyPermissions, findExecutable, getFileSize, getPermissions, listDirectory, setOwnerExecutable, setOwnerReadable, setOwnerSearchable, setOwnerWritable)
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
  ops <- operations
  let prev k = stateGet k m.stateFile
      service = m.name <> ".service"
      pgDir = m.stateDir </> (m.name <> ".postgres")
      volumeName = m.name <> "_wiki-db"
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

  -- 3. PostgreSQL. What is there is looked at first, without changing
  -- it: the deployment's container (running or not, and the port it is
  -- set up on), its volume, and PostgreSQL's files. A container set up on
  -- another port than the move's is refused here, untouched. A container
  -- that runs is asked whether its database is empty before anything is
  -- written. Otherwise the files are written and the container started as
  -- a deploy on PostgreSQL does, and 'restorePg' puts back exactly what
  -- was found: the files' bytes, a container stopped or not there, a
  -- volume not there.
  saved <- savePgFiles pgDir
  foundPg <-
    pgContainer m.name >>= \case
      Right c -> pure c
      Left why -> die ("Docker does not say whether " <> m.name <> " has a PostgreSQL container (" <> why <> "); nothing was changed")
  volumeThere <- succeeds "docker" ["volume", "inspect", volumeName]
  forM_ foundPg $ \c ->
    unless (c.port == Just dbPort) $
      die
        ( "the PostgreSQL container of "
            <> m.name
            <> " is set up on "
            <> maybe "a port Docker does not say" ("127.0.0.1:" <>) c.port
            <> (if c.running then ", and runs" else ", stopped")
            <> ", and the move would put it on 127.0.0.1:"
            <> dbPort
            <> ". It is left as it is, and nothing was changed: move with --db-port "
            <> fromMaybe "PORT" c.port
            <> " to use it on its own port"
        )
  let wasUp = maybe False (.running) foundPg
      psqlIn database statement = do
        code <- pgCompose m.name pgDir dbPort ["exec", "-T", "postgres", "psql", "--quiet", "--username=wiki", "--dbname=" <> database, "--command", statement]
        pure (code == ExitSuccess)
      -- PostgreSQL as the move found it. A container that ran, ran on this
      -- port, and still does.
      restorePg = do
        now <- either (const Nothing) id <$> pgContainer m.name
        case foundPg of
          Just c | c.running -> pure ()
          Just _ -> forM_ now $ \c -> do
            stopped <- runInherit "docker" ["stop", c.container]
            if stopped == ExitSuccess
              then say ("stopped the PostgreSQL container of " <> m.name <> " again, as it was found")
              else warn ("the PostgreSQL container of " <> m.name <> " could not be stopped again (docker stop " <> c.container <> ")")
          Nothing -> do
            forM_ now $ \c -> do
              removed <- runInherit "docker" ["rm", "--force", c.container]
              unless (removed == ExitSuccess) (warn ("the PostgreSQL container this move made could not be removed (docker rm --force " <> c.container <> ")"))
            unless volumeThere $ do
              removed <- runInherit "docker" ["volume", "rm", volumeName]
              unless (removed == ExitSuccess) (warn ("the volume " <> volumeName <> " this move made could not be removed (docker volume rm " <> volumeName <> ")"))
            say ("removed the PostgreSQL container this move made" <> (if volumeThere then "" else ", and its volume " <> volumeName))
        restorePgFiles ops pgDir saved
      refuseAfterPg :: String -> IO b
      refuseAfterPg why = do
        attempt "putting PostgreSQL back as it was found" restorePg
        die why
  unless wasUp $ do
    written <- try @SomeException (Op.step ops ("write PostgreSQL's files in " <> pgDir) (pgFiles plan pgDir))
    case written of
      Right () -> pure ()
      Left e -> refuseAfterPg ("PostgreSQL's files could not be written in " <> pgDir <> " (" <> reason e <> "). The wiki was not touched: it runs on SQLite as it did")
    say ("starting PostgreSQL in Docker (the compose project " <> m.name <> ", on 127.0.0.1:" <> dbPort <> ") and waiting for it")
    up <- pgCompose m.name pgDir dbPort ["up", "--detach", "--wait", "postgres"]
    unless (up == ExitSuccess) $
      refuseAfterPg "PostgreSQL did not start (see above): if the port is taken, choose another with --db-port. The wiki was not touched: it runs on SQLite as it did"
  upNow <- either (const Nothing) id <$> pgContainer m.name
  answer <- case upNow of
    Just c | c.running -> outputOf "docker" ["exec", c.container, "psql", "--quiet", "--username=wiki", "--dbname=wiki", "--tuples-only", "--no-align", "--command", tablesQuery]
    _ -> pure (False, "")
  let leave why = if wasUp then die why else refuseAfterPg why
  case (fst answer, readMaybe (trim (snd answer)) :: Maybe Int) of
    (True, Just 0) -> pure ()
    (True, Just tables) ->
      leave
        ( "PostgreSQL's database wiki of "
            <> m.name
            <> " holds a wiki already ("
            <> show tables
            <> " tables, in the volume "
            <> volumeName
            <> "): one this deployment kept there before it moved to SQLite, or one a move left before a --rollback. It is left as it is, and nothing was changed. To move this wiki there instead, keep what you need of that one (an export, with a server on it), then delete the container and its volume: WIKI_DB_PASSWORD_FILE="
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
    _ -> leave "PostgreSQL's database wiki could not be read (see above), so the move cannot tell that it is empty. The wiki was not touched: it runs on SQLite as it did"
  -- The checks have passed: a container that ran gets the files a deploy
  -- writes too, which 'restorePg' puts back on a failure from here.
  when wasUp $ do
    written <- try @SomeException (Op.step ops ("write PostgreSQL's files in " <> pgDir) (pgFiles plan pgDir))
    case written of
      Right () -> pure ()
      Left e -> refuseAfterPg ("PostgreSQL's files could not be written in " <> pgDir <> " (" <> reason e <> "). The wiki was not touched: it runs on SQLite as it did")

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
          warn ("PostgreSQL's database wiki could not be emptied again (see above): it holds the copy, and a next --move-to-postgres refuses it until the volume " <> volumeName <> " is deleted")
      onSqliteAgain = do
        if wasRunning
          then do
            url <- deploymentUrl m.stateFile
            again <- startAgain service answers url
            if again
              then say (service <> " runs again on SQLite and answers on " <> url)
              else warn (service <> " does not answer on " <> url <> " after it started again on SQLite; see journalctl --user -u " <> m.name)
          else say (service <> " is left stopped, as it was before the move")
      beforeSwitch :: String -> IO b
      beforeSwitch why = do
        whenM (readIORef filled) (attempt "emptying PostgreSQL's database" emptyAgain)
        attempt "putting PostgreSQL back as it was found" restorePg
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
          attempt ("removing " <> scratch) (Op.remove ops scratch)
          dropped <- dropScratch
          unless dropped (warn ("the comparison's scratch database " <> rehearsalDatabase <> " could not be dropped (see above); the next move or upgrade drops it first"))
    Op.remove ops scratch
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

  -- 7. The switch. Each step that is more than one operation is noted in
  -- the journal before its first operation, and its undo is right
  -- whatever part of it was done. The wiki's SQLite files are recorded
  -- first, by size and SHA-256: the switch back starts the service on
  -- SQLite only once they are those bytes again ('sameDatabase').
  journal <- newIORef []
  let olderPrevious = dir </> "previous.before-move"
      note step = modifyIORef journal (step :)
  hadPrevious <- doesDirectoryExist (previousDir dir)
  database <-
    databaseFiles dataDir
      >>= either (\why -> beforeSwitch ("the wiki's files could not be recorded before the switch (" <> why <> ")")) pure
  replacedThere <- doesDirectoryExist (dataDir </> "replaced")
  taken <- if replacedThere then listDirectory (dataDir </> "replaced") else pure []
  stamp <- formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime
  let aside = dataDir </> "replaced" </> asideName taken stamp
  switched <- try @SomeException $ do
    olderThere <- doesPathExist olderPrevious
    when olderThere (throwIO (userError (olderPrevious <> " is there already, from a move that was stopped halfway: look at it, and remove it, before moving again")))
    -- One rename: done or not. Its undo puts it back only if it was done.
    when hadPrevious $ do
      note OlderSetAside
      Op.renameDir ops (previousDir dir) olderPrevious
    -- The SQLite files, one rename each, into a directory of their own.
    note (SqliteSetAside aside)
    Op.makeDir ops aside
    forM_ sqliteFiles $ \file -> do
      there <- doesFileExist (dataDir </> file)
      when there (Op.rename ops (dataDir </> file) (aside </> file))
    say ("moved " <> sqlite <> " aside into " <> aside <> ", where it is kept")
    -- The deployment kept in previous/, for --rollback: previous/ is this
    -- run's from here (the deployment it held was moved out of its way,
    -- or there was none). Its binary and page are moved there, its unit
    -- and state copied, and its info written last.
    note PreviousStarted
    let previous = previousDir dir
    now <- formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" <$> getCurrentTime
    Op.makeDir ops previous
    Op.permissions ops previous . setOwnerExecutable True . setOwnerSearchable True . setOwnerReadable True . setOwnerWritable True $ emptyPermissions
    forM_ ["bin", "app"] $ \d -> do
      there <- doesDirectoryExist (dir </> d)
      when there (Op.renameDir ops (dir </> d) (previous </> d))
    Op.copy ops m.unitFile (previous </> "unit")
    Op.copy ops m.stateFile (previous </> "state")
    Op.writeText ops (previous </> "info") (renderKept Kept {commit, backup = "", keptAt = now, running = wasRunning, unit = True, dbRunning = wasUp, aside, adoptedFrom = ""})
    note DeploymentKept
    say ("kept the deployment on SQLite (" <> commit <> ") in " <> previous <> ", for a rollback")
    -- What the deployment on PostgreSQL is: the undo of DeploymentKept
    -- puts back each of these from previous/.
    pageCopied <- Op.command ops "cp" ["-R", previous </> "app", dir </> "app"]
    unless (pageCopied == ExitSuccess) (throwIO (userError ("the page could not be copied back from " <> previous </> "app" <> " (see above)")))
    Op.makeDir ops (dir </> "bin")
    Op.copy ops newBin (dir </> "bin" </> "wiki-server")
    Op.permissions ops (dir </> "bin" </> "wiki-server") . setOwnerExecutable True =<< getPermissions (dir </> "bin" </> "wiki-server")
    Op.writeText ops (dir </> "bin" </> "wiki") (consoleWrapper m.name dir "postgres" dbPort pgDir)
    Op.permissions ops (dir </> "bin" </> "wiki") . setOwnerExecutable True =<< getPermissions (dir </> "bin" </> "wiki")
    Op.writeText ops (m.unitFile <> ".tmp") newUnit
    Op.rename ops (m.unitFile <> ".tmp") m.unitFile
    Op.step ops ("write " <> m.stateFile) (stateReplace [("db", "postgres"), ("db_port", dbPort)] m.stateFile)
    reloaded <- Op.command ops "systemctl" ["--user", "daemon-reload"]
    unless (reloaded == ExitSuccess) (throwIO (userError "systemctl --user daemon-reload failed (see above)"))
  let switchBack :: String -> IO b
      switchBack why = do
        warn (why <> "; switching " <> m.name <> " back to SQLite")
        attempt ("stopping " <> service) (() <$ runInherit "systemctl" ["--user", "stop", service])
        steps <- readIORef journal
        -- Phase one puts back, by copies, what each step of the journal
        -- moved, and deletes nothing it saved. Phase two, 'discardSaved',
        -- runs only when all of phase one has succeeded.
        whole <- restoreAll steps
        -- The guard, which does not rely on the journal: the service
        -- starts on SQLite, and PostgreSQL's copy is emptied, only once the
        -- files at data/ are the bytes the switch began with.
        same <- if whole then (== Right database) <$> databaseFiles dataDir else pure False
        if whole && same
          then do
            discardSaved ops dir steps
            attempt "systemctl --user daemon-reload" (() <$ Op.command ops "systemctl" ["--user", "daemon-reload"])
            whenM (readIORef filled) (attempt "emptying PostgreSQL's database" emptyAgain)
            attempt "putting PostgreSQL back as it was found" restorePg
            attempt ("starting " <> service <> " again") onSqliteAgain
            die (why <> ": switched back to SQLite, as it was before the move, " <> sqlite <> " unchanged")
          else
            if whole
              then
                die
                  ( why
                      <> "; the files at "
                      <> dataDir
                      <> " after the switch back are not the wiki's database as the switch began (wiki.sqlite and its -wal and -shm, by size and SHA-256), so "
                      <> service
                      <> " is left stopped and nothing was deleted: the wiki's SQLite files as the move set them aside are in "
                      <> aside
                      <> ", the deployment on SQLite in "
                      <> previousDir dir
                      <> concat [", the deployment previous/ held before the move in " <> olderPrevious | OlderSetAside <- steps]
                      <> ", and PostgreSQL's database holds the copy. Put the files of "
                      <> aside
                      <> " back into "
                      <> dataDir
                      <> " (compare them first), then run "
                      <> deployCommand
                      <> " --rollback --yes"
                  )
              else do
                keptWhole <- isJust <$> readKept dir
                die
                  ( why
                      <> "; the switch back to SQLite stopped where a step failed (see above), and "
                      <> service
                      <> " is left stopped. Everything the move saved is still there: "
                      <> intercalate
                        ", "
                        ( [ if keptWhole
                              then "the deployment on SQLite in " <> previousDir dir <> " (its binary, page, unit and state)"
                              else "what the move had moved of the deployment on SQLite (bin/, app/) in " <> previousDir dir
                          | any isPrevious steps
                          ]
                            <> ["the SQLite wiki in " <> at | SqliteSetAside at <- steps]
                            <> ["the deployment previous/ held before the move in " <> olderPrevious | OlderSetAside <- steps]
                        )
                      <> "; and PostgreSQL's database holds the copy. Fix the cause, then "
                      <> ( if keptWhole
                             then "run " <> deployCommand <> " --rollback --yes, which puts that deployment and its SQLite wiki back"
                             else "copy " <> previousDir dir <> "/bin and /app back into " <> dir <> " where they are missing and the SQLite files back into " <> dataDir <> ", then start " <> service
                         )
                      <> concat ["; then rename " <> olderPrevious <> " back to " <> previousDir dir <> " if you want it kept" | OlderSetAside <- steps]
                  )
      -- Phase one: each step put back, the last first, while each succeeds.
      restoreAll = \case
        [] -> pure True
        step : earlier -> do
          done <- restore step
          if done then restoreAll earlier else pure False
      restore = \case
        DeploymentKept -> do
          say ("putting back the deployment on SQLite this move kept in " <> previousDir dir)
          readKept dir >>= \case
            Just k -> restoring ("putting back the deployment kept in " <> previousDir dir) (restoreKept ops dir m.unitFile m.stateFile k)
            Nothing -> warn ("the deployment this move kept in " <> previousDir dir <> " cannot be read back") >> pure False
        -- A keep that stopped halfway: what it moved is copied back where
        -- it is missing. A keep that was whole was put back above.
        PreviousStarted -> restoring ("putting back what the move had moved into " <> previousDir dir) $ do
          copied <- forM ["bin", "app"] $ \d -> do
            keptThere <- doesDirectoryExist (previousDir dir </> d)
            here <- doesDirectoryExist (dir </> d)
            if keptThere && not here then copyDirectoryIn ops (previousDir dir </> d) (dir </> d) else pure True
          pure (and copied)
        SqliteSetAside at -> restoring ("putting " <> sqlite <> " back from " <> at) (copySqliteBack ops dir at)
        -- previous/ is still the move's in phase one: the deployment it
        -- held before comes back in phase two.
        OlderSetAside -> pure True
        Succeeded -> pure True
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
  discardSaved ops dir [Succeeded]
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
-- the deployment kept there whole. 'Succeeded' is not in the journal: it
-- tells 'discardSaved' that the move stands.
data Step = OlderSetAside | SqliteSetAside FilePath | PreviousStarted | DeploymentKept | Succeeded

-- | Run an action, and hand a failure of it (an exception, not the move
-- stopping itself) to the recovery given, with its reason.
guardedBy :: (String -> IO a) -> IO a -> IO a
guardedBy recover act =
  act `catch` \e -> case fromException e of
    Just (code :: ExitCode) -> throwIO code
    Nothing -> recover ("the move failed (" <> reason e <> ")")

-- | Run a step of a recovery that nothing after it needs, and warn when it
-- fails, so that the steps after it run all the same.
attempt :: String -> IO () -> IO ()
attempt what act =
  try act >>= \case
    Right () -> pure ()
    Left e -> case fromException e of
      Just (code :: ExitCode) -> throwIO code
      Nothing -> warn (what <> " failed (" <> reason e <> "); see that it is right by hand")

-- | Run a step of a recovery that the steps after it need: whether it
-- restored what it restores. A failure is said, and answers 'False'.
restoring :: String -> IO Bool -> IO Bool
restoring what act =
  try act >>= \case
    Right done -> pure done
    Left e -> case fromException e of
      Just (code :: ExitCode) -> throwIO code
      Nothing -> warn (what <> " failed (" <> reason e <> ")") >> pure False

-- | Put back the deployment the move kept in @previous\/@, by copies: its
-- state and unit copied back, then its binary and page copied in place of
-- the move's, each whole before the one it replaces goes. Nothing of
-- @previous\/@ is removed: that is 'discardSaved''s, once every step of the
-- switch back has succeeded. The answer is whether it was put back.
restoreKept :: Operations -> FilePath -> FilePath -> FilePath -> Kept -> IO Bool
restoreKept ops dir unitFile stateFile kept = do
  let previous = previousDir dir
  Op.copy ops (previous </> "state") stateFile
  when kept.unit (Op.copy ops (previous </> "unit") unitFile)
  copied <- forM ["bin", "app"] $ \d -> do
    there <- doesDirectoryExist (previous </> d)
    if there then copyDirectoryIn ops (previous </> d) (dir </> d) else pure True
  pure (and copied)

-- | Copy a directory to a place, in place of what is there: into a new
-- directory beside it first, which replaces it only once the copy is
-- whole. What is replaced is the move's own (its binary, its page). The
-- answer is whether the copy is in place.
copyDirectoryIn :: Operations -> FilePath -> FilePath -> IO Bool
copyDirectoryIn ops from to = do
  let incoming = to <> ".restoring"
  Op.remove ops incoming
  code <- Op.command ops "cp" ["-R", from, incoming]
  if code /= ExitSuccess
    then warn ("copying " <> from <> " back failed (see above)") >> pure False
    else do
      Op.remove ops to
      Op.renameDir ops incoming to
      pure True

-- | Copy the SQLite files the switch set aside back into the deployment's
-- @data\/@. The files set aside stay where they are: 'discardSaved'
-- removes them once every step of the switch back has succeeded. A file of
-- the same name in @data\/@, which nothing of the move makes, is never
-- overwritten: the answer is then 'False', since the service must not start
-- on another file.
copySqliteBack :: Operations -> FilePath -> FilePath -> IO Bool
copySqliteBack ops dir at = do
  copied <- forM sqliteFiles $ \file -> do
    kept <- doesFileExist (at </> file)
    taken <- doesPathExist (dir </> "data" </> file)
    if not kept
      then pure True
      else
        if taken
          then warn (dir </> "data" </> file <> " is there, so " <> at </> file <> " was not copied over it") >> pure False
          else Op.copy ops (at </> file) (dir </> "data" </> file) >> pure True
  when (and copied) (say ("copied the wiki set aside in " <> at <> " back into " <> dir </> "data"))
  pure (and copied)

-- | The one place where the move deletes what it saved: once a switch back
-- has put everything back ('restoreAll'), the deployment this run kept in
-- @previous\/@ and the SQLite files it set aside are removed, and the
-- deployment @previous\/@ held before the move takes its place again; once
-- a move has succeeded, that older deployment alone, which the one on
-- SQLite replaces. A removal that fails leaves the thing where it was, and
-- says so.
discardSaved :: Operations -> FilePath -> [Step] -> IO ()
discardSaved ops dir steps = do
  let older = dir </> "previous.before-move"
      discard what path = attempt ("removing " <> path <> ", " <> what) (Op.remove ops path)
  when (any isPrevious steps) (discard "the deployment the move kept, now put back" (previousDir dir))
  forM_ [at | SqliteSetAside at <- steps] (discard "the SQLite files the move set aside, now copied back")
  forM_ [() | OlderSetAside <- steps] $ \() -> do
    previousGone <- not <$> doesPathExist (previousDir dir)
    olderThere <- doesPathExist older
    if not olderThere
      then pure ()
      else
        if previousGone
          then attempt ("putting back the deployment " <> previousDir dir <> " held before the move (it stays in " <> older <> ")") (Op.renameDir ops older (previousDir dir))
          else warn ("the deployment " <> previousDir dir <> " held before the move stays in " <> older <> ", since " <> previousDir dir <> " is still there")
  forM_ [() | Succeeded <- steps] $ \() ->
    discard "the deployment previous/ held before the move, which the one on SQLite replaces" older

-- | Whether a step is one of the move's keeping a deployment in
-- @previous\/@.
isPrevious :: Step -> Bool
isPrevious = \case
  PreviousStarted -> True
  DeploymentKept -> True
  _ -> False

-- | The files of PostgreSQL's directory a deploy writes ('pgFiles'), and
-- so the move.
pgFileNames :: [FilePath]
pgFileNames = ["docker-compose.yml", "local.yml", "db-password", "pg_dump", "pg_restore"]

-- | 'PgSaved' is PostgreSQL's directory as the move found it: whether it
-- was there, and each file's bytes and permissions, or 'Nothing' for a
-- file that was not there.
data PgSaved = PgSaved
  { there :: Bool
  , files :: [(FilePath, Maybe (BS.ByteString, Permissions))]
  }

-- | Read PostgreSQL's directory as it is, before the move writes it.
savePgFiles :: FilePath -> IO PgSaved
savePgFiles pd = do
  there <- doesDirectoryExist pd
  files <- forM pgFileNames $ \f -> do
    present <- doesFileExist (pd </> f)
    if present
      then (\bytes perms -> (f, Just (bytes, perms))) <$> BS.readFile (pd </> f) <*> getPermissions (pd </> f)
      else pure (f, Nothing)
  pure PgSaved {there, files}

-- | Put PostgreSQL's directory back as 'savePgFiles' found it: each file's
-- bytes and permissions, a file that was not there removed, and the
-- directory removed when the move made it.
restorePgFiles :: Operations -> FilePath -> PgSaved -> IO ()
restorePgFiles ops pd saved
  | not saved.there = Op.remove ops pd
  | otherwise = forM_ saved.files $ \case
      (f, Just (bytes, perms)) -> Op.writeBytes ops (pd </> f) bytes >> Op.permissions ops (pd </> f) perms
      (f, Nothing) -> Op.remove ops (pd </> f)

-- | 'Container' is a deployment's PostgreSQL container as Docker shows it:
-- its id, whether it runs, and the port of this machine it is set up to
-- publish PostgreSQL on.
data Container = Container
  { container :: String
  , running :: Bool
  , port :: Maybe String
  }

-- | The PostgreSQL container of a deployment's compose project, found by
-- the labels docker compose gives it, so that no file of the deployment's
-- is needed to look: 'Nothing' when there is none, 'Left' when Docker does
-- not answer.
pgContainer :: String -> IO (Either String (Maybe Container))
pgContainer name = do
  let labels = ["--filter", "label=com.docker.compose.project=" <> name, "--filter", "label=com.docker.compose.service=postgres"]
  (listed, ids) <- outputOf "docker" (["ps", "--all", "--quiet"] <> labels)
  (asked, runningIds) <- outputOf "docker" (["ps", "--quiet"] <> labels)
  if not (listed && asked)
    then pure (Left "docker ps failed")
    else case words ids of
      [] -> pure (Right Nothing)
      c : _ -> do
        (_, ports) <- outputOf "docker" ["inspect", "--format", "{{range $p, $b := .HostConfig.PortBindings}}{{range $b}}{{.HostPort}} {{end}}{{end}}", c]
        pure (Right (Just Container {container = c, running = c `elem` words runningIds, port = case words ports of p : _ -> Just p; [] -> Nothing}))

-- | Why a step of the switch failed, in words: the message of a failure
-- the switch raised itself, or the exception as it shows.
reason :: SomeException -> String
reason e = case fromException e of
  Just io | isUserError io -> ioeGetErrorString io
  _ -> displayException e

-- | The wiki's SQLite files in a data directory, as the guard of the
-- switch back compares them: for wiki.sqlite and its -wal and -shm, the
-- size and SHA-256 of each that is there, or 'Nothing' for one that is
-- not. 'Left' when a file cannot be read or hashed.
databaseFiles :: FilePath -> IO (Either String [(FilePath, Maybe (Integer, String))])
databaseFiles dataDir = do
  files <- forM sqliteFiles $ \file -> do
    there <- doesFileExist (dataDir </> file)
    if not there
      then pure (Right (file, Nothing))
      else do
        size <- getFileSize (dataDir </> file)
        (ok, out) <- outputOf "sha256sum" [dataDir </> file]
        pure $ case words out of
          hash : _ | ok -> Right (file, Just (size, hash))
          _ -> Left ("sha256sum " <> dataDir </> file <> " failed")
  pure (sequence files)

-- | A text without the spaces around it.
trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace

-- | A file's text, read whole before it is used.
readStrict :: FilePath -> IO String
readStrict file = do
  text <- readFile file
  length text `seq` pure text
