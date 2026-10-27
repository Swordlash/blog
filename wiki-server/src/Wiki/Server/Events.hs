-- | The server's side of the live channel (decision 23 of docs/PLAN.md,
-- "Wiki.Api.Events"). Every browser tab keeps one WebSocket to the server,
-- at @api\/v1\/events@, on which it subscribes to the pages it shows, and
-- receives changes to their comments as they happen.
--
-- = Who listens
--
-- The connection belongs to the request: who is asking is found as for any
-- request, from the session cookie the upgrade request carries
-- ("Wiki.Server.App"'s 'Wiki.Server.App.findCaller'), and a closed wiki
-- has already refused someone not signed in with a 401 before this point.
-- A connection keeps the user it was opened as: a tab that signs in or out
-- opens another. A page is subscribed to only if that user may read it.
-- That is checked when they subscribe ('Refused' otherwise), and again
-- before each event is sent, since a grant may have been removed since.
--
-- The answer to a subscription carries the page's threads, read as that
-- user may read them. The subscription is made while the storage's
-- connection is held for that read, and writes publish their events while
-- they hold it too. So every change committed after the read is sent after
-- the answer, and none committed before it is sent as new. A tab that
-- shows the answer's threads and applies the events it receives then
-- misses nothing.
--
-- An upgrade request made by another site's page is refused. The session
-- cookie is @SameSite=Strict@, so a browser does not send it with such a
-- request anyway, but a WebSocket is not bound by the same-origin policy,
-- so its @Origin@ header is checked as a second safeguard.
--
-- = What they receive
--
-- The storage tells the 'Hub' of every change to a page's comments once
-- it is committed ('publish', which "Wiki.Server.Storage"'s @Config@
-- calls). The hub passes it to every connection subscribed to the page,
-- without waiting: each connection has a queue, and its own thread that
-- sends what is in it. A connection whose queue fills up (a tab that does
-- not read) is closed rather than waited for. The tab reconnects and
-- subscribes again, and the answers carry the current state, as after any
-- lost connection, so a lost event costs nothing.
--
-- = Who edits
--
-- A tab that opens a page's editor announces it, and announces when it
-- closes it (WP4.12 of docs/PLAN.md). The hub records that per connection
-- ("Wiki.Server.Presence"), only from someone who may edit the page, and
-- drops it when the connection closes. Each time the set of people editing
-- a page changes, every connection subscribed to it is told who else is
-- editing it ('Editing'), and the answer to a subscription says who is
-- editing at that moment. The storage also tells the hub of every save of
-- a page ('PageChanged'), as it does for comments.
--
-- = Notifications
--
-- The storage also tells the hub of every notification a write made
-- ("Wiki.Core.Notification", WP4.13 of docs/PLAN.md), once it is committed
-- ('notify'). The hub passes each to every connection of the user it is
-- for, whatever they are subscribed to: a tab receives its user's
-- notifications as long as it is connected. The storage made the
-- notification only if they may read its page, a moment ago, so it is not
-- checked again. A notification missed while a tab was disconnected is in
-- the list the tab fetches when it reconnects.
--
-- The subscriptions are kept in memory, since the server is one process.
-- A ping every 20 seconds keeps a quiet connection from being taken for a
-- dead one, by Warp (which drops a connection idle for 30 seconds) or by a
-- proxy.
module Wiki.Server.Events
  ( Hub
  , newHub
  , publish
  , notify
  , closeAll
  , openConnections
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
import Wiki.Api.Events (ClientMessage (..), PageEvent (..), ServerMessage (..))
import Wiki.Core.Id (PageId, UserId)
import Wiki.Core.Notification (Notification)
import Wiki.Server.Presence (Key, Presence, editorsFor, leave, nobodyEditing, startEditing, stopEditing)
import Wiki.Server.Storage (Storage, Who (..), editorOf, mayReadPage, threadsThen)

-- | 'Hub': every open connection, what each is subscribed to, and what
-- each is editing.
data Hub = Hub
  { connections :: TVar (Map Key Connection)
  , presence :: TVar Presence
  -- ^ Who is editing which page, by connection.
  , next :: TVar Key
  , closing :: TVar Bool
  -- ^ Set when the server stops: no new connection is accepted.
  }

-- | A connection, as the hub sees it.
data Connection = Connection
  { user :: Maybe UserId
  -- ^ The user it was opened as, if any.
  , pages :: TVar (Set PageId)
  , outbox :: TBQueue Outgoing
  , behind :: TVar Bool
  -- ^ Set when its outbox was full: the connection is then closed.
  }

-- | Put a message in a connection's outbox, or, if it is full, mark the
-- connection as behind.
enqueue :: Connection -> Outgoing -> STM ()
enqueue c message = do
  full <- isFullTBQueue c.outbox
  if full then writeTVar c.behind True else writeTBQueue c.outbox message

-- | How many connections are open, which the server's status and metrics
-- report for the live channel.
openConnections :: Hub -> IO Int
openConnections hub = Map.size <$> readTVarIO hub.connections

-- | What a connection's sending thread has to do.
data Outgoing
  = -- | Send this message.
    Say ServerMessage
  | -- | Send this event, if the page is still subscribed to and may still
    -- be read.
    Tell PageId PageEvent
  | -- | Close the connection: the server is stopping, or the tab is behind.
    Hangup Text

-- | A hub with nobody connected.
newHub :: IO Hub
newHub = Hub <$> newTVarIO mempty <*> newTVarIO nobodyEditing <*> newTVarIO 0 <*> newTVarIO False

-- | How many messages may wait in a connection's outbox before it counts
-- as behind, and is closed.
outboxSize :: Natural
outboxSize = 256

-- | Send an event on a page to every connection subscribed to it. It never
-- waits: it is called while the storage holds its connection.
publish :: Hub -> PageId -> PageEvent -> IO ()
publish hub page event = atomically $ do
  connections <- readTVar hub.connections
  for_ connections $ \c -> do
    subscribed <- Set.member page <$> readTVar c.pages
    when subscribed $ enqueue c (Tell page event)

-- | Send each user's notification to every connection of that user. It
-- never waits: it is called while the storage holds its connection.
notify :: Hub -> [(UserId, Notification)] -> IO ()
notify hub told = atomically $ do
  connections <- readTVar hub.connections
  for_ connections $ \c ->
    for_ c.user $ \u ->
      for_ [n | (v, n) <- told, v == u] $ \n -> enqueue c (Say (Notified n))

-- | Tell every connection subscribed to a page who else is editing it, as
-- the presence now says, in the transaction that changed it.
tellEditors :: Hub -> PageId -> STM ()
tellEditors hub page = do
  connections <- readTVar hub.connections
  now <- readTVar hub.presence
  for_ (Map.toList connections) $ \(k, c) -> do
    subscribed <- Set.member page <$> readTVar c.pages
    when subscribed $ enqueue c (Tell page (Editing (editorsFor k page now)))

-- | Change the presence, and if that changed who is editing a page, tell
-- its subscribers.
changePresence :: Hub -> PageId -> (Presence -> (Presence, Bool)) -> STM ()
changePresence hub page change = do
  (now, changed) <- change <$> readTVar hub.presence
  writeTVar hub.presence now
  when changed (tellEditors hub page)

-- | Close every connection, and accept no more: the server is stopping,
-- and would otherwise wait for them (Warp waits ten seconds for its
-- connections).
closeAll :: Hub -> IO ()
closeAll hub = atomically $ do
  writeTVar hub.closing True
  readTVar hub.connections >>= traverse_ (\c -> writeTVar c.behind True)

-- | The channel at its address, for a 'Who': the WebSocket, or a refusal
-- of a request that is not a WebSocket upgrade (426) or comes from another
-- site (403).
eventsApplication :: Storage -> Hub -> Who -> Application
eventsApplication storage hub who request respond
  | not sameSite = respond (responseLBS status403 [(hContentType, "application/json")] (encode ApiError.Forbidden))
  | otherwise = case websocketsApp WS.defaultConnectionOptions (serve storage hub who) request of
      Just upgrade -> respond upgrade
      Nothing ->
        respond (responseLBS status426 [(hContentType, "application/json"), ("Upgrade", "websocket")] (encode (ApiError.Invalid "This address is a WebSocket's.")))
  where
    headerOf name = lookup (CI.mk name) (requestHeaders request)
    -- The Origin a browser sends must be this server's address as the
    -- browser requested it (the Host, or what a proxy in front says it
    -- was); a client that sends none is not a page.
    sameSite = case headerOf "Origin" of
      Nothing -> True
      Just origin ->
        let authority = BS8.drop 2 (snd (BS8.breakSubstring "//" origin))
         in Just authority `elem` [headerOf "Host", headerOf "X-Forwarded-Host"]

-- | One connection, from the upgrade until it ends.
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
      let connection = Connection {user = case who of AsUser u -> Just u; _ -> Nothing, pages, outbox, behind}
      key <- atomically $ do
        k <- readTVar hub.next
        writeTVar hub.next (k + 1)
        modifyTVar' hub.connections (Map.insert k connection)
        pure k
      -- Closed: it edits nothing any more, which the subscribers of the
      -- pages it edited are told.
      let gone = atomically $ do
            modifyTVar' hub.connections (Map.delete key)
            (now, edited) <- leave key <$> readTVar hub.presence
            writeTVar hub.presence now
            traverse_ (tellEditors hub) edited
      flip finally gone . WS.withPingThread socket 20 pass $
        race_ (sending socket connection) (receiving key socket connection)
          `catch` \(_ :: WS.ConnectionException) -> pass
  where
    may page = mayReadPage storage who page

    -- The tab's requests: subscriptions, each checked and answered.
    receiving key socket connection = forever $ do
      message <- WS.receiveData socket
      case decode message of
        -- Answered with the page's threads, read as the connection's user
        -- may read them, and subscribed before the storage lets anything
        -- else write: every change committed after that read is sent after
        -- the answer. Who else is editing the page is included, read in the
        -- same transaction as the subscription is made, so that every
        -- change to it after the answer is sent after it.
        Just (Subscribe page) -> do
          read' <- threadsThen storage who page $ \threads -> atomically $ do
            modifyTVar' connection.pages (Set.insert page)
            editors <- editorsFor key page <$> readTVar hub.presence
            enqueue connection (Say (Subscribed page threads editors))
          when (isLeft read') $ atomically $ do
            modifyTVar' connection.pages (Set.delete page)
            enqueue connection (Say (Refused page))
        Just (Unsubscribe page) -> atomically (modifyTVar' connection.pages (Set.delete page))
        -- Accepted from someone who may edit the page, named as the
        -- storage names them; from anyone else, ignored.
        Just (StartEditing page) ->
          editorOf storage who page >>= traverse_ (\author -> atomically (changePresence hub page (startEditing key page author)))
        Just (StopEditing page) -> atomically (changePresence hub page (stopEditing key page))
        -- Anything else, from a newer tab or none: ignored.
        Nothing -> pass

    -- Send the queued messages, in order. A tab that fell behind, or a
    -- stopping server, closes the connection, for the tab to reconnect.
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
        -- The tab's close reaches the receiving thread, which ends the
        -- connection; this thread has nothing more to send.
        Hangup why -> WS.sendClose socket why >> forever (threadDelay maxBound)
