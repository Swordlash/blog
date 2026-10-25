{-# LANGUAGE TemplateHaskell #-}

-- | The backend over HTTP in a browser: its requests made through the
-- page's @fetch@ (jsbits/fetch.js), answered by a server the test puts in
-- fetch's place (test/jsbits/test-fetch.js), and the application over it:
-- what it shows while the server has not answered, once it has, and when
-- it cannot be reached; and the server's page, adopted with nothing to
-- repair: the build's, before anything is read, and one the server
-- rendered, from what the page carries, with nothing asked.
--
-- The server answers with the demo's wiki as its administrator sees it,
-- read from the in-memory backend and written as the API writes it, so the
-- views have something real to show.
module Test.Browser.Http
  ( spec

    -- * The server in fetch's place, for the other specs
  , Asked (..)
  , serverStarts
  , serverStops
  , serveDemo
  , answerWith
  , asked
  , offline
  , startServer
  , startServerWith
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), ToJSON, eitherDecodeStrict', encode, withObject, (.:))
import Data.Map.Strict qualified as Map
import Data.NT (type (~>) (..))
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Halogen qualified as H
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database, MonadIndexedDB)
import Wiki.Api (AdminApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Links (links)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Version (VersionTime (..))
import Wiki.App (component, serverInput, serverInputWith)
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Http (HttpEnv, browserTransport, cacheOf, newHttpEnv, newHttpEnvWith, runHttpWiki)
import Wiki.App.Backend.Http.Cache (Cache)
import Wiki.App.Backend.Http.Preload (encodePreload, preloadId)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.App.View.Common (spacePathOf)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id (AttachmentId (..), PageId (..), UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Space qualified as S
import Wiki.Core.User (Standing (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..))
#if defined(wasm32_HOST_ARCH)
import Halogen.VDom.DOM.Monad (runBrowserDOM)
import Wiki.App.Backend.Http.Preload (embeddedCache)
import Wiki.App.Route (route)
#endif

$( browserJS
     ["jsbits/test-fetch.js", "jsbits/test-markup.js"]
     [ ("js_server_start", "wiki_test_server_start", Unsafe, [t|IO ()|])
     , ("js_server_stop", "wiki_test_server_stop", Unsafe, [t|IO ()|])
     , ("js_server_answer", "wiki_test_server_answer", Unsafe, [t|JSText -> JSText -> Int -> JSText -> IO ()|])
     , ("js_server_offline", "wiki_test_server_offline", Unsafe, [t|Bool -> IO ()|])
     , ("js_server_hold", "wiki_test_server_hold", Unsafe, [t|IO ()|])
     , ("js_server_release", "wiki_test_server_release", Unsafe, [t|IO ()|])
     , ("js_server_asked", "wiki_test_server_asked", Unsafe, [t|IO JSText|])
     , ("js_markup", "wiki_test_markup", Unsafe, [t|IO JSText|])
     , ("js_embed", "wiki_test_embed", Unsafe, [t|JSText -> JSText -> IO ()|])
     , ("js_unembed", "wiki_test_unembed", Unsafe, [t|JSText -> IO ()|])
     ]
 )

-- | A request the server was asked.
data Asked = Asked
  { method :: Text
  , url :: Text
  , headers :: Map Text Text
  , body :: Text
  , bytes :: Text
  -- ^ The body's bytes, in base64.
  }
  deriving stock (Eq, Show)

instance FromJSON Asked where
  parseJSON = withObject "Asked" $ \o -> Asked <$> o .: "method" <*> o .: "url" <*> o .: "headers" <*> o .: "body" <*> o .: "bytes"

-- | The server in fetch's place, with nothing to answer yet, for the length
-- of the test.
serverStarts :: PageM s ()
serverStarts = unsafeIOToPageM js_server_start

serverStops :: PageM s ()
serverStops = unsafeIOToPageM js_server_stop

answerWith :: (ToJSON a) => Text -> Text -> Int -> a -> PageM s ()
answerWith method url status value = unsafeIOToPageM (js_server_answer (toJSText method) (toJSText url) status (toJSText (decodeUtf8 (toS (encode value)))))

-- | An answer whose body is not JSON (a proxy's, a failing server's).
answerRaw :: Text -> Text -> Int -> Text -> PageM s ()
answerRaw method url status body = unsafeIOToPageM (js_server_answer (toJSText method) (toJSText url) status (toJSText body))

-- | Take the network away, or give it back.
offline :: Bool -> PageM s ()
offline = unsafeIOToPageM . js_server_offline

asked :: PageM s [Asked]
asked = unsafeIOToPageM js_server_asked >>= either (\e -> panic ("the server's requests: " <> toS e)) pure . eitherDecodeStrict' . encodeUtf8 . fromJSText

-- | The demo's wiki as its administrator sees it, answered at the
-- addresses the shell and its views read it from: who is asking, the
-- spaces, each space by its path and its pages, no drafts, and the
-- administration's people.
serveDemo :: PageM s ()
serveDemo = do
  (me, spaces, pages, people) <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki $ do
      me <- session
      spaces <- listSpaces
      pages <- for spaces $ \s -> (s,) . fromRight [] <$> listPages s.id
      people <- directory
      pure (me, spaces, pages, people)
  answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing}
  for_ people (answerWith "GET" links.admin.directory 200)
  answerWith "GET" "api/v1/spaces" 200 spaces
  for_ pages $ \(s, ps) -> do
    answerWith "GET" (links.spaces.atPath (spacePathOf spaces s.id)) 200 s
    answerWith "GET" (links.spaces.listPages s.id) 200 ps
    for_ ps $ \p -> answerWith "GET" ("api/v1/pages/" <> p.id.text <> "/draft") 200 (Nothing :: Maybe ())

-- | The shell over the backend over HTTP, through the page's fetch, at a
-- route, with a router of its own that keeps the route in the fragment.
startServer
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => Route
  -> PageM s (Mounted s Shell.Query Void m)
startServer m at = do
  env <- unsafeIOToPageM (newHttpEnv browserTransport)
  startServerOver m env at

-- | 'startServer', over a backend of the test's.
startServerOver
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => HttpEnv
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
startServerOver m env at = do
  router <- prepare at
  mount m (H.hoist (NT (runHttpWiki env)) component) (serverInput router)

-- | 'startServer', with the demo's wiki in this browser looked for in this
-- database rather than the demo's own.
startServerWith
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => Database
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
startServerWith m db at = do
  env <- unsafeIOToPageM (newHttpEnv browserTransport)
  router <- prepare at
  mount m (H.hoist (NT (runHttpWiki env)) component) (serverInputWith db router)

-- | 'startServer', adopting a page that holds the shell's HTML already.
adoptServer
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => Element s
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
adoptServer m page at = do
  env <- unsafeIOToPageM (newHttpEnv browserTransport)
  adoptServerOver m env page at

-- | 'adoptServer', over a backend of the test's.
adoptServerOver
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m)
  => HttpEnv
  -> Element s
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
adoptServerOver m env page at = do
  router <- prepare at
  hydrate m page (H.hoist (NT (runHttpWiki env)) component) (serverInput router)

