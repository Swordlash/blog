-- | The demo's smoke test: the built demo, as a static host serves it,
-- driven in headless Chromium through haskell-halogen-playwright, which
-- waits after every action until the page's program says it is idle.
--
-- > npm run smoke-test           # after: npm run build-wasm; the server's smoke test too
-- > sh toolchain/smoke-suite.sh demo
-- > HALOGEN_PLAYWRIGHT_THROTTLE=4 sh toolchain/smoke-suite.sh demo   # every page four times slower
--
-- This is what the unit tests cannot see: the size-optimised app.wasm
-- loading in a real browser on every page the build wrote, adopting the
-- page prerendered into it; its links followed without loading a page; the
-- back and forward buttons and a reload arriving where they should; the
-- editor, search and the islands bundle (web/bundle.sh) working in the
-- built page; 404.html standing in for every address with no file; and the
-- page in a dark scheme and at a phone's width. An error a page throws, or
-- writes on its console, fails the example it is in.
--
-- Its parts, in the order the JavaScript smoke test had them:
--
-- 1. "Demo.Prerendered": every prerendered page (each index.html under the
--    directory) loaded by its address, app.wasm held back until the page
--    has been seen and every node of it marked; the program has to adopt it
--    as the same route, with nothing to repair ("Wiki.Smoke.Adoption").
--    Then the islands drawn, TikZ's letters, the first picture in a fresh
--    browser, the licences, the Content Security Policy and TikZJax's
--    files as served, and a page left while its picture is being drawn.
-- 2. "Demo.Walk": one long walk in one page, as someone would take it,
--    each step checked by its address and what is on screen.
-- 3. "Demo.Looks": the same page in a dark scheme and at a phone's width,
--    a page shown as slides, a page's source and a code block copied, and
--    a comment.
-- 4. "Demo.Offline": the demo as an application: its manifest, its service
--    worker, and the page read again offline. Every other part runs with
--    service workers blocked, so that what it holds back (app.wasm) is
--    held back: a worker's own requests and what it answers from its cache
--    pass by the driver's routes.
-- 5. "Demo.Assistant": the writing assistant with the scripted provider.
--
-- How the suite waits is in "Demo.Site". The walk's examples share one
-- page ('onOnePage'), in order: one of them cannot be run alone with
-- @--match@, and once one has failed the ones after it are pending.
-- Without the build the suite is one pending example, unless
-- @WIKI_SMOKE_REQUIRED=1@ (as @toolchain/smoke-suite.sh@ sets it).
module Main (main) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Demo.Prerendered qualified as Prerendered
import Demo.Site
import Halogen.Playwright.Hspec
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import Wiki.Smoke.Demo

main :: IO ()
main = withDemoIO "the demo, as a static host serves it" $ \demo -> do
  site <- newSite demo
  paths <- prerenderedPaths demo.dir
  visitor <- newProgramGate
  pure $ playwright $ do
    Prerendered.spec site paths visitor

-- | Every index.html under the directory, as the route that serves it:
-- @/@, @/s/docs/@.
prerenderedPaths :: FilePath -> IO [Text]
prerenderedPaths root = sort <$> go []
  where
    go parts = do
      let dir = foldl (</>) root parts
      here' <- doesFileExist (dir </> "index.html")
      names <- sort <$> listDirectory dir
      below <-
        concat
          <$> mapM
            ( \name -> do
                isDir <- doesDirectoryExist (dir </> name)
                if isDir then go (parts <> [name]) else pure []
            )
            names
      let path = if null parts then "/" else "/" <> Text.intercalate "/" (map Text.pack parts) <> "/"
      pure ([path | here'] <> below)
