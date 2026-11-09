-- | The maker's command line. Its commands are what the toolchain's scripts
-- run and what a developer asks for:
--
-- > maker bootstrap MODE --root DIR …    the bootstrap's second stage (toolchain/bootstrap.sh runs it)
-- > maker status                        the toolchain, component by component
-- > maker toolchain install [TARGET…]   install components (all a developer needs when none is named)
-- > maker build native|wasm|wasm-opt [CABAL-ARG…]   the builds (npm run build-native, build-wasm, build-wasm-opt)
-- > maker test native|wasm|all [CABAL-ARG…]         the tests (npm run test-native, test-wasm, test)
-- > maker serve [CABAL-ARG…]                        build the application and serve it (npm run serve)
-- > maker hspec-halogen                              build the browser tests' runner and print its path
-- > maker check native [--without-postgres] [--with-wizard] [--without-tex]   what the native build needs
-- > maker deploy [OPTION…]            the deploy, with toolchain/deploy-local.sh's options (it runs this)
--
-- @toolchain/maker.sh@ builds the maker with its own cabal project and runs
-- it, and also starts the terminal interface (@toolchain/maker.sh tui@).
module Maker.Cli
  ( Command (..)
  , Bootstrap (..)
  , BuildTarget (..)
  , TestTarget (..)
  , parser
  , parseArgs
  , main
  , contextFromEnvironment
  )
where

import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Maker.Build.Env (buildEnv)
import Maker.Build.Native (buildNative, testNative)
import Maker.Build.Wasm (buildWasm, hspecHalogen, serveWasm, testWasm, wasmBuildFrom)
import Maker.Check.Native qualified as Check
import Maker.Context
import Maker.Deploy.Front qualified as Front
import Maker.Log (say, withLock)
import Maker.Pins (readPins)
import Maker.Process (firstLine, found, output)
import Maker.Rules
import Maker.Status (ready, render, status)
import Options.Applicative
import System.Directory (canonicalizePath, getCurrentDirectory, getHomeDirectory, makeAbsolute)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)

