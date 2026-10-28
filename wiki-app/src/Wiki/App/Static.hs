-- | Native rendering of the application to HTML: the prerender. For a
-- route, it renders the page as it should arrive before the program has
-- loaded. @wiki-app-prerender@ writes one for every route, and the native
-- tests check them.
--
-- "Halogen.Static" takes the HTML as soon as the component has started,
-- which is before anything the component loads through the backend on a
-- worker thread has arrived. The shell and its views load what a route
-- shows in their initial states, so it is there from the first render.
-- But a view still reports when it is done ('Shell.Settled'), and the
-- islands write their source in from their initializers. So this asks the
-- shell whether it has loaded what the route shows, and then waits for the
-- HTML to stop changing.
--
-- A wiki on a server is prerendered by the server, for each request, as
-- the user who sent it sees it ('renderServed'). That is the application
-- over the HTTP backend, whose requests the server's API answers in the
-- same process, so that it reads exactly what the program would, and the
-- page carries the responses ("Wiki.App.Backend.Http.Preload"). The build
-- also prerenders one page for the server: the application before it has
-- loaded anything ('renderLoading'), the bare frame, the same at every
-- address. The server sends it when it cannot prerender a page. Its
-- requests never get a response, so it is taken as soon as it stops
-- changing.
--
-- The program adopts this HTML in the browser
-- ('Halogen.VDom.Driver.hydrateUI'), so its first render must produce the
-- same page. 'startRoute' can start the application either way, which is
-- how the native tests check that it does.
--
-- Native only: the in-memory document exists only on the host GHC.
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
  , withHead
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
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad)
import Wiki.App.Backend.Admin (MonadAdmin)
import Wiki.App.Backend.Comments (MonadComments)
import Wiki.App.Backend.Http (HttpEnv, Transport, cacheOf, newHttpEnv, newImmediateHttpEnv, runHttpWiki, silentTransport)
import Wiki.App.Backend.Http.Cache (Cache)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Head (Head (..), Site, escapeHtml, headTags, untitled)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Against (..), Route (..), route)
import Wiki.App.Security (MonadSecurity)
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Markdown (parseMarkdown)
import Wiki.Core.Page (Page (body, id, space))
import Wiki.Core.Path (pathOf)
import Wiki.Core.Slides (isDeck)
import Wiki.Core.Space (Space (id))

-- | A route's page: the application's HTML, for the mount point, the
-- document's title, and everything else the page says about itself in its
-- head ("Wiki.App.Head"), including the title.
data Rendered = Rendered
  { html :: Text
  , title :: Text
  , meta :: Head
  }

-- | The application at a route, over a wiki in this state, under this base
-- path (@\/@, or the path a site is served from). Nobody is signed in unless
-- the state says otherwise.
renderRoute :: MemState -> Text -> Route -> IO Rendered
renderRoute wiki base at = do
  container <- N.newElement Nothing (ElemName "div")
  (meta, dispose) <- startRoute Build wiki base at container
  html <- markup container `finally` dispose
  pure Rendered {html, title = meta.title, meta}

-- | The routes the build writes a page for: the front page; the search
-- results page; every space (its home page) and every space's list of
-- pages; every page of the wiki, with its source and its history (at its
-- latest version: another version's address is the history's with a
-- query, for which a static host serves the same page, and the program
-- then shows the version asked for); and every page written as slides
-- ("Wiki.Core.Slides"), as slides, at the first slide (another slide's
-- address is the same with a query, likewise). Every other address gets
-- the page for 'Unknown'.
prerenderedRoutes :: MemState -> [Route]
prerenderedRoutes st =
  Home
    : Search Nothing Nothing True
    : [r | s <- Map.elems st.spaces, Just path <- [spacePath s.id], r <- [Space path, SpacePages path]]
      <> [ r
         | p <- Map.elems st.pages
         , Just sp <- [spacePath p.space]
         , Just pp <- [pathOf (`Map.lookup` st.pages) p.id]
         , r <- [Page sp pp, PageSource sp pp, PageHistory sp pp Nothing AgainstPrevious] <> [PageSlides sp pp 1 | deck p.body]
         ]
  where
    spacePath = pathOf (`Map.lookup` st.spaces)
    deck = either (const False) isDeck . parseMarkdown

-- | How the application starts in its container: building its HTML there,
-- as the prerender does, or adopting the HTML already there, as the
-- program does in the browser.
data Start = Build | Adopt

-- | Start the application at a route in a container, over a wiki in this
-- state, under this base path, and wait until it has loaded what the route
-- shows and its HTML has stopped changing. The result is what the page
-- then says about itself (its title included), and an action that
-- disposes of the application, taking its HTML out of the container.
startRoute :: Start -> MemState -> Text -> Route -> N.NativeNode -> IO (Head, IO ())
startRoute how wiki base at container = do
  ref <- newMemWiki wiki
  let run :: MemWiki MemDOM a -> IO a
      run = runMemDOM . runMemWiki ref
  first (fromMaybe (untitled "Wiki")) <$> startApp True slowly how run input base at container

