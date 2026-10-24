-- | The requests the backend over HTTP ("Wiki.App.Backend.Http") makes, and
-- what it makes of their answers, as plain data and pure functions: what
-- the native tests check, and what any transport (the browser's @fetch@, or
-- a server's application called in the same process) carries.
--
-- Every address is one of "Wiki.Api.Links"', relative to the page's
-- @\<base href>@, so the client cannot ask for a path the server does not
-- serve. A body is JSON, or, for an attachment, a multipart form written
-- here ('multipart'), so that a request is bytes on every transport and
-- the browser's half is one call of @fetch@.
--
-- An answer is read as @MonadWiki@ wants it ('answer'): a 2xx with the JSON
-- it should have; a refusal, from its 'ApiError' body or, without one, from
-- its status alone ('errorForStatus'), as the 'WikiError' of the same name;
-- and anything else (no answer, a 5xx, a 2xx whose body is not what the
-- API says, which a proxy or a captive portal gives) as 'Unreachable'.
module Wiki.App.Backend.Http.Request
  ( -- * Requests
    Request (..)
  , Body (..)
  , get
  , delete
  , withJson
  , ifMatch
  , multipart

    -- * Answers
  , Response (..)
  , answer
  , answerNothing
  , failureOf
  , fromApiError
  )
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict', encode)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude hiding (get)
import Web.HttpApiData (toUrlPiece)
import Wiki.Api.Error (ApiError, errorForStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Version (PageVersion (..))
import Wiki.App.Backend (WikiError (..))

-- | A request: its method, its address relative to the page's base, its
-- headers and its body.
data Request = Request
  { method :: Text
  , url :: Text
  , headers :: [(Text, Text)]
  , body :: Body
  }
  deriving stock (Eq, Show)

-- | What a request carries: nothing, or bytes of a media type (which goes
-- out as its @Content-Type@).
data Body = NoBody | Body Text ByteString
  deriving stock (Eq, Show)

-- | A @GET@ of an address.
get :: Text -> Request
get url = Request {method = "GET", url, headers = [], body = NoBody}

-- | A @DELETE@ of an address.
delete :: Text -> Request
delete url = (get url) {method = "DELETE"}

-- | A request of this method to an address, with a value as its JSON body.
withJson :: (ToJSON a) => Text -> Text -> a -> Request
withJson method url value = Request {method, url, headers = [], body = Body "application/json" (toS (encode value))}

-- | The request, made against a page's version: a save's @If-Match@, the
-- version written as the page's @ETag@ is ("Wiki.Api.Version").
ifMatch :: UTCTime -> Request -> Request
ifMatch base r = r {headers = ("If-Match", toUrlPiece (PageVersion base)) : r.headers}

-- | A @POST@ of a multipart form (@multipart\/form-data@) with one file in
-- it: the part's name, the file's name, its media type and its bytes, as
-- the API's uploads want them ("Wiki.Api.Upload").
--
-- Written here rather than by the browser's @FormData@, so that the bytes
-- sent are the same on every transport and the tests see them. The boundary
-- is one the file does not contain; the file's name goes in quotes, with a
-- quote or a backslash in it escaped (an attachment's name has no control
-- characters, which a quoted string could not carry), and as UTF-8, which
-- is what browsers send and servers read.
multipart :: Text -> Text -> Text -> Text -> ByteString -> Request
multipart url part name mediaType bytes =
  Request
    { method = "POST"
    , url
    , headers = []
    , body = Body ("multipart/form-data; boundary=" <> decodeUtf8 boundary) form
    }
  where
    boundary = fromMaybe "wiki-form" (find (\b -> not (b `BS.isInfixOf` bytes)) candidates)
    candidates = ["wiki-form-boundary-" <> BC.pack (show n) | n <- [0 :: Int ..]]
    form =
      mconcat
        [ "--" <> boundary <> "\r\n"
        , "Content-Disposition: form-data; name=\"" <> quoted part <> "\"; filename=\"" <> quoted name <> "\"\r\n"
        , "Content-Type: " <> encodeUtf8 mediaType <> "\r\n\r\n"
        , bytes
        , "\r\n--" <> boundary <> "--\r\n"
        ]
    quoted = encodeUtf8 . T.concatMap (\c -> if c == '"' || c == '\\' then T.pack ['\\', c] else T.singleton c)

-- | What came back: a status and the body's bytes.
data Response = Response
  { status :: Int
  , body :: ByteString
  }
  deriving stock (Eq, Show)

-- | An answer that carries a value: the value, or why there is none. The
-- transport's 'Left' is that no answer came, and why.
answer :: (FromJSON a) => Either Text Response -> Either WikiError a
answer = \case
  Left why -> Left (Unreachable why)
  Right r
    | successful r -> first (\why -> Unreachable ("its answer was not one the wiki can read: " <> toS why)) (eitherDecodeStrict' r.body)
    | otherwise -> Left (failureOf r)

-- | An answer that carries nothing (a deletion's 204): whether it was done.
answerNothing :: Either Text Response -> Either WikiError ()
answerNothing = \case
  Left why -> Left (Unreachable why)
  Right r
    | successful r -> Right ()
    | otherwise -> Left (failureOf r)

successful :: Response -> Bool
successful r = r.status >= 200 && r.status < 300

-- | What an answer that is not a success means: the refusal its body
-- names, or, without such a body, the one its status means; and for a
-- status that refuses nothing (a 5xx, above all), that the server failed.
failureOf :: Response -> WikiError
failureOf r = case eitherDecodeStrict' r.body of
  Right e -> fromApiError e
  Left _ -> maybe (Unreachable ("the server failed, with status " <> show r.status)) fromApiError (errorForStatus r.status reason)
  where
    -- The body, if it is text a person can read: a proxy's page is not.
    reason = case decodeUtf8' r.body of
      Right t | not (T.null t), T.length t < 300, not ("<" `T.isPrefixOf` T.stripStart t) -> T.strip t
      _ -> "The request was refused (" <> show r.status <> ")."

-- | A refusal over HTTP as the backend's: the same, by name.
fromApiError :: ApiError -> WikiError
fromApiError = \case
  ApiError.NotFound -> NotFound
  ApiError.Forbidden -> Forbidden
  ApiError.Conflict t -> Conflict t
  ApiError.Invalid t -> Invalid t
