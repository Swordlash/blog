{-# LANGUAGE QuasiQuotes #-}

-- | The header's bell (WP4.13 of docs/PLAN.md): the signed-in user's
-- notifications ("Wiki.Core.Notification"). It is a button showing how
-- many are unread, which opens a list of the latest, each a link to its
-- page (and to its thread, for a comment), with "Mark read" on each unread
-- one and "Mark all read".
--
-- The notifications are fetched in the initial state on a backend that
-- answers at once, so that the server's page has the count the program
-- starts with, and otherwise in 'Initialize'. On a backend with a live
-- channel ("Wiki.App.Live") the bell listens for the user's notifications
-- as they are made, which keeps the tab's WebSocket open wherever the
-- reader is. It fetches them again when the socket reopens, since
-- notifications made while it was closed were delivered to nobody. The
-- demo has no channel: to see what another user was notified of, switch
-- to that user.
--
-- Following a notification's link marks it read.
--
-- Opening the list fetches it again: a page of an encrypted space is
-- titled as this tab can decrypt it now ("Wiki.App.Backend.Http"
-- decrypts such titles), and not as it could when the
-- list was last fetched, inside a space that asks each time it is opened
-- and that the reader has left since.
--
-- The list closes on a press outside it and on Escape
-- ("Wiki.App.View.Popup"), and when one of its links is followed.
module Wiki.App.View.Bell
  ( Input (..)
  , component
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Wiki.Api.Notifications (Notifications (..))
import Wiki.App.Backend (MonadLoad (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Live (Feed (..))
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Route (..), pageRoute)
import Wiki.App.View.Bell.Machine (Effect (Listen, Load, Unlisten, Unwatch, Watch), Event (..), Model (..), Sealer (..), initial, step, unreadCount)
import Wiki.App.View.Bell.Machine qualified as M
import Wiki.App.View.Comments (threadElementId)
import Wiki.App.View.Common hiding (Loaded)
import Wiki.App.View.Popup (watchPopup)
import Wiki.Core.Encrypted (encryptedPageTitle)
import Wiki.Core.Id (NotificationId)
import Wiki.Core.Notification (Notification (..), PageLocation (..), notificationText, withTitle)
import Wiki.Core.Space (Space (encryption))

data Input = Input
  { context :: Context
  , feed :: Maybe Feed
  }

data State = State
  { input :: Input
  , model :: Model
  -- ^ What the bell knows ("Wiki.App.View.Bell.Machine"): every change to
  -- it is a 'step'.
  , holder :: H.RefLabel
  -- ^ The element that holds the bell and the list: a press outside it
  -- closes the list.
  , listWatch :: Maybe H.SubscriptionId
  -- ^ The watch for a press outside or Escape, while the list is open.
  }

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Toggle
  | Close
  | Heard Live.Heard
  | MarkRead NotificationId
  | MarkAllRead
  | Follow NotificationId (Follow Route)
  | -- | An answer of the backend, or anything else the machine takes.
    Happened (Event (Follow Route))

component :: forall query output m. (MonadLoad m, MonadNotifications m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          notices <- atOnce notifications
          holder <- H.newRefLabel "notifications"
          pure State {input, model = initial notices input.context.revision, holder, listWatch = Nothing}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render State {model = st, input, holder} =
      [hh|
        <div class="notifications" {{ HP.ref holder }}>
          <button
            type="button"
            class="notifications-toggle{% if unread > 0 %} has-unread{% end %}"
            aria-expanded={{ ariaBool st.open }}
            aria-label={{ label }}
            title={{ label }}
            onClick={{ const Toggle }}
          >
            <span class="notifications-bell" aria-hidden="true">🔔</span>
            {% if unread > 0 %}<span class="notifications-count">{{ show unread :: Text }}</span>{% end %}
          </button>
          {% if st.open %}
            <section class="notifications-panel" aria-label="Notifications">
              <div class="notifications-head">
                <h2>Notifications</h2>
                <button type="button" class="notifications-read-all" disabled={{ st.busy || unread == 0 }} onClick={{ const MarkAllRead }}>Mark all read</button>
              </div>
              {{ listView input st }}
            </section>
          {% end %}
        </div>
      |]
      where
        unread = unreadCount st
        label :: Text
        label = case unread of
          0 -> "Notifications"
          1 -> "Notifications: 1 unread"
          n -> "Notifications: " <> show n <> " unread"

    listView :: Input -> Model -> H.ComponentHTML Action Empty m
    listView input st = case st.notices of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
      Just (Right ns)
        | null ns.items ->
            [hh|<p class="notifications-empty">Nothing yet. You are told here when someone mentions you, comments on a page you watch or in a thread of yours, or changes a page you watch.</p>|]
        | otherwise ->
            [hh|
              <ul class="notification-list">
                {% for n in ns.items %}
                  <li class="notification{% if not n.read %} unread{% end %}" data-kind={{ kindClass n }}>
                    {{ noticeLink input n }}
                    {% if not n.read %}
                      <button type="button" class="notification-read" disabled={{ st.busy }} onClick={{ const (MarkRead n.id) }}>Mark read</button>
                    {% end %}
                  </li>
                {% end %}
              </ul>
            |]

    -- What a notification says, as a link to its page (to its thread, for
    -- a comment) if the page is still there to go to.
    noticeLink :: Input -> Notification -> H.ComponentHTML Action Empty m
    noticeLink input n = case n.location of
      Just l ->
        [hh|
          <a class="notification-link" {{ props l }}>
            {{ inner }}
          </a>
        |]
      Nothing -> [hh|<span class="notification-link">{{ inner }}</span>|]
      where
        -- The router's link, except for its address, which also names the
        -- thread, for a link opened in a new tab.
        props l = HP.href (Router.href input.context.router (pageRoute l.space l.page) <> maybe "" (\t -> "#" <> threadElementId t) n.thread) : drop 1 (Router.linkProps input.context.router (Follow n.id) (pageRoute l.space l.page))
        inner =
          [hhs|
            <span class="notification-what">{{ notificationText n }}</span>
            <span class="notification-page">{{ n.title }}</span>
            {% if n.excerpt /= "" %}<span class="notification-excerpt">{{ n.excerpt }}</span>{% end %}
            <span class="notification-time">{{ stamped n.createdAt }}</span>
          |]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> happen Started
      Finalize -> happen Finished
      -- Another reload of the wiki (a write, someone signed in): fetch
      -- again, as what is shown may have changed. The titles of pages of
      -- encrypted spaces go at once, as the server names them, before the
      -- list is read again: the reader may have left a space that asks
      -- each time it is opened.
      Receive input -> do
        modify (\st -> st {input})
        happen (Revised input.context.revision (Sealer (sealedAgain input.context)))
      Toggle -> happen Toggled
      Close -> happen Dismissed
      Heard heard -> case heard of
        Live.Notice n -> happen (Told n)
        Live.Reopened -> happen Reopened
        _ -> pass
      MarkRead i -> happen (MarkClicked i)
      MarkAllRead -> happen MarkAllClicked
      Follow i f -> happen (Followed i f)
      Happened event -> happen event

    -- One step of the machine, in one step of the program, and then its
    -- effects. An ask is forked and comes back as an event, so that
    -- nothing after it in this program waits for it.
    happen :: Event (Follow Route) -> H.HalogenM State Action Empty output m ()
    happen event = do
      effects <- state (\st -> let (model, fx) = step event st.model in (fx, st {model}))
      traverse_ perform effects

    perform :: Effect (Follow Route) -> H.HalogenM State Action Empty output m ()
    perform = \case
      Listen ->
        gets (\st -> st.input.feed)
          >>= traverse_
            ( \f -> do
                H.liftEffect (liftIO f.listen)
                void (H.subscribe (Heard <$> f.heard))
            )
      Unlisten -> gets (\st -> st.input.feed) >>= traverse_ (\f -> H.liftEffect (liftIO f.unlisten))
      Watch -> do
        watch <- gets (\st -> st.holder) >>= (`watchPopup` Close)
        modify (\st -> st {listWatch = watch})
      Unwatch -> do
        gets (\st -> st.listWatch) >>= traverse_ H.unsubscribe
        modify (\st -> st {listWatch = Nothing})
      Load asked -> void . H.fork $ lift notifications >>= handleAction . Happened . M.Loaded asked
      M.MarkRead asked r -> void . H.fork $ lift (markRead r) >>= handleAction . Happened . Marked asked
      M.Follow f -> do
        router <- gets (\st -> st.input.context.router)
        Router.follow router f

-- | A notification's kind, as a class the stylesheet and the tests use.
kindClass :: Notification -> Text
kindClass n = T.toLower (show n.kind)

-- | A time, in words for a person to read, in UTC: the same in the page
-- the server prerenders and in the program.
stamped :: UTCTime -> Text
stamped = toS . formatTime defaultTimeLocale "%-d %b %Y, %H:%M UTC"

-- | A notification as the server names its page, when the page is in an
-- encrypted space, or nowhere this tab knows: by what it is, not by its
-- title decrypted.
sealedAgain :: Context -> Notification -> Notification
sealedAgain ctx n = case n.location of
  Just l | Just chain <- findSpace ctx.spaces l.space, Just sp <- lastMay chain, isNothing sp.encryption -> n
  _ -> withTitle encryptedPageTitle n
