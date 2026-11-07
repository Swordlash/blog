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
  , Settled (..)
  , afterSignIn
  , opensVault
  , keepVaultKey

    -- * Unlocking and the ways to unlock
  , unlockWithPasskey
  , unlockWithPassword
  , addPasswordUnlock
  , removePasswordUnlock
  , createWithPasskey
  , createWithProvedPassword
  , addPasskeyUnlock
  , setVaultAskEachTime

    -- * A new password
  , changeOwnPassword
  , resetLosses

    -- * Steps
  , Step
  , passwordVaultKey
  , newPasskey
  , usedPasskey
  , wrap
  , unwrap
  , server
  , passkey
  , recover
  , withKey
  , forgetting
  , wikiText
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.!=), (.:?), (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Protolude
import Wiki.Api.Account (PasswordChange (..), SignInMethods)
import Wiki.Api.Vault (AssertionOptions (..), AssertionResponse (..), NewPublicKey (..), PublicKeyEntry (..), RegistrationOptions (..), RegistrationResponse (..), StoredVault (..), VaultChange (..))
import Wiki.App.Account (SignInError (..), passwordErrorText)
import Wiki.App.Assistant (KeyRef, Made (..), MonadAssistant (..), NewIdentity (..), PasskeyRefusal (..), Used (..))
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..), Rewrap (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant.Vault (DeviceRecord (..), Stored (..), assistantItem, readStored, sealingData, wrappingData, wrappingInfo)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Password)
import Wiki.Core.Vault (CredentialId, Item (..), KeyId, Salt (..), Unlock (..), Vault (..), WrappedKey, identityItem, itemOf, passkeyWraps, vaultFormat, withItem, withWrap, withoutWrap, wrapFor)

--------------------------------------------------------------------------------
-- This device

-- | 'VaultDevice': what this device records of the user's vault, beside
-- the keys it holds: the id of the key pair whose private half it holds,
-- and whether it keeps the keys for the page's life only.
data VaultDevice = VaultDevice
  { held :: Maybe KeyId
  , askEachTime :: Bool
  , offered :: Bool
  -- ^ Whether this device has offered, after a sign-in, to unlock the
  -- vault with the password too: it offers once.
  }
  deriving stock (Eq, Show)

instance ToJSON VaultDevice where
  toJSON d = object ["held" .= d.held, "askEachTime" .= d.askEachTime, "offered" .= d.offered]

instance FromJSON VaultDevice where
  parseJSON = withObject "VaultDevice" $ \o -> VaultDevice <$> o .:? "held" <*> o .:? "askEachTime" .!= False <*> o .:? "offered" .!= False

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
    _ -> VaultDevice {held = Nothing, askEachTime = False, offered = False}

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

-- | The user's keys as the server and this device have them, without
-- changing anything.
loadUserKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
loadUserKeys u = runExceptT $ do
  stored <- fetched
  key <- lift (vaultKeyHere u stored)
  lift (traverse_ forgetKey key)
  describe u stored (isJust key)

-- | Bring this device up to date with the user's vault: find the vault key
-- here, keep it, and with it unseal the user's private key, or make the
-- user's key pair when the vault holds none.
settleKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
settleKeys u = runExceptT ((\s -> s.keys) <$> settleWith u Nothing)

-- | 'Settled': the user's keys after a sign-in, and the key the password
-- gave, kept for the page's offer to unlock the vault with the password
-- too, when the vault does not yet and this device has not offered it.
-- The offer's key is the caller's to forget.
data Settled = Settled
  { keys :: UserKeys
  , offer :: Maybe KeyRef
  }

-- | Bring this device up to date after a sign-in, with the key the
-- password gave (if the sign-in was with a password, in a browser). A user
-- with no vault gets one: their key pair, the vault key wrapped for the
-- password, since nothing else unlocks it yet. A vault the password
-- unlocks is unlocked with it (a new device). A vault it does not unlock
-- is unlocked as 'settleKeys' does, and the password is offered as one
-- more way to unlock it, once per device.
afterSignIn :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text Settled)
afterSignIn u = do
  key <- takePasswordKey
  -- Where the browser offers no WebCrypto (a page over plain HTTP), there
  -- are no keys to settle: the panel says why.
  here <- sealingHere
  result <- if here then runExceptT (settleWith u key) else pure (Left "This browser offers no encryption to this page.")
  case result of
    Left e -> traverse_ forgetKey key $> Left e
    Right settled -> do
      -- The key goes unless it is offered.
      when (isNothing settled.offer) (traverse_ forgetKey key)
      pure (Right settled)

