{-# LANGUAGE MultiWayIf #-}

-- | The assistant's vault and the passkeys that unlock it, on the server
-- (WP5.21 of docs/PLAN.md, "Wiki.Api.Vault"): what the routes under
-- @assistant\/@ store and check.
--
-- The server keeps, per user, the vault as the browser sent it
-- (@assistant_vaults@: its format, salt, nonce and ciphertext, with a
-- revision that is its tag) and the user's passkeys (@passkeys@: each
-- one's credential id, public key, algorithm and signature counter, and
-- the vault key wrapped for it). It cannot open the vault, and never
-- sees the PRF output a wrapped key is unwrapped with, nor a provider's
-- key. An administrator, who can read the database, sees no more than
-- that a vault and passkeys exist.
--
-- = Ceremonies
--
-- A registration or an assertion takes two requests: one that gives the
-- browser a challenge, and one that brings the browser's answer. The
-- challenge waits in memory ('Ceremonies'), for the session that asked
-- for it, for 'ceremonyLifetime', and is used once. A restart forgets the
-- challenges waiting, which costs whoever was touching their passkey a
-- second touch.
module Wiki.Server.Vault
  ( -- * The site
    Site (..)
  , siteFor

    -- * The vault
  , storedVault
  , storeVault
  , deleteVault

    -- * Passkeys
  , passkeysOf
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
  , ceremonyLifetime
  )
where

import Crypto.Random (getRandomBytes)
import Data.CaseInsensitive qualified as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, defaultTimeLocale, formatTime)
import Database.SQLite.Simple (Connection, Only (..), changes, execute, query)
import Network.Wai (Request (..))
import Protolude
import Wiki.Api.ContentPolicy (originOf)
import Wiki.Api.Vault (PasskeyInfo (..), StoredVault (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant.Vault (CredentialId (..), Sealed (..), Vault (..), VaultTag (..), WrappedKey (..), vaultFormat)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))
import Wiki.Server.Accounts (immediately)
import Wiki.Server.Storage (Storage, withDatabase)
import Wiki.Server.Storage.Rows (Stamp (..))
import Wiki.Server.WebAuthn (AssertionRefusal (..), NewCredential (..), StoredKey (..), toBase64Url)

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
-- the administration has set one, or else the host the request names (as
-- a proxy in front of the server passes it on), over HTTPS or plain HTTP,
-- since the server may not know which the browser used.
siteFor :: Maybe Url -> Request -> Site
siteFor publicUrl request = case publicUrl >>= originOf . (\u -> u.text) of
  Just origin -> Site {rpId = hostOf (T.drop 3 (snd (T.breakOn "://" origin))), origins = [origin]}
  Nothing -> Site {rpId = hostOf host, origins = ["https://" <> host, "http://" <> host]}
  where
    header name = decodeUtf8With lenientDecode <$> lookup (CI.mk name) (requestHeaders request)
    host = T.toLower (T.strip (T.takeWhile (/= ',') (fromMaybe "localhost" (header "X-Forwarded-Host" <|> (decodeUtf8With lenientDecode <$> requestHeaderHost request)))))
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
storedVault st u = withDatabase st (`vaultIn` u)

vaultIn :: Connection -> UserId -> IO (Maybe StoredVault)
vaultIn c u =
  query c "SELECT format, salt, nonce, ciphertext, revision FROM assistant_vaults WHERE user_id = ?" (Only u.text) >>= \case
    [(format, salt, nonce, ciphertext, revision)] -> do
      wrapped <- query c "SELECT credential_id, wrapped_nonce, wrapped_key FROM passkeys WHERE user_id = ? AND wrapped_key IS NOT NULL" (Only u.text)
      pure $
        Just
          StoredVault
            { tag = tagOf revision
            , vault = Vault {format, salt, sealed = Sealed {nonce, ciphertext}, wrapped = Map.fromList [(CredentialId i, WrappedKey n k) | (i, n, k) <- wrapped]}
            }
    _ -> pure Nothing

-- | The longest text of a vault's that is stored: its ciphertext holds a
-- few keys and settings, a few kilobytes; nothing much longer is one.
maxVaultText :: Int
maxVaultText = 256 * 1024

