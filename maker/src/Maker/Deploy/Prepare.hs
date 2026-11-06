-- | The part of a deploy between the TeX step and the moment the running
-- deployment starts to change: the builds (the page's bundles, the
-- application, wiki-server at -O2), the checks of what they made, the
-- service's Node, whether HTTPS can be served through Tailscale, whether
-- the ports are free, the adoption of a deployment made before @--prefix@,
-- and PostgreSQL's container. Nothing here changes what the running
-- deployment uses, so a failure stops the deploy with nothing changed.
--
-- It works out values the shell used to put into the plan (the Node, the
-- HTTPS host, the address, the server's binary, the state's place after an
-- adoption, whether the database is incompatible) and hands the plan on to
-- "Maker.Deploy.Apply". Its messages and the commands it runs are
-- @toolchain/deploy-local.sh@'s, as there.
module Maker.Deploy.Prepare
  ( prepare
  , pageBackend
  , localYml
  , pgWrapper
  , pgCompose
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM, forM_, unless, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toLower)
import Data.IORef
import Data.List (isInfixOf, sort, sortOn, stripPrefix)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time (UTCTime, getCurrentTime)
import Maker.Deploy.Plan
import Maker.Deploy.Tailscale qualified as Tailscale
import System.Directory
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (exitWith)
import System.FilePath (makeRelative, takeExtension, (</>))
import System.IO
import System.Process.Typed

