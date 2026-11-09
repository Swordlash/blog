-- | The check of what the native build of wiki-server needs from the
-- machine: the commands cc, make, curl, git and pkg-config, and the C
-- libraries GMP, libpq and zlib (terminfo too for the configuration
-- wizard). It prints one line per item, ok or missing, with how
-- the item was found or what was tried, then a summary that names the Debian
-- and RHEL packages of what is missing. It installs nothing.
--
-- It is @toolchain/check-native.sh@ in Haskell, line for line, so that the
-- deploy's messages and their tests stay as they are. @maker bootstrap
-- native@ runs it after the Debian packages; @maker check native@ runs it
-- alone. The deploy still runs the shell script, before GHC is there to
-- build the maker (docs/PLAN.md, WP5.68 c2 retires it).
--
-- How the build finds each item, and so how the check looks for it:
--
-- * The commands are only looked up on PATH, never run.
-- * GMP: its header @gmp.h@, through the C compiler's preprocessor.
-- * libpq: postgresql-libpq's Setup runs @pg_config@, which must be on PATH
--   and answer @pg_config --includedir@; pkg-config's @libpq.pc@ is not
--   enough. When PATH has none, the check looks in RHEL's
--   @\/usr\/pgsql-*\/bin@ and Debian's @\/usr\/lib\/postgresql\/*\/bin@ (or the
--   directories @WIKI_PG_CONFIG_DIRS@ names, for the tests), to name the one
--   to put on PATH. A build without PostgreSQL needs no libpq.
-- * zlib: through pkg-config (@zlib.pc@), as the zlib package finds it.
-- * libsodium is not looked for: the bootstrap builds the release
--   @toolchain/pins.env@ pins from source (@toolchain/libsodium.sh@), as a
--   static library in the toolchain's directory, so the machine needs none.
--   Its line says so, and is not counted.
-- * terminfo, for the wizard only: vty links @-ltinfo@.
--
-- One more line says whether the @xelatex@ on PATH typesets the PDF
-- exports, through @toolchain/check-tex.sh@. It is not counted and never
-- fails the check: a wiki without PDFs is a working wiki.
module Maker.Check.Native
  ( Options (..)
  , defaultOptions
  , Line (..)
  , Lack (..)
  , Findings (..)
  , checkNative
  , findings
  , render
  , itemLine
  )
where

