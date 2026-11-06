-- | libsodium for wasm32-wasi: the C library the opaque package (OPAQUE,
-- the password login) calls for its primitives, built from source with the
-- wasm sysroot's wasi-sdk and installed into that sysroot, where
-- wasm32-wasi-ghc's linker finds it without any flag.
--
-- The source is a git clone of libsodium at the pinned release tag, and
-- the commit checked out must be the pinned commit
-- (@LIBSODIUM_TAG@ and @LIBSODIUM_COMMIT@ in @toolchain/pins.env@).
-- libsodium publishes no wasm32-wasi build, and the owner wants it compiled
-- here in any case. @WIKI_LIBSODIUM_SOURCE@ names another place to clone
-- from: an @http://@ or @https://@ URL of a git repository, or a directory
-- of this machine holding a clone, for a machine that cannot reach GitHub.
-- Either must hold the pinned commit.
--
-- The library is built as position-independent code, and installed as a
-- shared object too (@libsodium.so@, linked from the archive): the wasm
-- build makes a shared object of every Haskell package as well, which
-- Template Haskell's interpreter loads, and it loads a package's
-- @extra-libraries@ only as shared objects. The program itself links the
-- archive.
module Maker.Toolchain.Sodium
  ( sodiumWasmReady
  , installSodiumWasm
  , sodiumRepo
  )
where

import Control.Monad (unless, when)
import Data.List (isPrefixOf)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import System.Directory
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process.Typed (setWorkingDir)

-- | Where libsodium is cloned from unless @WIKI_LIBSODIUM_SOURCE@ names
-- another place.
sodiumRepo :: String
sodiumRepo = "https://github.com/jedisct1/libsodium"

-- | The wasi-sdk's sysroot, inside the wasm prefix.
sysroot :: Context -> FilePath
sysroot ctx = wasmPrefix ctx </> "wasi-sdk" </> "share" </> "wasi-sysroot"

-- | The marker of a complete install of the pinned commit.
marker :: Context -> FilePath
marker ctx = wasmPrefix ctx </> (".libsodium-" <> ctx.pins.libsodiumCommit)

-- | Whether the pinned libsodium is installed into the sysroot: its marker,
-- its archive and its header. The sysroot's own setup deletes the whole
-- prefix, marker included, so a sysroot installed again gets libsodium
-- again.
sodiumWasmReady :: Context -> IO Bool
sodiumWasmReady ctx =
  and
    <$> mapM
      doesFileExist
      [ marker ctx
      , sysroot ctx </> "lib" </> "wasm32-wasi" </> "libsodium.a"
      , sysroot ctx </> "lib" </> "wasm32-wasi" </> "libsodium.so"
      , sysroot ctx </> "include" </> "wasm32-wasi" </> "sodium.h"
      ]

-- | Clone, build and install libsodium for wasm32-wasi unless it is ready.
-- The clone is deleted once the library is installed; a build that fails
-- leaves it for inspection, and the next run deletes it first.
installSodiumWasm :: Context -> IO ()
installSodiumWasm ctx = do
  ready <- sodiumWasmReady ctx
  unless ready $ do
    source <- maybe sodiumRepo (\s -> if null s then sodiumRepo else s) <$> lookupEnv "WIKI_LIBSODIUM_SOURCE"
    let p = ctx.pins
        isUrl = any (`isPrefixOf` source) ["http://", "https://"]
        src = stateDir ctx </> "libsodium-src"
        sdk = wasmPrefix ctx </> "wasi-sdk" </> "bin"
        root' = sysroot ctx
    isDir <- doesDirectoryExist source
    unless (isUrl || isDir) $ do
      sayErr ("WIKI_LIBSODIUM_SOURCE " <> source <> ": a git repository's http:// or https:// URL, or a directory of this machine")
      failStep ctx "finding libsodium's source"
    say ctx ("building libsodium " <> p.libsodiumVersion <> " for wasm32-wasi into " <> root' <> ", its source cloned from " <> source <> " at " <> p.libsodiumTag)
    removePath src
    if isUrl
      then run ctx "cloning libsodium" ["git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1", "--branch", p.libsodiumTag, source, src]
      else do
        run ctx "cloning libsodium" ["git", "clone", "--quiet", "--no-checkout", source, src]
        run ctx "checking libsodium out" ["git", "-C", src, "-c", "advice.detachedHead=false", "checkout", "--quiet", p.libsodiumCommit]
    commit <- maybe "" firstLine <$> output "git" ["-C", src, "rev-parse", "HEAD"]
    when (commit /= p.libsodiumCommit) $ do
      removePath src
      sayErr ("libsodium's " <> p.libsodiumTag <> " from " <> source <> " is commit " <> (if null commit then "(none)" else commit) <> ", not the pinned " <> p.libsodiumCommit)
      failStep ctx "checking libsodium's commit"
    jobs <- maybe "1" firstLine <$> output "nproc" []
    let inSrc = setWorkingDir src
        configure =
          [ "env"
          , "CC=" <> sdk </> "wasm32-wasi-clang"
          , "AR=" <> sdk </> "llvm-ar"
          , "RANLIB=" <> sdk </> "llvm-ranlib"
          , "CFLAGS=-O2 -fPIC"
          , "./configure"
          , "--host=wasm32-wasi"
          , "--prefix=" <> root'
          , "--libdir=" <> root' </> "lib" </> "wasm32-wasi"
          , "--includedir=" <> root' </> "include" </> "wasm32-wasi"
          , "--disable-pie"
          , "--disable-ssp"
          , "--disable-shared"
          , "--without-pthreads"
          ]
    runLong ctx "configuring libsodium for wasm32-wasi" inSrc configure
    runLong ctx "building libsodium for wasm32-wasi" inSrc ["make", "-j" <> jobs]
    runLong ctx "installing libsodium into the wasm sysroot" inSrc ["make", "install"]
    let lib = root' </> "lib" </> "wasm32-wasi"
    run
      ctx
      "linking libsodium's shared object for the wasm sysroot"
      [sdk </> "wasm32-wasi-clang", "-shared", "-Wl,--whole-archive", lib </> "libsodium.a", "-Wl,--no-whole-archive", "-o", lib </> "libsodium.so"]
    removePath src
    writeFile (marker ctx) ""
    installed <- sodiumWasmReady ctx
    unless installed (failStep ctx "verifying libsodium in the wasm sysroot")
