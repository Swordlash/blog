-- | The maker's command line; see "Maker.Cli".
module Main (main) where

import GHC.IO.Encoding (mkTextEncoding, setFileSystemEncoding, setForeignEncoding, setLocaleEncoding)
import Maker.Cli qualified
import System.IO (hSetEncoding, stderr, stdin, stdout)

-- | Run the command line with one encoding for everything: UTF-8 with
-- ROUNDTRIP for the terminal, files, paths and arguments, whatever the
-- locale says. The maker's messages hold characters beyond ASCII (the
-- deploy's "…"), which a handle in the C locale cannot write, and the shell
-- it replaces writes them as UTF-8 in every locale. ROUNDTRIP decodes a
-- byte that is not UTF-8 to a character that encodes back to the same
-- byte, so what programs print, a log, or a path in another encoding is
-- read without failing and passed on unchanged. One encoding for all means
-- a path read from a file or a program's output names the same file when
-- it is passed to the system.
main :: IO ()
main = do
  utf8 <- mkTextEncoding "UTF-8//ROUNDTRIP"
  setFileSystemEncoding utf8
  setForeignEncoding utf8
  setLocaleEncoding utf8
  mapM_ (`hSetEncoding` utf8) [stdin, stdout, stderr]
  Maker.Cli.main
