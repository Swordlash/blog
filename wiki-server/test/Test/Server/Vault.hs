-- | The assistant's vault and its passkeys over HTTP ("Wiki.Api.Vault",
-- "Wiki.Server.Vault"), with an authenticator the tests play
-- ("Test.Server.WebAuthn"): a passkey made and used for the signed-in
-- user, refused for another origin or challenge, a counter that does not
-- go up reported, another user's passkey and vault out of reach, and the
-- vault stored over the version it was read at, fetched by its tag,
-- losing a removed passkey's wrapped key, and deleted.
module Test.Server.Vault (spec) where

import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Types (Header, methodDelete, methodGet, methodPost, methodPut)
import Network.Wai (Request (..), defaultRequest)
import Protolude
import Test.Hspec
import Test.Server.Fixture
import Test.Server.WebAuthn (Authenticator (..), assertion, authenticator, registration)
import Wiki.Api (AssistantApi (..), WikiApi (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Vault
import Wiki.Core.Assistant.Vault
import Wiki.Core.Url (Url (..))
import Wiki.Server.Vault (Site (..), siteFor)
import Wiki.Server.WebAuthn (fromBase64Url, toBase64Url)

spec :: Spec
spec = describe "the assistant's vault and passkeys, over HTTP" $ do
  it "makes a passkey for the signed-in user, and checks its use" $ withSignedIn $ \r editor _ -> do
    options :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    (options.rpId, options.userName, options.rpName) `shouldBe` ("127.0.0.1", "editor", "Wiki")
    info :: PasskeyInfo <- register r editor options passkey r.public >>= jsonAs 200
    (info.id, info.unlocks) `shouldBe` (CredentialId (toBase64Url passkey.credentialId), False)
    (call r editor methodGet links.assistant.passkeys none >>= jsonAs 200) `shouldReturn` [info]
    used :: PasskeyInfo <- use r editor passkey 1 r.public >>= jsonAs 200
    used.lastUsedAt `shouldSatisfy` isJust
    -- The same passkey again is no new one.
    again :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    again.exclude `shouldBe` [info.id]
    (register r editor again passkey r.public >>= jsonAs 409) `shouldReturn` Conflict "This passkey is registered already."

  it "refuses a passkey made on another site, or for another challenge, and a challenge used twice" $ withSignedIn $ \r editor _ -> do
    options :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    refused :: ApiError <- register r editor options passkey "https://evil.example" >>= jsonAs 400
    refused `shouldSatisfy` says "made on another site"
    -- Its challenge was used up by that answer.
    stale :: ApiError <- register r editor options passkey r.public >>= jsonAs 400
    stale `shouldSatisfy` says "No passkey is being made"
    fresh :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    other :: ApiError <- register r editor (withChallenge (toBase64Url "not the challenge the server gave") fresh) passkey r.public >>= jsonAs 400
    other `shouldSatisfy` says "another challenge"
    (call r editor methodGet links.assistant.passkeys none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])

  it "reports a passkey whose counter does not go up, and keeps its counter" $ withSignedIn $ \r editor _ -> do
    _ :: PasskeyInfo <- registerNew r editor passkey
    _ :: PasskeyInfo <- use r editor passkey 5 r.public >>= jsonAs 200
    replayed :: ApiError <- use r editor passkey 5 r.public >>= jsonAs 409
    replayed `shouldSatisfy` says "counter went back, from 5 to 5"
    _ :: PasskeyInfo <- use r editor passkey 6 r.public >>= jsonAs 200
    pass

  it "keeps another user's passkey and vault out of reach" $ withSignedIn $ \r editor theReader -> do
    info <- registerNew r editor passkey
    _ <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [])) >>= jsonAs @StoredVault 200
    -- The reader's own assertion, answered with the editor's passkey.
    (use r theReader passkey 1 r.public >>= jsonAs 404) `shouldReturn` NotFound
    (call r theReader methodDelete (links.assistant.removePasskey info.id) none >>= jsonAs 404) `shouldReturn` NotFound
    (call r theReader methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    refused :: ApiError <- call r theReader methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bg" "aw")])) >>= jsonAs 400
    refused `shouldSatisfy` says "not one of yours"
    (call r editor methodGet links.assistant.passkeys none >>= jsonAs 200) `shouldReturn` [info]

  it "is refused to someone not signed in" $ withSignedIn $ \r _ _ ->
    for_ [(methodGet, links.assistant.vault), (methodGet, links.assistant.passkeys), (methodPost, links.assistant.beginRegistration)] $ \(m, address) ->
      (\x -> x.status) <$> send r m (r.public <> "/" <> address) [] "" `shouldReturn` 401

  it "stores the vault over the version read, fetches it by its tag, and deletes it" $ withSignedIn $ \r editor _ -> do
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
    map (\p -> p.unlocks) <$> (call r editor methodGet links.assistant.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [True]
    -- Over the first version again: changed meanwhile.
    stale :: ApiError <- send r methodPut (r.public <> "/" <> links.assistant.storeVault) (jsonHeader <> editor <> [("If-Match", encodeUtf8 first'.tag.text)]) (encodeBody wrapped) >>= jsonAs 409
    stale `shouldBe` Conflict "The vault was changed on another device meanwhile."
    -- The passkey removed takes its wrapped key with it.
    (call r editor methodDelete (links.assistant.removePasskey info.id) none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])
    third :: StoredVault <- call r editor methodGet links.assistant.vault none >>= jsonAs 200
    (third.vault.wrapped, third.tag /= secondVersion.tag) `shouldBe` (mempty, True)
    -- Turned off: the vault and every passkey go, with no passkey asked for.
    _ <- registerNew r editor (authenticator "another passkey")
    (\x -> x.status) <$> call r editor methodDelete links.assistant.deleteVault none `shouldReturn` 204
    (call r editor methodGet links.assistant.vault none >>= jsonAs 404) `shouldReturn` NotFound
    (call r editor methodGet links.assistant.passkeys none >>= jsonAs 200) `shouldReturn` ([] :: [PasskeyInfo])

  it "refuses a wrapped key, a passkey's answer or a passkey longer than any is" $ withSignedIn $ \r editor _ -> do
    info <- registerNew r editor passkey
    let tooLong = T.replicate (256 * 1024 + 1) "a"
    wrapped :: ApiError <- call r editor methodPut links.assistant.storeVault (Just (vaultWith [(info.id, WrappedKey "bm9uY2U" tooLong)])) >>= jsonAs 400
    wrapped `shouldSatisfy` says "too long"
    _ :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    let other = authenticator "another passkey"
        answer = RegistrationResponse {id = CredentialId (toBase64Url other.credentialId), clientDataJSON = "e30", attestationObject = T.replicate (64 * 1024 + 1) "a"}
    long :: ApiError <- call r editor methodPut links.assistant.finishRegistration (Just answer) >>= jsonAs 400
    long `shouldSatisfy` says "longer than a passkey's answer"
    -- A credential id longer than WebAuthn allows, which the server would
    -- otherwise store.
    fresh :: RegistrationOptions <- call r editor methodPost links.assistant.beginRegistration none >>= jsonAs 200
    longId :: ApiError <- register r editor fresh (authenticator (BS.replicate 1024 7)) r.public >>= jsonAs 400
    longId `shouldSatisfy` says "longer than a passkey's"
    map (\p -> p.id) <$> (call r editor methodGet links.assistant.passkeys none >>= jsonAs @[PasskeyInfo] 200) `shouldReturn` [info.id]

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
withSignedIn :: (Running -> [Header] -> [Header] -> IO a) -> IO a
withSignedIn test = withDemoRunning identity $ \r -> do
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
  call r session methodPut links.assistant.finishRegistration (Just RegistrationResponse {id = CredentialId (toBase64Url a.credentialId), clientDataJSON = toBase64Url client, attestationObject = toBase64Url attestation})

-- | Make a passkey, which the server takes.
registerNew :: (HasCallStack) => Running -> [Header] -> Authenticator -> IO PasskeyInfo
registerNew r session a = do
  options <- call r session methodPost links.assistant.beginRegistration none >>= jsonAs 200
  register r session options a r.public >>= jsonAs 200

-- | Use a passkey, with this counter, on this origin: the browser's
-- answer to a fresh challenge, sent.
use :: Running -> [Header] -> Authenticator -> Word32 -> Text -> IO Reply
use r session a counter origin = do
  options :: AssertionOptions <- call r session methodPost links.assistant.beginAssertion none >>= jsonAs 200
  challenge <- maybe (panic "no challenge") pure (fromBase64Url options.challenge)
  (client, authData, signature) <- assertion a counter options.rpId origin challenge
  call r session methodPut links.assistant.finishAssertion (Just AssertionResponse {id = CredentialId (toBase64Url a.credentialId), clientDataJSON = toBase64Url client, authenticatorData = toBase64Url authData, signature = toBase64Url signature})
