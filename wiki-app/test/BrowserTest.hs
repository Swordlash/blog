module Main (main) where

import Halogen.VDom.DOM.Monad (BrowserDOM)
import Protolude
import Test.Browser.Islands qualified as Islands
import Test.Browser.Search qualified as Search
import Test.Browser.Shell qualified as Shell
import Test.Hspec.Halogen (describe, runBrowserTests)

-- | Built as a reactor exporting @hs_start@, which the browser test runner
-- calls once the page has loaded the islands' scripts and styles
-- (test/web/bundle.sh). Under browser GHCi it is run with @:main@ instead.
--
-- The specs name no monad; this is where the suite picks the one the
-- components run in.
main :: IO ()
main = runBrowserTests $ do
  describe "Wiki.App.Islands" (Islands.spec BrowserDOM)
  describe "Wiki.App.Shell" (Shell.spec BrowserDOM)
  describe "Wiki.App.View.Search" (Search.spec BrowserDOM)

#if defined(wasm32_HOST_ARCH) && !defined(INTERACTIVE)
foreign export javascript "hs_start" main :: IO ()
#endif
