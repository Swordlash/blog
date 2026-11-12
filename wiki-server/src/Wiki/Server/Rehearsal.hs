{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RankNTypes #-}

-- | 'Wiki.Server.Rehearsal' is the upgrade's rehearsal (WP5.75 of
-- docs/PLAN.md, issue #205): @wiki-server rehearse@, which a deploy runs
-- with the new program before it touches the running wiki.
--
-- The rehearsal proves that what exists still works after the upgrade. It
-- copies the running wiki's database into a scratch place, as a backup
-- does ('backupInto': @VACUUM INTO@ on SQLite, @pg_dump@ on PostgreSQL),
-- while the wiki keeps running. Each check may make something in the copy
-- first ('seed'), through the old program's console. The old program
-- serves the copy, and each check's 'before' half reads it, or makes
-- something in it, and keeps a fixture. Then this program migrates the
-- copy, checks every row, serves it, and each check's 'after' half
-- compares what it finds with the fixture. A deploy that sees a check fail
-- stops before the running wiki is touched.
--
-- Both halves of a check live in this program, the new one. The old
-- program is only driven: through what it had already, the API it serves
-- and its console. A check written for a later upgrade can use only what
-- the program deployed before it understands, which is why 'OldNotDriven'
-- is an outcome of its own: an old program that does not take the options
-- the rehearsal starts it with is not a failed check.
--
-- So what the checks drive on the old program is stable: the options of
-- @serve@ (port 0 among them) and of the database, the line @serve@ logs
-- for each listener's address ('listenedAt'), @users add@, @users list@ and its table
-- (beside the running server), @\/healthz@ (its schema
-- version), the admin listener's API
-- (@info@, the spaces, a space at a path, their pages and a page at a path, and the routes
-- toolchain/rehearse-ci.sh seeds a wiki with: making a space and a page,
-- and a space's profile), the sign-in through a
-- provider with its cookies, and @session@. Each says so in its
-- documentation, and changes only compatibly: a later version's rehearsal
-- drives it as it is now. A new check that drives something else marks it
-- the same way.
--
-- The same checks rehearse a move of the wiki to PostgreSQL (WP5.80b of
-- docs/PLAN.md, @--move-to-database URL@). The program is then the same on
-- both sides, and the database differs. The old program serves the copy
-- in SQLite, as above. After the migration and the check, this program
-- copies the copy into the empty PostgreSQL database URL names
-- (@wiki-server copy-database@'s copy, "Wiki.Server.CopyDatabase"), and
-- serves that database for each check's 'after'. So the copy's second
-- half reads what the first half made, through the other backend. The
-- checks write (an account, a provider, settings), so they run on scratch
-- databases, never on the wiki the move fills.
--
-- Both servers listen on loopback addresses, on ports the system gives,
-- which the rehearsal reads from their logs. They are read through their administration listener, which is served
-- to the loopback address as an administrator without a sign-in
-- ("Wiki.Server"). The scratch directory is the caller's: it is made here
-- (readable only by the owner, as @data/@ is, since the copy holds the
-- wiki's secrets) and deleted however the rehearsal ends.
module Wiki.Server.Rehearsal
  ( -- * The command
    RehearsalOptions (..)
  , rehearsalParser
  , RehearsalOutcome (..)
  , runRehearsal
  , isolateCopy

    -- * Checks
  , Check (..)
  , Seeding (..)
  , Server (..)
  , withServer
  , listenAnywhere
  , listenedAt
  , checks
  , runConsoleIn
  , consoleEnvironment

    -- * The pages check, for its tests
  , PageRead (..)
  , PagesRead (..)
  , readPages
  , comparePages

    -- * The home pages check, for its tests
  , SpaceRead (..)
  , readSpaces
  , compareHomes

    -- * The ways in check, for its tests
  , readUsersList
  , compareWaysIn

    -- * Paths as a program builds them
  , rootedPaths
  , PageAt (..)
  , pathAsBuilt
  )
where

import Control.Concurrent.Async qualified as Async
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString qualified as BS
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, delete, insert, insertValues, runDelete, runInsert, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Network.HTTP.Client (CookieJar, Manager, Request (..), RequestBody (..), Response, createCookieJar, defaultManagerSettings, httpLbs, managerResponseTimeout, newManager, parseRequest, responseBody, responseCookieJar, responseHeaders, responseStatus, responseTimeoutMicro, responseVersion)
import Network.HTTP.Types (hLocation, hSetCookie, statusCode, urlEncode)
import Options.Applicative
import Protolude
import Servant.Client.Core qualified as Servant
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, removePathForcibly)
import System.Environment (getEnvironment, getExecutablePath)
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, terminateProcess, waitForProcess, withCreateProcess)
import System.Timeout (timeout)
import Wiki.Api (requestMarker)
import Wiki.Api.ServerSettings (ProviderKind (..), kindName)
import Wiki.App.Account (MonadAccount (..))
import Wiki.App.Backend (Session (..))
import Wiki.App.Backend.Http (Transport (..), newHttpEnv, requestHeaderList, requestUrl, runHttpWiki)
import Wiki.App.Guide (guideSlug)
import Wiki.Core.Access (Access (..), accessName)
import Wiki.Core.Slug (slugText)
import Wiki.Core.User (Login (..), Password (..), User (..))
import Wiki.Server.Console (CheckOutcome (..), MigrateOutcome (..), runCheck, runMigrate)
import Wiki.Server.CopyDatabase (CopyOptions (..), CopyOutcome (..), runCopy)
import Wiki.Server.FakeProvider (Fake (..), clientSecret, person, withFakeProvider)
import Wiki.Server.Options (DatabaseChoice (..), PlaceOptions (..), databaseUrl, placeOptions, resolvePlace)
import Wiki.Server.Storage (Place (..), withDatabase)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Backup (Restore (..), backupInto, restore)
import Wiki.Server.Storage.Layout (PgPrograms (..))
import Wiki.Server.Storage.Migrate (hasStep)
import Wiki.Server.Storage.Migrate.Code.Step0013 (step0013)
import Wiki.Server.Storage.Migrate.Code.Step0015 (Renamed (..), renamedLogins, step0015)
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))
import Wiki.Server.Storage.Rows (deleteSettingsLike, storeSetting)
import Wiki.Server.WaysIn (printable)

--------------------------------------------------------------------------------
-- The command

-- | 'RehearsalOptions' is what @wiki-server rehearse@ is given: the old
-- program, where the running wiki is (its data directory and database, to
-- copy), and the scratch place the copy is served from.
data RehearsalOptions = RehearsalOptions
  { old :: FilePath
  -- ^ The program the wiki runs now.
  , live :: PlaceOptions
  -- ^ The running wiki, read only: its database is copied, never opened
  -- otherwise.
  , scratch :: FilePath
  -- ^ The scratch data directory, made here and deleted afterwards. It
  -- must not exist yet.
  , scratchDatabase :: Maybe (Text, Maybe FilePath)
  -- ^ A PostgreSQL database for the copy, with its password file, when the
  -- wiki is on PostgreSQL; the copy is a SQLite file in the scratch
  -- directory otherwise. The database must exist and is the caller's to
  -- drop: it is overwritten.
  , scratchRestore :: Maybe FilePath
  -- ^ The @pg_restore@ that restores into the scratch database.
  , moveTo :: Maybe (Text, Maybe FilePath)
  -- ^ For the rehearsal of a move to PostgreSQL: an empty PostgreSQL
  -- database, with its password file. The migrated copy is copied into it,
  -- and the new program serves it there. It is the caller's to make and to
  -- drop.
  }
  deriving stock (Eq, Show)

rehearsalParser :: Parser RehearsalOptions
rehearsalParser =
  RehearsalOptions
    <$> strOption (long "old" <> metavar "PROGRAM" <> help "The wiki-server the wiki runs now, which serves the copy before the migration")
    <*> placeOptions
    <*> strOption (long "scratch" <> metavar "DIR" <> help "The scratch data directory for the copy, which must not exist yet; it is deleted afterwards")
    <*> optional ((,) <$> strOption (long "scratch-database" <> metavar "URL" <> help "A PostgreSQL database for the copy, postgres://USER@HOST:PORT/NAME (overwritten)") <*> optional (strOption (long "scratch-database-password-file" <> metavar "FILE" <> help "The file that holds the scratch database's password")))
    <*> optional (strOption (long "scratch-pg-restore" <> metavar "PROGRAM" <> help "The pg_restore that restores into the scratch database"))
    <*> optional ((,) <$> option (databaseUrl "put the password in --move-to-database-password-file FILE") (long "move-to-database" <> metavar "URL" <> help "Rehearse a move to PostgreSQL: copy the migrated copy into this empty database, postgres://USER@HOST:PORT/NAME, and serve it there with this program") <*> optional (strOption (long "move-to-database-password-file" <> metavar "FILE" <> help "The file that holds that database's password")))

