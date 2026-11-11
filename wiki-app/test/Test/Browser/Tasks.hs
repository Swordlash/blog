{-# LANGUAGE TemplateHaskell #-}

-- | Tasks ticked in a page, in a browser, over the demo's wiki (WP5.91 of
-- docs/PLAN.md): a reader who may edit ticks a task, which is struck
-- through at once and counted in the bar of unsaved ticks; the rules for
-- the tasks under a task; "Save" writes one version that differs from the
-- page only in its boxes, and "Discard" drops the ticks; a reader who may
-- not edit, and a version of the page, have disabled boxes; leaving with
-- unsaved ticks asks, as leaving the editor does; a save after the page
-- was saved elsewhere does not overwrite it; a sorted list moves a done
-- task down and ticks the box the source has; and the boxes are reached
-- with Tab and ticked with Space.
module Test.Browser.Tasks (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startChangedWith)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), insertPage, savePageIn)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page qualified as Core
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space qualified as Core

-- Which element has the focus (test/jsbits/test-focus.js), and how the
-- style sheet draws an element (test/jsbits/test-style.js).
$( browserJS
     ["jsbits/test-focus.js", "jsbits/test-style.js"]
     [ ("js_focused_matches", "wiki_test_focused_matches", Safe, [t|JSText -> IO Bool|])
     , ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = describe "tasks ticked in a page" $ do
  it "strikes a ticked task through at once, counts it, and saves one version that differs only in the box" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    before <- versionsOf wiki
    box 0 ui >>= click
    eventually $ find ui ".page-body li.task-done .task-text" >>= (`shouldHaveText` "Buy milk")
    computedStyle ".page-body li.task-done > .task-text" "text-decoration-line" `shouldReturn` "line-through"
    -- The tasks under a task are not struck through with it.
    computedStyle ".page-body li:not(.task-done) > .task-text" "text-decoration-line" `shouldReturn` "none"
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    -- Nothing is saved yet.
    bodyOf wiki `shouldReturn` tasksText
    find ui ".page-ticks-save" >>= click
    eventually $ length <$> findAll ui ".page-ticks-count" `shouldReturn` 0
    bodyOf wiki `shouldReturn` T.replace "- [ ] Buy milk" "- [x] Buy milk" tasksText
    versionsOf wiki `shouldReturn` before + 1
    -- The page shows the box as saved.
    box 0 ui >>= \b -> getProperty b "checked" `shouldReturn` "true"

  it "ticks the tasks under a task with it, and the task with the last of them, and Discard drops the ticks" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    box 1 ui >>= click
    eventually $ checked ui `shouldReturn` [False, True, True, True, True, False, False]
    find ui ".page-ticks-count" >>= (`shouldHaveText` "3 boxes changed, not saved yet.")
    -- Unticking one under it unticks it.
    box 2 ui >>= click
    eventually $ checked ui `shouldReturn` [False, False, False, True, True, False, False]
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    -- Ticking the last one under it ticks it again.
    box 2 ui >>= click
    eventually $ checked ui `shouldReturn` [False, True, True, True, True, False, False]
    find ui ".page-ticks-discard" >>= click
    eventually $ checked ui `shouldReturn` [False, False, False, False, True, False, False]
    length <$> findAll ui ".page-ticks-count" `shouldReturn` 0
    bodyOf wiki `shouldReturn` tasksText

  it "keeps the boxes disabled for a reader who may not edit, and in a version of the page" $ runPage $ do
    (ui, _) <- page m "user-reader" tasksText
    _ <- find ui ".page-body input[type='checkbox']"
    -- Once the program runs, when an editor's boxes are enabled.
    settle
    findAll ui ".page-body input[type='checkbox']" >>= traverse (`getProperty` "disabled") >>= (`shouldSatisfy` all (== "true"))
    length <$> findAll ui ".page-body input[data-task]" `shouldReturn` 0
    unmount ui
    (version, _) <- startChangedWith m (withTasksPage tasksText) (Just "user-admin") (PageAtVersion projects (slugs ["tasks"]) demoNow)
    _ <- find version ".version-note"
    settle
    findAll version ".page-body input[type='checkbox']" >>= traverse (`getProperty` "disabled") >>= (`shouldSatisfy` \ds -> not (null ds) && all (== "true") ds)

  it "asks before leaving the page with unsaved ticks: Stay keeps them, Leave drops them" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    box 0 ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    find ui ".wiki-brand" >>= click
    find ui ".leave-confirm p" >>= (`shouldHaveText` "This page has ticked tasks that are not saved. Leave the page and lose them?")
    clickButton ui ".leave-confirm button" "Stay"
    eventually $ length <$> findAll ui ".leave-confirm" `shouldReturn` 0
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    box 0 ui >>= \b -> getProperty b "checked" `shouldReturn` "true"
    find ui ".wiki-brand" >>= click
    _ <- find ui ".leave-confirm"
    find ui ".leave-confirm button.danger" >>= click
    eventually $ length <$> findAll ui ".page-view .page-body input[data-task]" `shouldReturn` 0
    bodyOf wiki `shouldReturn` tasksText

  it "does not overwrite a page saved elsewhere: keeps the ticks on it when its tasks are the same, and offers a reload when not" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    box 0 ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    -- Someone saves the page with the same tasks.
    let theirs = T.replace "# Tasks" "# Tasks\n\nA new line." tasksText
    saveBehind wiki 60 theirs
    find ui ".page-ticks-save" >>= click
    eventually $ find ui ".page-ticks-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "your ticks are kept on the new version")
    bodyOf wiki `shouldReturn` theirs
    find ui ".page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A new line.")
    find ui ".page-ticks-save" >>= click
    eventually $ bodyOf wiki `shouldReturn` T.replace "- [ ] Buy milk" "- [x] Buy milk" theirs
    -- Someone saves it with other tasks: nothing is saved.
    box 5 ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    now <- bodyOf wiki
    let other = now <> "- [ ] Another task\n"
    saveBehind wiki 120 other
    find ui ".page-ticks-save" >>= click
    eventually $ find ui ".page-ticks-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "its tasks are not the same now")
    bodyOf wiki `shouldReturn` other
    find ui ".page-ticks-reload" >>= click
    eventually $ find ui ".page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Another task")
    length <$> findAll ui ".page-ticks-count" `shouldReturn` 0

  it "shows a sorted list's done tasks last, and ticks the box the source has" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    eventually $ sortedLabels ui `shouldReturn` ["New", "Next", "Old"]
    box 6 ui >>= click
    eventually $ sortedLabels ui `shouldReturn` ["New", "Old", "Next"]
    find ui ".page-ticks-save" >>= click
    eventually $ bodyOf wiki `shouldReturn` T.replace "- [ ] Next" "- [x] Next" tasksText

  it "reaches the boxes with Tab and ticks them with Space" $ runPage $ do
    (ui, _) <- page m "user-admin" tasksText
    box 0 ui >>= focus
    press "Space"
    eventually $ box 0 ui >>= \b -> getProperty b "checked" `shouldReturn` "true"
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    press "Tab"
    eventually $ focusedIs ".page-body input[data-task='1']" `shouldReturn` True
    press "Space"
    eventually $ checked ui `shouldReturn` [True, True, True, True, True, False, False]
    -- The bar's buttons are buttons, in the order of the page.
    (findAll ui ".page-ticks button" >>= traverse textContent) `shouldReturn` ["Save", "Discard"]
    find ui ".page-ticks" >>= \bar -> getAttribute bar "role" `shouldReturn` Just "status"
  where
    focusedIs selector = unsafeIOToPageM (js_focused_matches (toJSText selector))
    computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))
    -- The box of the task with this index.
    box :: Int -> Mounted s q o n -> PageM s (Element s)
    box i ui = find ui (".page-body input[data-task='" <> show i <> "']")
    -- Whether each box is ticked, by the tasks' indices.
    checked ui = for [0 .. 6] $ \i -> (== "true") <$> (box i ui >>= (`getProperty` "checked"))
    -- The tasks of the sorted list, in the order shown.
    sortedLabels ui = findAll ui ".page-body .sorted .task-text" >>= traverse textContent

