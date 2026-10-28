{-# LANGUAGE TemplateHaskell #-}

-- | The backend over HTTP in a browser: its requests made through the
-- page's @fetch@ ("Halogen.Net.Fetch"), answered by a server the test puts
-- in fetch's place (test/jsbits/test-fetch.js), and the application over
-- it: what it shows while the server has not answered, once it has, and
-- when it cannot be reached or the browser is offline; that a request whose
-- wait ends early (a navigation away, a time limit) is aborted; and the
-- server's page, adopted with nothing to repair: the build's, before
-- anything is read, and one the server rendered, from what the page
-- carries, with nothing asked.
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
  , quietServer
  , answerWith
  , answerRaw
  , asked
  , offline
  , browserGoes
  , startServer
  , startServerWith
  , tellServer
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), ToJSON, decodeStrict', eitherDecodeStrict', encode, withObject, (.:))
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
import Test.Browser.Mount (clickButton, slugs, start)
import Test.Browser.Text (editorText, markdown)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database, MonadIndexedDB)
import Wiki.Api (AdminApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (SignInMethods (..))
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin (ServerStatus (..))
import Wiki.Api.Backups (Backups (..), defaultBackupSettings)
import Wiki.Api.Comments (CommentsApi (..), NewThread (..))
import Wiki.Api.Events (ClientMessage (..), PageEvent (CommentAdded, Editing, PageChanged), ServerMessage (..))
import Wiki.Api.Events qualified as Events
import Wiki.Api.Links (links)
import Wiki.Api.Notifications (Notifications (..), NotificationsApi (..))
import Wiki.Api.ServerSettings (ServerSettings, noServerSettings)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Version (VersionTime (..))
import Wiki.App (component, serverInput, serverInputWith)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http (HttpEnv, browserTransport, cacheOf, fetchTransport, newHttpEnv, newHttpEnvWith, runHttpWiki)
import Wiki.App.Backend.Http.Cache (Cache)
import Wiki.App.Backend.Http.Preload (encodePreload, preloadId)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common (pagePathOf, spacePathOf)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (AttachmentId (..), CommentId (..), CommentThreadId (..), PageId (..), UserId (..))
import Wiki.Core.Notification (Watch (..), WatchReason (..), WatchTarget (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Space qualified as S
import Wiki.Core.Url (Url (..))
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
     , ("js_server_hold_at", "wiki_test_server_hold_at", Unsafe, [t|JSText -> JSText -> IO ()|])
     , ("js_network_event", "wiki_test_network_event", Unsafe, [t|Bool -> IO ()|])
     , ("js_server_release", "wiki_test_server_release", Unsafe, [t|IO ()|])
     , ("js_server_asked", "wiki_test_server_asked", Unsafe, [t|IO JSText|])
     , ("js_markup", "wiki_test_markup", Unsafe, [t|IO JSText|])
     , ("js_embed", "wiki_test_embed", Unsafe, [t|JSText -> JSText -> IO ()|])
     , ("js_unembed", "wiki_test_unembed", Unsafe, [t|JSText -> IO ()|])
     , ("js_server_tell", "wiki_test_server_tell", Unsafe, [t|JSText -> IO ()|])
     , ("js_server_hang_up", "wiki_test_server_hang_up", Unsafe, [t|IO ()|])
     , ("js_server_said", "wiki_test_server_said", Unsafe, [t|IO JSText|])
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
  , aborted :: Bool
  -- ^ Whether the request was aborted.
  }
  deriving stock (Eq, Show)

instance FromJSON Asked where
  parseJSON = withObject "Asked" $ \o -> Asked <$> o .: "method" <*> o .: "url" <*> o .: "headers" <*> o .: "body" <*> o .: "bytes" <*> o .: "aborted"

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

-- | The browser saying that it has gone online ('True') or offline: the
-- window's @online@ or @offline@ event, which a headless page never has
-- cause to dispatch itself.
browserGoes :: Bool -> PageM s ()
browserGoes = unsafeIOToPageM . js_network_event

asked :: PageM s [Asked]
asked = unsafeIOToPageM js_server_asked >>= either (\e -> panic ("the server's requests: " <> toS e)) pure . eitherDecodeStrict' . encodeUtf8 . fromJSText

-- | The demo's wiki as its administrator sees it, answered at the
-- addresses the shell and its views read it from: who is asking, the
-- spaces, each space by its path and its pages, no drafts, and the
-- administration's people.
serveDemo :: PageM s ()
serveDemo = do
  (me, spaces, pages, people, threads, counts) <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki $ do
      me <- session
      spaces <- listSpaces
      pages <- for spaces $ \s -> do
        ps <- fromRight [] <$> listPages s.id
        details <- fromRight mempty <$> postDetails s.id
        -- The list of pages has no bodies: each page is read by itself.
        full <- rights <$> for ps (\p -> getPage s.id (pagePathOf ps p.id))
        pure (s, ps, details, full)
      people <- directory
      threads <- for (concatMap (\(_, ps, _, _) -> ps) pages) $ \p -> (p.id,) . fromRight [] <$> listThreads p.id
      counts <- pageCounts
      pure (me, spaces, pages, people, threads, counts)
  -- What the bell, the "Watch" buttons and the mentions read
  -- ("Wiki.App.View.Bell", "Wiki.App.View.Watch", "Wiki.App.View.Body").
  (named, watched) <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki $ do
      named <- for (concatMap (\(_, _, _, full) -> full) pages) $ \p -> do
        let logins = Body.unasked Body.noPeople (p.body : [c.body | (q, ts) <- threads, q == p.id, t <- ts, c <- t.comments])
        (logins,) <$> mentionable logins
      watched <-
        (<>)
          <$> for (concatMap (\(_, ps, _, _) -> ps) pages) (\p -> (links.notifications.pageWatch p.id,) . fromRight (Watch False Unchosen) <$> watching (WatchPage p.id))
          <*> for spaces (\s -> (links.notifications.spaceWatch s.id,) . fromRight (Watch False Unchosen) <$> watching (WatchSpace s.id))
      pure (named, watched)
  answerWith "GET" links.notifications.list 200 Notifications {unread = 0, items = []}
  for_ named $ \(logins, found) -> unless (null logins) (answerWith "GET" (links.notifications.people logins) 200 found)
  for_ watched $ \(url, w) -> answerWith "GET" url 200 w
  for_ threads $ \(p, ts) -> answerWith "GET" (links.comments p).list 200 ts
  answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing, providers = [], exports = []}
  for_ people (answerWith "GET" links.admin.directory 200)
  answerWith "GET" links.admin.server 200 (noServerSettings :: ServerSettings)
  answerWith "GET" links.admin.backups 200 Backups {available = True, settings = defaultBackupSettings, last = Nothing, running = False, next = Nothing, kept = 0}
  answerWith "GET" (links.admin.activity Nothing Nothing Nothing) 200 Activity {available = True, entries = [], more = False, actors = []}
  answerWith "GET" links.admin.status 200 quietServer
  answerWith "GET" "api/v1/spaces" 200 spaces
  answerWith "GET" links.spaces.pageCounts 200 counts
  for_ pages $ \(s, ps, details, full) -> do
    answerWith "GET" (links.spaces.atPath (spacePathOf spaces s.id)) 200 s
    answerWith "GET" (links.spaces.listPages s.id) 200 ps
    for_ full $ \p -> answerWith "GET" (links.spaces.pageAt s.id (pagePathOf ps p.id)) 200 p
    answerWith "GET" (links.spaces.postDetails s.id) 200 details
    for_ ps $ \p -> answerWith "GET" ("api/v1/pages/" <> p.id.text <> "/draft") 200 (Nothing :: Maybe ())

-- | A server's status with nothing to say: what 'serveDemo' answers.
quietServer :: ServerStatus
quietServer =
  ServerStatus
    { version = "wiki-server test"
    , startedAt = demoNow
    , dataDir = "/data"
    , spaces = 4
    , pages = 20
    , attachments = 0
    , users = 3
    , backups = 0
    , schemaVersion = 9
    , lastBackup = Nothing
    , connections = 1
    , errors = []
    }

-- | The shell over the backend over HTTP, through the page's fetch, at a
-- route, with a router of its own that keeps the route in the fragment.
startServer
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)
  => Route
  -> PageM s (Mounted s Shell.Query Void m)
