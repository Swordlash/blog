-- | The system packages the wiki's builds need besides what GHC itself
-- needs. @toolchain/bootstrap.sh@ installs GHC's own (a C toolchain, GMP's
-- development files, curl, tar and xz) before it builds the maker; the
-- maker installs the rest here, first of every mode: git (cabal fetches
-- haskell-halogen with it), pkg-config, the C libraries wiki-server links
-- (zlib, libsodium, libpq unless the build has no PostgreSQL, ncurses for
-- the configuration wizard), and what ghc-wasm-meta's setup runs (jq,
-- unzip, zstd) in the modes that install the wasm toolchain.
--
-- On Debian or Ubuntu the packages that are missing are installed with
-- apt-get, as root or through a sudo that needs no password; the bootstrap
-- never asks for one, and without root it names the packages and stops.
-- Elsewhere nothing is installed: the native mode's check, which runs next,
-- names what is missing, and the other modes check the commands the wasm
-- toolchain's setup runs.
module Maker.Toolchain.Debian
  ( debianPackages
  , systemPackages
  )
where

import Control.Monad (filterM, unless)
import Data.List (isInfixOf)
import Data.Maybe (isNothing)
import Maker.Context
import Maker.Log
import Maker.Process (found, output)
import System.Exit (ExitCode (..), exitWith)

-- | The Debian packages a mode needs from the maker. The native mode builds
-- wiki-server alone, and runs none of the wasm toolchain's setup.
debianPackages :: Context -> [String]
debianPackages ctx =
  base
    <> ["libsodium-dev", "pkg-config", "zlib1g-dev"]
    <> ["libpq-dev" | ctx.postgres]
    <> ["libncurses-dev" | ctx.wizard]
  where
    base = case ctx.mode of
      Native -> ["git"]
      _ -> ["git", "jq", "unzip", "zstd"]

-- | Install the mode's Debian packages that are missing, or on another
-- system check the wasm setup's commands. Stops the run, saying why, when
-- something is missing and cannot be installed.
systemPackages :: Context -> IO ()
systemPackages ctx = do
  dpkg <- found "dpkg-query"
  case dpkg of
    Nothing
      | ctx.mode == Native -> pure ()
      | otherwise -> do
          missing <- filterM (fmap isNothing . found) ["git", "jq", "unzip", "unzstd"]
          unless (null missing) $ do
            say ctx ("missing commands:" <> concatMap (' ' :) missing <> "; install them and run this again")
            exitWith (ExitFailure 1)
    Just _ -> do
      missing <- filterM (fmap not . installed) (debianPackages ctx)
      unless (null missing) $ do
        let names = concatMap (' ' :) missing
        root <- asRoot
        case root of
          Nothing -> do
            say ctx ("missing Debian packages:" <> names <> "; install them (sudo apt-get install" <> names <> ") and run this again")
            exitWith (ExitFailure 1)
          Just sudo -> do
            say ctx ("installing Debian packages:" <> names)
            let apt = sudo <> ["env", "DEBIAN_FRONTEND=noninteractive", "apt-get"]
            -- A failing third-party source should not stop the Ubuntu
            -- archive's lists from updating; the install below fails by
            -- itself if what it needs is not there.
            logLine ctx ("+ " <> command (apt <> ["update"]))
            _ <- runQuiet ctx (apt <> ["update"])
            run ctx "installing Debian packages" (apt <> ["install", "--yes", "--no-install-recommends"] <> missing)
  where
    installed pkg = do
      status <- output "dpkg-query" ["-W", "-f", "${Status}", pkg]
      pure (maybe False ("install ok installed" `isInfixOf`) status)
