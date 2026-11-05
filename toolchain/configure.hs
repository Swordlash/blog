{- cabal:
build-depends:
    base
  , brick ==3.0
  , directory
  , filepath
  , microlens
  , process
  , text
  , unix
  , vty ==6.6
  , vty-crossplatform ==0.5.0.0
-- brick runs vty's input in a thread of its own, which needs the threaded
-- runtime.
ghc-options: -threaded
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -Wall -Wextra #-}

-- | The configuration wizard of toolchain/deploy-local.sh: a terminal
-- application that asks for a deployment's options in a few screens and
-- builds the deploy's command line from the answers.
--
-- Run it through the wrapper, from anywhere:
--
-- >   sh toolchain/configure.sh
--
-- The wrapper checks the machine (toolchain/check-native.sh), installs GHC
-- and cabal (toolchain/bootstrap.sh native), and runs this file as a cabal
-- script from the checkout's root:
--
-- >   cabal run -z -v0 toolchain/configure.hs -- [--system-tools] [--hackage-mirror URL] [--npm-registry URL] [--args-from FILE]
--
-- --system-tools, --hackage-mirror URL and --npm-registry URL are the
-- deploy's options for a machine that installs nothing from the internet.
-- The wrapper gives them to the bootstrap that installs GHC and cabal for
-- the wizard, and the wizard takes them as answers over the state (see
-- presetArgs), so that its screens start with them.
--
-- The -z (--ignore-project) matters: without it cabal would build the
-- script inside the repository's cabal.project, and resolve and fetch every
-- package of the wiki first. The first run compiles brick and vty, which
-- takes a few minutes; cabal keeps them for the runs after.
--
-- The screens: what to do (deploy, --status or --stop) and which deployment
-- (--name, --prefix); what to deploy (--server or --static); where the
-- page comes from (built here, --backend-only, or --app-page, with
-- --bundle-locally); where the toolchain and the packages come from
-- (--system-tools, --npm-registry, --hackage-mirror); the database and the
-- TeX of the PDF exports (server only); how it is reached (the ways of
-- HTTPS, or plain HTTP); the address (port, bind address, admin port); the
-- extras. The answers start from the deployment's state file, found by
-- prefix and name as the deploy finds it, so that a rerun is Enter through
-- every screen. The last screen shows the command line: Enter runs it (the
-- wizard replaces itself with /bin/sh toolchain/deploy-local.sh, so the
-- deploy's output reaches the terminal and its exit status is the
-- wizard's), and q quits and prints the command line for copying.
--
-- With --args-from FILE the wizard shows no screens: it reads answers from
-- FILE, prints the command line it would run, and exits. The tests use it
-- (toolchain/test-configure.sh). FILE holds key=value lines; blank lines
-- and lines starting with # are skipped. The deployment's state is read
-- first, for the name and prefix the file gives (or the defaults), and the
-- file's lines change the answers from there, as the screens would. The
-- keys:
--
-- >   action=deploy|status|stop     name=NAME             prefix=DIR
-- >   mode=server|static            backend_only=|head|REF
-- >   db=postgres|sqlite            db_port=N
-- >   texlive=machine|toolchain|none  texlive_mirror=URL
-- >   texlive_installer=URL|DIR  perl_source=URL|DIR
-- >   way=tailscale|cert|proxy|http tls_cert=FILE  tls_key=FILE  tls_ca=FILE
-- >   port=N  bind=ADDRESS  admin_port=N  toolchain=DIR
-- >   fresh|refresh_page|no_build|no_firewall|enable_linger=yes|no
-- >   semaphore=probe|on|off
-- >   app_page=FILE  bundle_locally|system_tools=yes|no
-- >   npm_registry=URL  hackage_mirror=URL
--
-- backend_only is empty for a page built here, head for the page of the
-- checkout's commit, or a REF (main, a tag, a commit hash), as the state
-- file keeps it. texlive is the TeX of the PDF exports: the TeX on this
-- machine (no option), TeX Live under the toolchain (--texlive, with
-- --texlive-mirror when a mirror is given) or none (--no-texlive).
-- app_page is the zip of a page CI built, taken from a file (--app-page,
-- which a backend_only answer replaces); bundle_locally builds its
-- bundles here. system_tools, npm_registry and hackage_mirror are the
-- options for a machine that installs nothing from the internet.
-- texlive_installer and perl_source are the git repositories (or
-- directories) TeX Live's installer and Perl's source come from, when not
-- from their GitHub mirrors; the deploy does not remember them, so the
-- state file does not give them. Answers
-- that the deploy would refuse are printed on
-- standard error, and the wizard exits 1.
--
-- Every option of deploy-local.sh's header but --force (which does
-- nothing) is a string literal in this file, and every option literal here
-- is in the header: toolchain/test-deploy-local.sh checks both ways.
module Main (main) where

import Brick
  ( App (..)
  , AttrMap
  , AttrName
  , BrickEvent (..)
  , EventM
  , Padding (..)
  , ViewportType (Vertical)
  , Widget
  , attrMap
  , attrName
  , defaultMain
  , fg
  , get
  , hLimit
  , halt
  , on
  , padBottom
  , padLeft
  , padTop
  , put
  , showFirstCursor
  , txt
  , txtWrap
  , vBox
  , viewport
  , withAttr
  )
import Brick.Focus (focusGetCurrent)
import Brick.Forms
  ( Form
  , FormFieldState
  , checkboxField
  , editTextField
  , focusedFormInputAttr
  , formFocus
  , formState
  , handleFormEvent
  , newForm
  , radioField
  , renderForm
  , setFormFocus
  , (@@=)
  )
import Brick.Types (nestEventM')
import Brick.Widgets.Edit (editAttr, editFocusedAttr)
import Control.Exception (IOException, try)
import Control.Monad (foldM, unless)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Graphics.Vty as V
import Lens.Micro (Lens', lens)
import System.Directory (doesFileExist, getHomeDirectory, makeAbsolute)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (executeFile)
import System.Process (readProcess)

-- * The answers

-- | What the wizard is asked to do with the deployment.
data Action = Deploy | Status | Stop
  deriving (Eq, Ord, Show)

-- | What is deployed: the wiki's server, or the serverless demo.
data Mode = Server | Demo
  deriving (Eq, Ord, Show)

-- | Where the page comes from: built on this machine, downloaded from the
-- GitHub release CI keeps it in (--backend-only), or that zip taken from a
-- file (--app-page).
data Page = BuiltHere | Downloaded | FromFile
  deriving (Eq, Ord, Show)

-- | Where the server keeps the wiki.
data Database = Postgres | Sqlite
  deriving (Eq, Ord, Show)

-- | The TeX that makes the server's PDF exports: the TeX on this machine,
-- checked at the deploy (no option); TeX Live installed under the
-- toolchain directory (--texlive); or none (--no-texlive). The state file
-- keeps the choice as texlive=yes or texlive=no, and nothing for the first.
data TexChoice = MachineTex | ToolchainTex | NoTex
  deriving (Eq, Ord, Show)

-- | Whether the server's build uses cabal's build semaphore: as
-- toolchain/check-semaphore.sh finds (the deploy's default), always
-- (--semaphore), or never (--no-semaphore). The deploy does not remember
-- it, so a rerun starts from the probe.
data Semaphore = Probe | SemaphoreOn | SemaphoreOff
  deriving (Eq, Ord, Show)

-- | How the deployment is reached. The names are the state file's values
-- of its key way.
data Way = Tailscale | Certificate | Proxy | PlainHttp
  deriving (Eq, Ord, Show)

-- | The answers to every screen, which 'deployArgs' turns into the
-- deploy's arguments. Text fields hold what was typed; an empty one means
-- that the deploy decides (the previous run's value, or its default). The
-- two fields at the end are not asked: they say what the state file
-- remembered, which the deploy keeps unless told to forget it.
data Answers = Answers
  { action :: Action
  , name :: Text
  , prefix :: Text
  , mode :: Mode
  , page :: Page
  , pageRef :: Text
  , refreshPage :: Bool
  , appPage :: Text
  , bundleLocally :: Bool
  , systemTools :: Bool
  , npmRegistry :: Text
  , hackageMirror :: Text
  , database :: Database
  , dbPort :: Text
  , fresh :: Bool
  , tex :: TexChoice
  , texMirror :: Text
  , texInstaller :: Text
  , perlSource :: Text
  , way :: Way
  , tlsCert :: Text
  , tlsKey :: Text
  , tlsCa :: Text
  , port :: Text
  , bind :: Text
  , adminPort :: Text
  , toolchain :: Text
  , noBuild :: Bool
  , semaphore :: Semaphore
  , noFirewall :: Bool
  , enableLinger :: Bool
  , rememberedDownload :: Bool
  , rememberedCa :: Bool
  , rememberedTexLive :: Bool
  , rememberedBundle :: Bool
  , rememberedSystemTools :: Bool
  , rememberedNpmRegistry :: Bool
  , rememberedHackageMirror :: Bool
  }
  deriving (Eq, Show)

-- | The answers of a first run: the deploy's own defaults, written out.
defaultAnswers :: Answers
defaultAnswers =
  Answers
    { action = Deploy
    , name = "wiki-demo"
    , prefix = ""
    , mode = Server
    , page = BuiltHere
    , pageRef = ""
    , refreshPage = False
    , appPage = ""
    , bundleLocally = False
    , systemTools = False
    , npmRegistry = ""
    , hackageMirror = ""
    , database = Postgres
    , dbPort = "5433"
    , fresh = False
    , tex = MachineTex
    , texMirror = ""
    , texInstaller = ""
    , perlSource = ""
    , way = Tailscale
    , tlsCert = ""
    , tlsKey = ""
    , tlsCa = ""
    , port = "8080"
    , bind = ""
    , adminPort = "8081"
    , toolchain = ""
    , noBuild = False
    , semaphore = Probe
    , noFirewall = False
    , enableLinger = False
    , rememberedDownload = False
    , rememberedCa = False
    , rememberedTexLive = False
    , rememberedBundle = False
    , rememberedSystemTools = False
    , rememberedNpmRegistry = False
    , rememberedHackageMirror = False
    }

-- | The answers a deployment's state file gives: what the deploy would
-- take from it when run without options. The name and the prefix stay as
-- they are, since they are how the file was found.
fromState :: [(Text, Text)] -> Answers -> Answers
fromState kv a =
  a
    { mode = if value "mode" == "server" then Server else Demo
    , page =
        if not (T.null appPageFile)
          then FromFile
          else if T.null backendOnly then BuiltHere else Downloaded
    , pageRef = if backendOnly == "head" then "" else backendOnly
    , appPage = appPageFile
    , bundleLocally = value "bundle_locally" == "yes"
    , systemTools = value "system_tools" == "yes"
    , npmRegistry = value "npm_registry"
    , hackageMirror = value "hackage_mirror"
    , database = if value "db" == "sqlite" then Sqlite else Postgres
    , dbPort = orKeep (dbPort a) (value "db_port")
    , tex = case value "texlive" of
        "yes" -> ToolchainTex
        "no" -> NoTex
        _ -> MachineTex
    , texMirror = value "texlive_mirror"
    , way = remembered
    , tlsCert = if remembered == Certificate then value "tls_cert" else ""
    , tlsKey = if remembered == Certificate then value "tls_key" else ""
    , tlsCa = if remembered == Certificate then value "tls_ca" else ""
    , port = orKeep (port a) (value "port")
    , -- An address the deploy chose itself (bind_choice=auto) is chosen
      -- again on the next run, so it is not an answer.
      bind = if value "bind_choice" == "explicit" then value "bind" else ""
    , adminPort = orKeep (adminPort a) (value "admin_port")
    , toolchain = value "toolchain"
    , rememberedDownload = not (T.null backendOnly) || not (T.null appPageFile)
    , rememberedCa = remembered == Certificate && not (T.null (value "tls_ca"))
    , rememberedTexLive = value "texlive" == "yes"
    , rememberedBundle = value "bundle_locally" == "yes"
    , rememberedSystemTools = value "system_tools" == "yes"
    , rememberedNpmRegistry = not (T.null (value "npm_registry"))
    , rememberedHackageMirror = not (T.null (value "hackage_mirror"))
    }
  where
    -- As state_get: the last line of the key wins.
    value key = fromMaybe "" (lookup key (reverse kv))
    orKeep old new = if T.null new then old else new
    backendOnly = value "backend_only"
    appPageFile = value "app_page"
    -- A deployment from before the four ways has no way, and its https
    -- says which of the first two it was.
    remembered = case value "way" of
      "cert" -> Certificate
      "proxy" -> Proxy
      "http" -> PlainHttp
      "tailscale" -> Tailscale
      _ -> if value "https" == "no" then PlainHttp else Tailscale

-- | One line of an answer file applied to the answers, or what is wrong
-- with it.
applyAnswer :: Answers -> (Text, Text) -> Either Text Answers
applyAnswer a (key, v) = case key of
  "action" -> pick (\x -> a {action = x}) [("deploy", Deploy), ("status", Status), ("stop", Stop)]
  "name" -> Right a {name = v}
  "prefix" -> Right a {prefix = v}
  "mode" -> pick (\x -> a {mode = x}) [("server", Server), ("static", Demo)]
  "backend_only"
    | T.null v -> Right a {page = BuiltHere, pageRef = ""}
    | v == "head" -> Right a {page = Downloaded, pageRef = ""}
    | otherwise -> Right a {page = Downloaded, pageRef = v}
  "app_page"
    | T.null v -> Right a {appPage = ""}
    | otherwise -> Right a {page = FromFile, appPage = v}
  "bundle_locally" -> yesNo (\x -> a {bundleLocally = x})
  "system_tools" -> yesNo (\x -> a {systemTools = x})
  "npm_registry" -> Right a {npmRegistry = v}
  "hackage_mirror" -> Right a {hackageMirror = v}
  "db" -> pick (\x -> a {database = x}) [("postgres", Postgres), ("sqlite", Sqlite)]
  "db_port" -> Right a {dbPort = v}
  "texlive" -> pick (\x -> a {tex = x}) [("machine", MachineTex), ("toolchain", ToolchainTex), ("none", NoTex)]
  "texlive_mirror" -> Right a {texMirror = v}
  "texlive_installer" -> Right a {texInstaller = v}
  "perl_source" -> Right a {perlSource = v}
  "way" ->
    pick
      (\x -> a {way = x})
      [("tailscale", Tailscale), ("cert", Certificate), ("proxy", Proxy), ("http", PlainHttp)]
  "tls_cert" -> Right a {tlsCert = v}
  "tls_key" -> Right a {tlsKey = v}
  "tls_ca" -> Right a {tlsCa = v}
  "port" -> Right a {port = v}
  "bind" -> Right a {bind = v}
  "admin_port" -> Right a {adminPort = v}
  "toolchain" -> Right a {toolchain = v}
  "fresh" -> yesNo (\x -> a {fresh = x})
  "refresh_page" -> yesNo (\x -> a {refreshPage = x})
  "no_build" -> yesNo (\x -> a {noBuild = x})
  "semaphore" -> pick (\x -> a {semaphore = x}) [("probe", Probe), ("on", SemaphoreOn), ("off", SemaphoreOff)]
  "no_firewall" -> yesNo (\x -> a {noFirewall = x})
  "enable_linger" -> yesNo (\x -> a {enableLinger = x})
  _ -> Left ("unknown key " <> key)
  where
    pick set choices = case lookup v choices of
      Just x -> Right (set x)
      Nothing -> Left (key <> "=" <> v <> ": one of " <> T.intercalate ", " (map fst choices))
    yesNo set = pick set [("yes", True), ("no", False)]

-- | Lines of key=value, without blank lines and comments.
keyValues :: Text -> [(Text, Text)]
keyValues contents =
  [ (T.strip key, T.drop 1 rest)
  | line <- T.lines contents
  , not (T.null (T.strip line))
  , not ("#" `T.isPrefixOf` T.stripStart line)
  , let (key, rest) = T.breakOn "=" line
  ]

-- | A demo has no certificate of its own: its static server speaks plain
-- HTTP, so a remembered certificate gives way to Tailscale when the
-- deployment becomes the demo.
normalise :: Answers -> Answers
normalise a
  | mode a == Demo && way a == Certificate = a {way = Tailscale}
  | otherwise = a

-- * The command line

-- | The deploy's arguments for the answers. Only options that apply are
-- given: the deploy refuses a server's options for the demo, --db-port
-- with SQLite, --tls-ca without a certificate, and an address other than
-- 127.0.0.1 behind tailscale serve or a reverse proxy, where the address
-- is therefore left to the deploy.
deployArgs :: Answers -> [Text]
deployArgs a = case action a of
  Status -> "--status" : which
  Stop -> "--stop" : which
  Deploy ->
    concat
      [ [if server then "--server" else "--static"]
      , which
      , pageArgs
      , sourceArgs
      , if server then databaseArgs else []
      , if server then texArgs else []
      , wayArgs
      , option "--port" (port a)
      , if way a `elem` [PlainHttp, Certificate] then option "--bind" (bind a) else []
      , if server then option "--admin-port" (adminPort a) else []
      , option "--toolchain" (toolchain a)
      , flag "--no-build" (noBuild a)
      , if server && not (noBuild a) then semaphoreArgs else []
      , flag "--no-firewall" (noFirewall a)
      , flag "--enable-linger" (enableLinger a)
      ]
  where
    server = mode a == Server
    which =
      option "--prefix" (prefix a)
        ++ if name a == name defaultAnswers then [] else option "--name" (name a)
    pageArgs = case page a of
      Downloaded ->
        (if T.null (pageRef a) then "--backend-only" else "--backend-only=" <> pageRef a)
          : flag "--refresh-page" (refreshPage a)
          ++ bundleArgs
      FromFile -> option "--app-page" (appPage a) ++ bundleArgs
      BuiltHere -> flag "--no-backend-only" (rememberedDownload a)
    -- The bundles built here, for a page CI built; --no-bundle-locally
    -- forgets a remembered choice.
    bundleArgs
      | bundleLocally a = ["--bundle-locally"]
      | otherwise = flag "--no-bundle-locally" (rememberedBundle a)
    -- For a machine that installs nothing from the internet. What the
    -- state remembers and the answers drop is forgotten explicitly.
    sourceArgs =
      (if systemTools a then ["--system-tools"] else flag "--no-system-tools" (rememberedSystemTools a))
        ++ forgettable "--npm-registry" (npmRegistry a) (rememberedNpmRegistry a)
        ++ forgettable "--hackage-mirror" (hackageMirror a) (rememberedHackageMirror a)
    forgettable key v remembered
      | not (T.null v) = [key, v]
      | remembered = [key <> "="]
      | otherwise = []
    databaseArgs =
      ( case database a of
          Postgres -> "--postgres" : option "--db-port" (dbPort a)
          Sqlite -> ["--sqlite"]
      )
        ++ flag "--fresh" (fresh a)
    -- The TeX on this machine is the deploy's default, so it takes no
    -- option, unless the state remembers TeX Live under the toolchain,
    -- which --no-texlive forgets.
    texArgs = case tex a of
      MachineTex -> flag "--no-texlive" (rememberedTexLive a)
      ToolchainTex ->
        "--texlive"
          : option "--texlive-mirror" (texMirror a)
          ++ option "--texlive-installer" (texInstaller a)
          ++ option "--perl-source" (perlSource a)
      NoTex -> ["--no-texlive"]
    semaphoreArgs = case semaphore a of
      Probe -> []
      SemaphoreOn -> ["--semaphore"]
      SemaphoreOff -> ["--no-semaphore"]
    wayArgs = case way a of
      Tailscale -> ["--https"]
      Proxy -> ["--behind-proxy"]
      PlainHttp -> ["--http"]
      Certificate ->
        ["--tls-cert", tlsCert a, "--tls-key", tlsKey a]
          ++ if T.null (tlsCa a)
            then flag "--tls-ca=" (rememberedCa a)
            else ["--tls-ca", tlsCa a]
    option key v = if T.null v then [] else [key, v]
    flag key on' = [key | on']

-- | What the deploy would refuse in the answers, said for the person at
-- the wizard; empty when the command line can run.
problems :: Answers -> [Text]
problems a =
  concat
    [ ["The name may hold letters, digits, '-', '_', '.' and '@', and not start with '.'." | not (validName (name a))]
    , case action a of
        Deploy ->
          concat
            [ portProblem "The port" (port a)
            , if server then portProblem "The admin port" (adminPort a) else []
            , if server && database a == Postgres then portProblem "The database's port" (dbPort a) else []
            , ["The admin port and the port must differ." | server, not (T.null (port a)), port a == adminPort a]
            , [ "The database's port must differ from the listeners' ports."
              | server
              , database a == Postgres
              , not (T.null (dbPort a))
              , dbPort a `elem` [port a, adminPort a]
              ]
            , ["A certificate needs its file." | way a == Certificate, T.null (tlsCert a)]
            , [ "The CTAN mirror is an http:// or https:// URL, without spaces or quotes."
              | server
              , tex a == ToolchainTex
              , not (T.null (texMirror a))
              , not (validMirror (texMirror a))
              ]
            , [ what <> " is a git repository's http:// or https:// URL, without spaces or quotes, or a directory of this machine."
              | server
              , tex a == ToolchainTex
              , (what, v) <- [("TeX Live's installer", texInstaller a), ("Perl's source", perlSource a)]
              , "://" `T.isInfixOf` v
              , not (validMirror v)
              ]
            , ["A certificate needs its key's file (the same file when one .pem holds both)." | way a == Certificate, T.null (tlsKey a)]
            , ["A page from a file needs the file, the zip CI built (--app-page)." | page a == FromFile, T.null (appPage a)]
            , [ "The machine's own toolchain (--system-tools) needs the page CI built, downloaded or from a file: building the page here needs the wasm toolchain, which only the bootstrap installs."
              | systemTools a
              , page a == BuiltHere
              , not (noBuild a)
              ]
            , [ what <> " is an http:// or https:// URL, without spaces or quotes."
              | (what, v) <- [("The npm registry", npmRegistry a), ("The Hackage mirror", hackageMirror a)]
              , not (T.null v)
              , not (validMirror v)
              ]
            , [ "The Hackage mirror is written into the toolchain's own cabal configuration, never ~/.cabal: give a prefix, or a toolchain directory of its own."
              | not (T.null (hackageMirror a))
              , T.null (prefix a)
              , T.null (toolchain a)
              ]
            ]
        _ -> []
    ]
  where
    server = mode a == Server
    portProblem what v
      | T.null v = []
      | T.all isDigit v && not ("0" `T.isPrefixOf` v) && T.length v <= 5 && within (read (T.unpack v) :: Int) = []
      | otherwise = [what <> " is a number from 1024 to 65535."]
    within n = n >= 1024 && n <= 65535
    -- As the deploy checks --texlive-mirror, and the URLs of
    -- --texlive-installer and --perl-source (a value without :// is a
    -- directory, whose existence the deploy checks).
    validMirror m =
      any (\scheme -> scheme `T.isPrefixOf` m && T.length m > T.length scheme) ["http://", "https://"]
        && not (T.any (\c -> c `elem` ("\"'\\`$" :: String) || c == ' ' || c == '\t' || c == '\n') m)
    validName n =
      not (T.null n)
        && not ("." `T.isPrefixOf` n)
        && T.all (\c -> c `elem` ("_.@-" :: String) || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || isDigit c) n

-- | The command line as it can be pasted into a shell at the checkout's
-- root: every argument that holds anything but plain characters is in
-- single quotes.
commandLine :: Answers -> Text
commandLine a = T.unwords ("sh" : "toolchain/deploy-local.sh" : map quote (deployArgs a))

quote :: Text -> Text
quote w
  | not (T.null w) && T.all plain w = w
  | otherwise = "'" <> T.replace "'" "'\\''" w <> "'"
  where
    plain c = c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || isDigit c || c `elem` ("_@%+=:,./-" :: String)

-- * Paths and the state file

-- | A path as the deploy will see it. ~ and ~/ are expanded, and a
-- relative path is taken from the directory toolchain/configure.sh was
-- started in (WIKI_CONFIGURE_DIR, which the wrapper sets before it changes
-- to the checkout's root), or else from the current directory. Then the
-- path is resolved by `realpath -m`, the program the deploy itself resolves
-- its paths with, so that the two cannot disagree: realpath follows
-- symbolic links and removes . and .. in an order of its own, which a
-- path such as /srv/missing/../link/../wiki depends on. The deploy needs
-- realpath too, so a machine without it fails here as the deploy would.
absolute :: Text -> IO Text
absolute t
  | T.null t = pure t
  | otherwise = do
      home <- getHomeDirectory
      let s = T.unpack t
          expanded
            | s == "~" = home
            | "~/" `T.isPrefixOf` t = home </> drop 2 s
            | otherwise = s
      started <- lookupEnv "WIKI_CONFIGURE_DIR"
      rooted <- case started of
        Just dir | not (null dir) -> pure (dir </> expanded)
        _ -> makeAbsolute expanded
      resolved <- try (readProcess "realpath" ["-m", rooted] "")
      case resolved of
        Right out | (line : _) <- lines out, not (null line) -> pure (T.pack line)
        Right _ -> ioError (userError ("realpath -m " <> rooted <> " printed nothing"))
        Left e ->
          ioError
            ( userError
                ( "realpath -m "
                    <> rooted
                    <> " failed ("
                    <> show (e :: IOException)
                    <> "): the wizard resolves paths with realpath, as the deploy does; install coreutils"
                )
            )

-- | The answers' paths as the deploy will resolve them ('absolute'): the
-- prefix as the deploy keeps it in the state, the toolchain and the
-- certificate's files as the unit will name them, and the directories TeX
-- Live's installer and Perl's source come from, as the deploy reads them.
resolvePaths :: Answers -> IO Answers
resolvePaths a = do
  p <- absolute (prefix a)
  t <- absolute (toolchain a)
  c <- absolute (tlsCert a)
  k <- absolute (tlsKey a)
  ca <- absolute (tlsCa a)
  i <- source (texInstaller a)
  ps <- source (perlSource a)
  ap <- absolute (appPage a)
  pure a {prefix = p, toolchain = t, tlsCert = c, tlsKey = k, tlsCa = ca, texInstaller = i, perlSource = ps, appPage = ap}
  where
    -- A source of the TeX step is a URL, kept as it is, or a directory.
    source v = if "://" `T.isInfixOf` v then pure v else absolute v

-- | The state file of a deployment, found as deploy-lib.sh's layout finds
-- it: under the prefix (<prefix>/state/<name>.state), or for a deployment
-- in the home directory in ${XDG_CONFIG_HOME:-~/.config}/wiki-demo. A
-- deployment made before --prefix keeps its state in the home directory
-- until a deploy adopts it, and is found there when its dir is the prefix.
-- The prefix is absolute, with its links resolved ('resolvePaths').
statePath :: Text -> Text -> IO (Maybe FilePath)
statePath pfx nm = do
  home <- getHomeDirectory
  -- As ${XDG_CONFIG_HOME:-$HOME/.config}: an empty value counts as unset.
  config <- maybe (home </> ".config") (\c -> if null c then home </> ".config" else c) <$> lookupEnv "XDG_CONFIG_HOME"
  let file = T.unpack (fromMaybe nm (T.stripSuffix ".service" nm)) <> ".state"
      inHome = config </> "wiki-demo" </> file
  if T.null pfx
    then existing inHome
    else do
      underPrefix <- existing (T.unpack pfx </> "state" </> file)
      case underPrefix of
        Just f -> pure (Just f)
        Nothing -> do
          old <- existing inHome
          case old of
            Just f -> do
              kv <- keyValues <$> T.readFile f
              pure (if lookup "dir" (reverse kv) == Just pfx then Just f else Nothing)
            Nothing -> pure Nothing
  where
    existing f = do
      there <- doesFileExist f
      pure (if there then Just f else Nothing)

-- | The answers for a deployment: the given ones with the paths resolved
-- and, when the deployment has a state file, what it remembers; with the
-- file, or a note that none was found.
prefill :: Answers -> IO (Answers, Text)
prefill given = do
  a <- resolvePaths given
  found <- statePath (prefix a) (name a)
  case found of
    Just f -> do
      kv <- keyValues <$> T.readFile f
      pure (fromState kv a, "The answers are those of the last deploy, from " <> T.pack f <> ".")
    Nothing ->
      pure
        ( a
        , "No deployment "
            <> name a
            <> (if T.null (prefix a) then "" else " under " <> prefix a)
            <> " yet: the answers are the first run's defaults."
        )

-- * The screens

data Screen = Which | What | PageSource | Sources | DatabaseScreen | Reach | Address | Extras | Command
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The resource names: one per field, one per choice of a radio field,
-- and the viewport the form scrolls in.
data Name
  = ActionChoice Action
  | NameField
  | PrefixField
  | ModeChoice Mode
  | PageChoice Page
  | RefField
  | RefreshField
  | AppPageField
  | BundleField
  | SystemToolsField
  | NpmRegistryField
  | HackageMirrorField
  | DatabaseChoice Database
  | DbPortField
  | FreshField
  | TexChoiceName TexChoice
  | MirrorField
  | InstallerField
  | PerlSourceField
  | WayChoice Way
  | CertField
  | KeyField
  | CaField
  | PortField
  | BindField
  | AdminPortField
  | ToolchainField
  | NoBuildField
  | SemaphoreChoice Semaphore
  | NoFirewallField
  | LingerField
  | Scroll
  deriving (Eq, Ord, Show)

type Field = Answers -> FormFieldState Answers () Name

-- | The title and introduction of a screen.
screenTitle :: Screen -> (Text, Text)
screenTitle s = case s of
  Which ->
    ( "Which deployment"
    , "A deployment is a name and a place: several live side by side under different names. What you choose here fills the next screens from that deployment's last run."
    )
  What -> ("What to deploy", "The wiki's server, or the demo that keeps its wiki in the browser.")
  PageSource -> ("Where the page comes from", "The page is the application the browser runs, compiled to WebAssembly.")
  Sources ->
    ( "Where the toolchain and the packages come from"
    , "For a machine that installs nothing from the internet: the machine's own compilers, and mirrors for npm's and Hackage's packages. Empty and unticked, the deploy downloads them as usual."
    )
  DatabaseScreen -> ("The database and PDFs", "Where the wiki's server keeps the wiki, and the TeX that makes its PDF exports.")
  Reach -> ("How it is reached", "HTTPS one of three ways, or plain HTTP. The ways exclude each other.")
  Address -> ("The address", "Where the server listens on this machine.")
  Extras -> ("The rest", "Options most deployments leave alone.")
  Command -> ("The command", "")

-- | The fields of a screen, for the answers so far: a field that does not
-- apply to the choices made before it is left out.
fieldsFor :: Screen -> Answers -> [Field]
fieldsFor s a = case s of
  Which ->
    [ choice
        "What to do"
        ( case action a of
            Deploy -> "Build and install the deployment, or replace it with a new build. The next screens ask how."
            Status -> "Show the deployment, its service and its address, and change nothing."
            Stop -> "Stop and disable the service, remove its unit, close its port and turn its tailscale serve off. Its files and the wiki's data stay."
        )
        actionL
        [ (Deploy, ActionChoice Deploy, "deploy")
        , (Status, ActionChoice Status, "--status  show it")
        , (Stop, ActionChoice Stop, "--stop  take it down")
        ]
    , text
        "--name"
        "The deployment's name, which is also its systemd unit's (NAME.service). Letters, digits, '-', '_', '.' and '@'."
        nameL
        NameField
    , text
        "--prefix"
        "The directory everything of the deployment goes under: the program, the page, the data, the state and the toolchain. Empty: the home directory, with the deployment in ~/NAME and its state in ~/.config/wiki-demo. A deployment under a prefix is found again only through it, so give the same one every time."
        prefixL
        PrefixField
    ]
  What ->
    [ choice
        "What"
        ( case mode a of
            Server -> "wiki-server, with the wiki's data on this machine in <directory>/data, and an admin listener on 127.0.0.1 for its administration."
            Demo -> "The serverless demo, served as static files: each visitor's wiki lives in their browser. A server's data already in the directory is kept."
        )
        modeL
        [ (Server, ModeChoice Server, "--server  the wiki's server")
        , (Demo, ModeChoice Demo, "--static  the demo")
        ]
    ]
  PageSource ->
    [ choice
        "The page"
        ( case page a of
            BuiltHere ->
              "Compiled here, with the wasm toolchain and Node, which the bootstrap installs. The first build takes over an hour; later ones minutes. After a deployment that downloaded its page, this gives --no-backend-only."
            Downloaded ->
              "Downloaded from the GitHub release CI keeps it in, so nothing is compiled for the browser: the server is built alone (GHC and cabal, no Node), and the demo is not built at all."
            FromFile ->
              "The zip CI built, as it is downloaded, but from a file on this machine, for a machine that cannot reach github.com. Nothing is compiled for the browser, as when it is downloaded."
        )
        pageL
        [ (BuiltHere, PageChoice BuiltHere, "built on this machine")
        , (Downloaded, PageChoice Downloaded, "--backend-only  downloaded, as CI built it")
        , (FromFile, PageChoice FromFile, "--app-page  CI's zip, from a file")
        ]
    ]
      ++ ( if page a == Downloaded
             then
               [ text
                   "Which commit's page (--backend-only=REF)"
                   "Empty: the page of this checkout's commit, which matches its server. main: the newest page of main. A tag: its release's page. A commit hash, whole or its beginning."
                   pageRefL
                   RefField
               , check
                   "Downloads go to a cache of the five newest pages; a commit's page never changes, so a cached one is used as it is."
                   refreshPageL
                   RefreshField
                   "--refresh-page  download it even when the cache has it"
               ]
             else []
         )
      ++ [ text
             "--app-page"
             "The zip CI built (app-server-<hash>.zip, or app-demo-<hash>.zip for the demo), copied onto this machine from the GitHub release. It is checked and cached as a downloaded one is. Remembered."
             appPageL
             AppPageField
         | page a == FromFile
         ]
      ++ [ check
             "Of the page CI built, keep only what needs the wasm toolchain (app.wasm and the prerendered pages), and build its JavaScript and CSS bundles here with npm ci and web/bundle.sh, then compare the page with CI's file by file: the deploy says identical, or names every file that differs. Needs Node."
             bundleLocallyL
             BundleField
             "--bundle-locally  build its JavaScript and CSS bundles here"
         | page a /= BuiltHere
         ]
  Sources ->
    [ check
        "Nothing is downloaded for the toolchain: GHC, cabal and Node are this machine's own, on PATH, and ghcup is not needed. The deploy checks them before anything else, and stops at once naming any that is missing or older than toolchain/bootstrap.sh accepts; one that is not the version the bootstrap pins is used with a warning. Needs the page CI built (the screen before), since building the page needs the wasm toolchain."
        systemToolsL
        SystemToolsField
        "--system-tools  this machine's own GHC, cabal and Node"
    , text
        "--npm-registry"
        "The npm registry npm ci and npx take every package from, such as a company's mirror; npm rewrites the lockfile's registry.npmjs.org addresses to it. Empty: the registry npm is set up with. Remembered."
        npmRegistryL
        NpmRegistryField
    , text
        "--hackage-mirror"
        "A mirror of Hackage that cabal takes its index and packages from, written into the toolchain's own cabal configuration and never into ~/.cabal, so it needs a prefix or a toolchain directory of its own. It must serve Hackage's signed index (root.json and the rest), as a full mirror does. Empty: Hackage. Remembered."
        hackageMirrorL
        HackageMirrorField
    ]
  DatabaseScreen ->
    [ choice
        "The database"
        ( case database a of
            Postgres -> "PostgreSQL 17 in Docker, as the compose project NAME, its data in the volume NAME_wiki-db and its port on 127.0.0.1 only. Needs Docker and its compose plugin."
            Sqlite -> "A file, <directory>/data/wiki.sqlite, with no Docker and no second process. The server is then built without PostgreSQL, so libpq is not needed."
        )
        databaseL
        [ (Postgres, DatabaseChoice Postgres, "--postgres  PostgreSQL, in Docker")
        , (Sqlite, DatabaseChoice Sqlite, "--sqlite  SQLite, a file")
        ]
    ]
      ++ [ text
             "--db-port"
             "The port PostgreSQL listens on, on 127.0.0.1."
             dbPortL
             DbPortField
         | database a == Postgres
         ]
      ++ [ check
             "Over a data/wiki.sqlite this deployment cannot use (one of an older schema, or of SQLite when PostgreSQL is chosen), go on and move the file aside into data/replaced/<time>/ rather than stop. Export the wiki with the running server first, and import it after."
             freshL
             FreshField
             "--fresh  move an unusable database file aside"
         ]
      ++ [ choice
             "PDF exports"
             ( case tex a of
                 MachineTex ->
                   "The xelatex the service finds on its PATH (the systemd user manager's, not your shell's), checked at the deploy by typesetting a small document under the export's limits. When there is none, or it fails (TeX Live 2020 and older loop on unicode-math's table), the deploy asks whether to install TeX Live under the toolchain, unless an earlier deploy was told no (--no-texlive, or no at its question)."
                 ToolchainTex ->
                   "TeX Live installed under the toolchain directory (.wiki-toolchain/texlive) from a CTAN mirror, about 250 MB and a few minutes, when the TeX the service finds does not work; one installed there already is checked and used. Its installer is cloned with git from its GitHub mirror, and needs curl and tar, and Perl with its standard modules: where the machine has none, the deploy clones Perl's source from its GitHub mirror and builds it under the toolchain (.wiki-toolchain/perl, a few minutes with cc), for the installer only. The unit puts TeX Live's bin directory first on the service's PATH."
                 NoTex ->
                   "No TeX Live is installed. The server makes PDFs only with a TeX of this machine's that works; otherwise it offers no PDFs, and its administration's Server section says why."
             )
             texL
             [ (MachineTex, TexChoiceName MachineTex, "the TeX on this machine, checked at the deploy")
             , (ToolchainTex, TexChoiceName ToolchainTex, "--texlive  TeX Live under the toolchain, from a CTAN mirror")
             , (NoTex, TexChoiceName NoTex, "--no-texlive  none")
             ]
         ]
      ++ [ text
             "--texlive-mirror"
             "The CTAN mirror TeX Live is downloaded from, through the proxy https_proxy names, if any. Empty: https://mirror.ctan.org, which redirects to a mirror near you."
             texMirrorL
             MirrorField
         | tex a == ToolchainTex
         ]
      ++ [ text
             "--texlive-installer"
             "Optional: the git repository TeX Live's installer is cloned from, an http:// or https:// URL, or a directory of this machine holding install-tl, used as it is. Empty: https://github.com/TeX-Live/installer, its official mirror. Not remembered."
             texInstallerL
             InstallerField
         | tex a == ToolchainTex
         ]
      ++ [ text
             "--perl-source"
             "Optional, for a machine without a Perl that works: the git repository Perl's source is cloned from at its tag v5.44.0, an http:// or https:// URL, or a directory of this machine with that source, copied and built under the toolchain. Empty: https://github.com/Perl/perl5. Not remembered."
             perlSourceL
             PerlSourceField
         | tex a == ToolchainTex
         ]
  Reach ->
    [ choice
        "The way"
        ( case way a of
            Tailscale ->
              "tailscale serve puts the wiki on your tailnet at https://<machine>.<tailnet>.ts.net/, with a certificate it fetches and renews itself. The server listens on 127.0.0.1. The tailnet needs MagicDNS and HTTPS Certificates on."
            Certificate ->
              "wiki-server serves HTTPS itself, with a certificate and key of your own in PEM, as a company's certificate authority issues them. The service reads them as it starts: a renewed certificate takes a restart."
            Proxy ->
              "A reverse proxy on this machine (Caddy, nginx) serves HTTPS and forwards to the server's plain HTTP on 127.0.0.1. The deploy prints what the proxy must do."
            PlainHttp ->
              "Plain HTTP on the Tailscale address, without Secure cookies, for a tailnet without HTTPS certificates."
        )
        wayL
        ( [(Tailscale, WayChoice Tailscale, "--https  through tailscale serve")]
            ++ [(Certificate, WayChoice Certificate, "--tls-cert  a certificate of your own") | mode a == Server]
            ++ [ (Proxy, WayChoice Proxy, "--behind-proxy  behind a reverse proxy")
               , (PlainHttp, WayChoice PlainHttp, "--http  plain HTTP")
               ]
        )
    ]
      ++ if way a == Certificate
        then
          [ text
              "--tls-cert"
              "The certificate, PEM, its chain after it in the file. It stays where it is and must stay readable by you; inside the deployment's directory only data/ will do, since installing empties the rest."
              tlsCertL
              CertField
          , text
              "--tls-key"
              "The certificate's private key, PEM: the same file as the certificate when one .pem holds both."
              tlsKeyL
              KeyField
          , text
              "--tls-ca"
              "Optional: the certificate authority to check the served certificate against after the deploy, for the name the certificate is issued for. Empty: the check skips verification."
              tlsCaL
              CaField
          ]
        else []
  Address ->
    [ text
        "--port"
        "The port the wiki is served on, 1024 to 65535."
        portL
        PortField
    ]
      ++ [ text
             "--bind"
             ( "The address to listen on. Empty: "
                 <> (if way a == PlainHttp then "this machine's Tailscale address" else "the Tailscale address")
                 <> ", or the last run's choice. 0.0.0.0 listens everywhere."
             )
             bindL
             BindField
         | way a `elem` [PlainHttp, Certificate]
         ]
      ++ [ text
             "--admin-port"
             "The port of the admin listener, on 127.0.0.1 only: the administration, for whoever is on this machine (from elsewhere through ssh -L)."
             adminPortL
             AdminPortField
         | mode a == Server
         ]
  Extras ->
    [ text
        "--toolchain"
        "Where the toolchain the build needs is installed. Empty: the last run's, or <prefix>/toolchain under a prefix, or the home directory. Two deployments share one by naming the same directory."
        toolchainL
        ToolchainField
    , check
        "Deploy the last -O2 build as it is, without building."
        noBuildL
        NoBuildField
        "--no-build  skip the build"
    ]
      ++ [ choice
             "The build semaphore"
             ( case semaphore a of
                 Probe ->
                   "cabal's build semaphore lets cabal and GHC share one budget of jobs, so the modules of a package compile in parallel too. Some machines refuse it, and then every package's build fails: toolchain/check-semaphore.sh tries it first, and the build uses it only when it works."
                 SemaphoreOn -> "Build with the semaphore, without trying it first."
                 SemaphoreOff -> "Build without the semaphore: packages in parallel, the modules of each one at a time."
             )
             semaphoreL
             [ (Probe, SemaphoreChoice Probe, "tried first, used when it works")
             , (SemaphoreOn, SemaphoreChoice SemaphoreOn, "--semaphore  always")
             , (SemaphoreOff, SemaphoreChoice SemaphoreOff, "--no-semaphore  never")
             ]
         | mode a == Server
         ]
      ++ [ check
             "With plain HTTP or a certificate the deploy opens the port in ufw on the Tailscale interface; this leaves the firewall alone."
             noFirewallL
             NoFirewallField
             "--no-firewall  leave the firewall alone"
         , check
             "Run sudo loginctl enable-linger, so the service starts at boot and keeps running after you log out."
             enableLingerL
             LingerField
             "--enable-linger  start at boot"
         ]
  Command -> []

-- | A radio field with its title and the help of the current choice.
choice :: (Eq v) => Text -> Text -> Lens' Answers v -> [(v, Name, Text)] -> Field
choice title help l options = framed (Just title) help @@= radioField l options

-- | A one-line text field, titled.
text :: Text -> Text -> Lens' Answers Text -> Name -> Field
text title help l n = framed (Just title) help @@= editTextField l n (Just 1)

-- | A checkbox, with its label beside it and its help below.
check :: Text -> Lens' Answers Bool -> Name -> Text -> Field
check help l n label = framed Nothing help @@= checkboxField l n label

framed :: Maybe Text -> Text -> Widget Name -> Widget Name
framed title help w =
  padBottom (Pad 1) $
    vBox
      [ maybe (vBox []) (withAttr titleAttr . txt) title
      , padLeft (Pad 2) (hLimit 100 w)
      , padLeft (Pad 4) (hLimit 96 (withAttr helpAttr (txtWrap help)))
      ]

-- The lenses the fields read and write the answers through.
actionL :: Lens' Answers Action
actionL = lens action (\a v -> a {action = v})

nameL, prefixL, pageRefL, dbPortL, texMirrorL, texInstallerL, perlSourceL, tlsCertL, tlsKeyL, tlsCaL, portL, bindL, adminPortL, toolchainL :: Lens' Answers Text
nameL = lens name (\a v -> a {name = v})
prefixL = lens prefix (\a v -> a {prefix = v})
pageRefL = lens pageRef (\a v -> a {pageRef = v})
dbPortL = lens dbPort (\a v -> a {dbPort = v})
texMirrorL = lens texMirror (\a v -> a {texMirror = v})
texInstallerL = lens texInstaller (\a v -> a {texInstaller = v})
perlSourceL = lens perlSource (\a v -> a {perlSource = v})
tlsCertL = lens tlsCert (\a v -> a {tlsCert = v})
tlsKeyL = lens tlsKey (\a v -> a {tlsKey = v})
tlsCaL = lens tlsCa (\a v -> a {tlsCa = v})
portL = lens port (\a v -> a {port = v})
bindL = lens bind (\a v -> a {bind = v})
adminPortL = lens adminPort (\a v -> a {adminPort = v})
toolchainL = lens toolchain (\a v -> a {toolchain = v})

appPageL, npmRegistryL, hackageMirrorL :: Lens' Answers Text
appPageL = lens appPage (\a v -> a {appPage = v})
npmRegistryL = lens npmRegistry (\a v -> a {npmRegistry = v})
hackageMirrorL = lens hackageMirror (\a v -> a {hackageMirror = v})

bundleLocallyL, systemToolsL :: Lens' Answers Bool
bundleLocallyL = lens bundleLocally (\a v -> a {bundleLocally = v})
systemToolsL = lens systemTools (\a v -> a {systemTools = v})

modeL :: Lens' Answers Mode
modeL = lens mode (\a v -> a {mode = v})

pageL :: Lens' Answers Page
pageL = lens page (\a v -> a {page = v})

databaseL :: Lens' Answers Database
databaseL = lens database (\a v -> a {database = v})

texL :: Lens' Answers TexChoice
texL = lens tex (\a v -> a {tex = v})

wayL :: Lens' Answers Way
wayL = lens way (\a v -> a {way = v})

semaphoreL :: Lens' Answers Semaphore
semaphoreL = lens semaphore (\a v -> a {semaphore = v})

refreshPageL, freshL, noBuildL, noFirewallL, enableLingerL :: Lens' Answers Bool
refreshPageL = lens refreshPage (\a v -> a {refreshPage = v})
freshL = lens fresh (\a v -> a {fresh = v})
noBuildL = lens noBuild (\a v -> a {noBuild = v})
noFirewallL = lens noFirewall (\a v -> a {noFirewall = v})
enableLingerL = lens enableLinger (\a v -> a {enableLinger = v})

-- * The application

-- | The wizard's state: the screen, its form (whose state is the
-- answers), the deployment the answers were last filled from and the note
-- that says so, and how the wizard ends.
data Wizard = Wizard
  { screen :: Screen
  , form :: Form Answers () Name
  , filledFrom :: (Text, Text)
  , note :: Text
  , ending :: Ending
  , presets :: [(Text, Text)]
  -- ^ The answers the wrapper's options give (see presetArgs), applied
  -- again over every deployment's state the first screen loads.
  }

-- | How the wizard ends: still running, quit before the last screen,
-- quit from the last screen (and print the command line, to copy), or run
-- the deploy.
data Ending = Running | Abandon | Quit | Run
  deriving (Eq)

-- | A screen's form for the answers. Choices that hide or show fields
-- rebuild it ('shape').
formFor :: Screen -> Answers -> Form Answers () Name
formFor s a = newForm (fieldsFor s a') a' where a' = normalise a

-- | What decides which fields a screen shows, and the help of its
-- choices: when an event changes it, the form is built again.
shape :: Answers -> (Action, Mode, Page, Database, TexChoice, Way)
shape a = (action a, mode a, page a, database a, tex a, way a)

answers :: Wizard -> Answers
answers = formState . form

-- | The screen after this one, for the answers: the status and the stop
-- go straight to the command, and the demo has no database.
nextScreen :: Answers -> Screen -> Screen
nextScreen a s = case s of
  Which | action a /= Deploy -> Command
  Sources | mode a == Demo -> Reach
  Command -> Command
  _ -> succ s

previousScreen :: Answers -> Screen -> Screen
previousScreen a s = case s of
  Command | action a /= Deploy -> Which
  Reach | mode a == Demo -> Sources
  Which -> Which
  _ -> pred s

-- | The screens a deployment goes through, for the progress line.
screensFor :: Answers -> [Screen]
screensFor a = go Which
  where
    go Command = [Command]
    go s = s : go (nextScreen a s)

-- | Go to a screen. Leaving the first one for another deployment fills
-- the answers from that deployment's state first.
goTo :: Screen -> EventM Name Wizard ()
goTo s = do
  w <- get
  let a = answers w
  (a', from, n) <-
    if screen w == Which && filledFrom w /= (name a, prefix a)
      then do
        -- Another deployment starts from the defaults, not from the
        -- answers of the one before, and the presets apply to it too.
        (filled, n) <- liftIO (loadDeployment (presets w) defaultAnswers {action = action a, name = name a, prefix = prefix a})
        -- Remembered as prefill resolved them, as the form now shows them,
        -- so that coming back to the first screen does not fill again.
        pure (filled, (name filled, prefix filled), n)
      else pure (a, filledFrom w, note w)
  put w {screen = s, form = formFor s a', filledFrom = from, note = n}

handleEvent :: BrickEvent Name () -> EventM Name Wizard ()
handleEvent ev = do
  w <- get
  let a = answers w
  case ev of
    VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl]) -> put w {ending = Abandon} >> halt
    VtyEvent (V.EvKey V.KEsc [])
      | screen w == Which -> put w {ending = Abandon} >> halt
      | otherwise -> goTo (previousScreen a (screen w))
    VtyEvent (V.EvKey V.KEnter [])
      | screen w == Command ->
          if null (problems a) then put w {ending = Run} >> halt else pure ()
      | otherwise -> goTo (nextScreen a (screen w))
    VtyEvent (V.EvKey (V.KChar 'q') [])
      | screen w == Command -> put w {ending = Quit} >> halt
    _ | screen w == Command -> pure ()
    _ -> do
      f <- nestEventM' (form w) (handleFormEvent ev)
      let a' = formState f
      if shape a' == shape a
        then put w {form = f}
        else do
          -- Rebuilt, so that fields come and go with the choice; the
          -- focus stays on the field that had it.
          let rebuilt = formFor (screen w) a'
              focused = focusGetCurrent (formFocus f)
          put w {form = maybe rebuilt (`setFormFocus` rebuilt) focused}

draw :: Wizard -> [Widget Name]
draw w =
  [ padLeft (Pad 1) . padTop (Pad 1) $
      vBox
        [ withAttr titleAttr (txt ("Configure a deployment (" <> progress <> "): " <> title))
        , if screen w == Which then vBox [] else withAttr helpAttr (txtWrap (note w))
        , padTop (Pad 1) (if T.null intro then vBox [] else hLimit 100 (txtWrap intro))
        , padTop (Pad 1) body
        , padTop (Pad 1) (withAttr helpAttr (txtWrap keys))
        ]
  ]
  where
    a = answers w
    (title, intro) = screenTitle (screen w)
    steps = screensFor a
    progress = case lookup (screen w) (zip steps [1 :: Int ..]) of
      Just i -> T.pack (show i) <> " of " <> T.pack (show (length steps))
      Nothing -> ""
    body = case screen w of
      Command ->
        vBox
          ( [ txtWrap "The deploy will run as:"
            , padTop (Pad 1) (padLeft (Pad 2) (withAttr commandAttr (txtWrap (commandLine a))))
            ]
              ++ [ padTop (Pad 1) (vBox (map (withAttr problemAttr . txtWrap) ps))
                 | let ps = problems a
                 , not (null ps)
                 ]
          )
      _ -> viewport Scroll Vertical (renderForm (form w))
    keys = case screen w of
      Command
        | null (problems a) -> "Enter runs it   Esc goes back   q quits and prints the command line, to copy"
        | otherwise -> "Esc goes back to change the answers   q quits and prints the command line"
      Which -> "Tab, Shift-Tab: next and previous field   Space chooses   Enter: next screen   Esc quits"
      _ -> "Tab, Shift-Tab: next and previous field   Space chooses   Enter: next screen   Esc: back   Ctrl-C quits"

titleAttr, helpAttr, commandAttr, problemAttr :: AttrName
titleAttr = attrName "title"
helpAttr = attrName "help"
commandAttr = attrName "command"
problemAttr = attrName "problem"

attributes :: AttrMap
attributes =
  attrMap
    V.defAttr
    [ (titleAttr, V.defAttr `V.withStyle` V.bold)
    , (helpAttr, fg V.brightBlack)
    , (commandAttr, V.defAttr `V.withStyle` V.bold)
    , (problemAttr, fg V.red)
    , (editAttr, V.white `on` V.brightBlack)
    , (editFocusedAttr, V.black `on` V.yellow)
    , (focusedFormInputAttr, V.defAttr `V.withStyle` V.reverseVideo)
    ]

app :: App Wizard () Name
app =
  App
    { appDraw = draw
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = pure ()
    , appAttrMap = const attributes
    }

-- * Main

main :: IO ()
main = do
  args <- getArgs
  case presetArgs args of
    Left e -> hPutStrLn stderr ("configure: " <> e) >> hPutStrLn stderr (T.unpack usage) >> exitFailure
    Right (given, rest) -> case rest of
      ["--args-from", file] -> fromFile given file
      ["--help"] -> T.putStr usage
      [] -> wizard given
      _ -> hPutStrLn stderr (T.unpack usage) >> exitFailure

-- | The options for a machine that installs nothing from the internet,
-- which toolchain/configure.sh also gives the bootstrap that installs the
-- wizard's compiler: --system-tools, --hackage-mirror URL and
-- --npm-registry URL, as answers (system_tools, hackage_mirror,
-- npm_registry). They are applied over the deployment's state, so that the
-- screens start with them, and before an answer file's lines, which win.
-- The rest of the arguments are returned as they are.
presetArgs :: [String] -> Either String ([(Text, Text)], [String])
presetArgs args = do
  (ps, rest) <- go [] [] args
  -- Checked once here, so that applying them to a deployment's answers
  -- (loadDeployment) cannot fail later.
  case foldM applyAnswer defaultAnswers ps of
    Left e -> Left (T.unpack e)
    Right _ -> Right (ps, rest)
  where
    go ps rest [] = Right (reverse ps, reverse rest)
    go ps rest (arg : more) = case arg of
      "--system-tools" -> go (("system_tools", "yes") : ps) rest more
      "--hackage-mirror" -> withValue "hackage_mirror" more
      "--npm-registry" -> withValue "npm_registry" more
      _
        | Just v <- T.stripPrefix "--hackage-mirror=" (T.pack arg) -> go (("hackage_mirror", v) : ps) rest more
        | Just v <- T.stripPrefix "--npm-registry=" (T.pack arg) -> go (("npm_registry", v) : ps) rest more
        | otherwise -> go ps (arg : rest) more
      where
        withValue key (v : after) = go ((key, T.pack v) : ps) rest after
        withValue _ [] = Left (arg <> " needs a URL")

usage :: Text
usage =
  T.unlines
    [ "usage: sh toolchain/configure.sh [--system-tools] [--hackage-mirror URL] [--npm-registry URL] [--args-from FILE]"
    , ""
    , "Asks for the options of toolchain/deploy-local.sh in a few screens and runs"
    , "the deploy with them. With --args-from FILE it reads the answers from FILE"
    , "(key=value lines; see the header of toolchain/configure.hs) and prints the"
    , "command line instead. --system-tools, --hackage-mirror and --npm-registry,"
    , "for a machine that installs nothing from the internet, are given to the"
    , "bootstrap that installs the wizard's compiler, and start the wizard's"
    , "screens with those answers."
    ]

-- | A deployment's answers: its state over the answers given (prefill),
-- then the presets of the wrapper's options (presetArgs, which has checked
-- that they apply). The first screen, the start of the wizard and an
-- answer file all load a deployment through this, so that the presets
-- reach whichever deployment is chosen.
loadDeployment :: [(Text, Text)] -> Answers -> IO (Answers, Text)
loadDeployment ps given = do
  (filled, n) <- prefill given
  pure (either (const filled) id (foldM applyAnswer filled ps), n)

-- | The answers of a file, over the state of the deployment it names, and
-- the command line they make.
fromFile :: [(Text, Text)] -> FilePath -> IO ()
fromFile given file = do
  -- The file is named from where toolchain/configure.sh was started.
  path <- T.unpack <$> absolute (T.pack file)
  kv <- keyValues <$> T.readFile path
  let named = defaultAnswers {name = value "name" kv (name defaultAnswers), prefix = value "prefix" kv ""}
  (filled, n) <- loadDeployment given named
  hPutStrLn stderr ("configure: " <> T.unpack n)
  case foldM applyAnswer filled kv of
    Left e -> hPutStrLn stderr ("configure: " <> file <> ": " <> T.unpack e) >> exitFailure
    Right answered -> do
      a <- normalise <$> resolvePaths answered
      let ps = problems a
      unless (null ps) $ do
        mapM_ (hPutStrLn stderr . ("configure: " <>) . T.unpack) ps
        exitFailure
      T.putStrLn (commandLine a)
  where
    value key kv def = fromMaybe def (lookup key (reverse kv))

-- | The screens, and then the deploy or the command line.
wizard :: [(Text, Text)] -> IO ()
wizard given = do
  there <- doesFileExist "toolchain/deploy-local.sh"
  unless there $ do
    hPutStrLn stderr "configure: run this from the checkout's root, where toolchain/deploy-local.sh is (sh toolchain/configure.sh does)"
    exitFailure
  (a, n) <- loadDeployment given defaultAnswers
  let start =
        Wizard
          { screen = Which
          , form = formFor Which a
          , filledFrom = (name a, prefix a)
          , note = n
          , ending = Running
          , presets = given
          }
  end <- defaultMain app start
  let final = normalise (answers end)
  case ending end of
    Run -> do
      resolved <- resolvePaths final
      T.putStrLn ("configure: " <> commandLine resolved)
      executeFile "/bin/sh" False (map T.unpack ("toolchain/deploy-local.sh" : deployArgs resolved)) Nothing
    Quit -> do
      resolved <- resolvePaths final
      T.putStrLn (commandLine resolved)
    _ -> pure ()
