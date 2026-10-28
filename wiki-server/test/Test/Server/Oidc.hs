-- | Signing in with a provider, over real HTTP (WP3.6 of docs/PLAN.md):
-- the server on the demo's wiki, a fake provider beside it
-- ("Test.Server.FakeProvider"), and a test that plays the browser between
-- them, following the redirects by hand with the cookies a browser would
-- send (the session's, @SameSite=Strict@, not on the provider's redirect
-- back; the round trip's own, @SameSite=Lax@, on it).
--
-- The providers are set as the administration sets them (WP4.4), on the
-- admin listener of a server already running, and signing in with one
-- added, changed or removed is seen at once.
--
-- Then the parts that need no server: the ID token's claims, the logins
-- made for a new account, and @wiki-server oidc check@ on a data
-- directory.
module Test.Server.Oidc (spec) where

import Data.Aeson (ToJSON, Value, decode, encode, withObject, (.:))
import Data.Aeson.Types (parseMaybe)
import Data.ByteArray.Encoding (Base (..), convertToBase)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef, writeIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Network.HTTP.Types (Header, Method, hContentType, methodDelete, methodPost, methodPut)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.FakeProvider
import Test.Server.Fixture
import Wiki.Api (AccountApi (..), AdminApi (..), InvitationsApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), InvitationToken (..), LinkedIdentity (..), NewPassword (..), PasswordChange (..), SignInMethods (..))
import Wiki.Api.Admin (Directory (..), Invited (..), NewInvitation (..), WikiSettings (..))
import Wiki.Api.ContentPolicy (signInPolicy)
import Wiki.Api.Links (links)
import Wiki.Api.Security (CurrentPassword (..), OneTimeCode (..), RecoveryCodes, TotpEnrolment (..))
import Wiki.Api.ServerSettings (ProviderChange, ProviderKind (..), ProviderSettingsOf (..), ServerSettingsChange, ServerSettingsOf (..), noServerSettings)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Login (..), Password (..), SignInProvider (..), Standing (..), User (..))
import Wiki.Server.Accounts (Claimed (..), loginCandidates)
import Wiki.Server.Auth (safeNext)
import Wiki.Server.Console (OidcCheck (..), runOidcCheck)
import Wiki.Server.Oidc (IdClaims (..), checkClaims, decodeIdToken)
import Wiki.Server.Storage (Who (..), defaultConfig, runSqliteWiki, withStorage)
import Wiki.Server.Totp (codeAt, secretFromText)

spec :: Spec
spec = describe "signing in with a provider" $ do
  overHttp
  claims
  logins
  checking

-- | Someone at the provider: their subject, address, whether it is
-- verified, name, username, and whether the ID token says the name.
someone :: Text -> Maybe Text -> Bool -> Maybe Text -> Maybe Text -> Bool -> Person
someone sub email emailVerified name username nameInToken = Person {sub, email, emailVerified, name, username, nameInToken}

-- | The wiki's address as the providers know it: not the test server's,
-- whose port is chosen when it starts. The test's browser goes to the
-- server's wherever the provider sends it here.
publicUrl :: Text
publicUrl = "http://wiki.test/"

-- | The providers, all played by the fake: OpenID Connect at its root,
-- GitHub below @\/gh@, and Apple, whose answer is a form; each with the
-- fake's secret.
fakeProviders :: Fake -> [ProviderChange]
fakeProviders fake =
  [ ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url fake.url), secret = Just clientSecret}
  , ProviderSettings {name = "hub", kind = GitHub, clientId = "hub-client", issuer = Just (Url (fake.url <> "/gh")), secret = Just clientSecret}
  , ProviderSettings {name = "fruit", kind = Apple, clientId = "fruit-client", issuer = Just (Url fake.url), secret = Just clientSecret}
  ]

-- | The server's settings with these providers.
signingInWith :: [ProviderChange] -> ServerSettingsChange
signingInWith providers = ServerSettings {publicUrl = Just (Url publicUrl), mail = Nothing, providers, assistantHosts = []}

-- | A server over the demo's wiki, with the fake's providers set by its
-- operator once it runs.
withOidc :: (Fake -> Running -> IO a) -> IO a
withOidc test = withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
  _ <- setServer r (signingInWith (fakeProviders fake))
  test fake r

onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | The cookies a reply sets, by name.
cookiesSet :: Reply -> [(Text, Text)]
cookiesSet reply =
  [ (k, T.drop 1 v)
  | (name, raw) <- reply.headers
  , name == "Set-Cookie"
  , let (k, v) = T.breakOn "=" (T.takeWhile (/= ';') (decodeUtf8 raw))
  ]

-- | The session a reply gives, as the cookie to send.
sessionGiven :: (HasCallStack) => Reply -> IO Header
sessionGiven reply = case lookup "wiki_session" (cookiesSet reply) of
  Just token | not (T.null token) -> pure (cookie token)
  _ -> assertFailure ("no session given: " <> show reply)

