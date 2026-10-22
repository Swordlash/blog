-- | The application rendered natively, for a route, as the page should
-- arrive before the program has loaded: what @wiki-app-prerender@ writes for
-- every route, and what the native tests look at.
--
-- "Halogen.Static" takes the HTML as soon as the component has started,
-- which is before anything it loads through the backend has arrived (a
-- component waits for the backend on a worker, as for any other 'lift').
-- So this asks the shell whether it has loaded what the route shows
-- ('Shell.Settled'), and then waits for the HTML to stop changing, for the
-- islands that write their source in on a worker too.
--
-- Natively only: the in-memory document exists on a host GHC only.
module Wiki.App.Static
  ( renderRoute
  , Rendered (..)
  )
where

import Halogen qualified as H
import Halogen.HTML.Core (ElemName (..))
import Halogen.IO.Driver (HalogenSocket (..))
import Halogen.IO.Driver qualified as AD
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Halogen.VDom.Driver (renderSpec)
import Protolude
import Wiki.App (component, input)
import Wiki.App.Backend.Mem (MemWiki, newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Route (Route (..), route)
import Wiki.App.Shell qualified as Shell

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
  ref <- newMemWiki wiki
  let run :: MemWiki MemDOM a -> IO a
      run = runMemDOM . runMemWiki ref
  router <- run (Router.newRouter base Unknown route)
  Router.redirect router at
  document <- N.newDocument
  container <- N.newElement Nothing (ElemName "div")
  HalogenSocket {query = send, dispose} <-
    run (AD.runUI (renderSpec (N.fromNative document) (N.fromNative container)) (component @Void) (input router))
  let snapshot = mconcat <$> (traverse N.renderToText =<< N.childNodes container)
  flip finally (run dispose) $ do
    title <- settled (run (join <$> send (H.mkRequest Shell.Settled)))
    html <- stable snapshot
    pure Rendered {html, title}

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
