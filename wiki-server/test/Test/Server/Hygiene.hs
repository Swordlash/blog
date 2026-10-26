-- | Keeping an account safe (WP4.11 of docs/PLAN.md), over real HTTP: a
-- user's sessions listed and ended, a second factor set up, asked for at
-- sign-in and taken away, an e-mail address verified by a mailed link, and
-- a password reset by mail; and, on the storage, the rules of the reset's
-- links (single use, thirty minutes, a few an hour) and of "last seen".
--
-- The demo's wiki is the server's, as in "Test.Server.Accounts"; the
-- editor signs in with a password the operator gives them.
module Test.Server.Hygiene (spec) where

import Data.Aeson (encode)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Database.SQLite.Simple (Only (..), query)
import Network.HTTP.Types (Header, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AccountApi (..), AdminApi (..), PasswordResetApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), Credentials (..), NewAccount (..))
import Wiki.Api.Admin (Directory (..), WikiSettings (..), defaultSettings)
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Security
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), noServerSettings)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Backend qualified as WikiError
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (User (..))
import Wiki.Server.Accounts (Resolved (..), createAccount, resolveSession, seenEvery, signIn)
import Wiki.Server.Mail (Message (..))
import Wiki.Server.Reset (ResetMail (..), requestReset, resetPassword, setEmail, verifyEmail)
import Wiki.Server.Storage (Storage, defaultConfig, withDatabase, withStorage)
import Wiki.Server.Totp (codeAt, secretFromText)

spec :: Spec
spec = describe "account hygiene" $ do
  sessions
  secondFactor
  email
  reset
  storageRules

onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | The demo with a password for the editor, signed in once: the cookie.
withEditor :: (Running -> Text -> IO a) -> IO a
withEditor test = withDemoRunning identity $ \r -> do
  givePassword r "user-editor" "editor's password"
  token <- signInAs r "editor" "editor's password"
  test r token

-- | The server mailing into the test's outbox, at a public address.
mailing :: Running -> IO ()
mailing r =
  void . setServer r $
    noServerSettings
      { publicUrl = Just "https://wiki.example.org/"
      , mail = Just MailSettings {host = "mail.test", port = 587, security = StartTls, user = Nothing, password = Nothing, from = "Wiki <wiki@example.org>"}
      }

-- | A request as the signed-in user.
as :: Running -> Text -> Method' -> Text -> LByteString -> IO Reply
as r token m address body = send r m (onPublic r address) [(hContentType, "application/json"), cookie token] body

type Method' = ByteString

-- | The secret of the first link in the mails sent so far to an address
-- that starts so.
linkIn :: Running -> Text -> IO (Maybe Text)
linkIn r prefix = do
  sent <- readIORef r.outbox
  pure (head [T.dropEnd 1 (T.drop (T.length prefix) w) | m <- reverse sent, w <- T.words m.body, prefix `T.isPrefixOf` w])

-- | Wait, a little at a time, for something to hold: a mail sent after the
-- answer.
eventually :: (HasCallStack) => IO Bool -> IO ()
eventually condition = go (100 :: Int)
  where
    go 0 = expectationFailure "it did not happen in time"
    go n = condition >>= \held -> unless held (threadDelay 50_000 >> go (n - 1))

-- | The cookie of a sign-in waiting for its second factor, from a response.
pendingOf :: Reply -> Maybe Text
pendingOf reply =
  head
    [ T.takeWhile (/= ';') v
    | (name, raw) <- reply.headers
    , name == "Set-Cookie"
    , Just v <- [T.stripPrefix "wiki_pending=" (decodeUtf8 raw)]
    , not (T.null (T.takeWhile (/= ';') v))
    ]

pendingCookie :: Text -> Header
pendingCookie token = ("Cookie", "wiki_pending=" <> encodeUtf8 token)

--------------------------------------------------------------------------------

