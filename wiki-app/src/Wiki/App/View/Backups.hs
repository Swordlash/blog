{-# LANGUAGE QuasiQuotes #-}

-- | The "Backups" part of the administration's "Server" section (WP4.9 of
-- docs/PLAN.md, "Wiki.Api.Backups"): whether the server backs itself up,
-- when, how many backups it keeps, and where it copies them off the
-- machine; the last backup's time, size and result; and "Back up now".
-- Backups are off until they are turned on here, which is the only place
-- they are set.
--
-- It is a separate component inside the Server section, which mounts it,
-- so that its own state (the settings as typed, a running backup) belongs
-- to it. It reads the backups as the section's other parts read their
-- data: at once where the backend answers at once (the demo, and a page
-- the server prerendered, which carries them), and otherwise in its
-- initializer.
--
-- The settings are changed in a form that replaces what is shown, and
-- saved all at once. The rclone configuration, a secret, is typed once and
-- never shown again, like the section's passwords: "Replace…" and "Clear".
-- "Back up now" answers once the backup is made, or, if it takes longer (a
-- slow copy off the machine), while it is still running. The part then
-- fetches the backups' state again every few seconds until it is done.
--
-- The demo makes no backups: its wiki is in the browser. Its backend says
-- they are not available, and the part is shown disabled, with a note.
module Wiki.App.View.Backups
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Text.Printf (printf)
import Wiki.Api.Backups
import Wiki.Api.ServerSettings (SecretState (..))
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Common

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready Backups

-- | Where the backups go, as chosen in the form.
data Kind = Nowhere | Directory | Rclone
  deriving stock (Eq, Show, Enum, Bounded)

-- | The settings' form, as typed.
data Form = Form
  { turnedOn :: Bool
  , everyDay :: Bool
  -- ^ Every day at a time, or every so many hours.
  , typedTime :: Text
  , typedHours :: Text
  , typedDays :: Text
  , typedWeeks :: Text
  , kind :: Kind
  , typedPath :: Text
  , typedRemote :: Text
  , typedConfig :: Text
  , configSet :: Bool
  -- ^ Whether the server has a configuration already: if so, the field is
  -- offered only once "Replace…" is chosen.
  , replacingConfig :: Bool
  , clearingConfig :: Bool
  }

