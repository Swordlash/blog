-- | Where a deployment's pieces are, as toolchain/deploy-lib.sh finds them
-- for the deploy: its name checked, its prefix resolved, the directory of
-- its state and its unit file, and whether a deployment made before
-- @--prefix@ waits to be adopted under the prefix. The shell keeps its own
-- copy of these for @--status@, @--stop@ and undeploy-local.sh, which need
-- no GHC; the two must find the same files.
module Maker.Deploy.Layout
  ( Layout (..)
  , validName
  , checkName
  , layoutFor
  , requirePrefixOfUnit
  , unsafeDir
  , markedFor
  , realpath
  , markerName
  )
where

import Control.Monad (unless, when)
import Data.List (isPrefixOf, stripPrefix)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)
import Maker.Deploy.Plan
import Maker.Deploy.State (stateGet)
import System.Directory (doesFileExist, getCurrentDirectory, getHomeDirectory)
import System.Environment (lookupEnv)
import System.FilePath ((</>))

-- | The marker file a deployment's directory holds, which names the
-- deployment: only a directory carrying it is ever emptied.
markerName :: FilePath
markerName = ".wiki-demo-deployment"

-- | A deployment's places: its name (without @.service@), its prefix
-- (empty for one in the home directory), the directory of its state and
-- its state file, its unit file and the directory of the units, the home
-- directory's state directory, and whether its state waits to be adopted
-- under the prefix.
data Layout = Layout
  { name :: String
  , prefix :: FilePath
  , stateDir :: FilePath
  , stateFile :: FilePath
  , unitDir :: FilePath
  , unitFile :: FilePath
  , homeStateDir :: FilePath
  , adoptable :: Bool
  }
  deriving (Eq, Show)

-- | Whether a name is one systemd accepts as a unit's and a file system as
-- a file's: letters, digits and @_.\@-@, not starting with a dot.
validName :: String -> Bool
validName n = not (null n) && not ("." `isPrefixOf` n) && all ok n
  where
    ok c = c `elem` ("_.@-" :: String) || c `elem` ['a' .. 'z'] || c `elem` ['A' .. 'Z'] || c `elem` ['0' .. '9']

-- | The name without its @.service@, or the deploy stops, as check_name.
checkName :: String -> IO String
checkName given = do
  let n = fromMaybe given (stripSuffix ".service" given)
  unless (validName n) (die ("invalid --name '" <> given <> "': use letters, digits, '-', '_', '.' and '@'"))
  pure n
  where
    stripSuffix s t = reverse <$> stripPrefix (reverse s) (reverse t)

-- | A path as @realpath@ resolves it (with @-m@ when the path need not
-- exist): the program the shell resolves its paths with, so that the two
-- cannot disagree.
realpath :: [String] -> FilePath -> IO FilePath
realpath flags path = do
  (ok, out) <- outputOf "realpath" (flags <> [path])
  unless ok (die ("realpath " <> unwords flags <> " " <> path <> " failed"))
  pure (takeWhile (/= '\n') out)

-- | The deployment's places, as resolve_prefix and layout find them. The
-- prefix is made absolute from the directory the deploy runs in, and its
-- links are resolved. A deployment made before --prefix and named by it
-- now still has its state in the home directory: it is read there, and is
-- adoptable. A state in the home directory that names another directory is
-- another deployment of the same name, and the deploy stops.
layoutFor :: String -> String -> IO Layout
layoutFor n optPrefix = do
  home <- getHomeDirectory
  config <- maybe (home </> ".config") (\c -> if null c then home </> ".config" else c) <$> lookupEnv "XDG_CONFIG_HOME"
  here <- getCurrentDirectory
  pwd <- fromMaybe here <$> lookupEnv "PWD"
  p <-
    if null optPrefix
      then pure ""
      else realpath ["-m"] (if "/" `isPrefixOf` optPrefix then optPrefix else pwd <> "/" <> optPrefix)
  let homeState = config </> "wiki-demo"
      units = config </> "systemd" </> "user"
      underPrefix = p </> "state"
      file d = d </> (n <> ".state")
  base <-
    pure
      Layout
        { name = n
        , prefix = p
        , stateDir = if null p then homeState else underPrefix
        , stateFile = file (if null p then homeState else underPrefix)
        , unitDir = units
        , unitFile = units </> (n <> ".service")
        , homeStateDir = homeState
        , adoptable = False
        }
  if null p
    then pure base
    else do
      own <- doesFileExist (file underPrefix)
      old <- doesFileExist (file homeState)
      if own || not old
        then pure base
        else do
          at <- stateGet "dir" (file homeState)
          when (at /= p) $
            die ("the deployment " <> n <> " is at " <> at <> ", its state in " <> homeState <> " and the wiki's data in " <> at <> "/data: deploy it there with --prefix " <> at <> ", or this one under another --name")
          pure base {stateDir = homeState, stateFile = file homeState, adoptable = True}

-- | The unit in the home directory names the prefix of the deployment it
-- belongs to ("# Prefix: DIR"; a deployment in the home directory writes
-- none). A run named for another place stops, saying what to give, and
-- what else it could do (the hint). A deployment being adopted is the
-- unit's own.
requirePrefixOfUnit :: Layout -> String -> IO ()
requirePrefixOfUnit l hint = do
  there <- doesFileExist l.unitFile
  when (there && not l.adoptable) $ do
    text <- readFile l.unitFile
    let elsewhere = fromMaybe "" (listToMaybe (mapMaybe (stripPrefix "# Prefix: ") (lines text)))
    length text `seq` pure ()
    unless (elsewhere == l.prefix) $
      if null elsewhere
        then die ("the deployment " <> l.name <> " is in the home directory (its unit names no prefix): run this without --prefix" <> hint)
        else die ("the deployment " <> l.name <> " is under " <> elsewhere <> ": run this with --prefix " <> elsewhere <> hint)

-- | Directories never to empty or delete, whatever their marker says: the
-- root, the home directory and any directory above it.
unsafeDir :: FilePath -> IO Bool
unsafeDir d = do
  home <- getHomeDirectory >>= realpath ["-m"]
  pure (d == "/" || d == home || (d <> "/") `isPrefixOf` (home <> "/"))

-- | Whether a directory carries the marker of the named deployment.
markedFor :: FilePath -> String -> IO Bool
markedFor d n = do
  there <- doesFileExist (d </> markerName)
  if not there then pure False else (== n) <$> stateGet "name" (d </> markerName)
