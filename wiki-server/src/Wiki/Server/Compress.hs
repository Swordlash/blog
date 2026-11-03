-- | Compressed copies of the application's files, written by
-- @wiki-server compress DIR@.
--
-- A gzip copy, @\<file>.gz@, goes beside each file of the directory that is
-- worth compressing, and "Wiki.Server.Static" sends that copy to a browser
-- that accepts gzip. The deploy script runs the command when it deploys
-- without Node (@toolchain\/deploy-local.sh --backend-only@): a machine
-- that cannot install Node still gets compressed files, from the server's
-- own binary. Every other deployment writes brotli copies with
-- @toolchain\/compress.mjs@ instead.
--
-- The files chosen are the ones the deploy gives that script: those with an
-- extension of the page's text and code ('compressedExtensions'), and only
-- over 1 KiB, since a smaller file gains nothing worth a second copy.
-- Already compressed files (TikZJax's @.gz@ files) have none of those
-- extensions, so they are left alone.
module Wiki.Server.Compress
  ( compressDirectory
  , compressible
  , compressedExtensions
  )
where

import Codec.Compression.GZip (CompressParams (..), bestCompression, compressWith, defaultCompressParams)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Protolude
import System.Directory (doesDirectoryExist, doesFileExist, getFileSize, getModificationTime, listDirectory, pathIsSymbolicLink, renameFile)
import System.FilePath (takeExtension, (</>))

-- | The extensions of the files that get a compressed copy, the same as
-- the deploy script's list for @toolchain\/compress.mjs@.
compressedExtensions :: [FilePath]
compressedExtensions = [".wasm", ".js", ".mjs", ".css", ".html", ".svg", ".json"]

-- | Whether a file of this name and size in bytes gets a compressed copy:
-- one of 'compressedExtensions', and larger than 1 KiB (what the deploy
-- script's @find -size +1k@ selects).
compressible :: FilePath -> Integer -> Bool
compressible path size = takeExtension path `elem` compressedExtensions && size > 1024

-- | Write the gzip copies under a directory and its subdirectories, and
-- return how many were written. A file whose copy is newer than the file
-- keeps that copy, so a second run writes nothing. Symbolic links are not
-- followed, as the deploy script's @find -type f@ does not follow them.
compressDirectory :: FilePath -> IO Int
compressDirectory dir = do
  entries <- sort <$> listDirectory dir
  counts <- for entries $ \entry -> do
    let path = dir </> entry
    symbolic <- pathIsSymbolicLink path
    directory <- doesDirectoryExist path
    if symbolic
      then pure 0
      else if directory then compressDirectory path else compressFile path
  pure (sum counts)

-- | Write one file's gzip copy if it gets one and has no newer one; 1 when
-- a copy was written. The copy is written beside it under a temporary
-- name and renamed, so that the server never sends half a copy.
compressFile :: FilePath -> IO Int
compressFile path = do
  size <- getFileSize path
  if not (compressible path size)
    then pure 0
    else do
      let copy = path <> ".gz"
      fresh <- do
        exists <- doesFileExist copy
        if exists
          then (>) <$> getModificationTime copy <*> getModificationTime path
          else pure False
      if fresh
        then pure 0
        else do
          contents <- BS.readFile path
          let params = defaultCompressParams {compressLevel = bestCompression}
          BSL.writeFile (copy <> ".tmp") (compressWith params (BSL.fromStrict contents))
          renameFile (copy <> ".tmp") copy
          pure 1
