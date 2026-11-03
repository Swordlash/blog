{-# LANGUAGE TemplateHaskell #-}

-- | The session history's entries as the shell numbers them
-- ("Wiki.App.Browser"), in a browser: an entry the previous version wrote,
-- an object with the number as @wikiEntry@ and the preview's mark as
-- @wikiPreview@, which a tab open across the deployment still has, keeps
-- its number and its mark.
module Test.Browser.Entries (spec) where

import Halogen.JSBits.Fields (inlineJS)
import Protolude
import Test.Hspec.Halogen
import Wiki.App.Browser (forgetPreviewEntry, historyEntry, onPreviewEntry)

-- The entry as the version before WP5.47 pushed it for the editor's preview.
$(inlineJS "js_push_previous_entry" "history.pushState({ wikiEntry: $1, wikiPreview: true }, \"\")" [t|Int -> IO ()|])

spec :: Spec
spec = it "keeps the number and the preview's mark of an entry the previous version wrote" $ runPage $ do
  unsafeIOToPageM (js_push_previous_entry 7)
  unsafeIOToPageM historyEntry >>= (`shouldBe` 7)
  unsafeIOToPageM onPreviewEntry >>= (`shouldBe` True)
  unsafeIOToPageM forgetPreviewEntry
  unsafeIOToPageM onPreviewEntry >>= (`shouldBe` False)
  unsafeIOToPageM historyEntry >>= (`shouldBe` 7)
