{-# LANGUAGE MultiWayIf #-}

-- | The user's vault and passkeys, on the server (WP5.21, WP5.30 and
-- WP5.74 of docs/PLAN.md, "Wiki.Api.Vault", "Wiki.Core.Vault"): what the
-- routes under @assistant\/@, @account\/passkeys\/@ and
-- @session\/passkey@ store and check. A passkey signs its owner in, and
-- unlocks the vault when the vault has the vault key wrapped for it.
--
-- The server keeps, per user, the vault as the browser sent it (@vaults@:
-- its salt, the password's wrap of its key if the user chose one, and a
-- revision that is its tag; @vault_items@: its sealed items by name) and
-- the user's passkeys (@passkeys@: each one's credential id, public key,
-- algorithm and signature counter, and the vault key wrapped for it). It
-- cannot open the vault, and never sees the PRF output or the password's
-- key a wrapped key is unwrapped with, nor anything sealed. An
-- administrator, who can read the database, sees no more than that a
-- vault, its items' names and passkeys exist.
--
-- = Ceremonies
--
-- A registration or an assertion takes two requests: one that gives the
-- browser a challenge, and one that brings the browser's answer. The
-- challenge waits in memory ('Ceremonies'), for the session that asked
-- for it, for 'ceremonyLifetime', and is used once. A sign-in with a
-- passkey has no session yet: its challenge waits under itself
-- ('beginSignIn'), and the answer finds it by the challenge its client
-- data names. A restart forgets the challenges waiting, which costs
-- whoever was touching their passkey a second touch.
module Wiki.Server.Vault
  ( -- * The site
    Site (..)
  , siteFor

    -- * The vault
  , storedVault
  , storeVault
  , storeVaultIn
  , deleteVault
  , vaultProblem
  , passwordRewrapIn
  , resetVaultIn

    -- * The directory of public keys
  , publicKeyOf
  , currentKeyIn
  , keyIdOf

    -- * Passkeys
  , passkeysOf
  , ownerOf
  , registerPasskey
  , assertPasskey
  , removePasskey
  , maxPasskeys

    -- * Ceremonies
  , Ceremonies
  , Purpose (..)
  , newCeremonies
  , beginCeremony
  , takeCeremony
  , beginSignIn
  , takeSignIn
  , maxSignInsPerAddress
  , ceremonyLifetime
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as BS
import Data.Char (isAsciiLower)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, defaultTimeLocale, formatTime)
import Database.Beam (all_, asc_, current_, delete, filter_, insert, insertValues, isJust_, isNothing_, orderBy_, runDelete, runInsert, runSelectReturningList, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Network.Wai (Request)
import Protolude
import Wiki.Api.ContentPolicy (originOf)
import Wiki.Api.Opaque (PasswordWrapChange (..))
import Wiki.Api.Vault (NewPublicKey (..), PasskeyInfo (..), PublicKeyEntry (..), StoredVault (..), VaultChange (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant.Vault (assistantItem)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.Vault (Ciphertext (..), CredentialId (..), Item (..), ItemName (..), KeyId (..), Nonce (..), PublicKey (..), Salt (..), Sealed (..), Unlock (..), Vault (..), VaultTag (..), WrappedKey (..), identityItem, itemOf, passkeyWraps, vaultFormat, wrapFor)
import Wiki.Server.Address (requestOrigin)
import Wiki.Server.Storage (Storage, reading, writing, writingEither)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (StoredPassword (..), micro, passwordOf)
import Wiki.Server.Storage.Schema (Passkeys (..), PublicKeys (..), VaultItems (..), Vaults (..), WikiDb (..), wikiDb)
import Wiki.Server.WebAuthn (AssertionRefusal (..), NewCredential (..), StoredKey (..), fromBase64Url, toBase64Url)

--------------------------------------------------------------------------------
-- The site

-- | 'Site': what a passkey is made for: the relying party's id (the
-- wiki's host, without its port) and the origins the wiki's pages are
-- served from.
data Site = Site
  { rpId :: Text
  , origins :: [Text]
  }
  deriving stock (Eq, Show)

-- | The site a request reaches: that of the wiki's public address when
-- the administration has set one, or else the origin the request names
-- ('requestOrigin': the host, and the scheme a proxy in front of the
-- server says the browser used, else plain HTTP). A proxy that serves the
-- wiki over HTTPS and does not say so with @X-Forwarded-Proto@ needs the
-- public address set, or the browser's origin is refused.
siteFor :: Maybe Url -> Request -> Site
siteFor publicUrl request = Site {rpId = hostOf (T.drop 3 (snd (T.breakOn "://" origin))), origins = [origin]}
  where
    asked = requestOrigin request
    origin = fromMaybe (T.toLower asked) ((publicUrl >>= originOf . (\u -> u.text)) <|> originOf asked)
    hostOf authority
      | "[" `T.isPrefixOf` authority = T.takeWhile (/= ']') (T.drop 1 authority)
      | otherwise = T.takeWhile (/= ':') authority

--------------------------------------------------------------------------------
-- The vault

-- | The tag of a vault's revision, as its @ETag@: the number, quoted.
tagOf :: Int64 -> VaultTag
tagOf revision = VaultTag ("\"" <> show revision <> "\"")

-- | A user's vault and its tag, if they have one.
storedVault :: Storage -> UserId -> IO (Maybe StoredVault)
storedVault st u = reading st (vaultIn u)

-- | A user's vault as stored now, in the current format: the row of
-- @vaults@, its items, and the wraps of its key, the passkeys' from
-- @passkeys@.
vaultIn :: (Backend be) => UserId -> Db be (Maybe StoredVault)
vaultIn u =
  runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text) (all_ wikiDb.vaults))) >>= \case
    [x] -> do
      items <- runSelectReturningList (select (filter_ (\i -> i.user_id ==. val_ u.text) (all_ wikiDb.vault_items)))
      wrapped <- runSelectReturningList (select (filter_ (\p -> p.user_id ==. val_ u.text &&. isJust_ p.wrapped_key) (all_ wikiDb.passkeys)))
      let byPassword = case (x.password_nonce, x.password_key) of
            (Just n, Just k) -> [(ByPassword, WrappedKey (Nonce n) (Ciphertext k))]
            _ -> []
      pure $
        Just
          StoredVault
            { tag = tagOf x.revision
            , vault =
                Vault
                  { format = vaultFormat
                  , salt = Salt x.salt
                  , items = Map.fromList [(ItemName i.name, Item {keyId = KeyId <$> i.key_id, sealed = Sealed (Nonce i.nonce) (Ciphertext i.ciphertext)}) | i <- items]
                  , wraps =
                      Map.fromList $
                        byPassword <> [(ByPasskey (CredentialId p.credential_id), WrappedKey (Nonce n) (Ciphertext k)) | p <- wrapped, Just n <- [p.wrapped_nonce], Just k <- [p.wrapped_key]]
                  }
            }
    _ -> pure Nothing

