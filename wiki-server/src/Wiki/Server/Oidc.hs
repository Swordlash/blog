-- | Signing in with an account at a provider (WP3.6 of docs/PLAN.md): the
-- providers the configuration names, and the server's half of the round
-- trip through their pages, OpenID Connect's authorization code flow with
-- PKCE and a nonce, driven by the server ("Wiki.Server.Auth" has the
-- routes; the browser only goes to the provider and comes back).
--
-- = Providers
--
-- A provider is configured as @--oidc NAME=KIND,CLIENT-ID[,ISSUER]@
-- ("Wiki.Server.Options"), its client's secret read from the environment
-- ('secretVariable'), never the command line. Its kind says how the server
-- talks to it:
--
-- * @google@: OpenID Connect at @https:\/\/accounts.google.com@, found by
--   discovery.
-- * @apple@: OpenID Connect at @https:\/\/appleid.apple.com@. The secret is
--   the JWT the operator signs with Apple's key (Apple's client secret is
--   one; it lasts at most six months); the answer comes back as a form
--   posted to the callback (@response_mode=form_post@, which Apple wants
--   when the name and e-mail address are asked for), and the person's name
--   only the first time they sign in, in that form.
-- * @oidc@: any OpenID Connect provider, at the issuer given, found by
--   discovery (@\<issuer>\/.well-known\/openid-configuration@).
-- * @github@: GitHub's OAuth apps, which are OAuth 2 without OpenID
--   Connect: fixed addresses (those of a GitHub Enterprise server at the
--   address given instead), and the user's id, login, name and verified
--   e-mail address read from its API.
--
-- The address given replaces the kind's own for any kind, which is how
-- the tests point one at a provider of their own.
--
-- = Trusting what the provider says
--
-- The ID token comes from the provider's token endpoint, over TLS, in
-- answer to the server's own request with its client's secret, so the
-- server knows whom it came from without checking its signature, as
-- OpenID Connect Core (3.1.3.7, item 6) allows for a token received that
-- way; its claims are checked all the same ('checkClaims'): the issuer,
-- the audience (this client), the expiry, and the nonce of this round
-- trip. No JOSE library is needed for that. An e-mail address is kept only
-- if the provider says it has verified it.
--
-- Nothing secret is ever written into a log or a page: the codes, tokens
-- and secrets of the round trip stay in this module's requests, and its
-- failures are told in its own words, never an HTTP library's, which would
-- quote the request.
module Wiki.Server.Oidc
  ( -- * Providers
    Kind (..)
  , kindName
  , readKind
  , OidcOption (..)
  , renderOidcOption
  , parseOidcOption
  , checkOidcOption
  , secretVariable
  , Provider (..)
  , newProvider
  , newProviders
  , signInProvider
  , redirectUri

    -- * The round trip
  , Endpoints (..)
  , endpointsOf
  , Secrets (..)
  , newSecrets
  , challengeOf
  , authorizeUrl
  , Answer (..)
  , claimsFor

    -- * ID tokens
  , IdClaims (..)
  , decodeIdToken
  , checkClaims
  , clockSkew

    -- * Pending round trips
  , Pending (..)
  , Flows
  , newFlows
  , remember
  , takePending
  , flowLifetime
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON (..), Object, Value (..), eitherDecode, eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither, parseMaybe, typeMismatch)
import Data.ByteArray.Encoding (Base (..), convertFromBase, convertToBase)
import Data.Char (isAsciiLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client (Manager, Request (..), RequestBody (..), httpLbs, parseRequest, responseBody, responseStatus, responseTimeoutMicro)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (HeaderName, hAccept, hAuthorization, hContentType, hUserAgent, statusCode)
import Protolude
import Text.Show (Show (showsPrec))
import Web.FormUrlEncoded (urlEncodeParams)
import Wiki.Api.Auth (callbackPath)
import Wiki.Core.User (SignInProvider (..))
import Wiki.Server.Accounts (Claimed (..), Intent)
import Wiki.Server.Password (newToken, tokenHash)

--------------------------------------------------------------------------------
-- Providers

-- | How the server talks to a provider (see the module's Haddock).
data Kind = Google | Apple | GitHub | Generic
  deriving stock (Eq, Show, Enum, Bounded)

-- | As @--oidc@ names it.
kindName :: Kind -> Text
kindName = \case
  Google -> "google"
  Apple -> "apple"
  GitHub -> "github"
  Generic -> "oidc"

readKind :: Text -> Maybe Kind
readKind t = find (\k -> kindName k == t) [minBound .. maxBound]

-- | A provider as the command line names it: @NAME=KIND,CLIENT-ID[,ISSUER]@.
data OidcOption = OidcOption
  { name :: Text
  -- ^ Its name in the wiki's addresses (@auth\/\<name>\/…@) and its
  -- configuration: lower-case letters, digits and dashes.
  , kind :: Kind
  , clientId :: Text
  -- ^ The client's id the provider gave when it was registered there.
  , issuer :: Maybe Text
  -- ^ For @oidc@, the issuer; for another kind, an address in place of
  -- its own (a GitHub Enterprise server's, say).
  }
  deriving stock (Eq, Show)

renderOidcOption :: OidcOption -> Text
renderOidcOption o = o.name <> "=" <> kindName o.kind <> "," <> o.clientId <> maybe "" ("," <>) o.issuer

-- | The option as written, or why it cannot be one.
parseOidcOption :: Text -> Either Text OidcOption
parseOidcOption t = case T.breakOn "=" t of
  (name, rest) | Just fields <- T.stripPrefix "=" rest -> case T.splitOn "," fields of
    k : clientId : more | length more <= 1 -> do
      kind <- maybe (Left ("--oidc " <> t <> ": not a kind of provider: " <> k <> " (google, apple, github or oidc)")) Right (readKind (T.strip k))
      pure OidcOption {name = T.strip name, kind, clientId = T.strip clientId, issuer = mfilter (not . T.null) (T.strip <$> head more)}
    _ -> Left ("--oidc " <> t <> ": write it as NAME=KIND,CLIENT-ID or NAME=KIND,CLIENT-ID,ISSUER")
  _ -> Left ("--oidc " <> t <> ": write it as NAME=KIND,CLIENT-ID or NAME=KIND,CLIENT-ID,ISSUER")

-- | Why a provider cannot be configured so, if it cannot.
checkOidcOption :: OidcOption -> [Text]
checkOidcOption o =
  [ "--oidc " <> o.name <> ": a provider's name is lower-case letters, digits and dashes, starting with a letter, at most 32 characters"
  | not (validName o.name)
  ]
    <> ["--oidc " <> o.name <> ": the client id is missing" | T.null o.clientId]
    <> ["--oidc " <> o.name <> ": a provider of kind oidc needs its issuer: NAME=oidc,CLIENT-ID,https://issuer.example.org" | o.kind == Generic, isNothing o.issuer]
    <> [ "--oidc " <> o.name <> ": the address " <> i <> " must start with https:// (or http:// on this machine, for a test)"
       | Just i <- [o.issuer]
       , not (secureAddress i)
       ]
  where
    validName n =
      not (T.null n)
        && T.length n <= 32
        && maybe False (isAsciiLower . fst) (T.uncons n)
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-') n

-- | Whether an address may be talked to with secrets: over TLS, or on
-- this machine.
secureAddress :: Text -> Bool
secureAddress a =
  "https://" `T.isPrefixOf` a
    || any (\here -> ("http://" <> here) `T.isPrefixOf` a) ["127.0.0.1:", "127.0.0.1/", "localhost:", "localhost/", "[::1]:"]

-- | The environment variable a provider's client secret is read from:
-- @WIKI_OIDC_\<NAME>_SECRET@, the name in upper case with its dashes as
-- underscores.
secretVariable :: Text -> Text
secretVariable name = "WIKI_OIDC_" <> T.map (\c -> if c == '-' then '_' else toUpper c) name <> "_SECRET"

-- | A provider, as the server talks to it.
data Provider = Provider
  { option :: OidcOption
  , secret :: Text
  -- ^ The client's secret ('secretVariable').
  , label :: Text
  -- ^ How the wiki's pages name it: "Sign in with Google".
  , publicUrl :: Text
  -- ^ The wiki's address, ending in a slash, which the redirect URI is
  -- below.
  , manager :: Manager
  , discovered :: IORef (Maybe Endpoints)
  -- ^ What discovery found, once it has (on the first sign-in, so that a
  -- server starts while a provider cannot be reached).
  }

instance Show Provider where
  showsPrec _ p rest = "Provider {option = " <> show p.option <> ", secret = <hidden>, label = " <> show p.label <> "}" <> rest

-- | A provider, with its secret, below the wiki's public address, talked
-- to through this manager.
newProvider :: Manager -> Text -> OidcOption -> Text -> IO Provider
newProvider manager publicUrl option secret = do
  discovered <- newIORef Nothing
  pure Provider {option, secret, label = labelOf option, publicUrl, manager, discovered}

-- | The providers, sharing one manager of TLS connections, made only if
-- there is a provider to talk to.
newProviders :: Text -> [(OidcOption, Text)] -> IO [Provider]
newProviders _ [] = pure []
newProviders publicUrl configured = do
  manager <- newTlsManager
  for configured (uncurry (newProvider manager publicUrl))

-- | A kind's own name for the provider, or, for @oidc@, its name with a
-- capital.
labelOf :: OidcOption -> Text
labelOf o = case o.kind of
  Google -> "Google"
  Apple -> "Apple"
  GitHub -> "GitHub"
  Generic -> case T.uncons o.name of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> o.name

-- | The provider as the application shows it.
signInProvider :: Provider -> SignInProvider
signInProvider p = SignInProvider {name = p.option.name, label = p.label}

-- | Where the provider sends the browser back to, which is registered with
-- it: @\<public-url>auth\/\<name>\/callback@.
redirectUri :: Text -> Text -> Text
redirectUri publicUrl name = publicUrl <> callbackPath name

--------------------------------------------------------------------------------
-- The round trip

-- | Where a provider is asked what.
data Endpoints = Endpoints
  { issuer :: Text
  -- ^ What its ID tokens say issued them; for GitHub, which issues none,
  -- its address.
  , authorization :: Text
  , token :: Text
  , userinfo :: Maybe Text
  -- ^ For an OpenID Connect provider, its user info, if it has one; for
  -- GitHub, its API.
  , secretInForm :: Bool
  -- ^ Whether the client's secret goes in the token request's form
  -- (@client_secret_post@), as GitHub, Google and Apple take it, or in its
  -- @Authorization@ header (@client_secret_basic@), which a provider whose
  -- discovery document does not say that it takes the form wants (the
  -- default of OpenID Connect Discovery).
  }
  deriving stock (Eq, Show)

-- | The kind's own address, or the one configured in its place.
baseOf :: OidcOption -> Text
baseOf o = T.dropWhileEnd (== '/') $ fromMaybe own o.issuer
  where
    own = case o.kind of
      Google -> "https://accounts.google.com"
      Apple -> "https://appleid.apple.com"
      GitHub -> "https://github.com"
      Generic -> ""

-- | A provider's endpoints: GitHub's fixed ones, or what discovery finds,
-- asked once and kept. 'Left' says why they could not be found, for a
-- person to read.
endpointsOf :: Provider -> IO (Either Text Endpoints)
endpointsOf p = case p.option.kind of
  GitHub ->
    let base = baseOf p.option
        api = if base == "https://github.com" then "https://api.github.com" else base <> "/api/v3"
     in pure (Right Endpoints {issuer = base, authorization = base <> "/login/oauth/authorize", token = base <> "/login/oauth/access_token", userinfo = Just api, secretInForm = True})
  _ ->
    readIORef p.discovered >>= \case
      Just e -> pure (Right e)
      Nothing -> do
        let base = baseOf p.option
            address = base <> "/.well-known/openid-configuration"
        fetched <- fetchJson p [] address
        case fetched >>= first (\why -> "its discovery document at " <> address <> " is not one: " <> toS why) . parseEither discovery of
          Left why -> pure (Left (p.label <> " could not be asked how to sign in: " <> why))
          Right e
            | T.dropWhileEnd (== '/') e.issuer /= base ->
                pure (Left (p.label <> "'s discovery document names another issuer, " <> e.issuer <> ", than " <> base))
            | otherwise -> writeIORef p.discovered (Just e) $> Right e
  where
    discovery = withObject "discovery" $ \o -> do
      methods :: Maybe [Text] <- o .:? "token_endpoint_auth_methods_supported"
      Endpoints
        <$> o
        .: "issuer"
        <*> o .: "authorization_endpoint"
        <*> o .: "token_endpoint"
        <*> o .:? "userinfo_endpoint"
        <*> pure (maybe False ("client_secret_post" `elem`) methods)

-- | The secrets of one round trip: its state (what the provider sends back
-- to say which round trip it ends), its nonce (which the ID token must
-- carry) and its PKCE verifier (which the token endpoint wants with the
-- code). Each is 32 random bytes in base64 for URLs.
data Secrets = Secrets
  { state :: Text
  , nonce :: Text
  , verifier :: Text
  }

instance Show Secrets where
  showsPrec _ _ rest = "Secrets <hidden>" <> rest

newSecrets :: IO Secrets
newSecrets = Secrets <$> newToken <*> newToken <*> newToken

-- | The PKCE challenge of a verifier: its SHA-256, in base64 for URLs
-- (@S256@).
challengeOf :: Text -> Text
challengeOf verifier = decodeUtf8 (convertToBase Base64URLUnpadded (SHA256.hash (encodeUtf8 verifier)))

-- | Whether the kind takes PKCE. Apple does not say it does, and might
-- refuse a token request with a verifier it does not know; the state and
-- the nonce protect its round trip.
withPkce :: Kind -> Bool
withPkce = (/= Apple)

-- | Where the browser is sent to sign in at the provider.
authorizeUrl :: Provider -> Endpoints -> Secrets -> Text
authorizeUrl p e s = e.authorization <> (if "?" `T.isInfixOf` e.authorization then "&" else "?") <> decodeUtf8 (toS (urlEncodeParams params))
  where
    o = p.option
    params =
      [ ("response_type", "code")
      , ("client_id", o.clientId)
      , ("redirect_uri", redirectUri p.publicUrl o.name)
      , ("scope", scope)
      , ("state", s.state)
      ]
        <> [("nonce", s.nonce) | o.kind /= GitHub]
        <> [("response_mode", "form_post") | o.kind == Apple]
        <> (if withPkce o.kind then [("code_challenge", challengeOf s.verifier), ("code_challenge_method", "S256")] else [])
    scope = case o.kind of
      GitHub -> "read:user user:email"
      Apple -> "openid name email"
      _ -> "openid email profile"

-- | What the provider sent the browser back with.
data Answer = Answer
  { code :: Text
  , user :: Maybe Text
  -- ^ Apple's @user@ field, a JSON object with the person's name, sent
  -- the first time they sign in only.
  }

instance Show Answer where
  showsPrec _ _ rest = "Answer <hidden>" <> rest

-- | Who the provider says signed in, once the code is exchanged at its
-- token endpoint and what it answered is checked; or why not, for a
-- person to read.
claimsFor :: Provider -> Secrets -> Answer -> IO (Either Text Claimed)
claimsFor p s answer = runExceptT $ do
  e <- ExceptT (endpointsOf p)
  now <- liftIO getCurrentTime
  tokens <- ExceptT (exchange p e s answer.code)
  case p.option.kind of
    GitHub -> do
      access <- maybe (throwError (p.label <> " gave no access token.")) pure tokens.accessToken
      ExceptT (gitHubUser p e access)
    kind -> do
      idToken <- maybe (throwError (p.label <> " gave no ID token.")) pure tokens.idToken
      claims <- either (\why -> throwError (p.label <> "'s ID token cannot be read: " <> why)) pure (decodeIdToken idToken)
      either (\why -> throwError (p.label <> "'s ID token " <> why)) pure (checkClaims (acceptedIssuers kind e) p.option.clientId s.nonce now claims)
      -- What the token does not say, the user info may.
      extra <- case (e.userinfo, tokens.accessToken) of
        (Just url, Just access)
          | isNothing claims.email || isNothing claims.name ->
              liftIO (rightToMaybe . (>>= first (toS :: [Char] -> Text) . parseEither (parseJSON @IdClaims)) <$> fetchJson p [(hAuthorization, "Bearer " <> encodeUtf8 access)] url)
        _ -> pure Nothing
      let fromInfo = mfilter (\i -> i.sub == claims.sub) extra
          merged = maybe claims (claims `filledFrom`) fromInfo
          appleName = answer.user >>= appleNameOf
      pure
        Claimed
          { provider = p.option.name
          , subject = merged.sub
          , email = mfilter (const (merged.emailVerified == Just True)) merged.email
          , name = merged.name <|> appleName <|> joinedName merged
          , login = merged.preferredUsername
          }
  where
    filledFrom a b =
      a
        { email = a.email <|> b.email
        , emailVerified = a.emailVerified <|> b.emailVerified
        , name = a.name <|> b.name
        , preferredUsername = a.preferredUsername <|> b.preferredUsername
        , givenName = a.givenName <|> b.givenName
        , familyName = a.familyName <|> b.familyName
        }
    joinedName c = mfilter (not . T.null) (Just (T.unwords (catMaybes [c.givenName, c.familyName])))

-- | The issuers whose ID tokens are taken: the discovered one, and for
-- Google its name without the scheme, which its tokens may carry too.
acceptedIssuers :: Kind -> Endpoints -> [Text]
acceptedIssuers kind e = e.issuer : ["accounts.google.com" | kind == Google]

-- | Apple's @user@ field's name: @{"name": {"firstName": …, "lastName": …}}@.
appleNameOf :: Text -> Maybe Text
appleNameOf raw = do
  v <- rightToMaybe (eitherDecodeStrict' (encodeUtf8 raw))
  (first', last') <- flip parseMaybe v $ withObject "user" $ \o -> do
    n <- o .: "name"
    (,) <$> n .:? "firstName" <*> n .:? "lastName"
  mfilter (not . T.null) (Just (T.unwords (catMaybes [first', last'])))

-- | What a token endpoint answered.
data Tokens = Tokens
  { idToken :: Maybe Text
  , accessToken :: Maybe Text
  }

-- | Exchange the code for tokens, with the client's secret and the
-- verifier.
exchange :: Provider -> Endpoints -> Secrets -> Text -> IO (Either Text Tokens)
exchange p e s code = do
  let o = p.option
      form =
        [ ("grant_type", "authorization_code")
        , ("code", code)
        , ("redirect_uri", redirectUri p.publicUrl o.name)
        , ("client_id", o.clientId)
        ]
          <> [("client_secret", p.secret) | e.secretInForm]
          <> [("code_verifier", s.verifier) | withPkce o.kind]
      -- RFC 6749, 2.3.1: the id and the secret form-encoded, then joined.
      basic = "Basic " <> convertToBase Base64 (encodeUtf8 (formEncoded o.clientId <> ":" <> formEncoded p.secret))
      formEncoded = T.drop 2 . decodeUtf8 . toS . urlEncodeParams . pure . ("x",)
      -- GitHub answers in a form's encoding unless asked for JSON.
      headers = [(hContentType, "application/x-www-form-urlencoded"), (hAccept, "application/json")] <> [(hAuthorization, basic) | not e.secretInForm]
  answered <- request p "POST" e.token headers (urlEncodeParams form)
  pure $ do
    (status, body) <- answered
    v <- first (const (p.label <> "'s token endpoint answered with something that is not JSON (status " <> show status <> ").")) (eitherDecode body)
    let field name = parseMaybe (withObject "tokens" (.:? name)) v >>= identity
    case field "error" of
      Just err -> Left (p.label <> " would not exchange the code: " <> err <> maybe "" (\d -> " (" <> d <> ")") (field "error_description"))
      Nothing
        | status /= 200 -> Left (p.label <> "'s token endpoint answered with status " <> show status <> ".")
        | otherwise -> Right Tokens {idToken = field "id_token", accessToken = field "access_token"}

-- | Who a GitHub access token is: its user, and their primary e-mail
-- address if it is verified.
gitHubUser :: Provider -> Endpoints -> Text -> IO (Either Text Claimed)
gitHubUser p e access = runExceptT $ do
  api <- maybe (throwError "GitHub's API has no address.") pure e.userinfo
  let hs = [(hAuthorization, "Bearer " <> encodeUtf8 access), (hAccept, "application/vnd.github+json")]
  v <- ExceptT (first ((p.label <> " would not say who signed in: ") <>) <$> fetchJson p hs (api <> "/user"))
  (uid, login, name) <- either (\why -> throwError (p.label <> " said something unexpected of the user: " <> toS why)) pure $
    flip parseEither v $
      withObject "user" $ \o -> do
        uid :: Integer <- o .: "id"
        (uid,,) <$> o .:? "login" <*> o .:? "name"
  -- Without the user:email scope there is no list, and no address.
  emails <- liftIO (fetchJson p hs (api <> "/user/emails"))
  let primary = do
        listed <- rightToMaybe emails
        entries <- parseMaybe parseJSON listed :: Maybe [Value]
        head
          [ address
          | entry <- entries
          , Just (address, isPrimary, verified) <- [parseMaybe (withObject "email" (\o -> (,,) <$> o .: "email" <*> o .: "primary" <*> o .: "verified")) entry]
          , isPrimary && verified
          ]
  pure Claimed {provider = p.option.name, subject = show uid, email = primary, name = mfilter (not . T.null) name, login}

-- | A GET whose answer is JSON.
fetchJson :: Provider -> [(HeaderName, ByteString)] -> Text -> IO (Either Text Value)
fetchJson p hs url = do
  answered <- request p "GET" url ((hAccept, "application/json") : hs) ""
  pure $ do
    (status, body) <- answered
    unless (status == 200) (Left ("it answered with status " <> show status))
    first (const "it answered with something that is not JSON") (eitherDecode body)

-- | A request to a provider, with the server's name as the user agent
-- (GitHub's API refuses a request without one) and a time limit: the
-- status and the body, or why there are none, in words of this module's
-- own (an HTTP library's exception quotes its request, secrets and all).
request :: Provider -> ByteString -> Text -> [(HeaderName, ByteString)] -> LByteString -> IO (Either Text (Int, LByteString))
request p method url hs body = do
  outcome <- try $ do
    initial <- parseRequest (toS url)
    response <-
      httpLbs
        initial
          { method
          , requestHeaders = (hUserAgent, "wiki-server") : hs
          , requestBody = RequestBodyLBS body
          , responseTimeout = responseTimeoutMicro 15_000_000
          , redirectCount = 0
          }
        p.manager
    pure (statusCode (responseStatus response), responseBody response)
  pure $ case outcome of
    Right answered -> Right answered
    Left (_ :: SomeException) -> Left (p.label <> " could not be reached at " <> T.takeWhile (/= '?') url <> ".")

--------------------------------------------------------------------------------
-- ID tokens

-- | The claims of an ID token the server looks at.
data IdClaims = IdClaims
  { iss :: Text
  , sub :: Text
  , aud :: [Text]
  , azp :: Maybe Text
  , expires :: Maybe UTCTime
  -- ^ @exp@.
  , nonce :: Maybe Text
  , email :: Maybe Text
  , emailVerified :: Maybe Bool
  , name :: Maybe Text
  , preferredUsername :: Maybe Text
  , givenName :: Maybe Text
  , familyName :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | User info has the same claims, but for those only an ID token has.
instance FromJSON IdClaims where
  parseJSON = withObject "claims" claimsOf

claimsOf :: Object -> Parser IdClaims
claimsOf o = do
  iss <- fromMaybe "" <$> o .:? "iss"
  sub <- o .: "sub" >>= stringOrNumber
  aud <-
    o .:? "aud" >>= \case
      Nothing -> pure []
      Just (String a) -> pure [a]
      Just v -> parseJSON v
  azp <- o .:? "azp"
  expires <- fmap (posixSecondsToUTCTime . fromInteger) <$> o .:? "exp"
  nonce <- o .:? "nonce"
  email <- o .:? "email"
  -- Apple writes it as a string.
  emailVerified <-
    o .:? "email_verified" >>= \case
      Just (Bool b) -> pure (Just b)
      Just (String "true") -> pure (Just True)
      Just (String _) -> pure (Just False)
      _ -> pure Nothing
  name <- o .:? "name"
  preferredUsername <- o .:? "preferred_username"
  givenName <- o .:? "given_name"
  familyName <- o .:? "family_name"
  pure IdClaims {iss, sub, aud, azp, expires, nonce, email, emailVerified, name, preferredUsername, givenName, familyName}
  where
    stringOrNumber = \case
      String t -> pure t
      Number n -> pure (show (truncate n :: Integer))
      other -> typeMismatch "a string" other

-- | An ID token's claims, read without checking its signature (see the
-- module's Haddock): the JSON of its second part.
decodeIdToken :: Text -> Either Text IdClaims
decodeIdToken t = case T.splitOn "." t of
  [_, payload, _] -> do
    bytes <- first (const "its claims are not base64") (convertFromBase Base64URLUnpadded (encodeUtf8 (T.dropWhileEnd (== '=') payload)) :: Either [Char] ByteString)
    first toS (eitherDecodeStrict' bytes)
  _ -> Left "it is not a JWT"

-- | How far the server's clock and the provider's may differ: a minute.
clockSkew :: NominalDiffTime
clockSkew = 60

-- | Whether an ID token's claims are those of this round trip: issued by
-- one of these issuers, for this client, not expired, with this nonce.
-- 'Left' finishes "The ID token …", for a person to read.
checkClaims :: [Text] -> Text -> Text -> UTCTime -> IdClaims -> Either Text ()
checkClaims issuers clientId nonce now c
  | c.iss `notElem` issuers = Left ("was issued by " <> c.iss <> ", not by the provider.")
  | clientId `notElem` c.aud = Left "is for another client than this wiki's."
  | length c.aud > 1, c.azp /= Just clientId = Left "is for several clients, and not on this wiki's behalf."
  | maybe True (\e -> addUTCTime clockSkew e <= now) c.expires = Left "has expired."
  | c.nonce /= Just nonce = Left "is not for this sign-in."
  | T.null c.sub = Left "names nobody."
  | otherwise = Right ()

--------------------------------------------------------------------------------
-- Pending round trips

-- | A round trip under way: what it is for, its secrets, and where to go
-- once done. Kept in memory for 'flowLifetime', by the hash of its state:
-- a server restarted meanwhile has forgotten it, and the person signs in
-- again.
data Pending = Pending
  { provider :: Text
  , secrets :: Secrets
  , intent :: Intent
  , next :: Text
  -- ^ The application's path to go to once done.
  , expires :: UTCTime
  }
  deriving stock (Show)

-- | The round trips under way.
newtype Flows = Flows (IORef (Map Text Pending))

newFlows :: IO Flows
newFlows = Flows <$> newIORef mempty

-- | How long a round trip may take: ten minutes, which is long enough to
-- sign in at a provider, and short enough that a link left open does not
-- work tomorrow.
flowLifetime :: NominalDiffTime
flowLifetime = 10 * 60

-- | The most round trips kept at once: beyond it, the oldest go.
maxFlows :: Int
maxFlows = 10000

-- | Keep a round trip, dropping those that have expired.
remember :: Flows -> UTCTime -> Pending -> IO ()
remember (Flows ref) now p = atomicModifyIORef' ref $ \m ->
  let live = Map.filter (\x -> x.expires > now) m
      bounded = if Map.size live >= maxFlows then Map.fromList (drop (Map.size live - maxFlows + 1) (sortOn (\(_, x) -> x.expires) (Map.toList live))) else live
   in (Map.insert (tokenHash p.secrets.state) p bounded, ())

-- | The round trip a state names, if it has not expired, forgotten as it
-- is taken: a state ends one round trip once.
takePending :: Flows -> UTCTime -> Text -> IO (Maybe Pending)
takePending (Flows ref) now given = atomicModifyIORef' ref $ \m ->
  let key = tokenHash given
   in (Map.delete key m, mfilter (\x -> x.expires > now) (Map.lookup key m))
