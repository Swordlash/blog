{-# LANGUAGE QuasiQuotes #-}

-- | The administration's "Overview" section (WP4.10 of docs/PLAN.md; a
-- section of its own since WP5.25): which program version is running and
-- since when, the version of its database's schema, its newest backup, how
-- many live channels are open, how much the wiki holds, and the last
-- errors the server logged (twenty at most, kept in memory since it
-- started: the message, when, and the route it happened on, never a
-- secret, since the log has none). Where the wiki has no guide (the
-- space at @/guide@, WP5.29 of docs/PLAN.md), it offers "Install the
-- guide", which puts it in and goes to it.
--
-- It reads the status at once where the backend answers at once (a page
-- the server prerendered carries it), and otherwise in its initializer. "Refresh" fetches it again, as does a
-- change of the wiki. The demo has no server: its backend says so, and the
-- part shows a note.
module Wiki.App.View.Status
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Admin (LoggedError (..), ServerStatus (..))
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Route (Route (Space))
import Wiki.App.View.Common
import Wiki.Core.Slug (Slug, mkSlug)

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready (Maybe ServerStatus)

data State = State
  { input :: Input
  , loaded :: Loaded
  , busy :: Bool
  , refusal :: Maybe WikiError
  -- ^ Why the guide could not be installed.
  }

data Action
  = Initialize
  | Receive Input
  | Refresh
  | InstallGuide

component :: forall query m. (MonadAdmin m, MonadLoad m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce serverStatus
          pure State {input, loaded, busy = False, refusal = Nothing}
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
        <div class="server-part server-status">
          {{ body }}
        </div>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Refresh
          Ready Nothing ->
            [hh|
              <p class="admin-note status-unavailable">
                The demo has no server: its wiki is in this browser. A wiki's server says here how it is,
                with the last errors it logged.
              </p>
            |]
          Ready (Just s) -> statusView st s

    statusView :: State -> ServerStatus -> H.ComponentHTML Action Empty m
    statusView st s =
      [hh|
        <div class="status">
          <dl class="status-summary">
            <dt>Program</dt>
            <dd class="status-version">{{ s.version }}</dd>
            <dt>Running since</dt>
            <dd class="status-started">{{ timeText s.startedAt }}</dd>
            <dt>Data</dt>
            <dd class="status-data">{{ s.dataDir }}</dd>
            <dt>Schema</dt>
            <dd class="status-schema">{{ "Version " <> show s.schemaVersion :: Text }}</dd>
            <dt>Newest backup</dt>
            <dd class="status-backup">{{ maybe "None in the data directory." timeText s.lastBackup }}</dd>
            <dt>Live channels</dt>
            <dd class="status-connections">{{ show s.connections <> " open" :: Text }}</dd>
            <dt>Content</dt>
            <dd class="status-counts">{{ countsText s }}</dd>
          </dl>
          <h4>Recent errors</h4>
          {% if null s.errors %}
            <p class="status-no-errors">None since the server started.</p>
          {% else %}
            <ol class="status-errors">
              {% for e in s.errors %}
                <li class="status-error">
                  <span class="status-error-when">{{ timeText e.at }}</span>
                  <code class="status-error-route">{{ e.route }}</code>
                  <span class="status-error-message">{{ e.message }}</span>
                </li>
              {% end %}
            </ol>
          {% end %}
          {% if not s.guide %}
            <div class="status-guide">
              <h4>The guide</h4>
              <p class="admin-intro">
                The wiki has no guide: the public space at /guide with a tour and the Markdown guide, which a new server makes
                for itself. Install it to give everyone who reads this wiki its documentation.
              </p>
              {{ errorView <$> st.refusal }}
              <div class="actions">
                <button type="button" class="status-install-guide" disabled={{ st.busy }} onClick={{ const InstallGuide }}>Install the guide</button>
              </div>
            </div>
          {% end %}
          <div class="actions">
            <button type="button" class="status-refresh" disabled={{ st.busy }} onClick={{ const Refresh }}>Refresh</button>
          </div>
        </div>
      |]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Refresh -> modify (\st -> st {busy = True}) >> load
      InstallGuide -> do
        modify (\st -> st {busy = True, refusal = Nothing})
        lift installGuide >>= \case
          Left e -> modify (\st -> st {busy = False, refusal = Just e})
          -- The shell reloads the spaces and goes to the guide; this
          -- section is then left behind.
          Right () -> H.raise (Changed (Just (Space [guideSlug])))
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      result <- lift serverStatus
      modify (\st -> st {loaded = either Failed Ready result, busy = False})

-- | A time, in words for a person to read.
timeText :: UTCTime -> Text
timeText = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC"

-- | How much the wiki holds, in a line.
countsText :: ServerStatus -> Text
countsText s = T.intercalate ", " [counted s.spaces "space", counted s.pages "page", counted s.attachments "attachment", counted s.users "user"]
  where
    counted n what = show n <> " " <> what <> (if n == 1 then "" else "s")

-- | The guide's space's slug, @guide@, where the server installs it.
guideSlug :: Slug
guideSlug = either (panic . show) identity (mkSlug "guide")