-- | The rows of a user's passkeys.
passkeysWhere :: (Backend be) => UserId -> Db be [Passkeys Identity]
passkeysWhere u = runSelectReturningList (select (filter_ (\p -> p.user_id ==. val_ u.text) (all_ wikiDb.passkeys)))

-- | The longest text of a vault's that is stored: its ciphertext holds a
-- few keys and settings, a few kilobytes; nothing much longer is one.
maxVaultText :: Int
maxVaultText = 256 * 1024

-- | The most items a vault keeps: a few kinds of secret, with room for
-- more; a bound on what one account stores.
maxVaultItems :: Int
maxVaultItems = 16

-- | Whether a name can be an item's: one to 32 lower-case letters, digits
-- and hyphens.
itemNameOk :: ItemName -> Bool
itemNameOk n = not (T.null n.text) && T.length n.text <= 32 && T.all (\c -> isAsciiLower c || isDigit c || c == '-') n.text

-- | The number of bytes base64url text holds, if it is base64url.
bytesIn :: Text -> Maybe Int
bytesIn t = BS.length <$> fromBase64Url t

-- | Whether base64url text holds exactly so many bytes.
holds :: Int -> Text -> Bool
holds n t = bytesIn t == Just n

-- | Why a vault cannot be stored as it is, if it cannot: a format this
-- wiki does not take, a part of the wrong length, too many items or a
-- name that is not one. The server checks lengths, and never reads what
-- the parts hold: the salt is 32 bytes, each nonce 12, each wrapped key 48
-- (an AES-256 key and AES-GCM's tag), a key id 16, and the @identity@
-- item an X25519 private key in PKCS #8 (48 bytes) and its tag, 64 bytes.
-- Other items are any length up to 'maxVaultText'.
vaultProblem :: Vault -> Maybe WikiError
vaultProblem v
  | v.format /= 1 && v.format /= vaultFormat = Just (Invalid ("A vault of format " <> show v.format <> ": this wiki writes format " <> show vaultFormat <> "."))
  | any (\t -> T.null t || T.length t > maxVaultText) texts = Just (Invalid "This is not a vault this wiki keeps: a part of it is empty or too long.")
  | Map.null v.items = Just (Invalid "A vault holds at least one item.")
  | Map.size v.items > maxVaultItems || not (all itemNameOk (Map.keys v.items)) = Just (Invalid ("A vault holds at most " <> show maxVaultItems <> " items, named in lower-case letters, digits and hyphens."))
  | not (holds 32 v.salt.text) = Just (wrongLength "Its salt")
  | not (all (\i -> holds 12 i.sealed.nonce.text) (Map.elems v.items) && all (\w -> holds 12 w.nonce.text) (Map.elems v.wraps)) = Just (wrongLength "A nonce")
  | not (all (\w -> holds 48 w.key.text) (Map.elems v.wraps)) = Just (wrongLength "A wrapped key")
  | not (all (\i -> maybe True (\k -> holds 16 k.text) i.keyId) (Map.elems v.items)) = Just (wrongLength "A key id")
  | Just i <- itemOf identityItem v, isNothing i.keyId || not (holds 64 i.sealed.ciphertext.text) = Just (wrongLength "Its key pair")
  | otherwise = Nothing
  where
    texts =
      [v.salt.text]
        <> concat [[i.sealed.nonce.text, i.sealed.ciphertext.text] <> maybe [] (\k -> [k.text]) i.keyId | i <- Map.elems v.items]
        <> concat [[w.nonce.text, w.key.text] | w <- Map.elems v.wraps]
    wrongLength what = Invalid ("This is not a vault this wiki keeps: " <> T.toLower (T.take 1 what) <> T.drop 1 what <> " is not of its length.")

-- | The id of a public key: the first 16 bytes of its SHA-256, in
-- base64url, as the browser computes it; 'Nothing' for a key that is not
-- X25519's 32 bytes.
keyIdOf :: PublicKey -> Maybe KeyId
keyIdOf k = case fromBase64Url k.text of
  Just raw | BS.length raw == 32 -> Just (KeyId (toBase64Url (BS.take 16 (SHA256.hash raw))))
  _ -> Nothing

-- | A user's current public key, if they have one.
publicKeyOf :: Storage -> UserId -> IO (Maybe PublicKeyEntry)
publicKeyOf st u = reading st (currentKeyIn u)

currentKeyIn :: (Backend be) => UserId -> Db be (Maybe PublicKeyEntry)
currentKeyIn u =
  runSelectReturningList (select (filter_ (\k -> k.user_id ==. val_ u.text &&. isNothing_ k.retired_at) (all_ wikiDb.public_keys))) <&> \case
    [k] -> Just PublicKeyEntry {user = u, keyId = KeyId k.key_id, publicKey = PublicKey k.public_key, createdAt = k.created_at}
    _ -> Nothing

-- | Why the key pair a vault holds cannot be stored with the public key
-- sent beside it, if it cannot. The vault's @identity@ item and the
-- directory's current key name the same key pair once stored: a new key
-- pair comes with its public key, which must be the one its id names, and
-- only for a user who has no current key (a key pair is replaced only
-- after a password reset retired the last); an item already there needs
-- none; and the item cannot be removed, except by a reset.
identityProblem :: Maybe Item -> Maybe NewPublicKey -> Maybe PublicKeyEntry -> Maybe WikiError
identityProblem pair new current = case (pair, new) of
  (_, Just k)
    | Just k.keyId /= (pair >>= \i -> i.keyId) -> Just (Invalid "The public key sent is not the key pair the vault holds.")
    | keyIdOf k.publicKey /= Just k.keyId -> Just (Invalid "A public key is X25519's 32 bytes, and its id the first 16 bytes of its SHA-256.")
    | Just c <- current, c.keyId /= k.keyId -> Just (Conflict "You have a key pair already: it is replaced only after a password reset.")
    | otherwise -> Nothing
  (Nothing, Nothing) | isJust current -> Just (Invalid "The vault's key pair cannot be removed.")
  (Just i, Nothing) | i.keyId /= ((\c -> c.keyId) <$> current) -> Just (Invalid "The vault holds a key pair the directory does not have: send its public key with it.")
  _ -> Nothing

-- | Store a user's vault, over the version the given tag names, or, with
-- none, only if they have no vault yet; 'Conflict' otherwise. The result
-- is the vault as stored now.
--
-- A vault of the current format is the vault whole: its items and its
-- password's wrap replace those stored. One of format 1, which a tab of
-- the wiki before WP5.74 sends, holds only the assistant's settings: they
-- replace the stored @assistant@ item, and the other items and the
-- password's wrap stay. Either way the passkeys' wraps it carries are
-- stored for the passkeys they name, which must be the user's ('Invalid'
-- otherwise), and those of the passkeys it does not name are kept: a
-- passkey's wrap goes with the passkey.
storeVault :: Storage -> UTCTime -> UserId -> Maybe VaultTag -> VaultChange -> IO (Either WikiError StoredVault)
storeVault st now u base change = case vaultProblem change.vault of
  Just problem -> pure (Left problem)
  Nothing -> writingEither st (storeVaultIn now u base change)