import Control.Monad (filterM)
import Data.Char (isSpace)
import Data.List (intercalate, sort, stripPrefix)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Development.Shake (getDirectoryFilesIO)
import Maker.Process (decodeFs, found, output, succeeds)
import System.Directory (doesFileExist, executable, getPermissions)
import System.Environment (lookupEnv)
import System.FilePath (isAbsolute, takeDirectory, (</>))
import System.IO (readFile')
import System.IO.Extra (withTempDir)
import System.Process.Typed

-- | What the check is asked for.
data Options = Options
  { postgres :: Bool
  -- ^ Whether the build has PostgreSQL, and so needs libpq. Off for a wiki
  -- in SQLite (@--without-postgres@).
  , wizard :: Bool
  -- ^ Whether terminfo is checked, for the configuration wizard
  -- (@--with-wizard@).
  , tex :: Bool
  -- ^ Whether xelatex is tried. The deploy turns it off (@--without-tex@):
  -- its TeX step tries the xelatex the service finds, and an xelatex that
  -- hangs would otherwise cost its timeout twice.
  }
  deriving (Eq, Show)

-- | The check as @check-native.sh@ runs it with no option.
defaultOptions :: Options
defaultOptions = Options {postgres = True, wizard = False, tex = True}

-- | An item that is missing, with the packages that bring it.
data Lack = Lack
  { item :: String
  , debian :: String
  , rhel :: String
  , detail :: String
  -- ^ What was tried.
  }
  deriving (Eq, Show)

-- | One line of the check's report.
data Line
  = -- | An item that is there, and how it was found. Counted.
    Ok String String
  | -- | An item that is missing. Counted.
    Missing Lack
  | -- | A line that is not counted: its status column, the item, the text.
    Uncounted String String String
  deriving (Eq, Show)

-- | What the check found, in the order it reports it.
data Findings = Findings
  { lines' :: [Line]
  , texNote :: Maybe String
  -- ^ Why the PDF exports would not work, for the summary.
  , pgConfigElsewhere :: Maybe FilePath
  -- ^ A @pg_config@ off PATH, to name in the hint.
  }
  deriving (Eq, Show)

-- | Run the check: the report's lines, and whether everything is there.
-- @root@ is the repository, whose @toolchain/check-tex.sh@ tries xelatex.
checkNative :: FilePath -> Options -> IO ([String], Bool)
checkNative root options = render options <$> findings root options

-- | One line of the report, in the script's columns
-- (@printf '%-8s %-11s %s'@).
itemLine :: String -> String -> String -> String
itemLine status item text = pad 8 status <> " " <> pad 11 item <> " " <> text
  where
    pad n s = s <> replicate (n - length s) ' '

-- | The report and the summary.
render :: Options -> Findings -> ([String], Bool)
render options f = (map line f.lines' <> summary, null missing)
  where
    line = \case
      Ok item how -> itemLine "ok" item how
      Missing l -> itemLine "missing" l.item (l.detail <> " (Debian: " <> l.debian <> "; RHEL: " <> l.rhel <> ")")
      Uncounted status item text -> itemLine status item text
    checked = length [() | l <- f.lines', counted l]
    counted = \case
      Uncounted {} -> False
      _ -> True
    missing = [l | Missing l <- f.lines']
    names = map (\l -> l.item) missing
    what = "the native build of wiki-server" <> (if options.wizard then " and the configuration wizard" else "")
    needs = if options.wizard then "need" else "needs"
    texSummary =
      [ "PDF exports need xelatex: " <> note <> ", so the server would offer no PDFs (the deploy offers TeX Live under the toolchain: sh toolchain/deploy-local.sh --server --texlive)."
      | Just note <- [f.texNote]
      ]
    summary
      | null missing = ["All " <> show checked <> " items " <> what <> " " <> needs <> " are there."] <> texSummary
      | otherwise =
          [ ""
          , "Missing for " <> what <> ": " <> intercalate ", " names <> "."
          , "Install them and run this again:"
          , "    Debian, Ubuntu: sudo apt-get install " <> unwords (map (\l -> l.debian) missing)
          , "    RHEL, Fedora:   sudo dnf install " <> unwords (map (\l -> l.rhel) missing)
          ]
            <> (if "libpq" `elem` names then libpqHint else [])
            <> [ "The build sees the environment this runs in: LIBRARY_PATH, C_INCLUDE_PATH, CPATH"
               , "and PKG_CONFIG_PATH reach cabal untouched, for a library in a directory of its own."
               , "A shared library there also needs LD_LIBRARY_PATH when wiki-server runs"
               , "(toolchain/deploy-local.sh writes it into the systemd unit)."
               ]
            <> texSummary
    libpqHint =
      [ "postgresql-libpq runs pg_config when cabal builds it, so pg_config must be on PATH."
      , "RHEL has it in libpq-devel, or in PGDG's postgresqlNN-devel, which puts it in /usr/pgsql-NN/bin."
      ]
        <> case f.pgConfigElsewhere of
          Just path ->
            [ "There is one at " <> path <> ": put its directory on PATH for the deploy:"
            , "    PATH=" <> takeDirectory path <> ":$PATH sh toolchain/deploy-local.sh ..."
            ]
          Nothing ->
            [ "Put the directory of pg_config on PATH for the deploy:"
            , "    PATH=/usr/pgsql-NN/bin:$PATH sh toolchain/deploy-local.sh ..."
            ]

-- | Look at the machine, item by item, in the report's order.
findings :: FilePath -> Options -> IO Findings
findings root options = do
  commands <-
    mapM
      commandItem
      [ ("cc", "build-essential", "gcc")
      , ("make", "make", "make")
      , ("curl", "curl", "curl")
      , ("git", "git", "git")
      , ("pkg-config", "pkg-config", "pkgconf-pkg-config")
      ]
  (texLine, texNote') <- xelatex root options
  hasCc <- isJust <$> found "cc"
  hasPkgConfig <- isJust <$> found "pkg-config"
  gmp <- gmpItem hasCc
  (libpq, elsewhere) <- libpqItem options hasPkgConfig
  zlib <- zlibItem hasPkgConfig
  sodium <- sodiumLine root
  terminfo <- terminfoItem options hasCc
  pure
    Findings
      { lines' = commands <> [texLine, gmp, libpq, zlib, sodium, terminfo]
      , texNote = texNote'
      , pgConfigElsewhere = elsewhere
      }

-- | A command on PATH. It is only looked up: running it is the build's
-- business.
commandItem :: (String, String, String) -> IO Line
commandItem (name, deb, rh) =
  maybe (Missing (Lack name deb rh "not on PATH")) (Ok name) <$> found name

-- | The xelatex line, and the summary's note when the PDF exports would not
-- work. @check-tex.sh@ exits 0 when xelatex works, 1 when it fails and 2
-- when PATH has none; its first line says where, its second why it fails.
xelatex :: FilePath -> Options -> IO (Line, Maybe String)
xelatex root options
  | not options.tex = pure (Uncounted "--" "xelatex" "checked by the deploy's TeX step, on the service's PATH (for the PDF exports; not counted)", Nothing)
  | otherwise = do
      (code, out) <- readProcessInterleaved (setStdin nullStream (proc "sh" [root </> "toolchain" </> "check-tex.sh"]))
      let reportLines = Prelude.lines (decodeFs out)
          first = fromMaybe "" (listToMaybe reportLines)
          second = case drop 1 reportLines of
            r : _ | not (null r) -> r
            _ -> "see sh toolchain/check-tex.sh"
          without prefix s = fromMaybe s (stripPrefix prefix s)
          notCounted = " (for the PDF exports; not counted)"
      pure $ case code of
        ExitSuccess -> (Uncounted "ok" "xelatex" ("working at " <> without "working " first <> notCounted), Nothing)
        ExitFailure 1 ->
          ( Uncounted "no" "xelatex" ("failing at " <> without "failing " first <> ": " <> second <> notCounted)
          , Just (without "failing " first <> " fails (sh toolchain/check-tex.sh says why)")
          )
        ExitFailure 2 -> (Uncounted "no" "xelatex" ("not-found: no xelatex on PATH" <> notCounted), Just "none is on PATH")
        ExitFailure _ -> (Uncounted "no" "xelatex" ("not checked: toolchain/check-tex.sh could not run: " <> first <> notCounted), Just "it could not be checked")

-- | GMP's header, through the C compiler's preprocessor.
gmpItem :: Bool -> IO Line
gmpItem hasCc
  | not hasCc = pure (lacks "not checked: needs cc")
  | otherwise = do
      code <- runProcess (setStdin (byteStringInput "#include <gmp.h>\n") (quiet (proc "cc" ["-E", "-x", "c", "-"])))
      pure (if code == ExitSuccess then Ok "GMP" "gmp.h, through cc -E" else lacks "cc -E finds no gmp.h")
  where
    lacks = Missing . Lack "GMP" "libgmp-dev" "gmp-devel"

-- | libpq, through the @pg_config@ on PATH, which postgresql-libpq's Setup
-- runs. When PATH has none, the last @pg_config@ the directories' patterns
-- find (usually the newest PostgreSQL) is named in the hint.
libpqItem :: Options -> Bool -> IO (Line, Maybe FilePath)
libpqItem options hasPkgConfig
  | not options.postgres = pure (Uncounted "skipped" "libpq" "not needed (built without PostgreSQL)", Nothing)
  | otherwise =
      found "pg_config" >>= \case
        Just path -> do
          includedir <- fmap (reverse . dropWhile (== '\n') . reverse) <$> output "pg_config" ["--includedir"]
          pure $ case includedir of
            Just dir | not (null dir) -> (Ok "libpq" ("pg_config at " <> path <> ", headers in " <> dir), Nothing)
            _ -> (lacks ("pg_config at " <> path <> " does not answer pg_config --includedir"), Nothing)
        Nothing -> do
          dirs <- maybe defaultDirs words . nonEmpty <$> lookupEnv "WIKI_PG_CONFIG_DIRS"
          candidates <- concat <$> mapM pgConfigsIn dirs
          elsewhere <- lastMaybe <$> filterM isExecutable candidates
          knows <- if hasPkgConfig then succeeds "pkg-config" ["--exists", "libpq"] else pure False
          pure $ case elsewhere of
            Just path -> (lacks ("no pg_config on PATH, but there is one at " <> path), Just path)
            Nothing
              | knows -> (lacks "no pg_config on PATH, though pkg-config knows libpq: the build runs pg_config", Nothing)
              | otherwise -> (lacks "no pg_config on PATH", Nothing)
  where
    lacks = Missing . Lack "libpq" "libpq-dev" "libpq-devel"
    defaultDirs = ["/usr/pgsql-*/bin", "/usr/lib/postgresql/*/bin"]
    nonEmpty = \case
      Just s | not (all isSpace s) -> Just s
      _ -> Nothing
    lastMaybe xs = if null xs then Nothing else Just (last xs)

-- | The @pg_config@ files a directory pattern names, sorted as the shell
-- sorts a glob's matches. A pattern's @*@ stands for any part of one
-- directory's name (Shake's file patterns, which have no @?@ or @[…]@); a
-- directory without one is taken as it is.
pgConfigsIn :: String -> IO [FilePath]
pgConfigsIn dir
  | '*' `notElem` dir = pure [dir </> "pg_config"]
  | isAbsolute dir = map ("/" <>) . sort <$> getDirectoryFilesIO "/" [drop 1 (dir </> "pg_config")]
  | otherwise = sort <$> getDirectoryFilesIO "" [dir </> "pg_config"]

-- | Whether a file is there and may be run.
isExecutable :: FilePath -> IO Bool
isExecutable path = do
  exists <- doesFileExist path
  if exists then executable <$> getPermissions path else pure False

-- | zlib, through pkg-config, as the zlib package finds it.
zlibItem :: Bool -> IO Line
zlibItem hasPkgConfig
  | not hasPkgConfig = pure (lacks "not checked: needs pkg-config")
  | otherwise = do
      ok <- succeeds "pkg-config" ["--exists", "zlib"]
      pure (if ok then Ok "zlib" "pkg-config --exists zlib" else lacks "pkg-config --exists zlib failed")
  where
    lacks = Missing . Lack "zlib" "zlib1g-dev" "zlib-devel"

-- | libsodium's line, which is not counted: the bootstrap builds the
-- pinned release from source, so nothing is needed from the machine. The
-- version comes from @toolchain/pins.env@, read as the shell script reads
-- it, so that a missing file leaves it empty rather than failing the check.
sodiumLine :: FilePath -> IO Line
sodiumLine root = do
  let file = root </> "toolchain" </> "pins.env"
  exists <- doesFileExist file
  text' <- if exists then readFile' file else pure ""
  let version = fromMaybe "" (listToMaybe [v | l <- Prelude.lines text', Just v <- [stripPrefix "LIBSODIUM_VERSION=" l]])
  pure (Uncounted "--" "libsodium" ("not needed from the system: the bootstrap builds libsodium " <> version <> " from source (toolchain/libsodium.sh; not counted)"))

-- | terminfo, linked as vty links it (GHC's terminfo package names
-- @-ltinfo@). The probe declares the one function it calls, so that it
-- needs no header: the build compiles no C against terminfo, it only links
-- the library.
terminfoItem :: Options -> Bool -> IO Line
terminfoItem options hasCc
  | not options.wizard = pure (Uncounted "skipped" "terminfo" "not needed (for the configuration wizard only: --with-wizard)")
  | not hasCc = pure (lacks "not checked: needs cc")
  | otherwise = do
      linked <- probe "tinfo" "int setupterm(const char *, int, int *);\nint main(void) { int e; (void)setupterm(0, 1, &e); return 0; }\n" "-ltinfo"
      pure $
        if linked
          then Ok "terminfo" "-ltinfo, through cc (for the configuration wizard)"
          else lacks "cc cannot link a program with -ltinfo (the configuration wizard needs it)"
  where
    lacks = Missing . Lack "terminfo" "libncurses-dev" "ncurses-devel"

-- | Whether cc compiles and links a one-line program with a library, in a
-- directory of its own that is removed afterwards.
probe :: String -> String -> String -> IO Bool
probe name source library =
  withTempDir $ \dir -> do
    let file = dir </> name <> ".c"
    writeFile file source
    (== ExitSuccess) <$> runProcess (quiet (proc "cc" ["-o", dir </> name, file, library]))

-- | A process with no input whose output is dropped.
quiet :: ProcessConfig i o e -> ProcessConfig i () ()
quiet = setStdout nullStream . setStderr nullStream