-- | Where a page of the server's goes on to (its @meta refresh@).
onwardsOf :: Reply -> Maybe Text
onwardsOf reply = do
  let body = decodeUtf8 (BSL.toStrict reply.body)
  found <- nonEmpty' (snd (T.breakOn "url=" body))
  pure (T.replace "&amp;" "&" (T.takeWhile (/= '"') (T.drop 4 found)))
  where
    nonEmpty' t = if T.null t then Nothing else Just t

-- | A browser's way through a sign-in: the server's start, with these
-- cookies (the session's, if any) and this query; the provider; and back
-- to the callback, with the round trip's cookie only, as a browser sends
-- cookies on another site's redirect. For a provider that answers with a
-- form (Apple), the form is posted to the callback, with no cookie at all,
-- and the page it answers with followed, as a page of the wiki's own. The
-- callback's reply.
roundTrip :: (HasCallStack) => Running -> Text -> Text -> [Header] -> IO Reply
roundTrip r provider query hs = do
  started <- getUrlWith r (onPublic r ("auth/" <> provider <> "/start?" <> query)) hs
  unless (started.status == 302) $ assertFailure ("start did not go to the provider: " <> show started)
  flow <- maybe (assertFailure ("no round trip cookie: " <> show started)) pure (lookup "wiki_oidc" (cookiesSet started))
  let flowCookie = ("Cookie", "wiki_oidc=" <> encodeUtf8 flow)
  atProvider <- getUrl r (maybe "" decodeUtf8 (header "Location" started))
  case atProvider.status of
    302 -> do
      let back = maybe "" decodeUtf8 (header "Location" atProvider)
      getUrlWith r (atServer back) [flowCookie]
    200 -> do
      -- Apple's form, posted from its site.
      let fields :: Maybe (Text, Text, Text)
          fields = parseMaybe (withObject "form" (\o -> (,,) <$> o .: "code" <*> o .: "state" <*> o .: "user")) =<< (decodeValue atProvider.body)
      (code, given, user) <- maybe (assertFailure ("not a form: " <> show atProvider)) pure fields
      posted <- sendBare r methodPost (onPublic r ("auth/" <> provider <> "/callback")) [(hContentType, "application/x-www-form-urlencoded")] (formOf [("code", code), ("state", given), ("user", user)])
      posted.status `shouldBe` 200
      target <- maybe (assertFailure ("the form's page goes nowhere: " <> show posted)) pure (onwardsOf posted)
      getUrlWith r (r.public <> target) [flowCookie]
    _ -> assertFailure ("the provider did not answer: " <> show atProvider)
  where
    atServer url = maybe url (r.public <>) (T.stripPrefix (T.dropEnd 1 publicUrl) url)
    decodeValue :: LByteString -> Maybe Value
    decodeValue = decode
    formOf = BSL.fromStrict . encodeUtf8 . T.intercalate "&" . map (\(k, v) -> k <> "=" <> escape v)
    escape = T.concatMap (\c -> if isAlphaNum c then T.singleton c else T.pack (concatMap (\b -> '%' : hex b) (BSL.unpack (BSL.fromStrict (encodeUtf8 (T.singleton c))))))
    hex b = let (h, l) = b `divMod` 16 in [digit h, digit l]
    digit n = T.index "0123456789ABCDEF" (fromIntegral n)

-- | Who the public listener takes a request with these headers for.
sessionOf :: (HasCallStack) => Running -> [Header] -> IO SessionInfo
sessionOf r hs = getUrlWith r (onPublic r links.session) hs >>= jsonAs 200

loginOf :: SessionInfo -> Maybe Text
loginOf s = (\u -> u.login.text) <$> s.user

-- | Sign in through a provider, which must work: the session's cookie.
signedInWith :: (HasCallStack) => Running -> Text -> Text -> [Header] -> IO Header
signedInWith r provider query hs = do
  reply <- roundTrip r provider query hs
  unless (reply.status == 200) $ assertFailure ("not signed in: " <> show reply)
  sessionGiven reply

usersNow :: (HasCallStack) => Running -> IO Directory
usersNow r = getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200

settleAccess :: (HasCallStack) => Running -> Access -> IO ()
settleAccess r access = do
  _ :: WikiSettings <- sendJson r methodPut (onAdmin r links.admin.setSettings) WikiSettings {access, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True} >>= jsonAs 200
  pass

-- | A request with a JSON body and these headers besides.
sendJson' :: (ToJSON a) => Running -> Method -> Text -> [Header] -> a -> IO Reply
sendJson' r m url hs value = send r m url ((hContentType, "application/json") : hs) (encode value)

says :: Reply -> Text -> Expectation
says reply words' = decodeUtf8 (BSL.toStrict reply.body) `shouldSatisfy` T.isInfixOf words'

overHttp :: Spec
overHttp = describe "over HTTP" $ do
  describe "set at run time" $ do
    it "signs in with no provider until one is set, and with one as soon as it is" $ withFakeProvider $ \fake -> withDemoRunning identity $ \r -> do
      (\me -> me.providers) <$> sessionOf r [] `shouldReturn` []
      (\x -> x.status) <$> getUrl r (onPublic r "auth/acme/start?next=%2F") `shouldReturn` 404
      _ <- setServer r (signingInWith (take 1 (fakeProviders fake)))
      (\me -> me.providers) <$> sessionOf r [] `shouldReturn` [SignInProvider "acme" "Acme"]
      writeIORef fake.user (person "early")
      c <- signedInWith r "acme" "next=%2F" []
      loginOf <$> sessionOf r [c] `shouldReturn` Just "early"

    it "forgets a provider removed, and asks one changed how to sign in again" $ withOidc $ \fake r -> do
      _ <- setServer r (signingInWith (drop 1 (fakeProviders fake)))
      (\x -> x.status) <$> getUrl r (onPublic r "auth/acme/start?next=%2F") `shouldReturn` 404
      -- Its discovery is not the one found before: nothing listens there.
      _ <- setServer r (signingInWith [ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url "http://127.0.0.1:9"), secret = Just clientSecret}])
      gone <- getUrl r (onPublic r "auth/acme/start?next=%2F")
      gone.status `shouldBe` 502
      gone `says` "could not be asked how to sign in"
      -- Back where it was, kept secret and all (none given keeps it).
      _ <- setServer r (signingInWith [ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url fake.url), secret = Nothing}])
      writeIORef fake.user (person "again")
      c <- signedInWith r "acme" "next=%2F" []
      loginOf <$> sessionOf r [c] `shouldReturn` Just "again"

    it "signs in with the secret as it is now" $ withOidc $ \fake r -> do
      _ <- setServer r (signingInWith [ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url fake.url), secret = Just "not the secret"}])
      writeIORef fake.user (person "wrong")
      (\x -> x.status) <$> roundTrip r "acme" "next=%2F" [] `shouldReturn` 502
      _ <- setServer r (signingInWith [ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url fake.url), secret = Just clientSecret}])
      writeIORef fake.user (person "right")
      void (signedInWith r "acme" "next=%2F" [])

  it "offers the providers in every session, by name and label" $ withOidc $ \_ r -> do
    me <- sessionOf r []
    me.providers `shouldBe` [SignInProvider "acme" "Acme", SignInProvider "hub" "GitHub", SignInProvider "fruit" "Apple"]

  it "makes an account for someone unknown in an open wiki, signs them in, and goes back where they were" $ withOidc $ \fake r -> do
    writeIORef fake.user (someone "grace" (Just "grace@example.org") True (Just "Grace Hopper") (Just "grace") True)
    reply <- roundTrip r "acme" "next=%2Fs%2Fblog%2F" []
    reply.status `shouldBe` 200
    onwardsOf reply `shouldBe` Just "/s/blog/"
    -- The round trip's cookie is forgotten.
    lookup "wiki_oidc" (cookiesSet reply) `shouldBe` Just ""
    c <- sessionGiven reply
    me <- sessionOf r [c]
    ((\u -> (u.login.text, u.displayName)) <$> me.user, me.standing) `shouldBe` (Just ("grace", "Grace Hopper"), SignedIn)
    d <- usersNow r
    let grace = find (\u -> u.login.text == "grace") d.users
    (\u -> u.id `elem` toList d.withPassword) <$> grace `shouldBe` Just False
    ((\u -> lookup u.id (toPairs d.identities)) =<< grace) `shouldBe` Just ["acme"]

  it "signs the same person in as the same user next time" $ withOidc $ \fake r -> do
    writeIORef fake.user (person "grace")
    first' <- signedInWith r "acme" "next=%2F" []
    countBefore <- length . (\d -> d.users) <$> usersNow r
    second' <- signedInWith r "acme" "next=%2F" []
    countAfter <- length . (\d -> d.users) <$> usersNow r
    countAfter `shouldBe` countBefore
    a <- sessionOf r [first']
    b <- sessionOf r [second']
    ((\u -> u.id) <$> a.user) `shouldBe` ((\u -> u.id) <$> b.user)

  it "makes another login when the one wanted is taken" $ withOidc $ \fake r -> do
    -- The demo has an editor already.
    writeIORef fake.user (person "editor")
    c <- signedInWith r "acme" "next=%2F" []
    loginOf <$> sessionOf r [c] `shouldReturn` Just "editor-2"

  it "sends the client's secret as the provider takes it: in the form to GitHub, as HTTP's Basic where discovery does not say" $ withOidc $ \fake r -> do
    _ <- signedInWith r "acme" "next=%2F" []
    writeIORef fake.user (someone "77" (Just "g@example.org") True (Just "G") (Just "gee") True)
    _ <- signedInWith r "hub" "next=%2F" []
    readIORef fake.secretsBy `shouldReturn` ["form", "basic"]

  it "takes the user's login, name and verified address from GitHub's API" $ withOidc $ \fake r -> do
    writeIORef fake.user (someone "4242" (Just "octo@example.org") True (Just "Octo Cat") (Just "octo-cat") True)
    c <- signedInWith r "hub" "next=%2F" []
    me <- sessionOf r [c]
    (\u -> (u.login.text, u.displayName)) <$> me.user `shouldBe` Just ("octo-cat", "Octo Cat")
    methods :: SignInMethods <- getUrlWith r (onPublic r links.account.identities) [c] >>= jsonAs 200
    map (\i -> (i.provider, (\e -> e.text) <$> i.email)) methods.identities `shouldBe` [("hub", Just "octo@example.org")]

  it "keeps no address the provider has not verified" $ withOidc $ \fake r -> do
    writeIORef fake.user (someone "una" (Just "una@example.org") False (Just "Una") (Just "una") True)
    c <- signedInWith r "acme" "next=%2F" []
    methods :: SignInMethods <- getUrlWith r (onPublic r links.account.identities) [c] >>= jsonAs 200
    map (\i -> (\e -> e.text) <$> i.email) methods.identities `shouldBe` [Nothing]

  it "asks the user info for what the ID token does not say" $ withOidc $ \fake r -> do
    writeIORef fake.user (someone "ida" (Just "ida@example.org") True (Just "Ida Info") (Just "ida") False)
    c <- signedInWith r "acme" "next=%2F" []
    me <- sessionOf r [c]
    (\u -> u.displayName) <$> me.user `shouldBe` Just "Ida Info"

  it "takes Apple's answer as a form, and the name it sends the first time" $ withOidc $ \fake r -> do
    writeIORef fake.user (someone "apple-1" (Just "apple-1@example.org") True Nothing Nothing True)
    c <- signedInWith r "fruit" "next=%2F" []
    me <- sessionOf r [c]
    (\u -> (u.login.text, u.displayName)) <$> me.user `shouldBe` Just ("apple-1", "Fruit Lover")

  describe "in a closed wiki" $ do
    it "lets the round trip through, but makes no account without an invitation" $ withOidc $ \fake r -> do
      settleAccess r Closed
      writeIORef fake.user (person "stranger")
      countBefore <- length . (\d -> d.users) <$> usersNow r
      reply <- roundTrip r "acme" "next=%2F" []
      reply.status `shouldBe` 403
      reply `says` "open to its members only"
      lookup "wiki_session" (cookiesSet reply) `shouldBe` Nothing
      countAfter <- length . (\d -> d.users) <$> usersNow r
      countAfter `shouldBe` countBefore

    it "makes the account with an invitation, and uses the invitation up" $ withOidc $ \fake r -> do
      settleAccess r Closed
      invited :: Invited <- sendJson r methodPost (onAdmin r links.admin.invite) NewInvitation {email = "guest@example.org"} >>= jsonAs 201
      token <- maybe (assertFailure "no secret") pure ((\t -> t.text) <$> invited.token)
      writeIORef fake.user (person "guest")
      c <- signedInWith r "acme" ("next=%2F&invite=" <> token) []
      loginOf <$> sessionOf r [c] `shouldReturn` Just "guest"
      (\x -> x.status) <$> getUrl r (onPublic r (links.invitations.details (InvitationToken token))) `shouldReturn` 404

    it "signs in someone whose identity is known" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "member")
      _ <- signedInWith r "acme" "next=%2F" []
      settleAccess r Closed
      c <- signedInWith r "acme" "next=%2F" []
      loginOf <$> sessionOf r [c] `shouldReturn` Just "member"

  describe "connecting and disconnecting" $ do
    it "connects a provider's account to the user signed in, who then signs in with it" $ withOidc $ \fake r -> do
      givePassword r "user-editor" "editor's password"
      token <- signInAs r "editor" "editor's password"
      writeIORef fake.user (person "ed-at-acme")
      reply <- roundTrip r "acme" "next=%2F&link=1" [cookie token]
      reply.status `shouldBe` 200
      reply `says` "signs you in now"
      -- Still the same session: connecting signs no one in anew.
      lookup "wiki_session" (cookiesSet reply) `shouldBe` Nothing
      methods :: SignInMethods <- getUrlWith r (onPublic r links.account.identities) [cookie token] >>= jsonAs 200
      (methods.password, map (\i -> i.provider) methods.identities) `shouldBe` (True, ["acme"])
      c <- signedInWith r "acme" "next=%2F" []
      loginOf <$> sessionOf r [c] `shouldReturn` Just "editor"

    it "refuses to connect an account that is another user's" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "shared")
      _ <- signedInWith r "acme" "next=%2F" []
      givePassword r "user-editor" "editor's password"
      token <- signInAs r "editor" "editor's password"
      reply <- roundTrip r "acme" "next=%2F&link=1" [cookie token]
      reply.status `shouldBe` 403
      reply `says` "another user"

    it "asks someone not signed in to sign in before connecting" $ withOidc $ \_ r -> do
      reply <- getUrl r (onPublic r "auth/acme/start?next=%2F&link=1")
      reply.status `shouldBe` 403

    it "disconnects one, but not the last way to sign in" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "solo")
      c <- signedInWith r "acme" "next=%2F" []
      last' <- send r methodDelete (onPublic r (links.account.unlinkIdentity "acme")) [c] ""
      last'.status `shouldBe` 409
      writeIORef fake.user (someone "1234" (Just "solo@example.org") True (Just "Solo") (Just "solo-hub") True)
      linked <- roundTrip r "hub" "next=%2F&link=1" [c]
      linked.status `shouldBe` 200
      remaining :: SignInMethods <- send r methodDelete (onPublic r (links.account.unlinkIdentity "acme")) [c] "" >>= jsonAs 200
      map (\i -> i.provider) remaining.identities `shouldBe` ["hub"]

    it "refuses a password to a user who signs in only with a provider, their own and an administrator's alike" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "solo")
      c <- signedInWith r "acme" "next=%2F" []
      Just me <- (\s -> s.user) <$> sessionOf r [c]
      (\d -> me.id `Set.member` d.providerOnly) <$> usersNow r `shouldReturn` True
      own <- sendJson' r methodPut (onPublic r links.account.changePassword) [c] PasswordChange {current = Nothing, new = Password "solo's own password"}
      own.status `shouldBe` 400
      own `says` "no password to set"
      given <- sendJson r methodPut (onAdmin r (links.admin.setPassword me.id)) NewPassword {password = Password "given by the administrator"}
      given.status `shouldBe` 400
      given `says` "no password to set"
      mailed <- send r methodPost (onAdmin r (links.admin.sendPasswordLink me.id)) [] ""
      mailed.status `shouldBe` 400
      mailed `says` "no password to set"
      -- Nothing was set: the provider is still the only way in.
      methods :: SignInMethods <- getUrlWith r (onPublic r links.account.identities) [c] >>= jsonAs 200
      methods.password `shouldBe` False
      (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "solo", password = Password "solo's own password"} `shouldReturn` 401

    it "lets a user whose provider is removed from the server set a password, without a current one, and then sign in with it" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "solo")
      c <- signedInWith r "acme" "next=%2F" []
      Just me <- (\s -> s.user) <$> sessionOf r [c]
      _ <- setServer r (signingInWith [p | p <- fakeProviders fake, p.name /= "acme"])
      -- No way in now, but the session they are in: a password may be set.
      d <- usersNow r
      (lookup me.id (toPairs d.identities), me.id `Set.member` d.providerOnly) `shouldBe` (Just ["acme"], False)
      set :: SignInMethods <-
        sendJson' r methodPut (onPublic r links.account.changePassword) [c] PasswordChange {current = Nothing, new = Password "solo's own password"} >>= jsonAs 200
      (set.password, map (\i -> i.provider) set.identities) `shouldBe` (True, ["acme"])
      -- Still signed in, and now with a password too.
      loginOf <$> sessionOf r [c] `shouldReturn` Just "solo"
      signedIn <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "solo", password = Password "solo's own password"}
      signedIn.status `shouldBe` 200
      -- From now on, changing it asks for it, the provider back or not.
      _ <- setServer r (signingInWith (fakeProviders fake))
      (.status) <$> sendJson' r methodPut (onPublic r links.account.changePassword) [c] PasswordChange {current = Nothing, new = Password "another password"} `shouldReturn` 401
      (.status) <$> sendJson' r methodPut (onPublic r links.account.changePassword) [c] PasswordChange {current = Just (Password "solo's own password"), new = Password "another password"} `shouldReturn` 200

    it "lets an administrator give a password to a user whose last provider they disconnected" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "ex")
      c <- signedInWith r "acme" "next=%2F" []
      Just me <- (\s -> s.user) <$> sessionOf r [c]
      (.status) <$> sendJson r methodPut (onAdmin r (links.admin.setPassword me.id)) NewPassword {password = Password "given by the administrator"} `shouldReturn` 400
      (.status) <$> send r methodDelete (onAdmin r (links.admin.unlinkIdentity me.id "acme")) [] "" `shouldReturn` 204
      (\d -> me.id `Set.member` d.providerOnly) <$> usersNow r `shouldReturn` False
      account :: Account <- sendJson r methodPut (onAdmin r (links.admin.setPassword me.id)) NewPassword {password = Password "given by the administrator"} >>= jsonAs 200
      account.hasPassword `shouldBe` True
      (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "ex", password = Password "given by the administrator"} `shouldReturn` 200

    it "lets an administrator disconnect one, which ends the user's sessions" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "ex")
      c <- signedInWith r "acme" "next=%2F" []
      Just me <- (\s -> s.user) <$> sessionOf r [c]
      d <- usersNow r
      lookup me.id (toPairs d.identities) `shouldBe` Just ["acme"]
      gone <- send r methodDelete (onAdmin r (links.admin.unlinkIdentity me.id "acme")) [] ""
      gone.status `shouldBe` 204
      ((\s -> s.user) <$> sessionOf r [c]) `shouldReturn` Nothing
      again <- send r methodDelete (onAdmin r (links.admin.unlinkIdentity me.id "acme")) [] ""
      again.status `shouldBe` 404

    it "answers someone not signed in 401 for their identities" $ withOidc $ \_ r -> do
      reply <- getUrl r (onPublic r links.account.identities)
      reply.status `shouldBe` 401

  describe "with a second factor" $
    it "asks for its code on a page of its own, takes the right one only, and goes on where the user was" $
      withOidc $ \fake r -> do
        writeIORef fake.user (person "careful")
        c <- signedInWith r "acme" "next=%2F" []
        enrolment :: TotpEnrolment <- sendJson' r methodPost (onPublic r links.account.enrolTotp) [c] CurrentPassword {password = Nothing} >>= jsonAs 200
        secret <- maybe (assertFailure "not base32") pure (secretFromText enrolment.secret)
        now <- getCurrentTime
        _ :: RecoveryCodes <- sendJson' r methodPut (onPublic r links.account.confirmTotp) [c] OneTimeCode {code = codeAt secret now} >>= jsonAs 200
        reply <- roundTrip r "acme" "next=%2Fs%2Fblog%2F" []
        reply.status `shouldBe` 200
        reply `says` "second factor"
        lookup "wiki_session" (cookiesSet reply) `shouldBe` Nothing
        held <- maybe (assertFailure ("no pending cookie: " <> show reply)) pure (lookup "wiki_pending" (cookiesSet reply))
        let codeForm code = sendBare r methodPost (onPublic r "auth/acme/second-factor") [(hContentType, "application/x-www-form-urlencoded"), ("Cookie", "wiki_pending=" <> encodeUtf8 held)] ("code=" <> BSL.fromStrict (encodeUtf8 code))
        wrong <- codeForm "abcdef"
        wrong.status `shouldBe` 401
        wrong `says` "not right"
        lookup "wiki_session" (cookiesSet wrong) `shouldBe` Nothing
        right <- codeForm (codeAt secret (addUTCTime 30 now))
        right.status `shouldBe` 200
        onwardsOf right `shouldBe` Just "/s/blog/"
        lookup "wiki_pending" (cookiesSet right) `shouldBe` Just ""
        c' <- sessionGiven right
        loginOf <$> sessionOf r [c'] `shouldReturn` Just "careful"
        -- Over: the same cookie ends nothing more.
        again <- codeForm (codeAt secret (addUTCTime 30 now))
        again.status `shouldBe` 400

  describe "refusing" $ do
    it "refuses a disabled user" $ withOidc $ \fake r -> do
      writeIORef fake.user (person "later-off")
      c <- signedInWith r "acme" "next=%2F" []
      Just me <- (\s -> s.user) <$> sessionOf r [c]
      _ :: Account <- sendJson r methodPut (onAdmin r (links.admin.setDisabled me.id)) AccountDisabled {disabled = True} >>= jsonAs 200
      reply <- roundTrip r "acme" "next=%2F" []
      reply.status `shouldBe` 403
      reply `says` "disabled"
      lookup "wiki_session" (cookiesSet reply) `shouldBe` Nothing

    it "refuses an ID token for another client, with another nonce, from another issuer, or expired" $ withOidc $ \fake r ->
      for_ [WrongAudience, WrongNonce, WrongIssuer, Expired] $ \spoiled -> do
        writeIORef fake.spoil spoiled
        reply <- roundTrip r "acme" "next=%2F" []
        (spoiled, reply.status, lookup "wiki_session" (cookiesSet reply)) `shouldBe` (spoiled, 502, Nothing)
        reply `says` "ID token"

    it "says so when the provider says no" $ withOidc $ \fake r -> do
      writeIORef fake.spoil Refuses
      reply <- roundTrip r "acme" "next=%2F" []
      reply.status `shouldBe` 403
      reply `says` "The user said no"

    it "refuses a state it did not give, and one without the browser's cookie, once each" $ withOidc $ \_ r -> do
      unknown <- getUrlWith r (onPublic r "auth/acme/callback?code=c&state=nothing") [("Cookie", "wiki_oidc=nothing")]
      unknown.status `shouldBe` 400
      started <- getUrl r (onPublic r "auth/acme/start?next=%2F")
      let given = fromMaybe "" (lookup "wiki_oidc" (cookiesSet started))
      noCookie <- getUrl r (onPublic r ("auth/acme/callback?code=c&state=" <> given))
      noCookie.status `shouldBe` 400
      unknown `says` "start it again"

    it "sends its pages with the application's policy, their forms let lead to the provider" $ withOidc $ \fake r -> do
      missing <- getUrl r (onPublic r "auth/nobody/start?next=%2F")
      header "Content-Security-Policy" missing `shouldBe` Just (encodeUtf8 (signInPolicy []))
      -- Once the provider has said how to sign in (at the first start),
      -- its authorisation address is known.
      _ <- getUrl r (onPublic r "auth/acme/start?next=%2F")
      unknown <- getUrlWith r (onPublic r "auth/acme/callback?code=c&state=nothing") [("Cookie", "wiki_oidc=nothing")]
      header "Content-Security-Policy" unknown `shouldBe` Just (encodeUtf8 (signInPolicy [fake.url]))
      (header "Referrer-Policy" unknown, header "Permissions-Policy" unknown) `shouldBe` (Just "no-referrer", Just "camera=(), microphone=(), geolocation=()")

    it "answers a provider it does not have with 404, and nothing on the admin listener" $ withOidc $ \_ r -> do
      (\x -> x.status) <$> getUrl r (onPublic r "auth/nobody/start?next=%2F") `shouldReturn` 404
      (\x -> x.status) <$> getUrl r (onAdmin r "auth/acme/start?next=%2F") `shouldReturn` 404

    it "goes back only to the wiki's own addresses" $ do
      safeNext "/" (Just "/s/blog/") `shouldBe` "/s/blog/"
      safeNext "/" (Just "//evil.example/") `shouldBe` "/"
      safeNext "/" (Just "https://evil.example/") `shouldBe` "/"
      safeNext "/wiki/" (Just "/other/") `shouldBe` "/wiki/"
      safeNext "/wiki/" (Just "/wiki/s/x/") `shouldBe` "/wiki/s/x/"
      safeNext "/" Nothing `shouldBe` "/"
      safeNext "/" (Just "") `shouldBe` "/"
      safeNext "/wiki/" (Just "/wiki") `shouldBe` "/wiki"

    it "limits the accounts made from one address" $ withOidc $ \fake r -> do
      for_ [1 .. 5 :: Int] $ \n -> do
        writeIORef fake.user (person ("many-" <> show n))
        void (signedInWith r "acme" "next=%2F" [])
      writeIORef fake.user (person "many-6")
      reply <- roundTrip r "acme" "next=%2F" []
      reply.status `shouldBe` 429

  it "writes no code, token, state or secret into the log" $ withOidc $ \fake r -> do
    writeIORef fake.user (person "quiet")
    started <- getUrl r (onPublic r "auth/acme/start?next=%2F")
    let given = fromMaybe "" (lookup "wiki_oidc" (cookiesSet started))
    _ <- signedInWith r "acme" "next=%2F" []
    writeIORef fake.spoil WrongNonce
    _ <- roundTrip r "acme" "next=%2F" []
    issuedSecrets <- readIORef fake.issued
    logged <- T.unlines <$> readIORef r.logged
    length issuedSecrets `shouldSatisfy` (>= 4)
    for_ (clientSecret : given : issuedSecrets) $ \secret ->
      (secret, secret `T.isInfixOf` logged) `shouldBe` (secret, False)
    logged `shouldSatisfy` T.isInfixOf "event=oidc"

toPairs :: Map k v -> [(k, v)]
toPairs = Map.toList

claims :: Spec
claims = describe "an ID token's claims" $ do
  let now = UTCTime (fromGregorian 2026 10 25) 0
      token iss aud azp expires nonce =
        IdClaims
          { iss
          , sub = "s1"
          , aud
          , azp
          , expires
          , nonce
          , email = Nothing
          , emailVerified = Nothing
          , name = Nothing
          , preferredUsername = Nothing
          , givenName = Nothing
          , familyName = Nothing
          }
      soon = Just (addUTCTime 300 now)
      good = token "https://id.example" ["client"] Nothing soon (Just "n1")
      checked = checkClaims ["https://id.example"] "client" "n1" now
  it "takes those of this round trip" $ checked good `shouldBe` Right ()
  it "refuses another issuer, audience, nonce, or an expired token" $ do
    checked (token "https://other.example" ["client"] Nothing soon (Just "n1")) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["someone-else"] Nothing soon (Just "n1")) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["client"] Nothing soon (Just "n2")) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["client"] Nothing soon Nothing) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["client"] Nothing (Just (addUTCTime (-120) now)) (Just "n1")) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["client"] Nothing Nothing (Just "n1")) `shouldSatisfy` isLeft
  it "allows a minute of clock skew" $
    checked (token "https://id.example" ["client"] Nothing (Just (addUTCTime (-30) now)) (Just "n1")) `shouldBe` Right ()
  it "takes several audiences only on this client's behalf" $ do
    checked (token "https://id.example" ["client", "other"] Nothing soon (Just "n1")) `shouldSatisfy` isLeft
    checked (token "https://id.example" ["client", "other"] (Just "client") soon (Just "n1")) `shouldBe` Right ()
  it "reads a token's claims, a numeric subject and Apple's string e-mail_verified included" $ do
    let part :: Text -> Text
        part = decodeUtf8 . convertToBase Base64URLUnpadded . encodeUtf8
        payload = "{\"iss\":\"https://appleid.apple.com\",\"sub\":12,\"aud\":\"c\",\"exp\":1800000000,\"email_verified\":\"true\"}"
        jwt = part "{}" <> "." <> part payload <> ".sig"
    ((\c -> (c.sub, c.aud, c.emailVerified)) <$> decodeIdToken jwt) `shouldBe` Right ("12", ["c"], Just True)
    decodeIdToken "not a token" `shouldSatisfy` isLeft