-- | Store a user's vault, over the version the given tag names, or, with
-- none, only if they have no vault yet; 'Conflict' otherwise. The wrapped
-- keys it carries are stored for the passkeys they name, which must be
-- the user's ('Invalid' otherwise); the wrapped keys of the passkeys it
-- does not name are kept. The result is the vault as stored now.
storeVault :: Storage -> UTCTime -> UserId -> Maybe VaultTag -> Vault -> IO (Either WikiError StoredVault)
storeVault st now u base v
  | v.format /= vaultFormat = pure (Left (Invalid ("A vault of format " <> show v.format <> ": this wiki writes format " <> show vaultFormat <> ".")))
  | any (\t -> T.null t || T.length t > maxVaultText) [v.salt, v.sealed.nonce, v.sealed.ciphertext] = pure (Left (Invalid "This is not a vault this wiki keeps: a part of it is empty or too long."))
  | otherwise = withDatabase st $ \c -> immediately c $ do
      mine <- map fromOnly <$> query c "SELECT credential_id FROM passkeys WHERE user_id = ?" (Only u.text)
      revision <- map fromOnly <$> query c "SELECT revision FROM assistant_vaults WHERE user_id = ?" (Only u.text)
      case (revision, base) of
        _ | any (\i -> i.text `notElem` mine) (Map.keys v.wrapped) -> pure (Left (Invalid "The vault names a passkey that is not one of yours."))
        ([], Nothing) -> do
          execute
            c
            "INSERT INTO assistant_vaults (user_id, format, salt, nonce, ciphertext, revision, updated_at) VALUES (?, ?, ?, ?, ?, 1, ?)"
            (u.text, v.format, v.salt, v.sealed.nonce, v.sealed.ciphertext, Stamp now)
          stored c
        ([r :: Int64], Just t)
          | tagOf r == t -> do
              execute
                c
                "UPDATE assistant_vaults SET format = ?, salt = ?, nonce = ?, ciphertext = ?, revision = revision + 1, updated_at = ? WHERE user_id = ?"
                (v.format, v.salt, v.sealed.nonce, v.sealed.ciphertext, Stamp now, u.text)
              stored c
        ([], Just _) -> pure (Left (Conflict "There is no vault any more: synchronisation was turned off on another device."))
        ([_], Nothing) -> pure (Left (Conflict "There is a vault already: unlock it with a passkey instead."))
        _ -> pure (Left (Conflict "The vault was changed on another device meanwhile."))
  where
    stored c = do
      for_ (Map.toList v.wrapped) $ \(i, w) ->
        execute c "UPDATE passkeys SET wrapped_nonce = ?, wrapped_key = ? WHERE credential_id = ? AND user_id = ?" (w.nonce, w.key, i.text, u.text)
      maybe (Left NotFound) Right <$> vaultIn c u

-- | Turn synchronisation off for a user: their vault and their passkeys
-- go. Nothing else is needed: a user who has lost every passkey starts
-- again this way. Nothing to delete is no error.
deleteVault :: Storage -> UserId -> IO ()
deleteVault st u = withDatabase st $ \c -> void . immediately c $ do
  execute c "DELETE FROM assistant_vaults WHERE user_id = ?" (Only u.text)
  execute c "DELETE FROM passkeys WHERE user_id = ?" (Only u.text)
  pure (Right () :: Either () ())

--------------------------------------------------------------------------------
-- Passkeys

-- | The most passkeys a user may register: enough for every device and a
-- spare, and a bound on what one account stores.
maxPasskeys :: Int
maxPasskeys = 20

-- | A user's passkeys, the oldest first.
passkeysOf :: Storage -> UserId -> IO [PasskeyInfo]
passkeysOf st u = withDatabase st (`passkeysIn` u)

passkeysIn :: Connection -> UserId -> IO [PasskeyInfo]
passkeysIn c u =
  map (\(i, name, Stamp createdAt, lastUsed, unlocks) -> PasskeyInfo {id = CredentialId i, name, createdAt, lastUsedAt = (\(Stamp t) -> t) <$> lastUsed, unlocks})
    <$> query c "SELECT credential_id, name, created_at, last_used_at, wrapped_key IS NOT NULL FROM passkeys WHERE user_id = ? ORDER BY created_at, credential_id" (Only u.text)

-- | Store a passkey just registered for a user, without a wrapped key yet.
-- A credential registered already (by anyone) is a 'Conflict'; one more
-- than 'maxPasskeys' is 'Invalid'.
registerPasskey :: Storage -> UTCTime -> UserId -> NewCredential -> IO (Either WikiError PasskeyInfo)
registerPasskey st now u new = withDatabase st $ \c -> immediately c $ do
  let i = toBase64Url new.credentialId
  taken <- query c "SELECT count(*) FROM passkeys WHERE credential_id = ?" (Only i)
  count' <- query c "SELECT count(*) FROM passkeys WHERE user_id = ?" (Only u.text)
  if
    | any ((> (0 :: Int)) . fromOnly) taken -> pure (Left (Conflict "This passkey is registered already."))
    | any ((>= maxPasskeys) . fromOnly) count' -> pure (Left (Invalid ("You have " <> show maxPasskeys <> " passkeys already: remove one first.")))
    | otherwise -> do
        execute
          c
          "INSERT INTO passkeys (credential_id, user_id, public_key, algorithm, sign_count, name, created_at, last_used_at, wrapped_nonce, wrapped_key) VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL)"
          (i, u.text, new.publicKey, new.algorithm, fromIntegral new.signCount :: Int64, "Added on " <> toS (formatTime defaultTimeLocale "%Y-%m-%d at %H:%M UTC" now) :: Text, Stamp now)
        maybe (Left NotFound) Right . find (\p -> p.id == CredentialId i) <$> passkeysIn c u

