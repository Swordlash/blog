-- | What the demo's smoke suite knows of the demo it drives, and the steps
-- its sections share: the built pages, the base path, the requests it
-- makes past the browser, a page loaded with its program held back, and
-- what a page shows of its route.
--
-- How it waits. The demo is a Halogen program, prerendered and adopted,
-- with its content in the browser's IndexedDB. Every action of the driver
-- settles: the program has handled the event and rendered what it renders
-- at once (a route's view, a menu, a dialog). After a navigation 'visit'
-- (or 'adoptedAfter', for a page whose adoption is checked) waits until
-- the program has started. After an action whose result the program reads
-- or writes in IndexedDB, or after typing that starts a debounce, the
-- suite calls 'waitQuiet' and reads the page once. What is not the
-- program's is waited for as a condition, each saying what it waits for:
-- what the islands' libraries draw (KaTeX, Mermaid, TikZJax,
-- highlight.js, CodeMirror), the fonts, a frame's own script, the service
-- worker, the writing assistant's scripted provider.
module Demo.Site
  ( -- * The site
    Site (..)
  , newSite
  , here
  , drawableLetters

    -- * Requests past the browser
  , fetch
  , fetchText
  , contentType

    -- * The report
  , report
  , expect

    -- * A walk of examples
  , Chain
  , newChain
  , step

    -- * Pages
  , ProgramGate
  , newProgramGate
  , holdProgram
  , gateOf
  , load
  , reloadAdopted
  , noRepairs
  , describeRepairs
  , footerLink
  , footerHtml
  , footerShown
  , crumb
  , editorText
  , editorReady
  , markdownIn
  , contentText
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (chr)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Network.HTTP.Client (Manager, httpLbs, newManager, parseRequest, responseBody, responseHeaders, responseStatus)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Types (hContentType, statusCode)
import System.Directory (makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.Process (readProcess)
import Text.Read (readMaybe)
import Wiki.Smoke.Adoption
import Wiki.Smoke.Demo
import Wiki.Smoke.Walk

-- | The demo as the suite sees it.
data Site = Site
  { demo :: Demo
  , manager :: Manager
  -- ^ For what the suite asks the demo's server for itself, as a static
  -- host serves it, before any script runs.
  , letters :: Text
  -- ^ Every letter beyond ASCII a TikZ picture can hold, as
  -- @web/src/tikz-letters.mjs@ lists them ('drawableLetters').
  }

newSite :: Demo -> IO Site
newSite demo = do
  manager <- newManager Http.defaultManagerSettings
  letters <- drawableLetters
  pure Site {demo, manager, letters}

-- | The route the page is at, with its query, under the base path
-- ('localPath').
here :: Site -> Page -> IO Text
here site page = localPath site.demo <$> url page

-- | The letters @web/src/tikz-letters.mjs@ says a TikZ picture can draw
-- (its @drawable@), read from the module itself by node, which the driver
-- runs anyway: the list is the module's, and is not copied here. The
-- module is under the repository's root, @WIKI_SOURCE_DIR@ (which
-- @toolchain/smoke-suite.sh@ sets), else the directory above the
-- package's, where cabal runs the suite. The letters cross as their code
-- points, so that no locale's encoding is in the way.
drawableLetters :: IO Text
drawableLetters = do
  source <- fromMaybe ".." <$> lookupEnv "WIKI_SOURCE_DIR"
  node <- maybe "node" (\n -> if null n then "node" else n) <$> lookupEnv "HALOGEN_PLAYWRIGHT_NODE"
  module' <- makeAbsolute (source </> "web" </> "src" </> "tikz-letters.mjs")
  out <-
    readProcess
      node
      [ "--input-type=module"
      , "-e"
      , "const { drawable } = await import("
          <> show ("file://" <> module')
          <> ");\
             \process.stdout.write([...drawable].map((c) => c.codePointAt(0)).join(','));"
      ]
      ""
  case traverse readMaybe (splitOn ',' out) of
    Just points | not (null points) -> pure (Text.pack (map chr points))
    _ -> fail ("the letters of " <> module' <> " could not be read: " <> out)
  where
    splitOn c s = case break (== c) s of
      (a, _ : rest) -> a : splitOn c rest
      (a, []) -> [a]

----------------------------------------------------------------------
-- Requests past the browser

-- | Ask the demo's server for a path of the site, as a static host serves
-- it: the status and the body.
fetch :: Site -> Text -> IO (Int, ByteString)
fetch site path = do
  request <- parseRequest (Text.unpack (address site.demo path))
  response <- httpLbs request site.manager
  pure (statusCode (responseStatus response), LazyByteString.toStrict (responseBody response))

-- | 'fetch', the body as text.
fetchText :: Site -> Text -> IO (Int, Text)
fetchText site path = fmap (Text.decodeUtf8With Text.lenientDecode) <$> fetch site path

-- | The media type the server says a path is, from a @HEAD@ request.
contentType :: Site -> Text -> IO (Maybe Text)
contentType site path = do
  request <- parseRequest ("HEAD " <> Text.unpack (address site.demo path))
  response <- httpLbs request site.manager
  pure (Text.decodeUtf8With Text.lenientDecode <$> lookup hContentType (responseHeaders response))

----------------------------------------------------------------------
-- Pages

-- | Hold the page's program at its gate ('armProgram'): an 'onOnePage'
-- setup, which also answers the demo's photograph with its stand-in.
holdProgram :: ProgramGate -> Page -> IO ()
holdProgram gate page = do
  standIns (pageContext page)
  armProgram gate page

-- | Go to a route of the demo with its program held back, and say what
-- adopting the page changed ('adoptedAfter').
load :: (HasCallStack) => Site -> Gate -> Page -> Text -> IO Adopted
load site gate page path = adoptedAfter gate page (goto page (address site.demo path))

-- | Reload the page with its program held back, and say what adopting
-- the page changed.
reloadAdopted :: (HasCallStack) => Gate -> Page -> IO Adopted
reloadAdopted gate page = adoptedAfter gate page (reload page)

noRepairs :: Adopted -> Bool
noRepairs adopted = null adopted.repairs

describeRepairs :: [Repair] -> String
describeRepairs = unlines . map (("  " <>) . Text.unpack . describeRepair)

-- | The footer every page ends with, prerendered or not, as the server
-- sends it and as the page shows it.
footerLink :: Text
footerLink = "https://github.com/Swordlash/haskell-halogen"

footerHtml :: Text
footerHtml = "<footer class=\"wiki-footer\">Built with <a href=\"" <> footerLink <> "\">haskell-halogen</a></footer>"

footerShown :: (HasCallStack) => Page -> Text -> IO ()
footerShown page where' = do
  let footer = locator page "#app .wiki > footer.wiki-footer"
  shown' <- count footer
  expect (shown' == 1) (Text.unpack where' <> ": no footer")
  text <- Text.strip <$> textContent footer
  expect (text == "Built with haskell-halogen") (Text.unpack where' <> ": the footer's text is " <> show text)
  getAttribute (locator footer "a") "href" `shouldReturn` Just footerLink

-- | The breadcrumb of the route shown, which names it: a space's or a
-- page's name, \"Edit\", \"Search\"; the front page has none.
crumb :: Page -> IO Text
crumb page = textContent (locator page "#app .breadcrumbs [aria-current=page]")

-- | The editor's text: CodeMirror (@web/src/editor.js@), which takes the
-- place of the textarea the editor is rendered with once
-- @islands/editor.js@ has loaded. What one types into is its content.
editorText :: Page -> Locator
editorText page = locator page "#app .editor-cm .cm-content"

-- | Wait until CodeMirror has taken the place of the editor's textarea:
-- an island the program does not draw, loaded from @islands/editor.js@,
-- so a condition; then settle, as after every condition.
editorReady :: Page -> IO ()
editorReady page = do
  waitFor (editorText page) Visible
  settle page

-- | The Markdown in the editor, read from CodeMirror through what its
-- element carries for the application.
markdownIn :: Page -> IO (Maybe Text)
markdownIn page = evaluate page "document.querySelector('#app .editor-cm .cm-content')?.wikiEditor?.text() ?? null"

-- | The text of the route's content.
contentText :: Page -> IO Text
contentText page = textContent (locator page "#app .wiki-content")