startServer m at = do
  env <- unsafeIOToPageM (newHttpEnv browserTransport)
  startServerOver m env at

-- | 'startServer', over a backend of the test's.
startServerOver
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)
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
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)
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
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)
  => Element s
  -> Route
  -> PageM s (Mounted s Shell.Query Void m)
adoptServer m page at = do
  env <- unsafeIOToPageM (newHttpEnv browserTransport)
  adoptServerOver m env page at

-- | 'adoptServer', over a backend of the test's.
adoptServerOver
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)
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
overHttp :: HttpEnv -> (forall n. (MonadLoad n, MonadComments n, MonadNotifications n) => n a) -> PageM s a
overHttp env program = unsafeIOToPageM (runHttpWiki env program)

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  requests
  refusals
  views m
  accounts m
  ownPassword m
  comments m
  presence m

-- | Who is asking, as the server says: someone of the demo's signed in,
-- or nobody.
signedInAs :: Text -> IO SessionInfo
signedInAs uid = do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = []}

nobody :: SessionInfo
nobody = SessionInfo {user = Nothing, groups = mempty, grants = mempty, standing = NotSignedIn, providers = [], exports = []}

-- | Signing in and out from the header, over the server's backend.
accounts :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
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
    find ui ".directory .empty" >>= (`shouldHaveText` "There are no spaces you can see.")
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
    find ui ".wiki-sidebar a[href$='#/s/team/']" >>= click
    find ui ".sign-in-notice" >>= (`shouldHaveText` "Your session has ended. Sign in again to go on.")
    _ <- find ui ".sign-in-form input[name=login]"
    length <$> findAll ui ".account .sign-out" `shouldReturn` 0
    unmount ui
    serverStops

