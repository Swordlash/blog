-- | Stars and help in a browser (WP5.44 of docs/PLAN.md), over the demo. A
-- page's "Star" button stars it, and the header's "Starred" list then
-- holds it, as a link that goes to the page; the button takes the star
-- away again. Someone not signed in has neither. The "?" in the corner
-- opens the help dialog, with the guide's sections rendered and the demo's
-- own kind of box, and closes it.
module Test.Browser.Stars (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  starring m
  helping m

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

hello :: Route
hello = Page (slugs ["blog"]) (slugs ["hello-world"])

starring :: forall m -> (Specs m) => Spec
starring m = describe "stars" $ do
  it "stars a page, lists it under Starred with a link to it, and takes the star away" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    button <- find ui ".page-actions .star-toggle"
    getAttribute button "aria-pressed" `shouldReturn` Just "false"
    -- Nothing starred yet.
    find ui ".starred-toggle" >>= click
    find ui ".starred-panel .starred-empty" >>= (`shouldContainText` "No starred pages yet")
    find ui ".starred-toggle" >>= click
    find ui ".page-actions .star-toggle" >>= click
    eventually (find ui ".page-actions .star-toggle" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "true")
    find ui ".page-actions .star-toggle" >>= (`shouldContainText` "Starred")
    -- The list holds the page, with its space, and goes to it from
    -- another page.
    find ui ".wiki-brand" >>= click
    find ui ".starred-toggle" >>= click
    starredLink <- find ui ".starred-list a.starred-link"
    find ui ".starred-list .starred-title" >>= (`shouldHaveText` "Hello, world")
    find ui ".starred-list .starred-space" >>= (`shouldHaveText` "Blog")
    getAttribute starredLink "href" >>= (`shouldSatisfy` maybe False (T.isInfixOf "/s/blog/p/hello-world/"))
    click starredLink
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".starred-panel" `shouldReturn` 0
    -- The button takes the star away, and the list is empty again.
    find ui ".page-actions .star-toggle" >>= click
    eventually (find ui ".page-actions .star-toggle" >>= \b -> getAttribute b "aria-pressed" `shouldReturn` Just "false")
    find ui ".starred-toggle" >>= click
    find ui ".starred-panel .starred-empty" >>= (`shouldContainText` "No starred pages yet")
    unmount ui

  it "offers neither the button nor the list to someone not signed in" $ runPage $ do
    ui <- start m Nothing hello
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".star-toggle" `shouldReturn` 0
    length <$> findAll ui ".starred-menu" `shouldReturn` 0
    unmount ui

helping :: forall m -> (Specs m) => Spec
helping m = describe "help" $ do
  it "opens a dialog with the guide's sections and this wiki's kinds of box, and closes it" $ runPage $ do
    ui <- start m Nothing Home
    let dialogOpen = find ui "dialog.help-dialog" >>= (`getProperty` "open")
    dialogOpen `shouldReturn` "false"
    length <$> findAll ui ".help-section" `shouldReturn` 0
    find ui ".help-toggle" >>= click
    eventually (dialogOpen `shouldReturn` "true")
    titles <- traverse textContent =<< findAll ui ".help-section h3"
    titles `shouldSatisfy` \ts -> all (`elem` ts) ["Emoji", "Mathematics", "Diagrams", "Pictures", "Notes and boxes", "This wiki's kinds of box"]
    -- The guide's boxes, rendered, and the demo's own kind.
    length <$> findAll ui ".help-section .alert-note" >>= (`shouldSatisfy` (> 0))
    length <$> findAll ui ".help-section .alert-exercise" >>= (`shouldSatisfy` (> 0))
    -- Each section's Markdown is there to read.
    length <$> findAll ui ".help-section details.help-source pre" >>= (`shouldSatisfy` (>= length titles))
    -- The link to the whole guide leads to the demo's Docs.
    find ui ".help-guide-link" >>= (`getAttribute` "href") >>= (`shouldSatisfy` maybe False (T.isInfixOf "/s/docs/p/markdown-guide/"))
    find ui ".help-dialog-close" >>= click
    eventually (dialogOpen `shouldReturn` "false")
    length <$> findAll ui ".help-section" `shouldReturn` 0
    unmount ui
