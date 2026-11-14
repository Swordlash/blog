-- | The header's bell ("Wiki.App.View.Bell"), the real component, mounted
-- natively on haskell-halogen's in-memory DOM and driven by the same
-- generated runs as its machine ("Test.Bell"). A click is the click
-- listener of the element run with an event; the live channel is a feed
-- the test tells through; the backend holds every read and mark of the
-- notifications until the test gives its answer ('Gated'). After each
-- step the program is run until it has nothing left to do but wait for
-- the asks held ('settle'), and what the bell shows is read from the DOM:
-- the count, the rows with their unread mark, whether the buttons that
-- mark are disabled.
--
-- After each step the DOM must show what the machine shows after the same
-- step, and the rules of "Test.Bell" are checked on what the DOM shows.
--
-- What the in-memory DOM cannot do here: a press outside the list, and
-- Escape. The list's watch hears them only while its element says it is
-- in the document ('Web.DOM.Element.isConnected'), which reads false
-- natively. So these runs have no 'PressOutside'.
module Test.BellDom (spec) where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.UUID (MonadUUID (..))
import Data.Aeson (object, (.=))
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Row.Internal (LT (..), Row (R))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.Activity (Activity (..), activity)
import Halogen.HTML qualified as HH
import Halogen.HTML.Core (ElemName (..))
import Halogen.Router qualified as Router
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (runUI)
import Protolude hiding (State)
import Test.Bell (Server (..), Step (..), World (..), emptyServer, genRun, handleMark, handleRead, made, play, shrinkRun, start)
import Test.Hspec
import Test.QuickCheck (counterexample, forAllShrinkShow, ioProperty, withNumTests, (===))
import Test.QuickCheck qualified as QC
import Wiki.Api.Notifications (Notifications (..), ReadMark (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki, WikiError, anonymousIn)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Live (Feed (..), Heard (..))
import Wiki.App.Route (Route (..), route)
import Wiki.App.View.Bell qualified as Bell
import Wiki.App.View.Bell.Machine (Model (..), busy, listed, unreadCount)
import Wiki.App.View.Common (Context (..), PageWidth (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (NotificationId (..))
import Wiki.Core.Notification (Notification (..))

-- | One ask held, in the gate in the order the asks were made: what it
-- asks, the answer the server gave once it handled it, and where the
-- answer goes when the test lets it go.
data Held = Held
  { asked :: Maybe ReadMark
  -- ^ 'Nothing' for a read, the mark for a mark.
  , handled :: Maybe Notifications
  , answer :: MVar (Either WikiError Notifications)
  }

-- | 'Gated' is the in-memory backend with the notifications' reads and
-- marks held in a gate, the asks held in the order they were made, until
-- the test gives each its answer. Everything else is the in-memory
-- backend's.
newtype Gated m a = Gated (ReaderT (TVar [Held]) m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

instance MonadTrans Gated where
  lift = Gated . lift

deriving newtype instance (MonadDOM m) => MonadDOM (Gated m)

deriving newtype instance (MonadAttributes m) => MonadAttributes (Gated m)

deriving newtype instance (MonadBrowserDOM m) => MonadBrowserDOM (Gated m)

instance (MonadUUID m) => MonadUUID (Gated m) where
  generateV4 = lift generateV4

instance (MonadWiki m) => MonadWiki (Gated m)

-- | Nothing is answered at once: the bell reads its list after it is
-- mounted, as over the network.
instance (MonadWiki m) => MonadLoad (Gated m) where
  atOnce _ = pure Nothing
  attempt = fmap Right

instance (MonadNotifications m, MonadIO m) => MonadNotifications (Gated m) where
  notifications = held Nothing
  markRead = held . Just

-- | An ask put in the gate, and its answer once the test gives it.
held :: (MonadIO m) => Maybe ReadMark -> Gated m (Either WikiError Notifications)
held asked = Gated $ do
  gate <- ask
  liftIO $ do
    answer <- newEmptyMVar
    atomically (modifyTVar' gate (<> [Held {asked, handled = Nothing, answer}]))
    takeMVar answer

type App = Gated (MemWiki MemDOM)

data Query a = SetRevision Int a

type Slots = R '["bell" ':-> H.Slot (Const Void) Void ()]

-- | The bell under a parent that gives it its input: the parent changes
-- the revision when asked, which the bell receives.
parent :: Feed -> Router.Router Route -> H.Component Query () Void App
parent feed router =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> pure (0 :: Int)
      , render
      , eval = H.mkEval H.defaultEval {H.handleQuery = \(SetRevision r a) -> put r $> Just a}
      }
  where
    render :: Int -> H.ComponentHTML () Slots App
    render revision = HH.div_ [HH.slot_ "bell" () Bell.component Bell.Input {context = contextAt revision, feed = Just feed}]
    contextAt revision = Context {router, session = anonymousIn Open, spaces = [], icons = mempty, revision, pageWidth = Compact}

-- | A bell mounted, with what drives it.
data Mounted = Mounted
  { container :: N.NativeNode
  , gate :: TVar [Held]
  , channel :: HS.Subscribe IO Heard
  , listening :: IORef Int
  -- ^ 'listen's less 'unlisten's of the feed.
  , revision :: IORef Int
  , revise :: Int -> IO ()
  , dispose :: IO ()
  }

mount :: IO Mounted
mount = do
  wiki <- newMemWiki (demoState demoNow)
  gate <- newTVarIO []
  let run :: App a -> IO a
      run (Gated p) = runMemDOM (runMemWiki wiki (runReaderT p gate))
  channel <- HS.create
  listening <- newIORef (0 :: Int)
  let feed =
        Feed
          { heard = channel.emitter
          , watch = \_ -> pass
          , unwatch = \_ -> pass
          , restart = pass
          , startEditing = \_ -> pass
          , stopEditing = \_ -> pass
          , editorsOf = \_ -> pure Nothing
          , readersOf = \_ -> pure Nothing
          , listen = atomicModifyIORef' listening (\n -> (n + 1, ()))
          , unlisten = atomicModifyIORef' listening (\n -> (n - 1, ()))
          }
  router <- run (Router.newRouter "/" Unknown route)
  container <- N.newElement Nothing (ElemName "div")
  H.HalogenSocket {H.query = send, H.dispose = disposeUI} <- run (runUI (parent feed router) () (N.fromNative container))
  revision <- newIORef 0
  let mounted = Mounted {container, gate, channel, listening, revision, revise = \r -> void (run (send (SetRevision r ()))), dispose = run disposeUI}
  settle mounted
  pure mounted

-- | Run the program until it has done all it can: no tree has work, and
-- the fibers that wait are exactly the asks held in the gate and not yet
-- given their answer. A read of the runtime's activity, a millisecond
-- apart: the library has no call that returns at that moment. Once the
-- bell is disposed of, no tree is left, and the asks it held wait for
-- nothing: their fibers were cancelled. Every tree
-- in the process counts, so this spec runs alone.
settle :: Mounted -> IO ()
settle m = go (0 :: Int)
  where
    go tries = do
      a <- activity
      waitingNow <- length <$> readTVarIO m.gate
      if a.running == 0 && (a.waiting == waitingNow || a.trees == 0)
        then pass
        else
          if tries > 10_000
            then panic ("the bell did not settle: " <> show a <> ", held " <> show waitingNow)
            else threadDelay 1000 >> go (tries + 1)

-- | What the bell shows: the count; whether the list is open; each
-- notification listed, by its number, and whether it is unread; and
-- whether the buttons that mark are disabled.
data Shown = Shown
  { count :: Int
  , open :: Bool
  , rows :: [(Int, Bool)]
  , busy :: Bool
  }
  deriving stock (Eq, Show)

-- | What the bell shows, read from the DOM. With no row unread there is no
-- "Mark read" to read the busy flag from, and "Mark all read" is disabled
-- for nothing unread as well, so the flag reads as not busy.
shownIn :: N.NativeNode -> IO Shown
shownIn root = do
  nodes <- descendants root
  count <-
    withClass "notifications-count" nodes >>= \case
      c : _ -> fromMaybe 0 . readMaybe <$> textOf c
      [] -> pure 0
  open <- not . null <$> withClass "notifications-panel" nodes
  rows <- withClass "notification" nodes >>= traverse row
  marking <- withClass "notification-read" nodes >>= fmap or . traverse disabled
  pure Shown {count, open, rows, busy = marking}
  where
    row r = do
      links <- descendants r >>= withClass "notification-link"
      k <- maybe (pure (-1)) (fmap (numberOf . fromMaybe "") . attribute "href") (head links)
      (k,) <$> hasClass "unread" r
    -- The notification's number in its link, "/s/blog/p/page-<k>/".
    numberOf href = fromMaybe (-1) (readMaybe (T.takeWhile (/= '/') (snd (T.breakOnEnd "page-" href))))

-- | What the machine shows, in the same terms.
shownBy :: World -> Shown
shownBy w =
  Shown
    { count = unreadCount w.bell
    , open = w.bell.open && not w.finished
    , rows = if w.bell.open then [(numberOf n.id, not n.read) | n <- listed w.bell] else []
    , busy = busy w.bell && any (\n -> not n.read) (listed w.bell) && w.bell.open
    }
  where
    numberOf (NotificationId t) = fromMaybe (-1) (readMaybe (T.drop 1 t))

descendants :: N.NativeNode -> IO [N.NativeNode]
descendants node = do
  kids <- N.childNodes node
  (kids <>) . concat <$> traverse descendants kids

withClass :: Text -> [N.NativeNode] -> IO [N.NativeNode]
withClass c = filterM (hasClass c)

attribute :: Text -> N.NativeNode -> IO (Maybe Text)
attribute name node = do
  attrs <- N.attributeList node
  props <- N.propertyList node
  pure (head ([v | ((_, n), v) <- attrs, n == name] <> [v | (n, v) <- props, n == name]))

hasClass :: Text -> N.NativeNode -> IO Bool
hasClass c node = do
  attrs <- N.attributeList node
  props <- N.propertyList node
  pure (c `elem` concatMap T.words ([v | ((_, "class"), v) <- attrs] <> [v | ("className", v) <- props]))

disabled :: N.NativeNode -> IO Bool
disabled node = do
  attrs <- N.attributeList node
  props <- N.propertyList node
  pure (any (\((_, n), _) -> n == "disabled") attrs || ("disabled", "true") `elem` props)

textOf :: N.NativeNode -> IO Text
textOf node = case node.kind of
  N.TextNode -> readIORef node.content
  _ -> mconcat <$> (traverse textOf =<< N.childNodes node)

-- | A click on an element: its click listeners run with a plain click of
-- the main button, as a browser dispatches it. A disabled button gets no
-- click, as in a browser.
click :: N.NativeNode -> IO ()
click node = do
  off <- disabled node
  unless off $ do
    listeners <- readIORef node.listeners
    for_ [l | l <- listeners, l.eventType == "click"] $ \l ->
      runMemDOM (l.fire (N.event (object ["button" .= (0 :: Int), "type" .= ("click" :: Text)])))

-- | Carry out one step on the mounted bell, as "Test.Bell"'s run does on
-- the machine, and settle. The server is the test's: it changes here, and
-- gives each ask held its answer when the step handles it.
drive :: Mounted -> IORef Server -> Step -> IO ()
drive m ref s = do
  nodes <- descendants m.container
  case s of
    ClickBell -> withClass "notifications-toggle" nodes >>= traverse_ click . take 1
    PressOutside -> pass
    ClickMark i -> do
      unread <- filterM (hasClass "unread") =<< withClass "notification" nodes
      for_ (atMay unread i) $ \r -> descendants r >>= withClass "notification-read" >>= traverse_ click . take 1
    ClickMarkAll -> withClass "notifications-read-all" nodes >>= traverse_ click . take 1
    ClickLink i -> withClass "notification-link" nodes >>= traverse_ click . (`atMay` i)
    Make -> modifyIORef' ref made
    ReadElsewhere i -> modifyIORef' ref $ \server -> case atMay [n | n <- server.notes, not n.read] i of
      Just n -> fst (handleMark ReadMark {ids = [n.id], everything = False} server)
      Nothing -> server
    Tell -> do
      server <- readIORef ref
      case server.untold of
        n : rest -> do
          writeIORef ref server {untold = rest}
          HS.notify m.channel.listener (Notice n)
        [] -> pass
    Reconnect -> do
      modifyIORef' ref (\server -> server {untold = []})
      HS.notify m.channel.listener Reopened
    Handle -> do
      server <- readIORef ref
      waiting <- readTVarIO m.gate
      case break (isNothing . (.handled)) waiting of
        (earlier, h : later) -> do
          let (server', a) = maybe (server, handleRead server) (`handleMark` server) h.asked
          writeIORef ref server'
          atomically (writeTVar m.gate (earlier <> (h {handled = Just a} : later)))
        _ -> pass
    Deliver i -> do
      waiting <- readTVarIO m.gate
      for_ (atMay [(h, a) | h <- waiting, Just a <- [h.handled]] i) $ \(h, a) -> do
        atomically (modifyTVar' m.gate (filter (\x -> x.answer /= h.answer)))
        putMVar h.answer (Right a)
    Revise -> do
      r <- atomicModifyIORef' m.revision (\r -> (r + 1, r + 1))
      m.revise r
    Finish -> m.dispose
  settle m

-- | How a run on the mounted bell is checked after each step: against
-- the machine's run of the same steps, or against the rules alone, read
-- from the DOM, whatever the component's logic is.
data Check = BesideMachine | RulesOnly
  deriving stock (Eq)

-- | A run on the mounted bell: what went wrong first, with the steps up to
-- it, or nothing.
runOnDom :: Check -> [Step] -> IO (Maybe Text)
runOnDom how run = do
  m <- mount
  ref <- newIORef emptyServer
  let go _ _ _ [] = pure Nothing
      go done w seen (s : rest) = do
        drive m ref s
        let w' = play w s
        dom <- if w'.finished then pure (shownBy w') else shownIn m.container
        waiting <- readTVarIO m.gate
        listening <- readIORef m.listening
        let expected = shownBy w'
            holding = length waiting
            marksHeld = length [() | h <- waiting, isJust h.asked]
            asksOut = if w'.finished then holding else length w'.outs
            -- Every notification listed so far, and whether it was ever
            -- listed read.
            seen' = if dom.open then Map.unionWith (||) seen (Map.fromList [(k, not unread) | (k, unread) <- dom.rows]) else seen
            beside =
              ["the DOM shows " <> show dom <> ", the machine " <> show expected | dom /= expected]
                <> ["the gate holds " <> show holding <> " asks, the machine has " <> show asksOut <> " out" | holding /= asksOut]
            rules
              | w'.finished = ["the feed is listened to " <> show listening <> " times after the bell went away" | listening /= 0]
              | otherwise =
                  ["n" <> show k <> " was shown read, and is shown unread again" | dom.open, (k, True) <- dom.rows, Map.lookup k seen == Just True]
                    <> ["listed before and gone: " <> show gone | dom.open, let gone = [k | k <- Map.keys seen, k `notElem` map fst dom.rows], not (null gone)]
                    <> ["the count says " <> show dom.count <> ", and " <> show (length (filter snd dom.rows)) <> " are listed unread" | dom.open, dom.count /= length (filter snd dom.rows)]
                    <> ["Mark read is enabled while a mark is held" | dom.open, any snd dom.rows, marksHeld > 0, not dom.busy]
                    <> ["Mark read is disabled with no mark held" | dom.open, dom.busy, marksHeld == 0]
                    <> ["the feed is listened to " <> show listening <> " times" | listening /= 1]
            problems = rules <> (if how == BesideMachine then beside else [])
        if null problems
          then go (done <> [s]) w' seen' rest
          else pure (Just (T.unlines (("after " <> show (done <> [s])) : problems)))
  outcome <- go [] start mempty (filter (/= PressOutside) run)
  -- The asks still held are let go, so that no worker waits for ever.
  readTVarIO m.gate >>= traverse_ (\h -> tryPutMVar h.answer (Right Notifications {unread = 0, items = []}))
  unless (Finish `elem` run) m.dispose
  pure outcome

spec :: Spec
spec = describe "Wiki.App.View.Bell, mounted on the in-memory DOM" $ do
  it "keeps the rules, read from the DOM, on any run" $
    QC.property . withNumTests 300 $
      forAllShrinkShow genRun shrinkRun show $ \run ->
        ioProperty $ do
          outcome <- runOnDom RulesOnly run
          pure (counterexample (toS (fromMaybe "" outcome)) (outcome === Nothing))

  it "shows what its machine shows after every step of any run, and holds the same asks" $
    QC.property . withNumTests 300 $
      forAllShrinkShow genRun shrinkRun show $ \run ->
        ioProperty $ do
          outcome <- runOnDom BesideMachine run
          pure (counterexample (toS (fromMaybe "" outcome)) (outcome === Nothing))

  it "counts a notification the live channel tells of, lists it when opened, and marks it read, with no wait in the test" $ do
    outcome <- runOnDom BesideMachine [Handle, Deliver 0, Make, Tell, ClickBell, Handle, Deliver 0, ClickMark 0, Handle, Deliver 0]
    outcome `shouldBe` Nothing
