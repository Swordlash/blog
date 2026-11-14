-- | What the bell's component tests share, on the in-memory DOM
-- ("Test.BellDom") and in a browser over haskell-halogen-remote
-- ("Test.Remote.Bell"): a backend that holds the bell's asks until the test
-- gives each its answer ('Gated'), a feed the test tells through, the bell
-- under a parent that gives it a revision, and a run of "Test.Bell"'s steps
-- carried out on the mounted bell and checked after each step ('runSteps').
-- Where the bell is mounted and how its page is read and clicked is each
-- module's own ('Ui').
module Test.BellHarness
  ( -- * The backend
    Held (..)
  , Gated (..)
  , runGated

    -- * The bell mounted
  , Query (..)
  , parent
  , Rig (..)
  , newRig

    -- * A run
  , Shown (..)
  , Ui (..)
  , Check (..)
  , runSteps
  )
where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.Trans.Class (MonadTrans (..))
import Control.Monad.UUID (MonadUUID (..))
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Row.Internal (LT (..), Row (R))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router qualified as Router
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude hiding (State)
import Test.Bell (Server (..), Step (..), World (..), emptyServer, handleMark, handleRead, made, play, start)
import Wiki.Api.Notifications (Notifications (..), ReadMark (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki, WikiError, anonymousIn)
import Wiki.App.Backend.Mem (MemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Live (Feed (..), Heard (..))
import Wiki.App.Route (Route)
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
-- marks held in a gate, in the order they were made, until the test gives
-- each its answer. Everything else is the in-memory backend's.
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

-- | A program of the gated backend run over a wiki in memory.
runGated :: TVar [Held] -> IORef MemState -> Gated (MemWiki n) a -> n a
runGated gate wiki (Gated p) = runMemWiki wiki (runReaderT p gate)

data Query a = SetRevision Int a

type Slots = R '["bell" ':-> H.Slot (Const Void) Void ()]

-- | The bell under a parent that gives it its input: the parent changes
-- the revision when asked, which the bell receives.
parent :: forall n. (MonadUUID n, MonadBrowserDOM n, MonadUnliftIO n) => Feed -> Router.Router Route -> H.Component Query () Void (Gated (MemWiki n))
parent feed router =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> pure (0 :: Int)
      , render
      , eval = H.mkEval H.defaultEval {H.handleQuery = \(SetRevision r a) -> put r $> Just a}
      }
  where
    render :: Int -> H.ComponentHTML () Slots (Gated (MemWiki n))
    render revision = HH.div_ [HH.slot_ "bell" () Bell.component Bell.Input {context = contextAt revision, feed = Just feed}]
    contextAt revision = Context {router, session = anonymousIn Open, spaces = [], icons = mempty, revision, pageWidth = Compact}

-- | What drives a mounted bell besides its page: the gate, the feed's
-- channel, how many listen to the feed, the revision given, and how to
-- give a new one and to take the bell away.
data Rig = Rig
  { gate :: TVar [Held]
  , channel :: HS.Subscribe IO Heard
  , listening :: IORef Int
  -- ^ 'listen's less 'unlisten's of the feed.
  , revision :: IORef Int
  , revise :: Int -> IO ()
  , dispose :: IO ()
  }

-- | A gate, a feed the test tells through, and the rest of a 'Rig' but
-- for the bell's own 'revise' and 'dispose'.
newRig :: IO (Feed, (Int -> IO ()) -> IO () -> Rig)
newRig = do
  gate <- newTVarIO []
  channel <- HS.create
  listening <- newIORef (0 :: Int)
  revision <- newIORef 0
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
  pure (feed, \revise dispose -> Rig {gate, channel, listening, revision, revise, dispose})

-- | What the bell shows: the count; whether the list is open; each
-- notification listed, by its number, and whether it is unread; and
-- whether the buttons that mark are disabled (read from "Mark read", so
-- not busy when nothing is listed unread).
data Shown = Shown
  { count :: Int
  , open :: Bool
  , rows :: [(Int, Bool)]
  , busy :: Bool
  }
  deriving stock (Eq, Show)

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

-- | The page of a mounted bell: its clicks, each a no-op where the page
-- has nothing to click (or the button is disabled), what it shows, and
-- how to wait until the program has done all it can.
data Ui = Ui
  { clickBell :: IO ()
  , clickMark :: Int -> IO ()
  -- ^ "Mark read" on the unread notification at this place.
  , clickMarkAll :: IO ()
  , clickLink :: Int -> IO ()
  , shown :: IO Shown
  , settle :: IO ()
  }

