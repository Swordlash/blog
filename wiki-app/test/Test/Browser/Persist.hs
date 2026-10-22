-- | The demo kept in the browser's IndexedDB, in a browser: what one
-- mounted application saves, the next one mounted from the same database
-- finds, as a reload of the demo's page does; and the user menu's reset
-- puts the demo's content back, there and in the database.
module Test.Browser.Persist (spec) where

import Control.Monad.UUID (MonadUUID)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, startKept)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "finds a page saved in one mounted application in the next one" $ runPage $ do
    db <- fresh m "saved"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    clear text
    typeText text "Kept for the next visit."
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-body p" >>= (`shouldHaveText` "Kept for the next visit.")
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body p" >>= (`shouldHaveText` "Kept for the next visit.")
    -- Who was signed in is not kept: the next visit starts as nobody.
    find again ".user-switcher-toggle" >>= (`shouldHaveText` "Not signed in")

  it "puts the demo's content back when told to, after asking" $ runPage $ do
    db <- fresh m "reset"
    ui <- startKept m db (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- find ui ".editor-text"
    clear text
    typeText text "Soon gone."
    find ui ".editor-form button.primary" >>= click
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
    -- Who is signed in stays.
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Edgar Editor")
    unmount ui
    again <- startKept m db Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find again ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")

-- | A database of the test's own, with nothing in it.
fresh :: forall n -> (MonadBrowserTest n, MonadIndexedDB n) => Text -> PageM s Database
fresh n name = do
  let db = memDatabase ("wiki-browser-test-" <> name)
  unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: n ()))
  pure db
