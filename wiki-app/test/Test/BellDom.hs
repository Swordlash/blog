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

import Control.Concurrent.STM (TVar, readTVarIO)
import Data.Aeson (object, (.=))
import Data.IORef (readIORef)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.Activity (Activity (..), activity)
import Halogen.HTML.Core (ElemName (..))
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (runUI)
import Protolude hiding (State)
import Test.Bell (Step (..), genRun, shrinkRun)
import Test.BellHarness (Check (..), Gated, Held, Query (..), Rig (..), Shown (..), Ui (..), newRig, parent, runGated, runSteps)
import Test.Hspec
import Test.QuickCheck (counterexample, forAllShrinkShow, ioProperty, withNumTests, (===))
import Test.QuickCheck qualified as QC
import Wiki.App.Backend.Mem (MemWiki, newMemWiki)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route (..), route)

-- | The bell mounted on the in-memory DOM, under the gated in-memory
-- backend, with its page.
mount :: IO (Rig, Ui)
mount = do
  wiki <- newMemWiki (demoState demoNow)
  (feed, rigWith) <- newRig
  let rig0 = rigWith (\_ -> pass) pass
      run :: Gated (MemWiki MemDOM) a -> IO a
      run = runMemDOM . runGated rig0.gate wiki
  router <- run (Router.newRouter "/" Unknown route)
  container <- N.newElement Nothing (ElemName "div")
  H.HalogenSocket {H.query = send, H.dispose = disposeUI} <- run (runUI (parent feed router) () (N.fromNative container))
  let rig = rigWith (\r -> void (run (send (SetRevision r ())))) (run disposeUI)
      nodes = descendants container
      clickFirst c = nodes >>= withClass c >>= traverse_ click . take 1
      ui =
        Ui
          { clickBell = clickFirst "notifications-toggle"
          , clickMark = \i -> do
              unread <- nodes >>= withClass "notification" >>= filterM (hasClass "unread")
              for_ (atMay unread i) $ \r -> descendants r >>= withClass "notification-read" >>= traverse_ click . take 1
          , clickMarkAll = clickFirst "notifications-read-all"
          , clickLink = \i -> nodes >>= withClass "notification-link" >>= traverse_ click . (`atMay` i)
          , shown = shownIn container
          , settle = settleOn rig.gate
          }
  ui.settle
  pure (rig, ui)

-- | Run the program until it has done all it can: no tree has work, and
-- the fibers that wait are exactly the asks held in the gate and not yet
-- given their answer. A read of the runtime's activity, a millisecond
-- apart: the library has no call that returns at that moment. Once the
-- bell is disposed of, no tree is left, and the asks it held wait for
-- nothing: their fibers were cancelled. Every tree
-- in the process counts, so this spec runs alone.
settleOn :: TVar [Held] -> IO ()
settleOn gate = go (0 :: Int)
  where
    go tries = do
      a <- activity
      waitingNow <- length <$> readTVarIO gate
      if a.running == 0 && (a.waiting == waitingNow || a.trees == 0)
        then pass
        else
          if tries > 10_000
            then panic ("the bell did not settle: " <> show a <> ", held " <> show waitingNow)
            else threadDelay 1000 >> go (tries + 1)

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

-- | A run on the bell mounted afresh.
runOnDom :: Check -> [Step] -> IO (Maybe Text)
runOnDom how run = mount >>= \(rig, ui) -> runSteps how rig ui run

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
