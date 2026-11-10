-- | The deploy's configuration wizard, @maker-tui deploy@: a terminal
-- application that asks for toolchain/deploy-local.sh's options in a few
-- screens and builds the deploy's command line from the answers. Run it
-- through its wrapper, from anywhere:
--
-- >   sh toolchain/configure.sh
--
-- The wrapper checks the machine (toolchain/check-native.sh), installs GHC
-- and cabal (toolchain/bootstrap.sh native), and runs
-- @toolchain/maker.sh tui deploy@ from the checkout's root with its own
-- arguments:
--
-- >   maker-tui deploy [--system-tools] [--hackage-mirror URL] [--npm-registry URL] [--args-from FILE]
--
-- --system-tools, --hackage-mirror URL and --npm-registry URL are the
-- deploy's options for a machine that installs nothing from the internet.
-- The wrapper gives them to the bootstrap that installs GHC and cabal for
-- the wizard, and the wizard takes them as answers over the state
-- ('presetArgs'), so that its screens start with them.
--
-- The screens: what to do (deploy, --status, --stop, --rollback or
-- --move-to-postgres) and which deployment (--name, --prefix); what to
-- deploy (--server or --static); where the page comes from (built here,
-- --backend-only, or --app-page, with --bundle-locally); where the
-- toolchain and the packages come from (--system-tools, --npm-registry,
-- --hackage-mirror); the database and the TeX of the PDF exports (server
-- only); how it is reached (the ways of HTTPS, or plain HTTP); the address
-- (port, bind address, admin port); the extras. The answers start from
-- the deployment's state file, found by prefix and name as the deploy
-- finds it, so that a rerun is Enter through every screen. The last
-- screen shows the command line: Enter runs it (the wizard replaces itself
-- with /bin/sh toolchain/deploy-local.sh, so the deploy's output reaches
-- the terminal and its exit status is the wizard's), and q quits and
-- prints the command line for copying.
--
-- With --args-from FILE the wizard shows no screens: it reads answers from
-- FILE ("Maker.Deploy.Wizard.Answers" lists the keys), prints the command
-- line it would run, and exits ("Maker.Deploy.Wizard.Load"). Answers that
-- the deploy would refuse are printed on standard error, and the wizard
-- exits 1.
module Maker.Tui.Deploy (run) where

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
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Graphics.Vty qualified as V
import Lens.Micro (Lens', lens)
import Maker.Deploy.Wizard.Answers
import Maker.Deploy.Wizard.Command
import Maker.Deploy.Wizard.Load
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Process (executeFile)

-- | The wizard's command line: the presets, then --args-from FILE, --help,
-- or nothing for the screens.
run :: [String] -> IO ()
run args =
  case presetArgs args of
    Left e -> hPutStrLn stderr ("configure: " <> e) >> hPutStrLn stderr (T.unpack usage) >> exitFailure
    Right (given, rest) -> case rest of
      ["--args-from", file] -> fromFile given file
      ["--help"] -> T.putStr usage
      [] -> wizard given
      _ -> hPutStrLn stderr (T.unpack usage) >> exitFailure

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
  | WhatsNewField
  | PageChoice Page
  | RefField
  | RefreshField
  | AppPageField
  | BundleField
  | SystemToolsField
  | NpmRegistryField
  | HackageMirrorField
  | LibsodiumSourceField
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
  | NoRehearsalField
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
    , "For a machine that installs nothing from the internet: the machine's own compilers, mirrors for npm's and Hackage's packages, and libsodium's release tarball as a file. Empty and unticked, the deploy downloads them as usual."
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
        ( case a.action of
            Deploy -> "Build and install the deployment, or replace it with a new build. The next screens ask how."
            Status -> "Show the deployment, its service and its address, and change nothing."
            Stop -> "Stop and disable the service, remove its unit, close its port and turn its tailscale serve off. Its files and the wiki's data stay."
            Rollback -> "Put back the server deployment the last upgrade replaced, with its database as the backup made before the upgrade: what was written since is lost. The deploy says what comes back, and asks first."
            MoveToPostgres -> "Move the wiki of a server deployment on SQLite into PostgreSQL in Docker, accounts, settings and all, and switch the deployment to it: the service stops for the copy and a comparison, and starts again on PostgreSQL, or on SQLite as it was if anything fails. The deployment must be at this checkout's commit. data/wiki.sqlite is set aside into data/replaced/, never deleted, and --rollback goes back to it."
        )
        actionL
        [ (Deploy, ActionChoice Deploy, "deploy")
        , (Status, ActionChoice Status, "--status  show it")
        , (Stop, ActionChoice Stop, "--stop  take it down")
        , (Rollback, ActionChoice Rollback, "--rollback  go back")
        , (MoveToPostgres, ActionChoice MoveToPostgres, "--move-to-postgres  move its wiki into PostgreSQL")
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
        ( case a.mode of
            Server -> "wiki-server, with the wiki's data on this machine in <directory>/data, and an admin listener on 127.0.0.1 for its administration."
            Demo -> "The serverless demo, served as static files: each visitor's wiki lives in their browser. A server's data already in the directory is kept."
        )
        modeL
        [ (Server, ModeChoice Server, "--server  the wiki's server")
        , (Demo, ModeChoice Demo, "--static  the demo")
        ]
    ]
      ++ [ check
             "The page \"What's new?\", linked at the bottom of the sidebar, shows the server's version and build date and what the last pull requests changed (the changelog entries it was built with). Unticked, the server runs with --no-whats-new: no page and no link. Ticked after that, the deploy gives --whats-new."
             whatsNewL
             WhatsNewField
             "show the page \"What's new?\" (--no-whats-new when unticked)"
         | a.mode == Server
         ]
  PageSource ->
    [ choice
        "The page"
        ( case a.page of
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
      ++ ( if a.page == Downloaded
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
         | a.page == FromFile
         ]
      ++ [ check
             "Of the page CI built, keep only what needs the wasm toolchain (app.wasm and the prerendered pages), and build its JavaScript and CSS bundles here with npm ci and web/bundle.sh, then compare the page with CI's file by file: the deploy says identical, or names every file that differs. Needs Node."
             bundleLocallyL
             BundleField
             "--bundle-locally  build its JavaScript and CSS bundles here"
         | a.page /= BuiltHere
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
    , text
        "--libsodium-source"
        "The release tarball of libsodium (libsodium-<version>.tar.gz, the version toolchain/pins.env pins), copied onto this machine, which the bootstrap builds instead of downloading it from download.libsodium.org or GitHub. Its checksum is checked against the pin, as a download's is. Needed only while libsodium is not built under the toolchain yet. Empty: downloaded. Not remembered."
        libsodiumSourceL
        LibsodiumSourceField
    ]
  DatabaseScreen ->
    [ choice
        "The database"
        ( case a.database of
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
         | a.database == Postgres
         ]
      ++ [ check
             "Over a data/wiki.sqlite this deployment cannot use (one of an older schema, or of SQLite when PostgreSQL is chosen), go on and move the file aside into data/replaced/<time>/ rather than stop. Export the wiki with the running server first, and import it after."
             freshL
             FreshField
             "--fresh  move an unusable database file aside"
         ]
      ++ [ choice
             "PDF exports"
             ( case a.tex of
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
         | a.tex == ToolchainTex
         ]
      ++ [ text
             "--texlive-installer"
             "Optional: the git repository TeX Live's installer is cloned from, an http:// or https:// URL, or a directory of this machine holding install-tl, used as it is. Empty: https://github.com/TeX-Live/installer, its official mirror. Not remembered."
             texInstallerL
             InstallerField
         | a.tex == ToolchainTex
         ]
      ++ [ text
             "--perl-source"
             "Optional, for a machine without a Perl that works: the git repository Perl's source is cloned from at its tag v5.44.0, an http:// or https:// URL, or a directory of this machine with that source, copied and built under the toolchain. Empty: https://github.com/Perl/perl5. Not remembered."
             perlSourceL
             PerlSourceField
         | a.tex == ToolchainTex
         ]
  Reach ->
    [ choice
        "The way"
        ( case a.way of
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
            ++ [(Certificate, WayChoice Certificate, "--tls-cert  a certificate of your own") | a.mode == Server]
            ++ [ (Proxy, WayChoice Proxy, "--behind-proxy  behind a reverse proxy")
               , (PlainHttp, WayChoice PlainHttp, "--http  plain HTTP")
               ]
        )
    ]
      ++ if a.way == Certificate
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
                 <> (if a.way == PlainHttp then "this machine's Tailscale address" else "the Tailscale address")
                 <> ", or the last run's choice. 0.0.0.0 listens everywhere."
             )
             bindL
             BindField
         | a.way `elem` [PlainHttp, Certificate]
         ]
      ++ [ text
             "--admin-port"
             "The port of the admin listener, on 127.0.0.1 only: the administration, for whoever is on this machine (from elsewhere through ssh -L)."
             adminPortL
             AdminPortField
         | a.mode == Server
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
             ( case a.semaphore of
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
         | a.mode == Server
         ]
      ++ [ check
             "With plain HTTP or a certificate the deploy opens the port in ufw on the Tailscale interface; this leaves the firewall alone."
             noFirewallL
             NoFirewallField
             "--no-firewall  leave the firewall alone"
         ]
      ++ [ check
             "An upgrade is rehearsed on a copy of the wiki before the running one changes: the old program serves the copy, the new one migrates it and checks it reads the same. This deploys without that, once."
             noRehearsalL
             NoRehearsalField
             "--no-rehearsal  deploy without rehearsing the upgrade"
         | a.mode == Server
         ]
      ++ [ check
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
actionL = lens (.action) (\a v -> a {action = v})

nameL, prefixL, pageRefL, dbPortL, texMirrorL, texInstallerL, perlSourceL, tlsCertL, tlsKeyL, tlsCaL, portL, bindL, adminPortL, toolchainL :: Lens' Answers Text
nameL = lens (.name) (\a v -> a {name = v})
prefixL = lens (.prefix) (\a v -> a {prefix = v})
pageRefL = lens (.pageRef) (\a v -> a {pageRef = v})
dbPortL = lens (.dbPort) (\a v -> a {dbPort = v})
texMirrorL = lens (.texMirror) (\a v -> a {texMirror = v})
texInstallerL = lens (.texInstaller) (\a v -> a {texInstaller = v})
perlSourceL = lens (.perlSource) (\a v -> a {perlSource = v})
tlsCertL = lens (.tlsCert) (\a v -> a {tlsCert = v})
tlsKeyL = lens (.tlsKey) (\a v -> a {tlsKey = v})
tlsCaL = lens (.tlsCa) (\a v -> a {tlsCa = v})
portL = lens (.port) (\a v -> a {port = v})
bindL = lens (.bind) (\a v -> a {bind = v})
adminPortL = lens (.adminPort) (\a v -> a {adminPort = v})
toolchainL = lens (.toolchain) (\a v -> a {toolchain = v})

appPageL, npmRegistryL, hackageMirrorL, libsodiumSourceL :: Lens' Answers Text
appPageL = lens (.appPage) (\a v -> a {appPage = v})
npmRegistryL = lens (.npmRegistry) (\a v -> a {npmRegistry = v})
hackageMirrorL = lens (.hackageMirror) (\a v -> a {hackageMirror = v})
libsodiumSourceL = lens (.libsodiumSource) (\a v -> a {libsodiumSource = v})

bundleLocallyL, systemToolsL :: Lens' Answers Bool
bundleLocallyL = lens (.bundleLocally) (\a v -> a {bundleLocally = v})
systemToolsL = lens (.systemTools) (\a v -> a {systemTools = v})

modeL :: Lens' Answers Mode
modeL = lens (.mode) (\a v -> a {mode = v})

pageL :: Lens' Answers Page
pageL = lens (.page) (\a v -> a {page = v})

databaseL :: Lens' Answers Database
databaseL = lens (.database) (\a v -> a {database = v})

texL :: Lens' Answers TexChoice
texL = lens (.tex) (\a v -> a {tex = v})

wayL :: Lens' Answers Way
wayL = lens (.way) (\a v -> a {way = v})

semaphoreL :: Lens' Answers Semaphore
semaphoreL = lens (.semaphore) (\a v -> a {semaphore = v})

refreshPageL, freshL, noBuildL, noFirewallL, noRehearsalL, enableLingerL, whatsNewL :: Lens' Answers Bool
whatsNewL = lens (.whatsNew) (\a v -> a {whatsNew = v})
refreshPageL = lens (.refreshPage) (\a v -> a {refreshPage = v})
freshL = lens (.fresh) (\a v -> a {fresh = v})
noBuildL = lens (.noBuild) (\a v -> a {noBuild = v})
noFirewallL = lens (.noFirewall) (\a v -> a {noFirewall = v})
noRehearsalL = lens (.noRehearsal) (\a v -> a {noRehearsal = v})
enableLingerL = lens (.enableLinger) (\a v -> a {enableLinger = v})

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
shape a = (a.action, a.mode, a.page, a.database, a.tex, a.way)

answers :: Wizard -> Answers
answers w = formState w.form

-- | The screen after this one, for the answers: the status and the stop
-- go straight to the command, and the demo has no database.
nextScreen :: Answers -> Screen -> Screen
nextScreen a s = case s of
  Which | a.action /= Deploy -> Command
  Sources | a.mode == Demo -> Reach
  Command -> Command
  _ -> succ s

previousScreen :: Answers -> Screen -> Screen
previousScreen a s = case s of
  Command | a.action /= Deploy -> Which
  Reach | a.mode == Demo -> Sources
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
    if w.screen == Which && w.filledFrom /= (a.name, a.prefix)
      then do
        -- Another deployment starts from the defaults, not from the
        -- answers of the one before, and the presets apply to it too.
        (filled, n) <- liftIO (loadDeployment (w.presets) defaultAnswers {action = a.action, name = a.name, prefix = a.prefix})
        -- Remembered as prefill resolved them, as the form now shows them,
        -- so that coming back to the first screen does not fill again.
        pure (filled, (filled.name, filled.prefix), n)
      else pure (a, w.filledFrom, w.note)
  put w {screen = s, form = formFor s a', filledFrom = from, note = n}

handleEvent :: BrickEvent Name () -> EventM Name Wizard ()
handleEvent ev = do
  w <- get
  let a = answers w
  case ev of
    VtyEvent (V.EvKey (V.KChar 'c') [V.MCtrl]) -> put w {ending = Abandon} >> halt
    VtyEvent (V.EvKey V.KEsc [])
      | w.screen == Which -> put w {ending = Abandon} >> halt
      | otherwise -> goTo (previousScreen a (w.screen))
    VtyEvent (V.EvKey V.KEnter [])
      | w.screen == Command ->
          if null (problems a) then put w {ending = Run} >> halt else pure ()
      | otherwise -> goTo (nextScreen a (w.screen))
    VtyEvent (V.EvKey (V.KChar 'q') [])
      | w.screen == Command -> put w {ending = Quit} >> halt
    _ | w.screen == Command -> pure ()
    _ -> do
      f <- nestEventM' (w.form) (handleFormEvent ev)
      let a' = formState f
      if shape a' == shape a
        then put w {form = f}
        else do
          -- Rebuilt, so that fields come and go with the choice; the
          -- focus stays on the field that had it.
          let rebuilt = formFor (w.screen) a'
              focused = focusGetCurrent (formFocus f)
          put w {form = maybe rebuilt (`setFormFocus` rebuilt) focused}

draw :: Wizard -> [Widget Name]
draw w =
  [ padLeft (Pad 1) . padTop (Pad 1) $
      vBox
        [ withAttr titleAttr (txt ("Configure a deployment (" <> progress <> "): " <> title))
        , if w.screen == Which then vBox [] else withAttr helpAttr (txtWrap (w.note))
        , padTop (Pad 1) (if T.null intro then vBox [] else hLimit 100 (txtWrap intro))
        , padTop (Pad 1) body
        , padTop (Pad 1) (withAttr helpAttr (txtWrap keys))
        ]
  ]
  where
    a = answers w
    (title, intro) = screenTitle (w.screen)
    steps = screensFor a
    progress = case lookup (w.screen) (zip steps [1 :: Int ..]) of
      Just i -> T.pack (show i) <> " of " <> T.pack (show (length steps))
      Nothing -> ""
    body = case w.screen of
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
      _ -> viewport Scroll Vertical (renderForm (w.form))
    keys = case w.screen of
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
          , filledFrom = (a.name, a.prefix)
          , note = n
          , ending = Running
          , presets = given
          }
  end <- defaultMain app start
  let final = normalise (answers end)
  case end.ending of
    Run -> do
      resolved <- resolvePaths final
      T.putStrLn ("configure: " <> commandLine resolved)
      executeFile "/bin/sh" False (map T.unpack ("toolchain/deploy-local.sh" : deployArgs resolved)) Nothing
    Quit -> do
      resolved <- resolvePaths final
      T.putStrLn (commandLine resolved)
    _ -> pure ()
