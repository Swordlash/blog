-- | The TeX step of a server's deploy: whether the service has an xelatex
-- that makes the PDF exports, and, when it has none and the owner agrees,
-- TeX Live installed under the toolchain directory (with a Perl built from
-- source first when the machine has none that TeX Live's installer can
-- use). It decides what the state keeps (@texlive@, @texlive_dir@,
-- @perl_dir@), the bin directory the unit puts first on its PATH
-- (@tex_bin@, empty when the service uses the TeX it finds itself, or
-- none), and @pdf@, @yes@ when the step ends with an xelatex that works.
-- With @pdf@ @no@ the unit runs wiki-server with @--no-pdf@. It never stops
-- the deploy: without a TeX that works, the server offers no PDFs.
--
-- It is @toolchain/deploy-local.sh@'s @tex_step@, with its messages; the
-- shell keeps the few helpers @--status@ uses.
module Maker.Deploy.Tex
  ( texStep
  , sourceWords
  , texYear
  , texlivePackages
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM, forM_, unless, when)
import Data.Char (isDigit)
import Data.IORef
import Data.List (isPrefixOf, isSuffixOf, sort, stripPrefix)
import Data.Maybe (fromMaybe, isJust, listToMaybe)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Maker.Deploy.Plan
import Maker.Deploy.Sqlite (unitBasePath)
import System.Directory
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath ((</>))
import System.IO
import System.Process.Typed

-- | The CTAN mirror TeX Live is installed from when --texlive-mirror names
-- none; it redirects to a mirror near the machine.
defaultMirror :: String
defaultMirror = "https://mirror.ctan.org"

-- | The Perl built when the machine has none that TeX Live's installer can
-- use.
perlVersion :: String
perlVersion = "5.44.0"

-- | Where TeX Live's installer and Perl's source are cloned from unless
-- --texlive-installer and --perl-source name others.
installerRepo, perlRepo :: String
installerRepo = "https://github.com/TeX-Live/installer"
perlRepo = "https://github.com/Perl/perl5"

-- | What the TeX step works out, written into the plan.
data Tex = Tex
  { texlive :: IORef String
  , texliveDir :: IORef String
  , perlDir :: IORef String
  , texBin :: IORef String
  , pdf :: IORef String
  }

