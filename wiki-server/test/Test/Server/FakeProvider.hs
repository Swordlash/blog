-- | A provider to sign in with, for the tests (WP3.6 of docs/PLAN.md): a
-- small Warp server on a free port of 127.0.0.1 that plays an OpenID
-- Connect provider (discovery, authorization, token endpoint, user info)
-- at its root and GitHub (its OAuth app's addresses and its API) below
-- @\/gh@, over real HTTP.
--
-- Its authorization endpoint signs in at once whoever the test says
-- ('Fake.user'), redirecting straight back with a code (or, asked for
-- @response_mode=form_post@ as Apple is, answering the form's fields as
-- JSON for the test to post); its token endpoint checks the client, its
-- secret, the redirect URI and the PKCE verifier as a provider does, and
-- issues an ID token with the claims expected, or with the one the test
-- spoils ('Fake.spoil').
module Test.Server.FakeProvider
  ( Fake (..)
  , Person (..)
  , Spoiled (..)
  , person
  , withFakeProvider
  , clientSecret
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value, encode, object, toJSON, (.=))
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (hAuthorization, hContentType, hLocation, parseQueryText, status200, status302, status400, status401, status404)
import Network.Wai (Application, Request (..), responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Protolude
import Web.FormUrlEncoded (urlEncodeParams)

-- | Whom the provider signs in.
data Person = Person
  { sub :: Text
  , email :: Maybe Text
  , emailVerified :: Bool
  , name :: Maybe Text
  , username :: Maybe Text
  , nameInToken :: Bool
  -- ^ Whether the ID token says the name, or only the user info does.
  }
  deriving stock (Eq, Show)

-- | Someone with a verified address, a name and a username.
person :: Text -> Person
person s = Person {sub = s, email = Just (s <> "@example.org"), emailVerified = True, name = Just ("Person " <> s), username = Just s, nameInToken = True}

-- | How the next ID token is spoiled, if it is.
data Spoiled
  = Unspoiled
  | WrongAudience
  | WrongNonce
  | WrongIssuer
  | Expired
  | -- | The authorization endpoint says no instead of signing in.
    Refuses
  deriving stock (Eq, Show)

-- | A running provider.
data Fake = Fake
  { url :: Text
  -- ^ Its root, the OpenID Connect issuer: @http:\/\/127.0.0.1:\<port>@.
  , user :: IORef Person
  , spoil :: IORef Spoiled
  , issued :: IORef [Text]
  -- ^ Every code, access token and ID token it has given, which must
  -- never be written to the server's log.
  }

-- | The secret every client of it has.
clientSecret :: Text
clientSecret = "s3cret-of-the-client"

-- | A code's request, as the authorization endpoint was asked.
data Grant = Grant
  { clientId :: Text
  , redirectUri :: Text
  , nonce :: Maybe Text
  , challenge :: Maybe Text
  , who :: Person
  }

withFakeProvider :: (Fake -> IO a) -> IO a
withFakeProvider test = do
  user <- newIORef (person "first")
  spoil <- newIORef Unspoiled
  issued <- newIORef []
  grants <- newIORef mempty
  counter <- newIORef (0 :: Int)
  testWithApplication (pure (app user spoil issued grants counter)) $ \port -> do
    let url = "http://127.0.0.1:" <> show port
    test Fake {url, user, spoil, issued}

app :: IORef Person -> IORef Spoiled -> IORef [Text] -> IORef (Map Text Grant) -> IORef Int -> Application
app user spoil issued grants counter request respond = do
  let base = "http://" <> maybe "127.0.0.1" decodeUtf8 (requestHeaderHost request)
      query = [(k, v) | (k, Just v) <- parseQueryText (rawQueryString request)]
      json :: Value -> IO _
      json v = respond (responseLBS status200 [(hContentType, "application/json")] (encode v))
      bad why = respond (responseLBS status400 [(hContentType, "application/json")] (encode (object ["error" .= ("invalid_grant" :: Text), "error_description" .= (why :: Text)])))
      fresh prefix = do
        n <- atomicModifyIORef' counter (\c -> (c + 1, c + 1))
        let t = prefix <> "-" <> show n <> "-" <> show (12345 * n)
        modifyIORef' issued (t :)
        pure t
      form = do
        body <- strictRequestBody request
        pure [(k, v) | (k, Just v) <- parseQueryText (toS body)]
      bearer = T.stripPrefix "Bearer " . decodeUtf8 =<< lookup hAuthorization (requestHeaders request)
      -- The person a code was for, by the access token issued for it.
      byToken = (\known -> bearer >>= (`Map.lookup` known)) <$> readIORef grants
      authorize = do
        spoiled <- readIORef spoil
        let redirect = fromMaybe "" (lookup "redirect_uri" query)
            given = fromMaybe "" (lookup "state" query)
            back params = respond (responseLBS status302 [(hLocation, encodeUtf8 (redirect <> "?" <> decodeUtf8 (toS (urlEncodeParams params))))] "")
        if spoiled == Refuses
          then back [("error", "access_denied"), ("error_description", "The user said no"), ("state", given)]
          else do
            code <- fresh "code"
            who <- readIORef user
            modifyIORef' grants (Map.insert code Grant {clientId = fromMaybe "" (lookup "client_id" query), redirectUri = redirect, nonce = lookup "nonce" query, challenge = lookup "code_challenge" query, who})
            if lookup "response_mode" query == Just "form_post"
              then json (object ["code" .= code, "state" .= given, "user" .= ("{\"name\":{\"firstName\":\"Fruit\",\"lastName\":\"Lover\"}}" :: Text)])
              else back [("code", code), ("state", given)]
      -- The token endpoint: the code exchanged once, by its client with its
      -- secret, for the same redirect URI, with the verifier of the
      -- challenge.
      exchange github = do
        f <- form
        let field k = fromMaybe "" (lookup k f)
        found <- atomicModifyIORef' grants (\m -> (Map.delete (field "code") m, Map.lookup (field "code") m))
        case found of
          Nothing -> bad "unknown code"
          Just g
            | field "client_secret" /= clientSecret -> bad "wrong secret"
            | field "client_id" /= g.clientId -> bad "wrong client"
            | field "redirect_uri" /= g.redirectUri -> bad "wrong redirect_uri"
            | Just c <- g.challenge, decodeUtf8 (convertToBase Base64URLUnpadded (SHA256.hash (encodeUtf8 (field "code_verifier")))) /= c -> bad "wrong code_verifier"
            | otherwise -> do
                access <- fresh "access"
                modifyIORef' grants (Map.insert access g)
                if github
                  then json (object ["access_token" .= access, "token_type" .= ("bearer" :: Text), "scope" .= ("read:user,user:email" :: Text)])
                  else do
                    spoiled <- readIORef spoil
                    now <- round <$> getPOSIXTime :: IO Integer
                    let p = g.who
                        claims =
                          object $
                            [ "iss" .= (if spoiled == WrongIssuer then "https://elsewhere.example" else base)
                            , "sub" .= p.sub
                            , "aud" .= (if spoiled == WrongAudience then "another-client" else g.clientId)
                            , "exp" .= (if spoiled == Expired then now - 600 else now + 300)
                            , "iat" .= now
                            , "nonce" .= (if spoiled == WrongNonce then Just "not-the-nonce" else g.nonce)
                            , "email" .= p.email
                            , "email_verified" .= p.emailVerified
                            , "preferred_username" .= p.username
                            ]
                              <> ["name" .= p.name | p.nameInToken]
                        part :: LByteString -> Text
                        part = decodeUtf8 . convertToBase Base64URLUnpadded . (toS :: LByteString -> ByteString)
                        idToken = part "{\"alg\":\"RS256\",\"typ\":\"JWT\"}" <> "." <> part (encode claims) <> ".bm90IGNoZWNrZWQ"
                    modifyIORef' issued (idToken :)
                    json (object ["access_token" .= access, "token_type" .= ("Bearer" :: Text), "id_token" .= idToken])
      unauthorized = respond (responseLBS status401 [] "")
  case (requestMethod request, pathInfo request) of
    ("GET", [".well-known", "openid-configuration"]) ->
      json (object ["issuer" .= base, "authorization_endpoint" .= (base <> "/authorize"), "token_endpoint" .= (base <> "/token"), "userinfo_endpoint" .= (base <> "/userinfo")])
    ("GET", ["authorize"]) -> authorize
    ("POST", ["token"]) -> exchange False
    ("GET", ["userinfo"]) ->
      byToken >>= \case
        Nothing -> unauthorized
        Just g -> json (object ["sub" .= g.who.sub, "name" .= g.who.name, "email" .= g.who.email, "email_verified" .= g.who.emailVerified])
    ("GET", ["gh", "login", "oauth", "authorize"]) -> authorize
    ("POST", ["gh", "login", "oauth", "access_token"]) -> exchange True
    ("GET", ["gh", "api", "v3", "user"]) ->
      byToken >>= \case
        Just g | hasAgent -> json (object ["id" .= (readMaybe g.who.sub :: Maybe Integer), "login" .= g.who.username, "name" .= g.who.name])
        _ -> unauthorized
    ("GET", ["gh", "api", "v3", "user", "emails"]) ->
      byToken >>= \case
        Just g -> json (toJSON [object ["email" .= e, "primary" .= True, "verified" .= g.who.emailVerified] | Just e <- [g.who.email]])
        _ -> unauthorized
    _ -> respond (responseLBS status404 [] "")
  where
    -- GitHub's API refuses a request without a User-Agent.
    hasAgent = isJust (lookup "User-Agent" (requestHeaders request))