-- | 'storeVault' in a transaction of the caller's, for a change that must
-- be stored together with the vault (a new password and its wrap).
storeVaultIn :: (Backend be) => UTCTime -> UserId -> Maybe VaultTag -> VaultChange -> Db be (Either WikiError StoredVault)
storeVaultIn now u base change
  | Just problem <- vaultProblem v = pure (Left problem)
  | otherwise = do
      mine <- map (\p -> p.credential_id) <$> passkeysWhere u
      before <- vaultIn u
      current <- currentKeyIn u
      hasRecord <-
        passwordOf u <&> \case
          Just (WithRecord _) -> True
          _ -> False
      let unlocking = maybe [] (Map.keys . passkeyWraps . (\b -> b.vault)) before
      taken <- case change.publicKey of
        Just k | Just k.keyId /= ((\c -> c.keyId) <$> current) -> not . null <$> runSelectReturningList (select (filter_ (\x -> x.key_id ==. val_ k.keyId.text) (all_ wikiDb.public_keys)))
        _ -> pure False
      let named = Map.keys (passkeyWraps v)
          -- What the vault holds once stored: format 1's settings over the
          -- items and the password's wrap stored, else the vault as sent.
          whole = case (v.format, before) of
            (1, Just old) -> (Map.union v.items old.vault.items, wrapFor ByPassword old.vault)
            _ -> (v.items, wrapFor ByPassword v)
      case (before, base) of
        _ | any (\i -> i.text `notElem` mine) named -> pure (Left (Invalid "The vault names a passkey that is not one of yours."))
        _ | Just problem <- identityProblem (Map.lookup identityItem (fst whole)) change.publicKey current -> pure (Left problem)
        _ | isJust (snd whole) && not hasRecord -> pure (Left (Invalid "You have no password to unlock a vault with: you sign in with a provider."))
        _ | Map.member identityItem (fst whole) && isNothing (snd whole) && null (named <> unlocking) -> pure (Left (Invalid "A vault that holds your key pair keeps at least one way to unlock it."))
        _ | taken -> pure (Left (Conflict "This public key is in the directory already."))
        (Nothing, Nothing) -> do
          runInsert . insert wikiDb.vaults $
            insertValues [VaultRow {user_id = u.text, salt = v.salt.text, password_nonce = Nothing, password_key = Nothing, revision = 1, updated_at = micro now}]
          stored current whole
        (Just old, Just t)
          | old.tag == t -> do
              runUpdate $
                update
                  wikiDb.vaults
                  (\x -> (x.salt <-. val_ v.salt.text) <> (x.revision <-. current_ x.revision + 1) <> (x.updated_at <-. val_ (micro now)))
                  (\x -> x.user_id ==. val_ u.text)
              stored current whole
        (Nothing, Just _) -> pure (Left (Conflict "There is no vault any more: synchronisation was turned off on another device."))
        (Just _, Nothing) -> pure (Left (Conflict "There is a vault already: unlock it with a passkey instead."))
        _ -> pure (Left (Conflict "The vault was changed on another device meanwhile."))
  where
    v = change.vault
    stored :: (Backend be) => Maybe PublicKeyEntry -> (Map ItemName Item, Maybe WrappedKey) -> Db be (Either WikiError StoredVault)
    stored current (items, password) = do
      for_ change.publicKey $ \k ->
        unless (Just k.keyId == ((\c -> c.keyId) <$> current))
          $ runInsert . insert wikiDb.public_keys
          $ insertValues [PublicKeyRow {key_id = k.keyId.text, user_id = u.text, public_key = k.publicKey.text, created_at = micro now, retired_at = Nothing, retired_because = Nothing}]
      runUpdate (update wikiDb.vaults (\x -> (x.password_nonce <-. val_ ((\w -> w.nonce.text) <$> password)) <> (x.password_key <-. val_ ((\w -> w.key.text) <$> password))) (\x -> x.user_id ==. val_ u.text))
      runDelete (delete wikiDb.vault_items (\i -> i.user_id ==. val_ u.text))
      runInsert . insert wikiDb.vault_items $
        insertValues [VaultItemRow {user_id = u.text, name = n.text, key_id = (\k -> k.text) <$> i.keyId, nonce = i.sealed.nonce.text, ciphertext = i.sealed.ciphertext.text} | (n, i) <- Map.toList items]
      for_ (Map.toList (passkeyWraps v)) $ \(i, w) ->
        runUpdate (update wikiDb.passkeys (\p -> (p.wrapped_nonce <-. val_ (Just w.nonce.text)) <> (p.wrapped_key <-. val_ (Just w.key.text))) (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text))
      maybe (Left NotFound) Right <$> vaultIn u

