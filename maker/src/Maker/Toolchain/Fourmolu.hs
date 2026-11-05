-- | fourmolu, the formatter @npm run format@ runs: any fourmolu on PATH that
-- reports the pinned version will do. Otherwise the release binary goes
-- into ghcup's bin directory, which the environment file puts on PATH; a
-- network that refuses GitHub's release downloads (Claude Code's cloud
-- sessions do) gets one built from Hackage instead, slow but needing nothing
-- else. The log says which it was.
module Maker.Toolchain.Fourmolu
  ( fourmoluVersionNow
  , installFourmolu
  )
where

import Control.Monad (unless, when)
import Data.Maybe (fromMaybe)
import Maker.Context
import Maker.Log
import Maker.Pins (Pins (..))
import Maker.Process
import System.Directory
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- | The first line of what @fourmolu --version@ says (@fourmolu 0.21.0.0@),
-- or the empty string.
fourmoluVersionNow :: IO String
fourmoluVersionNow = maybe "" firstLine <$> output "fourmolu" ["--version"]

-- | Install the pinned fourmolu unless one is on PATH; answers where it is.
installFourmolu :: Context -> IO FilePath
installFourmolu ctx = do
  let version = ctx.pins.fourmoluVersion
  now <- fourmoluVersionNow
  if now == "fourmolu " <> version
    then fromMaybe "fourmolu" <$> found "fourmolu"
    else do
      let target = ctx.ghcupBin </> "fourmolu"
          tmp = target <> ".download"
          zipFile = tmp <> ".zip"
      createDirectoryIfMissing True ctx.ghcupBin
      mapM_ removePath [tmp, zipFile]
      logLine ctx ("+ fetch fourmolu " <> version <> " release zip")
      fetched <-
        fetch
          ctx
          ("https://github.com/fourmolu/fourmolu/releases/download/v" <> version <> "/fourmolu-" <> version <> "-linux-x86_64.zip")
          zipFile
      if fetched
        then do
          matches <- sha256Matches zipFile ctx.pins.fourmoluSha256
          unless matches (failStep ctx "checking fourmolu's checksum")
          -- The zip holds one directory with the binary in it; -j drops the
          -- directory.
          code <- runQuiet ctx ["unzip", "-q", "-o", "-j", zipFile, "*/fourmolu", "-d", tmp]
          when (code /= ExitSuccess) (failStep ctx "unpacking fourmolu's release zip")
          perms <- getPermissions (tmp </> "fourmolu")
          setPermissions (tmp </> "fourmolu") (setOwnerExecutable True perms)
          renameFile (tmp </> "fourmolu") target
          mapM_ removePath [tmp, zipFile]
          say ctx ("installed fourmolu " <> version <> "'s release binary into " <> ctx.ghcupBin)
        else do
          mapM_ removePath [tmp, zipFile]
          say ctx ("fourmolu's release binary could not be downloaded; building fourmolu " <> version <> " from Hackage into " <> ctx.ghcupBin <> " (this takes a while)")
          ghc <- fromMaybe "ghc" <$> found "ghc"
          run
            ctx
            "building fourmolu"
            [ "cabal"
            , "install"
            , "fourmolu-" <> version
            , "--ignore-project"
            , "--with-compiler=" <> ghc
            , "--installdir=" <> ctx.ghcupBin
            , "--install-method=copy"
            , "--overwrite-policy=always"
            ]
          say ctx ("built fourmolu " <> version <> " from Hackage into " <> ctx.ghcupBin)
      pure target
