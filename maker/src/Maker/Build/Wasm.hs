{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}

-- | The browser application's build, @npm run build-wasm@: wiki-app
-- compiled to WebAssembly, linked with its JavaScript glue, shrunk by
-- wasm-opt, put beside the page from @web/@ and the islands' bundle, and
-- prerendered into a page per route by a native program.
--
-- The output is @$WASM_BUILDDIR/public/app@ (or @WIKI_PUBLIC_DIR@),
-- emptied first so that nothing stale ships. Three steps are Shake file
-- rules whose results are kept in @$WASM_BUILDDIR/maker@: the JavaScript
-- glue and the shrunk binary, rebuilt when cabal's binary changes, and the
-- bundle, rebuilt when its sources, @package-lock.json@ or the installed
-- packages change. A build in which only the page changed then skips
-- wasm-opt and esbuild. Each rule also asks an oracle for the version of
-- the tool it runs, so a new Node or binaryen rebuilds what it made.
--
-- The environment says what to build, as it did for
-- @toolchain/build-wasm.sh@, which the Dockerfile and CI still call:
-- @WASM_PROJECT@ and @WASM_BUILDDIR@ (default @cabal-wasm.project@ and
-- @dist-newstyle/wasm@), @WIKI_PUBLIC_DIR@, @WIKI_BACKEND@ (@demo@, the
-- serverless demo, or @server@, the pages wiki-server renders into),
-- @NATIVE_PROJECT@ and @NATIVE_BUILDDIR@ for the prerender, with
-- @NATIVE_CONSTRAINTS@ (cabal constraints, one per line) for its build, and
-- @HALOGEN_BASE_PATH@, which the prerender reads itself.
module Maker.Build.Wasm
  ( WasmBuild (..)
  , Backend (..)
  , wasmBuildFrom
  , buildWasm
  , hspecHalogen
  , testWasm
  , serveWasm
  )
where

