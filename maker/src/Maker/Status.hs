-- | The toolchain's state, component by component, as @maker status@ prints
-- it and the terminal interface shows it: each component's version, and
-- whether it is the pinned one, another that will do, missing, or blocked.
-- Nothing is installed or changed to find it out.
module Maker.Status
  ( Component (..)
  , State (..)
  , status
  , render
  , ready
  )
where

import Maker.Context
import Maker.Pins (Pins (..))
import Maker.Process
import Maker.Toolchain.Chromium
import Maker.Toolchain.Fourmolu (fourmoluVersionNow)
import Maker.Toolchain.Ghcup (managedToolReady)
import Maker.Toolchain.Node (compatibleNode, nodeVersionNow)
import Maker.Toolchain.Sodium (sodiumWasmReady)
import Maker.Toolchain.Wasm (sysrootReady)
import System.Directory (doesPathExist)

-- | Where a component stands.
data State
  = -- | Installed, at the pinned version or one that will do.
    Ready String
  | -- | Not there (or not working); the bootstrap installs it.
    Missing String
  | -- | In the way: the bootstrap refuses to install over it.
    Blocked String
  deriving (Eq, Show)

-- | One component of the toolchain.
data Component = Component
  { name :: String
  , state :: State
  }
  deriving (Eq, Show)

-- | Whether a component needs nothing.
ready :: Component -> Bool
ready c = case c.state of
  Ready _ -> True
  _ -> False

-- | Every component's state.
status :: Context -> IO [Component]
status ctx = do
  ghc <- pinned "GHC" "ghc" ctx.pins.ghcVersion
  cabal <- pinned "cabal" "cabal" ctx.pins.cabalVersion
  sysroot <- do
    ok <- sysrootReady ctx
    there <- doesPathExist (wasmPrefix ctx)
    pure . Component "wasm sysroot" $
      if ok
        then Ready (wasmPrefix ctx)
        else
          if there
            then Blocked (wasmPrefix ctx <> " is there but unrecognised or incomplete")
            else Missing (wasmPrefix ctx)
  sodium <- do
    ok <- sodiumWasmReady ctx
    pure . Component "libsodium (wasm)" $
      if ok then Ready ctx.pins.libsodiumVersion else Missing ("wants " <> ctx.pins.libsodiumVersion <> ", built from source into the wasm sysroot")
  wasmGhc <- do
    let version = ctx.pins.wasmGhcVersion
    onPath <- numericVersion "wasm32-wasi-ghc"
    managed <- managedToolReady ctx "ghc" ("wasm32-wasi-" <> version) ("wasm32-wasi-ghc-" <> version) version
    pure . Component "wasm32-wasi-ghc" $
      if onPath == version || managed then Ready version else Missing ("wants " <> version <> describe onPath)
  node <- do
    ok <- compatibleNode ctx
    version <- nodeVersionNow
    pure . Component "Node" $
      if ok then Ready version else Missing ("wants " <> show ctx.pins.nodeMinMajor <> " or later with npm" <> describe version)
  chromium <- do
    pw <- playwrightLocation ctx
    case pw.cli of
      Nothing -> pure (Component "Chromium" (Missing ("playwright-core " <> pw.version <> " is not installed")))
      Just cliPath -> do
        location <- chromiumLocation cliPath
        cached <- chromiumCached pw.prefix
        pure . Component "Chromium" $ case location of
          Just where' | cached -> Ready where'
          _ -> Missing ("the headless shell for Playwright " <> pw.version)
  fourmolu <- do
    said <- fourmoluVersionNow
    let wanted = "fourmolu " <> ctx.pins.fourmoluVersion
    pure . Component "fourmolu" $ if said == wanted then Ready ctx.pins.fourmoluVersion else Missing ("wants " <> ctx.pins.fourmoluVersion <> describe said)
  pure [ghc, cabal, sysroot, sodium, wasmGhc, node, chromium, fourmolu]
  where
    pinned label tool version = do
      said <- numericVersion tool
      pure . Component label $
        if said == version then Ready version else Missing ("wants " <> version <> describe said)
    describe "" = ", none found"
    describe said = ", found " <> said

-- | The state as @maker status@ prints it: one line per component.
render :: [Component] -> String
render = unlines . map line
  where
    line c =
      pad 18 c.name <> case c.state of
        Ready detail -> "ready    " <> detail
        Missing detail -> "missing  " <> detail
        Blocked detail -> "blocked  " <> detail
    pad n s = s <> replicate (n - length s) ' '
