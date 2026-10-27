module Main (main) where

import Halogen.VDom.DOM.Monad (BrowserDOM, runBrowserDOM)
import Protolude

#if defined(wasm32_HOST_ARCH)
import Halogen.IO.Util qualified as HA
import Halogen.Router qualified as Router
import Halogen.VDom.Driver (hydrateUI)
import Web.DOM.ParentNode (QuerySelector (..))
import Wiki.App (Route (Unknown), component, input, route, serverInput)
import Wiki.App.Backend.Http (browserTransport, newHttpEnvWith, runHttpWiki)
import Wiki.App.Backend.Http.Cache (emptyCache)
import Wiki.App.Backend.Http.Preload (embeddedCache)
import Wiki.App.Backend.Mem (Opened (..), openMemWiki, runMemWikiWith)
import Wiki.App.Browser (PageBackend (..), consoleWarn, pageBackend)
import Wiki.App.Demo (demoDatabase, demoNow, demoState)
#endif

-- | Mount the application into the page's @#app@ element, routed by the
-- page's address under its @\<base href>@, over the backend the page names
-- ('pageBackend'): the in-memory one with the demo's content, or the HTTP
-- one that talks to the server. This is the one place that picks the
-- component's monad: 'Wiki.App.Backend.Mem.MemWiki' or
-- 'Wiki.App.Backend.Http.HttpWiki' over the browser's DOM. The binary is
-- the same for both, so the demo and the server's build differ only in
-- their pages.
attachComponent :: BrowserDOM ()

#if defined(wasm32_HOST_ARCH)
attachComponent = do
  HA.awaitLoad
  app <- HA.selectElement (QuerySelector "#app") >>= maybe (panic "index.html has no #app to mount the wiki into") pure
  base <- Router.pageBase
  router <- Router.newRouter base Unknown route
  pageBackend >>= \case
    DemoBackend -> demo router app
    -- The server prerendered the route's page from the responses it read,
    -- which the page carries. The backend starts with them, so that the
    -- application's first render matches that page, which it adopts, with
    -- nothing fetched again. A page that carries nothing (the build's own
    -- page, which the server sends when it cannot prerender one) holds the
    -- application as it looks before it has loaded anything; the
    -- application adopts it all the same, and then loads the route's data.
    ServerBackend -> do
      carried <-
        embeddedCache >>= \case
          Right cache -> pure cache
          Left why -> consoleWarn why $> emptyCache
      env <- newHttpEnvWith browserTransport carried
      void $ runHttpWiki env (hydrateUI component (serverInput router) app)
  where
    -- The page arrives with the route already rendered into #app (see
    -- Prerender.hs), so that it shows before this binary has loaded. The
    -- application adopts that HTML instead of rendering afresh in its
    -- place: its first render is the same page, from the same demo content,
    -- unless the browser has saved edits to it, which the adoption then
    -- repairs. The demo content is the one the browser saved, or, the first
    -- time, the content as of the time the prerendered pages show, so that
    -- they agree on when each page was last changed.
    demo router app = do
      opened <- openMemWiki demoDatabase (demoState demoNow)
      void $ runMemWikiWith opened.store opened.wiki (hydrateUI component (input router) app)
#else
-- Natively there is no page to mount into: this executable builds only so
-- that it type-checks with the rest, and the native program that renders
-- the application is wiki-app-prerender.
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
