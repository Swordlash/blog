{-# LANGUAGE TemplateHaskell #-}

-- | The demo kept in the browser's IndexedDB, in a browser: what one
-- mounted application saves, the next one mounted from the same database
-- finds, as a reload of the demo's page does; and the administration's
-- reset puts the demo's content back, there and in the database; its
-- export, downloaded and imported again, brings back what it held; and a
-- draft the editor saved by itself is there after a reload, until it is
-- discarded.
module Test.Browser.Persist (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.ByteString.Base64 qualified as Base64
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startKept, startKeptWith)
import Test.Browser.Text (editorText, markdown)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem (Opened (..), memArchive, runMemWiki)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Browser (zipFiles)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Export (writeArchive)

$( browserJS
     ["jsbits/test-files.js"]
     [ ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_downloads", "wiki_test_downloads", Unsafe, [t|IO JSText|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "finds a page saved in one mounted application in the next one" $ runPage $ do
    db <- fresh m "saved"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- editorText ui
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
    text <- editorText ui
    original <- markdown ui
    clear text
    typeText text "Not saved, but kept."
    -- Quietly, a few seconds after the typing stops.
    eventuallyWithin 10000 $ find ui ".editor-draft-status" >>= (`shouldHaveText` "Draft saved")
    unmount ui
    again <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".editor-draft-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Restored your unsaved draft from")
    markdown again `shouldReturn` "Not saved, but kept."
    -- Discarded, the page is as it was saved.
    find again ".editor-draft-discard" >>= click
    eventually $ length <$> findAll again ".editor-draft-found" `shouldReturn` 0
    eventually (markdown again `shouldReturn` original)
    unmount again
    third <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    markdown third `shouldReturn` original
    length <$> findAll third ".editor-draft-found" `shouldReturn` 0

  it "puts the demo's content back from the administration, after asking" $ runPage $ do
    db <- fresh m "reset"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- editorText ui
    clear text
    typeText text "Soon gone."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Soon gone.")
    -- The user menu only switches users now.
    find ui ".user-switcher-toggle" >>= click
    _ <- find ui ".user-menu button[data-login=admin]"
    length <$> findAll ui ".user-menu .demo-reset-ask" `shouldReturn` 0
    find ui ".user-switcher-toggle" >>= click
    administration ui
    find ui ".admin-view .demo-kept" >>= (`shouldHaveText` "Changes to the demo are kept in this browser.")
    -- Cancel leaves everything as it was, and the question can be asked again.
    find ui ".admin-view .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Cancel"
    find ui ".admin-view .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Reset"
    find ui ".admin-view .demo-told" >>= (`shouldHaveText` "The demo's content is back as it was at the start.")
    -- Signed in as the demo starts, too.
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Ada Admin")
    helloWorld ui
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")

  it "exports the wiki as a download, and brings back what it held after a reset, refusing what is not an export" $ runPage $ do
    db <- fresh m "export"
    (ui, opened) <- startKeptWith m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- editorText ui
    clear text
    typeText text "Exported, and brought back."
    find ui ".editor-save-close" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")
    administration ui
    before <- unsafeIOToPageM downloads
    find ui ".admin-view .demo-export" >>= click
    told <- find ui ".admin-view .demo-told" >>= textContent
    told `shouldSatisfy` ("Exported the wiki as wiki-" `T.isPrefixOf`)
    -- Handed to the browser to save, by the name it says.
    saved <- unsafeIOToPageM downloads
    drop (length before) saved `shouldBe` [T.dropEnd 1 (T.drop (T.length "Exported the wiki as ") told)]
    -- What was handed to the browser to save, made again the same way.
    zipped <- unsafeIOToPageM (runMemWiki opened.wiki (memArchive "test") >>= zipFiles . writeArchive)
    find ui ".admin-view .demo-reset-ask" >>= click
    clickButton ui ".demo-reset-confirm button" "Reset"
    find ui ".admin-view .demo-told" >>= (`shouldHaveText` "The demo's content is back as it was at the start.")
    -- A file that is not an export is refused, saying why.
    unsafeIOToPageM (choose "notes.txt" "text/plain" "just some text")
    find ui ".admin-view .demo-refused" >>= textContent >>= (`shouldSatisfy` ("Not imported: notes.txt." `T.isPrefixOf`))
    -- The export is read, and asked about before anything changes; Cancel
    -- leaves the wiki as it is.
    unsafeIOToPageM (choose "wiki-export.zip" "application/zip" zipped)
    find ui ".demo-import-confirm p" >>= textContent >>= (`shouldSatisfy` ("Replace everything in this wiki with wiki-export.zip" `T.isPrefixOf`))
    clickButton ui ".demo-import-confirm button" "Cancel"
    length <$> findAll ui ".demo-import-confirm" `shouldReturn` 0
    unsafeIOToPageM (choose "wiki-export.zip" "application/zip" zipped)
    _ <- find ui ".demo-import-confirm p"
    clickButton ui ".demo-import-confirm button" "Replace"
    find ui ".admin-view .demo-told" >>= textContent >>= (`shouldSatisfy` ("Imported wiki-export.zip: 3 users, 4 spaces" `T.isPrefixOf`))
    helloWorld ui
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")
    -- And kept: the next visit finds it too.
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body p" >>= (`shouldHaveText` "Exported, and brought back.")

-- | Go to the administration from the header, as admin: the link is there
-- for nobody else, so whoever is signed in is switched to admin first, if
-- need be, from the user menu.
administration :: Mounted s q o n -> PageM s ()
administration ui = do
  signedIn <- find ui ".user-switcher-toggle" >>= textContent
  unless (T.strip signedIn == "Ada Admin") $ do
    length <$> findAll ui ".admin-link" `shouldReturn` 0
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Ada Admin")
  find ui ".wiki-header a.admin-link" >>= click
  find ui ".admin-view h1" >>= (`shouldHaveText` "Administration")
  find ui ".admin-view .admin-data h2" >>= (`shouldHaveText` "Wiki data")

-- | Go to Hello, world from the spaces: the blog's card, then its page
-- tree.
helloWorld :: Mounted s q o n -> PageM s ()
helloWorld ui = do
  find ui ".wiki-brand" >>= click
  find ui ".space-card-link[href$='#/s/blog/']" >>= click
  find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/hello-world/']" >>= click
  find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Hello, world")

-- | Hand the administration's import a file, as choosing it would.
choose :: Text -> Text -> ByteString -> IO ()
choose name mediaType bytes =
  evaluate =<< js_choose_file (toJSText ".admin-view .demo-import input") (toJSText name) (toJSText mediaType) (toJSText (decodeUtf8 (Base64.encode bytes)))

-- | A database of the test's own, with nothing in it.
fresh :: forall n -> (MonadBrowserTest n, MonadIndexedDB n) => Text -> PageM s Database
fresh n name = do
  let db = memDatabase ("wiki-browser-test-" <> name)
  unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: n ()))
  pure db

-- | The names of the files the page has handed the browser to save, since
-- the first time this was asked.
downloads :: IO [Text]
downloads = filter (not . T.null) . T.splitOn "\n" . fromJSText <$> js_downloads
