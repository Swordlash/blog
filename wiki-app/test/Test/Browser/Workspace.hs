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
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Browser.Text (editorText, setMarkdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-live.js", "jsbits/test-style.js"]
     [ ("js_live_start", "wiki_test_live_start", Unsafe, [t|IO ()|])
     , ("js_live_stop", "wiki_test_live_stop", Unsafe, [t|IO ()|])
     , ("js_live_hello", "wiki_test_live_hello", Unsafe, [t|IO JSText|])
     , ("js_live_heard", "wiki_test_live_heard", Unsafe, [t|IO JSText|])
     , ("js_live_send", "wiki_test_live_send", Unsafe, [t|JSText -> Int -> IO ()|])
     , ("js_live_close", "wiki_test_live_close", Unsafe, [t|IO ()|])
     , ("js_live_cursor", "wiki_test_live_cursor", Unsafe, [t|Int -> IO ()|])
     , ("js_scrolled", "wiki_test_live_scrolled", Unsafe, [t|JSText -> IO Double|])
     , ("js_computed_style", "wiki_test_computed_style", Unsafe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "folds the sidebar away and back, and keeps it folded" $ runPage $ do
    ui <- start m (Just "user-editor") hello
    _ <- find ui ".wiki-sidebar"
    find ui ".sidebar-fold" >>= click
    eventually $ computedStyle ".wiki-sidebar" "display" `shouldReturn` "none"
    find ui ".sidebar-fold" >>= (`shouldHaveText` "»")
    unmount ui
    -- The browser keeps it folded.
    again <- start m (Just "user-editor") hello
    eventually $ computedStyle ".wiki-sidebar" "display" `shouldReturn` "none"
    find again ".sidebar-fold" >>= click
    eventually $ computedStyle ".wiki-sidebar" "display" `shouldReturn` "block"
    unmount again

  it "makes the Markdown's font smaller and larger, and keeps its size" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    _ <- editorText ui
    computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "14.4px"
    find ui ".editor-font-smaller" >>= click
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "13.6px"
    unmount ui
    again <- start m (Just "user-editor") helloEditor
    _ <- editorText again
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "13.6px"
    find again ".editor-font-larger" >>= click
    find again ".editor-font-larger" >>= click
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "16px"
    -- Back to the size it starts at, for the tests after this one.
    find again ".editor-font-smaller" >>= click
    eventually $ computedStyle ".editor-cm .cm-scroller" "font-size" `shouldReturn` "14.4px"
    unmount again

  it "scrolls the side by side preview to the block of the cursor's line" $ runPage $ do
    ui <- start m (Just "user-editor") helloEditor
    find ui ".editor-side-by-side input" >>= click
    find ui ".editor-preview" >>= shouldBeVisible
    setMarkdown ui long
    eventually $ length <$> findAll ui ".editor-preview .page-body h2" `shouldReturn` 60
    unsafeIOToPageM (js_live_cursor (T.length long))
    eventually $ scrolled ".editor-preview" >>= (`shouldSatisfy` (> 500))
    unsafeIOToPageM (js_live_cursor 0)
    eventually $ scrolled ".editor-preview" >>= (`shouldSatisfy` (< 50))
    find ui ".editor-side-by-side input" >>= click
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
    unmount ui
    -- The editor gone, the window is told.
    eventually $ (field "closed" <=< decodeStrict . encodeUtf8) <$> unsafeIOToPageM (fromJSText <$> js_live_heard) `shouldReturn` Just (Bool True)
    unsafeIOToPageM js_live_stop

  it "shows the page in a window of its own, following its editor until it goes" $ runPage $ do
    unsafeIOToPageM js_live_start
    ui <- start m (Just "user-editor") (LivePreview (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".live-preview-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The page as saved")
    find ui ".live-preview .page-body h1" >>= (`shouldHaveText` "Hello, world")
    eventually $ unsafeIOToPageM (fromJSText <$> js_live_hello) >>= (`shouldSatisfy` T.isSuffixOf "/hello-world")
    unsafeIOToPageM (js_live_send (toJSText long) 1)
    find ui ".live-preview-state" >>= (`shouldHaveText` "Following the editor.")
    eventually $ length <$> findAll ui ".live-preview .page-body h2" `shouldReturn` 60
    unsafeIOToPageM (js_live_send (toJSText long) 230)
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
    scrolled :: Text -> PageM s Double
    scrolled selector = unsafeIOToPageM (js_scrolled (toJSText selector))
    computedStyle :: Text -> Text -> PageM s Text
    computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))
    field :: Text -> Value -> Maybe Value
    field key = \case
      Object o -> KeyMap.lookup (Key.fromText key) o
      _ -> Nothing
