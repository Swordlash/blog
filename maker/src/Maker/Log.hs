{-# LANGUAGE InterruptibleFFI #-}

-- | The bootstrap's way of talking and of running commands: one line per
-- step on the terminal (@bootstrap: …@), every command's own output in the
-- log (@~/.wiki-toolchain/bootstrap.log@), and on a failure the log's end on
-- the terminal. The words are toolchain/bootstrap.sh's, since the hooks, the
-- deploy and their tests read them.
module Maker.Log
  ( say
  , sayErr
  , logLine
  , failStep
  , run
  , runWith
  , runLong
  , runQuiet
  , fetch
  , logSize
  , asRoot
  , withLock
  , command
  )
where

import Control.Exception (bracket)
import Control.Monad (unless, when)
import Data.Bits ((.|.))
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import Maker.Context (Context (..), Mode (..), logFile)
import Maker.Process (firstLine, output, relay, succeeds)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Exit (exitWith)
import System.FilePath (takeDirectory)
import System.IO
import System.Posix.IO (OpenFileFlags (..), OpenMode (..), closeFd, defaultFileFlags, openFd)
import System.Posix.User (getEffectiveUserID)
import System.Process.Typed

-- | A step, on the terminal and in the log with the time.
say :: Context -> String -> IO ()
say ctx message = do
  putStrLn ("bootstrap: " <> message)
  hFlush stdout
  now <- getZonedTime
  appendFile (logFile ctx) (formatTime defaultTimeLocale "%F %T" now <> " " <> message <> "\n")

-- | A line on the terminal's standard error, as @bootstrap: …@.
sayErr :: String -> IO ()
sayErr message = hPutStrLn stderr ("bootstrap: " <> message)

-- | A line in the log alone.
logLine :: Context -> String -> IO ()
logLine ctx line = appendFile (logFile ctx) (line <> "\n")

-- | Stop the run: the step that failed, then the end of the log, on the
-- terminal's standard error.
failStep :: Context -> String -> IO a
failStep ctx step = do
  sayErr (step <> " failed; the end of " <> logFile ctx <> ":")
  exists <- doesFileExist (logFile ctx)
  when exists $ do
    text <- readFile (logFile ctx)
    length text `seq` hPutStr stderr (unlines (lastLines 40 (lines text)))
  exitWith (ExitFailure 1)
  where
    lastLines n xs = drop (length xs - n) xs

-- | A command and its arguments as the log writes them.
command :: [String] -> String
command = unwords

-- | Run a command with its output in the log; on failure, stop the run.
run :: Context -> String -> [String] -> IO ()
run ctx step = runWith ctx step id

-- | 'run', with the process changed first (its directory, its environment).
runWith :: Context -> String -> (ProcessConfig () () () -> ProcessConfig () () ()) -> [String] -> IO ()
runWith _ _ _ [] = pure ()
runWith ctx step change (program : args) = do
  logLine ctx ("+ " <> command (program : args))
  code <- withFile (logFile ctx) AppendMode $ \h -> runProcess (intoLog h (change (proc program args)))
  unless (code == ExitSuccess) (failStep ctx step)

-- | A process with no input whose output and errors go to the log.
intoLog :: Handle -> ProcessConfig () () () -> ProcessConfig () () ()
intoLog h = setStdin nullStream . setStdout (useHandleOpen h) . setStderr (useHandleOpen h)

-- | Run a command with its output in the log, and answer how it ended,
-- without stopping the run when it fails.
runQuiet :: Context -> [String] -> IO ExitCode
runQuiet _ [] = pure ExitSuccess
runQuiet ctx (program : args) =
  withFile (logFile ctx) AppendMode $ \h -> runProcess (intoLog h (proc program args))

-- | Run a long step (a compiler's install, the wasm sysroot's setup, the
-- index's update) as 'run' does. In the build, native and static modes, which the
-- deploy uses, its output is also shown as it comes, so that a deploy does
-- not sit silent for minutes; the other modes keep it in the log alone.
runLong :: Context -> String -> (ProcessConfig () () () -> ProcessConfig () () ()) -> [String] -> IO ()
runLong ctx step change args
  | ctx.mode `notElem` [Build, Native, Static] = runWith ctx step change args
runLong _ _ _ [] = pure ()
runLong ctx step change (program : args) = do
  logLine ctx ("+ " <> command (program : args))
  -- Its output and its errors through one pipe, in the order they come,
  -- copied byte for byte to the terminal and the log.
  (code, _) <- withBinaryFile (logFile ctx) AppendMode $ \h -> relay (Just h) (change (proc program args))
  hFlush stdout
  unless (code == ExitSuccess) (failStep ctx step)

-- | Download a URL into a file, with what curl says in the log. 'False'
-- when the download fails.
fetch :: Context -> String -> FilePath -> IO Bool
fetch ctx url file =
  withFile (logFile ctx) AppendMode $ \h ->
    (== ExitSuccess) <$> runProcess (intoLog h (proc "curl" ["--fail", "--location", "--retry", "5", "--silent", "--show-error", "--output", file, url]))

-- | The log's size, to tell a run that did nothing (the log unchanged) from
-- one that did.
logSize :: Context -> IO Integer
logSize ctx = do
  exists <- doesFileExist (logFile ctx)
  if exists then getFileSize (logFile ctx) else pure 0

-- | What runs a command as root: nothing when this already is root, @sudo@
-- when it needs no password, and 'Nothing' otherwise: the bootstrap never
-- asks for a password.
--
-- The user is the one @id -u@ names, as the shell's bootstrap asks, so that
-- the bootstrap's tests, which run as root in CI, can pretend to be another
-- user with an @id@ of their own on PATH; without an @id@ the process's own
-- effective user counts.
asRoot :: IO (Maybe [String])
asRoot = do
  named <- output "id" ["-u"]
  uid <- maybe (show <$> getEffectiveUserID) (pure . firstLine) named
  if uid == "0"
    then pure (Just [])
    else do
      sudo <- succeeds "sudo" ["-n", "true"]
      pure (if sudo then Just ["sudo"] else Nothing)

-- | Hold a lock file for an action, saying so when another run holds it.
-- The lock is flock(2)'s, the lock toolchain/bootstrap.sh takes with the
-- flock command, so the two stages and their runs exclude each other.
withLock :: Context -> FilePath -> String -> IO a -> IO a
withLock ctx path what action =
  bracket open closeFd $ \fd -> do
    free <- c_flock (fromIntegral fd) (lockExclusive .|. lockNonBlocking)
    when (free /= 0) $ do
      say ctx ("another bootstrap holds " <> what <> "; waiting for it (its progress is in " <> logFile ctx <> ")")
      _ <- throwErrnoIfMinus1Retry "flock" (c_flock (fromIntegral fd) lockExclusive)
      pure ()
    action
  where
    -- The lock lives in the state directory, which a first run of
    -- @maker toolchain install@ finds missing: only an installing run of
    -- the bootstrap makes it before handing over.
    open = do
      createDirectoryIfMissing True (takeDirectory path)
      openFd path WriteOnly defaultFileFlags {creat = Just 0o644}

foreign import ccall interruptible "flock"
  c_flock :: CInt -> CInt -> IO CInt

lockExclusive, lockNonBlocking :: CInt
lockExclusive = 2
lockNonBlocking = 4
