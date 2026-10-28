-- | A page's source in a browser, over the demo's wiki: opened from the page
-- by anyone who may read it, left by its link back, and refused where the
-- page is.
module Test.Browser.Source (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "lets someone not signed in open a page's source from the page and come back" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["tour"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    -- Nothing else among the page's actions for someone who may only read it.
    actions <- traverse textContent =<< findAll ui ".page-view .actions > *"
    actions `shouldBe` ["View source", "History", "Comments (0)"]
    find ui ".page-view .actions a[href$='#/s/docs/p/tour/source/']" >>= click
    find ui ".source-view h1" >>= (`shouldHaveText` "Tour")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Source")
    source <- find ui ".source-view pre.source-text" >>= textContent
    source `shouldSatisfy` T.isPrefixOf "# Tour\n\nThis is the demo"
    -- The Markdown as written, not rendered.
    source `shouldSatisfy` T.isInfixOf "> [!NOTE]"
    length <$> findAll ui ".page-body" `shouldReturn` 0
    find ui ".source-view a.source-back" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    length <$> findAll ui ".source-view" `shouldReturn` 0

  it "says what Copy did" $ runPage $ do
    ui <- start m Nothing (PageSource (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".source-copied" >>= (`shouldHaveText` "")
    find ui ".source-view button.source-copy" >>= click
    -- Whether the headless browser lets the page write to the clipboard is
    -- its own business; either way the reader is told.
    eventually $
      find ui ".source-copied" >>= textContent >>= (`shouldSatisfy` \said -> said == "Copied" || "Could not copy" `T.isPrefixOf` said)

  it "offers an editor the source next to Edit" $ runPage $ do
    ui <- start m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    actions <- traverse textContent =<< findAll ui ".page-view .actions > a"
    take 2 actions `shouldBe` ["Edit", "View source"]

  it "says the page is not there to a reader who may not read it" $ runPage $ do
    ui <- start m (Just "user-reader") (PageSource (slugs ["team"]) (slugs ["team-handbook"]))
    find ui ".wiki-content .error-not-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "nothing here")
    length <$> findAll ui ".source-text" `shouldReturn` 0
    -- Switching to someone who may read it shows it where the refusal was.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui ".source-view h1" >>= (`shouldHaveText` "Team handbook")

  it "says that the source of a page that is not there is not there" $ runPage $ do
    ui <- start m Nothing (PageSource (slugs ["docs"]) (slugs ["no-such-page"]))
    _ <- find ui ".wiki-content .error-not-found"
    length <$> findAll ui ".source-text" `shouldReturn` 0
