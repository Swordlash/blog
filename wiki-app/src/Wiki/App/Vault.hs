-- | The user's vault on this device (WP5.74 of docs/PLAN.md,
-- "Wiki.Core.Vault"): the vault key and the user's key pair, as this
-- browser keeps them, and the steps that bring them up to date with the
-- server's vault. The writing assistant's part of the vault is
-- "Wiki.App.Assistant.Keys"'s; this module is the rest.
--
-- = What this device keeps
--
-- The browser keeps three things per user, apart from the assistant's:
--
-- * the vault key, as a WebCrypto key that cannot be exported, in the
--   IndexedDB slot 'vaultSlot';
-- * the private half of the user's key pair, as a WebCrypto key that
--   cannot be exported either, in the slot 'identitySlot';
-- * a small record ('VaultDevice'), in the assistant's database under the
--   same name as the vault key's slot: the id of the key pair this device
--   holds, and whether it asks for an unlock each time the wiki opens.
--
-- With "ask each time", both keys are kept for the page's life only, so
-- that a reload asks for the passkey or the password again.
--
-- = Bringing the device up to date
--
-- 'settleKeys' fetches the server's vault and finds the vault key on this
-- device: the one kept in 'vaultSlot', or the assistant's when its
-- settings sync, or the one a password unwraps. It checks that the key
-- opens the vault. With it, the user's private key is unsealed and kept
-- here when this device does not hold it yet; and when the vault holds no
-- key pair yet, one is made, its private half sealed into the vault and
-- its public half stored in the server's directory, in one request.
-- Without the vault key nothing changes: the device waits for an unlock.
--
-- = Security
--
-- The server never sees the vault key, the private key or anything
-- sealed. The vault is as strong as its weakest way to unlock: with a
-- password's wrap, the password; without one, the passkeys. The server is
-- trusted for the directory of public keys: it could give another user a
-- key that is not this user's, and only comparing fingerprints catches
-- that. And a server, or an administrator, that changes the JavaScript it
-- sends reads whatever the browser opens: that is not defended against.
module Wiki.App.Vault
  ( -- * This device
    VaultDevice (..)
  , vaultSlot
  , identitySlot
  , readDevice
  , writeDevice

    -- * The user's keys
  , UserKeys (..)
  , loadUserKeys
  , settleKeys
  , opensVault
  , keepVaultKey
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.!=), (.:?), (.=))
import Data.ByteString.Lazy qualified as BSL
import Protolude
import Wiki.Api.Vault (NewPublicKey (..), PublicKeyEntry (..), StoredVault (..), VaultChange (..))
import Wiki.App.Assistant (KeyRef, MonadAssistant (..), NewIdentity (..))
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant.Vault (assistantItem, sealingData)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Vault (Item (..), KeyId, Vault (..), identityItem, itemOf, withItem)

--------------------------------------------------------------------------------
-- This device

-- | 'VaultDevice': what this device records of the user's vault, beside
-- the keys it holds: the id of the key pair whose private half it holds,
-- and whether it keeps the keys for the page's life only.
data VaultDevice = VaultDevice
  { held :: Maybe KeyId
  , askEachTime :: Bool
  }
  deriving stock (Eq, Show)

instance ToJSON VaultDevice where
  toJSON d = object ["held" .= d.held, "askEachTime" .= d.askEachTime]

instance FromJSON VaultDevice where
  parseJSON = withObject "VaultDevice" $ \o -> VaultDevice <$> o .:? "held" <*> o .:? "askEachTime" .!= False

-- | The slot of this device's IndexedDB where the user's vault key is kept,
-- and the name its 'VaultDevice' record is stored under. The assistant's
-- own key and record are under the user's id alone, as before the vault
-- held anything else, so that a tab of an older version, which reads only
-- that, finds what it wrote.
vaultSlot :: UserId -> UserId
vaultSlot u = UserId ("vault:" <> u.text)

-- | The slot where the private half of the user's key pair is kept.
identitySlot :: UserId -> UserId
identitySlot u = UserId ("identity:" <> u.text)

-- | What this device records of the user's vault; nothing recorded is a
-- device that holds no key pair and does not ask each time.
readDevice :: (MonadAssistant m) => UserId -> m VaultDevice
readDevice u =
  deviceRecord (vaultSlot u) <&> \case
    Right (Just bytes) | Right d <- eitherDecodeStrict bytes -> d
    _ -> VaultDevice {held = Nothing, askEachTime = False}

-- | Record what this device holds of the user's vault.
writeDevice :: (MonadAssistant m) => UserId -> VaultDevice -> m (Either Text ())
writeDevice u d = keepDeviceRecord (vaultSlot u) (Just (BSL.toStrict (encode d)))

--------------------------------------------------------------------------------
-- The user's keys

-- | 'UserKeys': the user's vault and key pair as the security panel shows
-- them.
data UserKeys = UserKeys
  { vault :: Maybe StoredVault
  -- ^ The server's vault, if the user has one.
  , publicKey :: Maybe PublicKeyEntry
  -- ^ The user's current public key in the directory.
  , fingerprint :: Text
  -- ^ Its fingerprint (SHA-256, in hexadecimal), empty without one.
  , unlocked :: Bool
  -- ^ Whether this device holds a vault key that opens the vault.
  , heldHere :: Bool
  -- ^ Whether this device holds the private half of the current key pair.
  , askEachTime :: Bool
  -- ^ Whether this device keeps the keys for the page's life only.
  }
  deriving stock (Eq, Show)

type Step m = ExceptT Text m

