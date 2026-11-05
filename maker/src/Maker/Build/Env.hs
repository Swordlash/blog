-- | The environments the builds run their tools in, and running a tool in
-- one. The native build and the wasm build need different environments:
-- @~/.ghc-wasm/env@ exports a @CC@, an @ar@ and a @clang@ for WebAssembly,
-- and cabal's native configuration breaks when those are set. The shell
-- scripts kept them apart with subshells; the maker computes both
-- environments once and passes one to each tool it starts, and never
-- changes its own.
module Maker.Build.Env
  ( BuildEnv (..)
  , buildEnv
  , crossVariables
  , withoutCross
  , wasmEnvironment
  , parseNulEnvironment
  , executableIn
  , call
  , callOut
  , stage
  , removeCaches
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM_)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Maker.Process (removePath)
import System.Directory (findExecutablesInDirectories, getCurrentDirectory, getHomeDirectory)
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath (searchPathSeparator, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process.Typed

-- | Where a build runs: the repository, the directory that holds the
-- toolchain (@WIKI_TOOLCHAIN_HOME@, else the home directory), and the
-- environment the maker was started with, without the cross compiler's
-- variables.
data BuildEnv = BuildEnv
  { root :: FilePath
  , toolchainHome :: FilePath
  , native :: [(String, String)]
  }

-- | The build environment of the current directory, which is the
-- repository's root when @toolchain/maker.sh@ runs the maker.
buildEnv :: IO BuildEnv
buildEnv = do
  root' <- getCurrentDirectory
  home <- getHomeDirectory
  named <- lookupEnv "WIKI_TOOLCHAIN_HOME"
  environment <- getEnvironment
  pure
    BuildEnv
      { root = root'
      , toolchainHome = case named of
          Just dir | not (null dir) -> dir
          _ -> home
      , native = withoutCross environment
      }

-- | The variables @~/.ghc-wasm/env@ sets for the cross compiler. A native
-- build must not see them, should the calling shell have loaded that file.
crossVariables :: [String]
crossVariables = ["CC", "CXX", "LD", "AR", "NM", "RANLIB", "STRIP", "OBJCOPY", "OBJDUMP", "SIZE", "STRINGS"]

-- | An environment without the cross compiler's variables.
withoutCross :: [(String, String)] -> [(String, String)]
withoutCross = filter ((`notElem` crossVariables) . fst)

-- | The environment of the wasm build: the maker's own with
-- @~/.ghc-wasm/env@ loaded on top, read back from a shell that loads it.
wasmEnvironment :: BuildEnv -> IO [(String, String)]
wasmEnvironment be = do
  let script = be.toolchainHome </> ".ghc-wasm" </> "env"
  printed <- readProcessStdout_ (proc "sh" ["-c", ". \"$1\" && env -0", "sh", script])
  pure (parseNulEnvironment (text printed))

-- | @env -0@'s output: variables separated by NUL bytes, each
-- @NAME=VALUE@, where the value may hold newlines.
parseNulEnvironment :: String -> [(String, String)]
parseNulEnvironment = foldr entry [] . splitNul
  where
    splitNul s = case break (== '\0') s of
      (item, []) -> [item | not (null item)]
      (item, _ : rest) -> item : splitNul rest
    entry item acc = case break (== '=') item of
      (name, '=' : value) | not (null name) -> (name, value) : acc
      _ -> acc

-- | Where a program is on an environment's @PATH@, as @command -v@ finds it.
executableIn :: [(String, String)] -> String -> IO (Maybe FilePath)
executableIn environment name = do
  let dirs = splitPath' (fromMaybe "" (lookup "PATH" environment))
  found <- findExecutablesInDirectories dirs name
  pure (case found of (p : _) -> Just p; [] -> Nothing)
  where
    splitPath' s = case break (== searchPathSeparator) s of
      (dir, []) -> [dir]
      (dir, _ : rest) -> dir : splitPath' rest

-- | Run a program in an environment, with the maker's standard streams. A
-- failure ends the maker with the program's exit code, as the shell's
-- @set -e@ and @exec@ did, so a caller sees cabal's own status. Ctrl-C
-- goes to the program, as it did when the script ran it.
call :: [(String, String)] -> FilePath -> [String] -> IO ()
call environment program args = do
  path <- resolve environment program
  code <- runProcess (setDelegateCtlc True (setEnv environment (proc path args)))
  case code of
    ExitSuccess -> pure ()
    failure -> throwIO failure

-- | Run a program and return the last line it prints, as a shell's @$(…)@
-- of a command whose answer is its last line. Its standard error is the
-- maker's; a failure ends the maker with its exit code.
callOut :: [(String, String)] -> FilePath -> [String] -> IO String
callOut environment program args = do
  path <- resolve environment program
  (code, printed) <- readProcessStdout (setDelegateCtlc True (setEnv environment (proc path args)))
  case code of
    ExitSuccess -> pure (lastLine (text printed))
    failure -> throwIO failure
  where
    lastLine s = case reverse (filter (not . null) (lines s)) of
      (l : _) -> l
      [] -> ""

-- | Where a program named without a directory is, on the PATH of the
-- environment it will run in. The process library looks a name up on the
-- maker's own PATH even when the child gets another environment, and
-- wasm-opt, for one, is only on the wasm environment's. (Shake's @cmd@,
-- which the build's rules use, does the same by itself.)
resolve :: [(String, String)] -> FilePath -> IO FilePath
resolve environment program
  | '/' `elem` program = pure program
  | otherwise = fromMaybe program <$> executableIn environment program

-- | A step of the build, timed: @Build stage NAME: N s@ on standard error
-- once it has succeeded, as the build script printed, so that a slow build
-- says where its time went.
stage :: (MonadIO m) => String -> m a -> m a
stage name action = do
  started <- liftIO getPOSIXTime
  result <- action
  ended <- liftIO getPOSIXTime
  liftIO (hPutStrLn stderr ("Build stage " <> name <> ": " <> show (floor (ended - started) :: Integer) <> " s"))
  pure result

-- | What a program printed, as text, replacing a byte that is not UTF-8.
text :: LBS.ByteString -> String
text = T.unpack . decodeUtf8With lenientDecode . LBS.toStrict

-- | Delete cabal's cached files in a build directory. @cache/compiler@ may
-- hold the host's @ghc-pkg@ after a switch of toolchain, and
-- @cache/config@, the parsed project, is checked against the project file
-- but not reliably against the files it imports: after a change to
-- haskell-halogen's pin in @cabal.project@ a build went on building the
-- old commit's sources. Reading both afresh costs a few seconds.
removeCaches :: FilePath -> [String] -> IO ()
removeCaches buildDir names = forM_ names $ \name -> removePath (buildDir </> "cache" </> name)
