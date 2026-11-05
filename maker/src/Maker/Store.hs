-- | Warming the cabal store: building the repository's dependencies for
-- each of its projects (cabal.project natively, cabal-wasm.project for wasm)
-- so that the first real build compiles only the repository's own packages.
-- A project is warmed again only when what decides its plan changed since
-- the last warm-up that succeeded: its project files, every package
-- description in the repository, and the compilers.
module Maker.Store
  ( warm
  , fingerprintInput
  , cabalFiles
  )
where

import Control.Monad (forM, unless, when)
import Data.IORef
import Data.List (sort)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Maker.Context
import Maker.Log
import Maker.Process
import System.Directory
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.IO (readFile')
import System.Process (CreateProcess (..))

-- | The text whose SHA-256 is a project's fingerprint: the files given, the
-- freeze and local files, every package description, then the two
-- compilers' versions. It is the text toolchain/bootstrap.sh hashed, so a
-- store it warmed is not warmed again.
fingerprintInput :: FilePath -> [FilePath] -> [FilePath] -> String -> String -> IO String
fingerprintInput root projectFiles packageFiles ghcVersion wasmVersion = do
  let named = projectFiles <> ["cabal.project.freeze", "cabal.project.local"]
  projects <- forM named $ \f -> do
    exists <- doesFileExist (root </> f)
    if exists then readFile' (root </> f) else pure ""
  packages <- mapM readFile' packageFiles
  pure (concat projects <> concat packages <> ghcVersion <> wasmVersion)

-- | Every package description under the root, outside build directories,
-- node_modules and .git, in the order a C-locale sort of their paths gives.
-- The maker's own (@maker/@) is left out: it has a project of its own, and
-- no bearing on the wiki's plans.
cabalFiles :: FilePath -> IO [FilePath]
cabalFiles root = sort <$> walk root
  where
    walk dir = do
      entries <- listDirectory dir
      fmap concat . forM entries $ \entry -> do
        let path = dir </> entry
        isLink <- pathIsSymbolicLink path
        isDir <- doesDirectoryExist path
        if isDir && not isLink
          then if entry `elem` ["dist-newstyle", "node_modules", ".git"] || path == root </> "maker" then pure [] else walk path
          else do
            isFile <- doesFileExist path
            pure [path | isFile && not isLink && hasCabalSuffix entry]
    hasCabalSuffix name = reverse ".cabal" == take 6 (reverse name)

-- | Warm both projects that exist, under the store's lock.
warm :: Context -> IO ()
warm ctx = withLock ctx (stateDir ctx </> "warm.lock") "the cabal store" $ do
  updated <- newIORef False
  native <- warmOne ctx updated "cabal.project" ["cabal.project"] warmNative
  wasm <- warmOne ctx updated "cabal-wasm.project" ["cabal.project", "cabal-wasm.project"] warmWasm
  unless (native || wasm) (putStrLn "bootstrap: no cabal.project yet, nothing to warm")

-- | Warm one project unless its fingerprint is the stamp's; answers whether
-- the project exists.
warmOne :: Context -> IORef Bool -> FilePath -> [FilePath] -> (Context -> IO ()) -> IO Bool
warmOne ctx updated project files builder = do
  exists <- doesFileExist (ctx.root </> project)
  when exists $ do
    key <- sha256Text (ctx.root </> project)
    let stamp = stateDir ctx </> ("warm-" <> take 16 key)
    packages <- cabalFiles ctx.root
    ghc <- maybe "" id <$> output "ghc" ["--numeric-version"]
    wasm <- maybe "" id <$> output "wasm32-wasi-ghc" ["--numeric-version"]
    sumNow <- sha256Text =<< fingerprintInput ctx.root files packages ghc wasm
    stamped <- do
      there <- doesFileExist stamp
      if there then readFile' stamp else pure ""
    if stamped == sumNow <> "\n"
      then putStrLn ("bootstrap: " <> project <> " dependencies already built")
      else do
        done <- readIORef updated
        unless done $ do
          say ctx "updating cabal's package index"
          runLong ctx "updating cabal's package index" (\p -> p {cwd = Just (stateDir ctx)}) ["cabal", "update"]
          writeIORef updated True
        say ctx ("building " <> project <> "'s dependencies into the cabal store (this can take a while)")
        started <- getPOSIXTime
        builder ctx
        writeFile stamp (sumNow <> "\n")
        finished <- getPOSIXTime
        say ctx ("built " <> project <> "'s dependencies in " <> show (truncate (finished - started) :: Integer) <> "s")
  pure exists

-- | The native project's dependencies, without the wasm target's compiler
-- variables, which a shell may have loaded.
warmNative :: Context -> IO ()
warmNative ctx = do
  environment <- getEnvironment
  let dropped = ["CC", "CXX", "LD", "AR", "NM", "RANLIB", "STRIP", "OBJCOPY", "OBJDUMP", "SIZE", "STRINGS"]
      clean = filter ((`notElem` dropped) . fst) environment
  runWith
    ctx
    "building cabal.project's dependencies"
    (\p -> p {cwd = Just ctx.root, env = Just clean})
    ["cabal", "build", "all", "--only-dependencies", "--project-file=cabal.project", "--builddir=dist-newstyle/native"]

-- | The wasm project's dependencies, with the sysroot's environment loaded,
-- as toolchain/build-wasm.sh builds. Cabal may reuse the host ghc-pkg from
-- its cached compiler configuration when switching toolchains, and miss a
-- change to cabal.project, which cabal-wasm.project imports, so both are
-- removed first.
warmWasm :: Context -> IO ()
warmWasm ctx =
  runWith
    ctx
    "building cabal-wasm.project's dependencies"
    (\p -> p {cwd = Just ctx.root})
    [ "sh"
    , "-c"
    , unwords
        [ ". \"$1/env\" &&"
        , "rm -f dist-newstyle/wasm/cache/compiler dist-newstyle/wasm/cache/config &&"
        , "cabal build all --only-dependencies --project-file=cabal-wasm.project"
        , "--builddir=dist-newstyle/wasm"
        , "--with-compiler=\"$(command -v wasm32-wasi-ghc)\""
        , "--with-hc-pkg=\"$(command -v wasm32-wasi-ghc-pkg)\""
        , "--with-hsc2hs=\"$(command -v wasm32-wasi-hsc2hs)\""
        ]
    , "sh"
    , wasmPrefix ctx
    ]