-- | A signed-in user's own password, from the panel under their name
-- (WP3.7 of docs/PLAN.md), where the server names no provider to sign in
-- with: the name is a button all the same.
ownPassword :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
ownPassword m = describe "one's own password" $ do
  let typeIn ui field text = find ui (".password-change input[name=" <> field <> "]") >>= (`typeText` text)
      puts = filter (\r -> r.method == "PUT") <$> asked

  it "is changed from the panel under the name, with the current one" $ runPage $ do
    serverStarts
    serveDemo
    rita <- unsafeIOToPageM (signedInAs "user-reader")
    answerWith "GET" "api/v1/session" 200 rita
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = True, identities = []}
    answerWith "PUT" "api/v1/account/password" 200 SignInMethods {password = True, identities = []}
    ui <- startServer m Home
    find ui ".account-toggle" >>= (`shouldHaveText` "Rita Reader")
    find ui ".account-toggle" >>= click
    find ui ".account-password" >>= (`shouldHaveText` "With your password")
    find ui ".password-change-toggle" >>= (`shouldHaveText` "Change password…")
    find ui ".password-change-toggle" >>= click
    typeIn ui "current" "rita's password"
    typeIn ui "new" "a longer new password"
    typeIn ui "repeat" "a longer new password"
    find ui ".password-change button[type=submit]" >>= (`shouldHaveText` "Change password")
    find ui ".password-change button[type=submit]" >>= click
    find ui ".account-told" >>= (`shouldContainText` "Your password is changed.")
    map (\r -> (r.url, r.body)) <$> puts `shouldReturn` [("api/v1/account/password", "{\"current\":\"rita's password\",\"new\":\"a longer new password\"}")]
    -- The form is gone, with what was typed in it; Rita is still signed in.
    length <$> findAll ui ".password-change" `shouldReturn` 0
    _ <- find ui ".password-change-toggle"
    find ui ".account-toggle" >>= (`shouldHaveText` "Rita Reader")
    unmount ui
    serverStops

  it "says why it was not changed: a repetition that differs, asked nothing, and a wrong current one" $ runPage $ do
    serverStarts
    serveDemo
    rita <- unsafeIOToPageM (signedInAs "user-reader")
    answerWith "GET" "api/v1/session" 200 rita
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = True, identities = []}
    answerRaw "PUT" "api/v1/account/password" 401 "{\"error\":\"Unauthenticated\"}"
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    find ui ".password-change-toggle" >>= click
    typeIn ui "current" "not rita's password"
    typeIn ui "new" "a longer new password"
    typeIn ui "repeat" "a longer new passwort"
    find ui ".password-change button[type=submit]" >>= click
    find ui ".password-error" >>= (`shouldHaveText` "The new password and its repetition are not the same.")
    puts `shouldReturn` []
    find ui ".password-change input[name=repeat]" >>= clear
    typeIn ui "repeat" "a longer new password"
    find ui ".password-change button[type=submit]" >>= click
    find ui ".password-error" >>= (`shouldHaveText` "Your current password is not right.")
    length <$> puts `shouldReturn` 1
    -- Still signed in, the form still open.
    _ <- find ui ".password-change input[name=current]"
    find ui ".account-toggle" >>= (`shouldHaveText` "Rita Reader")
    unmount ui
    serverStops

  it "is set by a user who has none, without a current one" $ runPage $ do
    serverStarts
    serveDemo
    rita <- unsafeIOToPageM (signedInAs "user-reader")
    answerWith "GET" "api/v1/session" 200 rita
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = False, identities = []}
    answerWith "PUT" "api/v1/account/password" 200 SignInMethods {password = True, identities = []}
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    find ui ".password-change-toggle" >>= (`shouldHaveText` "Set a password…")
    find ui ".password-change-toggle" >>= click
    _ <- find ui ".password-change input[name=new]"
    length <$> findAll ui ".password-change input[name=current]" `shouldReturn` 0
    typeIn ui "new" "a longer new password"
    typeIn ui "repeat" "a longer new password"
    find ui ".password-change button[type=submit]" >>= (`shouldHaveText` "Set password")
    find ui ".password-change button[type=submit]" >>= click
    find ui ".account-told" >>= (`shouldContainText` "Your password is set")
    map (\r -> r.body) <$> puts `shouldReturn` ["{\"current\":null,\"new\":\"a longer new password\"}"]
    find ui ".account-password" >>= (`shouldHaveText` "With your password")
    find ui ".password-change-toggle" >>= (`shouldHaveText` "Change password…")
    unmount ui
    serverStops

  it "is not offered to the operator of the admin listener, who has no account" $ runPage $ do
    serverStarts
    serveDemo
    rita <- unsafeIOToPageM (signedInAs "user-admin")
    answerWith "GET" "api/v1/session" 200 SessionInfo {user = rita.user, groups = rita.groups, grants = rita.grants, standing = Operator, providers = [], exports = []}
    ui <- startServer m Home
    find ui ".user-name" >>= (`shouldHaveText` "Ada Admin")
    length <$> findAll ui ".account-toggle" `shouldReturn` 0
    length <$> findAll ui ".sign-out" `shouldReturn` 0
    unmount ui
    serverStops

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | Hello, world, from the demo.
helloWorld :: IO P.Page
helloWorld = do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
  runMemWiki wiki $ do
    blog <- getSpace (slugs ["blog"])
    either (panic . show) pure =<< either (pure . Left) (\s -> getPage s.id (slugs ["hello-world"])) blog

