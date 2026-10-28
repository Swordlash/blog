-- | The page's Content Security Policy in the files the build serves
-- (WP5.21 of docs/PLAN.md, "Wiki.Api.ContentPolicy"): the offline page
-- (@web\/offline.html@), which the service worker shows on its own, carries
-- the same policy as @web\/index.html@, the policy's one source. The pages
-- the prerender writes from @web\/index.html@ keep its head; the smoke test
-- checks the built ones.
module Test.Policy (spec) where

import Data.ByteString qualified as BS
import Protolude
import Test.Hspec
import Wiki.Api.ContentPolicy (basePolicy)
import Wiki.Api.ContentPolicy.Embed (policyOfPage)

spec :: Spec
spec = describe "the pages' Content Security Policy" $ do
  it "is web/index.html's, and the offline page's too" $ do
    policyOfPage <$> readPage "../web/index.html" `shouldReturn` Just basePolicy
    policyOfPage <$> readPage "../web/offline.html" `shouldReturn` Just basePolicy
  where
    -- Read as bytes: the locale the tests run in may not be UTF-8.
    readPage path = decodeUtf8 <$> BS.readFile path