-- | Turn the assistant's synchronisation off for a user: the vault's
-- @assistant@ item goes. A vault that holds nothing else goes with it,
-- and so do the vault key's wrapped copies; a vault that holds more (the
-- user's key pair) stays, with its wraps, at a new version. Their passkeys
-- stay, since they also sign the user in. Nothing to delete is no error.
-- A tab of the wiki from before WP5.74 asks for this too, and so never
-- deletes more than the assistant's settings.
deleteVault :: Storage -> UTCTime -> UserId -> IO ()
deleteVault st now u = writing st $ do
  runDelete (delete wikiDb.vault_items (\i -> i.user_id ==. val_ u.text &&. i.name ==. val_ assistantItem.text))
  left <- runSelectReturningList (select (filter_ (\i -> i.user_id ==. val_ u.text) (all_ wikiDb.vault_items)))
  if null left
    then do
      runDelete (delete wikiDb.vaults (\x -> x.user_id ==. val_ u.text))
      runUpdate (update wikiDb.passkeys (\p -> (p.wrapped_nonce <-. val_ Nothing) <> (p.wrapped_key <-. val_ Nothing)) (\p -> p.user_id ==. val_ u.text))
    else runUpdate (update wikiDb.vaults (\x -> (x.revision <-. current_ x.revision + 1) <> (x.updated_at <-. val_ (micro now))) (\x -> x.user_id ==. val_ u.text))

