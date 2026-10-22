-- | The shell in a browser, over the demo's wiki: what each user sees, going
-- from page to page by clicking, and changing spaces and pages. Each test
-- starts on a fresh copy of the demo ("Test.Browser.Mount").
module Test.Browser.Shell (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadIslands m, MonadUUID m) => Spec
spec m = do
  it "lists the public spaces on the front page for someone not signed in" $ runPage $ do
    ui <- start m Nothing Home
    names <- traverse textContent =<< findAll ui ".home .space-list li a"
    names `shouldBe` ["Blog", "Docs"]
    textContent (root ui) >>= (`shouldSatisfy` (not . T.isInfixOf "Team"))
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Not signed in")

  it "goes to a page by clicking, and draws its formulas" $ runPage $ do
    ui <- start m Nothing Home
    find ui ".space-tree a[href='#/s/docs/']" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Docs")
    find ui ".space-view .page-tree a[href='#/s/docs/p/markdown-guide/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Markdown guide")
    find ui ".wiki-sidebar .page-tree a[href='#/s/docs/p/markdown-guide/mathematics/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Mathematics")
    _ <- find ui ".page-body .wiki-math-display .katex-display"
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Mathematics")

  it "follows a link in a page's Markdown without loading another page" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["tour"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    find ui ".page-body a[href='#/s/docs/p/markdown-guide/diagrams/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Diagrams")
    _ <- eventuallyWithin 15000 (find ui ".page-body .wiki-mermaid > svg")
    pure ()

  it "lets admin create a space, which the tree then shows" $ runPage $ do
    ui <- start m Nothing Home
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Ada Admin")
    find ui ".wiki-sidebar a.new-space-link" >>= click
    find ui ".new-space-view input" >>= (`typeText` "Research notes")
    find ui ".new-space-view button.primary" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Research notes")
    find ui ".space-tree a[href='#/s/research-notes/']" >>= (`shouldHaveText` "Research notes")

  it "shows reader the private Team only as the way to Projects" $ runPage $ do
    ui <- start m (Just "user-reader") Home
    find ui ".space-tree .unviewable" >>= (`shouldHaveText` "Team")
    length <$> findAll ui ".space-tree a[href='#/s/team/']" `shouldReturn` 0
    find ui ".space-tree a[href='#/s/team/projects/']" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Projects")

  it "says in place that reader may not see Team" $ runPage $ do
    ui <- start m (Just "user-reader") (Space (slugs ["team"]))
    find ui ".wiki-content .error-forbidden" >>= (`shouldSatisfy'` "permission")
    -- Switching to someone who may see it shows it where the refusal was.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Team")

  it "offers nobody an action on a space they may only read" $ runPage $ do
    ui <- start m Nothing (Space (slugs ["blog"]))
    find ui ".space-view h1" >>= (`shouldHaveText` "Blog")
    length <$> findAll ui ".space-view .actions button" `shouldReturn` 0

  it "lets an editor add a page, rename it and delete it" $ runPage $ do
    ui <- start m (Just "user-editor") (Space (slugs ["blog"]))
    find ui ".space-view .actions a[href='#/s/blog/new-page/']" >>= (`shouldHaveText` "New page")
    find ui ".space-view .actions a[href='#/s/blog/new-page/']" >>= click
    find ui ".editor-title input" >>= (`typeText` "Third post")
    find ui ".editor-form button.primary" >>= click
    find ui ".page-view .page-title" >>= (`shouldHaveText` "Third post")
    clickButton ui ".page-view .actions button" "Rename"
    field <- find ui ".page-view form input"
    clear field
    typeText field "The third post"
    find ui ".page-view form button.primary" >>= click
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "The third post")
    clickButton ui ".page-view .actions button" "Delete"
    find ui ".page-view .confirm button.danger" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Blog")
    links <- traverse textContent =<< findAll ui ".space-view .page-tree a"
    links `shouldBe` ["Hello, world", "Notes on Haskell"]

  it "lets admin move a subspace to the top level" $ runPage $ do
    ui <- start m (Just "user-admin") (Space (slugs ["team", "projects"]))
    clickButton ui ".space-view .actions button" "Move"
    find ui ".space-view form select" >>= (`shouldHaveText'` "The top level")
    find ui ".space-view form button.primary" >>= click
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Projects")
    _ <- find ui ".wiki-sidebar > .space-tree > li > .space-row a[href='#/s/projects/']"
    pure ()

  it "shows that an address is nothing" $ runPage $ do
    ui <- start m Nothing Unknown
    find ui ".not-found h1" >>= (`shouldHaveText` "Not found")
  where
    shouldSatisfy' element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)
    shouldHaveText' element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)
