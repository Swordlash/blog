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
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Store (warm)
import Maker.Toolchain.Chromium (installChromium)
import Maker.Toolchain.Fourmolu (installFourmolu)
import Maker.Toolchain.Node (installNode, nodeVersionNow)
import Maker.Toolchain.Wasm (guardSysroot, installSysroot, installWasmGhc)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.Posix.IO (closeFd)
import System.Posix.Types (Fd (..))

-- | What the maker can be asked to install or do.
data Target
  = WasmSysroot
  | WasmGhc
  | Node
  | Chromium
  | Fourmolu
  | Store
  deriving (Eq, Show, Enum, Bounded)

-- | The target's name, as rules and the command line know it.
targetName :: Target -> String
targetName = \case
  WasmSysroot -> "wasm-sysroot"
  WasmGhc -> "wasm-ghc"
  Node -> "node"
  Chromium -> "chromium"
  Fourmolu -> "fourmolu"
  Store -> "store"

-- | What a mode installs, in order. A build (@build@, the Dockerfile's
-- builder, the deploy's page built on the machine) runs neither the browser
-- tests nor the formatter.
targetsFor :: Mode -> [Target]
targetsFor = \case
  Toolchain -> [WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]
  Build -> [WasmSysroot, WasmGhc, Node]
  All -> [WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]
  Warm -> [WasmSysroot, WasmGhc, Node, Chromium, Fourmolu]

-- | What each rule found out, for the summary at the end.
data Found = Found
  { chromium :: IORef (Maybe String)
  , fourmolu :: IORef (Maybe FilePath)
  }

rules :: Context -> Found -> Rules ()
rules ctx found' = do
  forM_ [minBound .. maxBound] $ \target ->
    phony (targetName target) $ case target of
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
-- run wanting only the toolchain does not wait for the store.
bootstrap :: Context -> Maybe Int -> Integer -> Integer -> IO ()
bootstrap ctx lockFd logBefore started = do
  allowed <- guardSysroot ctx
  when (not allowed) (exitWith (ExitFailure 1))
  found' <- runTargets ctx (targetsFor ctx.mode)
  node <- nodeVersionNow
  chromium <- readIORef found'.chromium
  fourmolu <- readIORef found'.fourmolu
  let p = ctx.pins
      base' = "GHC " <> p.ghcVersion <> ", cabal " <> p.cabalVersion <> ", wasm32-wasi-ghc " <> p.wasmGhcVersion <> ", Node " <> node
      summary = case ctx.mode of
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
