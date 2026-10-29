-- | Servers for the tests: each started on free ports of 127.0.0.1, over a
-- data directory and a small built application made afresh in a temporary
-- directory, and driven over HTTP as a browser would.
module Test.Server.Fixture
  ( -- * Servers
    Running (..)
  , withRunning
  , withRunningAs
  , withDemoRunning
  , withDemoRestarted
  , site
  , template
  , serverInfoOn

    -- * Requests
  , Reply (..)
  , getUrl
  , getUrlWith
  , getRawPath
  , send
  , sendBare
  , sendJson
  , multipart
  , header
  , json
  , jsonAs
  , ok200

    -- * Sessions
  , cookie
  , setCookie
  , givePassword
  , signInAs
  , withAdminSession

    -- * The server's settings
  , setServer
  , serverAs
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, modifyIORef', newIORef)
import Data.List (lookup)
import Data.Text qualified as T
import Network.HTTP.Client (Manager, RequestBody (..), decompress, defaultManagerSettings, httpLbs, managerResponseTimeout, method, newManager, parseRequest, path, redirectCount, requestBody, requestHeaders, responseBody, responseHeaders, responseStatus, responseTimeoutMicro)
import Network.HTTP.Types (Header, Method, hContentType, methodGet, statusCode)
import Network.Socket (SockAddr (..))
import Protolude
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing (..), choiceOf, withPlace)
import Test.HUnit (assertFailure)
import Test.Storage.Fixture (demoArchive)
import Wiki.Api (AdminApi (..), WikiApi (..), requestMarker)
import Wiki.Api.Account (Account (..), Credentials (..), NewPassword (..))
import Wiki.Api.Info (Capabilities (..), SearchKind (..), ServerInfo (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (ServerSettings, ServerSettingsChange)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Password (..), Standing (..))
import Wiki.Server (Server (..), withServerUsing)
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Mail (Message, SendMail, Smtp (..), smtpSend)
import Wiki.Server.Options (Listen (..), ServeOptions (..), defaultServeOptions)
import Wiki.Server.Storage (Place (..), defaultConfig, importArchive, withStorage)

-- | A server being driven by a test.
data Running = Running
  { public :: Text
  -- ^ The public listener's root, @http:\/\/127.0.0.1:\<port>@.
  , admin :: Text
  -- ^ The admin listener's root.
  , dataDir :: FilePath
  , place :: Place
  -- ^ The data directory and the database the server keeps the wiki in.
  , staticDir :: FilePath
  , logged :: IORef [Text]
  -- ^ What it logged, the latest first.
  , manager :: Manager
  , outbox :: IORef [Message]
  -- ^ What it mailed, the latest first: a server whose settings name a
  -- mail server mails here instead ('testMail'), and one whose host is
  -- @unreachable.test@ fails to.
  }

-- | What a server of the tests says of itself ("Wiki.Api.Info"), on a
-- database of this backing: its capabilities name the database, so a test
-- of a server on PostgreSQL that ran on SQLite fails here.
serverInfoOn :: Backing -> ServerInfo
serverInfoOn backing = ServerInfo {name = "Wiki", apiVersion = 1, capabilities}
  where
    capabilities = case backing of
      OnSqlite -> Capabilities {database = "sqlite", search = FoldedText}
      _ -> Capabilities {database = "postgres", search = FullText}

-- | The files of a small built application, by path: what the tests of
-- static serving ask for.
site :: [(FilePath, ByteString)]
site =
  [ ("index.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>front</title></head><body>front</body></html>")
  , ("404.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>missing</title></head><body>missing</body></html>")
  , ("s/blog/index.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>blog</title></head><body>blog</body></html>")
  , -- A page with its Content Security Policy in a meta element, as
    -- web/index.html has it.
    ("policed/index.html", "<!doctype html><html><head>\n    <base href=\"/\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\"><title>policed</title></head><body>policed</body></html>")
  , ("app.wasm", "\0asm\1\0\0\0")
  , ("app.wasm.br", "brotli bytes")
  , ("index.js", "console.log('index');")
  , ("index.js.gz", "gzip bytes")
  , ("downloads/archive.gz", "an archive, compressed")
  , ("downloads/archive.gz.br", "not to be used")
  , ("tikzjax/core.dump.bin", "a dump, as a zlib stream")
  , ("style.css", "body {}")
  , ("sw.js", "self.addEventListener(\"fetch\", () => {});")
  , ("manifest.webmanifest", "{\"name\": \"Wiki\", \"start_url\": \"./\"}")
  , ("offline.html", "<!doctype html><html><head><title>offline</title></head><body>offline</body></html>")
  ]

-- | The template a server's build has for the pages the server renders
-- (@wiki-app-prerender --server@ writes it from @web\/index.html@): the
-- page with its mount point empty, saying the program is the server's.
template :: ByteString
template =
  encodeUtf8 . T.unlines $
    [ "<!doctype html>"
    , "<html lang=\"en\">"
    , "  <head>"
    , "    <base href=\"/\">"
    , "    <meta charset=\"utf-8\">"
    , "    <meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'\">"
    , "    <meta name=\"wiki-backend\" content=\"server\">"
    , "    <title>Wiki</title>"
    , "  </head>"
    , "  <body>"
    , "    <div id=\"app\"></div>"
    , "    <script type=\"module\" src=\"./index.js\"></script>"
    , "  </body>"
    , "</html>"
    ]

-- | A server whose build is the server's (its files, and 'template'), over
-- the demo's wiki, with its options changed as given.
withDemoRunning :: Backing -> (ServeOptions -> ServeOptions) -> (Running -> IO a) -> IO a
withDemoRunning backing change = withRunningPrepared backing change demoPrepared

-- | The directories of a server whose build is the server's, over the
-- demo's wiki.
demoPrepared :: Place -> FilePath -> IO ()
demoPrepared at staticDir = do
  BS.writeFile (staticDir </> "template.html") template
  withStorage defaultConfig at (\st -> importArchive st demoArchive) >>= either (\e -> assertFailure ("the demo does not import: " <> toS e)) pure

-- | A server with the default options but for its addresses (free ports
-- of 127.0.0.1), its directories and its database, run while the test
-- runs.
withRunning :: Backing -> (Running -> IO a) -> IO a
withRunning backing = withRunningAs backing identity

-- | A server with its options changed as given.
withRunningAs :: Backing -> (ServeOptions -> ServeOptions) -> (Running -> IO a) -> IO a
withRunningAs backing change = withRunningPrepared backing change (\_ _ -> pass)

-- | A server with its options changed as given, and its data and static
-- directories prepared as given before it starts.
withRunningPrepared :: Backing -> (ServeOptions -> ServeOptions) -> (Place -> FilePath -> IO ()) -> (Running -> IO a) -> IO a
withRunningPrepared backing change prepare test =
  withSystemTempDirectory "wiki-server-http" $ \dir -> withPlace backing (dir </> "data") $ \at -> do
    staticDir <- prepared dir at prepare
    serveIn change at staticDir test

-- | A server over the demo's wiki, stopped once the first action is done,
-- and started again over the same directories for the second, which is
-- given what the first gave back: a restart. (Two servers cannot run on
-- one data directory at once: the second is refused.)
withDemoRestarted :: Backing -> (Running -> IO x) -> (x -> Running -> IO a) -> IO a
withDemoRestarted backing before after =
  withSystemTempDirectory "wiki-server-http" $ \dir -> withPlace backing (dir </> "data") $ \at -> do
    staticDir <- prepared dir at demoPrepared
    x <- serveIn identity at staticDir before
    serveIn identity at staticDir (after x)

-- | The static directory of a test's server in a directory, with the
-- data directory and the database prepared as given.
prepared :: FilePath -> Place -> (Place -> FilePath -> IO ()) -> IO FilePath
prepared dir at prepare = do
  let staticDir = dir </> "app"
  for_ site $ \(path, bytes) -> do
    createDirectoryIfMissing True (takeDirectory (staticDir </> path))
    BS.writeFile (staticDir </> path) bytes
  prepare at staticDir
  pure staticDir

-- | A server over this place and static directory, with its options
-- changed as given, while the test runs. The server's database is the
-- place's: a test of a server on PostgreSQL is a test of PostgreSQL.
serveIn :: (ServeOptions -> ServeOptions) -> Place -> FilePath -> (Running -> IO a) -> IO a
serveIn change at staticDir test = do
  let dataDir = at.dataDir
  logged <- newIORef []
  outbox <- newIORef []
  manager <- newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 60000000}
  let options =
        change
          (defaultServeOptions dataDir)
            { database = choiceOf at.database
            , pgPrograms = at.programs
            , listen = Listen "127.0.0.1" 0
            , adminListen = Just (Listen "127.0.0.1" 0)
            , staticDir = Just staticDir
            , -- Most tests start from a wiki with nothing in it; those of
              -- the guide turn it on ("Test.Server.Guide").
              guide = False
            }
  withServerUsing (silentLogger (\line -> modifyIORef' logged (line :))) options (testMail outbox) $ \server ->
    test
      Running
        { public = root server.publicAddress
        , admin = maybe "" root server.adminAddress
        , dataDir
        , place = at
        , staticDir
        , logged
        , manager
        , outbox
        }
  where
    root = \case
      SockAddrInet port _ -> "http://127.0.0.1:" <> show port
      other -> panic ("not an IPv4 address: " <> show other)

-- | How the test servers send mail: into the outbox, as a mail server
-- would take it; not at all to @unreachable.test@; and for real, over
-- SMTP, to a mail server on 127.0.0.1, which is a test's own
-- ("Test.Server.Mail").
testMail :: IORef [Message] -> SendMail
testMail outbox smtp password m
  | smtp.host == "unreachable.test" = pure (Left "The mail server at unreachable.test:587 did not answer in time.")
  | smtp.host == "127.0.0.1" = smtpSend smtp password m
  | otherwise = Right <$> modifyIORef' outbox (m :)

-- | A response, as the tests look at it.
data Reply = Reply
  { status :: Int
  , headers :: [Header]
  , body :: LByteString
  }
  deriving stock (Show)

-- | A request with a method, headers and a body, to a URL, as the
-- application makes it: with the header that says so ('requestMarker').
send :: Running -> Method -> Text -> [Header] -> LByteString -> IO Reply
send r m url hs = sendBare r m url (marker : hs)
  where
    marker = (CI.mk (encodeUtf8 (fst requestMarker)), encodeUtf8 (snd requestMarker))

-- | A request with exactly these headers: one a page of another site
-- could make a browser send.
sendBare :: Running -> Method -> Text -> [Header] -> LByteString -> IO Reply
sendBare r m url hs b = do
  initial <- parseRequest (toS url)
  response <- httpLbs initial {method = m, requestHeaders = hs, requestBody = RequestBodyLBS b, redirectCount = 0, decompress = const False} r.manager
  pure Reply {status = statusCode (responseStatus response), headers = responseHeaders response, body = responseBody response}

getUrl :: Running -> Text -> IO Reply
getUrl r url = send r methodGet url [] ""

-- | A GET of a path exactly as written, which need not be one a URL may
-- have: what a client that does not check its addresses sends.
getRawPath :: Running -> Text -> ByteString -> IO Reply
getRawPath r root raw = do
  initial <- parseRequest (toS root)
  response <- httpLbs initial {path = raw, redirectCount = 0, decompress = const False} r.manager
  pure Reply {status = statusCode (responseStatus response), headers = responseHeaders response, body = responseBody response}

getUrlWith :: Running -> Text -> [Header] -> IO Reply
getUrlWith r url hs = send r methodGet url hs ""

-- | A request with a JSON body.
sendJson :: (ToJSON a) => Running -> Method -> Text -> a -> IO Reply
sendJson r m url value = send r m url [(hContentType, "application/json")] (encode value)

-- | A multipart form, as a browser's FormData sends it: text parts, then
-- file parts (part name, file name, media type, bytes).
multipart :: Running -> Text -> [(Text, Text)] -> [(Text, Text, Text, LByteString)] -> IO Reply
multipart r url inputs files =
  send r "POST" url [(hContentType, "multipart/form-data; boundary=" <> boundary)] formBody
  where
    boundary = "wiki-server-test-boundary"
    line t = BSL.fromStrict (encodeUtf8 t) <> "\r\n"
    part disposition ctype bytes =
      "--"
        <> BSL.fromStrict boundary
        <> "\r\n"
        <> line ("Content-Disposition: form-data; " <> disposition)
        <> maybe "" (\c -> line ("Content-Type: " <> c)) ctype
        <> "\r\n"
        <> bytes
        <> "\r\n"
    formBody =
      mconcat [part ("name=\"" <> n <> "\"") Nothing (BSL.fromStrict (encodeUtf8 v)) | (n, v) <- inputs]
        <> mconcat [part ("name=\"" <> n <> "\"; filename=\"" <> f <> "\"") (Just c) bytes | (n, f, c, bytes) <- files]
        <> "--"
        <> BSL.fromStrict boundary
        <> "--\r\n"

-- | A header of a response.
header :: Text -> Reply -> Maybe ByteString
header name reply = lookup (CI.mk (encodeUtf8 name)) reply.headers

-- | The body as JSON of the type it should be, or a failed test that shows
-- the response.
json :: (HasCallStack, FromJSON a) => Reply -> IO a
json reply = either (\e -> assertFailure ("not the JSON expected (" <> e <> "): " <> show reply)) pure (eitherDecode reply.body)

-- | The body as JSON, from a response with that status.
jsonAs :: (HasCallStack, FromJSON a) => Int -> Reply -> IO a
jsonAs code reply = do
  when (reply.status /= code) $ assertFailure ("expected status " <> show code <> ", got " <> show reply)
  json reply

-- | The body of a 200, as JSON.
ok200 :: (HasCallStack, FromJSON a) => IO Reply -> IO a
ok200 act = act >>= jsonAs 200

--------------------------------------------------------------------------------
-- Sessions

-- | A session's cookie, as a browser sends it back.
cookie :: Text -> Header
cookie token = ("Cookie", "theme=dark; wiki_session=" <> encodeUtf8 token)

-- | The session id a response's @Set-Cookie@ gives, and the attributes it
-- gives it with.
setCookie :: Reply -> Maybe (Text, [Text])
setCookie reply = case T.splitOn "; " . decodeUtf8 <$> header "Set-Cookie" reply of
  Just (first' : attributes) | Just value <- T.stripPrefix "wiki_session=" first' -> Just (value, attributes)
  _ -> Nothing

-- | Give a user a password, as the operator on the admin listener.
givePassword :: (HasCallStack) => Running -> Text -> Text -> IO ()
givePassword r uid password = do
  reply <- sendJson r "PUT" (r.admin <> "/admin/" <> links.admin.setPassword (UserId uid)) NewPassword {password = Password password}
  account :: Account <- jsonAs 200 reply
  unless account.hasPassword $ assertFailure ("no password for " <> toS uid)

-- | Sign in on the public listener: the session id its cookie carries.
signInAs :: (HasCallStack) => Running -> Text -> Text -> IO Text
signInAs r login password = do
  reply <- sendJson r "POST" (r.public <> "/" <> links.signIn) Credentials {login, password = Password password}
  info :: SessionInfo <- jsonAs 200 reply
  unless (info.standing == SignedIn) $ assertFailure ("not signed in: " <> show info)
  maybe (assertFailure ("no session cookie: " <> show reply)) (pure . fst) (setCookie reply)

-- | A server over the demo's wiki with its options changed as given, and
-- the cookie of a session of the demo's administrator (@admin@, who holds
-- the global administer) signed in on the public listener: who the
-- public listener serves the administration to.
withAdminSession :: Backing -> (ServeOptions -> ServeOptions) -> (Running -> Header -> IO a) -> IO a
withAdminSession backing change test = withDemoRunning backing change $ \r -> do
  givePassword r "user-admin" "admin's password"
  token <- signInAs r "admin" "admin's password"
  test r (cookie token)

--------------------------------------------------------------------------------
-- The server's settings

-- | Set the server's settings, as the operator on the admin listener:
-- what they then are.
setServer :: (HasCallStack) => Running -> ServerSettingsChange -> IO ServerSettings
setServer r change = sendJson r "PUT" (r.admin <> "/admin/" <> links.admin.setServer) change >>= jsonAs 200

-- | The server's settings, as the operator reads them.
serverAs :: (HasCallStack) => Running -> IO ServerSettings
serverAs r = getUrl r (r.admin <> "/admin/" <> links.admin.server) >>= jsonAs 200
