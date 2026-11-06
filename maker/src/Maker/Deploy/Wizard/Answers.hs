-- | The answers of the deploy's configuration wizard: what it asks for,
-- the first run's defaults, what a deployment's state file gives, and the
-- answer file of @--args-from@. The wizard itself, the screens, is
-- @maker-tui deploy@ ("Maker.Tui.Deploy"); "Maker.Deploy.Wizard.Command"
-- turns the answers into the deploy's command line, and
-- "Maker.Deploy.Wizard.Load" fills them from a deployment's state.
--
-- An answer file holds key=value lines; blank lines and lines starting
-- with # are skipped. The keys:
--
-- >   action=deploy|status|stop|rollback   name=NAME   prefix=DIR
-- >   mode=server|static            backend_only=|head|REF
-- >   db=postgres|sqlite            db_port=N
-- >   texlive=machine|toolchain|none  texlive_mirror=URL
-- >   texlive_installer=URL|DIR  perl_source=URL|DIR
-- >   way=tailscale|cert|proxy|http tls_cert=FILE  tls_key=FILE  tls_ca=FILE
-- >   port=N  bind=ADDRESS  admin_port=N  toolchain=DIR
-- >   fresh|refresh_page|no_build|no_firewall|enable_linger=yes|no
-- >   whats_new=yes|no              semaphore=probe|on|off
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
-- whats_new is whether the server shows the page "What's new?": yes (no
-- option, unless the state remembers no, which --whats-new forgets) or no
-- (--no-whats-new). texlive_installer and perl_source are the git
-- repositories (or directories) TeX Live's installer and Perl's source
-- come from, when not from their GitHub mirrors; the deploy does not
-- remember them, so the state file does not give them.
module Maker.Deploy.Wizard.Answers
  ( Action (..)
  , Mode (..)
  , Page (..)
  , Database (..)
  , TexChoice (..)
  , Semaphore (..)
  , Way (..)
  , Answers (..)
  , defaultAnswers
  , fromState
  , applyAnswer
  , keyValues
  , normalise
  , presetArgs
  )
where

import Control.Monad (foldM)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T

-- * The answers

-- | What the wizard is asked to do with the deployment.
data Action = Deploy | Status | Stop | Rollback
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
  , whatsNew :: Bool
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
  , rememberedNoWhatsNew :: Bool
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
    , whatsNew = True
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
    , rememberedNoWhatsNew = False
    }

-- | The answers a deployment's state file gives: what the deploy would
-- take from it when run without options. The name and the prefix stay as
-- they are, since they are how the file was found.
fromState :: [(Text, Text)] -> Answers -> Answers
fromState kv a =
  a
    { mode = if value "mode" == "server" then Server else Demo
    , whatsNew = value "whats_new" /= "no"
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
    , dbPort = orKeep (a.dbPort) (value "db_port")
    , tex = case value "texlive" of
        "yes" -> ToolchainTex
        "no" -> NoTex
        _ -> MachineTex
    , texMirror = value "texlive_mirror"
    , way = remembered
    , tlsCert = if remembered == Certificate then value "tls_cert" else ""
    , tlsKey = if remembered == Certificate then value "tls_key" else ""
    , tlsCa = if remembered == Certificate then value "tls_ca" else ""
    , port = orKeep (a.port) (value "port")
    , -- An address the deploy chose itself (bind_choice=auto) is chosen
      -- again on the next run, so it is not an answer.
      bind = if value "bind_choice" == "explicit" then value "bind" else ""
    , adminPort = orKeep (a.adminPort) (value "admin_port")
    , toolchain = value "toolchain"
    , rememberedDownload = not (T.null backendOnly) || not (T.null appPageFile)
    , rememberedCa = remembered == Certificate && not (T.null (value "tls_ca"))
    , rememberedTexLive = value "texlive" == "yes"
    , rememberedBundle = value "bundle_locally" == "yes"
    , rememberedSystemTools = value "system_tools" == "yes"
    , rememberedNpmRegistry = not (T.null (value "npm_registry"))
    , rememberedHackageMirror = not (T.null (value "hackage_mirror"))
    , rememberedNoWhatsNew = value "whats_new" == "no"
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
  "action" -> pick (\x -> a {action = x}) [("deploy", Deploy), ("status", Status), ("stop", Stop), ("rollback", Rollback)]
  "name" -> Right a {name = v}
  "prefix" -> Right a {prefix = v}
  "mode" -> pick (\x -> a {mode = x}) [("server", Server), ("static", Demo)]
  "whats_new" -> yesNo (\x -> a {whatsNew = x})
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
  | a.mode == Demo && a.way == Certificate = a {way = Tailscale}
  | otherwise = a

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