-- | 'RehearsalOutcome' is how a rehearsal ended. The program's exit code
-- tells them apart for the deploy: 0, 6, 7 and 1.
data RehearsalOutcome
  = -- | Every check passed: what each did and found.
    Rehearsed [Text]
  | -- | A check failed: what passed, and why the others did not.
    ChecksFailed [Text]
  | -- | The old program could not be driven: it did not start on the copy
    -- with the options the rehearsal gives it, or does not serve what the
    -- checks read. The upgrade is then not rehearsed, which is not a
    -- failed check: the deploy says so and offers to go on without it.
    OldNotDriven Text
  | -- | The rehearsal could not be set up: the copy, its restore, the
    -- migration or the new server failed, for this reason.
    RehearsalBroken Text
  deriving stock (Eq, Show)

-- | Rehearse the upgrade, as the module's documentation says.
runRehearsal :: RehearsalOptions -> IO RehearsalOutcome
runRehearsal o = do
  there <- doesDirectoryExist o.scratch
  occupied <- if there then not . null <$> listDirectory o.scratch else pure False
  if occupied
    then pure (RehearsalBroken ("The scratch directory " <> toS o.scratch <> " is not empty: the rehearsal makes it, and deletes it afterwards."))
    else rehearse o `finally` removePathForcibly o.scratch

rehearse :: RehearsalOptions -> IO RehearsalOutcome
rehearse o = either identity identity <$> runExceptT steps
  where
    broken = throwError . RehearsalBroken
    steps = do
      createDirectoryIfMissing True o.scratch & liftIO
      setFileMode o.scratch 0o700 & liftIO
      livePlace <- liftIO (resolvePlace o.live.dataDir o.live.database o.live.programs) >>= either (broken . ("The running wiki's database: " <>)) pure
      let scratchChoice = maybe (SqliteChosen (o.scratch </> "wiki.sqlite")) (uncurry PostgresChosen) o.scratchDatabase
          scratchPrograms = PgPrograms {dump = livePlace.programs.dump, restore = fromMaybe livePlace.programs.restore o.scratchRestore}
          scratchOptions = PlaceOptions {dataDir = o.scratch, database = scratchChoice, programs = scratchPrograms}
      scratchPlace <- liftIO (resolvePlace o.scratch scratchChoice scratchPrograms) >>= either (broken . ("The scratch database: " <>)) pure
      -- The copy: a backup of the running wiki, restored into the scratch
      -- place. Neither opens the running wiki for writing.
      now <- liftIO getCurrentTime
      (copy, _) <- liftIO (backupInto livePlace.programs livePlace.database (o.scratch </> "copy") now) >>= either (broken . ("The running wiki could not be copied: " <>)) pure
      _ <- liftIO (restore Restore {backupFile = copy, dataDir = o.scratch, database = scratchPlace.database, programs = scratchPrograms, attachments = Nothing}) >>= either (broken . ("The copy could not be restored: " <>)) pure
      liftIO (try (isolateCopy scratchPlace)) >>= either (\(e :: SomeException) -> broken ("The copy could not be cut off from the outside: " <> show e)) pure
      manager <- liftIO (newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 120_000_000})
      holdAll checks $ \held -> do
        -- What each check makes in the copy before the old program serves
        -- it, through the old program's console or in the copy's settings.
        let seeding = Seeding {copy = scratchPlace, console = runConsole o.old (placeArgs scratchChoice)}
        seeded <- for held $ \(Held name seed before after) ->
          liftIO (try (seed seeding)) >>= \case
            Left (e :: SomeException) -> broken ("The check of " <> name <> " could not prepare the copy: " <> show e)
            Right (Left why) -> throwError (OldNotDriven ("The check of " <> name <> " could not prepare the copy with the old program: " <> why))
            Right (Right s) -> pure (Seeded name (before s) after)
        -- The old program on the copy, and what each check keeps of it.
        fixtures <- withServer (o.scratch </> "old.log") o.old (placeArgs scratchChoice) (serveArgs scratchChoice []) (throwError . OldNotDriven) $ \server ->
          for seeded $ \(Seeded name before after) ->
            liftIO (try (before manager server)) >>= \case
              Left (e :: SomeException) -> throwError (OldNotDriven ("The check of " <> name <> " could not use the old program's wiki: " <> show e))
              Right (Left why) -> throwError (OldNotDriven ("The check of " <> name <> " could not use the old program's wiki: " <> why))
              Right (Right f) -> pure (name, \server' -> either (\(e :: SomeException) -> Left (show e)) identity <$> try (after f manager server'))
        afterTheMigration scratchOptions scratchChoice fixtures
    afterTheMigration scratchOptions scratchChoice fixtures = do
      -- The migration, and every row read back, by this program.
      liftIO (runMigrate scratchOptions) >>= \case
        MigratedTo _ -> pass
        MigrateFailed why -> broken ("The copy could not be migrated: " <> why)
        MigrateOfEarlierServer why -> broken ("The copy could not be migrated: " <> why)
      liftIO (runCheck scratchOptions) >>= \case
        CheckPassed _ -> pass
        CheckNotMigrated why -> broken ("The migrated copy was not read: " <> why)
        CheckUnreadable lines' -> broken ("The migrated copy has rows this program cannot read: " <> T.intercalate "; " (take 5 lines'))
        CheckFailed why -> broken ("The migrated copy was not read: " <> why)
      -- For a move, the migrated copy goes into the move's PostgreSQL
      -- database, which the new program serves instead.
      servedChoice <- case o.moveTo of
        Nothing -> pure scratchChoice
        Just (url, passwordFile) -> do
          let target = PostgresChosen url passwordFile
          liftIO (runCopy CopyOptions {place = scratchOptions, target}) >>= \case
            Copied _ -> pure target
            CopyNotMigrated why -> broken ("The copy could not be moved to PostgreSQL: " <> why)
            CopyUnreadable lines' -> broken ("The copy could not be moved to PostgreSQL: " <> T.intercalate "; " (take 5 lines'))
            CopyRefused why -> broken ("The copy could not be moved to PostgreSQL: " <> why)
            CopyFailed why -> broken ("The copy could not be moved to PostgreSQL: " <> why)
      -- This program on the migrated copy, and each check's verdict.
      self <- liftIO getExecutablePath
      results <- withServer (o.scratch </> "new.log") self (placeArgs servedChoice) (serveArgs servedChoice ["--no-guide"]) (broken . ("The new program did not serve the migrated copy: " <>)) $ \server ->
        for fixtures $ \(name, after) -> (name,) <$> liftIO (after server)
      let lines' = [either (\why -> name <> ": failed: " <> why) (const (name <> ": passed")) r | (name, r) <- results]
      pure (if all (isRight . snd) results then Rehearsed lines' else ChecksFailed lines')
    serveArgs choice extra = ["serve"] <> placeArgs choice <> listenAnywhere <> extra
    placeArgs choice = ["--data", o.scratch] <> databaseArgs choice
    databaseArgs = \case
      SqliteChosen file -> ["--sqlite", file]
      PostgresChosen url passwordFile -> ["--database", toS url] <> maybe [] (\f -> ["--database-password-file", f]) passwordFile
      InDataDirectory -> []

-- | Turn off, in a copy of the wiki, what a server does outside its own
-- data on its own: scheduled backups, which the scheduler copies to the
-- backup destination, and notification mail, which the notifier sends
-- through the mail server. The copy keeps the running wiki's settings, so
-- a server started on it would otherwise back the copy up to the running
-- wiki's destination and send mail the running wiki sends too. The rows go
-- from the @settings@ table, whose shape every version of the server
-- shares, so the old program finds them gone as well. The last backup's
-- record stays: it is only read.
isolateCopy :: Place -> IO ()
isolateCopy place = withDatabase place $ \c -> runDb c $ do
  deleteSettingsLike "backup-" ["backup-last"]
  deleteSettingsLike "mail-" []

(</>) :: FilePath -> FilePath -> FilePath
a </> b = a <> "/" <> b

--------------------------------------------------------------------------------
-- Servers

