-- | The rules of "Wiki.Smoke.Adoption" that need no browser: which
-- attribute changes adoption may make, which pages a page embeds as
-- presentations, and which requests are a presentation viewer's. They are
-- the twins of @toolchain/smoke-adoption.mjs@'s, and these examples are
-- that module's cases.
module Main (main) where

import Halogen.Playwright.Hspec
import Wiki.Smoke.Adoption

main :: IO ()
main = hspec $ describe "Wiki.Smoke.Adoption" $ do
  describe "adoptionMayChange" $ do
    it "allows the scripts' attributes on any element" $
      adoptionMayChange False "data-stuck" Nothing (Just "true") `shouldBe` True
    it "allows a fitted frame a height where it had no style" $
      adoptionMayChange True "style" Nothing (Just "height: 412px;") `shouldBe` True
    it "refuses a style on an element that is no fitted frame" $
      adoptionMayChange False "style" Nothing (Just "height: 412px;") `shouldBe` False
    it "refuses a fitted frame a style it had, or more than a height" $ do
      adoptionMayChange True "style" (Just "height: 10px;") (Just "height: 412px;") `shouldBe` False
      adoptionMayChange True "style" Nothing (Just "height: 412px; width: 3px;") `shouldBe` False
      adoptionMayChange True "style" Nothing (Just "height: 41.5px;") `shouldBe` False
    it "refuses any other attribute of a fitted frame" $
      adoptionMayChange True "srcdoc" (Just "a") (Just "b") `shouldBe` False

  describe "presentationsEmbedded" $ do
    it "reads an embed from the space's top, without its last slash" $
      presentationsEmbedded "![Talk](/s/docs/p/guide/talk/){.presentation}" "guide" `shouldBe` ["guide/talk"]
    it "reads a relative embed from the page's parent" $
      presentationsEmbedded "![Talk](talk){.presentation}" "guide/intro" `shouldBe` ["guide/talk"]
    it "takes an embed once, and only with the class presentation" $
      presentationsEmbedded
        "![A](/s/docs/p/a/){.presentation}\n\n![A](/s/docs/p/a){#x .presentation}\n\n![B](/s/docs/p/b/){.wide}\n\n![C](/s/docs/p/c/)"
        "x"
        `shouldBe` ["a"]
    it "leaves out an embed shown as code in a fence" $
      presentationsEmbedded "```markdown\n![Talk](/s/docs/p/talk/){.presentation}\n```\n\n~~~\n![Other](other){.presentation}\n~~~" "x" `shouldBe` []
    it "keeps an embed after a fence that is never closed" $
      presentationsEmbedded "```\n![Talk](/s/docs/p/talk/){.presentation}" "x" `shouldBe` ["talk"]
    it "leaves out a page's permanent address and another site's" $
      presentationsEmbedded "![P](/l/abc?version=3){.presentation} ![Q](https://example.com/q){.presentation}" "x" `shouldBe` []

  describe "viewerAsks" $ do
    let embedded = ["guide/talk", "zażółć"]
    it "is a read of an embedded page at its path, under any base path" $ do
      viewerAsks "http://127.0.0.1:8080/api/v1/spaces/s1/pages/at/guide/talk" embedded `shouldBe` True
      viewerAsks "http://127.0.0.1:8080/wiki/api/v1/spaces/s1/pages/at/guide/talk/?x=1" embedded `shouldBe` True
    it "decodes the path" $
      viewerAsks "http://127.0.0.1:8080/api/v1/spaces/s1/pages/at/za%C5%BC%C3%B3%C5%82%C4%87" embedded `shouldBe` True
    it "is not a read of another page, or the space's pages" $ do
      viewerAsks "http://127.0.0.1:8080/api/v1/spaces/s1/pages/at/guide" embedded `shouldBe` False
      viewerAsks "http://127.0.0.1:8080/api/v1/spaces/s1/pages" embedded `shouldBe` False
