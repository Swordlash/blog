-- | 'Operations' is how the move to PostgreSQL ("Maker.Deploy.Move")
-- changes files and runs commands: every rename, copy, write, removal and
-- permission change of the move, and every external command it runs (but
-- the deploy's own helpers it calls whole), goes through one of this
-- module's functions, and each is one counted operation.
-- "Maker.Deploy.Move" imports none of "System.Directory"'s functions that
-- change files, nor the deploy's ways of running a command, so an
-- operation added there is counted too, or does not compile; the deploy's
-- tests also check its source for them.
--
-- A command's exit code is never thrown away: 'run' and 'compose' answer
-- it, and 'output' answers whether the command succeeded with what it
-- printed, to a caller that must look at them (GHC's unused-do-bind
-- warning, an error in this project, catches a bare call, and the source
-- check a discarded one). 'report' alone runs a command whose result means
-- nothing to the move: it shows a service's status.
--
-- The count is what the tests drive. With @WIKI_TEST_MOVE_OPERATIONS=FILE@
-- each operation appends its number and what it does to FILE, so a test
-- learns how many there are from the code itself. With
-- @WIKI_TEST_MOVE_FAILPOINT=N@ the N-th operation fails before it does
-- anything: a file operation as an I/O error would, a command as one that
-- exits with 97, or prints nothing and fails. A test runs the move once for
-- each N and checks what the recovery leaves. Neither variable is set
-- outside the tests, and without them an operation is just what it does.
module Maker.Deploy.Operations
  ( Operations
  , operations
  , rename
  , renameDir
  , copy
  , writeText
  , writeBytes
  , remove
  , makeDir
  , permissions
  , command
  , step
  , run
  , compose
  , output
  , report
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.ByteString qualified as BS
import Data.IORef
import Maker.Deploy.Plan (outputOf, runInherit, warn)
import Maker.Deploy.Prepare (pgCompose)
import System.Directory qualified as Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)

-- | 'Operations' counts the move's file operations: how many have run, the
-- one to fail (@WIKI_TEST_MOVE_FAILPOINT@), and the file each is logged in
-- (@WIKI_TEST_MOVE_OPERATIONS@).
data Operations = Operations
  { counted :: IORef Int
  , failAt :: Maybe Int
  , logFile :: Maybe FilePath
  }

-- | The move's operations, none run yet, with the tests' variables read.
operations :: IO Operations
operations = do
  counted <- newIORef 0
  failAt <- (>>= readMaybe) <$> lookupEnv "WIKI_TEST_MOVE_FAILPOINT"
  logFile <- (>>= \f -> if null f then Nothing else Just f) <$> lookupEnv "WIKI_TEST_MOVE_OPERATIONS"
  pure Operations {counted, failAt, logFile}

-- | One operation: counted, logged, failed when it is the one to fail, and
-- otherwise done.
operation :: Operations -> String -> IO a -> IO a
operation o what act = do
  failing <- count o what
  when failing $ throwIO (userError ("failpoint: " <> what))
  act

-- | Rename a file.
rename :: Operations -> FilePath -> FilePath -> IO ()
rename o from to = operation o ("rename " <> from <> " to " <> to) (Directory.renameFile from to)

-- | Rename a directory.
renameDir :: Operations -> FilePath -> FilePath -> IO ()
renameDir o from to = operation o ("rename " <> from <> " to " <> to) (Directory.renameDirectory from to)

-- | Copy a file, atomically: the copy appears whole or not at all.
copy :: Operations -> FilePath -> FilePath -> IO ()
copy o from to = operation o ("copy " <> from <> " to " <> to) (Directory.copyFile from to)

-- | Write a text file.
writeText :: Operations -> FilePath -> String -> IO ()
writeText o file text = operation o ("write " <> file) (writeFile file text)

-- | Write a file's bytes.
writeBytes :: Operations -> FilePath -> BS.ByteString -> IO ()
writeBytes o file bytes = operation o ("write " <> file) (BS.writeFile file bytes)

-- | Remove a file or a directory with all it holds.
remove :: Operations -> FilePath -> IO ()
remove o path = operation o ("remove " <> path) (Directory.removePathForcibly path)

-- | Make a directory, with the directories above it.
makeDir :: Operations -> FilePath -> IO ()
makeDir o path = operation o ("make " <> path) (Directory.createDirectoryIfMissing True path)

-- | Set a file's permissions.
permissions :: Operations -> FilePath -> Directory.Permissions -> IO ()
permissions o path perms = operation o ("permissions of " <> path) (Directory.setPermissions path perms)

-- | Run a command that changes files (@cp -R@), or the system's view of
-- them (@systemctl --user daemon-reload@), as 'run' does.
command :: Operations -> FilePath -> [String] -> IO ExitCode
command = run

-- | An action of another module that is one operation, done whole or not
-- at all (the state file, written to a temporary file and renamed), or
-- whose partial effect the move undoes as a whole (PostgreSQL's files,
-- which the move saves first): counted as one.
step :: Operations -> String -> IO a -> IO a
step = operation

-- | Whether this operation is the one to fail: counted and logged, and
-- 'True' for the failpoint's, which the caller then makes fail its own way
-- (a command that fails rather than an exception).
count :: Operations -> String -> IO Bool
count o what = do
  n <- atomicModifyIORef' o.counted (\k -> (k + 1, k + 1))
  forM_ o.logFile $ \f -> appendFile f (show n <> " " <> what <> "\n")
  let failing = o.failAt == Just n
  when failing (warn ("failpoint " <> show n <> ": " <> what <> " (made to fail)"))
  pure failing

-- | Run a command, its output on the terminal, and answer how it ended:
-- with 97, and without running it, at the failpoint.
run :: Operations -> FilePath -> [String] -> IO ExitCode
run o program args = do
  failing <- count o (unwords (program : args))
  if failing then pure (ExitFailure 97) else runInherit program args

-- | docker compose on a deployment's project, with its files and port
-- ("Maker.Deploy.Prepare"'s 'pgCompose'), as 'run'.
compose :: Operations -> String -> FilePath -> String -> [String] -> IO ExitCode
compose o name pd port args = do
  failing <- count o (unwords (["docker", "compose", "--project-name", name] <> args))
  if failing then pure (ExitFailure 97) else pgCompose name pd port args

-- | What a command prints, and whether it succeeded; at the failpoint,
-- nothing and a failure.
output :: Operations -> FilePath -> [String] -> IO (Bool, String)
output o program args = do
  failing <- count o (unwords (program : args))
  if failing then pure (False, "") else outputOf program args

-- | Run a command only to show what it prints (a service's status): its
-- exit code means nothing to the move. Not counted.
report :: FilePath -> [String] -> IO ()
report program args = () <$ runInherit program args
