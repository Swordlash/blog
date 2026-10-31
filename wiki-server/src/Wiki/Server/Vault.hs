{-# LANGUAGE MultiWayIf #-}

-- | The assistant's vault and the user's passkeys, on the server (WP5.21
-- and WP5.30 of docs/PLAN.md, "Wiki.Api.Vault"): what the routes under
-- @assistant\/@, @account\/passkeys\/@ and @session\/passkey@ store and
-- check. A passkey signs its owner in, and unlocks the vault when the vault
-- has the vault key wrapped for it.
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
  , deleteVault

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

import Crypto.Random (getRandomBytes)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, defaultTimeLocale, formatTime)
import Database.Beam (all_, asc_, current_, delete, filter_, insert, insertValues, isJust_, orderBy_, runDelete, runInsert, runSelectReturningList, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Network.Wai (Request)
import Protolude
import Wiki.Api.ContentPolicy (originOf)
import Wiki.Api.Vault (PasskeyInfo (..), StoredVault (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Assistant.Vault (CredentialId (..), Sealed (..), Vault (..), VaultTag (..), WrappedKey (..), vaultFormat)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))
import Wiki.Server.Address (requestOrigin)
import Wiki.Server.Storage (Storage, reading, writing, writingEither)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (micro)
import Wiki.Server.Storage.Schema (AssistantVaults (..), Passkeys (..), WikiDb (..), wikiDb)
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

vaultIn :: (Backend be) => UserId -> Db be (Maybe StoredVault)
vaultIn u =
  runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text) (all_ wikiDb.assistant_vaults))) >>= \case
    [x] -> do
      wrapped <- runSelectReturningList (select (filter_ (\p -> p.user_id ==. val_ u.text &&. isJust_ p.wrapped_key) (all_ wikiDb.passkeys)))
      pure $
        Just
          StoredVault
            { tag = tagOf x.revision
            , vault =
                Vault
                  { format = fromIntegral x.format
                  , salt = x.salt
                  , sealed = Sealed {nonce = x.nonce, ciphertext = x.ciphertext}
                  , wrapped = Map.fromList [(CredentialId p.credential_id, WrappedKey n k) | p <- wrapped, Just n <- [p.wrapped_nonce], Just k <- [p.wrapped_key]]
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

-- | Store a user's vault, over the version the given tag names, or, with
-- none, only if they have no vault yet; 'Conflict' otherwise. The wrapped
-- keys it carries are stored for the passkeys they name, which must be
-- the user's ('Invalid' otherwise); the wrapped keys of the passkeys it
-- does not name are kept. The result is the vault as stored now.
storeVault :: Storage -> UTCTime -> UserId -> Maybe VaultTag -> Vault -> IO (Either WikiError StoredVault)
storeVault st now u base v
  | v.format /= vaultFormat = pure (Left (Invalid ("A vault of format " <> show v.format <> ": this wiki writes format " <> show vaultFormat <> ".")))
  | any (\t -> T.null t || T.length t > maxVaultText) ([v.salt, v.sealed.nonce, v.sealed.ciphertext] <> concat [[w.nonce, w.key] | w <- Map.elems v.wrapped]) = pure (Left (Invalid "This is not a vault this wiki keeps: a part of it is empty or too long."))
  | otherwise = writingEither st $ do
      mine <- map (\p -> p.credential_id) <$> passkeysWhere u
      revision <- map (\x -> x.revision) <$> runSelectReturningList (select (filter_ (\x -> x.user_id ==. val_ u.text) (all_ wikiDb.assistant_vaults)))
      case (revision, base) of
        _ | any (\i -> i.text `notElem` mine) (Map.keys v.wrapped) -> pure (Left (Invalid "The vault names a passkey that is not one of yours."))
        ([], Nothing) -> do
          runInsert . insert wikiDb.assistant_vaults $
            insertValues [VaultRow {user_id = u.text, format = fromIntegral v.format, salt = v.salt, nonce = v.sealed.nonce, ciphertext = v.sealed.ciphertext, revision = 1, updated_at = micro now}]
          stored
        ([r], Just t)
          | tagOf r == t -> do
              runUpdate $
                update
                  wikiDb.assistant_vaults
                  ( \x ->
                      mconcat
                        [ x.format <-. val_ (fromIntegral v.format)
                        , x.salt <-. val_ v.salt
                        , x.nonce <-. val_ v.sealed.nonce
                        , x.ciphertext <-. val_ v.sealed.ciphertext
                        , x.revision <-. current_ x.revision + 1
                        , x.updated_at <-. val_ (micro now)
                        ]
                  )
                  (\x -> x.user_id ==. val_ u.text)
              stored
        ([], Just _) -> pure (Left (Conflict "There is no vault any more: synchronisation was turned off on another device."))
        ([_], Nothing) -> pure (Left (Conflict "There is a vault already: unlock it with a passkey instead."))
        _ -> pure (Left (Conflict "The vault was changed on another device meanwhile."))
  where
    stored :: (Backend be) => Db be (Either WikiError StoredVault)
    stored = do
      for_ (Map.toList v.wrapped) $ \(i, w) ->
        runUpdate (update wikiDb.passkeys (\p -> (p.wrapped_nonce <-. val_ (Just w.nonce)) <> (p.wrapped_key <-. val_ (Just w.key))) (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text))
      maybe (Left NotFound) Right <$> vaultIn u

-- | Turn synchronisation off for a user: their vault goes, and so do the
-- vault key's wrapped copies. Their passkeys stay, since they also sign
-- the user in. Nothing else is needed: a user who has lost every passkey
-- starts again this way. Nothing to delete is no error.
deleteVault :: Storage -> UserId -> IO ()
deleteVault st u = writing st $ do
  runDelete (delete wikiDb.assistant_vaults (\x -> x.user_id ==. val_ u.text))
  runUpdate (update wikiDb.passkeys (\p -> (p.wrapped_nonce <-. val_ Nothing) <> (p.wrapped_key <-. val_ Nothing)) (\p -> p.user_id ==. val_ u.text))

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
-- left; another user's passkey, or none, is 'NotFound'.
removePasskey :: Storage -> UTCTime -> UserId -> CredentialId -> IO (Either WikiError [PasskeyInfo])
removePasskey st now u i = writingEither st $ do
  there <- runSelectReturningList (select (filter_ (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text) (all_ wikiDb.passkeys)))
  if null there
    then pure (Left NotFound)
    else do
      runDelete (delete wikiDb.passkeys (\p -> p.credential_id ==. val_ i.text &&. p.user_id ==. val_ u.text))
      runUpdate (update wikiDb.assistant_vaults (\x -> (x.revision <-. current_ x.revision + 1) <> (x.updated_at <-. val_ (micro now))) (\x -> x.user_id ==. val_ u.text))
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
