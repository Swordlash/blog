-- | The backups the server makes by itself, over HTTP (WP4.9 of
-- docs/PLAN.md): none until an administrator turns them on; then on
-- schedule and on "Back up now", each checked, the old ones pruned to the
-- retention, and copied off the machine to a directory or with rclone,
-- whose configuration is never given back nor logged, and is deleted once
-- used; rclone missing is a failure the panel shows, not a crash. The
-- settings and the last backup last across a restart, and a restore is
-- refused the data directory of a running server.
module Test.Server.Backups (spec) where

import Data.ByteString qualified as BS
import Data.IORef (readIORef)
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getFileSize, getPermissions, listDirectory, setOwnerExecutable, setPermissions)
import System.FilePath (takeExtension, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit (assertFailure)
import Test.Database (Backing)
import Test.Storage.Fixture (withPlaceIn)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), WikiApi (..))
import Wiki.Api.Backups
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (SecretState (..))
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Storage (Database (..), Place (..))
import Wiki.Server.Storage.Backup (Restore (..), backupFiles, restore)
import Wiki.Server.Storage.Postgres (checkDump)
import Wiki.Server.Storage.Sqlite (integrityProblems)
import Wiki.Server.Storage.Blobs (storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir)

spec :: Backing -> Spec
spec backing = describe "the server's backups, over HTTP" $ do
  offAtFirst backing
  onSchedule backing
  byHand backing
  offSite backing
  lasting backing

onAdmin :: Running -> Text -> Text
onAdmin r address = r.admin <> "/admin/" <> address

-- | A file the fake rclone wrote, decoded as UTF-8 whatever the locale
-- says, so that the test does not depend on the locale it runs in.
readText :: FilePath -> IO Text
readText file = decodeUtf8 <$> BS.readFile file

-- | The backups, as the operator reads them.
backupsOf :: (HasCallStack) => Running -> IO Backups
backupsOf r = getUrl r (onAdmin r links.admin.backups) >>= jsonAs 200

-- | Set the backups up as the operator.
setBackups :: (HasCallStack) => Running -> BackupSettingsChange -> IO Backups
setBackups r change = sendJson r "PUT" (onAdmin r links.admin.setBackups) change >>= jsonAs 200

-- | Make one now, as the operator.
backUpNow :: (HasCallStack) => Running -> IO Backups
backUpNow r = send r "POST" (onAdmin r links.admin.backUpNow) [] "" >>= jsonAs 200

-- | The backups once one has been made after the one given (if any) and
-- none is under way: ten seconds at most.
madeAfter :: (HasCallStack) => Running -> Maybe BackupRecord -> IO (Backups, BackupRecord)
madeAfter r previous = go (100 :: Int)
  where
    go 0 = assertFailure "no backup was made in ten seconds"
    go n = do
      b <- backupsOf r
      case b.last of
        Just made | Just made /= previous, not b.running -> pure (b, made)
        _ -> threadDelay 100_000 >> go (n - 1)

-- | Backups on, every six hours, with these to keep and copied there.
everySix :: Retention -> Maybe (DestinationOf (Maybe Text)) -> BackupSettingsChange
everySix keep destination = BackupSettings {enabled = True, schedule = EveryHours 6, keep, destination}

week :: Retention
week = Retention {daily = 7, weekly = 4}

