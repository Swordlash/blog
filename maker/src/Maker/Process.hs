-- | Running the tools the toolchain is made of and reading what they print:
-- their versions, a one-line answer, whether they exist.
module Maker.Process
  ( output
  , outputIn
  , succeeds
  , firstLine
  , numericVersion
  , found
  , sha256Of
  , sha256Matches
  , sha256Text
  , removePath
  )
where

import Control.Exception (IOException, try)
import Control.Monad (when)
import Data.Char (isSpace)
import System.Directory (doesDirectoryExist, doesFileExist, findExecutable, removeDirectoryRecursive, removeFile)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc, readCreateProcess, readCreateProcessWithExitCode)

-- | What a command prints on its standard output when it succeeds, or
-- 'Nothing' when it fails or cannot be started. Its standard error is
-- dropped, as the bootstrap's @2>/dev/null@ drops it.
output :: FilePath -> [String] -> IO (Maybe String)
output = outputIn Nothing

-- | 'output', run in the directory given.
outputIn :: Maybe FilePath -> FilePath -> [String] -> IO (Maybe String)
outputIn dir command args = do
  result <- try (readCreateProcessWithExitCode (proc command args) {cwd = dir} "")
  pure $ case result of
    Right (ExitSuccess, out, _) -> Just out
    Right _ -> Nothing
    Left (_ :: IOException) -> Nothing

-- | Whether a command runs and succeeds.
succeeds :: FilePath -> [String] -> IO Bool
succeeds command args = (/= Nothing) <$> output command args

-- | The first line of a text, without the spaces around it.
firstLine :: String -> String
firstLine = trim . takeWhile (/= '\n')
  where
    trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | What @tool --numeric-version@ says, or the empty string, as the
-- bootstrap's @numeric_version@ gives it.
numericVersion :: FilePath -> IO String
numericVersion tool = maybe "" firstLine <$> output tool ["--numeric-version"]

-- | Where a command is on PATH, if it is.
found :: String -> IO (Maybe FilePath)
found = findExecutable

-- | A file's SHA-256, by @sha256sum@, as the bootstrap checks downloads.
sha256Of :: FilePath -> IO (Maybe String)
sha256Of file = fmap (takeWhile (not . isSpace)) <$> output "sha256sum" [file]

-- | Whether a file's SHA-256 is the one given.
sha256Matches :: FilePath -> String -> IO Bool
sha256Matches file expected = (== Just expected) <$> sha256Of file

-- | The SHA-256 of a text, by @sha256sum@, in hexadecimal.
sha256Text :: String -> IO String
sha256Text text = takeWhile (not . isSpace) <$> readCreateProcess (proc "sha256sum" []) text

-- | Remove a file or a directory with everything in it, if it is there.
removePath :: FilePath -> IO ()
removePath path = do
  isDir <- doesDirectoryExist path
  isFile <- doesFileExist path
  when isDir (removeDirectoryRecursive path)
  when isFile (removeFile path)
