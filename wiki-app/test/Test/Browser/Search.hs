-- | The search box in the shell's header, in a browser, over the demo's wiki:
-- typing, the space selector, the keyboard, and following a hit.
module Test.Browser.Search (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  it "narrows the results as words are typed, down to none" $ runPage $ do
    ui <- start m Nothing Home
    box <- find ui ".wiki-search .search-input"
    typeText box "mermaid"
    eventually $ hitTitles ui >>= (`shouldSatisfy` elem "Diagrams")
    before <- hitTitles ui
    typeText box " flow"
    eventually $ do
      after <- hitTitles ui
      after `shouldSatisfy` elem "Diagrams"
      after `shouldSatisfy` all (`elem` before)
    find ui ".search-results .search-hit mark" >>= (`shouldHaveText` "mermaid")
    typeText box " xyzzy"
    find ui ".search-results .search-empty" >>= (`shouldHaveText` "No results")

  it "keeps to the space chosen" $ runPage $ do
    ui <- start m Nothing Home
    find ui ".wiki-search .search-input" >>= (`typeText` "the")
    eventually $ hitSpaces ui >>= (`shouldSatisfy` elem "Docs")
    find ui ".wiki-search .search-space" >>= (`typeText` "Blog")
    eventually $ do
      spaces <- hitSpaces ui
      spaces `shouldSatisfy` (not . null)
      ordNub spaces `shouldBe` ["Blog"]
    -- The space was chosen with focus in the box, so the list stayed open.
    find ui ".wiki-search .search-subspaces input" >>= (`getProperty` "checked") >>= (`shouldBe` "true")

  it "finds nothing of Team for reader but in Projects" $ runPage $ do
    ui <- start m (Just "user-reader") Home
    box <- find ui ".wiki-search .search-input"
    typeText box "the"
    eventually $ hitSpaces ui >>= (`shouldSatisfy` elem "Team / Projects")
    hitSpaces ui >>= (`shouldSatisfy` notElem "Team")
    clear box
    typeText box "handbook"
    find ui ".search-results .search-empty" >>= (`shouldHaveText` "No results")

  it "opens the hit chosen with the arrows and Enter" $ runPage $ do
    ui <- start m Nothing Home
    find ui ".wiki-search .search-input" >>= (`typeText` "diagrams")
    eventually $ hitTitles ui >>= (`shouldSatisfy` ((== Just "Diagrams") . head))
    press "ArrowDown"
    press "ArrowDown"
    press "ArrowUp"
    find ui ".search-results .search-hit.selected .search-hit-title" >>= (`shouldHaveText` "Diagrams")
    press "Enter"
    find ui ".page-body h1" >>= (`shouldHaveText` "Diagrams")
    eventually $ length <$> findAll ui ".search-results" `shouldReturn` 0

  it "opens a hit that is clicked" $ runPage $ do
    ui <- start m Nothing (Space (slugs ["blog"]))
    find ui ".wiki-search .search-input" >>= (`typeText` "mathematics")
    hit <- eventually $ do
      hits <- findAll ui ".search-results a.search-hit[href='#/s/docs/p/markdown-guide/mathematics/']"
      maybe (expectationFailure "no hit for Mathematics yet") pure (head hits)
    click hit
    find ui ".page-body h1" >>= (`shouldHaveText` "Mathematics")
    eventually $ length <$> findAll ui ".search-results" `shouldReturn` 0

  it "opens the page of all results with Enter when no hit is chosen" $ runPage $ do
    ui <- start m Nothing Home
    find ui ".wiki-search .search-input" >>= (`typeText` "mermaid")
    eventually $ hitTitles ui >>= (`shouldSatisfy` elem "Diagrams")
    press "Enter"
    find ui ".search-view h1" >>= (`shouldHaveText` "Search")
    find ui ".search-view .search-summary" >>= \summary ->
      textContent summary >>= (`shouldSatisfy` T.isSuffixOf "for “mermaid” in every space.")
    _ <- find ui ".search-view a.search-hit[href='#/s/docs/p/markdown-guide/diagrams/']"
    pure ()

  it "is focused by /, and closed by Escape" $ runPage $ do
    ui <- start m Nothing Home
    press "/"
    traverse_ press ["t", "o", "u", "r"]
    box <- find ui ".wiki-search .search-input"
    eventually $ getProperty box "value" >>= (`shouldBe` "tour")
    eventually $ hitTitles ui >>= (`shouldSatisfy` elem "Tour")
    press "Escape"
    eventually $ length <$> findAll ui ".search-results" `shouldReturn` 0

-- | The titles of the hits the box lists now.
hitTitles :: Mounted s q o m -> PageM s [Text]
hitTitles ui = traverse textContent =<< findAll ui ".search-results .search-hit-title"

-- | The space of each hit the box lists now.
hitSpaces :: Mounted s q o m -> PageM s [Text]
hitSpaces ui = traverse textContent =<< findAll ui ".search-results .search-hit-space"
