{-# LANGUAGE TemplateHaskell #-}

-- | The editor in a browser, in the shell, over the demo's wiki: typing
-- Markdown and seeing the preview follow, saving (and staying, or closing)
-- and reading the page back from the backend, a new page made from its
-- title and given a file before anything is saved, leaving with and without
-- unsaved changes, Cancel keeping or discarding the draft, a save over
-- someone else's and the conflict view's three ways out of it (keep mine,
-- take theirs, merge by hand), files attached by a drop, a paste or a file input, text
-- pasted, the toolbar and
-- its shortcuts, and the preview shown on its own or beside the Markdown.
module Test.Browser.Editor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Text qualified as T
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (clickButton, slugs, startChanged, startWith)
import Test.Browser.Text (clearBody, completing, editorSelection, editorText, markdown, mathIn, setMarkdown)
import Test.Hspec.Halogen
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..), insertUser)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Attachment (Attachment (name), FileName (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Markdown.Ast (Block (..), Inline (..), parseMarkdown)
import Wiki.Core.Markdown.Box (BoxKind (..))
import Wiki.Core.Page (Page (attachments, body, id, title, updatedAt))
import Wiki.Core.Space (Space (id, mathMacros))
import Wiki.Core.User (Login (..), User (..))

-- The page has no file dialog the harness can answer, so a test hands the
-- editor a file the way the browser would: test/jsbits/test-files.js.
-- Whether a key reached the browser is read by a listener of its own:
-- test/jsbits/test-keys.js. The colour the style sheet gives an element:
-- test/jsbits/test-style.js.
$( browserJS
     ["jsbits/test-files.js", "jsbits/test-keys.js", "jsbits/test-style.js"]
     [ ("js_drop_filePromise", "wiki_test_drop_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     , ("js_pastePromise", "wiki_test_paste", Safe, [t|JSText -> JSText -> JSText -> JSText -> JSText -> IO (Promise Bool)|])
     , ("js_choose_filePromise", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     , ("js_watch_keys", "wiki_test_watch_keys", Safe, [t|IO ()|])
     , ("js_last_key_prevented", "wiki_test_last_key_prevented", Safe, [t|IO Bool|])
     , ("js_computed_colour", "wiki_test_computed_colour", Safe, [t|JSText -> IO JSText|])
     , ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

js_drop_file :: JSText -> JSText -> JSText -> JSText -> IO ()
js_drop_file a1 a2 a3 a4 = if inBrowser then wait =<< js_drop_filePromise a1 a2 a3 a4 else pure inert

js_paste :: JSText -> JSText -> JSText -> JSText -> JSText -> IO Bool
js_paste a1 a2 a3 a4 a5 = if inBrowser then wait =<< js_pastePromise a1 a2 a3 a4 a5 else pure inert

js_choose_file :: JSText -> JSText -> JSText -> JSText -> IO ()
js_choose_file a1 a2 a3 a4 = if inBrowser then wait =<< js_choose_filePromise a1 a2 a3 a4 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "previews what is typed, with its formulas drawn, and saves it" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Euler: $e^{i\\pi} + 1 = 0$"
    find ui ".editor-preview .page-body h1" >>= (`shouldHaveText` "Hello, world")
    formula <- find ui ".editor-preview .wiki-math-inline .katex"
    findIn formula "annotation" >>= (`shouldHaveText` "e^{i\\pi} + 1 = 0")
    -- More typing redraws the preview, but not a formula it has not touched.
    island <- find ui ".editor-preview .wiki-math-inline"
    typeText text "\n\nAnd more."
    eventually $ find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "And more.")
    find ui ".editor-preview .wiki-math-inline" >>= (`shouldBeSameElement` island)
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    _ <- find ui ".page-view .wiki-math-inline .katex"
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello, world\n\nEuler: $e^{i\\pi} + 1 = 0$\n\nAnd more."

  it "saves with Ctrl+S and stays, saying Saved for a while, and indents with Tab" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    notice <- find ui ".editor-saved-notice"
    getAttribute notice "role" `shouldReturn` Just "status"
    notice `shouldHaveText` ""
    clearBody ui
    typeText text "- a list"
    press "Enter"
    press "Tab"
    typeText text "- nested"
    markdown ui `shouldReturn` "# Hello, world\n\n- a list\n  - nested"
    press "Control+s"
    notice `shouldHaveText` "Saved"
    -- The focus is still in the text after the save.
    press "x"
    markdown ui `shouldReturn` "# Hello, world\n\n- a list\n  - nestedx"
    press "Backspace"
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello, world\n\n- a list\n  - nested"
    -- Still the same text, with the cursor where it was.
    editorText ui >>= (`shouldBeSameElement` text)
    typeText text "\n- more"
    -- The notice goes by itself.
    eventuallyWithin 6000 (notice `shouldHaveText` "")
    -- A second save is made against the first: no conflict.
    press "Control+s"
    notice `shouldHaveText` "Saved"
    length <$> findAll ui ".error-conflict" `shouldReturn` 0
    again <- readPage wiki ["blog"] ["hello-world"]
    again.body `shouldBe` "# Hello, world\n\n- a list\n  - nested\n- more"
    again.updatedAt `shouldSatisfy` (> saved.updatedAt)

  it "saves, saves again, and shows the page after Save and close" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "One."
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    typeText text " Two."
    find ui ".editor-save" >>= click
    eventually $ (\p -> p.body) <$> readPage wiki ["blog"] ["hello-world"] >>= (`shouldBe` "# Hello, world\n\nOne. Two.")
    typeText text " Three."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "One. Two. Three.")
    length <$> findAll ui ".error-conflict" `shouldReturn` 0

  it "writes a new page from the space's New page, made from its title first" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (SpacePages (slugs ["blog"]))
    find ui ".space-view .actions a[href$='#/s/blog/new-page/']" >>= click
    find ui ".new-page-view h1" >>= (`shouldHaveText` "New page in Blog")
    find ui ".new-page-title" >>= (`typeText` "Third post")
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Third post")
    -- Made, empty, before anything is written.
    made <- readPage wiki ["blog"] ["third-post"]
    made.body `shouldBe` ""
    find ui ".editor-title-text" >>= (`shouldHaveText` "Third post")
    editorText ui >>= (`typeText` "Some **news**.")
    -- Shown on its own, the preview has the draft at once; Save is there.
    find ui ".editor-show-preview" >>= click
    -- The title line is the page's title, shown once.
    find ui ".editor-preview .page-body h1" >>= (`shouldHaveText` "Third post")
    length <$> findAll ui ".editor-preview .page-title" `shouldReturn` 0
    find ui ".editor-preview .page-body strong" >>= (`shouldHaveText` "news")
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Third post")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Third post")
    created <- readPage wiki ["blog"] ["third-post"]
    created.body `shouldBe` "# Third post\n\nSome **news**."

  it "writes a new page under another from its New subpage" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-view .actions a[href$='#/s/blog/new-page/hello-world/']" >>= click
    find ui ".new-page-view h1" >>= (`shouldHaveText` "New page under Hello, world")
    find ui ".new-page-title" >>= (`typeText` "Follow-up")
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Follow-up")
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Follow-up")
    created <- readPage wiki ["blog"] ["hello-world", "follow-up"]
    created.title `shouldBe` "Follow-up"
    created.body `shouldBe` "# Follow-up\n\n"

  it "attaches a file to a new page before anything is saved" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (NewPage (slugs ["blog"]) Nothing)
    find ui ".new-page-title" >>= (`typeText` "With a picture")
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing With a picture")
    length <$> findAll ui ".editor-attach.disabled" `shouldReturn` 0
    -- Once CodeMirror has the text, which the reference goes into.
    _ <- editorText ui
    unsafeIOToPageM (chooseFile ".editor-attach input" "dot.png" "image/png" dotPng)
    settle
    eventually $ markdown ui `shouldReturn` "# With a picture\n\n![dot.png](attachment:dot.png)"
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-hint" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "first"))
    attached <- readPage wiki ["blog"] ["with-a-picture"]
    map (\a -> a.name.text) attached.attachments `shouldBe` ["dot.png"]
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    pass

  it "asks on Cancel with changes whether to keep the draft, and keeps it or not as told" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Kept for later."
    find ui ".editor-cancel" >>= click
    _ <- find ui ".editor-cancel-confirm"
    -- Going on editing leaves everything as it was.
    clickButton ui ".editor-cancel-confirm button" "Go on editing"
    length <$> findAll ui ".editor-cancel-confirm" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nKept for later."
    editorText ui >>= (`shouldBeSameElement` text)
    find ui ".editor-cancel" >>= click
    clickButton ui ".editor-cancel-confirm button" "Keep the draft"
    -- Gone to the page, without being asked again whether to leave.
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0
    -- The draft is there the next time, and readers never see it.
    unchanged <- readPage wiki ["blog"] ["hello-world"]
    unchanged.body `shouldSatisfy` T.isPrefixOf "# Hello, world"
    find ui ".page-view .actions a[href$='/edit/']" >>= click
    find ui ".editor-draft-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Restored your unsaved draft from")
    markdown ui `shouldReturn` "# Hello, world\n\nKept for later."
    -- This time the changes are let go, and the draft with them.
    find ui ".editor-cancel" >>= click
    clickButton ui ".editor-cancel-confirm button" "Discard my changes"
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    find ui ".page-view .actions a[href$='/edit/']" >>= click
    markdown ui >>= (`shouldSatisfy` T.isPrefixOf "# Hello, world")
    length <$> findAll ui ".editor-draft-found" `shouldReturn` 0

  it "goes back to the page on Cancel when nothing has changed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-cancel" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0

  it "asks before leaving unsaved changes, and stays or leaves as told" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Draft"
    find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/notes-on-haskell/']" >>= click
    _ <- find ui ".leave-confirm"
    clickButton ui ".leave-confirm button" "Stay"
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nDraft"
    -- Again, and leaving goes there; the work is lost.
    find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/notes-on-haskell/']" >>= click
    find ui ".leave-confirm button.danger" >>= click
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Notes on Haskell")
    unchanged <- readPage wiki ["blog"] ["hello-world"]
    unchanged.body `shouldSatisfy` T.isPrefixOf "# Hello, world"

  it "opens the conflict view on a save over someone else's, keeping the text as a draft, and keeps mine" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    page <- someoneElseSaves wiki
    clearBody ui
    typeText text "My words."
    find ui ".editor-save" >>= click
    -- Their version, compared with the author's text, beside it.
    find ui ".editor-conflict" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Ada Admin saved this page")
    find ui ".editor-form" >>= (`shouldHaveClass` "conflicting")
    find ui ".editor-conflict-pane h2" >>= (`shouldHaveText` "Their version, compared with yours")
    find ui ".editor-conflict-pane .diff-removed .diff-text" >>= (`shouldHaveText` "My words.")
    find ui ".editor-conflict-pane .diff-added .diff-text" >>= (`shouldHaveText` "Someone else's words.")
    length <$> findAll ui ".error-conflict" `shouldReturn` 0
    -- Nothing is lost meanwhile: the text is in the editor and in the draft.
    markdown ui `shouldReturn` "# Hello, world\n\nMy words."
    eventually $ (fmap (\d -> d.body) <$> draftOf wiki page) `shouldReturn` Just "# Hello, world\n\nMy words."
    clickButton ui ".editor-conflict button" "Keep mine"
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict" `shouldReturn` 0
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello, world\n\nMy words."
    draftOf wiki page `shouldReturn` Nothing

  it "takes theirs in place of the author's text when told to" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    _ <- someoneElseSaves wiki
    clearBody ui
    typeText text "My words."
    find ui ".editor-save" >>= click
    clickButton ui ".editor-conflict button" "Take theirs"
    eventually (markdown ui `shouldReturn` "# Hello, world\n\nSomeone else's words.")
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    find ui ".editor-show-preview" >>= click
    find ui ".editor-preview .page-body p" >>= (`shouldHaveText` "Someone else's words.")
    -- The toolbar works on the text loaded again, whose undo has nothing of
    -- what was there before.
    find ui ".editor-back" >>= click
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\n**bold text**Someone else's words."
    press "Control+z"
    markdown ui `shouldReturn` "# Hello, world\n\nSomeone else's words."
    -- And the next save is made over theirs.
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict" `shouldReturn` 0

  it "merges by hand: the author's text stays, their changes beside it, and the save is over theirs" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    page <- someoneElseSaves wiki
    clearBody ui
    typeText text "My words."
    find ui ".editor-save" >>= click
    clickButton ui ".editor-conflict button" "Merge by hand"
    find ui ".editor-conflict-pane h2" >>= (`shouldHaveText` "Their changes since you began")
    -- What their save changed in the version the edit began from.
    find ui ".editor-conflict-pane .diff-added .diff-text" >>= (`shouldHaveText` "Someone else's words.")
    find ui ".editor-conflict-pane .diff-removed .diff-text" >>= (`shouldHaveText` "This is the first post of a blog that is also a wiki. Every page is Markdown, written in a split view with the page rendered next to it as you type.")
    markdown ui `shouldReturn` "# Hello, world\n\nMy words."
    focus text
    press "Control+End"
    typeText text " And theirs: someone else's words."
    -- The draft follows, as an edit of their version.
    eventuallyWithin 8000 $ (fmap (\d -> d.body) <$> draftOf wiki page) `shouldReturn` Just "# Hello, world\n\nMy words. And theirs: someone else's words."
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello, world\n\nMy words. And theirs: someone else's words."

  it "loses no keystroke while the preview catches up with a long page" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Markdown guide")
    sideBySide ui
    text <- editorText ui
    original <- markdown ui
    focus text
    press "Control+End"
    -- Words typed with pauses about as long as the preview's delay, so that
    -- the preview's turn to follow the draft (which re-renders the editor
    -- around the textarea) comes as the next key is typed; then a long run
    -- typed without pauses, while the preview of the long page is drawn.
    let pauses = cycle [150, 180, 190, 195, 200, 205, 210, 220, 250]
        pieces = [" w" <> show i | i <- [1 .. 24 :: Int]]
        sentence = " the quick brown fox jumps over the lazy dog"
        long = T.replicate 3 sentence
    -- Each key a few milliseconds after the one before, still far faster
    -- than anyone types: keys sent back to back, as fast as Playwright can,
    -- set off a race in CodeMirror itself (its scroller's scroll handler
    -- reading the browser's selection a key ahead of its state, "Selection
    -- points outside of document"; docs/PLAN.md, "Known gaps and notes").
    let typeKeys = traverse_ (\c -> press (T.singleton c) >> unsafeIOToPageM (threadDelay 12000)) . T.unpack
    for_ (zip pieces pauses) $ \(word, pause) -> do
      typeKeys word
      unsafeIOToPageM (threadDelay (pause * 1000))
    -- The run is typed without pauses between words, so the preview of the
    -- long page is drawn as it goes.
    for_ (T.words long) $ \word ->
      typeKeys (" " <> word)
    let expected = original <> mconcat pieces <> long
    eventually $ markdown ui `shouldReturn` expected
    eventually $ find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "w24 the quick")
    markdown ui `shouldReturn` expected
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Markdown guide")
    saved <- readPage wiki ["docs"] ["markdown-guide"]
    saved.body `shouldBe` expected

  it "attaches a dropped image and embeds it at the cursor" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Look: "
    unsafeIOToPageM (dropFile ".editor-cm .cm-content" "dot.png" "image/png" dotPng)
    settle
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\nLook: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name.text) saved.attachments `shouldBe` ["dot.png"]

  it "attaches a pasted image at the cursor, and a file pasted into the textarea, putting in nothing else" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Look: "
    -- With the file's name as text beside it, as a file manager copies a
    -- file: the file is attached, and its name is not put in.
    prevented <- unsafeIOToPageM (pasteFile ".editor-cm .cm-content" "dot.png" "dot.png" "image/png" dotPng)
    prevented `shouldBe` True
    settle
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\nLook: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    -- A paste in the textarea (the editor before CodeMirror has come) is
    -- the panes' too, and the browser is kept from putting the name in.
    inTextarea <- unsafeIOToPageM (pasteFile ".editor-text" "notes.txt" "notes.txt" "text/plain" "aGVsbG8K")
    inTextarea `shouldBe` True
    settle
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\nLook: ![dot.png](attachment:dot.png)[notes.txt](attachment:notes.txt)"
    findAll ui ".editor-attachments li a" >>= traverse textContent >>= (`shouldBe` ["dot.png", "notes.txt"])
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name.text) saved.attachments `shouldBe` ["dot.png", "notes.txt"]
    saved.body `shouldBe` "# Hello, world\n\nLook: ![dot.png](attachment:dot.png)[notes.txt](attachment:notes.txt)"

  it "puts pasted text in unchanged but for its line endings, attaching nothing" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    attached <- length <$> findAll ui ".editor-attachments li"
    clearBody ui
    typeText text "Say: "
    _ <- unsafeIOToPageM (pasteText ".editor-cm .cm-content" "*Hello*, <b>world</b>\r\n\n- [x] one\r\n")
    settle
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\nSay: *Hello*, <b>world</b>\n\n- [x] one\n"
    previewHas ui "b" "world"
    length <$> findAll ui ".editor-attachments li" `shouldReturn` attached

  it "attaches a chosen file as a link, its name with spaces in angle brackets" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    _ <- editorText ui
    clearBody ui
    unsafeIOToPageM (chooseFile ".editor-attach input" "meeting notes.txt" "text/plain" "aGVsbG8K")
    settle
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\n[meeting notes.txt](<attachment:meeting notes.txt>)"
    download <- find ui ".editor-preview .page-body a[download='meeting notes.txt']"
    getAttribute download "href" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))

  it "makes a selected word bold from the toolbar, in the Markdown and the preview" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Some words"
    press "Control+Shift+ArrowLeft"
    editorSelection ui `shouldReturn` (21, 26)
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\nSome **words**"
    editorSelection ui `shouldReturn` (23, 28)
    previewHas ui "strong" "words"
    -- Again, and the word is plain again.
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\nSome words"

  it "makes every line selected a list item from the toolbar, and another list from a shortcut" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "one\ntwo\nthree"
    -- The three lines, under the title line, which is not one of them.
    press "Shift+ArrowUp"
    press "Shift+ArrowUp"
    press "Shift+Home"
    find ui ".editor-toolbar button[aria-label='Numbered list']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\n1. one\n2. two\n3. three"
    press "Control+Shift+8"
    markdown ui `shouldReturn` "# Hello, world\n\n- one\n- two\n- three"
    find ui ".editor-toolbar button[aria-label='Bulleted list']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\none\ntwo\nthree"

  it "leaves Ctrl+B's placeholder selected, for the typing to replace" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Hi "
    press "Control+b"
    markdown ui `shouldReturn` "# Hello, world\n\nHi **bold text**"
    editorSelection ui `shouldReturn` (21, 30)
    typeText text "there"
    markdown ui `shouldReturn` "# Hello, world\n\nHi **there**"

  it "keeps Ctrl+K from the browser, and puts in a link the browser's undo takes back" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    _ <- editorText ui
    clearBody ui
    unsafeIOToPageM js_watch_keys
    press "Control+k"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` True
    markdown ui `shouldReturn` "# Hello, world\n\n[link text](https://)"
    editorSelection ui `shouldReturn` (17, 26)
    press "Control+z"
    markdown ui `shouldReturn` "# Hello, world\n\n"
    -- A key the editor does not answer to is the browser's.
    press "x"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` False

  it "links a page found in the \"Link to a page\" dialog, with its title as the text" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "See "
    find ui ".editor-toolbar button[aria-label='Link to a page']" >>= click
    find ui ".link-dialog .search-input" >>= (`typeText` "diagrams")
    eventually $ find ui ".link-dialog .search-hit .search-hit-title" >>= (`shouldHaveText` "Diagrams")
    -- Enter with no hit chosen picks the first.
    press "Enter"
    eventually $ length <$> findAll ui ".link-dialog" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nSee [Diagrams](/s/docs/p/markdown-guide/diagrams/)"
    -- The text has the focus again, after the link.
    typeText text "."
    markdown ui `shouldReturn` "# Hello, world\n\nSee [Diagrams](/s/docs/p/markdown-guide/diagrams/)."
    -- The address leads to the page.
    _ <- find ui ".editor-preview .page-body a[href$='#/s/docs/p/markdown-guide/diagrams/']"
    pure ()

  it "links the selection to a section of a page, from Ctrl+Shift+K" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "the macros"
    press "Control+Shift+ArrowLeft"
    press "Control+Shift+K"
    field <- find ui ".link-dialog .search-input"
    find ui ".link-dialog-section-toggle input" >>= click
    typeText field "mathematics"
    hit <- eventually $ do
      hits <- findAll ui ".link-dialog a.search-hit[href$='#/s/docs/p/markdown-guide/mathematics/']"
      maybe (expectationFailure "no hit for Mathematics yet") pure (head hits)
    click hit
    -- The page's sections, its title line not among them.
    find ui ".link-dialog-page" >>= (`shouldHaveText` "Sections of Mathematics")
    -- Listed once the page has been read.
    anchors <- eventually $ do
      listed <- traverse (`getAttribute` "data-anchor") =<< findAll ui ".link-dialog-anchor"
      listed `shouldSatisfy` elem (Just "macros")
      pure listed
    anchors `shouldSatisfy` notElem (Just "mathematics")
    find ui ".link-dialog-anchor[data-anchor='macros']" >>= click
    eventually $ length <$> findAll ui ".link-dialog" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nthe [macros](/s/docs/p/markdown-guide/mathematics/#macros)"

  it "writes nothing when the \"Link to a page\" dialog is closed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    _ <- editorText ui
    clearBody ui
    find ui ".editor-toolbar button[aria-label='Link to a page']" >>= click
    find ui ".link-dialog .search-input" >>= (`typeText` "diagrams")
    eventually $ find ui ".link-dialog .search-hit .search-hit-title" >>= (`shouldHaveText` "Diagrams")
    -- The first Escape may only clear the search input's text, as the
    -- browser does in a search field.
    press "Escape"
    press "Escape"
    eventually $ length <$> findAll ui ".link-dialog" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\n"
    -- The header's search box is still the header's: its list is shut.
    length <$> findAll ui ".wiki-search .search-results" `shouldReturn` 0

  it "wraps the selection in an element from the HTML menu" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Look here"
    press "Control+Shift+ArrowLeft"
    find ui ".editor-toolbar button[aria-label='HTML']" >>= click
    clickButton ui ".toolbar-menu button" "Mark<mark>"
    markdown ui `shouldReturn` "# Hello, world\n\nLook <mark>here</mark>"
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui "mark" "here"

  it "makes the lines selected a box from the Box menu, numbered in the preview, and changes its kind" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Read this first"
    press "Shift+Home"
    find ui ".editor-toolbar button[aria-label='Box']" >>= click
    -- GitHub's five, then the demo's own kind; no "New kind…" for an editor.
    labels <- traverse textContent =<< findAll ui ".box-menu button"
    labels `shouldBe` ["Note[!NOTE]", "Tip[!TIP]", "Important[!IMPORTANT]", "Warning[!WARNING]", "Caution[!CAUTION]", "Exercise[!EXERCISE]"]
    length <$> findAll ui ".box-menu-new" `shouldReturn` 0
    clickButton ui ".box-menu button" "Tip[!TIP]"
    markdown ui `shouldReturn` "# Hello, world\n\n> [!TIP]\n> Read this first"
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui ".alert-tip .alert-title" "Tip 1"
    -- On the marker's line, another kind replaces the box's.
    find ui ".editor-toolbar button[aria-label='Box']" >>= click
    clickButton ui ".box-menu button" "Exercise[!EXERCISE]"
    markdown ui `shouldReturn` "# Hello, world\n\n> [!EXERCISE]\n> Read this first"
    previewHas ui ".alert-exercise .alert-title" "Exercise 1"

  it "defines a new kind of box in a dialog, without leaving the page, writes a box of it, and lists it at once" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") helloEditor
    find ui ".editor-toolbar button[aria-label='Box']" >>= click
    find ui ".box-menu .box-menu-new" >>= (`shouldHaveText` "New kind…")
    find ui ".box-menu .box-menu-new" >>= click
    -- The administration's form, in a dialog over the editor. One of
    -- GitHub's five is refused, and the dialog stays with what was typed.
    kind <- find ui ".new-kind-dialog .server-box-form input[name=kind]"
    typeText kind "note"
    find ui ".new-kind-dialog .server-box-form button[type=submit]" >>= click
    find ui ".new-kind-dialog .error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "one of GitHub's five")
    clear kind
    typeText kind "lemma"
    find ui ".new-kind-dialog .server-box-form input[name=label]" >>= (`typeText` "Lemma")
    find ui ".new-kind-dialog .server-box-form button[type=submit]" >>= click
    eventually (length <$> findAll ui ".new-kind-dialog" `shouldReturn` 0)
    -- The server keeps it, a box of it is in the text, and the menu lists
    -- it without a reload.
    kinds <- unsafeIOToPageM (runMemWiki wiki (either (panic . show) (\s -> s.boxes) <$> serverSettings))
    map (\k -> k.name) kinds `shouldSatisfy` elem "lemma"
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "> [!LEMMA]")
    find ui ".editor-toolbar button[aria-label='Box']" >>= click
    eventually (find ui ".box-menu button[data-kind='LEMMA']" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "Lemma"))
    -- The dialog's form, refused or saved, did not save the page.
    blog <- unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getSpace (slugs ["blog"])))
    stored <- unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])))
    stored.body `shouldSatisfy` (not . T.isInfixOf "[!LEMMA]")

  it "offers no new kind of box to someone who is not an administrator" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-toolbar button[aria-label='Box']" >>= click
    _ <- find ui ".box-menu button[data-kind='TIP']"
    length <$> findAll ui ".box-menu .box-menu-new" `shouldReturn` 0

  it "edits the page's block of macros and the space's from the Math macros panel" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Half: $\\half + \\twice$"
    find ui ".editor-toolbar .editor-macros-toggle" >>= click
    _ <- find ui ".editor-macros"
    -- The page's block, applied into the text under the title.
    page <- find ui ".editor-macros-page .macros-source"
    -- A block that would show something is refused: the page could not
    -- find it again as its block of definitions.
    typeText page "\\newcommand{\\half}{\\frac{1}{2}}x"
    eventually (find ui ".editor-macros-page .macros-error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "only definitions"))
    find ui ".editor-macros-page button[type=submit]" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
    clear page
    typeText page "\\newcommand{\\half}{\\frac{1}{2}}"
    eventually (length <$> findAll ui ".editor-macros-page .macros-error" `shouldReturn` 0)
    find ui ".editor-macros-page button[type=submit]" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\n```math\n\\newcommand{\\half}{\\frac{1}{2}}\n```\n\nHalf: $\\half + \\twice$"
    -- The block shows nothing in the preview; the formula has the macro.
    eventually (length <$> findAll ui ".editor-preview .wiki-math-display" `shouldReturn` 0)
    -- The space's, which an editor of the whole space saves at once.
    space <- find ui ".editor-macros-space .macros-source"
    typeText space "\\newcommand{\\twice}{2}"
    find ui ".editor-macros-space button[type=submit]" >>= click
    eventually (find ui ".editor-macros-space .settings-saved" >>= (`shouldHaveText` "Saved"))
    blog <- unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getSpace (slugs ["blog"])))
    blog.mathMacros `shouldBe` "\\newcommand{\\twice}{2}"
    -- Neither panel's form saved the page: the text with the page's block
    -- is still only in the editor.
    stored <- unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])))
    stored.body `shouldSatisfy` (not . T.isInfixOf "\\half")

  it "colours a word from the palette, changes its colour, highlights it and takes the colour away" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clearBody ui
    typeText text "Look here"
    press "Control+Shift+ArrowLeft"
    let pick swatch = do
          find ui ".editor-toolbar button[aria-label='Colour']" >>= click
          find ui (".colour-menu button[aria-label='" <> swatch <> "']") >>= click
    pick "Red text"
    markdown ui `shouldReturn` "# Hello, world\n\nLook <span class=\"c-red\">here</span>"
    editorSelection ui `shouldReturn` (41, 45)
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui "span.c-red" "here"
    -- The style sheet draws the class, in a colour of its own.
    plain <- computedColour ".editor-preview .page-body p"
    red <- computedColour ".editor-preview .page-body span.c-red"
    red `shouldNotBe` plain
    red `shouldNotBe` ""
    -- Another colour replaces the first, rather than going inside it.
    pick "Blue text"
    markdown ui `shouldReturn` "# Hello, world\n\nLook <span class=\"c-blue\">here</span>"
    previewHas ui "span.c-blue" "here"
    pick "Yellow highlight"
    markdown ui `shouldReturn` "# Hello, world\n\nLook <span class=\"c-blue\"><mark class=\"h-yellow\">here</mark></span>"
    pick "No text colour"
    markdown ui `shouldReturn` "# Hello, world\n\nLook <mark class=\"h-yellow\">here</mark>"
    previewHas ui "mark.h-yellow" "here"
    pick "No highlight"
    markdown ui `shouldReturn` "# Hello, world\n\nLook here"

  it "shows the Markdown as it will look while it is typed, its markers dimmed" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Some **bold** and _it_.\n\n```python\ndef f():\n```"
    let typed = "# Hello, world\n\nSome **bold** and _it_.\n\n```python\ndef f():\n```"
        -- The text of every element of a class, in order.
        classed cls = mconcat <$> (findAll ui (".editor-cm ." <> cls) >>= traverse textContent)
    -- The title line is a level-one heading.
    eventually $ classed "cm-md-h1" `shouldReturn` "# Hello, world"
    classed "cm-md-h1.cm-md-syntax" `shouldReturn` "#"
    classed "cm-md-strong" `shouldReturn` "**bold**"
    classed "cm-md-strong.cm-md-syntax" `shouldReturn` "****"
    classed "cm-md-emphasis" `shouldReturn` "_it_"
    classed "cm-md-emphasis.cm-md-syntax" `shouldReturn` "__"
    -- Fenced code on its own background, highlighted as the page will be.
    length <$> findAll ui ".editor-cm .cm-line.cm-md-codeblock" `shouldReturn` 3
    classed "hljs-keyword" `shouldReturn` "def"
    -- And the style sheet draws them so: a heading larger, strong bold,
    -- emphasis in italics, the markers in a colour of their own.
    body <- computedStyle ".editor-cm .cm-content" "font-size"
    heading <- computedStyle ".editor-cm .cm-md-h1" "font-size"
    (readPx heading > readPx body) `shouldBe` True
    computedStyle ".editor-cm .cm-md-strong" "font-weight" `shouldReturn` "700"
    computedStyle ".editor-cm .cm-md-emphasis" "font-style" `shouldReturn` "italic"
    marker <- computedColour ".editor-cm .cm-md-strong.cm-md-syntax"
    plain <- computedColour ".editor-cm .cm-content"
    marker `shouldNotBe` plain
    -- What is saved is what was typed, byte for byte.
    markdown ui `shouldReturn` typed
    find ui ".editor-save" >>= click
    eventually $ (\p -> p.body) <$> readPage wiki ["blog"] ["hello-world"] >>= (`shouldBe` typed)

  it "takes back a toolbar command as one step of the undo, and the typing after it as another" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Some words"
    press "Control+Shift+ArrowLeft"
    -- A colour rewrites more than the selection, still one step.
    find ui ".editor-toolbar button[aria-label='Colour']" >>= click
    find ui ".colour-menu button[aria-label='Red text']" >>= click
    markdown ui `shouldReturn` "# Hello, world\n\nSome <span class=\"c-red\">words</span>"
    press "ArrowRight"
    typeText text "!"
    markdown ui `shouldReturn` "# Hello, world\n\nSome <span class=\"c-red\">words!</span>"
    press "Control+z"
    markdown ui `shouldReturn` "# Hello, world\n\nSome <span class=\"c-red\">words</span>"
    press "Control+z"
    markdown ui `shouldReturn` "# Hello, world\n\nSome words"

  it "shows the preview on its own, and comes back to the Markdown as it was left" $ runPage $ do
    (ui, _) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    text <- editorText ui
    original <- markdown ui
    length <$> findAll ui ".editor-preview" `shouldReturn` 0
    focus text
    press "Control+End"
    typeText text "\n\nTyped last."
    for_ [1 .. 5 :: Int] (const (press "ArrowLeft"))
    let typed = original <> "\n\nTyped last."
        at = T.length typed - 5
    editorSelection ui `shouldReturn` (at, at)
    scroller <- find ui ".editor-cm .cm-scroller"
    scrolled <- getProperty scroller "scrollTop"
    scrolled `shouldNotBe` "0"
    find ui ".editor-show-preview" >>= click
    shouldBeHidden text
    find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Typed last.")
    find ui ".editor-save" >>= shouldBeVisible
    find ui ".editor-back" >>= click
    shouldBeVisible text
    shouldBeHidden =<< find ui ".editor-preview"
    markdown ui `shouldReturn` typed
    editorSelection ui `shouldReturn` (at, at)
    getProperty scroller "scrollTop" `shouldReturn` scrolled
    -- The focus is back at the cursor: the next key goes there.
    press "X"
    markdown ui `shouldReturn` (T.take at typed <> "X" <> T.drop at typed)

  it "shows both panes with the side by side preview, and remembers it" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    length <$> findAll ui ".editor-preview" `shouldReturn` 0
    sideBySide ui
    editorText ui >>= shouldBeVisible
    find ui ".editor-preview" >>= shouldBeVisible
    find ui ".editor-preview .page-body h1" >>= (`shouldHaveText` "Hello, world")
    -- Out of the editor and back into it: the choice is the browser's.
    find ui ".editor-cancel" >>= click
    find ui ".page-view .actions a[href$='/edit/']" >>= click
    find ui ".editor-side-by-side" >>= \button -> getAttribute button "aria-pressed" `shouldReturn` Just "true"
    find ui ".editor-preview" >>= shouldBeVisible

  it "finds TeX math in the text where the wiki's own parser does" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    -- The cases of commonmark-extensions' math and of TexMath: delimiters
    -- that open and close, a blank or a digit that stops them, braces, a
    -- backslash, a formula over two lines, and math beside a mention.
    let cases =
          [ "$x$"
          , "$ x$"
          , "$x $"
          , "$5 and $6"
          , "$x$5"
          , "a $x$ and $y$ b"
          , "$a{$}b$"
          , "$a}b$"
          , "$\\$x$"
          , "$\\alpha + 1$"
          , "$a\nb$"
          , "$$x$$"
          , "$$a $ b$$"
          , "$$ $$"
          , "\\(x\\)"
          , "\\( \\)"
          , "\\[a \\\\ b\\]"
          , "\\(x"
          , "`$x$` $y$"
          , "$x @an y$ @an"
          ]
    -- Each under a title line, which the editor keeps.
    for_ cases $ \source -> do
      setMarkdown ui ("# Cases\n\n" <> source)
      found <- map stripDelimiters <$> mathIn ui
      (source, found) `shouldBe` (source, wikiMath source)

  it "underlines inline math left open on its line, from its opening to the line's end, and nothing else" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let underlined = T.concat <$> (findAll ui ".cm-wiki-unclosed-math" >>= traverse textContent)
    -- Open: a $ closed by nothing, a \( and a $ closed on the next line
    -- only. Closed or not math: a formula, \(…\), a price, display math
    -- over lines, code and an escaped $.
    setMarkdown ui "# Cases\n\nOpen $x + y here\n\nClosed $x$ and \\(y\\), a price of $5, and $$\nz\n$$\n\nLate \\(a\nb\\) and $c\nd$\n\nCode `$x` and \\$x"
    eventually $ underlined `shouldReturn` "$x + y here\\(a$c"
    find ui ".cm-wiki-unclosed-math" >>= (`getAttribute` "title") >>= (`shouldBe` Just "This formula is not closed on its line.")
    -- Closed, the line is no longer underlined.
    setMarkdown ui "# Cases\n\nOpen $x + y$ here"
    eventually $ underlined `shouldReturn` ""
    -- A formula that starts with a number is not a price, and a dollar in
    -- a link's title is not math.
    setMarkdown ui "# Cases\n\nCompute $2x + y here\n\nThen $2 + x\n\nSee [this](other \"Amount: $USD\") and $3.50 or $5 each."
    eventually $ underlined `shouldReturn` "$2x + y here$2 + x"

  it "completes a mention with the users whose names start with what is typed, but not in code, a link or math" $ runPage $ do
    ui <- startChanged m withMentionable (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Ask @an"
    -- Anna by her login and Annabel by her display name, display name
    -- first and the login after it, in the order of their display names;
    -- not Annex, whose login a mention cannot name.
    shown <- listShown ui
    (findAllIn shown ".cm-completionLabel" >>= traverse textContent) `shouldReturn` ["Anna Nowak", "Annabel Smith"]
    (findAllIn shown ".cm-completionDetail" >>= traverse textContent) `shouldReturn` ["@anna", "@jsmith"]
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nAsk @anna "
    eventually $ length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    -- The arrows choose another, and Tab takes it rather than indenting.
    typeText text "and @AN"
    _ <- listShown ui
    press "ArrowDown"
    press "Tab"
    markdown ui `shouldReturn` "# Hello, world\n\nAsk @anna and @jsmith "
    -- Escape closes the list and leaves the text as typed.
    typeText text "or @an"
    _ <- listShown ui
    press "Escape"
    eventually $ length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nAsk @anna and @jsmith or @an"
    -- Chosen with a space after the cursor already: no second space.
    clearBody ui
    typeText text "Ask  now"
    typeAfter 4 ["@", "a", "n"]
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nAsk @anna now"
    -- Brackets with no link defined are text, where a mention counts.
    clearBody ui
    typeText text "[note ]"
    typeAfter 6 ["@", "a", "n"]
    _ <- listShown ui
    press "Escape"
    eventually $ length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    -- Not in a code fence, where a mention does not count.
    clearBody ui
    typeText text "```\n@an"
    noCompletion ui
    -- Nor in a link's text: typed between the brackets of one.
    clearBody ui
    typeText text "[see ](https://example.org)"
    typeAfter 5 ["@", "a", "n"]
    markdown ui `shouldReturn` "# Hello, world\n\n[see @an](https://example.org)"
    noCompletion ui
    -- Nor in a link to a page of the wiki, [[page]].
    clearBody ui
    typeText text "[[Plans ]]"
    typeAfter 8 ["@", "a", "n"]
    markdown ui `shouldReturn` "# Hello, world\n\n[[Plans @an]]"
    noCompletion ui
    -- Nor in math, between dollars or TeX's own delimiters.
    clearBody ui
    typeText text "$x y$"
    typeAfter 2 [" ", "@", "a", "n"]
    markdown ui `shouldReturn` "# Hello, world\n\n$x @an y$"
    noCompletion ui
    clearBody ui
    typeText text "\\(\\)"
    typeAfter 2 ["@", "a", "n"]
    markdown ui `shouldReturn` "# Hello, world\n\n\\(@an\\)"
    noCompletion ui
    -- After the formula, where a mention counts again, it opens.
    press "End"
    traverse_ press [" ", "@", "a", "n"]
    _ <- listShown ui
    pass
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])
    -- The TeX of each formula the wiki's parser finds, in the order of the
    -- text: in a paragraph, or a block of its own for display math alone
    -- in one.
    wikiMath source = case parseMarkdown source of
      Right blocks -> concatMap formulas blocks
      Left _ -> []
    formulas = \case
      Para inlines -> [tex | Math _ tex <- inlines]
      MathBlock tex -> [tex]
      _ -> []
    -- A formula as the editor's tree has it, without its delimiters.
    stripDelimiters t
      | "$$" `T.isPrefixOf` t = T.dropEnd 2 (T.drop 2 t)
      | "$" `T.isPrefixOf` t = T.dropEnd 1 (T.drop 1 t)
      | otherwise = T.dropEnd 2 (T.drop 2 t)
    -- Two users whose names start with "an", one by login and one by
    -- display name, one whose login a mention cannot name, and one who
    -- does not start so.
    withMentionable =
      insertUser User {id = UserId "user-anna", login = Login "anna", displayName = "Anna Nowak", avatar = Nothing}
        . insertUser User {id = UserId "user-jsmith", login = Login "jsmith", displayName = "Annabel Smith", avatar = Nothing}
        . insertUser User {id = UserId "user-annex", login = Login "annex@example.org", displayName = "Annex Corp", avatar = Nothing}
        . insertUser User {id = UserId "user-bob", login = Login "bob", displayName = "Bob Banner", avatar = Nothing}
    -- Type keys after the first n characters of the line.
    typeAfter n keys = do
      press "Home"
      replicateM_ n (press "ArrowRight")
      traverse_ press keys
    -- The list, open and ready to choose from. The library takes Enter
    -- and Tab only once the list has been open for 75 ms (its
    -- interactionDelay), so that a key pressed just as it opens is the
    -- text's. The list opened before it was seen here, so a wait of more
    -- than that after seeing it is always enough, however slow the page.
    listShown ui = do
      eventually (completing ui `shouldReturn` "active")
      shown <- find ui ".cm-tooltip-autocomplete"
      unsafeIOToPageM (threadDelay 100_000)
      pure shown
    -- No list opens. The keys just typed have made CodeMirror ask its
    -- source ("pending"); once it has had the answer and opened nothing,
    -- its completion is idle again (""), with no list.
    noCompletion ui = do
      eventually (completing ui `shouldReturn` "")
      length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0

