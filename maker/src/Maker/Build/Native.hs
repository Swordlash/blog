-- | The native build and its tests: @npm run build-native@ and
-- @npm run test-native@. Both build with the host GHC into
-- @dist-newstyle/native@, the build directory CI caches under that name.
module Maker.Build.Native
  ( buildNative
  , testNative
  , testTarget
  , changelogStamp
  )
where

import Control.Exception (throwIO)
import Maker.Build.Env
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (hPutStrLn, stderr)

-- | Write @wiki-server/changelog.stamp@ and @wiki-app/changelog.stamp@,
-- which make cabal rebuild each package when an entry of the changelog is
-- added (@toolchain/changelog-stamp.sh@ says why). The Dockerfile, the
-- deploy and the smoke test run the same script.
changelogStamp :: BuildEnv -> IO ()
changelogStamp be = call be.native "sh" ["toolchain/changelog-stamp.sh"]

-- | Build every package natively, with cabal's arguments after the
-- maker's.
buildNative :: BuildEnv -> [String] -> IO ()
buildNative be args = do
  changelogStamp be
  call be.native "cabal" (["build", "all", "--builddir=dist-newstyle/native"] <> args)

-- | The cabal target a test group runs. CI runs the tests without a
-- database apart from the server's two backends, each on a runner of its
-- own: @unit@ runs everything (the server's suite skips its database
-- cases when the group says so), @sqlite@ and @postgres@ only the server's
-- suite. Unset means all of them.
testTarget :: Maybe String -> Either String String
testTarget = \case
  Nothing -> Right "all"
  Just group
    | group `elem` ["all", "unit"] -> Right "all"
    | group `elem` ["sqlite", "postgres"] -> Right "wiki-server:test:wiki-server-test"
    | otherwise -> Left "WIKI_TEST_GROUP must be all, unit, sqlite or postgres"

-- | Run the native test suites of the group @WIKI_TEST_GROUP@ names. A
-- group the maker does not know ends it with status 2 before cabal runs.
testNative :: BuildEnv -> [String] -> IO ()
testNative be args = do
  group <- lookupEnv "WIKI_TEST_GROUP"
  case testTarget group of
    Left message -> do
      hPutStrLn stderr message
      throwIO (ExitFailure 2)
    Right target -> do
      changelogStamp be
      call be.native "cabal" (["test", target, "--builddir=dist-newstyle/native"] <> args)