prepare :: Route -> PageM s (Router Route)
prepare at = do
  router <- unsafeIOToPageM testRouter
  unsafeIOToPageM (Router.redirect router at)
  pure router

-- | A backend that starts from what the page carries, as the program's
-- does (@Main.hs@).
fromPage :: PageM s HttpEnv
fromPage = unsafeIOToPageM $ readPreload >>= either (panic . ("the page's preload: " <>)) (newHttpEnvWith browserTransport)

readPreload :: IO (Either Text Cache)
#if defined(wasm32_HOST_ARCH)
readPreload = runBrowserDOM embeddedCache
#else
readPreload = panic "the backend's browser tests run in a browser"
#endif

testRouter :: IO (Router Route)
#if defined(wasm32_HOST_ARCH)
testRouter = runBrowserDOM (Router.newHashRouter Unknown route)
#else
testRouter = panic "the backend's browser tests run in a browser"
#endif

-- | A program against the server, through the page's fetch.
overHttp :: HttpEnv -> (forall n. (MonadLoad n) => n a) -> PageM s a
overHttp env program = unsafeIOToPageM (runHttpWiki env program)

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  requests
  refusals
  views m
  accounts m

-- | Who is asking, as the server says: someone of the demo's signed in,
-- or nobody.
signedInAs :: Text -> IO SessionInfo
signedInAs uid = do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn}

