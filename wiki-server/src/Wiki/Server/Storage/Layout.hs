-- | The layout of a data directory. The server's whole state is one
-- directory, given on its command line, so that deploying it, backing it
-- up and moving it all concern one path.
--
-- > <data>/wiki.sqlite                    the database (with -wal and -shm beside it)
-- > <data>/attachments/<ab>/<abcd…>       attachments' bytes, by content hash
-- > <data>/backups/<time>.sqlite          copies of the database
module Wiki.Server.Storage.Layout
  ( databaseFile
  , attachmentsDir
  , backupsDir
  )
where

import Protolude
import System.FilePath ((</>))

-- | The database.
databaseFile :: FilePath -> FilePath
databaseFile dataDir = dataDir </> "wiki.sqlite"

-- | The attachments' bytes ("Wiki.Server.Storage.Blobs").
attachmentsDir :: FilePath -> FilePath
attachmentsDir dataDir = dataDir </> "attachments"

-- | The backups of the database ("Wiki.Server.Storage.Backup").
backupsDir :: FilePath -> FilePath
backupsDir dataDir = dataDir </> "backups"
