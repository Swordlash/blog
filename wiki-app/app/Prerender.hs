-- | Write the application's pages, one per route of the demo, each with the
-- application already rendered into it for that route; or, for a wiki a
-- server keeps, the two pages its build serves.
--
--   wiki-app-prerender [--server] TEMPLATE OUTPUT-DIR
--
-- The template, @web/index.html@, has an empty @\<div id=\"app\">\<\/div>@.
-- The front page, the directory of spaces, goes to
-- @OUTPUT-DIR\/index.html@, each space's (its home page) to
-- @OUTPUT-DIR\/s\/\<space path>\/index.html@, its list of pages to
-- @…\/pages\/index.html@ and each page's to
-- @OUTPUT-DIR\/s\/\<space path>\/p\/\<page path>\/index.html@, each
-- page's source to @…\/p\/\<page path>\/source\/index.html@ (anyone who
-- may read a page may read its source, and may well arrive there by its
-- address, so it is served as the page is), as are its history and, for a
-- page written as slides, the slides, and the page of search results
-- to @OUTPUT-DIR\/search\/index.html@ with nothing searched for (a search's
-- words are in its query, which a static host ignores; the program searches
-- once it has loaded). So a static host has a file at every
-- address the demo starts with: a link from elsewhere and a reload load that
-- route's page straight away. Every other address (a space made in the demo,
-- an editor) gets @404.html@, which GitHub Pages and http-server serve for an
-- address they have no file for; the program, once loaded, reads the address
-- and shows its route.
--
-- Each page is rendered as the demo starts, with nobody signed in
-- ("Wiki.App.Static"), so a private space's page says that it is private;
-- a public one says what it is to a link preview in its head
-- ("Wiki.App.Head"), as the server's pages do.
-- The site's base path, from @HALOGEN_BASE_PATH@ (@\/@ when unset;
-- @toolchain\/build-wasm.sh@ passes it on), is written into each page's
-- @\<base href>@: the template's relative @.\/index.js@ and @.\/style.css@
-- then resolve to the same files from every directory, and the program reads
-- its router's base from it ('Halogen.Router.pageBase').
--
-- With @--server@, the build is for @wiki-server@, which serves the wiki it
-- keeps: the program is to talk to it over HTTP, which the page says by its
-- @\<meta name=\"wiki-backend\">@ (the template's says @demo@, and this
-- writes @server@ there; @Main.hs@ reads it). Its content is the server's,
-- unknown at build time: the server renders each route's page itself, per
-- request, into @OUTPUT-DIR\/template.html@, the page with its mount point
-- left empty, which this writes. What it writes besides is the page the
-- server sends when it cannot render one: the application as it shows
-- before it has loaded anything ('renderLoading'), the same at every
-- address, at @OUTPUT-DIR\/index.html@ and @OUTPUT-DIR\/404.html@. Any
-- page a demo build left there is removed.
module Main (main) where

import Data.ByteString qualified as B
import Data.Text qualified as T
import Halogen.Router qualified as Router
import Halogen.Static (fillMountPoint)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Protolude
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, removeDirectoryRecursive)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Wiki.App (Route (..), route)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Head (Site (..))
import Wiki.App.Static (Rendered (..), prerenderedRoutes, renderLoading, renderRoute, withBase, withHead, withTitle)

main :: IO ()
main = do
  (server, template, outputDir) <-
    getArgs >>= \case
      [template, outputDir] -> pure (False, template, outputDir)
      ["--server", template, outputDir] -> pure (True, template, outputDir)
      _ -> die "usage: wiki-app-prerender [--server] TEMPLATE OUTPUT-DIR"
  base <- maybe "/" toS <$> lookupEnv "HALOGEN_BASE_PATH"
  page <- decodeUtf8 <$> B.readFile template
  unless (backendMeta "demo" `T.isInfixOf` page) $
    die (toS template <> ": no " <> backendMeta "demo" <> " to say which backend the page runs on")
  if server then serverPages base template outputDir page else demoPages base template outputDir page

-- | The demo's pages, one per route.
demoPages :: Text -> FilePath -> FilePath -> Text -> IO ()
demoPages base template outputDir page = do
  let demo = demoState demoNow
  -- Only for its addresses: 'Router.href' with the base, natively.
  router <- runMemDOM (Router.newRouter base Unknown route)
  let home = Router.href router Home
  for_ (Unknown : prerenderedRoutes demo) $ \r -> do
    Rendered {html, meta} <- renderRoute demo base r
    filled <- either (die . ((toS template <> ": ") <>)) pure (fillMountPoint "app" html (withBase home (withHead demoSite meta page)))
    let file = case r of
          Unknown -> outputDir </> "404.html"
          _ -> outputDir </> toS (T.drop (T.length home) (Router.href router r)) </> "index.html"
    createDirectoryIfMissing True (takeDirectory file)
    B.writeFile file (encodeUtf8 filled)

-- | What the demo's pages know of where they are: nothing but their paths.
-- The demo is served wherever its files are put, so a link preview's
-- address is the page's path, without a host; its attachments live in
-- the reader's browser and have no address to give; and it has no feeds,
-- which need a server.
demoSite :: Site
demoSite = Site {address = identity, feeds = False, attachmentAddress = const Nothing, iconAddress = const Nothing}

-- | The server's template and its two pages, and none of a demo build's: a
-- page of the demo's left at a space's address would be served there in
-- place of the server's wiki.
serverPages :: Text -> FilePath -> FilePath -> Text -> IO ()
serverPages base template outputDir page = do
  for_ ["s", "search"] $ \dir ->
    doesDirectoryExist (outputDir </> dir) >>= (`when` removeDirectoryRecursive (outputDir </> dir))
  router <- runMemDOM (Router.newRouter base Unknown route)
  Rendered {html, title} <- renderLoading base
  let served = T.replace (backendMeta "demo") (backendMeta "server") (withBase (Router.href router Home) (withTitle title page))
  filled <- either (die . ((toS template <> ": ") <>)) pure (fillMountPoint "app" html served)
  for_ ["index.html", "404.html"] $ \file -> B.writeFile (outputDir </> file) (encodeUtf8 filled)
  B.writeFile (outputDir </> "template.html") (encodeUtf8 served)

-- | The element that says which backend the page's program runs on.
backendMeta :: Text -> Text
backendMeta backend = "<meta name=\"wiki-backend\" content=\"" <> backend <> "\">"
