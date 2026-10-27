{-# LANGUAGE TemplateHaskell #-}

-- | Backups the server makes by itself (WP4.9 of docs/PLAN.md), set in a
-- "Backups" part of the administration's "Server" section and nowhere
-- else: no option and no environment variable turns them on, and a server
-- nobody has set them up on makes none.
--
-- Once on, the server copies its database aside on a schedule ('Schedule':
-- every day at a time, or every so many hours) and when an administrator
-- asks ("Back up now"), as the deploy does before it starts a new server:
-- with SQLite's @VACUUM INTO@ into @data\/backups\/\<time>.sqlite@, checked
-- with @PRAGMA integrity_check@. The backups are pruned to a number of days
-- and weeks ('Retention', 'retained'), and the newest, with the
-- attachments' files, is copied off the machine if a destination is set
-- ('Destination'): a directory (a disk mounted there) or an @rclone@ remote,
-- whose configuration is a secret written once and never read back, as the
-- mail account's password is ("Wiki.Api.ServerSettings").
--
-- So the settings are one type with that secret as its parameter, as the
-- server's other settings are: 'BackupSettings' as they are read (whether
-- it is set), 'BackupSettingsChange' as they are written ('Nothing' keeps
-- it, an empty text clears it, any other text replaces it), and, on the
-- server, as they are kept, with the secret itself.
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

    -- * What the server says of them
  , Backups (..)
  , BackupRecord (..)
  , Trigger (..)
  , OffSite (..)

    -- * When, and which are kept
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
import Wiki.Core.Json (defaultOptions, deriveValueJSON)

--------------------------------------------------------------------------------
-- The settings

-- | How the server backs itself up, with the @rclone@ configuration as an
-- @s@.
data BackupSettingsOf s = BackupSettings
  { enabled :: Bool
  -- ^ Whether the server backs up by itself at all: off until an
  -- administrator turns it on.
  , schedule :: Schedule
  , keep :: Retention
  , destination :: Maybe (DestinationOf s)
  -- ^ Where the newest backup and the attachments' files are copied after
  -- each backup, off the machine; none, if not set.
  }
  deriving stock (Eq, Show, Functor)

-- | As the API answers them.
type BackupSettings = BackupSettingsOf SecretState

-- | As the API is sent them: the @rclone@ configuration kept, replaced or
-- cleared.
type BackupSettingsChange = BackupSettingsOf (Maybe Text)

-- | When the server backs up. Times are in UTC, as the backups' names are,
-- so that a schedule means the same whatever the machine's time zone and
-- whatever the clocks do in spring and autumn.
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

-- | How many backups are kept: the newest of each of the last so many days
-- that have one, and of each of the last so many weeks (ISO weeks,
-- Monday to Sunday). The newest backup is always kept.
data Retention = Retention
  { daily :: Int
  , weekly :: Int
  }
  deriving stock (Eq, Show)

-- | Where the backups are copied off the machine.
data DestinationOf s
  = -- | A directory on this machine that is another disk (or a network
    -- share) mounted there: it must be there already, so that a disk that
    -- is not mounted is a failure rather than a copy onto the machine's
    -- own disk under the mount point.
    ToDirectory Text
  | -- | An @rclone@ remote and path (@b2:my-bucket\/wiki@), and the
    -- configuration @rclone@ is run with (the text of an @rclone.conf@):
    -- without one, @rclone@'s own configuration of the server's user is
    -- used.
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
      -- A change may leave the configuration out, which keeps it.
      <|> (ToRclone <$> o .: "rclone" <*> (maybe (parseJSON Null) parseJSON =<< o .:? "config"))

-- Below 'DestinationOf', since a splice above it would hide it from
-- 'BackupSettingsOf', which holds it ("Wiki.Core.Json" says why).
deriveValueJSON defaultOptions ''Retention

-- Below 'Schedule', 'Retention' and 'DestinationOf', which it holds
-- ("Wiki.Core.Json" says why).
deriveValueJSON defaultOptions ''BackupSettingsOf

