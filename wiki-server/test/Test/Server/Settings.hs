-- | The server's own settings over HTTP (WP4.4 of docs/PLAN.md): its
-- public address, its mail server and its providers, read and written by
-- an administrator only, their secrets never given back, checked as a
-- whole, taking effect at once and kept across a restart; a provider
-- asked how to sign in ("Check") and a test mail sent from the panel.
--
-- Signing in with a provider set at run time is "Test.Server.Oidc"'s, and
-- mail through settings changed at run time "Test.Server.Mail"'s.
module Test.Server.Settings (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.Text qualified as T
import Network.HTTP.Types (Header)
import Protolude
import Test.Hspec
import Test.Server.FakeProvider (Fake (..), clientSecret, withFakeProvider)
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), WikiApi (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings
import Wiki.Api.Types qualified as Types
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), SignInProvider (..))
import Wiki.Server.Mail (Message (..))

spec :: Spec
spec = describe "the server's settings, over HTTP" $ do
  reading
  secrets
  checks
  lasting
  checkingProviders
  testMails

-- | The address of an endpoint on the public listener and on the admin one.
onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | A mail server, with a password if one is given (and then a user).
mailServer :: Text -> Maybe Text -> MailChange
mailServer host password = mailAs host ("wiki" <$ password) password

-- | A mail server, with this user and this password.
mailAs :: Text -> Maybe Text -> Maybe Text -> MailChange
mailAs host user password = MailSettings {host, port = 587, security = StartTls, user, password, from = "Wiki <wiki@example.org>"}

-- | A provider of the fake's, with a secret if one is given.
provider :: Text -> Text -> Maybe Text -> ProviderChange
provider name issuer secret = ProviderSettings {name, kind = Generic, clientId = name <> "-client", issuer = Just (Url issuer), secret}

-- | Settings with an address, and what else is given.
withAddress :: ServerSettingsChange
withAddress = noServerSettings {publicUrl = Just (Url "https://wiki.example.org/")}

putServer :: Running -> [Header] -> Text -> ServerSettingsChange -> IO Reply
putServer r hs root change = send r "PUT" (root <> links.admin.setServer) (("Content-Type", "application/json") : hs) (encode change)

reading :: Spec
reading = describe "reading and writing them" $ do
  it "has nothing set at first: no address, no mail, no provider" $ withDemoRunning identity $ \r ->
    serverAs r `shouldReturn` noServerSettings

  it "answers the operator and an administrator's session, and nobody else" $ withAdminSession identity $ \r admin -> do
    (getUrlWith r (onPublic r links.admin.server) [admin] >>= jsonAs 200) `shouldReturn` (noServerSettings :: ServerSettings)
    (getUrl r (onPublic r links.admin.server) >>= jsonAs 403) `shouldReturn` Forbidden
    (putServer r [] (r.public <> "/") withAddress >>= jsonAs 403) `shouldReturn` Forbidden
    givePassword r "user-editor" "editor's password"
    editor <- cookie <$> signInAs r "editor" "editor's password"
    (getUrlWith r (onPublic r links.admin.server) [editor] >>= jsonAs 403) `shouldReturn` Forbidden
    (putServer r [editor] (r.public <> "/") withAddress >>= jsonAs 403) `shouldReturn` Forbidden
    (send r "POST" (onPublic r links.admin.testMail) [editor, ("Content-Type", "application/json")] "{\"to\":\"a@example.org\"}" >>= jsonAs 403) `shouldReturn` Forbidden
    (send r "POST" (onPublic r (links.admin.checkProvider "x")) [editor, ("Content-Type", "application/json")] "null" >>= jsonAs 403) `shouldReturn` Forbidden
    -- The administrator's session writes them, as the operator does.
    set :: ServerSettings <- putServer r [admin] (r.public <> "/") withAddress >>= jsonAs 200
    set.publicUrl `shouldBe` Just (Url "https://wiki.example.org/")
    serverAs r `shouldReturn` set

  it "normalises the address, and leaves out what is blank" $ withDemoRunning identity $ \r -> do
    set <- setServer r noServerSettings {publicUrl = Just (Url "  https://wiki.example.org/team  "), mail = Just (mailAs " mail.example.org " (Just "  ") Nothing)}
    set.publicUrl `shouldBe` Just (Url "https://wiki.example.org/team/")
    ((\m -> (m.host, m.user)) <$> set.mail) `shouldBe` Just ("mail.example.org", Nothing)