-- | The TeX step, for a server's deploy; the plan for a demo is answered
-- as it is.
texStep :: Plan -> IO Plan
texStep p
  | get p "mode" /= "server" = pure p
  | otherwise = do
      t <- Tex <$> newIORef (get p "texlive") <*> newIORef (get p "texlive_dir") <*> newIORef (get p "perl_dir") <*> newIORef "" <*> newIORef "no"
      step p t
      texlive' <- readIORef t.texlive
      dir <- readIORef t.texliveDir
      perl <- readIORef t.perlDir
      bin <- readIORef t.texBin
      ok <- readIORef t.pdf
      pure (set "texlive" texlive' (set "texlive_dir" dir (set "perl_dir" perl (set "tex_bin" bin (set "pdf" ok p)))))

-- | The result of toolchain/check-tex.sh: its status (0 working, 1
-- failing, 2 not found), its first line and its whole report.
data Check = Check {status :: Int, line :: String, report :: String}

step :: Plan -> Tex -> IO ()
step p t = do
  let base = get p "toolchain_base"
      root' = base </> ".wiki-toolchain" </> "texlive"
      perlRoot = base </> ".wiki-toolchain" </> "perl"
      mirror = let m = get p "texlive_mirror" in if null m then defaultMirror else m
      offerOff = "the server runs with --no-pdf and offers no PDFs, and its administration's Server section says why"
  servicePath <- managerPath
  texlive0 <- readIORef t.texlive
  dir0 <- readIORef t.texliveDir
  toolchainBin <- if null dir0 then pure Nothing else texliveBin dir0 "xelatex"
  done <- case toolchainBin of
    Just bin | texlive0 /= "no" -> do
      c <- checkTex p (bin <> ":" <> unitBasePath)
      if c.status == 0
        then do
          say ("PDF exports: " <> without "working " c.line <> " works, the toolchain's TeX Live; the unit puts " <> bin <> " first on its PATH")
          writeIORef t.texBin bin >> writeIORef t.pdf "yes"
          pure True
        else do
          warn ("PDF exports: the toolchain's TeX Live in " <> dir0 <> " does not work:")
          hPutStr stderr (reason c)
          pure False
    Just _ -> do
      say ("--no-texlive: not using the toolchain's TeX Live in " <> dir0 <> ", which stays there (--texlive uses it again)")
      pure False
    Nothing -> pure False
  unless done $ do
    c <- checkTex p servicePath
    if c.status == 0
      then do
        say ("PDF exports: " <> without "working " c.line <> " works, the TeX on this machine, found on the service's PATH (" <> servicePath <> ")")
        writeIORef t.pdf "yes"
      else do
        if c.status == 2
          then say ("PDF exports: no xelatex on the service's PATH (" <> servicePath <> "): the systemd user manager's PATH, not this shell's")
          else do
            warn ("PDF exports: " <> without "failing " c.line <> " does not make the probe's PDF under the export's limits, on the service's PATH (" <> servicePath <> "):")
            hPutStr stderr (reason c)
        -- The trap: a TeX this shell finds and the service does not.
        shellTex <- findExecutable "xelatex"
        case shellTex of
          Just found | c.status == 2 -> say ("this shell finds " <> found <> ", but the service does not: a unit does not inherit the shell's PATH")
          _ -> pure ()
        offer p t root' perlRoot mirror offerOff

-- | When no TeX works: install TeX Live, if the owner wants it.
offer :: Plan -> Tex -> FilePath -> FilePath -> String -> String -> IO ()
offer p t root' perlRoot mirror offerOff = do
  choice <- readIORef t.texlive
  if choice == "no"
    then say ("PDF exports: " <> offerOff <> " (--no-texlive; --texlive installs TeX Live under " <> root' <> ")")
    else do
      -- Whether TeX Live's installer has a Perl, or one must be built
      -- first: the question names the build, so that one answer covers both.
      perl <- readIORef t.perlDir
      (perlBin, perlBuild) <- perlPlan perl
      let perlSource = let s = get p "perl_source" in if null s then perlRepo else s
          installerSource = let s = get p "texlive_installer" in if null s then installerRepo else s
          perlClause
            | perlBuild = ", building Perl " <> perlVersion <> " under " <> perlRoot <> " first, its source " <> sourceWords perlSource ("v" <> perlVersion) <> ", since this machine has no Perl with its standard modules (a few minutes with cc)"
            | otherwise = ""
          installerClause = ", its installer " <> sourceWords installerSource ""
      go <-
        if choice == "yes"
          then pure True
          else do
            interactive <- (&&) <$> hIsTerminalDevice stdin <*> hIsTerminalDevice stdout
            if interactive
              then do
                putStr (prog <> ": PDF exports need a TeX that works and none was found. Install TeX Live under " <> root' <> " from " <> mirror <> installerClause <> " (about 250 MB, a few minutes)" <> perlClause <> "? [y/N] ")
                hFlush stdout
                answer <- either (\(_ :: IOException) -> "") id <$> try getLine
                if answer `elem` ["y", "Y", "yes", "Yes", "YES"]
                  then writeIORef t.texlive "yes" >> pure True
                  else do
                    writeIORef t.texlive "no"
                    say ("PDF exports: " <> offerOff <> " (remembered; --texlive installs TeX Live under " <> root' <> " later)")
                    pure False
              else do
                say ("PDF exports: " <> offerOff <> ". --texlive installs TeX Live under " <> root' <> " from " <> mirror <> installerClause <> " (about 250 MB and a few minutes" <> perlClause <> "); --no-texlive says no and stops this note")
                pure False
      when go $ do
        missing <- filterM (fmap not . fmap isJust . findExecutable) ["git", "curl", "tar", "gzip"]
        if not (null missing)
          then warn ("TeX Live's install needs " <> joinComma missing <> ", missing here: install them (Debian and Ubuntu: sudo apt-get install git curl tar gzip; RHEL and Fedora: sudo dnf install git curl tar gzip) and deploy again. Meanwhile " <> offerOff)
          else do
            when (not perlBuild && not (null (get p "perl_source"))) $
              say "--perl-source: not used, since TeX Live's installer has a Perl that works"
            perlReady <-
              if not perlBuild
                then pure (Just perlBin)
                else do
                  tools <- (&&) <$> (isJust <$> findExecutable "cc") <*> (isJust <$> findExecutable "make")
                  if not tools
                    then do
                      warn ("TeX Live's installer needs Perl with its standard modules, which this machine lacks, and building Perl needs cc and make, missing here: install them, or perl itself (Debian and Ubuntu: sudo apt-get install perl; RHEL and Fedora: sudo dnf install perl, the whole perl, not perl-interpreter alone), and deploy again. Meanwhile " <> offerOff)
                      pure Nothing
                    else do
                      built <- buildPerl p t root' perlRoot perlSource
                      case built of
                        Just bin -> pure (Just bin)
                        Nothing -> do
                          warn ("Perl " <> perlVersion <> " was not built (see above), so TeX Live was not installed and " <> offerOff <> "; the next deploy tries again (--no-texlive stops it)")
                          pure Nothing
            forM_ perlReady $ \bin -> do
              installed <- installTexlive p root' mirror installerSource bin
              case installed of
                Nothing -> do
                  -- An install of the remembered installation's year
                  -- removed it first: then nothing is remembered, rather
                  -- than a directory that is gone.
                  dir <- readIORef t.texliveDir
                  still <- if null dir then pure Nothing else texliveBin dir "xelatex"
                  unless (isJust still) (writeIORef t.texliveDir "")
                  warn ("TeX Live was not installed (see above), so " <> offerOff <> "; the next deploy tries again (--no-texlive stops it)")
                Just (new, newBin) -> do
                  c <- checkTex p (newBin <> ":" <> unitBasePath)
                  if c.status /= 0
                    then do
                      warn ("the TeX Live just installed in " <> new <> " does not make the probe's PDF:")
                      hPutStr stderr (reason c)
                      warn ("so " <> offerOff <> "; the next deploy installs it again (--no-texlive stops it)")
                    else do
                      -- One installation is kept: those of other years go.
                      entries <- either (\(_ :: IOException) -> []) id <$> try (listDirectory root')
                      forM_ (sort [e | e <- entries, length e == 4, all isDigit e]) $ \e -> do
                        let old = root' </> e
                        isDir <- doesDirectoryExist old
                        when (isDir && old /= new) $ do
                          removePathForcibly old
                          say ("deleted the older TeX Live in " <> old)
                      writeIORef t.texliveDir new
                      writeIORef t.texBin newBin
                      writeIORef t.pdf "yes"
                      say ("PDF exports: " <> without "working " c.line <> " works, the toolchain's TeX Live; the unit puts " <> newBin <> " first on its PATH")

-- | The PATH the user's systemd manager gives a unit that sets none, which
-- the service sees; systemd's usual default when systemctl says nothing.
managerPath :: IO String
managerPath = do
  (_, out) <- outputOf "systemctl" ["--user", "show-environment"]
  pure $ case [rest | l <- lines out, Just rest <- [stripPrefix "PATH=" l]] of
    [] -> unitBasePath
    paths -> let path = last paths in if null path then unitBasePath else path

-- | The bin directory of a TeX Live installation (bin/<platform>) that
-- holds a program.
texliveBin :: FilePath -> String -> IO (Maybe FilePath)
texliveBin dir program = do
  entries <- either (\(_ :: IOException) -> []) id <$> try (listDirectory (dir </> "bin"))
  candidates <- filterM (\e -> doesDirectoryExist (dir </> "bin" </> e)) (sort entries)
  usable <- filterM (\e -> isExecutable (dir </> "bin" </> e </> program)) candidates
  pure ((\e -> dir </> "bin" </> e) <$> listToMaybe usable)

-- | toolchain/check-tex.sh as the service would run xelatex: with an empty
-- environment but HOME and the PATH given.
checkTex :: Plan -> String -> IO Check
checkTex p path = do
  home <- getHomeDirectory
  timeoutVar <- lookupEnv "WIKI_TEX_TIMEOUT"
  let environment = [("HOME", home), ("PATH", path)] <> [("WIKI_TEX_TIMEOUT", v) | Just v <- [timeoutVar], not (null v)]
  result <- try (readProcessInterleaved (setStdin nullStream (setEnv environment (proc "/bin/sh" [get p "root" </> "toolchain" </> "check-tex.sh"]))))
  let (code, out) = case result of
        Right (c, o) -> (c, decodeFs o)
        Left (_ :: IOException) -> (ExitFailure 127, "")
      text = reverse (dropWhile (== '\n') (reverse out))
  pure
    Check
      { status = case code of
          ExitSuccess -> 0
          ExitFailure n -> n
      , line = takeWhile (/= '\n') text
      , report = text
      }

-- | A failed check's reason: its report's lines after the first, indented.
reason :: Check -> String
reason c = unlines (map ("    " <>) (drop 1 (lines c.report)))

-- | Whether a perl runs with the standard modules install-tl and tlmgr
-- use; RHEL's perl-interpreter alone lacks some.
perlUsable :: FilePath -> IO Bool
perlUsable perl = succeeds perl ["-MDigest::MD5", "-MDigest::SHA", "-MFile::Temp", "-MGetopt::Long", "-MPod::Usage", "-MData::Dumper", "-MTime::HiRes", "-e", "1"]

-- | The Perl TeX Live's installer runs with: the bin directory to put first
-- on its PATH (the toolchain's Perl when one was built and still works,
-- empty when the machine's own will do), and whether a Perl must be built.
perlPlan :: FilePath -> IO (FilePath, Bool)
perlPlan perl = do
  own <- if null perl then pure False else perlUsable (perl </> "bin" </> "perl")
  if own
    then pure (perl </> "bin", False)
    else do
      machine <- perlUsable "perl"
      pure ("", not machine)

-- | Where a source comes from, for the messages: a URL is a git repository,
-- cloned (at a tag when one is given), anything else a directory.
sourceWords :: String -> String -> String
sourceWords source tag
  | "http://" `isPrefixOf` source || "https://" `isPrefixOf` source = "cloned from " <> source <> (if null tag then "" else " at " <> tag)
  | otherwise = "from the directory " <> source

-- | One step of the install: the command's output shown as it comes and
-- appended to the install's log; a failure shows the log's end.
texliveStep :: FilePath -> String -> ProcessConfig () () () -> String -> IO Bool
texliveStep logFile name config shown = do
  appendFile logFile ("+ " <> shown <> "\n")
  (code, _) <- withBinaryFile logFile AppendMode $ \h -> relay (Just h) config
  case code of
    ExitSuccess -> pure True
    ExitFailure n -> do
      warn (name <> " failed (exit " <> show n <> "); the end of " <> logFile <> ":")
      tailLog 20 logFile
      pure False

-- | Build Perl from its source into the toolchain, for TeX Live's
-- installer: a shallow clone of its tag (or a copy of a directory),
-- Configure -des with relocatable modules, make with a job per processor,
-- make install. Answers the bin directory when the Perl works; leaves no
-- half-built Perl behind.
buildPerl :: Plan -> Tex -> FilePath -> FilePath -> String -> IO (Maybe FilePath)
buildPerl _ t root' perlRoot source = do
  createDirectoryIfMissing True root'
  let logFile = root' </> "install.log"
      sourceDir = perlRoot </> "src" </> "perl5"
  stamp <- formatTime defaultTimeLocale "%F %T" <$> getZonedTime
  appendFile logFile ("\n" <> stamp <> " building Perl " <> perlVersion <> "\n")
  -- Whatever Perl was there goes first, and is forgotten until the new one
  -- works.
  writeIORef t.perlDir ""
  removePathForcibly perlRoot
  createDirectoryIfMissing True (perlRoot </> "src")
  say ("building Perl " <> perlVersion <> " under " <> perlRoot <> " for TeX Live's installer, its source " <> sourceWords source ("v" <> perlVersion) <> " (its output also goes to " <> logFile <> ")")
  let isUrl = "http://" `isPrefixOf` source || "https://" `isPrefixOf` source
      fetchArgs
        | isUrl = ("cloning Perl's source", "git", ["-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1", "--branch", "v" <> perlVersion, source, sourceDir])
        | otherwise = ("copying Perl's source", "cp", ["-R", source, sourceDir])
      (fetchName, fetchProgram, fetchArgs') = fetchArgs
      fail' = removePathForcibly perlRoot >> pure Nothing
  fetched <- texliveStep logFile fetchName (proc fetchProgram fetchArgs') (unwords (fetchProgram : fetchArgs'))
  if not fetched
    then fail'
    else do
      configure <- doesFileExist (sourceDir </> "Configure")
      if not configure
        then do
          warn ("Perl's source " <> sourceWords source ("v" <> perlVersion) <> " has no Configure at its top")
          fail'
        else do
          (_, n) <- outputOf "nproc" []
          let jobs = let j = takeWhile (/= '\n') n in if null j then "1" else j
              configureArgs = ["-c", "cd \"$1\" && exec sh Configure -des -Dprefix=\"$2\" -Duserelocatableinc", "configure", sourceDir, perlRoot]
          ok1 <- texliveStep logFile "Perl's Configure" (proc "sh" configureArgs) (unwords ("sh" : configureArgs))
          ok2 <- if ok1 then texliveStep logFile ("building Perl (make -j" <> jobs <> ")") (proc "make" ["-C", sourceDir, "-j" <> jobs]) ("make -C " <> sourceDir <> " -j" <> jobs) else pure False
          ok3 <- if ok2 then texliveStep logFile "installing Perl (make install)" (proc "make" ["-C", sourceDir, "install"]) ("make -C " <> sourceDir <> " install") else pure False
          if not ok3
            then fail'
            else do
              removePathForcibly (perlRoot </> "src")
              usable <- perlUsable (perlRoot </> "bin" </> "perl")
              if not usable
                then do
                  warn ("the Perl built in " <> perlRoot <> " does not run with the modules TeX Live's installer needs (see " <> logFile <> ")")
                  fail'
                else do
                  writeIORef t.perlDir perlRoot
                  say ("built Perl " <> perlVersion <> " in " <> perlRoot <> ", for TeX Live's installer only")
                  pure (Just (perlRoot </> "bin"))

-- | Install TeX Live under the toolchain from the mirror: the installer,
-- the scheme basic without documentation and sources into the year of the
-- installer's TeX Live, then the packages of toolchain/texlive-packages.txt
-- with tlmgr. The repository is checked first. Answers the installation
-- and its bin directory.
installTexlive :: Plan -> FilePath -> String -> String -> FilePath -> IO (Maybe (FilePath, FilePath))
installTexlive p root' mirror source perlBin = do
  let repository = dropSlash mirror <> "/systems/texlive/tlnet"
      logFile = root' </> "install.log"
      probeUrl = repository <> "/tlpkg/texlive.tlpdb.sha512"
  createDirectoryIfMissing True root'
  stamp <- formatTime defaultTimeLocale "%F %T" <$> getZonedTime
  appendFile logFile ("\n" <> stamp <> " installing TeX Live from " <> repository <> "\n")
  appendFile logFile ("+ curl " <> probeUrl <> "\n")
  (reachCode, reached) <- withFile logFile AppendMode $ \h -> do
    result <- try (readProcessStdout (setStdin nullStream (setStderr (useHandleOpen h) (proc "curl" ["--fail", "--location", "--silent", "--show-error", "--max-time", "30", "--output", "/dev/null", "--write-out", "%{url_effective}", probeUrl]))))
    pure $ case result of
      Right (c, o) -> (c, decodeFs o)
      Left (_ :: IOException) -> (ExitFailure 127, "")
  let tail' = "/systems/texlive/tlnet/tlpkg/texlive.tlpdb.sha512"
  case reachCode of
    ExitFailure n -> do
      let landed = if null reached || reached == probeUrl then "" else " (curl ended at " <> reached <> ")"
      warn ("TeX Live's repository " <> repository <> " does not answer from this machine" <> landed <> ": curl exited " <> show n <> " (see " <> logFile <> "). mirror.ctan.org sends each request to another mirror, and a proxy may block some of them: name a mirror this machine can reach with --texlive-mirror URL (https://ctan.org/mirrors lists them)")
      pure Nothing
    ExitSuccess -> do
      let answered
            | reached == probeUrl || null reached = ""
            | tail' `isSuffixOf` reached = ", which answered from the mirror " <> take (length reached - length tail') reached
            | otherwise = ", which answered from " <> reached
          installerDir = root' </> "installer.tmp"
          isUrl = "http://" `isPrefixOf` source || "https://" `isPrefixOf` source
      removePathForcibly installerDir
      createDirectoryIfMissing True installerDir
      say ("TeX Live's installer " <> sourceWords source "" <> ", its packages from " <> repository <> answered <> " (its output also goes to " <> logFile <> ")")
      installer <-
        if isUrl
          then do
            let into = installerDir </> "install-tl"
            ok <- texliveStep logFile "cloning TeX Live's installer" (proc "git" ["clone", "--quiet", "--depth", "1", source, into]) ("git clone --quiet --depth 1 " <> source <> " " <> into)
            pure (if ok then Just into else Nothing)
          else pure (Just source)
      case installer of
        Nothing -> pure Nothing
        Just dir -> do
          hasInstaller <- doesFileExist (dir </> "install-tl")
          if not hasInstaller
            then do
              warn ("TeX Live's installer " <> sourceWords source "" <> " holds no install-tl")
              pure Nothing
            else do
              path <- fromMaybe "" <$> lookupEnv "PATH"
              let tlPath = (if null perlBin then "" else perlBin <> ":") <> path
              environment <- tlEnvironment tlPath
              let run program args = setWorkingDir root' (setEnv environment (proc program args))
              appendFile logFile ("+ " <> dir </> "install-tl" <> " --no-interaction --version\n")
              versionOut <- withFile logFile AppendMode $ \h -> do
                result <- try (readProcessStdout (setStdin nullStream (setStderr (useHandleOpen h) (run (dir </> "install-tl") ["--no-interaction", "--version"]))))
                pure $ either (\(_ :: IOException) -> "") (decodeFs . snd) result
              case texYear versionOut of
                Nothing -> do
                  warn ("TeX Live's installer in " <> dir <> " does not say its year (install-tl --version; see " <> logFile <> ")")
                  pure Nothing
                Just year -> do
                  let new = root' </> year
                  removePathForcibly new
                  say ("installing TeX Live " <> year <> " into " <> new <> " (the scheme basic, no documentation or sources)")
                  let installArgs = ["--no-interaction", "--scheme=basic", "--texdir=" <> new, "--texuserdir=" <> root' </> "user", "--no-doc-install", "--no-src-install", "--repository", repository]
                  installed <- texliveStep logFile "TeX Live's installer" (run (dir </> "install-tl") installArgs) (unwords ((dir </> "install-tl") : installArgs))
                  if not installed
                    then pure Nothing
                    else do
                      tlmgr <- texliveBin new "tlmgr"
                      case tlmgr of
                        Nothing -> do
                          warn ("TeX Live's installer left no bin/<platform>/tlmgr under " <> new <> " (see " <> logFile <> ")")
                          pure Nothing
                        Just tlmgrBin -> do
                          packages <- texlivePackages <$> readFile (get p "root" </> "toolchain" </> "texlive-packages.txt")
                          say "installing the packages the PDF exports need (toolchain/texlive-packages.txt) with tlmgr"
                          ok <- texliveStep logFile "tlmgr install" (run (tlmgrBin </> "tlmgr") ("install" : packages)) (unwords ((tlmgrBin </> "tlmgr") : "install" : packages))
                          if not ok
                            then pure Nothing
                            else do
                              newBin <- texliveBin new "xelatex"
                              case newBin of
                                Nothing -> do
                                  warn ("tlmgr installed the packages, but there is no xelatex under " <> new <> "/bin (see " <> logFile <> ")")
                                  pure Nothing
                                Just bin -> do
                                  removePathForcibly installerDir
                                  pure (Just (new, bin))

-- | The environment of install-tl and tlmgr: never a question about
-- resuming an install (TEXLIVE_INSTALL_NO_RESUME), and the Perl first on
-- PATH. They run with no input and in the TeX Live directory, so that an
-- installation.profile elsewhere is never seen.
tlEnvironment :: String -> IO [(String, String)]
tlEnvironment path = do
  environment <- getEnvironment
  pure ([("TEXLIVE_INSTALL_NO_RESUME", "1"), ("PATH", path)] <> filter ((`notElem` ["TEXLIVE_INSTALL_NO_RESUME", "PATH"]) . fst) environment)

-- | The year of TeX Live an installer installs, from install-tl
-- --version's "… version 2026".
texYear :: String -> Maybe String
texYear out = listToMaybe [y | l <- lines out, Just y <- [after l]]
  where
    after l = case breakOn "version " l of
      Just rest -> let y = take 4 rest in if length y == 4 && all isDigit y then Just y else Nothing
      Nothing -> Nothing
    breakOn needle s
      | needle `isPrefixOf` s = Just (drop (length needle) s)
      | otherwise = case s of
          [] -> Nothing
          _ : more -> breakOn needle more

-- | The words of toolchain/texlive-packages.txt, without its comments.
texlivePackages :: String -> [String]
texlivePackages = concatMap (words . takeWhile (/= '#')) . lines

isExecutable :: FilePath -> IO Bool
isExecutable path = do
  exists <- doesFileExist path
  if exists then executable <$> getPermissions path else pure False

without :: String -> String -> String
without prefix s = fromMaybe s (stripPrefix prefix s)

joinComma :: [String] -> String
joinComma [] = ""
joinComma [x] = x
joinComma (x : xs) = x <> ", " <> joinComma xs

dropSlash :: String -> String
dropSlash s = if "/" `isSuffixOf` s then init s else s