-- | 'Server' is a server the rehearsal started: the base of its
-- administration listener's API, which answers as an administrator, the
-- address of its public listener, where people sign in, and its program's
-- console on the same database.
data Server = Server
  { adminApi :: Text
  -- ^ @http:\/\/127.0.0.1:\<port>\/admin\/api\/v1@.
  , public :: Text
  -- ^ @http:\/\/127.0.0.1:\<port>@, with no slash at the end.
  , console :: [Text] -> Text -> IO (Either Text Text)
  -- ^ The server's program's console on the database the server serves,
  -- as 'Seeding''s console runs it: the arguments, then the place's
  -- options, with the text on standard input; its output, or what it said
  -- when it failed. The console opens the database beside the running
  -- server, as @wiki-server users@ always may.
  }

-- | Run a program's server, wait until it answers, run the action, and
-- stop the server however the action ends. The arguments are the whole
-- command line after the program; the rehearsal starts @serve@ with
-- @--listen 127.0.0.1:0 --admin-listen 127.0.0.1:0@ ('listenAnywhere'),
-- so the system gives each listener a free port, and the addresses are
-- read from the server's log ('listenedAt'). No port is chosen here, so
-- nothing can take one between its choice and its use. The place's
-- options (@--data@ and the database's) are those its console is run
-- with. What the server writes goes to a log file in the scratch
-- directory, not a pipe: a pipe nobody reads fills up and stops the
-- server. The log is bytes, read as UTF-8; the server runs with a UTF-8
-- locale ('consoleEnvironment'), so that an old one does not fail on a
-- name it logs. A server that exits, or does not log its addresses and
-- answer within a minute, is reported to @failed@ with the end of its
-- log.
withServer :: FilePath -> FilePath -> [[Char]] -> [[Char]] -> (Text -> ExceptT RehearsalOutcome IO a) -> (Server -> ExceptT RehearsalOutcome IO a) -> ExceptT RehearsalOutcome IO a
withServer logFile program placeArgs args failed act = do
  logHandle <- liftIO (openFile logFile WriteMode)
  environment <- liftIO (consoleEnvironment <$> getEnvironment)
  (_, _, _, process) <- liftIO (createProcess (proc program args) {env = Just environment, std_in = NoStream, std_out = UseHandle logHandle, std_err = UseHandle logHandle})
  let stop = do
        terminateProcess process
        void (timeout 20_000_000 (waitForProcess process))
        hClose logHandle
  ExceptT $
    ( runExceptT $
        liftIO (answers process logFile) >>= \case
          Left how -> do
            said <- liftIO (T.strip . T.takeEnd 2000 <$> readLog logFile)
            failed (toS program <> " " <> how <> (if T.null said then "" else ": " <> said))
          Right (public, admin) -> act Server {adminApi = admin <> "/api/v1", public, console = runConsole program placeArgs}
    )
      `finally` stop

-- | The options that make @wiki-server serve@ listen on a port the system
-- gives for each of its two listeners, on the loopback address. Every
-- version of the server takes port 0, and logs the address it took.
listenAnywhere :: [[Char]]
listenAnywhere = ["--listen", "127.0.0.1:0", "--admin-listen", "127.0.0.1:0"]

-- | Wait, for a minute, until the server has logged the addresses of its
-- public and admin listeners and answers @info@ on the admin one. 'Right'
-- has the two addresses, as 'listenedAt' reads them; 'Left' says how the
-- server failed to answer.
answers :: ProcessHandle -> FilePath -> IO (Either Text (Text, Text))
answers process logFile = do
  manager <- newManager defaultManagerSettings
  let attempt :: Int -> IO (Either Text (Text, Text))
      attempt n =
        getProcessExitCode process >>= \case
          Just code -> pure (Left ("exited (" <> show code <> ") before it answered"))
          Nothing -> do
            logged <- readLog logFile
            found <- case (listenedAt "public" logged, listenedAt "admin" logged) of
              (Just public, Just admin) -> getJson manager (admin <> "/api/v1/info") <&> either (const Nothing) (const (Just (public, admin)))
              _ -> pure Nothing
            case found of
              Just addresses -> pure (Right addresses)
              Nothing
                | n <= 0 -> pure (Left "did not answer within a minute")
                | otherwise -> threadDelay 250_000 >> attempt (n - 1)
  attempt 240

-- | The address a listener of the server took, as the server's log says:
-- the line @event=listening listener=NAME address=URL@ that every version
-- of the server writes for each listener once it listens ("Wiki.Server").
-- The address is the listener's root with no slash at its end: the public
-- listener's @http:\/\/127.0.0.1:41377@ (its base path, @\/@, dropped),
-- the admin listener's @http:\/\/127.0.0.1:41378\/admin@. 'Nothing' while
-- the log has no such line.
listenedAt :: Text -> Text -> Maybe Text
listenedAt name logged =
  head
    [ T.dropWhileEnd (== '/') (T.dropAround (== '"') address)
    | line <- T.lines logged
    , let fields = T.words line
    , "event=listening" `elem` fields
    , ("listener=" <> name) `elem` fields
    , Just address <- [asum (map (T.stripPrefix "address=") fields)]
    ]

-- | The server's log so far, as UTF-8; empty when it cannot be read.
readLog :: FilePath -> IO Text
readLog file = try @SomeException (BS.readFile file) <&> either (const "") decodeUtf8

-- | A POST of JSON, answered with JSON: the value, or why not. A write
-- through the administration API answers 200 or 201, and is made with the
-- header the application's own writes carry ('Wiki.Api.requestMarker'),
-- which every listener asks of a write.
postJson :: Manager -> Text -> Value -> IO (Either Text Value)
postJson manager url body =
  try @SomeException (parseRequest (toS url) >>= \r -> httpLbs r {method = "POST", requestHeaders = [("Content-Type", "application/json"), bimap (CI.mk . encodeUtf8) encodeUtf8 requestMarker], requestBody = RequestBodyLBS (encode body)} manager) <&> \case
    Left e -> Left (show e)
    Right response
      | statusCode (responseStatus response) `notElem` [200, 201] -> Left ("POST " <> url <> " answered " <> show (statusCode (responseStatus response)))
      | otherwise -> first (\why -> "POST " <> url <> ": " <> toS why) (eitherDecode (responseBody response))

-- | A GET of JSON: the value, or why not.
getJson :: Manager -> Text -> IO (Either Text Value)
getJson manager url =
  try @SomeException (parseRequest (toS url) >>= \r -> httpLbs r manager) <&> \case
    Left e -> Left (show e)
    Right response
      | statusCode (responseStatus response) /= 200 -> Left ("GET " <> url <> " answered " <> show (statusCode (responseStatus response)))
      | otherwise -> first (\why -> "GET " <> url <> ": " <> toS why) (eitherDecode (responseBody response))

--------------------------------------------------------------------------------
-- Checks

-- | 'Check' is one thing an upgrade must keep working. A feature that
-- changes how existing data is read or used adds a check here, written
-- against what the program deployed before it understands. A check has
-- four parts, run in this order:
--
-- * 'holding': what the check keeps running for the whole rehearsal, given
--   to the other three (a fake sign-in provider; nothing for most).
-- * 'seed': what it makes in the copy before the old program serves it,
--   through the old program's console or in the copy's settings
--   ('Seeding'). Its result goes to 'before'.
-- * 'before': what it does with the old program's server and keeps, the
--   fixture.
-- * 'after': what it checks with the new program's server against the
--   fixture.
--
-- A 'Left' of 'seed' or 'before' means the old program could not be
-- driven ('OldNotDriven'); a 'Left' of 'after' is a failed check.
data Check = forall held seeded fixture. Check
  { name :: Text
  , holding :: forall a. (held -> IO a) -> IO a
  , seed :: held -> Seeding -> IO (Either Text seeded)
  , before :: held -> seeded -> Manager -> Server -> IO (Either Text fixture)
  , after :: held -> fixture -> Manager -> Server -> IO (Either Text ())
  }

-- | 'Seeding' is what a check's 'seed' may use: the copy, not served yet,
-- and the old program's console on it.
data Seeding = Seeding
  { copy :: Place
  -- ^ The copy's data directory and database, at the old program's
  -- schema. Only tables whose shape every version shares may be written,
  -- such as @settings@, and through row types declared for the copy (as
  -- 'CopyProvider' is), not those of "Wiki.Server.Storage.Schema", which
  -- are this program's.
  , console :: [Text] -> Text -> IO (Either Text Text)
  -- ^ Run the old program with these arguments, followed by the copy's
  -- @--data@ and database options, with this text on its standard input.
  -- Its output, or what it said when it failed. A command a check runs
  -- here is stable from then on, and says so in its documentation.
  }

-- | A check while its 'holding' runs: its other parts, given what it
-- holds.
data Held = forall seeded fixture. Held Text (Seeding -> IO (Either Text seeded)) (seeded -> Manager -> Server -> IO (Either Text fixture)) (fixture -> Manager -> Server -> IO (Either Text ()))

-- | A check after its 'seed': its 'before', given what the seed made, and
-- its 'after'.
data Seeded = forall fixture. Seeded Text (Manager -> Server -> IO (Either Text fixture)) (fixture -> Manager -> Server -> IO (Either Text ()))

-- | Run every check's 'holding' around the action, nested in the checks'
-- order.
holdAll :: [Check] -> ([Held] -> ExceptT e IO a) -> ExceptT e IO a
holdAll [] act = act []
holdAll (Check name holding seed before after : rest) act =
  ExceptT $ holding $ \h -> runExceptT $ holdAll rest $ \others -> act (Held name (seed h) (before h) (after h) : others)

-- | Run a program's console command on the copy: the arguments, then the
-- copy's place options, with the text on standard input. The program runs
-- in this process's environment with a UTF-8 locale ('consoleEnvironment'),
-- and what it writes is read as UTF-8 bytes, whatever this process's
-- locale is: an old program from before wiki-server set its own encoding
-- writes in its locale's, and in the C locale it cannot write a name
-- beyond ASCII at all.
runConsole :: FilePath -> [[Char]] -> [Text] -> Text -> IO (Either Text Text)
runConsole program placeArgs args input = do
  environment <- getEnvironment
  runConsoleIn environment program placeArgs args input

-- | 'runConsole' with this environment in place of this process's: for
-- the tests, which give it a C locale.
runConsoleIn :: [([Char], [Char])] -> FilePath -> [[Char]] -> [Text] -> Text -> IO (Either Text Text)
runConsoleIn environment program placeArgs args input =
  try run <&> \case
    Left (e :: SomeException) -> Left (show e)
    Right (ExitSuccess, out, _) -> Right out
    Right (ExitFailure code, out, err) ->
      Left (T.unwords args <> " exited with " <> show code <> ": " <> T.strip (err <> out) <> (if "cannot encode character" `T.isInfixOf` err then noUtf8 else ""))
  where
    child = (proc program (map toS args <> placeArgs)) {env = Just (consoleEnvironment environment), std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}
    run = withCreateProcess child $ \toChild fromChild errors process -> do
      -- The input is a line or two: it fits in the pipe, and a program
      -- that exits without reading it is not an error.
      for_ toChild $ \h -> void (try @IOException (BS.hPut h (encodeUtf8 input) >> hClose h))
      (out, err) <- Async.concurrently (maybe (pure "") BS.hGetContents fromChild) (maybe (pure "") BS.hGetContents errors)
      code <- waitForProcess process
      pure (code, decodeUtf8With lenientDecode out, decodeUtf8With lenientDecode err)
    noUtf8 =
      " (the program could not write a character beyond ASCII, such as a name's: this machine has no UTF-8 locale for it, though C.UTF-8 was asked for. Install one or set LANG to one, or deploy with --no-rehearsal)"

-- | The environment a program the rehearsal runs gets: this one, with
-- @LC_ALL=C.UTF-8@ when the locale it names (@LC_ALL@, else @LC_CTYPE@,
-- else @LANG@) is not a UTF-8 one. A GHC program in the C or POSIX locale
-- fails on the first character beyond ASCII it writes, and the old
-- program, deployed already, cannot be changed to set its own encoding.
-- glibc has C.UTF-8 built in since 2.35, and Debian, Ubuntu and RHEL 8 ship
-- it. A locale that names UTF-8 already is kept, with the rest of the
-- environment.
consoleEnvironment :: [([Char], [Char])] -> [([Char], [Char])]
consoleEnvironment environment
  | any (`T.isInfixOf` T.toLower (toS locale)) ["utf-8", "utf8"] = environment
  | otherwise = ("LC_ALL", "C.UTF-8") : filter ((/= "LC_ALL") . fst) environment
  where
    locale = fromMaybe "" (find (not . null) (mapMaybe (`lookup` environment) ["LC_ALL", "LC_CTYPE", "LANG"]))

-- | Every check, in the order they run. The links check comes first: it
-- writes a space and its pages on the old program, which the checks after
-- it then read before the migration as they read them after.
checks :: [Check]
checks = [linksCheck, pagesCheck, accountsCheck, homesCheck, rootsCheck, waysInCheck, loginsCheck]

-- | A check that holds nothing and makes nothing before the old program
-- serves the copy.
simpleCheck :: Text -> (Manager -> Server -> IO (Either Text fixture)) -> (fixture -> Manager -> Server -> IO (Either Text ())) -> Check
simpleCheck name before after =
  Check
    { name
    , holding = ($ ())
    , seed = \() _ -> pure (Right ())
    , before = \() () -> before
    , after = \() -> after
    }

--------------------------------------------------------------------------------
-- The links check

-- | The links check (WP5.88 of docs/PLAN.md, issue #189): a page that
-- another page linked to before the upgrade lists that page among its
-- backlinks after it. The new program fills its table of links when it
-- first opens the copy ("Wiki.Server.Storage.Rows", "Links"), and this
-- checks that it did. Before the migration it makes a space of its own on
-- the old program, with a page and a page that links to it by its title,
-- through the administration API (@POST spaces@ and @POST
-- spaces\/\<id>\/pages@, stable already: toolchain/rehearse-ci.sh seeds a
-- wiki with them). After it, the first page's
-- backlinks (@GET pages\/\<id>\/backlinks@) must hold the second. The
-- space stays in the copy, which is thrown away.
linksCheck :: Check
linksCheck = simpleCheck "links" before after
  where
    before manager server = runExceptT $ do
      suffix <- liftIO (decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 4 :: IO ByteString))
      space <- ExceptT (postJson manager (server.adminApi <> "/spaces") (object ["parent" .= Null, "name" .= ("Rehearsal links " <> suffix)]))
      sid <- maybe (throwError "the new space has no id") pure (field "id" space)
      let pageIn title body = do
            made <- ExceptT (postJson manager (server.adminApi <> "/spaces/" <> sid <> "/pages") (object ["parent" .= Null, "title" .= title, "body" .= body]))
            maybe (throwError ("the new page " <> title <> " has no id")) pure (field "id" made)
      linked <- pageIn "Linked page" ""
      linking <- pageIn "Linking page" ("See [[Linked page]]." :: Text)
      pure (linked, linking)
    after (linked, linking) manager server = runExceptT $ do
      listed <- ExceptT (getJson manager (server.adminApi <> "/pages/" <> linked <> "/backlinks")) >>= asList "the backlinks"
      unless (Just linking `elem` map (field "page") listed) $
        throwError ("the page " <> linked <> " does not list the page " <> linking <> ", which links to it, among its backlinks")

--------------------------------------------------------------------------------
-- The pages check

-- | 'PageRead' is a page as the pages check reads it: its space's id, its
-- id, its title and its Markdown source.
data PageRead = PageRead
  { space :: Text
  , page :: Text
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show)

-- | 'PagesRead' is what the pages check reads of a server: every page it
-- reads, and the home page of each space whose pages it reads ('Nothing'
-- for a space with none), by the space's id.
data PagesRead = PagesRead
  { pages :: [PageRead]
  , homes :: Map Text (Maybe Text)
  }
  deriving stock (Eq, Show)

-- | The pages check: every page of every space reads the same after the
-- migration, its title and its source. The guide's space is left out: its
-- pages are the program's own, and change with its version. The only page
-- the migration may add is the home page step 12 of the schema gives a
-- space that had none ("Wiki.Server.Storage.Migrate.Code.Step0012").
pagesCheck :: Check
pagesCheck = simpleCheck "pages" readPages (\was manager server -> readPages manager server <&> (>>= comparePages was))

-- | Every page of every space but the guide's, read through a server's
-- administration API at its path as that server builds it ('pathAsBuilt':
-- from under the home page for a program with step 13 of the schema), with
-- each space's home page. A space whose pages
-- answer 404 is left out: the list of spaces names some that nobody may
-- read, administrators included (the container of personal spaces, and a
-- personal space its owner hid; "Wiki.Core.Permission"). So is a space
-- whose pages answer 409: an encrypted space, whose pages the server keeps
-- only as ciphertext and does not list as plain text. A space read before
-- the migration and not after still shows: its pages are then gone.
readPages :: Manager -> Server -> IO (Either Text PagesRead)
readPages manager server = runExceptT $ do
  rooted <- ExceptT (rootedPaths manager server)
  spaces <- ExceptT (getJson manager (server.adminApi <> "/spaces")) >>= asList "the spaces"
  let byId = Map.fromList [(i, s) | s <- spaces, Just i <- [field "id" s]]
      inGuide s = case (field "parent" s, field "slug" s) of
        (Nothing, Just slug) -> slug == slugText guideSlug
        (Just p, _) -> maybe False inGuide (Map.lookup p byId)
        _ -> False
  read' <- for [(i, s) | (i, s) <- Map.toList byId, not (inGuide s)] $ \(i, s) ->
    fmap (\ps -> (i, field "homePage" s, ps)) <$> pagesOf rooted i (field "homePage" s)
  pure PagesRead {pages = concat [ps | Just (_, _, ps) <- read'], homes = Map.fromList [(i, h) | Just (i, h, _) <- read']}
  where
    pagesOf rooted spaceId home =
      ExceptT (getJsonUnless [404, 409] manager (server.adminApi <> "/spaces/" <> spaceId <> "/pages")) >>= \case
        Nothing -> pure Nothing
        Just listed -> Just <$> (asList ("the pages of space " <> spaceId) listed >>= pagesIn rooted spaceId home)
    pagesIn rooted spaceId home summaries = do
      let at = pagesAtOf summaries
      for at $ \p -> do
        let url = pageUrl server spaceId (fromMaybe [] (pathAsBuilt rooted home at p.page))
        read' <- ExceptT (getJson manager url)
        case (,) <$> field "title" read' <*> field "body" read' of
          Just (title, body) -> pure PageRead {space = spaceId, page = p.page, title, body}
          Nothing -> throwError ("GET " <> url <> " gave no title and source")

-- | A JSON list's items, or why not.
asList :: (Monad m) => Text -> Value -> ExceptT Text m [Value]
asList what = \case
  Array xs -> pure (toList xs)
  _ -> throwError (what <> " are not a list")

--------------------------------------------------------------------------------
-- Paths as a program builds them

-- | Whether a server builds a page's path from under its space's home
-- page, the root of the space's pages, with no segment for the home page
-- (step 13 of the schema, "Wiki.Server.Storage.Migrate.Code.Step0013"),
-- or with every slug from the space's top-level pages, as a program before
-- it did. Its schema version says which: @\/healthz@, at the root of the
-- public listener, gives it, and has since before the rehearsal existed.
rootedPaths :: Manager -> Server -> IO (Either Text Bool)
rootedPaths manager server =
  getJson manager (server.public <> "/healthz") <&> \case
    Left why -> Left why
    Right v -> case v of
      Object o | Just (Number n) <- KeyMap.lookup "schemaVersion" o -> Right (n >= fromIntegral step0013.version)
      _ -> Left ("GET " <> server.public <> "/healthz gave no schema version")

-- | 'PageAt' is where a page is, as a space's list of pages gives it: its
-- id, its parent's, and its slug.
data PageAt = PageAt
  { page :: Text
  , parent :: Maybe Text
  , slug :: Text
  }
  deriving stock (Eq, Show)

-- | The pages of a list of pages, where each is.
pagesAtOf :: [Value] -> [PageAt]
pagesAtOf summaries = [PageAt {page = i, parent = field "parent" p, slug} | p <- summaries, Just i <- [field "id" p], Just slug <- [field "slug" p]]

-- | A page's path as a program builds it: the slugs from the space's top
-- level down to the page, and for a program that builds paths from under
-- the home page ('rootedPaths') without the home page's own, when the
-- page is under it or is it. 'Nothing' for a page not among them, or one
-- whose parents go round.
pathAsBuilt :: Bool -> Maybe Text -> [PageAt] -> Text -> Maybe [Text]
pathAsBuilt rooted home pages i = map (\p -> p.slug) . underRoot <$> chain mempty i
  where
    byId = Map.fromList [(p.page, p) | p <- pages]
    chain seen k
      | k `elem` seen = Nothing
      | otherwise = do
          p <- Map.lookup k byId
          above <- maybe (Just []) (chain (k : seen)) p.parent
          pure (above <> [p])
    underRoot = \case
      top : rest | rooted, Just top.page == home -> rest
      c -> c

-- | The address of a space's page at a path in a server's administration
-- API: @…\/pages\/at@ and the path's segments, none for the empty path.
pageUrl :: Server -> Text -> [Text] -> Text
pageUrl server spaceId path = server.adminApi <> "/spaces/" <> spaceId <> "/pages/at" <> foldMap (\s -> "/" <> segment s) path

-- | A slug as a segment of an address.
segment :: Text -> Text
segment = decodeUtf8 . urlEncode False . encodeUtf8

-- | A GET of JSON, as 'getJson', with 'Nothing' for an answer of one of
-- these statuses.
getJsonUnless :: [Int] -> Manager -> Text -> IO (Either Text (Maybe Value))
getJsonUnless statuses manager url =
  try @SomeException (parseRequest (toS url) >>= \r -> httpLbs r manager) <&> \case
    Left e -> Left (show e)
    Right response
      | statusCode (responseStatus response) `elem` statuses -> Right Nothing
      | statusCode (responseStatus response) /= 200 -> Left ("GET " <> url <> " answered " <> show (statusCode (responseStatus response)))
      | otherwise -> bimap (\why -> "GET " <> url <> ": " <> toS why) Just (eitherDecode (responseBody response))

-- | A text field of a JSON object.
field :: Text -> Value -> Maybe Text
field k = \case
  Object o -> case KeyMap.lookup (Key.fromText k) o of
    Just (String t) -> Just t
    _ -> Nothing
  _ -> Nothing

-- | Whether the pages read after the migration are those read before:
-- each page by its id, with its title and source. A page that is new is
-- accepted only as the home page of a space that had none before. Why
-- not names the first few differences.
comparePages :: PagesRead -> PagesRead -> Either Text ()
comparePages was now = listProblems problems
  where
    key p = (p.space, p.page)
    before' = Map.fromList [(key p, p) | p <- was.pages]
    after' = Map.fromList [(key p, p) | p <- now.pages]
    givenHome q = Map.lookup q.space was.homes == Just Nothing && Map.lookup q.space now.homes == Just (Just q.page)
    problems =
      ["page " <> p.page <> " (" <> p.title <> ") is gone" | (k, p) <- Map.toList before', not (Map.member k after')]
        <> [ "page " <> p.page <> " (" <> p.title <> ") " <> what
           | (k, p) <- Map.toList before'
           , Just q <- [Map.lookup k after']
           , what <- ["has another title: " <> q.title | q.title /= p.title] <> ["has another source" | q.body /= p.body]
           ]
        <> ["page " <> q.page <> " (" <> q.title <> ") is new" | (k, q) <- Map.toList after', not (Map.member k before'), not (givenHome q)]