--------------------------------------------------------------------------------
-- The password's wrap

-- | Replace the password's wrap of a user's vault key, in the transaction
-- of a change of their password ("Wiki.Server.Accounts"): the vault key
-- wrapped with the new password's key, over the version of the vault the
-- tag names. A vault that opens with the password needs the new wrap, or
-- the change is refused: the old wrap would open with nothing any more. A
-- wrap for a vault that does not open with the password, or over another
-- version, is refused too. Without a vault, or for a vault without the
-- password's wrap, a change carries none and nothing happens here.
passwordRewrapIn :: (Backend be) => UTCTime -> UserId -> Maybe PasswordWrapChange -> Db be (Either WikiError ())
passwordRewrapIn now u change = do
  row <- runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text) (all_ wikiDb.vaults)))
  let hasPassword x = isJust x.password_key
  case (row, change) of
    ([x], Nothing) | hasPassword x -> pure (Left (Conflict "Your vault opens with your password: change it from a page that can carry the vault along (the wiki at its HTTPS address), or reload this page and try again."))
    (_, Nothing) -> pure (Right ())
    ([x], Just c)
      | not (hasPassword x) -> pure (Left (Conflict "Your vault does not open with your password."))
      | tagOf x.revision /= c.tag -> pure (Left (Conflict "Your vault was changed meanwhile: try again."))
      | not (holds 12 c.wrapped.nonce.text && holds 48 c.wrapped.key.text) -> pure (Left (Invalid "This is not a vault this wiki keeps: a wrapped key is not of its length."))
      | otherwise -> do
          runUpdate $
            update
              wikiDb.vaults
              (\v -> (v.password_nonce <-. val_ (Just c.wrapped.nonce.text)) <> (v.password_key <-. val_ (Just c.wrapped.key.text)) <> (v.revision <-. current_ v.revision + 1) <> (v.updated_at <-. val_ (micro now)))
              (\v -> v.user_id ==. val_ u.text)
          pure (Right ())
    (_, Just _) -> pure (Left (Conflict "You have no vault to carry along."))

