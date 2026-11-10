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
-- @serve@ and of the database, @users add@, the admin listener's API
-- (@info@, the spaces, their pages and a page at a path, and the routes
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
-- Both servers listen on loopback addresses, on ports the system gives.
-- They are read through their administration listener, which is served
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
  , checks

    -- * The pages check, for its tests
  , PageRead (..)
  , PagesRead (..)
  , readPages
  , comparePages

    -- * The home pages check, for its tests
  , SpaceRead (..)
  , readSpaces
  , compareHomes
  )
where

import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, defaultDbSettings, delete, insert, insertValues, runDelete, runInsert, val_, (==.))
import Network.HTTP.Client (CookieJar, Manager, Request (..), RequestBody (..), Response, createCookieJar, defaultManagerSettings, httpLbs, managerResponseTimeout, newManager, parseRequest, responseBody, responseCookieJar, responseHeaders, responseStatus, responseTimeoutMicro, responseVersion)
import Network.HTTP.Types (hLocation, hSetCookie, statusCode, urlEncode)
import Network.Socket qualified as N
import Options.Applicative
import Protolude
import Servant.Client.Core qualified as Servant
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, removePathForcibly)
import System.Environment (getExecutablePath)
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, readCreateProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)
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
import Wiki.Server.Storage.Rows (deleteSettingsLike, storeSetting)

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
        let seeding = Seeding {copy = scratchPlace, console = runConsole o.old (["--data", o.scratch] <> databaseArgs scratchChoice)}
        seeded <- for held $ \(Held name seed before after) ->
          liftIO (try (seed seeding)) >>= \case
            Left (e :: SomeException) -> broken ("The check of " <> name <> " could not prepare the copy: " <> show e)
            Right (Left why) -> throwError (OldNotDriven ("The check of " <> name <> " could not prepare the copy with the old program: " <> why))
            Right (Right s) -> pure (Seeded name (before s) after)
        -- The old program on the copy, and what each check keeps of it.
        fixtures <- withServer (o.scratch </> "old.log") o.old (serveArgs scratchChoice []) (throwError . OldNotDriven) $ \server ->
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
      results <- withServer (o.scratch </> "new.log") self (serveArgs servedChoice ["--no-guide"]) (broken . ("The new program did not serve the migrated copy: " <>)) $ \server ->
        for fixtures $ \(name, after) -> (name,) <$> liftIO (after server)
      let lines' = [either (\why -> name <> ": failed: " <> why) (const (name <> ": passed")) r | (name, r) <- results]
      pure (if all (isRight . snd) results then Rehearsed lines' else ChecksFailed lines')
    serveArgs choice extra listen admin =
      ["serve", "--data", o.scratch]
        <> databaseArgs choice
        <> ["--listen", "127.0.0.1:" <> show listen, "--admin-listen", "127.0.0.1:" <> show admin]
        <> extra
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
-- administration listener's API, which answers as an administrator, and
-- the address of its public listener, where people sign in.
data Server = Server
  { adminApi :: Text
  -- ^ @http:\/\/127.0.0.1:\<port>\/admin\/api\/v1@.
  , public :: Text
  -- ^ @http:\/\/127.0.0.1:\<port>@, with no slash at the end.
  }

