{-# LANGUAGE TemplateHaskell #-}

-- | The editor in a browser, in the shell, over the demo's wiki: typing
-- Markdown and seeing the preview follow, saving and reading the page back
-- from the backend, a new page, leaving with and without unsaved changes, a
-- save over someone else's, and files attached by a drop or a file input.
module Test.Browser.Editor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
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
$( browserJS
     ["jsbits/test-files.js"]
     [ ("js_drop_file", "wiki_test_drop_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  it "previews what is typed, with its formulas drawn, and saves it" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
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
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello again")
    _ <- find ui ".page-view .wiki-math-inline .katex"
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "# Hello again\n\nEuler: $e^{i\\pi} + 1 = 0$\n\nAnd more."

  it "saves with Ctrl+S, and indents with Tab" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "- a list"
    press "Enter"
    press "Tab"
    typeText text "- nested"
    getProperty text "value" `shouldReturn` "- a list\n  - nested"
    press "Control+s"
    find ui ".page-view .page-body ul ul li" >>= (`shouldHaveText` "nested")
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` "- a list\n  - nested"

  it "writes a new page from the space's New page" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (Space (slugs ["blog"]))
    find ui ".space-view .actions a[href='#/s/blog/new-page/']" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "New page in Blog")
    find ui ".editor-title input" >>= (`typeText` "Third post")
    find ui ".editor-preview .page-title" >>= (`shouldHaveText` "Third post")
    find ui ".editor-text" >>= (`typeText` "Some **news**.")
    find ui ".editor-preview .page-body strong" >>= (`shouldHaveText` "news")
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-title" >>= (`shouldHaveText` "Third post")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Third post")
    created <- readPage wiki ["blog"] ["third-post"]
    created.body `shouldBe` "Some **news**."

  it "writes a new page under another from its New subpage" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-view .actions a[href='#/s/blog/new-page/hello-world/']" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "New page under Hello, world")
    find ui ".editor-title input" >>= (`typeText` "Follow-up")
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-title" >>= (`shouldHaveText` "Follow-up")
    created <- readPage wiki ["blog"] ["hello-world", "follow-up"]
    created.title `shouldBe` "Follow-up"

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
    find ui ".editor-form button.primary" >>= click
    _ <- find ui ".editor .error-conflict"
    getProperty text "value" `shouldReturn` "My words."
    clickButton ui ".error-conflict button" "Reload and lose my changes"
    find ui ".editor-text" >>= \t -> eventually (getProperty t "value" `shouldReturn` "Someone else's words.")
    find ui ".editor-preview .page-body p" >>= (`shouldHaveText` "Someone else's words.")
    length <$> findAll ui ".error-conflict" `shouldReturn` 0

  it "loses no keystroke while the preview catches up with a long page" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Markdown guide")
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
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Markdown guide")
    saved <- readPage wiki ["docs"] ["markdown-guide"]
    saved.body `shouldBe` expected

  it "attaches a dropped image and embeds it at the cursor" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    typeText text "Look: "
    unsafeIOToPageM (dropFile ".editor-panes" "dot.png" "image/png" dotPng)
    settle
    eventually $ getProperty text "value" `shouldReturn` "Look: ![dot.png](attachment:dot.png)"
    image <- find ui ".editor-preview .page-body img[alt='dot.png']"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    find ui ".editor-attachments li a" >>= (`shouldHaveText` "dot.png")
    find ui ".editor-form button.primary" >>= click
    _ <- find ui ".page-view .page-body img[alt='dot.png']"
    saved <- readPage wiki ["blog"] ["hello-world"]
    map (\a -> a.name) saved.attachments `shouldBe` ["dot.png"]

  it "attaches a chosen file as a link, its name with spaces in angle brackets" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    text <- find ui ".editor-text"
    clear text
    unsafeIOToPageM (chooseFile ".editor-attach input" "meeting notes.txt" "text/plain" "aGVsbG8K")
    settle
    eventually $ getProperty text "value" `shouldReturn` "[meeting notes.txt](<attachment:meeting notes.txt>)"
    download <- find ui ".editor-preview .page-body a[download='meeting notes.txt']"
    getAttribute download "href" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

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