-- | What a password reset does to a user's vault, in its transaction
-- ("Wiki.Server.Reset"): the old password's key is gone, so is its wrap.
-- A vault that a passkey still unlocks keeps everything else, and the
-- user unlocks it with a passkey to add the new password's wrap. A vault
-- that only the password unlocked can no longer be opened by anyone: it
-- is deleted, with its items (the assistant's settings and the user's
-- private key), and the user's public key is retired, as changed by a
-- reset, so that what was sealed to it can be found again. The next
-- sign-in makes a new vault and key pair.
resetVaultIn :: (Backend be) => UTCTime -> UserId -> Db be ()
resetVaultIn now u = do
  unlocking <- runSelectReturningList (select (filter_ (\p -> p.user_id ==. val_ u.text &&. isJust_ p.wrapped_key) (all_ wikiDb.passkeys)))
  if null unlocking
    then do
      runDelete (delete wikiDb.vault_items (\i -> i.user_id ==. val_ u.text))
      runDelete (delete wikiDb.vaults (\x -> x.user_id ==. val_ u.text))
      runUpdate (update wikiDb.public_keys (\k -> (k.retired_at <-. val_ (Just (micro now))) <> (k.retired_because <-. val_ (Just "reset"))) (\k -> k.user_id ==. val_ u.text &&. isNothing_ k.retired_at))
    else
      runUpdate
        ( update
            wikiDb.vaults
            (\x -> (x.password_nonce <-. val_ Nothing) <> (x.password_key <-. val_ Nothing) <> (x.revision <-. current_ x.revision + 1) <> (x.updated_at <-. val_ (micro now)))
            (\x -> x.user_id ==. val_ u.text &&. isJust_ x.password_key)
        )

--------------------------------------------------------------------------------
-- Passkeys

-- | The most passkeys a user may register: enough for every device and a
-- spare, and a bound on what one account stores.
maxPasskeys :: Int
maxPasskeys = 20

-- | A user's passkeys, the oldest first.
passkeysOf :: Storage -> UserId -> IO [PasskeyInfo]
passkeysOf st u = reading st (passkeysIn u)

passkeysIn :: (Backend be) => UserId -> Db be [PasskeyInfo]
passkeysIn u =
  map (\p -> PasskeyInfo {id = CredentialId p.credential_id, name = p.name, createdAt = p.created_at, lastUsedAt = p.last_used_at, unlocks = isJust p.wrapped_key})
    <$> runSelectReturningList (select (orderBy_ (\p -> (asc_ p.created_at, asc_ p.credential_id)) (filter_ (\p -> p.user_id ==. val_ u.text) (all_ wikiDb.passkeys))))

-- | Whose passkey a credential id names, if anyone's: what a sign-in with
-- a passkey alone learns first.
ownerOf :: Storage -> CredentialId -> IO (Maybe UserId)
ownerOf st i =
  reading st $
    runSelectReturningList (select (filter_ (\p -> p.credential_id ==. val_ i.text) (all_ wikiDb.passkeys))) <&> \case
      [p] -> Just (UserId p.user_id)
      _ -> Nothing

-- | The longest name of a passkey, in characters.
maxPasskeyName :: Int
maxPasskeyName = 100

-- | The longest public key of a passkey that is stored, in bytes: an
-- RS256 key of 4096 bits takes some 550, so nothing much longer is one.
maxPublicKey :: Int
maxPublicKey = 16 * 1024

-- | The longest credential id, in bytes, as WebAuthn bounds it.
maxCredentialId :: Int
maxCredentialId = 1023

-- | Store a passkey just registered for a user, with the name the user
-- gave it (when the day it was added otherwise), without a wrapped key
-- yet. A credential registered already (by anyone) is a 'Conflict'; one
-- more than 'maxPasskeys', one whose id or public key is too long, or a
-- name longer than 'maxPasskeyName', is 'Invalid'.
registerPasskey :: Storage -> UTCTime -> UserId -> Maybe Text -> NewCredential -> IO (Either WikiError PasskeyInfo)
registerPasskey _ _ _ _ new
  | BS.length new.publicKey > maxPublicKey || BS.null new.credentialId || BS.length new.credentialId > maxCredentialId =
      pure (Left (Invalid "This passkey's id or public key is longer than a passkey's."))
registerPasskey _ _ _ (Just given) _
  | T.length (T.strip given) > maxPasskeyName = pure (Left (Invalid ("A passkey's name has at most " <> show maxPasskeyName <> " characters.")))
