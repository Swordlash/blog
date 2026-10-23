{-# LANGUAGE TemplateHaskell #-}

-- | The editor in a browser, in the shell, over the demo's wiki: typing
-- Markdown and seeing the preview follow, saving (and staying, or closing)
-- and reading the page back from the backend, a new page made from its
-- title and given a file before anything is saved, leaving with and without
-- unsaved changes, Cancel keeping or discarding the draft, a save over
-- someone else's, files attached by a drop or a file input, the toolbar and
-- its shortcuts, and the preview shown on its own or beside the Markdown.
module Test.Browser.Editor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startWith)
import Test.Hspec.Halogen
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Attachment (Attachment (name))
import Wiki.Core.Page (Page (attachments, body, id, title, updatedAt))
import Wiki.Core.Space (Space (id))

-- The page has no file dialog the harness can answer, so a test hands the
-- editor a file the way the browser would: test/jsbits/test-files.js.
-- Whether a key reached the browser is read by a listener of its own:
-- test/jsbits/test-keys.js.
$( browserJS
     ["jsbits/test-files.js", "jsbits/test-keys.js"]
     [ ("js_drop_file", "wiki_test_drop_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_watch_keys", "wiki_test_watch_keys", Unsafe, [t|IO ()|])
     , ("js_last_key_prevented", "wiki_test_last_key_prevented", Unsafe, [t|IO Bool|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  it "previews what is typed, with its formulas drawn, and saves it" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    sideBySide ui
    text <- find ui ".editor-text"
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
    text <- find ui ".editor-text"
    notice <- find ui ".editor-saved-notice"
    getAttribute notice "role" `shouldReturn` Just "status"
    notice `shouldHaveText` ""
    clear text
    typeText text "- a list"
    press "Enter"
    press "Tab"
    typeText text "- nested"
    getProperty text "value" `shouldReturn` "- a list\n  - nested"
    press "Control+s"
    notice `shouldHaveText` "Saved"
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "- a list\n  - nested"
    -- Still the same textarea, with the cursor where it was.
    find ui ".editor-text" >>= (`shouldBeSameElement` text)
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
    text <- find ui ".editor-text"
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
    (ui, wiki) <- startWith m (Just "user-editor") (Space (slugs ["blog"]))
    find ui ".space-view .actions a[href='#/s/blog/new-page/']" >>= click
    find ui ".new-page-view h1" >>= (`shouldHaveText` "New page in Blog")
    find ui ".new-page-title" >>= (`typeText` "Third post")
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Third post")
    -- Made, empty, before anything is written.
    made <- readPage wiki ["blog"] ["third-post"]
    made.body `shouldBe` ""
    find ui ".editor-title input" >>= \t -> getProperty t "value" `shouldReturn` "Third post"
    find ui ".editor-text" >>= (`typeText` "Some **news**.")
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
    find ui ".page-view .actions a[href='#/s/blog/new-page/hello-world/']" >>= click
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
    text <- find ui ".editor-text"
    unsafeIOToPageM (chooseFile ".editor-attach input" "dot.png" "image/png" dotPng)
    settle
    eventually $ getProperty text "value" `shouldReturn` "![dot.png](attachment:dot.png)"
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-hint" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "first"))
    attached <- readPage wiki ["blog"] ["with-a-picture"]
    map (\a -> a.name) attached.attachments `shouldBe` ["dot.png"]
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    pass

  it "asks on Cancel with changes whether to keep the draft, and keeps it or not as told" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "Kept for later."
    find ui ".editor-cancel" >>= click
    _ <- find ui ".editor-cancel-confirm"
    -- Going on editing leaves everything as it was.
    clickButton ui ".editor-cancel-confirm button" "Go on editing"
    length <$> findAll ui ".editor-cancel-confirm" `shouldReturn` 0
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
    find ui ".editor-text" >>= \t -> getProperty t "value" `shouldReturn` "Kept for later."
    -- This time the changes are let go, and the draft with them.
    find ui ".editor-cancel" >>= click
    clickButton ui ".editor-cancel-confirm button" "Discard my changes"
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    find ui ".page-view .actions a[href$='/edit/']" >>= click
    find ui ".editor-text" >>= \t -> getProperty t "value" >>= (`shouldSatisfy` T.isPrefixOf "# Hello, world")
    length <$> findAll ui ".editor-draft-found" `shouldReturn` 0

  it "goes back to the page on Cancel when nothing has changed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-cancel" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0

  it "asks before leaving unsaved changes, and stays or leaves as told" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "Draft"
    find ui ".editor-cancel" >>= click
    _ <- find ui ".leave-confirm"
    clickButton ui ".leave-confirm button" "Stay"
    length <$> findAll ui ".leave-confirm" `shouldReturn` 0
    find ui ".editor-text" >>= \t -> getProperty t "value" `shouldReturn` "Draft"
    -- A link elsewhere asks too; leaving goes there, and the draft is lost.
    find ui ".wiki-sidebar .page-tree a[href='#/s/blog/p/notes-on-haskell/']" >>= click
    find ui ".leave-confirm button.danger" >>= click
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Notes on Haskell")
    unchanged <- readPage wiki ["blog"] ["hello-world"]
    unchanged.body `shouldSatisfy` T.isPrefixOf "# Hello, world"

  it "shows a save over someone else's as a conflict, keeping the draft until told to reload" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    -- Someone else saves the page after the editor has loaded it.
    page <- readPage wiki ["blog"] ["hello-world"]
    unsafeIOToPageM . runMemWiki wiki $
      savePage page.id page.updatedAt page.title "Someone else's words." >>= either (panic . show) (const pass)
    clear text
    typeText text "My words."
    find ui ".editor-save" >>= click
    _ <- find ui ".editor .error-conflict"
    getProperty text "value" `shouldReturn` "My words."
    clickButton ui ".error-conflict button" "Reload and lose my changes"
    find ui ".editor-text" >>= \t -> eventually (getProperty t "value" `shouldReturn` "Someone else's words.")
    find ui ".editor-show-preview" >>= click
    find ui ".editor-preview .page-body p" >>= (`shouldHaveText` "Someone else's words.")
    length <$> findAll ui ".error-conflict" `shouldReturn` 0

  it "loses no keystroke while the preview catches up with a long page" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Markdown guide")
    sideBySide ui
    text <- find ui ".editor-text"
    original <- getProperty text "value"
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
    -- In calls of five words, one after another with no pause between
    -- them, since one call may take at most five seconds and the test build
    -- types slower than the real one, slower still on a busy machine (a
    -- call of a whole sentence timed out on CI).
    for_ (chunksOf 5 [" " <> w | w <- T.words long]) $ \run ->
      typeText text (mconcat run)
    let expected = original <> mconcat pieces <> long
    eventually $ getProperty text "value" `shouldReturn` expected
    eventually $ find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "w24 the quick")
    getProperty text "value" `shouldReturn` expected
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Markdown guide")
    saved <- readPage wiki ["docs"] ["markdown-guide"]
    saved.body `shouldBe` expected

  it "attaches a dropped image and embeds it at the cursor" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- find ui ".editor-text"
    clear text
    typeText text "Look: "
    unsafeIOToPageM (dropFile ".editor-panes" "dot.png" "image/png" dotPng)
    settle
    eventually $ getProperty text "value" `shouldReturn` "Look: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-save-close" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name) saved.attachments `shouldBe` ["dot.png"]

  it "attaches a chosen file as a link, its name with spaces in angle brackets" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- find ui ".editor-text"
    clear text
    unsafeIOToPageM (chooseFile ".editor-attach input" "meeting notes.txt" "text/plain" "aGVsbG8K")
    settle
    eventually $ getProperty text "value" `shouldReturn` "[meeting notes.txt](<attachment:meeting notes.txt>)"
    download <- find ui ".editor-preview .page-body a[download='meeting notes.txt']"
    getAttribute download "href" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))

  it "makes a selected word bold from the toolbar, in the Markdown and the preview" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- find ui ".editor-text"
    clear text
    typeText text "Some words"
    press "Control+Shift+ArrowLeft"
    selection text `shouldReturn` (5, 10)
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    getProperty text "value" `shouldReturn` "Some **words**"
    selection text `shouldReturn` (7, 12)
    previewHas ui "strong" "words"
    -- Again, and the word is plain again.
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    getProperty text "value" `shouldReturn` "Some words"

  it "makes every line selected a list item from the toolbar, and another list from a shortcut" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "one\ntwo\nthree"
    press "Control+a"
    find ui ".editor-toolbar button[aria-label='Numbered list']" >>= click
    getProperty text "value" `shouldReturn` "1. one\n2. two\n3. three"
    press "Control+Shift+8"
    getProperty text "value" `shouldReturn` "- one\n- two\n- three"
    find ui ".editor-toolbar button[aria-label='Bulleted list']" >>= click
    getProperty text "value" `shouldReturn` "one\ntwo\nthree"

  it "leaves Ctrl+B's placeholder selected, for the typing to replace" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "Hi "
    press "Control+b"
    getProperty text "value" `shouldReturn` "Hi **bold text**"
    selection text `shouldReturn` (5, 14)
    typeText text "there"
    getProperty text "value" `shouldReturn` "Hi **there**"

  it "keeps Ctrl+K from the browser, and puts in a link the browser's undo takes back" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    unsafeIOToPageM js_watch_keys
    press "Control+k"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` True
    getProperty text "value" `shouldReturn` "[link text](https://)"
    selection text `shouldReturn` (1, 10)
    press "Control+z"
    getProperty text "value" `shouldReturn` ""
    -- A key the editor does not answer to is the browser's.
    press "x"
    unsafeIOToPageM js_last_key_prevented `shouldReturn` False

  it "wraps the selection in an element from the HTML menu" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    sideBySide ui
    text <- find ui ".editor-text"
    clear text
    typeText text "Look here"
    press "Control+Shift+ArrowLeft"
    find ui ".editor-toolbar button[aria-label='HTML']" >>= click
    clickButton ui ".toolbar-menu button" "Highlight<mark>"
    getProperty text "value" `shouldReturn` "Look <mark>here</mark>"
    length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    previewHas ui "mark" "here"

  it "shows the preview on its own, and comes back to the Markdown as it was left" $ runPage $ do
    (ui, _) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    text <- find ui ".editor-text"
    original <- getProperty text "value"
    length <$> findAll ui ".editor-preview" `shouldReturn` 0
    focus text
    press "Control+End"
    typeText text "\n\nTyped last."
    for_ [1 .. 5 :: Int] (const (press "ArrowLeft"))
    let typed = original <> "\n\nTyped last."
        at = T.length typed - 5
    selection text `shouldReturn` (at, at)
    scrolled <- getProperty text "scrollTop"
    scrolled `shouldNotBe` "0"
    find ui ".editor-show-preview" >>= click
    shouldBeHidden text
    find ui ".editor-preview .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Typed last.")
    find ui ".editor-save" >>= shouldBeVisible
    find ui ".editor-back" >>= click
    shouldBeVisible text
    shouldBeHidden =<< find ui ".editor-preview"
    getProperty text "value" `shouldReturn` typed
    selection text `shouldReturn` (at, at)
    getProperty text "scrollTop" `shouldReturn` scrolled
    -- The focus is back at the cursor: the next key goes there.
    press "X"
    getProperty text "value" `shouldReturn` (T.take at typed <> "X" <> T.drop at typed)

  it "shows both panes with the side by side preview, and remembers it" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    length <$> findAll ui ".editor-preview" `shouldReturn` 0
    sideBySide ui
    find ui ".editor-text" >>= shouldBeVisible
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

-- | A textarea's selection, in UTF-16 units, as the browser has it.
selection :: Element s -> PageM s (Int, Int)
selection text = do
  start <- getProperty text "selectionStart"
  end <- getProperty text "selectionEnd"
  pure (fromMaybe (-1) (readMaybe (T.unpack start)), fromMaybe (-1) (readMaybe (T.unpack end)))

-- | The page at a path of the demo, as the backend has it now.
readPage :: IORef MemState -> [Text] -> [Text] -> PageM s Page
readPage wiki space path =
  unsafeIOToPageM . runMemWiki wiki $ do
    s <- either (panic . show) identity <$> getSpace (slugs space)
    either (panic . show) identity <$> getPage s.id (slugs path)

dropFile, chooseFile :: Text -> Text -> Text -> Text -> IO ()
dropFile selector name mediaType base64 = evaluate =<< js_drop_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)
chooseFile selector name mediaType base64 = evaluate =<< js_choose_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)

-- | A PNG of one pixel, as base64.
dotPng :: Text
dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

-- | A list cut into runs of at most @n@.
chunksOf :: Int -> [a] -> [[a]]
chunksOf n = \case
  [] -> []
  xs -> let (run, rest) = splitAt n xs in run : chunksOf n rest
