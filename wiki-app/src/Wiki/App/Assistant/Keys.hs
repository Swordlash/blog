{-# LANGUAGE MultiWayIf #-}

-- | The assistant's keys on this device and across devices (WP5.21 of
-- docs/PLAN.md): reading and changing the settings through the vault
-- ("Wiki.Core.Assistant.Vault"), and the steps of syncing them with a
-- passkey. It puts the browser's half ("Wiki.App.Assistant": WebCrypto,
-- WebAuthn, this device's key) and the server's ("Wiki.App.Assistant.Sync")
-- together; the settings page and the editor call it.
--
-- = On this device
--
-- The settings are sealed with this device's vault key, which the
-- browser keeps and never exports; 'readKeys' opens them, 'changeKeys'
-- seals them again. A device that stored them as text before the vault
-- existed has them sealed, and the text replaced, the first time they are
-- read. The model lists and whether each provider could be reached stay
-- in the clear beside them, and change without sealing anything.
--
-- A page the browser offers no WebCrypto to (served over plain HTTP from
-- another machine) cannot seal: there the settings are stored as text,
-- as before the vault, and the settings page says so ('sealingHere').
--
-- = Across devices
--
-- 'turnOnSync' makes a passkey for the wiki, a vault key that can be
-- exported (only in this page, only for this), wraps it with the key the
-- passkey's PRF output gives, and stores the vault on the server; the
-- device keeps the vault key as one that cannot be exported. On another
-- device 'loadKeys' fetches the vault and finds it locked; 'unlockKeys'
-- uses a passkey to unwrap the vault key there, with one touch, and keeps
-- it. A change made anywhere is sealed and stored over the version it was
-- made to; the other devices fetch it the next time the wiki opens, by
-- its tag, and open it with the key they keep, without a touch.
-- 'addPasskey' wraps the vault key for one more passkey, which needs a
-- touch of a passkey the vault knows first, since the key the device keeps
-- cannot be exported. 'setAskEachTime' keeps the key for the page's life
-- only, so that each time the wiki opens the vault asks for the passkey.
-- 'turnOffSync' deletes the vault and the passkeys on the server and
-- keeps the keys on this device, sealed as before.
module Wiki.App.Assistant.Keys
  ( Keys (..)
  , loadKeys
  , loadFollowedKeys
  , readKeys
  , changeKeys
  , turnOnSync
  , unlockKeys
  , addPasskey
  , removePasskey
  , turnOffSync
  , setAskEachTime
  )
where

import Data.Aeson (eitherDecodeStrict, encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Protolude
import Wiki.Api.Vault (AssertionOptions (..), AssertionResponse (..), PasskeyInfo (..), RegistrationOptions (..), RegistrationResponse (..), StoredVault (..))
import Wiki.App.Account (passwordErrorText)
import Wiki.App.Assistant (KeyRef, Made (..), MonadAssistant (..), PasskeyRefusal (..), Used (..))
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant (Settings, blankSettings, defaultSettings)
import Wiki.Core.Assistant.Vault
import Wiki.Core.Id (UserId)
import Wiki.Core.User (Password)

-- | 'Keys': the assistant's settings on this device, and how they are kept.
data Keys = Keys
  { settings :: Settings
  -- ^ What the assistant uses here. While 'locked', what was typed on
  -- this device since: the vault's own settings wait for a passkey.
  , locked :: Bool
  -- ^ Whether the device follows a vault it has not unlocked.
  , synced :: Bool
  -- ^ Whether the device follows the vault on the server.
  , askEachTime :: Bool
  -- ^ Whether the device keeps the vault key only while the wiki is
  -- open, and asks for the passkey each time it opens.
  }
  deriving stock (Eq, Show)

-- | What this device can do with what it keeps for a user.
data Opened
  = -- | The settings, opened with the key that sealed them.
    Opened KeyRef Settings
  | -- | A vault from the server not yet opened here; the settings typed on
    -- this device meanwhile, with the key they are sealed with, if any.
    Locked (Maybe KeyRef) Settings
  | -- | Nothing sealed that this device can open: nothing set yet.
    Fresh

type Step m = ExceptT Text m

--------------------------------------------------------------------------------
-- Reading and changing

-- | The settings when the wiki opens: what this device keeps, brought up
-- to date with the server's vault when there is a server (fetched only
-- when its tag has changed; kept as it was when the server cannot be
-- reached).
-- This is also how a device learns that syncing was turned on elsewhere,
-- so the assistant's settings page loads the keys with it.
loadKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text Keys)
loadKeys user = sealing (plainKeys user) $ runExceptT $ do
  record <- refreshed user =<< current user
  key <- lift (deviceKey user)
  opened <- open record key
  pure (keysOf record opened)

