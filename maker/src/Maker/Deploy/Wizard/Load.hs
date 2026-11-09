-- | The wizard's answers for a deployment, filled from its state file as
-- the deploy finds it, with the paths resolved as the deploy resolves
-- them; and the wizard's @--args-from FILE@, which prints the command line
-- a file of answers makes instead of showing the screens (the tests use
-- it: toolchain/test-configure.sh). It needs no terminal library, so it is
-- in the maker's library; the screens are @maker-tui deploy@.
module Maker.Deploy.Wizard.Load
  ( absolute
  , resolvePaths
  , statePath
  , prefill
  , loadDeployment
  , fromFile
  , usage
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Maker.Deploy.Wizard.Answers
import Maker.Deploy.Wizard.Command
import Maker.Process (decodeFs)
import System.Directory (doesFileExist, getHomeDirectory, makeAbsolute)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Process.Typed (proc, readProcessStdout)

-- * Paths and the state file

-- | A path as the deploy will see it. ~ and ~/ are expanded, and a
-- relative path is taken from the directory toolchain/configure.sh was
-- started in (WIKI_CONFIGURE_DIR, which the wrapper sets before it changes
-- to the checkout's root), or else from the current directory. Then the
-- path is resolved by `realpath -m`, the program the deploy itself resolves
-- its paths with, so that the two cannot disagree: realpath follows
-- symbolic links and removes . and .. in an order of its own, which a
-- path such as /srv/missing/../link/../wiki depends on. The deploy needs
-- realpath too, so a machine without it fails here as the deploy would.
absolute :: Text -> IO Text
absolute t
  | T.null t = pure t
  | otherwise = do
      home <- getHomeDirectory
      let s = T.unpack t
          expanded
            | s == "~" = home
            | "~/" `T.isPrefixOf` t = home </> drop 2 s
            | otherwise = s
      started <- lookupEnv "WIKI_CONFIGURE_DIR"
      rooted <- case started of
        Just dir | not (null dir) -> pure (dir </> expanded)
        _ -> makeAbsolute expanded
      resolved <- try (readProcessStdout (proc "realpath" ["-m", rooted]))
      case resolved of
        Right (ExitSuccess, out) | (line : _) <- lines (decodeFs out), not (null line) -> pure (T.pack line)
        Right (ExitSuccess, _) -> ioError (userError ("realpath -m " <> rooted <> " printed nothing"))
        Right (code, _) -> ioError (userError ("realpath -m " <> rooted <> " failed (" <> show code <> ")"))
        Left e ->
          ioError
            ( userError
                ( "realpath -m "
                    <> rooted
                    <> " failed ("
                    <> show (e :: IOException)
                    <> "): the wizard resolves paths with realpath, as the deploy does; install coreutils"
                )
            )

-- | The answers' paths as the deploy will resolve them ('absolute'): the
-- prefix as the deploy keeps it in the state, the toolchain and the
-- certificate's files as the unit will name them, the directories TeX
-- Live's installer and Perl's source come from and libsodium's tarball, as
-- the deploy reads them.
resolvePaths :: Answers -> IO Answers
resolvePaths a = do
  p <- absolute (a.prefix)
  t <- absolute (a.toolchain)
  c <- absolute (a.tlsCert)
  k <- absolute (a.tlsKey)
  ca <- absolute (a.tlsCa)
  i <- source (a.texInstaller)
  ps <- source (a.perlSource)
  ap <- absolute (a.appPage)
  ls <- absolute (a.libsodiumSource)
  pure a {prefix = p, toolchain = t, tlsCert = c, tlsKey = k, tlsCa = ca, texInstaller = i, perlSource = ps, appPage = ap, libsodiumSource = ls}
  where
    -- A source of the TeX step is a URL, kept as it is, or a directory.
    source v = if "://" `T.isInfixOf` v then pure v else absolute v

-- | The state file of a deployment, found as deploy-lib.sh's layout finds
-- it: under the prefix (<prefix>/state/<name>.state), or for a deployment
-- in the home directory in ${XDG_CONFIG_HOME:-~/.config}/wiki-demo. A
-- deployment made before --prefix keeps its state in the home directory
-- until a deploy adopts it, and is found there when its dir is the prefix.
-- The prefix is absolute, with its links resolved ('resolvePaths').
statePath :: Text -> Text -> IO (Maybe FilePath)
statePath pfx nm = do
  home <- getHomeDirectory
  -- As ${XDG_CONFIG_HOME:-$HOME/.config}: an empty value counts as unset.
  config <- maybe (home </> ".config") (\c -> if null c then home </> ".config" else c) <$> lookupEnv "XDG_CONFIG_HOME"
  let file = T.unpack (fromMaybe nm (T.stripSuffix ".service" nm)) <> ".state"
      inHome = config </> "wiki-demo" </> file
  if T.null pfx
    then existing inHome
    else do
      underPrefix <- existing (T.unpack pfx </> "state" </> file)
      case underPrefix of
        Just f -> pure (Just f)
        Nothing -> do
          old <- existing inHome
          case old of
            Just f -> do
              kv <- keyValues <$> T.readFile f
              pure (if lookup "dir" (reverse kv) == Just pfx then Just f else Nothing)
            Nothing -> pure Nothing
  where
    existing f = do
      there <- doesFileExist f
      pure (if there then Just f else Nothing)

-- | The answers for a deployment: the given ones with the paths resolved
-- and, when the deployment has a state file, what it remembers; with the
-- file, or a note that none was found.
prefill :: Answers -> IO (Answers, Text)
prefill given = do
  a <- resolvePaths given
  found <- statePath (a.prefix) (a.name)
  case found of
    Just f -> do
      kv <- keyValues <$> T.readFile f
      pure (fromState kv a, "The answers are those of the last deploy, from " <> T.pack f <> ".")
    Nothing ->
      pure
        ( a
        , "No deployment "
            <> a.name
            <> (if T.null (a.prefix) then "" else " under " <> a.prefix)
            <> " yet: the answers are the first run's defaults."
        )

usage :: Text
usage =
  T.unlines
    [ "usage: sh toolchain/configure.sh [--system-tools] [--hackage-mirror URL] [--npm-registry URL] [--args-from FILE]"
    , ""
    , "Asks for the options of toolchain/deploy-local.sh in a few screens and runs"
    , "the deploy with them. With --args-from FILE it reads the answers from FILE"
    , "(key=value lines; see maker/src/Maker/Deploy/Wizard/Answers.hs) and prints the"
    , "command line instead. --system-tools, --hackage-mirror and --npm-registry,"
    , "for a machine that installs nothing from the internet, are given to the"
    , "bootstrap that installs the wizard's compiler, and start the wizard's"
    , "screens with those answers."
    ]

-- | A deployment's answers: its state over the answers given (prefill),
-- then the presets of the wrapper's options (presetArgs, which has checked
-- that they apply). The first screen, the start of the wizard and an
-- answer file all load a deployment through this, so that the presets
-- reach whichever deployment is chosen.
loadDeployment :: [(Text, Text)] -> Answers -> IO (Answers, Text)
loadDeployment ps given = do
  (filled, n) <- prefill given
  pure (either (const filled) id (foldM applyAnswer filled ps), n)

-- | The answers of a file, over the state of the deployment it names, and
-- the command line they make.
fromFile :: [(Text, Text)] -> FilePath -> IO ()
fromFile given file = do
  -- The file is named from where toolchain/configure.sh was started.
  path <- T.unpack <$> absolute (T.pack file)
  kv <- keyValues <$> T.readFile path
  let named = defaultAnswers {name = value "name" kv (defaultAnswers.name), prefix = value "prefix" kv ""}
  (filled, n) <- loadDeployment given named
  hPutStrLn stderr ("configure: " <> T.unpack n)
  case foldM applyAnswer filled kv of
    Left e -> hPutStrLn stderr ("configure: " <> file <> ": " <> T.unpack e) >> exitFailure
    Right answered -> do
      a <- normalise <$> resolvePaths answered
      let ps = problems a
      unless (null ps) $ do
        mapM_ (hPutStrLn stderr . ("configure: " <>) . T.unpack) ps
        exitFailure
      T.putStrLn (commandLine a)
  where
    value key kv def = fromMaybe def (lookup key (reverse kv))
