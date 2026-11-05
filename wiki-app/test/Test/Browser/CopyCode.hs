{-# LANGUAGE TemplateHaskell #-}

-- | The copy button of a code block in a page, in a browser (WP5.63 of
-- docs/PLAN.md), over the demo's wiki: a click puts the code on the
-- clipboard exactly as the fence holds it, the button says "Copied" for a
-- moment and "Copy" again after, a refusal says "Not copied", Enter on the
-- focused button copies as a click does, and a listing that scrolls keeps
-- the button in its corner. The button's label is the stylesheet's, so it
-- is no part of the page's text. The behaviour is the islands' script's
-- (web/src/islands.js), which the test page loads.
--
-- The test runner's page may not write to the clipboard, and its browser
-- context is the harness's, so a test cannot grant it: the tests put a
-- clipboard of their own in the browser's (test/jsbits/test-copy.js).
module Test.Browser.CopyCode (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (decodeStrict)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), insertPage)
import Wiki.App.Demo (demoNow)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Space qualified as Core

$( browserJS
     ["jsbits/test-copy.js"]
     [ ("js_stub_clipboard", "wiki_test_stub_clipboard", Safe, [t|Bool -> IO ()|])
     , ("js_unstub_clipboard", "wiki_test_unstub_clipboard", Safe, [t|IO ()|])
     , ("js_copied", "wiki_test_copied", Safe, [t|IO JSText|])
     , ("js_before_content", "wiki_test_before_content", Safe, [t|JSText -> IO JSText|])
     , ("js_scroll_to_end", "wiki_test_scroll_to_end", Safe, [t|JSText -> IO Int|])
     , ("js_corner", "wiki_test_corner", Safe, [t|JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = describe "a code block's copy button" $ do
  it "copies the code as written, says Copied for a moment and Copy again, and is no part of the page's text" $ runPage $ do
    stubClipboard False
    ui <- page m "Before.\n\n```haskell\nmain :: IO ()\nmain = print (1 < 2 && True)\n```\n\nAfter."
    -- Highlighted first, so that what is copied is read from
    -- highlight.js's markup.
    _ <- find ui ".page-body .code-block > pre.wiki-code > code.hljs span"
    button <- find ui ".page-body .code-block > button.code-copy"
    getAttribute button "type" `shouldReturn` Just "button"
    getAttribute button "aria-label" `shouldReturn` Just "Copy the code"
    label `shouldReturn` "\"Copy\""
    -- The label is drawn by the style sheet: the button has no text, and
    -- the page's text has the code and nothing of the button.
    textContent button `shouldReturn` ""
    find ui ".page-body" >>= textContent >>= (`shouldSatisfy` \text -> "Before.main :: IO ()\nmain = print (1 < 2 && True)\nAfter." `T.isInfixOf` text && not ("Copy" `T.isInfixOf` text))
    click button
    eventually $ copied `shouldReturn` ["main :: IO ()\nmain = print (1 < 2 && True)\n"]
    eventually $ label `shouldReturn` "\"Copied\""
    getAttribute button "aria-label" `shouldReturn` Just "Copied"
    -- About two seconds later, as it was.
    eventuallyWithin 6000 $ label `shouldReturn` "\"Copy\""
    getAttribute button "aria-label" `shouldReturn` Just "Copy the code"
    getAttribute button "data-copy" `shouldReturn` Nothing
    unstubClipboard

  it "copies a listing that scrolls whole, from the keyboard, with its button in its corner however far it is scrolled" $ runPage $ do
    stubClipboard False
    let code = T.unlines ["one = 1", "two = 2", "three = 3", "four = 4", "five = 5 -- " <> T.replicate 200 "x"]
    ui <- page m ("```haskell {rows=2}\n" <> code <> "```")
    _ <- find ui ".page-body .code-block > pre.wiki-code.code-scroll > code.hljs"
    button <- find ui ".page-body .code-block > button.code-copy"
    corner <- eventually $ do
      at <- cornerOf ".page-body .code-block > button.code-copy"
      at `shouldNotBe` ""
      pure at
    scrolled <- unsafeIOToPageM (js_scroll_to_end (toJSText (".page-body .code-block > pre" :: Text)))
    scrolled `shouldSatisfy` (> 0)
    cornerOf ".page-body .code-block > button.code-copy" `shouldReturn` corner
    focus button
    press "Enter"
    eventually $ copied `shouldReturn` [code]
    eventually $ label `shouldReturn` "\"Copied\""
    unstubClipboard

  it "says Not copied when the browser refuses, and Copy again after" $ runPage $ do
    stubClipboard True
    ui <- page m "```\nsecret\n```"
    _ <- find ui ".page-body .code-block > pre.wiki-code > code"
    find ui ".page-body .code-block > button.code-copy" >>= click
    eventually $ label `shouldReturn` "\"Not copied\""
    find ui ".page-body .code-block > button.code-copy" >>= (`getAttribute` "aria-label") >>= (`shouldBe` Just "Not copied")
    copied `shouldReturn` []
    eventuallyWithin 6000 $ label `shouldReturn` "\"Copy\""
    unstubClipboard

-- | The demo's Projects space with a page of this text, shown to an
-- administrator.
page
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => Text
  -> PageM s (Mounted s Shell.Query Void m)
page m body = startChanged m (withPage body) (Just "user-admin") (Page (slugs ["team", "projects"]) (slugs ["listing"]))

-- | The demo with a page called Listing, of this text, in its Projects
-- space.
withPage :: Text -> MemState -> MemState
withPage body st = case head (filter (\s -> s.name == "Projects") (Map.elems st.spaces)) of
  Just (s :: Core.Space) -> fst (insertPage s.id Nothing "Listing" body demoNow st)
  Nothing -> panic "the demo has no space Projects"

-- | A clipboard of the test's own in the browser's place, which keeps
-- what is written to it, or refuses it.
stubClipboard :: Bool -> PageM s ()
stubClipboard refuse = unsafeIOToPageM (js_stub_clipboard refuse)

unstubClipboard :: PageM s ()
unstubClipboard = unsafeIOToPageM js_unstub_clipboard

-- | What was written to the test's clipboard, in order.
copied :: PageM s [Text]
copied = unsafeIOToPageM (fromMaybe [] . decodeStrict . encodeUtf8 . fromJSText <$> js_copied)

-- | The label the style sheet draws on the page's first copy button.
label :: PageM s Text
label = unsafeIOToPageM (fromJSText <$> js_before_content (toJSText (".page-body .code-copy" :: Text)))

-- | Where an element is from its parent's top right corner.
cornerOf :: Text -> PageM s Text
cornerOf selector = unsafeIOToPageM (fromJSText <$> js_corner (toJSText selector))
