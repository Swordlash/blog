-- | Chromium's headless shell for Playwright: the browser the project's
-- Playwright (the version package-lock.json names, or the pin before there
-- is one) asks for, installed by that Playwright. It is kept in an npm
-- prefix of its own under the toolchain's directory, so that this works
-- before (and without) the project's node_modules.
module Maker.Toolchain.Chromium
  ( Playwright (..)
  , playwrightLocation
  , chromiumCached
  , chromiumLocation
  , installChromium
  )
where

import Control.Monad (unless, when)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import System.Directory
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))

-- | Which Playwright installs and finds the browser: its version, the npm
-- prefix it is (or is to be) installed under, and its command line, when an
-- installation of that version is there.
data Playwright = Playwright
  { version :: String
  , prefix :: FilePath
  , cli :: Maybe FilePath
  }

-- | The Playwright the tests run with: the project's own when it is the
-- lockfile's version, else a private one under the toolchain's directory. A
-- stale private installation is replaced; a project's other version is left
-- alone, since the lockfile decides which Chromium the tests need.
playwrightLocation :: Context -> IO Playwright
playwrightLocation ctx = do
  let lockfile = ctx.root </> "package-lock.json"
  hasLock <- doesFileExist lockfile
  node <- found "node"
  locked <-
    if hasLock && node /= Nothing
      then
        fromMaybe ""
          <$> output
            "node"
            [ "-e"
            , "const p=require(process.argv[1]); process.stdout.write(p.packages?.[\"node_modules/playwright-core\"]?.version || \"\")"
            , lockfile
            ]
      else pure ""
  let version' = if null locked then ctx.pins.playwrightVersion else locked
      private = stateDir ctx </> ("playwright-" <> version')
      matches candidate = do
        let core = candidate </> "node_modules" </> "playwright-core"
        hasCli <- doesFileExist (core </> "cli.js")
        if not hasCli
          then pure False
          else do
            said <- output "node" ["-p", "require(process.argv[1]).version", core </> "package.json"]
            pure (fmap firstLine said == Just version')
  inProject <- matches ctx.root
  inPrivate <- if inProject then pure False else matches private
  pure $ case () of
    _
      | inProject -> Playwright version' ctx.root (Just (ctx.root </> "node_modules/playwright-core/cli.js"))
      | inPrivate -> Playwright version' private (Just (private </> "node_modules/playwright-core/cli.js"))
      | otherwise -> Playwright version' private Nothing

-- | Where Playwright says its Chromium goes, asked without installing.
chromiumLocation :: FilePath -> IO (Maybe String)
chromiumLocation cliPath = do
  said <- output "node" [cliPath, "install", "--dry-run", "--only-shell", "chromium"]
  pure $ listToMaybe (mapMaybe location (lines (fromMaybe "" said)))
  where
    location l = case dropWhile (== ' ') l of
      rest | "Install location:" `isPrefixOf` rest -> Just (dropWhile (== ' ') (drop (length ("Install location:" :: String)) rest))
      _ -> Nothing

-- | Whether the browser is in Playwright's cache, complete and executable.
-- Playwright's own registry knows the platform, the revision and the
-- archive's layout (it renamed the executable once), so it is asked rather
-- than the layout being written here. Nothing is launched.
chromiumCached :: FilePath -> IO Bool
chromiumCached prefix' =
  succeeds
    "node"
    [ "-e"
    , unlines
        [ "const fs = require(\"node:fs\");"
        , "const path = require(\"node:path\");"
        , "const root = process.argv[1];"
        , "const bundled = path.join(root, \"lib/coreBundle.js\");"
        , "const { registry } = fs.existsSync(bundled)"
        , "  ? require(bundled).registry"
        , "  : require(path.join(root, \"lib/server/registry/index.js\"));"
        , "const browser = registry.findExecutable(\"chromium-headless-shell\");"
        , "fs.accessSync(path.join(browser.directory, \"INSTALLATION_COMPLETE\"), fs.constants.R_OK);"
        , "fs.accessSync(browser.executablePath(), fs.constants.X_OK);"
        ]
    , prefix' </> "node_modules" </> "playwright-core"
    ]

-- | Install Playwright (privately, when the project has no matching one)
-- and its Chromium, then launch the browser: a cache cannot prove that
-- today's shared libraries still let it start. When it does not start,
-- Playwright installs the Debian packages it needs if this can run it as
-- root, and otherwise they are named and the run stops. Answers where the
-- browser is.
installChromium :: Context -> IO String
installChromium ctx = do
  pw <- playwrightLocation ctx
  cliPath <- case pw.cli of
    Just path -> pure path
    Nothing -> do
      say ctx ("installing playwright-core " <> pw.version <> " into " <> pw.prefix)
      removePath pw.prefix
      run
        ctx
        "installing playwright-core"
        ["npm", "install", "--prefix", pw.prefix, "--no-save", "--no-audit", "--no-fund", "playwright-core@" <> pw.version]
      pure (pw.prefix </> "node_modules/playwright-core/cli.js")
  location <- chromiumLocation cliPath
  where' <- maybe (failStep ctx ("asking Playwright " <> pw.version <> " where Chromium goes")) pure location
  cached <- chromiumCached pw.prefix
  unless cached $ do
    say ctx ("installing Chromium (headless shell) for Playwright " <> pw.version <> " into " <> where')
    run ctx "installing Chromium" ["node", cliPath, "install", "--only-shell", "chromium"]
  started <- launch pw.prefix
  unless started $ do
    root' <- asRoot
    case root' of
      Nothing -> do
        say ctx ("Chromium does not start (the end of " <> logFile ctx <> " says why); the Debian packages Playwright would install or upgrade for it:")
        deps <- fromMaybe "" <$> output "node" [cliPath, "install-deps", "--dry-run", "chromium"]
        mapM_ (putStrLn . ("bootstrap:   " <>)) (lines deps)
        say ctx "install them (sudo apt-get install ...) and run this again"
        exitWith (ExitFailure 1)
      Just sudo -> do
        say ctx "installing the Debian packages Chromium needs"
        node <- fromMaybe "node" <$> found "node"
        run ctx "installing Chromium's Debian packages" (sudo <> [node, cliPath, "install-deps", "chromium"])
        again <- launch pw.prefix
        when (not again) (failStep ctx "launching Chromium")
  pure where'
  where
    launch prefix' = do
      logLine ctx "+ launch Chromium"
      code <-
        runQuiet
          ctx
          [ "node"
          , "-e"
          , "const { chromium } = require(process.argv[1]); chromium.launch().then((browser) => browser.close());"
          , prefix' </> "node_modules" </> "playwright-core"
          ]
      pure (code == ExitSuccess)