logins :: Spec
logins = describe "the logins of accounts made with a provider" $ do
  let claimed login email name = Claimed {provider = "p", subject = "1", email = Email <$> email, name, login}
  it "come from the provider's login, then the address, then the name, else user" $ do
    take 1 (loginCandidates (claimed (Just "Octo.Cat") (Just "x@y.z") Nothing)) `shouldBe` ["octo.cat"]
    take 1 (loginCandidates (claimed Nothing (Just "ada.l@example.org") (Just "Ada"))) `shouldBe` ["ada.l"]
    take 1 (loginCandidates (claimed Nothing Nothing (Just "Grace B. Hopper"))) `shouldBe` ["grace-b.-hopper"]
    take 1 (loginCandidates (claimed Nothing Nothing Nothing)) `shouldBe` ["user"]
    -- Microsoft's preferred_username is an address.
    take 1 (loginCandidates (claimed (Just "Ann.Lee@contoso.com") Nothing Nothing)) `shouldBe` ["ann.lee"]
  it "are numbered after the first" $
    take 3 (loginCandidates (claimed (Just "ada") Nothing Nothing)) `shouldBe` ["ada", "ada-2", "ada-3"]
  it "are no longer than 40 characters, and never blank" $ do
    all (\l -> T.length l <= 40) (take 1 (loginCandidates (claimed (Just (T.replicate 100 "a")) Nothing Nothing))) `shouldBe` True
    take 1 (loginCandidates (claimed (Just "日本") Nothing Nothing)) `shouldBe` ["user"]