-- | The page the tests tick: tasks under a task (indices 1 to 3), and a
-- sorted list (4 to 6) whose first task is done.
tasksText :: Text
tasksText =
  "# Tasks\n\n- [ ] Buy milk\n- [ ] Pack\n  - [ ] Shoes\n  - [ ] Coat\n\n{.sorted}\n- [x] Old\n- [ ] New\n- [ ] Next\n"

-- | The demo's Projects space.
projects :: [Slug]
projects = slugs ["team", "projects"]

-- | The demo with a page "Tasks" of this text in its Projects space, shown
-- to someone.
page
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> Text
  -> PageM s (Mounted s Shell.Query Void m, IORef MemState)
page m who body = do
  started <- startChangedWith m (withTasksPage body) (Just who) (Page projects (slugs ["tasks"]))
  _ <- find (fst started) ".page-body .task-list"
  pure started

withTasksPage :: Text -> MemState -> MemState
withTasksPage body st = case head (filter (\s -> s.name == "Projects") (Map.elems st.spaces)) of
  Just (s :: Core.Space) -> fst (insertPage s.id Nothing "Tasks" body demoNow st)
  Nothing -> panic "the demo has no space Projects"

-- | The page "Tasks" as the wiki holds it.
tasksPage :: IORef MemState -> PageM s Core.Page
tasksPage wiki = do
  st <- unsafeIOToPageM (readIORef wiki)
  maybe (panic "no page Tasks") pure (head [p | p <- Map.elems st.pages, p.title == "Tasks"])

bodyOf :: IORef MemState -> PageM s Text
bodyOf wiki = (\p -> p.body) <$> tasksPage wiki

-- | How many versions the wiki keeps of the page.
versionsOf :: IORef MemState -> PageM s Int
versionsOf wiki = do
  p <- tasksPage wiki
  st <- unsafeIOToPageM (readIORef wiki)
  pure (maybe 0 Map.size (Map.lookup p.id st.versions))

-- | The page saved with this text behind the view's back, as someone else
-- saving it, this many seconds after the demo's time.
saveBehind :: IORef MemState -> Integer -> Text -> PageM s ()
saveBehind wiki seconds body = do
  p <- tasksPage wiki
  unsafeIOToPageM $ modifyIORef' wiki $ \st ->
    either (panic . show) fst (savePageIn p.id p.updatedAt p.title body (addUTCTime (fromInteger seconds) demoNow) st)
