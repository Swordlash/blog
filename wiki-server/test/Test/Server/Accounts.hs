-- | Who is asking, over real HTTP: signing in and out on the public
-- listener, the session's cookie, the rules each principal is held to, the
-- administrator of the admin listener, and the checks that keep other
-- sites' pages and guessers out (decisions 8, 11 and 20 of docs/PLAN.md).
--
-- The demo's wiki is the server's: Blog and Docs public, Team private; the
-- editor edits Blog through their group, the reader views Team's Projects,
-- the admin holds the global administer. None of them has a password until
-- the administrator gives them one, on the admin listener, without a
-- cookie, as the console or the panel would.
--
-- A user signed in changes their own password (WP3.7 of docs/PLAN.md),
-- giving the one they have; wrong ones count as failed sign-ins.
module Test.Server.Accounts (spec) where

import Crypto.OPAQUE qualified as O
import Data.Aeson
  ( ToJSON
  , encode
  )
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (runUpdate, update, val_, (<-.), (==.))
import Network.HTTP.Types (Header, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Protolude
import Test.Database (Backing, placeOptionsOf, withConnectionTo)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AccountApi (..), AdminApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account
  ( Account (..)
  , AccountDisabled (..)
  , Credentials (..)
  , NewAccount (..)
  , SignInMethods (..)
  )
import Wiki.Api.Admin (Directory (..), ServerStatus (..), WikiSettings (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Opaque (LoginChallenge (..), LoginFinish (..), LoginStart (..), Message (..), NewAccountRecord (..), PasswordRecordChange (..), RegistrationFor (..), Stretch (..), bytesOf, messageOf)
import Wiki.Api.Types (NewPage (..), NewSpace (..), PersonalSpaceSwitch (..), SessionInfo (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (SpaceId, UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Login (..), Password (..), Standing (..), User (..))
import Wiki.Server.Console (Users (..), UsersCommand (..), runUsers)
import Wiki.Server.Opaque (loadServerSetup, registerHere)
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Password (hashWith, parameters)
import Wiki.Server.Storage (reading, withStorageAside, writing)
import Wiki.Server.Storage.Backend (withTransaction)
import Wiki.Server.Storage.Migrate.Code.Step0015 (step0015)
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))
import Wiki.Server.Storage.Rows (IdentityRow (..), identityOf, insertIdentity, storeRecord)
import Wiki.Server.Storage.Schema (Users (..), WikiDb (..), wikiDb)

spec :: Backing -> Spec
spec backing = describe "accounts over HTTP" $ do
  signingIn backing
  rules backing
  administration backing
  endings backing
  ownPassword backing
  opaque backing
  pages backing
  guards backing
  renamedLogins backing

-- | An address of the API on a listener.
onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | Who the public listener takes a request with this cookie for.
sessionWith :: Running -> [Header] -> IO (SessionInfo, Reply)
sessionWith r hs = do
  reply <- getUrlWith r (onPublic r links.session) hs
  (,reply) <$> jsonAs 200 reply

-- | The demo with passwords for the editor and the admin.
withPasswords :: Backing -> (ServeOptions -> ServeOptions) -> (Running -> IO a) -> IO a
withPasswords backing change test = withDemoRunning backing change $ \r -> do
  givePassword r "user-editor" "editor's password"
  givePassword r "user-admin" "admin's password"
  test r

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

spaceAt :: Running -> [Header] -> Text -> IO Reply
spaceAt r hs path = getUrlWith r (onPublic r (links.spaces.atPath (slugs path))) hs

spaceIdAt :: Running -> [Header] -> Text -> IO SpaceId
spaceIdAt r hs path = (\(s :: Space) -> s.id) <$> (spaceAt r hs path >>= jsonAs 200)

newPage :: Running -> [Header] -> SpaceId -> IO Reply
newPage r hs sid = send r methodPost (onPublic r (links.spaces.createPage sid)) ((hContentType, "application/json") : hs) (encode NewPage {parent = Nothing, title = "From a session", body = "Hello.", kind = Kind.Document})

signingIn :: Backing -> Spec
signingIn backing = describe "signing in" $ do
  it "answers with the session, and a cookie that is HttpOnly, SameSite=Strict, at the base path, for two weeks" $ withPasswords backing identity $ \r -> do
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's password"
    info :: SessionInfo <- jsonAs 200 reply
    ((\u -> u.login.text) <$> info.user, info.standing) `shouldBe` (Just "editor", SignedIn)
    (snd <$> setCookie reply) `shouldBe` Just ["Path=/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict"]
    token <- maybe (panic "no cookie") (pure . fst) (setCookie reply)
    (me, _) <- sessionWith r [cookie token]
    ((\u -> u.displayName) <$> me.user, me.standing) `shouldBe` (Just "Edgar Editor", SignedIn)

  it "marks the cookie Secure under --secure-cookies, and sets it below the base path" $
    withPasswords backing (\o -> o {secureCookies = True, basePath = "/wiki/"}) $ \r -> do
      reply <- passwordSignIn r (\l -> r.public <> "/wiki/" <> l) [] "editor" "editor's password"
      (snd <$> setCookie reply) `shouldBe` Just ["Path=/wiki/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict", "Secure"]

  it "refuses a wrong password, an unknown login and a login without a password alike, with a 401" $ withPasswords backing identity $ \r -> do
    for_ [("editor", "wrong"), ("nobody", "editor's password"), ("reader", "")] $ \(login, password) -> do
      reply <- passwordSignIn r (onPublic r) [] login password
      jsonAs 401 reply `shouldReturn` Unauthenticated
      setCookie reply `shouldBe` Nothing

  it "refuses a login tried too often from an address with a 429, even with the right password" $ withPasswords backing identity $ \r -> do
    replicateM_ 5 $ passwordSignIn r (onPublic r) [] "editor" "guess"
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's password"
    reply.status `shouldBe` 429
    (json reply :: IO ApiError) >>= (`shouldSatisfy` \case TooManyRequests why -> "try again in" `T.isInfixOf` why; _ -> False)
    header "Retry-After" reply `shouldSatisfy` maybe False (BC.all isDigit)
    -- Another login is not held to the editor's failures.
    _ <- signInAs r "admin" "admin's password"
    pass

  it "replaces the session the browser had" $ withPasswords backing identity $ \r -> do
    first' <- signInAs r "editor" "editor's password"
    reply <- passwordSignIn r (onPublic r) [cookie first'] "admin" "admin's password"
    second' <- maybe (panic "no cookie") (pure . fst) (setCookie reply)
    (old, _) <- sessionWith r [cookie first']
    old.user `shouldBe` Nothing
    (new, _) <- sessionWith r [cookie second']
    (\u -> u.login.text) <$> new.user `shouldBe` Just "admin"

rules :: Backing -> Spec
rules backing = describe "each principal" $ do
  it "anonymous reads the public spaces and nothing else, and writes nothing" $ withPasswords backing identity $ \r -> do
    spaces :: [Space] <- getUrl r (onPublic r links.spaces.list) >>= jsonAs 200
    map (\s -> s.name) spaces `shouldBe` ["Blog", "Docs"]
    (.status) <$> spaceAt r [] "team" `shouldReturn` 404
    blog <- spaceIdAt r [] "blog"
    (.status) <$> newPage r [] blog `shouldReturn` 403
    (me, _) <- sessionWith r []
    (me.user, me.standing) `shouldBe` (Nothing, NotSignedIn)

  it "a user signed in writes where they are granted to, gets 403 elsewhere, and 404 where they may not look" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    blog <- spaceIdAt r [cookie token] "blog"
    docs <- spaceIdAt r [cookie token] "docs"
    made <- newPage r [cookie token] blog
    made.status `shouldBe` 201
    (\(p :: Page) -> p.title) <$> json made `shouldReturn` "From a session"
    (.status) <$> newPage r [cookie token] docs `shouldReturn` 403
    (.status) <$> spaceAt r [cookie token] "team" `shouldReturn` 404
    -- Nor does a cookie make anyone an administrator.
    (.status) <$> getUrlWith r (onPublic r links.admin.status) [cookie token] `shouldReturn` 403

  it "an administrator signed in may do everything, the administration included" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "admin" "admin's password"
    (.status) <$> spaceAt r [cookie token] "team" `shouldReturn` 200
    (.status) <$> getUrlWith r (onPublic r links.admin.status) [cookie token] `shouldReturn` 200

  it "an administrator creates spaces without a create-spaces grant of their own" $ withPasswords backing identity $ \r -> do
    -- The demo's administrator holds the global administer only.
    people :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    UserId "user-admin" `elem` toList people.creators `shouldBe` False
    token <- signInAs r "admin" "admin's password"
    made <- send r methodPost (onPublic r links.spaces.create) [(hContentType, "application/json"), cookie token] (encode NewSpace {parent = Nothing, name = "Made by Ada"})
    made.status `shouldBe` 201

administration :: Backing -> Spec
administration backing = describe "the administrator on the admin listener" $ do
  it "needs no cookie, and takes none: the operator is whoever reaches it" $ withPasswords backing identity $ \r -> do
    _ :: ServerStatus <- getUrl r (onAdmin r links.admin.status) >>= jsonAs 200
    editor <- signInAs r "editor" "editor's password"
    me :: SessionInfo <- getUrlWith r (onAdmin r links.session) [cookie editor] >>= jsonAs 200
    ((\u -> u.login.text) <$> me.user, me.standing) `shouldBe` (Just "administrator", Operator)
    (.status) <$> passwordSignIn r (onAdmin r) [] "editor" "editor's password" `shouldReturn` 400

  it "makes a user with a password, who signs in on the public listener" $ withPasswords backing identity $ \r -> do
    made :: Account <- createUser r (onAdmin r) [] NewAccount {login = "bea", displayName = "Bea", password = Password "bea's password", email = Nothing} >>= jsonAs 201
    (made.user.login.text, made.hasPassword, made.disabled) `shouldBe` ("bea", True, False)
    token <- signInAs r "bea" "bea's password"
    (me, _) <- sessionWith r [cookie token]
    (\u -> u.id) <$> me.user `shouldBe` Just made.user.id
    again <- createUser r (onAdmin r) [] NewAccount {login = "BEA", displayName = "", password = Password "another password", email = Nothing}
    (json again :: IO ApiError) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    -- The record is the password as the server stores it; no hash is kept.
    legacyPasswords r `shouldReturn` 0

  -- WP5.18 of docs/PLAN.md: a wiki may leave accounts with a password to
  -- the server's console. The setting is kept in the database, so it
  -- holds across a restart, and the console is never refused.
  it "leaves accounts with a password to the console while the wiki's settings say so, across a restart" $
    withDemoRestarted
      backing
      ( \r -> do
          settings :: WikiSettings <- getUrl r (onAdmin r links.admin.settings) >>= jsonAs 200
          settings.adminCreatesPasswordAccounts `shouldBe` True
          _ :: Account <- createUser r (onAdmin r) [] (newAccount "bea") >>= jsonAs 201
          answered :: WikiSettings <- sendJson r methodPut (onAdmin r links.admin.setSettings) consoleOnly >>= jsonAs 200
          answered `shouldBe` consoleOnly
          (createUser r (onAdmin r) [] (newAccount "cid") >>= jsonAs 403) `shouldReturn` Forbidden
          -- Refused before the address is looked at.
          (sendJson r methodPost (onAdmin r links.admin.createUser) NewAccountRecord {login = "cid", displayName = "", password = noRecord, email = Just "not an address"} >>= jsonAs 403) `shouldReturn` Forbidden
          -- An administrator signed in on the public listener is refused the same.
          givePassword r "user-admin" "admin's password"
          admin <- signInAs r "admin" "admin's password"
          reply <- createUser r (onPublic r) [cookie admin] (newAccount "cid")
          jsonAs 403 reply `shouldReturn` Forbidden
          -- An existing user is given a password as before.
          givePassword r "user-editor" "editor's password"
      )
      ( \() again -> do
          (getUrl again (onAdmin again links.admin.settings) >>= jsonAs 200) `shouldReturn` consoleOnly
          (createUser again (onAdmin again) [] (newAccount "cid") >>= jsonAs 403) `shouldReturn` Forbidden
          users :: Directory <- getUrl again (onAdmin again links.admin.directory) >>= jsonAs 200
          users.adminCreatesPasswordAccounts `shouldBe` False
          map (\u -> u.login.text) users.users `shouldBe` ["admin", "bea", "editor", "reader"]
          -- The console makes the account, which signs in.
          made <- runUsers (const (pure (Right (Password "cid's password")))) Users {place = placeOptionsOf again.place, command = AddUser "cid" Nothing False True}
          made `shouldSatisfy` isRight
          _ <- signInAs again "cid" "cid's password"
          -- Turned on again, the administration makes accounts again.
          _ :: WikiSettings <- sendJson again methodPut (onAdmin again links.admin.setSettings) WikiSettings {access = Open, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True} >>= jsonAs 200
          _ :: Account <- createUser again (onAdmin again) [] (newAccount "dee") >>= jsonAs 201
          pass
      )

  it "is refused the account operations on the public listener unless an administrator is signed in" $ withPasswords backing identity $ \r -> do
    let attempt hs = send r methodPut (onPublic r (links.admin.setDisabled (UserId "user-reader"))) ((hContentType, "application/json") : hs) (encode AccountDisabled {disabled = True})
    (.status) <$> attempt [] `shouldReturn` 403
    editor <- signInAs r "editor" "editor's password"
    (.status) <$> attempt [cookie editor] `shouldReturn` 403
    admin <- signInAs r "admin" "admin's password"
    (attempt [cookie admin] >>= jsonAs 200) >>= \(a :: Account) -> a.disabled `shouldBe` True
    (.status) <$> sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "nobody"))) AccountDisabled {disabled = True} `shouldReturn` 404

-- | A user to make, with this login and a password.
newAccount :: Text -> NewAccount
newAccount login = NewAccount {login, displayName = "", password = Password (login <> "'s password"), email = Nothing}

-- | The wiki's settings with accounts with a password left to the console.
consoleOnly :: WikiSettings
consoleOnly = WikiSettings {access = Open, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = False}

endings :: Backing -> Spec
endings backing = describe "a session" $ do
  it "ends when its user signs out, and the cookie is cleared" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    reply <- send r methodDelete (onPublic r links.signOut) [cookie token] ""
    info :: SessionInfo <- jsonAs 200 reply
    (info.user, info.standing) `shouldBe` (Nothing, NotSignedIn)
    setCookie reply `shouldBe` Just ("", ["Path=/", "Max-Age=0", "HttpOnly", "SameSite=Strict"])
    (me, _) <- sessionWith r [cookie token]
    me.user `shouldBe` Nothing

  it "ends when its user is disabled: the next request is nobody's, and clears the cookie" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    blog <- spaceIdAt r [cookie token] "blog"
    _ :: Account <- sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "user-editor"))) AccountDisabled {disabled = True} >>= jsonAs 200
    (me, reply) <- sessionWith r [cookie token]
    (me.user, me.standing) `shouldBe` (Nothing, NotSignedIn)
    setCookie reply `shouldBe` Just ("", ["Path=/", "Max-Age=0", "HttpOnly", "SameSite=Strict"])
    (.status) <$> newPage r [cookie token] blog `shouldReturn` 403
    -- Still one of the wiki's people, in the administration's directory.
    people :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    map (\u -> u.login.text) people.users `shouldContain` ["editor"]
    -- Enabled again, they sign in again; the old session stays ended.
    _ :: Account <- sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "user-editor"))) AccountDisabled {disabled = False} >>= jsonAs 200
    (stale, _) <- sessionWith r [cookie token]
    stale.user `shouldBe` Nothing
    _ <- signInAs r "editor" "editor's password"
    pass

  it "ends when its user is given a new password" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    givePassword r "user-editor" "a new password"
    (me, _) <- sessionWith r [cookie token]
    me.user `shouldBe` Nothing
    (.status) <$> passwordSignIn r (onPublic r) [] "editor" "editor's password" `shouldReturn` 401
    _ <- signInAs r "editor" "a new password"
    pass

  it "is nobody's when the cookie names none, and that cookie is cleared" $ withPasswords backing identity $ \r -> do
    for_ [T.replicate 43 "A", "not-a-session-id"] $ \token -> do
      (me, reply) <- sessionWith r [cookie token]
      me.user `shouldBe` Nothing
      (fst <$> setCookie reply) `shouldBe` Just ""
    (_, plain) <- sessionWith r []
    setCookie plain `shouldBe` Nothing