-- | The demo's tour of the Docs space, as its administrator reads it.
tourOfDocs :: IO P.Page
tourOfDocs = do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
  runMemWiki wiki $ do
    docs <- getSpace (slugs ["docs"])
    either (panic . show) pure =<< either (pure . Left) (\s -> getPage s.id (slugs ["tour"])) docs

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
    let made = Attachment {id = AttachmentId "a1", name = "notes.txt", mediaType = "text/plain", size = 5, source = SourceUrl (Url "https://example.org/notes.txt")}
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

  it "aborts a request whose wait is killed" $ runPage $ do
    serverStarts
    unsafeIOToPageM js_server_hold
    env <- unsafeIOToPageM (newHttpEnv browserTransport)
    waiting <- unsafeIOToPageM (forkIO (void (runHttpWiki env (getSpace (slugs ["team"])))))
    eventually (map (\r -> (r.url, r.aborted)) <$> asked `shouldReturn` [(team, False)])
    unsafeIOToPageM (killThread waiting)
    eventually (map (\r -> (r.url, r.aborted)) <$> asked `shouldReturn` [(team, True)])
    serverStops

  it "gives up on an answer that does not come in time, and aborts its request" $ runPage $ do
    serverStarts
    unsafeIOToPageM js_server_hold
    env <- unsafeIOToPageM (newHttpEnv (fetchTransport (const 300)))
    overHttp env (getSpace (slugs ["team"])) `shouldReturn` Left (Unreachable "no answer in 300 milliseconds")
    eventually (map (\r -> (r.url, r.aborted)) <$> asked `shouldReturn` [(team, True)])
    serverStops
  where
    team = links.spaces.atPath (slugs ["team"])

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

