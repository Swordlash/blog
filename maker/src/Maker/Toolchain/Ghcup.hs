-- | ghcup, through which the cross compiler is installed: ghcup itself when
-- it is missing, and a tool that counts as installed only once its versioned
-- binary runs and reports the pinned version.
module Maker.Toolchain.Ghcup
  ( installGhcup
  , managedToolReady
  , ghcupTool
  )
where

import Control.Monad (unless, when)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import System.Directory (createDirectoryIfMissing, emptyPermissions, renameFile, setOwnerExecutable, setOwnerReadable, setOwnerWritable, setPermissions)
import System.FilePath ((</>))

-- | Install ghcup into its bin directory when it does not run: the pinned
-- release, checked against its checksum.
installGhcup :: Context -> IO ()
installGhcup ctx = do
  works <- succeeds (ghcup ctx) ["--version"]
  unless works $ do
    let version = ctx.pins.ghcupVersion
        tmp = ghcup ctx <> ".download"
    say ctx ("installing ghcup " <> version <> " into " <> ctx.ghcupBin)
    createDirectoryIfMissing True ctx.ghcupBin
    logLine ctx ("+ fetch ghcup " <> version)
    ok <- fetch ctx ("https://downloads.haskell.org/~ghcup/" <> version <> "/x86_64-linux-ghcup-" <> version) tmp
    unless ok (failStep ctx "downloading ghcup")
    matches <- sha256Matches tmp ctx.pins.ghcupSha256
    unless matches (failStep ctx "checking ghcup's checksum")
    setPermissions tmp (setOwnerExecutable True (setOwnerWritable True (setOwnerReadable True emptyPermissions)))
    renameFile tmp (ghcup ctx)

-- | Whether a tool ghcup installed is there: its versioned binary (@binary@,
-- in ghcup's bin directory) reports the version, and ghcup knows where the
-- tool at that version is.
managedToolReady :: Context -> String -> String -> String -> String -> IO Bool
managedToolReady ctx tool version binary reports = do
  said <- numericVersion (ctx.ghcupBin </> binary)
  if said /= reports then pure False else succeeds (ghcup ctx) ["whereis", tool, version]

-- | Install a tool with ghcup unless it is there, by the action given the
-- step's name. A directory an interrupted install left behind does not
-- count, and is removed first.
ghcupTool :: Context -> String -> String -> String -> String -> (String -> IO ()) -> IO ()
ghcupTool ctx tool version binary reports installWith = do
  ready <- managedToolReady ctx tool version binary reports
  unless ready $ do
    say ctx ("installing " <> tool <> " " <> version <> " with ghcup")
    known <- succeeds (ghcup ctx) ["whereis", tool, version]
    when known (run ctx ("removing a broken " <> tool <> " " <> version) [ghcup ctx, "rm", tool, version])
    installWith ("installing " <> tool <> " " <> version)
