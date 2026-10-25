-- | Backups of the database: a copy that opens and holds what the database
-- held, the last few kept, and the attachments' files they refer to kept
-- with them; a backup restored into a fresh data directory, which then
-- holds what the one backed up held (the drill the README describes), and
-- a restore refused while a storage has the directory open; and what the
-- server's own backups keep in the database (WP4.9 of docs/PLAN.md).
module Test.Storage.Backup (spec) where

import Data.ByteString qualified as BS
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Database.SQLite.Simple (withConnection)
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Backups (BackupSettingsOf (..), Backups (..), DestinationOf (..), Retention (..), Schedule (..), defaultBackupSettings)
import Wiki.Api.ServerSettings (SecretState (..))
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Space (..))
import Wiki.Server.Secret (revealed)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup
import Wiki.Server.Storage.Blobs (blobFile, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir, databaseFile)

spec :: Spec
spec = do
  copies
  restoring
  serversOwn

copies :: Spec
copies = describe "backup" $ do
  it "has nothing to back up before there is a database" $
    withSystemTempDirectory "wiki-backup-test" $ \dir ->
      backup dir defaultKeep `shouldReturn` Nothing

  it "makes a copy that opens and holds the same rows, while the storage is open and has written" $
    withStorageIn $ \dir st -> do
      importArchive st demoArchive >>= ok
      let admin = Administrator
      blog <- runSqliteWiki st admin (getSpace (path "blog")) >>= ok
      page <- runSqliteWiki st admin (createPage blog.id Nothing "Kept" "In the backup.") >>= ok
      _ <- runSqliteWiki st admin (uploadAttachment page.id "a.txt" "text/plain" "bytes") >>= ok
      _ <- runSqliteWiki st admin (saveDraft page.id page.updatedAt "Kept" "A draft") >>= ok
      file <- backup dir defaultKeep >>= maybe (expectationFailure "no backup made" >> panic "unreachable") pure
      takeDirectory file `shouldBe` backupsDir dir
      live <- withDatabase st tableRows
      copied <- withConnection file tableRows
      copied `shouldBe` live
      map fst live `shouldContain` ["pages"]
      sum (map (length . snd) live) `shouldSatisfy` (> 20)

  it "keeps the last few, the newest" $
    withStorageIn $ \dir _ -> do
      made <- replicateM 4 (backup dir 2)
      kept <- backupFiles (backupsDir dir)
      kept `shouldBe` catMaybes (drop 2 made)
      sort (map takeFileName kept) `shouldBe` map takeFileName kept

  it "keeps the files of attachments a backup refers to, and lets the rest go" $
    withSystemTempDirectory "wiki-backup-test" $ \dir -> do
      let upload st name bytes = do
            hello <- runSqliteWiki st Administrator (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "hello-world"))) >>= ok
            runSqliteWiki st Administrator (uploadAttachment hello.id name "text/plain" bytes) >>= ok
          fileOf a = case a.source of
            SourceBlob b -> maybe (panic "not a hash") pure (blobFile (attachmentsDir dir) b)
            SourceUrl _ -> panic "an upload is kept as a blob"
      (backedUp, notBackedUp) <- withStorage defaultConfig dir $ \st -> do
        importArchive st demoArchive >>= ok
        a <- upload st "backed-up.txt" "in a backup"
        _ <- backup dir defaultKeep
        b <- upload st "not-backed-up.txt" "in no backup"
        for_ [a, b] $ \x -> runSqliteWiki st Administrator (deleteAttachment x.id) >>= ok
        -- Nothing is deleted while the storage is open.
        for_ [a, b] $ \x -> (fileOf x >>= doesFileExist) `shouldReturn` True
        pure (a, b)
      withStorage defaultConfig dir (const pass)
      (fileOf backedUp >>= doesFileExist) `shouldReturn` True
      (fileOf notBackedUp >>= doesFileExist) `shouldReturn` False

