-- | The server's memory with large attachments (WP5.16c of docs/PLAN.md,
-- finding 10 of docs/scalability-audit.md): an export of a wiki with 100
-- MiB of attachments, and an upload of 50 MB, each keep the live heap under
-- 'bound', and the export imports back as the same wiki.
--
-- A test suite of its own, because the live heap is measured for the whole
-- process ('getRTSStats', with @+RTS -T@): the largest live heap any major
-- collection found since the program started. In the server's test suite
-- every other test would count too. The bound is far below what the export
-- held before it was streamed (every attachment's bytes, then the zip file
-- of all of them) and below the 50 MB of the upload.
module Main (main) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import GHC.Stats (RTSStats (..), getRTSStats)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Mem (performMajorGC)
import Test.HUnit (assertFailure)
import Test.Hspec
import Text.Printf (printf)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Space (..))
import Wiki.Server.Import (readUploadFile)
import Wiki.Server.Storage (Storage, Who (..), defaultConfig, exportArchive, importArchive, inDataDir, runStoredWiki, uploadAttachmentFile, withStorage, writeExport)

-- | The most the live heap may reach: 30 MiB.
bound :: Int
bound = 30 * 1024 * 1024

main :: IO ()
main = hspec . describe "the server's memory with large attachments" $
  it "stays under the bound for an export of 100 MiB of attachments and an upload of 50 MB, and the export imports back as the same wiki" $
    withSystemTempDirectory "wiki-memory" $ \dir ->
      withStorage defaultConfig (inDataDir (dir </> "wiki")) $ \st -> do
        page <- newPage st "Attachments"
        for_ [1 .. 100 :: Int] $ \i -> do
          randomFile (dir </> "upload") (1024 * 1024)
          void (runStoredWiki st Administrator (uploadAttachmentFile page.id ("file-" <> show i <> ".bin") "application/octet-stream" (dir </> "upload")) >>= ok)
        settled <- liveMax
        at <- writeExport st "wiki-server-memory-test" (dir </> "wiki.zip") >>= ok
        exported <- liveMax
        withStorage defaultConfig (inDataDir (dir </> "other")) $ \other -> do
          target <- newPage other "Upload"
          randomFile (dir </> "big") 50_000_000
          uploaded <- runStoredWiki other Administrator (uploadAttachmentFile target.id "big.bin" "application/octet-stream" (dir </> "big")) >>= ok
          uploaded.size `shouldBe` 50_000_000
        afterUpload <- liveMax
        printf "largest live heap: %d KiB after making the wiki, %d KiB after its export, %d KiB after an upload of 50 MB (bound %d KiB)\n" (kib settled) (kib exported) (kib afterUpload) (kib bound)
        afterUpload `shouldSatisfy` (< bound)
        -- The archive, read from disk, makes the same wiki in another
        -- storage.
        archive <- readUploadFile (dir </> "wiki.zip") >>= ok
        archive.createdAt `shouldBe` at
        withStorage defaultConfig (inDataDir (dir </> "imported")) $ \fresh -> do
          importArchive fresh archive >>= ok
          original <- exportArchive st "test" >>= ok
          again <- exportArchive fresh "test" >>= ok
          wiki again `shouldBe` wiki original
          Map.size again.blobs `shouldBe` 100
  where
    wiki a = (a.users, a.groups, a.grants, a.spaces, a.pages, a.blobs)
    kib n = n `div` 1024

-- | A space with one page.
newPage :: Storage -> Text -> IO Page
newPage st title = do
  space <- runStoredWiki st Administrator (createSpace Nothing title) >>= ok
  runStoredWiki st Administrator (createPage space.id Nothing title "") >>= ok

-- | Write a file of this many random bytes, 1 MiB at a time.
randomFile :: FilePath -> Int -> IO ()
randomFile file size =
  withFile "/dev/urandom" ReadMode $ \random -> withFile file WriteMode $ \out ->
    let loop left = when (left > 0) $ do
          BS.hGet random (min left (1024 * 1024)) >>= BS.hPut out
          loop (left - 1024 * 1024)
     in loop size

-- | The largest live heap a major collection has found so far, after one
-- more.
liveMax :: IO Int
liveMax = do
  performMajorGC
  fromIntegral . (\s -> s.max_live_bytes) <$> getRTSStats

ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure
