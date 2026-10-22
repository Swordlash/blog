module Main (main) where

import Halogen.VDom.DOM.Monad (BrowserDOM, runBrowserDOM)
import Protolude

#if defined(wasm32_HOST_ARCH)
import Halogen.IO.Util qualified as HA
import Halogen.Router qualified as Router
import Halogen.VDom.Driver (hydrateUI)
import Web.DOM.ParentNode (QuerySelector (..))
import Wiki.App (Route (Unknown), component, input, route)
import Wiki.App.Backend.Mem (Opened (..), openMemWiki, runMemWikiWith)
import Wiki.App.Demo (demoDatabase, demoNow, demoState)
#endif

-- | Mount the application into the page's @#app@, over the in-memory wiki
-- with the demo's content, routed by the page's address under its
-- @\<base href>@. This is the one place that picks the component's monad:
-- 'Wiki.App.Backend.Mem.MemWiki' over the browser's DOM.
attachComponent :: BrowserDOM ()

#if defined(wasm32_HOST_ARCH)
attachComponent = do
  HA.awaitLoad
  app <- HA.selectElement (QuerySelector "#app") >>= maybe (panic "index.html has no #app to mount the wiki into") pure
  -- The page arrives with the route already rendered into #app (see
  -- Prerender.hs), so that it shows before this binary has loaded. The
  -- application adopts that HTML rather than render afresh in its place:
  -- its first render is the same page, from the same demo, unless the
  -- browser keeps edits to it, which the adoption then repairs.
  -- The demo as the browser keeps it, or, the first time, as it was at the
  -- time the prerendered pages show it, so that they agree on when each
  -- page was last changed.
  opened <- openMemWiki demoDatabase (demoState demoNow)
  base <- Router.pageBase
  router <- Router.newRouter base Unknown route
  void $ runMemWikiWith opened.store opened.wiki (hydrateUI component (input router) app)
#else
-- Natively there is no page to mount into: this executable builds so that it
-- type-checks with the rest, and the native program that renders the
-- application is wiki-app-prerender.
attachComponent = panic "wiki-app runs in a browser: build it with toolchain/build-wasm.sh"
#endif

main :: IO ()
main = runBrowserDOM attachComponent

#if defined(wasm32_HOST_ARCH)
foreign export javascript "hs_start" start :: IO ()

-- | What web/index.js calls once the module is instantiated.
start :: IO ()
start = main
#endif
