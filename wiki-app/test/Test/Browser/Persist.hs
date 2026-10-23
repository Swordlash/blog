{-# LANGUAGE TemplateHaskell #-}

-- | The demo kept in the browser's IndexedDB, in a browser: what one
-- mounted application saves, the next one mounted from the same database
-- finds, as a reload of the demo's page does; and the user menu's reset
-- puts the demo's content back, there and in the database; an export
-- imported again brings back what it held; and a draft the editor saved by
-- itself is there after a reload, until it is discarded.
module Test.Browser.Persist (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.ByteString.Base64 qualified as Base64
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startKept, startKeptWith)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem (Opened (..), memArchive, runMemWiki)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Browser (zipFiles)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Export (writeArchive)

$( browserJS
     ["jsbits/test-files.js"]
     [("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])]
 )

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "finds a page saved in one mounted application in the next one" $ runPage $ do
    db <- fresh m "saved"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    clear text
    typeText text "Kept for the next visit."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Kept for the next visit.")
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body p" >>= (`shouldHaveText` "Kept for the next visit.")
    -- Who was signed in is not kept: the next visit starts as the demo does.
    find again ".user-switcher-toggle" >>= (`shouldHaveText` "Ada Admin")

  it "restores a draft saved while typing after a reload, and discards it when told to" $ runPage $ do
    db <- fresh m "draft"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    original <- getProperty text "value"
    clear text
    typeText text "Not saved, but kept."
    -- Quietly, a few seconds after the typing stops.
    eventuallyWithin 10000 $ find ui ".editor-draft-status" >>= (`shouldHaveText` "Draft saved")
    unmount ui
    again <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".editor-draft-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Restored your unsaved draft from")
    find again ".editor-text" >>= \t -> getProperty t "value" `shouldReturn` "Not saved, but kept."
    -- Discarded, the page is as it was saved.
    find again ".editor-draft-discard" >>= click
    eventually $ length <$> findAll again ".editor-draft-found" `shouldReturn` 0
    find again ".editor-text" >>= \t -> eventually (getProperty t "value" `shouldReturn` original)
    unmount again
    third <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    find third ".editor-text" >>= \t -> getProperty t "value" `shouldReturn` original
    length <$> findAll third ".editor-draft-found" `shouldReturn` 0

  it "puts the demo's content back when told to, after asking" $ runPage $ do
    db <- fresh m "reset"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    clear text
    typeText text "Soon gone."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Soon gone.")
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu .demo-kept" >>= (`shouldHaveText` "Changes to the demo are kept in this browser.")
    -- Cancel leaves everything as it was, and the question can be asked again.
    find ui ".user-menu .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Cancel"
    find ui ".user-menu .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Reset"
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".user-menu" `shouldReturn` 0
    -- Signed in as the demo starts, too.
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Ada Admin")
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")

  it "brings back what an export held, after a reset, and refuses what is not an export" $ runPage $ do
    db <- fresh m "export"
    (ui, opened) <- startKeptWith m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    clear text
    typeText text "Exported, and brought back."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu .demo-export" >>= click
    find ui ".user-menu .demo-told" >>= textContent >>= (`shouldSatisfy` ("Exported the wiki as wiki-" `T.isPrefixOf`))
    -- What was handed to the browser to save, made again the same way.
    zipped <- unsafeIOToPageM (runMemWiki opened.wiki (memArchive "test") >>= zipFiles . writeArchive)
    find ui ".user-menu .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Reset"
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    -- A file that is not an export is refused, saying why.
    find ui ".user-switcher-toggle" >>= click
    unsafeIOToPageM (choose "notes.txt" "text/plain" "just some text")
    find ui ".user-menu .demo-refused" >>= textContent >>= (`shouldSatisfy` ("Not imported: notes.txt." `T.isPrefixOf`))
    -- The export is read, and asked about before anything changes.
    unsafeIOToPageM (choose "wiki-export.zip" "application/zip" zipped)
    find ui ".demo-import-confirm p" >>= textContent >>= (`shouldSatisfy` ("Replace everything in this wiki with wiki-export.zip" `T.isPrefixOf`))
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    clickButton ui ".demo-import-confirm button" "Replace"
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")
    find ui ".user-menu .demo-told" >>= textContent >>= (`shouldSatisfy` ("Imported wiki-export.zip: 3 users, 4 spaces" `T.isPrefixOf`))
    -- And kept: the next visit finds it too.
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")

-- | Hand the user menu's import a file, as choosing it would.
choose :: Text -> Text -> ByteString -> IO ()
choose name mediaType bytes =
  evaluate =<< js_choose_file (toJSText ".user-menu .demo-import input") (toJSText name) (toJSText mediaType) (toJSText (decodeUtf8 (Base64.encode bytes)))

-- | A database of the test's own, with nothing in it.
fresh :: forall n -> (MonadBrowserTest n, MonadIndexedDB n) => Text -> PageM s Database
fresh n name = do
  let db = memDatabase ("wiki-browser-test-" <> name)
  unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: n ()))
  pure db
