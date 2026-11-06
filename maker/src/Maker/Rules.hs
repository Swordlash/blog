-- | The toolchain as Shake rules: one rule per component, and the targets
-- each of the bootstrap's modes wants, in the order they are installed. A
-- component's rule checks for itself whether the component is there and
-- works, and installs it only when it is not, so a run that was interrupted
-- halfway is repaired by the next one. Shake keeps its database in the
-- toolchain's directory, where the builds' rules join it in the next phase
-- (docs/PLAN.md, WP5.68).
module Maker.Rules
  ( Target (..)
  , targetName
  , targetsFor
  , runTargets
  , bootstrap
  )
where

import Control.Exception (SomeException, fromException, throwIO, try)
import Control.Monad (forM_, when)
import Data.IORef
import Data.Time.Clock.POSIX (getPOSIXTime)
import Development.Shake
import Maker.Check.Native qualified as Check
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process (numericVersion)
import Maker.Store (warm)
import Maker.Toolchain.Chromium (installChromium)
import Maker.Toolchain.Debian (systemPackages)
import Maker.Toolchain.Fourmolu (installFourmolu)
import Maker.Toolchain.Node (installNode, nodeVersionNow)
import Maker.Toolchain.Wasm (guardSysroot, installSysroot, installWasmGhc)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (hPutStr, stderr)
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd (..))

-- | What the maker can be asked to install or do.
data Target
  = SystemPackages
  | WasmSysroot
  | WasmGhc
  | Node
  | Chromium
  | Fourmolu
  | Store
  deriving (Eq, Show, Enum, Bounded)

-- | The target's name, as rules and the command line know it.
targetName :: Target -> String
targetName = \case
  SystemPackages -> "system-packages"
  WasmSysroot -> "wasm-sysroot"
  WasmGhc -> "wasm-ghc"
  Node -> "node"
  Chromium -> "chromium"
  Fourmolu -> "fourmolu"
  Store -> "store"

