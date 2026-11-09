{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiWayIf #-}

-- | 'Wiki.Server.Rehearsal' is the upgrade's rehearsal (WP5.75 of
-- docs/PLAN.md, issue #205): @wiki-server rehearse@, which a deploy runs
-- with the new program before it touches the running wiki.
--
-- The rehearsal proves that what exists still works after the upgrade. It
-- copies the running wiki's database into a scratch place, as a backup
-- does ('backupInto': @VACUUM INTO@ on SQLite, @pg_dump@ on PostgreSQL),
-- while the wiki keeps running. The old program serves the copy, and each
-- check's 'before' half reads it, or makes something in it, and keeps a
-- fixture. Then this program migrates the copy, checks every row, serves
-- it, and each check's 'after' half compares what it finds with the
-- fixture. A deploy that sees a check fail stops before the running wiki
-- is touched.
--
-- Both halves of a check live in this program, the new one. The old
-- program is only driven: through what it had already, the API it serves
-- and its console. A check written for a later upgrade can use only what
-- the program deployed before it understands, which is why 'OldNotDriven'
-- is an outcome of its own: an old program that does not take the options
-- the rehearsal starts it with is not a failed check.
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
  , Server (..)
  , checks

    -- * The pages check, for its tests
  , PageRead (..)
  , readPages
  , comparePages
  )
where

import Data.Aeson (Value (..), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.HTTP.Client (Manager, defaultManagerSettings, httpLbs, newManager, parseRequest, responseBody, responseStatus)
import Network.HTTP.Types (statusCode, urlEncode)
import Network.Socket qualified as N
import Options.Applicative
import Protolude
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, listDirectory, removePathForcibly)
import System.Environment (getExecutablePath)
import System.IO (hClose)
import System.Posix.Files (setFileMode)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, getProcessExitCode, proc, terminateProcess, waitForProcess)
import System.Timeout (timeout)
import Wiki.App.Guide (guideSlug)
import Wiki.Core.Slug (slugText)
import Wiki.Server.Console (CheckOutcome (..), MigrateOutcome (..), runCheck, runMigrate)
import Wiki.Server.Options (DatabaseChoice (..), PlaceOptions (..), placeOptions, resolvePlace)
import Wiki.Server.Storage (Place (..), withDatabase)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Backup (Restore (..), backupInto, restore)
import Wiki.Server.Storage.Layout (PgPrograms (..))
import Wiki.Server.Storage.Rows (deleteSettingsLike)

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
      manager <- liftIO (newManager defaultManagerSettings)
      -- The old program on the copy, and what each check keeps of it.
      fixtures <- withServer (o.scratch </> "old.log") o.old (serveArgs scratchChoice []) (throwError . OldNotDriven) $ \server ->
        for checks $ \(Check name before after) ->
          liftIO (before manager server) >>= \case
            Left why -> throwError (OldNotDriven ("The check of " <> name <> " could not read the old program's wiki: " <> why))
            Right f -> pure (name, \s -> after manager f s)
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
      -- This program on the migrated copy, and each check's verdict.
      self <- liftIO getExecutablePath
      results <- withServer (o.scratch </> "new.log") self (serveArgs scratchChoice ["--no-guide"]) (broken . ("The new program did not serve the migrated copy: " <>)) $ \server ->
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
-- administration listener's API, which answers as an administrator.
newtype Server = Server {adminApi :: Text}

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
  let server = Server {adminApi = "http://127.0.0.1:" <> show admin <> "/admin/api/v1"}
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

-- | 'Check' is one thing an upgrade must keep working: a name, a 'before'
-- half that reads the old program's wiki and keeps a fixture (or says why
-- it could not), and an 'after' half that reads the new program's wiki and
-- compares it with the fixture. A feature that changes how existing data
-- is read or used adds a check here, written against what the program
-- deployed before it serves.
data Check = forall fixture. Check
  { name :: Text
  , before :: Manager -> Server -> IO (Either Text fixture)
  , after :: Manager -> fixture -> Server -> IO (Either Text ())
  }

-- | Every check, in the order they run.
checks :: [Check]
checks = [pagesCheck]

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

-- | The pages check: every page of every space reads the same after the
-- migration, its title and its source. The guide's space is left out: its
-- pages are the program's own, and change with its version.
pagesCheck :: Check
pagesCheck =
  Check
    { name = "pages"
    , before = readPages
    , after = \manager was server -> readPages manager server <&> (>>= comparePages was)
    }

-- | Every page of every space but the guide's, read through a server's
-- administration API.
readPages :: Manager -> Server -> IO (Either Text [PageRead])
readPages manager server = runExceptT $ do
  spaces <- ExceptT (getJson manager (server.adminApi <> "/spaces")) >>= asList "the spaces"
  let byId = Map.fromList [(i, s) | s <- spaces, Just i <- [field "id" s]]
      inGuide s = case (field "parent" s, field "slug" s) of
        (Nothing, Just slug) -> slug == slugText guideSlug
        (Just p, _) -> maybe False inGuide (Map.lookup p byId)
        _ -> False
  concat <$> for [(i, s) | (i, s) <- Map.toList byId, not (inGuide s)] (\(i, _) -> pagesOf i)
  where
    pagesOf spaceId = do
      summaries <- ExceptT (getJson manager (server.adminApi <> "/spaces/" <> spaceId <> "/pages")) >>= asList ("the pages of space " <> spaceId)
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

-- | A text field of a JSON object.
field :: Text -> Value -> Maybe Text
field k = \case
  Object o -> case KeyMap.lookup (Key.fromText k) o of
    Just (String t) -> Just t
    _ -> Nothing
  _ -> Nothing

-- | Whether the pages read after the migration are those read before:
-- each page by its id, with its title and source. Why not names the first
-- few differences.
comparePages :: [PageRead] -> [PageRead] -> Either Text ()
comparePages was now
  | null problems = Right ()
  | otherwise = Left (T.intercalate "; " (take 5 problems) <> (if length problems > 5 then "; and " <> show (length problems - 5) <> " more" else ""))
  where
    key p = (p.space, p.page)
    before' = Map.fromList [(key p, p) | p <- was]
    after' = Map.fromList [(key p, p) | p <- now]
    problems =
      ["page " <> p.page <> " (" <> p.title <> ") is gone" | (k, p) <- Map.toList before', not (Map.member k after')]
        <> [ "page " <> p.page <> " (" <> p.title <> ") " <> what
           | (k, p) <- Map.toList before'
           , Just q <- [Map.lookup k after']
           , what <- ["has another title: " <> q.title | q.title /= p.title] <> ["has another source" | q.body /= p.body]
           ]
        <> ["page " <> q.page <> " (" <> q.title <> ") is new" | (k, q) <- Map.toList after', not (Map.member k before')]
