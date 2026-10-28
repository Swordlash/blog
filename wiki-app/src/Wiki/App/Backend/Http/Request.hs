-- | The requests the HTTP backend ("Wiki.App.Backend.Http") sends, and how
-- it reads their responses, as plain data and pure functions. The native
-- tests check them, and any transport carries them: the browser's
-- @fetch@, or the server's application called in the same process.
--
-- Every address comes from "Wiki.Api.Links" and is relative to the
-- page's @\<base href>@, so the client cannot request a path the server
-- does not serve. A body is JSON, or, for an attachment or an archive to
-- import, a multipart form written here ('multipart', 'multipartForm').
-- So a request is plain bytes on every transport, and the browser's side
-- is one call of @fetch@.
--
-- A response is read into the form 'Wiki.App.Backend.MonadWiki' returns
-- ('answer'). A 2xx carries the JSON it should have. A refusal becomes the
-- 'WikiError' of the same name, read from its 'ApiError' body or, without
-- one, from its status alone ('errorForStatus'). Anything else becomes
-- 'Unreachable': no response, a 5xx, or a 2xx whose body is not what the
-- API says, which a proxy or a captive portal can return.
module Wiki.App.Backend.Http.Request
  ( -- * Requests
    Request (..)
  , Body (..)
  , get
  , post
  , put
  , delete
  , withJson
  , ifMatch
  , withHeader
  , multipart
  , Part (..)
  , multipartForm

    -- * Answers
  , Response (..)
  , answer
  , answerNothing
  , failureOf
  , fromApiError

    -- * Sessions
  , sessionInfo
  , fromSessionInfo
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude hiding (get, put)
import Web.HttpApiData (toUrlPiece)
import Wiki.Api (requestMarker)
import Wiki.Api.Error (ApiError, errorForStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Version (PageVersion (..))
import Wiki.App.Backend (Session (..), WikiError (..))

-- | A request: its method, its address relative to the page's base, its
-- headers and its body.
data Request = Request
  { method :: Text
  , url :: Text
  , headers :: [(Text, Text)]
  , body :: Body
  }
  deriving stock (Eq, Show)

-- | A request's body: nothing, or bytes of a media type (which is sent as
-- its @Content-Type@).
data Body = NoBody | Body Text ByteString
  deriving stock (Eq, Show)

-- | A @GET@ of an address.
--
-- Every request carries 'requestMarker', the header that tells the server
-- the request comes from this application, and not from another site's
-- page making the browser send it. The server refuses a write without it.
-- It is set here rather than by the browser's side, so that every
-- transport sends it.
get :: Text -> Request
get url = Request {method = "GET", url, headers = [requestMarker], body = NoBody}

-- | A @POST@ with an empty body: an action whose arguments are all in its
-- address and headers.
post :: Text -> Request
post url = (get url) {method = "POST"}

-- | A @PUT@ without a body, for an action whose address says everything.
put :: Text -> Request
put url = (get url) {method = "PUT"}

-- | A @DELETE@ of an address.
delete :: Text -> Request
delete url = (get url) {method = "DELETE"}

-- | A request of this method to an address, with a value as its JSON body.
withJson :: (ToJSON a) => Text -> Text -> a -> Request
withJson method url value = Request {method, url, headers = [requestMarker], body = Body "application/json" (toS (encode value))}

-- | Make the request conditional on a page's version: a save's
-- @If-Match@, with the version written as the page's @ETag@
-- ("Wiki.Api.Version").
ifMatch :: UTCTime -> Request -> Request
ifMatch base r = r {headers = ("If-Match", toUrlPiece (PageVersion base)) : r.headers}

-- | A request with one more header.
withHeader :: Text -> Text -> Request -> Request
withHeader name value r = r {headers = (name, value) : r.headers}

-- | A @POST@ of a multipart form (@multipart\/form-data@) with one file in
-- it: the part's name, the file's name, its media type and its bytes, in
-- the form the API's uploads expect ("Wiki.Api.Upload").
multipart :: Text -> Text -> Text -> Text -> ByteString -> Request
multipart url part name mediaType bytes = multipartForm url [FilePart {part, name, mediaType, bytes}]

-- | One part of a multipart form.
data Part
  = -- | A file: the part's name, the file's name, its media type and its
    -- bytes.
    FilePart {part :: Text, name :: Text, mediaType :: Text, bytes :: ByteString}
  | -- | A field that is not a file, by its name, with its value. A server
    -- reads it as text rather than as a file, since it has no file name
    -- (an import's choices, "Wiki.Api.Upload").
    TextPart {part :: Text, value :: Text}
  deriving stock (Eq, Show)

-- | A @POST@ of a multipart form (@multipart\/form-data@) with these parts,
-- in this order.
--
-- It is written here rather than by the browser's @FormData@, so that the
-- bytes sent are the same on every transport and the tests can check
-- them. The boundary is a string no part contains. Names go in quotes,
-- with a quote or a backslash in them escaped (an attachment's name has no
-- control characters, which a quoted string could not carry), and as
-- UTF-8, which is what browsers send and servers read.
multipartForm :: Text -> [Part] -> Request
multipartForm url parts =
  Request
    { method = "POST"
    , url
    , headers = [requestMarker]
    , body = Body ("multipart/form-data; boundary=" <> decodeUtf8 boundary) (mconcat (map partBytes parts) <> "--" <> boundary <> "--\r\n")
    }
  where
    contents = \case
      FilePart {bytes} -> bytes
      TextPart {value} -> encodeUtf8 value
    boundary = fromMaybe "wiki-form" (find (\b -> not (any ((b `BS.isInfixOf`) . contents) parts)) candidates)
    candidates = ["wiki-form-boundary-" <> BC.pack (show n) | n <- [0 :: Int ..]]
    partBytes p =
      mconcat
        [ "--" <> boundary <> "\r\n"
        , case p of
            FilePart {part, name, mediaType} ->
              "Content-Disposition: form-data; name=\""
                <> quoted part
                <> "\"; filename=\""
                <> quoted name
                <> "\"\r\n"
                <> "Content-Type: "
                <> encodeUtf8 mediaType
                <> "\r\n\r\n"
            TextPart {part} -> "Content-Disposition: form-data; name=\"" <> quoted part <> "\"\r\n\r\n"
        , contents p
        , "\r\n"
        ]
    quoted = encodeUtf8 . T.concatMap (\c -> if c == '"' || c == '\\' then T.pack ['\\', c] else T.singleton c)

-- | A response: a status and the body's bytes.
data Response = Response
  { status :: Int
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | Read a response that carries a value: the value, or the error. The
-- transport's 'Left' means no response came, with the reason.
answer :: (FromJSON a) => Either Text Response -> Either WikiError a
answer = \case
  Left why -> Left (Unreachable why)
  Right r
    | successful r -> first (\why -> Unreachable ("its answer was not one the wiki can read: " <> toS why)) (eitherDecodeStrict' r.body)
    | otherwise -> Left (failureOf r)

-- | Read a response that carries nothing (a deletion's 204): whether the
-- request succeeded.
answerNothing :: Either Text Response -> Either WikiError ()
answerNothing = \case
  Left why -> Left (Unreachable why)
  Right r
    | successful r -> Right ()
    | otherwise -> Left (failureOf r)

successful :: Response -> Bool
successful r = r.status >= 200 && r.status < 300

-- | The error a response that is not a success means: the refusal its
-- body names, or, without such a body, the one its status means. A status
-- that is no refusal (above all a 5xx) means the server failed.
failureOf :: Response -> WikiError
failureOf r = case eitherDecodeStrict' r.body of
  Right e -> fromApiError e
  Left _ -> maybe (Unreachable ("the server failed, with status " <> show r.status)) fromApiError (errorForStatus r.status reason)
  where
    -- The body, if it is text a person can read; a proxy's HTML page is
    -- not.
    reason = case decodeUtf8' r.body of
      Right t | not (T.null t), T.length t < 300, not ("<" `T.isPrefixOf` T.stripStart t) -> T.strip t
      _ -> "The request was refused (" <> show r.status <> ")."

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
sessionInfo s = SessionInfo {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = s.providers, exports = s.exports}

fromSessionInfo :: SessionInfo -> Session
fromSessionInfo s = Session {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = s.providers, exports = s.exports}