secrets :: Spec
secrets = describe "their secrets" $ do
  it "are never given back, only whether they are set, and never logged" $ withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
    let change = withAddress {mail = Just (mailServer "mail.example.org" (Just "the mail password")), providers = [provider "acme" fake.url (Just "the client secret")]}
    reply <- sendJson r "PUT" (onAdmin r links.admin.setServer) change
    set :: ServerSettings <- jsonAs 200 reply
    ((\m -> m.password) <$> set.mail, map (\p -> p.secret) set.providers) `shouldBe` (Just Set, [Set])
    read' <- getUrl r (onAdmin r links.admin.server)
    for_ [reply, read'] $ \x -> do
      let body = decodeUtf8 (BSL.toStrict x.body)
      body `shouldSatisfy` (not . T.isInfixOf "the mail password")
      body `shouldSatisfy` (not . T.isInfixOf "the client secret")
    logged <- T.unlines <$> readIORef r.logged
    logged `shouldSatisfy` (not . T.isInfixOf "the mail password")
    logged `shouldSatisfy` (not . T.isInfixOf "the client secret")

  it "are kept when left out, cleared when empty, and go with what is removed" $ withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {mail = Just (mailServer "mail.example.org" (Just "pw")), providers = [provider "acme" fake.url (Just "s")]}
    -- Left out: kept.
    kept <- setServer r withAddress {mail = Just (mailAs "mail.example.org" (Just "wiki") Nothing), providers = [provider "acme" fake.url Nothing]}
    ((\m -> m.password) <$> kept.mail, map (\p -> p.secret) kept.providers) `shouldBe` (Just Set, [Set])
    -- Empty: cleared, which a mail server without a user may be.
    cleared <- setServer r withAddress {mail = Just (mailAs "mail.example.org" Nothing (Just "")), providers = [provider "acme" fake.url Nothing]}
    (\m -> m.password) <$> cleared.mail `shouldBe` Just NotSet
    -- A provider must have its secret.
    (sendJson r "PUT" (onAdmin r links.admin.setServer) withAddress {providers = [provider "acme" fake.url (Just "")]} >>= jsonAs 400)
      `shouldReturn` Invalid "The provider acme needs its client secret."
    -- Removed, and added again under its name: its secret went with it.
    _ <- setServer r withAddress
    (sendJson r "PUT" (onAdmin r links.admin.setServer) withAddress {providers = [provider "acme" fake.url Nothing]} >>= jsonAs 400)
      `shouldReturn` Invalid "The provider acme needs its client secret."
    -- So did the mail server's password.
    _ <- setServer r withAddress {mail = Just (mailServer "mail.example.org" (Just "pw"))}
    _ <- setServer r withAddress
    (sendJson r "PUT" (onAdmin r links.admin.setServer) withAddress {mail = Just (mailAs "mail.example.org" (Just "wiki") Nothing)} >>= jsonAs 400)
      `shouldReturn` Invalid "The mail server's user wiki needs its password."

checks :: Spec
checks = describe "a change that cannot be" $
  it "is refused whole, saying why, and nothing of it is kept" $
    withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
      let refused change = sendJson r "PUT" (onAdmin r links.admin.setServer) change >>= jsonAs @ApiError 400
      refused noServerSettings {publicUrl = Just (Url "wiki.example.org")} `shouldReturn` Invalid "The wiki's public address starts with http:// or https://: wiki.example.org"
      refused noServerSettings {mail = Just (mailServer "mail.example.org" Nothing)} `shouldReturn` Invalid "The mail needs the wiki's public address: the links it carries start with it."
      refused noServerSettings {providers = [provider "acme" fake.url (Just "s")]} `shouldReturn` Invalid "The providers need the wiki's public address: they send people back below it."
      refused withAddress {providers = [provider "acme" fake.url (Just "s"), provider "acme" fake.url (Just "t")]} `shouldReturn` Invalid "There are two providers named acme."
      refused withAddress {providers = [ProviderSettings {name = "corp", kind = Generic, clientId = "c", issuer = Nothing, secret = Just "s"}]}
        `shouldReturn` Invalid "The provider corp, of kind oidc, needs its issuer: https://issuer.example.org"
      refused withAddress {providers = [provider "Corp_1" fake.url (Just "s")]}
        >>= (`shouldSatisfy` \case Invalid why -> "A provider's name is lower-case letters" `T.isPrefixOf` why; _ -> False)
      refused withAddress {providers = [provider "corp" "http://id.example.org" (Just "s")]}
        `shouldReturn` Invalid "The provider corp's address http://id.example.org must start with https:// (or http:// on this machine, for a test)."
      refused withAddress {mail = Just (mailServer "" Nothing)} `shouldReturn` Invalid "The mail server needs its host."
      refused withAddress {mail = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user = Nothing, password = Nothing, from = " "}} `shouldReturn` Invalid "The mail needs its sender: the address it is sent from."
      serverAs r `shouldReturn` noServerSettings