views :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
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
    -- Whom the tour mentions is asked once it is shown, and answered.
    find ui ".page-body a.mention" >>= (`shouldHaveText` "@editor")
    -- The list of the space's pages has no bodies: the page is asked for
    -- by itself, once.
    let pagesAsked = map (\r -> r.url) . filter (\r -> "/pages/at/" `T.isInfixOf` r.url) <$> asked
    pagesAsked >>= (`shouldSatisfy` ((== 1) . length))
    unmount ui
    serverStops

  -- The tab that showed a page without someone else's edit (WP5.14 of
  -- docs/PLAN.md): page content is cached only until the route changes,
  -- so a page shown again is fetched again.
  it "fetches a page shown again, and shows what someone else saved meanwhile" $ runPage $ do
    serverStarts
    serveDemo
    tourPage <- unsafeIOToPageM tourOfDocs
    ui <- startServer m tour
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")
    let tourAt = links.spaces.pageAt tourPage.space (slugs ["tour"])
        fetchesOf url = length . filter (\r -> r.method == "GET" && r.url == url) <$> asked
        listsAsked = length . filter (\r -> "/pages" `T.isSuffixOf` r.url) <$> asked
    fetchesOf tourAt `shouldReturn` 1
    lists <- listsAsked
    -- Another page of the space: fetched, the space's list kept.
    find ui ".wiki-sidebar .page-tree a[href$='#/s/docs/p/markdown-guide/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Markdown guide")
    -- Someone else saves the tour meanwhile, in another session. Nothing
    -- tells this tab: it no longer shows the tour.
    answerWith "GET" tourAt 200 tourPage {P.body = "# Tour\n\nSaved by someone else."}
    find ui ".wiki-sidebar .page-tree a[href$='#/s/docs/p/tour/']" >>= click
    eventually $ (find ui ".page-view" >>= textContent) >>= (`shouldSatisfy` T.isInfixOf "Saved by someone else.")
    fetchesOf tourAt `shouldReturn` 2
    listsAsked `shouldReturn` lists
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

  -- The race the server's smoke test met on a slow machine: what is typed
  -- just after Ctrl+S, while the save is on its way, is the author's like
  -- any other keystroke, and was refused while the editor was read-only.
  it "keeps what is typed while a save is on its way, unsaved, and keeps it as a draft" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM helloWorld
    let saveAt = "api/v1/pages/" <> hello.id.text
        draftAt = links.pages.saveDraft hello.id
        requestsTo url = filter (\r -> r.method == "PUT" && r.url == url) <$> asked
    answerWith "PUT" saveAt 200 hello
    answerWith "PUT" draftAt 200 Draft {page = hello.id, author = UserId "user-admin", title = hello.title, body = "", base = hello.updatedAt, savedAt = hello.updatedAt}
    ui <- startServer m (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    text <- editorText ui
    typeText text "One."
    unsafeIOToPageM (js_server_hold_at (toJSText "PUT") (toJSText saveAt))
    press "Control+s"
    eventually $ length <$> requestsTo saveAt `shouldReturn` 1
    typeText text " Two."
    unsafeIOToPageM js_server_release
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    saved <- requestsTo saveAt
    map (\r -> "One. Two." `T.isInfixOf` r.body) saved `shouldBe` [False]
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "One. Two.")
    -- Not saved: Cancel asks about it, and it is kept as a draft once the
    -- typing has stopped.
    _ <- find ui "button.editor-cancel"
    eventuallyWithin 6000 $ do
      drafts <- requestsTo draftAt
      map (\r -> "One. Two." `T.isInfixOf` r.body) drafts `shouldBe` [True]
    unmount ui
    serverStops

  it "loads a page's history and a version from the server, and restores it against the page's version" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM helloWorld
    let older = addUTCTime (negate 86400) hello.updatedAt
        ada = Just Author {id = UserId "user-admin", name = "Ada Admin"}
        current = VersionInfo {page = hello.id, updatedAt = hello.updatedAt, title = hello.title, author = ada, number = 2}
    answerWith "GET" (links.pages.versions hello.id Nothing Nothing) 200 [current, VersionInfo {page = hello.id, updatedAt = older, title = "Hello", author = Nothing, number = 1}]
    answerWith "GET" (links.pages.version hello.id (VersionTime older)) 200 Version {page = hello.id, updatedAt = older, title = "Hello", body = "# Hello\n", author = Nothing}
    answerWith "POST" (links.pages.restore hello.id (VersionTime older)) 200 hello
    ui <- startServer m (PageHistory (slugs ["blog"]) (slugs ["hello-world"]) (Just older) AgainstPrevious)
    find ui ".version-detail h2" >>= (`shouldHaveText` "Version 1")
    versions <- traverse textContent =<< findAll ui ".version-list li > a"
    versions `shouldBe` ["Version 2 (current)", "Version 1"]
    (find ui ".diff-added .diff-text" >>= textContent) `shouldReturn` "# Hello"
    fetched <- map (\r -> r.url) . filter (\r -> r.method == "GET") <$> asked
    filter (T.isInfixOf "/versions") fetched `shouldBe` [links.pages.versions hello.id Nothing Nothing, links.pages.version hello.id (VersionTime older)]
    find ui "button.restore" >>= click
    find ui ".restore-confirm button.primary" >>= click
    eventually $ do
      restores <- filter (\r -> r.method == "POST") <$> asked
      map (\r -> (r.url, Map.lookup "If-Match" r.headers)) restores
        `shouldBe` [(links.pages.restore hello.id (VersionTime older), Just "\"2026-09-01T12:00:00Z\"")]
    unmount ui
    serverStops

  it "aborts a view's load when the reader goes elsewhere before it has come" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM helloWorld
    let versions = links.pages.versions hello.id Nothing Nothing
    unsafeIOToPageM (js_server_hold_at (toJSText "GET") (toJSText versions))
    ui <- startServer m (PageHistory (slugs ["blog"]) (slugs ["hello-world"]) Nothing AgainstPrevious)
    eventually (map (\r -> r.aborted) . filter (\r -> r.url == versions) <$> asked `shouldReturn` [False])
    find ui ".all-spaces" >>= click
    find ui ".directory h1" >>= (`shouldHaveText` "Spaces")
    -- The history view went with its fiber, and the request with them.
    eventually (map (\r -> r.aborted) . filter (\r -> r.url == versions) <$> asked `shouldReturn` [True])
    unmount ui
    serverStops

  it "says that the wiki cannot be reached while the browser is offline" $ runPage $ do
    serverStarts
    serveDemo
    ui <- startServer m Home
    find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
    length <$> findAll ui ".offline-notice" `shouldReturn` 0
    browserGoes False
    find ui ".offline-notice" >>= (`shouldHaveText` "You are offline: the wiki cannot be reached until the connection is back.")
    browserGoes True
    eventually (length <$> findAll ui ".offline-notice" `shouldReturn` 0)
    unmount ui
    serverStops

  it "loads what it could not once the browser is back online" $ runPage $ do
    serverStarts
    serveDemo
    offline True
    ui <- startServer m (SpacePages (slugs ["docs"]))
    find ui ".wiki-content .error-unreachable" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "could not be reached")
    browserGoes False
    _ <- find ui ".offline-notice"
    offline False
    browserGoes True
    find ui ".space-view h1" >>= (`shouldHaveText` "Docs")
    length <$> findAll ui ".offline-notice" `shouldReturn` 0
    unmount ui
    serverStops

  it "says nothing of the network over the demo, which needs none" $ runPage $ do
    ui <- start m Nothing Home
    _ <- find ui ".wiki-sidebar"
    browserGoes False
    -- Heard (the shell would have rendered by now), and not shown.
    _ <- find ui ".wiki-footer"
    length <$> findAll ui ".offline-notice" `shouldReturn` 0
    browserGoes True
    unmount ui

  it "says when the server cannot be reached, and tries again when asked" $ runPage $ do
    serverStarts
    serveDemo
    unsafeIOToPageM (js_server_offline True)
    ui <- startServer m (SpacePages (slugs ["docs"]))
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
    tourId <- overHttp reading $ do
      _ <- session
      _ <- listSpaces
      docs <- getSpace (slugs ["docs"])
      fmap join . for (rightToMaybe docs) $ \s -> do
        _ <- listPages s.id
        -- And the tour's comments, which its page shows, whom they and
        -- the tour mention, whether the tour is watched, and the bell's
        -- notifications.
        page <- getPage s.id (slugs ["tour"])
        for_ page $ \p -> do
          threads <- fromRight [] <$> listThreads p.id
          _ <- mentionable (Body.unasked Body.noPeople (p.body : [c.body | t <- threads, c <- t.comments]))
          watching (WatchPage p.id)
        _ <- notifications
        pure ((\p -> p.id) <$> rightToMaybe page)
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
    -- The page shown from the first render listens for its comments (the
    -- first program, unmounted, stopped listening before).
    eventually $ lastMay <$> said `shouldReturn` (Subscribe <$> tourId)
    unmount ui
    unsafeIOToPageM (js_unembed (toJSText preloadId))
    serverStops
  where
    -- Every element but what is inside an island, which its library fills
    -- after the shell has adopted it.
    adoptable = "*:not(.wiki-math *, .wiki-mermaid *, .wiki-tikz *, .wiki-code *, .wiki-time *)"