registerPasskey st now u given new = writingEither st $ do
  let i = toBase64Url new.credentialId
  taken <- runSelectReturningList (select (filter_ (\p -> p.credential_id ==. val_ i) (all_ wikiDb.passkeys)))
  count' <- length <$> passkeysWhere u
  if
    | not (null taken) -> pure (Left (Conflict "This passkey is registered already."))
    | count' >= maxPasskeys -> pure (Left (Invalid ("You have " <> show maxPasskeys <> " passkeys already: remove one first.")))
    | otherwise -> do
        runInsert . insert wikiDb.passkeys $
          insertValues
            [ PasskeyRow
                { credential_id = i
                , user_id = u.text
                , public_key = toBase64Url new.publicKey
                , algorithm = fromIntegral new.algorithm
                , sign_count = fromIntegral new.signCount
                , name = case T.strip <$> given of
                    Just named | not (T.null named) -> named
                    _ -> "Added on " <> toS (formatTime defaultTimeLocale "%Y-%m-%d at %H:%M UTC" now)
                , created_at = micro now
                , last_used_at = Nothing
                , wrapped_nonce = Nothing
                , wrapped_key = Nothing
                }
            ]
        maybe (Left NotFound) Right . find (\p -> p.id == CredentialId i) <$> passkeysIn u

-- | Check an assertion of one of a user's passkeys with the given check
-- (which 'Wiki.Server.WebAuthn.verifyAssertion' makes), and keep its new
-- signature counter. Another user's passkey, or none, is 'NotFound'; an
-- answer that is not the passkey's is 'Invalid'; a counter that went back
-- is a 'Conflict', with the counter kept as it was.
assertPasskey :: Storage -> UTCTime -> UserId -> CredentialId -> (StoredKey -> Either AssertionRefusal Word32) -> IO (Either WikiError PasskeyInfo)
assertPasskey st now u i verify =
  writingEither st $
    runSelectReturningList (select (filter_ (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text) (all_ wikiDb.passkeys))) >>= \case
      [found] | Just publicKey <- fromBase64Url found.public_key ->
        case verify StoredKey {publicKey, signCount = fromIntegral found.sign_count} of
          Left (Refused why) -> pure (Left (Invalid ("The passkey's answer was refused: " <> why <> ".")))
          Left (CounterWentBack was now') ->
            pure (Left (Conflict ("The passkey's counter went back, from " <> show was <> " to " <> show now' <> ": it may have been copied. If you trust it, remove it and add it again.")))
          Right counted -> do
            runUpdate (update wikiDb.passkeys (\p -> (p.sign_count <-. val_ (fromIntegral counted)) <> (p.last_used_at <-. val_ (Just (micro now)))) (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text))
            maybe (Left NotFound) Right . find (\p -> p.id == i) <$> passkeysIn u
      _ -> pure (Left NotFound)

-- | Remove one of a user's passkeys, with its wrapped copy of the vault
-- key, which changes the vault's version. The result is their passkeys
-- left; another user's passkey, or none, is 'NotFound'. The passkey that
-- is the last way to unlock a vault holding the user's key pair is
-- refused ('Conflict'): checked here, in the transaction, because the
-- panel's guard can work from a stale list (another tab, two removals in
-- a row), and a vault nothing unlocks is lost once the device's copies go.
removePasskey :: Storage -> UTCTime -> UserId -> CredentialId -> IO (Either WikiError [PasskeyInfo])
removePasskey st now u i = writingEither st $ do
  there <- runSelectReturningList (select (filter_ (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text) (all_ wikiDb.passkeys)))
  holdsPair <- not . null <$> runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text &&. x.name ==. val_ identityItem.text) (all_ wikiDb.vault_items)))
  byPassword <- any (\x -> isJust x.password_key) <$> runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text) (all_ wikiDb.vaults)))
  othersUnlock <- any (\p -> p.credential_id /= i.text && isJust p.wrapped_key) <$> runSelectReturningList (select (filter_ (\p -> p.user_id ==. val_ u.text) (all_ wikiDb.passkeys)))
  let unlocksVault = any (\p -> isJust p.wrapped_key) there
  if
    | null there -> pure (Left NotFound)
    | holdsPair && unlocksVault && not byPassword && not othersUnlock ->
        pure (Left (Conflict "This passkey is the last way to unlock your vault, which holds your keys: add your password or another passkey as a way to unlock it first."))
    | otherwise -> do
        runDelete (delete wikiDb.passkeys (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text))
        runUpdate (update wikiDb.vaults (\x -> (x.revision <-. current_ x.revision + 1) <> (x.updated_at <-. val_ (micro now))) (\x -> x.user_id ==. val_ u.text))
        Right <$> passkeysIn u

