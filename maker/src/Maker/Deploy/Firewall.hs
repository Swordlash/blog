-- | The deploy's firewall rule, through ufw only: a rule that lets the
-- tailnet's interface reach the deployment's port. Tailscale's ACLs and the
-- bind address already limit who can connect, so the rule is a second line
-- the owner may or may not have. Every change goes through @sudo -n@, so the
-- deploy never stops at a password prompt; where sudo wants one, the
-- commands are printed for the owner to run. This is
-- @toolchain/deploy-lib.sh@'s firewall, which undeploy-local.sh still uses.
module Maker.Deploy.Firewall
  ( Firewall
  , Status (..)
  , probe
  , status
  , explain
  , open
  , close
  , report
  , quoteArgs
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, unless)
import Data.IORef
import Data.List (isPrefixOf, sort)
import Data.Maybe (listToMaybe)
import Maker.Deploy.Plan (outputOf, prog, runInherit, say, succeeds, warn)
import Maker.Deploy.State (stateGet)
import System.Directory (doesFileExist, executable, findExecutable, getPermissions, listDirectory, readable)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeExtension, (</>))

-- | What ufw is here: absent, inactive, active (sudo works), locked
-- (active, but sudo needs a password) or unknown (sudo needs a password and
-- ufw's configuration cannot be read).
data Status = Absent | Inactive | Active | Locked | Unknown
  deriving (Eq, Show)

-- | The firewall as probed, with the commands printed for the owner that
-- have not been reported yet.
data Firewall = Firewall
  { status' :: Status
  , ufw :: FilePath
  , pending :: IORef [String]
  }

-- | What ufw is here.
status :: Firewall -> Status
status f = f.status'

-- | The interface the rule is for.
interface :: String
interface = "tailscale0"

-- | Find ufw and tell how it stands.
probe :: IO Firewall
probe = do
  pending' <- newIORef []
  found <- findUfw
  case found of
    Nothing -> pure (Firewall Absent "" pending')
    Just path -> do
      sudo <- succeeds "sudo" ["-n", "true"]
      s <-
        if sudo
          then do
            (_, out) <- outputOf "sudo" ["-n", path, "status"]
            pure (if any ("Status: active" `isPrefixOf`) (lines out) then Active else Inactive)
          else do
            conf <- maybe "/etc/ufw/ufw.conf" id <$> lookupEnv "WIKI_DEPLOY_UFW_CONF"
            canRead <- isReadable conf
            if not canRead
              then pure Unknown
              else do
                text <- readFile conf
                pure (if any ("ENABLED=yes" `isPrefixOf`) (lines text) then Locked else Inactive)
      pure (Firewall s path pending')
  where
    isReadable path = do
      exists <- doesFileExist path
      if exists then readable <$> getPermissions path else pure False

-- | ufw on PATH, or in the system's sbin directories, which an ordinary
-- user's PATH often lacks (@WIKI_DEPLOY_SBIN@ names others, for the tests).
findUfw :: IO (Maybe FilePath)
findUfw = do
  onPath <- findExecutable "ufw"
  case onPath of
    Just p -> pure (Just p)
    Nothing -> do
      dirs <- maybe "/usr/sbin:/sbin" id <$> lookupEnv "WIKI_DEPLOY_SBIN"
      listToMaybe <$> filterM isExecutable [d </> "ufw" | d <- splitOn ':' dirs, not (null d)]
  where
    isExecutable p = do
      exists <- doesFileExist p
      if exists then executable <$> getPermissions p else pure False

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, _ : rest) -> a : splitOn c rest
  (a, []) -> [a]

-- | Say why no rule changes, when ufw is not there or not active.
explain :: Firewall -> IO ()
explain f = case f.status' of
  Absent -> say "ufw is not installed: no firewall rule to change (Tailscale's ACLs and the bind address limit who can connect)"
  Inactive -> say "ufw is not active: no firewall rule to change (Tailscale's ACLs and the bind address limit who can connect)"
  _ -> pure ()

-- | Run one ufw command as root, or keep it to print when that needs a
-- password.
ufwRun :: Firewall -> [String] -> IO ()
ufwRun f args = case f.status' of
  Active -> do
    say ("sudo ufw " <> unwords args)
    code <- runInherit "sudo" (["-n", f.ufw] <> args)
    unless (code == ExitSuccess) (warn ("ufw " <> unwords args <> " failed"))
  Locked -> keep
  Unknown -> keep
  _ -> pure ()
  where
    keep = modifyIORef' f.pending (<> ["    sudo ufw " <> quoteArgs args])

-- | Arguments as a shell would need them typed, quoting only those that
-- need it.
quoteArgs :: [String] -> String
quoteArgs = unwords . map quote
  where
    quote a
      | all plain a = a
      | otherwise = "'" <> a <> "'"
    plain c = c `elem` ("_./:=@-" :: String) || c `elem` ['A' .. 'Z'] || c `elem` ['a' .. 'z'] || c `elem` ['0' .. '9']

-- | Print the commands ufw could not run itself, once.
report :: Firewall -> IO ()
report f = do
  kept <- readIORef f.pending
  unless (null kept) $ do
    let commands = concatMap ("\n" <>) kept
    case f.status' of
      Locked -> putStrLn (prog <> ": sudo needs a password, so run these yourself:" <> commands)
      Unknown -> putStrLn (prog <> ": sudo needs a password and ufw's state cannot be read; if 'sudo ufw status' says it is active, run:" <> commands)
      _ -> pure ()
    writeIORef f.pending []

-- | Let the tailnet reach a port; the rule carries the deployment's name.
open :: Firewall -> String -> String -> IO ()
open f name port = ufwRun f ["allow", "in", "on", interface, "to", "any", "port", port, "proto", "tcp", "comment", name]

-- | Close a port's rule, unless another deployment whose state is in the
-- same directory (the home directory's, or the same prefix's) still claims
-- it. The arguments are the state directory, this deployment's state file
-- and the port.
close :: Firewall -> FilePath -> FilePath -> String -> IO ()
close f stateDir stateFile port = do
  shared <- portRuleShared stateDir stateFile port
  if shared
    then say ("leaving the firewall rule for port " <> port <> " open: another deployment uses it")
    else -- ufw matches the rule to delete on its specification; the
    -- comment is not part of it.
      ufwRun f ["delete", "allow", "in", "on", interface, "to", "any", "port", port, "proto", "tcp"]

portRuleShared :: FilePath -> FilePath -> String -> IO Bool
portRuleShared stateDir stateFile port = do
  entries <- either (\(_ :: IOException) -> []) id <$> try (listDirectory stateDir)
  let others = [stateDir </> e | e <- sort entries, takeExtension e == ".state", stateDir </> e /= stateFile]
  files <- filterM doesFileExist others
  rules <- mapM (stateGet "rule_port") files
  pure (port `elem` rules)
