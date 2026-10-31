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
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..))
import Wiki.Api.Security (CurrentPassword (..), OneTimeCode (..), RecoveryCodes (..), TotpEnrolment (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), Password (..), Standing (..), User (..))
import Wiki.Server.Totp (codeAt, secretFromText)
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Vault
import Wiki.Core.Assistant.Vault
import Wiki.Core.Url (Url (..))
import Wiki.Server.Vault (Site (..), siteFor)
import Wiki.Server.WebAuthn (fromBase64Url, toBase64Url)

spec :: Backing -> Spec
spec backing = do
  vaultAndPasskeys backing
  signing backing

vaultAndPasskeys :: Backing -> Spec
vaultAndPasskeys backing = describe "the assistant's vault and passkeys, over HTTP" $ do
  it "makes a passkey for the signed-in user, and checks its use" $ withSignedIn backing $ \r editor _ -> do
    options :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
    (options.rpId, options.userName, options.rpName) `shouldBe` ("127.0.0.1", "editor", "Wiki")
    info :: PasskeyInfo <- register r editor options passkey r.public >>= jsonAs 200
    (info.id, info.unlocks) `shouldBe` (CredentialId (toBase64Url passkey.credentialId), False)
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` [info]
    used :: PasskeyInfo <- use r editor passkey 1 r.public >>= jsonAs 200
    used.lastUsedAt `shouldSatisfy` isJust
    -- The same passkey again is no new one.
    again :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
    again.exclude `shouldBe` [info.id]
    (register r editor again passkey r.public >>= jsonAs 409) `shouldReturn` Conflict "This passkey is registered already."

  it "refuses a passkey made on another site, or for another challenge, and a challenge used twice" $ withSignedIn backing $ \r editor _ -> do
    options :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
    refused :: ApiError <- register r editor options passkey "https://evil.example" >>= jsonAs 400
    refused `shouldSatisfy` says "made on another site"
    -- Its challenge was used up by that answer.
    stale :: ApiError <- register r editor options passkey r.public >>= jsonAs 400
    stale `shouldSatisfy` says "No passkey is being made"
    fresh :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
    other :: ApiError <- register r editor (withChallenge (toBase64Url "not the challenge the server gave") fresh) passkey r.public >>= jsonAs 400
    other `shouldSatisfy` says "another challenge"
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])

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
    refused :: ApiError <- call r theReader methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bg" "aw")])) >>= jsonAs 400
    refused `shouldSatisfy` says "not one of yours"
    (call r editor methodGet links.account.passkeys none >>= jsonAs 200) `shouldReturn` [info]

  it "is refused to someone not signed in" $ withSignedIn backing $ \r _ _ ->
    for_ [(methodGet, links.assistant.vault), (methodGet, links.account.passkeys), (methodPost, links.account.beginRegistration)] $ \(m, address) ->
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
    let wrapped = vaultWith [(info.id, WrappedKey "bm9uY2U" "a2V5")]
    secondVersion :: StoredVault <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) (encodeBody wrapped) >>= jsonAs 200
    secondVersion.tag `shouldNotBe` first'.tag
    wrappedFor info.id secondVersion.vault `shouldBe` Just (WrappedKey "bm9uY2U" "a2V5")
    map (\p -> p.unlocks) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [True]
    -- Over the first version again: changed meanwhile.
    stale :: ApiError <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) (encodeBody wrapped) >>= jsonAs 409
    stale `shouldBe` Conflict "The vault was changed on another device meanwhile."
    -- The passkey removed takes its wrapped key with it.
    (call r editor methodDelete (links.account.removePasskey info.id) none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])
    third :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    (third.vault.wrapped, third.tag /= secondVersion.tag) `shouldBe` (mempty, True)
    -- Turned off: the vault and its wrapped keys go, with no passkey asked
    -- for; the passkeys stay, since they sign the user in.
    another <- registerNew r editor (authenticator "another passkey")
    stored :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    _ :: StoredVault <-
      send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 stored.tag.text)]) (encodeBody (vaultWith [(another.id, WrappedKey "bm9uY2U" "a2V5")])) >>= jsonAs 200
    (\x -> x.status) <$> call r editor methodDelete links.assistant.deleteVault none `shouldReturn` 204
    (call r editor methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    map (\p -> (p.id, p.unlocks)) <$> (call r editor methodGet links.account.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [(another.id, False)]

  it "refuses a wrapped key, a passkey's answer or a passkey longer than any is" $ withSignedIn backing $ \r editor _ -> do
    info <- registerNew r editor passkey
    let tooLong = T.replicate (256 * 1024 + 1) "a"
    wrapped :: ApiError <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bm9uY2U" tooLong)])) >>= jsonAs 400
    wrapped `shouldSatisfy` says "too long"
    _ :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
    let other = authenticator "another passkey"
        answer = RegistrationResponse {id = CredentialId (toBase64Url other.credentialId), clientDataJSON = "e30", attestationObject = T.replicate (64 * 1024 + 1) "a", name = Nothing}
    long :: ApiError <- call r editor methodPut links.account.finishRegistration (Just answer) >>= jsonAs 400
    long `shouldSatisfy` says "longer than a passkey's answer"
    -- A credential id longer than WebAuthn allows, which the server would
    -- otherwise store.
    fresh :: RegistrationOptions <- call r editor methodPost links.account.beginRegistration none >>= jsonAs 200
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
    vaultWith wrapped = Vault {format = vaultFormat, salt = "c2FsdA", sealed = Sealed {nonce = "bm9uY2U", ciphertext = "c2VhbGVk"}, wrapped = Map.fromList wrapped}
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
  options <- call r session methodPost links.account.beginRegistration none >>= jsonAs 200
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
    enrolment :: TotpEnrolment <- call r editor methodPost links.account.enrolTotp (Just CurrentPassword {password = Just (Password "editor's password")}) >>= jsonAs 200
    secret <- maybe (panic "not base32") pure (secretFromText enrolment.secret)
    now <- getCurrentTime
    _ :: RecoveryCodes <- call r editor methodPut links.account.confirmTotp (Just OneTimeCode {code = codeAt secret now}) >>= jsonAs 200
    -- A passkey alone needs no code.
    (\x -> x.status) <$> signInWith r passkey 0x05 1 r.public (Just "user-editor") `shouldReturn` 200
    -- The password wants the code, or a passkey.
    half <- sendJson r methodPost (r.public <> "/" <> links.signIn) Credentials {login = "editor", password = Password "editor's password"}
    jsonAs 401 half `shouldReturn` SecondFactorRequired
    held <- maybe (panic "no pending cookie") pure (pendingOf half)
    let halfway = [("Cookie", "wiki_pending=" <> encodeUtf8 held)]
    options :: AssertionOptions <- send r methodPost (r.public <> "/" <> links.beginSecondFactorPasskey) halfway "" >>= jsonAs 200
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
