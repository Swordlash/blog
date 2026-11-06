-- | The front of a deploy, @maker deploy [OPTIONS]@: what
-- toolchain/deploy-local.sh did before it handed the deploy to the maker
-- with a plan. It reads the options ("Maker.Deploy.Options") and the
-- deployment's state, checks the names, ports, addresses and files, and
-- works out the prefix, the directory, the toolchain's directory and where
-- the page comes from. Then it checks the machine (toolchain/check-native.sh,
-- or the machine's own tools with @--system-tools@), runs the bootstrap
-- for what the deploy needs, loads the toolchain's environment, and runs
-- the rest of the deploy in this process: the page, the TeX step, the
-- builds and checks, and the change of the running deployment
-- ("Maker.Deploy.Page", "Maker.Deploy.Tex", "Maker.Deploy.Prepare",
-- "Maker.Deploy.Apply"). @--rollback@ goes back to the kept deployment.
--
-- Everything that can be checked is checked before the build, which takes
-- minutes (over an hour the first time), and the build before the running
-- service is touched. The steps, their order, their messages and the
-- programs they run are the shell's, which the deploy's tests
-- (toolchain/test-deploy-local.sh) check. @--status@ and @--stop@ stay in
-- the shell, which needs no GHC: the maker hands them back to it.
module Maker.Deploy.Front
  ( deploy
  , urlProblem
  , portProblem
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.Char (isSpace)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe, isJust)
import Maker.Deploy.Apply (apply, rollbackByHand)
import Maker.Deploy.Layout
import Maker.Deploy.Options
import Maker.Deploy.Page (pageStep)
import Maker.Deploy.Plan
import Maker.Deploy.Prepare (prepare)
import Maker.Deploy.State (stateGet)
import Maker.Deploy.Tailscale (tailscaleIp)
import Maker.Deploy.Tex (texStep)
import System.Directory
import System.Environment (getEnvironment, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.Process.Typed (nullStream, proc, readProcessInterleaved, readProcessStdout, setStdin)

-- | Run @maker deploy@ with its arguments, from the checkout at the root.
deploy :: FilePath -> [String] -> IO ()
deploy root args = do
  opts <- case parseOptions args of
    Left why -> die why
    Right Help -> printUsage root >> exitWith ExitSuccess
    Right (Parsed o) -> pure o
  -- --status and --stop are the shell's, which needs no GHC.
  when (opts.action `elem` [Status, Stop]) $ do
    code <- runInherit "sh" ((root </> "toolchain" </> "deploy-local.sh") : args)
    exitWith code
  front root opts

-- | The deploy's usage: the header of toolchain/deploy-local.sh.
printUsage :: FilePath -> IO ()
printUsage root = do
  text <- readFile (root </> "toolchain" </> "deploy-local.sh")
  let header = takeWhile (/= "set -eu") (drop 1 (lines text))
      strip l = case l of
        '#' : ' ' : rest -> rest
        '#' : rest -> rest
        _ -> l
  putStr (unlines (map strip header))

-- | Why a URL given for a mirror or a registry cannot be one, if it cannot:
-- an http:// or https:// URL, without spaces or quotes.
urlProblem :: String -> String -> String -> Maybe String
urlProblem option example url
  | null url = Nothing
  | any unsafeChar url = Just ("--" <> option <> " " <> url <> ": an http:// or https:// URL without spaces or quotes")
  | isUrl url = Nothing
  | otherwise = Just ("--" <> option <> " " <> url <> ": an http:// or https:// URL, such as " <> example)

-- | A character a URL or a path given to the deploy cannot hold: one the
-- shell's @[[:space:]\"\'\\\`\$]@ matches.
unsafeChar :: Char -> Bool
unsafeChar c = isSpace c || c `elem` ("\"'\\`$" :: String)

-- | Whether a value is an http:// or https:// URL with something after the
-- scheme.
isUrl :: String -> Bool
isUrl u = any (\s -> s `isPrefixOf` u && length u > length s) ["http://", "https://"]

-- | Why a port given (or remembered) cannot be used, if it cannot.
portProblem :: String -> String -> Maybe String
portProblem option v
  | null v || "0" `isPrefixOf` v || not (all (`elem` ['0' .. '9']) v) = Just ("invalid " <> option <> " '" <> v <> "': a number from 1024 to 65535")
  | n < 1024 || n > 65535 = Just ("invalid " <> option <> " " <> v <> ": a number from 1024 to 65535" <> (if option == "--port" then " (lower ports need root)" else ""))
  | otherwise = Nothing
  where
    n = read (take 6 v) :: Integer

-- | The front itself, in the shell's order.
front :: FilePath -> Options -> IO ()
front root o0 = do
  -- The ways to serve exclude each other: one may be given, and a later
  -- run moves to another by naming it.
  let given = ways o0
  when (length given > 1) $
    die (intercalate " and " given <> " are ways to serve that exclude each other: give one (--https through tailscale serve, --tls-cert FILE --tls-key FILE with a certificate of your own, --behind-proxy behind a reverse proxy, or --http for plain HTTP)")
  let m = o0.optTexliveMirror
  unless (null m) $
    if any unsafeChar m
      then die ("--texlive-mirror " <> m <> ": an http:// or https:// URL without spaces or quotes")
      else unless (isUrl m) (die ("--texlive-mirror " <> m <> ": an http:// or https:// URL, such as https://mirror.ctan.org"))
  mapM_ (mapM_ die) [urlProblem "npm-registry" "https://npm.example.org/" o0.optNpmRegistry, urlProblem "hackage-mirror" "https://hackage.example.org/" o0.optHackageMirror]
  -- The page's zip from a file (--app-page): a zip holding app.wasm, named
  -- by absolute path from here on. A file that is not there is taken only
  -- when the page cache keeps a copy of it (checked below).
  (o1, appPageMissing) <-
    if null o0.optAppPage
      then pure (o0, "")
      else do
        let file = o0.optAppPage
        when ('\n' `elem` file) (die ("--app-page " <> file <> " holds a newline, which the state file cannot hold"))
        when (o0.optBackendOnly == "none") (die "--app-page takes the page CI built from a file, and --no-backend-only builds it here: give one")
        unless (null o0.optBackendOnly) (die "--app-page takes the page from a file, and --backend-only downloads it from GitHub: give one")
        readable <- isReadableFile file
        if readable
          then do
            holds <- zipHoldsApp file
            unless holds (die ("--app-page " <> file <> ": not a page CI built (a zip with app.wasm at its root)"))
            resolved <- realpath [] file
            pure (o0 {optAppPage = resolved}, "")
          else do
            resolved <- realpath ["-m"] file
            pure (o0 {optAppPage = resolved}, file)
  -- Where the TeX step takes TeX Live's installer and Perl's source from:
  -- a git repository's URL, or a directory of this machine, which must be
  -- there now and is named by absolute path from here on.
  installer <- source "texlive-installer" o1.optTexliveInstaller
  perlSource <- source "perl-source" o1.optPerlSource
  let o = o1 {optTexliveInstaller = installer, optPerlSource = perlSource}

  n <- checkName o.name
  l <- layoutFor n o.optPrefix
  requirePrefixOfUnit l ", or deploy this one under another --name"
  let prev k = stateGet k l.stateFile
  prevDir <- prev "dir"
  prevToolchain <- prev "toolchain"
  prevPort <- prev "port"
  prevBind <- prev "bind"
  prevBindChoice <- prev "bind_choice"
  prevRulePort <- prev "rule_port"
  stateThere <- doesFileExist l.stateFile
  -- A deployment of a version before --server kept no mode, and was the
  -- demo: it stays one.
  prevMode <- (\m' -> if null m' && stateThere then "static" else m') <$> prev "mode"
  prevAdminPort <- prev "admin_port"
  prevTrust <- prev "trust"
  prevHttps <- prev "https"
  -- How the deployment is reached; a deployment from before the last two
  -- ways has none, and its https says which of the first two it was.
  prevWay <- (\w -> if null w then (if prevHttps == "no" then "http" else "tailscale") else w) <$> prev "way"
  prevTlsCert <- prev "tls_cert"
  prevTlsKey <- prev "tls_key"
  prevTlsCa <- prev "tls_ca"
  prevServePort <- prev "serve_port"
  prevDb <- prev "db"
  prevDbPort <- prev "db_port"
  prevBackendOnly <- prev "backend_only"
  prevBackendOnlyCommit <- prev "backend_only_commit"
  prevAppPage <- prev "app_page"
  prevBundleLocally <- prev "bundle_locally"
  prevSystemTools <- prev "system_tools"
  prevNpmRegistry <- prev "npm_registry"
  prevHackageMirror <- prev "hackage_mirror"
  prevTexlive <- prev "texlive"
  prevTexliveDir <- prev "texlive_dir"
  prevTexliveMirror <- prev "texlive_mirror"
  prevPerlDir <- prev "perl_dir"
  prevWhatsNew <- prev "whats_new"
  prevGitCommit <- prev "git_commit"
  gitCommit <- (\(ok, out) -> if ok then takeWhile (/= '\n') out else "unknown") <$> outputOf "git" ["-C", root, "rev-parse", "HEAD"]
  prevSmtpHost <- prev "smtp_host"
  prevSmtpPort <- prev "smtp_port"
  prevSmtpFrom <- prev "smtp_from"
  prevPublicUrl <- prev "public_url"
  prevOidc <- prev "oidc"
  let envFile = l.stateDir </> (n <> ".env")
  user <- takeWhile (/= '\n') . snd <$> outputOf "id" ["-un"]
  home <- getHomeDirectory
  pwd <- getPwd

  -- The directory the toolchain is under: --toolchain's, the previous
  -- run's, the home directory for a deployment adopted from it,
  -- <prefix>/toolchain under a prefix, or the home directory, remembered as
  -- chosen. The bootstrap and the build read it from WIKI_TOOLCHAIN_HOME;
  -- the home directory is their default, so it is not named.
  let chosen = firstOf [o.optToolchain, prevToolchain, if l.adoptable then home else "", if null l.prefix then "" else l.prefix <> "/toolchain"]
  (toolchainDir, toolchainHome) <-
    if null chosen
      then pure ("", "")
      else do
        resolved <- realpath ["-m"] (if "/" `isPrefixOf` chosen then chosen else pwd <> "/" <> chosen)
        homeReal <- realpath ["-m"] home
        pure (resolved, if resolved == homeReal then "" else resolved)
  if null toolchainHome then unsetEnv "WIKI_TOOLCHAIN_HOME" else setEnv "WIKI_TOOLCHAIN_HOME" toolchainHome
  let toolchainBase = if null toolchainHome then home else toolchainHome

  when (o.action == Rollback) $ do
    unless (not (null prevDir) && prevMode == "server") $
      die ("there is no server deployed under the name " <> n <> (if null l.prefix then "" else " under " <> l.prefix) <> " to roll back")
    -- The toolchain's environment, as a deploy loads it.
    loadEnvironment root (not (null prevSystemTools)) toolchainBase
    rollbackByHand
      . set "name" n
      . set "dir" prevDir
      . set "state_dir" l.stateDir
      . set "unit_file" l.unitFile
      . set "state_file" l.stateFile
      . set "yes" (flag o.yes)
      . set "no_firewall" (flag o.noFirewall)
      $ parsePlan ""
    exitWith ExitSuccess

  -- id, as the shell asks, rather than the process's own user: the
  -- deploy's tests answer through a fake id.
  uid <- takeWhile (/= '\n') . snd <$> outputOf "id" ["-u"]
  when (uid == "0") (die "run this as the user the wiki should run as, not root: it installs a systemd user service under that user")
  systemd <- succeeds "systemctl" ["--user", "show-environment"]
  unless systemd $
    die ("cannot reach your systemd user instance (systemctl --user). Log in to a normal session (ssh as " <> user <> " works; su and sudo -u do not), or check that XDG_RUNTIME_DIR is set (it is usually /run/user/" <> uid <> ").")

  let port = firstOf [o.optPort, prevPort, "8080"]
  mapM_ die (portProblem "--port" port)
  -- The first run deploys the server; a later run keeps what the previous
  -- one deployed.
  let mode = firstOf [o.optMode, prevMode, "server"]
      adminPort = firstOf [o.optAdminPort, prevAdminPort, "8081"]
      server = mode == "server"
  mapM_ die (portProblem "--admin-port" adminPort)
  if server
    then when (adminPort == port) (die ("--admin-port and --port are both " <> port <> ": choose two ports"))
    else do
      unless (null o.optAdminPort) (die "--admin-port is for the wiki's server: add --server")
      unless (null o.optDb && null o.optDbPort && not o.fresh) (die "--postgres, --sqlite, --db-port and --fresh are for the wiki's server: add --server")
      unless (null o.optTexlive && null o.optTexliveMirror) (die "--texlive, --no-texlive and --texlive-mirror are for the wiki's server, which makes the PDFs: add --server")
      unless (null o.optTexliveInstaller && null o.optPerlSource) (die "--texlive-installer and --perl-source are for the wiki's server, which makes the PDFs: add --server")
      unless (null o.optWhatsNew) (die "--whats-new and --no-whats-new are for the wiki's server, which shows the page: add --server")
  let whatsNew = if firstOf [o.optWhatsNew, prevWhatsNew] == "no" then "no" else ""

  -- The wiki's database: PostgreSQL in Docker unless --sqlite said
  -- otherwise; the demo keeps what a server before it chose.
  (db, dbPort) <-
    if not server
      then pure (prevDb, prevDbPort)
      else do
        let db' = firstOf [o.optDb, prevDb, "postgres"]
        if db' == "postgres"
          then do
            let dbPort' = firstOf [o.optDbPort, prevDbPort, "5433"]
            mapM_ die (portProblem "--db-port" dbPort')
            when (dbPort' `elem` [port, adminPort]) (die ("--db-port " <> dbPort' <> " is the port of a listener: choose another"))
            ready <- dockerReady
            unless ready (die "the wiki's database is PostgreSQL, which runs in Docker (docker compose), and Docker is not installed here or does not answer (docker info): install Docker and its compose plugin, or deploy with --sqlite, which keeps the database a file in the data directory, with no container")
            pure (db', dbPort')
          else do
            unless (null o.optDbPort) (die "--db-port is for a database on PostgreSQL: drop --sqlite")
            pure (db', prevDbPort)

  -- The page CI built: from GitHub (--backend-only) or from a file
  -- (--app-page), given now or remembered.
  let pageKind = if server then "server" else "demo"
      backendOnly0 = case o.optBackendOnly of
        "" -> prevBackendOnly
        "none" -> ""
        b -> b
      appPage
        | o.optAppPageGiven = o.optAppPage
        | not (null o.optBackendOnly) = ""
        | otherwise = prevAppPage
      backendOnly = if null appPage then backendOnly0 else ""
  xdgCache <- lookupEnv "XDG_CACHE_HOME"
  let pageCache
        | not (null toolchainHome) = toolchainHome </> ".wiki-toolchain" </> "pages"
        | otherwise = maybe (home </> ".cache") (\c -> if null c then home </> ".cache" else c) xdgCache </> "wiki-demo" </> "pages"
  unless (null appPageMissing) $ do
    entries <- appPageEntries pageCache pageKind ("file=" <> appPage)
    when (null entries) $
      die ("--app-page " <> appPageMissing <> ": no such file here, or it cannot be read, and the page cache " <> pageCache <> " keeps no copy of it from an earlier deploy")
  let prebuilt = backendOnly <> appPage
      pageOption = if null appPage then "--backend-only" else "--app-page"
      backendOnlyCommit = if null prebuilt then "" else prevBackendOnlyCommit
      -- Nothing in the server's mode runs Node; the demo's runs it to
      -- serve the page.
      nodeless = not (null prebuilt) && server
  unless (null prebuilt) $ do
    curl <- found "curl"
    if not (null backendOnly)
      then unless curl (die "--backend-only downloads the page with curl, which is not installed here")
      else when (nodeless && not curl) (die "--app-page with --server checks that the server answers with curl, which is not installed here")
    python <- found "python3"
    unless python $ do
      unzipThere <- found "unzip"
      jq <- found "jq"
      if o.build && not unzipThere
        then die (pageOption <> " unpacks the page with python3, which is not installed here (nor unzip, which would do instead)")
        else when (nodeless && not jq) (die (pageOption <> " reads JSON (tailscale status, the administration's settings) with python3, which is not installed here (nor jq, which would do instead)"))

  -- For a machine that installs nothing from the internet, given now or
  -- remembered.
  let bundleLocally0 = case o.optBundleLocally of
        "yes" -> "yes"
        "no" -> ""
        _ -> prevBundleLocally
  bundleLocally <-
    if not (null bundleLocally0) && null prebuilt
      then do
        when (o.optBundleLocally == "yes") $
          die "--bundle-locally builds here the bundles of the page CI built: it goes with --backend-only[=REF] or --app-page FILE (a page built here has its bundles built here anyway)"
        pure ""
      else pure bundleLocally0
  let systemTools = case o.optSystemTools of
        "yes" -> "yes"
        "no" -> ""
        _ -> prevSystemTools
  when (not (null systemTools) && null prebuilt && o.build) $
    die "--system-tools takes GHC, cabal and Node from this machine, and building the page here needs the wasm toolchain too, which only toolchain/bootstrap.sh installs: take the page CI built (--backend-only[=REF] or --app-page FILE), or let the bootstrap install the toolchain (--no-system-tools)"
  let npmRegistry = if o.optNpmRegistryGiven then o.optNpmRegistry else prevNpmRegistry
  -- Every npm and npx of the deploy and of the bootstrap reads it from the
  -- environment.
  unless (null npmRegistry) (setEnv "NPM_CONFIG_REGISTRY" npmRegistry)
  let hackageMirror = if o.optHackageMirrorGiven then o.optHackageMirror else prevHackageMirror
  when (not (null hackageMirror) && null toolchainHome) $
    die ("--hackage-mirror " <> hackageMirror <> " is written into the toolchain's own cabal configuration, and this deployment's toolchain is in the home directory, whose cabal configuration (~/.cabal) is yours and is left alone: give the toolchain a directory of its own (--prefix DIR, which puts it under DIR/toolchain, or --toolchain DIR)")

  -- The way it is served, one of four, remembered: tailscale, http, cert
  -- or proxy. A way given now replaces the remembered one, and with it the
  -- remembered certificate.
  let way
        | o.optHttps == "yes" = "tailscale"
        | o.optHttps == "no" = "http"
        | not (null (o.optTlsCert <> o.optTlsKey)) = "cert"
        | o.optProxy = "proxy"
        | otherwise = prevWay
  case prevWay of
    "cert" | way /= "cert" -> say ("no longer serving with the certificate " <> prevTlsCert <> ": " <> unwords given <> " replaces --tls-cert")
    "proxy" | way /= "proxy" -> say ("no longer behind a reverse proxy: " <> unwords given <> " replaces --behind-proxy")
    _ -> pure ()
  (tlsCert, tlsKey, tlsCa) <-
    if way == "cert"
      then do
        unless server $
          die "the demo's static server speaks plain HTTP, so --tls-cert is for the wiki's server (--server); serve the demo through tailscale serve (--https) or a reverse proxy (--behind-proxy)"
        -- A file not given now is the previous run's: a renewed
        -- certificate in a new file is given alone.
        let (c0, k0, a0)
              | prevWay == "cert" = (firstOf [o.optTlsCert, prevTlsCert], firstOf [o.optTlsKey, prevTlsKey], prevTlsCa)
              | otherwise = (o.optTlsCert, o.optTlsKey, "")
        when (null c0) (die "--tls-key needs --tls-cert FILE, the certificate (PEM) it is the key of")
        when (null k0) (die "--tls-cert needs --tls-key FILE, the certificate's private key (PEM; the same file when one .pem holds both)")
        let a1 = if o.optTlsCaGiven then o.optTlsCa else a0
        -- The unit reads the files from where they are, at every start of
        -- the service, as this user: named by absolute path.
        let tlsFile option file
              | null file = pure file
              | otherwise = do
                  when ('\n' `elem` file) (die ("--" <> option <> " " <> file <> " holds a newline, which the unit file cannot hold"))
                  readable <- isReadableFile file
                  unless readable (die ("cannot read --" <> option <> " " <> file <> ": the service reads it from where it is, as " <> user <> ", at every start"))
                  realpath [] file
        c <- tlsFile "tls-cert" c0
        k <- tlsFile "tls-key" k0
        a <- tlsFile "tls-ca" a1
        curl <- found "curl"
        unless curl (die "--tls-cert: the deploy checks the HTTPS listener with curl, which is not installed here")
        pure (c, k, a)
      else do
        unless (null o.optTlsCa) (die "--tls-ca is the authority the deploy checks the server's own certificate against: it goes with --tls-cert FILE --tls-key FILE")
        pure ("", "", "")

  -- The directory, absolute and with its links resolved, so that the
  -- safety checks compare what would really be deleted.
  let dir0 = firstOf [l.prefix, prevDir, home </> n]
  dir <- realpath ["-m"] (if "/" `isPrefixOf` dir0 then dir0 else pwd <> "/" <> dir0)
  when (any (`elem` ("\"\\$%`'\n" :: String)) (dir <> toolchainHome)) $
    die ("the target directory " <> dir <> " or the toolchain's " <> toolchainHome <> " contains a character the unit file or the toolchain's env file cannot hold (\" \\ $ % ` ' or a newline)")
  unsafe <- unsafeDir dir
  when unsafe (die ("refusing to install into " <> dir <> ": it is /, your home directory or above it"))
  when (null l.prefix && o.force) (say "--force does nothing any more: --prefix allows any directory but /, the home directory and the ones above it")
  -- The install empties the directory (but for data/, state/ and
  -- toolchain/), so the checkout cannot be inside it, nor the toolchain
  -- anywhere but at toolchain/.
  when ((dir <> "/") `isPrefixOf` (root <> "/")) $
    die ("the checkout " <> root <> " is inside " <> dir <> ", which installing empties: run this from a checkout elsewhere, or choose another --prefix")
  unless (null toolchainHome || toolchainHome == dir </> "toolchain")
    $ when (toolchainHome == dir || (dir <> "/") `isPrefixOf` toolchainHome)
    $ die ("--toolchain " <> toolchainHome <> " is inside " <> dir <> ", which installing empties but for data/, state/ and toolchain/: put it at " <> dir <> "/toolchain, or outside " <> dir)
  isFile <- doesFileExist dir
  when isFile (die ("refusing to install into " <> dir <> ": it is not a directory"))
  isDir <- doesDirectoryExist dir
  when isDir $ do
    entries <- listDirectory dir
    marked <- markedFor dir n
    when (not (null entries) && not marked) $ do
      other <- doesFileExist (dir </> markerName)
      when other $ do
        owner <- stateGet "name" (dir </> markerName)
        die ("refusing to install into " <> dir <> ": it holds the deployment '" <> owner <> "'; use --name " <> owner <> " or another --dir")
      die ("refusing to empty " <> dir <> ": this script did not create it (it has no " <> markerName <> "). Choose another --dir, or empty or remove it yourself")
  -- A server's data stays where it is: moving the deployment would leave it
  -- behind and start an empty wiki in the new place.
  when (server && not (null prevDir) && prevDir /= dir) $ do
    oldData <- doesDirectoryExist (prevDir </> "data")
    newData <- doesDirectoryExist (dir </> "data")
    when (oldData && not newData) $
      die ("the wiki's data is in " <> prevDir <> "/data: move it to " <> dir <> "/data yourself first (with the service stopped: sh toolchain/undeploy-local.sh --name " <> n <> "), or deploy under another --name")
  -- The certificate's files must survive the install, which empties the
  -- directory but for data/, state/ and toolchain/.
  forM_ [tlsCert, tlsKey, tlsCa] $ \file ->
    when (not (null file) && (dir <> "/") `isPrefixOf` file && not (any (\keep -> (dir </> keep <> "/") `isPrefixOf` file) ["data", "state", "toolchain"])) $
      die ("the TLS file " <> file <> " is inside " <> dir <> ", which installing empties but for data/, state/ and toolchain/, so it would be deleted: keep it in " <> dir <> "/data/tls/ or outside " <> dir)
  -- The directory is claimed now, before the build.
  createDirectoryIfMissing True dir
  hasMarker <- doesFileExist (dir </> markerName)
  unless hasMarker (writeFile (dir </> markerName) ("name=" <> n <> "\ncreated-by=toolchain/deploy-local.sh\n"))

  -- HTTPS through tailscale serve is the tailscale way alone. The previous
  -- run's address is kept when it was asked for (but not one --https or
  -- --behind-proxy, given now, cannot serve from); one chosen
  -- automatically is chosen again.
  let https0 = if way == "tailscale" then "yes" else "no"
      (bind0, bindChoice)
        | not (null o.optBind) = (o.optBind, "explicit")
        | prevBindChoice == "explicit" && not (null prevBind) && not ((o.optHttps == "yes" || o.optProxy) && prevBind /= "127.0.0.1") = (prevBind, "explicit")
        | otherwise = ("", "auto")
  unless (all (`elem` ("0123456789ABCDEFabcdef.:" :: String)) bind0) (die ("invalid --bind '" <> bind0 <> "': an IPv4 or IPv6 address"))
  https <-
    if not (null bind0) && bind0 /= "127.0.0.1" && https0 == "yes"
      then do
        when (o.optHttps == "yes") (die ("--https serves from 127.0.0.1 behind tailscale serve: drop --bind " <> bind0 <> ", or give --bind 127.0.0.1"))
        say ("--bind " <> bind0 <> " implies --http: tailscale serve proxies to 127.0.0.1 only")
        pure "no"
      else pure https0
  when (way == "proxy" && not (null bind0) && bind0 /= "127.0.0.1") $
    die ("--behind-proxy serves plain HTTP on 127.0.0.1, for a reverse proxy on this machine: drop --bind " <> bind0 <> ", or give --bind 127.0.0.1")
  bind <-
    if not (null bind0)
      then pure bind0
      else
        if https == "yes" || way == "proxy"
          then pure "127.0.0.1"
          else do
            ip <- tailscaleIp
            case ip of
              Just a -> say ("listening on the Tailscale address " <> a) >> pure a
              Nothing -> do
                warn "Tailscale does not answer (tailscale ip -4), so listening on 127.0.0.1 only; rerun when it is up, or choose with --bind (0.0.0.0 listens everywhere)"
                pure "127.0.0.1"
  let out = root </> "dist-newstyle" </> "wasm-opt" </> "public" </> "app"

  -- The checks of the machine and the bootstrap. Only the wiki's server on
  -- SQLite builds without PostgreSQL, and the TeX step checks xelatex on
  -- the service's PATH, so toolchain/check-native.sh is told not to.
  let checkFlags = ["--without-postgres" | server && db == "sqlite"] <> ["--without-tex" | server]
      bootstrap mode' flags = do
        code <- runInherit "sh" ((root </> "toolchain" </> "bootstrap.sh") : mode' : flags)
        unless (code == ExitSuccess) (exitWith code)
      systemToolsFlag = ["--system-tools" | not (null systemTools)]
      hackageFlag = ["--hackage-mirror=" <> hackageMirror | not (null hackageMirror)]
      under = if null toolchainHome then "" else ", under " <> toolchainHome
  when o.build $ do
    unless (null systemTools) $ do
      let needs = "native" : ["node" | not server || not (null bundleLocally)]
      say ("--system-tools: checking this machine's own toolchain (toolchain/bootstrap.sh system-tools " <> unwords needs <> ")")
      code <- runInherit "sh" ((root </> "toolchain" </> "bootstrap.sh") : "system-tools" : needs)
      unless (code == ExitSuccess) $
        die "--system-tools: this machine's own toolchain will not do (see above), so nothing was changed; without --system-tools (--no-system-tools) toolchain/bootstrap.sh installs it"
    recheck <-
      if not server
        then pure False
        else do
          say "checking what the native build of wiki-server needs (toolchain/check-native.sh)"
          (ok, report) <- interleaved "sh" ((root </> "toolchain" </> "check-native.sh") : checkFlags)
          putStrLn (chomp report)
          if ok
            then pure False
            else do
              debian <- found "dpkg-query"
              unless debian (die "the native build of wiki-server needs what is missing above; nothing was changed")
              let missing = intercalate "\n" [rest | ln <- lines report, Just rest <- [stripMissing ln]]
              warn ("missing for the native build of wiki-server: " <> (if null missing then "see above" else missing) <> "; the bootstrap installs the Debian packages next, and the check runs again after it")
              pure True
    if not (null prebuilt) && not server
      then do
        say ("installing or checking Node, which serves the demo, and GHC and cabal, which build the deploy's maker (toolchain/bootstrap.sh static)" <> under)
        bootstrap "static" (systemToolsFlag <> hackageFlag)
      else
        if not (null prebuilt)
          then do
            say ("installing or checking the toolchain wiki-server's build needs (toolchain/bootstrap.sh native)" <> under)
            bootstrap "native" (["--without-postgres" | server && db == "sqlite"] <> systemToolsFlag <> hackageFlag)
            unless (null bundleLocally) $ do
              say ("installing or checking Node, which builds the page's bundles (toolchain/bootstrap.sh node)" <> under)
              bootstrap "node" systemToolsFlag
          else do
            built <- doesDirectoryExist (root </> "dist-newstyle" </> "wasm-opt")
            unless built (say "first -O2 build: every dependency is compiled again at -O2 for wasm, so this can take over an hour once; later runs rebuild only what changed.")
            say ("installing or checking the toolchain a build needs (toolchain/bootstrap.sh build)" <> under)
            bootstrap "build" (["--without-postgres" | server && db == "sqlite"] <> hackageFlag)
    when recheck $ do
      say "checking again what the native build of wiki-server needs, after the bootstrap"
      code <- runInherit "sh" ((root </> "toolchain" </> "check-native.sh") : checkFlags)
      unless (code == ExitSuccess) (die "the native build of wiki-server still needs what is missing above; nothing was changed")
  -- The environment npm's own entry points load, for npm and Node here.
  loadEnvironment root (not (null systemTools)) toolchainBase
  let plan =
        foldr
          (uncurry set)
          (parsePlan "")
          [ ("root", root)
          , ("state_dir", l.stateDir)
          , ("unit_dir", l.unitDir)
          , ("marker", markerName)
          , ("git_commit", gitCommit)
          , ("prev_git_commit", prevGitCommit)
          , ("name", n)
          , ("dir", dir)
          , ("out", out)
          , ("mode", mode)
          , ("nodeless", flag nodeless)
          , ("db", db)
          , ("db_port", dbPort)
          , ("prev_db", prevDb)
          , ("prev_db_port", prevDbPort)
          , ("prev_dir", prevDir)
          , ("no_firewall", flag o.noFirewall)
          , ("prev_rule_port", prevRulePort)
          , ("port", port)
          , ("bind", bind)
          , ("admin_port", adminPort)
          , ("prev_serve_port", prevServePort)
          , ("prev_port", prevPort)
          , ("prev_bind", prevBind)
          , ("prev_mode", prevMode)
          , ("prev_admin_port", prevAdminPort)
          , ("way", way)
          , ("tls_cert", tlsCert)
          , ("tls_key", tlsKey)
          , ("tls_ca", tlsCa)
          , ("whats_new", whatsNew)
          , ("prefix", l.prefix)
          , ("user", user)
          , ("toolchain_home", toolchainHome)
          , ("toolchain_base", toolchainBase)
          , ("enable_linger", flag o.enableLinger)
          , ("state_file", l.stateFile)
          , ("unit_file", l.unitFile)
          , ("env_file", envFile)
          , ("adoptable", flag l.adoptable)
          , ("fresh", flag o.fresh)
          , ("build", flag o.build)
          , ("prebuilt", prebuilt)
          , ("opt_semaphore", o.optSemaphore)
          , ("page_kind", pageKind)
          , ("refresh_page", flag o.refreshPage)
          , ("prev_smtp_host", prevSmtpHost)
          , ("prev_smtp_port", prevSmtpPort)
          , ("prev_smtp_from", prevSmtpFrom)
          , ("prev_public_url", prevPublicUrl)
          , ("prev_oidc", prevOidc)
          , ("prev_trust", prevTrust)
          , ("toolchain_dir", toolchainDir)
          , ("bind_choice", bindChoice)
          , ("https", https)
          , ("serve_port", "")
          , ("backend_only", backendOnly)
          , ("backend_only_commit", backendOnlyCommit)
          , ("app_page", appPage)
          , ("bundle_locally", bundleLocally)
          , ("system_tools", systemTools)
          , ("npm_registry", npmRegistry)
          , ("hackage_mirror", hackageMirror)
          , -- The TeX of the PDF exports; the demo keeps what a server
            -- before it chose.
            ("texlive", firstOf [o.optTexlive, prevTexlive])
          , ("texlive_dir", prevTexliveDir)
          , ("texlive_mirror", firstOf [o.optTexliveMirror, prevTexliveMirror])
          , ("perl_dir", prevPerlDir)
          , ("texlive_installer", o.optTexliveInstaller)
          , ("perl_source", o.optPerlSource)
          ]
  pageStep plan >>= texStep >>= prepare >>= apply
  where
    source option v
      | null v = pure v
      | isUrl v =
          if any unsafeChar v
            then die ("--" <> option <> " " <> v <> ": a git repository's http:// or https:// URL without spaces or quotes, or a directory of this machine")
            else pure v
      | "://" `isInfixOf` v = die ("--" <> option <> " " <> v <> ": a git repository's http:// or https:// URL, or a directory of this machine")
      | otherwise = directory option v
    directory option v = do
      there <- doesDirectoryExist v
      unless there (die ("--" <> option <> " " <> v <> ": no such directory here, and not a git repository's http:// or https:// URL"))
      realpath [] v
    stripMissing ln = do
      rest <- stripPrefixOf "Missing for the native build of wiki-server: " ln
      if "." `isSuffixOf` rest then Just (take (length rest - 1) rest) else Nothing
    stripPrefixOf pre s = if pre `isPrefixOf` s then Just (drop (length pre) s) else Nothing

-- | The first value that is not empty, as the shell's @${a:-${b:-c}}@.
firstOf :: [String] -> String
firstOf vs = case filter (not . null) vs of
  v : _ -> v
  [] -> ""

-- | A plan's yes, as the shell's set variable: @1@, or empty.
flag :: Bool -> String
flag b = if b then "1" else ""

-- | The directory the deploy was started in, as the shell's @$PWD@ names
-- it (links not resolved).
getPwd :: IO FilePath
getPwd = do
  here <- getCurrentDirectory
  fromMaybe here <$> lookupEnv "PWD"

-- | Whether a program is on PATH, as @command -v@.
found :: String -> IO Bool
found program = isJust <$> findExecutable program

-- | Whether a path is a file this user can read, as @[ -f F ] && [ -r F ]@.
isReadableFile :: FilePath -> IO Bool
isReadableFile file = do
  isFile <- doesFileExist file
  if not isFile
    then pure False
    else either (\(_ :: IOException) -> False) readable <$> try (getPermissions file)

-- | Whether Docker and its compose plugin answer.
dockerReady :: IO Bool
dockerReady = do
  docker <- found "docker"
  if not docker then pure False else (&&) <$> succeeds "docker" ["compose", "version"] <*> succeeds "docker" ["info"]

-- | Whether a zip holds app.wasm at its root, as the pages CI builds do:
-- read with python3, or unzip where there is none.
zipHoldsApp :: FilePath -> IO Bool
zipHoldsApp file = do
  python <- found "python3"
  if python
    then succeeds "python3" ["-c", "import sys, zipfile\nsys.exit(0 if \"app.wasm\" in zipfile.ZipFile(sys.argv[1]).namelist() else 1)", file]
    else do
      unzipThere <- found "unzip"
      unless unzipThere (die "--app-page: reading the zip takes python3, which is not installed here (nor unzip, which would do instead)")
      (_, listing) <- outputOf "unzip" ["-Z1", file]
      pure ("app.wasm" `elem` lines listing)

-- | The page cache's copies of the page from a file: the zips whose .meta
-- file names that file.
appPageEntries :: FilePath -> String -> String -> IO [FilePath]
appPageEntries cache kind meta = do
  there <- doesDirectoryExist cache
  if not there
    then pure []
    else do
      names <- listDirectory cache
      let metas = [cache </> f | f <- names, ("app-" <> kind <> "-file-") `isPrefixOf` f, ".zip.meta" `isSuffixOf` f]
      filterM
        ( \m' -> do
            let zip' = take (length m' - length (".meta" :: String)) m'
            isMeta <- doesFileExist m'
            isZip <- doesFileExist zip'
            if isMeta && isZip then (== meta) . chomp <$> readFile' m' else pure False
        )
        metas
  where
    readFile' f = do
      t <- readFile f
      length t `seq` pure t

-- | What a command prints, its errors after its output as @2>&1@ gives
-- them, and whether it succeeded.
interleaved :: FilePath -> [String] -> IO (Bool, String)
interleaved program args = do
  result <- try (readProcessInterleaved (setStdin nullStream (proc program args)))
  pure $ case result of
    Right (code, bytes) -> (code == ExitSuccess, decodeFs bytes)
    Left (_ :: IOException) -> (False, "")

-- | A text without its final newlines, as @$(…)@ gives it.
chomp :: String -> String
chomp = reverse . dropWhile (== '\n') . reverse

-- | Load the toolchain's environment into this process, for the programs
-- the deploy runs after it, as the shell loaded it: the toolchain
-- directory's env file (but with --system-tools, whose tools are the
-- machine's own), then the lines @toolchain/bootstrap.sh env@ prints. A
-- shell sources them and prints its environment, which replaces this
-- process's.
loadEnvironment :: FilePath -> Bool -> FilePath -> IO ()
loadEnvironment root systemTools base = do
  let script =
        "set -e\n\
        \if [ -z \"$1\" ] && [ -r \"$2\" ]; then . \"$2\"; fi\n\
        \bootstrap_env=$(sh \"$3\" env ${1:+--system-tools})\n\
        \eval \"$bootstrap_env\"\n\
        \env -0\n"
  (code, bytes) <- readProcessStdout (proc "sh" ["-c", script, "sh", if systemTools then "1" else "", base </> ".wiki-toolchain" </> "env", root </> "toolchain" </> "bootstrap.sh"])
  unless (code == ExitSuccess) (exitWith code)
  let entries = [(k, drop 1 v) | e <- splitNul (decodeFs bytes), not (null e), let (k, v) = break (== '=') e, k `notElem` shellOwn]
  current <- getEnvironment
  forM_ [k | (k, _) <- current, k `notElem` map fst entries, k `notElem` shellOwn] unsetEnv
  forM_ entries $ \(k, v) -> when (lookup k current /= Just v) (setEnv k v)
  where
    -- What the shell sets for itself, which this process keeps as it is.
    shellOwn = ["_", "SHLVL", "PWD", "OLDPWD"]
    splitNul s = case break (== '\0') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitNul rest
