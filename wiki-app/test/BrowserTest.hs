module Main (main) where

import Halogen.VDom.DOM.Monad (BrowserDOM)
import Protolude
import Test.Browser.Islands qualified as Islands
import Test.Hspec.Halogen (describe, runBrowserTests)
#if defined(wasm32_HOST_ARCH)
import Test.Browser.Editor qualified as Editor
import Test.Browser.Hydrate qualified as Hydrate
import Test.Browser.Search qualified as Search
import Test.Browser.Shell qualified as Shell
import Test.Browser.Source qualified as Source
#endif

-- | Built as a reactor exporting @hs_start@, which the browser test runner
-- calls once the page has loaded the islands' scripts and styles
-- (test/web/bundle.sh). Under browser GHCi it is run with @:main@ instead.
--
-- The specs name no monad; this is where the suite picks the one the
-- components run in.
--
-- Natively, where the suite only type-checks and reports a skip,
-- 'BrowserDOM' has no browser to keep local storage in (no
-- 'Halogen.VDom.DOM.Monad.Class.MonadBrowserDOM' instance), which the
-- shell's specs need for the editor's remembered layout; they are
-- type-checked in their own modules, polymorphic in the monad, and picked
-- here in a browser only.
main :: IO ()
main = runBrowserTests $ do
  describe "Wiki.App.Islands" (Islands.spec BrowserDOM)
#if defined(wasm32_HOST_ARCH)
  describe "Wiki.App.Shell" (Shell.spec BrowserDOM)
  describe "Wiki.App.View.Search" (Search.spec BrowserDOM)
  describe "Wiki.App.View.Editor" (Editor.spec BrowserDOM)
  describe "Wiki.App.View.Source" (Source.spec BrowserDOM)
  describe "Hydration" (Hydrate.spec BrowserDOM)
#endif

#if defined(wasm32_HOST_ARCH) && !defined(INTERACTIVE)
foreign export javascript "hs_start" main :: IO ()
#endif
