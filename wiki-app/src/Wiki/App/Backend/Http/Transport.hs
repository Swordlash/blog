-- | How the HTTP backend's requests reach the server: a 'Transport', and
-- the request it is given ('HttpRequest').
--
-- The backend's client is derived from the API's type with
-- servant-client-core ("Wiki.App.Backend.Http.Client"), which makes a
-- servant request for each call. A transport carries that request to the
-- server and brings back the server's response. There are three
-- transports: the browser's @fetch@ ('browserTransport'), the server's own
-- application called in the same process (@inProcess@ in @wiki-server@,
-- for the server's prerender and its tests), and transports the tests
-- write, which answer from a table.
--
-- The request a transport is given is servant's, with its body already
-- collected into bytes and its path as text, relative to the page's
-- @\<base href>@ ('requestUrl'). So every transport sends the same bytes,
-- and the tests can compare them.
module Wiki.App.Backend.Http.Transport
  ( -- * Requests
    HttpRequest
  , requestUrl
  , requestHeaderList

    -- * Transports
  , Transport (..)
  , browserTransport
  , fetchTransport
  , silentTransport

    -- * Time limits
  , timeLimit
  , requestTimeout
  , uploadTimeout

    -- * Failures
  , fetchFailure
  , noAnswerIn
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Halogen.Net.Fetch qualified as Fetch
import Network.HTTP.Media (mainType, renderHeader)
import Network.HTTP.Types (Header, http11, mkStatus, urlEncode)
import Protolude
import Servant.Client.Core (RequestF (..), Response, ResponseF (..))
import System.Timeout (timeout)

-- | 'HttpRequest' is a request as a transport sends it: servant's request,
-- with its body's bytes collected and its media type, and its path as
-- text, without a leading slash.
--
-- The path is relative, so that a wiki served below a path finds its API
-- below the same path: a browser resolves it against the page's
-- @\<base href>@. The query is still servant's list of items, each value
-- already encoded; 'requestUrl' joins the two.
type HttpRequest = RequestF ByteString Text

-- | The address of a request, relative to the page's base: its path, and
-- its query if it has one (@api\/v1\/search?q=two%20words&limit=50@).
--
-- A query's values come encoded from servant-client-core, and are written
-- as they are; a name is encoded here. An item without a value (a
-- @QueryFlag@) is written as its name alone. This is how servant-client
-- writes a query too.
requestUrl :: RequestF b Text -> Text
requestUrl r = r.requestPath <> query
  where
    items = toList r.requestQueryString
    query
      | null items = ""
      | otherwise = "?" <> T.intercalate "&" (map item items)
    item (name, value) = decodeUtf8 (urlEncode True name) <> maybe "" (("=" <>) . decodeUtf8) value

-- | Every header a request sends: its own (the API's request marker,
-- @If-Match@ and the like), then @Accept@ with the media types servant
-- accepts for the response, and @Content-Type@ with its body's media type.
requestHeaderList :: HttpRequest -> [Header]
requestHeaderList r =
  toList r.requestHeaders
    <> [("Accept", renderHeader (toList r.requestAccept)) | not (Seq.null r.requestAccept)]
    <> [("Content-Type", renderHeader mediaType) | Just (_, mediaType) <- [r.requestBody]]

-- | 'Transport' is how a request reaches the server: it sends the request,
-- and returns the server's response, or why no response came (the
-- network is down, the time limit passed). A response with an error
-- status is a response.
newtype Transport = Transport (HttpRequest -> IO (Either Text Response))

-- | How long a request waits for its whole response, in milliseconds,
-- before the wiki is taken to be unreachable: long enough for a slow
-- network and a large page, short enough that a reader is told rather than
-- left waiting.
requestTimeout :: Int
requestTimeout = 30_000

-- | How long an upload waits: an attachment of up to 50 MB goes up a slow
-- line in that time (about 140 KB a second).
uploadTimeout :: Int
uploadTimeout = 6 * 60_000

-- | How long a request may take, in milliseconds: 'uploadTimeout' for an
-- upload (a multipart form), 'requestTimeout' for anything else.
timeLimit :: HttpRequest -> Int
timeLimit r = case r.requestBody of
  Just (_, mediaType) | mainType mediaType == "multipart" -> uploadTimeout
  _ -> requestTimeout

-- | The browser's @fetch@, with 'timeLimit''s limits. Natively there is no
-- network, and every request fails, saying so.
browserTransport :: Transport
browserTransport = fetchTransport timeLimit

-- | The browser's @fetch@, through "Halogen.Net.Fetch", with a limit, in
-- milliseconds, on how long each request may take to complete.
--
-- The request is sent as the wiki's own: to its origin, with its cookies
-- (@credentials: same-origin@), and with the headers 'requestHeaderList'
-- gives it, including the API's request marker. A network failure, a
-- request the browser refused, and no complete response within the limit
-- all mean the same to the application: no response, with the reason
-- ('fetchFailure', 'noAnswerIn').
--
-- The request, and the wait for its body, run on the thread that calls
-- this, which is a component's worker thread. Killing that thread aborts
-- the request instead of leaving it to run unread. The driver kills it
-- when the component goes away (a navigation while a view loads) or when
-- the component's fiber is killed. The time limit works the same way:
-- 'timeout' kills the wait, and the kill aborts the request.
--
-- A response @fetch@ took from the browser's own HTTP cache would not come
-- from the server. So the API's responses say @Cache-Control: private,
-- no-cache@ (the server's @privately@): the browser asks the server every
-- time, and, since the responses carry no validator, for the whole
-- response.
fetchTransport :: (HttpRequest -> Int) -> Transport
fetchTransport limit = Transport $ \r -> do
  let within = limit r
  answered <- timeout (within * 1000) $ do
    Fetch.fetch (fetchRequest r) >>= \case
      Left e -> pure (Left e)
      Right response -> fmap (responseOf response) <$> Fetch.bytes response
  pure $ case answered of
    Nothing -> Left (noAnswerIn within)
    Just (Left e) -> Left (fetchFailure e)
    Just (Right response) -> Right response

-- | The request as @fetch@ is given it: the browser's defaults (CORS mode,
-- on a same-origin address), except that the wiki's cookies are sent with
-- it.
fetchRequest :: HttpRequest -> Fetch.Request
fetchRequest r =
  (Fetch.request method (requestUrl r))
    { Fetch.headers = [(decodeUtf8 (CI.original name), decodeUtf8 value) | (name, value) <- requestHeaderList r]
    , Fetch.body = Fetch.BytesBody . fst <$> r.requestBody
    , Fetch.credentials = Fetch.SameOriginCredentials
    }
  where
    method = case r.requestMethod of
      "GET" -> Fetch.GET
      "HEAD" -> Fetch.HEAD
      "POST" -> Fetch.POST
      "PUT" -> Fetch.PUT
      "PATCH" -> Fetch.PATCH
      "DELETE" -> Fetch.DELETE
      "OPTIONS" -> Fetch.OPTIONS
      other -> Fetch.OtherMethod (decodeUtf8 other)

-- | The response @fetch@ gave, with its body, as servant reads one. The
-- headers' names are in lower case, as the browser gives them; servant
-- looks a header up without regard to case.
responseOf :: Fetch.Response -> ByteString -> Response
responseOf response body =
  Response
    { responseStatusCode = mkStatus response.status (encodeUtf8 response.statusText)
    , responseHeaders = Seq.fromList [(CI.mk (encodeUtf8 name), encodeUtf8 value) | (name, value) <- response.headers]
    , responseHttpVersion = http11
    , responseBody = BSL.fromStrict body
    }

-- | The reason a request got no response, as the application shows it
-- ('Wiki.App.Backend.Unreachable'). @fetch@ rejects with a @TypeError@
-- when the network or the server is down, or when the browser refused the
-- request (which this application's requests never give it cause to do).
fetchFailure :: Fetch.JSError -> Text
fetchFailure e = case e.name of
  "TypeError" -> "the network or the server is down"
  "NotInBrowserError" -> "there is no network natively"
  "AbortError" -> "the request was cancelled"
  _ | T.null e.message -> e.name
  _ -> e.message

-- | The reason given when no complete response came within a limit, in
-- milliseconds.
noAnswerIn :: Int -> Text
noAnswerIn ms
  | ms `mod` 1000 == 0 = "no answer in " <> show (ms `div` 1000) <> " seconds"
  | otherwise = "no answer in " <> show ms <> " milliseconds"

-- | A transport whose requests never get a response. A page prerendered
-- before the program starts shows the application before anything has
-- loaded, and the requests it makes are cancelled with it.
silentTransport :: Transport
silentTransport = Transport (const (forever (threadDelay maxBound)))