settleWith :: (MonadAssistant m, MonadVault m) => UserId -> Maybe KeyRef -> Step m Settled
settleWith u password = do
  stored <- fetched
  device <- lift (readDevice u)
  case (stored, password) of
    (Nothing, Just k) -> do
      made <- createWithPassword u device k
      Settled <$> describe u (Just made) True <*> pure Nothing
    (Nothing, Nothing) -> Settled <$> describe u Nothing False <*> pure Nothing
    (Just s, _) -> do
      byPassword <- case (password, wrapFor ByPassword s.vault) of
        (Just k, Just w) -> Just <$> unwrapWith' k s w False
        _ -> pure Nothing
      here <- maybe (lift (vaultKeyHere u stored)) (pure . Just) byPassword
      fresh <- case here of
        Nothing -> pure s
        Just v -> forgettingAfter v $ do
          keepVaultKey u v (not device.askEachTime)
          lift (shareWithAssistant u v)
          withIdentity u device v s
      let offering = isJust password && isNothing (wrapFor ByPassword s.vault) && not device.offered
      when offering (void (lift (writeDevice u device {offered = True})))
      keys' <- describe u (Just fresh) (isJust here)
      pure Settled {keys = keys', offer = if offering then password else Nothing}

-- | A step, after which the page forgets the given key, however it ends.
forgettingAfter :: (MonadAssistant m) => KeyRef -> Step m a -> Step m a
forgettingAfter = forgetting

-- | A new vault, made at the first sign-in of a user who has none: their
-- key pair in it, and its key wrapped for the password. The vault key can
-- be exported only while it is wrapped; this device keeps a copy that
-- cannot be.
createWithPassword :: (MonadAssistant m, MonadVault m) => UserId -> VaultDevice -> KeyRef -> Step m StoredVault
createWithPassword u device k = do
  salt <- Salt <$> lift newSalt
  withKey (lift (newVaultKey True)) $ \v -> do
    w <- ExceptT (passwordKey k salt)
    wrapped <- forgetting w (wrap w v)
    made <- ExceptT (newIdentity v)
    let vault = Vault {format = vaultFormat, salt, items = Map.singleton identityItem Item {keyId = Just made.keyId, sealed = made.sealed}, wraps = Map.singleton ByPassword wrapped}
    lift (storeVaultChange Nothing VaultChange {vault, publicKey = Just NewPublicKey {keyId = made.keyId, publicKey = made.publicKey}}) >>= \case
      Left e -> lift (forgetKey made.key) >> throwError ("Your keys could not be stored: " <> wikiText e)
      Right fresh -> do
        keepVaultKey u v (not device.askEachTime)
        keepIdentityKey u device made.key made.keyId
        pure fresh

-- | Unwrap the vault key with the password's key: the key OPAQUE's export
-- key gave, and the vault's salt. Exportable only when asked.
unwrapWith' :: (MonadAssistant m) => KeyRef -> StoredVault -> WrappedKey -> Bool -> Step m KeyRef
unwrapWith' k s w exportable = do
  wrapping <- ExceptT (passwordKey k s.vault.salt)
  forgetting wrapping (unwrap wrapping w exportable) `recover` \_ -> throwError "Your password does not unlock your vault: it was set again since (a reset), or the vault was changed. Unlock it with a passkey."

-- | Keep the vault key as the assistant's too, when the assistant's
-- settings sync and this device holds no key of the assistant's: one
-- unlock opens the whole vault. A key the assistant holds already is left
-- alone, since what was typed here while it was locked is sealed with it.
shareWithAssistant :: (MonadAssistant m) => UserId -> KeyRef -> m ()
shareWithAssistant u v =
  deviceKey u >>= \case
    Just k -> forgetKey k
    Nothing ->
      deviceRecord u >>= \case
        Right (Just bytes)
          | Right (Current r) <- readStored bytes
          , isJust r.server -> do
              -- On disk only when neither the assistant nor the vault asks
              -- each time: the copy is the vault key, and either setting
              -- means it must not outlive the page.
              device <- readDevice u
              void (keepDeviceKey u v (not r.askEachTime && not device.askEachTime))
        _ -> pass

--------------------------------------------------------------------------------
-- Unlocking and the ways to unlock

-- | Unlock the vault on this device with one of the passkeys it knows
-- (one touch), and bring the device up to date with it.
unlockWithPasskey :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
unlockWithPasskey u = runExceptT $ do
  s <- fetched >>= maybe (throwError "You have no vault to unlock.") pure
  v <- passkeyVaultKey s False
  settleHolding u s v

-- | Unlock the vault on this device with the password, which is proved
-- again to the server (no new session): the key it gives unwraps the
-- vault key.
unlockWithPassword :: (MonadAssistant m, MonadVault m) => UserId -> Password -> m (Either Text UserKeys)
unlockWithPassword u password = runExceptT $ do
  s <- fetched >>= maybe (throwError "You have no vault to unlock.") pure
  w <- maybe (throwError "Your vault does not open with your password: unlock it with a passkey.") pure (wrapFor ByPassword s.vault)
  k <- provedKey password
  v <- forgetting k (unwrapWith' k s w False)
  settleHolding u s v

-- | The device brought up to date with a vault key just unwrapped.
settleHolding :: (MonadAssistant m, MonadVault m) => UserId -> StoredVault -> KeyRef -> Step m UserKeys
settleHolding u s v = do
  device <- lift (readDevice u)
  fresh <- forgetting v $ do
    keepVaultKey u v (not device.askEachTime)
    lift (shareWithAssistant u v)
    withIdentity u device v s
  describe u (Just fresh) True

-- | The key a password gives the page, proved again to the server.
provedKey :: (MonadVault m) => Password -> Step m KeyRef
provedKey password =
  lift (provePassword password) >>= \case
    Left e -> throwError (passwordErrorText e)
    Right Nothing -> throwError "This browser gave no key for your password: open the wiki at its HTTPS address."
    Right (Just k) -> pure k

-- | The vault key, unwrapped with the key the password gives, proved again
-- to the server (no new session); exportable only when asked. The proof
-- left on the session also lets the next change that needs the password go
-- without it (making a passkey, for one).
passwordVaultKey :: (MonadAssistant m, MonadVault m) => StoredVault -> Password -> Bool -> Step m KeyRef
passwordVaultKey s password exportable = do
  w <- maybe (throwError "Your vault does not open with your password: unlock it with a passkey.") pure (wrapFor ByPassword s.vault)
  k <- provedKey password
  forgetting k (unwrapWith' k s w exportable)

-- | The vault key, unwrapped with one of the passkeys the vault knows (one
-- touch); exportable only when asked.
passkeyVaultKey :: (MonadAssistant m, MonadVault m) => StoredVault -> Bool -> Step m KeyRef
passkeyVaultKey s exportable = do
  let unlocking = Map.keys (passkeyWraps s.vault)
  when (null unlocking) (throwError "No passkey unlocks your vault.")
  (credential, wrapping) <- usedPasskey s.vault.salt (Just unlocking)
  forgetting wrapping $ do
    wrapped <- maybe (throwError "This passkey has no copy of the vault's key: use another one.") pure (wrapFor (ByPasskey credential) s.vault)
    unwrap wrapping wrapped exportable

-- | Unlock the vault with the password too: the password proved again
-- (or the key a sign-in gave) gives its key, a passkey the vault knows
-- gives the vault key (one touch: the page cannot wrap the copy a device
-- keeps, which cannot be exported), and the vault key is wrapped for the
-- password. This device is unlocked with it too. The vault is then as
-- strong as the password.
addPasswordUnlock :: (MonadAssistant m, MonadVault m) => UserId -> Maybe KeyRef -> Maybe Password -> m (Either Text UserKeys)
addPasswordUnlock u given password = runExceptT $ do
  s <- fetched >>= maybe (throwError "You have no vault.") pure
  k <- maybe (maybe (throwError "Type your password.") provedKey password) pure given
  fresh <- forgetting k $ withKey (passkeyVaultKey s True) $ \v -> do
    w <- ExceptT (passwordKey k s.vault.salt)
    wrapped <- forgetting w (wrap w v)
    stored <- server (storeVaultChange (Just s.tag) VaultChange {vault = withWrap ByPassword wrapped s.vault, publicKey = Nothing})
    -- The touch that gave the vault key unlocks this device too: the key
    -- is kept (as one that cannot be exported) and opens the key pair.
    device <- lift (readDevice u)
    keepVaultKey u v (not device.askEachTime)
    lift (shareWithAssistant u v)
    withIdentity u device v stored
  describe u (Just fresh) True

-- | Unlock the vault with the passkeys alone: the password's wrap goes. The
-- last way to unlock it cannot go.
removePasswordUnlock :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text UserKeys)
removePasswordUnlock u = runExceptT $ do
  s <- fetched >>= maybe (throwError "You have no vault.") pure
  when (Map.null (passkeyWraps s.vault)) (throwError "Your password is the only way to unlock your vault: add a passkey to it first.")
  fresh <- server (storeVaultChange (Just s.tag) VaultChange {vault = withoutWrap ByPassword s.vault, publicKey = Nothing})
  here <- lift (vaultKeyHere u (Just fresh))
  lift (traverse_ forgetKey here)
  describe u (Just fresh) (isJust here)

-- | Make the user's vault with their password, proved again to the server,
-- for a user who has none yet (one who has not signed in with a password
-- since keys were made, on this device or any).
createWithProvedPassword :: (MonadAssistant m, MonadVault m) => UserId -> Password -> m (Either Text UserKeys)
createWithProvedPassword u password = runExceptT $ do
  existing <- fetched
  when (isJust existing) (throwError "You have a vault already.")
  device <- lift (readDevice u)
  k <- provedKey password
  fresh <- forgetting k (createWithPassword u device k)
  describe u (Just fresh) True

-- | Unlock the vault with a passkey too: a vault the password alone
-- unlocks (the password proved again unwraps its key), wrapped for a
-- passkey of the user's, or a new one. The passkey is then one more way
-- to unlock it, and what the assistant's syncing needs.
addPasskeyUnlock :: (MonadAssistant m, MonadVault m) => UserId -> Maybe Password -> m (Either Text UserKeys)
addPasskeyUnlock u password = runExceptT $ do
  s <- fetched >>= maybe (throwError "You have no vault.") pure
  w <- maybe (throwError "Your vault does not open with your password: add a passkey to it from a device where a passkey unlocks it.") pure (wrapFor ByPassword s.vault)
  current <- maybe (throwError "Type your password.") pure password
  k <- provedKey current
  known <- server listPasskeys
  fresh <- withKey (forgetting k (unwrapWith' k s w True)) $ \v -> do
    -- A passkey the user has is tried first: the browser would refuse to
    -- make another on the same authenticator.
    (credential, wrapping) <-
      if null known
        then newPasskey Nothing s.vault.salt
        else usedPasskey s.vault.salt Nothing `recover` const (newPasskey Nothing s.vault.salt)
    wrapped <- forgetting wrapping (wrap wrapping v)
    server (storeVaultChange (Just s.tag) VaultChange {vault = withWrap (ByPasskey credential) wrapped s.vault, publicKey = Nothing})
  describe u (Just fresh) True

-- | Make the user's vault with a passkey, for a user who has none and no
-- password to make it at a sign-in with (one who signs in with a
-- provider): a passkey of theirs (or a new one) wraps a new vault key,
-- which seals their new key pair.
createWithPasskey :: (MonadAssistant m, MonadVault m) => UserId -> Maybe Password -> m (Either Text UserKeys)
createWithPasskey u password = runExceptT $ do
  existing <- fetched
  when (isJust existing) (throwError "You have a vault already.")
  device <- lift (readDevice u)
  salt <- Salt <$> lift newSalt
  known <- server listPasskeys
  (credential, wrapping) <-
    if null known
      then newPasskey password salt
      else usedPasskey salt Nothing `recover` const (newPasskey password salt)
  fresh <- forgetting wrapping $ withKey (lift (newVaultKey True)) $ \v -> do
    wrapped <- wrap wrapping v
    made <- ExceptT (newIdentity v)
    let vault = Vault {format = vaultFormat, salt, items = Map.singleton identityItem Item {keyId = Just made.keyId, sealed = made.sealed}, wraps = Map.singleton (ByPasskey credential) wrapped}
    lift (storeVaultChange Nothing VaultChange {vault, publicKey = Just NewPublicKey {keyId = made.keyId, publicKey = made.publicKey}}) >>= \case
      Left e -> lift (forgetKey made.key) >> throwError ("Your keys could not be stored: " <> wikiText e)
      Right fresh -> do
        keepVaultKey u v (not device.askEachTime)
        keepIdentityKey u device made.key made.keyId
        pure fresh
  describe u (Just fresh) True

-- | Whether this device asks for an unlock each time the wiki opens: if
-- so, it keeps the vault key and the private key for the page's life
-- only; if not, in IndexedDB too.
setVaultAskEachTime :: (MonadAssistant m, MonadVault m) => UserId -> Bool -> m (Either Text UserKeys)
setVaultAskEachTime u asking = runExceptT $ do
  stored <- fetched
  device <- lift (readDevice u)
  v <- lift (vaultKeyHere u stored) >>= maybe (throwError "Unlock your vault on this device first.") pure
  forgetting v (keepVaultKey u v (not asking))
  lift (deviceKey (identitySlot u)) >>= traverse_ (\k -> forgetting k (ExceptT (keepDeviceKey (identitySlot u) k (not asking))))
  -- The assistant's slot may hold the same vault key (shared when its
  -- settings sync). Asking each time must cover that copy too, or a reload
  -- would reopen the vault from it without an unlock. A key of the
  -- assistant's own (one that does not open the vault) is left as it is.
  when asking $
    lift (deviceKey u)
      >>= traverse_
        ( \k -> forgetting k $ do
            same <- lift (maybe (pure False) (\s -> opensVault k s.vault) stored)
            when same (ExceptT (keepDeviceKey u k False))
        )
  ExceptT (writeDevice u VaultDevice {held = device.held, askEachTime = asking, offered = device.offered})
  describe u stored True

--------------------------------------------------------------------------------
-- A new password

-- | Change the signed-in user's password, carrying their vault along when
-- it opens with the password: the current password is proved first (which
-- gives its key and lets the change go without it), the vault key is
-- unwrapped with it, and the change sends the vault key wrapped for the
-- new password, which the server stores with the new password, both or
-- neither. A vault the password does not unlock needs nothing.
changeOwnPassword :: (MonadAssistant m, MonadVault m) => (PasswordChange -> m (Either SignInError SignInMethods)) -> PasswordChange -> m (Either SignInError SignInMethods)
changeOwnPassword plain change =
  runExceptT fetched >>= \case
    Right (Just s)
      | Just w <- wrapFor ByPassword s.vault
      , Just current <- change.current ->
          provePassword current >>= \case
            Left e -> pure (Left e)
            Right Nothing -> plain change
            Right (Just k) ->
              runExceptT (forgetting k (unwrapWith' k s w True)) >>= \case
                Left why -> pure (Left (SignInFailed (Invalid why)))
                Right v -> do
                  result <- changePasswordCarrying PasswordChange {current = Nothing, new = change.new} Rewrap {tag = s.tag, salt = s.vault.salt, vaultKey = v}
                  forgetKey v
                  pure result
    _ -> plain change

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
    keepIdentity = keepIdentityKey u device

-- | Keep the user's private key on this device, and record which key pair
-- it is.
keepIdentityKey :: (MonadAssistant m) => UserId -> VaultDevice -> KeyRef -> KeyId -> Step m ()
keepIdentityKey u device k keyId = do
  kept <- lift (keepDeviceKey (identitySlot u) k (not device.askEachTime))
  lift (forgetKey k)
  either throwError pure kept
  ExceptT (writeDevice u device {held = Just keyId})

-- | What a password reset deletes when only the old password unlocked the
-- user's vault, in the words the reset page lists before it is done: one
-- line per kind of secret the vault holds. Encrypted spaces add theirs.
resetLosses :: [Text]
resetLosses =
  [ "your key pair, which encrypted spaces use (a new one is made at your next sign-in);"
  , "the writing assistant's settings and API keys, where they sync across your devices;"
  , "your encrypted pages will be destroyed for you: you read an encrypted space again only once another member opens it and shares its key with your new key pair, and an encrypted space nobody else can read is lost."
  ]

--------------------------------------------------------------------------------
-- Steps

-- | 'Step': a step of the vault's, which fails with what to tell the
-- person.
type Step m = ExceptT Text m

-- | Make a passkey for the wiki, checked by the server, and the key that
-- wraps the vault key for it: from its PRF output at once, or by using it
-- once. A passkey without the PRF extension cannot wrap the vault key; it
-- is kept, since it signs the user in (WP5.30), and the person is told.
newPasskey :: (MonadAssistant m, MonadVault m) => Maybe Password -> Salt -> Step m (CredentialId, KeyRef)
newPasskey password salt = do
  -- Making a passkey asks for the user's password, since it signs them in.
  options <- ExceptT (first passwordErrorText <$> beginRegistration password)
  made <- passkey (createPasskey options salt.text wrappingInfo)
  let credential = made.response.id
      -- The key the PRF output gave goes if a step below fails.
      forgetWrapping = lift (traverse_ forgetKey made.wrapping)
  -- A passkey the server did not take is told to the password manager as
  -- not the wiki's, so that it does not linger there.
  _ <-
    server (finishRegistration made.response)
      `recover` \why -> lift (discardPasskey options.rpId credential) >> forgetWrapping >> throwError why
  unless made.prf $ do
    forgetWrapping
    throwError "This passkey cannot sync the keys: it has no PRF extension, which the browser or the password manager that keeps it does not offer. It was kept to sign in with, and is listed under Passkeys in your account. Try a passkey kept elsewhere (Google Password Manager, iCloud Keychain, Windows Hello, a security key)."
  case made.wrapping of
    Just wrapping -> pure (credential, wrapping)
    Nothing ->
      ((Right <$> usedPasskey salt (Just [credential])) `recover` (pure . Left)) >>= \case
        Right (_, wrapping) -> pure (credential, wrapping)
        Left why -> lift (void (dropPasskey credential)) >> throwError why

-- | Use one of the user's passkeys, checked by the server: the passkey
-- used, and the key its PRF output gives. Given a list, only the passkeys
-- in it are offered: those that hold a copy of the vault's key, so that
-- no touch goes to a passkey that cannot unlock it.
usedPasskey :: (MonadAssistant m, MonadVault m) => Salt -> Maybe [CredentialId] -> Step m (CredentialId, KeyRef)
usedPasskey salt only = do
  options <- server beginAssertion
  when (null options.allow) (throwError "You have no passkey for this wiki any more: turn syncing off, and on again with a new passkey.")
  let allowed = maybe options.allow (\these -> filter (`elem` these) options.allow) only
  when (null allowed) (throwError "None of your passkeys holds a copy of the vault's key: turn syncing off, and on again with a passkey.")
  used <- passkey (usePasskey AssertionOptions {challenge = options.challenge, rpId = options.rpId, allow = allowed} salt.text wrappingInfo)
  _ <- server (finishAssertion used.response) `recover` \why -> lift (traverse_ forgetKey used.wrapping) >> throwError why
  wrapping <- maybe (throwError "This passkey gave no PRF output, so it cannot unlock the keys. Use another passkey, or remove this one under Passkeys in your account and turn syncing on again with a new one.") pure used.wrapping
  pure (used.response.id, wrapping)

wrap :: (MonadAssistant m) => KeyRef -> KeyRef -> Step m WrappedKey
wrap wrapping k = ExceptT (wrapWith wrapping k wrappingData)

unwrap :: (MonadAssistant m) => KeyRef -> WrappedKey -> Bool -> Step m KeyRef
unwrap wrapping w exportable = ExceptT (unwrapWith wrapping w wrappingData exportable)

server :: (Monad m) => m (Either WikiError a) -> Step m a
server request = ExceptT (first wikiText <$> request)

passkey :: (Monad m) => m (Either PasskeyRefusal a) -> Step m a
passkey request =
  lift request >>= \case
    Right a -> pure a
    Left Cancelled -> throwError "The passkey was not used: the browser's dialog was closed."
    Left (PasskeyFailed why) -> throwError ("The browser could not use a passkey: " <> why)

-- | A step, or else what to do with why it failed.
recover :: (Monad m) => Step m a -> (Text -> Step m a) -> Step m a
recover step otherwise' = lift (runExceptT step) >>= either otherwise' pure

-- | A step with a key the page holds for it alone: the key is forgotten
-- when the step ends, whether it succeeds or fails. A key that can be
-- exported must not stay in the page longer than it is needed.
withKey :: (MonadAssistant m) => Step m KeyRef -> (KeyRef -> Step m a) -> Step m a
withKey acquire step = do
  k <- acquire
  result <- lift (runExceptT (step k))
  lift (forgetKey k)
  either throwError pure result

-- | A step, after which the page forgets the given key, however it ends.
forgetting :: (MonadAssistant m) => KeyRef -> Step m a -> Step m a
forgetting k step = withKey (pure k) (const step)

-- | What a backend's refusal says.
wikiText :: WikiError -> Text
wikiText = \case
  NotFound -> "The server knows nothing of it."
  Forbidden -> "The server refused it."
  Conflict t -> t
  Invalid t -> t
  Unreachable t -> "The server could not be reached: " <> t