-- | How the bootstrap hands over to the maker.
data Bootstrap = Bootstrap
  { mode :: Mode
  , root :: FilePath
  , base :: FilePath
  , namedBase :: Bool
  , ghcupBin :: FilePath
  , logSizeBefore :: Integer
  , started :: Integer
  , lockFd :: Maybe Int
  , withoutPostgres :: Bool
  , withWizard :: Bool
  , systemTools :: Bool
  , libsodiumSource :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | What @maker build@ builds.
data BuildTarget = BuildNative | BuildWasm | BuildWasmOpt
  deriving (Eq, Show)

-- | What @maker test@ runs.
data TestTarget = TestNative | TestWasm | TestAll
  deriving (Eq, Show)

-- | A command of the maker. The builds' and tests' arguments go to cabal
-- after the maker's own, as the npm scripts passed theirs.
data Command
  = RunBootstrap Bootstrap
  | Status (Maybe FilePath)
  | Install (Maybe FilePath) [Target]
  | RunBuild BuildTarget [String]
  | RunTest TestTarget [String]
  | Serve [String]
  | HspecHalogen
  | CheckNative (Maybe FilePath) Check.Options
  | Deploy [String]
  deriving (Eq, Show)

-- | The command line's parser.
parser :: ParserInfo Command
parser =
  info
    (commands <**> helper)
    (fullDesc <> progDesc "The wiki's toolchain and builds (docs/PLAN.md, WP5.68)" <> header "maker")
  where
    commands =
      hsubparser
        ( command "bootstrap" (info (RunBootstrap <$> bootstrapOptions) (progDesc "The second stage of toolchain/bootstrap.sh, which runs it"))
            <> command "status" (info (Status <$> rootOption) (progDesc "The toolchain, component by component; installs nothing"))
            <> command
              "toolchain"
              ( info
                  (hsubparser (command "install" (info installOptions (progDesc "Install the components named, or all a developer needs"))))
                  (progDesc "The toolchain's components")
              )
            <> command
              "build"
              ( info
                  ( hsubparser
                      ( passing "native" (RunBuild BuildNative) "Every package with the host GHC (npm run build-native)"
                          <> passing "wasm" (RunBuild BuildWasm) "The browser application and its pages (npm run build-wasm)"
                          <> passing "wasm-opt" (RunBuild BuildWasmOpt) "The -O2 production build of the application (npm run build-wasm-opt)"
                      )
                  )
                  (progDesc "The builds")
              )
            <> command
              "test"
              ( info
                  ( hsubparser
                      ( passing "native" (RunTest TestNative) "The native test suites of WIKI_TEST_GROUP (npm run test-native)"
                          <> passing "wasm" (RunTest TestWasm) "The test suites on wasm, browser suites in Chromium (npm run test-wasm)"
                          <> passing "all" (RunTest TestAll) "Native, then wasm (npm run test)"
                      )
                  )
                  (progDesc "The tests")
              )
            <> passing "serve" Serve "Build the application and serve it on PORT, default 8080 (npm run serve)"
            <> command "hspec-halogen" (info (pure HspecHalogen) (progDesc "Build the browser tests' runner and print its path"))
            <> command
              "deploy"
              ( info
                  (Deploy <$> many (strArgument (metavar "OPTION…")))
                  (forwardOptions <> progDesc "Deploy the wiki on this machine, with toolchain/deploy-local.sh's options (sh toolchain/deploy-local.sh --help lists them)")
              )
            <> command
              "check"
              ( info
                  (hsubparser (command "native" (info checkNativeOptions (progDesc "What the native build of wiki-server needs from the machine; installs nothing"))))
                  (progDesc "The machine's checks")
              )
        )
    -- A command whose remaining arguments, options included, go to cabal.
    passing name make what =
      command name (info (make <$> many (strArgument (metavar "CABAL-ARG"))) (progDesc what <> forwardOptions))
    rootOption = optional (strOption (long "root" <> metavar "DIR" <> help "The repository (default: the current directory)"))
    installOptions = Install <$> rootOption <*> many (argument targetReader (metavar "TARGET" <> help targetsHelp))
    targetsHelp = "One of: " <> unwords (map targetName [minBound .. maxBound])
    targetReader = maybeReader (\s -> lookup s [(targetName t, t) | t <- [minBound .. maxBound]])
    bootstrapOptions =
      Bootstrap
        <$> argument modeReader (metavar "MODE")
        <*> strOption (long "root" <> metavar "DIR")
        <*> strOption (long "base" <> metavar "DIR")
        <*> switch (long "named-base")
        <*> strOption (long "ghcup-bin" <> metavar "DIR")
        <*> option auto (long "log-size" <> metavar "BYTES")
        <*> option auto (long "started" <> metavar "SECONDS")
        <*> optional (option auto (long "lock-fd" <> metavar "FD"))
        <*> switch (long "without-postgres" <> help "wiki-server is built without PostgreSQL: no libpq")
        <*> switch (long "with-wizard" <> help "The configuration wizard is built too: terminfo")
        <*> switch (long "system-tools" <> help "GHC and cabal are the machine's own")
        <*> optional (strOption (long "libsodium-source" <> metavar "FILE" <> help "libsodium's release tarball, used instead of a download"))
    checkNativeOptions =
      (\r p w t -> CheckNative r Check.Options {postgres = not p, wizard = w, tex = not t})
        <$> rootOption
        <*> switch (long "without-postgres" <> help "For a build without PostgreSQL, which needs no libpq")
        <*> switch (long "with-wizard" <> help "Also terminfo, which the configuration wizard links")
        <*> switch (long "without-tex" <> help "Do not try xelatex (the deploy's TeX step tries it)")
    modeReader = maybeReader (\s -> lookup s [(modeName m, m) | m <- [minBound .. maxBound]])

-- | Parse arguments as the maker does, for the tests.
parseArgs :: [String] -> Maybe Command
parseArgs = getParseResult . execParserPure defaultPrefs parser

-- | The context of a command run by hand: the paths computed as the
-- bootstrap computes them.
contextFromEnvironment :: Maybe FilePath -> Mode -> IO Context
contextFromEnvironment rootArg mode' = do
  root' <- maybe getCurrentDirectory makeAbsolute rootArg
  home <- getHomeDirectory
  named <- lookupEnv "WIKI_TOOLCHAIN_HOME"
  base' <- maybe (pure home) makeAbsolute (nonEmpty named)
  isNamed <- case nonEmpty named of
    Nothing -> pure False
    Just dir -> (/=) <$> canonicalizePath dir <*> canonicalizePath home
  ghcupBin' <-
    if isNamed
      then pure (base' </> ".ghcup" </> "bin")
      else do
        onPath <- found "ghcup"
        case onPath of
          Just g -> maybe (pure (home </> ".ghcup" </> "bin")) (pure . firstLine) =<< output g ["whereis", "bindir"]
          Nothing -> do
            prefix <- lookupEnv "GHCUP_INSTALL_BASE_PREFIX"
            pure (fromMaybe home (nonEmpty prefix) </> ".ghcup" </> "bin")
  pins' <- readPins root'
  pure
    Context
      { root = root'
      , base = base'
      , namedBase = isNamed
      , ghcupBin = ghcupBin'
      , pins = pins'
      , mode = mode'
      , postgres = True
      , wizard = False
      , systemTools = False
      , libsodiumSource = Nothing
      }
  where
    nonEmpty = \case
      Just "" -> Nothing
      other -> other

-- | The maker's entry point.
main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  cmd <- execParser parser
  case cmd of
    RunBootstrap b -> do
      pins' <- readPins b.root
      let ctx =
            Context
              { root = b.root
              , base = b.base
              , namedBase = b.namedBase
              , ghcupBin = b.ghcupBin
              , pins = pins'
              , mode = b.mode
              , postgres = not b.withoutPostgres
              , wizard = b.withWizard
              , systemTools = b.systemTools
              , libsodiumSource = b.libsodiumSource
              }
      bootstrap ctx b.lockFd b.logSizeBefore b.started
    Status rootArg -> do
      ctx <- contextFromEnvironment rootArg Toolchain
      components <- status ctx
      putStr (render components)
      unless (all ready components) exitFailure
    Install rootArg targets -> do
      ctx <- contextFromEnvironment rootArg Toolchain
      let wanted = if null targets then targetsFor Toolchain else targets
      withLock ctx (stateDir ctx </> "toolchain.lock") "the toolchain" $ do
        _ <- runTargets ctx wanted
        say ctx ("installed or checked: " <> unwords (map targetName wanted))
    RunBuild target args -> do
      be <- buildEnv
      case target of
        BuildNative -> buildNative be args
        BuildWasm -> wasmBuild False >>= \wb -> buildWasm be wb args
        BuildWasmOpt -> wasmBuild True >>= \wb -> buildWasm be wb args
    RunTest target args -> do
      be <- buildEnv
      case target of
        TestNative -> testNative be args
        TestWasm -> testWasm be args
        TestAll -> do
          putStrLn "Running native"
          testNative be args
          putStrLn "Running wasm"
          testWasm be args
    Serve args -> do
      be <- buildEnv
      wb <- wasmBuild False
      serveWasm be wb args
    HspecHalogen -> buildEnv >>= hspecHalogen >>= putStrLn
    Deploy args -> do
      -- The checkout the deploy runs from: toolchain/deploy-local.sh names
      -- it, since the deploy runs in the directory it was started in, from
      -- which relative paths are taken.
      root' <- maybe getCurrentDirectory pure =<< lookupEnv "WIKI_DEPLOY_ROOT"
      Front.deploy root' args
    CheckNative rootArg options -> do
      root' <- maybe getCurrentDirectory makeAbsolute rootArg
      (report, ok) <- Check.checkNative root' options
      putStr (unlines report)
      unless ok exitFailure
  where
    -- The build the environment describes, or the maker stops with status 2
    -- and the reason, as the build script did.
    wasmBuild optimised = do
      environment <- getEnvironment
      case wasmBuildFrom optimised (`lookup` environment) of
        Right wb -> pure wb
        Left message -> do
          hPutStrLn stderr ("maker: " <> message)
          exitWith (ExitFailure 2)