lasting :: Spec
lasting = describe "a change" $
  it "is seen by the very next request, and lasts across a restart" $
    withFakeProvider $ \fake ->
      withDemoRestarted
        ( \r -> do
            set <- setServer r withAddress {providers = [provider "acme" fake.url (Just clientSecret)]}
            session :: Types.SessionInfo <- getUrl r (onPublic r links.session) >>= jsonAs 200
            session.providers `shouldBe` [SignInProvider "acme" "Acme"]
            pure set
        )
        (\set again -> serverAs again `shouldReturn` set)

checkingProviders :: Spec
checkingProviders = describe "checking a provider" $ do
  it "asks it how to sign in, as set, and gives the redirect URI to register" $ withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {providers = [provider "acme" fake.url (Just clientSecret)]}
    found :: ProviderCheck <- sendJson r "POST" (onAdmin r (links.admin.checkProvider "acme")) (Nothing :: Maybe ProviderChange) >>= jsonAs 200
    found.redirectUri `shouldBe` Just (Url "https://wiki.example.org/auth/acme/callback")
    found.clientSecret `shouldBe` Set
    found.problem `shouldBe` Nothing
    (\d -> d.token) <$> found.discovered `shouldBe` Just (Url (fake.url <> "/token"))

  it "asks one as given before it is saved, with the secret set for its name" $ withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {providers = [provider "acme" "https://id.invalid" (Just clientSecret)]}
    found :: ProviderCheck <- sendJson r "POST" (onAdmin r (links.admin.checkProvider "acme")) (Just (provider "acme" fake.url Nothing)) >>= jsonAs 200
    (found.clientSecret, isJust found.discovered, found.problem) `shouldBe` (Set, True, Nothing)
    fresh :: ProviderCheck <- sendJson r "POST" (onAdmin r (links.admin.checkProvider "new")) (Just (provider "new" fake.url Nothing)) >>= jsonAs 200
    (fresh.clientSecret, fresh.redirectUri) `shouldBe` (NotSet, Just (Url "https://wiki.example.org/auth/new/callback"))
    -- Nothing given and nothing set by that name.
    (sendJson r "POST" (onAdmin r (links.admin.checkProvider "nobody")) (Nothing :: Maybe ProviderChange) >>= jsonAs 404) `shouldReturn` NotFound

  it "says why one cannot be asked" $ withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {providers = [provider "gone" "http://127.0.0.1:9" (Just "s")]}
    found :: ProviderCheck <- sendJson r "POST" (onAdmin r (links.admin.checkProvider "gone")) (Nothing :: Maybe ProviderChange) >>= jsonAs 200
    found.discovered `shouldBe` Nothing
    found.problem `shouldSatisfy` maybe False (T.isInfixOf "could not be asked how to sign in")
    bad :: ProviderCheck <- sendJson r "POST" (onAdmin r (links.admin.checkProvider "corp")) (Just (provider "corp" "http://id.example.org" Nothing)) >>= jsonAs 200
    bad.problem `shouldSatisfy` maybe False (T.isInfixOf "must start with https://")

testMails :: Spec
testMails = describe "a test mail" $ do
  it "is sent to the address given, through the mail server as set" $ withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {mail = Just (mailServer "mail.test" Nothing)}
    (sendJson r "POST" (onAdmin r links.admin.testMail) MailTest {to = "ada@example.org"} >>= jsonAs 200) `shouldReturn` MailTestResult {failure = Nothing}
    sent <- readIORef r.outbox
    map (\m -> (m.to.text, m.subject)) sent `shouldBe` [("ada@example.org", "A test mail from the wiki at wiki.example.org")]

  it "says why it was not sent" $ withDemoRunning identity $ \r -> do
    _ <- setServer r withAddress {mail = Just (mailServer "unreachable.test" Nothing)}
    result :: MailTestResult <- sendJson r "POST" (onAdmin r links.admin.testMail) MailTest {to = "ada@example.org"} >>= jsonAs 200
    result.failure `shouldSatisfy` maybe False (T.isInfixOf "did not answer")

  it "is refused without a mail server, or to what is not an address" $ withDemoRunning identity $ \r -> do
    (sendJson r "POST" (onAdmin r links.admin.testMail) MailTest {to = "ada@example.org"} >>= jsonAs 400)
      `shouldReturn` Invalid "This wiki has no mail server yet, or no public address: set them first."
    _ <- setServer r withAddress {mail = Just (mailServer "mail.test" Nothing)}
    (sendJson r "POST" (onAdmin r links.admin.testMail) MailTest {to = "not an address"} >>= jsonAs @ApiError 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
