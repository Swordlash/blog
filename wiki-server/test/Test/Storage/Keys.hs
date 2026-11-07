-- | The user's vault and key pair in the storage (WP5.74b1 of
-- docs/PLAN.md, "Wiki.Server.Vault"), on each database: a change of
-- password stores the new record and the vault's new password wrap
-- together, or neither; a reset deletes the password's wrap of a vault a
-- passkey still unlocks, and a vault only the password unlocked, with the
-- user's public key retired as changed by a reset; and a user without a
-- password cannot wrap a vault for one.
module Test.Storage.Keys (spec) where

import Data.Map.Strict qualified as Map
import Data.Time (getCurrentTime)
import Database.Beam (all_, filter_, runSelectReturningList, select, val_, (==.))
import Protolude
import Test.Database (Backing)
import Test.Hspec
import Test.Storage.Fixture (ok, withPlaceIn)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Opaque (PasswordRecord (..), PasswordWrapChange (..))
import Wiki.Api.Opaque qualified as Opaque
import Wiki.Api.Vault (NewPublicKey (..), PasskeyInfo (..), PublicKeyEntry (..), StoredVault (..), VaultChange (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Email (..), Password (..), User (..))
import Wiki.Core.Vault
import Wiki.Server.Accounts (PasswordRefusal (..), changePassword, createAccount)
import Wiki.Server.Opaque (Proof (..), defaultStretch)
import Wiki.Server.Reset (ResetMail (..), requestReset, resetPassword, setEmail, verifyEmail)
import Wiki.Server.Storage (Storage, defaultConfig, reading, recordHere, withStorage)
import Wiki.Server.Storage.Rows (StoredRecord (..), passwordOf)
import Wiki.Server.Storage.Schema (PublicKeys (..), WikiDb (..), wikiDb)
import Wiki.Server.Vault (keyIdOf, publicKeyOf, registerPasskey, storeVault, storedVault)
import Wiki.Server.WebAuthn (NewCredential (..))

spec :: Backing -> Spec
spec backing = describe "the user's keys in the storage" $ do
  it "change the password and the vault's password wrap together, or neither" $ withAda backing $ \st u -> do
    now <- getCurrentTime
    stored <- ok =<< storeVault st now u Nothing (withKeyPair (vaultOf [(ByPassword, wrapA)]))
    was <- reading st (passwordOf u)
    record <- recordAt st u "a new password"
    let change = changePassword st u Nothing (pure (Just ByOpaque)) Nothing record
        unchanged = do
          reading st (passwordOf u) `shouldReturn` was
          storedVault st u `shouldReturn` Just stored
    -- No new wrap for a vault the password unlocks: refused, both stay.
    (change Nothing >>= either (pure . refusal) (const (pure "changed"))) `shouldReturn` "conflict"
    unchanged
    -- A new wrap over another version of the vault: refused, both stay.
    (change (Just PasswordWrapChange {tag = VaultTag "\"99\"", wrapped = wrapB}) >>= either (pure . refusal) (const (pure "changed"))) `shouldReturn` "conflict"
    unchanged
    -- A wrap of the wrong length: refused, both stay.
    (change (Just PasswordWrapChange {tag = stored.tag, wrapped = WrappedKey nonceB "c2hvcnQ"}) >>= either (pure . refusal) (const (pure "changed"))) `shouldReturn` "invalid"
    unchanged
    -- Over the version read: both change.
    void (ok =<< change (Just PasswordWrapChange {tag = stored.tag, wrapped = wrapB}))
    reading st (passwordOf u) >>= (`shouldNotBe` was)
    later <- storedVault st u
    ((\s -> wrapFor ByPassword s.vault) <$> later, (\s -> s.tag /= stored.tag) <$> later) `shouldBe` (Just (Just wrapB), Just True)

  it "a reset deletes the password's wrap of a vault a passkey still unlocks, and keeps the rest" $ withAda backing $ \st u -> do
    now <- getCurrentTime
    passkey <- ok =<< registerPasskey st now u Nothing NewCredential {credentialId = "a passkey", publicKey = "its public key", algorithm = -7, signCount = 0}
    stored <- ok =<< storeVault st now u Nothing (withKeyPair (vaultOf [(ByPassword, wrapA), (ByPasskey passkey.id, wrapB)]))
    reset st u
    later <- storedVault st u
    ((\s -> s.vault.wraps) <$> later) `shouldBe` Just (Map.singleton (ByPasskey passkey.id) wrapB)
    ((\s -> s.vault.items) <$> later) `shouldBe` Just stored.vault.items
    fmap (\k -> k.keyId) <$> publicKeyOf st u `shouldReturn` Just keyId

  it "a reset deletes a vault only the password unlocked, and retires the key pair as changed by a reset" $ withAda backing $ \st u -> do
    now <- getCurrentTime
    void (ok =<< storeVault st now u Nothing (withKeyPair (vaultOf [(ByPassword, wrapA)])))
    reset st u
    storedVault st u `shouldReturn` Nothing
    publicKeyOf st u `shouldReturn` Nothing
    rows <- reading st (runSelectReturningList (select (filter_ (\k -> k.user_id ==. val_ u.text) (all_ wikiDb.public_keys))))
    [(k.key_id, isJust k.retired_at, k.retired_because) | k <- rows] `shouldBe` [(keyId.text, True, Just "reset")]
    -- The next sign-in's new key pair takes its place.
    let fresh = PublicKey "YW5vdGhlciBYMjU1MTkgcHVibGljIGtleSwgMzJiLi4"
        freshId = fromMaybe (KeyId "") (keyIdOf fresh)
        vault = withItem identityItem Item {keyId = Just freshId, sealed = Sealed nonceA keyPair} (vaultOf [(ByPassword, wrapB)])
    void (ok =<< storeVault st now u Nothing VaultChange {vault, publicKey = Just NewPublicKey {keyId = freshId, publicKey = fresh}})
    fmap (\k -> k.keyId) <$> publicKeyOf st u `shouldReturn` Just freshId

  it "refuses a password's wrap to a user who has no password, and a vault of a key pair with no way to unlock it" $ withPlaceIn backing $ \at -> withStorage defaultConfig at $ \st -> do
    pat <- ok =<< createAccount st "pat" "Pat" Nothing
    now <- getCurrentTime
    storeVault st now pat.user.id Nothing (withKeyPair (vaultOf [(ByPassword, wrapA)]))
      `shouldReturn` Left (Invalid "You have no password to unlock a vault with: you sign in with a provider.")
    storeVault st now pat.user.id Nothing (withKeyPair (vaultOf []))
      `shouldReturn` Left (Invalid "A vault that holds your key pair keeps at least one way to unlock it.")
  where
    refusal = \case
      PasswordRefused (Conflict _) -> "conflict" :: Text
      PasswordRefused (Invalid _) -> "invalid"
      _ -> "other"

-- | A storage with Ada, who has a password and a verified address.
withAda :: Backing -> (Storage -> UserId -> IO a) -> IO a
withAda backing action = withPlaceIn backing $ \at -> withStorage defaultConfig at $ \st -> do
  ada <- ok =<< createAccount st "ada" "Ada" (Just (Password "correct horse"))
  now <- getCurrentTime
  Right (Just (_, token)) <- setEmail st now ada.user.id "ada@example.org"
  verifyEmail st now token `shouldReturn` Right ()
  action st ada.user.id

-- | Reset Ada's password with a link mailed to her.
reset :: Storage -> UserId -> IO ()
reset st u = do
  now <- getCurrentTime
  mails <- requestReset st now "ada"
  mail <- maybe (panic "no reset was mailed") pure (head mails)
  (\m -> m.email) mail `shouldBe` Email "ada@example.org"
  record <- recordAt st u "a password set again"
  resetPassword st now mail.token record `shouldReturn` Right ()

-- | A record of a password for a user, as the browser would make it.
recordAt :: Storage -> UserId -> Text -> IO PasswordRecord
recordAt st u password =
  recordHere st u (Password password) >>= \case
    Left why -> panic why
    Right stored -> pure PasswordRecord {credential = u.text, record = Opaque.Message stored.record, stretch = defaultStretch}

-- | A vault of made-up bytes of the right lengths, with these wraps.
vaultOf :: [(Unlock, WrappedKey)] -> Vault
vaultOf wraps = Vault {format = vaultFormat, salt = "c2FsdC1vZi10aGlydHktdHdvLWJ5dGVzLWZvci1wcmY", items = mempty, wraps = Map.fromList wraps}

-- | A vault with the key pair 'publicKey' names, and the change that
-- stores it with its public key.
withKeyPair :: Vault -> VaultChange
withKeyPair v = VaultChange {vault = withItem identityItem Item {keyId = Just keyId, sealed = Sealed nonceA keyPair} v, publicKey = Just NewPublicKey {keyId, publicKey}}

publicKey :: PublicKey
publicKey = PublicKey "YW4gWDI1NTE5IHB1YmxpYyBrZXksIDMyIGJ5dGVzISE"

keyId :: KeyId
keyId = fromMaybe (KeyId "") (keyIdOf publicKey)

keyPair :: Ciphertext
keyPair = "YSBrZXkgcGFpciBzZWFsZWQ6IGl0cyBwa2NzOCBhbmQgaXRzIHRhZywgc2l4dHktZm91ciBieXRlcyBvZiBpdA"

nonceA, nonceB :: Nonce
nonceA = "bm9uY2UtMTJieXRl"
nonceB = "b3RoZXItbm9uY2Uh"

wrapA, wrapB :: WrappedKey
wrapA = WrappedKey nonceA "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n"
wrapB = WrappedKey nonceB "YW5vdGhlciB2YXVsdCBrZXksIHdyYXBwZWQgd2l0aCBhbm90aGVyIHBhc3NrZXku"
