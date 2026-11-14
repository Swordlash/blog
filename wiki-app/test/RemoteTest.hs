-- | The bell tested over haskell-halogen-remote (WP5.118's spike,
-- "Test.Remote.Bell"): mounted in this process, its DOM in headless
-- Chromium.
--
-- Without @WIKI_REMOTE_REQUIRED=1@ the examples are pending, so that a
-- plain @cabal test@ on a machine without Chromium passes, as wiki-smoke's
-- suites do without their build.
module Main (main) where

import Halogen.Playwright.Hspec (describe, hspec, it, pendingWith, playwright)
import Halogen.Remote.Test (withTestServer)
import Prelude
import System.Environment (lookupEnv)
import Test.Remote.Bell qualified as Bell

main :: IO ()
main = do
  required <- (== Just "1") <$> lookupEnv "WIKI_REMOTE_REQUIRED"
  if required
    then withTestServer $ \server ->
      hspec $ playwright $ describe "Wiki.App.View.Bell, over a wire in Chromium" (Bell.spec server)
    else hspec $ it "runs with WIKI_REMOTE_REQUIRED=1" (pendingWith "no browser asked for")
