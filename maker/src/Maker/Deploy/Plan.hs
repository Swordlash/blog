-- | The plan of a deploy: what the deploy's front ("Maker.Deploy.Front")
-- worked out from the options and the remembered state, by key, with the
-- names of the shell variables it was once written from. Each step after
-- the front reads it and adds what it works out ("Maker.Deploy.Page",
-- "Maker.Deploy.Tex", "Maker.Deploy.Prepare"), and "Maker.Deploy.Apply"
-- changes the running deployment from it. The state file is written from
-- it ("Maker.Deploy.State").
--
-- A key that was never set reads as the empty string, as an unset variable
-- does in the shell.
--
-- The module also holds the deploy's way of talking, which is the shell's:
-- @deploy-local: …@ on standard output, @deploy-local: warning: …@ and the
-- reason it stops on standard error.
module Maker.Deploy.Plan
  ( Plan
  , parsePlan
  , get
  , has
  , set
  , say
  , warn
  , die
  , prog
  , quietly
  , succeeds
  , outputOf
  , decodeFs
  , encodeFs
  , relay
  , tailLog
  , runInherit
  )
where

import Control.Exception (IOException, try)
import Data.Map.Strict qualified as Map
import Maker.Process (decodeFs, encodeFs, relay, tailLog)
import System.Exit (exitWith)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.Process.Typed

-- | The plan's values by key.
newtype Plan = Plan (Map.Map String String)
  deriving (Eq, Show)

-- | A plan's lines: @key=value@, the value the rest of the line. Lines
-- without @=@ and comments are skipped. A key given twice keeps its last
-- value, as a state file's does.
parsePlan :: String -> Plan
parsePlan = Plan . Map.fromList . concatMap entry . lines
  where
    entry ('#' : _) = []
    entry l = case break (== '=') l of
      (k, '=' : v) | not (null k) -> [(k, v)]
      _ -> []

-- | A value, empty when the plan has none.
get :: Plan -> String -> String
get (Plan m) k = Map.findWithDefault "" k m

-- | A plan with a value replaced: what the maker works out itself, which
-- the shell used to put into the plan.
set :: String -> String -> Plan -> Plan
set k v (Plan m) = Plan (Map.insert k v m)

-- | Whether a value is not empty.
has :: Plan -> String -> Bool
has p k = not (null (get p k))

-- | The deploy's name in its messages.
prog :: String
prog = "deploy-local"

-- | A step, on standard output.
say :: String -> IO ()
say message = putStrLn (prog <> ": " <> message) >> hFlush stdout

-- | A warning, on standard error.
warn :: String -> IO ()
warn message = hFlush stdout >> hPutStrLn stderr (prog <> ": warning: " <> message)

-- | Stop the deploy with a reason, as the shell's @die@ does.
die :: String -> IO a
die message = do
  hFlush stdout
  hPutStrLn stderr (prog <> ": " <> message)
  exitWith (ExitFailure 1)

-- | A process with no input whose output and errors are dropped.
quietly :: ProcessConfig i o e -> ProcessConfig () () ()
quietly = setStdin nullStream . setStdout nullStream . setStderr nullStream

-- | Whether a command runs and exits 0, its output dropped; 'False' when it
-- cannot be started.
succeeds :: FilePath -> [String] -> IO Bool
succeeds program args = do
  result <- try (runProcess (quietly (proc program args)))
  pure $ case result of
    Right ExitSuccess -> True
    Right _ -> False
    Left (_ :: IOException) -> False

-- | What a command prints on standard output, and whether it succeeded;
-- its errors are dropped, as @2>/dev/null@ drops them.
outputOf :: FilePath -> [String] -> IO (Bool, String)
outputOf program args = do
  result <- try (readProcessStdout (setStdin nullStream (setStderr nullStream (proc program args))))
  pure $ case result of
    Right (code, out) -> (code == ExitSuccess, decodeFs out)
    Left (_ :: IOException) -> (False, "")

-- | Run a command with the terminal's output and errors, and answer how it
-- ended; a command that cannot be started ends as 127, as in the shell.
runInherit :: FilePath -> [String] -> IO ExitCode
runInherit program args = do
  hFlush stdout
  result <- try (runProcess (proc program args))
  pure $ case result of
    Right code -> code
    Left (_ :: IOException) -> ExitFailure 127
