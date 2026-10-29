{-# LANGUAGE DeriveAnyClass #-}

-- | Server settings (WP4.4 of docs/PLAN.md): the wiki's public address,
-- the mail server that sends invitations and other mail, and the sign-in
-- providers. They are set in the administration's "Server" section and
-- nowhere else (the owner's decision of 2026-10-25). Before anyone can
-- sign in, the first settings are set through the loopback admin listener
-- of decision 11, so the server needs no command-line option for them.
--
-- = Secrets
--
-- The mail account's password and each provider's client secret can be
-- written but are never read back. A response carries only whether each
-- secret is set ('SecretState'). A request carries a 'Maybe Text' for each
-- secret: 'Nothing' (or a missing field) keeps the secret unchanged, an
-- empty text clears it, and any other text replaces it. So the settings
-- are one type with the secret's type as its parameter
-- ('ServerSettingsOf'): 'ServerSettings' in responses,
-- 'ServerSettingsChange' in requests, and, on the server and in the demo,
-- the stored settings, with the secrets themselves.
--
-- A provider is identified by its name, which is part of its redirect URI
-- ('redirectUri') and of the wiki's record of who signs in with it. A
-- change that keeps a provider's name keeps its secret, unless the change
-- carries a new one. A provider missing from a change is removed, with its
-- secret. A change without a mail server ('Nothing') removes the mail
-- server and its password.
module Wiki.Api.ServerSettings
  ( -- * The settings
    ServerSettingsOf (..)
  , ServerSettings
  , ServerSettingsChange
  , MailSettingsOf (..)
  , MailSettings
  , MailChange
  , ProviderSettingsOf (..)
  , ProviderSettings
  , ProviderChange
  , noServerSettings

    -- * Secrets
  , SecretState (..)
  , secretState
  , applyChange
  , providerWith
  , withSecret
  , named

    -- * Mail
  , Security (..)
  , securityName
  , readSecurity
  , securityFor
  , defaultMailPort

    -- * Providers
  , ProviderKind (..)
  , kindName
  , readKind
  , providerLabel
  , redirectUri

    -- * Checks
  , checkServerSettings
  , parsePublicUrl
  , providerProblems
  , secureAddress

    -- * Checking a provider
  , ProviderCheck (..)
  , Discovered (..)

    -- * A test mail
  , MailTest (..)
  , MailTestResult (..)
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), withObject, withText, (.!=), (.:), (.:?))
import Data.Char (isAsciiLower)
import Data.Text qualified as T
import Protolude
import Wiki.Api.Auth (callbackPath)
import Wiki.Api.ContentPolicy (parseAssistantHost)
import Wiki.Core.Url (Url (..))

--------------------------------------------------------------------------------
-- The settings

-- | 'ServerSettingsOf': the server's settings, with each secret of type @s@.
data ServerSettingsOf s = ServerSettings
  { publicUrl :: Maybe Url
  -- ^ The wiki's address as its readers reach it, ending in a slash
  -- (@https:\/\/wiki.example.org\/@): the start of links sent by mail and
  -- of the providers' redirect URIs. Behind a proxy the server cannot find
  -- it out by itself.
  , mail :: Maybe (MailSettingsOf s)
  -- ^ The mail server invitations are sent through. Without one, the
  -- administration shows an invitation's link for the administrator to
  -- pass on.
  , providers :: [ProviderSettingsOf s]
  -- ^ The providers users may sign in with, in the order of their buttons.
  , assistantHosts :: [Text]
  -- ^ The addresses besides Anthropic's and OpenAI's APIs that the
  -- writing assistant may reach from the browser (WP5.21 of docs/PLAN.md):
  -- the origins of the base URLs its users set, such as a server of
  -- Ollama or LM Studio, or a proxy. The page's Content Security Policy
  -- allows them ("Wiki.Api.ContentPolicy"), and refuses every other
  -- address. Each is an origin, as 'parseAssistantHost' writes it.
  }
  deriving stock (Eq, Show, Generic, Functor)

-- | The settings as API responses carry them.
type ServerSettings = ServerSettingsOf SecretState

-- | The settings as API requests carry them: each secret kept, replaced or cleared.
type ServerSettingsChange = ServerSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (ServerSettingsOf s)

-- | Read by hand rather than derived, so that settings without
-- @assistantHosts@, from before the field existed (in a demo's stored
-- state, or from an older client), read as having none.
instance (FromJSON s) => FromJSON (ServerSettingsOf s) where
  parseJSON = withObject "ServerSettings" $ \o ->
    ServerSettings
      <$> o
      .:? "publicUrl"
      <*> o .:? "mail"
      <*> o .: "providers"
      <*> o .:? "assistantHosts" .!= []

-- | 'MailSettingsOf': a mail server, reached over SMTP.
data MailSettingsOf s = MailSettings
  { host :: Text
  , port :: Word16
  , security :: Security
  , user :: Maybe Text
  -- ^ The account to sign in to the mail server with, if it requires one.
  , password :: s
  -- ^ The password of that account.
  , from :: Text
  -- ^ The sender: @wiki\@example.org@, or @Wiki \<wiki\@example.org>@.
  }
  deriving stock (Eq, Show, Generic, Functor)

type MailSettings = MailSettingsOf SecretState

type MailChange = MailSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (MailSettingsOf s)

instance (FromJSON s) => FromJSON (MailSettingsOf s)

-- | 'ProviderSettingsOf': a sign-in provider.
data ProviderSettingsOf s = ProviderSettings
  { name :: Text
  -- ^ Its name in the wiki's addresses (@auth\/\<name>\/…@): lowercase
  -- letters, digits and dashes.
  , kind :: ProviderKind
  , clientId :: Text
  -- ^ The client id the provider issued when the wiki was registered with
  -- it.
  , issuer :: Maybe Url
  -- ^ For @oidc@, the issuer; for another kind, an address that replaces
  -- the provider's default one (a GitHub Enterprise server's, for example).
  , secret :: s
  -- ^ The client secret.
  }
  deriving stock (Eq, Show, Generic, Functor)

