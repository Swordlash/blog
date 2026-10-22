-- | An archive's files as a zip file and back, natively, through
-- @zip-archive@: for the native tests, and for the server of Phase 2.
--
-- The browser makes and reads the same zip files with fflate (see
-- @web/src/archive.js@): @zip-archive@ needs the C library zlib through
-- @digest@, which the WebAssembly toolchain does not have, so this module
-- is built natively only.
module Wiki.Core.Export.Zip
  ( zipFiles
  , unzipFiles
  )
where

import Codec.Archive.Zip (Entry (..), addEntryToArchive, emptyArchive, fromArchive, fromEntry, toArchiveOrFail, toEntry, zEntries)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Protolude

-- | A zip file of these files, by path, each dated at the time given.
zipFiles :: UTCTime -> [(Text, ByteString)] -> ByteString
zipFiles time files =
  BSL.toStrict . fromArchive $
    foldl' (\archive (path, bytes) -> addEntryToArchive (toEntry (T.unpack path) seconds (BSL.fromStrict bytes)) archive) emptyArchive (reverse files)
  where
    seconds = floor (utcTimeToPOSIXSeconds time)

-- | The files a zip file holds, by path, but for directories' own
-- entries; or why it is not a zip file that can be read.
unzipFiles :: ByteString -> Either Text (Map Text ByteString)
unzipFiles bytes = do
  archive <- first toS (toArchiveOrFail (BSL.fromStrict bytes))
  pure $
    Map.fromList
      [ (T.pack (eRelativePath entry), BSL.toStrict (fromEntry entry))
      | entry <- zEntries archive
      , not ("/" `isSuffixOf` eRelativePath entry)
      ]
