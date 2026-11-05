-- | The wasm toolchain: ghc-wasm-meta's sysroot (wasi-sdk, binaryen,
-- wasmtime and its own Node, in @~/.ghc-wasm@) and, through ghcup, the
-- cross compiler wasm32-wasi-ghc, installed exactly as haskell-halogen's CI
-- installs them.
module Maker.Toolchain.Wasm
  ( sysrootReady
  , guardSysroot
  , installSysroot
  , installWasmGhc
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import Maker.Toolchain.Ghcup
import System.Directory
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (readFile')

-- | Whether the pinned sysroot is installed and works: the marker of a
-- complete install for this revision (the bootstrap's, or the one
-- ghc-wasm-meta's setup leaves), its env file, libc, and each of its tools
-- answering. A marker alone does not prove the setup finished.
sysrootReady :: Context -> IO Bool
sysrootReady ctx = do
  let prefix = wasmPrefix ctx
      rev = ctx.pins.ghcWasmMetaRev
  ours <- doesFileExist (prefix </> (".bootstrap-" <> rev))
  theirs <- (== Just (rev <> "\n")) <$> readIfThere (prefix </> ".paladyn-rev")
  envFile <- doesFileExist (prefix </> "env")
  github <- isExecutable (prefix </> "add_to_github_path.sh")
  libc <- doesFileExist (prefix </> "wasi-sdk/share/wasi-sysroot/lib/wasm32-wasi/libc.a")
  if not ((ours || theirs) && envFile && github && libc)
    then pure False
    else
      and
        <$> mapM
          (\tool -> succeeds (prefix </> tool) ["--version"])
          [ "wasi-sdk/bin/wasm32-wasi-clang"
          , "binaryen/bin/wasm-opt"
          , "wasmtime/bin/wasmtime"
          , "nodejs/bin/node"
          ]
  where
    isExecutable path = do
      exists <- doesFileExist path
      if exists then executable <$> getPermissions path else pure False

-- | Whether the sysroot may be installed: it is ready, or its prefix is
-- missing or an empty directory. Anything else is someone's, which
-- ghc-wasm-meta's setup would delete, so it is refused, said on the
-- terminal.
guardSysroot :: Context -> IO Bool
guardSysroot ctx = do
  ready <- sysrootReady ctx
  if ready
    then pure True
    else do
      let prefix = wasmPrefix ctx
      isLink <- either (const False) id <$> (try (pathIsSymbolicLink prefix) :: IO (Either IOException Bool))
      isDir <- doesDirectoryExist prefix
      isFile <- doesFileExist prefix
      contents <- if isDir && not isLink then listDirectory prefix else pure []
      if isLink || isFile || (isDir && not (null contents))
        then do
          sayErr ("BLOCKED: " <> prefix <> " is unrecognised or incomplete; refusing to overwrite it. Inspect it and move it aside yourself before retrying.")
          pure False
        else pure True

-- | Fetch ghc-wasm-meta at the pinned revision: the archive from
-- gitlab.haskell.org, or, where that host is refused (a company proxy
-- answers 403 there), the commit from the repository's mirror on GitHub.
-- Everything its setup then downloads is on GitHub already.
fetchMeta :: Context -> IO ()
fetchMeta ctx = do
  let dir = metaDir ctx
      tmp = dir <> ".tmp"
      rev = ctx.pins.ghcWasmMetaRev
  there <- doesFileExist (dir </> "ghcup-wasm-0.0.9.yaml")
  unless there $ do
    say ctx ("fetching ghc-wasm-meta " <> rev)
    mapM_ removePath [dir, tmp]
    createDirectoryIfMissing True tmp
    logLine ctx ("+ fetch ghc-wasm-meta " <> rev <> " from gitlab.haskell.org")
    let archive = tmp <> ".tar.gz"
    fetched <-
      fetch
        ctx
        ("https://gitlab.haskell.org/haskell-wasm/ghc-wasm-meta/-/archive/" <> rev <> "/ghc-wasm-meta-" <> rev <> ".tar.gz")
        archive
    if fetched
      then do
        run ctx "unpacking ghc-wasm-meta" ["tar", "xzf", archive, "--strip-components=1", "--directory", tmp]
        removePath archive
      else do
        removePath archive
        say ctx ("gitlab.haskell.org did not give the archive (the end of " <> logFile ctx <> " says why); fetching the commit from the GitHub mirror, github.com/haskell-wasm/ghc-wasm-meta")
        run ctx "starting a repository for ghc-wasm-meta" ["git", "init", "-q", tmp]
        run
          ctx
          "fetching ghc-wasm-meta from the GitHub mirror"
          ["git", "-C", tmp, "fetch", "-q", "--depth", "1", "https://github.com/haskell-wasm/ghc-wasm-meta", rev]
        run ctx "checking ghc-wasm-meta out" ["git", "-C", tmp, "-c", "advice.detachedHead=false", "checkout", "-q", "FETCH_HEAD"]
        removePath (tmp </> ".git")
    arrived <- doesFileExist (tmp </> "ghcup-wasm-0.0.9.yaml")
    unless arrived (failStep ctx "fetching ghc-wasm-meta (no ghcup-wasm-0.0.9.yaml in what arrived)")
    renameDirectory tmp dir

-- | Install the sysroot by ghc-wasm-meta's own setup, unless it is ready.
-- The setup deletes its prefix first, so the marker it is given at the end
-- exists only after a complete run, and only for this revision.
installSysroot :: Context -> IO ()
installSysroot ctx = do
  ready <- sysrootReady ctx
  unless ready $ do
    allowed <- guardSysroot ctx
    unless allowed (exitWith (ExitFailure 1))
    fetchMeta ctx
    let prefix = wasmPrefix ctx
    say ctx ("installing the wasm sysroot into " <> prefix <> " (wasi-sdk, binaryen, wasmtime, Node)")
    runLong
      ctx
      "installing the wasm sysroot"
      id
      ["env", "PREFIX=" <> prefix, "SKIP_GHC=1", "FLAVOUR=" <> ctx.pins.ghcWasmFlavour, "bash", metaDir ctx </> "setup.sh"]
    writeFile (prefix </> (".bootstrap-" <> ctx.pins.ghcWasmMetaRev)) ""
    verified <- sysrootReady ctx
    unless verified (failStep ctx "verifying the wasm sysroot (inspect it before retrying)")

-- | Install the cross compiler from ghc-wasm-meta's ghcup metadata, with the
-- configure arguments the sysroot's env file exports, unless
-- wasm32-wasi-ghc on PATH already reports the pinned version.
installWasmGhc :: Context -> IO ()
installWasmGhc ctx = do
  let version = ctx.pins.wasmGhcVersion
  current <- numericVersion "wasm32-wasi-ghc"
  unless (current == version) $ do
    installGhcup ctx
    ghcupTool ctx "ghc" ("wasm32-wasi-" <> version) ("wasm32-wasi-ghc-" <> version) version $ \step -> do
      fetchMeta ctx
      -- In a shell of its own: the sysroot's env file exports CC and friends
      -- for the wasm target, which nothing after this step must see.
      runLong
        ctx
        step
        id
        [ "sh"
        , "-c"
        , ". \"$1/env\" && \"$2\" -s \"file://$3/ghcup-wasm-0.0.9.yaml\" install ghc \"wasm32-wasi-$4\" --set -- $CONFIGURE_ARGS"
        , "sh"
        , wasmPrefix ctx
        , ghcup ctx
        , metaDir ctx
        , version
        ]
    after <- numericVersion (ctx.ghcupBin </> "wasm32-wasi-ghc")
    when (after /= version) $
      run ctx ("making wasm32-wasi-ghc " <> version <> " the default") [ghcup ctx, "set", "ghc", "wasm32-wasi-" <> version]

readIfThere :: FilePath -> IO (Maybe String)
readIfThere path = do
  exists <- doesFileExist path
  if exists then Just <$> readFile' path else pure Nothing
