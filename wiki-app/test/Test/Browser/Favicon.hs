{-# LANGUAGE TemplateHaskell #-}

-- | The favicon in a browser (WP5.45 of docs/PLAN.md), over the demo: a
-- space's pages show the space's icon on the tab, the home page the wiki's
-- logo; an administrator gives the wiki an icon among the home page's
-- settings, and the tab shows it away from the spaces. Nobody else is
-- offered the setting.
module Test.Browser.Favicon (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-favicon.js"]
     [ ("js_favicon", "wiki_test_favicon", Safe, [t|IO JSText|])
     ]
 )

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

-- | The favicon's address (a @data:@ URL decoded), a space, and its type.
favicon :: PageM s Text
favicon = unsafeIOToPageM (fromJSText <$> js_favicon)

spec :: forall m -> (Specs m) => Spec
spec m = describe "the favicon" $ do
  it "is a space's icon on its pages, and the wiki's logo on the home page" $ runPage $ do
    ui <- start m (Just "user-reader") (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    eventually (favicon >>= (`shouldSatisfy` \f -> "data:image/svg+xml," `T.isPrefixOf` f && "✍️" `T.isInfixOf` f))
    find ui ".wiki-brand" >>= click
    eventually (favicon `shouldReturn` "./icon.svg image/svg+xml")
    -- Only an administrator sets the wiki's icon.
    length <$> findAll ui ".home-icon" `shouldReturn` 0
    unmount ui

  it "is the wiki's icon away from the spaces, once an administrator sets it" $ runPage $ do
    ui <- start m (Just "user-admin") Home
    -- The icon is among the home page's options, in its editor.
    find ui ".edit-home" >>= click
    form <- find ui ".editor-home .home-icon"
    findIn form ".home-icon-kind-emoji input" >>= click
    find ui ".home-icon-emoji" >>= (`typeText` "🏠")
    find ui ".home-icon-save" >>= click
    eventually (find ui ".home-icon .settings-saved" >>= (`shouldHaveText` "Saved"))
    -- Saved at once: leaving the editor without saving keeps it.
    find ui ".editor-cancel" >>= click
    eventually (favicon >>= (`shouldSatisfy` \f -> "data:image/svg+xml," `T.isPrefixOf` f && "🏠" `T.isInfixOf` f))
    -- A space's own pages keep the space's.
    find ui ".space-card[data-space] .space-card-link" >>= click
    eventually (favicon >>= (`shouldSatisfy` (not . T.isInfixOf "🏠")))
    unmount ui
