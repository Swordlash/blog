-- | What the server's smoke suite knows of the server it drives, and the
-- steps its parts share: the users the console made, the administrator's
-- session, the API as her, browsers signed in as someone or nobody, and a
-- page loaded with its program and the API held back.
--
-- How it waits. The page is a Halogen program, prerendered by the server
-- and adopted. Every action of the driver settles: the program has handled
-- the event and rendered what it renders at once (a route's view, a menu,
-- a dialog). After a navigation 'visit' waits until the program has
-- started. After an action that makes requests (a save, a search, a
-- sign-in), the suite calls 'waitQuiet' and reads the page once. What is
-- not the program's is waited for as a condition, each with a comment
-- naming it, and the page settled after it before anything else is read:
-- what the islands' libraries draw (CodeMirror among them), a frame's own
-- script and document, the service worker, a WebSocket's push arriving in
-- another tab, a backup the server makes by itself, an image decoded, a
-- navigation through another site (the provider's).
module Server.Site
  ( -- * The site
    Smoke (..)
  , adminLogin
  , adminName
  , adminPassword
  , readerUser
  , address
  , adminSession
  , setAdminSession
  , asAdmin
  , pagesOf
  , pageAt
  , pageAtWithTag

    -- * Browsers
  , Who (..)
  , inBrowser
  , openBrowser
  , closeBrowser
  , here

    -- * Loads with the program and the API held
  , Loads
  , holdLoads
  , Loaded (..)
  , loadAdopted
  , askedSince
  , adoptedCleanly

    -- * Reading the page
  , hasText
  , lacksText
  , contentText
  , editorText
  , editorReady
  , markdownIn
  , includes
  , orFail
  )
where

import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Monad (unless, when)
import Data.Aeson (Value)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Network.HTTP.Types (Method)
import Server.Canary (Canary)
import Server.Provider (Provider)
import Wiki.Smoke.Adoption
import Wiki.Smoke.Api
import Wiki.Smoke.Browser
import Wiki.Smoke.Server
import Wiki.Smoke.Walk

-- | The server the suite drives, and what its parts share.
data Smoke = Smoke
  { build :: ServerBuild
  , server :: Server
  , wiki :: Wiki
  , origin :: Text
  -- ^ @http://127.0.0.1:PORT@, the server's public address.
  , dataDir :: FilePath
  , database :: Database
  , restoreDatabase :: Maybe Database
  -- ^ On PostgreSQL, the database a restore into a fresh data directory
  -- takes.
  , provider :: Provider
  , admin :: IORef (Maybe Session)
  -- ^ The administrator's session, once the walk has signed her in.
  , canary :: Canary
  , chain :: Chain
  -- ^ The walk's: its parts go on from one another.
  }

-- | The first administrator, made with the console before the server
-- starts.
adminLogin, adminName, adminPassword :: Text
adminLogin = "ada"
adminName = "Ada Admin"
adminPassword = "the smoke test's password"

-- | A user who is no administrator, a reader of the encrypted space.
readerUser :: NewUser
readerUser = NewUser {login = "bea", displayName = "Bea Reader", password = "the reader's password", admin = False}

-- | An address of the server: its origin and a path.
address :: Smoke -> Text -> Text
address smoke path = smoke.origin <> path

-- | The administrator's session, which the walk's first example takes.
adminSession :: (HasCallStack) => Smoke -> IO Session
adminSession smoke = readIORef smoke.admin >>= maybe (fail "the administrator has not signed in: the walk's first example did not pass") pure

setAdminSession :: Smoke -> Session -> IO ()
setAdminSession smoke = writeIORef smoke.admin . Just

-- | Ask the API as the administrator.
asAdmin :: Smoke -> Method -> Text -> Maybe Value -> IO Reply
asAdmin smoke method path body = do
  s <- adminSession smoke
  api smoke.wiki (Just s) method path body []

-- | A space's pages, as the API lists them to the administrator.
pagesOf :: (HasCallStack) => Smoke -> Text -> IO [Value]
pagesOf smoke spacePath = do
  space <- asAdmin smoke "GET" ("spaces/at/" <> spacePath) Nothing >>= expectStatus 200 ("the space at " <> Text.unpack spacePath) >>= apiJson
  sid <- text (space .! "id")
  asAdmin smoke "GET" ("spaces/" <> escape sid <> "/pages") Nothing >>= expectStatus 200 "a space's pages" >>= apiJson >>= list

-- | A page at a top-level path of a space, body and all: the list of a
-- space's pages has no bodies.
pageAt :: (HasCallStack) => Smoke -> Text -> Text -> IO Value
pageAt smoke spacePath slug = fst <$> pageAtWithTag smoke spacePath slug

-- | 'pageAt', and the version's tag the server sent with it (@ETag@), for
-- a save that names the version it replaces (@If-Match@).
pageAtWithTag :: (HasCallStack) => Smoke -> Text -> Text -> IO (Value, Text)
pageAtWithTag smoke spacePath slug = do
  space <- asAdmin smoke "GET" ("spaces/at/" <> spacePath) Nothing >>= expectStatus 200 ("the space at " <> Text.unpack spacePath) >>= apiJson
  sid <- text (space .! "id")
  found <- asAdmin smoke "GET" ("spaces/" <> escape sid <> "/pages/at/" <> slug) Nothing >>= expectStatus 200 ("the page at " <> Text.unpack (spacePath <> "/" <> slug))
  v <- apiJson found
  pure (v, maybe "" id (header "etag" found))

----------------------------------------------------------------------
-- Browsers

-- | Whose session a browser starts with.
data Who = Admin | Nobody | As Session

-- | A browser of its own ('serverContext': no service worker, dialogs
-- accepted), signed in as someone or nobody, with a page, for the body;
-- the page must have nothing wrong on it when the body ends, and the
-- browser is closed afterwards.
inBrowser :: (HasCallStack) => Smoke -> Playwright -> Who -> (Page -> IO a) -> IO a
inBrowser smoke pw who body = do
  session <- sessionOf smoke who
  withSessionContext pw serverContext smoke.origin session $ \page -> do
    result <- body page
    nothingWrongOnServer page
    pure result

-- | 'inBrowser' for a browser closed within an example: 'closeBrowser'
-- checks its page and closes it.
openBrowser :: Smoke -> Playwright -> Who -> IO (Context, Page)
openBrowser smoke pw who = do
  session <- sessionOf smoke who
  ctx <- newContext pw serverContext
  mapM_ (\s -> addCookies ctx [sessionCookie smoke.origin s]) session
  page <- newPage ctx
  pure (ctx, page)

closeBrowser :: (HasCallStack) => (Context, Page) -> IO ()
closeBrowser (ctx, page) = do
  withFailureContext page (nothingWrongOnServer page)
  closeContext ctx

sessionOf :: Smoke -> Who -> IO (Maybe Session)
sessionOf smoke = \case
  Admin -> Just <$> adminSession smoke
  Nobody -> pure Nothing
  As s -> pure (Just s)

-- | The path the page is at, without its query and fragment.
here :: Page -> IO Text
here page = do
  full <- url page
  let afterScheme = maybe full snd (splitOnce "://" full)
  pure (Text.takeWhile (\c -> c /= '?' && c /= '#') (Text.dropWhile (/= '/') afterScheme))
  where
    splitOnce sep t = case Text.breakOn sep t of
      (a, b) | not (Text.null b) -> Just (a, Text.drop (Text.length sep) b)
      _ -> Nothing

----------------------------------------------------------------------
-- Loads with the program and the API held

-- | A page's gates: its program's (@app.wasm@), and the API's, which holds
-- the program's own requests to the API (a fetch) and lets the page's
-- pass (a space's icon, an attached image, an interactive SVG's frame:
-- what the page shows from the API's addresses is the page's). Each is one
-- for the page, made with it and never taken away while it loads. The
-- API's also keeps what the program asked it since the last load.
data Loads = Loads
  { program :: Gate
  , apiOpen :: TVar Bool
  , asked :: TVar [Text]
  }

-- | Make a page's gates, released.
holdLoads :: Page -> IO Loads
holdLoads page = do
  program <- hold page serverAdoptionOptions.program
  release program
  apiOpen <- newTVarIO True
  asked <- newTVarIO []
  _ <- route page "**/api/v1/**" $ \request -> do
    when (request.resourceType == "fetch") $ do
      atomically (modifyTVar' asked (<> [request.url]))
      atomically (readTVar apiOpen >>= STM.check)
    pure Continue
  pure Loads {program, apiOpen, asked}

-- | A page as its program adopted it: the status the server sent it with,
-- the text of its content before the program ran, the repairs adopting it
-- made, and what the program asked the API before the server had answered
-- anything.
data Loaded = Loaded
  { status :: Maybe Int
  , shown :: Text
  , repairs :: [Repair]
  , asked :: [Text]
  }

-- | Load an address with the program and the API held back: mark every
-- node of the page as the server sent it, let the program adopt it, and
-- say what adopting it changed and what it asked the API for before the
-- server answered anything; then let the API answer. While the API is
-- held the program is rightly waiting, so the suite waits for it to have
-- started ('waitStarted'), never for it to be quiet. Every html fence's
-- frame that the islands' script fits has its height before the compare
-- ('framesFitted': the frame's document loading, not the program).
loadAdopted :: Smoke -> Loads -> Page -> Text -> IO Loaded
loadAdopted smoke loads page path = do
  rearm loads.program
  atomically $ do
    writeTVar loads.apiOpen False
    writeTVar loads.asked []
  status <- gotoStatus page (address smoke path)
  waitHeld loads.program
  shown' <- textContent (locator page "#app .wiki-content")
  markPrerenderedWith serverAdoptionOptions page
  release loads.program
  waitStarted page
  framesFitted page
  settle page
  (repairs, objectUrls) <- repairsSinceMarked page >>= sortRepairs page
  asked' <- readTVarIO loads.asked
  atomically (writeTVar loads.apiOpen True)
  pure Loaded {status, shown = shown', repairs = repairs <> objectUrls, asked = asked'}

-- | What the program has asked the API since the last load.
askedSince :: Loads -> IO [Text]
askedSince loads = readTVarIO loads.asked

-- | Fail unless the load was the status given, showed a text before the
-- program ran, and was adopted with nothing to repair and nothing asked
-- of the API.
adoptedCleanly :: (HasCallStack) => Text -> Loaded -> Int -> Text -> IO ()
adoptedCleanly path loaded status expected = do
  loaded.status `shouldBe` Just status
  expect (expected `Text.isInfixOf` loaded.shown) (Text.unpack path <> ": \"" <> Text.unpack expected <> "\" is not there before app.wasm: " <> Text.unpack loaded.shown)
  unless (null loaded.repairs) $ expectationFailure (Text.unpack path <> ": adopting it repaired it:\n" <> unlines (map (Text.unpack . describeRepair) loaded.repairs))
  unless (null loaded.asked) $ expectationFailure (Text.unpack path <> ": the program asked the API for what the page carries: " <> show loaded.asked)

----------------------------------------------------------------------
-- Reading the page

-- | Fail unless an element the locator finds holds the text (anywhere in
-- it, case ignored, as Playwright's @hasText@), read now.
hasText :: (HasCallStack) => Locator -> Text -> IO ()
hasText found wanted = do
  n <- count (withText wanted found)
  unless (n > 0) $ do
    texts' <- allTextContents found
    expectationFailure ("no element holds \"" <> Text.unpack wanted <> "\"; the texts found: " <> show texts')

-- | Fail if an element the locator finds holds the text.
lacksText :: (HasCallStack) => Locator -> Text -> IO ()
lacksText found unwanted = do
  n <- count (withText unwanted found)
  when (n > 0) $ expectationFailure ("an element holds \"" <> Text.unpack unwanted <> "\"")

-- | The text of the route's content.
contentText :: Page -> IO Text
contentText page = textContent (locator page "#app .wiki-content")

-- | The editor's text: CodeMirror, which takes the place of the textarea
-- the editor is rendered with once @islands/editor.js@ has loaded.
editorText :: Page -> Locator
editorText page = locator page "#app .editor-cm .cm-content"

-- | Wait until CodeMirror has taken the textarea's place: an island the
-- program does not draw, so a condition; then settle.
editorReady :: Page -> IO ()
editorReady page = do
  waitFor (editorText page) Visible
  settle page

-- | The Markdown in the editor, from CodeMirror, through what its element
-- carries for the application.
markdownIn :: Page -> IO Text
markdownIn page = maybe "" id <$> (evaluate page "document.querySelector('#app .editor-cm .cm-content')?.wikiEditor?.text() ?? null" :: IO (Maybe Text))

-- | Fail unless the text holds the part.
includes :: (HasCallStack) => Text -> Text -> String -> IO ()
includes whole part what = expect (part `Text.isInfixOf` whole) (what <> ": \"" <> Text.unpack part <> "\" is not in: " <> Text.unpack (Text.take 2000 whole))

-- | The value, or a failure that says what was missing.
orFail :: (HasCallStack) => String -> Maybe a -> IO a
orFail what = maybe (fail what) pure
