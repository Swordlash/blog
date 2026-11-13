-- | What a smoke suite asks a wiki-server itself, past the browser, over
-- @http-client@: a page's address with its status and headers, and the
-- API, as a user (by their session's cookie) or as nobody.
--
-- A write to the API carries the header the application's own requests
-- carry (@X-Wiki-Request: 1@), without which the server refuses it
-- (another site's page cannot send it). Answers are read whole; the
-- server's JSON is read as an aeson 'Value' and taken apart with the small
-- readers below, which fail saying what they looked for, since a suite
-- reads a few fields of many kinds of answer.
module Wiki.Smoke.Api
  ( -- * Asking
    Wiki (..)
  , newWiki
  , Session (..)
  , Reply (..)
  , get
  , getManual
  , fetchAs
  , api
  , apiJson
  , upload
  , uploadAt
  , header
  , bodyText
  , expectStatus

    -- * Reading JSON
  , (.!)
  , text
  , texts
  , list
  , int
  , bool
  , isNull
  , textOr
  , escape
  , failure
  )
where

import Data.Aeson (Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.CaseInsensitive qualified as CaseInsensitive
import Data.Foldable (toList)
import Data.Maybe (fromMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright.Hspec (expectationFailure)
import Network.HTTP.Client (Manager, RequestBody (..), httpLbs, newManager, parseRequest, redirectCount, requestBody, requestHeaders, responseBody, responseHeaders, responseStatus)
import Network.HTTP.Client qualified as Http
import Network.HTTP.Client.MultipartFormData (PartM (..), formDataBody, partBS, partFileRequestBody)
import Network.HTTP.Types (Header, Method, ResponseHeaders, statusCode, urlEncode)

-- | A wiki-server, as the suite asks it.
data Wiki = Wiki
  { manager :: Manager
  , origin :: Text
  -- ^ Its public address, without the last slash.
  }

newWiki :: Text -> IO Wiki
newWiki origin = do
  manager <- newManager Http.defaultManagerSettings
  pure Wiki {manager, origin}

-- | Someone signed in: the value of their session's cookie, @wiki_session@.
newtype Session = Session {token :: Text}
  deriving stock (Eq, Show)

-- | An answer, read whole.
data Reply = Reply
  { status :: Int
  , headers :: ResponseHeaders
  , body :: ByteString
  }

-- | A header of the answer, by its name in any case.
header :: Text -> Reply -> Maybe Text
header name a = Text.decodeUtf8With Text.lenientDecode <$> lookup (CaseInsensitive.mk (Text.encodeUtf8 name)) a.headers

-- | The reply, if its status is the one given; a failure that says what
-- was asked for and what came otherwise.
expectStatus :: (HasCallStack) => Int -> String -> Reply -> IO Reply
expectStatus wanted what a = do
  if a.status == wanted
    then pure a
    else failure (what <> ": " <> show a.status <> " where " <> show wanted <> " was expected: " <> Text.unpack (Text.take 500 (bodyText a)))

-- | The body as text.
bodyText :: Reply -> Text
bodyText a = Text.decodeUtf8With Text.lenientDecode a.body

-- | Ask an address (a whole one, or a path of the wiki's) as someone or
-- nobody, with a method, headers and a body, following redirects or not.
fetchAs :: Wiki -> Maybe Session -> Bool -> Method -> Text -> [Header] -> Maybe RequestBody -> IO Reply
fetchAs wiki who follow method address extra body = do
  let full = if "/" `Text.isPrefixOf` address then wiki.origin <> address else address
  request <- parseRequest (Text.unpack full)
  let request' =
        request
          { Http.method = method
          , requestHeaders = maybe [] (\s -> [("Cookie", "wiki_session=" <> Text.encodeUtf8 s.token)]) who <> extra
          , requestBody = fromMaybe (RequestBodyBS "") body
          , redirectCount = if follow then 10 else 0
          }
  response <- httpLbs request' wiki.manager
  pure
    Reply
      { status = statusCode (responseStatus response)
      , headers = responseHeaders response
      , body = LazyByteString.toStrict (responseBody response)
      }

-- | A @GET@ of an address, following redirects, as a browser's fetch does.
get :: Wiki -> Maybe Session -> Text -> IO Reply
get wiki who address = fetchAs wiki who True "GET" address [] Nothing

-- | A @GET@ that does not follow a redirect: its own status and @Location@.
getManual :: Wiki -> Maybe Session -> Text -> IO Reply
getManual wiki who address = fetchAs wiki who False "GET" address [] Nothing

-- | Ask the API (a path under @\/api\/v1\/@) with a method and a JSON body
-- or none, and the application's header, and more headers given.
api :: Wiki -> Maybe Session -> Method -> Text -> Maybe Value -> [Header] -> IO Reply
api wiki who method path body extra =
  fetchAs
    wiki
    who
    True
    method
    ("/api/v1/" <> path)
    (("X-Wiki-Request", "1") : [("Content-Type", "application/json") | Just _ <- [body]] <> extra)
    (RequestBodyLBS . Aeson.encode <$> body)

-- | The answer's body as JSON, or a failure that says what it was.
apiJson :: (HasCallStack) => Reply -> IO Value
apiJson a = case Aeson.eitherDecodeStrict a.body of
  Right v -> pure v
  Left e -> failure ("not JSON (" <> e <> ", status " <> show a.status <> "): " <> Text.unpack (Text.take 500 (bodyText a)))

-- | Upload a file to the API as a form (a path under @\/api\/v1\/@): the
-- file's field, name, media type and bytes, and other fields of text.
upload :: Wiki -> Session -> Text -> Text -> Text -> Text -> ByteString -> [(Text, Text)] -> IO Reply
upload wiki who path = uploadAt wiki (Just who) (wiki.origin <> "/api/v1/" <> path)

-- | 'upload' to a whole address, as someone or nobody: a server's admin
-- listener, say, which asks nobody to sign in.
uploadAt :: Wiki -> Maybe Session -> Text -> Text -> Text -> Text -> ByteString -> [(Text, Text)] -> IO Reply
uploadAt wiki who address field name mediaType bytes others = do
  request <- parseRequest (Text.unpack address)
  let file =
        (partFileRequestBody field (Text.unpack name) (RequestBodyBS bytes))
          { partContentType = Just (Text.encodeUtf8 mediaType)
          }
  form <-
    formDataBody
      (file : [partBS k (Text.encodeUtf8 v) | (k, v) <- others])
      request
        { Http.method = "POST"
        , requestHeaders = ("X-Wiki-Request", "1") : maybe [] (\s -> [("Cookie", "wiki_session=" <> Text.encodeUtf8 s.token)]) who
        }
  response <- httpLbs form wiki.manager
  pure
    Reply
      { status = statusCode (responseStatus response)
      , headers = responseHeaders response
      , body = LazyByteString.toStrict (responseBody response)
      }

----------------------------------------------------------------------
-- Reading JSON

-- | A field of an object; 'Null' when it is not there or the value is not
-- an object, as JavaScript's @?.@ reads it.
(.!) :: Value -> Text -> Value
(.!) (Object o) k = fromMaybe Null (KeyMap.lookup (Key.fromText k) o)
(.!) _ _ = Null

infixl 9 .!

-- | A string, or a failure that shows what was there.
text :: (HasCallStack) => Value -> IO Text
text = \case
  String t -> pure t
  other -> failure ("not a string: " <> show other)

-- | A string, or the default for anything else.
textOr :: Text -> Value -> Text
textOr fallback = \case
  String t -> t
  _ -> fallback

-- | The strings of an array.
texts :: (HasCallStack) => Value -> IO [Text]
texts v = list v >>= traverse text

-- | The elements of an array, or a failure.
list :: (HasCallStack) => Value -> IO [Value]
list = \case
  Array a -> pure (toList a)
  other -> failure ("not an array: " <> show other)

-- | A whole number, or a failure.
int :: (HasCallStack) => Value -> IO Int
int = \case
  Number n | Just i <- toBoundedInteger n -> pure i
  other -> failure ("not a whole number: " <> show other)

-- | A boolean, or a failure.
bool :: (HasCallStack) => Value -> IO Bool
bool = \case
  Bool b -> pure b
  other -> failure ("not a boolean: " <> show other)

isNull :: Value -> Bool
isNull = (== Null)

-- | Fail with the message as an expectation does, naming the line of the
-- suite that called (hspec's @expectationFailure@, through every function
-- that carries 'HasCallStack' on the way). @fail@ names the line only
-- where base's @MonadFail@ carries a call stack, which it does from GHC
-- 9.14; on the floor's GHC 9.10 it does not.
failure :: (HasCallStack) => String -> IO a
failure message = do
  expectationFailure message
  -- Not reached: the expectation has thrown.
  ioError (userError message)

-- | A part of a path, escaped as JavaScript's @encodeURIComponent@ does.
escape :: Text -> Text
escape = Text.decodeUtf8 . urlEncode True . Text.encodeUtf8
