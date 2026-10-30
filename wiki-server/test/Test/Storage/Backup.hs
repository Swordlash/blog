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
import Protolude
import System.Directory (copyFile, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing (..))
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
import Wiki.Server.Secret (Secret (..), revealed)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup
import Wiki.Server.Storage.Blobs (blobFile, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir)
import Wiki.Server.Storage.Postgres (PgPrograms (..), checkDump, withDatabaseAlone)
import Wiki.Server.Storage.Sqlite (Access (..), closeSqlite, integrityProblems, openSqlite)

spec :: Backing -> Spec
spec backing = do
  copies backing
  restoring backing
  serversOwn backing

-- | Back up a place's database into its data directory's backups, keeping
-- so many: the new backup, or 'Nothing' when there is no wiki yet.
backup :: Place -> Int -> IO (Maybe FilePath)
backup at keep = backupNow at.programs at.database at.dataDir keep >>= either (panic . ("the backup failed: " <>)) pure

-- | The backup of a place, which must be made.
backupOf :: Place -> IO FilePath
backupOf at = backup at defaultKeep >>= maybe (panic "no backup made") pure

-- | A restore into a place, of a backup.
restoreInto :: Place -> FilePath -> Maybe FilePath -> Restore
restoreInto at file attachments = Restore {backupFile = file, dataDir = at.dataDir, database = at.database, programs = at.programs, attachments}

-- | The name a database's file has in a data directory, and that a
-- restore keeps the database it replaced under.
keptName :: Place -> FilePath
keptName at = case at.database of
  SqliteFile _ -> "wiki.sqlite"
  PostgresAt _ -> "wiki.pgdump"

-- | The ending of a backup's name on a place's database.
extension :: Place -> Text
extension at = case at.database of
  SqliteFile _ -> "sqlite"
  PostgresAt _ -> "pgdump"

-- | What is wrong with a backup's file, by the check of its database.
problemsOf :: Place -> FilePath -> IO [Text]
problemsOf at file = case at.database of
  SqliteFile _ -> integrityProblems file
  PostgresAt _ -> either pure (const []) <$> checkDump at.programs file

copies :: Backing -> Spec
copies backing = describe "backup" $ do
  it "has nothing to back up before there is a wiki" $
    withPlaceIn backing $ \at ->
      backup at defaultKeep `shouldReturn` Nothing

  it "makes a copy that holds the same rows, while the storage is open and has written" $
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= ok
      let admin = Administrator
      blog <- runStoredWiki st admin (getSpace (path "blog")) >>= ok
      page <- runStoredWiki st admin (createPage blog.id Nothing "Kept" "In the backup.") >>= ok
      _ <- runStoredWiki st admin (uploadAttachment page.id "a.txt" "text/plain" "bytes") >>= ok
      _ <- runStoredWiki st admin (saveDraft page.id page.updatedAt "Kept" "A draft") >>= ok
      file <- backupOf at
      takeDirectory file `shouldBe` backupsDir at.dataDir
      live <- tableRows st
      -- The copy, restored into a database of its own, holds the rows.
      copied <- withPlaceIn backing $ \fresh -> do
        _ <- restore (restoreInto fresh file Nothing) >>= either (panic . toS) pure
        withStorageAside fresh tableRows
      copied `shouldBe` live
      map fst live `shouldContain` ["pages"]
      sum (map (length . snd) live) `shouldSatisfy` (> 20)

  it "keeps the last few, the newest" $
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= ok
      made <- replicateM 4 (backup at 2)
      kept <- backupFiles (backupsDir at.dataDir)
      kept `shouldBe` catMaybes (drop 2 made)
      sort (map takeFileName kept) `shouldBe` map takeFileName kept

  it "keeps the files of attachments a backup refers to, and lets the rest go" $
    withPlaceIn backing $ \at -> do
      let upload st name bytes = do
            hello <- runStoredWiki st Administrator (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "hello-world"))) >>= ok
            runStoredWiki st Administrator (uploadAttachment hello.id name "text/plain" bytes) >>= ok
          fileOf a = case a.source of
            SourceBlob b -> maybe (panic "not a hash") pure (blobFile (attachmentsDir at.dataDir) b)
            SourceUrl _ -> panic "an upload is kept as a blob"
      (backedUp, notBackedUp) <- withStorage defaultConfig at $ \st -> do
        importArchive st demoArchive >>= ok
        a <- upload st "backed-up.txt" "in a backup"
        _ <- backup at defaultKeep
        b <- upload st "not-backed-up.txt" "in no backup"
        for_ [a, b] $ \x -> runStoredWiki st Administrator (deleteAttachment x.id) >>= ok
        -- Nothing is deleted while the storage is open.
        for_ [a, b] $ \x -> (fileOf x >>= doesFileExist) `shouldReturn` True
        pure (a, b)
      withStorage defaultConfig at (const pass)
      (fileOf backedUp >>= doesFileExist) `shouldReturn` True
      (fileOf notBackedUp >>= doesFileExist) `shouldReturn` False

