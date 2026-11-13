-- | A real wiki-server for a smoke suite: the server's build of the page,
-- an administrator made on the console, the server on free ports of
-- 127.0.0.1 with a temporary data directory (SQLite) or fresh databases
-- (PostgreSQL), and everything taken away at the end, whatever happened.
--
-- The build in @dist-newstyle/wasm/public/app@ is the demo's; its
-- @app.wasm@ is the server's too, since the page chooses its backend
-- (@<meta name="wiki-backend">@). So 'withServerBuild' copies it into a
-- temporary directory, without the demo's pages, and writes the server's
-- there with @wiki-app-prerender --server@, as @WIKI_BACKEND=server
-- toolchain/build-wasm.sh@ would. Users are made with the console before
-- the server starts, as an owner makes the first administrator
-- (@wiki-server users add LOGIN --admin@, the password on standard input).
-- The server is started on port 0 of 127.0.0.1, and the addresses it took
-- are read from its log, the lines @event=listening listener=NAME
-- address=URL@ (decision 75 of docs/PLAN.md: no test chooses a port).
--
-- On PostgreSQL ('PostgreSQL') the server and the console find their
-- database in @WIKI_DATABASE_URL@, which wiki-server reads when no option
-- names one; the suite makes two databases of its own for the run (the
-- live one, and one for a restore into a fresh data directory) and drops
-- them at the end. On SQLite every variable naming a database is taken
-- out of the server's environment, so that a run never reaches a live
-- deployment's database by accident.
module Wiki.Smoke.Server
  ( -- * What the suites need built
    Built (..)
  , withServerSuite

    -- * The server's build, in a temporary directory
  , ServerBuild (..)
  , withServerBuild

    -- * Databases
  , Database (..)
  , withDatabase

    -- * The console
  , NewUser (..)
  , addUser
  , restoreBackup

    -- * A running server
  , ServerOptions (..)
  , serverOptions
  , Server (..)
  , withServer
  , serverLog
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, registerDelay)
import Control.Concurrent.STM qualified as STM
import Control.Exception (SomeException, bracket, finally, onException, try)
import Control.Monad (forM_, unless, when)
import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isSuffixOf)
import Data.Maybe (fromMaybe, isNothing, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word8)
import Halogen.Playwright.Hspec
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.Environment (getEnvironment, lookupEnv, setEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle, hClose, hIsEOF, hSetEncoding, stderr, stdout, utf8)
import System.IO.Temp (createTempDirectory)
import System.Process (terminateProcess)
import System.Process.Typed qualified as Process
import Text.Read (readMaybe)

----------------------------------------------------------------------
-- What the suites need built

