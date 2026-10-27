-- | The order of a space's pages, in a browser: an administrator chooses
-- it in the space's settings and the lists follow; an editor moves a page
-- by hand and the order is still there after a reload (IndexedDB); a
-- reader sees the order and nothing to change it with.
module Test.Browser.Order (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start, startChanged, startKept)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State (MemState (..), setOrder)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Order (ChildOrder (..), Children (..))
import Wiki.Core.Space qualified as Core

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "lists a space's pages newest first once an administrator chooses it, in the space and the sidebar" $ runPage $ do
    ui <- start m (Just "user-admin") blog
    titlesIn ui spacePages `shouldReturn` ["Hello, world", "Notes on Haskell"]
    chooseOrder ui ".order-pages select" "ArrowDown"
    eventually (titlesIn ui spacePages `shouldReturn` ["Notes on Haskell", "Hello, world"])
    titlesIn ui sidebarPages `shouldReturn` ["Notes on Haskell", "Hello, world"]
    -- Not by hand, so there is nothing to move a page with.
    length <$> findAll ui ".space-view .move-controls" `shouldReturn` 0

  it "keeps a page an editor moved up after a reload" $ runPage $ do
    db <- fresh "order"
    admin <- startKept m db (Just "user-admin") blog
    chooseOrder admin ".order-pages select" "End"
    _ <- eventually (find admin ".space-view .page-tree .move-controls")
    unmount admin
    editor <- startKept m db (Just "user-editor") blog
    titlesIn editor spacePages `shouldReturn` ["Hello, world", "Notes on Haskell"]
    -- The first page cannot go further up; the second can.
    ups <- findAll editor ".space-view .page-tree .move-up"
    traverse (`getProperty` "disabled") ups `shouldReturn` ["true", "false"]
    case ups of
      [_, notes] -> click notes
      _ -> expectationFailure "expected a move-up button for each page"
    eventually (titlesIn editor spacePages `shouldReturn` ["Notes on Haskell", "Hello, world"])
    unmount editor
    again <- startKept m db (Just "user-editor") blog
    titlesIn again spacePages `shouldReturn` ["Notes on Haskell", "Hello, world"]
    titlesIn again sidebarPages `shouldReturn` ["Notes on Haskell", "Hello, world"]

  it "shows a reader the order chosen, and nothing to change it with" $ runPage $ do
    ui <- startChanged m (byHandNewestFirst "Blog") (Just "user-reader") blog
    titlesIn ui spacePages `shouldReturn` ["Notes on Haskell", "Hello, world"]
    length <$> findAll ui ".move-controls" `shouldReturn` 0
    buttons <- findAll ui ".space-view .actions button"
    labels <- traverse textContent buttons
    labels `shouldSatisfy` notElem "Order"
  where
    blog = SpacePages (slugs ["blog"])
    spacePages = ".space-view .page-tree a"
    sidebarPages = ".wiki-sidebar .page-tree a"

    -- Open the space's order form, move the menu given with a key (a menu
    -- of the orders: by name, newest first, oldest first, by hand), save.
    chooseOrder ui menu key = do
      clickButton ui ".space-view .actions button" "Order"
      select <- find ui menu
      focus select
      press key
      clickButton ui ".space-view .inline-form button" "Save order"

    titlesIn ui selector = findAll ui selector >>= traverse textContent

    -- A database of the test's own, with nothing in it.
    fresh :: Text -> PageM s Database
    fresh name = do
      let db = memDatabase ("wiki-browser-test-" <> name)
      unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
      pure db

-- | The demo with a space's pages put by hand in the order newest first
-- gives them: the order it shows when it is switched to by hand from there.
byHandNewestFirst :: Text -> MemState -> MemState
byHandNewestFirst name st = case [s.id | s :: Core.Space <- Map.elems st.spaces, s.name == name] of
  sid : _ -> setOrder sid ChildPages ByHand (setOrder sid ChildPages NewestFirst st)
  [] -> panic ("the demo has no space " <> name)
