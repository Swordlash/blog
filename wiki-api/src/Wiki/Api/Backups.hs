{-# LANGUAGE DeriveAnyClass #-}

-- | Automatic backups (WP4.9 of docs/PLAN.md), set in a "Backups" part of
-- the administration's "Server" section and nowhere else. No command-line
-- option or environment variable turns them on, and a server where nobody
-- has set them up makes none.
--
-- Once backups are on, the server copies its database on a schedule
-- ('Schedule': every day at a set time, or every so many hours) and when
-- an administrator clicks "Back up now", as the deploy does before it
-- starts a new server. The copy is made with SQLite's @VACUUM INTO@ into
-- @data\/backups\/\<time>.sqlite@, and checked with
-- @PRAGMA integrity_check@. Old backups are pruned to a number of days and
-- weeks ('Retention', 'retained'). If a destination is set
-- ('Destination'), the newest backup and the attachments' files are copied
-- off the machine: to a directory (where a disk is mounted) or to an
-- @rclone@ remote. The @rclone@ configuration is a secret that can be
-- written but is never read back, like the mail account's password
-- ("Wiki.Api.ServerSettings").
--
-- So the settings are one type with that secret's type as its parameter,
-- like the server's other settings: 'BackupSettings' in responses (whether
-- the secret is set), 'BackupSettingsChange' in requests ('Nothing' keeps
-- it, an empty text clears it, any other text replaces it), and, on the
-- server, the stored settings, with the secret itself.
module Wiki.Api.Backups
  ( -- * The settings
    BackupSettingsOf (..)
  , BackupSettings
  , BackupSettingsChange
  , Schedule (..)
  , Retention (..)
  , DestinationOf (..)
  , defaultBackupSettings
  , applyBackupChange
  , checkBackupSettings
  , destinationText

    -- * The server's backup state
  , Backups (..)
  , BackupRecord (..)
  , Trigger (..)
  , OffSite (..)

    -- * Scheduling and retention
  , nextBackup
  , retained
  , scheduleText
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (Null), object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addDays, addUTCTime, secondsToDiffTime)
import Data.Time.Calendar.WeekDate (toWeekDate)
import Protolude
import Text.Printf (printf)
import Wiki.Api.ServerSettings (SecretState)

--------------------------------------------------------------------------------
-- The settings

-- | 'BackupSettingsOf': how the server backs itself up, with the @rclone@
-- configuration of type @s@.
data BackupSettingsOf s = BackupSettings
  { enabled :: Bool
  -- ^ Whether the server makes automatic backups at all: off until an
  -- administrator turns them on.
  , schedule :: Schedule
  , keep :: Retention
  , destination :: Maybe (DestinationOf s)
  -- ^ Where the newest backup and the attachments' files are copied off
  -- the machine after each backup; 'Nothing' if not set.
  }
  deriving stock (Eq, Show, Generic, Functor)

instance (ToJSON s) => ToJSON (BackupSettingsOf s)

instance (FromJSON s) => FromJSON (BackupSettingsOf s)

-- | The settings as API responses carry them.
type BackupSettings = BackupSettingsOf SecretState

-- | The settings as API requests carry them: the @rclone@ configuration
-- kept, replaced or cleared.
type BackupSettingsChange = BackupSettingsOf (Maybe Text)

-- | 'Schedule': when the server makes backups. Times are in UTC, as the
-- backups' names are, so that a schedule means the same whatever the
-- machine's time zone and whatever daylight saving time does.
data Schedule
  = -- | Every day at this hour and minute (UTC).
    DailyAt Int Int
  | -- | Every so many hours, counted from the last backup.
    EveryHours Int
  deriving stock (Eq, Show)

-- | @{"daily": "03:30"}@ or @{"everyHours": 6}@.
instance ToJSON Schedule where
  toJSON = \case
    DailyAt h m -> object ["daily" .= (toS (printf "%02d:%02d" h m :: [Char]) :: Text)]
    EveryHours n -> object ["everyHours" .= n]

instance FromJSON Schedule where
  parseJSON = withObject "a schedule" $ \o ->
    (o .: "daily" >>= time) <|> (EveryHours <$> o .: "everyHours")
    where
      time :: Text -> Parser Schedule
      time t = case T.splitOn ":" t of
        [h, m] | Just hour <- readMaybe h, Just minute <- readMaybe m -> pure (DailyAt hour minute)
        _ -> fail ("not a time of day, HH:MM: " <> toS t)