-- | The settings when the editor opens: as 'loadKeys', but the server is
-- asked only when this device already follows a vault. A page the server
-- rendered carries everything else the editor needs, so a device that does
-- not sync makes no request for the assistant when it opens the editor.
loadFollowedKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text Keys)
loadFollowedKeys user = sealing (plainKeys user) $ runExceptT $ do
  kept <- current user
  record <- if isJust kept.server then refreshed user kept else pure kept
  key <- lift (deviceKey user)
  keysOf record <$> open record key

-- | The settings as this device keeps them, without asking the server.
readKeys :: (MonadAssistant m) => UserId -> m (Either Text Keys)
readKeys user = sealing (plainKeys user) $ runExceptT $ do
  record <- current user
  key <- lift (deviceKey user)
  keysOf record <$> open record key

-- | Change the settings, and keep them. Only what was learnt from a
-- provider changes without sealing. Otherwise the settings are sealed
-- again, and, when they sync, stored on the server over the version this
-- device has; a version changed elsewhere meanwhile is fetched, and the
-- change made again on it. A change that the server cannot take is not
-- kept here either, so that the devices do not drift apart. While the
-- vault is locked, a change is kept on this device only, under a key of
-- its own, until the vault is unlocked ('unlockKeys').
changeKeys :: (MonadAssistant m, MonadVault m) => UserId -> (Settings -> Settings) -> m (Either Text Keys)
changeKeys user f = sealing (plainChange user f) $ runExceptT (attempt (2 :: Int))
  where
    attempt tries = do
      record <- current user
      key <- lift (deviceKey user)
      opened <- open record key
      let old = joinSettings (secretsIn opened) record.learnt
          new = f old
          learnt = learntOf new
          secrets = secretsOf new
          kept = learntTo learnt record
      if
        | secrets == secretsOf old -> write user kept $> keysOf kept opened
        | blankSettings new && isNothing record.server -> do
            -- Nothing set and nothing synced: nothing is kept.
            lift (dropDeviceKey user)
            stored user Nothing
            pure (Keys {settings = defaultSettings, locked = False, synced = False, askEachTime = False})
        | otherwise -> case opened of
            Opened k _
              | Just copy <- record.server -> do
                  sealed <- seal k secrets
                  lift (storeVault (Just copy.tag) (withSealed sealed copy.vault)) >>= \case
                    Right fresh -> do
                      let changed = serverTo (Just (ServerCopy fresh.tag fresh.vault)) (sealedTo (Just fresh.vault.sealed) kept)
                      write user changed $> keysOf changed (Opened k secrets)
                    Left (Conflict _) | tries > 0 -> do
                      _ <- refreshed user record
                      attempt (tries - 1)
                    Left e -> throwError ("The change was not kept: your keys sync across your devices, and the server did not take it. " <> wikiText e)
              | otherwise -> do
                  sealed <- seal k secrets
                  let changed = sealedTo (Just sealed) kept
                  write user changed $> keysOf changed (Opened k secrets)
            Locked mk _ -> do
              k <- maybe (localKey user) pure mk
              sealed <- seal k secrets
              let changed = sealedTo (Just sealed) kept
              write user changed $> keysOf changed (Locked (Just k) secrets)
            Fresh -> do
              k <- localKey user
              sealed <- seal k secrets
              let changed = sealedTo (Just sealed) kept
              write user changed $> keysOf changed (Opened k secrets)

--------------------------------------------------------------------------------
-- Across devices