-- | Do the deploy's preparing steps and answer the plan with what they
-- worked out.
prepare :: Plan -> IO Plan
prepare p0 = do
  let v = get p0
      root = v "root"
      out = v "out"
      server = v "mode" == "server"
      build = has p0 "build"
      prebuilt = has p0 "prebuilt"
      name = v "name"
  -- The builds.
  when (build && prebuilt) $ do
    when (has p0 "bundle_locally") (bundleLocally p0)
    when server $ do
      say "building wiki-server at -O2 (cabal-native-opt.project)"
      serverBuildNative p0
  when (build && not prebuilt) $ do
    say "npm ci"
    orExit =<< runIn root "npm" ["ci", "--no-audit", "--no-fund"] []
    say "building the application (npm run build-wasm-opt)"
    -- The wiki is served at the root of its own port.
    orExit =<< runIn root "npm" ["run", "build-wasm-opt"] [("HALOGEN_BASE_PATH", "/"), ("WIKI_BACKEND", if server then "server" else "demo")]
    when server $ do
      say "building wiki-server at -O2 (cabal-native-opt.project)"
      serverBuildNative p0
  forM_ ["index.html", "404.html", "app.wasm"] $ \file -> do
    there <- doesFileExist (out </> file)
    unless there (die ("the build in " <> out <> " lacks " <> file <> "; run without --no-build"))
  -- The commit the deployed files were built from, which a rollback names
  -- (WP5.73): this checkout's when this deploy builds, written beside the
  -- builds for a later --no-build; with --no-build, the one the last build
  -- wrote, since the checkout may have moved on since; unknown without one.
  let commitFile = root </> "dist-newstyle" </> ("deployed-commit." <> v "mode")
  commit <-
    if build
      then do
        createDirectoryIfMissing True (root </> "dist-newstyle")
        writeFile commitFile (v "git_commit" <> "\n")
        pure (v "git_commit")
      else do
        there <- doesFileExist commitFile
        recorded <- if there then takeWhile (/= '\n') <$> readFileStrict commitFile else pure ""
        pure (if null recorded then "unknown" else recorded)
  -- The page in out is the last one built or downloaded, for whichever
  -- mode that run had: with --no-build nothing replaces it, so a page of
  -- the other mode would be installed for the wrong server. The page's
  -- <meta name="wiki-backend"> says which it is; a page without one is not
  -- checked.
  unless build $ do
    index <- readFile (out </> "index.html")
    case pageBackend index of
      Just backend
        | backend /= v "page_kind" ->
            die ("the page in " <> out <> " is the " <> backend <> "'s, and this deploy is of the " <> v "page_kind" <> " (--" <> v "mode" <> "): run without --no-build, which builds or downloads the " <> v "page_kind" <> "'s page")
      _ -> pure ()
  serverBin <-
    if not server
      then pure ""
      else do
        (ok, found) <- serverCabalOutput p0 "list-bin" ["-v0"]
        let binary = takeWhile (/= '\n') found
        usable <- if ok && not (null binary) then isExecutable binary else pure False
        unless usable (die "there is no -O2 build of wiki-server (dist-newstyle/native-opt); run without --no-build")
        pure binary

  -- The service's Node, by absolute path: the managed one if the bootstrap
  -- installed it (through the link .wiki-toolchain/node, which an upgrade
  -- moves), otherwise the one on PATH. A deployment with --backend-only has
  -- none: it serves with wiki-server.
  let managed = v "toolchain_base" </> ".wiki-toolchain" </> "node" </> "bin" </> "node"
  node <-
    if has p0 "nodeless"
      then pure ""
      else do
        managedThere <- if has p0 "system_tools" then pure False else isExecutable managed
        if managedThere
          then pure managed
          else
            findExecutable "node" >>= \case
              Just onPath -> do
                real <- canonicalizePath onPath
                warn ("using " <> real <> " for the service; it must stay where it is (the bootstrap's own Node, in " <> v "toolchain_base" <> "/.wiki-toolchain, would)")
                pure real
              Nothing -> die "no Node to run the static server with; run sh toolchain/bootstrap.sh node, which installs it"

  -- Whether HTTPS can be served: Tailscale running, with MagicDNS and
  -- certificates for this machine's name. Without them this deployment
  -- serves plain HTTP as --http would, but stays HTTPS by choice, so that a
  -- later run, once they are on, moves to it.
  bindRef <- newIORef (v "bind")
  httpsHost <-
    if v "https" /= "yes"
      then pure ""
      else do
        let dnsOff = "in the tailnet's DNS settings (https://login.tailscale.com/admin/dns)"
        Tailscale.tailscaleHttps >>= \case
          Nothing -> do
            warn "Tailscale does not answer (tailscale status), so cannot serve HTTPS through tailscale serve; listening on 127.0.0.1 only. Rerun when it is up, or deploy with --http"
            pure ""
          Just ts -> do
            host <-
              if ts.name == "-" || not ts.magicDns
                then do
                  warn ("MagicDNS is off, so this machine has no name to serve HTTPS on: turn on MagicDNS and HTTPS Certificates " <> dnsOff <> " and run this again. Serving plain HTTP meanwhile, as --http does")
                  pure ""
                else
                  if not ts.certificates
                    then do
                      warn ("the tailnet does not issue HTTPS certificates for " <> ts.name <> ": turn on HTTPS Certificates " <> dnsOff <> " and run this again. Serving plain HTTP meanwhile, as --http does")
                      pure ""
                    else pure ts.name
            when (null host && v "bind_choice" == "auto") $
              Tailscale.tailscaleIp >>= \case
                Just ip -> do
                  writeIORef bindRef ip
                  say ("listening on the Tailscale address " <> ip)
                Nothing -> writeIORef bindRef "127.0.0.1"
            pure host
  bind <- readIORef bindRef
  let port = v "port"
  servePort <-
    if null httpsHost
      then pure ""
      else do
        say ("serving HTTPS at https://" <> httpsHost <> "/ through tailscale serve, from 127.0.0.1:" <> port)
        pure port

  -- A port another program holds would only show as a service failing to
  -- start after the old one is gone, so find out first. The running
  -- deployment's own port is not checked: it is about to be freed.
  active <- succeeds "systemctl" ["--user", "is-active", "--quiet", name <> ".service"]
  unless (port == v "prev_port" && bind == v "prev_bind" && active) $ do
    free <- canListen (has p0 "nodeless") node port bind
    unless free (die ("cannot listen on " <> bind <> ":" <> port <> " (see above): choose another --port or --bind"))
  when (server && not (v "prev_mode" == "server" && v "admin_port" == v "prev_admin_port" && active)) $ do
    free <- canListen (has p0 "nodeless") node (v "admin_port") "127.0.0.1"
    unless free (die ("cannot listen on 127.0.0.1:" <> v "admin_port" <> " (see above): choose another --admin-port"))

  -- A deployment made before --prefix is adopted now that the build is
  -- done: its state comes under the prefix, where what follows writes.
  (stateDir, stateFile, adoptedPgDir) <- adoptIntoPrefix p0
  let pgDir = stateDir </> (name <> ".postgres")
      dir = v "dir"
      sqlite = dir </> "data" </> "wiki.sqlite"

  -- The wiki's database. On PostgreSQL its files are written and its
  -- container is made, or started, and waited for; this changes nothing
  -- the running deployment uses. Then a data/wiki.sqlite this deployment
  -- cannot use stops the deploy, unless --fresh (or a "yes") moves it aside.
  incompatible <-
    if not server
      then pure ""
      else do
        when (v "db" == "postgres") $ do
          pgFiles p0 pgDir
          say ("starting PostgreSQL in Docker (the compose project " <> name <> ", on 127.0.0.1:" <> v "db_port" <> ") and waiting for it")
          code <- pgCompose name pgDir (v "db_port") ["up", "--detach", "--wait", "postgres"]
          unless (code == ExitSuccess) (die "PostgreSQL did not start (see above): if the port is taken, choose another with --db-port, or deploy with --sqlite")
        sqliteThere <- doesFileExist sqlite
        let fromFile
              | sqliteThere && v "db" == "postgres" && not (has p0 "prev_db") =
                  sqlite <> " holds a wiki of a wiki-server from before PostgreSQL (or one on SQLite), and this deployment keeps the wiki in PostgreSQL"
              | sqliteThere && v "db" == "postgres" = sqlite <> " holds the wiki in SQLite, and this deployment keeps it in PostgreSQL"
              | otherwise = ""
            -- From PostgreSQL to SQLite: the new wiki starts empty in a file,
            -- and the old one stays in the container's volume.
            toSqlite
              | v "db" == "sqlite" && v "prev_db" == "postgres" =
                  "this deployment kept the wiki in PostgreSQL (the volume " <> name <> "_wiki-db), and --sqlite keeps it in " <> sqlite <> ", so the new wiki starts empty; the PostgreSQL container is stopped and its volume kept, and --postgres goes back to it"
              | otherwise = fromFile
            -- --fresh moves a data/wiki.sqlite aside whatever it holds.
            found
              | has p0 "fresh" && sqliteThere && null toSqlite = sqlite <> " is set aside (--fresh)"
              | otherwise = toSqlite
        when (not (null found) && not (has p0 "fresh")) $ do
          warn ("the state is incompatible: " <> found <> ". Its content moves by export and import: export the wiki with the running server (Administration, Wiki data, Export the wiki), go on here, then import the archive into the new wiki (Administration, Wiki data, Import). Going on moves a data/wiki.sqlite aside into " <> dir <> "/data/replaced/<time>/; nothing is deleted")
          interactive <- (&&) <$> hIsTerminalDevice stdin <*> hIsTerminalDevice stdout
          if interactive
            then do
              putStr (prog <> ": type yes to start an empty wiki: ")
              hFlush stdout
              answer <- try getLine
              case answer of
                Right "yes" -> pure ()
                Right _ -> die "nothing was changed"
                Left (_ :: IOException) -> die "nothing was changed"
            else die "nothing was changed: run this again with --fresh to start an empty wiki"
        pure found
  pure
    . set "git_commit" commit
    . set "node" node
    . set "bind" bind
    . set "https_host" httpsHost
    . set "serve_port" servePort
    . set "server_bin" serverBin
    . set "state_dir" stateDir
    . set "state_file" stateFile
    . set "adopted_pg_dir" adoptedPgDir
    . set "incompatible" incompatible
    $ p0