-- | The user's keys as the server and this device have them, without
-- changing anything.
loadUserKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
loadUserKeys u = runExceptT $ do
  stored <- fetched
  key <- lift (vaultKeyHere u stored)
  lift (traverse_ forgetKey key)
  describe u stored (isJust key)

-- | Bring this device up to date with the user's vault: find the vault key
-- here (or with the password's wrapping key, if one is given), keep it,
-- and with it unseal the user's private key, or make the user's key pair
-- when the vault holds none.
settleKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
settleKeys u = runExceptT $ do
  stored <- fetched
  device <- lift (readDevice u)
  lift (vaultKeyHere u stored) >>= \case
    Nothing -> describe u stored False
    Just key -> do
      keepVaultKey u key (not device.askEachTime)
      fresh <- case stored of
        Just s -> Just <$> withIdentity u device key s
        Nothing -> pure Nothing
      lift (forgetKey key)
      describe u fresh True

-- | The server's vault, if the user has one.
fetched :: (MonadVault m) => Step m (Maybe StoredVault)
fetched =
  lift (fetchVault Nothing) >>= \case
    Right (Fetched s) -> pure (Just s)
    Right _ -> pure Nothing
    Left e -> throwError ("The vault could not be fetched: " <> wikiText e)

-- | What the panel shows, from the vault fetched and this device.
describe :: (MonadAssistant m, MonadVault m) => UserId -> Maybe StoredVault -> Bool -> Step m UserKeys
describe u stored unlocked = do
  current <- either (\e -> throwError ("The directory of public keys could not be read: " <> wikiText e)) pure =<< lift (publicKeyOf u)
  device <- lift (readDevice u)
  printed <- maybe (pure "") (lift . fingerprintOf . (\k -> k.publicKey)) current
  key <- lift (deviceKey (identitySlot u))
  lift (traverse_ forgetKey key)
  pure
    UserKeys
      { vault = stored
      , publicKey = current
      , fingerprint = printed
      , unlocked
      , heldHere = isJust key && isJust current && device.held == ((\c -> c.keyId) <$> current)
      , askEachTime = device.askEachTime
      }

-- | The vault key this device holds that opens the vault, if it holds one:
-- the vault's own slot first, then the assistant's (whose key is the
-- vault key when its settings sync). The key is the caller's to forget.
vaultKeyHere :: (MonadAssistant m) => UserId -> Maybe StoredVault -> m (Maybe KeyRef)
vaultKeyHere u = \case
  Nothing -> pure Nothing
  Just s -> firstOpening [deviceKey (vaultSlot u), deviceKey u]
    where
      firstOpening = \case
        [] -> pure Nothing
        candidate : rest ->
          candidate >>= \case
            Nothing -> firstOpening rest
            Just k ->
              opensVault k s.vault >>= \case
                True -> pure (Just k)
                False -> forgetKey k >> firstOpening rest

-- | Whether a key opens the vault: whether it opens the vault's key pair,
-- or else the assistant's settings.
opensVault :: (MonadAssistant m) => KeyRef -> Vault -> m Bool
opensVault k v = case (itemOf identityItem v, itemOf assistantItem v) of
  (Just i, _)
    | Just keyId <- i.keyId ->
        openIdentity k keyId i.sealed >>= \case
          Right opened -> forgetKey opened $> True
          Left _ -> pure False
  (_, Just a) -> isRight <$> openWith k a.sealed sealingData
  _ -> pure False

-- | Keep the vault key as this device's: on disk, or for the page's life
-- only.
keepVaultKey :: (MonadAssistant m) => UserId -> KeyRef -> Bool -> Step m ()
keepVaultKey u key onDisk = ExceptT (keepDeviceKey (vaultSlot u) key onDisk)

-- | The vault with the user's key pair: the private key unsealed and kept
-- here when this device does not hold it, or a key pair made and stored
-- when the vault holds none. The result is the vault as stored now.
withIdentity :: (MonadAssistant m, MonadVault m) => UserId -> VaultDevice -> KeyRef -> StoredVault -> Step m StoredVault
withIdentity u device key s = case itemOf identityItem s.vault of
  Just i | Just keyId <- i.keyId -> do
    here <- lift (deviceKey (identitySlot u))
    case here of
      Just h | device.held == Just keyId -> lift (forgetKey h)
      _ -> do
        lift (traverse_ forgetKey here)
        opened <- ExceptT (openIdentity key keyId i.sealed)
        keepIdentity opened keyId
    pure s
  Just _ -> throwError "The vault's key pair has no id: it cannot be opened."
  Nothing -> do
    made <- ExceptT (newIdentity key)
    let item = Item {keyId = Just made.keyId, sealed = made.sealed}
        change = VaultChange {vault = withItem identityItem item s.vault, publicKey = Just NewPublicKey {keyId = made.keyId, publicKey = made.publicKey}}
    lift (storeVaultChange (Just s.tag) change) >>= \case
      Left e -> lift (forgetKey made.key) >> throwError ("Your key pair could not be stored: " <> wikiText e)
      Right fresh -> keepIdentity made.key made.keyId $> fresh
  where
    keepIdentity k keyId = do
      kept <- lift (keepDeviceKey (identitySlot u) k (not device.askEachTime))
      lift (forgetKey k)
      either throwError pure kept
      ExceptT (writeDevice u device {held = Just keyId})

-- | What a backend's refusal says.
wikiText :: WikiError -> Text
wikiText = \case
  NotFound -> "The server knows nothing of it."
  Forbidden -> "The server refused it."
  Conflict t -> t
  Invalid t -> t
  Unreachable t -> "The server could not be reached: " <> t
