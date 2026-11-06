-- | The writing assistant's part of the user's vault (WP5.21 of
-- docs/PLAN.md, "Wiki.Core.Vault"). The assistant's settings hold the
-- user's API keys ("Wiki.Core.Assistant"), so neither this browser's
-- IndexedDB nor the wiki's server keeps them as text.
--
-- = What is sealed
--
-- The vault key seals the settings that matter: the keys, the models, the
-- efforts and the base URLs ('secretsOf'), as the vault's item
-- @assistant@ ('assistantItem'). The model lists fetched from the
-- providers, and whether each provider could be reached, are not secret,
-- and stay out of the vault ('learntOf').
--
-- The settings sync across the user's devices when the vault has the
-- @assistant@ item, and only then: a vault made for other items (the
-- user's key pair) does not make the assistant sync. Syncing still needs a
-- passkey, as it did before the vault held anything else.
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
  ( -- * The vault ("Wiki.Core.Vault")
    module Wiki.Core.Vault

    -- * The assistant's item
  , assistantItem
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
import Wiki.Core.Assistant (Mode (..), Provider (..), ProviderSettings (..), Settings (..), defaultSettings)
import Wiki.Core.Vault

--------------------------------------------------------------------------------
-- The assistant's item

-- | The name the assistant's settings are kept under in the vault.
assistantItem :: ItemName
assistantItem = ItemName "assistant"

-- | The sealed settings of a vault, if it has them: whether the
-- assistant's settings sync.
sealedOf :: Vault -> Maybe Sealed
sealedOf v = (\i -> i.sealed) <$> itemOf assistantItem v

-- | A vault with its settings sealed again (after a change), or sealed for
-- the first time; its salt, its wraps and its other items as they were:
-- the vault key has not changed.
withSealed :: Sealed -> Vault -> Vault
withSealed s = withItem assistantItem Item {keyId = Nothing, sealed = s}

-- | A vault with the vault key wrapped for one more passkey, or wrapped
-- anew for one it had.
withWrapped :: CredentialId -> WrappedKey -> Vault -> Vault
withWrapped c = withWrap (ByPasskey c)

-- | A vault without a passkey's wrapped copy of its key: the passkey,
-- removed, opens it no more.
withoutPasskey :: CredentialId -> Vault -> Vault
withoutPasskey c = withoutWrap (ByPasskey c)

-- | A passkey's wrapped copy of the vault key, if the vault has one.
wrappedFor :: CredentialId -> Vault -> Maybe WrappedKey
wrappedFor c = wrapFor (ByPasskey c)

-- | The additional data AES-GCM authenticates with the sealed settings:
-- the format's name and version. A ciphertext of another kind, or of
-- another format, then fails to open rather than being read as settings.
-- The three strings are those WP5.21 sealed and wrapped every existing
-- vault with, and stay as they are: a change would leave every vault
-- made before it unopenable.
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

-- | The part of the settings the vault seals: the chosen provider, the
-- mode, and each provider's key, model, effort and base URL. What was
-- learnt from a provider (its model list, whether it could be reached) is
-- left out.
secretsOf :: Settings -> Settings
secretsOf s = s {byProvider = Map.map (\(ProviderSettings k m e b _ _) -> ProviderSettings k m e b Nothing False) s.byProvider}

-- | The part of the settings a device keeps in the clear: what was learnt
-- from each provider, and nothing a user typed.
learntOf :: Settings -> Settings
learntOf s = Settings {provider = Anthropic, chatMode = Agent, byProvider = Map.map (\(ProviderSettings _ _ _ _ f u) -> ProviderSettings Nothing Nothing Nothing Nothing f u) s.byProvider}

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
