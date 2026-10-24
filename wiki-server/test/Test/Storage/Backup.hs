-- | Backups of the database: a copy that opens and holds what the database
-- held, the last few kept, and the attachments' files they refer to kept
-- with them.
module Test.Storage.Backup (spec) where

import Database.SQLite.Simple (withConnection)
import Protolude
import System.Directory (doesFileExist)
import System.FilePath (takeDirectory, takeFileName)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.App.Backend
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Space (..))
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup
import Wiki.Server.Storage.Blobs (blobFile)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir)

spec :: Spec
spec = describe "backup" $ do
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