-- | What a server's suite needs: the demo's build, the repository (for
-- @web/index.html@, the page the server's prerender starts from), and
-- the native wiki-server and wiki-app-prerender.
data Built = Built
  { demo :: FilePath
  -- ^ @npm run build-wasm@'s directory, @WIKI_DEMO_DIR@.
  , source :: FilePath
  -- ^ The repository's root, @WIKI_SOURCE_DIR@.
  , server :: FilePath
  -- ^ The wiki-server binary, @WIKI_SERVER@.
  , prerender :: FilePath
  -- ^ The wiki-app-prerender binary, @WIKI_PRERENDER@.
  }

-- | Run a suite that needs the builds: the body is given them and the way
-- to run its spec (under the suite's name), so that it can start what the
-- spec needs around the run (a server) and stop it after. Without the
-- builds, a spec with one pending example that says what is missing, or a
-- failing one when @WIKI_SMOKE_REQUIRED=1@ (as @toolchain/smoke-suite.sh@
-- and CI set it).
--
-- The demo is @WIKI_DEMO_DIR@, else @../dist-newstyle/wasm/public/app@
-- (cabal runs a suite in its package's directory); the repository
-- @WIKI_SOURCE_DIR@, else @..@; the binaries @WIKI_SERVER@ and
-- @WIKI_PRERENDER@, which @toolchain/smoke-suite.sh@ builds and names.
-- Every call of the driver may take 30 seconds when
-- @HALOGEN_PLAYWRIGHT_TIMEOUT@ is not set, times the throttle's factor
-- (@HALOGEN_PLAYWRIGHT_THROTTLE@), as for the demo's suite.
withServerSuite :: String -> (Built -> (Spec -> IO ()) -> IO ()) -> IO ()
withServerSuite name body = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  demo <- fromMaybe "../dist-newstyle/wasm/public/app" <$> lookupEnv "WIKI_DEMO_DIR"
  source <- fromMaybe ".." <$> lookupEnv "WIKI_SOURCE_DIR"
  server <- nonEmpty <$> lookupEnv "WIKI_SERVER"
  prerender <- nonEmpty <$> lookupEnv "WIKI_PRERENDER"
  required <- (== Just "1") <$> lookupEnv "WIKI_SMOKE_REQUIRED"
  timeout <- lookupEnv "HALOGEN_PLAYWRIGHT_TIMEOUT"
  throttle <- lookupEnv "HALOGEN_PLAYWRIGHT_THROTTLE"
  when (isNothing timeout) $ setEnv "HALOGEN_PLAYWRIGHT_TIMEOUT" (show (defaultTimeout throttle))
  built <- (&&) <$> doesFileExist (demo </> "index.html") <*> doesFileExist (demo </> "app.wasm")
  let missing =
        [ "no built demo in " <> demo <> ": build it with npm run build-wasm (or set WIKI_DEMO_DIR)" | not built
        ]
          <> ["WIKI_SERVER names no wiki-server: toolchain/smoke-suite.sh builds and names it" | isNothing server]
          <> ["WIKI_PRERENDER names no wiki-app-prerender: toolchain/smoke-suite.sh builds and names it" | isNothing prerender]
  case (server, prerender) of
    (Just s, Just p) | built -> body Built {demo, source, server = s, prerender = p} (hspec . describe name)
    _ ->
      hspec
        $ describe name
        $ it "is run against the built page and a built wiki-server"
        $ (if required then expectationFailure else pendingWith) (unlines missing)
  where
    nonEmpty = \case
      Just s | not (null s) -> Just s
      _ -> Nothing

-- | The time a call of the driver may take when @HALOGEN_PLAYWRIGHT_TIMEOUT@
-- is not set, in milliseconds: 30 seconds, times the throttle's factor.
defaultTimeout :: Maybe String -> Int
defaultTimeout throttle = ceiling (30000 * max 1 (fromMaybe 1 (throttle >>= readMaybe)) :: Double)

----------------------------------------------------------------------
-- The server's build

-- | The server's build of the page in a temporary directory of the
-- suite's, with room beside it for data directories.
data ServerBuild = ServerBuild
  { built :: Built
  , work :: FilePath
  -- ^ The temporary directory: the build is in @app@, and a server's data
  -- directory goes beside it.
  , app :: FilePath
  -- ^ What the server serves (@--static@): the demo's files but its pages
  -- (the service worker's offline page is not one of them), and the
  -- server's page.
  }

-- | Make the server's build in a temporary directory, for the body, and
-- remove the directory afterwards, whatever happened.
withServerBuild :: Built -> String -> (ServerBuild -> IO a) -> IO a
withServerBuild built prefix body = do
  tmp <- getTemporaryDirectory
  bracket (createTempDirectory tmp prefix) removePathForcibly $ \work -> do
    let app = work </> "app"
    copyBuild built.demo app
    -- At the root, whatever base path the demo's build was made for (the
    -- CI's is GitHub Pages', /blog/), since the server serves the page at
    -- its root.
    environment <- getEnvironment
    let prerendering =
          Process.setWorkingDir built.source
            . Process.setEnv (("HALOGEN_BASE_PATH", "/") : filter ((/= "HALOGEN_BASE_PATH") . fst) environment)
            $ Process.proc built.prerender ["--server", "web/index.html", app]
    Process.runProcess_ prerendering
    page404 <- Text.readFile (app </> "404.html")
    unless ("<meta name=\"wiki-backend\" content=\"server\">" `Text.isInfixOf` page404) $
      fail "the server's page does not say it is the server's (<meta name=\"wiki-backend\">)"
    body ServerBuild {built, work, app}

-- | Copy the demo's build, but its pages: an HTML file at the top but the
-- service worker's offline page, and the directories of its spaces and
-- its search (@s@, @search@), which the server renders itself.
copyBuild :: FilePath -> FilePath -> IO ()
copyBuild from to = do
  createDirectoryIfMissing True to
  names <- listDirectory from
  forM_ names $ \name -> do
    isDir <- doesDirectoryExist (from </> name)
    if isDir
      then unless (name `elem` ["s", "search"]) (copyTree (from </> name) (to </> name))
      else unless (".html" `isSuffixOf` name && name /= "offline.html") (copyFile (from </> name) (to </> name))
  where
    copyTree a b = do
      createDirectoryIfMissing True b
      entries <- listDirectory a
      forM_ entries $ \e -> do
        isDir <- doesDirectoryExist (a </> e)
        if isDir then copyTree (a </> e) (b </> e) else copyFile (a </> e) (b </> e)

----------------------------------------------------------------------
-- Databases

-- | Where a server keeps its wiki.
data Database
  = -- | A SQLite database in the data directory.
    SQLite
  | -- | A PostgreSQL database of the run's own, by its URL, with the
    -- programs the server's backups run (@WIKI_PG_DUMP@, @WIKI_PG_RESTORE@;
    -- empty for the PATH's).
    PostgreSQL
      { url :: Text
      , pgDump :: Text
      , pgRestore :: Text
      }

-- | Two databases of the run's own on the PostgreSQL server
-- @WIKI_TEST_DATABASE_URL@ names, for the body: the live one and one for a
-- restore into a fresh data directory, dropped at the end whatever
-- happened. 'SQLite' and no second one when the variable is not set or
-- the suite is not asked to (@WIKI_SMOKE_POSTGRES=1@). The server may be
-- shared with other runs (@toolchain/ci-postgres.sh@), so the databases
-- are named in a namespace of this run's own, in the shape the server's
-- tests use (@Test.Database.namespaceFor@): @wiki_test_@, the time the run
-- began, eight random letters and digits. A run killed before its cleanup
-- leaves them behind; the server's PostgreSQL tests drop them once they
-- are six hours old. @WIKI_TEST_PSQL@ names the psql that makes and drops
-- them, @WIKI_TEST_PG_DUMP@ and @WIKI_TEST_PG_RESTORE@ the programs the
-- server's backups run.
withDatabase :: ((Database, Maybe Database) -> IO a) -> IO a
withDatabase body = do
  wanted <- (== Just "1") <$> lookupEnv "WIKI_SMOKE_POSTGRES"
  base <- lookupEnv "WIKI_TEST_DATABASE_URL"
  case base of
    Just b | wanted && not (null b) -> do
      psql <- fromMaybe "psql" <$> lookupEnv "WIKI_TEST_PSQL"
      dump <- maybe "" Text.pack <$> lookupEnv "WIKI_TEST_PG_DUMP"
      restore <- maybe "" Text.pack <$> lookupEnv "WIKI_TEST_PG_RESTORE"
      started <- round <$> getPOSIXTime :: IO Integer
      letters <- map letter . ByteString.unpack <$> getRandomBytes 8
      let live = "wiki_test_" <> show started <> "_" <> letters <> "_smoke"
          restored = live <> "_restored"
          urlOf name = Text.pack (renamed b name)
          database name = PostgreSQL {url = urlOf name, pgDump = dump, pgRestore = restore}
          drop' =
            Process.runProcess_ . Process.proc psql $
              [b, "-q", "-c", "DROP DATABASE IF EXISTS " <> live <> " WITH (FORCE)", "-c", "DROP DATABASE IF EXISTS " <> restored <> " WITH (FORCE)"]
      Process.runProcess_ (Process.proc psql [b, "-q", "-c", "CREATE DATABASE " <> live, "-c", "CREATE DATABASE " <> restored])
      body (database live, Just (database restored)) `finally` drop'
    Just _ | wanted -> fail "WIKI_SMOKE_POSTGRES=1 asks for PostgreSQL, and WIKI_TEST_DATABASE_URL names none"
    _ | wanted -> fail "WIKI_SMOKE_POSTGRES=1 asks for PostgreSQL, and WIKI_TEST_DATABASE_URL names none"
    _ -> body (SQLite, Nothing)
  where
    letter :: Word8 -> Char
    letter w = ("abcdefghijklmnopqrstuvwxyz0123456789" :: String) !! (fromIntegral w `mod` 36)
    -- The URL with its database's name changed, its query kept:
    -- postgres://wiki@127.0.0.1:55432/postgres?x=1 to .../NAME?x=1.
    renamed url name =
      let (beforeQuery, query) = break (== '?') url
          (prefix, _) = breakEnd (== '/') beforeQuery
       in prefix <> name <> query
    breakEnd p s = let (a, b) = break p (reverse s) in (reverse b, reverse a)

-- | The environment a server or its console runs with: this process's,
-- without any variable naming a database, and with the database's.
environmentFor :: Database -> IO [(String, String)]
environmentFor database = do
  environment <- filter ((`notElem` databaseVariables) . fst) <$> getEnvironment
  pure $ case database of
    SQLite -> environment
    PostgreSQL {url, pgDump, pgRestore} ->
      [("WIKI_DATABASE_URL", Text.unpack url)]
        <> [("WIKI_PG_DUMP", Text.unpack pgDump) | not (Text.null pgDump)]
        <> [("WIKI_PG_RESTORE", Text.unpack pgRestore) | not (Text.null pgRestore)]
        <> environment
  where
    databaseVariables = ["WIKI_DATABASE_URL", "WIKI_SMOKE_RESTORE_DATABASE_URL", "WIKI_PG_DUMP", "WIKI_PG_RESTORE"]

----------------------------------------------------------------------
-- The console

-- | A user the console makes before the server starts.
data NewUser = NewUser
  { login :: Text
  , displayName :: Text
  , password :: Text
  , admin :: Bool
  }

-- | Make a user with the console (@wiki-server users add@), the password
-- on standard input, as an owner makes the first administrator.
addUser :: Built -> Database -> FilePath -> NewUser -> IO ()
addUser built database dataDir user = do
  environment <- environmentFor database
  Process.runProcess_
    . Process.setEnv environment
    . Process.setStdin (Process.byteStringInput (LazyByteString.fromStrict (Text.encodeUtf8 (user.password <> "\n"))))
    $ Process.proc built.server
    $ ["users", "add", "--data", dataDir, Text.unpack user.login, "--display-name", Text.unpack user.displayName]
      <> ["--admin" | user.admin]

-- | Restore a backup with the console into a data directory (@wiki-server
-- restore FILE --data DIR --attachments DIR@), with the database given: its
-- exit code and what it wrote, standard output and standard error.
restoreBackup :: Built -> Database -> FilePath -> FilePath -> FilePath -> IO (ExitCode, Text, Text)
restoreBackup built database backup dataDir attachments = do
  environment <- environmentFor database
  (code, out, err) <-
    Process.readProcess
      . Process.setEnv environment
      . Process.setStdin Process.nullStream
      $ Process.proc built.server ["restore", backup, "--data", dataDir, "--attachments", attachments]
  pure (code, decode out, decode err)
  where
    decode = Text.decodeUtf8With Text.lenientDecode . LazyByteString.toStrict

----------------------------------------------------------------------
-- A running server

-- | How a server is started.
data ServerOptions = ServerOptions
  { dataDir :: FilePath
  , database :: Database
  , adminListener :: Bool
  -- ^ Whether it has its admin listener (@--admin-listen 127.0.0.1:0@), or
  -- none (@--no-admin-listen@).
  , guide :: Bool
  -- ^ Whether it makes the guide's space when it starts with none
  -- (@--no-guide@ when not).
  }

-- | A server on a data directory, with its admin listener and the guide.
serverOptions :: FilePath -> Database -> ServerOptions
serverOptions dataDir database = ServerOptions {dataDir, database, adminListener = True, guide = True}

-- | A server that has started.
data Server = Server
  { build :: ServerBuild
  , options :: ServerOptions
  , origin :: Text
  -- ^ Its public listener's address, without the last slash:
  -- @http://127.0.0.1:PORT@.
  , adminOrigin :: Maybe Text
  -- ^ Its admin listener's address, without the @/admin/@ it is mounted
  -- at.
  , output :: TVar Text
  -- ^ Everything it has written, standard output and standard error.
  }

-- | Start wiki-server on the build, with these options, on ports the
-- system gives; wait until its log names every listener's address (30
-- seconds at most, or until it exits); run the body; then stop the
-- server (SIGTERM, and wait for it), whatever happened. When the body
-- fails, the server's log is written on standard error before the failure
-- goes on, so a suite's failure says what the server said.
withServer :: ServerBuild -> ServerOptions -> (Server -> IO a) -> IO a
withServer build options body = do
  environment <- environmentFor options.database
  output <- newTVarIO ""
  let arguments =
        ["serve", "--data", options.dataDir, "--static", build.app, "--listen", "127.0.0.1:0"]
          <> (if options.adminListener then ["--admin-listen", "127.0.0.1:0"] else ["--no-admin-listen"])
          <> ["--no-guide" | not options.guide]
      config =
        Process.setEnv environment
          . Process.setStdin Process.nullStream
          . Process.setStdout Process.createPipe
          . Process.setStderr Process.createPipe
          $ Process.proc build.built.server arguments
  bracket (Process.startProcess config) stop $ \process -> do
    _ <- forkIO (keep output (Process.getStdout process))
    _ <- forkIO (keep output (Process.getStderr process))
    late <- registerDelay 30_000_000
    started <- atomically $ do
      said <- readTVar output
      exited <- Process.getExitCodeSTM process
      over <- readTVar late
      let public = listener "public" said
          admin = listener "admin" said
          ready = isJustAnd public && (not options.adminListener || isJustAnd admin)
      if ready
        then pure (Right (public, admin))
        else case exited of
          Just code -> pure (Left ("wiki-server exited (" <> show code <> ")"))
          Nothing -> if over then pure (Left "wiki-server did not start in 30 seconds") else STM.retry
    case started of
      Left why -> do
        said <- readTVarIO output
        fail (why <> ":\n" <> Text.unpack said)
      Right (Just origin, admin) ->
        let server = Server {build, options, origin, adminOrigin = Text.dropWhileEnd (== '/') . stripAdmin <$> admin, output}
         in body server `onException` (serverLog server >>= \said -> Text.hPutStrLn stderr ("wiki-server's log:\n" <> said))
      Right (Nothing, _) -> fail "wiki-server named no public listener"
  where
    -- SIGTERM first, and wait for the server to exit: the threads reading
    -- its output then reach the end and let go of the pipes, which
    -- 'Process.stopProcess' closes (a handle is not closed while a read
    -- of it waits).
    stop process = do
      terminateProcess (Process.unsafeProcessHandle process)
      _ <- Process.waitExitCode process
      Process.stopProcess process
    isJustAnd = maybe False (const True)
    stripAdmin address = fromMaybe address (Text.stripSuffix "/admin" (Text.dropWhileEnd (== '/') address))

-- | Everything the server has written so far.
serverLog :: Server -> IO Text
serverLog server = readTVarIO server.output

-- | Read a handle's lines into the log until it ends.
keep :: TVar Text -> Handle -> IO ()
keep output handle = loop `finally` hClose handle
  where
    loop = do
      ended <- try (hIsEOF handle)
      case ended of
        Left (_ :: SomeException) -> pure ()
        Right True -> pure ()
        Right False -> do
          line <- try (Char8.hGetLine handle)
          case line of
            Left (_ :: SomeException) -> pure ()
            Right bytes -> do
              atomically (modifyTVar' output (<> Text.decodeUtf8With Text.lenientDecode bytes <> "\n"))
              loop

-- | The address a listener of this name took, from the server's log: the
-- line @event=listening listener=NAME address=URL@, the URL without its
-- last slash (and quoted or not, as the log writes a value).
listener :: Text -> Text -> Maybe Text
listener name said =
  listToMaybe
    [ Text.dropWhileEnd (== '/') (Text.dropAround (== '"') address)
    | line <- Text.lines said
    , let fields = Text.words line
    , "event=listening" `elem` fields
    , ("listener=" <> name) `elem` fields
    , Just address <- [listToMaybe [a | f <- fields, Just a <- [Text.stripPrefix "address=" f]]]
    ]