-- | Sync the settings with a passkey: the vault made, sealed with a new
-- vault key wrapped for the passkey, stored on the server, and the key
-- kept on this device. A user who has passkeys already (to sign in with,
-- or kept when syncing was turned off) uses one of them: the browser would
-- refuse to make another on the same authenticator, since the wiki names
-- them as made already. A user with none makes one; one without the PRF
-- extension is kept to sign in with, and said so ('newPasskey').
turnOnSync :: (MonadAssistant m, MonadVault m) => UserId -> Maybe Password -> m (Either Text Keys)
turnOnSync user password = sealing (pure (Left needsSealing)) $ runExceptT $ do
  record <- refreshed user =<< current user
  when (isJust record.server) (throwError "Your keys sync already, or another device of yours syncs them: unlock them with a passkey.")
  key <- lift (deviceKey user)
  secrets <-
    open record key >>= \case
      Opened _ s -> pure s
      Fresh -> pure defaultSettings
      Locked _ _ -> throwError "Unlock your keys first."
  salt <- lift newSalt
  existing <- server listPasskeys
  -- The new vault key can be exported, to be wrapped: the page forgets it
  -- however this ends, and keeps only a copy that cannot be.
  stored' <- withKey (lift (newVaultKey True)) $ \vaultKey -> do
    (credential, wrapping) <-
      if null existing
        then newPasskey password salt
        else usedPasskey salt Nothing
    -- A passkey made here goes again if the vault is not stored; one the
    -- user had stays, since it signs them in.
    let made = credential `notElem` map (\p -> p.id) existing
    stored' <-
      forgetting
        wrapping
        ( do
            wrapped <- wrap wrapping vaultKey
            sealed <- seal vaultKey secrets
            server (storeVault Nothing Vault {format = vaultFormat, salt, sealed, wrapped = Map.singleton credential wrapped})
        )
        `recover` \why -> lift (when made (void (dropPasskey credential))) >> throwError why
    keep user vaultKey (not record.askEachTime)
    pure stored'
  let synced' = serverTo (Just (ServerCopy stored'.tag stored'.vault)) (sealedTo (Just stored'.vault.sealed) record)
  write user synced'
  keysOf synced' . (\k -> Opened k secrets) <$> deviceKeyOrFail user