-- | 'Right' for no problems, or the first five and how many more.
listProblems :: [Text] -> Either Text ()
listProblems problems
  | null problems = Right ()
  | otherwise = Left (T.intercalate "; " (take 5 problems) <> (if length problems > 5 then "; and " <> show (length problems - 5) <> " more" else ""))

--------------------------------------------------------------------------------
-- The home pages check

-- | 'SpaceRead' is a space as the home pages check reads it: its id, its
-- name, its home page if it has one, and whether it is one of the two
-- kinds that have none (the container of personal spaces, an encrypted
-- space).
data SpaceRead = SpaceRead
  { space :: Text
  , name :: Text
  , homePage :: Maybe Text
  , withoutHome :: Bool
  }
  deriving stock (Eq, Show)

-- | The home pages check, step 12 of the schema's
-- ("Wiki.Server.Storage.Migrate.Code.Step0012", WP5.78 of docs/PLAN.md):
-- after the migration, every space has a home page but the two kinds that
-- have none, and a space that had one keeps it. The pages check makes sure
-- the page a space is given is the only page the migration adds.
homesCheck :: Check
homesCheck = simpleCheck "home pages" readSpaces (\was manager server -> readSpaces manager server <&> (>>= compareHomes was))

-- | Every space a server lists, read through its administration API. A
-- program older than personal spaces or encrypted spaces lists spaces
-- without @personalContainer@ or @encryption@: none of its spaces is
-- either kind.
readSpaces :: Manager -> Server -> IO (Either Text [SpaceRead])
readSpaces manager server = runExceptT $ do
  listed <- ExceptT (getJson manager (server.adminApi <> "/spaces"))
  spaces <- case listed of
    Array xs -> pure (toList xs)
    _ -> throwError "the spaces are not a list"
  pure
    [ SpaceRead {space = i, name = fromMaybe i (field "name" s), homePage = field "homePage" s, withoutHome = isTrue "personalContainer" s || present "encryption" s}
    | s <- spaces
    , Just i <- [field "id" s]
    ]
  where
    isTrue k = \case
      Object o -> KeyMap.lookup (Key.fromText k) o == Just (Bool True)
      _ -> False
    present k = \case
      Object o -> maybe False (/= Null) (KeyMap.lookup (Key.fromText k) o)
      _ -> False