-- | Check an assertion of one of a user's passkeys with the given check
-- (which 'Wiki.Server.WebAuthn.verifyAssertion' makes), and keep its new
-- signature counter. Another user's passkey, or none, is 'NotFound'; an
-- answer that is not the passkey's is 'Invalid'; a counter that went back
-- is a 'Conflict', with the counter kept as it was.
assertPasskey :: Storage -> UTCTime -> UserId -> CredentialId -> (StoredKey -> Either AssertionRefusal Word32) -> IO (Either WikiError PasskeyInfo)
assertPasskey st now u i verify = withDatabase st $ \c ->
  immediately c $
    query c "SELECT public_key, sign_count FROM passkeys WHERE credential_id = ? AND user_id = ?" (i.text, u.text) >>= \case
      [(publicKey, count')] -> case verify StoredKey {publicKey, signCount = fromIntegral (count' :: Int64)} of
        Left (Refused why) -> pure (Left (Invalid ("The passkey's answer was refused: " <> why <> ".")))
        Left (CounterWentBack was now') ->
          pure (Left (Conflict ("The passkey's counter went back, from " <> show was <> " to " <> show now' <> ": it may have been copied. If you trust it, remove it and add it again.")))
        Right counted -> do
          execute c "UPDATE passkeys SET sign_count = ?, last_used_at = ? WHERE credential_id = ? AND user_id = ?" (fromIntegral counted :: Int64, Stamp now, i.text, u.text)
          maybe (Left NotFound) Right . find (\p -> p.id == i) <$> passkeysIn c u
      _ -> pure (Left NotFound)

-- | Remove one of a user's passkeys, with its wrapped copy of the vault
-- key, which changes the vault's version. The result is their passkeys
-- left; another user's passkey, or none, is 'NotFound'.
removePasskey :: Storage -> UTCTime -> UserId -> CredentialId -> IO (Either WikiError [PasskeyInfo])
removePasskey st now u i = withDatabase st $ \c -> immediately c $ do
  execute c "DELETE FROM passkeys WHERE credential_id = ? AND user_id = ?" (i.text, u.text)
  removed <- changes c
  if removed == 0
    then pure (Left NotFound)
    else do
      execute c "UPDATE assistant_vaults SET revision = revision + 1, updated_at = ? WHERE user_id = ?" (Stamp now, u.text)
      Right <$> passkeysIn c u

--------------------------------------------------------------------------------
-- Ceremonies

-- | 'Purpose': what a challenge was given for.
data Purpose = Registering | Asserting
  deriving stock (Eq, Ord, Show)

-- | 'Ceremonies': the challenges waiting for the browser's answer, by the
-- session (the hash of its secret) and the purpose, each with the user it
-- was given to and when it expires.
newtype Ceremonies = Ceremonies (IORef (Map (Text, Purpose) (UserId, ByteString, UTCTime)))

newCeremonies :: IO Ceremonies
newCeremonies = Ceremonies <$> newIORef mempty

-- | How long a challenge waits for its answer: five minutes, which a
-- person touching a passkey needs much less of.
ceremonyLifetime :: NominalDiffTime
ceremonyLifetime = 5 * 60

-- | The most challenges waiting; beyond it, the oldest are dropped.
maxCeremonies :: Int
maxCeremonies = 10000

-- | A new challenge (32 random bytes) for a session and a user, replacing
-- the session's waiting one for the same purpose.
beginCeremony :: Ceremonies -> UTCTime -> Text -> UserId -> Purpose -> IO ByteString
beginCeremony (Ceremonies ref) now session u purpose = do
  challenge <- getRandomBytes 32
  atomicModifyIORef' ref $ \m ->
    let live = Map.filter (\(_, _, expires) -> expires > now) m
        bounded = if Map.size live >= maxCeremonies then Map.fromList (drop (Map.size live - maxCeremonies + 1) (sortOn (\(_, (_, _, e)) -> e) (Map.toList live))) else live
     in (Map.insert (session, purpose) (u, challenge, addUTCTime ceremonyLifetime now) bounded, ())
  pure challenge

-- | The challenge waiting for a session, a user and a purpose, if it has
-- not expired; it is used up.
takeCeremony :: Ceremonies -> UTCTime -> Text -> UserId -> Purpose -> IO (Maybe ByteString)
takeCeremony (Ceremonies ref) now session u purpose =
  atomicModifyIORef' ref $ \m -> case Map.lookup (session, purpose) m of
    Just (owner, challenge, expires) | owner == u, expires > now -> (Map.delete (session, purpose) m, Just challenge)
    _ -> (Map.delete (session, purpose) m, Nothing)
