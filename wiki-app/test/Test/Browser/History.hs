-- | A page's history in a browser, over the demo's wiki with its first post
-- saved twice by the editor: opened from the page by anyone who may read
-- it, a version chosen and compared both ways, and restored by an editor,
-- which the page and its history then show; a reader is offered no
-- restore.
module Test.Browser.History (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), savePageIn)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page qualified as P

-- | The demo with its first post's heading changed twice by the editor:
-- "Hello, world", then "Hello, wiki" (with a new title), then "Hello,
-- everyone".
savedTwice :: MemState -> MemState
savedTwice demo = case saves of
  Right st -> st {current = demo.current}
  Left e -> panic ("the demo's first post could not be saved: " <> show e)
  where
    hello = fromMaybe (panic "the demo has no first post") (head (filter (\p -> p.title == "Hello, world") (Map.elems demo.pages)))
    heading h = T.replace "# Hello, world" ("# Hello, " <> h) hello.body
    saves = do
      (st1, once) <- savePageIn hello.id hello.updatedAt "Hello, again" (heading "wiki") demoNow demo {current = Just (UserId "user-editor")}
      (st2, _) <- savePageIn hello.id once.updatedAt "Hello, again" (heading "everyone") demoNow st1
      pure st2

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "lets someone not signed in open a page's history from the page, and come back" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["tour"]))
    actions <- traverse textContent =<< findAll ui ".page-view .actions > *"
    actions `shouldBe` ["View source", "History", "Comments (0)"]
    find ui ".page-view .actions a[href$='#/s/docs/p/tour/history/']" >>= click
    find ui ".history-view h1" >>= (`shouldHaveText` "Tour")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "History")
    versions <- traverse textContent =<< findAll ui ".version-list li > a"
    versions `shouldBe` ["Version 1 (current)"]
    find ui ".diff-summary" >>= (`shouldHaveText` "The first version: all of its text is new.")
    (find ui ".diff .diff-added .diff-text" >>= textContent) `shouldReturn` "# Tour"
    -- The time, written by the reader's browser in their zone.
    eventually $ find ui ".version-meta time" >>= textContent >>= (`shouldSatisfy` (not . T.null))
    length <$> findAll ui ".restore" `shouldReturn` 0
    find ui ".history-view a.history-back" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")

  it "shows what a version changed and what has changed since, and restores it for an editor" $ runPage $ do
    ui <- startChanged m savedTwice (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, everyone")
    clickLink ui ".page-view .actions a" "History"
    versions <- traverse textContent =<< findAll ui ".version-list li > a"
    versions `shouldBe` ["Version 3 (current)", "Version 2", "Version 1"]
    -- The latest: what the last save changed, a word in a line.
    find ui ".version-detail h2" >>= (`shouldHaveText` "Version 3 (current)")
    (find ui ".diff-removed del" >>= textContent) `shouldReturn` "wiki"
    (find ui ".diff-added ins" >>= textContent) `shouldReturn` "everyone"
    length <$> findAll ui ".restore" `shouldReturn` 0
    clickLink ui ".version-list a" "Version 2"
    find ui ".version-detail h2" >>= (`shouldHaveText` "Version 2")
    find ui ".diff-title del" >>= (`shouldHaveText` "Hello, world")
    find ui ".diff-title ins" >>= (`shouldHaveText` "Hello, again")
    (find ui ".diff-removed del" >>= textContent) `shouldReturn` "world"
    (find ui ".diff-added ins" >>= textContent) `shouldReturn` "wiki"
    clickLink ui ".diff-against a" "the current version"
    find ui ".diff-against-chosen" >>= (`shouldHaveText` "the current version")
    (find ui ".diff-added ins" >>= textContent) `shouldReturn` "everyone"
    -- Restore asks first, and Cancel leaves everything as it was.
    find ui "button.restore" >>= click
    clickButton ui ".restore-confirm button" "Cancel"
    length <$> findAll ui ".restore-confirm" `shouldReturn` 0
    find ui "button.restore" >>= click
    clickButton ui ".restore-confirm button" "Restore"
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, wiki")
    clickLink ui ".page-view .actions a" "History"
    versions' <- traverse textContent =<< findAll ui ".version-list li > a"
    versions' `shouldBe` ["Version 4 (current)", "Version 3", "Version 2", "Version 1"]
    find ui ".version-detail .version-meta" >>= textContent >>= (`shouldSatisfy` T.isSuffixOf "by Edgar Editor")
    (find ui ".diff-removed del" >>= textContent) `shouldReturn` "everyone"
    (find ui ".diff-added ins" >>= textContent) `shouldReturn` "wiki"

  it "offers a reader who may not edit the page no restore" $ runPage $ do
    ui <- startChanged m savedTwice (Just "user-reader") (PageHistory (slugs ["blog"]) (slugs ["hello-world"]) Nothing AgainstPrevious)
    clickLink ui ".version-list a" "Version 1"
    find ui ".version-detail h2" >>= (`shouldHaveText` "Version 1")
    find ui ".diff-summary" >>= (`shouldHaveText` "The first version: all of its text is new.")
    length <$> findAll ui ".restore" `shouldReturn` 0

  it "refuses the history where the page is refused" $ runPage $ do
    ui <- start m Nothing (PageHistory (slugs ["team"]) (slugs ["team-handbook"]) Nothing AgainstPrevious)
    find ui ".wiki-content .error-forbidden" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "permission")
    length <$> findAll ui ".history-view" `shouldReturn` 0
  where
    -- Follow the link among those matching a selector that says this.
    clickLink ui selector label = do
      links <- findAll ui selector
      labelled <- filterM (fmap (== label) . textContent) links
      case labelled of
        l : _ -> click l
        [] -> expectationFailure ("no " <> selector <> " says " <> label)
