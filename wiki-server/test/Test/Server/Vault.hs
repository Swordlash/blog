-- | The assistant's vault and the account's passkeys over HTTP
-- ("Wiki.Api.Vault", "Wiki.Server.Vault"), with an authenticator the tests
-- play ("Test.Server.WebAuthn"): a passkey made and used for the signed-in
-- user, refused for another origin or challenge, a counter that does not
-- go up reported, another user's passkey and vault out of reach, and the
-- vault stored over the version it was read at, fetched by its tag,
-- losing a removed passkey's wrapped key, and deleted. Then signing in
-- with a passkey (WP5.30): alone, with the cookie set and no second
-- factor, refused for a wrong origin, a stale or used challenge, an
-- unknown passkey, another user's handle, no user verification, a counter
-- that went back and a disabled user, limited per address; and as the
-- second step of a password's sign-in.
module Test.Server.Vault (spec) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.HTTP.Types (Header, methodDelete, methodGet, methodPost, methodPut)
import Network.Wai (Request (..), defaultRequest)
import Protolude
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture
import Test.Server.WebAuthn (Authenticator (..), assertion, assertionFlagged, authenticator, registration)
import Wiki.Api (AccountApi (..), AdminApi (..), AssistantApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), AccountDisabled (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Security (CurrentPassword (..), OneTimeCode (..), RecoveryCodes (..), TotpEnrolment (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Vault
import Wiki.Core.Assistant.Vault
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Login (..), Password (..), Standing (..), User (..))
import Wiki.Server.Totp (codeAt, secretFromText)
import Wiki.Server.Vault (Site (..), keyIdOf, siteFor)
import Wiki.Server.WebAuthn (fromBase64Url, toBase64Url)

spec :: Backing -> Spec
spec backing = do
  vaultAndPasskeys backing
  signing backing

vaultAndPasskeys :: Backing -> Spec
vaultAndPasskeys backing = describe "the assistant's vault and passkeys, over HTTP" $ do
  it "makes a passkey only with the user's current password, since it signs them in" $ withSignedIn backing $ \r editor _ -> do
    (call r editor methodPost links.account.beginRegistration (Just CurrentPassword {password = Just (Password "not the password")}) >>= jsonAs 401) `shouldReturn` Unauthenticated
    (call r editor methodPost links.account.beginRegistration (Just CurrentPassword {password = Nothing}) >>= jsonAs 401) `shouldReturn` Unauthenticated
    (\x -> x.status) <$> send r methodPost (r.public <> "/" <> links.account.beginRegistration) jsonHeader (encode CurrentPassword {password = Just (Password "editor's password")}) `shouldReturn` 401

  it "makes a passkey for the signed-in user, and checks its use" $ withSignedIn backing $ \r editor _ -> do
    options :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    (options.rpId, options.userName, options.rpName) `shouldBe` ("127.0.0.1", "editor", "Wiki")
    info :: PasskeyInfo <- register r editor options passkey r.public >>= jsonAs 200
    (info.id, info.unlocks) `shouldBe` (CredentialId (toBase64Url passkey.credentialId), False)
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` [info]
    used :: PasskeyInfo <- use r editor passkey 1 r.public >>= jsonAs 200
    used.lastUsedAt `shouldSatisfy` isJust
    -- The same passkey again is no new one.
    again :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    again.exclude `shouldBe` [info.id]
    (register r editor again passkey r.public >>= jsonAs 409) `shouldReturn` Conflict "This passkey is registered already."

  it "refuses a passkey made on another site, or for another challenge, and a challenge used twice" $ withSignedIn backing $ \r editor _ -> do
    options :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    refused :: ApiError <- register r editor options passkey "https://evil.example" >>= jsonAs 400
    refused `shouldSatisfy` says "made on another site"
    -- Its challenge was used up by that answer.
    stale :: ApiError <- register r editor options passkey r.public >>= jsonAs 400
    stale `shouldSatisfy` says "No passkey is being made"
    fresh :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    other :: ApiError <- register r editor (withChallenge (toBase64Url "not the challenge the server gave") fresh) passkey r.public >>= jsonAs 400
    other `shouldSatisfy` says "another challenge"
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])

  -- One ceremony waits for a session and a purpose, and a new one replaces
  -- it. A late answer to the one replaced (a registration sent again after
  -- its panel closed, another tab of the session) is refused and leaves the
  -- new one for its own answer: taken before it was checked, it used up the
  -- new one, whose answer was then refused too.
  it "leaves a registration's challenge for its own answer when an answer to the one it replaced comes" $ withSignedIn backing $ \r editor _ -> do
    earlier :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    later :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    late :: ApiError <- register r editor earlier (authenticator "the earlier passkey") r.public >>= jsonAs 400
    late `shouldSatisfy` says "another challenge"
    info :: PasskeyInfo <- register r editor later passkey r.public >>= jsonAs 200
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` [info]

  it "leaves a passkey's use's challenge for its own answer when an answer to the one it replaced comes" $ withSignedIn backing $ \r editor _ -> do
    _ :: PasskeyInfo <- registerNew r editor passkey
    earlier :: AssertionOptions <- call r editor methodPost links.assistant.beginAssertion none >>= jsonAs 200
    later :: AssertionOptions <- call r editor methodPost links.assistant.beginAssertion none >>= jsonAs 200
    let answer options counter = do
          challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
          signed <- assertion passkey counter options.rpId r.public challenge
          call r editor methodPut links.assistant.finishAssertion (Just (answered passkey signed Nothing))
    late :: ApiError <- answer earlier 1 >>= jsonAs 400
    late `shouldSatisfy` says "another challenge"
    used :: PasskeyInfo <- answer later 2 >>= jsonAs 200
    used.lastUsedAt `shouldSatisfy` isJust

  it "reports a passkey whose counter does not go up, and keeps its counter" $ withSignedIn backing $ \r editor _ -> do
    _ :: PasskeyInfo <- registerNew r editor passkey
    _ :: PasskeyInfo <- use r editor passkey 5 r.public >>= jsonAs 200
    replayed :: ApiError <- use r editor passkey 5 r.public >>= jsonAs 409
    replayed `shouldSatisfy` says "counter went back, from 5 to 5"
    _ :: PasskeyInfo <- use r editor passkey 6 r.public >>= jsonAs 200
    pass

  it "keeps another user's passkey and vault out of reach" $ withSignedIn backing $ \r editor theReader -> do
    info <- registerNew r editor passkey
    _ <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [])) >>= jsonAs @StoredVault 200
    -- The reader's own assertion, answered with the editor's passkey.
    (use r theReader passkey 1 r.public >>= jsonAs 404) `shouldReturn` NotFound
    (call r theReader methodDelete (links.account.removePasskey info.id) none >>= jsonAs 404) `shouldReturn` NotFound
    (call r theReader methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    refused :: ApiError <- call r theReader methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")])) >>= jsonAs 400
    refused `shouldSatisfy` says "not one of yours"
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` [info]

  it "is refused to someone not signed in" $ withSignedIn backing $ \r _ _ ->
    for_ [(methodGet, links.assistant.vault), (methodGet, links.account.passkeys)] $ \(m, address) ->
      (\x -> x.status) <$> send r m (r.public <> "/" <> address) [] "" `shouldReturn` 401

  it "stores the vault over the version read, fetches it by its tag, and deletes it" $ withSignedIn backing $ \r editor _ -> do
    info <- registerNew r editor passkey
    first' :: StoredVault <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [])) >>= jsonAs 200
    -- A first vault where there is one already is a conflict.
    (call r editor methodPut links.assistant.storeVault (Just (vaultWith [])) >>= jsonAs 409) `shouldReturn` Conflict "There is a vault already: unlock it with a passkey instead."
    fetched <- call r editor methodGet links.assistant.vault none
    (fetched.status, header "ETag" fetched) `shouldBe` (200, Just (encodeUtf8 first'.tag.text))
    json fetched `shouldReturn` first'
    unchanged <- send r methodGet (r.public <> "/" <> links.assistant.vault) (editor <> [("If-None-Match", encodeUtf8 first'.tag.text)]) ""
    (unchanged.status, unchanged.body) `shouldBe` (304, "")
    -- A new version, with the key wrapped for the passkey.
    let wrapped = vaultWith [(info.id, WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")]
    secondVersion :: StoredVault <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) (encodeBody wrapped) >>= jsonAs 200
    secondVersion.tag `shouldNotBe` first'.tag
    wrappedFor info.id secondVersion.vault `shouldBe` Just (WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")
    map (\p -> p.unlocks) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [True]
    -- Over the first version again: changed meanwhile.
    stale :: ApiError <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) (encodeBody wrapped) >>= jsonAs 409
    stale `shouldBe` Conflict "The vault was changed on another device meanwhile."
    -- The passkey removed takes its wrapped key with it.
    (call r editor methodDelete (links.account.removePasskey info.id) none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])
    third :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    (third.vault.wraps, third.tag /= secondVersion.tag) `shouldBe` (mempty, True)
    -- Turned off: the vault and its wrapped keys go, with no passkey asked
    -- for; the passkeys stay, since they sign the user in.
    another <- registerNew r editor (authenticator "another passkey")
    stored :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    _ :: StoredVault <-
      send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 stored.tag.text)]) (encodeBody (vaultWith [(another.id, WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")])) >>= jsonAs 200
    (\x -> x.status) <$> call r editor methodDelete links.assistant.deleteVault none `shouldReturn` 204
    (call r editor methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    map (\p -> (p.id, p.unlocks)) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [(another.id, False)]

  it "takes a vault of WP5.21's format from an older tab as its settings alone, and keeps the rest" $ withSignedIn backing $ \r editor _ -> do
    info <- registerNew r editor passkey
    -- A vault of the current format, with an item the assistant does not
    -- know besides its settings.
    let notes = Item {keyId = Nothing, sealed = Sealed "b3RoZXItbm9uY2Uh" "bm90ZXM"}
    first' :: StoredVault <- call r editor methodPut links.assistant.storeVault (Just (withItem (ItemName "notes") notes (vaultWith [(info.id, WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")]))) >>= jsonAs 200
    -- A tab of the wiki before WP5.74 stores its settings in its format,
    -- over the version it read: only the settings change.
    let old = "{\"format\":1,\"salt\":\"c2FsdC1vZi10aGlydHktdHdvLWJ5dGVzLWZvci1wcmY\",\"nonce\":\"b3RoZXItbm9uY2Uh\",\"ciphertext\":\"bmV3\",\"wrapped\":{}}"
    stored2 :: StoredVault <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) old >>= jsonAs 200
    (sealedOf stored2.vault, itemOf (ItemName "notes") stored2.vault, wrappedFor info.id stored2.vault)
      `shouldBe` (Just (Sealed "b3RoZXItbm9uY2Uh" "bmV3"), Just notes, Just (WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n"))
    stored2.vault.format `shouldBe` vaultFormat
    -- Over a version it did not read, it is refused, as before.
    (send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) old >>= jsonAs 409)
      `shouldReturn` Conflict "The vault was changed on another device meanwhile."
    -- Turning syncing off, as such a tab does, deletes the settings alone:
    -- the vault, its other item and its wraps stay, at a new version.
    (\x -> x.status) <$> call r editor methodDelete links.assistant.deleteVault none `shouldReturn` 204
    third :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    (sealedOf third.vault, itemOf (ItemName "notes") third.vault, wrappedFor info.id third.vault, third.tag /= stored2.tag)
      `shouldBe` (Nothing, Just notes, Just (WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n"), True)
    -- A vault of a later format than this wiki's, or one with no item, is
    -- refused, and the stored one stays.
    let newer = "{\"format\":3,\"salt\":\"c2FsdC1vZi10aGlydHktdHdvLWJ5dGVzLWZvci1wcmY\",\"items\":{}}"
    (\x -> x.status) <$> send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 third.tag.text)]) newer `shouldReturn` 400
    (call r editor methodPut links.assistant.storeVault (Just (withoutItem assistantItem (withoutItem (ItemName "notes") (vaultWith [])))) >>= jsonAs 400)
      `shouldReturn` Invalid "A vault holds at least one item."
    (call r editor methodGet links.assistant.vault none >>= jsonAs 200) `shouldReturn` third

  it "stores the user's key pair with its public key in one request, and gives the public key to anyone signed in" $ withSignedIn backing $ \r editor theReader -> do
    info <- registerNew r editor passkey
    let key = PublicKey "YW4gWDI1NTE5IHB1YmxpYyBrZXksIDMyIGJ5dGVzISE"
        keyId = fromMaybe (KeyId "") (keyIdOf key)
        pair = Item {keyId = Just keyId, sealed = Sealed "b3RoZXItbm9uY2Uh" "YSBrZXkgcGFpciBzZWFsZWQ6IGl0cyBwa2NzOCBhbmQgaXRzIHRhZywgc2l4dHktZm91ciBieXRlcyBvZiBpdA"}
        withIdentity = withItem identityItem pair (vaultWith [(info.id, wrap)])
        change v k = VaultChange {vault = v, publicKey = k}
    -- The key pair alone, with no public key for the directory, or with
    -- one that is not the key pair's, is refused.
    (call r editor methodPut links.assistant.storeVault (Just (change withIdentity Nothing)) >>= jsonAs 400)
      `shouldReturn` Invalid "The vault holds a key pair the directory does not have: send its public key with it."
    (call r editor methodPut links.assistant.storeVault (Just (change withIdentity (Just NewPublicKey {keyId, publicKey = PublicKey "YW5vdGhlciBYMjU1MTkgcHVibGljIGtleSwgMzJiLi4"}))) >>= jsonAs 400)
      `shouldReturn` Invalid "A public key is X25519's 32 bytes, and its id the first 16 bytes of its SHA-256."
    (call r editor methodPut links.assistant.storeVault (Just (change (vaultWith []) (Just NewPublicKey {keyId, publicKey = key}))) >>= jsonAs 400)
      `shouldReturn` Invalid "The public key sent is not the key pair the vault holds."
    -- Nobody has a key yet.
    (call r theReader methodGet (links.account.publicKey (UserId "user-editor")) none >>= jsonAs 404) `shouldReturn` NotFound
    stored :: StoredVault <- call r editor methodPut links.assistant.storeVault (Just (change withIdentity (Just NewPublicKey {keyId, publicKey = key}))) >>= jsonAs 200
    itemOf identityItem stored.vault `shouldBe` Just pair
    -- Anyone signed in reads the public key; nobody else reads the vault.
    entry :: PublicKeyEntry <- call r theReader methodGet (links.account.publicKey (UserId "user-editor")) none >>= jsonAs 200
    (entry.user, entry.keyId, entry.publicKey) `shouldBe` (UserId "user-editor", keyId, key)
    (call r editor methodGet (links.account.publicKey (UserId "user-reader")) none >>= jsonAs 404) `shouldReturn` NotFound
    (\x -> x.status) <$> send r methodGet (r.public <> "/" <> links.account.publicKey (UserId "user-editor")) [] "" `shouldReturn` 401
    (call r theReader methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    -- The vault changes on with its key pair, which needs no public key
    -- again; another key pair does not replace it, and the item cannot be
    -- dropped.
    let at t = jsonHeader <> editor <> [("If-Match", encodeUtf8 t.text)]
    again :: StoredVault <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (at stored.tag) (encode (change (withSealed (Sealed "b3RoZXItbm9uY2Uh" "c2VhbGVkIGFnYWlu") stored.vault) Nothing)) >>= jsonAs 200
    itemOf identityItem again.vault `shouldBe` Just pair
    let otherKey = PublicKey "YW5vdGhlciBYMjU1MTkgcHVibGljIGtleSwgMzJiLi4"
        otherId = fromMaybe (KeyId "") (keyIdOf otherKey)
        other = withItem identityItem Item {keyId = Just otherId, sealed = pair.sealed} again.vault
    (send r methodPut (r.public <> "/" <> links.assistant.storeVault) (at again.tag) (encode (change other (Just NewPublicKey {keyId = otherId, publicKey = otherKey}))) >>= jsonAs 409)
      `shouldReturn` Conflict "You have a key pair already: it is replaced only after a password reset."
    (send r methodPut (r.public <> "/" <> links.assistant.storeVault) (at again.tag) (encode (change (withoutItem identityItem again.vault) Nothing)) >>= jsonAs 400)
      `shouldReturn` Invalid "The vault's key pair cannot be removed."
    -- Turning the assistant's syncing off leaves the key pair and its key.
    (\x -> x.status) <$> call r editor methodDelete links.assistant.deleteVault none `shouldReturn` 204
    rest :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    (sealedOf rest.vault, itemOf identityItem rest.vault) `shouldBe` (Nothing, Just pair)
    (call r theReader methodGet (links.account.publicKey (UserId "user-editor")) none >>= jsonAs 200) `shouldReturn` entry
    -- The passkey that alone unlocks the vault holding the key pair is
    -- not removed, whatever the panel showed: the vault would be lost.
    (call r editor methodDelete (links.account.removePasskey info.id) none >>= jsonAs 409)
      `shouldReturn` Conflict "This passkey is the last way to unlock your vault, which holds your keys: add your password or another passkey as a way to unlock it first."
    map (\p -> (p.id, p.unlocks)) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [(info.id, True)]

  it "refuses parts of a vault that are not of their lengths" $ withSignedIn backing $ \r editor _ -> do
    info <- registerNew r editor passkey
    let base = vaultWith [(info.id, wrap)]
        refused v = call r editor methodPut links.assistant.storeVault (Just v) >>= jsonAs @ApiError 400
    refused Vault {format = base.format, salt = "c2FsdA", items = base.items, wraps = base.wraps} >>= (`shouldSatisfy` says "salt is not of its length")
    refused (withSealed (Sealed "bm9uY2U" "c2VhbGVk") base) >>= (`shouldSatisfy` says "nonce is not of its length")
    refused (vaultWith [(info.id, WrappedKey "bm9uY2UtMTJieXRl" "a2V5")]) >>= (`shouldSatisfy` says "wrapped key is not of its length")
    refused (withItem identityItem Item {keyId = Just (KeyId "a2V5"), sealed = Sealed "b3RoZXItbm9uY2Uh" "YSBrZXkgcGFpciBzZWFsZWQ6IGl0cyBwa2NzOCBhbmQgaXRzIHRhZywgc2l4dHktZm91ciBieXRlcyBvZiBpdA"} base) >>= (`shouldSatisfy` says "key id is not of its length")
    refused (withItem identityItem Item {keyId = keyIdOf (PublicKey "YW4gWDI1NTE5IHB1YmxpYyBrZXksIDMyIGJ5dGVzISE"), sealed = Sealed "b3RoZXItbm9uY2Uh" "c2hvcnQ"} base) >>= (`shouldSatisfy` says "key pair is not of its length")

  it "refuses a wrapped key, a passkey's answer or a passkey longer than any is" $ withSignedIn backing $ \r editor _ -> do
    info <- registerNew r editor passkey
    let tooLong = T.replicate (256 * 1024 + 1) "a"
    wrapped :: ApiError <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bm9uY2UtMTJieXRl" (Ciphertext tooLong))])) >>= jsonAs 400
    wrapped `shouldSatisfy` says "too long"
    _ :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    let other = authenticator "another passkey"
        answer = RegistrationResponse {id = CredentialId (toBase64Url other.credentialId), clientDataJSON = "e30", attestationObject = T.replicate (64 * 1024 + 1) "a", name = Nothing}
    long :: ApiError <- call r editor methodPut links.account.finishRegistration (Just answer) >>= jsonAs 400
    long `shouldSatisfy` says "longer than a passkey's answer"
    -- A credential id longer than WebAuthn allows, which the server would
    -- otherwise store.
    fresh :: RegistrationOptions <- (proved r editor >> call r editor methodPost links.account.beginRegistration (Just editorsPassword)) >>= jsonAs 200
    longId :: ApiError <- register r editor fresh (authenticator (BS.replicate 1024 7)) r.public >>= jsonAs 400
    longId `shouldSatisfy` says "longer than a passkey's"
    map (\p -> p.id) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [info.id]

  describe "the site a passkey is made for" $ do
    let request headers = defaultRequest {requestHeaders = headers, requestHeaderHost = Just "wiki.example.org:8080"}
    it "is the public address, when one is set" $
      siteFor (Just (Url "https://Wiki.Example.ORG/base/")) (request []) `shouldBe` Site {rpId = "wiki.example.org", origins = ["https://wiki.example.org"]}
    it "is the request's host otherwise, over the scheme a proxy reports, else plain HTTP" $ do
      siteFor Nothing (request []) `shouldBe` Site {rpId = "wiki.example.org", origins = ["http://wiki.example.org:8080"]}
      siteFor Nothing (request [("X-Forwarded-Host", "Docs.Example.net, inner"), ("X-Forwarded-Proto", "https")])
        `shouldBe` Site {rpId = "docs.example.net", origins = ["https://docs.example.net"]}
  where
    passkey = authenticator "the editor's passkey"
    wrap = WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n"
    vaultWith wrapped = withSealed Sealed {nonce = "bm9uY2UtMTJieXRl", ciphertext = "c2VhbGVk"} Vault {format = vaultFormat, salt = "c2FsdC1vZi10aGlydHktdHdvLWJ5dGVzLWZvci1wcmY", items = mempty, wraps = Map.fromList [(ByPasskey c, w) | (c, w) <- wrapped]}
    says part = \case
      Invalid t -> part `T.isInfixOf` t
      Conflict t -> part `T.isInfixOf` t
      _ -> False

-- | A server over the demo's wiki with the editor and the reader signed
-- in on the public listener: each one's cookie.
withSignedIn :: Backing -> (Running -> [Header] -> [Header] -> IO a) -> IO a
withSignedIn backing test = withDemoRunning backing identity $ \r -> do
  givePassword r "user-editor" "editor's password"
  givePassword r "user-reader" "reader's password"
  editor <- signInAs r "editor" "editor's password"
  readerToken <- signInAs r "reader" "reader's password"
  test r [cookie editor] [cookie readerToken]

-- | Registration options with another challenge.
withChallenge :: Text -> RegistrationOptions -> RegistrationOptions
withChallenge challenge o = RegistrationOptions {challenge, rpId = o.rpId, rpName = o.rpName, userId = o.userId, userName = o.userName, displayName = o.displayName, exclude = o.exclude}

-- | The editor's password, which making a passkey asks for.
editorsPassword :: CurrentPassword
editorsPassword = CurrentPassword {password = Just (Password "editor's password")}

-- | Prove the session's password (the editor's) again, as the
-- application does before a change that needs it (Wiki.Api.Opaque).
proved :: (HasCallStack) => Running -> [Header] -> IO ()
proved r session = do
  reply <- provePassword r (\l -> r.public <> "/" <> l) session "editor's password"
  reply.status `shouldBe` 204

-- | No body.
none :: Maybe ()
none = Nothing

jsonHeader :: [Header]
jsonHeader = [("Content-Type", "application/json")]

encodeBody :: Vault -> LByteString
encodeBody = encode

-- | A request of the signed-in user to the API, with a JSON body if one is
-- given.
call :: (ToJSON a) => Running -> [Header] -> ByteString -> Text -> Maybe a -> IO Reply
call r session m address body = send r m (r.public <> "/" <> address) (session <> maybe [] (const jsonHeader) body) (maybe "" encode body)

-- | Make a passkey with the given options: the browser's answer, sent.
register :: Running -> [Header] -> RegistrationOptions -> Authenticator -> Text -> IO Reply
register r session options a origin = do
  challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
  let (client, attestation) = registration a 0x45 options.rpId origin challenge
  call r session methodPut links.account.finishRegistration (Just RegistrationResponse {id = CredentialId (toBase64Url a.credentialId), clientDataJSON = toBase64Url client, attestationObject = toBase64Url attestation, name = Nothing})

-- | Make a passkey, which the server takes.
registerNew :: (HasCallStack) => Running -> [Header] -> Authenticator -> IO PasskeyInfo
registerNew r session a = do
  proved r session
  options <- call r session methodPost links.account.beginRegistration (Just editorsPassword) >>= jsonAs 200
  register r session options a r.public >>= jsonAs 200

-- | Use a passkey, with this counter, on this origin: the browser's
-- answer to a fresh challenge, sent.
use :: Running -> [Header] -> Authenticator -> Word32 -> Text -> IO Reply
use r session a counter origin = do
  options :: AssertionOptions <- call r session methodPost links.assistant.beginAssertion none >>= jsonAs 200
  challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
  (client, authData, signature) <- assertion a counter options.rpId origin challenge
  call r session methodPut links.assistant.finishAssertion (Just AssertionResponse {id = CredentialId (toBase64Url a.credentialId), clientDataJSON = toBase64Url client, authenticatorData = toBase64Url authData, signature = toBase64Url signature, userHandle = Nothing})

-- | 'AssertionResponse' for a passkey's answer, with the user handle given.
answered :: Authenticator -> (ByteString, ByteString, ByteString) -> Maybe Text -> AssertionResponse
answered a (client, authData, signature) userHandle =
  AssertionResponse {id = CredentialId (toBase64Url a.credentialId), clientDataJSON = toBase64Url client, authenticatorData = toBase64Url authData, signature = toBase64Url signature, userHandle = toBase64Url . encodeUtf8 <$> userHandle}

-- | A fresh challenge for a sign-in with a passkey, from no session.
signInOptions :: (HasCallStack) => Running -> IO AssertionOptions
signInOptions r = send r methodPost (r.public <> "/" <> links.beginPasskeySignIn) [] "" >>= jsonAs 200

-- | Sign in with a passkey alone, its counter, origin and user handle as
-- given, and the flags of its authenticator data: the answer, sent.
signInWith :: Running -> Authenticator -> Word8 -> Word32 -> Text -> Maybe Text -> IO Reply
signInWith r a flags counter origin userHandle = do
  options <- signInOptions r
  options.allow `shouldBe` []
  challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
  signed <- assertionFlagged flags a counter options.rpId origin challenge
  send r methodPut (r.public <> "/" <> links.finishPasskeySignIn) jsonHeader (encode (answered a signed userHandle))

signing :: Backing -> Spec
signing backing = describe "signing in with a passkey" $ do
  it "signs its owner in alone, with a session cookie, and keeps its counter" $ withSignedIn backing $ \r editor _ -> do
    _ <- registerNew r editor passkey
    reply <- signInWith r passkey 0x05 3 r.public (Just "user-editor")
    info :: SessionInfo <- jsonAs 200 reply
    ((\u -> u.login.text) <$> info.user, info.standing) `shouldBe` (Just "editor", SignedIn)
    token <- maybe (panic ("no session cookie: " <> show reply)) (pure . fst) (setCookie reply)
    me :: SessionInfo <- send r methodGet (r.public <> "/" <> links.session) [cookie token] "" >>= jsonAs 200
    (\u -> u.login.text) <$> me.user `shouldBe` Just "editor"
    [k] <- call r [cookie token] methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200
    k.lastUsedAt `shouldSatisfy` isJust
    -- The same counter again: the passkey may have been copied.
    (signInWith r passkey 0x05 3 r.public (Just "user-editor") >>= jsonAs 409) >>= (`shouldSatisfy` says "counter went back")

  it "is refused on another site, without a verified user, for another user, or for an unknown passkey" $ withSignedIn backing $ \r editor _ -> do
    _ <- registerNew r editor passkey
    (signInWith r passkey 0x05 1 "https://evil.example" (Just "user-editor") >>= jsonAs 400) >>= (`shouldSatisfy` says "made on another site")
    (signInWith r passkey 0x01 1 r.public (Just "user-editor") >>= jsonAs 400) >>= (`shouldSatisfy` says "verified the user")
    (signInWith r passkey 0x05 1 r.public (Just "user-reader") >>= jsonAs 400) >>= (`shouldSatisfy` says "another user's passkey")
    (signInWith r passkey 0x05 1 r.public Nothing >>= jsonAs 400) >>= (`shouldSatisfy` says "whose passkey")
    (signInWith r (authenticator "nobody's") 0x05 1 r.public (Just "user-editor") >>= jsonAs 400) >>= (`shouldSatisfy` says "not one of this wiki's")

  it "refuses a challenge the server did not give, or used twice" $ withSignedIn backing $ \r editor _ -> do
    _ <- registerNew r editor passkey
    options <- signInOptions r
    let send' signed = send r methodPut (r.public <> "/" <> links.finishPasskeySignIn) jsonHeader (encode (answered passkey signed (Just "user-editor")))
    made <- assertion passkey 0 options.rpId r.public "a challenge the server never gave"
    (send' made >>= jsonAs 400) >>= (`shouldSatisfy` says "start again")
    challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
    signed <- assertion passkey 0 options.rpId r.public challenge
    (\x -> x.status) <$> send' signed `shouldReturn` 200
    (send' signed >>= jsonAs 400) >>= (`shouldSatisfy` says "start again")

  it "refuses a disabled user" $ withSignedIn backing $ \r editor _ -> do
    _ <- registerNew r editor passkey
    _ :: Account <- sendJson r methodPut (r.admin <> "/admin/" <> links.admin.setDisabled (UserId "user-editor")) AccountDisabled {disabled = True} >>= jsonAs 200
    (signInWith r passkey 0x05 1 r.public (Just "user-editor") >>= jsonAs 401) `shouldReturn` Unauthenticated

  it "counts failures against the address, and refuses beyond the limit" $ withSignedIn backing $ \r _ _ -> do
    for_ [1 .. 30 :: Int] $ \_ ->
      (\x -> x.status) <$> signInWith r (authenticator "nobody's") 0x05 1 r.public Nothing `shouldReturn` 400
    (\x -> x.status) <$> signInWith r (authenticator "nobody's") 0x05 1 r.public Nothing `shouldReturn` 429

  it "completes a password's sign-in in place of the second factor's code" $ withSignedIn backing $ \r editor _ -> do
    _ <- registerNew r editor passkey
    proved r editor
    enrolment :: TotpEnrolment <- call r editor methodPost links.account.enrolTotp (Just CurrentPassword {password = Just (Password "editor's password")}) >>= jsonAs 200
    secret <- maybe (panic "not base32") pure (secretFromText enrolment.secret)
    now <- getCurrentTime
    _ :: RecoveryCodes <- call r editor methodPut links.account.confirmTotp (Just OneTimeCode {code = codeAt secret now}) >>= jsonAs 200
    -- A passkey alone needs no code.
    (\x -> x.status) <$> signInWith r passkey 0x05 1 r.public (Just "user-editor") `shouldReturn` 200
    -- The password wants the code, or a passkey.
    half <- passwordSignIn r (\l -> r.public <> "/" <> l) [] "editor" "editor's password"
    jsonAs 401 half `shouldReturn` SecondFactorRequired
    held <- maybe (panic "no pending cookie") pure (pendingOf half)
    let halfway = [("Cookie", "wiki_pending=" <> encodeUtf8 held)]
    -- A challenge begun again: an answer to the one it replaced is refused,
    -- and leaves the new one for its own answer.
    replaced :: AssertionOptions <- send r methodPost (r.public <> "/" <> links.beginSecondFactorPasskey) halfway "" >>= jsonAs 200
    options :: AssertionOptions <- send r methodPost (r.public <> "/" <> links.beginSecondFactorPasskey) halfway "" >>= jsonAs 200
    replacedChallenge <- maybe (panic "no challenge") pure (fromBase64Url replaced.challenge)
    late <- assertion passkey 2 replaced.rpId r.public replacedChallenge
    lateRefused :: ApiError <- send r methodPut (r.public <> "/" <> links.finishSecondFactorPasskey) (jsonHeader <> halfway) (encode (answered passkey late Nothing)) >>= jsonAs 400
    lateRefused `shouldSatisfy` says "another challenge"
    options.allow `shouldBe` [CredentialId (toBase64Url passkey.credentialId)]
    challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
    wrong <- assertion (authenticator "nobody's") 2 options.rpId r.public challenge
    (send r methodPut (r.public <> "/" <> links.finishSecondFactorPasskey) (jsonHeader <> halfway) (encode (answered (authenticator "nobody's") wrong Nothing)) >>= jsonAs 401) `shouldReturn` Unauthenticated
    options' :: AssertionOptions <- send r methodPost (r.public <> "/" <> links.beginSecondFactorPasskey) halfway "" >>= jsonAs 200
    challenge' <- maybe (panic "no challenge") pure (fromBase64Url options'.challenge)
    signed <- assertion passkey 2 options'.rpId r.public challenge'
    reply <- send r methodPut (r.public <> "/" <> links.finishSecondFactorPasskey) (jsonHeader <> halfway) (encode (answered passkey signed Nothing))
    info :: SessionInfo <- jsonAs 200 reply
    (\u -> u.login.text) <$> info.user `shouldBe` Just "editor"
    setCookie reply `shouldSatisfy` isJust
    -- The sign-in is used up.
    (\x -> x.status) <$> send r methodPost (r.public <> "/" <> links.beginSecondFactorPasskey) halfway "" `shouldReturn` 400
  where
    passkey = authenticator "the editor's passkey"
    says part = \case
      Invalid t -> part `T.isInfixOf` t
      Conflict t -> part `T.isInfixOf` t
      _ -> False

-- | The cookie of a sign-in waiting for its second factor, from the
-- response that began it.
pendingOf :: Reply -> Maybe Text
pendingOf reply =
  head
    [ T.takeWhile (/= ';') v
    | (name, raw) <- reply.headers
    , name == "Set-Cookie"
    , Just v <- [T.stripPrefix "wiki_pending=" (decodeUtf8 raw)]
    , not (T.null (T.takeWhile (/= ';') v))
    ]
