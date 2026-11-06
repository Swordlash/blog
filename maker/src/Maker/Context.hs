-- | Where the toolchain lives and how this run was asked for: the paths
-- toolchain/bootstrap.sh computes (the toolchain's base directory, its state
-- directory and log, ghcup's bin directory), the pins and the mode. The
-- bootstrap passes what it computed on the command line, so that both stages
-- agree on every path.
module Maker.Context
  ( Context (..)
  , Mode (..)
  , modeName
  , stateDir
  , logFile
  , wasmPrefix
  , metaDir
  , nodeDir
  , nodeLink
  , ghcup
  )
where

import Maker.Pins (Pins (..))
import System.FilePath ((</>))

-- | What the bootstrap was run for, of the modes the maker carries on with
-- (every mode that installs something, but @node@). @toolchain@ installs
-- everything a developer needs; @build@ what a build needs (no Chromium, no
-- fourmolu); @all@ and @warm@ also build the repository's dependencies into
-- the cabal store; @native@ only what the native build of wiki-server needs
-- besides GHC and cabal (the C libraries' packages and their check);
-- @static@ only Node, for the deploy of a demo whose page is not built on
-- the machine, which needs GHC and cabal for the maker alone.
data Mode = Toolchain | Build | All | Warm | Native | Static
  deriving (Eq, Show, Enum, Bounded)

-- | The mode's name, as the bootstrap's command line has it.
modeName :: Mode -> String
modeName = \case
  Toolchain -> "toolchain"
  Build -> "build"
  All -> "all"
  Warm -> "warm"
  Native -> "native"
  Static -> "static"

-- | One run of the maker.
data Context = Context
  { root :: FilePath
  -- ^ The repository's root.
  , base :: FilePath
  -- ^ Where the toolchain goes: the home directory, or WIKI_TOOLCHAIN_HOME.
  , namedBase :: Bool
  -- ^ Whether the base is a directory WIKI_TOOLCHAIN_HOME names rather than
  -- the home directory, which tells ghcup, cabal, npm and Playwright to keep
  -- their files there too.
  , ghcupBin :: FilePath
  -- ^ ghcup's bin directory, where its tools and fourmolu go.
  , pins :: Pins
  , mode :: Mode
  , postgres :: Bool
  -- ^ Whether wiki-server is built with PostgreSQL, and so needs libpq.
  -- @--without-postgres@ (@native@ and @build@) turns it off, for a wiki in
  -- SQLite.
  , wizard :: Bool
  -- ^ Whether the configuration wizard is built too, which links terminfo
  -- (@native --with-wizard@).
  , systemTools :: Bool
  -- ^ Whether GHC and cabal are the machine's own, as PATH finds them
  -- (@native --system-tools@): the summary then names the versions found.
  }

-- | The toolchain's own directory: its state, its log, Node, the markers.
stateDir :: Context -> FilePath
stateDir ctx = ctx.base </> ".wiki-toolchain"

-- | The log every command's output goes to.
logFile :: Context -> FilePath
logFile ctx = stateDir ctx </> "bootstrap.log"

-- | ghc-wasm-meta's prefix: wasi-sdk, binaryen, wasmtime and its Node.
wasmPrefix :: Context -> FilePath
wasmPrefix ctx = ctx.base </> ".ghc-wasm"

-- | Where ghc-wasm-meta's pinned revision is unpacked.
metaDir :: Context -> FilePath
metaDir ctx = stateDir ctx </> ("ghc-wasm-meta-" <> ctx.pins.ghcWasmMetaRev)

-- | Where the pinned Node is unpacked.
nodeDir :: Context -> FilePath
nodeDir ctx = stateDir ctx </> ("node-v" <> ctx.pins.nodeVersion <> "-linux-x64")

-- | The link the environment file puts on PATH, to whichever Node is
-- installed.
nodeLink :: Context -> FilePath
nodeLink ctx = stateDir ctx </> "node"

-- | ghcup itself.
ghcup :: Context -> FilePath
ghcup ctx = ctx.ghcupBin </> "ghcup"
