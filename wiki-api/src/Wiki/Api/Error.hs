-- | API errors: how the server reports that it refused a request.
--
-- The application's backend interface (@MonadWiki@ in @wiki-app@) returns a
-- @WikiError@ for every refusal: not found, forbidden, invalid, conflict.
-- Over HTTP the same four are sent as a status and a JSON body, so that
-- the client returns to its components exactly the error the server's
-- handler returned. 'ApiError' is that body, with one constructor per
-- @WikiError@ constructor, with the same name and the same text, and
-- 'errorStatus' is its status.
--
-- 'ApiError' is a separate type rather than @WikiError@ itself because
-- @WikiError@ belongs to @wiki-app@, which depends on this package, not
-- the other way round. Converting between the two is a total function
-- each way, written where both types are in scope (the server's handlers,
-- the HTTP backend).
module Wiki.Api.Error
  ( ApiError (..)
  , errorStatus
  , errorForStatus
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Pair, parseFail)
import Protolude

-- | 'ApiError': why a request was refused, as the body of an error response:
--
-- > {"error": "NotFound"}
-- > {"error": "Forbidden"}
-- > {"error": "Conflict", "message": "The page has been saved since."}
-- > {"error": "Invalid", "message": "A page needs a title."}
-- > {"error": "Unauthenticated"}
-- > {"error": "TooManyRequests", "message": "Too many failed attempts: try again in 15 minutes."}
-- > {"error": "SecondFactorRequired"}
--
-- The last three belong to signing in ("Wiki.Api.Account"), which
-- @MonadWiki@ has no method for: a login and password that do not match, a
-- login tried too often, and a correct password for an account that also
-- needs a second factor ("Wiki.Api.Security"). A client that receives them
-- where it expects a @WikiError@ maps them to the nearest one
-- ('Forbidden', 'Invalid').
--
-- When more than one error applies, the order in @MonadWiki@'s Haddock
-- decides (not found first, then forbidden, invalid and conflict).
data ApiError
  = -- | No record has that id or path: status 404.
    NotFound
  | -- | The current user may not see it, or may not do that to it: status 403.
    Forbidden
  | -- | Something has changed since the request was made, as the text
    -- says: status 409.
    Conflict Text
  | -- | The request cannot be carried out as it is, as the text says:
    -- status 400.
    Invalid Text
  | -- | Signing in failed: no account has that login and password, or the
    -- account cannot sign in (it has no password, or it is disabled). The
    -- response does not say which: status 401.
    Unauthenticated
  | -- | Too many requests, as the text says: signing in after too many
    -- failed attempts: status 429.
    TooManyRequests Text
  | -- | The login and password are correct, and the account has a second
    -- factor ("Wiki.Api.Security"): status 401, with a cookie that the
    -- request carrying the code then uses to complete the sign-in.
    SecondFactorRequired
  deriving stock (Eq, Show)

instance ToJSON ApiError where
  toJSON e = object (("error" .= tag) : message)
    where
      tag :: Text
      message :: [Pair]
      (tag, message) = case e of
        NotFound -> ("NotFound", [])
        Forbidden -> ("Forbidden", [])
        Conflict t -> ("Conflict", ["message" .= t])
        Invalid t -> ("Invalid", ["message" .= t])
        Unauthenticated -> ("Unauthenticated", [])
        TooManyRequests t -> ("TooManyRequests", ["message" .= t])
        SecondFactorRequired -> ("SecondFactorRequired", [])

instance FromJSON ApiError where
  parseJSON = withObject "ApiError" $ \o ->
    o .: "error" >>= \case
      ("NotFound" :: Text) -> pure NotFound
      "Forbidden" -> pure Forbidden
      "Conflict" -> Conflict <$> o .: "message"
      "Invalid" -> Invalid <$> o .: "message"
      "Unauthenticated" -> pure Unauthenticated
      "TooManyRequests" -> TooManyRequests <$> o .: "message"
      "SecondFactorRequired" -> pure SecondFactorRequired
      other -> parseFail ("not an error the API knows: " <> show other)

-- | The HTTP status of an error response.
errorStatus :: ApiError -> Int
errorStatus = \case
  NotFound -> 404
  Forbidden -> 403
  Conflict _ -> 409
  Invalid _ -> 400
  Unauthenticated -> 401
  TooManyRequests _ -> 429
  SecondFactorRequired -> 401

-- | The error a response with this status means when its body is not an
-- 'ApiError'. Such a response comes from the server's own routing, before
-- any handler ran (a path no endpoint has, a header or parameter that does
-- not parse), or from a proxy in front of the server. Each such 4xx status
-- maps to the error a handler would have returned for the same reason,
-- with the given text, usually the body. Any other status, above all a
-- 5xx, is not a refusal but a failure of the server, and gives 'Nothing'.
errorForStatus :: Int -> Text -> Maybe ApiError
errorForStatus status text
  | status == 404 || status == 410 = Just NotFound
  | status == 401 = Just Unauthenticated
  | status == 403 = Just Forbidden
  | status == 409 || status == 412 = Just (Conflict text)
  | status == 429 = Just (TooManyRequests text)
  | status >= 400 && status < 500 = Just (Invalid text)
  | otherwise = Nothing