type ProviderSettings = ProviderSettingsOf SecretState

type ProviderChange = ProviderSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (ProviderSettingsOf s)

instance (FromJSON s) => FromJSON (ProviderSettingsOf s)

-- | The settings of a server nobody has configured: no address, no mail
-- server, no provider. A wiki created before these settings existed keeps
-- working as before.
noServerSettings :: ServerSettingsOf s
noServerSettings = ServerSettings {publicUrl = Nothing, mail = Nothing, providers = [], assistantHosts = []}

--------------------------------------------------------------------------------
-- Secrets

-- | 'SecretState': whether a secret is set, the only thing ever said about a secret.
data SecretState = Set | NotSet
  deriving stock (Eq, Show, Enum, Bounded)

instance ToJSON SecretState where
  toJSON = \case
    Set -> "set"
    NotSet -> "not-set"

instance FromJSON SecretState where
  parseJSON = withText "set or not-set" $ \case
    "set" -> pure Set
    "not-set" -> pure NotSet
    other -> fail ("not set or not-set: " <> toS other)

-- | Whether a stored secret is set.
secretState :: Maybe k -> SecretState
secretState = maybe NotSet (const Set)

-- | The stored settings, with secrets of type @k@ (made from the sent text
-- by the given function), after a change is applied to them. A secret the
-- change leaves out is kept from the mail server, or from the provider
-- with the same name; an empty one is cleared; any other one is replaced.
applyChange :: (Text -> k) -> ServerSettingsOf (Maybe k) -> ServerSettingsChange -> ServerSettingsOf (Maybe k)
applyChange keep old new =
  ServerSettings
    { publicUrl = new.publicUrl
    , mail = (\m -> withPassword (resolve (old.mail >>= \o -> o.password) m.password) m) <$> new.mail
    , providers = [withSecret (resolve (previous p.name) p.secret) p | p <- new.providers]
    , assistantHosts = new.assistantHosts
    }
  where
    previous name = find (\o -> o.name == name) old.providers >>= \o -> o.secret
    resolve kept = \case
      Nothing -> kept
      Just t
        | T.null t -> Nothing
        | otherwise -> Just (keep t)

-- | A provider as it is checked before it is saved: the given values,
-- with the stored secret for its name if the change gives none.
providerWith :: (Text -> k) -> ServerSettingsOf (Maybe k) -> ProviderChange -> ProviderSettingsOf (Maybe k)
providerWith keep kept p = case (applyChange keep kept noServerSettings {providers = [p]}).providers of
  [resolved] -> resolved
  _ -> withSecret Nothing p

-- | A provider with a different secret, which may be of a different type.
withSecret :: t -> ProviderSettingsOf s -> ProviderSettingsOf t
withSecret secret p = ProviderSettings {name = p.name, kind = p.kind, clientId = p.clientId, issuer = p.issuer, secret}

named :: Text -> ProviderSettingsOf s -> ProviderSettingsOf s
named name p = ProviderSettings {name, kind = p.kind, clientId = p.clientId, issuer = p.issuer, secret = p.secret}

-- | A mail server with a different password.
withPassword :: t -> MailSettingsOf s -> MailSettingsOf t
withPassword password m = MailSettings {host = m.host, port = m.port, security = m.security, user = m.user, password, from = m.from}

