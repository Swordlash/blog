-- | The maker's command line. Its commands are what the toolchain's scripts
-- run and what a developer asks for:
--
-- > maker bootstrap MODE --root DIR …    the bootstrap's second stage (toolchain/bootstrap.sh runs it)
-- > maker status                        the toolchain, component by component
-- > maker toolchain install [TARGET…]   install components (all a developer needs when none is named)
--
-- @toolchain/maker.sh@ builds the maker with its own cabal project and runs
-- it, and also starts the terminal interface (@toolchain/maker.sh tui@).
module Maker.Cli
  ( Command (..)
  , Bootstrap (..)
  , parser
  , parseArgs
  , main
  , contextFromEnvironment
  )
where

import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Maker.Context
import Maker.Log (say, withLock)
import Maker.Pins (readPins)
import Maker.Process (firstLine, found, output)
import Maker.Rules
import Maker.Status (ready, render, status)
import Options.Applicative
import System.Directory (canonicalizePath, getCurrentDirectory, getHomeDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering, stdout)

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
  }
  deriving (Eq, Show)

-- | A command of the maker.
data Command
  = RunBootstrap Bootstrap
  | Status (Maybe FilePath)
  | Install (Maybe FilePath) [Target]
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
        )
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
  pure Context {root = root', base = base', namedBase = isNamed, ghcupBin = ghcupBin', pins = pins', mode = mode'}
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
      let ctx = Context {root = b.root, base = b.base, namedBase = b.namedBase, ghcupBin = b.ghcupBin, pins = pins', mode = b.mode}
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
