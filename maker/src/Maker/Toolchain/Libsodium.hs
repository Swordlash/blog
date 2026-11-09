-- | libsodium, which the native build links statically: the release pinned
-- in @toolchain/pins.env@, built from source by @toolchain/libsodium.sh@
-- into the toolchain's directory. The script does the work, because CI's
-- hosted runners, which do not run the bootstrap, run it too; the maker
-- runs it only when the library is not installed yet, and then points this
-- process's environment at it, so that the cabal store's warm-up and the
-- check after the native mode find it.
module Maker.Toolchain.Libsodium
  ( installLibsodium
  , libsodiumLink
  , useLibsodium
  )
where

import Control.Monad (forM_, unless)
import Data.List (intercalate)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process (succeeds)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))

-- | The link to the installed release, which the environment file names.
libsodiumLink :: Context -> FilePath
libsodiumLink ctx = stateDir ctx </> "libsodium"

-- | Build and install the pinned libsodium unless the script says it is
-- installed, then 'useLibsodium'.
installLibsodium :: Context -> IO ()
installLibsodium ctx = do
  let script = ctx.root </> "toolchain" </> "libsodium.sh"
  ready <- succeeds "sh" [script, "ready", stateDir ctx]
  unless ready $ do
    say ctx ("building libsodium " <> ctx.pins.libsodiumVersion <> " from source into " <> stateDir ctx <> " (a static library, once)")
    runLong ctx "building libsodium" id ["sh", script, "install", stateDir ctx]
  useLibsodium ctx

-- | Put the installed libsodium first in this process's PKG_CONFIG_PATH,
-- LIBRARY_PATH and C_INCLUDE_PATH, as the environment file does for a
-- shell. The bootstrap starts the maker from a shell that may not have
-- loaded that file yet.
useLibsodium :: Context -> IO ()
useLibsodium ctx = do
  let link = libsodiumLink ctx
  forM_
    [ ("PKG_CONFIG_PATH", link </> "lib" </> "pkgconfig")
    , ("LIBRARY_PATH", link </> "lib")
    , ("C_INCLUDE_PATH", link </> "include")
    ]
    $ \(name, dir) -> do
      current <- maybe [] splitColons <$> lookupEnv name
      unless (dir `elem` current) $
        setEnv name (intercalate ":" (dir : filter (not . null) current))
  where
    splitColons s = case break (== ':') s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitColons rest