-- | 'Retention': which backups are kept. The newest backup of each of the
-- last so many days that have one, and of each of the last so many weeks
-- (ISO weeks, Monday to Sunday). The newest backup is always kept.
data Retention = Retention
  { daily :: Int
  , weekly :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'DestinationOf': where the backups are copied off the machine.
data DestinationOf s
  = -- | A directory on this machine where another disk (or a network
    -- share) is mounted. The directory must already exist, so that an
    -- unmounted disk is a failure rather than a copy onto the machine's
    -- own disk under the mount point.
    ToDirectory Text
  | -- | An @rclone@ remote and path (@b2:my-bucket\/wiki@), and the
    -- configuration @rclone@ runs with (the text of an @rclone.conf@).
    -- Without a configuration, the @rclone@ configuration of the server's
    -- system user is used.
    ToRclone Text s
  deriving stock (Eq, Show, Functor)

-- | @{"directory": "/mnt/backup/wiki"}@ or @{"rclone": "b2:bucket/wiki",
-- "config": …}@.
instance (ToJSON s) => ToJSON (DestinationOf s) where
  toJSON = \case
    ToDirectory path -> object ["directory" .= path]
    ToRclone remote config -> object ["rclone" .= remote, "config" .= config]

instance (FromJSON s) => FromJSON (DestinationOf s) where
  parseJSON = withObject "a destination" $ \o ->
    (ToDirectory <$> o .: "directory")
      -- A change may leave out the configuration, which keeps it.
      <|> (ToRclone <$> o .: "rclone" <*> (maybe (parseJSON Null) parseJSON =<< o .:? "config"))

-- | The backup settings of a server where nobody has set them up: off,
-- and, once turned on, every day at 03:00 UTC, keeping seven days and four
-- weeks.
defaultBackupSettings :: BackupSettingsOf s
defaultBackupSettings =
  BackupSettings
    { enabled = False
    , schedule = DailyAt 3 0
    , keep = Retention {daily = 7, weekly = 4}
    , destination = Nothing
    }

-- | The stored settings, with the configuration of type @k@ (made from the
-- sent text by the given function), after a change is applied to them. If
-- the change leaves the configuration out, the stored configuration of an
-- @rclone@ destination is kept; if it is empty, it is cleared; otherwise
-- it replaces the stored one.
applyBackupChange :: (Text -> k) -> BackupSettingsOf (Maybe k) -> BackupSettingsChange -> BackupSettingsOf (Maybe k)
applyBackupChange keep' old new =
  BackupSettings
    { enabled = new.enabled
    , schedule = new.schedule
    , keep = new.keep
    , destination = case new.destination of
        Nothing -> Nothing
        Just (ToDirectory path) -> Just (ToDirectory path)
        Just (ToRclone remote given) -> Just (ToRclone remote (resolve given))
    }
  where
    kept = case old.destination of
      Just (ToRclone _ c) -> c
      _ -> Nothing
    resolve = \case
      Nothing -> kept
      Just t
        | T.null t -> Nothing
        | otherwise -> Just (keep' t)

-- | The settings as they are stored, or the first reason they are
-- invalid: every text trimmed.
checkBackupSettings :: BackupSettingsOf s -> Either Text (BackupSettingsOf s)
checkBackupSettings s = do
  case s.schedule of
    DailyAt h m -> unless (h >= 0 && h <= 23 && m >= 0 && m <= 59) $ Left "A backup's time of day is from 00:00 to 23:59."
    EveryHours n -> unless (n >= 1 && n <= 168) $ Left "Backups every so many hours: from 1 to 168 (a week)."
  unless (s.keep.daily >= 1 && s.keep.daily <= 366) $ Left "The days to keep a backup of: from 1 to 366."
  unless (s.keep.weekly >= 0 && s.keep.weekly <= 520) $ Left "The weeks to keep a backup of: from 0 to 520."
  destination <- traverse checkDestination s.destination
  pure BackupSettings {enabled = s.enabled, schedule = s.schedule, keep = s.keep, destination}
  where
    checkDestination = \case
      ToDirectory raw -> do
        let path = T.strip raw
        when (T.null path) $ Left "The directory to copy the backups to needs its path."
        unless ("/" `T.isPrefixOf` path) $ Left ("The directory to copy the backups to is a full path, starting with /: " <> path)
        when (T.any isControl path) $ Left "The directory's path has a character a path cannot."
        pure (ToDirectory path)
      ToRclone raw config -> do
        let remote = T.strip raw
            (name, rest) = T.breakOn ":" remote
        when (T.null remote) $ Left "The rclone remote needs its name and path: remote:path."
        when (T.null rest || T.null name) $ Left ("An rclone remote is written remote:path, as rclone config names it: " <> remote)
        when ("-" `T.isPrefixOf` remote) $ Left ("An rclone remote does not start with a dash: " <> remote)
        when (T.any (\c -> isControl c || isSpace c) name) $ Left ("An rclone remote's name has no blank in it: " <> remote)
        when (T.any isControl remote) $ Left "The rclone remote has a character a path cannot."
        pure (ToRclone remote config)

-- | A destination, for a person to read.
destinationText :: DestinationOf s -> Text
destinationText = \case
  ToDirectory path -> path
  ToRclone remote _ -> remote

--------------------------------------------------------------------------------
-- The server's backup state

-- | 'Backups': the response to @GET \/api\/v1\/admin\/server\/backups@.
-- The settings, the last backup made, and any backup in progress.
data Backups = Backups
  { available :: Bool
  -- ^ Whether this backend makes backups at all. A server does. The demo,
  -- whose wiki is stored in the browser, does not, and shows the section
  -- disabled.
  , settings :: BackupSettings
  , last :: Maybe BackupRecord
  -- ^ The last backup made or attempted, by schedule or by hand.
  , running :: Bool
  -- ^ Whether a backup is being made now.
  , next :: Maybe UTCTime
  -- ^ When the next backup is due, while backups are on.
  , kept :: Int
  -- ^ The number of backups in the data directory, including the deploy's.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'BackupRecord': a backup made, or attempted.
data BackupRecord = BackupRecord
  { startedAt :: UTCTime
  , finishedAt :: UTCTime
  , trigger :: Trigger
  , file :: Maybe Text
  -- ^ The backup's file name in @data\/backups@, if one was made and kept.
  , size :: Maybe Integer
  -- ^ Its size in bytes.
  , failure :: Maybe Text
  -- ^ Why no backup was made, or why the backup made was deleted (it
  -- failed its integrity check).
  , offSite :: Maybe OffSite
  -- ^ The result of copying it off the machine, when a destination is set.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Trigger': what started a backup.
data Trigger = OnSchedule | Manual
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'OffSite': a copy off the machine.
data OffSite = OffSite
  { to :: Text
  -- ^ The destination, as 'destinationText' describes it.
  , problem :: Maybe Text
  -- ^ Why it failed, if it did.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- Scheduling and retention

-- | When the next backup is due, given a schedule, the time of the last
-- backup made or attempted (if any), and the current time. A time not
-- after the current time means a backup is due now.
--
-- An hourly schedule counts from the last backup, and the first backup is
-- due immediately. A daily schedule is due at the latest scheduled time
-- not after now that no backup has followed. So the first backup is made
-- as soon as backups are turned on, a backup missed while the server was
-- stopped is made when it starts again, and a backup made by hand after
-- the scheduled time counts for that day.
nextBackup :: Schedule -> Maybe UTCTime -> UTCTime -> UTCTime
nextBackup schedule lastAt now = case schedule of
  EveryHours n -> maybe now (addUTCTime (fromIntegral (n * 3600))) lastAt
  DailyAt h m ->
    let at day = UTCTime day (secondsToDiffTime (fromIntegral (h * 3600 + m * 60)))
        today = at (utctDay now)
        slot = if today <= now then today else at (addDays (-1) (utctDay now))
     in case lastAt of
          Just l | l >= slot -> addUTCTime 86400 slot
          _ -> slot

-- | The backups a retention keeps, among backups made at these times: the
-- newest of all, and the newest of each of the last @daily@ days and of
-- each of the last @weekly@ weeks that have one (in UTC).
retained :: Retention -> [UTCTime] -> Set UTCTime
retained r times = Set.fromList (take 1 newest <> newestOf r.daily utctDay <> newestOf r.weekly week)
  where
    newest = sortOn Down times
    week t = let (y, w, _) = toWeekDate (utctDay t) in (y, w)
    newestOf :: (Ord k) => Int -> (UTCTime -> k) -> [UTCTime]
    newestOf n key = take n (map snd (firstOfEach [(key t, t) | t <- newest]))

-- | The first element of each run of the same key.
firstOfEach :: (Eq k) => [(k, a)] -> [(k, a)]
firstOfEach = \case
  (k, a) : rest -> (k, a) : firstOfEach (dropWhile ((== k) . fst) rest)
  [] -> []

-- | A schedule, for a person to read.
scheduleText :: Schedule -> Text
scheduleText = \case
  DailyAt h m -> "every day at " <> toS (printf "%02d:%02d" h m :: [Char]) <> " UTC"
  EveryHours 1 -> "every hour"
  EveryHours n -> "every " <> show n <> " hours"