nobody :: SessionInfo
nobody = SessionInfo {user = Nothing, groups = mempty, grants = mempty, standing = NotSignedIn}

-- | Signing in and out from the header, over the server's backend.
accounts :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
accounts m = describe "signing in and out" $ do
  it "signs in from the header, and loads everything again as the user signed in" $ runPage $ do
    serverStarts
    serveDemo
    ada <- unsafeIOToPageM (signedInAs "user-admin")
    answerWith "GET" "api/v1/session" 200 nobody
    answerWith "POST" "api/v1/session" 200 ada
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    find ui ".sign-in-form input[name=login]" >>= (`typeText` "ada")
    find ui ".sign-in-form input[name=password]" >>= (`typeText` "correct horse")
    spacesBefore <- length . filter (\r -> r.url == "api/v1/spaces") <$> asked
    find ui ".sign-in-form button[type=submit]" >>= click
    find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
    _ <- find ui ".account .sign-out"
    length <$> findAll ui ".sign-in-form" `shouldReturn` 0
    [signIn] <- filter (\r -> r.method == "POST") <$> asked
    (signIn.url, signIn.body) `shouldBe` ("api/v1/session", "{\"login\":\"ada\",\"password\":\"correct horse\"}")
    Map.lookup "X-Wiki-Request" signIn.headers `shouldBe` Just "1"
    -- Everything read as nobody is read again as Ada: the spaces were.
    eventually $ (length . filter (\r -> r.url == "api/v1/spaces") <$> asked) >>= (`shouldSatisfy` (> spacesBefore))
    find ui ".admin-link" >>= (`shouldHaveText` "Administration")
    unmount ui
    serverStops

  it "says why signing in failed, and keeps the form open" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "POST" "api/v1/session" 401 "{\"error\":\"Unauthenticated\"}"
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    find ui ".sign-in-form input[name=login]" >>= (`typeText` "ada")
    find ui ".sign-in-form input[name=password]" >>= (`typeText` "wrong password")
    find ui ".sign-in-form button[type=submit]" >>= click
    find ui ".sign-in-error" >>= (`shouldHaveText` "The login or the password is not right.")
    answerRaw "POST" "api/v1/session" 429 "{\"error\":\"TooManyRequests\",\"message\":\"Too many failed attempts to sign in as ada: try again in 15 minutes.\"}"
    find ui ".sign-in-form button[type=submit]" >>= click
    find ui ".sign-in-error" >>= (`shouldHaveText` "Too many failed attempts to sign in as ada: try again in 15 minutes.")
    _ <- find ui ".sign-in-toggle"
    unmount ui
    serverStops

  it "signs out, and loads everything again as nobody" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "DELETE" "api/v1/session" 200 nobody
    ui <- startServer m Home
    find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
    answerWith "GET" "api/v1/spaces" 200 ([] :: [S.Space])
    find ui ".account .sign-out" >>= click
    _ <- find ui ".sign-in-toggle"
    find ui ".home .empty" >>= (`shouldHaveText` "There are no spaces you can see.")
    length <$> findAll ui ".admin-link" `shouldReturn` 0
    map (\r -> r.url) . filter (\r -> r.method == "DELETE") <$> asked `shouldReturn` ["api/v1/session"]
    unmount ui
    serverStops

  it "offers to sign in again when the session has ended by itself" $ runPage $ do
    serverStarts
    serveDemo
    ui <- startServer m Home
    find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
    -- The session ends on the server: what Ada could read is refused, and
    -- the server says nobody is asking.
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "GET" (links.spaces.atPath (slugs ["team"])) 403 "{\"error\":\"Forbidden\"}"
    find ui ".wiki-sidebar a[href='#/s/team/']" >>= click
    find ui ".sign-in-notice" >>= (`shouldHaveText` "Your session has ended. Sign in again to go on.")
    _ <- find ui ".sign-in-form input[name=login]"
    length <$> findAll ui ".account .sign-out" `shouldReturn` 0
    unmount ui
    serverStops

