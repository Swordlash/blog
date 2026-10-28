-- | Zip archives, natively: an archive's files written as a zip file and
-- read back, through @zip-archive@. The server and the native tests use it.
--
-- 'writeZipFile' writes the same zip file as 'zipFiles' does, byte for
-- byte, but into a file on disk and one entry at a time, so that a zip
-- file of a whole wiki does not have to fit in memory: the server's export
-- copies each attachment from its blob's file into the zip file.
-- 'unzipFile' reads a zip file from disk. It still holds every file of the
-- archive in memory, which an import needs anyway.
--
-- The browser writes and reads the same zip files with fflate (see
-- @web/src/archive.js@). @zip-archive@ needs the C library zlib through
-- @digest@, which the WebAssembly toolchain does not have, so this module
-- is built natively only.
module Wiki.Core.Export.Zip
  ( zipFiles
  , unzipFiles

    -- * On disk
  , ZipSource (..)
  , writeZipFile
  , ZipTooLarge (..)
  , unzipFile
  )
where

import Codec.Archive.Zip (Entry (..), addEntryToArchive, emptyArchive, fromArchive, fromEntry, toArchiveOrFail, toEntry, zEntries)
import Codec.Compression.Zlib.Internal (DecompressError)
import Codec.Compression.Zlib.Raw qualified as Raw
import Data.ByteString qualified as BS
import Data.ByteString.Builder (byteString, hPutBuilder, word16LE, word32LE)
import Data.ByteString.Lazy qualified as BSL
import Data.Digest.CRC32 (crc32Update)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, toGregorian)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.Time.LocalTime (TimeOfDay (..), timeToTimeOfDay)
import Protolude
import System.FilePath (splitDirectories, takeDirectory, takeFileName)
import System.IO (SeekMode (..), hSeek, hSetFileSize, hTell, withBinaryFile)

-- | A zip file of these files, by path, each dated at the given time.
zipFiles :: UTCTime -> [(Text, ByteString)] -> ByteString
zipFiles time files =
  BSL.toStrict . fromArchive $
    foldl' (\archive (path, bytes) -> addEntryToArchive (toEntry (T.unpack path) seconds (BSL.fromStrict bytes)) archive) emptyArchive (reverse files)
  where
    seconds = floor (utcTimeToPOSIXSeconds time)

-- | The files in a zip file, by path, without the entries for directories;
-- or why the zip file cannot be read.
unzipFiles :: ByteString -> Either Text (Map Text ByteString)
unzipFiles = unzipLazy . BSL.fromStrict

-- | The files in the zip file at this path, as 'unzipFiles' gives them.
-- The file is read as the zip file is parsed, rather than into one string
-- first; every file in it is still held in memory at the end.
unzipFile :: FilePath -> IO (Either Text (Map Text ByteString))
unzipFile path =
  handle (\(e :: DecompressError) -> pure (Left ("a file in it does not decompress: " <> show e))) $
    withBinaryFile path ReadMode $ \h -> do
      parsed <- unzipLazy <$> BSL.hGetContents h
      -- Everything is read before the file is closed: the map is strict,
      -- so building it decompresses every file.
      evaluate parsed >>= either (fmap Left . evaluate) (fmap Right . evaluate)

unzipLazy :: LByteString -> Either Text (Map Text ByteString)
unzipLazy bytes = do
  archive <- first toS (toArchiveOrFail bytes)
  pure $
    Map.fromList
      [ (T.pack (eRelativePath entry), BSL.toStrict (fromEntry entry))
      | entry <- zEntries archive
      , not ("/" `isSuffixOf` eRelativePath entry)
      ]

-- | 'ZipSource' is where 'writeZipFile' gets a file's bytes: from memory,
-- or from a file on disk, which is read in chunks and never held whole.
data ZipSource
  = ZipBytes ByteString
  | ZipFile FilePath

-- | 'ZipTooLarge' is thrown by 'writeZipFile' for a zip file this format
-- cannot describe: one with a file of 4 GiB or more, one of 4 GiB or more
-- in all, or one of 65,535 files or more. Those need the ZIP64 extension,
-- which neither @zip-archive@ nor fflate reads.
newtype ZipTooLarge = ZipTooLarge Text
  deriving stock (Show)

instance Exception ZipTooLarge

