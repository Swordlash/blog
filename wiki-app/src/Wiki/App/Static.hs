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
-- A wiki a server keeps is rendered by the server, for each request, as
-- the request's principal sees it ('renderServed'): the application over
-- the backend over HTTP, whose requests the server's API answers in the
-- same process, so that it reads exactly what the program would and the
-- page carries what it read ("Wiki.App.Backend.Http.Preload"). The build
-- prerenders one page for it besides, as the application shows before it
-- has loaded anything ('renderLoading'): the frame, the same at every
-- address, which the server sends when it cannot render a page. Its
-- requests are never answered, so it is taken as soon as it stops
-- changing.
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
  , Served (..)
  , renderServed
  , startServed

    -- * Pages
  , withBase
  , withTitle
  , escapeHtml
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Core (ElemName (..))
import Halogen.IO.Driver (HalogenSocket (..))
import Halogen.IO.Driver qualified as AD
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad (MemDOM, MonadBrowserDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (hydrateUI, renderSpec)
import Protolude
import Wiki.App (component, input, serverInput)
import Wiki.App.Backend (MonadLoad)
import Wiki.App.Backend.Http (HttpEnv, Transport, cacheOf, newHttpEnv, newImmediateHttpEnv, runHttpWiki, silentTransport)
import Wiki.App.Backend.Http.Cache (Cache)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Against (..), Route (..), route)
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
  html <- markup container `finally` dispose
  pure Rendered {html, title}

-- | The routes the build writes a page for: the front page, the page of
-- search results, every space, and every page of the wiki with its source
-- and its history (at its latest version: another version's address is the
-- history's with a query, which a static host serves the same page for, and
-- the program then shows the version asked for).
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
         , r <- [Page sp pp, PageSource sp pp, PageHistory sp pp Nothing AgainstPrevious]
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
  first (fromMaybe "Wiki") <$> startApp True slowly how run input base at container

-- | The application for a wiki a server keeps, under this base path, as it
-- shows before anything has been loaded: what the server's build serves at
-- every address.
renderLoading :: Text -> IO Rendered
renderLoading base = do
  container <- N.newElement Nothing (ElemName "div")
  dispose <- startLoading Build base Home container
  html <- markup container `finally` dispose
  pure Rendered {html, title = "Wiki"}

-- | Start the application for a wiki a server keeps at a route in a
-- container, under this base path, over a server that never answers, and
-- wait until its HTML has stopped changing; then how to dispose of it.
startLoading :: Start -> Text -> Route -> N.NativeNode -> IO (IO ())
startLoading how base at container = do
  env <- newHttpEnv silentTransport
  snd <$> startApp False slowly how (runMemDOM . runHttpWiki env) serverInput base at container

-- | A route's page as a server renders it: the application's HTML, the
-- document's title, and what the application read, which the page
-- carries for the program ("Wiki.App.Backend.Http.Preload").
data Served = Served
  { html :: Text
  , title :: Text
  , cache :: Cache
  }

-- | The application for a wiki a server keeps, at a route, under this
-- base path, over a transport that answers at once (the server's API in
-- its own process, as the request's principal): every view loads what it
-- shows in its initial state, as over the in-memory backend, which is how
-- the program renders it first from what the page carries. Whatever the
-- transport answers is rendered, a failure to reach the server included:
-- whether to send the page is the caller's to decide, by what the
-- transport answered.
renderServed :: Transport -> Text -> Route -> IO Served
renderServed transport base at = do
  env <- newImmediateHttpEnv transport
  container <- N.newElement Nothing (ElemName "div")
  (title, dispose) <- startServed Build env base at container
  html <- markup container `finally` dispose
  cache <- cacheOf env
  pure Served {html, title, cache}

-- | Start the application for a wiki a server keeps at a route in a
-- container, over this backend, under this base path, and wait until it
-- has loaded what the route shows (from what the backend has read, or by
-- asking a transport that answers at once) and its HTML has stopped
-- changing. The document's title then, and how to dispose of it.
startServed :: Start -> HttpEnv -> Text -> Route -> N.NativeNode -> IO (Text, IO ())
startServed how env base at container =
  first (fromMaybe "Wiki") <$> startApp True briskly how (runMemDOM . runHttpWiki env) serverInput base at container

-- | Start the application in a container, over a backend run as given, with
-- the shell's input for its router, at a route under a base path; wait,
-- if asked, until the shell has loaded what the route shows, and then
-- until its HTML has stopped changing, looking again every so many
-- microseconds. The document's title, if waited for, and how to dispose of
-- the application.
startApp
  :: forall m
   . (MonadLoad m, MonadIslands m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m)
  => Bool
  -> Int
  -> Start
  -> (forall a. m a -> IO a)
  -> (Router Route -> Shell.Input m)
  -> Text
  -> Route
  -> N.NativeNode
  -> IO (Maybe Text, IO ())
startApp waitForShell pace how run inputFor base at container = do
  router <- run (Router.newRouter base Unknown route)
  Router.redirect router at
  document <- N.newDocument
  HalogenSocket {query = send, dispose} <- run $ case how of
    Build -> AD.runUI (renderSpec (N.fromNative document) (N.fromNative container)) (component @Void) (inputFor router)
    Adopt -> hydrateUI (component @Void) (inputFor router) (N.fromNative container)
  flip onException (run dispose) $ do
    title <-
      if waitForShell
        then Just <$> settled pace (run (join <$> send (H.mkRequest Shell.Settled)))
        else pure Nothing
    void (stable pace (markup container))
    pure (title, run dispose)

-- | What a container holds, as HTML.
markup :: N.NativeNode -> IO Text
markup container = mconcat <$> (traverse N.renderToText =<< N.childNodes container)

-- | A page with a @\<base href>@ first in its head, before anything it
-- applies to: the template's, which has none.
withBase :: Text -> Text -> Text
withBase base = T.replace "<head>" ("<head>\n    <base href=\"" <> escapeHtml base <> "\">")

-- | A page titled for its route: the template's title, @Wiki@, replaced.
withTitle :: Text -> Text -> Text
withTitle title = T.replace "<title>Wiki</title>" ("<title>" <> escapeHtml title <> "</title>")

-- | Text as it is written in HTML, in an element or an attribute's value.
escapeHtml :: Text -> Text
escapeHtml = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  c -> T.singleton c

-- | How often the prerender looks, in microseconds: it writes its pages
-- once, so it can afford to look slowly.
slowly :: Int
slowly = 10_000

-- | How often a server's render looks: a reader is waiting for the page,
-- and over a transport that answers at once everything is there by the
-- first look, so this is about the time the render waits in vain.
briskly :: Int
briskly = 1_000

-- | Ask until the answer is there, every so many microseconds; ten seconds
-- is far longer than a render takes, and longer means something is wrong.
settled :: Int -> IO (Maybe Text) -> IO Text
settled pace asking = go (10_000_000 `div` pace)
  where
    go 0 = panic "Wiki.App.Static: the shell did not finish loading"
    go n = asking >>= maybe (threadDelay pace >> go (n - 1)) pure

-- | The HTML once two looks at it, so many microseconds apart, find it the
-- same.
stable :: Int -> IO Text -> IO Text
stable pace snapshot = snapshot >>= go (2_000_000 `div` pace)
  where
    go 0 html = pure html
    go n html = do
      threadDelay pace
      again <- snapshot
      if again == html then pure html else go (n - 1) again
