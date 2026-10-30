-- | The shared front page edited and read in a real browser.
module Test.Browser.HomePage (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (readIORef)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (answerWith, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (start, startKept, startWith)
import Test.Browser.Text (editorText, markdown)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.Error qualified as Api
import Wiki.Api.ServerSettings (HomePage (..), ServerSettingsOf (homePage), defaultHomePage)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "edits shared Markdown with CodeMirror, previews actual sections and saves independent switches" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") Home
    find ui ".edit-home" >>= click
    title <- find ui ".home-title"
    clear title
    typeText title "Knowledge"
    text <- editorText ui
    typeText text "Shared **welcome**.\n\n> [!exercise]\n> Try this.\n\n$x^2$"
    find ui ".home-spaces" >>= click
    find ui ".preview-home" >>= click
    find ui ".home-preview h1" >>= (`shouldHaveText` "Knowledge")
    find ui ".home-preview strong" >>= (`shouldHaveText` "welcome")
    find ui ".home-preview .alert-exercise .alert-title" >>= (`shouldHaveText` "Exercise")
    _ <- find ui ".home-preview .katex"
    length <$> findAll ui ".home-preview .space-cards" `shouldReturn` 0
    _ <- find ui ".home-preview .recent-spaces"
    find ui ".preview-home" >>= click
    getProperty title "value" `shouldReturn` "Knowledge"
    markdown ui `shouldReturn` "Shared **welcome**.\n\n> [!exercise]\n> Try this.\n\n$x^2$"
    find ui ".save-home" >>= click
    find ui ".directory-header h1" >>= (`shouldHaveText` "Knowledge")
    _ <- find ui ".directory .page-body strong"
    length <$> findAll ui ".space-cards" `shouldReturn` 0
    _ <- find ui ".directory .recent-spaces"
    _ <- find ui ".wiki-sidebar a[href$='#/s/docs/']"
    saved <- unsafeIOToPageM (readIORef wiki)
    saved.server.homePage.showSpaces `shouldBe` False
    saved.server.homePage.showRecent `shouldBe` True
    find ui ".edit-home" >>= click
    find ui ".home-spaces" >>= click
    find ui ".home-recent" >>= click
    find ui ".save-home" >>= click
    _ <- find ui ".space-cards"
    length <$> findAll ui ".directory .recent-spaces" `shouldReturn` 0

  it "cancels title, Markdown and section changes without writing them" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") Home
    find ui ".edit-home" >>= click
    title <- find ui ".home-title"
    clear title
    typeText title "Discarded"
    editorText ui >>= (`typeText` "Discarded body.")
    find ui ".home-recent" >>= click
    find ui ".cancel-home" >>= click
    find ui ".directory-header h1" >>= (`shouldHaveText` "Spaces")
    _ <- find ui ".space-cards"
    st <- unsafeIOToPageM (readIORef wiki)
    st.server.homePage `shouldBe` defaultHomePage
    find ui ".edit-home" >>= click
    markdown ui `shouldReturn` ""

  it "keeps a failed save's draft, including its title and section choices" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "PUT" "api/v1/admin/home-page" 400 (Api.Invalid "The save was refused.")
    ui <- startServer m Home
    find ui ".edit-home" >>= click
    title <- find ui ".home-title"
    clear title
    typeText title "Still here"
    editorText ui >>= (`typeText` "Keep this draft.")
    find ui ".home-spaces" >>= click
    find ui ".save-home" >>= click
    find ui ".home-editor .error" >>= (`shouldHaveText` "The save was refused.")
    getProperty title "value" `shouldReturn` "Still here"
    markdown ui `shouldReturn` "Keep this draft."
    find ui ".preview-home" >>= click
    length <$> findAll ui ".home-preview .space-cards" `shouldReturn` 0
    find ui ".home-preview h1" >>= (`shouldHaveText` "Still here")
    serverStops

  it "reloads the saved home page from IndexedDB for a reader and an anonymous visitor" $ runPage $ do
    let db = memDatabase "wiki-test-homepage"
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
    ui <- startKept m db (Just "user-admin") Home
    find ui ".edit-home" >>= click
    title <- find ui ".home-title"
    clear title
    typeText title "Our wiki"
    editorText ui >>= (`typeText` "Everyone sees this.")
    find ui ".home-spaces" >>= click
    find ui ".home-recent" >>= click
    find ui ".save-home" >>= click
    _ <- find ui ".directory-header"
    unmount ui
    readingUi <- startKept m db (Just "user-reader") Home
    find readingUi ".directory-header h1" >>= (`shouldHaveText` "Our wiki")
    find readingUi ".directory .page-body p" >>= (`shouldHaveText` "Everyone sees this.")
    length <$> findAll readingUi ".edit-home" `shouldReturn` 0
    length <$> findAll readingUi ".directory .space-cards, .directory .recent-spaces" `shouldReturn` 0
    unmount readingUi
    visitor <- startKept m db (Just "") Home
    find visitor ".directory-header h1" >>= (`shouldHaveText` "Our wiki")
    length <$> findAll visitor ".edit-home" `shouldReturn` 0
    unmount visitor
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))

  it "offers no editing action to a space editor or an anonymous visitor" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    _ <- find ui ".space-cards"
    length <$> findAll ui ".edit-home" `shouldReturn` 0
    unmount ui
    visitor <- start m Nothing Home
    _ <- find visitor ".space-cards"
    length <$> findAll visitor ".edit-home" `shouldReturn` 0
