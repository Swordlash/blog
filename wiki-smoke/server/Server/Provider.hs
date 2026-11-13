-- | A provider to sign in with, for the server's smoke suite (WP3.6 of
-- docs/PLAN.md): a fake OpenID Connect provider on localhost, another site
-- than the wiki's 127.0.0.1, so that the browser applies its rules for
-- cookies across sites as it does with a real one.
--
-- It has OpenID Connect's discovery, an authorization endpoint that signs
-- Olive in at once and sends the browser straight back, and a token
-- endpoint that checks the client's secret and the PKCE verifier and
-- issues an ID token for the round trip (unsigned: the server reads it from
-- the token endpoint and checks its claims, not a signature). It keeps
-- every code and token it issued, so that the suite can check that none of
-- them is in the server's log.
module Server.Provider
  ( Provider (..)
  , withProvider
  , clientId
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.HTTP.Types (hContentType, hLocation, parseQuery, queryToQueryText, status200, status302, status400, status404, urlEncode)
import Network.HTTP.Types.URI (urlDecode)
import Network.Wai (Application, queryString, rawPathInfo, requestHeaders, requestMethod, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (withApplication)

-- | The provider, while it runs.
data Provider = Provider
  { origin :: Text
  -- ^ @http://localhost:PORT@.
  , secret :: Text
  -- ^ The client's secret, which the administration types once.
  , issued :: IORef [Text]
  -- ^ Every code and ID token it gave out.
  }

-- | The client the wiki is registered as.
clientId :: Text
clientId = "smoke-client"

-- | What an authorization code was given for: the nonce and the PKCE
-- challenge the wiki sent.
data Grant = Grant {nonce :: Text, challenge :: Text}

-- | Run the provider on a free port for the body.
withProvider :: (Provider -> IO a) -> IO a
withProvider body = do
  originRef <- newIORef ""
  issued <- newIORef []
  grants <- newMVar Map.empty
  let secret = "the smoke test's client secret"
  withApplication (pure (app originRef issued grants secret)) $ \port -> do
    -- localhost, not 127.0.0.1: another site than the wiki's.
    let origin = "http://localhost:" <> Text.pack (show port)
    writeIORef originRef origin
    body Provider {origin, secret, issued}

app :: IORef Text -> IORef [Text] -> MVar (Map Text Grant) -> Text -> Application
app originRef issued grants secret request respond = do
  origin <- readIORef originRef
  let json status v = respond (responseLBS status [(hContentType, "application/json")] (Aeson.encode v))
      query = queryToQueryText (queryString request)
      param k = fromMaybe "" (lookup k query >>= id)
  case (requestMethod request, rawPathInfo request) of
    (_, "/.well-known/openid-configuration") ->
      json status200 (object ["issuer" .= origin, "authorization_endpoint" .= (origin <> "/authorize"), "token_endpoint" .= (origin <> "/token")])
    (_, "/authorize") -> do
      n <- length <$> readIORef issued
      now <- getPOSIXTime
      let code = "code-" <> Text.pack (show n) <> "-" <> Text.pack (show (floor (now * 1000000) :: Integer))
      atomicModifyIORef' issued (\xs -> (xs <> [code], ()))
      modifyMVar grants (\m -> pure (Map.insert code Grant {nonce = param "nonce", challenge = param "code_challenge"} m, ()))
      let back = param "redirect_uri"
          joiner = if "?" `Text.isInfixOf` back then "&" else "?"
          location = back <> joiner <> "code=" <> encode code <> "&state=" <> encode (param "state")
      respond (responseLBS status302 [(hLocation, Text.encodeUtf8 location)] "")
    ("POST", "/token") -> do
      form <- queryToQueryText . parseQuery . LazyByteString.toStrict <$> strictRequestBody request
      let field k = fromMaybe "" (lookup k form >>= id)
          code = field "code"
      grant <- modifyMVar grants (\m -> pure (Map.delete code m, Map.lookup code m))
      let verified = Text.decodeUtf8 (convertToBase Base64URLUnpadded (hashWith SHA256 (Text.encodeUtf8 (field "code_verifier"))))
          -- The secret as HTTP's Basic, since the discovery document does
          -- not say that the form may carry it.
          basic = fromMaybe "" (lookup "Authorization" (requestHeaders request) >>= ByteString.stripPrefix "Basic ")
          (idPart, secretPart) = Text.breakOn ":" (Text.decodeUtf8Lenient (Base64.decodeLenient basic))
          decoded = Text.decodeUtf8Lenient . urlDecode True . Text.encodeUtf8
      case grant of
        Just g
          | decoded idPart == clientId && decoded (Text.drop 1 secretPart) == secret && verified == g.challenge -> do
              now <- floor <$> getPOSIXTime :: IO Integer
              let token =
                    part (object ["alg" .= ("none" :: Text)])
                      <> "."
                      <> part
                        ( object
                            [ "iss" .= origin
                            , "sub" .= ("olive-1" :: Text)
                            , "aud" .= clientId
                            , "exp" .= (now + 300)
                            , "iat" .= now
                            , "nonce" .= g.nonce
                            , "email" .= ("olive@example.org" :: Text)
                            , "email_verified" .= True
                            , "name" .= ("Olive Oidc" :: Text)
                            , "preferred_username" .= ("olive" :: Text)
                            ]
                        )
                      <> "."
              atomicModifyIORef' issued (\xs -> (xs <> [token], ()))
              json status200 (object ["access_token" .= ("not used" :: Text), "token_type" .= ("Bearer" :: Text), "id_token" .= token])
        _ -> json status400 (object ["error" .= ("invalid_grant" :: Text)])
    _ -> respond (responseLBS status404 [] "")
  where
    encode = Text.decodeUtf8 . urlEncode True . Text.encodeUtf8
    part :: Value -> Text
    part v = Text.decodeUtf8 (convertToBase Base64URLUnpadded (LazyByteString.toStrict (Aeson.encode v)) :: ByteString)