-- | A storage with the demo's wiki and two attachments of the blog's first
-- post, one of them deleted since: what a backup and a restore must carry.
withContent :: (FilePath -> Storage -> IO a) -> IO a
withContent action = withSystemTempDirectory "wiki-restore-test" $ \dir -> do
  let dataDir = dir </> "data"
  withStorage defaultConfig dataDir $ \st -> do
    importArchive st demoArchive >>= ok
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    hello <- runSqliteWiki st Administrator (getPage blog.id (path "hello-world")) >>= ok
    _ <- runSqliteWiki st Administrator (uploadAttachment hello.id "kept.txt" "text/plain" "kept bytes") >>= ok
    gone <- runSqliteWiki st Administrator (uploadAttachment hello.id "gone.txt" "text/plain" "gone bytes") >>= ok
    _ <- runSqliteWiki st Administrator (deleteAttachment gone.id) >>= ok
    action dir st

restoring :: Spec
restoring = describe "restore" $ do
  it "puts a backup into a fresh data directory, which then holds what was backed up, attachments and all" $
    withContent $ \dir st -> do
      let dataDir = storageDataDir st
          fresh = dir </> "fresh"
      file <- backup dataDir defaultKeep >>= maybe (panic "no backup made") pure
      exported <- exportArchive st "test" >>= ok
      rows <- withDatabase st tableRows
      -- The drill: a copy of the backup and of the attachments elsewhere,
      -- restored into a directory that has never had a wiki.
      restore Restore {backupFile = file, dataDir = fresh, attachments = Just (attachmentsDir dataDir)} >>= \case
        Left why -> expectationFailure (toS why)
        Right said -> T.unlines said `shouldSatisfy` (not . T.isInfixOf "Warning")
      withConnection (databaseFile fresh) tableRows `shouldReturn` rows
      withStorage defaultConfig fresh $ \again -> do
        restored <- exportArchive again "test" >>= ok
        -- All of it but when the export was made.
        let content (a :: Archive) = (a.users, a.groups, a.membership, a.grants, a.spaces, a.pages, a.blobs)
        content restored `shouldBe` content exported
        withDatabase again tableRows `shouldReturn` rows
      -- Every file the database refers to is there, and those it does not
      -- refer to went when the storage opened.
      stored <- storedBlobs (attachmentsDir fresh)
      Set.size stored `shouldBe` 2

  it "refuses a data directory a storage has open, and changes nothing there" $
    withContent $ \_ st -> do
      let dataDir = storageDataDir st
      file <- backup dataDir defaultKeep >>= maybe (panic "no backup made") pure
      was <- withDatabase st tableRows
      restore Restore {backupFile = file, dataDir, attachments = Nothing} >>= \case
        Left why -> why `shouldSatisfy` T.isInfixOf "stop it first"
        Right _ -> expectationFailure "restored into a directory a storage has open"
      withDatabase st tableRows `shouldReturn` was
      doesDirectoryExist (dataDir </> "replaced") `shouldReturn` False

  it "keeps the database it replaces, and says which attachments' files are missing" $
    withSystemTempDirectory "wiki-restore-test" $ \dir -> do
      let dataDir = dir </> "data"
          other = dir </> "other"
      -- A backup of a wiki with an attachment, kept where its own
      -- attachments' files are not.
      file <- withContent $ \_ st -> do
        made <- backup (storageDataDir st) defaultKeep >>= maybe (panic "no backup made") pure
        copyFile made (dir </> "copy.sqlite")
        pure (dir </> "copy.sqlite")
      withStorage defaultConfig dataDir (\st -> importArchive st demoArchive) >>= ok
      withStorage defaultConfig other (const pass)
      said <- restore Restore {backupFile = file, dataDir, attachments = Nothing} >>= either (panic . toS) pure
      T.unlines said `shouldSatisfy` T.isInfixOf "Warning: 1 of the attachments' files"
      replaced <- listDirectory (dataDir </> "replaced")
      length replaced `shouldBe` 1
      kept <- listDirectory (dataDir </> "replaced" </> fromMaybe "" (head replaced))
      kept `shouldContain` ["wiki.sqlite"]

  it "refuses what is not a sound backup of a wiki, and a directory of attachments that is not there" $
    withSystemTempDirectory "wiki-restore-test" $ \dir -> do
      let dataDir = dir </> "data"
          refused r = restore r >>= either (const pass) (\_ -> expectationFailure ("restored " <> show r))
      BS.writeFile (dir </> "junk.sqlite") "not a database at all, but long enough to look like a header of one"
      refused Restore {backupFile = dir </> "junk.sqlite", dataDir, attachments = Nothing}
      refused Restore {backupFile = dir </> "none.sqlite", dataDir, attachments = Nothing}
      withConnection (dir </> "empty.sqlite") (const pass)
      refused Restore {backupFile = dir </> "empty.sqlite", dataDir, attachments = Nothing}
      file <- withContent $ \_ st -> backup (storageDataDir st) defaultKeep >>= maybe (panic "no backup made") (\f -> copyFile f (dir </> "good.sqlite") $> (dir </> "good.sqlite"))
      refused Restore {backupFile = file, dataDir, attachments = Just (dir </> "nowhere")}
      doesFileExist (databaseFile dataDir) `shouldReturn` False