-- | A server nobody has set backups up on: off, and, once turned on,
-- every day at 03:00 UTC, keeping a week of days and four weeks.
defaultBackupSettings :: BackupSettingsOf s
defaultBackupSettings =
  BackupSettings
    { enabled = False
    , schedule = DailyAt 3 0
    , keep = Retention {daily = 7, weekly = 4}
    , destination = Nothing
    }

-- | The settings kept, with the configuration kept as @k@ (made from the
-- text sent by the function given), once a change is written over them:
-- left out, the configuration of an @rclone@ destination kept before is
-- kept; empty, it is cleared; given, it replaces it.
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

-- | The settings as they are kept, or the first reason they cannot be:
-- every text trimmed.
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
-- What the server says

-- | @GET \/api\/v1\/admin\/server\/backups@: the settings, the last backup
-- made, and what is under way.
data Backups = Backups
  { available :: Bool
  -- ^ Whether this backend makes backups at all: a server does; the demo,
  -- whose wiki is in the browser, does not, and shows the section
  -- disabled.
  , settings :: BackupSettings
  , last :: Maybe BackupRecord
  -- ^ The last backup made or tried, by schedule or by hand.
  , running :: Bool
  -- ^ Whether one is being made now.
  , next :: Maybe UTCTime
  -- ^ When the next is due, while they are on.
  , kept :: Int
  -- ^ How many backups the data directory holds, the deploy's included.
  }
  deriving stock (Eq, Show)

-- | A backup made, or tried.
data BackupRecord = BackupRecord
  { startedAt :: UTCTime
  , finishedAt :: UTCTime
  , trigger :: Trigger
  , file :: Maybe Text
  -- ^ The backup's name in @data\/backups@, if one was made and kept.
  , size :: Maybe Integer
  -- ^ Its size in bytes.
  , failure :: Maybe Text
  -- ^ Why no backup was made, or why the one made was let go (it failed
  -- its integrity check).
  , offSite :: Maybe OffSite
  -- ^ How copying it off the machine went, when there is somewhere to.
  }
  deriving stock (Eq, Show)

-- | What made a backup.
data Trigger = OnSchedule | Manual
  deriving stock (Eq, Show)

-- | A copy off the machine.
data OffSite = OffSite
  { to :: Text
  -- ^ Where to, as 'destinationText' says.
  , problem :: Maybe Text
  -- ^ Why it failed, if it did.
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''OffSite

-- Below 'OffSite', since a splice above it would hide it from
-- 'BackupRecord', which holds it ("Wiki.Core.Json" says why).
deriveValueJSON defaultOptions ''Trigger

-- Below 'Trigger' and 'OffSite', which it holds ("Wiki.Core.Json" says
-- why).
deriveValueJSON defaultOptions ''BackupRecord

-- Below 'BackupRecord', which it holds ("Wiki.Core.Json" says why).
deriveValueJSON defaultOptions ''Backups

--------------------------------------------------------------------------------
-- When, and which are kept

-- | When the next backup is due, by a schedule, after the last one made or
-- tried (if any), as it is now: a time not after now means one is due now.
--
-- Every so many hours counts from the last backup, and the first is due at
-- once. Every day at a time is due at the latest such time not after now
-- that no backup has followed: so the first is made as soon as backups are
-- turned on, a backup missed while the server was stopped is made when it
-- starts again, and one made by hand after that time counts for the day.
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

-- | Which backups a retention keeps, of those made at these times: the
-- newest of all, and the newest of each of the last @daily@ days and of
-- each of the last @weekly@ weeks that have one (in UTC).
retained :: Retention -> [UTCTime] -> Set UTCTime
retained r times = Set.fromList (take 1 newest <> newestOf r.daily utctDay <> newestOf r.weekly week)
  where
    newest = sortOn Down times
    week t = let (y, w, _) = toWeekDate (utctDay t) in (y, w)
    newestOf :: (Ord k) => Int -> (UTCTime -> k) -> [UTCTime]
    newestOf n key = take n (map snd (firstOfEach [(key t, t) | t <- newest]))

-- | The first of each run of the same key.
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
