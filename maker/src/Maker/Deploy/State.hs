-- | A deployment's state file, @<state dir>/<name>.state@: the options a
-- deploy remembers for the next one, and what undeploy-local.sh and
-- @--status@ read. Its format is @toolchain/deploy-lib.sh@'s @state_write@,
-- key for key, since the shell still reads it.
module Maker.Deploy.State
  ( stateKeys
  , renderState
  , writeState
  , stateGet
  )
where

import Control.Exception (IOException, try)
import Maker.Deploy.Plan (Plan, get)
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath (takeDirectory)

-- | The state file's keys in order, each with the plan's key it comes from
-- (the state's @toolchain@ is the plan's @toolchain_dir@).
stateKeys :: [(String, String)]
stateKeys =
  [ ("name", "name")
  , ("dir", "dir")
  , ("toolchain", "toolchain_dir")
  , ("port", "port")
  , ("bind", "bind")
  , ("bind_choice", "bind_choice")
  , ("rule_port", "rule_port")
  , ("mode", "mode")
  , ("admin_port", "admin_port")
  , ("https", "https")
  , ("way", "way")
  , ("tls_cert", "tls_cert")
  , ("tls_key", "tls_key")
  , ("tls_ca", "tls_ca")
  , ("https_host", "https_host")
  , ("serve_port", "serve_port")
  , ("db", "db")
  , ("db_port", "db_port")
  , ("backend_only", "backend_only")
  , ("backend_only_commit", "backend_only_commit")
  , ("app_page", "app_page")
  , ("bundle_locally", "bundle_locally")
  , ("system_tools", "system_tools")
  , ("npm_registry", "npm_registry")
  , ("hackage_mirror", "hackage_mirror")
  , ("texlive", "texlive")
  , ("texlive_dir", "texlive_dir")
  , ("texlive_mirror", "texlive_mirror")
  , ("perl_dir", "perl_dir")
  , ("whats_new", "whats_new")
  ]

-- | The state file's text for a plan, with the firewall's rule port as the
-- deploy has it now (it changes during the deploy). A plan with no mode is
-- a static deployment's, as the shell writes it.
renderState :: Plan -> String -> String
renderState plan rulePort =
  unlines ("# Written by toolchain/deploy-local.sh; read by it and by undeploy-local.sh." : map line stateKeys)
  where
    line (key, from) = key <> "=" <> value key from
    value "rule_port" _ = rulePort
    value "mode" from = let m = get plan from in if null m then "static" else m
    value _ from = get plan from

-- | Write a state file atomically: a deploy that stops halfway never leaves
-- half a file behind.
writeState :: FilePath -> String -> IO ()
writeState file text = do
  createDirectoryIfMissing True (takeDirectory file)
  writeFile (file <> ".tmp") text
  renameFile (file <> ".tmp") file

-- | One value of a state file, its last line for the key, or the empty
-- string when the file or the key is missing.
stateGet :: String -> FilePath -> IO String
stateGet key file = do
  text <- try (readFile file)
  pure $ case text of
    Left (_ :: IOException) -> ""
    Right t ->
      let values = [drop (length key + 1) l | l <- lines t, (key <> "=") == take (length key + 1) l]
       in if null values then "" else length t `seq` last values