-- | Unlock the vault on this device with a passkey: the vault key
-- unwrapped with what the passkey gives, kept, and the settings opened.
-- Settings typed here while it was locked are merged in
-- ('mergeUnlocked') and stored, if they add anything.
unlockKeys :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text Keys)
unlockKeys user = sealing (pure (Left needsSealing)) $ runExceptT $ do
  record <- refreshed user =<< current user
  copy <- maybe (throwError "There is nothing to unlock: your keys do not sync.") pure record.server
  key <- lift (deviceKey user)
  typed <-
    open record key >>= \case
      Opened _ _ -> throwError "Your keys are unlocked on this device already."
      Locked _ s -> pure s
      Fresh -> pure defaultSettings
  (credential, wrapping) <- usedPasskey copy.vault.salt (Just (Map.keys copy.vault.wrapped))
  let vaultKeyOf = forgetting wrapping $ do
        wrapped <- maybe (throwError "This passkey has no copy of the vault's key: add it again from a device where your keys are unlocked.") pure (wrappedFor credential copy.vault)
        unwrap wrapping wrapped False
  (merged, copy') <- withKey vaultKeyOf $ \vaultKey -> do
    secrets <- openSettings vaultKey copy.vault.sealed
    let merged = mergeUnlocked secrets (secretsOf typed)
    copy' <-
      if merged == secrets
        then pure copy
        else do
          sealed <- seal vaultKey merged
          fresh <- server (storeVault (Just copy.tag) (withSealed sealed copy.vault))
          pure (ServerCopy fresh.tag fresh.vault)
    keep user vaultKey (not record.askEachTime)
    pure (merged, copy')
  let unlocked = serverTo (Just copy') (sealedTo (Just copy'.vault.sealed) record)
  write user unlocked
  keysOf unlocked . (\k -> Opened k merged) <$> deviceKeyOrFail user

-- | Wrap the vault key for one more passkey, on a device where the vault
-- is unlocked: a passkey the vault knows gives the vault key (one touch),
-- then the new passkey is made (another, and a third if its authenticator
-- gives its PRF output only when used).
addPasskey :: (MonadAssistant m, MonadVault m) => UserId -> Maybe Password -> m (Either Text Keys)
addPasskey user password = sealing (pure (Left needsSealing)) $ runExceptT $ do
  record <- refreshed user =<< current user
  copy <- maybe (throwError "Your keys do not sync: turn syncing on first.") pure record.server
  key <- lift (deviceKey user)
  opened <- open record key
  case opened of
    Opened _ _ -> pass
    _ -> throwError "Unlock your keys on this device first."
  (known, wrapping) <- usedPasskey copy.vault.salt (Just (Map.keys copy.vault.wrapped))
  -- The vault key unwrapped here can be exported, to be wrapped for the
  -- new passkey: the page forgets it however this ends.
  let vaultKeyOf = forgetting wrapping $ do
        wrapped <- maybe (throwError "This passkey has no copy of the vault's key: use another one.") pure (wrappedFor known copy.vault)
        unwrap wrapping wrapped True
  fresh <- withKey vaultKeyOf $ \vaultKey -> do
    (credential, newWrapping) <- newPasskey password copy.vault.salt
    forgetting
      newWrapping
      ( do
          rewrapped <- wrap newWrapping vaultKey
          server (storeVault (Just copy.tag) (withWrapped credential rewrapped copy.vault))
      )
      `recover` \why -> lift (void (dropPasskey credential)) >> throwError why
  let added = serverTo (Just (ServerCopy fresh.tag fresh.vault)) (sealedTo (Just fresh.vault.sealed) record)
  write user added
  keysOf added <$> open added key

-- | Remove one of the user's passkeys, with its wrapped copy of the vault
-- key: the passkeys left.
removePasskey :: (MonadAssistant m, MonadVault m) => UserId -> CredentialId -> m (Either Text [PasskeyInfo])
removePasskey user credential = runExceptT $ do
  left <- server (dropPasskey credential)
  _ <- refreshed user =<< current user
  pure left

-- | Stop syncing: the vault and every passkey deleted on the server,
-- which needs no passkey (the way back for someone who lost every
-- passkey). The keys stay on this device: the vault's latest version,
-- fetched first, when this device can open it, or else what was typed
-- here while it was locked. The key is kept on this device from now on.
turnOffSync :: (MonadAssistant m, MonadVault m) => UserId -> m (Either Text Keys)
turnOffSync user = sealing (runExceptT (server deleteVault) >>= either (pure . Left) (const (plainKeys user))) $ runExceptT $ do
  record <- refreshed user =<< current user
  server deleteVault
  key <- lift (deviceKey user)
  traverse_ (\k -> keep user k True) key
  off <- unsynced key record
  write user off
  keysOf off <$> open off key

-- | Whether this device asks for the passkey each time the wiki opens: if
-- so, it keeps the vault key for the page's life only; if not, in
-- IndexedDB too.
setAskEachTime :: (MonadAssistant m) => UserId -> Bool -> m (Either Text Keys)
setAskEachTime user asking = sealing (pure (Left needsSealing)) $ runExceptT $ do
  record <- current user
  key <- deviceKeyOrFail user
  opened <- open record (Just key)
  case opened of
    Opened _ _ -> pass
    _ -> throwError "Unlock your keys on this device first."
  keep user key (not asking)
  let changed = askTo asking record
  write user changed
  pure (keysOf changed opened)

--------------------------------------------------------------------------------
-- Where nothing can be sealed

-- | The first where this page can seal, the second where it cannot.
sealing :: (MonadAssistant m) => m a -> m a -> m a
sealing plain sealed = sealingHere >>= bool plain sealed

needsSealing :: Text
needsSealing = "Syncing your keys needs this wiki at its HTTPS address: the browser offers no encryption to a page served over plain HTTP."

-- | The settings as stored where nothing can be sealed: as text.
plainKeys :: (MonadAssistant m) => UserId -> m (Either Text Keys)
plainKeys user = runExceptT (plainOf <$> plainSettings user)

-- | Change the settings stored as text; nothing set, nothing stored.
plainChange :: (MonadAssistant m) => UserId -> (Settings -> Settings) -> m (Either Text Keys)
plainChange user f = runExceptT $ do
  new <- f <$> plainSettings user
  stored user (if blankSettings new then Nothing else Just (BSL.toStrict (encode new)))
  pure (plainOf new)

plainSettings :: (MonadAssistant m) => UserId -> Step m Settings
plainSettings user =
  ExceptT (deviceRecord user) >>= \case
    Nothing -> pure defaultSettings
    Just bytes -> case readStored bytes of
      Left why -> throwError ("The assistant's settings on this device cannot be read (" <> why <> ").")
      Right (OldSettings s) -> pure s
      Right (Current _) -> throwError "The assistant's settings on this device are sealed, and this page cannot open them: the browser offers no encryption to a page served over plain HTTP. Open this wiki at its HTTPS address."

plainOf :: Settings -> Keys
plainOf settings = Keys {settings, locked = False, synced = False, askEachTime = False}

--------------------------------------------------------------------------------
-- Steps

-- | A device record with one part changed. (Built whole: 'sealed' and
-- 'askEachTime' are fields of other records too, which makes a record
-- update ambiguous.)
sealedTo :: Maybe Sealed -> DeviceRecord -> DeviceRecord
sealedTo sealed r = DeviceRecord {sealed, server = r.server, learnt = r.learnt, askEachTime = r.askEachTime}

serverTo :: Maybe ServerCopy -> DeviceRecord -> DeviceRecord
serverTo copy r = DeviceRecord {sealed = r.sealed, server = copy, learnt = r.learnt, askEachTime = r.askEachTime}

learntTo :: Settings -> DeviceRecord -> DeviceRecord
learntTo learnt r = DeviceRecord {sealed = r.sealed, server = r.server, learnt, askEachTime = r.askEachTime}

askTo :: Bool -> DeviceRecord -> DeviceRecord
askTo askEachTime r = DeviceRecord {sealed = r.sealed, server = r.server, learnt = r.learnt, askEachTime}

-- | What this device keeps for a user: a record, or the old settings as
-- text, sealed into one and stored in their place.
current :: (MonadAssistant m) => UserId -> Step m DeviceRecord
current user =
  ExceptT (deviceRecord user) >>= \case
    Nothing -> pure emptyRecord
    Just bytes -> case readStored bytes of
      Left why -> throwError ("The assistant's settings on this device cannot be read (" <> why <> ").")
      Right (Current record) -> pure record
      Right (OldSettings old) -> do
        k <- localKey user
        sealed <- seal k (secretsOf old)
        let record = learntTo (learntOf old) (sealedTo (Just sealed) emptyRecord)
        write user record
        pure record

-- | A record brought up to date with the server's vault, and stored if it
-- changed: the vault fetched when its tag changed; the copy dropped when
-- there is none any more (syncing was turned off elsewhere), the key then
-- kept on this device.
refreshed :: (MonadAssistant m, MonadVault m) => UserId -> DeviceRecord -> Step m DeviceRecord
refreshed user record =
  lift vaultSync >>= \case
    False -> pure record
    True ->
      lift (fetchVault ((\c -> c.tag) <$> record.server)) >>= \case
        Right (Fetched fresh) -> do
          let changed = serverTo (Just (ServerCopy fresh.tag fresh.vault)) record
          write user changed $> changed
        Right NoVault | isJust record.server -> do
          key <- lift (deviceKey user)
          traverse_ (\k -> keep user k True) key
          changed <- unsynced key record
          write user changed $> changed
        -- The same version, none at all, or no server to ask: as kept.
        _ -> pure record

-- | A record that no longer syncs. The settings it keeps become the
-- vault's, the latest version this device fetched, when the device's key
-- opens them; otherwise (a device still locked) they stay what was typed
-- here. Without this, a device that took changes made elsewhere would go
-- back to the settings of its own last change.
unsynced :: (MonadAssistant m) => Maybe KeyRef -> DeviceRecord -> Step m DeviceRecord
unsynced key record = do
  let off = askTo False (serverTo Nothing record)
  case (record.server, key) of
    (Just copy, Just k) ->
      lift (openWith k copy.vault.sealed sealingData) <&> \case
        Right _ -> sealedTo (Just copy.vault.sealed) off
        Left _ -> off
    _ -> pure off

-- | Open what a device keeps with the key it holds.
open :: (MonadAssistant m) => DeviceRecord -> Maybe KeyRef -> Step m Opened
open record key = case (record.server, key) of
  (Just copy, Just k) ->
    lift (openWith k copy.vault.sealed sealingData) >>= \case
      Right text -> Opened k <$> decoded text
      Left _ -> Locked (Just k) <$> typedWith k
  (Just _, Nothing) -> pure (Locked Nothing defaultSettings)
  (Nothing, Just k) -> case record.sealed of
    Nothing -> pure (Opened k defaultSettings)
    Just s -> lift (openWith k s sealingData) >>= either (const (pure Fresh)) (fmap (Opened k) . decoded)
  -- Sealed under a key this device no longer has (it was kept for the
  -- page's life only, and syncing went off elsewhere): nothing can open
  -- it, and the next change starts again.
  (Nothing, Nothing) -> pure Fresh
  where
    typedWith k = case record.sealed of
      Nothing -> pure defaultSettings
      Just s -> lift (openWith k s sealingData) >>= either (const (pure defaultSettings)) decoded

keysOf :: DeviceRecord -> Opened -> Keys
keysOf record opened =
  Keys
    { settings = joinSettings (secretsIn opened) record.learnt
    , locked = case opened of
        Locked _ _ -> True
        _ -> False
    , synced = isJust record.server
    , askEachTime = record.askEachTime
    }

secretsIn :: Opened -> Settings
secretsIn = \case
  Opened _ s -> s
  Locked _ s -> s
  Fresh -> defaultSettings

-- | A new vault key for this device alone, kept on it.
localKey :: (MonadAssistant m) => UserId -> Step m KeyRef
localKey user = do
  k <- lift (newVaultKey False)
  keep user k True
  pure k

-- | Make a passkey for the wiki, checked by the server, and the key that
-- wraps the vault key for it: from its PRF output at once, or by using it
-- once. A passkey without the PRF extension cannot wrap the vault key; it
-- is kept, since it signs the user in (WP5.30), and the person is told.
newPasskey :: (MonadAssistant m, MonadVault m) => Maybe Password -> Text -> Step m (CredentialId, KeyRef)
newPasskey password salt = do
  -- Making a passkey asks for the user's password, since it signs them in.
  options <- ExceptT (first passwordErrorText <$> beginRegistration password)
  made <- passkey (createPasskey options salt wrappingInfo)
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
usedPasskey :: (MonadAssistant m, MonadVault m) => Text -> Maybe [CredentialId] -> Step m (CredentialId, KeyRef)
usedPasskey salt only = do
  options <- server beginAssertion
  when (null options.allow) (throwError "You have no passkey for this wiki any more: turn syncing off, and on again with a new passkey.")
  let allowed = maybe options.allow (\these -> filter (`elem` these) options.allow) only
  when (null allowed) (throwError "None of your passkeys holds a copy of the vault's key: turn syncing off, and on again with a passkey.")
  used <- passkey (usePasskey AssertionOptions {challenge = options.challenge, rpId = options.rpId, allow = allowed} salt wrappingInfo)
  _ <- server (finishAssertion used.response) `recover` \why -> lift (traverse_ forgetKey used.wrapping) >> throwError why
  wrapping <- maybe (throwError "This passkey gave no PRF output, so it cannot unlock the keys. Use another passkey, or remove this one under Passkeys in your account and turn syncing on again with a new one.") pure used.wrapping
  pure (used.response.id, wrapping)

seal :: (MonadAssistant m) => KeyRef -> Settings -> Step m Sealed
seal k s = ExceptT (sealWith k (decodeUtf8 (BSL.toStrict (encode (secretsOf s)))) sealingData)

openSettings :: (MonadAssistant m) => KeyRef -> Sealed -> Step m Settings
openSettings k s = decoded =<< ExceptT (openWith k s sealingData)

wrap :: (MonadAssistant m) => KeyRef -> KeyRef -> Step m WrappedKey
wrap wrapping k = ExceptT (wrapWith wrapping k wrappingData)

unwrap :: (MonadAssistant m) => KeyRef -> WrappedKey -> Bool -> Step m KeyRef
unwrap wrapping w exportable = ExceptT (unwrapWith wrapping w wrappingData exportable)

keep :: (MonadAssistant m) => UserId -> KeyRef -> Bool -> Step m ()
keep user k onDisk = ExceptT (keepDeviceKey user k onDisk)

deviceKeyOrFail :: (MonadAssistant m) => UserId -> Step m KeyRef
deviceKeyOrFail user = lift (deviceKey user) >>= maybe (throwError "This browser kept no key for your settings.") pure

decoded :: (Monad m) => Text -> Step m Settings
decoded text = either (\why -> throwError ("The settings in the vault cannot be read (" <> toS why <> ").")) pure (eitherDecodeStrict (encodeUtf8 text))

write :: (MonadAssistant m) => UserId -> DeviceRecord -> Step m ()
write user record = stored user (Just (BSL.toStrict (encode record)))

stored :: (MonadAssistant m) => UserId -> Maybe ByteString -> Step m ()
stored user = ExceptT . keepDeviceRecord user

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
