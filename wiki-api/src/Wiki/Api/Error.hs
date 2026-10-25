-- | How the server says that a request was not carried out.
--
-- The application's backend interface (@MonadWiki@ in @wiki-app@) returns a
-- @WikiError@ for every refusal: not found, forbidden, invalid, conflict.
-- Over HTTP the same four travel as a status and a JSON body, so that the
-- client gives its components back exactly the error the server's handler
-- had: 'ApiError' is that body, one constructor per @WikiError@ constructor
-- with the same name and the same text, and 'errorStatus' its status.
--
-- 'ApiError' is a type of its own rather than @WikiError@ itself because the
-- latter belongs to @wiki-app@, which depends on this package rather than the
-- other way round; converting between the two is a total function each way,
-- written where both are in scope (the server's handlers, the HTTP backend).
module Wiki.Api.Error
  ( ApiError (..)
  , errorStatus
  , errorForStatus
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Pair, parseFail)
import Protolude

-- | Why a request was not carried out, as the body of an error response:
--
-- > {"error": "NotFound"}
-- > {"error": "Forbidden"}
-- > {"error": "Conflict", "message": "The page has been saved since."}
-- > {"error": "Invalid", "message": "A page needs a title."}
-- > {"error": "Unauthenticated"}
-- > {"error": "TooManyRequests", "message": "Too many failed attempts: try again in 15 minutes."}
-- > {"error": "SecondFactorRequired"}
--
-- The last three are signing in's ("Wiki.Api.Account"), which @MonadWiki@
-- has no method for: a login and password that do not match, a login
-- tried too often, and a password that is right where a second factor is
-- wanted too ("Wiki.Api.Security"). A client that reads them where a @WikiError@ is wanted
-- takes them for the nearest one ('Forbidden', 'Invalid').
--
-- Which of them a request gets, when more than one would apply, is decided
-- as @MonadWiki@'s Haddock says (not found first, then forbidden, invalid
-- and conflict).
data ApiError
  = -- | Nothing has that id or path: status 404.
    NotFound
  | -- | The current user may not see it, or may not do that to it: status 403.
    Forbidden
  | -- | Something has changed since the request was made, as the text says:
    -- status 409.
    Conflict Text
  | -- | The request cannot be carried out as it is, as the text says: status
    -- 400.
    Invalid Text
  | -- | Signing in failed: no account has that login and password, or it
    -- cannot sign in (it has no password, or it is disabled), which the
    -- answer does not tell apart: status 401.
    Unauthenticated
  | -- | Asked too often, as the text says: signing in, after too many
    -- failed attempts: status 429.
    TooManyRequests Text
  | -- | The login and password are right, and the account has a second
    -- factor ("Wiki.Api.Security"): status 401, with a cookie that the
    -- code then ends the sign-in with.
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

-- | The status an error is answered with.
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
-- 'ApiError': one the server's own routing answered before any handler ran
-- (an address no endpoint has, a header or parameter that does not parse),
-- or one a proxy in front of it did. Each such 4xx status is the error a
-- handler would have given for the same reason, with the text given for
-- it, usually the body; anything else, a 5xx above all, is not a refusal but
-- a failure of the server, and gives 'Nothing'.
errorForStatus :: Int -> Text -> Maybe ApiError
errorForStatus status text
  | status == 404 || status == 410 = Just NotFound
  | status == 401 = Just Unauthenticated
  | status == 403 = Just Forbidden
  | status == 409 || status == 412 = Just (Conflict text)
  | status == 429 = Just (TooManyRequests text)
  | status >= 400 && status < 500 = Just (Invalid text)
  | otherwise = Nothing
