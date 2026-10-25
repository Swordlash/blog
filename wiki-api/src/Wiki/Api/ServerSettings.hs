{-# LANGUAGE DeriveAnyClass #-}

-- | The server's own settings (WP4.4 of docs/PLAN.md): the wiki's public
-- address, the mail server invitations go through, and the providers
-- people sign in with. They are set in the administration's "Server"
-- section and nowhere else (the owner's decision of 2026-10-25): the
-- loopback admin listener of decision 11 is how the first ones are set,
-- before anyone can sign in, so the server needs no option for them.
--
-- = Secrets
--
-- The mail account's password and each provider's client secret are
-- written once and never read back. What the API answers carries only
-- whether one is set ('SecretState'); what it is sent carries, for each, a
-- 'Maybe Text': 'Nothing' (or the field left out) keeps the secret as it
-- is, an empty text clears it, and any other text replaces it. So the
-- settings are one type with the secret as its parameter
-- ('ServerSettingsOf'): 'ServerSettings' as they are read,
-- 'ServerSettingsChange' as they are written, and, on the server and in
-- the demo, the settings as kept, with the secrets themselves.
--
-- A provider is known by its name, which is in its redirect URI
-- ('redirectUri') and in the wiki's record of who signs in with it: a
-- change that keeps the name keeps the provider's secret unless it gives a
-- new one; a provider left out of a change is removed, with its secret.
-- Leaving the mail server out ('Nothing') removes it with its password.
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
  , checkPublicUrl
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
import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Char (isAsciiLower)
import Data.Text qualified as T
import Protolude
import Wiki.Api.Auth (callbackPath)

--------------------------------------------------------------------------------
-- The settings

-- | The server's settings, with each secret as an @s@.
data ServerSettingsOf s = ServerSettings
  { publicUrl :: Maybe Text
  -- ^ The wiki's address as its readers reach it, ending in a slash
  -- (@https:\/\/wiki.example.org\/@): where mailed links and the
  -- providers' redirect URIs start. The server cannot know it by itself
  -- behind a proxy.
  , mail :: Maybe (MailSettingsOf s)
  -- ^ The mail server invitations go through; without one the
  -- administration shows an invitation's link to pass on.
  , providers :: [ProviderSettingsOf s]
  -- ^ The providers people may sign in with, in the order their buttons
  -- show.
  }
  deriving stock (Eq, Show, Generic, Functor)

-- | As the API answers them.
type ServerSettings = ServerSettingsOf SecretState

-- | As the API is sent them: each secret kept, replaced or cleared.
type ServerSettingsChange = ServerSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (ServerSettingsOf s)

instance (FromJSON s) => FromJSON (ServerSettingsOf s)

-- | A mail server, over SMTP.
data MailSettingsOf s = MailSettings
  { host :: Text
  , port :: Word16
  , security :: Security
  , user :: Maybe Text
  -- ^ The account to sign in to it as, if it wants one.
  , password :: s
  -- ^ That account's password.
  , from :: Text
  -- ^ The sender: @wiki\@example.org@, or @Wiki \<wiki\@example.org>@.
  }
  deriving stock (Eq, Show, Generic, Functor)

type MailSettings = MailSettingsOf SecretState

type MailChange = MailSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (MailSettingsOf s)

instance (FromJSON s) => FromJSON (MailSettingsOf s)

-- | A provider to sign in with.
data ProviderSettingsOf s = ProviderSettings
  { name :: Text
  -- ^ Its name in the wiki's addresses (@auth\/\<name>\/…@): lower-case
  -- letters, digits and dashes.
  , kind :: ProviderKind
  , clientId :: Text
  -- ^ The client's id the provider gave when the wiki was registered
  -- there.
  , issuer :: Maybe Text
  -- ^ For @oidc@, the issuer; for another kind, an address in place of
  -- its own (a GitHub Enterprise server's, say).
  , secret :: s
  -- ^ The client's secret.
  }
  deriving stock (Eq, Show, Generic, Functor)

type ProviderSettings = ProviderSettingsOf SecretState

type ProviderChange = ProviderSettingsOf (Maybe Text)

instance (ToJSON s) => ToJSON (ProviderSettingsOf s)

instance (FromJSON s) => FromJSON (ProviderSettingsOf s)

-- | A server nobody has set up: no address, no mail, no provider. So a
-- wiki made before there were these settings goes on as it was.
noServerSettings :: ServerSettingsOf s
noServerSettings = ServerSettings {publicUrl = Nothing, mail = Nothing, providers = []}

--------------------------------------------------------------------------------
-- Secrets

-- | Whether a secret is set, which is all that is ever said of one.
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

-- | Whether a secret kept is there.
secretState :: Maybe k -> SecretState
secretState = maybe NotSet (const Set)

-- | The settings kept, with secrets kept as @k@ (made from the text sent
-- by the function given), once a change is written over them: each
-- secret the change leaves out kept from the mail server or the provider
-- of the same name, each empty one cleared, each other one replaced.
applyChange :: (Text -> k) -> ServerSettingsOf (Maybe k) -> ServerSettingsChange -> ServerSettingsOf (Maybe k)
applyChange keep old new =
  ServerSettings
    { publicUrl = new.publicUrl
    , mail = (\m -> withPassword (resolve (old.mail >>= \o -> o.password) m.password) m) <$> new.mail
    , providers = [withSecret (resolve (previous p.name) p.secret) p | p <- new.providers]
    }
  where
    previous name = find (\o -> o.name == name) old.providers >>= \o -> o.secret
    resolve kept = \case
      Nothing -> kept
      Just t
        | T.null t -> Nothing
        | otherwise -> Just (keep t)

-- | A provider as checked before it is saved: the values given, with the
-- secret kept for its name if none is given.
providerWith :: (Text -> k) -> ServerSettingsOf (Maybe k) -> ProviderChange -> ProviderSettingsOf (Maybe k)
providerWith keep kept p = case (applyChange keep kept noServerSettings {providers = [p]}).providers of
  [resolved] -> resolved
  _ -> withSecret Nothing p

-- | A provider with another secret, or another name.
withSecret :: t -> ProviderSettingsOf s -> ProviderSettingsOf t
withSecret secret p = ProviderSettings {name = p.name, kind = p.kind, clientId = p.clientId, issuer = p.issuer, secret}

named :: Text -> ProviderSettingsOf s -> ProviderSettingsOf s
named name p = ProviderSettings {name, kind = p.kind, clientId = p.clientId, issuer = p.issuer, secret = p.secret}

-- | A mail server with another password.
withPassword :: t -> MailSettingsOf s -> MailSettingsOf t
withPassword password m = MailSettings {host = m.host, port = m.port, security = m.security, user = m.user, password, from = m.from}

--------------------------------------------------------------------------------
-- Mail

-- | How the connection to the mail server is protected.
data Security
  = -- | TLS from the start (SMTPS, port 465).
    ImplicitTls
  | -- | A plain connection that the client upgrades with @STARTTLS@ before
    -- it says anything else (submission, port 587).
    StartTls
  | -- | No TLS at all: only for a mail server on the same machine or the
    -- same private network, never across the internet, since the password
    -- and the mail would cross it in the clear.
    Plain
  deriving stock (Eq, Show, Enum, Bounded)

-- | As the API writes it: @tls@, @starttls@ or @plain@.
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

-- | What a port implies: implicit TLS on 465, @STARTTLS@ on any other.
securityFor :: Word16 -> Security
securityFor = \case
  465 -> ImplicitTls
  _ -> StartTls

-- | Submission's port.
defaultMailPort :: Word16
defaultMailPort = 587

--------------------------------------------------------------------------------
-- Providers

-- | How the server talks to a provider ("Wiki.Server.Oidc" says more).
data ProviderKind = Google | Apple | GitHub | Generic
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | As the API writes it: @google@, @apple@, @github@ or @oidc@ (any
-- OpenID Connect provider, at its issuer).
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

-- | How the wiki's pages name a provider ("Sign in with Google"): its
-- kind's own name, or, for @oidc@, its name with a capital.
providerLabel :: ProviderKind -> Text -> Text
providerLabel kind name = case kind of
  Google -> "Google"
  Apple -> "Apple"
  GitHub -> "GitHub"
  Generic -> case T.uncons name of
    Just (c, rest) -> T.cons (toUpper c) rest
    Nothing -> name

-- | Where a provider sends the browser back to, which is registered with
-- it: @\<public-url>auth\/\<name>\/callback@.
redirectUri :: Text -> Text -> Text
redirectUri publicUrl name = publicUrl <> callbackPath name

--------------------------------------------------------------------------------
-- Checks

-- | The settings as they are kept, or the first reason they cannot be:
-- the address normalised and every text trimmed, a blank one left out.
-- The function given says whether a secret is set, which a provider needs,
-- and so does a mail server's user.
checkServerSettings :: (s -> Bool) -> ServerSettingsOf s -> Either Text (ServerSettingsOf s)
checkServerSettings isSet s = do
  publicUrl <- traverse checkPublicUrl (blankless s.publicUrl)
  mail <- traverse checkMail s.mail
  let providers = map trimProvider s.providers
  case concatMap providerProblems providers <> duplicates providers <> missingSecrets providers of
    why : _ -> Left why
    [] -> pass
  when (isNothing publicUrl && isJust mail) $
    Left "The mail needs the wiki's public address: the links it carries start with it."
  when (isNothing publicUrl && not (null providers)) $
    Left "The providers need the wiki's public address: they send people back below it."
  pure ServerSettings {publicUrl, mail, providers}
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
    trimProvider p = ProviderSettings {name = T.strip p.name, kind = p.kind, clientId = T.strip p.clientId, issuer = blankless p.issuer, secret = p.secret}
    duplicates ps =
      let names = map (\p -> p.name) ps
       in ["There are two providers named " <> n <> "." | n <- ordNub names, length (filter (== n) names) > 1]
    missingSecrets ps = ["The provider " <> p.name <> " needs its client secret." | p <- ps, not (isSet p.secret)]
    blankless = mfilter (not . T.null) . fmap T.strip

-- | The wiki's address as the server uses it: @http@ or @https@, with a
-- host, and a slash at its end; or why it is not one.
checkPublicUrl :: Text -> Either Text Text
checkPublicUrl raw
  | not (any (`T.isPrefixOf` u) ["http://", "https://"]) = Left ("The wiki's public address starts with http:// or https://: " <> u)
  | T.null (T.takeWhile (/= '/') (T.drop 2 (T.dropWhile (/= '/') u))) = Left ("The wiki's public address has no host: " <> u)
  | T.any (\c -> isControl c || isSpace c || c `elem` ("\"<>\\?#" :: [Char])) u = Left ("The wiki's public address has a character an address cannot: " <> u)
  | otherwise = Right (if "/" `T.isSuffixOf` u then u else u <> "/")
  where
    u = T.strip raw

-- | Why a provider cannot be set up so, if it cannot.
providerProblems :: ProviderSettingsOf s -> [Text]
providerProblems p =
  [ "A provider's name is lower-case letters, digits and dashes, starting with a letter, at most 32 characters: " <> p.name
  | not (validName p.name)
  ]
    <> ["The provider " <> p.name <> " needs its client id." | T.null (T.strip p.clientId)]
    <> ["The provider " <> p.name <> ", of kind oidc, needs its issuer: https://issuer.example.org" | p.kind == Generic, isNothing p.issuer]
    <> [ "The provider " <> p.name <> "'s address " <> i <> " must start with https:// (or http:// on this machine, for a test)."
       | Just i <- [p.issuer]
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

--------------------------------------------------------------------------------
-- Checking a provider

-- | What asking a provider how to sign in found: the answer to @POST
-- \/api\/v1\/admin\/server\/providers\/\<name>\/check@.
data ProviderCheck = ProviderCheck
  { redirectUri :: Maybe Text
  -- ^ The redirect URI to register with the provider, once the wiki has a
  -- public address.
  , clientSecret :: SecretState
  -- ^ Whether its client secret is set.
  , discovered :: Maybe Discovered
  -- ^ Its endpoints, if it could be asked.
  , problem :: Maybe Text
  -- ^ Why it could not be, for a person to read.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where a provider is asked what.
data Discovered = Discovered
  { issuer :: Text
  , authorization :: Text
  , token :: Text
  , userinfo :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- A test mail

-- | The body of @POST \/api\/v1\/admin\/server\/mail\/test@: whom to send
-- a test mail to, through the mail server as set.
newtype MailTest = MailTest {to :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether the test mail was sent: 'Nothing', or why not.
newtype MailTestResult = MailTestResult {failure :: Maybe Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
