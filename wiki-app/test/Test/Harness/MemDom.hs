{-# LANGUAGE MultiWayIf #-}

-- | A view mounted on haskell-halogen's in-memory DOM for a native test
-- ("Halogen.VDom.DOM.Monad.Native"): the harness every view's native spec
-- uses. The view is the real component, run as a page runs it: mounted in
-- a container of the process's one document, clicked and typed into by
-- events that bubble as in a page, read with CSS selectors, and waited for
-- through what its program is doing ("Halogen.Activity"), never by a
-- clock.
--
-- > withView run component input $ \view -> do
-- >   click view ".notifications-toggle"
-- >   settle view
-- >   rows <- N.querySelectorAll ".notification" view.container
--
-- = What the program waits for
--
-- A view's asks of its backend are held for the test in one of two ways.
--
-- * The library's held waits ("Halogen.Activity.Control", re-exported
--   here): inside 'withHeldWaits', every wait of the view's program is
--   held before its action starts; 'pending' gives them once the program
--   has done all it can, and 'release' runs the real action. For a test
--   whose backend's own answer is the one wanted, at the moment the test
--   chooses: a read let go after a write, an echo of the live channel
--   before or after the answer to the write.
-- * A 'Gate': the test's backend puts each ask in it and waits for an
--   answer the test gives, a value of the test's own ('answer'). For a
--   test whose answers come from a model of the server, as the bell's
--   generated runs do ("Test.BellHarness"). 'settleHolding' waits until
--   the program has done all it can but wait for the gate.
--
-- = The document is one for the process
--
-- Every container is in the same document, and a component's listeners
-- on the document and the window hear every event that reaches them,
-- from any view, as in one page: a popup open in one view closes on a
-- press in another view's container. So 'withView' takes the document for
-- its body ('inTurn'): views mounted with it run one after another. The
-- rest of the native suite runs beside them. What it mounts (the
-- prerender's shell, "Wiki.App.Static") is on elements in no document,
-- whose popups never act; but its routers write the address, which is
-- the process's one @location@ too. So a spec reads where its view went
-- from its own router's 'Halogen.Router.changes', not from the address.
module Test.Harness.MemDom
  ( -- * A view mounted
    View (..)
  , withView
  , mount
  , query
  , inTurn

    -- * Acting as the reader
  , click
  , clickAt
  , typeInto
  , keyDown
  , pressOutside

    -- * Reading
  , find
  , findAll
  , textOf

    -- * Waiting for the program
  , settle
  , settleHolding
  , within

    -- * Asks the test answers with values of its own
  , Gate
  , Held (..)
  , newGate
  , hold
  , heldNow
  , heldCount
  , answer

    -- * Asks held by the library
  , HeldWaits
  , HeldWait
  , withHeldWaits
  , pending
  , release
  , releaseAll

    -- * Pauses on the test's clock
  , TestClock
  , withTestClock
  , advance
  )
where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Aeson (Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Coerce (coerce)
import Halogen qualified as H
import Halogen.Activity (Activity (..), idle, quiet)
import Halogen.Activity.Control (HeldWait, HeldWaits, TestClock, advance, pending, release, releaseAll, withHeldWaits, withTestClock)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (runUI)
import Protolude hiding (find)
import System.IO.Unsafe (unsafePerformIO)
import System.Timeout (timeout)
import Web.DOM.Internal.Types (Element (..))
import Web.HTML.HTMLInputElement (HTMLInputElement (..))

-- | A view mounted in a container of the process's document: the
-- container, what the program is doing, and how to ask the view and to
-- take it away.
data View q = View
  { container :: N.NativeNode
  , queries :: Queries q
  , activity :: IO Activity
  -- ^ What this view's tree alone is doing.
  , waitActivity :: (Activity -> Bool) -> IO ()
  -- ^ Return once 'activity' satisfies the predicate, woken by each
  -- change of it, never by a clock.
  , dispose :: IO ()
  -- ^ Finalize the view and take its container out of the document.
  -- Twice does nothing more.
  }

-- | A view's queries, run to the end.
newtype Queries q = Queries (forall a. q a -> IO (Maybe a))

-- | Ask the view, as its parent would, and wait for the answer.
query :: View q -> q a -> IO (Maybe a)
query view = let Queries send = view.queries in send

-- | Mount a component in a new container of the process's document, with
-- the function that runs its monad. The caller disposes of it; 'withView'
-- does both and takes the document for the time between.
mount :: (MonadBrowserDOM m, MonadUnliftIO m) => (forall a. m a -> IO a) -> H.Component q i o m -> i -> IO (View q)
mount run component input = do
  container <- N.newContainer
  H.HalogenSocket {H.query = send, H.dispose = disposeTree, H.activity = reading, H.waitActivity = waiting} <- run (runUI component input (N.fromNative container))
  pure
    View
      { container
      , queries = Queries (run . send)
      , activity = run reading
      , waitActivity = run . waiting
      , dispose = run disposeTree >> (N.fromNative container :: Element).remove
      }

-- | Mount a view, run the body on it, and dispose of it, with the
-- process's document taken for the time between ('inTurn'). Mount it on
-- the thread that opened 'withHeldWaits' or 'withTestClock', as here, for
-- them to hold its waits and move its pauses.
withView :: (MonadBrowserDOM m, MonadUnliftIO m) => (forall a. m a -> IO a) -> H.Component q i o m -> i -> (View q -> IO b) -> IO b
withView run component input body = inTurn (bracket (mount run component input) (\v -> v.dispose) body)

-- | The process's document, for one view at a time.
theDocument :: MVar ()
theDocument = unsafePerformIO (newMVar ())
{-# NOINLINE theDocument #-}

-- | Run with the process's document taken: another body that takes it
-- waits. Not to be nested.
inTurn :: IO a -> IO a
inTurn = withMVar theDocument . const

-- | Click the first element a selector finds in the view, with the main
-- button, as a reader does: the event bubbles from it to the document and
-- the window, and a disabled control gets none. False when nothing is
-- found.
click :: View q -> Text -> IO Bool
click view selector = find view selector >>= maybe (pure False) (\e -> clickAt e $> True)

-- | Click an element found already.
clickAt :: N.NativeNode -> IO ()
clickAt = N.dispatch "click" (object ["button" .= (0 :: Int)])

-- | Type into a field as a reader does: its value set, then @input@
-- dispatched at it. False when nothing is found.
typeInto :: View q -> Text -> Text -> IO Bool
typeInto view selector text =
  find view selector >>= \case
    Nothing -> pure False
    Just field -> do
      (HTMLInputElement (coerce (N.fromNative field :: Element))).value_set text
      N.dispatch "input" (object []) field
      pure True

-- | A key pressed at an element, as @keydown@ with the key's name
-- (@"Escape"@); with the extra fields given (@"ctrlKey" .= True@).
keyDown :: Text -> [(Text, Value)] -> N.NativeNode -> IO ()
keyDown key extra = N.dispatch "keydown" (object (("key" .= key) : [Key.fromText k .= v | (k, v) <- extra]))

-- | A press of the pointer on the view's container, outside everything the
-- view rendered in it: @pointerdown@, which bubbles to the document.
pressOutside :: View q -> IO ()
pressOutside view = N.dispatch "pointerdown" (object ["button" .= (0 :: Int)]) view.container

-- | The first element a selector finds in the view.
find :: View q -> Text -> IO (Maybe N.NativeNode)
find view selector = N.querySelector selector view.container

-- | Every element a selector finds in the view, in document order.
findAll :: View q -> Text -> IO [N.NativeNode]
findAll view selector = N.querySelectorAll selector view.container

-- | The text of the first element a selector finds, if it finds one.
textOf :: View q -> Text -> IO (Maybe Text)
textOf view selector = find view selector >>= traverse N.textContent

-- | Wait until the view's program is quiet: no work running or queued,
-- and nothing it waits for in a @liftIO@ still out.
settle :: View q -> IO ()
settle view = within (("the view to be quiet; it is at " <>) . show <$> view.activity) (view.waitActivity quiet)

-- | Wait until the view's program has done all it can but wait for the
-- asks a gate holds: no work running or queued, and as many fibers waiting
-- as the gate holds asks. The two disagree for a moment at each end of an
-- ask: its fiber starts to wait before the ask reaches the gate, and an
-- ask answered leaves the gate before its fiber stops waiting; a wait of
-- the program's own, not an ask, ends without the gate changing. Neither
-- a change of the gate nor the end of a wait is sure to change the
-- activity the test last read, so until the two agree, the wait is on
-- whichever changes first, the gate or the activity. Once the view is
-- disposed of, no tree is left and its asks' fibers are cancelled.
settleHolding :: View q -> STM Int -> IO ()
settleHolding view holding = within stateNow go
  where
    go = do
      view.waitActivity (\a -> idle a || a.trees == 0)
      a <- view.activity
      n <- atomically holding
      if
        | a.trees == 0 || (idle a && a.waiting == n) -> pass
        | otherwise -> void (race (atomically (holding >>= \m -> check (m /= n))) (view.waitActivity (/= a))) >> go
    stateNow = do
      a <- view.activity
      n <- atomically holding
      pure ("the view to wait only for the " <> show n <> " asks held; it is at " <> show a)

-- | A wait that has not ended after ten seconds has hung: the test fails,
-- saying what it waited for and where things stand. A guard against a
-- hang, not a pause.
within :: IO Text -> IO a -> IO a
within what action = timeout 10_000_000 action >>= maybe (what >>= \w -> panic ("waited ten seconds for " <> w)) pure

-- | Asks of a test's backend held until the test answers each, in the
-- order they were made, and the number the next one takes.
data Gate q r = Gate
  { held :: TVar [Held q r]
  , next :: TVar Int
  }

-- | One ask held: its number in the order of the asks, what it asks, and
-- where its answer goes.
data Held q r = Held
  { number :: Int
  , asked :: q
  , reply :: MVar r
  }

newGate :: IO (Gate q r)
newGate = Gate <$> newTVarIO [] <*> newTVarIO 1

-- | Put an ask in the gate and wait for its answer: for the test's
-- backend's methods.
hold :: Gate q r -> q -> IO r
hold gate asked = do
  reply <- newEmptyMVar
  atomically $ do
    number <- readTVar gate.next
    writeTVar gate.next (number + 1)
    modifyTVar' gate.held (<> [Held {number, asked, reply}])
  takeMVar reply

-- | The asks held now, oldest first.
heldNow :: Gate q r -> IO [Held q r]
heldNow gate = readTVarIO gate.held

-- | How many asks the gate holds, for 'settleHolding'.
heldCount :: Gate q r -> STM Int
heldCount gate = length <$> readTVar gate.held

-- | Answer an ask held: it leaves the gate, and its fiber goes on.
answer :: Gate q r -> Held q r -> r -> IO ()
answer gate h value = do
  atomically (modifyTVar' gate.held (filter (\x -> x.number /= h.number)))
  void (tryPutMVar h.reply value)
