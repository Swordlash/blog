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

import Data.Aeson (decodeStrict', encode)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Database.SQLite.Simple (Only (..), Query (..), query, query_)
import Network.HTTP.Types (hCacheControl, hContentType, methodGet, methodHead, status200, status405, status503)
import Network.Wai (Application, Request (..), responseLBS)
import Protolude
import System.Directory (doesFileExist, getFileSize)
import Wiki.Api.Info (Health (..))
import Wiki.Core.Id (BlobId (..))
import Wiki.Core.Space (Icon (..))
import Wiki.Server.Api (Env (..))
import Wiki.Server.Events (openConnections)
import Wiki.Server.Log (errorCount)
import Wiki.Server.Metrics (Kind (..), Sample (..), contentType, renderMetrics, snapshot)
import Wiki.Server.Storage (schemaVersionOf, storageDataDir, withReadConnection)
import Wiki.Server.Storage.Backup (backupFiles, backupTime)
import Wiki.Server.Storage.Blobs (blobFile)
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

-- | What the server holds, read now. The blobs are counted from the
-- database, not from the blob directory: @wiki_blobs@ is the blobs the
-- attachments and the spaces' icons name, each once, and @wiki_blob_bytes@
-- their sizes, as the attachments' rows record them (a blob only an icon
-- names is sized from its file). So a scrape costs one query however many
-- attachments there are. Files that nothing names any more, which are
-- deleted at the next start ("Wiki.Server.Storage.Blobs"), are not counted.
metricSamples :: Env -> IO [Sample]
metricSamples env = do
  now <- getCurrentTime
  let dataDir = storageDataDir env.storage
      gauge name help value = Sample {name, help, kind = Gauge, labels = [], value}
  (counts, (blobs, attachedBytes), iconsAlone) <- withReadConnection env.storage $ \c -> do
    counted <- for ["spaces", "pages", "attachments", "users"] $ \table ->
      (table,) . maybe 0 fromOnly . head <$> (query_ c (Query ("SELECT count(*) FROM " <> table)) :: IO [Only Int])
    -- Two attachments with the same bytes share one blob, of one size.
    attached <-
      fromMaybe (0, 0)
        . head
        <$> (query_ c "SELECT count(*), coalesce(sum(size), 0) FROM (SELECT blob, max(size) AS size FROM attachments WHERE blob IS NOT NULL GROUP BY blob)" :: IO [(Int, Integer)])
    icons <- mapMaybe (\(Only t) -> imageOf =<< decodeStrict' (encodeUtf8 t)) <$> (query_ c "SELECT icon FROM spaces WHERE icon IS NOT NULL" :: IO [Only Text])
    alone <- filterM (\b -> null <$> (query c "SELECT 1 FROM attachments WHERE blob = ? LIMIT 1" (Only b.text) :: IO [Only Int])) (ordNub icons)
    pure (counted, attached, alone)
  schema <- schemaVersionOf env.storage
  connections <- openConnections env.events
  database <- sum <$> traverse sizeOf [databaseFile dataDir, databaseFile dataDir <> "-wal"]
  iconBytes <- sum <$> traverse (maybe (pure 0) sizeOf . blobFile (attachmentsDir dataDir)) iconsAlone
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
         , gauge "wiki_blobs" "The blobs (files of bytes) the attachments and the spaces' icons name." (fromIntegral (blobs + length iconsAlone))
         , gauge "wiki_blob_bytes" "The size of those blobs, in bytes." (fromIntegral (attachedBytes + iconBytes))
         , gauge "wiki_backups_kept" "The backups kept in the data directory." (fromIntegral (length kept))
         ]
      <> [ gauge "wiki_backup_age_seconds" "How long ago the newest backup kept was made, in seconds; absent when there is none." (realToFrac (diffUTCTime now t))
         | Just t <- [lastMay kept >>= backupTime]
         ]
      <> [Sample {name = "wiki_errors_total", help = "Errors the server logged since it started.", kind = Counter, labels = [], value = fromIntegral errors}]
  where
    posix t = realToFrac (utcTimeToPOSIXSeconds t)
    imageOf :: Icon -> Maybe BlobId
    imageOf = \case
      IconImage b _ -> Just b
      _ -> Nothing
    sizeOf file = ifM (doesFileExist file) (getFileSize file) (pure 0)