-- | Hello, world, from the demo.
helloWorld :: IO P.Page
helloWorld = do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
  runMemWiki wiki $ do
    blog <- getSpace (slugs ["blog"])
    either (panic . show) pure =<< either (pure . Left) (\s -> getPage s.id (slugs ["hello-world"])) blog

requests :: Spec
requests = describe "its requests, through fetch" $ do
  let page = PageId "page 1"
  it "saves with the version it started from in If-Match, and the edit as JSON" $ runPage $ do
    serverStarts
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    hello <- unsafeIOToPageM helloWorld
    answerWith "PUT" ("api/v1/pages/" <> hello.id.text) 200 hello
    overHttp env (savePage hello.id hello.updatedAt "Title" "Body") `shouldReturn` Right hello
    [r] <- asked
    (r.method, r.url) `shouldBe` ("PUT", "api/v1/pages/" <> hello.id.text)
    r.headers `shouldBe` Map.fromList [("If-Match", "\"2026-09-01T12:00:00Z\""), ("Content-Type", "application/json"), ("X-Wiki-Request", "1")]
    r.body `shouldBe` "{\"body\":\"Body\",\"title\":\"Title\"}"
    serverStops

  it "uploads a file as a multipart form" $ runPage $ do
    serverStarts
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    let made = Attachment {id = AttachmentId "a1", name = "notes.txt", mediaType = "text/plain", size = 5, source = SourceUrl "https://example.org/notes.txt"}
    answerWith "POST" "api/v1/pages/page%201/attachments" 201 made
    overHttp env (uploadAttachment page "notes.txt" "text/plain" "hello") `shouldReturn` Right made
    [r] <- asked
    (r.method, r.url) `shouldBe` ("POST", "api/v1/pages/page%201/attachments")
    fromMaybe "" (Map.lookup "Content-Type" r.headers) `shouldSatisfy` T.isPrefixOf "multipart/form-data; boundary="
    r.body `shouldSatisfy` T.isInfixOf "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\nContent-Type: text/plain\r\n\r\nhello\r\n"
    serverStops

  it "deletes with DELETE, and takes a 204 for done" $ runPage $ do
    serverStarts
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    answerRaw "DELETE" "api/v1/pages/page%201/draft" 204 ""
    overHttp env (discardDraft page) `shouldReturn` Right ()
    map (\r -> (r.method, r.url)) <$> asked `shouldReturn` [("DELETE", "api/v1/pages/page%201/draft")]
    serverStops

refusals :: Spec
refusals = describe "its refusals, through fetch" $ do
  let at = links.spaces.atPath (slugs ["team"])
      -- With a backend of its own each time, since a refusal is kept.
      getTeam :: HttpEnv -> PageM s (Either WikiError S.Space)
      getTeam _ = unsafeIOToPageM (newHttpEnv browserTransport) >>= \fresh -> overHttp fresh (getSpace (slugs ["team"]))
  it "reads each refusal of the API as the backend's error of its name" $ runPage $ do
    serverStarts
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    answerRaw "GET" at 404 "{\"error\":\"NotFound\"}"
    getTeam env `shouldReturn` Left NotFound
    answerRaw "GET" at 403 "{\"error\":\"Forbidden\"}"
    getTeam env `shouldReturn` Left Forbidden
    answerRaw "GET" at 409 "{\"error\":\"Conflict\",\"message\":\"Saved since.\"}"
    getTeam env `shouldReturn` Left (Conflict "Saved since.")
    answerRaw "GET" at 400 "{\"error\":\"Invalid\",\"message\":\"No.\"}"
    getTeam env `shouldReturn` Left (Invalid "No.")
    serverStops

  it "takes a failing server, and no network, for out of reach" $ runPage $ do
    serverStarts
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    answerRaw "GET" at 503 "<html>down for maintenance</html>"
    getTeam env `shouldReturn` Left (Unreachable "the server failed, with status 503")
    unsafeIOToPageM (js_server_offline True)
    getTeam env `shouldReturn` Left (Unreachable "the network or the server is down")
    overHttp env (attempt listSpaces) `shouldReturn` Left (Unreachable "the network or the server is down")
    serverStops