data State = State
  { input :: Input
  , loaded :: Loaded
  , form :: Maybe Form
  , busy :: Bool
  , refusal :: Maybe WikiError
  , watching :: Bool
  -- ^ Whether a running backup is being waited for.
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | Edit
  | Cancel
  | Save
  | BackUpNow
  | Look
  | ChoseEnabled Bool
  | ChoseSchedule Text
  | TypedTime Text
  | TypedHours Text
  | TypedDays Text
  | TypedWeeks Text
  | ChoseKind Text
  | TypedPath Text
  | TypedRemote Text
  | TypedConfig Text
  | ReplaceConfig
  | ClearConfig

-- | How long to wait before fetching the backups' state again while one
-- is running, in microseconds.
lookAgain :: Int
lookAgain = 2_000_000

component :: forall query m. (MonadAdmin m, MonadLoad m, MonadIO m) => H.Component query Input Void m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce backups
          pure State {input, loaded, form = Nothing, busy = False, refusal = Nothing, watching = False}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="server-part server-backups">
          <h3>Backups</h3>
          {{ body }}
        </div>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready b -> backupsView st b

    backupsView :: State -> Backups -> H.ComponentHTML Action Empty m
    backupsView st b =
      [hh|
        <div class="backups">
          {% if not b.available %}
            <p class="admin-note backups-unavailable">
              The demo makes no backups: its wiki is in this browser, and "Export the wiki" above keeps a copy of it.
              A wiki's server backs itself up from here once they are turned on.
            </p>
          {% end %}
          <fieldset class="backups-body" disabled={{ not b.available }}>
            {{ errorView <$> st.refusal }}
            {{ maybe (summary st b) (formView st) st.form }}
          </fieldset>
        </div>
      |]

    summary :: State -> Backups -> H.ComponentHTML Action Empty m
    summary st b =
      [hh|
        <div class="backups-shown">
          <p class="backups-state">{{ stateText b.settings }}</p>
          <p class="admin-intro">
            Each backup is a copy of the database in the data directory's backups, checked before it is kept.
            The attachments' files are copied with it when it goes off the machine.
          </p>
          <dl class="backups-summary">
            <dt>Last backup</dt>
            <dd class="backups-last">{{ maybe "None made yet." lastText b.last }}</dd>
            {% for problem in lastProblems b.last %}
              <dt>Problem</dt>
              <dd class="backups-problem error">{{ problem }}</dd>
            {% end %}
            {% for n in maybeToList (mfilter (const b.settings.enabled) b.next) %}
              <dt>Next</dt>
              <dd class="backups-next">{{ timeText n }}</dd>
            {% end %}
            <dt>Kept</dt>
            <dd class="backups-kept">{{ keptText b.kept }}</dd>
          </dl>
          {% if b.running %}
            <p class="backups-running loading" role="status">Making a backup…</p>
          {% end %}
          <div class="actions">
            <button type="button" class="backups-edit" disabled={{ st.busy }} onClick={{ const Edit }}>Change</button>
            <button
              type="button"
              class="backups-now"
              disabled={{ st.busy || b.running || not b.settings.enabled }}
              title={{ if b.settings.enabled then "" else "Turn backups on first" :: Text }}
              onClick={{ const BackUpNow }}
            >
              Back up now
            </button>
          </div>
        </div>
      |]

    formView :: State -> Form -> H.ComponentHTML Action Empty m
    formView st form =
      [hh|
        <form class="backups-form" aria-label="Backups" {{ HE.preventingDefault (HE.onSubmit (const Save)) }}>
          <label class="field field-check">
            <input type="checkbox" name="enabled" checked={{ form.turnedOn }} onChecked={{ ChoseEnabled }}>
            <span>Back the server up by itself</span>
          </label>
          <label class="field">
            <span>How often</span>
            <select name="schedule" onValueChange={{ ChoseSchedule }}>
              <option value="daily" selected={{ form.everyDay }}>Every day at a time (UTC)</option>
              <option value="hours" selected={{ not form.everyDay }}>Every so many hours</option>
            </select>
          </label>
          {% if form.everyDay %}
            <label class="field">
              <span>At (HH:MM, UTC)</span>
              <input type="text" name="time" inputmode="numeric" placeholder="03:00" required value={{ form.typedTime }} onValueInput={{ TypedTime }}>
            </label>
          {% else %}
            <label class="field">
              <span>Every so many hours</span>
              <input type="number" name="hours" min="1" max="168" required value={{ form.typedHours }} onValueInput={{ TypedHours }}>
            </label>
          {% end %}
          <label class="field">
            <span>Keep the newest of each of the last so many days</span>
            <input type="number" name="days" min="1" max="366" required value={{ form.typedDays }} onValueInput={{ TypedDays }}>
          </label>
          <label class="field">
            <span>And of each of the last so many weeks</span>
            <input type="number" name="weeks" min="0" max="520" required value={{ form.typedWeeks }} onValueInput={{ TypedWeeks }}>
          </label>
          <label class="field">
            <span>Copy each off the machine to</span>
            <select name="destination" onValueChange={{ ChoseKind }}>
              {% for k in [minBound .. maxBound :: Kind] %}
                <option value={{ kindValue k }} selected={{ k == form.kind }}>{{ kindText k }}</option>
              {% end %}
            </select>
          </label>
          {% if form.kind == Nowhere %}
            <p class="admin-note">The backups stay in the data directory only: a disk that fails takes them with it.</p>
          {% elif form.kind == Directory %}
            <label class="field">
              <span>Directory (a full path, where another disk is mounted)</span>
              <input type="text" name="path" autocomplete="off" required placeholder="/mnt/backup/wiki" value={{ form.typedPath }} onValueInput={{ TypedPath }}>
            </label>
          {% else %}
            <label class="field">
              <span>rclone remote and path</span>
              <input type="text" name="remote" autocomplete="off" required placeholder="b2:my-bucket/wiki" value={{ form.typedRemote }} onValueInput={{ TypedRemote }}>
            </label>
            {{ configField form }}
          {% end %}
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Save</button>
            <button type="button" class="backups-cancel" onClick={{ const Cancel }}>Cancel</button>
          </div>
        </form>
      |]

    -- The rclone configuration: typed once, never shown. Where one is set,
    -- the field is offered only to replace it, and it may be cleared.
    configField :: Form -> H.ComponentHTML Action Empty m
    configField form
      | form.configSet && not form.replacingConfig =
          [hh|
            <div class="field server-secret backups-config">
              <span>rclone configuration</span>
              <span class="server-secret-state">{{ if form.clearingConfig then "Cleared when saved" else "Set" :: Text }}</span>
              <button type="button" class="server-secret-replace" onClick={{ const ReplaceConfig }}>Replace…</button>
              <button type="button" class="server-secret-clear" disabled={{ form.clearingConfig }} onClick={{ const ClearConfig }}>Clear</button>
            </div>
          |]
      | otherwise =
          [hh|
            <label class="field server-secret backups-config">
              <span>{{ configLabel form.configSet }}</span>
              <textarea name="config" autocomplete="off" spellcheck="false" rows="4" placeholder="The remote's section of rclone.conf" value={{ form.typedConfig }} onValueInput={{ TypedConfig }}></textarea>
            </label>
          |]

    handleAction :: Action -> H.HalogenM State Action Empty Void m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          Ready b | b.running -> watch
          _ -> pass
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      Edit -> withBackups $ \b -> modify (\st -> st {form = Just (formOf b.settings), refusal = Nothing})
      Cancel -> modify (\st -> st {form = Nothing, refusal = Nothing})
      Save ->
        gets (\st -> st.form) >>= \case
          Nothing -> pass
          Just form -> case changeOf form of
            Left why -> modify (\st -> st {refusal = Just (Invalid why)})
            Right change -> do
              modify (\st -> st {busy = True, refusal = Nothing})
              lift (setBackupSettings change) >>= \case
                Left e -> modify (\st -> st {busy = False, refusal = Just e})
                Right b -> do
                  modify (\st -> st {busy = False, loaded = Ready b, form = Nothing})
                  when b.running watch
      BackUpNow -> do
        modify (\st -> st {busy = True, refusal = Nothing})
        lift backUpNow >>= \case
          Left e -> modify (\st -> st {busy = False, refusal = Just e})
          Right b -> do
            modify (\st -> st {busy = False, loaded = Ready b})
            when b.running watch
      Look -> do
        result <- lift backups
        modify (\st -> st {watching = False, loaded = either Failed Ready result})
        case result of
          Right b | b.running -> watch
          _ -> pass
      ChoseEnabled yes -> onForm (\f -> f {turnedOn = yes})
      ChoseSchedule t -> onForm (\f -> f {everyDay = t == "daily"})
      TypedTime t -> onForm (\f -> f {typedTime = t})
      TypedHours t -> onForm (\f -> f {typedHours = t})
      TypedDays t -> onForm (\f -> f {typedDays = t})
      TypedWeeks t -> onForm (\f -> f {typedWeeks = t})
      ChoseKind t -> onForm (\f -> f {kind = fromMaybe f.kind (find (\k -> kindValue k == t) [minBound .. maxBound])})
      TypedPath t -> onForm (\f -> f {typedPath = t})
      TypedRemote t -> onForm (\f -> f {typedRemote = t})
      TypedConfig t -> onForm (\f -> f {typedConfig = t})
      ReplaceConfig -> onForm (\f -> f {replacingConfig = True, clearingConfig = False})
      ClearConfig -> onForm (\f -> f {clearingConfig = True})

    -- Fetch the backups' state again once, after a while: a backup is
    -- running.
    watch :: H.HalogenM State Action Empty Void m ()
    watch =
      unlessM (gets (\st -> st.watching)) $ do
        modify (\st -> st {watching = True})
        void (H.fork (liftIO (threadDelay lookAgain) >> handleAction Look))

    withBackups :: (Backups -> H.HalogenM State Action Empty Void m ()) -> H.HalogenM State Action Empty Void m ()
    withBackups f =
      gets (\st -> st.loaded) >>= \case
        Ready b -> f b
        _ -> pass

    onForm :: (Form -> Form) -> H.HalogenM State Action Empty Void m ()
    onForm f = modify (\st -> st {form = f <$> st.form})

    load :: H.HalogenM State Action Empty Void m ()
    load = do
      result <- lift backups
      modify (\st -> st {loaded = either Failed Ready result, busy = False})
      case result of
        Right b | b.running -> watch
        _ -> pass

-- | The form for the current settings.
formOf :: BackupSettings -> Form
formOf s =
  Form
    { turnedOn = s.enabled
    , everyDay = isDaily
    , typedTime = case s.schedule of
        DailyAt h m -> toS (printf "%02d:%02d" h m :: [Char])
        EveryHours _ -> "03:00"
    , typedHours = case s.schedule of
        EveryHours n -> show n
        DailyAt _ _ -> "6"
    , typedDays = show s.keep.daily
    , typedWeeks = show s.keep.weekly
    , kind = case s.destination of
        Nothing -> Nowhere
        Just (ToDirectory _) -> Directory
        Just (ToRclone _ _) -> Rclone
    , typedPath = case s.destination of
        Just (ToDirectory p) -> p
        _ -> ""
    , typedRemote = case s.destination of
        Just (ToRclone r _) -> r
        _ -> ""
    , typedConfig = ""
    , configSet = case s.destination of
        Just (ToRclone _ Set) -> True
        _ -> False
    , replacingConfig = False
    , clearingConfig = False
    }
  where
    isDaily = case s.schedule of
      DailyAt _ _ -> True
      EveryHours _ -> False

-- | The settings as the form describes them, or why they cannot be: the
-- configuration kept unless one is typed, or it is cleared.
changeOf :: Form -> Either Text BackupSettingsChange
changeOf f = do
  schedule <-
    if f.everyDay
      then case T.splitOn ":" (T.strip f.typedTime) of
        [h, m] | Just hour <- readMaybe h, Just minute <- readMaybe m -> Right (DailyAt hour minute)
        _ -> Left "The time of day is written HH:MM, as 03:00."
      else maybe (Left "Every so many hours: a number from 1 to 168.") (Right . EveryHours) (readMaybe (T.strip f.typedHours))
  daily <- maybe (Left "The days to keep: a number.") Right (readMaybe (T.strip f.typedDays))
  weekly <- maybe (Left "The weeks to keep: a number.") Right (readMaybe (T.strip f.typedWeeks))
  pure
    BackupSettings
      { enabled = f.turnedOn
      , schedule
      , keep = Retention {daily, weekly}
      , destination = case f.kind of
          Nowhere -> Nothing
          Directory -> Just (ToDirectory (T.strip f.typedPath))
          Rclone ->
            Just
              ( ToRclone
                  (T.strip f.typedRemote)
                  ( if f.clearingConfig
                      then Just ""
                      else mfilter (not . T.null . T.strip) (Just f.typedConfig)
                  )
              )
      }

-- | Whether backups are on, and what they do, in a sentence.
stateText :: BackupSettings -> Text
stateText s
  | not s.enabled = "Off: the server makes no backups by itself."
  | otherwise =
      "On: "
        <> scheduleText s.schedule
        <> ", keeping the newest of each of the last "
        <> plural s.keep.daily "day"
        <> " and "
        <> plural s.keep.weekly "week"
        <> maybe ", in the data directory only." (\d -> ", copied to " <> destinationText d <> ".") s.destination
  where
    plural n what = show n <> " " <> what <> (if n == 1 then "" else "s")

-- | The last backup, in one line: when, its result, and its size.
lastText :: BackupRecord -> Text
lastText r =
  timeText r.startedAt
    <> (if r.trigger == Manual then ", by hand: " else ": ")
    <> case (r.failure, r.size) of
      (Just _, _) -> "failed."
      (Nothing, Just bytes) -> "made, " <> sizeText bytes <> maybe "." offSiteText r.offSite
      (Nothing, Nothing) -> "made."
  where
    offSiteText o = case o.problem of
      Nothing -> ", and copied to " <> o.to <> "."
      Just _ -> ", but not copied to " <> o.to <> "."

-- | What went wrong with the last backup, if anything did.
lastProblems :: Maybe BackupRecord -> [Text]
lastProblems = \case
  Nothing -> []
  Just r -> catMaybes [r.failure, r.offSite >>= \o -> o.problem]

timeText :: UTCTime -> Text
timeText = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

-- | A size in bytes, in the units people read.
sizeText :: Integer -> Text
sizeText bytes
  | bytes < 1024 = show bytes <> " bytes"
  | bytes < 1024 * 1024 = toS (printf "%.1f KB" (fromIntegral bytes / 1024 :: Double) :: [Char])
  | bytes < 1024 * 1024 * 1024 = toS (printf "%.1f MB" (fromIntegral bytes / (1024 * 1024) :: Double) :: [Char])
  | otherwise = toS (printf "%.2f GB" (fromIntegral bytes / (1024 * 1024 * 1024) :: Double) :: [Char])

keptText :: Int -> Text
keptText = \case
  0 -> "No backup in the data directory."
  1 -> "1 backup in the data directory."
  n -> show n <> " backups in the data directory."

configLabel :: Bool -> Text
configLabel isSet
  | isSet = "rclone configuration (a new one; left empty, the old one stays)"
  | otherwise = "rclone configuration (the remote's section of rclone.conf; left empty, the server's own)"

kindValue :: Kind -> Text
kindValue = \case
  Nowhere -> "none"
  Directory -> "directory"
  Rclone -> "rclone"

kindText :: Kind -> Text
kindText = \case
  Nowhere -> "Nowhere: keep them on this machine only"
  Directory -> "A directory (another disk mounted here)"
  Rclone -> "An rclone remote"
