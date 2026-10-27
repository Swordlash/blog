{-# LANGUAGE TemplateHaskell #-}

-- | The shell adopting a page that arrives with its HTML, as a prerendered
-- page does ('Halogen.VDom.Driver.hydrateUI'): every element is kept, the
-- listeners are attached, and the page goes on from there.
--
-- "Halogen.Static" renders natively only, so the HTML here is the shell's
-- own, rendered in the test page at the route and written out as the
-- prerender writes it (test/jsbits/test-markup.js), then parsed back by the
-- browser into a container of its own, which a fresh shell over a fresh
-- demo adopts. The prerendered pages themselves are adopted in the smoke
-- test, which counts what the program had to repair in each.
module Test.Browser.Hydrate (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (adopt, slugs, start)
import Test.Browser.Text (markdown, movedBy)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-markup.js"]
     [("js_markup", "wiki_test_markup", Unsafe, [t|IO JSText|])]
 )

-- | Every element of the shell, but what is inside an island, which its
-- library fills after the shell has adopted it, inside the element
-- CodeMirror takes the editor's textarea's place in, and the assistant's
-- bubbles in the editor, which come with the settings this browser keeps
-- for the user, read once the program has started (a page rendered ahead
-- has none, and @jsbits/test-markup.js@ leaves them out of the one
-- 'prerendered' takes from a program here; the program adopting it may
-- have read them by the time its elements are counted).
adoptable :: Text
adoptable = "*:not(.wiki-math *, .wiki-mermaid *, .wiki-tikz *, .wiki-code *, .editor-cm *, .editor-providers *)"

-- | A container holding the shell's HTML at a route, as someone, as a page
-- rendered ahead of the program holds it.
prerendered
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Maybe Text
  -> Route
  -> PageM s (Element s)
prerendered m who at = do
  ui <- start m who at
  html <- fromJSText <$> unsafeIOToPageM js_markup
  unmount ui
  htmlContainer html

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "adopts a page with the shell around it, and follows a link from there" $ runPage $ do
    let tour = Page (slugs ["docs"]) (slugs ["tour"])
    page <- prerendered m Nothing tour
    shell <- findIn page ".wiki"
    before <- findAllIn page adoptable
    ui <- adopt m page Nothing tour
    after <- findAll ui adoptable
    length after `shouldBe` length before
    zipWithM_ shouldBeSameElement after before
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    -- Listeners on what was adopted: a link in the page's Markdown, then
    -- one of the shell's.
    find ui ".page-body a[href$='#/s/docs/p/markdown-guide/diagrams/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Diagrams")
    find ui ".wiki-sidebar .page-tree a[href$='#/s/docs/p/markdown-guide/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Markdown guide")
    find ui ".wiki" >>= (`shouldBeSameElement` shell)

  it "adopts the editor, its toolbar too, which then works" $ runPage $ do
    let editing = EditPage (slugs ["blog"]) (slugs ["hello-world"])
    page <- prerendered m (Just "user-editor") editing
    toolbar <- findIn page ".editor-toolbar"
    before <- findAllIn page adoptable
    ui <- adopt m page (Just "user-editor") editing
    after <- findAll ui adoptable
    length after `shouldBe` length before
    zipWithM_ shouldBeSameElement after before
    -- The toolbar is memoized: what the shell adopted is the thunk's, and
    -- its buttons answer.
    find ui ".editor-toolbar" >>= (`shouldBeSameElement` toolbar)
    -- CodeMirror takes the adopted textarea's place, with its Markdown, in
    -- the same box.
    markdown ui >>= (`shouldSatisfy` T.isPrefixOf "# Hello, world")
    movedBy ui `shouldReturn` ""
    find ui ".editor-show-preview" >>= click
    find ui ".editor-preview .page-body h1" >>= (`shouldHaveText` "Hello, world")
    find ui ".editor-toolbar" >>= (`shouldBeSameElement` toolbar)
