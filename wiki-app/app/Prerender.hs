-- | Write the application's pages, one per route of the demo, each with the
-- application already rendered into it for that route.
--
--   wiki-app-prerender TEMPLATE OUTPUT-DIR
--
-- The template, @web/index.html@, has an empty @\<div id=\"app\">\<\/div>@.
-- The front page goes to @OUTPUT-DIR\/index.html@, each space's to
-- @OUTPUT-DIR\/s\/\<space path>\/index.html@ and each page's to
-- @OUTPUT-DIR\/s\/\<space path>\/p\/\<page path>\/index.html@, each
-- page's source to @…\/p\/\<page path>\/source\/index.html@ (anyone who
-- may read a page may read its source, and may well arrive there by its
-- address, so it is served as the page is), and the page of search results
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
-- ("Wiki.App.Static"), so a private space's page says that it is private.
-- The site's base path, from @HALOGEN_BASE_PATH@ (@\/@ when unset;
-- @toolchain\/build-wasm.sh@ passes it on), is written into each page's
-- @\<base href>@: the template's relative @.\/index.js@ and @.\/style.css@
-- then resolve to the same files from every directory, and the program reads
-- its router's base from it ('Halogen.Router.pageBase').
module Main (main) where

import Data.ByteString qualified as B
import Data.Text qualified as T
import Halogen.Router qualified as Router
import Halogen.Static (fillMountPoint)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Protolude
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (</>))
import Wiki.App (Route (..), route)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Static (Rendered (..), prerenderedRoutes, renderRoute)

main :: IO ()
main = do
  (template, outputDir) <-
    getArgs >>= \case
      [template, outputDir] -> pure (template, outputDir)
      _ -> die "usage: wiki-app-prerender TEMPLATE OUTPUT-DIR"
  base <- maybe "/" toS <$> lookupEnv "HALOGEN_BASE_PATH"
  page <- decodeUtf8 <$> B.readFile template
  let demo = demoState demoNow
  -- Only for its addresses: 'Router.href' with the base, natively.
  router <- runMemDOM (Router.newRouter base Unknown route)
  let home = Router.href router Home
  for_ (Unknown : prerenderedRoutes demo) $ \r -> do
    Rendered {html, title} <- renderRoute demo base r
    filled <- either (die . ((toS template <> ": ") <>)) pure (fillMountPoint "app" html (withBase home (withTitle title page)))
    let file = case r of
          Unknown -> outputDir </> "404.html"
          _ -> outputDir </> toS (T.drop (T.length home) (Router.href router r)) </> "index.html"
    createDirectoryIfMissing True (takeDirectory file)
    B.writeFile file (encodeUtf8 filled)

-- | The page with a @\<base href>@ first in its head, before anything it
-- applies to.
withBase :: Text -> Text -> Text
withBase base = T.replace "<head>" ("<head>\n    <base href=\"" <> escape base <> "\">")

-- | The page titled for its route.
withTitle :: Text -> Text -> Text
withTitle title = T.replace "<title>Wiki</title>" ("<title>" <> escape title <> "</title>")

escape :: Text -> Text
escape = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  c -> T.singleton c