-- | What the page has sent on the live channel, each message read.
said :: PageM s [ClientMessage]
said = do
  messages <- unsafeIOToPageM js_server_said >>= either (\e -> panic ("what was said: " <> toS e)) pure . eitherDecodeStrict' . encodeUtf8 . fromJSText
  pure (mapMaybe (decodeStrict' . encodeUtf8) (messages :: [Text]))

-- | The server says this on the live channel, for the other specs.
tellServer :: ServerMessage -> PageM s ()
tellServer = tell

-- | The server says this on the live channel.
tell :: ServerMessage -> PageM s ()
tell = unsafeIOToPageM . js_server_tell . toJSText . decodeUtf8 . toS . encode

-- | A page's comments over the server's backend: read with the page, a new
-- one sent, what another tab writes heard over the live channel, and, when
-- the channel's connection is cut, the channel opened again and the
-- comments taken from the answer to the subscription; and a comment made
-- between the page's preload and its subscription caught up with, without
-- a request.
comments :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
comments m = describe "a page's comments" $ do
  it "reads them with the page, sends a new one, hears another tab's, and catches up after a lost connection" $ runPage $ do
    serverStarts
    serveDemo
    hello <- unsafeIOToPageM $ do
      wiki <- newMemWiki (demoState demoNow)
      runMemWiki wiki $ do
        blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
        either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
    ui <- startServer m (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui "mark.comment-mark[data-thread='thread-hello-1']" >>= (`shouldHaveText` "a blog that is also a wiki")
    eventually $ said `shouldReturn` [Subscribe hello.id]
    -- A new comment about the page, sent to the server, shown as it answered.
    let ada = Author {id = UserId "user-admin", name = "Ada Admin"}
        comment' tid cid body = Comment {id = CommentId cid, thread = CommentThreadId tid, author = ada, body, createdAt = demoNow, editedAt = Nothing}
        made = Thread {id = CommentThreadId "thread-new", page = hello.id, anchor = Nothing, resolved = False, createdAt = demoNow, comments = [comment' "thread-new" "comment-new" "Sent."]}
    answerWith "POST" (links.comments hello.id).open 201 made
    text <- find ui ".page-comments .comment-new textarea"
    typeText text "Sent."
    clickButton ui ".page-comments .comment-new button" "Comment"
    find ui ".page-comments #comment-thread-thread-new .comment-body" >>= (`shouldHaveText` "Sent.")
    posted <- filter (\r -> r.method == "POST") <$> asked
    map (\r -> (r.url, eitherDecodeStrict' (encodeUtf8 r.body))) posted `shouldBe` [((links.comments hello.id).open, Right NewThread {anchor = Nothing, body = "Sent."})]
    -- Another tab replies: heard, and shown.
    tell (Event hello.id (CommentAdded (comment' "thread-hello-3" "comment-elsewhere" "From another tab.")))
    eventually $ (traverse textContent =<< findAll ui "#comment-thread-thread-hello-3 .comment-body") `shouldReturn` ["Welcome! Comments here are about the whole post; select some of its text to comment on that.", "Thanks, that works.", "From another tab."]
    -- The connection is cut: opened again after a pause, and subscribed
    -- again; the server's answer has the comments as they are now, which
    -- the page shows without reading them itself (were they read, the
    -- demo's three threads would come back).
    let threadsAt = (links.comments hello.id).list
        readsSoFar = length . filter (\r -> r.method == "GET" && r.url == threadsAt) <$> asked
    before <- readsSoFar
    unsafeIOToPageM js_server_hang_up
    eventually $ said `shouldReturn` [Subscribe hello.id, Subscribe hello.id]
    tell (Subscribed hello.id [made] [])
    eventually $ length <$> findAll ui ".page-comments .comment-thread" `shouldReturn` 1
    readsSoFar `shouldReturn` before
    length <$> findAll ui "mark.comment-mark" `shouldReturn` 0
    unmount ui
    serverStops

  it "catches up with a comment made between the page's preload and its subscription, asking nothing" $ runPage $ do
    -- What the server's render reads at the post: who is asking, the
    -- spaces, the blog and its pages, the post and its comments.
    serverStarts
    serveDemo
    reading <- unsafeIOToPageM (newHttpEnv browserTransport)
    (hello, preloaded) <- overHttp reading $ do
      _ <- session
      _ <- listSpaces
      blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
      _ <- listPages blog.id
      page <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
      threads <- either (panic . show) identity <$> listThreads page.id
      -- The bell's, and the page's "Watch" button's.
      _ <- notifications
      _ <- watching (WatchPage page.id)
      pure (page, threads)
    carried <- unsafeIOToPageM (cacheOf reading)
    serverStops
    -- A server that answers nothing from here on, and the page with what
    -- it carries.
    serverStarts
    unsafeIOToPageM (js_embed (toJSText preloadId) (toJSText (encodePreload carried)))
    env <- fromPage
    ui <- startServerOver m env (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui "mark.comment-mark[data-thread='thread-hello-1']" >>= (`shouldHaveText` "a blog that is also a wiki")
    eventually $ said `shouldReturn` [Subscribe hello.id]
    -- Someone commented after the page was read and before the tab
    -- subscribed: the answer has it, and the page shows it.
    let grace = Author {id = UserId "user-editor", name = "Grace Editor"}
        meanwhile =
          Thread
            { id = CommentThreadId "thread-meanwhile"
            , page = hello.id
            , anchor = Nothing
            , resolved = False
            , createdAt = demoNow
            , comments = [Comment {id = CommentId "comment-meanwhile", thread = CommentThreadId "thread-meanwhile", author = grace, body = "Made meanwhile.", createdAt = demoNow, editedAt = Nothing}]
            }
    tell (Subscribed hello.id (preloaded <> [meanwhile]) [])
    find ui ".page-comments #comment-thread-thread-meanwhile .comment-body" >>= (`shouldHaveText` "Made meanwhile.")
    find ui "mark.comment-mark[data-thread='thread-hello-1']" >>= (`shouldHaveText` "a blog that is also a wiki")
    asked `shouldReturn` []
    unmount ui
    unsafeIOToPageM (js_unembed (toJSText preloadId))
    serverStops

-- | Who is editing a page, and its saves, over the live channel (WP4.12 of
-- docs/PLAN.md): the page view names whoever edits the page and shows a
-- save at once, or offers it while the reader is busy with the page; the editor asks before it starts when someone else edits
-- the page, says it edits it once the author goes on, names the others,
-- says it stopped when it goes away, says it again on a new connection,
-- and says when someone else has saved the page meanwhile.
presence :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
presence m = describe "who is editing" $ do
  let edgar = Author {id = UserId "user-editor", name = "Edgar Editor"}
      rita = Author {id = UserId "user-reader", name = "Rita Reader"}
      blog = slugs ["blog"]
      helloAt = slugs ["hello-world"]
      demoHello = unsafeIOToPageM $ do
        wiki <- newMemWiki (demoState demoNow)
        runMemWiki wiki $ do
          s <- either (panic . show) identity <$> getSpace blog
          p <- either (panic . show) identity <$> getPage s.id helloAt
          ps <- either (panic . show) identity <$> listPages s.id
          pure (p, ps)
  it "names who edits the page shown, and shows a save of it at once" $ runPage $ do
    serverStarts
    serveDemo
    (hello, blogPages) <- demoHello
    ui <- startServer m (Page blog helloAt)
    _ <- find ui ".page-view .page-body"
    eventually $ said `shouldReturn` [Subscribe hello.id]
    length <$> findAll ui ".page-live" `shouldReturn` 0
    tell (Event hello.id (Editing [edgar]))
    find ui ".page-actions .page-editors" >>= (`shouldHaveText` "Edgar Editor is editing this page.")
    tell (Event hello.id (Editing [edgar, rita]))
    find ui ".page-actions .page-editors" >>= (`shouldHaveText` "Edgar Editor and Rita Reader are editing this page.")
    tell (Event hello.id (Editing []))
    eventually $ length <$> findAll ui ".page-live" `shouldReturn` 0
    -- Saved elsewhere: read again and shown, with no button to ask for it.
    let later = addUTCTime 60 hello.updatedAt
        saved = hello {P.body = "Saved in another tab.", P.updatedAt = later}
    answerWith "GET" (links.spaces.listPages hello.space) 200 [if p.id == hello.id then P.summaryOf saved else p | p <- blogPages]
    answerWith "GET" (links.spaces.pageAt hello.space helloAt) 200 saved
    tell (Event hello.id (PageChanged later))
    eventuallyWithin 5000 $ (find ui ".page-view" >>= textContent) >>= (`shouldSatisfy` T.isInfixOf "Saved in another tab.")
    length <$> findAll ui ".page-changed" `shouldReturn` 0
    -- The tab's own version, told again, is not read again.
    before <- length <$> asked
    tell (Event hello.id (PageChanged later))
    (find ui ".page-view" >>= textContent) >>= (`shouldSatisfy` T.isInfixOf "Saved in another tab.")
    length <$> asked `shouldReturn` before
    -- Saved again while the reader renames the page: offered, not shown,
    -- until asked for.
    clickButton ui ".page-actions button" "Rename"
    _ <- find ui ".page-view .inline-form"
    let again = addUTCTime 120 hello.updatedAt
        savedAgain = saved {P.body = "Saved once more.", P.updatedAt = again}
    answerWith "GET" (links.spaces.listPages hello.space) 200 [if p.id == hello.id then P.summaryOf savedAgain else p | p <- blogPages]
    answerWith "GET" (links.spaces.pageAt hello.space helloAt) 200 savedAgain
    tell (Event hello.id (PageChanged again))
    _ <- find ui ".page-actions .page-live .page-changed"
    (find ui ".page-view" >>= textContent) >>= (`shouldSatisfy` T.isInfixOf "Saved in another tab.")
    _ <- find ui ".page-view .inline-form"
    clickButton ui ".page-actions .page-live button" "Changed since: show the new version"
    eventuallyWithin 5000 $ (find ui ".page-view" >>= textContent) >>= (`shouldSatisfy` T.isInfixOf "Saved once more.")
    eventually $ length <$> findAll ui ".page-live" `shouldReturn` 0
    unmount ui
    serverStops

  it "asks before editing a page someone else edits, says it edits it once told to go on, and stops when it goes" $ runPage $ do
    serverStarts
    serveDemo
    (hello, _) <- demoHello
    ui <- startServer m (EditPage blog helloAt)
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Hello, world")
    eventually $ said `shouldReturn` [Subscribe hello.id]
    tell (Subscribed hello.id [] [edgar])
    find ui ".editor-presence-warning p" >>= (`shouldHaveText` "Edgar Editor is editing this page. Open the editor anyway?")
    -- Not said until the author goes on.
    said `shouldReturn` [Subscribe hello.id]
    clickButton ui ".editor-presence-warning button" "Edit anyway"
    eventually $ said `shouldReturn` [Subscribe hello.id, StartEditing hello.id]
    length <$> findAll ui ".editor-presence-warning" `shouldReturn` 0
    find ui ".editor-others" >>= (`shouldHaveText` "Edgar Editor is also editing this page.")
    tell (Event hello.id (Editing []))
    eventually $ length <$> findAll ui ".editor-others" `shouldReturn` 0
    -- A new connection is told again, after the subscription.
    unsafeIOToPageM js_server_hang_up
    eventually $ said `shouldReturn` [Subscribe hello.id, StartEditing hello.id, Subscribe hello.id, StartEditing hello.id]
    -- Saved by someone else meanwhile: said, and the work is left alone.
    text <- editorText ui
    typeText text "Mine."
    tell (Event hello.id (PageChanged (addUTCTime 60 hello.updatedAt)))
    _ <- find ui ".editor-changed"
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "Mine.")
    -- Leaving the editor: it stops editing, and stops listening.
    find ui ".wiki-sidebar .page-tree a[href$='#/s/blog/p/notes-on-haskell/']" >>= click
    find ui ".leave-confirm button.danger" >>= click
    eventually $ (\ms -> [msg | msg <- ms, msg `elem` [StopEditing hello.id, Events.Unsubscribe hello.id]]) <$> said `shouldReturn` [StopEditing hello.id, Events.Unsubscribe hello.id]
    unmount ui
    serverStops

  it "says at once that it edits a page nobody else edits" $ runPage $ do
    serverStarts
    serveDemo
    (hello, _) <- demoHello
    ui <- startServer m (EditPage blog helloAt)
    eventually $ said `shouldReturn` [Subscribe hello.id]
    tell (Subscribed hello.id [] [])
    eventually $ said `shouldReturn` [Subscribe hello.id, StartEditing hello.id]
    length <$> findAll ui ".editor-presence-warning" `shouldReturn` 0
    length <$> findAll ui ".editor-others" `shouldReturn` 0
    unmount ui
    eventually $ (StopEditing hello.id `elem`) <$> said `shouldReturn` True
    serverStops