-- | Turn the side by side preview on, so that the preview follows the
-- typing beside the Markdown.
sideBySide :: Mounted s q o m -> PageM s ()
sideBySide ui = do
  find ui ".editor-side-by-side" >>= click
  find ui ".editor-side-by-side" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "true"
  find ui ".editor-preview" >>= shouldBeVisible

-- | Wait for the preview to have an element with this text, finding it
-- again on each try: until the preview follows the draft, an element found
-- may be one that is going away.
previewHas :: Mounted s q o m -> Text -> Text -> PageM s ()
previewHas ui selector expected =
  eventually $ find ui (".editor-preview .page-body " <> selector) >>= textContent >>= (`shouldBe` expected)

-- | A property the style sheet gives the first element a selector finds.
computedStyle :: Text -> Text -> PageM s Text
computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))

-- | The colour the style sheet gives the first element a selector finds.
computedColour :: Text -> PageM s Text
computedColour selector = unsafeIOToPageM (fromJSText <$> js_computed_colour (toJSText selector))

-- | The page at a path of the demo, as the backend has it now.
-- | Someone else (the demo's administrator) saves the post after the
-- editor has loaded it: the page as it was.
someoneElseSaves :: IORef MemState -> PageM s Page
someoneElseSaves wiki = do
  page <- readPage wiki ["blog"] ["hello-world"]
  unsafeIOToPageM $ do
    editing <- (\st -> st.current) <$> readIORef wiki
    modifyIORef' wiki (\st -> st {current = Just (UserId "user-admin")})
    runMemWiki wiki (savePage page.id page.updatedAt page.title "# Hello, world\n\nSomeone else's words.") >>= either (panic . show) (const pass)
    modifyIORef' wiki (\st -> st {current = editing})
  pure page

-- | The editor's draft of a page, if there is one.
draftOf :: IORef MemState -> Page -> PageM s (Maybe Draft)
draftOf wiki page = unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getDraft page.id))

