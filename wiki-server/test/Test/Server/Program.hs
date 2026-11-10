-- | The wiki-server program itself, run as a child by the tests that need
-- a real process: its console in another locale than the test's, as the
-- rehearsal runs an old program's console. The test suite's
-- @build-tool-depends@ puts the program on PATH while the tests run.
module Test.Server.Program
  ( wikiServerProgram
  , cLocale
  , placeArgsOf
  , runBytes
  )
where

import Data.ByteString qualified as BS
import Protolude
import System.Directory (findExecutable)
import System.Environment (getEnvironment)
import System.Process (CreateProcess (..), StdStream (..), proc, waitForProcess, withCreateProcess)
import Test.Database (choiceOf)
import Wiki.Server.Options (DatabaseChoice (..))
import Wiki.Server.Storage (Place (..))

-- | Where the wiki-server program is: the first on PATH, which @cabal
-- test@ makes this package's own. A test fails at once without it.
wikiServerProgram :: IO FilePath
wikiServerProgram =
  findExecutable "wiki-server"
    >>= maybe (panic "wiki-server is not on PATH: run the tests with cabal test, which puts the program there") pure

-- | This process's environment with the C locale in place of whatever
-- locale it names: what a deploy over a bare ssh command, or from a
-- systemd unit, often has.
cLocale :: IO [([Char], [Char])]
cLocale = (("LC_ALL", "C") :) . filter (\(k, _) -> k `notElem` ["LC_ALL", "LC_CTYPE", "LANG"]) <$> getEnvironment

-- | A place's options on a command line: @--data@ and the database's.
placeArgsOf :: Place -> [[Char]]
placeArgsOf at =
  ["--data", at.dataDir] <> case choiceOf at.database of
    SqliteChosen file -> ["--sqlite", file]
    PostgresChosen url _ -> ["--database", toS url]
    InDataDirectory -> []

-- | Run a program in this environment, with nothing on its standard
-- input: how it exited, and the bytes it wrote to its standard output and
-- its standard error, as they are, not decoded through any locale.
runBytes :: [([Char], [Char])] -> FilePath -> [[Char]] -> IO (ExitCode, ByteString, ByteString)
runBytes environment program args =
  withCreateProcess (proc program args) {env = Just environment, std_in = NoStream, std_out = CreatePipe, std_err = CreatePipe} $ \_ out err process -> do
    -- Standard error is read on a thread of its own, so that neither pipe
    -- fills while the other is read.
    errors <- async (maybe (pure "") BS.hGetContents err)
    written <- maybe (pure "") BS.hGetContents out
    code <- waitForProcess process
    (code,written,) <$> wait errors