-- | A change of one's own password, with the cookie of the session it is
-- made from.
changing :: Running -> Text -> Maybe Text -> Text -> IO Reply
changing r token current new = do
  -- As the application does: the current password proved through OPAQUE
  -- first, and sent only when that fails.
  proved <- case current of
    Nothing -> pure False
    Just c -> (\x -> x.status == 204) <$> provePassword r (onPublic r) [cookie token] c
  withRecord r (onPublic r) [cookie token] ForOwnPassword new $ \record ->
    send r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json"), cookie token] (encode PasswordRecordChange {current = if proved then Nothing else Password <$> current, password = record, vault = Nothing})

-- | A PUT with a JSON body and these headers.
sendJson' :: (ToJSON a) => Running -> Text -> [Header] -> a -> IO Reply
sendJson' r url hs value = send r methodPut url ((hContentType, "application/json") : hs) (encode value)

-- | Create a user as the application does, through the API at the
-- addresses the function gives: the reply. A registration that is refused
-- is the reply.
createUser :: Running -> (Text -> Text) -> [Header] -> NewAccount -> IO Reply
createUser r at hs new =
  withRecord r at hs ForNewUser new.password.text $ \record ->
    send r methodPost (at links.admin.createUser) ((hContentType, "application/json") : hs) (encode NewAccountRecord {login = new.login, displayName = new.displayName, password = record, email = new.email})

