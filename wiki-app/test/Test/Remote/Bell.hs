-- | The header's bell over haskell-halogen-remote: the real component,
-- under the gated in-memory backend ("Test.BellHarness"), mounted in this
-- process, its DOM shown in headless Chromium over a WebSocket, clicked
-- and read through the Playwright driver. The same runs as on the
-- in-memory DOM ("Test.BellDom"), checked the same way after each step.
--
-- How a step settles: a click settles in the driver (the page's probe,
-- answered by the session); an answer the test lets go from the gate is
-- not an action of the page's, so the test reads the session's activity
-- until it has nothing left to do but wait for the asks still held, and
-- then has the driver settle, which the page answers in order with the
-- batches the session sent.
module Test.Remote.Bell (spec) where

import Control.Concurrent.STM (TVar, readTVarIO)
import Data.IORef (readIORef)
import Data.NT (type (~>) (..))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.Activity (Activity (..))
import Halogen.Playwright (Locator, Page, Playwright, click, count, getAttribute, isDisabled, locator, nth, settle, textContent, visit)
import Halogen.Playwright.Hspec (SpecWith, inPage, it, shouldBe)
import Halogen.Remote.Session qualified as Session
import Halogen.Remote.Test (Mounted (..), TestServer, mountingEach, queryComponent)
import Halogen.Router qualified as Router
import Protolude
import Test.Bell (Step (..), genRun, shrinkRun)
import Test.BellHarness (Check (..), Held, Query (..), Rig (..), Shown (..), Ui (..), newRig, parent, runGated, runSteps)
import Test.QuickCheck (counterexample, forAllShrinkShow, ioProperty, withNumTests, (===))
import Test.QuickCheck qualified as QC
import Wiki.App.Backend.Mem (newMemWiki)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route (..), route)

-- | The bell mounted for a page, over the wire, with its page.
mount :: TestServer -> Page -> IO (Rig, Ui)
mount server page = do
  wiki <- newMemWiki (demoState demoNow)
  (feed, rigWith) <- newRig
  let gate = (rigWith (\_ -> pass) pass).gate
  (address, next) <- mountingEach server $ do
    base <- Router.pageBase
    router <- Router.newRouter base Unknown route
    pure (H.hoist (NT (runGated gate wiki)) (parent feed router), ())
  visit page address
  mounted <- next
  let rig = rigWith (\r -> void (queryComponent mounted (SetRevision r ()))) (disposed (rigWith (\_ -> pass) pass).listening)
      -- The session disposed of, and then the bell's finalizer waited
      -- for, read from the feed's listeners a millisecond apart: in two
      -- runs of about a hundred the feed was still listened to just after
      -- the session's dispose returned, and nothing else says when the
      -- finalizer has run.
      disposed ref = do
        Session.dispose mounted.session
        let pending k = do
              n <- readIORef ref
              unless (n == 0 || k > 2000) (threadDelay 1000 >> pending (k + 1))
        pending (0 :: Int)
      at = locator page
      clickIf l = do
        n <- count l
        when (n > 0) $ do
          off <- isDisabled (nth 0 l)
          unless off (click (nth 0 l))
      ui =
        Ui
          { clickBell = clickIf (at ".notifications-toggle")
          , clickMark = \i -> do
              n <- count (at ".notification.unread")
              when (i < n) (clickIf (locator (nth i (at ".notification.unread")) ".notification-read"))
          , clickMarkAll = clickIf (at ".notifications-read-all")
          , clickLink = \i -> do
              n <- count (at ".notification-link")
              when (i < n) (click (nth i (at ".notification-link")))
          , shown = shownOn page
          , settle = settleOver mounted.session gate page
          }
  ui.settle
  pure (rig, ui)

-- | Read the session until no work is left and the fibers that wait are
-- the asks held, a millisecond apart, then have the driver settle the
-- page.
settleOver :: Session.Session -> TVar [Held] -> Page -> IO ()
settleOver session gate page = go (0 :: Int)
  where
    go tries = do
      a <- Session.activity session
      waitingNow <- length <$> readTVarIO gate
      if a.running == 0 && (a.waiting == waitingNow || a.trees == 0)
        then settle page
        else
          if tries > 10_000
            then panic ("the bell did not settle: " <> show a <> ", held " <> show waitingNow)
            else threadDelay 1000 >> go (tries + 1)

-- | What the bell shows, read from the page.
shownOn :: Page -> IO Shown
shownOn page = do
  let at = locator page
  counts <- count (at ".notifications-count")
  shownCount <- if counts > 0 then fromMaybe 0 . readMaybe <$> textContent (nth 0 (at ".notifications-count")) else pure 0
  open <- (> 0) <$> count (at ".notifications-panel")
  n <- count (at ".notification")
  rows <- for [0 .. n - 1] $ \i -> row (nth i (at ".notification"))
  buttons <- count (at ".notification-read")
  disabled <- for [0 .. buttons - 1] $ \i -> isDisabled (nth i (at ".notification-read"))
  pure Shown {count = shownCount, open, rows, busy = or disabled}
  where
    row :: Locator -> IO (Int, Bool)
    row r = do
      href <- fromMaybe "" <$> getAttribute (locator r ".notification-link") "href"
      classes <- fromMaybe "" <$> getAttribute r "class"
      pure (numberOf href, "unread" `elem` T.words classes)
    -- The notification's number in its link, "…/s/blog/p/page-<k>/".
    numberOf href = fromMaybe (-1) (readMaybe (T.takeWhileEnd (/= '-') (T.dropWhileEnd (== '/') href)))

-- | A run on the bell mounted afresh for the page.
runOver :: TestServer -> Page -> [Step] -> IO (Maybe Text)
runOver server page run = mount server page >>= \(rig, ui) -> runSteps BesideMachine rig ui run

spec :: TestServer -> SpecWith Playwright
spec server = do
  it "counts a notification the live channel tells of, lists it when opened, and marks it read" $ inPage $ \page ->
    runOver server page [Handle, Deliver 0, Make, Tell, ClickBell, Handle, Deliver 0, ClickMark 0, Handle, Deliver 0] >>= (`shouldBe` Nothing)

  it "keeps a notification listed when an older read is answered last" $ inPage $ \page ->
    runOver server page [Handle, Make, ClickBell, Handle, Deliver 1, Deliver 0] >>= (`shouldBe` Nothing)

  it "keeps a notification read when a read asked before the mark is answered after it" $ inPage $ \page ->
    runOver server page [Make, Handle, Deliver 0, ClickBell, ClickMark 0, Handle, Handle, Deliver 1, Deliver 0] >>= (`shouldBe` Nothing)

  it "keeps the buttons that mark disabled until the last mark out comes back" $ inPage $ \page ->
    runOver server page [ClickBell, Make, Handle, Handle, Deliver 0, ClickMarkAll, ClickLink 0, Handle, Deliver 1] >>= (`shouldBe` Nothing)

  it "shows what its machine shows after every step of twenty generated runs" $ \pw -> do
    result <-
      QC.quickCheckResult . withNumTests 20 $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          ioProperty . flip inPage pw $ \page -> do
            outcome <- runOver server page run
            pure (counterexample (toS (fromMaybe "" outcome)) (outcome === Nothing))
    QC.isSuccess result `shouldBe` True