-- | What the server's own backups keep: their settings, checked, with the
-- rclone configuration never given back; a backup checked as it is made;
-- and the old ones pruned by the retention.
serversOwn :: Spec
serversOwn = describe "the server's own backups" $ do
  it "keep their settings, the rclone configuration kept, replaced and cleared, and never given back" $
    withStorageIn $ \_ st -> do
      let admin = runSqliteWiki st Administrator
          rclone config = defaultBackupSettings {enabled = True, schedule = EveryHours 6, destination = Just (ToRclone "b2:wiki" config)}
      set <- admin (setBackupSettings (rclone (Just "[b2]\ntype = b2\n"))) >>= ok
      set.settings `shouldBe` rclone Set
      (admin backups >>= ok) `shouldReturn` set
      kept <- readBackupSettings st
      (\case Just (ToRclone _ (Just c)) -> revealed c; _ -> "") kept.destination `shouldBe` "[b2]\ntype = b2\n"
      show set `shouldSatisfy` (not . isInfixOf "type = b2")
      again <- admin (setBackupSettings (rclone Nothing)) >>= ok
      again.settings.destination `shouldBe` Just (ToRclone "b2:wiki" Set)
      cleared <- admin (setBackupSettings (rclone (Just ""))) >>= ok
      cleared.settings.destination `shouldBe` Just (ToRclone "b2:wiki" NotSet)
      admin (setBackupSettings defaultBackupSettings {schedule = EveryHours 0}) >>= either (const pass) (\_ -> expectationFailure "took every 0 hours")
      (admin backups >>= ok) `shouldReturn` cleared

  it "check a backup as it is made, and keep none that fails" $
    withStorageIn $ \dir st -> do
      let t = UTCTime (fromGregorian 2026 10 25) 0
      made <- checkedBackup (copyDatabase st) (backupsDir dir) t >>= either (panic . toS) pure
      fst made `shouldSatisfy` ("20261025T000000.000Z.sqlite" `isSuffixOf`)
      integrityProblems (fst made) `shouldReturn` []
      broken <- checkedBackup (\f -> BS.writeFile f "no database") (backupsDir dir) t
      broken `shouldSatisfy` isLeft
      failed <- checkedBackup (\_ -> throwIO (userError "the disk is full")) (backupsDir dir) t
      failed `shouldSatisfy` isLeft
      map takeFileName <$> backupFiles (backupsDir dir) `shouldReturn` ["20261025T000000.000Z.sqlite"]

  it "prune to the newest of so many days and weeks, never the one just made" $
    withSystemTempDirectory "wiki-prune-test" $ \dir -> do
      createDirectoryIfMissing True dir
      let names = ["20261001T030000.000Z.sqlite", "20261018T030000.000Z.sqlite", "20261024T030000.000Z.sqlite", "20261025T030000.000Z.sqlite", "20261025T090000.000Z.sqlite"]
      for_ names $ \n -> BS.writeFile (dir </> n) ""
      gone <- pruneRetained dir Retention {daily = 2, weekly = 1} (dir </> "20261025T030000.000Z.sqlite")
      map takeFileName gone `shouldBe` ["20261001T030000.000Z.sqlite", "20261018T030000.000Z.sqlite"]
      map takeFileName <$> backupFiles dir `shouldReturn` ["20261024T030000.000Z.sqlite", "20261025T030000.000Z.sqlite", "20261025T090000.000Z.sqlite"]
