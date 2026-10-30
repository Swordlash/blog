{-# LANGUAGE TemplateHaskell #-}

-- | The wiki root uses the ordinary page and editor components.
module Test.Browser.HomePage (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (readIORef)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start, startChanged, startKept, startWith)
import Test.Browser.Text (editorText, markdown, setMarkdown)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.ServerSettings (HomePage (..), ServerSettingsOf (homePage))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Access (Access (Closed))
import Wiki.Core.Permission qualified as Permission

$( browserJS
     ["jsbits/test-files.js"]
     [("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "opens the full editor, formats text, previews islands, saves and stays, then saves and closes" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") Home
    find ui ".edit-home" >>= click
    title <- find ui ".editor-title input"
    clear title
    typeText title "Knowledge"
    text <- editorText ui
    typeText text "welcome"
    press "Control+a"
    find ui ".editor-toolbar button[aria-label='Bold']" >>= click
    markdown ui `shouldReturn` "**welcome**"
    clear text
    typeText text "one\ntwo"
    press "Control+a"
    find ui ".editor-toolbar button[aria-label='Numbered list']" >>= click
    markdown ui `shouldReturn` "1. one\n2. two"
    find ui ".editor-toolbar button[aria-label='Table']" >>= click
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "|")
    setMarkdown ui "Shared **welcome**.\n\n> [!exercise]\n> Try this.\n\n$x^2$"
    find ui ".editor-side-by-side input" >>= click
    find ui ".editor-preview strong" >>= (`shouldHaveText` "welcome")
    _ <- find ui ".editor-preview .katex"
    _ <- find ui ".editor-preview .alert-exercise"
    _ <- find ui ".editor-providers"
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    _ <- editorText ui
    find ui ".editor-save-close" >>= click
    find ui ".page-view h1" >>= (`shouldHaveText` "Knowledge")
    clickButton ui ".page-actions button" "Rename"
    renamed <- find ui ".inline-form input"
    clear renamed
    typeText renamed "Knowledge renamed"
    find ui ".inline-form button.primary" >>= click
    find ui ".page-view h1" >>= (`shouldHaveText` "Knowledge renamed")
    saved <- unsafeIOToPageM (readIORef wiki)
    saved.server.homePage.title `shouldBe` "Knowledge renamed"
    length <$> findAll ui ".comments-toggle, .comments-panel, .page-comments" `shouldReturn` 0
    find ui ".home-spaces" >>= click
    find ui ".home-recent" >>= click
    eventually $ length <$> findAll ui ".space-cards, .directory .recent-spaces" `shouldReturn` 0
    void (find ui ".wiki-sidebar a[href$='#/s/docs/']")

  it "keeps uploaded attachments and source across IndexedDB reload" $ runPage $ do
    let db = memDatabase "wiki-test-full-home-attachment"
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
    ui <- startKept m db (Just "user-admin") EditHome
    _ <- editorText ui
    unsafeIOToPageM (js_choose_file (toJSText ".editor-attach input") (toJSText "home.txt") (toJSText "text/plain") (toJSText "aGVsbG8K"))
    eventually $ markdown ui `shouldReturn` "[home.txt](attachment:home.txt)"
    find ui ".editor-save-close" >>= click
    _ <- find ui ".attachments a[download='home.txt']"
    unmount ui
    again <- startKept m db (Just "user-reader") Home
    _ <- find again ".page-body a[download='home.txt']"
    _ <- find again ".attachments a[download='home.txt']"
    clickButton again ".page-actions a" "View source"
    find again ".source-text" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "attachment:home.txt")
    find again ".source-back" >>= click
    _ <- find again ".page-view"
    unmount again
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))

  it "recovers automatic drafts and protects navigation through the ordinary editor" $ runPage $ do
    let db = memDatabase "wiki-test-full-home-draft"
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
    ui <- startKept m db (Just "user-admin") EditHome
    editorText ui >>= (`typeText` "A recovered home draft.")
    find ui ".wiki-brand" >>= click
    _ <- find ui ".leave-confirm"
    clickButton ui ".leave-confirm button" "Stay"
    markdown ui `shouldReturn` "A recovered home draft."
    eventuallyWithin 10000 $ find ui ".editor-draft-status" >>= (`shouldHaveText` "Draft saved")
    unmount ui
    again <- startKept m db (Just "user-admin") EditHome
    _ <- find again ".editor-draft-found"
    markdown again `shouldReturn` "A recovered home draft."
    find again ".editor-save-close" >>= click
    find again ".page-body p" >>= (`shouldHaveText` "A recovered home draft.")
    unmount again
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))

  it "reads source and history and restores a previous root version at canonical home routes" $ runPage $ do
    ui <- start m (Just "user-admin") EditHome
    setMarkdown ui "First version."
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    setMarkdown ui "Second version."
    find ui ".editor-save-close" >>= click
    clickButton ui ".page-actions a" "History"
    find ui ".version-list li:nth-child(2) > a" >>= click
    find ui "button.restore" >>= click
    clickButton ui ".restore-confirm button" "Restore"
    find ui ".page-body p" >>= (`shouldHaveText` "First version.")
    length <$> findAll ui ".comments-toggle" `shouldReturn` 0
    unmount ui
    ordinary <- start m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    void (find ordinary ".comments-toggle")

  it "hides editing from readers and shows only the opted-in home in a closed wiki" $ runPage $ do
    reading <- start m (Just "user-editor") Home
    length <$> findAll reading ".edit-home" `shouldReturn` 0
    unmount reading
    closed <- startChanged m (privateHome False) Nothing Home
    _ <- find closed ".wiki-closed"
    unmount closed
    public <- startChanged m (privateHome False) (Just "user-admin") Home
    find public ".home-anonymous" >>= click
    find public ".user-switcher-toggle" >>= click
    find public ".user-menu button[data-login='']" >>= click
    find public ".page-view h1" >>= (`shouldHaveText` "Spaces")
    length <$> findAll public ".edit-home, .sidebar-spaces .space-link" `shouldReturn` 0
    clickButton public ".page-actions a" "View source"
    _ <- find public ".source-text"
    unmount public
    privatePage <- startChanged m (privateHome True) Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    void (find privatePage ".wiki-closed")
  where
    privateHome allowed st =
      st
        { grants = st.grants {Permission.access = Closed}
        , server = st.server {homePage = st.server.homePage {showAnonymous = allowed}}
        }
