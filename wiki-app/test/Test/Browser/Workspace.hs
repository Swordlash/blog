{-# LANGUAGE TemplateHaskell #-}

-- | The room to write in (WP5.36 of docs/PLAN.md): the sidebar folded away
-- and kept folded, the Markdown's font made smaller and larger and kept so,
-- the side by side preview scrolled to the block of the cursor's line, and
-- the preview in a window of its own, which follows the editor of its page
-- on the channel between the wiki's windows. The other window is played by
-- @jsbits/test-live.js@, on the same channel in this page.
module Test.Browser.Workspace (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value (..), decodeStrict)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as T
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, start, startAgain)
import Test.Browser.Text (editorSelection, editorText, markdown, setMarkdown)
import Test.Hspec.Halogen
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-live.js", "jsbits/test-style.js", "jsbits/test-files.js"]
     [ ("js_live_start", "wiki_test_live_start", Safe, [t|IO ()|])
     , ("js_live_stop", "wiki_test_live_stop", Safe, [t|IO ()|])
     , ("js_live_hello", "wiki_test_live_hello", Safe, [t|IO JSText|])
     , ("js_live_heard", "wiki_test_live_heard", Safe, [t|IO JSText|])
     , ("js_live_heard_all", "wiki_test_live_heard_all", Safe, [t|IO JSText|])
     , ("js_live_send", "wiki_test_live_send", Safe, [t|JSText -> JSText -> Int -> IO ()|])
     , ("js_live_close", "wiki_test_live_close", Safe, [t|IO ()|])
     , ("js_live_cursor", "wiki_test_live_cursor", Safe, [t|Int -> IO ()|])
     , ("js_history_back", "wiki_test_history_back", Safe, [t|IO ()|])
     , ("js_scrolled", "wiki_test_live_scrolled", Safe, [t|JSText -> IO Double|])
     , ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_choose_filePromise", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     ]
 )