-- | A storage with the demo's wiki and two attachments of the blog's first
-- post, one of them deleted since: what a backup and a restore must carry.
withContent :: Backing -> (Place -> Storage -> IO a) -> IO a
withContent backing action = withPlaceIn backing $ \at ->
  withStorage defaultConfig at $ \st -> do
    importArchive st demoArchive >>= ok
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    hello <- runStoredWiki st Administrator (getPage blog.id (path "hello-world")) >>= ok
    _ <- runStoredWiki st Administrator (uploadAttachment hello.id "kept.txt" "text/plain" "kept bytes") >>= ok
    gone <- runStoredWiki st Administrator (uploadAttachment hello.id "gone.txt" "text/plain" "gone bytes") >>= ok
    _ <- runStoredWiki st Administrator (deleteAttachment gone.id) >>= ok
    action at st

restoring :: Backing -> Spec
restoring backing = describe "restore" $ do
  it "puts a backup into a fresh data directory, which then holds what was backed up, attachments and all" $
    withContent backing $ \at st -> do
      file <- backupOf at
      exported <- exportArchive st "test" >>= ok
      rows <- tableRows st
      -- The drill: a copy of the backup and of the attachments elsewhere,
      -- restored into a directory that has never had a wiki.
      withPlaceIn backing $ \fresh -> do
        restore (restoreInto fresh file (Just (attachmentsDir at.dataDir))) >>= \case
          Left why -> expectationFailure (toS why)
          Right said -> T.unlines said `shouldSatisfy` (not . T.isInfixOf "Warning")
        withStorage defaultConfig fresh $ \again -> do
          restored <- exportArchive again "test" >>= ok
          -- All of it but when the export was made.
          let content (a :: Archive) = (a.users, a.groups, a.membership, a.grants, a.spaces, a.pages, a.blobs)
          content restored `shouldBe` content exported
          tableRows again `shouldReturn` rows
        -- Every file the database refers to is there, and those it does
        -- not refer to went when the storage opened.
        stored <- storedBlobs (attachmentsDir fresh.dataDir)
        Set.size stored `shouldBe` 2

  it "refuses a data directory a storage has open, and changes nothing there" $
    withContent backing $ \at st -> do
      file <- backupOf at
      was <- tableRows st
      restore (restoreInto at file Nothing) >>= \case
        Left why -> why `shouldSatisfy` T.isInfixOf "stop it first"
        Right _ -> expectationFailure "restored into a directory a storage has open"
      tableRows st `shouldReturn` was
      doesDirectoryExist (at.dataDir </> "replaced") `shouldReturn` False

  it "keeps the database it replaces, and says which attachments' files are missing" $
    withSystemTempDirectory "wiki-restore-test" $ \dir -> do
      -- A backup of a wiki with an attachment, kept where its own
      -- attachments' files are not.
      file <- withContent backing $ \at _ -> do
        made <- backupOf at
        let copy = dir </> takeFileName made
        copyFile made copy
        whenM (doesFileExist (made <> ".json")) (copyFile (made <> ".json") (copy <> ".json"))
        pure copy
      withPlaceIn backing $ \at -> do
        rows <- withStorage defaultConfig at (\st -> importArchive st demoArchive >>= ok >> tableRows st)
        said <- restore (restoreInto at file Nothing) >>= either (panic . toS) pure
        T.unlines said `shouldSatisfy` T.isInfixOf "Warning: 1 of the attachments' files"
        replaced <- listDirectory (at.dataDir </> "replaced")
        length replaced `shouldBe` 1
        let aside = at.dataDir </> "replaced" </> fromMaybe "" (head replaced)
        kept <- listDirectory aside
        kept `shouldContain` [keptName at]
        -- What was replaced restores as a backup does, which undoes the
        -- restore: a dump has its facts beside it, as a backup has.
        _ <- restore (restoreInto at (aside </> keptName at) Nothing) >>= either (panic . toS) pure
        withStorageAside at tableRows `shouldReturn` rows
        length <$> listDirectory (at.dataDir </> "replaced") `shouldReturn` 2

  case backing of
    OnPostgres _ -> it "refuses a PostgreSQL database that a storage on another data directory has open, and a storage cannot open one being restored" $
      withContent backing $ \at st -> do
        file <- backupOf at
        was <- tableRows st
        withSystemTempDirectory "wiki-restore-test" $ \other -> do
          let elsewhere = Place {dataDir = other, database = at.database, programs = at.programs}
          restore (restoreInto elsewhere file Nothing) >>= \case
            Left why -> why `shouldSatisfy` T.isInfixOf "open in a running server or console"
            Right _ -> expectationFailure "restored a database that a storage has open"
          doesDirectoryExist (other </> "replaced") `shouldReturn` False
        tableRows st `shouldReturn` was
        withPlaceIn backing $ \fresh -> case fresh.database of
          PostgresAt db -> do
            withStorage defaultConfig fresh (const pass)
            opened <- withDatabaseAlone db (try @DataDirInUse (withStorage defaultConfig fresh (const pass)))
            either (\(DataDirInUse why) -> why) (const "opened") <$> opened `shouldBe` Just "The PostgreSQL database is being restored (wiki-server restore holds its lock): start the server once the restore has ended."
          SqliteFile _ -> expectationFailure "a place on SQLite"
    _ -> pass
  case backing of
    -- The test server trusts every connection and ignores the password;
    -- what this checks is that the password, kept apart from the URL,
    -- makes a connection string libpq takes, and reaches pg_dump.
    OnPostgres _ -> it "opens and backs up a PostgreSQL database whose password is kept apart from its URL" $
      withPlaceIn backing $ \plain -> case plain.database of
        PostgresAt db -> do
          let at = Place {dataDir = plain.dataDir, database = PostgresAt PgDatabase {url = db.url, password = Just (Secret "pass + word/&é")}, programs = plain.programs}
          withStorage defaultConfig at $ \st -> importArchive st demoArchive >>= ok
          file <- backupOf at
          problemsOf at file `shouldReturn` []
        SqliteFile _ -> expectationFailure "a place on SQLite"
    _ -> pass

  it "refuses what is not a sound backup of a wiki, and a directory of attachments that is not there" $
    withSystemTempDirectory "wiki-restore-test" $ \dir -> withPlaceIn backing $ \at -> do
      priorRows <- withStorageAside at tableRows
      let refused r = restore r >>= either (const pass) (\_ -> expectationFailure ("restored " <> show r))
      BS.writeFile (dir </> "junk.sqlite") "not a database at all, but long enough to look like a header of one"
      BS.writeFile (dir </> "junk.pgdump") "not a dump at all"
      BS.writeFile (dir </> "junk.pgdump.json") "{\"schema\": 1, \"blobs\": []}"
      refused (restoreInto at (dir </> "junk.sqlite") Nothing)
      refused (restoreInto at (dir </> "junk.pgdump") Nothing)
      refused (restoreInto at (dir </> "none.sqlite") Nothing)
      openSqlite ReadWrite (dir </> "empty.sqlite") >>= closeSqlite
      refused (restoreInto at (dir </> "empty.sqlite") Nothing)
      file <- withContent backing $ \other _ -> do
        made <- backupOf other
        let copy = dir </> takeFileName made
        copyFile made copy
        whenM (doesFileExist (made <> ".json")) (copyFile (made <> ".json") (copy <> ".json"))
        pure copy
      refused (restoreInto at file (Just (dir </> "nowhere")))
      withStorageAside at tableRows `shouldReturn` priorRows

