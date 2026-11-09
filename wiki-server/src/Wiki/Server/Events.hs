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
-- That is checked when they subscribe ('Refused' otherwise).
--
-- = Checked again
--
-- A grant may be removed after a subscription, so the user may be checked
-- again before an event is sent. A change to a page's comments and a save
-- ('PageChanged') carry what the page says, and are checked before each
-- one is sent. Who reads and who edits the page ('Reading', 'Editing')
-- carry no content and change often on a busy page, so they are not
-- checked each time (WP5.76 of docs/PLAN.md). Each subscription keeps the
-- hub's 'epoch' at its last passed check. The storage tells the hub when
-- who may read which page may have changed: a grant, a revocation, a
-- group's members, a user, a space, a page moved, the wiki's settings
-- ("Wiki.Server.Storage"'s @Config@ @permissionsChanged@). The hub then
-- counts a new epoch, and asks every connection to check each page it is
-- subscribed to again ('Recheck'). A presence update goes without a check
-- to a subscription checked in the current epoch, and is checked first
-- otherwise. A subscription that fails a check, of any kind, is dropped:
-- the tab is told 'Refused', and stops being counted among the page's
-- readers and editors.
--
-- A check is made once for each user an event goes to, however many of
-- their tabs show the page ('Check'), and on one of the storage's readers,
-- so it waits for no write.
--
-- The answer to a subscription carries the page's threads, read as that
-- user may read them. The subscription is made while the storage's writer
-- is held for that read, and writes publish their events while they hold
-- the writer too. So every change committed after the read is sent after
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
-- = Who reads
--
-- A connection subscribed to a page is reading it (WP5.55 of
-- docs/PLAN.md), as the user it was opened as ('authorOf', read with the
-- subscription's threads), or as a visitor for a connection of someone not
-- signed in. The server's operator is neither, and is not counted. The
-- hub records it per connection in the presence too, and each time a
-- page's readers change (a subscription, an unsubscription, a connection
-- that closes), every connection subscribed to the page is told who else
-- reads it ('Reading', "Wiki.Server.Presence"'s 'readersFor'), and the
-- answer to a subscription says who reads it at that moment.
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
  , permissionsChanged
  , closeAll
  , openConnections
  , eventsApplication
  )
where

import Control.Concurrent.STM (TBQueue, TVar, isFullTBQueue, modifyTVar', newTBQueueIO, newTVar, newTVarIO, readTBQueue, readTVar, readTVarIO, writeTBQueue, writeTVar)
import Data.Aeson (decode, encode)
import Data.ByteString.Char8 qualified as BS8
import Data.CaseInsensitive qualified as CI
import Data.List (lookup)
import Data.Map.Strict qualified as Map
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
import Wiki.Server.Presence (Key, PageReader (..), Presence, editorsFor, leave, leaveReading, nobodyEditing, readersFor, startEditing, startReading, stopEditing, stopReading)
import Wiki.Server.Storage (Storage, Who (..), editorOf, mayReadPage, threadsThen)

-- | 'Hub': every open connection, what each is subscribed to, and what
-- each is editing.
data Hub = Hub
  { connections :: TVar (Map Key Connection)
  , presence :: TVar Presence
  -- ^ Who is editing and reading which page, by connection.
  , epoch :: TVar Epoch
  -- ^ How many times the storage has said that who may read which page
  -- may have changed ('permissionsChanged'). A subscription checked in an
  -- earlier epoch is checked again before a presence update is sent.
  , next :: TVar Key
  , closing :: TVar Bool
  -- ^ Set when the server stops: no new connection is accepted.
  }

-- | A connection, as the hub sees it.
data Connection = Connection
  { who :: Who
  -- ^ Who it was opened as.
  , pages :: TVar (Map PageId Epoch)
  -- ^ The pages it is subscribed to, each with the epoch its last passed
  -- check began in.
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

-- | 'Epoch' counts the changes of who may read which page that the hub
-- has been told of ('permissionsChanged').
type Epoch = Word64

-- | What a connection's sending thread has to do.
data Outgoing
  = -- | Send this message.
    Say ServerMessage
  | -- | Send this event, if the page is still subscribed to and may still
    -- be read. The 'Check' answers whether it may be read, when it has to
    -- be asked ('mustCheck').
    Tell PageId PageEvent Check
  | -- | Check again whether the page may be read, if it has not been in
    -- this epoch, and drop the subscription if not.
    Recheck PageId Check
  | -- | Close the connection: the server is stopping, or the tab is behind.
    Hangup Text

-- | A hub with nobody connected.
newHub :: IO Hub
newHub = Hub <$> newTVarIO mempty <*> newTVarIO nobodyEditing <*> newTVarIO 0 <*> newTVarIO 0 <*> newTVarIO False

-- | How many messages may wait in a connection's outbox before it counts
-- as behind, and is closed.
outboxSize :: Natural
outboxSize = 256

-- | Send an event on a page to every connection subscribed to it. It never
-- waits: it is called while the storage holds its writer.
publish :: Hub -> PageId -> PageEvent -> IO ()
publish hub page event = atomically $ do
  connections <- readTVar hub.connections
  tellSubscribers page (Map.toList connections) (const event)

-- | Put an event on a page in the outbox of every connection subscribed to
-- the page. The event for a connection may depend on its key. All the
-- connections opened as one 'Who' share one 'Check' of whether that 'Who'
-- may read the page.
tellSubscribers :: PageId -> [(Key, Connection)] -> (Key -> PageEvent) -> STM ()
tellSubscribers page connections eventFor = foldM_ tell mempty connections
  where
    tell :: Map Who Check -> (Key, Connection) -> STM (Map Who Check)
    tell checks (k, c) = do
      subscribed <- Map.member page <$> readTVar c.pages
      if not subscribed
        then pure checks
        else do
          shared <- maybe (newTVar Unasked) pure (Map.lookup c.who checks)
          enqueue c (Tell page (eventFor k) shared)
          pure (Map.insert c.who shared checks)

-- | Tell the hub that who may read which page may have changed: the
-- storage calls it once such a change is committed ("Wiki.Server.Storage"'s
-- @Config@). A new epoch begins, and every connection is asked to check
-- each page it is subscribed to again ('Recheck'), sharing one 'Check'
-- for each user and page. A check that fails drops the subscription, so
-- someone who may no longer read a page stops being told and counted at
-- once, not at the page's next event. It never waits.
permissionsChanged :: Hub -> IO ()
permissionsChanged hub = atomically $ do
  modifyTVar' hub.epoch (+ 1)
  connections <- readTVar hub.connections
  foldM_ recheck mempty connections
  where
    recheck :: Map (Who, PageId) Check -> Connection -> STM (Map (Who, PageId) Check)
    recheck checks c = do
      subscribed <- Map.keys <$> readTVar c.pages
      foldM
        ( \held page -> do
            shared <- maybe (newTVar Unasked) pure (Map.lookup (c.who, page) held)
            enqueue c (Recheck page shared)
            pure (Map.insert (c.who, page) shared held)
        )
        checks
        subscribed

-- | What a check did to a subscription: it passed, it failed and the
-- subscription was dropped, or it failed for a subscription that had gone
-- (or was made again after the check began) and nothing was dropped.
data Checked = Passed | Dropped | Failed
  deriving stock (Eq)

-- | Whether an event has to be checked before it is sent to a
-- subscription checked in the current epoch: one about what the page
-- says does, who reads and edits it does not.
mustCheck :: PageEvent -> Bool
mustCheck = \case
  Reading _ -> False
  Editing _ -> False
  _ -> True

-- | 'Check' is whether one 'Who' may read one page, for one event. Every
-- connection of that 'Who' that the event goes to shares it. The first
-- connection to send the event asks the storage, and the others wait for
-- its answer. So an event costs one permission check for each person
-- subscribed, not one for each connection: a person with many tabs open on
-- a page is checked once.
type Check = TVar CheckState

-- | Where a 'Check' is: not asked yet, being asked by a connection, or
-- answered, with the epoch the asking began in.
data CheckState = Unasked | Asking | Answered Epoch Bool

-- | The answer of a 'Check', with the epoch the storage was asked in. The
-- first connection to need it asks, with the action given, and the others
-- wait for that answer. A connection that fails or is closed while it asks
-- puts the check back to 'Unasked', for the next connection to ask.
--
-- The epoch is read as the asking begins, not when the answer comes: a
-- revocation committed while the storage is asked begins a newer epoch,
-- so a subscription that passed is checked again.
answerOf :: Hub -> Check -> IO Bool -> IO (Epoch, Bool)
answerOf hub shared askStorage = mask $ \restore -> do
  claimed <- atomically $ do
    readTVar shared >>= \case
      Answered at allowed -> pure (Right (at, allowed))
      Asking -> retry
      Unasked -> writeTVar shared Asking >> Left <$> readTVar hub.epoch
  case claimed of
    Right answered -> pure answered
    Left at -> do
      allowed <- restore askStorage `onException` atomically (writeTVar shared Unasked)
      atomically (writeTVar shared (Answered at allowed))
      pure (at, allowed)

-- | Send each user's notification to every connection of that user. It
-- never waits: it is called while the storage holds its writer.
notify :: Hub -> [(UserId, Notification)] -> IO ()
notify hub told = atomically $ do
  connections <- readTVar hub.connections
  for_ connections $ \c -> case c.who of
    AsUser u -> for_ [n | (v, n) <- told, v == u] $ \n -> enqueue c (Say (Notified n))
    _ -> pass

-- | Tell every connection subscribed to a page who else is editing it, as
-- the presence now says, in the transaction that changed it.
tellEditors :: Hub -> PageId -> STM ()
tellEditors hub page = do
  connections <- readTVar hub.connections
  now <- readTVar hub.presence
  tellSubscribers page (Map.toList connections) (\k -> Editing (editorsFor k page now))

-- | Tell every connection subscribed to a page who else reads it, as the
-- presence now says, in the transaction that changed it; but the one
-- given, which has just been answered with it.
tellReaders :: Hub -> Maybe Key -> PageId -> STM ()
tellReaders hub answered page = do
  connections <- readTVar hub.connections
  now <- readTVar hub.presence
  tellSubscribers page [(k, c) | (k, c) <- Map.toList connections, Just k /= answered] (\k -> Reading (readersFor k page now))

-- | Change the presence, and if that changed who reads a page, tell its
-- subscribers.
changeReading :: Hub -> PageId -> (Presence -> (Presence, Bool)) -> STM ()
changeReading hub page change = do
  (now, changed) <- change <$> readTVar hub.presence
  writeTVar hub.presence now
  when changed (tellReaders hub Nothing page)

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
      let connection = Connection {who, pages, outbox, behind}
      key <- atomically $ do
        k <- readTVar hub.next
        writeTVar hub.next (k + 1)
        modifyTVar' hub.connections (Map.insert k connection)
        pure k
      -- Closed: it edits and reads nothing any more, which the
      -- subscribers of the pages it edited and read are told.
      let gone = atomically $ do
            modifyTVar' hub.connections (Map.delete key)
            (now, edited) <- leave key <$> readTVar hub.presence
            let (now', read') = leaveReading key now
            writeTVar hub.presence now'
            traverse_ (tellEditors hub) edited
            traverse_ (tellReaders hub Nothing) read'
      flip finally gone . WS.withPingThread socket 20 pass $
        race_ (sending key socket connection) (receiving key socket connection)
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
        -- change to it after the answer is sent after it. So is who reads
        -- it, this connection now among them, which the page's other
        -- subscribers are told.
        --
        -- The epoch is read before the storage is asked, so that a change
        -- committed meanwhile leaves the subscription to be checked again.
        Just (Subscribe page) -> do
          at <- readTVarIO hub.epoch
          read' <- threadsThen storage who page $ \(threads, author) -> atomically $ do
            modifyTVar' connection.pages (Map.insert page at)
            let readingAs = case who of
                  Anonymous -> Just Visitor
                  AsUser _ -> Named <$> author
                  Administrator -> Nothing
            (now, changed) <- maybe (,False) (startReading key page) readingAs <$> readTVar hub.presence
            writeTVar hub.presence now
            enqueue connection (Say (Subscribed page threads (editorsFor key page now) (readersFor key page now)))
            when changed (tellReaders hub (Just key) page)
          when (isLeft read') $ atomically $ do
            modifyTVar' connection.pages (Map.delete page)
            enqueue connection (Say (Refused page))
        Just (Unsubscribe page) -> atomically $ do
          modifyTVar' connection.pages (Map.delete page)
          changeReading hub page (stopReading key page)
        -- Accepted from someone who may edit the page, named as the
        -- storage names them; from anyone else, ignored.
        Just (StartEditing page) ->
          editorOf storage who page >>= traverse_ (\author -> atomically (changePresence hub page (startEditing key page author)))
        Just (StopEditing page) -> atomically (changePresence hub page (stopEditing key page))
        -- Anything else, from a newer tab or none: ignored.
        Nothing -> pass

    -- Send the queued messages, in order. A tab that fell behind, or a
    -- stopping server, closes the connection, for the tab to reconnect.
    sending key socket connection = do
      next <- atomically $ do
        behind <- readTVar connection.behind
        if behind then pure (Hangup "Connect again.") else readTBQueue connection.outbox
      case next of
        Say message -> WS.sendTextData socket (encode message) >> sending key socket connection
        Tell page event shared -> do
          (passedAt, now) <- atomically ((,) <$> (Map.lookup page <$> readTVar connection.pages) <*> readTVar hub.epoch)
          allowed <- case passedAt of
            Nothing -> pure False
            Just at | at == now && not (mustCheck event) -> pure True
            Just _ -> checked key socket connection page shared
          when allowed $ WS.sendTextData socket (encode (Event page event))
          sending key socket connection
        Recheck page shared -> do
          (passedAt, now) <- atomically ((,) <$> (Map.lookup page <$> readTVar connection.pages) <*> readTVar hub.epoch)
          when (any (< now) passedAt) (void (checked key socket connection page shared))
          sending key socket connection
        -- The tab's close reaches the receiving thread, which ends the
        -- connection; this thread has nothing more to send.
        Hangup why -> WS.sendClose socket why >> forever (threadDelay maxBound)

    -- Whether the connection's user may read a subscribed page, asked
    -- through the shared check. A pass is kept with its epoch. A failure
    -- drops the subscription, unless the tab subscribed again after the
    -- check began: the tab is told 'Refused', and the page's other tabs
    -- that it no longer reads or edits the page.
    --
    -- The shared check of an event queued before a change may have been
    -- answered before the change, by another tab. Such an answer is not
    -- trusted: the storage is asked again, for this tab alone.
    checked key socket connection page shared = do
      (asked, answer) <- answerOf hub shared (may page)
      now <- readTVarIO hub.epoch
      (at, allowed) <- if asked < now then (now,) <$> may page else pure (asked, answer)
      outcome <- atomically $ do
        passedAt <- Map.lookup page <$> readTVar connection.pages
        case passedAt of
          Just since
            | allowed -> modifyTVar' connection.pages (Map.insert page (max since at)) $> Passed
            | since <= at -> do
                modifyTVar' connection.pages (Map.delete page)
                changeReading hub page (stopReading key page)
                changePresence hub page (stopEditing key page)
                pure Dropped
          _ -> pure Failed
      when (outcome == Dropped) $ WS.sendTextData socket (encode (Refused page))
      pure (outcome == Passed)
