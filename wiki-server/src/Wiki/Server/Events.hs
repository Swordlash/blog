-- | The live channel (decision 23 of docs/PLAN.md, "Wiki.Api.Events"):
-- every browser tab keeps one WebSocket to the server, at @api\/v1\/events@,
-- on which it subscribes to the pages it shows, and is told what happens
-- to their comments as it happens.
--
-- = Who listens
--
-- The connection is the request's: who is asking is found as for any
-- request, from the session cookie the upgrade carries
-- ("Wiki.Server.App"'s 'Wiki.Server.App.findCaller'), and a closed wiki
-- has refused someone not signed in with a 401 before it gets here. A
-- connection keeps who it was made as: a tab that signs in or out opens
-- another. A page is subscribed to only if that someone may read it, which
-- is checked when they subscribe ('Refused' otherwise) and again before
-- each event is sent, since a grant may have been taken away since.
--
-- The answer to a subscription carries the page's threads, read as that
-- someone may read them, and the subscription is made in the same hold of
-- the storage's connection as that read: writes publish while they hold it
-- too, so every change committed after the read is told after the answer,
-- and none committed before it is told as new. A tab that shows the
-- answer's threads and folds in what it is told then misses nothing.
--
-- An upgrade that a page of another site asked for is refused: the
-- session cookie is @SameSite=Strict@, so a browser does not send it with
-- such a request anyway, but a WebSocket is not bound by the same-origin
-- policy, and its @Origin@ header is checked as a second lock.
--
-- = What they hear
--
-- The storage tells the 'Hub' of every change to a page's comments once it
-- is committed ('publish', which "Wiki.Server.Storage"'s @Config@ calls),
-- and the hub hands it to every connection subscribed to the page, without
-- waiting: each connection has a queue, and a thread of its own that sends
-- what is in it. A connection whose queue fills up (a tab that does not
-- read) is closed rather than waited for: the tab connects again and
-- subscribes again, and the answers carry what it shows afresh, as after
-- any lost connection, so a lost event costs nothing.
--
-- The subscriptions are kept in memory, for the one process the server
-- is. Pings every 20 seconds keep a quiet connection from being taken for
-- a dead one, by Warp (which drops a connection idle for 30) or a proxy.
module Wiki.Server.Events
  ( Hub
  , newHub
  , publish
  , closeAll
  , eventsApplication
  )
where

import Control.Concurrent.STM (TBQueue, TVar, isFullTBQueue, modifyTVar', newTBQueueIO, newTVarIO, readTBQueue, readTVar, readTVarIO, writeTBQueue, writeTVar)
import Data.Aeson (decode, encode)
import Data.ByteString.Char8 qualified as BS8
import Data.CaseInsensitive qualified as CI
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Network.HTTP.Types (hContentType, status403, status426)
import Network.Wai (Application, Request (..), responseLBS)
import Network.Wai.Handler.WebSockets (websocketsApp)
import Network.WebSockets qualified as WS
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (ClientMessage (..), PageEvent, ServerMessage (..))
import Wiki.Core.Id (PageId)
import Wiki.Server.Storage (Storage, Who, mayReadPage, threadsThen)

-- | Every connection open, and what each is subscribed to.
data Hub = Hub
  { connections :: TVar (Map Int Connection)
  , next :: TVar Int
  , closing :: TVar Bool
  -- ^ Set when the server stops: no connection is taken any more.
  }

-- | A connection, as the hub sees it.
data Connection = Connection
  { pages :: TVar (Set PageId)
  , outbox :: TBQueue Outgoing
  , behind :: TVar Bool
  -- ^ Set when its outbox was full: the connection is closed.
  }

-- | Put something in a connection's outbox, or, if it is full, mark the
-- connection as behind.
enqueue :: Connection -> Outgoing -> STM ()
enqueue c message = do
  full <- isFullTBQueue c.outbox
  if full then writeTVar c.behind True else writeTBQueue c.outbox message

-- | What a connection's sending thread has to do.
data Outgoing
  = -- | Say this.
    Say ServerMessage
  | -- | Tell of this, if the page is still subscribed to and may still be
    -- read.
    Tell PageId PageEvent
  | -- | Close the connection: the server is stopping, or the tab is behind.
    Hangup Text

-- | A hub with nobody connected.
newHub :: IO Hub
newHub = Hub <$> newTVarIO mempty <*> newTVarIO 0 <*> newTVarIO False

-- | How many messages a connection may have waiting before it is taken to
-- be behind, and closed.
outboxSize :: Natural
outboxSize = 256

-- | Tell every connection subscribed to a page of something that happened
-- to it. It never waits: called while the storage holds its connection.
publish :: Hub -> PageId -> PageEvent -> IO ()
publish hub page event = atomically $ do
  connections <- readTVar hub.connections
  for_ connections $ \c -> do
    subscribed <- Set.member page <$> readTVar c.pages
    when subscribed $ enqueue c (Tell page event)

-- | Close every connection, and take no more: the server is stopping, and
-- would otherwise wait for them (Warp waits ten seconds for the
-- connections it has).
closeAll :: Hub -> IO ()
closeAll hub = atomically $ do
  writeTVar hub.closing True
  readTVar hub.connections >>= traverse_ (\c -> writeTVar c.behind True)

-- | The channel at its address, for someone: the WebSocket, or a refusal of
-- a request that is no WebSocket's (426) or is another site's (403).
eventsApplication :: Storage -> Hub -> Who -> Application
eventsApplication storage hub who request respond
  | not sameSite = respond (responseLBS status403 [(hContentType, "application/json")] (encode ApiError.Forbidden))
  | otherwise = case websocketsApp WS.defaultConnectionOptions (serve storage hub who) request of
      Just upgrade -> respond upgrade
      Nothing ->
        respond (responseLBS status426 [(hContentType, "application/json"), ("Upgrade", "websocket")] (encode (ApiError.Invalid "This address is a WebSocket's.")))
  where
    headerOf name = lookup (CI.mk name) (requestHeaders request)
    -- The Origin a browser sends, which must be this server's address as
    -- the browser asked for it (the Host, or what a proxy in front says it
    -- was); a client that sends none is no page's.
    sameSite = case headerOf "Origin" of
      Nothing -> True
      Just origin ->
        let authority = BS8.drop 2 (snd (BS8.breakSubstring "//" origin))
         in Just authority `elem` [headerOf "Host", headerOf "X-Forwarded-Host"]

-- | One connection, from the upgrade to its end.
serve :: Storage -> Hub -> Who -> WS.PendingConnection -> IO ()
serve storage hub who pending = do
  stopping <- readTVarIO hub.closing
  if stopping
    then WS.rejectRequest pending "The server is stopping."
    else do
      socket <- WS.acceptRequest pending
      pages <- newTVarIO mempty
      outbox <- newTBQueueIO outboxSize
      behind <- newTVarIO False
      let connection = Connection {pages, outbox, behind}
      key <- atomically $ do
        k <- readTVar hub.next
        writeTVar hub.next (k + 1)
        modifyTVar' hub.connections (Map.insert k connection)
        pure k
      let leave = atomically (modifyTVar' hub.connections (Map.delete key))
      flip finally leave . WS.withPingThread socket 20 pass $
        race_ (sending socket connection) (receiving socket connection)
          `catch` \(_ :: WS.ConnectionException) -> pass
  where
    may page = mayReadPage storage who page

    -- What the tab asks for: subscriptions, each checked and answered.
    receiving socket connection = forever $ do
      message <- WS.receiveData socket
      case decode message of
        -- Answered with the page's threads, read as the connection's user
        -- may, and subscribed before the storage lets anything else write:
        -- every change committed after that read is told after the answer.
        Just (Subscribe page) -> do
          read' <- threadsThen storage who page $ \threads -> atomically $ do
            modifyTVar' connection.pages (Set.insert page)
            enqueue connection (Say (Subscribed page threads))
          when (isLeft read') $ atomically $ do
            modifyTVar' connection.pages (Set.delete page)
            enqueue connection (Say (Refused page))
        Just (Unsubscribe page) -> atomically (modifyTVar' connection.pages (Set.delete page))
        -- Something else, from a newer tab or none: nothing to do.
        Nothing -> pass

    -- What there is to say, in order; a tab that fell behind, or a server
    -- that is stopping, closes the connection, for the tab to connect again.
    sending socket connection = do
      next <- atomically $ do
        behind <- readTVar connection.behind
        if behind then pure (Hangup "Connect again.") else readTBQueue connection.outbox
      case next of
        Say message -> WS.sendTextData socket (encode message) >> sending socket connection
        Tell page event -> do
          subscribed <- Set.member page <$> readTVarIO connection.pages
          allowed <- if subscribed then may page else pure False
          when allowed $ WS.sendTextData socket (encode (Event page event))
          sending socket connection
        -- The tab's close comes to the receiving thread, which ends the
        -- connection; this one has nothing more to say.
        Hangup why -> WS.sendClose socket why >> forever (threadDelay maxBound)