-- | What the server's own backups keep: their settings, checked, with the
-- rclone configuration never given back; a backup checked as it is made;
-- and the old ones pruned by the retention.
serversOwn :: Backing -> Spec
serversOwn backing = describe "the server's own backups" $ do
  it "keep their settings, the rclone configuration kept, replaced and cleared, and never given back" $
    withStorageIn backing $ \_ st -> do
      let admin = runStoredWiki st Administrator
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
    withStorageIn backing $ \at st -> do
      importArchive st demoArchive >>= ok
      let t = UTCTime (fromGregorian 2026 10 25) 0
          dir = backupsDir at.dataDir
      made <- backupInto at.programs at.database dir t >>= either (panic . toS) pure
      fst made `shouldSatisfy` (("20261025T000000.000Z." <> toS (extension at)) `isSuffixOf`)
      problemsOf at (fst made) `shouldReturn` []
      -- A copy that cannot be made leaves nothing behind.
      BS.writeFile (at.dataDir </> "junk") "no database"
      broken <- case at.database of
        SqliteFile _ -> backupInto at.programs (SqliteFile (at.dataDir </> "junk")) dir t
        PostgresAt _ -> backupInto at.programs {dump = "false"} at.database dir t
      broken `shouldSatisfy` isLeft
      map takeFileName <$> backupFiles dir `shouldReturn` ["20261025T000000.000Z." <> toS (extension at)]

  it "prune to the newest of so many days and weeks, never the one just made" $
    withSystemTempDirectory "wiki-prune-test" $ \dir -> do
      createDirectoryIfMissing True dir
      let names = ["20261001T030000.000Z.sqlite", "20261018T030000.000Z.sqlite", "20261024T030000.000Z.sqlite", "20261025T030000.000Z.sqlite", "20261025T090000.000Z.sqlite"]
      for_ names $ \n -> BS.writeFile (dir </> n) ""
      gone <- pruneRetained dir Retention {daily = 2, weekly = 1} (dir </> "20261025T030000.000Z.sqlite")
      map takeFileName gone `shouldBe` ["20261001T030000.000Z.sqlite", "20261018T030000.000Z.sqlite"]
      map takeFileName <$> backupFiles dir `shouldReturn` ["20261024T030000.000Z.sqlite", "20261025T030000.000Z.sqlite", "20261025T090000.000Z.sqlite"]
