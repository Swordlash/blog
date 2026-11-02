{-# LANGUAGE TemplateHaskell #-}

-- | The administration's "Editor" section in a browser (WP5.41 of
-- docs/PLAN.md, "Wiki.App.View.EditorSettings"), over the demo's wiki: the
-- kinds of box, defined, changed and removed, with a custom colour, and a
-- page drawing them; the built-in math macros, copied from the shipped ones
-- the first time the section is opened, checked by KaTeX as they are
-- typed, setting every page's formulas once saved, and naming the pages
-- that use a macro being taken out.
module Test.Browser.EditorSettings (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Route qualified as R

-- How the page's style sheet draws an element (test/jsbits/test-style.js).
$( browserJS
     ["jsbits/test-style.js"]
     [ ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

-- | Choose the option at this index of a menu, from the keyboard.
choose :: Mounted s q o m -> Text -> Int -> PageM s ()
choose ui selector n = do
  menu <- find ui selector
  focus menu
  press "Home"
  replicateM_ n (press "ArrowDown")

-- | A property of the first element a selector finds, as the style sheet
-- computes it.
computed :: Text -> Text -> PageM s Text
computed selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = describe "over the demo's wiki" $ do
  it "defines kinds of box, each shown as a page shows it, and refuses one of GitHub's five" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin R.EditorSettings)
    -- The demo's own kind.
    find ui ".server-box[data-name=exercise] .alert-title" >>= (`shouldHaveText` "Exercise")
    find ui ".server-box[data-name=exercise] .server-box-written" >>= (`shouldContainText` "teal, pencil icon")
    find ui ".server-box-add" >>= click
    find ui ".server-box-form input[name=kind]" >>= (`typeText` "note")
    find ui ".server-box-form button[type=submit]" >>= click
    find ui ".admin-editor .error" >>= (`shouldContainText` "one of GitHub's five")
    find ui ".server-box-form input[name=kind]" >>= clear
    find ui ".server-box-form input[name=kind]" >>= (`typeText` "fun-fact")
    find ui ".server-box-form input[name=label]" >>= (`typeText` "Did you know?")
    -- Pink, and the info icon, from the keyboard.
    choose ui ".server-box-form select[name=colour]" 7
    choose ui ".server-box-form select[name=icon]" 1
    find ui ".server-box-form .server-box-preview .alert-title" >>= (`shouldHaveText` "Did you know?")
    find ui ".server-box-form button[type=submit]" >>= click
    eventually (find ui ".server-box[data-name=fun-fact] .alert-title" >>= (`shouldHaveText` "Did you know?"))
    find ui ".server-box[data-name=fun-fact] .server-box-written" >>= (`shouldContainText` "pink, info icon")
    -- Changed: the name stays, the rest is the form's.
    find ui ".server-box[data-name=fun-fact] .server-box-edit" >>= click
    find ui ".server-box-form input[name=label]" >>= clear
    find ui ".server-box-form button[type=submit]" >>= click
    eventually (find ui ".server-box[data-name=fun-fact] .alert-title" >>= (`shouldHaveText` "Fun fact"))
    find ui ".server-box[data-name=fun-fact] .server-box-remove" >>= click
    eventually (length <$> findAll ui ".server-box[data-name=fun-fact]" `shouldReturn` 0)
    unmount ui

  it "gives a kind of box a custom colour from a colour picker" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin R.EditorSettings)
    find ui ".server-box[data-name=exercise] .server-box-edit" >>= click
    length <$> findAll ui ".server-box-form input[type=color]" `shouldReturn` 0
    -- After the theme's nine, "custom…".
    choose ui ".server-box-form select[name=colour]" 9
    picker <- find ui ".server-box-form input[type=color]"
    getProperty picker "value" `shouldReturn` "#0a6d69"
    preview <- find ui ".server-box-form .server-box-preview .alert"
    getAttribute preview "style" >>= (`shouldSatisfy` maybe False (T.isInfixOf "--box-colour: #0a6d69"))
    find ui ".server-box-form button[type=submit]" >>= click
    eventually (find ui ".server-box[data-name=exercise] .server-box-written" >>= (`shouldContainText` "#0a6d69, pencil icon"))
    unmount ui

  it "draws a page's box of a defined kind in its colour with its icon, and one of another kind plain" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    box <- find ui ".page-body .alert.alert-exercise"
    getAttribute box "style" >>= (`shouldSatisfy` maybe False (T.isInfixOf "--box-colour: var(--c-teal)"))
    find ui ".page-body .alert-exercise .alert-title" >>= (`shouldHaveText` "Exercise 1")
    -- Teal, the editor's palette's, in the light scheme.
    computed ".page-body .alert.alert-exercise" "border-left-color" `shouldReturn` "rgb(10, 109, 105)"
    computed ".page-body .alert-exercise .alert-title" "color" `shouldReturn` "rgb(10, 109, 105)"
    computed ".page-body .alert-exercise .alert-icon" "mask-image" >>= (`shouldSatisfy` T.isInfixOf "data:image/svg+xml")
    -- The boxes of the kind are numbered, and the second gives its own
    -- title, with math in it.
    titles <- traverse textContent =<< findAll ui ".page-body .alert-exercise .alert-title"
    take 1 titles `shouldBe` ["Exercise 1"]
    map (T.isPrefixOf "Exercise 2: The area of a circle") (drop 1 titles) `shouldBe` [True]
    length <$> findAll ui ".page-body .alert-exercise .alert-title .wiki-math-inline" `shouldReturn` 1
    -- GitHub's five keep their look.
    computed ".page-body .alert.alert-tip" "border-left-color" `shouldReturn` "rgb(26, 127, 55)"
    unmount ui
  it "copies the shipped macros the first time, and sets every page's formulas with the block once saved" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin R.EditorSettings)
    source <- find ui ".editor-macros-form .macros-source"
    -- Copied from the shipped ones, and saved at once.
    eventually (getProperty source "value" >>= (`shouldSatisfy` T.isInfixOf "\\newcommand{\\Prob}"))
    eventually (find ui ".editor-macros-form .settings-saved" >>= (`shouldHaveText` "Saved"))
    -- KaTeX's error for a block it cannot read, which is not saved.
    clear source
    typeText source "\\newcommand{\\half}{\\frac{1}"
    _ <- find ui ".editor-macros-form .macros-error"
    find ui ".editor-macros-form button[type=submit]" >>= \b -> getProperty b "disabled" `shouldReturn` "true"
    -- A block of the shipped ones and one more, tried on a formula.
    find ui ".editor-macros-shipped" >>= click
    typeText source "\n\\newcommand{\\half}{\\frac{1}{2}}"
    length <$> findAll ui ".editor-macros-form .macros-error" `shouldReturn` 0
    find ui ".editor-macros-form .macros-sample-input" >>= (`typeText` "\\half")
    eventually (find ui ".editor-macros-form .macros-preview .katex" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "1"))
    find ui ".editor-macros-form button[type=submit]" >>= click
    eventually (find ui ".editor-macros-form .settings-saved" >>= (`shouldHaveText` "Saved"))
    unmount ui
    -- A page now has it.
    page <- start m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide", "mathematics"]))
    _ <- find page ".page-body .wiki-math-inline .katex"
    unmount page

  it "names the pages that use a macro being taken out, and saves only when asked" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin R.EditorSettings)
    source <- find ui ".editor-macros-form .macros-source"
    eventually (find ui ".editor-macros-form .settings-saved" >>= (`shouldHaveText` "Saved"))
    -- The guide's Mathematics page uses \\abs, which a block of one other
    -- macro takes out.
    clear source
    typeText source "\\newcommand{\\Prob}{\\mathbb{P}}"
    find ui ".editor-macros-form button[type=submit]" >>= click
    removal <- find ui ".editor-macros-removal"
    removal `shouldContainText` "\\abs"
    find ui ".editor-macros-pages" >>= (`shouldContainText` "Mathematics")
    find ui ".editor-macros-form .settings-saved" >>= (`shouldHaveText` "")
    find ui ".editor-macros-anyway" >>= click
    eventually (find ui ".editor-macros-form .settings-saved" >>= (`shouldHaveText` "Saved"))
    length <$> findAll ui ".editor-macros-removal" `shouldReturn` 0
    unmount ui