-- | Carry out one step on the mounted bell, as "Test.Bell"'s run does on
-- the machine, and settle. The server is the test's: it changes here, and
-- gives each ask held its answer when the step handles it. Once the bell
-- has gone away its page is not touched.
drive :: Rig -> Ui -> IORef Server -> Bool -> Step -> IO ()
drive rig ui ref gone s = do
  case s of
    _ | gone && s `elem` [ClickBell, ClickMarkAll, Revise, Finish] -> pass
    ClickBell -> ui.clickBell
    PressOutside -> pass
    ClickMark i -> unless gone (ui.clickMark i)
    ClickMarkAll -> ui.clickMarkAll
    ClickLink i -> unless gone (ui.clickLink i)
    Make -> modifyIORef' ref made
    ReadElsewhere i -> modifyIORef' ref $ \server -> case atMay [n | n <- server.notes, not n.read] i of
      Just n -> fst (handleMark ReadMark {ids = [n.id], everything = False} server)
      Nothing -> server
    Tell -> do
      server <- readIORef ref
      case server.untold of
        n : rest -> do
          writeIORef ref server {untold = rest}
          HS.notify rig.channel.listener (Notice n)
        [] -> pass
    Reconnect -> do
      modifyIORef' ref (\server -> server {untold = []})
      HS.notify rig.channel.listener Reopened
    HandleOut _ -> pass
    Handle -> do
      server <- readIORef ref
      waiting <- readTVarIO rig.gate
      case break (isNothing . (.handled)) waiting of
        (earlier, h : later) -> do
          let (server', a) = maybe (server, handleRead server) (`handleMark` server) h.asked
          writeIORef ref server'
          atomically (writeTVar rig.gate (earlier <> (h {handled = Just a} : later)))
        _ -> pass
    Deliver i -> do
      waiting <- readTVarIO rig.gate
      for_ (atMay [(h, a) | h <- waiting, Just a <- [h.handled]] i) $ \(h, a) -> do
        atomically (modifyTVar' rig.gate (filter (\x -> x.answer /= h.answer)))
        putMVar h.answer (Right a)
    Revise -> do
      r <- atomicModifyIORef' rig.revision (\r -> (r + 1, r + 1))
      rig.revise r
    Finish -> rig.dispose
  unless (gone || s == Finish) ui.settle

-- | How a run on the mounted bell is checked after each step: against
-- the machine's run of the same steps, or against the rules alone, read
-- from the page, whatever the component's logic is.
data Check = BesideMachine | RulesOnly
  deriving stock (Eq)

-- | A run on a mounted bell: what went wrong first, with the steps up to
-- it, or nothing. Runs here have no 'PressOutside' (the module's Haddock
-- of "Test.BellDom" says why).
runSteps :: Check -> Rig -> Ui -> [Step] -> IO (Maybe Text)
runSteps how rig ui run = do
  ref <- newIORef emptyServer
  let go _ _ _ [] = pure Nothing
      go done w seen (s : rest) = do
        drive rig ui ref w.finished s
        let w' = play w s
        page <- if w'.finished then pure (shownBy w') else ui.shown
        server <- readIORef ref
        waiting <- readTVarIO rig.gate
        listening <- readIORef rig.listening
        let expected = shownBy w'
            holding = length waiting
            marksHeld = length [() | h <- waiting, isJust h.asked]
            asksOut = if w'.finished then holding else length w'.outs
            -- Every notification listed so far, and whether it was ever
            -- listed read.
            newest = [k | n <- take server.limit server.notes, let NotificationId t = n.id, Just k <- [readMaybe (T.drop 1 t)]]
            seen' = if page.open then Map.unionWith (||) seen (Map.fromList [(k, not unread) | (k, unread) <- page.rows]) else seen
            beside =
              ["the page shows " <> show page <> ", the machine " <> show expected | page /= expected]
                <> ["the gate holds " <> show holding <> " asks, the machine has " <> show asksOut <> " out" | holding /= asksOut]
            rules
              | w'.finished = ["the feed is listened to " <> show listening <> " times after the bell went away" | listening /= 0]
              | otherwise =
                  ["n" <> show k <> " was shown read, and is shown unread again" | page.open, (k, True) <- page.rows, Map.lookup k seen == Just True]
                    <> ["listed before and gone: " <> show gone | page.open, let gone = [k | k <- Map.keys seen, k `notElem` map fst page.rows, k `elem` newest], not (null gone)]
                    <> ["the count says " <> show page.count <> ", and " <> show (length (filter snd page.rows)) <> " are listed unread" | page.open, page.count < length (filter snd page.rows)]
                    <> ["Mark read is enabled while a mark is held" | page.open, any snd page.rows, marksHeld > 0, not page.busy]
                    <> ["Mark read is disabled with no mark held" | page.open, page.busy, marksHeld == 0]
                    <> ["the feed is listened to " <> show listening <> " times" | listening /= 1]
            problems = rules <> (if how == BesideMachine then beside else [])
        if null problems
          then go (done <> [s]) w' seen' rest
          else pure (Just (T.unlines (("after " <> show (done <> [s])) : problems)))
  outcome <- go [] start mempty (filter (/= PressOutside) run)
  -- The asks still held are let go, so that no worker waits for ever.
  readTVarIO rig.gate >>= traverse_ (\h -> tryPutMVar h.answer (Right Notifications {unread = 0, items = []}))
  unless (Finish `elem` run) rig.dispose
  pure outcome
