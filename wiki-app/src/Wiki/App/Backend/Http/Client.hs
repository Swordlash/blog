-- | The HTTP backend's client of the wiki's API: the parts of it that do
-- not depend on the backend's state.
--
-- The client is derived from the API's type ("Wiki.Api") with
-- servant-client-core: each endpoint of the API is a function, made by
-- servant, that builds the request, and checks and decodes the response.
-- So the application cannot send a request the API does not declare, and
-- an endpoint that changes in @wiki-api@ changes its client when this
-- package is compiled. The backend ("Wiki.App.Backend.Http") runs these
-- functions in its own monad, whose @RunClient@ instance hands each
-- request to a transport ("Wiki.App.Backend.Http.Transport").
--
-- This module has what servant leaves to the client's user: the
-- request's last touches before a transport sends it ('prepare'), the
-- boundary of a multipart form ('withBoundary'), and how a response is read
-- into the form 'Wiki.App.Backend.MonadWiki' returns ('answer'). A 2xx
-- with the body the API declares is the value. A refusal becomes the
-- 'WikiError' of the same name, read from its 'ApiError' body or, without
-- one, from its status alone ('errorForStatus'). Anything else becomes
-- 'Unreachable': no response, a 5xx, or a 2xx whose body is not what the
-- API says, which a proxy or a captive portal can return.
module Wiki.App.Backend.Http.Client
  ( -- * The API the client is derived from
    ClientApi

    -- * Requests
  , prepare
  , withBoundary
  , endpointUrl

    -- * Answers
  , answer
  , refusal
  , failureOf
  , fromApiError
  , noResponse
  , NoResponse (..)

    -- * Sessions
  , sessionInfo
  , fromSessionInfo
  )
where