readPage :: IORef MemState -> [Text] -> [Text] -> PageM s Page
readPage wiki space path =
  unsafeIOToPageM . runMemWiki wiki $ do
    s <- either (panic . show) identity <$> getSpace (slugs space)
    either (panic . show) identity <$> getPage s.id (slugs path)

-- | A paste of a file, with a text beside it, on the element a selector
-- finds; whether its default was prevented.
pasteFile :: Text -> Text -> Text -> Text -> Text -> IO Bool
pasteFile selector text name mediaType base64 = evaluate =<< js_paste (toJSText selector) (toJSText text) (toJSText name) (toJSText mediaType) (toJSText base64)

-- | A paste of text alone; whether its default was prevented.
pasteText :: Text -> Text -> IO Bool
pasteText selector text = pasteFile selector text "" "" ""

dropFile, chooseFile :: Text -> Text -> Text -> Text -> IO ()
dropFile selector name mediaType base64 = evaluate =<< js_drop_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)
chooseFile selector name mediaType base64 = evaluate =<< js_choose_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)

-- | A PNG of one pixel, as base64.
dotPng :: Text
dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

-- | A length in CSS pixels, as computed styles give it ("14.4px").
readPx :: Text -> Double
readPx = fromMaybe 0 . readMaybe . T.unpack . T.dropEnd 2
