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
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startWith)
import Test.Browser.Text (editorSelection, editorText, markdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Attachment (Attachment (name))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page (Page (attachments, body, id, title, updatedAt))
import Wiki.Core.Space (Space (id))

-- The page has no file dialog the harness can answer, so a test hands the
-- editor a file the way the browser would: test/jsbits/test-files.js.
-- Whether a key reached the browser is read by a listener of its own:
-- test/jsbits/test-keys.js. The colour the style sheet gives an element:
-- test/jsbits/test-style.js.
$( browserJS
     ["jsbits/test-files.js", "jsbits/test-keys.js", "jsbits/test-style.js"]
     [ ("js_drop_file", "wiki_test_drop_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_paste", "wiki_test_paste", Safe, [t|JSText -> JSText -> JSText -> JSText -> JSText -> IO Bool|])
     , ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_watch_keys", "wiki_test_watch_keys", Unsafe, [t|IO ()|])
     , ("js_last_key_prevented", "wiki_test_last_key_prevented", Unsafe, [t|IO Bool|])
     , ("js_computed_colour", "wiki_test_computed_colour", Unsafe, [t|JSText -> IO JSText|])
     , ("js_computed_style", "wiki_test_computed_style", Unsafe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "previews what is typed, with its formulas drawn, and saves it" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    sideBySide ui
    text <- editorText ui
    clear text
    typeText text "# Hello again\n\nEuler: $e^{i\\pi} + 1 = 0$"
    find ui ".editor-preview .page-body h1" >>= (`shouldHaveText` "Hello again")
    formula <- find ui ".editor-preview .wiki-math-inline .katex"
    findIn formula "annotation" >>= (`shouldHaveText` "e^{i\\pi} + 1 = 0")
    -- More typing redraws the preview, but not a formula it has not touched.
    island <- find ui ".editor-preview .wiki-math-inline"
    typeText text "\n\nAnd more."
    eventually $ find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "And more.")
    find ui ".editor-preview .wiki-math-inline" >>= (`shouldBeSameElement` island)
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello again")
    _ <- find ui ".page-view .wiki-math-inline .katex"
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello again\n\nEuler: $e^{i\\pi} + 1 = 0$\n\nAnd more."

  it "saves with Ctrl+S and stays, saying Saved for a while, and indents with Tab" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    notice <- find ui ".editor-saved-notice"
    getAttribute notice "role" `shouldReturn` Just "status"
    notice `shouldHaveText` ""
    clear text
    typeText text "- a list"
    press "Enter"
    press "Tab"
    typeText text "- nested"
    markdown ui `shouldReturn` "- a list\n  - nested"
    press "Control+s"
    notice `shouldHaveText` "Saved"
    -- The focus is still in the text after the save.
    press "x"
    markdown ui `shouldReturn` "- a list\n  - nestedx"
    press "Backspace"
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "- a list\n  - nested"
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
    again.body `shouldBe` "- a list\n  - nested\n- more"
    again.updatedAt `shouldSatisfy` (> saved.updatedAt)

  it "saves, saves again, and shows the page after Save and close" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    typeText text "One."
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    typeText text " Two."
    find ui ".editor-save" >>= click
    eventually $ (\p -> p.body) <$> readPage wiki ["blog"] ["hello-world"] >>= (`shouldBe` "One. Two.")
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
    find ui ".editor-title input" >>= \t -> getProperty t "value" `shouldReturn` "Third post"
    editorText ui >>= (`typeText` "Some **news**.")
    -- Shown on its own, the preview has the draft at once; Save is there.
    find ui ".editor-show-preview" >>= click
    find ui ".editor-preview .page-title" >>= (`shouldHaveText` "Third post")
    find ui ".editor-preview .page-body strong" >>= (`shouldHaveText` "news")
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-title" >>= (`shouldHaveText` "Third post")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Third post")
    created <- readPage wiki ["blog"] ["third-post"]
    created.body `shouldBe` "Some **news**."

  it "writes a new page under another from its New subpage" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-view .actions a[href$='#/s/blog/new-page/hello-world/']" >>= click
    find ui ".new-page-view h1" >>= (`shouldHaveText` "New page under Hello, world")
    find ui ".new-page-title" >>= (`typeText` "Follow-up")
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Follow-up")
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-title" >>= (`shouldHaveText` "Follow-up")
    created <- readPage wiki ["blog"] ["hello-world", "follow-up"]
    created.title `shouldBe` "Follow-up"

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
    eventually $ markdown ui `shouldReturn` "![dot.png](attachment:dot.png)"
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-hint" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "first"))
    attached <- readPage wiki ["blog"] ["with-a-picture"]
    map (\a -> a.name) attached.attachments `shouldBe` ["dot.png"]
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    pass

  it "asks on Cancel with changes whether to keep the draft, and keeps it or not as told" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    typeText text "Kept for later."
    find ui ".editor-cancel" >>= click
    _ <- find ui ".editor-cancel-confirm"
    -- Going on editing leaves everything as it was.
    clickButton ui ".editor-cancel-confirm button" "Go on editing"
    length <$> findAll ui ".editor-cancel-confirm" `shouldReturn` 0
    markdown ui `shouldReturn` "Kept for later."
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
    markdown ui `shouldReturn` "Kept for later."
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
    clear text
    typeText text "Draft"
    find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/notes-on-haskell/']" >>= click
    _ <- find ui ".leave-confirm"
    clickButton ui ".leave-confirm button" "Stay"
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0
    markdown ui `shouldReturn` "Draft"
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
    clear text
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
    markdown ui `shouldReturn` "My words."
    eventually $ (fmap (\d -> d.body) <$> draftOf wiki page) `shouldReturn` Just "My words."
    clickButton ui ".editor-conflict button" "Keep mine"
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict" `shouldReturn` 0
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "My words."
    draftOf wiki page `shouldReturn` Nothing

  it "takes theirs in place of the author's text when told to" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    _ <- someoneElseSaves wiki
    clear text
    typeText text "My words."
    find ui ".editor-save" >>= click
    clickButton ui ".editor-conflict button" "Take theirs"
    eventually (markdown ui `shouldReturn` "Someone else's words.")
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    find ui ".editor-show-preview" >>= click
    find ui ".editor-preview .page-body p" >>= (`shouldHaveText` "Someone else's words.")
    -- The toolbar works on the text loaded again, whose undo has nothing of
    -- what was there before.
    find ui ".editor-back" >>= click
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "**bold text**Someone else's words."
    press "Control+z"
    markdown ui `shouldReturn` "Someone else's words."
    -- And the next save is made over theirs.
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict" `shouldReturn` 0

  it "merges by hand: the author's text stays, their changes beside it, and the save is over theirs" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    page <- someoneElseSaves wiki
    clear text
    typeText text "My words."
    find ui ".editor-save" >>= click
    clickButton ui ".editor-conflict button" "Merge by hand"
    find ui ".editor-conflict-pane h2" >>= (`shouldHaveText` "Their changes since you began")
    -- What their save changed in the version the edit began from.
    find ui ".editor-conflict-pane .diff-added .diff-text" >>= (`shouldHaveText` "Someone else's words.")
    find ui ".editor-conflict-pane .diff-removed .diff-text" >>= (`shouldHaveText` "# Hello, world")
    markdown ui `shouldReturn` "My words."
    focus text
    press "Control+End"
    typeText text " And theirs: someone else's words."
    -- The draft follows, as an edit of their version.
    eventuallyWithin 8000 $ (fmap (\d -> d.body) <$> draftOf wiki page) `shouldReturn` Just "My words. And theirs: someone else's words."
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    length <$> findAll ui ".editor-conflict-pane" `shouldReturn` 0
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "My words. And theirs: someone else's words."

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
    for_ (zip pieces pauses) $ \(word, pause) -> do
      typeText text word
      unsafeIOToPageM (threadDelay (pause * 1000))
    -- One word to a call, one call after another with no pause between
    -- them: one call may take at most five seconds (Playwright's default,
    -- which hspec-halogen's typeText keeps), and the test build types
    -- slower than the real one, slower still on a busy machine. A call of a
    -- whole sentence timed out on CI, then one of five words now and then,
    -- then one of three words on a busy runner. The run is still typed
    -- without pauses, so the preview of the long page is drawn as it goes.
    for_ (T.words long) $ \word ->
      typeText text (" " <> word)
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
    clear text
    typeText text "Look: "
    unsafeIOToPageM (dropFile ".editor-cm .cm-content" "dot.png" "image/png" dotPng)
    settle
    eventually $ markdown ui `shouldReturn` "Look: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name) saved.attachments `shouldBe` ["dot.png"]

  it "attaches a pasted image at the cursor, and a file pasted into the textarea, putting in nothing else" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clear text
    typeText text "Look: "
    -- With the file's name as text beside it, as a file manager copies a
    -- file: the file is attached, and its name is not put in.
    prevented <- unsafeIOToPageM (pasteFile ".editor-cm .cm-content" "dot.png" "dot.png" "image/png" dotPng)
    prevented `shouldBe` True
    settle
    eventually $ markdown ui `shouldReturn` "Look: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    -- A paste in the textarea (the editor before CodeMirror has come) is
    -- the panes' too, and the browser is kept from putting the name in.
    inTextarea <- unsafeIOToPageM (pasteFile ".editor-text" "notes.txt" "notes.txt" "text/plain" "aGVsbG8K")
    inTextarea `shouldBe` True
    settle
    eventually $ markdown ui `shouldReturn` "Look: ![dot.png](attachment:dot.png)[notes.txt](attachment:notes.txt)"
    findAll ui ".editor-attachments li a" >>= traverse textContent >>= (`shouldBe` ["dot.png", "notes.txt"])
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name) saved.attachments `shouldBe` ["dot.png", "notes.txt"]
    saved.body `shouldBe` "Look: ![dot.png](attachment:dot.png)[notes.txt](attachment:notes.txt)"

  it "puts pasted text in unchanged but for its line endings, attaching nothing" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    attached <- length <$> findAll ui ".editor-attachments li"
    clear text
    typeText text "Say: "
    _ <- unsafeIOToPageM (pasteText ".editor-cm .cm-content" "*Hello*, <b>world</b>\r\n\n- [x] one\r\n")
    settle
    eventually $ markdown ui `shouldReturn` "Say: *Hello*, <b>world</b>\n\n- [x] one\n"
    previewHas ui "b" "world"
    length <$> findAll ui ".editor-attachments li" `shouldReturn` attached

  it "attaches a chosen file as a link, its name with spaces in angle brackets" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clear text
    unsafeIOToPageM (chooseFile ".editor-attach input" "meeting notes.txt" "text/plain" "aGVsbG8K")
    settle
    eventually $ markdown ui `shouldReturn` "[meeting notes.txt](<attachment:meeting notes.txt>)"
    download <- find ui ".editor-preview .page-body a[download='meeting notes.txt']"
    getAttribute download "href" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))

  it "makes a selected word bold from the toolbar, in the Markdown and the preview" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clear text
    typeText text "Some words"
    press "Control+Shift+ArrowLeft"
    editorSelection ui `shouldReturn` (5, 10)
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "Some **words**"
    editorSelection ui `shouldReturn` (7, 12)
    previewHas ui "strong" "words"
    -- Again, and the word is plain again.
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "Some words"

  it "makes every line selected a list item from the toolbar, and another list from a shortcut" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    typeText text "one\ntwo\nthree"
    press "Control+a"
    find ui ".editor-toolbar button[aria-label='Numbered list']" >>= click
    markdown ui `shouldReturn` "1. one\n2. two\n3. three"
    press "Control+Shift+8"
    markdown ui `shouldReturn` "- one\n- two\n- three"
    find ui ".editor-toolbar button[aria-label='Bulleted list']" >>= click
    markdown ui `shouldReturn` "one\ntwo\nthree"

  it "leaves Ctrl+B's placeholder selected, for the typing to replace" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    typeText text "Hi "
    press "Control+b"
    markdown ui `shouldReturn` "Hi **bold text**"
    editorSelection ui `shouldReturn` (5, 14)
    typeText text "there"
    markdown ui `shouldReturn` "Hi **there**"

  it "keeps Ctrl+K from the browser, and puts in a link the browser's undo takes back" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    unsafeIOToPageM js_watch_keys
    press "Control+k"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` True
    markdown ui `shouldReturn` "[link text](https://)"
    editorSelection ui `shouldReturn` (1, 10)
    press "Control+z"
    markdown ui `shouldReturn` ""
    -- A key the editor does not answer to is the browser's.
    press "x"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` False

  it "wraps the selection in an element from the HTML menu" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clear text
    typeText text "Look here"
    press "Control+Shift+ArrowLeft"
    find ui ".editor-toolbar button[aria-label='HTML']" >>= click
    clickButton ui ".toolbar-menu button" "Mark<mark>"
    markdown ui `shouldReturn` "Look <mark>here</mark>"
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui "mark" "here"

  it "colours a word from the palette, changes its colour, highlights it and takes the colour away" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- editorText ui
    clear text
    typeText text "Look here"
    press "Control+Shift+ArrowLeft"
    let pick swatch = do
          find ui ".editor-toolbar button[aria-label='Colour']" >>= click
          find ui (".colour-menu button[aria-label='" <> swatch <> "']") >>= click
    pick "Red text"
    markdown ui `shouldReturn` "Look <span class=\"c-red\">here</span>"
    editorSelection ui `shouldReturn` (25, 29)
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui "span.c-red" "here"
    -- The style sheet draws the class, in a colour of its own.
    plain <- computedColour ".editor-preview .page-body p"
    red <- computedColour ".editor-preview .page-body span.c-red"
    red `shouldNotBe` plain
    red `shouldNotBe` ""
    -- Another colour replaces the first, rather than going inside it.
    pick "Blue text"
    markdown ui `shouldReturn` "Look <span class=\"c-blue\">here</span>"
    previewHas ui "span.c-blue" "here"
    pick "Yellow highlight"
    markdown ui `shouldReturn` "Look <span class=\"c-blue\"><mark class=\"h-yellow\">here</mark></span>"
    pick "No text colour"
    markdown ui `shouldReturn` "Look <mark class=\"h-yellow\">here</mark>"
    previewHas ui "mark.h-yellow" "here"
    pick "No highlight"
    markdown ui `shouldReturn` "Look here"

  it "shows the Markdown as it will look while it is typed, its markers dimmed" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- editorText ui
    clear text
    typeText text "# h\n\nSome **bold** and _it_.\n\n```python\ndef f():\n```"
    let typed = "# h\n\nSome **bold** and _it_.\n\n```python\ndef f():\n```"
        -- The text of every element of a class, in order.
        classed cls = mconcat <$> (findAll ui (".editor-cm ." <> cls) >>= traverse textContent)
    eventually $ classed "cm-md-h1" `shouldReturn` "# h"
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
    clear text
    typeText text "Some words"
    press "Control+Shift+ArrowLeft"
    -- A colour rewrites more than the selection, still one step.
    find ui ".editor-toolbar button[aria-label='Colour']" >>= click
    find ui ".colour-menu button[aria-label='Red text']" >>= click
    markdown ui `shouldReturn` "Some <span class=\"c-red\">words</span>"
    press "ArrowRight"
    typeText text "!"
    markdown ui `shouldReturn` "Some <span class=\"c-red\">words!</span>"
    press "Control+z"
    markdown ui `shouldReturn` "Some <span class=\"c-red\">words</span>"
    press "Control+z"
    markdown ui `shouldReturn` "Some words"

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
    find ui ".editor-side-by-side input" >>= \box -> getProperty box "checked" `shouldReturn` "true"
    find ui ".editor-preview" >>= shouldBeVisible
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

-- | Turn the side by side preview on, so that the preview follows the
-- typing beside the Markdown.
sideBySide :: Mounted s q o m -> PageM s ()
sideBySide ui = do
  find ui ".editor-side-by-side input" >>= click
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
    runMemWiki wiki (savePage page.id page.updatedAt page.title "Someone else's words.") >>= either (panic . show) (const pass)
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
