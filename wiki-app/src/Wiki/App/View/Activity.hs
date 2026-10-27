{-# LANGUAGE QuasiQuotes #-}

-- | The administration's "Activity" section (WP4.10 of docs/PLAN.md,
-- "Wiki.Api.Activity"): the audit log, the newest first, one page at a
-- time, for everyone or for one person. Each entry says when, who, what
-- was done to what, what changed (never a secret: the log holds none), and
-- from which address.
--
-- It is a separate component, mounted by the administration page, and
-- reads the log as the other sections read their data: at once where the
-- backend answers at once (the demo, and a page the server prerendered,
-- which carries the log's first page), and otherwise in its initializer. It
-- fetches the log again when the wiki has changed (the context's
-- revision), since that change is in the log, and when another person or
-- page is chosen.
--
-- The demo keeps no log (its administration has one user, in this
-- browser): its backend says the log is not available, and the section
-- says so.
module Wiki.App.View.Activity
  ( Input (..)
  , component
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize, firstPage)
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.View.Common
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..), actionText)
import Wiki.Core.Id (UserId (..))

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready Activity

data State = State
  { input :: Input
  , query :: ActivityQuery
  , loaded :: Loaded
  , busy :: Bool
  -- ^ Another page, or another person's entries, are being fetched: the
  -- controls wait.
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | ChoseActor Text
  | Newer
  | Older

component :: forall query m. (MonadAdmin m, MonadLoad m) => H.Component query Input Void m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce (activity firstPage)
          pure State {input, query = firstPage, loaded, busy = False}
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
        <section class="admin-section admin-activity">
          <h2>Activity</h2>
          <p class="admin-intro">
            Every change to the wiki's administration, the newest first: who gave or took a
            permission, changed a group, an account or a setting, invited someone, deleted a space or
            a page, or imported a wiki, and from where.
          </p>
          {{ body }}
        </section>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready a
            | not a.available ->
                [hh|
                  <p class="admin-note activity-unavailable">
                    The demo keeps no activity log: its administration is yours alone, in this browser.
                    A wiki's server records every change to its administration here.
                  </p>
                |]
            | otherwise -> activityView st a

    activityView :: State -> Activity -> H.ComponentHTML Action Empty m
    activityView st a =
      [hh|
        <div class="activity">
          <label class="field activity-filter">
            <span>Who</span>
            <select name="actor" disabled={{ st.busy }} onValueChange={{ ChoseActor }}>
              <option value="" selected={{ isNothing st.query.actor }}>Everyone</option>
              {% for who in a.actors %}
                <option value={{ who.id.text }} selected={{ st.query.actor == Just who.id }}>{{ who.login }}</option>
              {% end %}
            </select>
          </label>
          {% if null a.entries %}
            <p class="empty activity-empty">{{ if isJust st.query.actor then "Nothing by them." else "Nothing yet." :: Text }}</p>
          {% else %}
            <table class="activity-table">
              <thead>
                <tr>
                  <th scope="col">When</th>
                  <th scope="col">Who</th>
                  <th scope="col">What</th>
                  <th scope="col">Details</th>
                  <th scope="col">From</th>
                </tr>
              </thead>
              <tbody>
                {% for e in a.entries %}
                  <tr class="activity-row" data-action={{ e.action }}>
                    <td class="activity-when">{{ timeText e.at }}</td>
                    <td class="activity-who">{{ e.actor.login }}</td>
                    <td class="activity-what">{{ actionText e.action }}{{ subjectText e.subject }}</td>
                    <td class="activity-detail">{{ detailText e.detail }}</td>
                    <td class="activity-from">{{ e.address }}</td>
                  </tr>
                {% end %}
              </tbody>
            </table>
          {% end %}
          <div class="actions activity-pages">
            <button type="button" class="activity-newer" disabled={{ st.busy || st.query.offset == 0 }} onClick={{ const Newer }}>Newer</button>
            <button type="button" class="activity-older" disabled={{ st.busy || not a.more }} onClick={{ const Older }}>Older</button>
            <span class="activity-range">{{ rangeText st.query a }}</span>
          </div>
        </div>
      |]

    handleAction :: Action -> H.HalogenM State Action Empty Void m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      ChoseActor chosen -> do
        let actor = if T.null chosen then Nothing else Just (UserId chosen)
        modify (\st -> st {query = ActivityQuery {actor, offset = 0}, busy = True})
        load
      Newer -> do
        modify (\st -> st {query = st.query {offset = max 0 (st.query.offset - activityPageSize)}, busy = True})
        load
      Older -> do
        modify (\st -> st {query = st.query {offset = st.query.offset + activityPageSize}, busy = True})
        load

    load :: H.HalogenM State Action Empty Void m ()
    load = do
      q <- gets (\st -> st.query)
      result <- lift (activity q)
      modify (\st -> st {loaded = either Failed Ready result, busy = False})

-- | A time, in words for a person to read.
timeText :: UTCTime -> Text
timeText = toS . formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC"

-- | What the action was done to, after the action's words: its name.
subjectText :: Subject -> Text
subjectText s
  | T.null s.name = ""
  | otherwise = ": " <> s.name

-- | What changed, field by field.
detailText :: Map Text Text -> Text
detailText = T.intercalate "; " . map (\(k, v) -> k <> ": " <> v) . Map.toList

-- | Which entries these are: @1–50@, @51–73@.
rangeText :: ActivityQuery -> Activity -> Text
rangeText q a
  | null a.entries = ""
  | otherwise = show (q.offset + 1) <> "–" <> show (q.offset + length a.entries)