-- | Write a zip file of these files, by path, each dated at the given
-- time, at this path, replacing what is there. The files are written one
-- at a time, in order, and the list is consumed as they are, so memory
-- holds one 'ZipBytes' at a time and no 'ZipFile' whole. The result is
-- what 'zipFiles' makes of the same files, byte for byte: each file is
-- compressed with deflate, unless that makes it no smaller, in which case
-- it is stored as it is. It throws 'ZipTooLarge' when the files need
-- ZIP64.
--
-- An entry's header comes before its data and holds the data's checksum
-- and size, which are known only once the data is written. So the header
-- is written with zeros first, and filled in afterwards: the file is
-- written in place, not streamed to a socket.
writeZipFile :: FilePath -> UTCTime -> [(Text, ZipSource)] -> IO ()
writeZipFile target time files = withBinaryFile target WriteMode $ \h -> do
  written <- foldM (\acc (path, source) -> (: acc) <$> writeEntry h path source) [] files
  let entries = reverse written
      count = length entries
  when (count >= 0xFFFF) $ throwIO (ZipTooLarge "65535 or more files")
  directoryStart <- hTell h
  for_ entries (hPutBuilder h . centralHeader)
  directoryEnd <- hTell h
  when (directoryStart >= 0xFFFFFFFF) $ throwIO (ZipTooLarge "4 GiB or more in all")
  hPutBuilder h $
    word32LE 0x06054b50
      <> word16LE 0
      <> word16LE 0
      <> word16LE (fromIntegral count)
      <> word16LE (fromIntegral count)
      <> word32LE (fromIntegral (directoryEnd - directoryStart))
      <> word32LE (fromIntegral directoryStart)
      <> word16LE 0
  where
    (dosTime, dosDate) = msDosDateTime (floor (utcTimeToPOSIXSeconds time))

    -- What the central directory says of an entry.
    centralHeader e =
      word32LE 0x02014b50
        <> word16LE 0 -- made by: MS-DOS, as zip-archive says
        <> word16LE 20
        <> word16LE 0x800 -- the name is UTF-8
        <> word16LE e.method
        <> word16LE dosTime
        <> word16LE dosDate
        <> word32LE e.crc
        <> word32LE (fromIntegral e.compressed)
        <> word32LE (fromIntegral e.size)
        <> word16LE (fromIntegral (BS.length e.name))
        <> word16LE 0
        <> word16LE 0
        <> word16LE 0
        <> word16LE 0
        <> word32LE 0
        <> word32LE (fromIntegral e.offset)
        <> byteString e.name

    localHeader name method crc compressed size =
      word32LE 0x04034b50
        <> word16LE 20
        <> word16LE 0x800
        <> word16LE method
        <> word16LE dosTime
        <> word16LE dosDate
        <> word32LE crc
        <> word32LE (fromIntegral compressed)
        <> word32LE (fromIntegral size)
        <> word16LE (fromIntegral (BS.length name))
        <> word16LE 0
        <> byteString name

    writeEntry :: Handle -> Text -> ZipSource -> IO Written
    writeEntry h path source = do
      offset <- hTell h
      let name = encodeUtf8 (normalised path)
      hPutBuilder h (localHeader name 0 0 0 (0 :: Integer))
      dataStart <- hTell h
      -- Three reads of a file on disk at most: its checksum and size, its
      -- compressed bytes, and its bytes as they are if compressing did not
      -- help. Each read is consumed as it is made.
      (crc, size) <- withSource source (evaluate . BSL.foldlChunks (\(c, n) chunk -> let !c' = crc32Update c chunk; !n' = n + fromIntegral (BS.length chunk) in (c', n')) (0, 0 :: Integer))
      when (size >= 0xFFFFFFFF) $ throwIO (ZipTooLarge (path <> " is 4 GiB or more"))
      withSource source (BSL.hPut h . Raw.compress)
      deflated <- subtract dataStart <$> hTell h
      (method, compressed) <-
        if size <= deflated
          then do
            hSeek h AbsoluteSeek dataStart
            withSource source (BSL.hPut h)
            hSetFileSize h (dataStart + fromIntegral size)
            pure (0, size)
          else pure (8, deflated)
      end <- hTell h
      hSeek h AbsoluteSeek offset
      hPutBuilder h (localHeader name method crc compressed size)
      hSeek h AbsoluteSeek end
      pure Written {name, method, crc, compressed, size, offset}

-- | What 'writeZipFile' wrote of one entry, for the central directory.
data Written = Written
  { name :: ByteString
  , method :: Word16
  , crc :: Word32
  , compressed :: Integer
  , size :: Integer
  , offset :: Integer
  }

-- | Run an action on a source's bytes, as a lazy string read as it is
-- consumed. The action must consume what it needs before it returns:
-- the file is closed then.
withSource :: ZipSource -> (LByteString -> IO a) -> IO a
withSource source act = case source of
  ZipBytes bytes -> act (BSL.fromStrict bytes)
  ZipFile file -> withBinaryFile file ReadMode (BSL.hGetContents >=> act)

-- | A path as @zip-archive@ writes it (its @normalizePath@): the
-- directories without @.@, then the file's name.
normalised :: Text -> Text
normalised path = T.intercalate "/" (map T.pack (filter (/= ".") (splitDirectories (takeDirectory p)) <> [takeFileName p]))
  where
    p = T.unpack path

-- | A time in seconds since the epoch as MS-DOS writes it, time and date,
-- with no time zone, as @zip-archive@ writes it: clamped to the years
-- 1980 to 2107, seconds rounded down to an even number.
msDosDateTime :: Integer -> (Word16, Word16)
msDosDateTime seconds = (fromIntegral dosTime, fromIntegral dosDate)
  where
    earliest = 315532800
    latest = floor (utcTimeToPOSIXSeconds (UTCTime (fromGregorian 2107 12 31) (23 * 3600 + 59 * 60 + 58)))
    clamped = max earliest (min latest seconds)
    UTCTime day dayTime = posixSecondsToUTCTime (fromIntegral clamped)
    (year, month, dayOfMonth) = toGregorian day
    TimeOfDay hour minute sec = timeToTimeOfDay dayTime
    dosTime = (floor sec `div` 2) + shiftL minute 5 + shiftL hour 11 :: Int
    dosDate = dayOfMonth + shiftL month 5 + shiftL (fromIntegral year - 1980) 9 :: Int
