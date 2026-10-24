-- | Attachments' bytes on disk, each file named by the SHA-256 of what is in
-- it.
--
-- Under a content hash, a file is written once and never changed: two
-- attachments of the same bytes (an image attached to two pages, an upload
-- made again) share one file, and a file that is there is the right one, so
-- writing it again is skipped. A blob is @\<dir\>/\<first two hex
-- digits\>/\<the 64 hex digits\>@, so that no directory holds every file.
--
-- Files are never deleted while the wiki runs, because the database is
-- backed up without them: a backup taken before an attachment was deleted
-- still names its file, and restoring it must find the file there. So
-- 'collectBlobs', which deletes the files nothing refers to, is given what
-- the database and every backup kept refer to, and runs when the storage is
-- opened, before anything else can write.
module Wiki.Server.Storage.Blobs
  ( blobOf
  , storeBlob
  , blobFile
  , readBlob
  , storedBlobs
  , collectBlobs
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as BS
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, removeFile, renameFile)
import System.FilePath ((</>))
import System.IO (hClose, openBinaryTempFile)
import Wiki.Core.Id (BlobId (..))

-- | The blob some bytes are: their SHA-256, in lowercase hex.
blobOf :: ByteString -> BlobId
blobOf = BlobId . decodeUtf8 . BSL.toStrict . toLazyByteString . byteStringHex . SHA256.hash

-- | Where a blob's file is in a directory of blobs; 'Nothing' for an id
-- that is not a hash, which names no file (and so cannot name one outside
-- the directory either).
blobFile :: FilePath -> BlobId -> Maybe FilePath
blobFile dir (BlobId h)
  | T.length h == 64 && T.all isHexDigit h && T.toLower h == h = Just (dir </> T.unpack (T.take 2 h) </> T.unpack h)
  | otherwise = Nothing

-- | Keep these bytes, unless they are kept already, and say which blob they
-- are. The file is written beside its place and moved there whole, so that
-- a file under a hash always holds every byte of it.
storeBlob :: FilePath -> ByteString -> IO BlobId
storeBlob dir bytes = do
  let blob = blobOf bytes
  for_ (blobFile dir blob) $ \file -> unlessM (doesFileExist file) $ do
    let shard = dir </> T.unpack (T.take 2 blob.text)
    createDirectoryIfMissing True shard
    (temporary, h) <- openBinaryTempFile shard "incoming"
    (BS.hPut h bytes >> hClose h) `onException` (hClose h >> removeFile temporary)
    renameFile temporary file
  pure blob

-- | A blob's bytes, if they are kept.
readBlob :: FilePath -> BlobId -> IO (Maybe ByteString)
readBlob dir blob = case blobFile dir blob of
  Nothing -> pure Nothing
  Just file -> ifM (doesFileExist file) (Just <$> BS.readFile file) (pure Nothing)

-- | Every blob there is a file of.
storedBlobs :: FilePath -> IO (Set BlobId)
storedBlobs dir =
  ifM
    (doesDirectoryExist dir)
    ( do
        shards <- filterM (doesDirectoryExist . (dir </>)) =<< listDirectory dir
        files <- concat <$> traverse (\s -> map (s,) <$> listDirectory (dir </> s)) shards
        pure (Set.fromList [blob | (_, f) <- files, let blob = BlobId (T.pack f), isJust (blobFile dir blob)])
    )
    (pure mempty)

-- | Delete the files of every blob not among these, and what a write that
-- never finished left behind; what is given back is the blobs deleted.
collectBlobs :: FilePath -> Set BlobId -> IO [BlobId]
collectBlobs dir keep = do
  stored <- storedBlobs dir
  let gone = Set.toList (stored `Set.difference` keep)
  for_ gone $ \blob -> traverse_ removeFile (blobFile dir blob)
  -- Files a write was interrupted in the middle of: nothing is writing now.
  whenM (doesDirectoryExist dir) $ do
    shards <- filterM (doesDirectoryExist . (dir </>)) =<< listDirectory dir
    for_ shards $ \s -> do
      leftovers <- filter ("incoming" `isPrefixOf`) <$> listDirectory (dir </> s)
      traverse_ (removeFile . ((dir </> s) </>)) leftovers
  pure gone