offAtFirst :: Backing -> Spec
offAtFirst backing = describe "a fresh server" $ do
  it "makes no backup until an administrator turns them on, and refuses one by hand meanwhile" $ withDemoRunning backing identity $ \r -> do
    b <- backupsOf r
    (b.available, b.settings.enabled, b.last, b.running, b.next) `shouldBe` (True, False, Nothing, False, Nothing)
    (send r "POST" (onAdmin r links.admin.backUpNow) [] "" >>= jsonAs 400) `shouldReturn` Invalid "Backups are off: turn them on first."
    -- Set up but not turned on: still none.
    _ <- setBackups r (everySix week Nothing) {enabled = False}
    threadDelay 500_000
    backupFiles (backupsDir r.dataDir) `shouldReturn` []
    (backupsOf r >>= \x -> pure x.last) `shouldReturn` Nothing

  it "answers the operator and an administrator, and nobody else" $ withAdminSession backing identity $ \r admin -> do
    (getUrlWith r (r.public <> "/" <> links.admin.backups) [admin] >>= jsonAs 200) >>= \(b :: Backups) -> b.settings.enabled `shouldBe` False
    (getUrl r (r.public <> "/" <> links.admin.backups) >>= jsonAs 403) `shouldReturn` Forbidden
    (sendJson r "PUT" (r.public <> "/" <> links.admin.setBackups) (everySix week Nothing) >>= jsonAs 403) `shouldReturn` Forbidden
    (send r "POST" (r.public <> "/" <> links.admin.backUpNow) [] "" >>= jsonAs 403) `shouldReturn` Forbidden
    backupFiles (backupsDir r.dataDir) `shouldReturn` []

onSchedule :: Backing -> Spec
onSchedule backing = describe "turned on" $ do
  it "makes the first at once, checked, and says when the next is due" $ withDemoRunning backing identity $ \r -> do
    _ <- setBackups r (everySix week Nothing)
    (b, made) <- madeAfter r Nothing
    made.trigger `shouldBe` OnSchedule
    made.failure `shouldBe` Nothing
    made.offSite `shouldBe` Nothing
    file <- maybe (assertFailure "no file named") (pure . (backupsDir r.dataDir </>) . toS) made.file
    case r.place.database of
      SqliteFile _ -> integrityProblems file `shouldReturn` []
      PostgresAt _ -> checkDump r.place.programs file `shouldReturn` Right ()
    (Just <$> getFileSize file) `shouldReturn` made.size
    b.next `shouldBe` Just (addUTCTime (6 * 3600) made.startedAt)
    b.kept `shouldBe` 1
    -- The next is hours away: nothing more is made meanwhile.
    threadDelay 500_000
    length <$> backupFiles (backupsDir r.dataDir) `shouldReturn` 1

  it "is refused settings that cannot be, and keeps the ones it had" $ withDemoRunning backing identity $ \r -> do
    was <- setBackups r (everySix week Nothing) {enabled = False}
    for_ [(everySix week Nothing) {schedule = DailyAt 25 0}, everySix week {daily = 0} Nothing, everySix week (Just (ToDirectory "relative/path"))] $ \bad ->
      sendJson r "PUT" (onAdmin r links.admin.setBackups) bad >>= jsonAs 400 >>= \case
        Invalid _ -> pass
        other -> expectationFailure ("not invalid: " <> show other)
    (backupsOf r >>= \b -> pure b.settings) `shouldReturn` was.settings

