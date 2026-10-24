-- | Servers for the tests: each started on free ports of 127.0.0.1, over a
-- data directory and a small built application made afresh in a temporary
-- directory, and driven over HTTP as a browser would.
module Test.Server.Fixture
  ( -- * Servers
    Running (..)
  , withRunning
  , withRunningAs
  , trusted
  , site

    -- * Requests
  , Reply (..)
  , getUrl
  , getUrlWith
  , getRawPath
  , send
  , sendJson
  , multipart
  , header
  , json
  , jsonAs
  , ok200
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, modifyIORef', newIORef)
import Data.List (lookup)
import Network.HTTP.Client (Manager, RequestBody (..), decompress, defaultManagerSettings, httpLbs, managerResponseTimeout, method, newManager, parseRequest, path, redirectCount, requestBody, requestHeaders, responseBody, responseHeaders, responseStatus, responseTimeoutMicro)
import Network.HTTP.Types (Header, Method, hContentType, methodGet, statusCode)
import Network.Socket (SockAddr (..))
import Protolude
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit (assertFailure)
import Wiki.Server (Server (..), withServer)
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Options (Listen (..), ServeOptions (..), defaultServeOptions)

-- | A server being driven by a test.
data Running = Running
  { public :: Text
  -- ^ The public listener's root, @http:\/\/127.0.0.1:\<port>@.
  , admin :: Text
  -- ^ The admin listener's root.
  , dataDir :: FilePath
  , staticDir :: FilePath
  , logged :: IORef [Text]
  -- ^ What it logged, the latest first.
  , manager :: Manager
  }

-- | The files of a small built application, by path: what the tests of
-- static serving ask for.
site :: [(FilePath, ByteString)]
site =
  [ ("index.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>front</title></head><body>front</body></html>")
  , ("404.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>missing</title></head><body>missing</body></html>")
  , ("s/blog/index.html", "<!doctype html><html><head>\n    <base href=\"/\"><title>blog</title></head><body>blog</body></html>")
  , ("app.wasm", "\0asm\1\0\0\0")
  , ("app.wasm.br", "brotli bytes")
  , ("index.js", "console.log('index');")
  , ("index.js.gz", "gzip bytes")
  , ("tikzjax/core.dump.gz", "a dump, compressed")
  , ("tikzjax/core.dump.gz.br", "not to be used")
  , ("style.css", "body {}")
  ]

-- | A server with the default options but for its addresses (free ports
-- of 127.0.0.1) and directories, run while the test runs.
withRunning :: (Running -> IO a) -> IO a
withRunning = withRunningAs identity

-- | A server with its options changed as given.
withRunningAs :: (ServeOptions -> ServeOptions) -> (Running -> IO a) -> IO a
withRunningAs change test =
  withSystemTempDirectory "wiki-server-http" $ \dir -> do
    let dataDir = dir </> "data"
        staticDir = dir </> "app"
    for_ site $ \(path, bytes) -> do
      createDirectoryIfMissing True (takeDirectory (staticDir </> path))
      BS.writeFile (staticDir </> path) bytes
    logged <- newIORef []
    manager <- newManager defaultManagerSettings {managerResponseTimeout = responseTimeoutMicro 60000000}
    let options =
          change
            (defaultServeOptions dataDir)
              { listen = Listen "127.0.0.1" 0
              , adminListen = Just (Listen "127.0.0.1" 0)
              , staticDir = Just staticDir
              }
    withServer (silentLogger (\line -> modifyIORef' logged (line :))) options $ \server ->
      test
        Running
          { public = root server.publicAddress
          , admin = maybe "" root server.adminAddress
          , dataDir
          , staticDir
          , logged
          , manager
          }
  where
    root = \case
      SockAddrInet port _ -> "http://127.0.0.1:" <> show port
      other -> panic ("not an IPv4 address: " <> show other)

-- | The options of a server on a trusted network.
trusted :: ServeOptions -> ServeOptions
trusted o = o {trustNetwork = True}

-- | A response, as the tests look at it.
data Reply = Reply
  { status :: Int
  , headers :: [Header]
  , body :: LByteString
  }
  deriving stock (Show)

-- | A request with a method, headers and a body, to a URL.
send :: Running -> Method -> Text -> [Header] -> LByteString -> IO Reply
send r m url hs b = do
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