--------------------------------------------------------------------------------
-- Ceremonies

-- | 'Purpose': what a challenge was given for.
data Purpose
  = Registering
  | Asserting
  | -- | The second step of a sign-in, by passkey instead of a code: the
    -- ceremony is kept for the half-finished sign-in rather than a session.
    Confirming
  deriving stock (Eq, Ord, Show)

-- | 'Ceremonies': the challenges waiting for the browser's answer. Those of
-- a signed-in session (or a half-finished sign-in) are kept by the session
-- (the hash of its secret) and the purpose, each with the user it was given
-- to and when it expires. Those of a sign-in with a passkey alone are kept
-- by the challenge itself, with the address that asked for it and when it
-- expires.
data Ceremonies = Ceremonies
  { held :: IORef (Map (Text, Purpose) (UserId, ByteString, UTCTime))
  , signIns :: IORef (Map ByteString (Text, UTCTime))
  }

newCeremonies :: IO Ceremonies
newCeremonies = Ceremonies <$> newIORef mempty <*> newIORef mempty

-- | How long a challenge waits for its answer: five minutes, which a
-- person touching a passkey needs much less of.
ceremonyLifetime :: NominalDiffTime
ceremonyLifetime = 5 * 60

-- | The most challenges waiting, of each kind; beyond it, the oldest are
-- dropped.
maxCeremonies :: Int
maxCeremonies = 10000

-- | The most sign-in challenges waiting for one address. A browser asks
-- for one each time the sign-in form opens, and anyone may ask without
-- signing in, so one address may not take the whole of 'maxCeremonies'.
maxSignInsPerAddress :: Int
maxSignInsPerAddress = 50

-- | The live entries of a map of challenges, bounded to one fewer than
-- 'maxCeremonies' by dropping the oldest, so that one more fits.
bounded :: (Ord k) => UTCTime -> (v -> UTCTime) -> Map k v -> Map k v
bounded now expiry m =
  let live = Map.filter (\v -> expiry v > now) m
   in if Map.size live >= maxCeremonies then Map.fromList (drop (Map.size live - maxCeremonies + 1) (sortOn (expiry . snd) (Map.toList live))) else live

-- | A new challenge (32 random bytes) for a session and a user, replacing
-- the session's waiting one for the same purpose.
beginCeremony :: Ceremonies -> UTCTime -> Text -> UserId -> Purpose -> IO ByteString
beginCeremony ceremonies now session u purpose = do
  challenge <- getRandomBytes 32
  atomicModifyIORef' ceremonies.held $ \m ->
    (Map.insert (session, purpose) (u, challenge, addUTCTime ceremonyLifetime now) (bounded now (\(_, _, e) -> e) m), ())
  pure challenge

-- | The challenge waiting for a session, a user and a purpose, if it has
-- not expired; it is used up.
takeCeremony :: Ceremonies -> UTCTime -> Text -> UserId -> Purpose -> IO (Maybe ByteString)
takeCeremony ceremonies now session u purpose =
  atomicModifyIORef' ceremonies.held $ \m -> case Map.lookup (session, purpose) m of
    Just (owner, challenge, expires) | owner == u, expires > now -> (Map.delete (session, purpose) m, Just challenge)
    _ -> (Map.delete (session, purpose) m, Nothing)

-- | A new challenge for a sign-in with a passkey, asked for from an
-- address; 'Nothing' when the address has 'maxSignInsPerAddress' waiting
-- already.
beginSignIn :: Ceremonies -> UTCTime -> Text -> IO (Maybe ByteString)
beginSignIn ceremonies now address = do
  challenge <- getRandomBytes 32
  atomicModifyIORef' ceremonies.signIns $ \m ->
    let live = bounded now snd m
     in if Map.size (Map.filter ((== address) . fst) live) >= maxSignInsPerAddress
          then (live, Nothing)
          else (Map.insert challenge (address, addUTCTime ceremonyLifetime now) live, Just challenge)

-- | Whether a sign-in challenge is waiting and has not expired; it is used
-- up either way.
takeSignIn :: Ceremonies -> UTCTime -> ByteString -> IO Bool
takeSignIn ceremonies now challenge =
  atomicModifyIORef' ceremonies.signIns $ \m -> case Map.lookup challenge m of
    Just (_, expires) | expires > now -> (Map.delete challenge m, True)
    _ -> (Map.delete challenge m, False)
