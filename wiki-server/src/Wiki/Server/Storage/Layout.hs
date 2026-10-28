-- | The layout of a data directory. The server's whole state is one
-- directory, given on its command line, so that deploying it, backing it
-- up and moving it all concern one path.
--
-- > <data>/wiki.sqlite                    the database (with -wal and -shm beside it)
-- > <data>/attachments/<ab>/<abcd…>       attachments' bytes, by content hash
-- > <data>/backups/<time>.sqlite          copies of the database
-- > <data>/tmp/                           uploads as they arrive, and exports
module Wiki.Server.Storage.Layout
  ( databaseFile
  , attachmentsDir
  , backupsDir
  , temporaryDir
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

-- | The server's temporary files: each upload as it arrives (an attachment,
-- an icon, an archive to import), and each export's zip file while it is
-- sent. A file there is deleted when its request ends, and the directory
-- when the storage is opened. It is in the data directory rather than the
-- system's, which is often in memory: an upload or an export of a large
-- wiki must cost disk, not memory.
temporaryDir :: FilePath -> FilePath
temporaryDir dataDir = dataDir </> "tmp"