views :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
views m = describe "the application over it" $ do
  let tour = Page (slugs ["docs"]) (slugs ["tour"])
  it "shows that it is loading until the server answers, then the page" $ runPage $ do
    serverStarts
    serveDemo
    unsafeIOToPageM js_server_hold
    ui <- startServer m tour
    find ui ".wiki-content > .loading" >>= (`shouldHaveText` "Loading…")
    length <$> findAll ui ".breadcrumbs li" `shouldReturn` 0
    unsafeIOToPageM js_server_release
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Tour")
    find ui ".user-name" >>= (`shouldHaveText` "Ada Admin")
    -- The page came with its space's pages: it was not asked for again.
    urls <- map (\r -> r.url) <$> asked
    filter (T.isInfixOf "/pages/at/") urls `shouldBe` []
    -- A page of the same space opens at once, from what was read.
    before <- length <$> asked
    find ui ".wiki-sidebar .page-tree a[href='#/s/docs/p/markdown-guide/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Markdown guide")
    length <$> asked `shouldReturn` before
    unmount ui
    serverStops

  it "loads the administration's people from the server, and marks an administrator with a PUT" $ runPage $ do
    serverStarts
    serveDemo
    unsafeIOToPageM js_server_hold
    ui <- startServer m Admin
    find ui ".wiki-content > .loading" >>= (`shouldHaveText` "Loading…")
    unsafeIOToPageM js_server_release
    eventually (length <$> findAll ui ".admin-users .user-row" `shouldReturn` 3)
    find ui ".admin-groups .group-name" >>= (`shouldHaveText` "writers")
    answerRaw "PUT" "api/v1/admin/users/user-editor/administrator" 204 ""
    find ui ".user-row[data-login=editor] .administrator-switch" >>= click
    -- Read again once the change is made, as the shell reloads.
    eventually (length . filter (\r -> r.url == "api/v1/admin/directory") <$> asked `shouldReturn` 2)
    _ <- eventually (find ui ".user-row[data-login=editor] .administrator-switch:not([disabled])")
    marks <- filter (\r -> r.method == "PUT") <$> asked
    map (\r -> (r.url, r.body)) marks `shouldBe` [("api/v1/admin/users/user-editor/administrator", "{\"administrator\":true}")]
    unmount ui
    serverStops

  it "opens the editor once the page and the draft have come, and saves against the page's version" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM helloWorld
    answerWith "PUT" ("api/v1/pages/" <> hello.id.text) 200 hello
    ui <- startServer m (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    saves <- filter (\r -> r.method == "PUT" && not ("/draft" `T.isSuffixOf` r.url)) <$> asked
    map (\r -> Map.lookup "If-Match" r.headers) saves `shouldBe` [Just "\"2026-09-01T12:00:00Z\""]
    unmount ui
    serverStops

  it "loads a page's history and a version from the server, and restores it against the page's version" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM helloWorld
    let older = addUTCTime (negate 86400) hello.updatedAt
        ada = Just Author {id = UserId "user-admin", name = "Ada Admin"}
        current = VersionInfo {page = hello.id, updatedAt = hello.updatedAt, title = hello.title, author = ada}
    answerWith "GET" (links.pages.versions hello.id) 200 [current, VersionInfo {page = hello.id, updatedAt = older, title = "Hello", author = Nothing}]
    answerWith "GET" (links.pages.version hello.id (VersionTime older)) 200 Version {page = hello.id, updatedAt = older, title = "Hello", body = "# Hello\n", author = Nothing}
    answerWith "POST" (links.pages.restore hello.id (VersionTime older)) 200 hello
    ui <- startServer m (PageHistory (slugs ["blog"]) (slugs ["hello-world"]) (Just older) AgainstPrevious)
    find ui ".version-detail h2" >>= (`shouldHaveText` "Version 1")
    versions <- traverse textContent =<< findAll ui ".version-list li > a"
    versions `shouldBe` ["Version 2 (current)", "Version 1"]
    (find ui ".diff-added .diff-text" >>= textContent) `shouldReturn` "# Hello"
    fetched <- map (\r -> r.url) . filter (\r -> r.method == "GET") <$> asked
    filter (T.isInfixOf "/versions") fetched `shouldBe` [links.pages.versions hello.id, links.pages.version hello.id (VersionTime older)]
    find ui "button.restore" >>= click
    find ui ".restore-confirm button.primary" >>= click
    eventually $ do
      restores <- filter (\r -> r.method == "POST") <$> asked
      map (\r -> (r.url, Map.lookup "If-Match" r.headers)) restores
        `shouldBe` [(links.pages.restore hello.id (VersionTime older), Just "\"2026-09-01T12:00:00Z\"")]
    unmount ui
    serverStops

  it "says when the server cannot be reached, and tries again when asked" $ runPage $ do
    serverStarts
    serveDemo
    unsafeIOToPageM (js_server_offline True)
    ui <- startServer m (Space (slugs ["docs"]))
    find ui ".wiki-content .error-unreachable" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "could not be reached")
    unsafeIOToPageM (js_server_offline False)
    find ui ".wiki-content .error-unreachable button.retry" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Docs")
    unmount ui
    serverStops

  it "adopts the server's page with nothing to repair, then loads into it" $ runPage $ do
    serverStarts
    serveDemo
    unsafeIOToPageM js_server_hold
    -- The page as the server's build has it: the shell before anything
    -- has come, which is the same at every address.
    first' <- startServer m Home
    _ <- find first' ".wiki-content > .loading"
    html <- fromJSText <$> unsafeIOToPageM js_markup
    unmount first'
    page <- htmlContainer html
    shell <- findIn page ".wiki"
    before <- findAllIn page "*"
    ui <- adoptServer m page tour
    after <- findAll ui "*"
    length after `shouldBe` length before
    zipWithM_ shouldBeSameElement after before
    unsafeIOToPageM js_server_release
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    find ui ".wiki" >>= (`shouldBeSameElement` shell)
    unmount ui
    serverStops

  it "adopts a page the server rendered, from what it carries, and asks nothing" $ runPage $ do
    -- What the server's render reads at the tour: who is asking, the
    -- spaces, the tour's space and its pages.
    serverStarts
    serveDemo
    reading <- unsafeIOToPageM (newHttpEnv browserTransport)
    overHttp reading $ do
      _ <- session
      _ <- listSpaces
      docs <- getSpace (slugs ["docs"])
      for_ docs (\s -> listPages s.id)
    carried <- unsafeIOToPageM (cacheOf reading)
    serverStops
    -- A server that answers nothing from here on, and the page with what
    -- it carries.
    serverStarts
    unsafeIOToPageM (js_embed (toJSText preloadId) (toJSText (encodePreload carried)))
    rendering <- fromPage
    first' <- startServerOver m rendering tour
    find first' ".page-body h1" >>= (`shouldHaveText` "Tour")
    html <- fromJSText <$> unsafeIOToPageM js_markup
    unmount first'
    page <- htmlContainer html
    before <- findAllIn page adoptable
    adopting <- fromPage
    ui <- adoptServerOver m adopting page tour
    after <- findAll ui adoptable
    length after `shouldBe` length before
    zipWithM_ shouldBeSameElement after before
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Tour")
    find ui ".user-name" >>= (`shouldHaveText` "Ada Admin")
    asked `shouldReturn` []
    unmount ui
    unsafeIOToPageM (js_unembed (toJSText preloadId))
    serverStops
  where
    -- Every element but what is inside an island, which its library fills
    -- after the shell has adopted it.
    adoptable = "*:not(.wiki-math *, .wiki-mermaid *, .wiki-tikz *, .wiki-code *, .wiki-time *)"