sessions :: Spec
sessions = describe "one's sessions" $ do
  it "are listed with where they were used, this one marked, without their secrets" $ withEditor $ \r t1 -> do
    t2 <- signInAs r "editor" "editor's password"
    reply <- as r t1 methodGet links.account.sessions ""
    listed :: [SessionSummary] <- jsonAs 200 reply
    length listed `shouldBe` 2
    map (\s -> s.current) listed `shouldMatchList` [True, False]
    map (\s -> s.address) listed `shouldBe` ["127.0.0.1", "127.0.0.1"]
    for_ [t1, t2] $ \t -> decodeUtf8 (toS reply.body) `shouldSatisfy` (not . T.isInfixOf t)
    (getUrl r (onPublic r links.account.sessions) >>= jsonAs 401) `shouldReturn` Unauthenticated

  it "end one by one, but not this one, and all but this one with \"Sign out everywhere\"" $ withEditor $ \r t1 -> do
    t2 <- signInAs r "editor" "editor's password"
    t3 <- signInAs r "editor" "editor's password"
    listed :: [SessionSummary] <- as r t1 methodGet links.account.sessions "" >>= jsonAs 200
    let others = filter (\s -> not s.current) listed
        this = filter (\s -> s.current) listed
    other <- maybe (panic "no other session") pure (head others)
    left :: [SessionSummary] <- as r t1 methodDelete (links.account.endSession other.id) "" >>= jsonAs 200
    length left `shouldBe` 2
    -- One of the other two is anonymous now, the other still signed in.
    stillIn <- for [t2, t3] $ \t -> (\(i :: SessionInfo) -> isJust i.user) <$> (getUrlWith r (onPublic r links.session) [cookie t] >>= jsonAs 200)
    sort stillIn `shouldBe` [False, True]
    (as r t1 methodDelete (links.account.endSession other.id) "" >>= jsonAs 404) `shouldReturn` NotFound
    for_ this $ \s -> (as r t1 methodDelete (links.account.endSession s.id) "" >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    only :: [SessionSummary] <- as r t1 methodDelete links.account.endOtherSessions "" >>= jsonAs 200
    map (\s -> s.current) only `shouldBe` [True]
    for_ [t2, t3] $ \t -> ((\(i :: SessionInfo) -> i.user) <$> (getUrlWith r (onPublic r links.session) [cookie t] >>= jsonAs 200)) `shouldReturn` Nothing
    me :: SessionInfo <- getUrlWith r (onPublic r links.session) [cookie t1] >>= jsonAs 200
    (\u -> u.login) <$> me.user `shouldBe` Just "editor"

--------------------------------------------------------------------------------

-- | Set up a second factor for the user signed in: the secret, the code
-- that confirmed it, and the recovery codes.
setUp :: Running -> Text -> IO (Text, Text, [Text])
setUp r token = do
  enrolment :: TotpEnrolment <- as r token methodPost links.account.enrolTotp (encode CurrentPassword {password = Just "editor's password"}) >>= jsonAs 200
  secret <- maybe (panic "not base32") pure (secretFromText enrolment.secret)
  now <- getCurrentTime
  let code = codeAt secret now
  codes :: RecoveryCodes <- as r token methodPut links.account.confirmTotp (encode OneTimeCode {code}) >>= jsonAs 200
  pure (enrolment.secret, code, codes.codes)

-- | Sign in with the password, which then wants the code: the cookie of
-- the sign-in waiting.
halfSignedIn :: (HasCallStack) => Running -> IO Text
halfSignedIn r = do
  reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
  jsonAs 401 reply `shouldReturn` SecondFactorRequired
  setCookie reply `shouldBe` Nothing
  maybe (panic ("no pending cookie: " <> show reply)) pure (pendingOf reply)

-- | End a sign-in that waits, with a code.
withCode :: Running -> Text -> Text -> IO Reply
withCode r held code = send r methodPost (onPublic r links.secondFactor) [(hContentType, "application/json"), pendingCookie held] (encode OneTimeCode {code})

secondFactor :: Spec
secondFactor = describe "a second factor" $ do
  it "is set up with a secret shown as text and a QR code, and is on only once a code confirms it" $ withEditor $ \r t -> do
    (as r t methodGet links.account.secondFactorState "" >>= jsonAs 200) `shouldReturn` SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = True}
    enrolment :: TotpEnrolment <- as r t methodPost links.account.enrolTotp (encode CurrentPassword {password = Just "editor's password"}) >>= jsonAs 200
    enrolment.uri `shouldSatisfy` T.isPrefixOf ("otpauth://totp/Wiki:editor?secret=" <> enrolment.secret)
    enrolment.qr `shouldSatisfy` (not . null)
    -- Not asked for until it is confirmed.
    _ <- signInAs r "editor" "editor's password"
    (as r t methodPut links.account.confirmTotp (encode OneTimeCode {code = "abcdef"}) >>= jsonAs 401) `shouldReturn` Unauthenticated
    secret <- maybe (panic "not base32") pure (secretFromText enrolment.secret)
    now <- getCurrentTime
    codes :: RecoveryCodes <- as r t methodPut links.account.confirmTotp (encode OneTimeCode {code = codeAt secret now}) >>= jsonAs 200
    length codes.codes `shouldBe` 10
    (as r t methodGet links.account.secondFactorState "" >>= jsonAs 200) `shouldReturn` SecondFactorState {enabled = True, recoveryCodesLeft = 10, asksPassword = True}
    -- On once: a second one is not begun over it.
    (as r t methodPost links.account.enrolTotp (encode CurrentPassword {password = Just "editor's password"}) >>= jsonAs 409) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    directory :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    directory.secondFactor `shouldBe` Set.singleton (UserId "user-editor")

  it "is asked for after the password, each code taken once, each recovery code once" $ withEditor $ \r t -> do
    (secretText', used, recovery) <- setUp r t
    secret <- maybe (panic "not base32") pure (secretFromText secretText')
    held <- halfSignedIn r
    -- Without the cookie the sign-in is not found; a wrong code is refused.
    (sendJson r methodPost (onPublic r links.secondFactor) OneTimeCode {code = used} >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    (withCode r held "abcdef" >>= jsonAs 401) `shouldReturn` Unauthenticated
    -- The code that confirmed it was taken then.
    (withCode r held used >>= jsonAs 401) `shouldReturn` Unauthenticated
    now <- getCurrentTime
    let next = codeAt secret (addUTCTime 30 now)
    reply <- withCode r held next
    info :: SessionInfo <- jsonAs 200 reply
    (\u -> u.login) <$> info.user `shouldBe` Just "editor"
    token <- maybe (panic "no session cookie") (pure . fst) (setCookie reply)
    me :: SessionInfo <- getUrlWith r (onPublic r links.session) [cookie token] >>= jsonAs 200
    isJust me.user `shouldBe` True
    -- The sign-in is over: its cookie ends no other.
    (withCode r held next >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    -- The same code again, in a new sign-in: taken already.
    again <- halfSignedIn r
    (withCode r again next >>= jsonAs 401) `shouldReturn` Unauthenticated
    recoveryCode <- maybe (panic "no recovery codes") pure (head recovery)
    _ <- withCode r again (T.toUpper recoveryCode) >>= jsonAs @SessionInfo 200
    third <- halfSignedIn r
    (withCode r third recoveryCode >>= jsonAs 401) `shouldReturn` Unauthenticated
    (as r token methodGet links.account.secondFactorState "" >>= jsonAs 200) `shouldReturn` SecondFactorState {enabled = True, recoveryCodesLeft = 9, asksPassword = True}

  it "counts wrong codes as failed sign-ins: after five, not even the password is taken" $ withEditor $ \r t -> do
    _ <- setUp r t
    held <- halfSignedIn r
    replicateM_ 5 (withCode r held "abcdef")
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
    reply.status `shouldBe` 429

  it "is taken away by its user with a code, and by an administrator without one" $ withEditor $ \r t -> do
    (_, _, recovery) <- setUp r t
    (as r t methodPost links.account.removeSecondFactor (encode OneTimeCode {code = "abcdef"}) >>= jsonAs 401) `shouldReturn` Unauthenticated
    recoveryCode <- maybe (panic "no recovery codes") pure (head recovery)
    (as r t methodPost links.account.removeSecondFactor (encode OneTimeCode {code = recoveryCode}) >>= jsonAs 200)
      `shouldReturn` SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = True}
    _ <- signInAs r "editor" "editor's password"
    _ <- setUp r t
    _ <- halfSignedIn r
    -- Not to a user, from the public listener, without the administer.
    (.status) <$> send r methodDelete (onPublic r (links.admin.removeSecondFactor (UserId "user-editor"))) [cookie t] "" `shouldReturn` 403
    (.status) <$> send r methodDelete (onAdmin r (links.admin.removeSecondFactor (UserId "user-editor"))) [] "" `shouldReturn` 204
    (send r methodDelete (onAdmin r (links.admin.removeSecondFactor (UserId "user-editor"))) [] "" >>= jsonAs 404) `shouldReturn` NotFound
    _ <- signInAs r "editor" "editor's password"
    pass

--------------------------------------------------------------------------------

email :: Spec
email = describe "an e-mail address" $ do
  it "cannot be given where the server sends no mail, and says so" $ withEditor $ \r t -> do
    current :: EmailState <- as r t methodGet links.account.email "" >>= jsonAs 200
    (current.email, current.mailing) `shouldBe` (Nothing, False)
    (as r t methodPut links.account.setEmail (encode EmailChange {email = "edgar@example.org", password = Just "editor\'s password"}) >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)

  it "takes the current password to be given, changed or removed, but not to have its link sent again" $ withEditor $ \r t -> do
    mailing r
    let change address password = as r t methodPut links.account.setEmail (encode EmailChange {email = address, password})
    (change "edgar@example.org" Nothing >>= jsonAs 401) `shouldReturn` Unauthenticated
    (change "edgar@example.org" (Just "not the password") >>= jsonAs 401) `shouldReturn` Unauthenticated
    given :: EmailState <- change "edgar@example.org" (Just "editor's password") >>= jsonAs 200
    given.asksPassword `shouldBe` True
    -- The same address again: its link again, nothing asked.
    _ <- change "EDGAR@example.org" Nothing >>= jsonAs @EmailState 200
    length <$> readIORef r.outbox `shouldReturn` 2
    (change "" Nothing >>= jsonAs 401) `shouldReturn` Unauthenticated
    removed :: EmailState <- change "" (Just "editor's password") >>= jsonAs 200
    removed.email `shouldBe` Nothing
    -- Nor is a second factor begun with the session alone.
    (as r t methodPost links.account.enrolTotp (encode CurrentPassword {password = Nothing}) >>= jsonAs 401) `shouldReturn` Unauthenticated
    -- Wrong passwords count as failed sign-ins.
    replicateM_ 4 (change "edgar@example.net" (Just "wrong"))
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
    reply.status `shouldBe` 429

  it "is verified by the link mailed to it, once, and not if it has changed since" $ withEditor $ \r t -> do
    mailing r
    given :: EmailState <- as r t methodPut links.account.setEmail (encode EmailChange {email = "edgar@example.org", password = Just "editor\'s password"}) >>= jsonAs 200
    (given.email, given.verified, given.mailing, given.mailError) `shouldBe` (Just "edgar@example.org", False, True, Nothing)
    sent <- readIORef r.outbox
    map (\m -> m.to) sent `shouldBe` ["edgar@example.org"]
    first' <- maybe (panic "no link") pure =<< linkIn r "https://wiki.example.org/verify-email/"
    -- A new address: the first link no longer verifies anything.
    _ <- as r t methodPut links.account.setEmail (encode EmailChange {email = "edgar@example.com", password = Just "editor\'s password"}) >>= jsonAs @EmailState 200
    (send r methodPost (onPublic r (links.emailVerification (MailToken first'))) [] "" >>= jsonAs 404) `shouldReturn` NotFound
    second' <- maybe (panic "no link") pure =<< latestLink r "https://wiki.example.org/verify-email/"
    second' `shouldNotBe` first'
    -- Anyone with the link verifies it, signed in or not.
    (.status) <$> send r methodPost (onPublic r (links.emailVerification (MailToken second'))) [] "" `shouldReturn` 204
    (as r t methodGet links.account.email "" >>= jsonAs 200) `shouldReturn` EmailState {email = Just "edgar@example.com", verified = True, mailing = True, mailError = Nothing, asksPassword = True}
    (send r methodPost (onPublic r (links.emailVerification (MailToken second'))) [] "" >>= jsonAs 404) `shouldReturn` NotFound
    directory :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    directory.emails `shouldBe` Map.singleton (UserId "user-editor") AccountEmail {email = "edgar@example.com", verified = True}
    directory.mailing `shouldBe` True

  it "may be given to a new user by the administration, which mails it the link" $ withDemoRunning identity $ \r -> do
    mailing r
    (sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "bea", displayName = "", password = "bea's password", email = Just "not an address"} >>= jsonAs 400)
      >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    made :: Account <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "bea", displayName = "", password = "bea's password", email = Just "bea@example.org"} >>= jsonAs 201
    sent <- readIORef r.outbox
    map (\m -> m.to) sent `shouldBe` ["bea@example.org"]
    directory :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    directory.emails `shouldBe` Map.singleton made.user.id AccountEmail {email = "bea@example.org", verified = False}

--------------------------------------------------------------------------------

-- | Ask for a reset, as anyone.
askReset :: Running -> Text -> IO Reply
askReset r login = sendJson r methodPost (onPublic r links.passwordReset.request) ResetRequest {login}

reset :: Spec
reset = describe "a password reset" $ do
  it "is refused alike for every login where the server sends no mail" $ withDemoRunning identity $ \r -> do
    a <- askReset r "editor"
    b <- askReset r "nobody"
    (a.status, a.body) `shouldBe` (b.status, b.body)
    a.status `shouldBe` 400

  it "is answered alike whoever it names, and mailed only to a verified address, whose link sets a password once and signs everyone out" $
    withEditor $ \r t -> do
      mailing r
      _ <- as r t methodPut links.account.setEmail (encode EmailChange {email = "edgar@example.org", password = Just "editor\'s password"}) >>= jsonAs @EmailState 200
      -- Not verified: no reset is mailed.
      unverified <- askReset r "editor"
      unverified.status `shouldBe` 204
      threadDelay 300_000
      length <$> readIORef r.outbox `shouldReturn` 1
      verify <- maybe (panic "no link") pure =<< linkIn r "https://wiki.example.org/verify-email/"
      (.status) <$> send r methodPost (onPublic r (links.emailVerification (MailToken verify))) [] "" `shouldReturn` 204
      known <- askReset r "editor"
      unknown <- askReset r "nobody"
      (known.status, known.body) `shouldBe` (unknown.status, unknown.body)
      eventually ((== 2) . length <$> readIORef r.outbox)
      sent <- readIORef r.outbox
      map (\m -> m.to) sent `shouldBe` ["edgar@example.org", "edgar@example.org"]
      token <- maybe (panic "no link") pure =<< linkIn r "https://wiki.example.org/reset-password/"
      show sent `shouldSatisfy` (not . T.isInfixOf token)
      -- By the verified address too, whatever its case.
      _ <- askReset r "EDGAR@example.org"
      eventually ((== 3) . length <$> readIORef r.outbox)
      (sendJson r methodPost (onPublic r (links.passwordReset.reset (MailToken token))) NewPasswordByMail {password = "short"} >>= jsonAs 400)
        >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
      (.status) <$> sendJson r methodPost (onPublic r (links.passwordReset.reset (MailToken token))) NewPasswordByMail {password = "a brand new password"} `shouldReturn` 204
      -- Everyone who was signed in is signed out, and nobody is signed in.
      me :: SessionInfo <- getUrlWith r (onPublic r links.session) [cookie t] >>= jsonAs 200
      me.user `shouldBe` Nothing
      (sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"} >>= jsonAs 401) `shouldReturn` Unauthenticated
      _ <- signInAs r "editor" "a brand new password"
      -- Used: neither it nor the other link mailed since works.
      (sendJson r methodPost (onPublic r (links.passwordReset.reset (MailToken token))) NewPasswordByMail {password = "another new password"} >>= jsonAs 404) `shouldReturn` NotFound
      other <- maybe (panic "no link") pure =<< latestLink r "https://wiki.example.org/reset-password/"
      (sendJson r methodPost (onPublic r (links.passwordReset.reset (MailToken other))) NewPasswordByMail {password = "another new password"} >>= jsonAs 404) `shouldReturn` NotFound

  it "is limited per address it is asked from" $ withDemoRunning identity $ \r -> do
    mailing r
    replicateM_ 10 (askReset r "nobody" >>= \reply -> reply.status `shouldBe` 204)
    reply <- askReset r "nobody"
    reply.status `shouldBe` 429
    header "Retry-After" reply `shouldSatisfy` maybe False (BC.all isDigit)

  it "and an address's verification are open to someone not signed in, in a closed wiki" $ withDemoRunning identity $ \r -> do
    mailing r
    _ <- sendJson r methodPut (onAdmin r links.admin.setSettings) defaultSettings {access = Closed} >>= jsonAs @WikiSettings 200
    (.status) <$> askReset r "editor" `shouldReturn` 204
    (send r methodPost (onPublic r (links.emailVerification (MailToken "nothing"))) [] "" >>= jsonAs 404) `shouldReturn` NotFound
    (.status) <$> getUrl r (onPublic r links.account.sessions) `shouldReturn` 401

--------------------------------------------------------------------------------

-- | A storage in a directory of its own, with a user who has a verified
-- address.
withVerified :: (Storage -> UserId -> IO a) -> IO a
withVerified action = withSystemTempDirectory "wiki-hygiene-test" $ \dir -> withStorage defaultConfig (dir </> "data") $ \st -> do
  ada <- createAccount st "ada" "Ada" (Just "correct horse") >>= either (panic . show) pure
  now <- getCurrentTime
  Right (Just (_, token)) <- setEmail st now ada.user.id "ada@example.org"
  verifyEmail st now (MailToken token) `shouldReturn` Right ()
  action st ada.user.id

storageRules :: Spec
storageRules = describe "the storage's rules" $ do
  it "a reset's link works for thirty minutes" $ withVerified $ \st _ -> do
    now <- getCurrentTime
    [early, late] <- (<>) <$> requestReset st now "ada" <*> requestReset st now "ada"
    resetPassword st (addUTCTime (31 * 60) now) (MailToken late.token) "a new password" `shouldReturn` Left WikiError.NotFound
    resetPassword st (addUTCTime (29 * 60) now) (MailToken early.token) "a new password" `shouldReturn` Right ()

  it "an account is mailed three an hour at most, and a disabled or unverified one none" $ withVerified $ \st u -> do
    now <- getCurrentTime
    made <- concat <$> replicateM 5 (requestReset st now "ada")
    length made `shouldBe` 3
    later' <- requestReset st (addUTCTime (61 * 60) now) "ada"
    length later' `shouldBe` 1
    _ <- setEmail st now u "ada@example.com"
    length <$> requestReset st (addUTCTime (2 * 61 * 60) now) "ada" `shouldReturn` 0

  it "\"last seen\" is written at most once a minute, with the address, and the cookie sent again only hourly" $ withVerified $ \st u -> do
    now <- getCurrentTime
    Right (_, token) <- signIn st now "10.0.0.1" "ada" "correct horse"
    let seen = withDatabase st (\c -> query c "SELECT last_seen_at, address FROM sessions WHERE user_id = ?" (Only u.text)) :: IO [(Text, Text)]
    seenFirst <- seen
    resolveSession st (addUTCTime 30 now) "10.0.0.2" token `shouldReturn` Just Resolved {user = u, refreshed = False}
    seen `shouldReturn` seenFirst
    resolveSession st (addUTCTime (seenEvery + 1) now) "10.0.0.2" token `shouldReturn` Just Resolved {user = u, refreshed = False}
    map snd <$> seen `shouldReturn` ["10.0.0.2"]
    (map fst <$> seen) >>= (`shouldNotBe` map fst seenFirst)

-- | The secret of the latest link mailed that starts so.
latestLink :: Running -> Text -> IO (Maybe Text)
latestLink r prefix = do
  sent <- readIORef r.outbox
  pure (head [T.dropEnd 1 (T.drop (T.length prefix) w) | m <- sent, w <- T.words m.body, prefix `T.isPrefixOf` w])
