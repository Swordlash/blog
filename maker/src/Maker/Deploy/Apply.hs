-- | The part of a deploy that changes the running deployment, from the
-- moment the old service stops to the report at the end: the database's
-- backup, the files copied into place, the unit, the restart, the checks
-- that the service answers, @tailscale serve@, the firewall rule and what to
-- do next. The steps before it (the options, the state, the builds, the
-- database's container; "Maker.Deploy.Front" and "Maker.Deploy.Prepare")
-- hand this over with a plan ("Maker.Deploy.Plan"); its messages are the
-- shell's, word for word, since people and the deploy's tests read them.
--
-- The steps run in order, as plain IO: they are not Shake rules, since each
-- one acts on the running system and the order is the point (the backup
-- before the new server opens the database, the unit before the restart,
-- the restart before the serve).
module Maker.Deploy.Apply
  ( apply
  , rollbackByHand
  , compressible
  , sanName

    -- * For the move to PostgreSQL ("Maker.Deploy.Move")
  , Place (..)
  , Settings (..)
  , settingsOf
  , rollBackDeployment
  , startAgain
  , answersWithin
  , deploymentUrl
  , urlAnswers
  , pgDown
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.Aeson (Value (..), decode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Char (toLower)
import Data.IORef
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Maker.Deploy.Firewall qualified as Firewall
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (pgCompose, pgWrapper)
import Maker.Deploy.Rehearse (rehearse)
import Maker.Deploy.State (renderState, stateGet, stateSet, writeState)
import Maker.Deploy.Tailscale qualified as Tailscale
import Maker.Deploy.Unit
import Maker.Deploy.Upgrade
import System.Directory
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (exitWith)
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))
import System.IO (hFlush, hIsTerminalDevice, hPutStr, stderr, stdin, stdout)
import System.Process.Typed
import Text.Read (readMaybe)

-- | Change the running deployment as the plan says.
apply :: Plan -> IO ()
apply p = do
  let v = get p
      name = v "name"
      dir = v "dir"
      server = v "mode" == "server"
      nodeless = has p "nodeless"
      noFirewall = has p "no_firewall"
      service = name <> ".service"
      pgDir = v "state_dir" </> (name <> ".postgres")
      prefixArg = if has p "prefix" then " --prefix " <> v "prefix" else ""
      db = v "db"
      dbPort = v "db_port"
      serverBin = v "server_bin"
      port = v "port"
      bind = v "bind"
      adminPort = v "admin_port"
      way = v "way"
      httpsHost = v "https_host"
      databaseArgs
        | db == "postgres" = ["--database", dbUrl dbPort, "--database-password-file", pgDir </> "db-password"]
        | otherwise = ["--sqlite", dir </> "data" </> "wiki.sqlite"]

  -- The upgrade is rehearsed on a copy of the wiki before anything of the
  -- running deployment changes, which keeps running meanwhile: a failed
  -- rehearsal stops the deploy here, with nothing to undo
  -- ("Maker.Deploy.Rehearse").
  rehearse p

  -- From here on the running deployment changes.
  madeBackup <- newIORef Nothing
  wasInstalled <- doesFileExist (v "unit_file")
  -- Whether the deployment ran when the deploy began: a rollback starts it
  -- again only then.
  wasRunning <- succeeds "systemctl" ["--user", "is-active", "--quiet", service]
  when wasInstalled $ do
    say ("stopping " <> service)
    _ <- runInherit "systemctl" ["--user", "stop", service]
    pure ()
  -- The database is copied aside before the new server, which may migrate
  -- it, first opens it, and with the old one stopped, so that the copy has
  -- every write. If that fails, the old deployment goes on as it was.
  -- An empty wiki starts here when the database changes kind or --fresh is
  -- given: a data/wiki.sqlite is moved aside, where a rollback finds it
  -- ('setAside'), and a PostgreSQL wiki stays in its container's volume.
  -- Before that, the old wiki-server backs its database up into
  -- data/backups: the new server deletes the attachments' files that
  -- neither its database nor a backup there refers to, and the old wiki's
  -- would go, although a rollback brings that wiki back. A wiki.sqlite set
  -- aside beside a PostgreSQL wiki that stays is not the deployment's
  -- database, and the deploy's own backup below covers that case.
  oldKind <- kindOf <$> stateGet "db" (v "state_file")
  when (server && has p "incompatible" && (oldKind /= kindOf db || oldKind == "sqlite")) $ do
    let oldBin = dir </> "bin" </> "wiki-server"
        oldArgs
          | oldKind == "postgres" = ["--database", dbUrl (v "prev_db_port"), "--database-password-file", pgDir </> "db-password", "--pg-dump", pgDir </> "pg_dump", "--pg-restore", pgDir </> "pg_restore"]
          | otherwise = ["--sqlite", dir </> "data" </> "wiki.sqlite"]
    there <- doesFileExist oldBin
    oldFile <- doesFileExist (dir </> "data" </> "wiki.sqlite")
    when (there && (oldKind == "postgres" || oldFile)) $ do
      say ("backing up the wiki that is set aside, with the wiki-server that wrote it, into " <> dir </> "data" </> "backups")
      code <- runInherit oldBin (["backup", "--data", dir </> "data"] <> oldArgs)
      unless (code == ExitSuccess) $
        warn "the backup of the wiki set aside failed (see above): the new server may delete the files of attachments only that wiki refers to, which a rollback to it would then miss"
  movedAside <-
    if server && has p "incompatible"
      then do
        moved <- setAside dir
        forM_ moved $ \aside -> say ("moved " <> dir </> "data" </> "wiki.sqlite" <> " aside into " <> aside <> ": the new wiki starts empty")
        when (db == "sqlite" && v "prev_db" == "postgres") (pgDown name pgDir (v "prev_db_port"))
        pure moved
      else pure Nothing
  when server $ do
    say ("backing the database up into " <> dir </> "data" </> "backups")
    let backup
          | db == "postgres" = ["backup", "--data", dir </> "data"] <> databaseArgs <> ["--pg-dump", pgDir </> "pg_dump", "--pg-restore", pgDir </> "pg_restore"]
          | otherwise = ["backup", "--data", dir </> "data"] <> databaseArgs
    let backupsDir = dir </> "data" </> "backups"
        listed = do
          there <- doesDirectoryExist backupsDir
          if there then map (backupsDir </>) <$> listDirectory backupsDir else pure []
    before <- listed
    code <- runInherit serverBin backup
    after <- listed
    writeIORef madeBackup (newBackup before after)
    unless (code == ExitSuccess) $ do
      when wasInstalled (() <$ runInherit "systemctl" ["--user", "start", service])
      when (code == ExitFailure 3) $
        die "the state is incompatible: the database is an earlier wiki-server's (see above), so nothing was changed. Export the wiki with the running server, run this again with --fresh, and import the archive into the new wiki"
      die ("the backup of " <> dir </> "data" <> " failed (see above), so nothing was changed")
  prevDirThere <- if has p "prev_dir" then doesDirectoryExist (v "prev_dir") else pure False
  when (prevDirThere && v "prev_dir" /= dir) $
    say ("moving from " <> v "prev_dir" <> " to " <> dir <> ": the old files stay in " <> v "prev_dir")

  firewall <-
    if noFirewall
      then pure Nothing
      else do
        f <- Firewall.probe
        Firewall.explain f
        pure (Just f)
  -- The previous port's rule goes when the port changes, or when the new
  -- address is local only and needs none.
  rulePort <- newIORef (v "prev_rule_port")
  let localOnly = bind `elem` ["127.0.0.1", "::1"]
  previousRule <- readIORef rulePort
  when (not (null previousRule) && (previousRule /= port || localOnly)) $ case firewall of
    Nothing -> say ("--no-firewall: leaving the rule for port " <> previousRule <> " as it is")
    Just f -> do
      Firewall.close f (v "state_dir") (v "state_file") previousRule
      writeIORef rulePort ""

  say ("installing into " <> dir)
  createDirectoryIfMissing True dir
  -- Everything but the data, which outlives every deployment of it, and,
  -- under a prefix, the state and the toolchain, which the next deploy
  -- needs.
  -- The deployment it replaces is kept for a rollback (Maker.Deploy.Upgrade),
  -- a server's only: its binary, page, unit and state, with its commit, the
  -- backup just made and whether it was running. A rollback puts back what
  -- the files say and reconciles the settings outside them (the firewall
  -- rule, tailscale serve, PostgreSQL's port and container, a wiki set
  -- aside, an adoption under --prefix; 'rollBackDeployment'). When the
  -- database changes kind or starts anew (--fresh), the backup just made
  -- is of the new, empty wiki and is not kept: the rollback brings back the
  -- wiki set aside instead. A deploy into another directory than the
  -- deployment's keeps nothing: the old deployment is intact where it was.
  -- An older one kept before goes either way.
  backupMade <- readIORef madeBackup
  oldDb <- stateGet "db" (v "state_file")
  -- The backup is of a new, empty wiki when the kind changes, or when
  -- --fresh set a SQLite wiki aside. A wiki.sqlite set aside beside a
  -- PostgreSQL wiki that stays was never that deployment's database: the
  -- backup is then the real one, and kept.
  let emptyWiki = kindOf oldDb /= kindOf db || (kindOf db == "sqlite" && has p "incompatible")
      elsewhere = has p "prev_dir" && v "prev_dir" /= dir
      adoptedFrom = if has p "adoptable" then v "adopted_state_file" else ""
  kept <-
    if server && not elsewhere
      then keepPrevious dir (v "unit_file") (v "state_file") (v "prev_git_commit") (if emptyWiki then Nothing else backupMade) wasRunning (has p "db_was_running") (fromMaybe "" movedAside) adoptedFrom
      else do
        replaced <- doesFileExist (dir </> "bin" </> "wiki-server")
        when (server && replaced) $
          say ("the deployment it replaces is not kept for a rollback: it is in " <> v "prev_dir" <> ", which this deploy leaves as it is")
        removePathForcibly (previousDir dir)
        pure False
  entries <- listDirectory dir
  forM_ [e | e <- entries, e `notElem` (["data", "state", "toolchain", v "marker"] <> ["previous" | server])] $ \e ->
    removePathForcibly (dir </> e)
  writeFile (dir </> v "marker") ("name=" <> name <> "\ncreated-by=toolchain/deploy-local.sh\n")
  orDie =<< runInherit "cp" ["-R", v "out", dir </> "app"]
  if server
    then do
      createDirectoryIfMissing True (dir </> "bin")
      createDirectoryIfMissing True (dir </> "data")
      orDie =<< runInherit "chmod" ["700", dir </> "data"]
      orDie =<< runInherit "cp" [serverBin, dir </> "bin" </> "wiki-server"]
      writeFile (dir </> "bin" </> "wiki") (consoleWrapper name dir db dbPort pgDir)
      orDie =<< runInherit "chmod" ["755", dir </> "bin" </> "wiki"]
    else do
      orDie =<< runInherit "cp" [v "root" </> "toolchain" </> "deploy-server.mjs", dir </> "server.mjs"]
      keeps <- doesDirectoryExist (dir </> "data")
      when keeps (say ("keeping the server's data in " <> dir </> "data"))
  -- Precompressed copies, which the server sends to browsers that accept
  -- brotli: the build itself writes none, since GitHub Pages compresses on
  -- the fly. Without Node, wiki-server writes gzip copies instead.
  if nodeless
    then do
      (ok, out) <- outputKeepingErrors (dir </> "bin" </> "wiki-server") ["compress", dir </> "app"]
      if ok
        then say ("copied the page; gzip copies by wiki-server compress, since there is no Node here for brotli ones: " <> chomp out)
        else warn "wiki-server compress failed (see above): the server sends the page's files uncompressed"
    else do
      files <- compressible (dir </> "app")
      forM_ (chunks 200 files) $ \batch ->
        orDie =<< runProcess (setStdout nullStream (proc (v "node") ((v "root" </> "toolchain" </> "compress.mjs") : batch)))
      brotli <- filter (".br" `isSuffixOf`) <$> filesUnder (dir </> "app")
      say ("copied the page and " <> show (length brotli) <> " brotli'd files")

  -- The new program brings the database to its schema and reads it back
  -- whole before it is started (WP5.73 of docs/PLAN.md): a migration that
  -- fails, or leaves a row it cannot read, puts the kept deployment back.
  let placeArgs = ["--data", dir </> "data"] <> databaseArgs <> pgPrograms
      pgPrograms = if db == "postgres" then ["--pg-dump", pgDir </> "pg_dump", "--pg-restore", pgDir </> "pg_restore"] else []
      probeUrl = serverUrl server bind port way
      answers = urlAnswers (if nodeless then Nothing else Just (v "node"))
      rollBack why = do
        mk <- if kept then readKept dir else pure Nothing
        case mk of
          Nothing -> die (why <> ", and no previous deployment is kept to go back to")
          Just k -> do
            warn why
            -- What this deploy has changed outside the files so far: the
            -- old port's firewall rule may be closed already, and
            -- PostgreSQL may listen on a new port. tailscale serve is set
            -- only after the new server answers, so it is still the old.
            ruleNow <- readIORef rulePort
            let now = Settings {rulePort = ruleNow, servePort = v "prev_serve_port", db = db, dbPort = dbPort}
            restored <- rollBackDeployment place firewall now k
            unless restored $ do
              -- The state still names the old port's rule, which may be
              -- closed now: --rollback then sees the difference and opens it.
              stateSet "rule_port" ruleNow (v "state_file")
              die (why <> "; the rollback to commit " <> k.commit <> " stopped before the files went back (see above). " <> (if null k.backup then "" else "If the restore failed, restore " <> k.backup <> " by hand with " <> previousDir dir </> "bin" </> "wiki-server restore; ") <> "fix the cause and run deploy-local.sh --rollback")
            let back = rollbackPlace place k
            if k.running
              then do
                url <- deploymentUrl back.stateFile
                started <- startAgain service answers url
                if started
                  then say ("the previous deployment runs again (" <> service <> " answers on " <> url <> ")")
                  else warn ("the previous deployment does not answer on " <> url <> " either; see journalctl --user -u " <> name)
              else leaveStopped back k >> say (service <> " is left stopped, as it was before the deploy")
            die
              ( why
                  <> ": rolled back to the previous deployment, of commit "
                  <> k.commit
                  <> (if null k.backup then "" else ", its database restored from the backup made before the upgrade (" <> takeFileName k.backup <> ")")
                  <> (if null k.aside then "" else ", its wiki put back from " <> k.aside)
                  <> ". Deploy that commit again (git checkout "
                  <> k.commit
                  <> ") until the cause is fixed"
              )
      place = Place {name = name, dir = dir, unitFile = v "unit_file", stateFile = v "state_file", stateDir = v "state_dir", pgDir = pgDir, noFirewall = noFirewall}
  when server $
    migrateAndCheck (dir </> "bin" </> "wiki-server") placeArgs >>= mapM_ rollBack

  let listen = if ':' `elem` bind then "[" <> bind <> "]:" <> port else bind <> ":" <> port
  ldLibraryPath <- fromMaybe "" <$> lookupEnv "LD_LIBRARY_PATH"
  (description, execStart', extra) <-
    if server
      then do
        -- The deployment's own paths in plain double quotes, as the shell
        -- writes them; only the paths given as options go through
        -- 'unitWord'.
        let quoted path = "\"" <> path <> "\""
            base =
              quoted (dir </> "bin" </> "wiki-server")
                <> " serve --data "
                <> quoted (dir </> "data")
                <> " --static "
                <> quoted (dir </> "app")
                <> " --listen "
                <> listen
                <> " --admin-listen 127.0.0.1:"
                <> adminPort
            -- A Secure cookie is sent over HTTPS only, so over plain HTTP it
            -- would make signing in impossible.
            tls
              | not (null httpsHost) || way == "proxy" = " --secure-cookies"
              | way == "cert" = " --tls-cert " <> unitWord (v "tls_cert") <> " --tls-key " <> unitWord (v "tls_key")
              | otherwise = ""
            database = databaseWords db dir dbPort pgDir
            pdf = if v "pdf" == "yes" then "" else " --no-pdf"
            whatsNew = if v "whats_new" == "no" then " --no-whats-new" else ""
        -- A systemd user unit does not inherit the shell's environment, so
        -- a server linked against a library in a directory of one's own is
        -- given LD_LIBRARY_PATH in its unit.
        libraryPath <-
          if null ldLibraryPath
            then pure []
            else do
              when ('\n' `elem` ldLibraryPath) (die "LD_LIBRARY_PATH holds a newline, which a unit file cannot hold")
              say ("the unit runs wiki-server with LD_LIBRARY_PATH=" <> ldLibraryPath <> ", as this shell has it: a systemd unit does not inherit the shell's environment")
              pure ["Environment=\"LD_LIBRARY_PATH=" <> environmentValue ldLibraryPath <> "\""]
        -- The toolchain's TeX Live, when the TeX step chose it, first on the
        -- unit's PATH, where the server looks for xelatex.
        let texPath = ["Environment=\"PATH=" <> environmentValue (v "tex_bin" <> ":" <> unitBasePath) <> "\"" | has p "tex_bin"]
        pure
          ( "Wiki server (" <> name <> ") from " <> dir <> " on " <> bind <> ":" <> port
          , base <> tls <> database <> pdf <> whatsNew
          , ["UMask=0077", "TimeoutStopSec=30"] <> libraryPath <> texPath
          )
      else
        pure
          ( "Wiki demo (" <> name <> ") from " <> dir <> " on " <> bind <> ":" <> port
          , "\"" <> v "node" <> "\" \"" <> dir </> "server.mjs" <> "\" --root \"" <> dir </> "app" <> "\" --port " <> port <> " --bind " <> bind
          , []
          )

  -- The secrets an earlier version kept for the unit's environment: the
  -- server reads them from its database now.
  envFile <- doesFileExist (v "env_file")
  when envFile $ do
    removeFile (v "env_file")
    say ("deleted " <> v "env_file" <> ": the mail password and providers' secrets it held are set in the administration's Server section now")

  createDirectoryIfMissing True (v "unit_dir")
  writeFile (v "unit_file" <> ".tmp") (renderUnit Unit {root = v "root", name, prefix = v "prefix", description, execStart = execStart', extra})
  renameFile (v "unit_file" <> ".tmp") (v "unit_file")
  let stateWrite = readIORef rulePort >>= writeState (v "state_file") . renderState p
  stateWrite
  orDie =<< runInherit "systemctl" ["--user", "daemon-reload"]
  quietEnable <- succeeds "systemctl" ["--user", "enable", service]
  unless quietEnable (orDie =<< runInherit "systemctl" ["--user", "enable", service])
  -- The end of an adoption: the old PostgreSQL files go, now that the unit,
  -- the console and the wrappers name the copies under the prefix. When the
  -- deployment before is kept, they go into previous/postgres, from where
  -- a rollback moves them back ('unadopt').
  when (has p "adopted_pg_dir") $
    if kept
      then orDie =<< runInherit "mv" [v "adopted_pg_dir", previousDir dir </> "postgres"]
      else removePathForcibly (v "adopted_pg_dir")
  say ("starting " <> service)
  restarted <- runInherit "systemctl" ["--user", "restart", service]
  unless (restarted == ExitSuccess) $ do
    let why = "systemctl --user restart " <> service <> " failed (see above)"
    if server && kept then rollBack why else die why

  let probeHost = hostOf bind
      probePath = if server then "api/v1/info" else ""
      scheme = if way == "cert" then "https" else "http"
  up <- answersWithin service answers probeUrl
  unless up $ do
    _ <- runProcess (setStdout (useHandleOpen stderr) (proc "systemctl" ["--user", "status", service, "--no-pager"]))
    mapM_ Firewall.report firewall
    let why = service <> " does not answer on " <> scheme <> "://" <> probeHost <> ":" <> port <> "/; see journalctl --user -u " <> name
    if server && kept then rollBack why else die why
  say (service <> " answers on " <> probeUrl)
  -- With --tls-ca, the certificate is checked as a browser that trusts that
  -- authority checks it: its chain, and its name.
  when (way == "cert" && has p "tls_ca") $ do
    tlsName <- certName (v "tls_cert")
    let target
          | null tlsName = ["https://" <> probeHost <> ":" <> port <> "/" <> probePath]
          | otherwise = ["--connect-to", tlsName <> ":" <> port <> ":" <> probeHost <> ":" <> port, "https://" <> tlsName <> ":" <> port <> "/" <> probePath]
        forName = if null tlsName then "" else " for " <> tlsName
    (ok, out) <- outputWithErrors "curl" (["-sS", "-o", "/dev/null", "--max-time", "10", "--noproxy", "*", "--cacert", v "tls_ca"] <> target)
    if ok
      then say ("its certificate verifies against " <> v "tls_ca" <> forName)
      else
        warn
          ( "its certificate does not verify against --tls-ca "
              <> v "tls_ca"
              <> (if null tlsName then "" else " for the name " <> tlsName)
              <> " ("
              <> (let o = chomp out in if null o then "curl failed" else o)
              <> "): a browser that trusts that authority refuses it too. Check that "
              <> v "tls_cert"
              <> " has the chain after the certificate, and that the certificate is for the name people use"
          )
  when server $ do
    admin <- answers ("http://127.0.0.1:" <> adminPort <> "/admin/api/v1/admin/status")
    if admin
      then say ("its admin listener answers on http://127.0.0.1:" <> adminPort <> "/admin/")
      else warn ("its admin listener does not answer on http://127.0.0.1:" <> adminPort <> "/admin/; see journalctl --user -u " <> name)
    -- The guide follows the server's version: each of its pages whose text
    -- this version changed gets the new text as a new version. A failure
    -- leaves the wiki as it was, and the deployment stands.
    say "bringing the guide's pages up to this version"
    code <- runInherit (dir </> "bin" </> "wiki-server") (["guide", "update", "--data", dir </> "data"] <> databaseArgs)
    unless (code == ExitSuccess) (warn "the guide's pages could not be updated (see above); the wiki is served as it was")

  -- tailscale serve. Over HTTPS: leave it when it already proxies to this
  -- port, set it when it serves nothing at https://<name>/ or this
  -- deployment's previous port, and leave anything else there alone. Over
  -- plain HTTP: turn off the serve an earlier HTTPS deploy of this
  -- deployment set.
  serveNote <-
    if not (null httpsHost)
      then do
        let serveCmd = "serve --bg http://127.0.0.1:" <> port
        current <- Tailscale.serveRead
        ours <- case current of
          Nothing -> do
            warn ("tailscale serve status does not answer, so cannot serve https://" <> httpsHost <> "/")
            Tailscale.rightsHint serveCmd
            pure Nothing
          Just s
            | Tailscale.proxiesTo s port -> do
                say ("tailscale serve already proxies https://" <> httpsHost <> "/ to 127.0.0.1:" <> port <> ": leaving it as it is")
                pure (Just s)
            | not (null s.kind)
                && not (has p "prev_serve_port" && Tailscale.proxiesTo s (v "prev_serve_port"))
                && not (has p "prev_port" && Tailscale.proxiesTo s (v "prev_port")) -> do
                warn ("https://" <> httpsHost <> "/ already serves " <> s.kind <> " " <> s.target <> ", which this deployment did not set, so it is left alone; to serve the wiki there instead, run: tailscale " <> serveCmd <> " (or deploy this one with --http)")
                pure Nothing
            | otherwise -> do
                old <- Tailscale.oldVersion
                case old of
                  Just version -> do
                    warn ("this Tailscale (" <> version <> ") is older than 1.52, whose tailscale serve this script uses; upgrade it and run this again, or set the serve yourself with the older form:")
                    putStrLn ("    sudo tailscale serve https:443 / http://127.0.0.1:" <> port)
                    pure Nothing
                  Nothing -> do
                    say ("tailscale " <> serveCmd)
                    (setOk, out) <- Tailscale.outputOfBoth 60 ["serve", "--bg", "http://127.0.0.1:" <> port]
                    after <- if setOk then Tailscale.serveRead else pure Nothing
                    case after of
                      Just s' | Tailscale.proxiesTo s' port -> do
                        say ("tailscale serve proxies https://" <> httpsHost <> "/ to 127.0.0.1:" <> port <> " (tailnet only)")
                        pure (Just s')
                      _ -> do
                        unless (null out) (hPutStr stderr (Tailscale.indented out))
                        warn ("could not set tailscale serve (see above); the deployment answers on 127.0.0.1:" <> port <> " meanwhile")
                        Tailscale.rightsHint serveCmd
                        pure Nothing
        case ours of
          Just s -> do
            when (s.funnel == "funnel") $
              warn ("Funnel is on for https://" <> httpsHost <> "/ (tailscale serve status): the wiki is public on the internet, not only on your tailnet. This script never turns it on")
            -- The first certificate is fetched as the first request
            -- arrives; the wait is counted by the clock rather than by
            -- attempts.
            httpsWait <- maybe 60 id . (>>= readMaybe) <$> lookupEnv "WIKI_DEPLOY_HTTPS_WAIT"
            started <- seconds
            let tryHttps = do
                  ok <- httpsAnswers (v "node") ("https://" <> httpsHost <> "/" <> probePath)
                  if ok
                    then pure True
                    else do
                      now <- seconds
                      if now - started < httpsWait then threadDelay 2000000 >> tryHttps else pure False
            ok <- tryHttps
            if ok
              then say ("it answers on https://" <> httpsHost <> "/" <> probePath)
              else warn ("https://" <> httpsHost <> "/ does not answer yet: the first certificate can take a minute or two to arrive; try it shortly (curl https://" <> httpsHost <> "/), and see tailscale serve status")
            pure ""
          Nothing -> pure "   (once tailscale serve is set: see above)"
      else do
        when (has p "prev_serve_port") (Tailscale.serveOff (v "prev_serve_port"))
        pure ""

  forM_ firewall $ \f -> unless localOnly $ do
    Firewall.open f name port
    when (Firewall.status f `elem` [Firewall.Active, Firewall.Locked, Firewall.Unknown]) (writeIORef rulePort port)
    stateWrite
  mapM_ Firewall.report firewall
  lingerReport (v "user") (has p "enable_linger")

  -- What to do next.
  let urls = printUrls httpsHost serveNote bind port way (v "tls_cert")
      adminUrl = "http://127.0.0.1:" <> adminPort <> "/admin/admin/"
      publicUrl
        | nodeless = do
            (ok, settings) <- outputOf "curl" ["-fs", "--max-time", "10", "--noproxy", "*", "http://127.0.0.1:" <> adminPort <> "/admin/api/v1/admin/server"]
            pure (if ok then publicUrlOf settings else Nothing)
        | otherwise = do
            (ok, out) <- outputOf (v "node") ["-e", nodePublicUrl, "http://127.0.0.1:" <> adminPort <> "/admin/api/v1/admin/server"]
            pure (if ok then Just out else Nothing)
  if server
    then do
      putStrLn ("\nThe wiki is served from " <> dir <> ", its data in " <> dir <> "/data. Open:")
      urls
      if db == "postgres"
        then do
          putStrLn ("Its database is PostgreSQL in Docker (docker compose --project-name " <> name <> " ps), on")
          putStrLn ("127.0.0.1:" <> dbPort <> ", its data in the volume " <> name <> "_wiki-db; its password is in " <> pgDir <> "/db-password.")
        else putStrLn ("Its database is SQLite, " <> dir <> "/data/wiki.sqlite.")
      -- The public address stays a setting of the panel: the deploy only
      -- says what to set it to.
      unless (null httpsHost) $ do
        public <- publicUrl
        case public of
          Nothing -> do
            putStrLn ("If the administration's Server section has no public address yet, set it to https://" <> httpsHost <> "/")
            putStrLn ("  (" <> adminUrl <> "): mailed links and sign-in providers start with it.")
          Just "" -> do
            putStrLn ("The wiki has no public address yet: set it to https://" <> httpsHost <> "/ in the administration's")
            putStrLn ("Server section (" <> adminUrl <> "); mailed links and sign-in providers start with it.")
          Just u
            | dropSlash u /= "https://" <> httpsHost -> do
                putStrLn ("The public address in the administration's Server section is " <> u <> ", but the wiki")
                putStrLn ("is served at https://" <> httpsHost <> "/: change it there (" <> adminUrl <> ") if people use that one.")
            | otherwise -> pure ()
      if way == "cert"
        then do
          putStrLn ("It serves HTTPS itself with " <> v "tls_cert" <> " and its key " <> v "tls_key" <> ", which it reads")
          putStrLn ("as it starts: a renewed certificate takes a restart, systemctl --user restart " <> service)
        else when (way == "proxy") (putStr (proxyNeeds port))
      when (way == "cert" || way == "proxy") $ do
        public <- publicUrl
        when (public == Just "") $ do
          putStrLn "The wiki has no public address yet: set it to the https:// address people use in the"
          putStrLn ("administration's Server section (" <> adminUrl <> "); mailed links and sign-in providers start with it.")
      putStr $
        unlines
          [ "Administration, on this machine only: http://127.0.0.1:" <> adminPort <> "/admin/"
          , "  from another: ssh -L " <> adminPort <> ":127.0.0.1:" <> adminPort <> " " <> v "user" <> "@<this machine>, then the same address"
          , "Backups: " <> dir <> "/data/backups (one before every deploy; another: " <> dir <> "/bin/wiki backup --data " <> dir <> "/data)"
          , "Users:   " <> dir <> "/bin/wiki users list --data " <> dir <> "/data"
          , "  the first administrator: " <> dir <> "/bin/wiki users add --data " <> dir <> "/data LOGIN --admin (asks for the password)"
          , "Logs:    journalctl --user -u " <> name <> " -f"
          , "Status:  sh toolchain/deploy-local.sh --status --name " <> name <> prefixArg
          , "Stop:    sh toolchain/undeploy-local.sh --name " <> name <> prefixArg <> "   (--purge deletes the files but data/, --purge-data that too)"
          ]
      when (has p "toolchain_home") $
        putStrLn ("The toolchain the build used is under " <> v "toolchain_home" <> " (--toolchain names another; the home directory holds only the unit).")
      putStr $
        unlines
          [ ""
          , "The public address serves whoever signs in there, and anyone else as an anonymous"
          , "reader, who sees the public spaces only; the operator is on the admin listener."
          , "Whether the wiki is open (anyone may make an account) or closed (by invitation"
          , "only, nothing shown to anyone not signed in) is the administration's \"Who may come in\"."
          , "The wiki's public address, the mail server invitations go through and the"
          , "providers people sign in with are set in its \"Server\" section, at"
          , "  " <> adminUrl
          , "where they take effect at once (check the providers: " <> dir <> "/bin/wiki oidc check --data " <> dir <> "/data)."
          ]
      when (has p "prev_smtp_host" || has p "prev_public_url" || has p "prev_oidc") $ do
        putStrLn (prog <> ": the previous deployment passed the server --smtp-host, --public-url or --oidc,")
        putStrLn (prog <> ": which are gone; set them again in the Server section:")
        when (has p "prev_public_url") (putStrLn (prog <> ":   the public address " <> v "prev_public_url"))
        when (has p "prev_smtp_host") $
          putStrLn (prog <> ":   mail through " <> v "prev_smtp_host" <> ":" <> (if has p "prev_smtp_port" then v "prev_smtp_port" else "587") <> ", from " <> v "prev_smtp_from" <> " (and its password)")
        forM_ (words (v "prev_oidc")) $ \provider ->
          putStrLn (prog <> ":   the provider " <> provider <> " (and its client secret)")
      when (v "prev_trust" == "yes") $ do
        putStrLn (prog <> ": the previous deployment took everyone at " <> listen <> " for the administrator")
        putStrLn (prog <> ": (--trust-network); that is gone. Sign in as an administrator there, made with")
        putStrLn (prog <> ":   " <> dir <> "/bin/wiki users add --data " <> dir <> "/data LOGIN --admin")
    else do
      putStrLn ("\nThe demo is served from " <> dir <> ". Open:")
      urls
      when (way == "proxy") (putStr (proxyNeeds port))
      putStr $
        unlines
          [ "Logs:    journalctl --user -u " <> name <> " -f"
          , "Status:  sh toolchain/deploy-local.sh --status --name " <> name <> prefixArg
          , "Stop:    sh toolchain/undeploy-local.sh --name " <> name <> prefixArg <> "   (--purge also deletes " <> dir <> ")"
          ]

-- | The PATH of a unit that uses the toolchain's TeX Live, after its bin
-- directory: the system's own programs.
unitBasePath :: String
unitBasePath = "/usr/local/bin:/usr/bin:/bin"

-- | Node's check that an address answers 200.
nodeFetch :: String
nodeFetch = "\n    fetch(process.argv[1]).then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1));\n  "

-- | Node's read of the public address the administration's Server section
-- holds.
nodePublicUrl :: String
nodePublicUrl =
  "\n    fetch(process.argv[1])\n      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))\n      .then((j) => process.stdout.write(j.publicUrl ?? \"\"), () => process.exit(1));\n  "

-- | The public address in the administration's settings, from their JSON;
-- empty for none, 'Nothing' when the JSON cannot be read.
publicUrlOf :: String -> Maybe String
publicUrlOf json = case decode (encodeFs json) of
  Just (Object o) -> Just $ case KeyMap.lookup "publicUrl" o of
    Just (String s) -> T.unpack s
    _ -> ""
  _ -> Nothing

-- | Whether an HTTPS address answers, through curl when there is one, as
-- you would check it by hand.
httpsAnswers :: FilePath -> String -> IO Bool
httpsAnswers node url = do
  curl <- isJust <$> findExecutable "curl"
  if curl
    then succeeds "curl" ["-fs", "-o", "/dev/null", "--max-time", "10", "--noproxy", "*", url]
    else
      succeeds
        node
        [ "-e"
        , "\n      fetch(process.argv[1], { signal: AbortSignal.timeout(10000) })\n        .then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1));\n    "
        , url
        ]

-- | The files under the page that are worth compressing: the page's text
-- and wasm files over a kilobyte, as the shell's
-- @find -size +1k@ picks them.
compressible :: FilePath -> IO [FilePath]
compressible dir = do
  files <- filesUnder dir
  filterM big [f | f <- files, map toLower (takeExtension f) `elem` [".wasm", ".js", ".mjs", ".css", ".html", ".svg", ".json"]]
  where
    big f = (> 1024) <$> getFileSize f

-- | Every file under a directory, by its path.
filesUnder :: FilePath -> IO [FilePath]
filesUnder dir = do
  entries <- listDirectory dir
  concat
    <$> mapM
      ( \e -> do
          let path = dir </> e
          isDir <- doesDirectoryExist path
          if isDir then filesUnder path else pure [path]
      )
      entries

chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks n xs = let (a, b) = splitAt n xs in a : chunks n b

-- | What a reverse proxy in front of the deployment must do
-- (@--behind-proxy@), with the Caddyfile that does it all.
proxyNeeds :: String -> String
proxyNeeds port =
  unlines
    [ "It is behind a reverse proxy (--behind-proxy), which must:"
    , "  - serve HTTPS and proxy to http://127.0.0.1:" <> port <> ","
    , "  - pass WebSocket upgrades on (comments and notifications arrive live at api/v1/events),"
    , "  - send X-Forwarded-Proto and X-Forwarded-Host (or keep the Host the browser asked for)."
    , "Caddy does all of it, with a certificate it fetches and renews itself, from a Caddyfile of:"
    , "  wiki.example.org {"
    , "      reverse_proxy 127.0.0.1:" <> port
    , "  }"
    ]

-- | The addresses to open, the one to use first: through tailscale serve
-- the MagicDNS name, then the listener on this machine; behind a reverse
-- proxy the listener; otherwise the listener at its address (the Tailscale
-- one for 0.0.0.0) and the MagicDNS name, over https with the server's own
-- certificate (first at the name it is for), over http without one.
printUrls :: String -> String -> String -> String -> String -> FilePath -> IO ()
printUrls httpsHost serveNote bind port way cert
  | not (null httpsHost) = do
      putStrLn ("  https://" <> httpsHost <> "/" <> serveNote)
      putStrLn ("  http://127.0.0.1:" <> port <> "/   (on this machine)")
  | way == "proxy" = do
      putStrLn "  the reverse proxy's https:// address, which proxies to"
      putStrLn ("  http://127.0.0.1:" <> port <> "/   (on this machine)")
  | otherwise = do
      urlScheme <-
        if way == "cert"
          then do
            cn <- certName cert
            unless (null cn) (putStrLn ("  https://" <> cn <> ":" <> port <> "/   (the name the certificate is for)"))
            pure "https"
          else pure "http"
      host <-
        if bind `elem` ["0.0.0.0", "::"]
          then do
            ip <- Tailscale.tailscaleIp
            case ip of
              Just a -> pure a
              Nothing -> takeWhile (/= '\n') . snd <$> outputOf "hostname" []
          else pure bind
      let host' = if ':' `elem` host then "[" <> host <> "]" else host
      putStrLn ("  " <> urlScheme <> "://" <> host' <> ":" <> port <> "/")
      dns <- Tailscale.magicDnsName
      unless (bind `elem` ["127.0.0.1", "::1"] || null dns) $
        putStrLn ("  " <> urlScheme <> "://" <> dns <> ":" <> port <> "/")

-- | The first DNS name a certificate (a PEM file) is issued for, from its
-- subjectAltName, else its subject's CN; empty when openssl is not here or
-- the certificate names none. A wildcard name stands for any name under
-- it: @wiki.@ is asked.
certName :: FilePath -> IO String
certName cert = do
  openssl <- isJust <$> findExecutable "openssl"
  if not openssl
    then pure ""
    else do
      (_, san) <- outputOf "openssl" ["x509", "-in", cert, "-noout", "-ext", "subjectAltName"]
      names <-
        case sanName san of
          Just n -> pure n
          Nothing -> do
            (_, subject) <- outputOf "openssl" ["x509", "-in", cert, "-noout", "-subject", "-nameopt", "sep_multiline"]
            pure $ case [n | l <- lines subject, Just n <- [stripPrefix "CN=" (dropWhile (== ' ') l)]] of
              n : _ -> n
              [] -> ""
      pure (maybe names ("wiki." <>) (stripPrefix "*." names))

-- | The first DNS name of @openssl x509 -ext subjectAltName@'s output: a
-- heading line, then the names separated by commas, as the shell's
-- @tr ',' '\n' | sed -n 's/^ *DNS://p'@ finds them.
sanName :: String -> Maybe String
sanName san = case [n | part <- lines (map (\c -> if c == ',' then '\n' else c) san), Just n <- [stripPrefix "DNS:" (dropWhile (== ' ') part)]] of
  n : _ -> Just n
  [] -> Nothing

-- | Whether lingering is on, which keeps the user's services running at
-- boot and after logging out; with @--enable-linger@ it is turned on.
lingerReport :: String -> Bool -> IO ()
lingerReport user enable = do
  (_, out) <- outputOf "loginctl" ["show-user", user, "-p", "Linger"]
  let linger = case [rest | l <- lines out, Just rest <- [stripPrefix "Linger=" l]] of
        l : _ -> l
        [] -> ""
  case linger of
    "yes" -> say ("lingering is on for " <> user <> ": the service starts at boot and survives logging out")
    "no"
      | enable -> do
          say ("sudo loginctl enable-linger " <> user)
          code <- runInherit "sudo" ["loginctl", "enable-linger", user]
          if code == ExitSuccess
            then say "lingering is now on: the service starts at boot and survives logging out"
            else warn ("could not enable lingering; run: sudo loginctl enable-linger " <> user)
      | otherwise -> do
          say ("lingering is off for " <> user <> ": the service stops when you log out and does not start at boot.")
          say ("  To keep it running: sudo loginctl enable-linger " <> user <> "   (or rerun with --enable-linger)")
    _ -> say ("cannot tell whether lingering is on for " <> user <> " (loginctl show-user " <> user <> " -p Linger); without it the service stops when you log out")

-- | Stop a deployment's PostgreSQL container, keeping its volume.
pgDown :: String -> FilePath -> String -> IO ()
pgDown name pgDir port = do
  there <- doesDirectoryExist pgDir
  when there $ do
    ready <- dockerReady
    if not ready
      then warn ("Docker does not answer, so the PostgreSQL container of " <> name <> " was left as it is (docker compose --project-name " <> name <> " stop)")
      else do
        environment <- (<>) [("WIKI_DB_PASSWORD_FILE", pgDir </> "db-password"), ("WIKI_DB_PORT", if null port then "5433" else port)] . filter ((`notElem` ["WIKI_DB_PASSWORD_FILE", "WIKI_DB_PORT"]) . fst) <$> getEnvironmentList
        code <- runProcess (quietly (setEnv environment (proc "docker" ["compose", "--project-name", name, "--file", pgDir </> "docker-compose.yml", "--file", pgDir </> "local.yml", "stop", "postgres"])))
        if code == ExitSuccess
          then say ("stopped the PostgreSQL container of " <> name <> "; its data stays in the volume " <> name <> "_wiki-db")
          else warn ("could not stop the PostgreSQL container of " <> name <> " (docker compose --project-name " <> name <> " stop postgres)")
  where
    dockerReady = do
      docker <- isJust <$> findExecutable "docker"
      if not docker
        then pure False
        else (&&) <$> succeeds "docker" ["compose", "version"] <*> succeeds "docker" ["info"]
    getEnvironmentList = getEnvironment

-- | Stop the deploy as the shell's @set -e@ does, with the status of a
-- command that failed.
orDie :: ExitCode -> IO ()
orDie = \case
  ExitSuccess -> pure ()
  code -> exitWith code

-- | What a command prints, its errors after its output as @2>&1@ gives
-- them in order, and whether it succeeded.
outputWithErrors :: FilePath -> [String] -> IO (Bool, String)
outputWithErrors program args = do
  result <- try (readProcessInterleaved (setStdin nullStream (proc program args)))
  pure $ case result of
    Right (code, out) -> (code == ExitSuccess, decodeFs out)
    Left (_ :: IOException) -> (False, "")

-- | What a command prints on standard output, its errors left on the
-- terminal, and whether it succeeded.
outputKeepingErrors :: FilePath -> [String] -> IO (Bool, String)
outputKeepingErrors program args = do
  result <- try (readProcessStdout (setStdin nullStream (proc program args)))
  pure $ case result of
    Right (code, out) -> (code == ExitSuccess, decodeFs out)
    Left (_ :: IOException) -> (False, "")

-- | A text without its final newlines, as @$(…)@ gives it.
chomp :: String -> String
chomp = reverse . dropWhile (== '\n') . reverse

dropSlash :: String -> String
dropSlash s = fromMaybe s (stripSuffix "/" s)
  where
    stripSuffix suffix t = reverse <$> stripPrefix (reverse suffix) (reverse t)

seconds :: IO Int
seconds = truncate <$> getPOSIXTime

-- | The host a deploy probes its own listener at: the loopback address for
-- a listener on every address, the address in brackets for IPv6.
hostOf :: String -> String
hostOf bind = case bind of
  "0.0.0.0" -> "127.0.0.1"
  "::" -> "[::1]"
  b | ':' `elem` b -> "[" <> b <> "]"
  b -> b

-- | The URL a deploy probes a deployment at: wiki-server's
-- @api\/v1\/info@, or the demo's page, over HTTPS when wiki-server
-- serves it with its own certificate.
serverUrl :: Bool -> String -> String -> String -> String
serverUrl server bind port way =
  (if way == "cert" then "https" else "http") <> "://" <> hostOf bind <> ":" <> port <> "/" <> (if server then "api/v1/info" else "")

-- | Whether a URL answers 200: with Node's fetch when Node is given, with
-- curl for HTTPS (the deploy probes its own listener, so the certificate
-- is not checked here) and where there is no Node.
urlAnswers :: Maybe FilePath -> String -> IO Bool
urlAnswers node url = case node of
  Just n | not ("https://" `isPrefixOf` url) -> succeeds n ["-e", nodeFetch, url]
  _ -> (== "200") . snd <$> outputOf "curl" (["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", "--noproxy", "*"] <> ["--insecure" | "https://" `isPrefixOf` url] <> [url])

-- | Whether a user service answers at a URL within the time a deploy waits
-- for one (WIKI_DEPLOY_WAIT, 20 seconds by default). The service being
-- active is not enough: systemd counts a service as active as soon as its
-- program starts, before the program has opened its database and its
-- listeners.
answersWithin :: String -> (String -> IO Bool) -> String -> IO Bool
answersWithin service answers url = do
  wait <- maybe 20 id . (>>= readMaybe) <$> lookupEnv "WIKI_DEPLOY_WAIT"
  let loop (n :: Int) = do
        up <- succeeds "systemctl" ["--user", "is-active", "--quiet", service]
        ok <- if up then answers url else pure False
        if ok || n + 1 >= wait then pure ok else threadDelay 1000000 >> loop (n + 1)
  loop 0

-- | @deploy-local.sh --rollback@: put back the deployment kept in
-- @previous/@ (Maker.Deploy.Upgrade), by hand, after saying what comes back
-- and what is lost, and asking. The database goes back to the backup made
-- before the upgrade, so everything written since is lost unless exported
-- first. Without a terminal to ask on, @--yes@ (the plan's @yes@) answers.
rollbackByHand :: Plan -> IO ()
rollbackByHand p = do
  let v = get p
      name = v "name"
      dir = v "dir"
      service = name <> ".service"
      pgDir = v "state_dir" </> (name <> ".postgres")
  mk <- readKept dir
  k <- maybe (die ("there is no previous deployment kept in " <> previousDir dir <> " to roll back to: a deploy keeps one when it replaces a server")) pure mk
  say ("the deployment kept in " <> previousDir dir <> " is of commit " <> k.commit <> ", kept " <> k.keptAt)
  oldDb <- stateGet "db" (previousDir dir </> "state")
  nowDb <- stateGet "db" (v "state_file")
  case () of
    _
      | not (null k.backup) -> do
          say ("its database goes back to the backup " <> k.backup <> ": everything written since is lost, unless exported first (Export in the administration)")
          unless (null k.aside) (say ("and the file the upgrade set aside in " <> k.aside <> " goes back into " <> dir </> "data"))
      | not (null k.aside) && kindOf nowDb == "postgres" ->
          say ("its wiki comes back from " <> k.aside <> ", where the move to PostgreSQL (or the upgrade) set it aside; what was written since stays in PostgreSQL, the volume " <> name <> "_wiki-db, whose container stops")
      | not (null k.aside) ->
          say ("its wiki comes back from " <> k.aside <> ", where the upgrade set it aside; the wiki written since is set aside in its place, in " <> dir </> "data" </> "replaced")
      | kindOf oldDb /= kindOf nowDb && kindOf oldDb == "postgres" ->
          say ("its wiki is the one in PostgreSQL (the volume " <> name <> "_wiki-db), which the upgrade left as it was; the SQLite wiki written since is set aside in " <> dir </> "data" </> "replaced")
      | kindOf oldDb /= kindOf nowDb ->
          say ("its wiki is SQLite's, which the upgrade did not change; the PostgreSQL container stops, and its volume " <> name <> "_wiki-db keeps what was written since")
      | otherwise -> say "its database is left as it is: there was none when it was kept"
  terminal <- hIsTerminalDevice stdin
  answer <-
    if has p "yes"
      then pure True
      else
        if terminal
          then do
            putStr (prog <> ": roll back? [y/N] ") >> hFlush stdout
            reply <- getLine
            pure (map toLower reply `elem` ["y", "yes"])
          else die "--rollback asks first, and there is no terminal to ask on: run it on one, or add --yes"
  unless answer (die "nothing was changed")
  -- The settings as the deployment being replaced has them, from its state.
  now <- settingsOf (v "state_file")
  let place = Place {name = name, dir = dir, unitFile = v "unit_file", stateFile = v "state_file", stateDir = v "state_dir", pgDir = pgDir, noFirewall = has p "no_firewall"}
  restored <- rollBackDeployment place Nothing now k
  unless restored $
    die ("the rollback stopped before the files went back (see above). " <> (if null k.backup then "" else "If the restore failed, restore " <> k.backup <> " by hand with " <> previousDir dir </> "bin" </> "wiki-server restore; ") <> "fix the cause and run --rollback again")
  let back = rollbackPlace place k
  if k.running
    then do
      url <- deploymentUrl back.stateFile
      node <- findExecutable "node"
      running <- startAgain service (urlAnswers node) url
      if running
        then say ("rolled back to commit " <> k.commit <> "; " <> service <> " answers on " <> url)
        else die ("rolled back to commit " <> k.commit <> ", but " <> service <> " does not answer on " <> url <> "; see journalctl --user -u " <> name)
    else do
      leaveStopped back k
      say ("rolled back to commit " <> k.commit <> "; " <> service <> " is left stopped, as it was before the upgrade")

-- | The database options of the deployment kept in @previous/@, read from
-- the state file kept with it. The backup a rollback restores is of that
-- database, which differs from the current one when the upgrade moved the
-- wiki between SQLite and PostgreSQL.
keptPlaceArgs :: FilePath -> FilePath -> IO [String]
keptPlaceArgs dir pgDir = do
  db <- stateGet "db" (previousDir dir </> "state")
  dbPort <- stateGet "db_port" (previousDir dir </> "state")
  pure $
    if db == "postgres"
      then ["--data", dir </> "data", "--database", dbUrl dbPort, "--database-password-file", pgDir </> "db-password", "--pg-dump", pgDir </> "pg_dump", "--pg-restore", pgDir </> "pg_restore"]
      else ["--data", dir </> "data", "--sqlite", dir </> "data" </> "wiki.sqlite"]

-- | The settings outside a deployment's files that an upgrade can change
-- and a rollback puts back: the port of the ufw rule the deploy opened, the
-- port tailscale serve proxies to, and the database's kind and published
-- port. Empty means none.
data Settings = Settings
  { rulePort :: String
  , servePort :: String
  , db :: String
  , dbPort :: String
  }

-- | A deployment's settings as its state file records them.
settingsOf :: FilePath -> IO Settings
settingsOf file = do
  rule <- stateGet "rule_port" file
  serve <- stateGet "serve_port" file
  kind <- stateGet "db" file
  port <- stateGet "db_port" file
  pure Settings {rulePort = rule, servePort = serve, db = kind, dbPort = port}

-- | Where a deployment's pieces are, for a rollback.
data Place = Place
  { name :: String
  , dir :: FilePath
  , unitFile :: FilePath
  , stateFile :: FilePath
  , stateDir :: FilePath
  , pgDir :: FilePath
  , noFirewall :: Bool
  }

-- | Put the kept deployment back (WP5.73c of docs/PLAN.md), given the
-- settings the deployment being replaced has now. In order: the service
-- stops; the database the upgrade started goes (a new PostgreSQL
-- container stopped, a new @wiki.sqlite@ set aside) and the one it set
-- aside comes back; an adoption under @--prefix@ is undone; PostgreSQL goes
-- back to its old port, since the restore connects there; the database is
-- restored from the kept backup, when there is one; the files and unit go
-- back; the firewall rule and tailscale serve go back to the old ports.
-- The service is left stopped for the caller, which starts it if it was
-- running. The answer is whether the rollback was made: a restore that
-- fails stops it before the files move.
rollBackDeployment :: Place -> Maybe Firewall.Firewall -> Settings -> Kept -> IO Bool
rollBackDeployment place firewall now k = do
  let service = place.name <> ".service"
      back = rollbackPlace place k
  say ("rolling back to the previous deployment (" <> k.commit <> "), kept in " <> previousDir place.dir)
  _ <- runInherit "systemctl" ["--user", "stop", service]
  old <- settingsOf (previousDir place.dir </> "state")
  -- From SQLite to PostgreSQL: the new container stops, and its volume
  -- keeps what the upgrade wrote.
  when (kindOf now.db == "postgres" && kindOf old.db /= "postgres") $
    pgDown place.name place.pgDir now.dbPort
  -- The wiki.sqlite the upgrade started is set aside, as the upgrade set
  -- the old one aside, when the old wiki is elsewhere: in PostgreSQL, or in
  -- the files the upgrade set aside, which come back in its place.
  when (kindOf now.db == "sqlite" && (kindOf old.db /= "sqlite" || not (null k.aside))) $ do
    moved <- setAside place.dir
    forM_ moved $ \aside -> say ("moved the wiki the upgrade started aside into " <> aside)
  unless (null k.aside) (putAsideBack place.dir k.aside)
  unless (null k.adoptedFrom) (unadopt place.dir place.name place.pgDir k)
  -- PostgreSQL runs on the kept port before the restore, which connects
  -- there: moved back when the upgrade changed the port or the kind, and
  -- started in any case, so that a --rollback retried after a move that
  -- failed finds it up even though the two states name the same port.
  -- A PostgreSQL that does not start stops the rollback here, before the
  -- files move: the old server could not run without it, and previous/
  -- must stay for a --rollback once the cause is fixed.
  pgUp <-
    if kindOf old.db /= "postgres"
      then pure True
      else do
        files <- doesFileExist (back.pgDir </> "docker-compose.yml")
        if not files
          then do
            warn ("PostgreSQL's files are not in " <> back.pgDir <> ", so its container cannot start: the rollback stopped there, and the previous deployment is still in " <> previousDir place.dir)
            pure False
          else do
            when (old.dbPort /= now.dbPort || kindOf now.db /= "postgres") (say ("moving PostgreSQL back to 127.0.0.1:" <> old.dbPort))
            forM_ ["pg_dump", "pg_restore"] $ \program ->
              writeFile (back.pgDir </> program) (pgWrapper place.name back.pgDir old.dbPort program)
            code <- pgCompose place.name back.pgDir old.dbPort ["up", "--detach", "--wait", "postgres"]
            unless (code == ExitSuccess) $
              warn ("PostgreSQL did not start on 127.0.0.1:" <> old.dbPort <> " (see above), so the rollback stopped there: the previous deployment is still in " <> previousDir place.dir)
            pure (code == ExitSuccess)
  args <- keptPlaceArgs place.dir back.pgDir
  restored <- if pgUp then restoreDatabase place.dir args k else pure False
  when restored $ do
    putBackFiles place.dir place.unitFile back.stateFile service k
    -- After an adoption the state goes back where it was, and the one
    -- under the prefix goes, with its directory when nothing else is in it.
    when (back.stateFile /= place.stateFile) $ do
      removePathForcibly place.stateFile
      left <- listDirectory place.stateDir
      when (null left) (removeDirectory place.stateDir)
    when (now.rulePort /= old.rulePort) $ do
      found <- case firewall of
        Just f -> pure (Just f)
        Nothing | place.noFirewall -> pure Nothing
        Nothing -> Just <$> Firewall.probe
      case found of
        Nothing -> do
          say ("--no-firewall: the firewall rule stays as it is; the previous deployment had " <> (if null old.rulePort then "none" else "one for port " <> old.rulePort))
          -- The state put back keeps naming the rule that is open, so
          -- that a later deploy or --stop closes that one.
          stateSet "rule_port" now.rulePort back.stateFile
        Just f -> do
          unless (null now.rulePort) (Firewall.close f back.stateDir back.stateFile now.rulePort)
          unless (null old.rulePort) (Firewall.open f place.name old.rulePort)
          Firewall.report f
    serveBack now.servePort old.servePort
  pure restored

-- | Where the pieces of the deployment a rollback goes back to are: those
-- of the deployment being replaced, but after an adoption under
-- @--prefix@ the state and PostgreSQL's files are where they were before
-- it, beside the state file 'adoptedFrom' names.
rollbackPlace :: Place -> Kept -> Place
rollbackPlace place k
  | null k.adoptedFrom = place
  | otherwise =
      let stateDir = takeDirectory k.adoptedFrom
       in Place
            { name = place.name
            , dir = place.dir
            , unitFile = place.unitFile
            , stateFile = k.adoptedFrom
            , stateDir = stateDir
            , pgDir = stateDir </> (place.name <> ".postgres")
            , noFirewall = place.noFirewall
            }

-- | The kind of a database a state file names: @postgres@, or @sqlite@,
-- which a state written before PostgreSQL leaves out.
kindOf :: String -> String
kindOf db = if db == "postgres" then "postgres" else "sqlite"

-- | Point tailscale serve back at the previous deployment's port, or turn
-- it off when the previous deployment had no serve. As the deploy does, a
-- serve that proxies to neither deployment's port is someone else's and is
-- left alone.
serveBack :: String -> String -> IO ()
serveBack now old
  | now == old = pure ()
  | null old = Tailscale.serveOff now
  | otherwise = do
      current <- Tailscale.serveRead
      case current of
        Nothing -> warn ("tailscale serve status does not answer, so tailscale serve was not pointed back at 127.0.0.1:" <> old <> "; run: tailscale serve --bg http://127.0.0.1:" <> old)
        Just s
          | Tailscale.proxiesTo s old -> pure ()
          | null s.kind || (not (null now) && Tailscale.proxiesTo s now) -> do
              say ("tailscale serve --bg http://127.0.0.1:" <> old)
              (ok, out) <- Tailscale.outputOfBoth 60 ["serve", "--bg", "http://127.0.0.1:" <> old]
              unless ok $ do
                hPutStr stderr (Tailscale.indented out)
                warn "could not point tailscale serve back (see above)"
                Tailscale.rightsHint ("serve --bg http://127.0.0.1:" <> old)
          | otherwise -> warn ("tailscale serve serves " <> s.kind <> " " <> s.target <> ", which this deployment did not set, so it is left alone")

-- | Start a service again after a rollback, and wait for it to answer.
startAgain :: String -> (String -> IO Bool) -> String -> IO Bool
startAgain service answers url = do
  _ <- runInherit "systemctl" ["--user", "restart", service]
  answersWithin service answers url

-- | The URL a server deployment answers at, as its state file describes
-- it. After a rollback the state is the restored deployment's, whose port,
-- address or HTTPS way may differ from the deployment rolled back.
deploymentUrl :: FilePath -> IO String
deploymentUrl stateFile = do
  bind <- stateGet "bind" stateFile
  port <- stateGet "port" stateFile
  way <- stateGet "way" stateFile
  pure (serverUrl True bind port way)

-- | Leave a rolled-back deployment stopped, as it was before the upgrade:
-- its PostgreSQL container too, which the deploy started, unless the
-- container was running before the deploy (the wiki's service can be
-- stopped or failed while its database runs).
leaveStopped :: Place -> Kept -> IO ()
leaveStopped place k = do
  kind <- stateGet "db" place.stateFile
  port <- stateGet "db_port" place.stateFile
  when (kind == "postgres" && not k.dbRunning) (pgDown place.name place.pgDir port)
