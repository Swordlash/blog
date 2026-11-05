-- | Node, which the npm scripts, the bundles and the test runners need: any
-- Node on PATH of the floor's major version or later, with npm, will do;
-- otherwise the pinned release goes into the toolchain's directory, behind
-- a link the environment file puts on PATH.
module Maker.Toolchain.Node
  ( compatibleNode
  , installNode
  , nodeVersionNow
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless, when)
import Data.Maybe (isJust)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import Maker.Version (nodeMajor)
import System.Directory
import System.FilePath ((</>))

-- | What @node --version@ says, or the empty string.
nodeVersionNow :: IO String
nodeVersionNow = maybe "" firstLine <$> output "node" ["--version"]

-- | Whether the Node on PATH will do: the floor's major version or later,
-- with npm beside it.
compatibleNode :: Context -> IO Bool
compatibleNode ctx = do
  version <- nodeVersionNow
  npm <- found "npm"
  pure $ case nodeMajor version of
    Just major -> major >= ctx.pins.nodeMinMajor && isJust npm
    Nothing -> False

-- | Install the pinned Node unless a compatible one is on PATH, and point the
-- toolchain's link at it.
installNode :: Context -> IO ()
installNode ctx = do
  compatible <- compatibleNode ctx
  let dir = nodeDir ctx
  unless compatible $ do
    let version = ctx.pins.nodeVersion
        tmp = dir <> ".tmp"
        archive = dir <> ".tar.xz"
    installed <- maybe "" firstLine <$> output (dir </> "bin" </> "node") ["--version"]
    when (installed /= "v" <> version) $ do
      say ctx ("installing Node " <> version <> " into " <> dir)
      mapM_ removePath [dir, tmp]
      createDirectoryIfMissing True tmp
      logLine ctx ("+ fetch Node " <> version)
      ok <- fetch ctx ("https://nodejs.org/dist/v" <> version <> "/node-v" <> version <> "-linux-x64.tar.xz") archive
      unless ok (failStep ctx "downloading Node")
      matches <- sha256Matches archive ctx.pins.nodeSha256
      unless matches (failStep ctx "checking Node's checksum")
      run ctx "unpacking Node" ["tar", "xJf", archive, "--strip-components=1", "--directory", tmp]
      removeFile archive
      renameDirectory tmp dir
    -- The link the environment file puts on PATH, made again only when it
    -- points elsewhere (or nowhere).
    let link = nodeLink ctx
    current <- try (getSymbolicLinkTarget link) :: IO (Either IOException FilePath)
    when (either (const True) (/= dir) current) $ do
      _ <- try (removeFile link) :: IO (Either IOException ())
      createDirectoryLink dir link