-- | Whether the spaces read after the migration have the home pages they
-- should: every space but the two kinds has one, and one that had a home
-- page before has the same one. Why not names the first few spaces that
-- do not.
compareHomes :: [SpaceRead] -> [SpaceRead] -> Either Text ()
compareHomes was now =
  listProblems $
    ["space " <> s.space <> " (" <> s.name <> ") has no home page" | s <- now, not s.withoutHome, isNothing s.homePage]
      <> [ "space " <> s.space <> " (" <> s.name <> ") has another home page"
         | s <- now
         , Just old <- [find (\o -> o.space == s.space) was]
         , isJust old.homePage
         , old.homePage /= s.homePage
         ]

--------------------------------------------------------------------------------
-- The roots check

-- | 'RootsRead' is what the roots check reads of a server before the
-- migration: each space it may read (but the guide's), by its id, with
-- its path and its home page; and each page at the top of a space's
-- pages, with its address as the program builds it ('pathAsBuilt').
data RootsRead = RootsRead
  { spaces :: [(Text, [Text], Maybe Text)]
  , tops :: [(Text, Text, [Text])]
  -- ^ The space's id, the page's id, the page's path.
  }
  deriving stock (Eq, Show)

-- | The roots check, step 13 of the schema's
-- ("Wiki.Server.Storage.Migrate.Code.Step0013", WP5.78 of docs/PLAN.md):
-- after the migration, every page that was at the top of its space's
-- pages answers at the address it had, and every space answers at its
-- own, with its home page at the space's address (the empty path). The
-- home page is checked there and not at its old address, which a page
-- under it with the home page's slug rightly takes over. A
-- space whose pages answer 404 or 409 is left out, as the pages check
-- leaves it out.
rootsCheck :: Check
rootsCheck = simpleCheck "roots" readRoots (\was manager server -> compareRoots was manager server)

-- | The spaces and the top-level pages, as a server lists them.
readRoots :: Manager -> Server -> IO (Either Text RootsRead)
readRoots manager server = runExceptT $ do
  rooted <- ExceptT (rootedPaths manager server)
  spaces <- ExceptT (getJson manager (server.adminApi <> "/spaces")) >>= asList "the spaces"
  let byId = Map.fromList [(i, s) | s <- spaces, Just i <- [field "id" s]]
      pathOf seen s = case (field "parent" s, field "slug" s) of
        (_, Nothing) -> Nothing
        (Nothing, Just slug) -> Just [slug]
        (Just p, Just slug)
          | p `elem` seen -> Nothing
          | otherwise -> (<> [slug]) <$> (pathOf (p : seen) =<< Map.lookup p byId)
      inGuide s = maybe False (\p -> take 1 p == [slugText guideSlug]) (pathOf [] s)
  read' <- for [(i, s, path) | (i, s) <- Map.toList byId, not (inGuide s), Just path <- [pathOf [] s]] $ \(i, s, path) -> do
    let home = field "homePage" s
    ExceptT (getJsonUnless [404, 409] manager (server.adminApi <> "/spaces/" <> i <> "/pages")) >>= \case
      Nothing -> pure Nothing
      Just listed -> do
        at <- pagesAtOf <$> asList ("the pages of space " <> i) listed
        -- The home page is checked at the space's address, where it is
        -- after the step: its old address may now name a page under it
        -- with the same slug, which the path as written reaches first.
        pure (Just ((i, path, home), [(i, p.page, built) | p <- at, isNothing p.parent, Just p.page /= home, Just built <- [pathAsBuilt rooted home at p.page]]))
  pure RootsRead {spaces = map fst (catMaybes read'), tops = concatMap snd (catMaybes read')}

-- | Whether every space and every page that was at the top answers where
-- it did. Why not names the first few that do not.
compareRoots :: RootsRead -> Manager -> Server -> IO (Either Text ())
compareRoots was manager server = do
  spaceProblems <- for was.spaces $ \(i, path, home) -> do
    let at = server.adminApi <> "/spaces/at/" <> T.intercalate "/" (map segment path)
    answered <- getJson manager at
    homeAnswer <- getJson manager (pageUrl server i [])
    pure $
      [ "space " <> i <> " does not answer at /" <> T.intercalate "/" path <> ": " <> either identity (const "another space does") answered
      | either (const True) (\v -> field "id" v /= Just i) answered
      ]
        <> [ "space " <> i <> " shows no home page at its address" <> either (": " <>) (const "") homeAnswer
           | either (const True) (\v -> isNothing (field "id" v)) homeAnswer
           ]
        <> [ "space " <> i <> " shows another page than its home page at its address"
           | Right v <- [homeAnswer]
           , isJust home
           , field "id" v /= home
           ]
  pageProblems <- for was.tops $ \(sid, pid, path) -> do
    answered <- getJson manager (pageUrl server sid path)
    pure
      [ "page " <> pid <> " of space " <> sid <> " does not answer at " <> T.intercalate "/" path <> either (": " <>) (const "") answered
      | either (const True) (\v -> field "id" v /= Just pid) answered
      ]
  pure (listProblems (concat spaceProblems <> concat pageProblems))

--------------------------------------------------------------------------------
-- The accounts check

-- | The accounts check (the owner, 2026-11-09, on WP5.74a): accounts made
-- on the old program still sign in on the new one. Two accounts are made
-- in the copy, with a login and a provider subject nobody has
-- ('Canary'):
--
-- * one with a password, by the old program's console (@users add@),
--   before the old program serves the copy;
-- * one through a fake OpenID Connect provider ("Wiki.Server.FakeProvider"),
--   by signing in with it on the old program's server.
--
-- After the migration, the first signs in on the new server with its
-- password as the application does ("Wiki.App.Backend.Http"), through the
-- client of the @opaque-hs@ package. Since OPAQUE (WP5.74a), @users add@
-- registers the password through OPAQUE, so the check proves that an
-- upgrade keeps the records it finds signing in. An old program from
-- before OPAQUE stored a hash instead: its account signs in the old way
-- once, which moves it to OPAQUE. So the canary signs in a second time,
-- which must not use the old way. The second account signs in through the
-- provider again and must be the same account.
--
-- For this the copy is opened to newcomers (its @access@ setting: a closed
-- wiki makes no account for a provider's newcomer), the fake is added to
-- its providers, and its public address is set to 'rehearsalUrl'. The
-- provider sends the browser back to that address, which the check maps
-- to the server it talks to. All three change the copy only.
accountsCheck :: Check
accountsCheck =
  Check
    { name = "accounts"
    , holding = withFakeProvider
    , seed = seedAccounts
    , before = \_ canary manager server -> runExceptT $ do
        who <- ExceptT (providerSignIn manager server)
        pure (canary, who)
    , after = \_ (canary, was) manager server -> runExceptT $ do
        moved <- ExceptT (appSignIn manager server canary.login canary.password <&> first ("the password's first sign-in: " <>))
        again <- ExceptT (appSignIn manager server canary.login canary.password <&> first ("the password's second sign-in: " <>))
        when (any oldSignIn again) $
          throwError ("the password's second sign-in went the old way, so the first did not move the account to OPAQUE (the first sent " <> T.intercalate ", " (map shown moved) <> ")")
        now <- ExceptT (providerSignIn manager server <&> first ("the provider's sign-in: " <>))
        unless (now == was) $ throwError ("the provider's sign-in is user " <> now <> ", not user " <> was <> " as before the migration")
    }
  where
    oldSignIn (method', path) = method' == "POST" && path == "api/v1/session"
    shown (method', path) = decodeUtf8 method' <> " " <> path

-- | 'Canary' is what the accounts check makes: a login, its password,
-- and the subject the fake provider signs in.
data Canary = Canary
  { login :: Text
  , password :: Text
  , subject :: Text
  }

-- | The public address the copy's servers are given: the provider sends
-- the browser back to it, and the check maps it to the server
-- ('onServer').
rehearsalUrl :: Text
rehearsalUrl = "http://wiki.rehearsal/"

-- | The fake provider's name in the copy.
rehearsalProvider :: Text
rehearsalProvider = "rehearsal"

-- | Make the password's account with the old program's console, and set
-- the copy up for the provider's.
seedAccounts :: Fake -> Seeding -> IO (Either Text Canary)
seedAccounts fake seeding = runExceptT $ do
  tag <- liftIO (decodeUtf8 . convertToBase @ByteString Base16 <$> (getRandomBytes 8 :: IO ByteString))
  let canary = Canary {login = "rehearsal-" <> tag, password = "rehearsal-password-" <> tag, subject = "rehearsal-provider-" <> tag}
  liftIO (writeIORef fake.user (person canary.subject))
  _ <- ExceptT (seeding.console ["users", "add", canary.login, "--display-name", "Rehearsal"] (canary.password <> "\n"))
  liftIO $ withDatabase seeding.copy $ \c -> runDb c $ do
    storeSetting "access" (accessName Open)
    storeSetting "public-url" rehearsalUrl
    runDelete (delete copyDb.sign_in_providers (\p -> p.name ==. val_ rehearsalProvider))
    runInsert . insert copyDb.sign_in_providers $
      insertValues [CopyProvider {name = rehearsalProvider, position = 1000, kind = kindName Generic, client_id = "rehearsal-client", issuer = Just fake.url, secret = Just clientSecret}]
  pure canary

-- | 'CopyProvider' is a row of @sign_in_providers@ as the accounts check
-- writes it into the copy, before the migration: the columns the table has
-- had since the first schema file. It is declared here rather than taken
-- from "Wiki.Server.Storage.Schema" because the copy is at the old
-- program's schema, not this program's: a column a later schema adds would
-- not be in the copy yet, and an insert that names it would fail.
data CopyProvider f = CopyProvider
  { name :: Columnar f Text
  , position :: Columnar f Int32
  , kind :: Columnar f Text
  , client_id :: Columnar f Text
  , issuer :: Columnar f (Maybe Text)
  , secret :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table CopyProvider where
  newtype PrimaryKey CopyProvider f = CopyProviderKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = CopyProviderKey r.name

-- | 'CopyUser' is a row of @users@ as the logins check reads and writes it
-- in the copy, before the migration: the user's id and login, which the
-- table has had since the first schema file. It is declared here for the
-- reason 'CopyProvider' is.
data CopyUser f = CopyUser
  { id :: Columnar f Text
  , login :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table CopyUser where
  newtype PrimaryKey CopyUser f = CopyUserKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = CopyUserKey r.id

-- | The tables of the copy the checks write, at the old program's schema.
data CopyDb f = CopyDb
  { sign_in_providers :: f (TableEntity CopyProvider)
  , users :: f (TableEntity CopyUser)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

copyDb :: DatabaseSettings be CopyDb
copyDb = defaultDbSettings

-- | Sign in through the fake provider as a browser does: the server's
-- start, the provider, and back to the server's callback with the round
-- trip's cookie. The id of the user the session is for.
providerSignIn :: Manager -> Server -> IO (Either Text Text)
providerSignIn manager server = runExceptT $ do
  started <- fetch (server.public <> "/auth/" <> rehearsalProvider <> "/start?next=%2F") []
  unless (statusOf started == 302) $ throwError ("the sign-in did not go to the provider: " <> describe started)
  flow <- maybe (throwError "the sign-in's start set no wiki_oidc cookie") pure (cookieOf "wiki_oidc" started)
  atProvider <- fetch (locationOf started) []
  unless (statusOf atProvider == 302) $ throwError ("the provider did not send the browser back: " <> describe atProvider)
  landed <- fetch (onServer (locationOf atProvider)) [("Cookie", "wiki_oidc=" <> encodeUtf8 flow)]
  unless (statusOf landed == 200) $ throwError ("the callback did not sign in: " <> describe landed)
  session <- maybe (throwError "the callback set no wiki_session cookie") pure (cookieOf "wiki_session" landed)
  sessionReply <- fetch (server.public <> "/api/v1/session") [("Cookie", "wiki_session=" <> encodeUtf8 session)]
  either (throwError . ("the session: " <>)) pure $ do
    decoded <- if statusOf sessionReply == 200 then first toS (eitherDecode (responseBody sessionReply)) else Left (describe sessionReply)
    maybe (Left "no user is signed in") Right (userOf decoded >>= field "id")
  where
    fetch url hs =
      ExceptT $
        try @SomeException (parseRequest (toS url) >>= \r -> httpLbs r {requestHeaders = ("X-Wiki-Request", "1") : hs, redirectCount = 0} manager)
          <&> first (\e -> "GET " <> url <> ": " <> show e)
    statusOf = statusCode . responseStatus
    describe r = show (statusOf r) <> " " <> T.take 300 (decodeUtf8 (toS (responseBody r)))
    locationOf r = maybe "" decodeUtf8 (lookup hLocation (responseHeaders r))
    onServer url = maybe url (server.public <>) (T.stripPrefix (T.dropEnd 1 rehearsalUrl) url)
    userOf = \case
      Object o -> KeyMap.lookup "user" o
      _ -> Nothing

-- | A cookie a response sets, by name.
cookieOf :: Text -> Response LByteString -> Maybe Text
cookieOf name r =
  listToMaybe
    [ T.drop 1 rest
    | (headerName, raw) <- responseHeaders r
    , headerName == hSetCookie
    , let (key, rest) = T.breakOn "=" (T.takeWhile (/= ';') (decodeUtf8 raw))
    , key == name
    , not (T.null (T.drop 1 rest))
    ]

-- | Sign in with a login and its password as the application does,
-- through a browser of its own (its own cookies). The requests it made, by
-- method and address, or why it did not sign in under that login.
appSignIn :: Manager -> Server -> Text -> Text -> IO (Either Text [(ByteString, Text)])
appSignIn manager server login password = do
  jar <- newIORef (createCookieJar [])
  sent <- newIORef []
  env <- newHttpEnv (httpTransport manager server.public jar sent)
  result <- runHttpWiki env (signIn login (Password password))
  requests <- reverse <$> readIORef sent
  pure $ case result of
    Left e -> Left ("not signed in (" <> show e <> ") after " <> T.intercalate ", " [decodeUtf8 m <> " " <> p | (m, p) <- requests])
    Right session
      | ((\u -> u.login.text) <$> session.user) == Just login -> Right requests
      | otherwise -> Left ("signed in as " <> maybe "nobody" (\u -> u.login.text) session.user)

-- | The application's requests sent over HTTP to a server, with a cookie
-- jar as a browser keeps one. Every request is noted, its method and
-- address, the latest first.
httpTransport :: Manager -> Text -> IORef CookieJar -> IORef [(ByteString, Text)] -> Transport
httpTransport manager base jar sent = Transport $ \r -> do
  modifyIORef' sent ((r.requestMethod, requestUrl r) :)
  answer <- try @SomeException $ do
    request <- parseRequest (toS (base <> "/" <> requestUrl r))
    cookies <- readIORef jar
    response <- httpLbs request {method = r.requestMethod, requestHeaders = requestHeaderList r, requestBody = RequestBodyBS (maybe "" fst r.requestBody), cookieJar = Just cookies, redirectCount = 0} manager
    writeIORef jar (responseCookieJar response)
    pure response
  pure $ case answer of
    Left e -> Left (show e)
    Right response ->
      Right
        Servant.Response
          { Servant.responseStatusCode = responseStatus response
          , Servant.responseHeaders = Seq.fromList (responseHeaders response)
          , Servant.responseHttpVersion = responseVersion response
          , Servant.responseBody = responseBody response
          }

--------------------------------------------------------------------------------
-- The ways in check

-- | The ways in check (WP5.85 of docs/PLAN.md, issue #205): every account
-- that signed in with a password before the upgrade still does after it.
-- The accounts check proves that a password made for the rehearsal signs
-- in; this one looks at the accounts people have, so that a migration
-- that loses their passwords fails the rehearsal.
--
-- Before, the old program's @wiki-server users list@ runs on the copy it
-- serves; after, the new program's on the copy it serves (for a move, the
-- PostgreSQL database). Both read the column SIGNS IN of each login
-- ('readUsersList'). The check fails for each login that read @yes@ before
-- and reads anything else after, naming it, and for nothing else: a login
-- that is new, one that is gone and one that went from no to yes are not
-- failures. Old output that is not that table is an old program the
-- rehearsal cannot drive, not a failed check.
--
-- What the check does not see: SIGNS IN knows of passwords alone. An
-- account that signs in only through a provider or with a passkey reads
-- @no (no password)@ before and after, whatever the upgrade did to it. The
-- canaries of the accounts check cover the provider's sign-in; nothing
-- here covers a passkey's. Nor does the column decode a password:
-- @wiki-server check@, which the rehearsal runs on the migrated copy,
-- refuses a password no sign-in can use ("Wiki.Server.WaysIn").
waysInCheck :: Check
waysInCheck = simpleCheck "ways in" (const listed) (\was _ server -> listed server <&> (>>= compareWaysIn was))
  where
    listed server = server.console ["users", "list"] "" <&> (>>= readUsersList)

-- | The column SIGNS IN of @wiki-server users list@'s output
-- ("Wiki.Server.Console"'s @listing@), by login, or why the output is not
-- that table. The output must say there are no users yet, or be the
-- table: its heading line, whose words are LOGIN, NAME, ADMINISTRATOR and
-- SIGNS IN, then one row after another, each followed by a line break.
--
-- The table is read by the heading's columns, never by what a line ends
-- with. @listing@ pads the login, the name and ADMINISTRATOR each to the
-- width of its column, counted in characters ('T.length'), puts two spaces
-- between columns, and ends the row with SIGNS IN: @yes@, @no (disabled)@
-- or @no (no password)@. The heading gives each column's offset, so a row
-- is read field by field: the login padded to its column's width, two
-- spaces, the name's width of characters, two spaces, @yes@ or @no@ padded
-- to ADMINISTRATOR's width, two spaces, and SIGNS IN up to the line break
-- that ends the row. A display name may hold line breaks: they are
-- characters of the name, counted in its column's width, so the row of
-- such a name spans several lines and is still read whole, with its own
-- SIGNS IN. No text inside a name can end a row early or join two rows,
-- since a name takes exactly its column's width. Anything that does not
-- fit (padding that is not spaces, a missing separator, a value that is
-- none of a column's, the same login twice) is output this function does
-- not know: the rehearsal then says it cannot drive the old program,
-- rather than guess.
readUsersList :: Text -> Either Text (Map Text Text)
readUsersList out = case T.breakOn "\n" (T.dropWhile (== '\n') out) of
  (heading, body)
    | T.null heading -> Left "users list printed nothing"
    | "There are no users yet" `T.isPrefixOf` heading -> Right Map.empty
    | T.words heading == ["LOGIN", "NAME", "ADMINISTRATOR", "SIGNS", "IN"] -> do
        let at word = T.length (fst (T.breakOn word heading))
        listed <- rows (at "NAME" - 2) (at "ADMINISTRATOR" - at "NAME" - 2) (at "SIGNS IN" - at "ADMINISTRATOR" - 2) (T.drop 1 body)
        let logins = map fst listed
        when (length (ordNub logins) /= length logins) (Left "users list printed a login twice")
        pure (Map.fromList listed)
    | otherwise -> Left ("users list did not print its table: its first line is " <> show heading)
  where
    rows loginWidth nameWidth adminWidth = go
      where
        go t
          | T.null t = Right []
          | otherwise = do
              let (loginField, afterLogin) = T.splitAt loginWidth t
                  login = T.dropWhileEnd (== ' ') loginField
              unless (T.length loginField == loginWidth && not (T.null login) && not ("\n" `T.isInfixOf` login)) $
                Left ("users list printed a row that does not start with a login: " <> show (T.take 80 t))
              (_, afterName) <- column login nameWidth =<< separated login afterLogin
              (admin, afterAdmin) <- column login adminWidth =<< separated login afterName
              unless (admin `elem` map (T.justifyLeft adminWidth ' ') ["yes", "no"]) $
                Left ("users list printed a row for " <> login <> " whose ADMINISTRATOR is not yes or no: " <> show admin)
              (status, next) <- T.breakOn "\n" <$> separated login afterAdmin
              unless (status `elem` signsInValues) $
                Left ("users list printed a row for " <> login <> " whose SIGNS IN is none of its values: " <> show status)
              ((login, status) :) <$> go (T.drop 1 next)
    separated login t =
      maybe (Left ("users list printed a row for " <> login <> " without two spaces between its columns")) Right (T.stripPrefix "  " t)
    column login width t =
      let (taken, after) = T.splitAt width t
       in if T.length taken == width then Right (taken, after) else Left ("users list printed a row for " <> login <> " that ends before its columns do")

-- | The values of the column SIGNS IN of @wiki-server users list@.
signsInValues :: [Text]
signsInValues = ["yes", "no (disabled)", "no (no password)"]

-- | Whether every login that signed in before the upgrade (SIGNS IN read
-- @yes@) still does after it. Why not names the first few that do not,
-- with what they read now. A login no longer listed is left out.
compareWaysIn :: Map Text Text -> Map Text Text -> Either Text ()
compareWaysIn was now =
  listProblems
    [ "the login " <> printable login <> " signed in with a password before the upgrade, and after it users list says " <> after
    | (login, "yes") <- Map.toList was
    , Just after <- [Map.lookup login now]
    , after /= "yes"
    ]

--------------------------------------------------------------------------------
-- The logins check

-- | The logins check, step 15 of the schema's
-- ("Wiki.Server.Storage.Migrate.Code.Step0015", WP5.87 of docs/PLAN.md):
-- an account whose login breaks the rule of a login (here one beyond
-- ASCII, @łucja-…@) signs in after the upgrade with the same password,
-- under the login the step gave it.
--
-- The old program's @users add@ has refused such a login since the rule
-- (2026-11-06). So the seed makes the account with an ASCII login and a
-- password through that command, then writes the login @łucja-…@ into
-- the account's row in the copy, through a row type of its own
-- ('CopyUser'). It reads every user's id and login there, and works out
-- the login the step will give with the step's own rule
-- ('renamedLogins'). After the migration the account must sign in with
-- its password under that login, as the application signs in. A copy at
-- step 15 already (an old program that has the step) has nothing to
-- rehearse: the seed makes nothing, and the check passes.
loginsCheck :: Check
loginsCheck =
  Check
    { name = "logins"
    , holding = ($ ())
    , seed = \() -> seedLogins
    , before = \() seeded _ _ -> pure (Right seeded)
    , after = \() seeded manager server -> case seeded of
        Nothing -> pure (Right ())
        Just (login, password) ->
          appSignIn manager server login password <&> bimap (\why -> "the renamed login " <> login <> " did not sign in with its password: " <> why) (const ())
    }

-- | Make the account whose login breaks the rule in the copy, unless the
-- copy is at step 15 already: the login the step will give it, and its
-- password.
seedLogins :: Seeding -> IO (Either Text (Maybe (Text, Text)))
seedLogins seeding = runExceptT $ do
  -- Whether the program rehearsed from has step 15 already: then it has
  -- renamed every login it would.
  done <- liftIO (withDatabase seeding.copy (hasStep step0015.version))
  if done
    then pure Nothing
    else do
      tag <- liftIO (decodeUtf8 . convertToBase @ByteString Base16 <$> (getRandomBytes 8 :: IO ByteString))
      let made = "rehearsal-login-" <> tag
          broken = "łucja-" <> tag
          password = "rehearsal-password-" <> tag
      _ <- ExceptT (seeding.console ["users", "add", made, "--display-name", "Rehearsal login"] (password <> "\n"))
      users <- liftIO $ withDatabase seeding.copy $ \c -> runDb c $ do
        runUpdate (update copyDb.users (\u -> u.login <-. val_ broken) (\u -> u.login ==. val_ made))
        runSelectReturningList (select (all_ copyDb.users))
      user <- maybe (throwError ("the account " <> made <> " that users add made is not in the copy")) pure (find (\u -> u.login == broken) users)
      case find (\r -> r.user == user.id) (renamedLogins [(u.id, u.login) | u <- users]) of
        Nothing -> throwError ("the step would not rename the login " <> broken)
        Just r -> pure (Just (r.now, password))