byHand :: Backing -> Spec
byHand backing = describe "Back up now" $
  it "makes one by hand, and prunes the old ones to the retention" $
    withDemoRunning backing identity $ \r -> do
      _ <- setBackups r (everySix Retention {daily = 1, weekly = 1} Nothing)
      (_, first') <- madeAfter r Nothing
      -- Backups of other days, as earlier backups (and the deploy's) left.
      let dir = backupsDir r.dataDir
      made <- maybe (assertFailure "no file") (pure . (dir </>) . toS) first'.file
      let extension = takeExtension made
      for_ ["20200106T030000.000Z", "20200107T030000.000Z", "20200108T030000.000Z"] $ \n -> do
        copyFile made (dir </> n <> extension)
        whenM (doesFileExist (made <> ".json")) (copyFile (made <> ".json") (dir </> n <> extension <> ".json"))
      answered <- backUpNow r
      (b, again) <-
        if answered.running then madeAfter r (Just first') else pure (answered, fromMaybe first' answered.last)
      again.trigger `shouldBe` Manual
      again.failure `shouldBe` Nothing
      -- The newest of today, and of this week; nothing of 2020.
      map takeFileName <$> backupFiles dir `shouldReturn` [toS f | Just f <- [again.file]]
      b.kept `shouldBe` 1

offSite :: Backing -> Spec
offSite backing = describe "copied off the machine" $ do
  it "goes to a directory, laid out as a data directory, with the attachments' files" $
    withSystemTempDirectory "wiki-offsite" $ \away -> withDemoRunning backing identity $ \r -> do
      _ <- setBackups r (everySix week (Just (ToDirectory (toS away))))
      (b, made) <- madeAfter r Nothing
      made.offSite `shouldBe` Just OffSite {to = toS away, problem = Nothing}
      b.settings.destination `shouldBe` Just (ToDirectory (toS away))
      name <- maybe (assertFailure "no file") (pure . toS) made.file
      doesFileExist (away </> "backups" </> name) `shouldReturn` True
      ours <- storedBlobs (attachmentsDir r.dataDir)
      ours `shouldSatisfy` (not . null)
      storedBlobs (away </> "attachments") `shouldReturn` ours
      -- And restored from there, the drill the README describes.
      withPlaceIn backing $ \fresh -> do
        restore Restore {backupFile = away </> "backups" </> name, dataDir = fresh.dataDir, database = fresh.database, programs = fresh.programs, attachments = Just (away </> "attachments")} >>= either (assertFailure . toS) (const pass)
        storedBlobs (attachmentsDir fresh.dataDir) `shouldReturn` ours

  it "says so when the directory is not there, and keeps the backup" $ withDemoRunning backing identity $ \r -> do
    _ <- setBackups r (everySix week (Just (ToDirectory "/nonexistent/wiki-backups")))
    (_, made) <- madeAfter r Nothing
    made.failure `shouldBe` Nothing
    ((\o -> o.problem) <$> made.offSite) `shouldSatisfy` maybe False (maybe False (T.isInfixOf "is not there"))
    length <$> backupFiles (backupsDir r.dataDir) `shouldReturn` 1

  it "goes to an rclone remote, with its configuration in a private file deleted after, never given back nor logged" $
    withSystemTempDirectory "wiki-rclone" $ \base -> do
      fake <- fakeRclone base
      withDemoRunning backing (\o -> o {rclone = fake}) $ \r -> do
        let config = "[fake]\ntype = local\nsecret_key = do-not-show-me\n"
        set <- setBackups r (everySix week (Just (ToRclone "fake:wiki" (Just config))))
        set.settings.destination `shouldBe` Just (ToRclone "fake:wiki" Set)
        (_, made) <- madeAfter r Nothing
        made.offSite `shouldBe` Just OffSite {to = "fake:wiki", problem = Nothing}
        name <- maybe (assertFailure "no file") (pure . toS) made.file
        doesFileExist (base </> "remote" </> "wiki" </> "backups" </> name) `shouldReturn` True
        storedBlobs (base </> "remote" </> "wiki" </> "attachments") >>= (`shouldSatisfy` (not . null))
        calls <- readText (base </> "calls")
        calls `shouldSatisfy` T.isInfixOf ("copyto " <> toS (backupsDir r.dataDir </> name) <> " fake:wiki/backups/" <> toS name)
        calls `shouldSatisfy` T.isInfixOf "copy "
        calls `shouldSatisfy` T.isInfixOf "fake:wiki/attachments --ignore-existing"
        -- rclone read the configuration from a file that is gone, in a
        -- directory that is gone.
        readText (base </> "configs") >>= (`shouldSatisfy` T.isInfixOf config)
        used <- T.lines <$> readText (base </> "config-paths")
        used `shouldSatisfy` (not . null)
        for_ used $ \p -> doesFileExist (toS p) `shouldReturn` False
        filter (".rclone-" `isPrefixOf`) <$> listDirectory r.dataDir `shouldReturn` []
        -- Never given back, never logged.
        (getUrl r (onAdmin r links.admin.backups) >>= \reply -> pure (decodeUtf8 (toS reply.body) :: Text)) >>= (`shouldSatisfy` (not . T.isInfixOf "do-not-show-me"))
        readIORef r.logged >>= (`shouldSatisfy` all (not . T.isInfixOf "do-not-show-me"))
        -- Left out of a change, it is kept; cleared, it is gone.
        kept <- setBackups r (everySix week (Just (ToRclone "fake:wiki" Nothing)))
        kept.settings.destination `shouldBe` Just (ToRclone "fake:wiki" Set)
        cleared <- setBackups r (everySix week (Just (ToRclone "fake:wiki" (Just ""))))
        cleared.settings.destination `shouldBe` Just (ToRclone "fake:wiki" NotSet)

  it "says so when rclone is not there, and keeps the backup" $
    withDemoRunning backing (\o -> o {rclone = "/nonexistent/rclone"}) $ \r -> do
      _ <- setBackups r (everySix week (Just (ToRclone "b2:wiki" Nothing)))
      (_, made) <- madeAfter r Nothing
      made.failure `shouldBe` Nothing
      ((\o -> o.problem) <$> made.offSite) `shouldSatisfy` maybe False (maybe False (T.isInfixOf "rclone could not be run"))
      length <$> backupFiles (backupsDir r.dataDir) `shouldReturn` 1

lasting :: Backing -> Spec
lasting backing = describe "across a restart" $ do
  it "keeps the settings and the last backup, and makes none before the next is due" $
    withDemoRestarted backing
      ( \r -> do
          _ <- setBackups r (everySix week Nothing)
          (b, _) <- madeAfter r Nothing
          pure b
      )
      ( \was again -> do
          threadDelay 500_000
          b <- backupsOf again
          (b.settings, b.last, b.kept) `shouldBe` (was.settings, was.last, 1)
      )

  it "refuses to restore into the data directory of a server that is running" $ withDemoRunning backing identity $ \r -> do
    _ <- setBackups r (everySix week Nothing)
    (_, made) <- madeAfter r Nothing
    name <- maybe (assertFailure "no file") (pure . toS) made.file
    restore Restore {backupFile = backupsDir r.dataDir </> name, dataDir = r.dataDir, database = r.place.database, programs = r.place.programs, attachments = Nothing} >>= \case
      Left why -> why `shouldSatisfy` T.isInfixOf "A server is running on"
      Right _ -> expectationFailure "restored under a running server"
    doesDirectoryExist (r.dataDir </> "replaced") `shouldReturn` False

-- | A stand-in for rclone in a directory: it writes each call's arguments
-- to @calls@, the configuration it is given to @configs@ and that file's
-- path to @config-paths@, and copies to @remote\/@ for a remote named
-- @fake:@.
fakeRclone :: FilePath -> IO FilePath
fakeRclone base = do
  let script = base </> "rclone"
  createDirectoryIfMissing True (base </> "remote")
  writeFile script . T.unlines $
    [ "#!/bin/sh"
    , "base='" <> toS base <> "'"
    , "echo \"$@\" >> \"$base/calls\""
    , "if [ \"$1\" = --config ]; then cat \"$2\" >> \"$base/configs\"; echo \"$2\" >> \"$base/config-paths\"; shift 2; fi"
    , "case \"$1\" in"
    , "  copyto) target=\"$base/remote/${3#fake:}\"; mkdir -p \"$(dirname \"$target\")\"; cp \"$2\" \"$target\" ;;"
    , "  copy) target=\"$base/remote/${3#fake:}\"; mkdir -p \"$target\"; cp -R -n \"$2\"/. \"$target\"/ ;;"
    , "  *) echo \"unknown command $1\" >&2; exit 3 ;;"
    , "esac"
    ]
  getPermissions script >>= setPermissions script . setOwnerExecutable True
  pure script