js_choose_file :: JSText -> JSText -> JSText -> JSText -> IO ()
js_choose_file a1 a2 a3 a4 = if inBrowser then wait =<< js_choose_filePromise a1 a2 a3 a4 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "folds the sidebar away and back, and keeps it folded" $ runPage $ do
    ui <- start m (Just "user-editor") hello
    _ <- find ui ".wiki-sidebar"
    find ui ".sidebar-fold" >>= click
    eventually $ computedStyle ".wiki-sidebar" "display" `shouldReturn` "none"
    find ui ".sidebar-fold" >>= (`shouldHaveText` "»")
    -- The browser keeps it folded (a mount here starts with nothing kept).
    storedBool "sidebar-folded" `shouldReturn` Just True
    find ui ".sidebar-fold" >>= click
    eventually $ computedStyle ".wiki-sidebar" "display" `shouldReturn` "block"
    storedBool "sidebar-folded" `shouldReturn` Just False
    unmount ui

  it "lays pages out compact or at full width, as chosen in the page's bar, and keeps the choice" $ runPage $ do
    ui <- start m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    view <- find ui ".page-view"
    classes view >>= (`shouldSatisfy` elem "page-width-compact")
    compact <- find ui ".page-actions .page-width-switch [role=radio].page-width-option-compact"
    getAttribute compact "aria-checked" `shouldReturn` Just "true"
    find ui ".page-actions .page-width-option-full" >>= click
    eventually $ find ui ".page-view" >>= classes >>= (`shouldSatisfy` elem "page-width-full")
    eventually $ find ui ".page-width-option-full" >>= \o -> getAttribute o "aria-checked" `shouldReturn` Just "true"
    storedText "page-width" `shouldReturn` Just "full"
    -- Every page is laid out so, and so it is after a reload.
    find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/notes-on-haskell/']" >>= click
    eventually $ find ui ".page-view" >>= classes >>= (`shouldSatisfy` elem "page-width-full")
    unmount ui
    again <- startAgain m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    eventually $ find again ".page-view" >>= classes >>= (`shouldSatisfy` elem "page-width-full")
    find again ".page-width-option-compact" >>= click
    eventually $ find again ".page-view" >>= classes >>= (`shouldSatisfy` elem "page-width-compact")
    storedText "page-width" `shouldReturn` Just "compact"
    unmount again

  it "makes the Markdown's font smaller and larger, and keeps its size" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    _ <- editorText ui
    computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "14.4px"
    find ui ".editor-font-smaller" >>= click
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "13.6px"
    storedInt "editor-font-step" `shouldReturn` Just 3
    -- Out of the editor and back into it: the size is the browser's.
    find ui ".editor-cancel" >>= click
    find ui ".page-view .actions a[href$='/edit/']" >>= click
    _ <- editorText ui
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "13.6px"
    find ui ".editor-font-larger" >>= click
    find ui ".editor-font-larger" >>= click
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "16px"
    unmount ui

  it "scrolls the side by side preview to the block of the cursor's line" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    find ui ".editor-side-by-side" >>= click
    find ui ".editor-preview" >>= shouldBeVisible
    setMarkdown ui titled
    eventually $ length <$> findAll ui ".editor-preview .page-body h2" `shouldReturn` 60
    unsafeIOToPageM (js_live_cursor (T.length titled))
    eventually $ scrolled ".editor-preview" >>= (`shouldSatisfy` (> 500))
    -- Back at the top: the title's block.
    unsafeIOToPageM (js_live_cursor 0)
    eventually $ scrolled ".editor-preview" >>= (`shouldSatisfy` (< 100))
    -- The cursor moved while the pane is hidden: shown again, the pane
    -- goes to its line.
    find ui ".editor-side-by-side" >>= click
    find ui ".editor-side-by-side" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "false"
    unsafeIOToPageM (js_live_cursor (T.length titled))
    find ui ".editor-side-by-side" >>= click
    eventually $ scrolled ".editor-preview" >>= (`shouldSatisfy` (> 500))
    -- "Show preview" shows the whole page, not the pane beside the text.
    find ui ".editor-show-preview" >>= click
    eventually $ computedStyle ".editor-preview" "overflow-y" `shouldReturn` "visible"
    unmount ui

  it "keeps the title on the text's first line, with its # in place, shows it as text, and goes to that line when it is clicked" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    text <- editorText ui
    -- Shown as text, not as a field.
    length <$> findAll ui ".editor-title input" `shouldReturn` 0
    title <- find ui ".editor-title-text"
    title `shouldHaveText` "Hello, world"
    -- Typed on the first line, the title changes with it.
    setMarkdown ui "# Hello, world\n\nText."
    unsafeIOToPageM (js_live_cursor 14)
    typeText text " again"
    markdown ui `shouldReturn` "# Hello, world again\n\nText."
    eventually $ find ui ".editor-title-text" >>= (`shouldHaveText` "Hello, world again")
    -- A click on the title puts the caret at the end of the first line,
    -- in the text, which has the focus.
    setMarkdown ui "# Hello\n\nText."
    unsafeIOToPageM (js_live_cursor 12)
    find ui ".editor-title-line" >>= click
    eventually $ editorSelection ui `shouldReturn` (7, 7)
    press "!"
    markdown ui `shouldReturn` "# Hello!\n\nText."
    -- The # stays: Backspace just after it does nothing, the cursor
    -- cannot go before it, and all of the text deleted leaves it.
    unsafeIOToPageM (js_live_cursor 2)
    press "Backspace"
    press "Backspace"
    markdown ui `shouldReturn` "# Hello, world again\n\nText."
    press "Home"
    press "x"
    markdown ui `shouldReturn` "# xHello, world again\n\nText."
    press "Backspace"
    -- A word deleted back over the "# " leaves it, and the cursor after it.
    unsafeIOToPageM (js_live_cursor 2)
    press "Control+Backspace"
    press "y"
    markdown ui `shouldReturn` "# yHello, world again\n\nText."
    press "Backspace"
    press "Control+a"
    press "Delete"
    markdown ui `shouldReturn` "# "
    -- A page needs a title: an empty one is not saved.
    find ui ".editor-save" >>= click
    find ui ".editor-notices .error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "write it after the #")
    typeText text "Back again"
    markdown ui `shouldReturn` "# Back again"
    unmount ui

  it "leaves a template its own name, and the heading it gives the pages made from it" $ runPage $ do
    ui <- start m (Just "user-admin") (EditPage (slugs ["team"]) (slugs ["weekly-sync"]))
    text <- editorText ui
    markdown ui >>= (`shouldSatisfy` T.isPrefixOf "# {{title}}\n")
    -- The title field is the template's name, typed there.
    title <- find ui ".editor-title input"
    getAttribute title "readonly" `shouldReturn` Nothing
    getProperty title "value" `shouldReturn` "Weekly sync"
    focus text
    press "Control+End"
    typeText text "\n\nMore."
    find ui ".editor-save-close" >>= click
    find ui ".page-view" >>= shouldBeVisible
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Weekly sync")
    unmount ui

  it "shows the preview alone at the block being edited, the bar still there, and Back returns to the text" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    _ <- editorText ui
    setMarkdown ui titled
    unsafeIOToPageM (js_live_cursor (T.length titled))
    -- Where the window is with the text. The preview is asked for with its
    -- key, which, unlike a click, does not scroll the window first.
    settle
    before <- scrolled ""
    press "Control+Alt+p"
    form <- find ui ".editor-form"
    eventually $ getAttribute form "class" >>= (`shouldSatisfy` maybe False (T.isInfixOf "previewing"))
    -- The window at the last block, far down the rendered page.
    eventually $ scrolled "" >>= (`shouldSatisfy` (> before + 500))
    -- Save and the way back stay at the top, under the header.
    find ui ".editor-top .editor-back" >>= shouldBeVisible
    find ui ".editor-top .editor-save" >>= shouldBeVisible
    -- The browser's Back returns to the text, with the window where it was:
    -- give or take a line, since the text, focused again, brings its cursor
    -- fully into view.
    unsafeIOToPageM js_history_back
    eventually $ getAttribute form "class" >>= (`shouldSatisfy` maybe False (not . T.isInfixOf "previewing"))
    eventually $ scrolled "" >>= \y -> (before, y) `shouldSatisfy` (\(b, a) -> abs (a - b) < 100)
    -- "Back to editing" does the same, and leaves the history as it was.
    find ui ".editor-show-preview" >>= click
    eventually $ getAttribute form "class" >>= (`shouldSatisfy` maybe False (T.isInfixOf "previewing"))
    find ui ".editor-back" >>= click
    eventually $ getAttribute form "class" >>= (`shouldSatisfy` maybe False (not . T.isInfixOf "previewing"))
    unmount ui

  it "tells the window of its page what is typed and where" $ runPage $ do
    unsafeIOToPageM js_live_start
    ui <- start m (Just "user-editor") helloEditor
    _ <- editorText ui
    setMarkdown ui "# Typed here\n\nand here"
    unsafeIOToPageM (js_live_cursor 14)
    eventually $ do
      heard <- unsafeIOToPageM (fromJSText <$> js_live_heard)
      let message = decodeStrict (encodeUtf8 heard) :: Maybe Value
      (field "text" =<< message, field "line" =<< message)
        `shouldBe` (Just (String "# Typed here\n\nand here"), Just (Number 3))
    find ui ".editor-detach" >>= \detach -> getAttribute detach "target" `shouldReturn` Just "wiki-live-preview"
    -- The title, which is the first line's, goes with it.
    eventually $ (field "title" =<<) . lastMay <$> heardAll `shouldReturn` Just (String "Typed here")
    setMarkdown ui "# Retitled\n\nand here"
    eventually $ (field "title" =<<) . lastMay <$> heardAll `shouldReturn` Just (String "Retitled")
    -- A file uploaded: the window is told to fetch the attachments again.
    unsafeIOToPageM (evaluate =<< js_choose_file (toJSText ".editor-attach input") (toJSText "dot.png") (toJSText "image/png") (toJSText dotPng))
    settle
    eventually $ (any ((== Just (Bool True)) . field "attachments") <$> heardAll) `shouldReturn` True
    -- Typed and closed at once, within the pause the text waits for: the
    -- text is sent before the window is told the editor has gone.
    setMarkdown ui "# Typed here\n\nand the last words"
    unmount ui
    eventually $ do
      heard <- heardAll
      map (field "closed") (take 1 (reverse heard)) `shouldBe` [Just (Bool True)]
      (field "text" =<< lastMay (filter (isJust . field "text") heard)) `shouldBe` Just (String "# Typed here\n\nand the last words")
    unsafeIOToPageM js_live_stop

  it "shows the page in a window of its own, following its editor until it goes" $ runPage $ do
    unsafeIOToPageM js_live_start
    ui <- start m (Just "user-editor") (LivePreview (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".live-preview-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The page as saved")
    find ui ".live-preview .page-body h1" >>= (`shouldHaveText` "Hello, world")
    eventually $ unsafeIOToPageM (fromJSText <$> js_live_hello) >>= (`shouldSatisfy` T.isSuffixOf "/hello-world")
    unsafeIOToPageM (js_live_send (toJSText long) (toJSText "Retitled") 1)
    find ui ".live-preview-state" >>= (`shouldHaveText` "Following the editor.")
    eventually $ length <$> findAll ui ".live-preview .page-body h2" `shouldReturn` 60
    find ui ".live-preview .page-title" >>= (`shouldHaveText` "Retitled")
    unsafeIOToPageM (js_live_send (toJSText long) (toJSText "") 230)
    eventually $ scrolled "" >>= (`shouldSatisfy` (> 500))
    unsafeIOToPageM js_live_close
    eventually $ find ui ".live-preview-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The editor was closed")
    length <$> findAll ui ".live-preview .page-body h2" `shouldReturn` 60
    unmount ui
    unsafeIOToPageM js_live_stop
  where
    hello = Page (slugs ["blog"]) (slugs ["hello-world"])
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])
    -- Sixty sections, each a heading and a paragraph: four lines each.
    long = T.concat ["## Section " <> show n <> "\n\nSome text of section " <> show n <> ".\n\n" | n <- [1 .. 60 :: Int]]
    -- The same under the page's title line, which the editor keeps.
    titled = "# Hello, world\n\n" <> long
    heardAll :: PageM s [Value]
    heardAll =
      unsafeIOToPageM (fromJSText <$> js_live_heard_all) <&> \raw -> case decodeStrict (encodeUtf8 raw) of
        Just (Array messages) -> toList messages
        _ -> []
    -- A PNG of one pixel, as base64.
    dotPng :: Text
    dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    scrolled :: Text -> PageM s Double
    scrolled selector = unsafeIOToPageM (js_scrolled (toJSText selector))
    -- What the application keeps in the browser's local storage, read as
    -- it reads it.
    storedBool :: Text -> PageM s (Maybe Bool)
    storedBool key = (rightToMaybe =<<) <$> unsafeIOToPageM (runTest (Storage.getItem LocalStorage key :: m (Maybe (Either _ Bool))))
    storedText :: Text -> PageM s (Maybe Text)
    storedText key = (rightToMaybe =<<) <$> unsafeIOToPageM (runTest (Storage.getItem LocalStorage key :: m (Maybe (Either _ Text))))
    storedInt :: Text -> PageM s (Maybe Int)
    storedInt key = (rightToMaybe =<<) <$> unsafeIOToPageM (runTest (Storage.getItem LocalStorage key :: m (Maybe (Either _ Int))))
    computedStyle :: Text -> Text -> PageM s Text
    computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))
    field :: Text -> Value -> Maybe Value
    field key = \case
      Object o -> KeyMap.lookup (Key.fromText key) o
      _ -> Nothing
