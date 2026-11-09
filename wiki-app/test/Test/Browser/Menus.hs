{-# LANGUAGE TemplateHaskell #-}

-- | The menus closing when the reader turns away from them
-- ("Wiki.App.View.Popup"), in a browser, over the demo: the header's
-- Starred list, the bell and the demo's menu of users, the sidebar's space
-- switcher, and the editor's toolbar menus. Each closes on a press outside
-- it and on Escape, and its own button closes it once, without opening it
-- again. A click inside a menu leaves it open.
module Test.Browser.Menus (spec) where

import Control.Monad.UUID (MonadUUID)
import Halogen.JSBits (Safety (..), browserJS)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Browser.Text (editorText)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-focus.js"]
     [("js_press_outside", "wiki_test_press_outside", Safe, [t|IO ()|])]
 )

-- | A menu as the tests find it: the button that opens it, and the menu
-- the button opens.
data Menu = Menu
  { toggle :: Text
  , popup :: Text
  }

starred, bell, users, switcher, box, html, colour :: Menu
starred = Menu {toggle = ".starred-toggle", popup = ".starred-panel"}
bell = Menu {toggle = ".notifications-toggle", popup = ".notifications-panel"}
users = Menu {toggle = ".user-switcher-toggle", popup = ".user-menu"}
switcher = Menu {toggle = ".space-switcher-toggle", popup = ".space-switcher-menu"}
box = Menu {toggle = ".editor-toolbar button[aria-label='Box']", popup = ".box-menu"}
html = Menu {toggle = ".editor-toolbar button[aria-label='HTML']", popup = ".toolbar-menu[aria-label='HTML']"}
colour = Menu {toggle = ".editor-toolbar button[aria-label='Colour']", popup = ".colour-menu"}

hello :: Route
hello = Page (slugs ["blog"]) (slugs ["hello-world"])

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "closes the Starred list on a press outside, on Escape and on its button, and not on a click inside" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    closesAway ui starred
    opened ui starred
    find ui ".starred-panel h2" >>= click
    stillOpen ui starred
    -- A real click on the page, outside the list.
    find ui ".page-body h1" >>= click
    shut ui starred

  it "closes the bell's list on a press outside, on Escape and on its button, and not on a click inside" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    closesAway ui bell
    opened ui bell
    find ui ".notifications-panel h2" >>= click
    stillOpen ui bell
    -- Opening the Starred list is a press outside the bell's: one list
    -- is open at a time.
    opened ui starred
    shut ui bell

  it "closes the demo's menu of users on a press outside, on Escape and on its button" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    closesAway ui users

  it "closes the space switcher on a press outside, on Escape and on its button" $ runPage $ do
    ui <- start m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["tour"]))
    closesAway ui switcher
    opened ui switcher
    find ui ".page-body h1" >>= click
    shut ui switcher

  it "closes the editor's toolbar menus on a press outside, on Escape and on their buttons, and on a click in the text" $ runPage $ do
    ui <- start m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    traverse_ (closesAway ui) [box, html, colour]
    -- A click inside the palette, on a row's name, leaves it open; another
    -- menu's button closes it and opens that menu.
    opened ui colour
    find ui ".colour-menu .colour-row-name" >>= click
    stillOpen ui colour
    opened ui html
    shut ui colour
    -- A click in the text is a press outside.
    editorText ui >>= click
    shut ui html

-- | Open the menu, and close it with a press outside it, with Escape, and
-- with its own button.
closesAway :: Mounted s q o n -> Menu -> PageM s ()
closesAway ui menu = do
  opened ui menu
  -- A press on the page around the menu, which moves no focus.
  unsafeIOToPageM js_press_outside
  shut ui menu
  opened ui menu
  press "Escape"
  shut ui menu
  -- The button's own press is inside: its click closes the menu, which a
  -- press outside would have closed first and the click opened again.
  opened ui menu
  find ui menu.toggle >>= click
  shut ui menu

-- | Click the menu's button, and see the menu open.
opened :: Mounted s q o n -> Menu -> PageM s ()
opened ui menu = do
  find ui menu.toggle >>= click
  stillOpen ui menu

-- | The menu is open, and its button says so.
stillOpen :: Mounted s q o n -> Menu -> PageM s ()
stillOpen ui menu = do
  _ <- find ui menu.popup
  find ui menu.toggle >>= \b -> getAttribute b "aria-expanded" `shouldReturn` Just "true"

-- | The menu closes, and its button says so.
shut :: Mounted s q o n -> Menu -> PageM s ()
shut ui menu = do
  eventually $ length <$> findAll ui menu.popup `shouldReturn` 0
  find ui menu.toggle >>= \b -> getAttribute b "aria-expanded" `shouldReturn` Just "false"
