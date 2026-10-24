-- | The application rendered natively, for a route, as the page should
-- arrive before the program has loaded: what @wiki-app-prerender@ writes for
-- every route, and what the native tests look at.
--
-- "Halogen.Static" takes the HTML as soon as the component has started,
-- which is before anything it loads through the backend on a worker has
-- arrived. The shell and its views load what a route shows in their initial
-- states, so that is there from the first render, but a view still says when
-- it is done ('Shell.Settled'), and the islands write their source in from
-- their initializers. So this asks the shell whether it has loaded what the
-- route shows, and then waits for the HTML to stop changing.
--
-- A wiki a server keeps is prerendered once, as the application shows
-- before it has loaded anything ('renderLoading'): the frame, the same at
-- every address, which the server serves for every route until it renders
-- each page itself. Its requests are never answered, so it is taken as
-- soon as it stops changing.
--
-- The program adopts this HTML in the browser
-- ('Halogen.VDom.Driver.hydrateUI'), so its first render has to be the same
-- page; 'startRoute' can start the application either way, which is how the
-- native tests check that it is.
--
-- Natively only: the in-memory document exists on a host GHC only.
module Wiki.App.Static
  ( renderRoute
  , Rendered (..)
  , prerenderedRoutes
  , Start (..)
  , startRoute
  , renderLoading
  , startLoading
  )
where

import Data.Map.Strict qualified as Map
import Halogen qualified as H
import Halogen.HTML.Core (ElemName (..))
import Halogen.IO.Driver (HalogenSocket (..))
import Halogen.IO.Driver qualified as AD
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (hydrateUI, renderSpec)
import Protolude
import Wiki.App (component, input, serverInput)
import Wiki.App.Backend.Http (HttpWiki, newHttpEnv, runHttpWiki, silentTransport)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Route (Route (..), route)
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page (Page (id, space))
import Wiki.Core.Path (pathOf)
import Wiki.Core.Space (Space (id))

-- | A route's page: the application's HTML, for the mount point, and the
-- document's title.
data Rendered = Rendered
  { html :: Text
  , title :: Text
  }

-- | The application at a route, over a wiki in this state, under this base
-- path (@\/@, or the path a site is served from). Nobody is signed in unless
-- the state says otherwise.
renderRoute :: MemState -> Text -> Route -> IO Rendered
renderRoute wiki base at = do
  container <- N.newElement Nothing (ElemName "div")
  (title, dispose) <- startRoute Build wiki base at container
  html <- (mconcat <$> (traverse N.renderToText =<< N.childNodes container)) `finally` dispose
  pure Rendered {html, title}

-- | The routes the build writes a page for: the front page, the page of
-- search results, every space, and every page of the wiki with its source.
-- (Every other address gets the page for 'Unknown'.)
prerenderedRoutes :: MemState -> [Route]
prerenderedRoutes st =
  Home
    : Search Nothing Nothing True
    : [Space path | s <- Map.elems st.spaces, Just path <- [spacePath s.id]]
      <> [ r
         | p <- Map.elems st.pages
         , Just sp <- [spacePath p.space]
         , Just pp <- [pathOf (`Map.lookup` st.pages) p.id]
         , r <- [Page sp pp, PageSource sp pp]
         ]
  where
    spacePath = pathOf (`Map.lookup` st.spaces)

-- | How the application starts in its container: building its HTML there,
-- as the prerender does, or adopting the HTML already there, as the
-- program does in the browser.
data Start = Build | Adopt

-- | Start the application at a route in a container, over a wiki in this
-- state, under this base path, and wait until it has loaded what the route
-- shows and its HTML has stopped changing. The document's title then, and
-- how to dispose of the application, which takes its HTML out of the
-- container again.
startRoute :: Start -> MemState -> Text -> Route -> N.NativeNode -> IO (Text, IO ())
startRoute how wiki base at container = do
  ref <- newMemWiki wiki
  let run :: MemWiki MemDOM a -> IO a
      run = runMemDOM . runMemWiki ref
  router <- run (Router.newRouter base Unknown route)
  Router.redirect router at
  document <- N.newDocument
  HalogenSocket {query = send, dispose} <- run $ case how of
    Build -> AD.runUI (renderSpec (N.fromNative document) (N.fromNative container)) (component @Void) (input router)
    Adopt -> hydrateUI (component @Void) (input router) (N.fromNative container)
  let snapshot = mconcat <$> (traverse N.renderToText =<< N.childNodes container)
  flip onException (run dispose) $ do
    title <- settled (run (join <$> send (H.mkRequest Shell.Settled)))
    void (stable snapshot)
    pure (title, run dispose)

-- | The application for a wiki a server keeps, under this base path, as it
-- shows before anything has been loaded: what the server's build serves at
-- every address.
renderLoading :: Text -> IO Rendered
renderLoading base = do
  container <- N.newElement Nothing (ElemName "div")
  dispose <- startLoading Build base Home container
  html <- (mconcat <$> (traverse N.renderToText =<< N.childNodes container)) `finally` dispose
  pure Rendered {html, title = "Wiki"}

-- | Start the application for a wiki a server keeps at a route in a
-- container, under this base path, over a server that never answers, and
-- wait until its HTML has stopped changing; then how to dispose of it.
startLoading :: Start -> Text -> Route -> N.NativeNode -> IO (IO ())
startLoading how base at container = do
  env <- newHttpEnv silentTransport
  let run :: HttpWiki MemDOM a -> IO a
      run = runMemDOM . runHttpWiki env
  router <- run (Router.newRouter base Unknown route)
  Router.redirect router at
  document <- N.newDocument
  HalogenSocket {dispose} <- run $ case how of
    Build -> AD.runUI (renderSpec (N.fromNative document) (N.fromNative container)) (component @Void) (serverInput router)
    Adopt -> hydrateUI (component @Void) (serverInput router) (N.fromNative container)
  let snapshot = mconcat <$> (traverse N.renderToText =<< N.childNodes container)
  flip onException (run dispose) $ do
    void (stable snapshot)
    pure (run dispose)

-- | Ask until the answer is there; ten seconds is far longer than an
-- in-memory wiki takes, and longer means something is wrong.
settled :: IO (Maybe Text) -> IO Text
settled asking = go (2000 :: Int)
  where
    go 0 = panic "Wiki.App.Static: the shell did not finish loading"
    go n = asking >>= maybe (threadDelay 5000 >> go (n - 1)) pure

-- | The HTML once two looks at it, a few milliseconds apart, find it the
-- same.
stable :: IO Text -> IO Text
stable snapshot = snapshot >>= go (200 :: Int)
  where
    go 0 html = pure html
    go n html = do
      threadDelay 10000
      again <- snapshot
      if again == html then pure html else go (n - 1) again