-- | Run a program's server on two loopback ports the system gives, wait
-- until it answers, run the action, and stop the server however the
-- action ends. What the server writes goes to a log file in the scratch
-- directory, not a pipe: a pipe nobody reads fills up and stops the
-- server. A server that exits, or does not answer within a minute, is
-- reported to @failed@ with the end of its log.
withServer :: FilePath -> FilePath -> (Int -> Int -> [[Char]]) -> (Text -> ExceptT RehearsalOutcome IO a) -> (Server -> ExceptT RehearsalOutcome IO a) -> ExceptT RehearsalOutcome IO a
withServer logFile program args failed act = do
  listen <- liftIO freePort
  admin <- liftIO freePort
  logHandle <- liftIO (openFile logFile WriteMode)
  (_, _, _, process) <- liftIO (createProcess (proc program (args listen admin)) {std_in = NoStream, std_out = UseHandle logHandle, std_err = UseHandle logHandle})
  let server = Server {adminApi = "http://127.0.0.1:" <> show admin <> "/admin/api/v1", public = "http://127.0.0.1:" <> show listen}
      stop = do
        terminateProcess process
        void (timeout 20_000_000 (waitForProcess process))
        hClose logHandle
  ExceptT $
    ( runExceptT $
        liftIO (answers process server) >>= \case
          Left how -> do
            said <- liftIO (T.strip . T.takeEnd 2000 . decodeUtf8 <$> readFile' logFile)
            failed (toS program <> " " <> how <> (if T.null said then "" else ": " <> said))
          Right () -> act server
    )
      `finally` stop
  where
    readFile' f = try @SomeException (BS.readFile f) <&> either (const "") identity

-- | Wait for the server to answer @info@, for a minute; 'Left' says how it
-- failed to.
answers :: ProcessHandle -> Server -> IO (Either Text ())
answers process server = do
  manager <- newManager defaultManagerSettings
  let attempt :: Int -> IO (Either Text ())
      attempt n =
        getProcessExitCode process >>= \case
          Just code -> pure (Left ("exited (" <> show code <> ") before it answered"))
          Nothing -> do
            ok <- either (const False) (const True) <$> getJson manager (server.adminApi <> "/info")
            if
              | ok -> pure (Right ())
              | n <= 0 -> pure (Left "did not answer within a minute")
              | otherwise -> threadDelay 250_000 >> attempt (n - 1)
  attempt 240

-- | A port on the loopback address that nothing listens on now.
freePort :: IO Int
freePort =
  bracket (N.socket N.AF_INET N.Stream N.defaultProtocol) N.close $ \s -> do
    N.bind s (N.SockAddrInet 0 (N.tupleToHostAddress (127, 0, 0, 1)))
    N.socketPort s <&> fromIntegral

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
-- copy's place options, with the text on standard input.
runConsole :: FilePath -> [[Char]] -> [Text] -> Text -> IO (Either Text Text)
runConsole program placeArgs args input =
  try (readCreateProcessWithExitCode (proc program (map toS args <> placeArgs)) (toS input)) <&> \case
    Left (e :: SomeException) -> Left (show e)
    Right (ExitSuccess, out, _) -> Right (toS out)
    Right (ExitFailure code, out, err) -> Left (T.unwords (map toS args) <> " exited with " <> show code <> ": " <> T.strip (toS err <> toS out))

-- | Every check, in the order they run.
checks :: [Check]
checks = [pagesCheck, accountsCheck, homesCheck]

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
-- administration API, with each space's home page. A space whose pages
-- answer 404 is left out: the list of spaces names some that nobody may
-- read, administrators included (the container of personal spaces, and a
-- personal space its owner hid; "Wiki.Core.Permission"). So is a space
-- whose pages answer 409: an encrypted space, whose pages the server keeps
-- only as ciphertext and does not list as plain text. A space read before
-- the migration and not after still shows: its pages are then gone.
readPages :: Manager -> Server -> IO (Either Text PagesRead)
readPages manager server = runExceptT $ do
  spaces <- ExceptT (getJson manager (server.adminApi <> "/spaces")) >>= asList "the spaces"
  let byId = Map.fromList [(i, s) | s <- spaces, Just i <- [field "id" s]]
      inGuide s = case (field "parent" s, field "slug" s) of
        (Nothing, Just slug) -> slug == slugText guideSlug
        (Just p, _) -> maybe False inGuide (Map.lookup p byId)
        _ -> False
  read' <- for [(i, s) | (i, s) <- Map.toList byId, not (inGuide s)] $ \(i, s) ->
    fmap (\ps -> (i, field "homePage" s, ps)) <$> pagesOf i
  pure PagesRead {pages = concat [ps | Just (_, _, ps) <- read'], homes = Map.fromList [(i, h) | Just (i, h, _) <- read']}
  where
    pagesOf spaceId =
      ExceptT (getJsonUnless [404, 409] manager (server.adminApi <> "/spaces/" <> spaceId <> "/pages")) >>= \case
        Nothing -> pure Nothing
        Just listed -> Just <$> (asList ("the pages of space " <> spaceId) listed >>= pagesIn spaceId)
    pagesIn spaceId summaries = do
      let byId = Map.fromList [(i, p) | p <- summaries, Just i <- [field "id" p]]
          pathOf p = maybe [] pathOf (field "parent" p >>= (`Map.lookup` byId)) <> toList (field "slug" p)
      for (Map.toList byId) $ \(i, p) -> do
        let url = server.adminApi <> "/spaces/" <> spaceId <> "/pages/at/" <> T.intercalate "/" (map segment (pathOf p))
        read' <- ExceptT (getJson manager url)
        case (,) <$> field "title" read' <*> field "body" read' of
          Just (title, body) -> pure PageRead {space = spaceId, page = i, title, body}
          Nothing -> throwError ("GET " <> url <> " gave no title and source")
    segment = decodeUtf8 . urlEncode False . encodeUtf8
    asList what = \case
      Array xs -> pure (toList xs)
      _ -> throwError (what <> " are not a list")

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
        moved <- ExceptT (appSignIn manager server canary <&> first ("the password's first sign-in: " <>))
        again <- ExceptT (appSignIn manager server canary <&> first ("the password's second sign-in: " <>))
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

-- | The tables of the copy the checks write, at the old program's schema.
newtype CopyDb f = CopyDb
  { sign_in_providers :: f (TableEntity CopyProvider)
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

-- | Sign in with the canary's password as the application does, through a
-- browser of its own (its own cookies). The requests it made, by method
-- and address, or why it did not sign in as the canary.
appSignIn :: Manager -> Server -> Canary -> IO (Either Text [(ByteString, Text)])
appSignIn manager server canary = do
  jar <- newIORef (createCookieJar [])
  sent <- newIORef []
  env <- newHttpEnv (httpTransport manager server.public jar sent)
  result <- runHttpWiki env (signIn canary.login (Password canary.password))
  requests <- reverse <$> readIORef sent
  pure $ case result of
    Left e -> Left ("not signed in (" <> show e <> ") after " <> T.intercalate ", " [decodeUtf8 m <> " " <> p | (m, p) <- requests])
    Right session
      | ((\u -> u.login.text) <$> session.user) == Just canary.login -> Right requests
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