-- | How many users have a password hash from before OPAQUE, as the
-- administration's Overview says.
legacyPasswords :: Running -> IO Int
legacyPasswords r = (\(status :: ServerStatus) -> status.legacyPasswords) <$> (getUrl r (onAdmin r links.admin.status) >>= jsonAs 200)

ownPassword :: Backing -> Spec
ownPassword backing = describe "one's own password" $ do
  it "is changed with the current one: the other sessions end, this one stays" $ withPasswords backing identity $ \r -> do
    here <- signInAs r "editor" "editor's password"
    elsewhere <- signInAs r "editor" "editor's password"
    methods :: SignInMethods <- changing r here (Just "editor's password") "a longer new password" >>= jsonAs 200
    methods.password `shouldBe` True
    (me, _) <- sessionWith r [cookie here]
    (\u -> u.login.text) <$> me.user `shouldBe` Just "editor"
    (other, _) <- sessionWith r [cookie elsewhere]
    other.user `shouldBe` Nothing
    (.status) <$> passwordSignIn r (onPublic r) [] "editor" "editor's password" `shouldReturn` 401
    _ <- signInAs r "editor" "a longer new password"
    -- Another user's sessions are not touched.
    admin <- signInAs r "admin" "admin's password"
    _ <- changing r here (Just "a longer new password") "and another one"
    (stillAdmin, _) <- sessionWith r [cookie admin]
    (\u -> u.login.text) <$> stillAdmin.user `shouldBe` Just "admin"

  it "is refused without the current one, or with a wrong one, with a 401, and nothing changes" $ withPasswords backing identity $ \r -> do
    here <- signInAs r "editor" "editor's password"
    for_ [Nothing, Just "not my password"] $ \current ->
      changing r here current "a longer new password" >>= jsonAs 401 >>= (`shouldBe` Unauthenticated)
    (me, _) <- sessionWith r [cookie here]
    (\u -> u.login.text) <$> me.user `shouldBe` Just "editor"
    _ <- signInAs r "editor" "editor's password"
    pass

  it "counts wrong current ones as failed sign-ins of the login from the address" $ withPasswords backing identity $ \r -> do
    here <- signInAs r "editor" "editor's password"
    replicateM_ 5 (changing r here (Just "a guess") "a longer new password")
    held <- changing r here (Just "editor's password") "a longer new password"
    held.status `shouldBe` 429
    (json held :: IO ApiError) >>= (`shouldSatisfy` \case TooManyRequests why -> "try again in" `T.isInfixOf` why; _ -> False)
    header "Retry-After" held `shouldSatisfy` maybe False (BC.all isDigit)
    -- The same count as signing in.
    (.status) <$> passwordSignIn r (onPublic r) [] "editor" "editor's password" `shouldReturn` 429
    -- Another user's is their own.
    admin <- signInAs r "admin" "admin's password"
    (.status) <$> changing r admin (Just "admin's password") "a longer new password" `shouldReturn` 200

  it "is no one's to change who is not signed in, nor the operator's, nor without the application's header" $ withPasswords backing identity $ \r -> do
    let body = encode PasswordRecordChange {current = Nothing, password = noRecord, vault = Nothing}
    nobody <- send r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json")] body
    jsonAs 401 nobody `shouldReturn` Unauthenticated
    operator <- send r methodPut (onAdmin r links.account.changePassword) [(hContentType, "application/json")] body
    operator.status `shouldBe` 400
    here <- signInAs r "editor" "editor's password"
    bare <- sendBare r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json"), cookie here] (encode PasswordRecordChange {current = Just (Password "editor's password"), password = noRecord, vault = Nothing})
    bare.status `shouldBe` 403
    _ <- signInAs r "editor" "editor's password"
    pass