--------------------------------------------------------------------------------
-- Mail

-- | 'Security': how the connection to the mail server is protected.
data Security
  = -- | TLS from the start (SMTPS, port 465).
    ImplicitTls
  | -- | A plain connection that the client upgrades with @STARTTLS@ before
    -- sending anything else (submission, port 587).
    StartTls
  | -- | No TLS at all: only for a mail server on the same machine or the
    -- same private network, never across the internet, since the password
    -- and the mail would be sent unencrypted.
    Plain
  deriving stock (Eq, Show, Enum, Bounded)

-- | Its name in the API: @tls@, @starttls@ or @plain@.
securityName :: Security -> Text
securityName = \case
  ImplicitTls -> "tls"
  StartTls -> "starttls"
  Plain -> "plain"

readSecurity :: Text -> Maybe Security
readSecurity t = find (\s -> securityName s == t) [minBound .. maxBound]

instance ToJSON Security where
  toJSON = toJSON . securityName

instance FromJSON Security where
  parseJSON = withText "tls, starttls or plain" $ \t -> maybe (fail ("not tls, starttls or plain: " <> toS t)) pure (readSecurity t)

-- | The security a port implies: implicit TLS on 465, @STARTTLS@ on any other.
securityFor :: Word16 -> Security
securityFor = \case
  465 -> ImplicitTls
  _ -> StartTls

-- | The submission port.
defaultMailPort :: Word16
defaultMailPort = 587

--------------------------------------------------------------------------------
-- Providers

-- | 'ProviderKind': how the server talks to a provider ("Wiki.Server.Oidc" has the details).
data ProviderKind = Google | Apple | GitHub | Generic
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Its name in the API: @google@, @apple@, @github@ or @oidc@ (any OpenID
-- Connect provider, at its issuer).
kindName :: ProviderKind -> Text
kindName = \case
  Google -> "google"
  Apple -> "apple"
  GitHub -> "github"
  Generic -> "oidc"

readKind :: Text -> Maybe ProviderKind
readKind t = find (\k -> kindName k == t) [minBound .. maxBound]

instance ToJSON ProviderKind where
  toJSON = toJSON . kindName

instance FromJSON ProviderKind where
  parseJSON = withText "google, apple, github or oidc" $ \t -> maybe (fail ("not google, apple, github or oidc: " <> toS t)) pure (readKind t)

-- | The name the wiki's pages show for a provider ("Sign in with Google"):
-- its kind's name, or, for @oidc@, its own name capitalised.
providerLabel :: ProviderKind -> Text -> Text
providerLabel kind name = case kind of
  Google -> "Google"
  Apple -> "Apple"
  GitHub -> "GitHub"
  Generic -> case T.uncons name of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> name

-- | The URL a provider redirects the browser back to, which is registered
-- with the provider: @\<public-url>auth\/\<name>\/callback@.
redirectUri :: Url -> Text -> Url
redirectUri publicUrl name = Url (publicUrl.text <> callbackPath name)

--------------------------------------------------------------------------------
-- Checks

-- | The settings as they are stored, or the first reason they are invalid:
-- the address normalised and every text trimmed, a blank text left out.
-- The given function says whether a secret is set; a provider needs one,
-- and so does a mail server that has a user.
checkServerSettings :: (s -> Bool) -> ServerSettingsOf s -> Either Text (ServerSettingsOf s)
checkServerSettings isSet s = do
  publicUrl <- traverse parsePublicUrl (blankless ((\u -> u.text) <$> s.publicUrl))
  mail <- traverse checkMail s.mail
  let providers = map trimProvider s.providers
  case concatMap providerProblems providers <> duplicates providers <> missingSecrets providers of
    why : _ -> Left why
    [] -> pass
  when (isNothing publicUrl && isJust mail) $
    Left "The mail needs the wiki's public address: the links it carries start with it."
  when (isNothing publicUrl && not (null providers)) $
    Left "The providers need the wiki's public address: they send people back below it."
  assistantHosts <- ordNub <$> traverse parseAssistantHost (filter (not . T.null . T.strip) s.assistantHosts)
  pure ServerSettings {publicUrl, mail, providers, assistantHosts}
  where
    checkMail m = do
      let host = T.strip m.host
          sender = T.strip m.from
          user = blankless m.user
      when (T.null host) $ Left "The mail server needs its host."
      when (T.any (\c -> isSpace c || isControl c || c == '/') host) $ Left ("The mail server's host is not one: " <> host)
      when (m.port == 0) $ Left "The mail server's port is a number from 1 to 65535."
      when (T.null sender) $ Left "The mail needs its sender: the address it is sent from."
      when (isJust user && not (isSet m.password)) $ Left ("The mail server's user " <> fromMaybe "" user <> " needs its password.")
      pure MailSettings {host, port = m.port, security = m.security, user, password = m.password, from = sender}
    trimProvider p = ProviderSettings {name = T.strip p.name, kind = p.kind, clientId = T.strip p.clientId, issuer = Url <$> blankless ((\u -> u.text) <$> p.issuer), secret = p.secret}
    duplicates ps =
      let names = map (\p -> p.name) ps
       in ["There are two providers named " <> n <> "." | n <- ordNub names, length (filter (== n) names) > 1]
    missingSecrets ps = ["The provider " <> p.name <> " needs its client secret." | p <- ps, not (isSet p.secret)]
    blankless = mfilter (not . T.null) . fmap T.strip

