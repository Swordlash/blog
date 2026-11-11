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
import Test.Browser.Http (Asked (..), answerRaw, answerWith, asked, holdAt, release, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (clickButton, slugs, startChangedWith)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (SpacesApi (..), WikiApi (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem.State (MemState (..), insertPage, savePageIn)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Id (PageId (..))
import Wiki.Core.Page (Page (body, template, updatedAt))
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

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = describe "tasks ticked in a page" $ do
  it "strikes a ticked task through at once, counts it, and saves one version that differs only in the box" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    before <- versionsOf wiki
    -- With no ticks the bar takes no room.
    computedStyle ".page-ticks" "display" `shouldReturn` "none"
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

  it "drops the ticks, and says so, when the reader becomes someone who may not edit, and moves the page only without ticks" $ runPage $ do
    (ui, _) <- page m "user-admin" tasksText
    box 0 ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    clickButton ui ".page-actions button" "Move"
    find ui ".page-view .error" >>= (`shouldHaveText` "Save or discard the ticked tasks first.")
    length <$> findAll ui ".inline-form" `shouldReturn` 0
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=reader]" >>= click
    eventually $ find ui ".page-ticks-note" >>= (`shouldHaveText` "You may no longer edit this page, so your tick was dropped.")
    length <$> findAll ui ".page-body input[data-task]" `shouldReturn` 0
    length <$> findAll ui ".page-ticks-count" `shouldReturn` 0
    find ui ".page-ticks-dismiss" >>= click
    eventually $ computedStyle ".page-ticks" "display" `shouldReturn` "none"

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

  it "keeps each box with its task when a sorted list moves it: ticking the first of two unticked tasks ticks it alone" $ runPage $ do
    (ui, _) <- page m "user-admin" tasksText
    eventually $ sortedLabels ui `shouldReturn` ["New", "Next", "Old"]
    box 5 ui >>= click
    eventually $ sortedLabels ui `shouldReturn` ["Next", "Old", "New"]
    -- In the order shown: Next not ticked, Old and New ticked.
    eventually $ sortedChecked ui `shouldReturn` [False, True, True]
    checked ui `shouldReturn` [False, False, False, False, True, True, False]
    -- And back: unticked, New goes up again, and only Old stays ticked.
    box 5 ui >>= click
    eventually $ sortedLabels ui `shouldReturn` ["New", "Next", "Old"]
    eventually $ sortedChecked ui `shouldReturn` [False, False, True]

  it "shows the view's state after a click it does not take, and after Discard" $ runPage $ do
    -- The parser reads the text in Unicode's composed form, so the box
    -- after a label written decomposed is not where the text has it: the
    -- tick is refused.
    (ui, wiki) <- page m "user-admin" "See[^e\x301].\n\n[^e\x301]: - [ ] Refused\n\n- [ ] Taken\n"
    box 1 ui >>= click
    eventually $ find ui ".page-ticks-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "was not found")
    eventually $ (box 1 ui >>= (`getProperty` "checked")) `shouldReturn` "false"
    length <$> findAll ui ".page-ticks-count" `shouldReturn` 0
    -- A box the view takes is ticked, and Discard unticks it again.
    box 0 ui >>= click
    eventually $ (box 0 ui >>= (`getProperty` "checked")) `shouldReturn` "true"
    find ui ".page-ticks-discard" >>= click
    eventually $ (box 0 ui >>= (`getProperty` "checked")) `shouldReturn` "false"
    (box 1 ui >>= (`getProperty` "checked")) `shouldReturn` "false"
    bodyOf wiki `shouldReturn` "See[^e\x301].\n\n[^e\x301]: - [ ] Refused\n\n- [ ] Taken\n"

  it "takes no tick while a form of the page is open, so a move cannot lose one" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    clickButton ui ".page-actions button" "Move"
    _ <- find ui ".inline-form"
    -- The first box, which carries no index while it is disabled.
    let firstBox = find ui ".page-body input[type='checkbox']"
    eventually $ (firstBox >>= (`getProperty` "disabled")) `shouldReturn` "true"
    length <$> findAll ui ".page-body input[data-task]" `shouldReturn` 0
    clickButton ui ".inline-form button" "Cancel"
    eventually $ (box 0 ui >>= (`getProperty` "disabled")) `shouldReturn` "false"
    bodyOf wiki `shouldReturn` tasksText

  it "keeps the page the reader went to when the answer about the page they left comes late" $ runPage $ do
    serverStarts
    serveDemo
    let guide = demoPage "markdown-guide"
        guideAt = endpointUrl (\e -> e.spaces.pageAt guide.space (slugs ["markdown-guide"]))
    -- The save meets a newer version, and the page as it is now is held.
    answerRaw "PUT" ("api/v1/pages/" <> guide.id.text) 409 "{\"error\":\"Conflict\",\"message\":\"Saved since.\"}"
    ui <- startServer m (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    -- The guide is long, and its islands many.
    eventuallyWithin 20000 (find ui ".page-body input[aria-label='Read it'][data-task]") >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    holdAt "GET" guideAt
    find ui ".page-ticks-save" >>= click
    eventually $ length . filter (\a -> a.method == "GET" && a.url == guideAt) <$> asked >>= (`shouldSatisfy` (>= 2))
    -- The reader goes to the space's home page meanwhile, in the same view.
    find ui ".breadcrumbs a[href$='#/s/docs/']" >>= click
    find ui ".leave-confirm button.danger" >>= click
    eventually $ find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    release
    settle
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    length <$> findAll ui ".page-ticks-note, .page-ticks-count" `shouldReturn` 0
    length <$> findAll ui ".page-body input[aria-label='Read it']" `shouldReturn` 0
    serverStops

  it "opens no form of the page while there are ticks, and keeps them through a render of the shell" $ runPage $ do
    (ui, wiki) <- page m "user-admin" tasksText
    box 0 ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    for_ ["Rename", "Delete", "Move"] $ \action -> do
      clickButton ui ".page-actions button" action
      find ui ".page-view .error" >>= (`shouldHaveText` "Save or discard the ticked tasks first.")
      length <$> findAll ui ".inline-form, .confirm" `shouldReturn` 0
    -- The page's width is the shell's: choosing it renders the shell,
    -- and the view with it.
    find ui ".page-width-option-full" >>= click
    eventually $ find ui ".page-view" >>= (`shouldHaveClass` "page-width-full")
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    (box 0 ui >>= (`getProperty` "checked")) `shouldReturn` "true"
    find ui ".page-ticks-save" >>= click
    eventually $ bodyOf wiki `shouldReturn` T.replace "- [ ] Buy milk" "- [x] Buy milk" tasksText

  it "keeps the page shown and the ticks when the page cannot be read again, and after" $ runPage $ do
    serverStarts
    serveDemo
    let guide = demoPage "markdown-guide"
        guideAt = endpointUrl (\e -> e.spaces.pageAt guide.space (slugs ["markdown-guide"]))
    answerWith "PUT" ("api/v1/pages/" <> guide.id.text <> "/template") 200 (guide :: Core.Page) {template = True}
    ui <- startServer m (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    readIt ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    -- "Use as template" reloads the wiki and the page, whose read fails.
    answerRaw "GET" guideAt 503 "<html>down for maintenance</html>"
    find ui ".use-as-template" >>= click
    eventually $ find ui ".page-ticks-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "could not be read again")
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    (readIt ui >>= (`getProperty` "checked")) `shouldReturn` "true"
    -- The next reload reads it, and the ticks are still there.
    answerWith "GET" guideAt 200 (guide :: Core.Page) {template = True}
    find ui ".use-as-template" >>= click
    eventually $ find ui ".use-as-template" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    (readIt ui >>= (`getProperty` "checked")) `shouldReturn` "true"
    serverStops

  it "keeps the ticks of a visit against a save of an earlier one that answers late" $ runPage $ do
    serverStarts
    serveDemo
    let guide = demoPage "markdown-guide"
        guideAt = endpointUrl (\e -> e.spaces.pageAt guide.space (slugs ["markdown-guide"]))
        saveAt = "api/v1/pages/" <> guide.id.text
        saved = (guide :: Core.Page) {body = T.replace "- [ ] Read it" "- [x] Read it" guide.body, updatedAt = addUTCTime 60 guide.updatedAt}
    answerWith "PUT" saveAt 200 saved
    holdAt "PUT" saveAt
    ui <- startServer m (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    readIt ui >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    find ui ".page-ticks-save" >>= click
    -- The save is slow; the reader leaves, comes back, and ticks again.
    find ui ".breadcrumbs a[href$='#/s/docs/']" >>= click
    find ui ".leave-confirm button.danger" >>= click
    eventually $ find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    find ui ".wiki-sidebar a[href$='#/s/docs/p/markdown-guide/']" >>= click
    eventuallyWithin 20000 (find ui ".page-body input[aria-label='Write the page'][data-task]") >>= click
    eventually $ find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    -- The first save lands: the page has its tick, and the new tick is
    -- kept, on the page as it is now.
    answerWith "GET" guideAt 200 saved
    release
    eventually $ (readIt ui >>= (`getProperty` "checked")) `shouldReturn` "true"
    eventually $ find ui ".page-ticks-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "kept on the new version")
    find ui ".page-ticks-count" >>= (`shouldHaveText` "1 box changed, not saved yet.")
    (find ui ".page-body input[aria-label='Write the page']" >>= (`getProperty` "checked")) `shouldReturn` "false"
    serverStops

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
    -- The tasks of the sorted list, in the order shown, and whether each
    -- box is ticked.
    sortedLabels ui = findAll ui ".page-body .sorted .task-text" >>= traverse textContent
    -- The Markdown guide's task "Read it", once the long guide is shown.
    readIt ui = eventuallyWithin 20000 (find ui ".page-body input[aria-label='Read it'][data-task]")
    sortedChecked ui = findAll ui ".page-body .sorted input" >>= traverse (fmap (== "true") . (`getProperty` "checked"))

-- | The page the tests tick: tasks under a task (indices 1 to 3), and a
-- sorted list (4 to 6) whose first task is done.
tasksText :: Text
tasksText =
  "# Tasks\n\n- [ ] Buy milk\n- [ ] Pack\n  - [ ] Shoes\n  - [ ] Coat\n\n{.sorted}\n- [x] Old\n- [ ] New\n- [ ] Next\n"

-- | A page of the demo, by its slug.
demoPage :: Text -> Core.Page
demoPage slug = fromMaybe (panic ("no page " <> slug)) (head [p | p <- Map.elems (demoState demoNow).pages, p.slug == fromMaybe (panic slug) (head (slugs [slug]))])

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