-- | Give a user a password hash from before OPAQUE in place of their
-- record, as an older server stored it: what a database from before
-- WP5.74a holds.
legacyAccount :: Running -> Text -> Text -> IO ()
legacyAccount r uid password = withStorageAside r.place $ \st ->
  writing st $
    runUpdate
      ( update
          wikiDb.users
          (\x -> mconcat [x.password_hash <-. val_ (Just (hashWith parameters "a salt of mine" (Password password))), x.opaque_record <-. val_ Nothing, x.opaque_stretch <-. val_ Nothing])
          (\x -> x.id ==. val_ uid)
      )

-- | The server's answer to a sign-in's first message for a login.
challengeFor :: Running -> Text -> Text -> IO LoginChallenge
challengeFor r login password = do
  (_, ke1) <- either (panic . show) pure =<< O.clientStart (encodeUtf8 password)
  sendJson r methodPost (onPublic r links.startPasswordSignIn) LoginStart {login, ke1 = messageOf (O.encode ke1)} >>= jsonAs 200

opaque :: Backing -> Spec
opaque backing = describe "passwords through OPAQUE" $ do
  it "answers a login nobody has, and one without a password, in the shape of a real one" $ withPasswords backing identity $ \r -> do
    real <- challengeFor r "editor" "editor's password"
    for_ ["nobody", "reader"] $ \login -> do
      fake <- challengeFor r login "editor's password"
      (T.length fake.ke2.text, fake.stretch, fake.fallback, T.length fake.attempt) `shouldBe` (T.length real.ke2.text, real.stretch, real.fallback, T.length real.attempt)
      -- Its answer cannot be finished, whatever is sent.
      reply <- sendJson r methodPut (onPublic r links.finishPasswordSignIn) LoginFinish {attempt = fake.attempt, ke3 = Message (T.replicate 86 "A")}
      jsonAs 401 reply `shouldReturn` Unauthenticated
    -- Each start of a sign-in counts against the limit until it finishes.
    replicateM_ 4 (challengeFor r "nobody" "a guess")
    (.status) <$> sendJson r methodPost (onPublic r links.startPasswordSignIn) LoginStart {login = "nobody", ke1 = real.ke2} `shouldReturn` 429

  it "refuses a last message that was tampered with, and uses the attempt up" $ withPasswords backing identity $ \r -> do
    (st, ke1) <- either (panic . show) pure =<< O.clientStart "editor's password"
    challenge :: LoginChallenge <- sendJson r methodPost (onPublic r links.startPasswordSignIn) LoginStart {login = "editor", ke1 = messageOf (O.encode ke1)} >>= jsonAs 200
    ke3 <- maybe (panic "no last message") pure (clientLast st challenge)
    let tampered = maybe ke3 (\b -> messageOf (BS.take 10 b <> BS.singleton (complement (BS.index b 10)) <> BS.drop 11 b)) (bytesOf ke3)
    (sendJson r methodPut (onPublic r links.finishPasswordSignIn) LoginFinish {attempt = challenge.attempt, ke3 = tampered} >>= jsonAs 401) `shouldReturn` Unauthenticated
    (sendJson r methodPut (onPublic r links.finishPasswordSignIn) LoginFinish {attempt = challenge.attempt, ke3} >>= jsonAs 401) `shouldReturn` Unauthenticated
    -- A fresh attempt with the right message signs in.
    _ <- signInAs r "editor" "editor's password"
    pass

  it "refuses a last message sent again after it signed in" $ withPasswords backing identity $ \r -> do
    (st, ke1) <- either (panic . show) pure =<< O.clientStart "editor's password"
    challenge :: LoginChallenge <- sendJson r methodPost (onPublic r links.startPasswordSignIn) LoginStart {login = "editor", ke1 = messageOf (O.encode ke1)} >>= jsonAs 200
    ke3 <- maybe (panic "no last message") pure (clientLast st challenge)
    let finish = sendJson r methodPut (onPublic r links.finishPasswordSignIn) LoginFinish {attempt = challenge.attempt, ke3}
    signedIn <- finish
    signedIn.status `shouldBe` 200
    isJust (setCookie signedIn) `shouldBe` True
    -- The same message again, as someone who saw it would send it.
    replayed <- finish
    jsonAs 401 replayed `shouldReturn` Unauthenticated
    setCookie replayed `shouldBe` Nothing

  it "refuses a last message whose exchange started before the password changed" $ withPasswords backing identity $ \r -> do
    -- Someone who knows the old password starts a sign-in and keeps its
    -- last message while the password is reset.
    (st, ke1) <- either (panic . show) pure =<< O.clientStart "editor's password"
    challenge :: LoginChallenge <- sendJson r methodPost (onPublic r links.startPasswordSignIn) LoginStart {login = "editor", ke1 = messageOf (O.encode ke1)} >>= jsonAs 200
    ke3 <- maybe (panic "no last message") pure (clientLast st challenge)
    givePassword r "user-editor" "editor's new password"
    late <- sendJson r methodPut (onPublic r links.finishPasswordSignIn) LoginFinish {attempt = challenge.attempt, ke3}
    jsonAs 401 late `shouldReturn` Unauthenticated
    setCookie late `shouldBe` Nothing
    _ <- signInAs r "editor" "editor's new password"
    pass

  it "lets an account from before OPAQUE in with its right password after four wrong ones" $ withPasswords backing identity $ \r -> do
    legacyAccount r "user-editor" "editor's old password"
    let tryOldWay password = do
          c <- challengeFor r "editor" password
          sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password password, attempt = Just c.attempt}
    replicateM_ 4 (tryOldWay "a wrong password" >>= jsonAs 401 >>= (`shouldBe` Unauthenticated))
    -- The fifth start was admitted and counted; the old way finishes it.
    (.status) <$> tryOldWay "editor's old password" `shouldReturn` 200

  it "gives back the start of each old-way sign-in that signs in, so that an address's many right sign-ins are never refused" $ withPasswords backing identity $ \r -> do
    legacyAccount r "user-editor" "editor's old password"
    -- One more than an address's limit of failures: each start through
    -- OPAQUE is counted as one, until the old way signs in.
    for_ [1 .. 31 :: Int] $ \_ ->
      (.status) <$> passwordSignIn r (onPublic r) [] "editor" "editor's old password" `shouldReturn` 200

  it "stores a record and no hash for every way a password is set, and each signs in" $ withPasswords backing identity $ \r -> do
    -- The administrator's new user, and new password for a user.
    _ :: Account <- createUser r (onAdmin r) [] (newAccount "bea") >>= jsonAs 201
    _ <- signInAs r "bea" "bea's password"
    givePassword r "user-reader" "reader's new password"
    _ <- signInAs r "reader" "reader's new password"
    -- One's own change.
    here <- signInAs r "editor" "editor's password"
    _ :: SignInMethods <- changing r here (Just "editor's password") "editor's new password" >>= jsonAs 200
    _ <- signInAs r "editor" "editor's new password"
    -- One's own account, in an open wiki.
    made <- withRecord r (onPublic r) [] ForSignUp "cid's password" $ \record ->
      sendJson r methodPost (onPublic r links.register) NewAccountRecord {login = "cid", displayName = "", password = record, email = Nothing}
    made.status `shouldBe` 200
    _ <- signInAs r "cid" "cid's password"
    legacyPasswords r `shouldReturn` 0
    -- None of them falls back to sending the password.
    challenge <- challengeFor r "cid" "cid's password"
    challenge.fallback `shouldBe` False

  it "refuses a record made for another account" $ withPasswords backing identity $ \r -> do
    record <- passwordRecord r (onAdmin r) [] (ForUser (UserId "user-reader")) "a password for reader"
    (sendJson r methodPut (onAdmin r (links.admin.setPassword (UserId "user-editor"))) record >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)

  it "moves an account from before OPAQUE at its first sign-in, and then signs in through OPAQUE alone" $ withPasswords backing identity $ \r -> do
    elsewhere <- signInAs r "editor" "editor's password"
    legacyAccount r "user-editor" "editor's old password"
    legacyPasswords r `shouldReturn` 1
    -- While it is left, a failed sign-in is tried the old way.
    (challengeFor r "admin" "anything") >>= (`shouldBe` True) . (\c -> c.fallback)
    -- The old way answers an account with a record as a wrong password.
    (sendJson r methodPost (onPublic r links.signIn) Credentials {login = "admin", password = Password "admin's password", attempt = Nothing} >>= jsonAs 401) `shouldReturn` Unauthenticated
    -- The editor signs in the old way, with a proof of the password left
    -- on the session, which registers the record without the password.
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's old password"
    token <- maybe (panic ("not signed in: " <> show reply)) (pure . fst) (setCookie reply)
    record <- passwordRecord r (onPublic r) [cookie token] ForOwnPassword "editor's old password"
    _ :: SignInMethods <- sendJson' r (onPublic r links.account.changePassword) [cookie token] PasswordRecordChange {current = Nothing, password = record, vault = Nothing} >>= jsonAs 200
    legacyPasswords r `shouldReturn` 0
    -- The move keeps the account's other sessions: its password is the same.
    (still, _) <- sessionWith r [cookie elsewhere]
    (\u -> u.login.text) <$> still.user `shouldBe` Just "editor"
    -- From now on through OPAQUE, and the old way is off.
    (challengeFor r "editor" "editor's old password") >>= (`shouldBe` False) . (\c -> c.fallback)
    _ <- signInAs r "editor" "editor's old password"
    (sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's old password", attempt = Nothing} >>= jsonAs 401) `shouldReturn` Unauthenticated

  it "answers the old sign-in alike for an account with a record, a login nobody has, and a wrong old password" $ withPasswords backing identity $ \r -> do
    -- One account from before OPAQUE keeps the old sign-in open.
    legacyAccount r "user-editor" "editor's old password"
    let oldWay login password = sendJson r methodPost (onPublic r links.signIn) Credentials {login, password = Password password, attempt = Nothing}
    withRecordRight <- oldWay "admin" "admin's password"
    nobody <- oldWay "nobody" "a guess"
    wrongOld <- oldWay "editor" "not the old password"
    let shape reply = (reply.status, reply.body, setCookie reply)
    shape withRecordRight `shouldBe` shape wrongOld
    shape nobody `shouldBe` shape wrongOld
    wrongOld.status `shouldBe` 401

  it "never lets the old password's proof replace a record the account has got meanwhile" $ withPasswords backing identity $ \r -> do
    legacyAccount r "user-editor" "editor's old password"
    -- Signed in the old way: the session holds a proof by the old password.
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's old password"
    token <- maybe (panic ("not signed in: " <> show reply)) (pure . fst) (setCookie reply)
    -- Meanwhile the account gets a record by another way, without its
    -- sessions ending.
    withStorageAside r.place $ \st -> writing st $ do
      setup <- loadServerSetup
      stored <- liftIO (registerHere setup Stretch {opsLimit = 1, memLimit = 8192} (UserId "user-editor") (Password "a password set elsewhere"))
      either (panic . show) (storeRecord (UserId "user-editor")) stored
    -- The migration path cannot overwrite it.
    record <- passwordRecord r (onPublic r) [cookie token] ForOwnPassword "the session's own choice"
    (sendJson' r (onPublic r links.account.changePassword) [cookie token] PasswordRecordChange {current = Nothing, password = record, vault = Nothing} >>= jsonAs 401) `shouldReturn` Unauthenticated
    _ <- signInAs r "editor" "a password set elsewhere"
    (.status) <$> passwordSignIn r (onPublic r) [] "editor" "the session's own choice" `shouldReturn` 401

  it "counts a wrong old password once when a session of an account from before OPAQUE proves it again" $ withPasswords backing identity $ \r -> do
    legacyAccount r "user-editor" "editor's old password"
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's old password"
    token <- maybe (panic ("not signed in: " <> show reply)) (pure . fst) (setCookie reply)
    -- Two wrong tries, each counted once, at its start.
    replicateM_ 2 ((.status) <$> provePassword r (onPublic r) [cookie token] "not the old password" `shouldReturn` 401)
    -- The right one is the third count, far from the limit; the change
    -- that needs it then takes the session's proof.
    (.status) <$> provePassword r (onPublic r) [cookie token] "editor's old password" `shouldReturn` 204
    record <- passwordRecord r (onPublic r) [cookie token] ForOwnPassword "editor's new password"
    _ :: SignInMethods <- sendJson' r (onPublic r links.account.changePassword) [cookie token] PasswordRecordChange {current = Nothing, password = record, vault = Nothing} >>= jsonAs 200
    _ <- signInAs r "editor" "editor's new password"
    pass

  it "ends the other sessions when an account from before OPAQUE changes its password after proving it again" $ withPasswords backing identity $ \r -> do
    legacyAccount r "user-editor" "editor's old password"
    elsewhereReply <- passwordSignIn r (onPublic r) [] "editor" "editor's old password"
    elsewhere <- maybe (panic "not signed in elsewhere") (pure . fst) (setCookie elsewhereReply)
    reply <- passwordSignIn r (onPublic r) [] "editor" "editor's old password"
    token <- maybe (panic ("not signed in: " <> show reply)) (pure . fst) (setCookie reply)
    -- Proved again in this session, then a new password: a real change,
    -- not the move of the same password that a sign-in's proof makes.
    (.status) <$> provePassword r (onPublic r) [cookie token] "editor's old password" `shouldReturn` 204
    record <- passwordRecord r (onPublic r) [cookie token] ForOwnPassword "editor's new password"
    _ :: SignInMethods <- sendJson' r (onPublic r links.account.changePassword) [cookie token] PasswordRecordChange {current = Nothing, password = record, vault = Nothing} >>= jsonAs 200
    (ended, _) <- sessionWith r [cookie elsewhere]
    ended.user `shouldBe` Nothing
    (kept, _) <- sessionWith r [cookie token]
    (\u -> u.login.text) <$> kept.user `shouldBe` Just "editor"

  it "lets a session prove its password again, once, for a change that needs it" $ withPasswords backing identity $ \r -> do
    here <- signInAs r "editor" "editor's password"
    (.status) <$> provePassword r (onPublic r) [cookie here] "not the password" `shouldReturn` 401
    (.status) <$> provePassword r (onPublic r) [cookie here] "editor's password" `shouldReturn` 204
    record <- passwordRecord r (onPublic r) [cookie here] ForOwnPassword "a newer password"
    let change = sendJson' r (onPublic r links.account.changePassword) [cookie here] PasswordRecordChange {current = Nothing, password = record, vault = Nothing}
    (.status) <$> change `shouldReturn` 200
    -- The proof is used up.
    (.status) <$> change `shouldReturn` 401

pages :: Backing -> Spec
pages backing = describe "the pages the server renders" $ do
  it "show a signed-in user as signed in from the first paint, carry them in the preload, and are private" $ withPasswords backing identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    reply <- getUrlWith r (r.public <> "/") [cookie token]
    reply.status `shouldBe` 200
    let html = decodeUtf8 (BSL.toStrict reply.body)
        app = fst (T.breakOn "<script" (snd (T.breakOn "<div id=\"app\">" html)))
    app `shouldSatisfy` T.isInfixOf ">Edgar Editor</button>"
    app `shouldSatisfy` T.isInfixOf "account-toggle"
    app `shouldSatisfy` T.isInfixOf "class=\"sign-out\""
    app `shouldNotSatisfy` T.isInfixOf "sign-in-toggle"
    html `shouldSatisfy` T.isInfixOf "\"standing\":\"SignedIn\""
    header "Cache-Control" reply `shouldBe` Just "private, no-cache"
    header "Vary" reply `shouldBe` Just "Cookie"
    -- A private space's page renders for whoever may see it, and is not
    -- found by anyone else.
    team <- getUrlWith r (r.public <> "/s/team/") [cookie token]
    team.status `shouldBe` 404
    admin <- signInAs r "admin" "admin's password"
    (.status) <$> getUrlWith r (r.public <> "/s/team/") [cookie admin] `shouldReturn` 200

  it "show nobody the way to sign in" $ withPasswords backing identity $ \r -> do
    reply <- getUrl r (r.public <> "/")
    let html = decodeUtf8 (BSL.toStrict reply.body)
    html `shouldSatisfy` T.isInfixOf "class=\"sign-in-toggle\""
    html `shouldSatisfy` T.isInfixOf "\"standing\":\"NotSignedIn\""

  it "answer the API privately too" $ withPasswords backing identity $ \r -> do
    reply <- getUrl r (onPublic r links.session)
    (header "Cache-Control" reply, header "Vary" reply) `shouldBe` (Just "private, no-cache", Just "Cookie")

guards :: Backing -> Spec
guards backing = describe "requests from other sites" $ do
  it "are refused when they change something without the application's header, on both listeners" $ withPasswords backing identity $ \r -> do
    let body = encode LoginStart {login = "editor", ke1 = Message "AAAA"}
    signIn <- sendBare r methodPost (onPublic r links.startPasswordSignIn) [(hContentType, "application/json")] body
    (signIn.status, setCookie signIn) `shouldBe` (403, Nothing)
    jsonAs 403 signIn `shouldReturn` Forbidden
    made <- sendBare r methodPost (onAdmin r links.admin.createUser) [(hContentType, "application/json")] (encode NewAccount {login = "eve", displayName = "", password = Password "eve's password", email = Nothing})
    made.status `shouldBe` 403
    -- Reading needs no header.
    (.status) <$> sendBare r methodGet (onPublic r links.session) [] "" `shouldReturn` 200

  it "are refused when the browser says they come from another site, header or not" $ withPasswords backing identity $ \r -> do
    reply <- passwordSignIn r (onPublic r) [("Sec-Fetch-Site", "cross-site")] "editor" "editor's password"
    reply.status `shouldBe` 403
    same <- passwordSignIn r (onPublic r) [("Sec-Fetch-Site", "same-origin")] "editor" "editor's password"
    same.status `shouldBe` 200

-- | WP5.87 of docs/PLAN.md: a login from before the rule of a login, which
-- step 15 of the schema renames ("Wiki.Server.Storage.Migrate.Code.Step0015").
-- The step is run by itself on the demo's database, between two servers,
-- as an upgrade runs it between the old server and the new one.
renamedLogins :: Backing -> Spec
renamedLogins backing = describe "a login step 15 of the schema renamed" $
  it "signs in with the same password under the new login, an OPAQUE record and a hash from before OPAQUE alike, and keeps its sessions, personal space and identity" $
    withDemoPlace backing $ \at serve -> do
      let setLogin :: Running -> Text -> Text -> IO ()
          setLogin r uid login = withStorageAside r.place $ \st -> writing st (runUpdate (update wikiDb.users (\x -> x.login <-. val_ login) (\x -> x.id ==. val_ uid)))
      (session, space) <- serve $ \r -> do
        givePassword r "user-editor" "editor's password"
        legacyAccount r "user-reader" "reader's old password"
        -- Logins made before the rule, as an older server kept them.
        setLogin r "user-editor" "łucja"
        setLogin r "user-reader" "żaneta"
        token <- signInAs r "łucja" "editor's password"
        turnedOn <- send r methodPut (onPublic r "api/v1/account/personal-space") [(hContentType, "application/json"), cookie token] (encode PersonalSpaceSwitch {enabled = True})
        space :: Space <- jsonAs 200 turnedOn
        now <- getCurrentTime
        withStorageAside r.place $ \st -> writing st (insertIdentity now (UserId "user-editor") "elsewhere" "subject-1" Nothing Nothing)
        pure (token, space)
      said <- withConnectionTo at $ \c -> withTransaction True c (case step0015 of CodeStep {run} -> run c)
      said
        `shouldBe` [ "Renamed the login \"łucja\" of the user user-editor to \"user-useredit\", since a login is now ASCII letters, digits and punctuation, with a letter or digit, at most 64 characters and not ~ first. The user signs in with the same password under the new login."
                   , "Renamed the login \"żaneta\" of the user user-reader to \"user-userread\", since a login is now ASCII letters, digits and punctuation, with a letter or digit, at most 64 characters and not ~ first. The user signs in with the same password under the new login."
                   ]
      serve $ \r -> do
        -- The session from before is the same user's, under the new login.
        (kept, _) <- sessionWith r [cookie session]
        ((\u -> (u.id, u.login)) <$> kept.user) `shouldBe` Just (UserId "user-editor", Login "user-useredit")
        -- The same passwords sign in under the new logins: an OPAQUE
        -- record, and a hash from before OPAQUE, which the sign-in moves
        -- to OPAQUE.
        token <- signInAs r "user-useredit" "editor's password"
        _ <- signInAs r "user-userread" "reader's old password"
        _ <- signInAs r "user-userread" "reader's old password"
        -- The old login names nobody.
        (.status) <$> passwordSignIn r (onPublic r) [] "łucja" "editor's password" `shouldReturn` 401
        -- The personal space is the user's, at its address.
        mine :: Maybe Space <- getUrlWith r (onPublic r "api/v1/account/personal-space") [cookie token] >>= jsonAs 200
        ((\s -> (s.id, s.slug, s.owner)) <$> mine) `shouldBe` Just (space.id, space.slug, Just (UserId "user-editor"))
        -- So is the identity at a provider.
        found <- withStorageAside r.place $ \st -> reading st (identityOf "elsewhere" "subject-1")
        ((\i -> i.user) <$> found) `shouldBe` Just (UserId "user-editor")