-- | What a mode installs, in order, the system packages first. A build
-- (@build@, the Dockerfile's builder, the deploy's page built on the
-- machine) runs neither the browser tests nor the formatter; @native@ (the
-- deploy's server built on the machine) needs only the packages, and then
-- the check of what its build links ('bootstrap').
targetsFor :: Mode -> [Target]
targetsFor = \case
  Toolchain -> [SystemPackages, WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]
  Build -> [SystemPackages, WasmSysroot, WasmGhc, Node]
  All -> [SystemPackages, WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]
  Warm -> [SystemPackages, WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]
  Native -> [SystemPackages]
  Static -> [Node]

-- | What each rule found out, for the summary at the end.
data Found = Found
  { chromium :: IORef (Maybe String)
  , fourmolu :: IORef (Maybe FilePath)
  }

rules :: Context -> Found -> Rules ()
rules ctx found' = do
  forM_ [minBound .. maxBound] $ \target ->
    phony (targetName target) $ case target of
      SystemPackages -> liftIO (systemPackages ctx)
      WasmSysroot -> liftIO (installSysroot ctx)
      WasmGhc -> do
        need [targetName WasmSysroot]
        liftIO (installWasmGhc ctx)
      Node -> liftIO (installNode ctx)
      Chromium -> do
        need [targetName Node]
        location <- liftIO (installChromium ctx)
        liftIO (writeIORef found'.chromium (Just location))
      Fourmolu -> do
        path <- liftIO (installFourmolu ctx)
        liftIO (writeIORef found'.fourmolu (Just path))
      Store -> do
        need [targetName WasmGhc]
        liftIO (warm ctx)

-- | Run the targets one after another, as listed: their messages come in
-- that order, as the bootstrap's always did. A step that fails has said why
-- and stops the run with its exit code.
runTargets :: Context -> [Target] -> IO Found
runTargets ctx targets = do
  found' <- Found <$> newIORef Nothing <*> newIORef Nothing
  let options =
        shakeOptions
          { shakeFiles = stateDir ctx </> "shake"
          , shakeThreads = 1
          , shakeVerbosity = Silent
          , shakeColor = False
          }
  result <-
    try . shake options $ do
      rules ctx found'
      action (mapM_ (\t -> need [targetName t]) targets)
  case result of
    Right () -> pure found'
    Left (e :: SomeException) -> case fromException e of
      Just (ShakeException {shakeExceptionInner = inner})
        | Just code <- fromException inner -> exitWith (code :: ExitCode)
      _ -> throwIO e

-- | The second stage of @toolchain/bootstrap.sh@ for a mode: the rest of the
-- toolchain after GHC and cabal, the summary line, then, for @all@ and
-- @warm@, the cabal store. The bootstrap holds the toolchain's lock on the
-- descriptor it names, which is let go before the store is warmed, so that a
-- run wanting only the toolchain does not wait for the store. The native
-- mode leaves the wasm sysroot alone, and checks what the native build
-- links once the packages are there.
bootstrap :: Context -> Maybe Int -> Integer -> Integer -> IO ()
bootstrap ctx lockFd logBefore started = do
  allowed <- if ctx.mode `elem` [Native, Static] then pure True else guardSysroot ctx
  when (not allowed) (exitWith (ExitFailure 1))
  found' <- runTargets ctx (targetsFor ctx.mode)
  when (ctx.mode == Native) (nativeCheck ctx)
  node <- nodeVersionNow
  chromium <- readIORef found'.chromium
  fourmolu <- readIORef found'.fourmolu
  ghcFound <- numericVersion "ghc"
  cabalFound <- numericVersion "cabal"
  let p = ctx.pins
      base' = "GHC " <> p.ghcVersion <> ", cabal " <> p.cabalVersion <> ", wasm32-wasi-ghc " <> p.wasmGhcVersion <> ", Node " <> node
      noWasm = "; no wasm toolchain, Node, Chromium or fourmolu (native)"
      summary = case ctx.mode of
        Static
          | ctx.systemTools -> "this machine's GHC " <> ghcFound <> ", cabal " <> cabalFound <> " and Node " <> node <> " (--system-tools); no wasm toolchain, Chromium or fourmolu (static)"
          | otherwise -> "GHC " <> p.ghcVersion <> ", cabal " <> p.cabalVersion <> ", Node " <> node <> "; no wasm toolchain, Chromium or fourmolu (static)"
        Native
          | ctx.systemTools -> "this machine's GHC " <> ghcFound <> " and cabal " <> cabalFound <> " (--system-tools)" <> noWasm
          | otherwise -> "GHC " <> p.ghcVersion <> ", cabal " <> p.cabalVersion <> noWasm
        Build -> base' <> "; no Chromium or fourmolu (build)"
        _ -> base' <> ", Chromium in " <> maybe "" id chromium <> ", fourmolu " <> p.fourmoluVersion <> " at " <> maybe "" id fourmolu
  logAfter <- logSize ctx
  if logAfter == logBefore
    then putStrLn ("bootstrap: toolchain already installed (" <> summary <> ")")
    else do
      now <- (truncate :: Rational -> Integer) . toRational <$> getPOSIXTime
      say ctx ("toolchain ready in " <> show (now - started) <> "s: " <> summary)
  forM_ lockFd $ \fd -> try (closeFd (Fd (fromIntegral fd))) :: IO (Either SomeException ())
  when (ctx.mode `elem` [All, Warm]) (warm ctx)

-- | The check of what the native build of wiki-server needs
-- ("Maker.Check.Native"), after the packages: on Debian it confirms the
-- packages just installed, and elsewhere it is the only check. Its report is
-- shown only when something is missing, so a run with nothing to do stays
-- one line.
nativeCheck :: Context -> IO ()
nativeCheck ctx = do
  (report, ok) <- Check.checkNative ctx.root Check.Options {postgres = ctx.postgres, wizard = ctx.wizard, tex = True}
  when (not ok) $ do
    hPutStr stderr (unlines report)
    say ctx $
      if ctx.wizard
        then "the native build of wiki-server and the configuration wizard need what is missing above; install it and run this again"
        else "the native build of wiki-server needs what is missing above; install it and run this again"
    exitWith (ExitFailure 1)
