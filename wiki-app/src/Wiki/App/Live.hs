-- | The live channel, as the application uses it (decision 23 of
-- docs/PLAN.md, "Wiki.Api.Events"): one WebSocket per tab to the server.
-- On it, the page view says which page it shows, and receives changes to
-- that page's comments as they happen.
--
-- It is a separate capability, 'MonadLive', which only the HTTP backend
-- has ("Wiki.App.Backend.Http"), as 'Wiki.App.Account.MonadAccount' is.
-- The demo keeps its wiki in the tab, where nobody else writes. When
-- there is a live channel, the shell gets it as a value ('Live', through
-- its input), asks it for the tab's 'Feed' once, and hands the feed to the
-- page view, which watches its page while it shows it.
--
-- = The feed
--
-- The WebSocket is opened lazily, when a page is first watched, and kept
-- for the tab's life. A watched page is subscribed to as soon as the
-- socket is open, and again whenever it reopens. A page no longer watched
-- is unsubscribed from. Each message the server sends about a page goes
-- to the listeners ('heard'), and to the backend first, which keeps the
-- page's cached threads up to date with it.
--
-- The server answers a subscription with the page's threads as they are
-- then, and afterwards sends every change ("Wiki.Api.Events"). The answer
-- replaces the threads the page view shows and the backend caches
-- ('Replaced'), and each event is applied to them ('Heard'). So any change
-- between the page's first read (with the page, or in the HTML it was
-- served in) and its subscription is caught up without a request of the
-- tab's own: a page adopted from the server's HTML still fetches nothing.
--
-- When the socket closes (the server went away, the network did, or the
-- server closed it), it is opened again after a pause. The pause doubles
-- from one second up to half a minute, and is one second again once a
-- socket has opened. Each wait is the pause give or take up to 30 % at
-- random ('jittered'), so that the tabs a server restart disconnected do
-- not all connect again in the same instant. Nothing is replayed: the
-- watched pages are subscribed to again, and the answers contain whatever
-- was missed, so a lost event costs nothing. While the socket is closed, the backend drops the cached
-- threads of every watched page, so that a page shown then fetches them
-- from the server.
--
-- A socket is opened as the user the browser's cookie names, and stays
-- that user's: signing in or out 'restart's it.
--
-- = Notifications
--
-- The server also sends on a socket every notification made for its user
-- (WP4.13 of docs/PLAN.md, "Wiki.Core.Notification"), whatever page it is
-- about. The header's bell 'listen's for them, which opens the socket
-- even where no page is shown, and keeps it open (reopening it if needed)
-- until the bell stops listening. Each notification is delivered as
-- 'Notice', to the backend first. When a socket opens again after it
-- closed, the feed delivers 'Reopened': notifications made meanwhile were
-- not delivered, so the bell fetches its notifications again.
--
-- = Editing
--
-- The editor says which page it edits ('startEditing', 'stopEditing'). The
-- feed tells the server at once if the socket is open, and again each time
-- it reopens, after the watched pages have been subscribed to: the server
-- forgets who is editing when the connection that said so closes, so a new
-- connection says it again. Who else is editing a page arrives as an event
-- ('Wiki.Api.Events.Editing'), and with the answer to the page's
-- subscription, which the feed delivers as such an event after
-- 'Replaced'. The feed keeps the latest editors it received for each
-- watched page ('editorsOf'), for a view that starts watching a page
-- another view watches already: that view gets no subscription answer of
-- its own.
--
-- Natively there is no WebSocket ("Halogen.Net.WebSocket" gives one that
-- never connects), and a feed does nothing. The server prerenders its
-- pages with the HTTP backend, whose page views watch their pages too.
module Wiki.App.Live
  ( -- * The capability
    MonadLive (..)
  , Live (..)
  , live

    -- * The feed
  , Feed (..)
  , Heard (..)
  , newFeed
  , quietFeed

    -- * Reconnecting
  , jittered
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Control.Monad.UUID (generateV4)
import Data.Aeson (decodeStrict', encode)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Type.Equality (type (~))
import Data.UUID.Types (toWords64)
import Halogen.JSBits (inBrowser)
import Halogen.Net.WebSocket qualified as WS
import Halogen.Query.HalogenM (HalogenM)
import Halogen.Subscription (Emitter (..), Listener (..))
import Halogen.Subscription qualified as HS
import Protolude
import Wiki.Api.Events (ClientMessage (..), PageEvent (..), ServerMessage (..), eventsPath)
import Wiki.Core.Comment (Thread)
import Wiki.Core.Id (PageId)
import Wiki.Core.Notification (Notification)
import Wiki.Core.Version (Author)

-- | A message the feed delivers to the tab.
data Heard
  = -- | An event on a page the tab watches.
    Heard PageId PageEvent
  | -- | The threads of a page the tab watches: the answer to its
    -- subscription, which replaces the threads shown.
    Replaced PageId [Thread]
  | -- | The user has a new notification.
    Notice Notification
  | -- | The socket opened again after it had closed: whatever the server
    -- sent meanwhile was lost.
    Reopened
  deriving stock (Eq, Show)

-- | The tab's live channel.
data Feed = Feed
  { heard :: Emitter IO Heard
  -- ^ The messages it delivers, for 'Halogen.subscribe'.
  , watch :: PageId -> IO ()
  -- ^ Listen for events on a page while it is shown. Each 'watch' is
  -- ended by an 'unwatch'.
  , unwatch :: PageId -> IO ()
  , restart :: IO ()
  -- ^ Open the socket again, as the user the cookie now names.
  , startEditing :: PageId -> IO ()
  -- ^ Announce that this tab edits a page, until 'stopEditing'.
  , stopEditing :: PageId -> IO ()
  , editorsOf :: PageId -> IO (Maybe [Author])
  -- ^ Who else edits a watched page, as last received; 'Nothing' until
  -- the server has said.
  , listen :: IO ()
  -- ^ Keep the socket open for the user's notifications, until 'unlisten'.
  , unlisten :: IO ()
  }

-- | A feed that delivers nothing: the feed natively, and for a backend
-- without a channel.
quietFeed :: IO Feed
quietFeed = do
  channel <- HS.create
  pure
    Feed
      { heard = channel.emitter
      , watch = \_ -> pass
      , unwatch = \_ -> pass
      , restart = pass
      , startEditing = \_ -> pass
      , stopEditing = \_ -> pass
      , editorsOf = \_ -> pure Nothing
      , listen = pass
      , unlisten = pass
      }

-- | The tab's channel.
class (Monad m) => MonadLive m where
  liveFeed :: m Feed
  default liveFeed :: (MonadTrans t, m ~ t n, MonadLive n) => m Feed
  liveFeed = lift liveFeed

instance (MonadLive m) => MonadLive (HalogenM st act slots output m)

-- | The class's method as a value, given to the shell on a backend that
-- has it.
newtype Live m = Live {liveFeed :: m Feed}

live :: (MonadLive m) => Live m
live = Live {liveFeed}

-- | The state of the feed's connection.
data Channel = Channel
  { socket :: Maybe WS.Socket
  -- ^ The socket, from when it is opened until it closes.
  , connecting :: Bool
  -- ^ Whether a socket is being opened, or will be after a pause; while
  -- it is, nothing else opens one.
  , open :: Bool
  -- ^ Whether it is open, and can send.
  , pages :: Map PageId Int
  -- ^ The watched pages, each with how many views watch it.
  , editing :: Set PageId
  -- ^ The pages this tab edits.
  , listeners :: Int
  -- ^ How many listen for notifications.
  , opened :: Bool
  -- ^ Whether a socket has opened before, since the last restart. A
  -- socket that opens again delivers 'Reopened'.
  , known :: Map PageId [Author]
  -- ^ Who else edits each watched page, as the current socket said.
  , pause :: Int
  -- ^ How long to wait before opening it again, in milliseconds.
  , generation :: Int
  -- ^ Incremented on each restart, so that messages from the socket the
  -- restart closed are not taken for the new one's.
  }

-- | What the backend does with the messages: apply an event to a page's
-- cached threads, replace them with the threads a subscription returned,
-- drop them when they may change unseen, add a notification, and drop the
-- notifications when some may have been missed.
data Keeping = Keeping
  { keep :: PageId -> PageEvent -> IO ()
  , catchUp :: PageId -> [Thread] -> IO ()
  , forget :: PageId -> IO ()
  , notified :: Notification -> IO ()
  , missed :: IO ()
  }

-- | Whether there is anything to keep the socket open for.
wanted :: Channel -> Bool
wanted c = not (null c.pages) || c.listeners > 0

-- | A feed whose socket is at @api\/v1\/events@, relative to the page's
-- @\<base href>@, with what the backend does with the messages: apply an
-- event to a page's cached threads, replace them with a subscription's
-- answer, drop them when they may have changed unseen, add a
-- notification, and drop the notifications when some may have been
-- missed.
newFeed :: (PageId -> PageEvent -> IO ()) -> (PageId -> [Thread] -> IO ()) -> (PageId -> IO ()) -> (Notification -> IO ()) -> IO () -> IO Feed
newFeed keep catchUp forget notified missed
  | not inBrowser = quietFeed
  | otherwise = do
      channel <- HS.create
      held <- newIORef Channel {socket = Nothing, connecting = False, open = False, pages = mempty, editing = mempty, listeners = 0, opened = False, known = mempty, pause = firstPause, generation = 0}
      let keeping = Keeping {keep, catchUp, forget, notified, missed}
      let tell = channel.listener.notify
          watch page = do
            (c, first', start) <- atomicModifyIORef' held $ \c ->
              let start = isNothing c.socket && not c.connecting
                  c' = c {pages = Map.insertWith (+) page 1 c.pages, connecting = c.connecting || start}
               in (c', (c', not (Map.member page c.pages), start))
            when (first' && c.open) (say c (Subscribe page))
            when start (connect held keeping tell)
          unwatch page = do
            gone <- atomicModifyIORef' held $ \c -> case Map.lookup page c.pages of
              Just n | n > 1 -> (c {pages = Map.insert page (n - 1) c.pages}, False)
              Just _ -> (c {pages = Map.delete page c.pages, known = Map.delete page c.known}, True)
              Nothing -> (c, False)
            when gone $ do
              c <- readIORef held
              when c.open (say c (Unsubscribe page))
              -- No longer watched: its cached threads may go stale.
              forget page
          restart = do
            old <- atomicModifyIORef' held $ \c ->
              (c {socket = Nothing, open = False, connecting = wanted c, known = mempty, opened = False, generation = c.generation + 1, pause = firstPause}, c)
            traverse_ WS.close' old.socket
            when (wanted old) (connect held keeping tell)
          listen = do
            start <- atomicModifyIORef' held $ \c ->
              let start = isNothing c.socket && not c.connecting
               in (c {listeners = c.listeners + 1, connecting = c.connecting || start}, start)
            when start (connect held keeping tell)
          unlisten = atomicModifyIORef' held (\c -> (c {listeners = max 0 (c.listeners - 1)}, ()))
          startEditing page = do
            c <- atomicModifyIORef' held (\c -> let c' = c {editing = Set.insert page c.editing} in (c', c))
            when (c.open && not (Set.member page c.editing)) (say c (StartEditing page))
          stopEditing page = do
            c <- atomicModifyIORef' held (\c -> let c' = c {editing = Set.delete page c.editing} in (c', c))
            when (c.open && Set.member page c.editing) (say c (StopEditing page))
          editorsOf page = Map.lookup page . (\c -> c.known) <$> readIORef held
      pure Feed {heard = channel.emitter, watch, unwatch, restart, startEditing, stopEditing, editorsOf, listen, unlisten}

-- | The pause before the socket is opened again, in milliseconds: the first
-- after a socket closed, and the longest it doubles to.
firstPause, longestPause :: Int
firstPause = 1000
longestPause = 30_000

-- | 'jittered' is a pause changed by up to 30 % either way, by a random
-- number: from 70 % of the pause for a number that is 0 modulo 601, to
-- 130 % for one that is 600. The socket waits this long rather than the
-- pause itself, so that the tabs that lost their socket at the same moment
-- do not all open a new one at the same moment. The longest wait is 130 %
-- of 'longestPause', 39 seconds.
jittered :: Word64 -> Int -> Int
jittered random pause = pause + pause * (fromIntegral (random `mod` 601) - 300) `div` 1000

-- | Send a message on the socket, if there is one.
say :: Channel -> ClientMessage -> IO ()
say c message = for_ c.socket $ \s -> void (WS.send s (WS.TextMessage (decodeUtf8 (toS (encode message)))))

-- | Open the socket, and listen to it.
connect :: IORef Channel -> Keeping -> (Heard -> IO ()) -> IO ()
connect held keeping tell = do
  generation <- (\c -> c.generation) <$> readIORef held
  let current = (\c -> c.generation == generation) <$> readIORef held
      watched page = Map.member page . (\c -> c.pages) <$> readIORef held
      heardEditors page editors = atomicModifyIORef' held (\c -> (c {known = Map.insert page editors c.known}, ()))
  WS.open eventsPath [] >>= \case
    -- Refused at once (the address is not a WebSocket's): no socket, and
    -- no point in trying again.
    Left _ -> atomicModifyIORef' held (\c -> (c {connecting = False}, ()))
    Right socket -> do
      atomicModifyIORef' held (\c -> (c {socket = Just socket, connecting = False}, ()))
      void . (WS.opened socket).registerHandler $ \() -> whenM current $ do
        (c, again) <- atomicModifyIORef' held (\c -> let c' = c {open = True, opened = True, pause = firstPause} in (c', (c', c.opened)))
        for_ (Map.keys c.pages) (say c . Subscribe)
        -- On a new connection, the server knows nothing of what this tab
        -- edits.
        for_ (Set.toList c.editing) (say c . StartEditing)
        -- Notifications made while it was closed were delivered to nobody.
        when again $ do
          keeping.missed
          tell Reopened
      void . (WS.messages socket).registerHandler $ \case
        WS.TextMessage text -> whenM current $ case decodeStrict' (encodeUtf8 text) of
          Just (Event page event) -> whenM (watched page) $ do
            case event of
              Editing editors -> heardEditors page editors
              _ -> pass
            keeping.keep page event
            tell (Heard page event)
          -- An answer about a page no longer watched since it was asked
          -- for is dropped. Who else edits the page is delivered after the
          -- threads, as the event that says it.
          Just (Subscribed page threads editors) -> whenM (watched page) $ do
            keeping.catchUp page threads
            heardEditors page editors
            tell (Replaced page threads)
            tell (Heard page (Editing editors))
          Just (Notified n) -> do
            keeping.notified n
            tell (Notice n)
          _ -> pass
        WS.BinaryMessage _ -> pass
      void . (WS.closed socket).registerHandler $ \_ -> whenM current $ do
        -- Opened again after a pause, if anything is watched; otherwise
        -- when something is.
        c <- atomicModifyIORef' held $ \c ->
          (c {socket = Nothing, open = False, connecting = wanted c, known = mempty, pause = min longestPause (c.pause * 2)}, c)
        -- Changes from now on go unseen.
        traverse_ keeping.forget (Map.keys c.pages)
        when (wanted c) . void . forkIO $ do
          -- The random number comes from a random UUID, which the
          -- browser's own generator makes.
          random <- fst . toWords64 <$> generateV4
          threadDelay (jittered random c.pause * 1000)
          whenM current (connect held keeping tell)
