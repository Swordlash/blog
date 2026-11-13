-- | The demo as @npm run build-wasm@ built it, served for a smoke suite:
-- where the build is, the address it is served at, and a page of it in a
-- fresh context.
--
-- The demo is the wiki without a server: the application and its
-- prerendered pages in @dist-newstyle/wasm/public/app@, with its content in
-- the browser's IndexedDB. A suite serves that directory as a static host
-- does, under the base path the build was made for (its @<base href>@),
-- with its @404.html@ for an address that has no file.
--
-- How the suites wait. The driver (haskell-halogen-playwright) settles
-- after every action: the program has handled the event and rendered.
-- After a navigation, 'visit' waits until the program has started. After
-- an action that reads or writes the demo's IndexedDB, or starts a debounce
-- before such work, 'waitQuiet' waits until the program has no fiber left
-- waiting in a @liftIO@; the notices' timers are @H.delay@ and are not
-- waited for ("Wiki.App.View.Common" states the rule). What the islands'
-- libraries draw (KaTeX, Mermaid, highlight.js, CodeMirror), the fonts and
-- the images are not the program's: a suite waits for those as explicit
-- conditions.
module Wiki.Smoke.Demo
  ( -- * The built demo
    Demo (..)
  , withDemo
  , address

    -- * Its pages
  , demoContext
  , onDemoPage
  , nothingThrown
  )
where

import Control.Monad (unless, when)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Halogen.Playwright.Serve (ServeOptions (..), defaultServeOptions, serveDirectoryWith)
import System.Directory (doesFileExist)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.IO (hSetEncoding, stderr, stdout, utf8)

-- | The demo, served for the suite.
data Demo = Demo
  { url :: Text
  -- ^ The site's address, ending in its base path:
  -- @http://127.0.0.1:<port>/@, or @http://127.0.0.1:<port>/blog/@ for a
  -- build made for a base path.
  , dir :: FilePath
  -- ^ The built directory it is served from.
  }

-- | Serve the built demo and run the suite's spec against it; without the
-- build, a spec with one pending example that says how to build it, or a
-- failing one when @WIKI_SMOKE_REQUIRED=1@ (as @toolchain/smoke-suite.sh@
-- and CI set it).
--
-- The directory is @WIKI_DEMO_DIR@, else @../dist-newstyle/wasm/public/app@:
-- cabal runs a suite in its package's directory. Every call of the driver
-- may take 30 seconds (@HALOGEN_PLAYWRIGHT_TIMEOUT@, when it is not set),
-- the time the JavaScript smoke tests allowed: the application is a few
-- megabytes of WebAssembly, and the islands load libraries of their own.
withDemo :: String -> (Demo -> Spec) -> IO ()
withDemo name spec = do
  -- The report quotes the pages, which write "…" and hspec's "✔": in UTF-8
  -- whatever the locale.
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  dir <- fromMaybe "../dist-newstyle/wasm/public/app" <$> lookupEnv "WIKI_DEMO_DIR"
  required <- (== Just "1") <$> lookupEnv "WIKI_SMOKE_REQUIRED"
  timeout <- lookupEnv "HALOGEN_PLAYWRIGHT_TIMEOUT"
  when (isNothing timeout) $ setEnv "HALOGEN_PLAYWRIGHT_TIMEOUT" "30000"
  built <- (&&) <$> doesFileExist (dir </> "index.html") <*> doesFileExist (dir </> "app.wasm")
  if not built
    then
      hspec
        $ describe name
        $ it "is served from the built demo"
        $ (if required then expectationFailure else pendingWith)
          ("no built demo in " <> dir <> ": build it with npm run build-wasm (or set WIKI_DEMO_DIR)")
    else do
      base <- baseOf <$> Text.readFile (dir </> "index.html")
      hasNotFound <- doesFileExist (dir </> "404.html")
      let options = defaultServeOptions {basePath = base, notFound = if hasNotFound then Just "404.html" else Nothing}
      serveDirectoryWith options dir $ \site -> hspec (describe name (spec Demo {url = site, dir}))

-- | The base path a built page names in its @<base href>@ (@/@ without
-- one): the path it was built to be served under (@HALOGEN_BASE_PATH@).
baseOf :: Text -> Text
baseOf index = case Text.breakOn "<base href=\"" index of
  (_, rest) | not (Text.null rest) -> Text.takeWhile (/= '"') (Text.drop (Text.length "<base href=\"") rest)
  _ -> "/"

-- | The address of a path of the demo, under its base path:
-- @address demo "/admin/users/"@.
address :: Demo -> Text -> Text
address demo path = demo.url <> Text.dropWhile (== '/') path

-- | A window of 1280 by 800 (at Playwright's device scale of 1), motion
-- reduced, so that a page that animates shows where the animation ends,
-- and no service worker, whose requests and cached answers would pass no
-- route of the test's.
demoContext :: ContextOptions
demoContext =
  defaultContextOptions
    { viewport = Just (1280, 800)
    , reducedMotion = True
    , serviceWorkers = False
    }

-- | A fresh context with these options and a page in it, for an example.
-- The demo starts in it as it is published: its content in a fresh
-- IndexedDB, signed in as admin. The demo's photograph on Wikimedia
-- Commons is answered with a stand-in, so that no suite needs the network.
-- A failure says the page's state, as 'inPage''s does.
onDemoPage :: (HasCallStack) => ContextOptions -> (Page -> IO a) -> Playwright -> IO a
onDemoPage options body pw = withContext pw options $ \ctx -> do
  _ <- route ctx "https://upload.wikimedia.org/**" $ \request ->
    pure $
      if ".webm" `Text.isSuffixOf` request.url
        then fulfill 204 Nothing ""
        else fulfill 200 (Just "image/png") standIn
  page <- newPage ctx
  withFailureContext page (body page)

-- | Fail if the page has thrown an error it did not catch.
nothingThrown :: (HasCallStack) => Page -> Expectation
nothingThrown page = do
  thrown <- pageErrors page
  unless (null thrown) $ expectationFailure ("the page threw: " <> show thrown)

-- | A 32 by 32 PNG, standing in for the demo's photograph.
standIn :: ByteString
standIn =
  Base64.decodeLenient
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAASklEQVR42mP48OUXTRHDCLDAJHUJHjRqwagFI8MCZFTR1ANENMzJoxbQyQKIKeShwWQBqeX+sLeAvPKAGF2jFoxaMHQsGG384kYAzNSeSHKJ2CAAAAAASUVORK5CYII="
