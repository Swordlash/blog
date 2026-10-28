-- | The vault: the writing assistant's settings encrypted (WP5.21 of
-- docs/PLAN.md). The settings hold the user's API keys
-- ("Wiki.Core.Assistant"), so neither this browser's IndexedDB nor the
-- wiki's server keeps them as text.
--
-- = How the vault is locked
--
-- A random key, the vault key (AES-GCM, 256 bits), encrypts the settings
-- that matter: the keys, the models, the efforts and the base URLs
-- ('secretsOf'). The result is 'Sealed': a nonce and the ciphertext. The
-- model lists fetched from the providers, and whether each provider could
-- be reached, are not secret, and stay out of the vault ('learntOf').
--
-- To follow the user to another device, the vault key itself is
-- encrypted ("wrapped") once per passkey ('WrappedKey'). The key that
-- wraps it is derived (HKDF-SHA256) from the output of the passkey's PRF
-- extension (WebAuthn), evaluated on the vault's salt. The authenticator
-- computes that output from a secret that never leaves it, the same on
-- every device the passkey is synced to, so one touch of the passkey on a
-- new device unwraps the vault key there. The browser never sends the PRF
-- output, the vault key or the settings to the server. The server stores
-- the 'Vault' (the salt, the sealed settings, and the wrapped copies by
-- the passkeys' credential ids) and gives it back; it cannot open it.
--
-- The cryptography runs in the browser, with WebCrypto
-- (@wiki-app\/jsbits\/vault.js@). This module is the format, pure: what is
-- sealed, how the vault and this device's record are written, and how
-- they change.
--
-- = This device's record
--
-- A device keeps a 'DeviceRecord' per user in IndexedDB: the settings
-- sealed with this device's key, a copy of the server's vault when the
-- device follows it, the learnt parts in the clear, and whether the
-- device asks for the passkey each time the wiki opens. The device's key
-- is kept apart, as a WebCrypto key that cannot be exported. Without
-- synchronisation the record has the same sealed settings and the same
-- kind of key, so the plain keys are never stored. A record written
-- before the vault existed was the settings as text ('OldSettings'); it
-- is sealed and replaced the first time it is read.
module Wiki.Core.Assistant.Vault
  ( -- * The vault
    Vault (..)
  , vaultFormat
  , Sealed (..)
  , WrappedKey (..)
  , CredentialId (..)
  , VaultTag (..)
  , sealedOf
  , withSealed
  , withWrapped
  , withoutPasskey
  , wrappedFor
  , sealingData
  , wrappingData
  , wrappingInfo

    -- * What is sealed
  , secretsOf
  , learntOf
  , joinSettings
  , mergeUnlocked

    -- * This device's record
  , DeviceRecord (..)
  , ServerCopy (..)
  , deviceFormat
  , emptyRecord
  , Stored (..)
  , readStored
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), eitherDecodeStrict, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Map.Merge.Strict qualified as Merge
import Data.Map.Strict qualified as Map
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import Wiki.Core.Assistant (Provider (..), ProviderSettings (..), Settings (..), defaultSettings)

--------------------------------------------------------------------------------
-- The vault

-- | The version of the vault's format that this module writes. A vault of
-- a later version is refused as made by a newer wiki, rather than misread.
vaultFormat :: Int
vaultFormat = 1

-- | 'CredentialId': a passkey's credential id, in base64url without
-- padding, as WebAuthn writes it. The vault keeps a wrapped copy of its
-- key under each.
newtype CredentialId = CredentialId {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'VaultTag': the version of the vault on the server, as its @ETag@
-- gives it. A device keeps the tag of the copy it has, and fetches the
-- vault again only when the server's tag differs; a change is stored
-- only over the version it was made to.
newtype VaultTag = VaultTag {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'Sealed': text encrypted with AES-GCM: the 12-byte nonce and the
-- ciphertext with its tag, each in base64url. Its 'Show' instance prints
-- neither, although neither reveals anything without the key.
data Sealed = Sealed
  { nonce :: Text
  , ciphertext :: Text
  }
  deriving stock (Eq)

instance Show Sealed where
  showsPrec _ _ rest = "Sealed <ciphertext>" <> rest

instance ToJSON Sealed where
  toJSON s = object ["nonce" .= s.nonce, "ciphertext" .= s.ciphertext]

instance FromJSON Sealed where
  parseJSON = withObject "Sealed" $ \o -> Sealed <$> o .: "nonce" <*> o .: "ciphertext"

-- | 'WrappedKey': the vault key encrypted with the key derived from one
-- passkey's PRF output: the nonce and the encrypted key, in base64url.
data WrappedKey = WrappedKey
  { nonce :: Text
  , key :: Text
  }
  deriving stock (Eq)

instance Show WrappedKey where
  showsPrec _ _ rest = "WrappedKey <encrypted>" <> rest

instance ToJSON WrappedKey where
  toJSON w = object ["nonce" .= w.nonce, "key" .= w.key]

instance FromJSON WrappedKey where
  parseJSON = withObject "WrappedKey" $ \o -> WrappedKey <$> o .: "nonce" <*> o .: "key"

-- | 'Vault': the settings as the server stores them for a user. It holds
-- the format's version, the salt the passkeys' PRF is evaluated on (32
-- random bytes in base64url, chosen once per user when the vault is
-- made), the sealed settings, and the vault key wrapped for each passkey.
data Vault = Vault
  { format :: Int
  , salt :: Text
  , sealed :: Sealed
  , wrapped :: Map CredentialId WrappedKey
  }
  deriving stock (Eq, Show)

-- | Written as one object: @format@, @salt@, @nonce@, @ciphertext@, and
-- @wrapped@, an object by credential id.
instance ToJSON Vault where
  toJSON v =
    object
      [ "format" .= v.format
      , "salt" .= v.salt
      , "nonce" .= v.sealed.nonce
      , "ciphertext" .= v.sealed.ciphertext
      , "wrapped" .= Map.mapKeys (\c -> c.text) v.wrapped
      ]

instance FromJSON Vault where
  parseJSON = withObject "Vault" $ \o -> do
    format <- o .: "format"
    when (format > vaultFormat) (fail ("a vault of format " <> show format <> ", which a newer version of the wiki made"))
    when (format < 1) (fail ("not a vault's format: " <> show format))
    Vault format
      <$> o
      .: "salt"
      <*> (Sealed <$> o .: "nonce" <*> o .: "ciphertext")
      <*> (Map.mapKeys CredentialId <$> o .:? "wrapped" .!= mempty)

-- | The sealed settings of a vault.
sealedOf :: Vault -> Sealed
sealedOf v = v.sealed

-- | A vault with its settings sealed again (after a change), its salt and
-- its wrapped keys as they were: the vault key has not changed.
withSealed :: Sealed -> Vault -> Vault
withSealed s v = Vault {format = v.format, salt = v.salt, sealed = s, wrapped = v.wrapped}

-- | A vault with the vault key wrapped for one more passkey, or wrapped
-- anew for one it had.
withWrapped :: CredentialId -> WrappedKey -> Vault -> Vault
withWrapped c w v = v {wrapped = Map.insert c w v.wrapped}

-- | A vault without a passkey's wrapped copy of its key: the passkey,
-- removed, opens it no more.
withoutPasskey :: CredentialId -> Vault -> Vault
withoutPasskey c v = v {wrapped = Map.delete c v.wrapped}

-- | A passkey's wrapped copy of the vault key, if the vault has one.
wrappedFor :: CredentialId -> Vault -> Maybe WrappedKey
wrappedFor c v = Map.lookup c v.wrapped

-- | The additional data AES-GCM authenticates with the sealed settings:
-- the format's name and version. A ciphertext of another kind, or of
-- another format, then fails to open rather than being read as settings.
sealingData :: Text
sealingData = "wiki-assistant-vault/1 settings"

-- | The additional data AES-GCM authenticates with a wrapped vault key.
wrappingData :: Text
wrappingData = "wiki-assistant-vault/1 vault key"

-- | The @info@ of the HKDF that derives the key wrapping the vault key
-- from a passkey's PRF output, whose salt is the vault's.
wrappingInfo :: Text
wrappingInfo = "wiki-assistant-vault/1 wrapping key"

--------------------------------------------------------------------------------
-- What is sealed

-- | The part of the settings the vault seals: the chosen provider, and
-- each provider's key, model, effort and base URL. What was learnt from a
-- provider (its model list, whether it could be reached) is left out.
secretsOf :: Settings -> Settings
secretsOf s = s {byProvider = Map.map (\(ProviderSettings k m e b _ _) -> ProviderSettings k m e b Nothing False) s.byProvider}

-- | The part of the settings a device keeps in the clear: what was learnt
-- from each provider, and nothing a user typed.
learntOf :: Settings -> Settings
learntOf s = Settings {provider = Anthropic, byProvider = Map.map (\(ProviderSettings _ _ _ _ f u) -> ProviderSettings Nothing Nothing Nothing Nothing f u) s.byProvider}

-- | The settings made whole again: the sealed part, with what was learnt
-- from each provider, which only applies while the provider's key and
-- base URL are those it was learnt with. (A device does not know that for
-- sure: a list learnt with another key is kept until it is a day old, as
-- 'Wiki.Core.Assistant.listStale' says, and then fetched again.)
joinSettings :: Settings -> Settings -> Settings
joinSettings secrets learnt =
  secrets
    { byProvider =
        Merge.merge
          (Merge.mapMissing (\_ ps -> ps))
          (Merge.mapMissing (\_ (ProviderSettings _ _ _ _ f u) -> ProviderSettings Nothing Nothing Nothing Nothing f u))
          (Merge.zipWithMatched (\_ (ProviderSettings k m e b _ _) (ProviderSettings _ _ _ _ f u) -> ProviderSettings k m e b f u))
          secrets.byProvider
          learnt.byProvider
    }

-- | The settings after a device unlocks the vault, having been used
-- before it could: the vault's settings, and for a provider the vault has
-- no key nor base URL for, the one typed on this device meanwhile. A key
-- typed on the device does not replace the vault's, which every other
-- device uses.
mergeUnlocked :: Settings -> Settings -> Settings
mergeUnlocked vault typed =
  vault {byProvider = Map.unionWith pick vault.byProvider typed.byProvider}
  where
    pick fromVault fromHere
      | set fromVault = fromVault
      | set fromHere = fromHere
      | otherwise = fromVault
    set (ProviderSettings k _ _ b _ _) = isJust k || isJust b

--------------------------------------------------------------------------------
-- This device's record

-- | The version of the device record's format that this module writes.
deviceFormat :: Int
deviceFormat = 1

-- | 'ServerCopy': the server's vault as this device last fetched it, with
-- the tag of that version.
data ServerCopy = ServerCopy
  { tag :: VaultTag
  , vault :: Vault
  }
  deriving stock (Eq, Show)

instance ToJSON ServerCopy where
  toJSON c = object ["tag" .= c.tag, "vault" .= c.vault]

instance FromJSON ServerCopy where
  parseJSON = withObject "ServerCopy" $ \o -> ServerCopy <$> o .: "tag" <*> o .: "vault"

-- | 'DeviceRecord': what a device keeps for a user.
data DeviceRecord = DeviceRecord
  { sealed :: Maybe Sealed
  -- ^ The settings, sealed with this device's key. When the device follows
  -- the server's vault and has unlocked it, that key is the vault key, and
  -- this is the vault's own sealed settings. Before it has, it is what was
  -- typed on this device, under a key of its own ('mergeUnlocked').
  , server :: Maybe ServerCopy
  -- ^ The server's vault, when this device follows it.
  , learnt :: Settings
  -- ^ What was learnt from the providers ('learntOf'), in the clear.
  , askEachTime :: Bool
  -- ^ Whether the device keeps no key, and asks for the passkey each time
  -- the wiki opens. Off unless the user turns it on.
  }
  deriving stock (Eq, Show)

-- | A record of nothing: no settings, no vault.
emptyRecord :: DeviceRecord
emptyRecord = DeviceRecord {sealed = Nothing, server = Nothing, learnt = defaultSettings, askEachTime = False}

-- | Written as one object with @device@, the format's version, which tells
-- a record from the settings written as text before the vault existed.
instance ToJSON DeviceRecord where
  toJSON r =
    object
      [ "device" .= deviceFormat
      , "sealed" .= r.sealed
      , "server" .= r.server
      , "learnt" .= r.learnt
      , "askEachTime" .= r.askEachTime
      ]

instance FromJSON DeviceRecord where
  parseJSON = withObject "DeviceRecord" $ \o -> do
    format <- o .: "device"
    when (format > deviceFormat) (fail ("a device record of format " <> show (format :: Int) <> ", which a newer version of the wiki wrote"))
    DeviceRecord
      <$> o
      .:? "sealed"
      <*> o .:? "server"
      <*> o .:? "learnt" .!= defaultSettings
      <*> o .:? "askEachTime" .!= False

-- | 'Stored': what IndexedDB holds for a user, as read.
data Stored
  = -- | A device record.
    Current DeviceRecord
  | -- | The settings as text, as they were stored before the vault
    -- existed (WP4.19). They are sealed into a record, and replaced by it,
    -- the first time they are read.
    OldSettings Settings
  deriving stock (Eq, Show)

-- | What IndexedDB holds for a user, or why it cannot be read: a record
-- (an object with @device@), or the old settings as text.
readStored :: ByteString -> Either Text Stored
readStored bytes = first toS $ do
  value <- eitherDecodeStrict bytes
  case value of
    Object o | KeyMap.member "device" o -> Current <$> parseEither parseJSON value
    _ -> OldSettings <$> parseEither (parseJSON :: Value -> Parser Settings) value