import Control.Monad.Free (Free (..))
import Data.Aeson (eitherDecode)
import Data.ByteString.Builder (Builder, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Network.HTTP.Types (statusCode)
import Protolude
import Servant.Client.Core (ClientError (..), Request, RequestBody (..), RequestF (..), Response, ResponseF (..), clientIn)
import Servant.Client.Free (ClientF (..))
import Servant.Client.Generic (AsClientT)
import Servant.Multipart.API (Mem)
import Servant.Multipart.Client (genBoundary)
import Servant.Types.SourceT (runSourceT)
import Wiki.Api (ApiWith, WikiApi, requestMarker)
import Wiki.Api.Error (ApiError, errorForStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Backend.Http.Transport (HttpRequest, requestUrl)

-- | 'ClientApi' is the API as the browser's client sees it: the server's
-- API, with an upload's bytes in memory rather than in a file on disk
-- ("Wiki.Api", 'ApiWith').
type ClientApi = ApiWith Mem

-- | The request servant made, as a transport sends it ('HttpRequest'): its
-- body collected into bytes, its path made relative to the page's base,
-- and the API's request marker added.
--
-- Every request carries 'requestMarker', the header that tells the server
-- the request comes from this application, and not from another site's
-- page making the browser send it. The server refuses a write without it.
-- It is added here rather than by a transport, so that every transport
-- sends it.
--
-- A body servant streams (a multipart form) is read to its end here. The
-- forms the application sends are in memory already, so this cannot fail
-- in practice; if it did, the request would fail as one that got no
-- response.
prepare :: Request -> IO HttpRequest
prepare r = do
  body <- for r.requestBody $ \(contents, mediaType) -> (,mediaType) <$> bytesOf contents
  pure
    Request
      { requestPath = relativePath r.requestPath
      , requestQueryString = r.requestQueryString
      , requestBody = body
      , requestAccept = r.requestAccept
      , requestHeaders = r.requestHeaders Seq.|> bimap (CI.mk . encodeUtf8) encodeUtf8 requestMarker
      , requestHttpVersion = r.requestHttpVersion
      , requestMethod = r.requestMethod
      }
  where
    bytesOf = \case
      RequestBodyLBS bytes -> pure (BSL.toStrict bytes)
      RequestBodyBS bytes -> pure bytes
      RequestBodySource source ->
        runExceptT (runSourceT source) >>= \case
          Left why -> throwIO (noResponse ("its body could not be written: " <> toS why))
          Right chunks -> pure (BSL.toStrict (mconcat chunks))

-- | A request's path as servant builds it, without the leading slash:
-- relative to the page's base. servant starts every path with a slash
-- (@\/api\/v1\/…@, each segment added as @\/segment@); a path without one
-- is kept as it is.
relativePath :: Builder -> Text
relativePath builder = fromMaybe path (T.stripPrefix "/" path)
  where
    path = decodeUtf8 (BSL.toStrict (toLazyByteString builder))

-- | The address a call of the client asks for, relative to the page's
-- base, worked out without sending anything: for a test that answers
-- requests by their address, and must name the address as the client
-- writes it. servant writes some addresses differently from
-- "Wiki.Api.Links" (a list in the query, a colon in a path), and the
-- server reads both.
--
-- Every endpoint's client starts by sending its request. A call that does
-- not (one that fails before it sends anything, or sends nothing) has no
-- address, and is a mistake in the test: this stops the test with the
-- reason, rather than give it an address no request has.
endpointUrl :: (WikiApi Mem (AsClientT (Free ClientF)) -> Free ClientF a) -> Text
endpointUrl endpoint = case endpoint (clientIn (Proxy @ClientApi) (Proxy @(Free ClientF))) of
  Free (RunRequest r _) -> requestUrl (relativePath <$> r)
  Free (Throw e) -> panic ("endpointUrl: the call fails before it sends a request: " <> show e)
  Pure _ -> panic "endpointUrl: the call sends no request"

-- | Call an endpoint that takes a multipart form, with a new boundary.
-- servant-multipart-client wants the boundary with the form, and does not
-- look at the form's bytes to choose it. It is random, 55 letters and
-- digits: long enough that a file is vanishingly unlikely to contain it.
withBoundary :: (MonadIO m) => ((BSL.ByteString, form) -> m a) -> form -> m a
withBoundary endpoint form = liftIO genBoundary >>= \boundary -> endpoint (boundary, form)

-- | 'NoResponse' is why a request got no response at all, in the words the
-- application shows ('Wiki.App.Backend.Unreachable'). It travels inside
-- servant's 'ConnectionError'.
newtype NoResponse = NoResponse Text
  deriving stock (Show)

instance Exception NoResponse

-- | The client's error for a request that got no response, with the
-- reason.
noResponse :: Text -> ClientError
noResponse = ConnectionError . toException . NoResponse

-- | Read the result of a call into the form 'Wiki.App.Backend.MonadWiki'
-- returns: the value, or the error.
answer :: Either ClientError a -> Either WikiError a
answer = first failure

-- | The 'WikiError' a client's error means.
failure :: ClientError -> WikiError
failure = \case
  FailureResponse _ r -> failureOf r
  DecodeFailure why _ -> unreadable why
  UnsupportedContentType mediaType _ -> unreadable ("it was " <> show mediaType)
  InvalidContentTypeHeader _ -> unreadable "its media type was not one"
  ConnectionError e -> Unreachable (maybe (show e) (\(NoResponse why) -> why) (fromException e))
  where
    unreadable why = Unreachable ("its answer was not one the wiki can read: " <> why)

-- | The response of a call the server answered with a status the API does
-- not declare for it: a refusal, or a 304 to a conditional request.
refusal :: Either ClientError a -> Maybe Response
refusal = \case
  Left (FailureResponse _ r) -> Just r
  _ -> Nothing

-- | The error a response that is not a success means: the refusal its
-- body names, or, without such a body, the one its status means. A status
-- that is no refusal (above all a 5xx) means the server failed.
failureOf :: Response -> WikiError
failureOf r = case eitherDecode r.responseBody of
  Right e -> fromApiError e
  Left _ -> maybe (Unreachable unexpected) fromApiError (errorForStatus status reason)
  where
    status = statusCode r.responseStatusCode
    unexpected
      | status >= 500 = "the server failed, with status " <> show status
      | otherwise = "its answer was not one the wiki can read: status " <> show status
    -- The body, if it is text a person can read; a proxy's HTML page is
    -- not.
    reason = case decodeUtf8' (BSL.toStrict r.responseBody) of
      Right t | not (T.null t), T.length t < 300, not ("<" `T.isPrefixOf` T.stripStart t) -> T.strip t
      _ -> "The request was refused (" <> show status <> ")."

-- | The backend's 'WikiError' for an API refusal: the one of the same
-- name.
fromApiError :: ApiError -> WikiError
fromApiError = \case
  ApiError.NotFound -> NotFound
  ApiError.Forbidden -> Forbidden
  ApiError.Conflict t -> Conflict t
  ApiError.Invalid t -> Invalid t
  -- Signing in's own error, which the server never returns to a
  -- 'Wiki.App.Backend.MonadWiki' request; if a proxy in front of it does,
  -- the nearest error.
  ApiError.Unauthenticated -> Forbidden
  ApiError.SecondFactorRequired -> Forbidden
  ApiError.TooManyRequests t -> Invalid t

-- | The session in the form the API sends it, and back: field for field.
sessionInfo :: Session -> SessionInfo
sessionInfo s = SessionInfo {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = s.providers, exports = s.exports, boxes = s.boxes}

fromSessionInfo :: SessionInfo -> Session
fromSessionInfo s = Session {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = s.providers, exports = s.exports, boxes = s.boxes}
