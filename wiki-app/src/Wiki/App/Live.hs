-- | The live channel, as the application sees it (decision 23 of
-- docs/PLAN.md, "Wiki.Api.Events"): one WebSocket per tab to the server,
-- on which the page view says which page it shows and hears what happens
-- to that page's comments as it happens.
--
-- A capability of its own, 'MonadLive', which only the backend over HTTP
-- has ("Wiki.App.Backend.Http"), as 'Wiki.App.Account.MonadAccount' is:
-- the demo keeps its wiki in the tab, where nobody else writes. The shell
-- is handed it as a value ('Live', through its input) when there is one,
-- asks it for the tab's 'Feed' once, and hands the feed to the page view,
-- which watches its page while it shows it.
--
-- = The feed
--
-- The socket is opened lazily, when a page is first watched, and kept for
-- the tab's life. A page watched is subscribed to as soon as the socket is
-- open, and again whenever it opens anew; a page no longer watched is
-- unsubscribed from. What the server says of a page is told to whoever
-- listens ('heard'), and handed to the backend first, which keeps the
-- page's threads up to date with it.
--
-- The server answers a subscription with the page's threads as they are
-- then, and tells of every change after them ("Wiki.Api.Events"): the
-- answer replaces the threads the page view shows and the backend keeps
-- ('Replaced'), and the events are folded into them ('Heard'). So what
-- happened between the page's first read (with the page, or in the HTML
-- it was served in) and its subscription is caught up with, without a
-- request of the tab's own: a page adopted from the server's HTML still
-- asks for nothing.
--
-- When the socket closes (the server went away, the network did, or the
-- server closed it), it is opened again after a pause that doubles from
-- one second to half a minute, and is one second again once a socket has
-- opened. Nothing is replayed: the pages watched are subscribed to again,
-- and the answers are what was missed meanwhile, so a lost event costs
-- nothing. The backend lets go of the threads of every page watched while
-- the socket is closed, so that a page shown then reads the server's.
--
-- A socket is opened as whoever the browser's cookie says, and stays so:
-- signing in or out 'restart's it.
--
-- Natively there is no WebSocket ("Halogen.Net.WebSocket" gives one that
-- never connects), and a feed does nothing: the server renders its pages
-- with a backend over HTTP, whose page views watch their pages too.
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
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Aeson (decodeStrict', encode)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Type.Equality (type (~))
import Halogen.JSBits (inBrowser)
import Halogen.Net.WebSocket qualified as WS
import Halogen.Query.HalogenM (HalogenM)
import Halogen.Subscription (Emitter (..), Listener (..))
import Halogen.Subscription qualified as HS
import Protolude
import Wiki.Api.Events (ClientMessage (..), PageEvent, ServerMessage (..), eventsPath)
import Wiki.Core.Comment (Thread)
import Wiki.Core.Id (PageId)

-- | What the tab hears.
data Heard
  = -- | Something happened to a page it watches.
    Heard PageId PageEvent
  | -- | A page it watches has these threads: the answer to its
    -- subscription, which what it showed is replaced with.
    Replaced PageId [Thread]
  deriving stock (Eq, Show)

-- | The tab's live channel.
data Feed = Feed
  { heard :: Emitter IO Heard
  -- ^ What it hears, for 'Halogen.subscribe'.
  , watch :: PageId -> IO ()
  -- ^ Listen for what happens to a page, as long as it is shown. Each
  -- 'watch' is ended by an 'unwatch'.
  , unwatch :: PageId -> IO ()
  , restart :: IO ()
  -- ^ Open the socket again, as whoever the cookie now says.
  }

-- | A feed that hears nothing: what there is natively, and for a backend
-- with no channel.
quietFeed :: IO Feed
quietFeed = do
  channel <- HS.create
  pure Feed {heard = channel.emitter, watch = \_ -> pass, unwatch = \_ -> pass, restart = pass}

-- | The tab's channel.
class (Monad m) => MonadLive m where
  liveFeed :: m Feed
  default liveFeed :: (MonadTrans t, m ~ t n, MonadLive n) => m Feed
  liveFeed = lift liveFeed

instance (MonadLive m) => MonadLive (HalogenM st act slots output m)

-- | The class's method as a value, handed to the shell over a backend that
-- has it.
newtype Live m = Live {liveFeed :: m Feed}

live :: (MonadLive m) => Live m
live = Live {liveFeed}

-- | Where the feed is.
data Channel = Channel
  { socket :: Maybe WS.Socket
  -- ^ The socket, from when it is opened until it closes.
  , connecting :: Bool
  -- ^ Whether a socket is being opened, or will be after a pause: then
  -- nothing else opens one.
  , open :: Bool
  -- ^ Whether it is open, and can send.
  , pages :: Map PageId Int
  -- ^ The pages watched, each with how many watch it.
  , pause :: Int
  -- ^ How long to wait before opening it again, in milliseconds.
  , generation :: Int
  -- ^ Counted up when it is restarted, so that what the socket it closed
  -- says afterwards is not taken for the new one's.
  }

-- | What the backend does with what is heard of a page: keep its threads
-- up to date with an event, take the threads the server answered a
-- subscription with, and let them go when they may change unheard.
data Keeping = Keeping
  { keep :: PageId -> PageEvent -> IO ()
  , catchUp :: PageId -> [Thread] -> IO ()
  , forget :: PageId -> IO ()
  }

-- | A feed whose socket is at @api\/v1\/events@, relative to the page's
-- @\<base href>@, with what the backend does with what is heard: keep a
-- page's threads up to date with an event, replace them with a
-- subscription's answer, and let them go when they may have changed
-- unheard.
newFeed :: (PageId -> PageEvent -> IO ()) -> (PageId -> [Thread] -> IO ()) -> (PageId -> IO ()) -> IO Feed
newFeed keep catchUp forget
  | not inBrowser = quietFeed
  | otherwise = do
      channel <- HS.create
      held <- newIORef Channel {socket = Nothing, connecting = False, open = False, pages = mempty, pause = firstPause, generation = 0}
      let keeping = Keeping {keep, catchUp, forget}
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
              Just _ -> (c {pages = Map.delete page c.pages}, True)
              Nothing -> (c, False)
            when gone $ do
              c <- readIORef held
              when c.open (say c (Unsubscribe page))
              -- Not heard of any more: what is kept of it may go stale.
              forget page
          restart = do
            old <- atomicModifyIORef' held $ \c ->
              (c {socket = Nothing, open = False, connecting = not (null c.pages), generation = c.generation + 1, pause = firstPause}, c)
            traverse_ WS.close' old.socket
            unless (null old.pages) (connect held keeping tell)
      pure Feed {heard = channel.emitter, watch, unwatch, restart}

firstPause, longestPause :: Int
firstPause = 1000
longestPause = 30_000

-- | Send a message on the socket, if there is one.
say :: Channel -> ClientMessage -> IO ()
say c message = for_ c.socket $ \s -> void (WS.send s (WS.TextMessage (decodeUtf8 (toS (encode message)))))

-- | Open the socket, and listen to it.
connect :: IORef Channel -> Keeping -> (Heard -> IO ()) -> IO ()
connect held keeping tell = do
  generation <- (\c -> c.generation) <$> readIORef held
  let current = (\c -> c.generation == generation) <$> readIORef held
      watched page = Map.member page . (\c -> c.pages) <$> readIORef held
  WS.open eventsPath [] >>= \case
    -- Refused on the spot (the address is no WebSocket's): no socket,
    -- and no point in trying again.
    Left _ -> atomicModifyIORef' held (\c -> (c {connecting = False}, ()))
    Right socket -> do
      atomicModifyIORef' held (\c -> (c {socket = Just socket, connecting = False}, ()))
      void . (WS.opened socket).registerHandler $ \() -> whenM current $ do
        c <- atomicModifyIORef' held (\c -> let c' = c {open = True, pause = firstPause} in (c', c'))
        for_ (Map.keys c.pages) (say c . Subscribe)
      void . (WS.messages socket).registerHandler $ \case
        WS.TextMessage text -> whenM current $ case decodeStrict' (encodeUtf8 text) of
          Just (Event page event) -> whenM (watched page) $ do
            keeping.keep page event
            tell (Heard page event)
          -- An answer about a page unwatched since it was asked for is no
          -- longer anyone's.
          Just (Subscribed page threads) -> whenM (watched page) $ do
            keeping.catchUp page threads
            tell (Replaced page threads)
          _ -> pass
        WS.BinaryMessage _ -> pass
      void . (WS.closed socket).registerHandler $ \_ -> whenM current $ do
        -- Opened again after a pause, if anything is watched; otherwise
        -- when something is.
        c <- atomicModifyIORef' held $ \c ->
          (c {socket = Nothing, open = False, connecting = not (null c.pages), pause = min longestPause (c.pause * 2)}, c)
        -- What changes now goes unheard.
        traverse_ keeping.forget (Map.keys c.pages)
        unless (null c.pages) . void . forkIO $ do
          threadDelay (c.pause * 1000)
          whenM current (connect held keeping tell)
