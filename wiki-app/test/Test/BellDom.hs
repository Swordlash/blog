-- | The header's bell ("Wiki.App.View.Bell"), the real component, mounted
-- on haskell-halogen's in-memory DOM ("Test.Harness.MemDom") and driven by
-- the same generated runs as its machine ("Test.Bell"). A click, a press
-- outside the bell and a key are events dispatched as in a page; the live
-- channel is a feed the test tells through; the backend holds every read
-- and mark of the notifications in a gate until the test gives its answer
-- ('Gated'). After each step the test waits until the program has nothing
-- left to do but wait for the asks held ('settleHolding'), and reads what
-- the bell shows: the count, the rows with their unread mark, whether the
-- buttons that mark are disabled.
--
-- After each step the DOM must show what the machine shows after the same
-- step, and the rules of "Test.Bell" are checked on what the DOM shows.
module Test.BellDom (spec) where

import Data.Aeson (object)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Protolude hiding (State, find)
import Test.Bell (Step (..), genRun, shrinkRun)
import Test.BellHarness (Check (..), Gated, Query (..), Rig (..), Shown (..), Ui (..), newRig, parent, runGated, runSteps)
import Test.Harness.MemDom (View (..), answer, click, clickAt, find, findAll, heldCount, heldNow, keyDown, pending, pressOutside, query, release, settle, settleHolding, textOf, withHeldWaits, withView)
import Test.Hspec hiding (pending)
import Test.QuickCheck (counterexample, forAllShrinkShow, ioProperty, withNumTests, (===))
import Test.QuickCheck qualified as QC
import Wiki.Api.Notifications (Notifications (..))
import Wiki.App.Backend (anonymousIn)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route (..), route)
import Wiki.App.View.Bell qualified as Bell
import Wiki.App.View.Common (Context (..), PageWidth (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (NotificationId (..), PageId (..), UserId (..))
import Wiki.Core.Notification (Kind (..), Notification (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Version (Author (..))

-- | The bell mounted for the body, under the gated in-memory backend, with
-- its page; disposed of after it.
withBell :: (Rig -> Ui -> View Query -> IO a) -> IO a
withBell body = do
  wiki <- newMemWiki (demoState demoNow)
  (feed, rigWith) <- newRig
  let gate = (rigWith (\_ -> pass) pass).gate
      run :: Gated (MemWiki MemDOM) a -> IO a
      run = runMemDOM . runGated gate wiki
  router <- run (Router.newRouter "/" Unknown route)
  withView run (parent feed router) () $ \view -> do
    let rig = rigWith (\r -> void (query view (SetRevision r ()))) (view.dispose >> Router.stop router)
        ui =
          Ui
            { clickBell = void (click view ".notifications-toggle")
            , clickMark = \i -> do
                unread <- findAll view ".notification.unread"
                for_ (atMay unread i) (N.querySelector ".notification-read" >=> traverse_ clickAt)
            , clickMarkAll = void (click view ".notifications-read-all")
            , clickLink = \i -> findAll view ".notification-link" >>= traverse_ clickAt . (`atMay` i)
            , pressOutside = pressOutside view
            , shown = shownIn view
            , settle = settleHolding view (heldCount gate)
            }
    ui.settle
    body rig ui view

-- | What the bell shows, read from the DOM. With no row unread there is no
-- "Mark read" to read the busy flag from, and "Mark all read" is disabled
-- for nothing unread as well, so the flag reads as not busy.
shownIn :: View q -> IO Shown
shownIn view = do
  count <- maybe 0 (fromMaybe 0 . readMaybe) <$> textOf view ".notifications-count"
  open <- isJust <$> find view ".notifications-panel"
  rows <- findAll view ".notification" >>= traverse row
  marking <- findAll view ".notification-read" >>= fmap (any isJust) . traverse (N.attribute "disabled")
  pure Shown {count, open, rows, busy = marking}
  where
    row r = do
      href <- N.querySelector ".notification-link" r >>= fmap join . traverse (N.attribute "href")
      unread <- elem "unread" . maybe [] T.words <$> N.attribute "class" r
      pure (maybe (-1) numberOf href, unread)
    -- The notification's number in its link, "/s/blog/p/page-<k>/".
    numberOf :: Text -> Int
    numberOf href = fromMaybe (-1) (readMaybe (T.takeWhile (/= '/') (snd (T.breakOnEnd "page-" href))))

-- | A run on the bell mounted afresh.
runOnDom :: Check -> [Step] -> IO (Maybe Text)
runOnDom how run = withBell (\rig ui _ -> runSteps how rig ui run)

-- | Whether the bell's list is open.
isOpen :: View q -> IO Bool
isOpen view = isJust <$> find view ".notifications-panel"

-- | The bell opened with its list read: the first read answered with
-- nothing, the list opened, and the read that opening asks answered too.
opened :: Rig -> Ui -> View q -> IO ()
opened rig ui view = do
  answerAll
  ui.clickBell
  ui.settle
  answerAll
  isOpen view `shouldReturn` True
  where
    answerAll = do
      heldNow rig.gate >>= traverse_ (\h -> answer rig.gate h (Right Notifications {unread = 0, items = []}))
      ui.settle

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

  -- Three orders the bell's suite over haskell-halogen-remote ran in
  -- Chromium, kept here by name: that suite showed nothing more.
  it "keeps a notification listed when an older read is answered last" $
    runOnDom BesideMachine [Handle, Make, ClickBell, Handle, Deliver 1, Deliver 0] `shouldReturn` Nothing

  it "keeps a notification read when a read asked before the mark is answered after it" $
    runOnDom BesideMachine [Make, Handle, Deliver 0, ClickBell, ClickMark 0, Handle, Handle, Deliver 1, Deliver 0] `shouldReturn` Nothing

  it "keeps the buttons that mark disabled until the last mark out comes back" $
    runOnDom BesideMachine [ClickBell, Make, Handle, Handle, Deliver 0, ClickMarkAll, ClickLink 0, Handle, Deliver 1] `shouldReturn` Nothing

  it "closes its list on a press outside it, and not on one inside" $
    withBell $ \rig ui view -> do
      opened rig ui view
      find view ".notifications-panel h2" >>= traverse_ (N.dispatch "pointerdown" (object []))
      ui.settle
      isOpen view `shouldReturn` True
      pressOutside view
      ui.settle
      isOpen view `shouldReturn` False

  -- A reader's click on the bell's button is a press and then a click:
  -- the press is inside, so the list is not closed by it and opened again
  -- by the click.
  it "closes its list on its own button once, without opening it again" $
    withBell $ \rig ui view -> do
      opened rig ui view
      find view ".notifications-toggle" >>= traverse_ (\b -> N.dispatch "pointerdown" (object []) b >> clickAt b)
      ui.settle
      isOpen view `shouldReturn` False
      textOf view ".notifications-toggle[aria-expanded=false] .notifications-bell" `shouldReturn` Just "🔔"

  it "closes its list on Escape pressed anywhere in the page, and not on another key" $
    withBell $ \rig ui view -> do
      opened rig ui view
      keyDown "Enter" [] view.container
      ui.settle
      isOpen view `shouldReturn` True
      keyDown "Escape" [] view.container
      ui.settle
      isOpen view `shouldReturn` False

  -- The library's held waits, over the in-memory backend's own answers:
  -- each ask of the bell is held before it starts, and runs when let go.
  it "keeps its buttons that mark disabled while a mark is held, and marks read once it is let go, over the in-memory backend" $
    withHeldWaits $ \waits -> do
      let rita = UserId "user-reader"
          demo = demoState demoNow
          -- The demo's blog post, which the reader may read.
          hello = fromMaybe (PageId "") (head [p.id | p <- Map.elems demo.pages, p.title == "Hello, world"])
          told =
            Notification
              { id = NotificationId "n1"
              , kind = Replied
              , page = hello
              , thread = Nothing
              , actor = Author {id = UserId "user-editor", name = "Ed Editor", avatar = Nothing}
              , title = "Hello, world"
              , excerpt = "Thanks."
              , createdAt = UTCTime (fromGregorian 2026 10 26) 0
              , read = False
              , location = Nothing
              }
      wiki <- newMemWiki demo {current = Just rita, notices = Map.singleton rita [told]}
      let run :: MemWiki MemDOM a -> IO a
          run = runMemDOM . runMemWiki wiki
      router <- run (Router.newRouter "/" Unknown route)
      let ctx = Context {router, session = anonymousIn Open, spaces = [], icons = mempty, revision = 0, pageWidth = Compact}
      withView run Bell.component Bell.Input {context = ctx, feed = Nothing} $ \view -> do
        -- The in-memory backend answered the first read at once.
        (length <$> pending waits) `shouldReturn` 0
        textOf view ".notifications-count" `shouldReturn` Just "1"
        -- Opening the list reads it again.
        void (click view ".notifications-toggle")
        pending waits >>= traverse_ release
        settle view
        void (click view ".notification-read")
        [mark] <- pending waits
        find view ".notification-read" >>= fmap join . traverse (N.attribute "disabled") >>= (`shouldBe` Just "")
        find view ".notifications-read-all" >>= fmap join . traverse (N.attribute "disabled") >>= (`shouldBe` Just "")
        release mark
        settle view
        textOf view ".notifications-count" `shouldReturn` Nothing
        findAll view ".notification.unread" >>= (`shouldBe` 0) . length
      Router.stop router