import Control.Exception (SomeException, displayException, fromException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.Maybe (fromMaybe)
import Development.Shake
import Development.Shake.Classes (Binary, Hashable, NFData)
import GHC.Generics (Generic)
import Maker.Build.Env
import Maker.Build.Native (changelogStamp)
import Maker.Process (removePath)
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.Directory qualified as Dir
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process.Typed qualified as P

-- | Which wiki the pages are for. The binary is the same; the page's
-- @<meta name="wiki-backend">@ says which backend it runs on.
data Backend = Demo | Server
  deriving (Eq, Show)

-- | What one build makes, and where.
data WasmBuild = WasmBuild
  { project :: FilePath
  , buildDir :: FilePath
  , publicDir :: FilePath
  , backend :: Backend
  , nativeProject :: FilePath
  , nativeBuildDir :: FilePath
  , nativeConstraints :: [String]
  -- ^ Constraints for the prerender's build, such as the deploy's
  -- @wiki-server -postgres@: a deploy builds the prerender in the server's
  -- project and build directory, so that wiki-app is compiled once, and
  -- the project's plan must then be the one the server's build solves.
  }
  deriving (Eq, Show)

-- | The build the environment asks for. @optimised@ is
-- @npm run build-wasm-opt@: the -O2 production build, in a build directory
-- of its own so that it and the everyday build never invalidate each
-- other; it ignores @WASM_PROJECT@ and @WASM_BUILDDIR@, as the npm script
-- did.
wasmBuildFrom :: Bool -> (String -> Maybe String) -> Either String WasmBuild
wasmBuildFrom optimised env = do
  backend' <- case fromMaybe "demo" (env "WIKI_BACKEND") of
    "demo" -> Right Demo
    "server" -> Right Server
    other -> Left ("WIKI_BACKEND is demo or server, not " <> other)
  let (project', buildDir')
        | optimised = ("cabal-wasm-opt.project", "dist-newstyle/wasm-opt")
        | otherwise = (fromMaybe "cabal-wasm.project" (env "WASM_PROJECT"), fromMaybe "dist-newstyle/wasm" (env "WASM_BUILDDIR"))
  pure
    WasmBuild
      { project = project'
      , buildDir = buildDir'
      , publicDir = fromMaybe (buildDir' </> "public" </> "app") (env "WIKI_PUBLIC_DIR")
      , backend = backend'
      , nativeProject = fromMaybe "cabal-native-fast.project" (env "NATIVE_PROJECT")
      , nativeBuildDir = fromMaybe "dist-newstyle/native-fast" (env "NATIVE_BUILDDIR")
      , nativeConstraints = filter (not . null) (lines (fromMaybe "" (env "NATIVE_CONSTRAINTS")))
      }

-- | A tool's version, which a rule's result depends on.
newtype ToolVersion = ToolVersion String
  deriving newtype (Eq, Show, Hashable, Binary, NFData)

type instance RuleResult ToolVersion = String

-- | The binary cabal built and the wasm compiler's library directory, which
-- holds @post-link.mjs@, as this run found them. Shake checks a rule's
-- recorded dependencies on the next run without running the rule, so a
-- binary at a new path (cabal's path carries the package's version) would
-- otherwise leave the rules on the old file, which is still there.
data Linked = Linked
  deriving (Eq, Show, Generic)
  deriving anyclass (Hashable, Binary, NFData)

type instance RuleResult Linked = (FilePath, FilePath)

-- | The wasm toolchain's programs, found on the wasm environment's PATH.
data WasmTools = WasmTools
  { ghc :: FilePath
  , ghcPkg :: FilePath
  , hsc2hs :: FilePath
  }

wasmTools :: [(String, String)] -> IO WasmTools
wasmTools environment = WasmTools <$> find "wasm32-wasi-ghc" <*> find "wasm32-wasi-ghc-pkg" <*> find "wasm32-wasi-hsc2hs"
  where
    find name =
      executableIn environment name >>= \case
        Just path -> pure path
        Nothing -> do
          hPutStrLn stderr ("maker: " <> name <> " is not on PATH after loading ~/.ghc-wasm/env")
          throwIO (ExitFailure 1)

-- | The arguments that point cabal at the wasm compiler. Cabal may
-- otherwise take the host's @ghc-pkg@ when it switches toolchains.
withCompiler :: WasmTools -> [String]
withCompiler tools = ["--with-compiler=" <> tools.ghc, "--with-hc-pkg=" <> tools.ghcPkg, "--with-hsc2hs=" <> tools.hsc2hs]

-- | The prerender, a native program, built with the host GHC (without
-- optimisation, unless the environment names an optimised project), and
-- its path. It is built before the wasm environment is
-- loaded: that environment's @ar@ and @clang@ would invalidate cabal's
-- native configuration on every switch of backend.
prerenderProgram :: BuildEnv -> WasmBuild -> IO FilePath
prerenderProgram be wb = do
  removeCaches wb.nativeBuildDir ["config"]
  let target = "wiki-app:exe:wiki-app-prerender"
      where' = ["--project-file=" <> wb.nativeProject, "--builddir=" <> wb.nativeBuildDir] <> map ("--constraint=" <>) wb.nativeConstraints
  stage "native-prerender-build" (call be.native "cabal" (["build", target] <> where'))
  callOut be.native "cabal" (["list-bin", "-v0", target] <> where')

-- | Build the application into its public directory, with cabal's
-- arguments after the maker's.
buildWasm :: BuildEnv -> WasmBuild -> [String] -> IO ()
buildWasm be wb extra = do
  -- wiki-app embeds the changelog for the demo, as wiki-server does.
  changelogStamp be
  prerender <- prerenderProgram be wb
  wasm <- wasmEnvironment be
  tools <- wasmTools wasm
  removeCaches wb.buildDir ["compiler", "config"]
  let args = ["--project-file=" <> wb.project, "--builddir=" <> wb.buildDir] <> withCompiler tools <> ["wiki-app:exe:wiki-app"] <> extra
  stage "wasm-compile" (call wasm "cabal" ("build" : args))
  -- Again: in a build directory that did not exist before, the build above
  -- leaves the host ghc-pkg in this cache despite --with-hc-pkg, and
  -- list-bin then fails with "Version mismatch between ghc and ghc-pkg".
  removeCaches wb.buildDir ["compiler"]
  binary <- callOut wasm "cabal" ("list-bin" : args)
  libdir <- callOut wasm tools.ghc ["--print-libdir"]
  let kept = wb.buildDir </> "maker"
  runRules wasm kept $ do
    want [kept </> "ghc_wasm_jsffi.js", kept </> "app.wasm", kept </> "bundle.stamp"]
    -- The JavaScript glue for this binary's imports and exports.
    _ <- addOracle $ \Linked -> pure (binary, libdir)
    kept </> "ghc_wasm_jsffi.js" %> \out -> do
      void (askOracle Linked)
      need [binary]
      void (askOracle (ToolVersion "node"))
      stage "post-link" (cmd_ (Env wasm) ("node" :: String) [libdir </> "post-link.mjs", "--input", binary, "--output", out])
    -- The linker's output carries a name section and debug info worth
    -- about a third of the file; stripping those and optimising for size
    -- roughly halves the binary and takes about a fifth off what is served
    -- gzipped. wasm-opt leaves the imports and exports the glue binds to
    -- untouched.
    kept </> "app.wasm" %> \out -> do
      void (askOracle Linked)
      need [binary]
      void (askOracle (ToolVersion "wasm-opt"))
      stage "wasm-opt" (cmd_ (Env wasm) ("wasm-opt" :: String) ["-Oz", "--strip-debug", "--strip-producers", binary, "-o", out])
    -- The islands' bundle (web/bundle.sh): KaTeX, Mermaid, TikZJax,
    -- highlight.js, CodeMirror and the rest, from node_modules. Its service
    -- worker is written again in the page below, over the page's files.
    kept </> "bundle.stamp" %> \out -> do
      sources <- getDirectoryFiles "" ["web/src//*", "web/licenses//*"]
      -- npm writes node_modules/.package-lock.json on every install, so a
      -- package installed anew rebuilds the bundle; an older npm does not
      -- write it, and package-lock.json then stands alone.
      installed <- doesFileExist "node_modules/.package-lock.json"
      need (["web/bundle.sh", "web/check-macros.mjs", "package-lock.json"] <> ["node_modules/.package-lock.json" | installed] <> sources)
      void (askOracle (ToolVersion "node"))
      liftIO (removePath (kept </> "bundle"))
      stage "bundle" (cmd_ (Env wasm) ("sh" :: String) ["web/bundle.sh", kept </> "bundle"])
      writeFile' out "the bundle in bundle/ was built from these inputs\n"
  removePath wb.publicDir
  createDirectoryIfMissing True wb.publicDir
  forM_ ["ghc_wasm_jsffi.js", "app.wasm"] $ \name -> call wasm "cp" [kept </> name, wb.publicDir </> name]
  -- The page itself; web/bundle.sh and the sources it bundles (web/src/)
  -- are build inputs, not part of it.
  entries <- listDirectory "web"
  forM_ [e | e <- entries, e `notElem` ["bundle.sh", "src"]] $ \entry ->
    call wasm "cp" ["-R", "web" </> entry, wb.publicDir </> entry]
  call wasm "cp" ["-R", kept </> "bundle" </> ".", wb.publicDir]
  -- The service worker's version is a hash of the files above, the page's
  -- among them, so it is written again here.
  stage "pwa" (call wasm "node" ["web/src/pwa.mjs", wb.publicDir])
  let flags = case wb.backend of Demo -> []; Server -> ["--server"]
      backendName = case wb.backend of Demo -> "demo"; Server -> "server"
  stage "prerender" (call be.native prerender (flags <> ["web/index.html", wb.publicDir]))
  putStrLn ("Prerendered " <> (wb.publicDir </> "index.html") <> " with wiki-app-prerender, for the " <> backendName <> ".")
  putStrLn ("\nBuilt wiki-app in " <> wb.publicDir <> ".")

-- | Run file rules with Shake. Its database is kept beside the results, in
-- the build directory, so that two checkouts never share it.
runRules :: [(String, String)] -> FilePath -> Rules () -> IO ()
runRules wasm kept rules' = do
  createDirectoryIfMissing True kept
  result <- try
    $ shake
      shakeOptions
        { shakeFiles = kept </> "shake"
        , shakeThreads = 1
        , shakeVerbosity = Warn
        , shakeChange = ChangeModtimeAndDigest
        }
    $ do
      _ <- addOracle $ \(ToolVersion tool) -> do
        Stdout version <- cmd (Env wasm) tool (["--version"] :: [String])
        pure (version :: String)
      rules'
  -- A tool's failure ends the maker with the tool's status, not Shake's
  -- report of it.
  case result of
    Right () -> pure ()
    Left (e :: SomeException) -> case fromException e of
      Just (ShakeException {shakeExceptionInner = inner})
        | Just code <- fromException inner -> throwIO (code :: ExitCode)
      -- A command that failed inside a rule: Shake's report names the
      -- command and the rule that ran it.
      _ -> do
        hPutStrLn stderr (displayException e)
        throwIO (ExitFailure 1)

-- | The hspec-halogen executable, built with the host GHC, and its path:
-- the program that runs the browser test suites in Chromium (cabal's test
-- wrapper hands them to it) and opens the page for @npm run dev-test@.
hspecHalogen :: BuildEnv -> IO FilePath
hspecHalogen be = do
  project' <- fromMaybe "cabal-native-fast.project" <$> lookupEnv "NATIVE_PROJECT"
  buildDir' <- fromMaybe "dist-newstyle/native-fast" <$> lookupEnv "NATIVE_BUILDDIR"
  removeCaches buildDir' ["config"]
  let target = "hspec-halogen:exe:hspec-halogen"
      where' = ["-v0", target, "--project-file=" <> project', "--builddir=" <> buildDir']
  -- cabal's own output goes to standard error: standard output is the
  -- path, for toolchain/build-hspec-halogen.sh's callers.
  code <- P.runProcess (P.setDelegateCtlc True (P.setStdout (P.useHandleOpen stderr) (P.setEnv be.native (P.proc "cabal" ("build" : where')))))
  when (code /= ExitSuccess) (throwIO code)
  callOut be.native "cabal" ("list-bin" : where')

-- | Run every test suite on the wasm backend, under the Node wrapper that
-- runs each test binary (@toolchain/wasm-test-wrapper.sh@), with cabal's
-- arguments after the maker's. It shares @dist-newstyle/wasm@ with the
-- everyday build.
testWasm :: BuildEnv -> [String] -> IO ()
testWasm be extra = do
  given <- lookupEnv "HSPEC_HALOGEN"
  hspec <- maybe (hspecHalogen be) pure (given >>= \p -> if null p then Nothing else Just p)
  wasm <- (("HSPEC_HALOGEN", hspec) :) . filter ((/= "HSPEC_HALOGEN") . fst) <$> wasmEnvironment be
  tools <- wasmTools wasm
  changelogStamp be
  -- A failing wasm process must fail the test command, on every Node
  -- version: this checks the wrapper on a program that exits as asked.
  call wasm "sh" ["toolchain/test-wasm-runner.sh"]
  let buildDir' = "dist-newstyle/wasm"
  removeCaches buildDir' ["compiler", "config"]
  call wasm "cabal" $
    ["test", "all", "--project-file=cabal-wasm.project", "--builddir=" <> buildDir']
      <> withCompiler tools
      <> ["--test-wrapper=" <> (be.root </> "toolchain" </> "wasm-test-wrapper.sh")]
      <> extra

-- | Build the application and serve it on @http://127.0.0.1:$PORT@
-- (default 8080), opening a browser unless @NO_OPEN=1@.
serveWasm :: BuildEnv -> WasmBuild -> [String] -> IO ()
serveWasm be wb extra = do
  buildWasm be wb extra
  port <- fromMaybe "8080" <$> lookupEnv "PORT"
  noOpen <- lookupEnv "NO_OPEN"
  let url = "http://127.0.0.1:" <> port
  -- The browser is opened a second after the server starts, by a process
  -- left to itself, as the script's background job was.
  unless (noOpen == Just "1") $
    void (P.startProcess (P.proc "sh" ["-c", "sleep 1; sh toolchain/open-browser.sh \"$1\"", "sh", url]))
  exists <- Dir.doesDirectoryExist wb.publicDir
  unless exists (throwIO (ExitFailure 1))
  call be.native (be.root </> "node_modules" </> ".bin" </> "http-server") [wb.publicDir, "-p", port]