-- | The wiki's address as the server uses it: @http@ or @https@, with a
-- host, and a slash at the end; or why it is invalid.
parsePublicUrl :: Text -> Either Text Url
parsePublicUrl raw
  | not (any (`T.isPrefixOf` u) ["http://", "https://"]) = Left ("The wiki's public address starts with http:// or https://: " <> u)
  | T.null (T.takeWhile (/= '/') (T.drop 2 (T.dropWhile (/= '/') u))) = Left ("The wiki's public address has no host: " <> u)
  | T.any (\c -> isControl c || isSpace c || c `elem` ("\"<>\\?#" :: [Char])) u = Left ("The wiki's public address has a character an address cannot: " <> u)
  | otherwise = Right (Url (if "/" `T.isSuffixOf` u then u else u <> "/"))
  where
    u = T.strip raw

-- | The reasons a provider's settings are invalid; empty if they are valid.
providerProblems :: ProviderSettingsOf s -> [Text]
providerProblems p =
  [ "A provider's name is lower-case letters, digits and dashes, starting with a letter, at most 32 characters: " <> p.name
  | not (validName p.name)
  ]
    <> ["The provider " <> p.name <> " needs its client id." | T.null (T.strip p.clientId)]
    -- Google takes the short form of its client ids when a person signs
    -- in, but names the full one in the ID token, which the server then
    -- refuses: a short id would fail every sign-in only at its end.
    <> [ "The provider " <> p.name <> "'s client id should end with " <> googleSuffix <> ", as Google writes it."
       | p.kind == Google
       , not (T.null (T.strip p.clientId))
       , not (googleSuffix `T.isSuffixOf` T.strip p.clientId)
       ]
    <> ["The provider " <> p.name <> ", of kind oidc, needs its issuer: https://issuer.example.org" | p.kind == Generic, isNothing p.issuer]
    <> [ "The provider " <> p.name <> "'s address " <> i.text <> " must start with https:// (or http:// on this machine, for a test)."
       | Just i <- [p.issuer]
       , not (secureAddress i)
       ]
  where
    googleSuffix = ".apps.googleusercontent.com"
    validName n =
      not (T.null n)
        && T.length n <= 32
        && maybe False (isAsciiLower . fst) (T.uncons n)
        && T.all (\c -> isAsciiLower c || isDigit c || c == '-') n

-- | Whether secrets may be sent to an address: over TLS, or on this
-- machine.
secureAddress :: Url -> Bool
secureAddress (Url a) =
  "https://" `T.isPrefixOf` a
    || any (\here -> ("http://" <> here) `T.isPrefixOf` a) ["127.0.0.1:", "127.0.0.1/", "localhost:", "localhost/", "[::1]:"]

--------------------------------------------------------------------------------
-- Checking a provider

-- | 'ProviderCheck': the result of a provider's discovery, the response to
-- @POST \/api\/v1\/admin\/server\/providers\/\<name>\/check@.
data ProviderCheck = ProviderCheck
  { redirectUri :: Maybe Url
  -- ^ The redirect URI to register with the provider, once the wiki has a
  -- public address.
  , clientSecret :: SecretState
  -- ^ Whether its client secret is set.
  , discovered :: Maybe Discovered
  -- ^ Its endpoints, if discovery succeeded.
  , problem :: Maybe Text
  -- ^ Why discovery failed, for a person to read.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Discovered': the endpoints discovery found.
data Discovered = Discovered
  { issuer :: Url
  , authorization :: Url
  , token :: Url
  , userinfo :: Maybe Url
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- A test mail

-- | The body of @POST \/api\/v1\/admin\/server\/mail\/test@: the address to
-- send a test mail to, through the configured mail server.
newtype MailTest = MailTest {to :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether the test mail was sent: 'Nothing', or why not.
newtype MailTestResult = MailTestResult {failure :: Maybe Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
