-- | What a listener reports about the server to a machine (WP4.10 of
-- docs/PLAN.md): @\/healthz@, on both listeners, for a health check, and
-- @\/metrics@, on the admin listener only, for Prometheus. Both are at the
-- listener's root, outside the path where it serves the wiki, and both are
-- answered to anyone who reaches them, before the closed wiki's rule.
-- @\/healthz@ reveals nothing of the wiki's content or users, and
-- @\/metrics@ is on the loopback listener, where whoever can reach the
-- machine is the administrator already (decision 11 of the plan).
module Wiki.Server.Health
  ( healthApplication
  , metricsApplication
  , metricSamples
  , lastBackupAt
  )
where

import Data.Aeson (encode)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple (Only (..), Query (..), query_)
import Network.HTTP.Types (hCacheControl, hContentType, methodGet, methodHead, status200, status405, status503)
import Network.Wai (Application, Request (..), responseLBS)
import Protolude
import System.Directory (doesFileExist, getFileSize)
import Wiki.Api.Info (Health (..))
import Wiki.Server.Api (Env (..))
import Wiki.Server.Events (openConnections)
import Wiki.Server.Log (errorCount)
import Wiki.Server.Metrics (Kind (..), Sample (..), contentType, renderMetrics, snapshot)
import Wiki.Server.Storage (schemaVersionOf, storageDataDir, withDatabase)
import Wiki.Server.Storage.Backup (backupFiles, backupTime)
import Wiki.Server.Storage.Blobs (blobFile, storedBlobs)
import Wiki.Server.Storage.Layout (attachmentsDir, backupsDir, databaseFile)

-- | @GET \/healthz@: 'Health' as JSON, a 200 while the database answers
-- and a 503 when it does not.
healthApplication :: Env -> Application
healthApplication env request respond
  | requestMethod request `notElem` [methodGet, methodHead] = respond (responseLBS status405 [("Allow", "GET, HEAD")] "")
  | otherwise = do
      now <- getCurrentTime
      checked <- try @SomeException (schemaVersionOf env.storage)
      newest <- lastBackupAt (storageDataDir env.storage)
      let age = (\t -> round (diffUTCTime now t)) <$> newest
          (status, health) = case checked of
            Right schemaVersion -> (status200, Health {status = "ok", schemaVersion, lastBackupAgeSeconds = age})
            Left _ -> (status503, Health {status = "failing", schemaVersion = 0, lastBackupAgeSeconds = age})
      respond (responseLBS status [(hContentType, "application/json"), (hCacheControl, "no-store")] (encode health))

-- | When the newest backup in a data directory was made, read from its
-- name: by the server's schedule, by hand, or by a deploy.
lastBackupAt :: FilePath -> IO (Maybe UTCTime)
lastBackupAt dataDir = (>>= backupTime) . lastMay <$> backupFiles (backupsDir dataDir)

-- | @GET \/metrics@: the requests counted and what the server holds, in
-- the Prometheus text format ("Wiki.Server.Metrics").
metricsApplication :: Env -> Application
metricsApplication env request respond
  | requestMethod request `notElem` [methodGet, methodHead] = respond (responseLBS status405 [("Allow", "GET, HEAD")] "")
  | otherwise = do
      counted <- snapshot env.metrics
      samples <- metricSamples env
      respond (responseLBS status200 [(hContentType, contentType), (hCacheControl, "no-store")] (toS (encodeUtf8 (renderMetrics counted samples))))

-- | What the server holds, read now.
metricSamples :: Env -> IO [Sample]
metricSamples env = do
  now <- getCurrentTime
  let dataDir = storageDataDir env.storage
      gauge name help value = Sample {name, help, kind = Gauge, labels = [], value}
  counts <- withDatabase env.storage $ \c ->
    for ["spaces", "pages", "attachments", "users"] $ \table ->
      (table,) . maybe 0 fromOnly . head <$> (query_ c (Query ("SELECT count(*) FROM " <> table)) :: IO [Only Int])
  schema <- schemaVersionOf env.storage
  connections <- openConnections env.events
  database <- sum <$> traverse sizeOf [databaseFile dataDir, databaseFile dataDir <> "-wal"]
  blobs <- toList <$> storedBlobs (attachmentsDir dataDir)
  blobBytes <- sum <$> traverse (maybe (pure 0) sizeOf . blobFile (attachmentsDir dataDir)) blobs
  kept <- backupFiles (backupsDir dataDir)
  errors <- errorCount env.errors
  pure $
    [ Sample {name = "wiki_build_info", help = "The server program and its version.", kind = Gauge, labels = [("version", env.version)], value = 1}
    , gauge "wiki_start_time_seconds" "When the server started, in seconds since the epoch." (posix env.startedAt)
    , gauge "wiki_schema_version" "The version of the database's schema: its last migration." (fromIntegral schema)
    , gauge "wiki_websockets_open" "Live channels (WebSockets) open." (fromIntegral connections)
    ]
      <> [gauge ("wiki_" <> table) ("How many " <> table <> " the wiki has.") (fromIntegral n) | (table, n) <- counts]
      <> [ gauge "wiki_database_bytes" "The size of the database's files (with its write-ahead log), in bytes." (fromIntegral database)
         , gauge "wiki_blobs" "The files the attachments' and icons' bytes are kept in." (fromIntegral (length blobs))
         , gauge "wiki_blob_bytes" "The size of those files, in bytes." (fromIntegral blobBytes)
         , gauge "wiki_backups_kept" "The backups kept in the data directory." (fromIntegral (length kept))
         ]
      <> [ gauge "wiki_backup_age_seconds" "How long ago the newest backup kept was made, in seconds; absent when there is none." (realToFrac (diffUTCTime now t))
         | Just t <- [lastMay kept >>= backupTime]
         ]
      <> [Sample {name = "wiki_errors_total", help = "Errors the server logged since it started.", kind = Counter, labels = [], value = fromIntegral errors}]
  where
    posix t = realToFrac (utcTimeToPOSIXSeconds t)
    sizeOf file = ifM (doesFileExist file) (getFileSize file) (pure 0)
