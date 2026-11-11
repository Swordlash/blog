-- | The frame an html fence is shown in ("Wiki.Core.Markdown.Frame"): its
-- sandboxes, and the document it holds.
module Test.Markdown.Frame (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Frame

spec :: Spec
spec = describe "Markdown.Frame" $ do
  describe "the sandboxes" $ do
    it "never let a frame both run scripts and have the wiki's origin" $
      for_ sandboxes $ \sandbox ->
        (sandbox, all (`elem` T.words sandbox) ["allow-scripts", "allow-same-origin"]) `shouldBe` (sandbox, False)
    it "list both of the wiki's frames" $
      sandboxes `shouldMatchList` [frameSandbox, scriptSandbox]
    it "run no script in an html fence's frame, which keeps its origin and opens links in ordinary tabs" $
      T.words frameSandbox `shouldMatchList` ["allow-same-origin", "allow-popups", "allow-popups-to-escape-sandbox"]
    it "keep the frame that runs scripts off the wiki's origin" $
      T.words scriptSandbox `shouldNotContain` ["allow-same-origin"]
    it "allow no form, navigation of the page or download in either" $
      for_ sandboxes $ \sandbox ->
        T.words sandbox `shouldSatisfy` all (`notElem` ["allow-forms", "allow-top-navigation", "allow-top-navigation-by-user-activation", "allow-downloads", "allow-modals"])

  describe "the frame's document" $
    it "imports the wiki's stylesheet into a layer, then holds the block in the page's wrapper" $
      frameDocument "<p>x</p>"
        `shouldBe` "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>@import url(\"style.css\") layer(wiki);</style></head><body class=\"html-frame\"><div class=\"page-body\"><p>x</p></div></body></html>"
