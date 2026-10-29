-- | Helpers for transports a test writes ("Wiki.App.Backend.Http.Transport"):
-- the parts of a request a test compares, and responses as the server
-- writes them.
module Test.Scripted
  ( -- * Requests
    methodOf
  , bodyOf
  , headersOf
  , formOf

    -- * Responses
  , jsonResponse
  , responseWith
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Network.HTTP.Media (parameters, renderHeader)
import Network.HTTP.Types (Header, http11, mkStatus)
import Protolude
import Servant.Client.Core (RequestF (..), Response, ResponseF (..))
import Wiki.App.Backend.Http (HttpRequest, requestHeaderList)

-- | A request's method, as text.
methodOf :: HttpRequest -> Text
methodOf r = decodeUtf8 r.requestMethod

-- | A request's body: its media type, as its @Content-Type@ says it, and
-- its bytes. Nothing for a request without one.
bodyOf :: HttpRequest -> Maybe (Text, ByteString)
bodyOf r = (\(bytes, mediaType) -> (decodeUtf8 (renderHeader mediaType), bytes)) <$> r.requestBody

-- | Every header a request sends, by name and value, in order.
headersOf :: HttpRequest -> [(Text, Text)]
headersOf r = [(decodeUtf8 (CI.original name), decodeUtf8 value) | (name, value) <- requestHeaderList r]

-- | A multipart form's boundary and bytes, for a request that sends one.
formOf :: HttpRequest -> Maybe (ByteString, ByteString)
formOf r = do
  (bytes, mediaType) <- r.requestBody
  boundary <- Map.lookup "boundary" (parameters mediaType)
  pure (CI.original boundary, bytes)

-- | A response with this status and this JSON as its body, as the API
-- writes one.
jsonResponse :: Int -> BSL.ByteString -> Response
jsonResponse status = responseWith status [("Content-Type", "application/json;charset=utf-8")]

-- | A response with this status, these headers and this body.
responseWith :: Int -> [Header] -> BSL.ByteString -> Response
responseWith status headers body =
  Response
    { responseStatusCode = mkStatus status ""
    , responseHeaders = Seq.fromList headers
    , responseHttpVersion = http11
    , responseBody = body
    }
