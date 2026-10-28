-- | The blob store: attachments' bytes on disk, each file named by the
-- SHA-256 of its contents.
--
-- With a content hash as its name, a file is written once and never
-- changed. Two attachments with the same bytes (an image attached to two
-- pages, an upload made again) share one file, and a file that exists is
-- the right one, so writing it again is skipped. A blob is stored at
-- @\<dir\>/\<first two hex digits\>/\<the 64 hex digits\>@, so that no
-- directory holds every file. A file is written under a temporary name
-- (@incoming…@), in its shard or, while its hash is still being worked out,
-- in the directory itself, and then renamed.
--
-- Files are never deleted while the wiki runs, because the database is
-- backed up without them: a backup taken before an attachment was deleted
-- still refers to its file, and restoring it must find the file there. So
-- 'collectBlobs', which deletes the files nothing refers to, is given what
-- the database and every kept backup refer to, and runs when the storage
-- is opened, before anything else can write.
module Wiki.Server.Storage.Blobs
  ( blobOf
  , storeBlob
  , storeBlobFile
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
import System.IO (hClose, openBinaryTempFile, withBinaryFile)
import Wiki.Core.Id (BlobId (..))

-- | The blob id of some bytes: their SHA-256, in lowercase hex.
blobOf :: ByteString -> BlobId
blobOf = BlobId . decodeUtf8 . BSL.toStrict . toLazyByteString . byteStringHex . SHA256.hash

-- | Where a blob's file is in a directory of blobs; 'Nothing' for an id
-- that is not a hash, which names no file (and so cannot name one outside
-- the directory either).
blobFile :: FilePath -> BlobId -> Maybe FilePath
blobFile dir (BlobId h)
  | T.length h == 64 && T.all isHexDigit h && T.toLower h == h = Just (dir </> T.unpack (T.take 2 h) </> T.unpack h)
  | otherwise = Nothing

-- | Store these bytes, unless they are stored already. The result is
-- their blob id. The file is written next to its final place and then
-- moved there in one step, so that a file under a hash always holds all
-- of it.
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

-- | Store the bytes of a file, unless they are stored already: an upload
-- the server received into a temporary file. The result is their blob id
-- and their size. The file is read once, in chunks: each chunk is hashed
-- and written to a temporary file in the blob directory, which is then
-- renamed to its hash. So a file of any size costs one chunk of memory.
-- The file given is left as it is.
storeBlobFile :: FilePath -> FilePath -> IO (BlobId, Integer)
storeBlobFile dir source = do
  createDirectoryIfMissing True dir
  (temporary, out) <- openBinaryTempFile dir "incoming"
  let copy = withBinaryFile source ReadMode $ \input ->
        -- The hash and the count are forced at each chunk, or they would
        -- hold every chunk until the end.
        let loop !context !n = do
              chunk <- BS.hGetSome input chunkSize
              if BS.null chunk
                then pure (SHA256.finalize context, n)
                else BS.hPut out chunk >> loop (SHA256.update context chunk) (n + fromIntegral (BS.length chunk))
         in loop SHA256.init 0
  (digest, size) <- (copy <* hClose out) `onException` (hClose out >> removeFile temporary)
  let blob = BlobId (decodeUtf8 (BSL.toStrict (toLazyByteString (byteStringHex digest))))
  case blobFile dir blob of
    Nothing -> removeFile temporary >> panic "a SHA-256 in hex is a blob id"
    Just file ->
      ifM
        (doesFileExist file)
        (removeFile temporary)
        (createDirectoryIfMissing True (dir </> T.unpack (T.take 2 blob.text)) >> renameFile temporary file)
  pure (blob, size)
  where
    chunkSize = 64 * 1024

-- | A blob's bytes, if they are stored.
readBlob :: FilePath -> BlobId -> IO (Maybe ByteString)
readBlob dir blob = case blobFile dir blob of
  Nothing -> pure Nothing
  Just file -> ifM (doesFileExist file) (Just <$> BS.readFile file) (pure Nothing)

-- | Every blob that has a file.
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

-- | Delete the files of every blob not among these, and what an
-- unfinished write left behind. The result is the blobs deleted.
collectBlobs :: FilePath -> Set BlobId -> IO [BlobId]
collectBlobs dir keep = do
  stored <- storedBlobs dir
  let gone = Set.toList (stored `Set.difference` keep)
  for_ gone $ \blob -> traverse_ removeFile (blobFile dir blob)
  -- Files of a write that was interrupted: nothing is writing now. They
  -- are in a shard, or in the directory itself for a file whose hash was
  -- not known yet ('storeBlobFile').
  whenM (doesDirectoryExist dir) $ do
    shards <- filterM (doesDirectoryExist . (dir </>)) =<< listDirectory dir
    for_ ("" : shards) $ \s -> do
      leftovers <- filter ("incoming" `isPrefixOf`) <$> listDirectory (dir </> s)
      traverse_ (removeFile . ((dir </> s) </>)) leftovers
  pure gone
