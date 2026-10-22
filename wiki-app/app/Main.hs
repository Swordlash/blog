module Main (main) where

import Halogen.VDom.DOM.Monad (BrowserDOM, runBrowserDOM)
import Protolude

#if defined(wasm32_HOST_ARCH)
import Halogen.IO.Util qualified as HA
import Halogen.VDom.DOM.Monad (setTextContent)
import Halogen.VDom.Driver (runUI)
import Web.DOM.Internal.Types (toNode)
import Web.DOM.ParentNode (QuerySelector (..))
import Wiki.App (component)
#endif

-- | Mount the application into the page's @#app@. The component monad is the
-- browser backend itself; an application with effects of its own stacks them
-- on it and derives the DOM classes through.
attachComponent :: BrowserDOM ()

#if defined(wasm32_HOST_ARCH)
attachComponent = do
  HA.awaitLoad
  app <- HA.selectElement (QuerySelector "#app") >>= maybe (panic "index.html has no #app to mount the wiki into") pure
  -- The page arrives with the component already rendered into #app (see
  -- Prerender.hs), so that it shows before this binary has loaded. That HTML
  -- is replaced rather than adopted: the component renders afresh in its
  -- place.
  setTextContent "" (toNode app)
  void $ runUI component () app
#else
-- Natively there is no page to mount into: this executable builds so that it
-- type-checks with the rest, and the native program that renders the
-- component is wiki-app-prerender.
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