-- | The backend a page was built for, from its
-- @<meta name="wiki-backend" content="…">@, as the build writes it.
pageBackend :: String -> Maybe String
pageBackend html = listToMaybe [b | l <- lines html, Just b <- [lineBackend l]]
  where
    marker = "<meta name=\"wiki-backend\" content=\""
    -- The shell's sed takes the last tag on a line (its leading .* is
    -- greedy) whose value is lower-case letters closed by a quote.
    lineBackend l = case [b | rest <- tails' l, Just after <- [stripPrefix marker rest], let (b, close) = span (`elem` ['a' .. 'z']) after, take 1 close == "\""] of
      [] -> Nothing
      found -> Just (last found)
    tails' [] = []
    tails' t@(_ : more) = t : tails' more

-- | What web/bundle.sh writes into the page, which --bundle-locally
-- removes first: the names at the page's root that web/bundle.sh's header
-- lists. toolchain/test-deploy-local.sh checks that the two agree.
bundleOutputs :: [FilePath]
bundleOutputs = ["islands.js", "islands", "tikzjax", "islands.css", "fonts", "wasi-shim.js", "licenses.txt", "icon.svg", "icons", "sw.js"]

-- | Build the page's bundles here and compare the page with CI's
-- (--bundle-locally). Of a page CI built, everything but what web/bundle.sh
-- writes needs the wasm toolchain or comes from the checkout's web/
-- (app.wasm, its ghc_wasm_jsffi.js, the prerendered index.html and the
-- page's other files). Here what web/bundle.sh writes is deleted from the
-- page and built again, from the checkout's package-lock.json, with npm ci
-- and web/bundle.sh, into the page itself: its service worker (sw.js) is
-- versioned by a hash of the page's files, the kept ones included. Then the
-- page is compared with CI's (@ci_page@, a copy of the zip's files that
-- "Maker.Deploy.Page" kept): with the lockfile's versions the two should be
-- identical, which is the evidence that the bundles CI built hold nothing
-- else.
bundleLocally :: Plan -> IO ()
bundleLocally p = do
  let ciPage = get p "ci_page"
      out = get p "out"
      root = get p "root"
  -- The page's directory, whose bundles are removed below, is never empty:
  -- with an empty one they would be removed from the working directory.
  when (null out) (die "--bundle-locally: the page's directory is not known")
  there <- doesDirectoryExist ciPage
  unless there (die "--bundle-locally: there is no copy of the page CI built to compare with (dist-newstyle/wasm-opt/ci-page)")
  forM_ bundleOutputs $ \o -> removePathForcibly (out </> o)
  say ("npm ci, for the page's bundles" <> (if has p "npm_registry" then ", from the npm registry " <> get p "npm_registry" else ""))
  npmCode <- runIn root "npm" ["ci", "--no-audit", "--no-fund"] []
  unless (npmCode == ExitSuccess) (die "npm ci failed (see above), so nothing was changed")
  say "building the page's JavaScript and CSS bundles here (sh web/bundle.sh)"
  bundleCode <- runIn root "sh" ["web/bundle.sh", out] []
  unless (bundleCode == ExitSuccess) (die "web/bundle.sh failed (see above), so nothing was changed")
  ci <- pageFiles ciPage
  here <- pageFiles out
  let ciSet = Set.fromList ci
      hereSet = Set.fromList here
      both = filter (`Set.member` hereSet) ci
  differ <- filterM (\f -> (/=) <$> BS.readFile (ciPage </> f) <*> BS.readFile (out </> f)) both
  let onlyCi = filter (`Set.notMember` hereSet) ci
      onlyHere = filter (`Set.notMember` ciSet) here
      total = show (length ci)
  if null differ && null onlyCi && null onlyHere
    then say ("the page with the bundles built here and the page CI built are identical: the same " <> total <> " files, byte for byte")
    else do
      warn ("the page with the bundles built here differs from the page CI built (" <> total <> " files): " <> show (length differ) <> " differ, " <> show (length onlyCi) <> " are in CI's alone, " <> show (length onlyHere) <> " are here alone; the page built here is the one deployed")
      forM_ differ $ \f -> hPutStrLn stderr ("    differs:          " <> f)
      forM_ onlyCi $ \f -> hPutStrLn stderr ("    only in CI's:     " <> f)
      forM_ onlyHere $ \f -> hPutStrLn stderr ("    only built here:  " <> f)
  removePathForcibly ciPage

-- | The files of a page, by their paths under it, sorted.
pageFiles :: FilePath -> IO [FilePath]
pageFiles dir = sort . map (makeRelative dir) <$> filesUnder dir
  where
    filesUnder d = do
      entries <- listDirectory d
      concat
        <$> forM
          entries
          ( \e -> do
              let path = d </> e
              isDir <- doesDirectoryExist path
              isLink <- pathIsSymbolicLink path
              if isDir && not isLink then filesUnder path else pure [path]
          )

-- | The version wiki-server says it is: WIKI_BUILD_VERSION, else what git
-- describes the checkout as.
buildVersion :: FilePath -> IO String
buildVersion root =
  lookupEnv "WIKI_BUILD_VERSION" >>= \case
    Just version | not (null version) -> pure version
    _ -> do
      (ok, out) <- outputOf "git" ["-C", root, "describe", "--tags", "--always", "--dirty"]
      let version = takeWhile (/= '\n') out
      pure (if ok && not (null version) then version else "unknown")

-- | cabal on wiki-server's -O2 build, after the changelog's stamp, with
-- the version in the environment, as the shell's server_cabal: the
-- command's arguments and the extra ones.
serverCabalArgs :: Plan -> String -> [String] -> [String]
serverCabalArgs p command extra =
  [command, "--project-file=cabal-native-opt.project", "--builddir=dist-newstyle/native-opt", "wiki-server:exe:wiki-server", "--constraint=wiki-server " <> (if get p "db" == "sqlite" then "-" else "+") <> "postgres"] <> extra

-- | Write the changelog's stamp for the build's version, which wiki-server
-- embeds; 'Nothing' when the stamp fails.
stampVersion :: Plan -> IO (Maybe String)
stampVersion p = do
  version <- buildVersion (get p "root")
  code <- runIn (get p "root") "sh" ["toolchain/changelog-stamp.sh"] [("WIKI_BUILD_VERSION", version)]
  pure (if code == ExitSuccess then Just version else Nothing)

-- | What a server cabal command prints, and whether it and the stamp
-- succeeded.
serverCabalOutput :: Plan -> String -> [String] -> IO (Bool, String)
serverCabalOutput p command extra =
  stampVersion p >>= \case
    Nothing -> pure (False, "")
    Just version -> do
      environment <- withVars [("WIKI_BUILD_VERSION", version)]
      result <- try (readProcessStdout (setWorkingDir (get p "root") (setEnv environment (setStdin nullStream (proc "cabal" (serverCabalArgs p command extra))))))
      pure $ case result of
        Right (code, out) -> (code == ExitSuccess, decodeFs out)
        Left (_ :: IOException) -> (False, "")

-- | Whether the build semaphore is used, by --semaphore or --no-semaphore,
-- or else by toolchain/check-semaphore.sh's probe.
semaphoreFlag :: Plan -> IO String
semaphoreFlag p = case get p "opt_semaphore" of
  "on" -> say "build semaphore: on, as --semaphore asks (not probed)" >> pure "--semaphore"
  "off" -> say "build semaphore: off, as --no-semaphore asks" >> pure "--no-semaphore"
  _ -> do
    (code, out) <- readProcessInterleaved (setStdin nullStream (proc "sh" [get p "root" </> "toolchain" </> "check-semaphore.sh"])) `orElse` (ExitFailure 127, "")
    -- The first line of the probe's error, which names the failure,
    -- without the probe's own name and a closing colon.
    let reason = case filter (not . null) (lines (decodeFs out)) of
          l : _ ->
            let l' = fromMaybe l (stripPrefix "check-semaphore: " l)
             in if not (null l') && last l' == ':' then init l' else l'
          [] -> ""
        orProbe = if null reason then "see toolchain/check-semaphore.sh" else reason
    case code of
      ExitSuccess -> say "build semaphore: ok, cabal and GHC share one job budget" >> pure "--semaphore"
      ExitFailure 1 -> say ("build semaphore: not usable (" <> orProbe <> "), building without it") >> pure "--no-semaphore"
      _ -> say ("build semaphore: not usable (the probe could not run: " <> orProbe <> "), building without it") >> pure "--no-semaphore"

-- | Build wiki-server at -O2, its output shown and kept; on a failure, the
-- end of cabal's newest build log and what the output suggests is missing.
serverBuildNative :: Plan -> IO ()
serverBuildNative p = do
  semaphore <- semaphoreFlag p
  started <- getCurrentTime
  stamped <- stampVersion p
  (code, output) <- case stamped of
    Nothing -> pure (ExitFailure 1, "")
    Just version -> do
      environment <- withVars [("WIKI_BUILD_VERSION", version)]
      teeProcess (setWorkingDir (get p "root") (setEnv environment (proc "cabal" (serverCabalArgs p "build" [semaphore]))))
  unless (code == ExitSuccess) $ do
    logs <- cabalLogsDir (get p "root")
    tailed <- case logs of
      Nothing -> pure ""
      Just dir -> do
        newest <- newestLog dir started
        case newest of
          Nothing -> pure ""
          Just file -> do
            hFlush stdout
            hPutStrLn stderr (prog <> ": the newest build log, " <> file <> ", ends with:")
            text <- readFileStrict file
            let end = unlines (lastN 30 (lines text))
            hPutStr stderr end
            pure end
    let lowered = map toLower (output <> tailed)
    when (any (`isInfixOf` lowered) missingLibraryHints) $
      warn "the build of wiki-server lacks a C library or pkg-config (see above): sh toolchain/check-native.sh says what is missing and which packages provide it, on Debian and on RHEL"
    when ("semOpen" `isInfixOf` (output <> tailed)) $
      warn "GHC could not open cabal's build semaphore (semOpen, see above): deploy again with --no-semaphore, which builds without it"
    die "the build of wiki-server failed (see above), so nothing was changed"
  where
    lastN n xs = drop (length xs - n) xs

-- | The directory cabal writes its build logs into: what cabal says, or
-- the first of its usual places that exists.
cabalLogsDir :: FilePath -> IO (Maybe FilePath)
cabalLogsDir root = do
  result <- try (readProcessStdout (setWorkingDir root (setStdin nullStream (setStderr nullStream (proc "cabal" ["path", "-z", "-v0", "--logs-dir"])))))
  let said = case result of
        Right (ExitSuccess, out) -> takeWhile (`notElem` ['\n', '\0']) (decodeFs out)
        Right _ -> ""
        Left (_ :: IOException) -> ""
  home <- getHomeDirectory
  cabalDir <- lookupEnv "CABAL_DIR"
  cache <- maybe (home </> ".cache") id <$> lookupEnv "XDG_CACHE_HOME"
  let candidates = [said] <> maybe [] (\d -> [d </> "logs" | not (null d)]) cabalDir <> [home </> ".cabal" </> "logs", cache </> "cabal" </> "logs", home </> ".local" </> "state" </> "cabal" </> "logs"]
  listToMaybe <$> filterM (\d -> if null d then pure False else doesDirectoryExist d) candidates

-- | The newest @.log@ file under a directory written since a time.
newestLog :: FilePath -> UTCTime -> IO (Maybe FilePath)
newestLog dir since = do
  files <- filter ((== ".log") . takeExtension) <$> everyFile dir
  dated <- forM files (\f -> (,f) <$> getModificationTime f)
  pure (snd <$> listToMaybe (sortOn (Down . fst) [d | d@(t, _) <- dated, t > since]))
  where
    everyFile d = do
      entries <- listDirectory d `orElse` []
      concat
        <$> forM
          entries
          ( \e -> do
              let path = d </> e
              isDir <- doesDirectoryExist path
              if isDir then everyFile path else pure [path]
          )

-- | What a failed build's output says when it lacks a C library or
-- pkg-config, in lower case: error messages only, since cabal's output
-- names packages such as zlib and postgresql-libpq as it builds them,
-- failure or not.
missingLibraryHints :: [String]
missingLibraryHints = ["pkg-config", "cannot find -l", "foreign librar", "missing (or bad) c librar", "could not be found", ".h: no such file"]

-- | Whether a port can be listened on at an address: with Node, by
-- listening; without, whether ss sees anything listening there (when ss
-- is here to tell).
canListen :: Bool -> FilePath -> String -> String -> IO Bool
canListen nodeless node port address
  | nodeless = do
      ss <- isJust <$> findExecutable "ss"
      if not ss
        then pure True
        else do
          (_, out) <- outputOf "ss" ["-Hltn", "sport = :" <> port]
          if null out
            then pure True
            else do
              hFlush stdout
              hPutStrLn stderr ("something already listens on port " <> port <> " (ss -ltn)")
              pure False
  | otherwise = (== ExitSuccess) <$> runInherit node ["-e", listenScript, port, address]
  where
    listenScript = "\n    const server = require(\"node:net\").createServer();\n    server.once(\"error\", (e) => { console.error(e.message); process.exit(1); });\n    server.listen(Number(process.argv[1]), process.argv[2], () => server.close());\n  "

-- | Adopt a deployment made before --prefix: its state file moves under
-- the prefix, and its PostgreSQL files are copied there, not moved, since
-- the running service still names them until the deploy writes its unit
-- anew; "Maker.Deploy.Apply" removes the old copy once the unit is in
-- place. Answers the state's directory and file, and the PostgreSQL
-- directory to remove then (empty when nothing was adopted).
adoptIntoPrefix :: Plan -> IO (FilePath, FilePath, FilePath)
adoptIntoPrefix p
  | not (has p "adoptable") = pure (get p "state_dir", get p "state_file", get p "adopted_pg_dir")
  | otherwise = do
      let name = get p "name"
          old = get p "state_dir"
          new = get p "prefix" </> "state"
          stateFile = new </> (name <> ".state")
      createDirectoryIfMissing True new
      -- mv, not rename(2): the prefix may be on another filesystem than
      -- the home directory, where mv copies and removes.
      orExit =<< runInherit "mv" [old </> (name <> ".state"), stateFile]
      removePathForcibly (old </> (name <> ".env"))
      oldPg <- doesDirectoryExist (old </> (name <> ".postgres"))
      adopted <-
        if not oldPg
          then pure ""
          else do
            removePathForcibly (new </> (name <> ".postgres"))
            orExit =<< runInherit "cp" ["-Rp", old </> (name <> ".postgres"), new </> (name <> ".postgres")]
            pure (old </> (name <> ".postgres"))
      home <- getHomeDirectory
      say ("adopting " <> name <> ": its state moves from " <> old <> " to " <> new <> "; the toolchain it builds with stays under " <> home <> " unless --toolchain says otherwise")
      pure (new, stateFile, adopted)

-- | The deployment's PostgreSQL files: a copy of docker-compose.yml, whose
-- postgres service runs the database; local.yml, which publishes its port
-- on this machine's loopback; the database's password, made once and kept;
-- and pg_dump and pg_restore, which run the container's own.
pgFiles :: Plan -> FilePath -> IO ()
pgFiles p pd = do
  let name = get p "name"
  createDirectoryIfMissing True pd
  orExit =<< runInherit "chmod" ["700", pd]
  copyFile (get p "root" </> "docker-compose.yml") (pd </> "docker-compose.yml")
  writeFile (pd </> "local.yml") (localYml name)
  password <- doesFileExist (pd </> "db-password")
  size <- if password then getFileSize (pd </> "db-password") else pure 0
  when (size == 0) $
    orExit =<< runInherit "sh" ["-c", "umask 077 && od -An -tx1 -N24 /dev/urandom | tr -d ' \\n' >\"$1\"", "sh", pd </> "db-password"]
  forM_ ["pg_dump", "pg_restore"] $ \program -> do
    writeFile (pd </> program) (pgWrapper name pd (get p "db_port") program)
    orExit =<< runInherit "chmod" ["700", pd </> program]

-- | local.yml, which publishes the database's port on the loopback.
localYml :: String -> String
localYml name =
  unlines
    [ "# Written by toolchain/deploy-local.sh for the deployment " <> name <> ": the"
    , "# database's port, published on this machine's loopback for the wiki's"
    , "# server, which runs as the systemd user service " <> name <> ".service."
    , "services:"
    , "  postgres:"
    , "    ports:"
    , "      - \"127.0.0.1:${WIKI_DB_PORT}:5432\""
    ]

-- | The pg_dump or pg_restore wrapper: the container's own program, which
-- connects to the container's socket as the user wiki.
pgWrapper :: String -> FilePath -> String -> String -> String
pgWrapper name pd dbPort program =
  unlines
    [ "#!/bin/sh"
    , "# " <> program <> " of the PostgreSQL container of the deployment " <> name <> ", written by"
    , "# toolchain/deploy-local.sh: wiki-server runs it for a backup or a restore"
    , "# with --dbname=<the URL it connects to>, which is this machine's address of"
    , "# the container; inside the container the program connects to its own"
    , "# socket instead, as the user wiki, to the database wiki."
    , "n=$#"
    , "named="
    , "while [ \"$n\" -gt 0 ]; do"
    , "  arg=$1"
    , "  shift"
    , "  n=$((n - 1))"
    , "  case $arg in"
    , "    --dbname=*) named=1 ;;"
    , "    *) set -- \"$@\" \"$arg\" ;;"
    , "  esac"
    , "done"
    , "[ -z \"$named\" ] || set -- --username=wiki --dbname=wiki \"$@\""
    , "WIKI_DB_PASSWORD_FILE='" <> pd <> "/db-password' WIKI_DB_PORT='" <> dbPort <> "' exec docker compose --project-name '" <> name <> "' \\"
    , "  --file '" <> pd <> "/docker-compose.yml' --file '" <> pd <> "/local.yml' exec -T postgres " <> program <> " \"$@\""
    ]

-- | docker compose on the deployment's project, with its files and port.
pgCompose :: String -> FilePath -> String -> [String] -> IO ExitCode
pgCompose name pd port args = do
  environment <- withVars [("WIKI_DB_PASSWORD_FILE", pd </> "db-password"), ("WIKI_DB_PORT", if null port then "5433" else port)]
  hFlush stdout
  runProcess (setEnv environment (proc "docker" (["compose", "--project-name", name, "--file", pd </> "docker-compose.yml", "--file", pd </> "local.yml"] <> args)))

-- | Run a command in a directory with variables added to the environment,
-- its output on the terminal.
runIn :: FilePath -> FilePath -> [String] -> [(String, String)] -> IO ExitCode
runIn dir program args vars = do
  environment <- withVars vars
  hFlush stdout
  runProcess (setWorkingDir dir (setEnv environment (proc program args))) `orElse` ExitFailure 127

-- | A command whose output and errors are shown as they come, byte for
-- byte, and kept, as the shell's @2>&1 | tee@; the kept output is read
-- leniently, for the hints it may hold.
teeProcess :: ProcessConfig () () () -> IO (ExitCode, String)
teeProcess config = do
  (code, out) <- relay Nothing config
  pure (code, T.unpack (decodeUtf8With lenientDecode (LBS.toStrict out)))

-- | The environment with variables set, replacing any of the same name.
withVars :: [(String, String)] -> IO [(String, String)]
withVars vars = (vars <>) . filter ((`notElem` map fst vars) . fst) <$> getEnvironment

isExecutable :: FilePath -> IO Bool
isExecutable path = do
  exists <- doesFileExist path
  if exists then executable <$> getPermissions path else pure False

orExit :: ExitCode -> IO ()
orExit = \case
  ExitSuccess -> pure ()
  code -> exitWith code

orElse :: IO a -> a -> IO a
orElse action fallback = either (\(_ :: IOException) -> fallback) id <$> try action

readFileStrict :: FilePath -> IO String
readFileStrict file = do
  text <- readFile file
  length text `seq` pure text