-- | The application for a wiki on a server, under this base path, as it
-- looks before anything has loaded: what the server's build serves at
-- every address.
renderLoading :: Text -> IO Rendered
renderLoading base = do
  container <- N.newElement Nothing (ElemName "div")
  dispose <- startLoading Build base Home container
  html <- markup container `finally` dispose
  pure Rendered {html, title = "Wiki", meta = untitled "Wiki"}

-- | Start the application for a wiki on a server at a route in a
-- container, under this base path, over a server that never responds, and
-- wait until its HTML has stopped changing. The result disposes of it.
startLoading :: Start -> Text -> Route -> N.NativeNode -> IO (IO ())
startLoading how base at container = do
  env <- newHttpEnv silentTransport
  snd <$> startApp False slowly how (runMemDOM . runHttpWiki env) serverInput base at container

-- | A route's page as a server prerenders it: the application's HTML, the
-- document's title, and the responses the application read, which the
-- page carries for the program ("Wiki.App.Backend.Http.Preload").
data Served = Served
  { html :: Text
  , title :: Text
  , meta :: Head
  , cache :: Cache
  }

-- | Prerender the application for a wiki on a server, at a route, under
-- this base path, over a transport that answers at once (the server's API
-- in its own process, as the user who sent the request). Every view loads
-- its data in its initial state, as over the in-memory backend, which is
-- also how the program first renders from the data the page carries.
-- Whatever the transport returns is rendered, including a failure to reach
-- the server: the caller decides, from the transport's responses, whether
-- to send the page.
renderServed :: Transport -> Text -> Route -> IO Served
renderServed transport base at = do
  env <- newImmediateHttpEnv transport
  container <- N.newElement Nothing (ElemName "div")
  (meta, dispose) <- startServed Build env base at container
  html <- markup container `finally` dispose
  cache <- cacheOf env
  pure Served {html, title = meta.title, meta, cache}

-- | Start the application for a wiki on a server at a route in a
-- container, over this backend, under this base path. Wait until it has
-- loaded what the route shows (from the backend's cache, or from a
-- transport that answers at once) and its HTML has stopped changing. The
-- result is what the page then says about itself, and an action that
-- disposes of it.
startServed :: Start -> HttpEnv -> Text -> Route -> N.NativeNode -> IO (Head, IO ())
startServed how env base at container =
  first (fromMaybe (untitled "Wiki")) <$> startApp True briskly how (runMemDOM . runHttpWiki env) serverInput base at container

-- | Start the application in a container, over a backend run as given,
-- with the shell's input for its router, at a route under a base path. If
-- asked, wait until the shell has loaded what the route shows, and then
-- until its HTML has stopped changing, checking every so many
-- microseconds. The result is what the page says about itself, if waited
-- for, and an action that disposes of the application.
startApp
  :: forall m
   . (Typeable m, MonadLoad m, MonadAdmin m, MonadComments m, MonadNotifications m, MonadSecurity m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m)
  => Bool
  -> Int
  -> Start
  -> (forall a. m a -> IO a)
  -> (Router Route -> Shell.Input m)
  -> Text
  -> Route
  -> N.NativeNode
  -> IO (Maybe Head, IO ())
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
-- applies to (the template has none).
withBase :: Text -> Text -> Text
withBase base = T.replace "<head>" ("<head>\n    <base href=\"" <> escapeHtml base <> "\">")

-- | A page titled for its route: the template's title, @Wiki@, replaced.
withTitle :: Text -> Text -> Text
withTitle title = T.replace "<title>Wiki</title>" ("<title>" <> escapeHtml title <> "</title>")

-- | A page titled for its route, with the other tags about it
-- ('headTags') after the title, for a writer that knows where the page is
-- served.
withHead :: Site -> Head -> Text -> Text
withHead site h = T.replace "<title>Wiki</title>" ("<title>" <> escapeHtml h.title <> "</title>" <> headTags site h)

-- | How often the prerender checks the HTML, in microseconds: it writes
-- its pages once, so it can afford to check slowly.
slowly :: Int
slowly = 10_000

-- | How often a server's prerender checks the HTML: a reader is waiting
-- for the page, and over a transport that answers at once everything is
-- there by the first check, so this is roughly the time the render waits
-- for nothing.
briskly :: Int
briskly = 1_000

-- | Check until the result is there, every so many microseconds. Ten
-- seconds is far longer than a render takes; taking longer means
-- something is wrong.
settled :: Int -> IO (Maybe a) -> IO a
settled pace asking = go (10_000_000 `div` pace)
  where
    go 0 = panic "Wiki.App.Static: the shell did not finish loading"
    go n = asking >>= maybe (threadDelay pace >> go (n - 1)) pure

-- | The HTML, once two checks so many microseconds apart find it the
-- same.
stable :: Int -> IO Text -> IO Text
stable pace snapshot = snapshot >>= go (2_000_000 `div` pace)
  where
    go 0 html = pure html
    go n html = do
      threadDelay pace
      again <- snapshot
      if again == html then pure html else go (n - 1) again