checking :: Spec
checking = describe "wiki-server oidc check" $ do
  let inData change test = withSystemTempDirectory "wiki-oidc-check" $ \dir -> do
        withStorage defaultConfig dir (\st -> runSqliteWiki st Administrator (setServerSettings change)) >>= either (\e -> assertFailure (show e)) (const pass)
        test dir
  it "asks each provider set how to sign in, and prints the redirect URI to register" $ withFakeProvider $ \fake -> do
    let acme = ProviderSettings {name = "acme", kind = Generic, clientId = "acme-client", issuer = Just (Url fake.url), secret = Just "x"}
    inData ServerSettings {publicUrl = Just (Url "https://wiki.example.org"), mail = Nothing, providers = [acme], assistantHosts = []} $ \dir -> do
      (fine, lines') <- runOidcCheck OidcCheck {dataDir = dir, only = Nothing}
      fine `shouldBe` True
      lines' `shouldContain` ["  redirect URI to register: https://wiki.example.org/auth/acme/callback"]
      lines' `shouldContain` ["  client secret: set"]
      lines' `shouldContain` ["  token: " <> fake.url <> "/token"]
      T.unlines lines' `shouldSatisfy` (not . T.isInfixOf "\"x\"")
  it "checks only the one named, and says when none is set" $ withFakeProvider $ \fake -> do
    let named n = ProviderSettings {name = n, kind = Generic, clientId = "c", issuer = Just (Url fake.url), secret = Just "x"}
    inData ServerSettings {publicUrl = Just (Url "https://wiki.example.org/"), mail = Nothing, providers = [named n | n <- ["a", "b"]], assistantHosts = []} $ \dir -> do
      (_, lines') <- runOidcCheck OidcCheck {dataDir = dir, only = Just "b"}
      filter ("auth/" `T.isInfixOf`) lines' `shouldBe` ["  redirect URI to register: https://wiki.example.org/auth/b/callback"]
      (fine, nobody) <- runOidcCheck OidcCheck {dataDir = dir, only = Just "c"}
      (fine, nobody) `shouldBe` (False, ["No provider is named c."])
    inData noServerSettings $ \dir -> do
      (fine, lines') <- runOidcCheck OidcCheck {dataDir = dir, only = Nothing}
      fine `shouldBe` False
      T.unlines lines' `shouldSatisfy` T.isInfixOf "Server section"
  it "fails for a provider that cannot be reached" $ do
    let gone = ProviderSettings {name = "gone", kind = Generic, clientId = "c", issuer = Just (Url "http://127.0.0.1:9"), secret = Just "x"}
    inData ServerSettings {publicUrl = Just (Url "https://wiki.example.org/"), mail = Nothing, providers = [gone], assistantHosts = []} $ \dir -> do
      (fine, lines') <- runOidcCheck OidcCheck {dataDir = dir, only = Nothing}
      fine `shouldBe` False
      T.unlines lines' `shouldSatisfy` T.isInfixOf "cannot be asked how to sign in"
