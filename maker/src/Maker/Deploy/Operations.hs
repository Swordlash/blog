-- | 'Operations' is how the move to PostgreSQL ("Maker.Deploy.Move")
-- changes files: every rename, copy, write, removal and permission change
-- of the move goes through one of this module's functions, and each is
-- one counted operation. "Maker.Deploy.Move" imports none of
-- "System.Directory"'s functions that change files, so an operation added
-- there is counted too, or does not compile; the deploy's tests also check
-- its source for them.
--
-- The count is what the tests drive. With @WIKI_TEST_MOVE_OPERATIONS=FILE@
-- each operation appends its number and what it does to FILE, so a test
-- learns how many there are from the code itself. With
-- @WIKI_TEST_MOVE_FAILPOINT=N@ the N-th operation fails, as an I/O error
-- would, before it does anything. A test runs the move once for each N and
-- checks what the recovery leaves. Neither variable is set outside the
-- tests, and without them an operation is just what it does.
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
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM_, when)
import Data.ByteString qualified as BS
import Data.IORef
import Maker.Deploy.Plan (runInherit)
import System.Directory qualified as Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode)
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
  n <- atomicModifyIORef' o.counted (\k -> (k + 1, k + 1))
  forM_ o.logFile $ \f -> appendFile f (show n <> " " <> what <> "\n")
  when (o.failAt == Just n) $ throwIO (userError ("failpoint " <> show n <> ": " <> what))
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
-- them (@systemctl --user daemon-reload@), as one operation.
command :: Operations -> FilePath -> [String] -> IO ExitCode
command o program args = operation o (unwords (program : args)) (runInherit program args)

-- | An action of another module that is one operation, done whole or not
-- at all (the state file, written to a temporary file and renamed), or
-- whose partial effect the move undoes as a whole (PostgreSQL's files,
-- which the move saves first): counted as one.
step :: Operations -> String -> IO a -> IO a
step = operation
