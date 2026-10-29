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

import Data.Aeson (encode)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Network.HTTP.Types (Header, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Protolude
import Test.Database (Backing, placeOptionsOf)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AccountApi (..), AdminApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), NewAccount (..), PasswordChange (..), SignInMethods (..))
import Wiki.Api.Admin (Directory (..), ServerStatus, WikiSettings (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Types (NewPage (..), NewSpace (..), SessionInfo (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (SpaceId, UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Login (..), Password (..), Standing (..), User (..))
import Wiki.Server.Console (Users (..), UsersCommand (..), runUsers)
import Wiki.Server.Options (ServeOptions (..))

spec :: Backing -> Spec
spec backing = describe "accounts over HTTP" $ do
  signingIn backing
  rules backing
  administration backing
  endings backing
  ownPassword backing
  pages backing
  guards backing

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
newPage r hs sid = send r methodPost (onPublic r (links.spaces.createPage sid)) ((hContentType, "application/json") : hs) (encode NewPage {parent = Nothing, title = "From a session", body = "Hello."})

signingIn :: Backing -> Spec
signingIn backing = describe "signing in" $ do
  it "answers with the session, and a cookie that is HttpOnly, SameSite=Strict, at the base path, for two weeks" $ withPasswords backing identity $ \r -> do
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's password"}
    info :: SessionInfo <- jsonAs 200 reply
    ((\u -> u.login.text) <$> info.user, info.standing) `shouldBe` (Just "editor", SignedIn)
    (snd <$> setCookie reply) `shouldBe` Just ["Path=/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict"]
    token <- maybe (panic "no cookie") (pure . fst) (setCookie reply)
    (me, _) <- sessionWith r [cookie token]
    ((\u -> u.displayName) <$> me.user, me.standing) `shouldBe` (Just "Edgar Editor", SignedIn)

  it "marks the cookie Secure under --secure-cookies, and sets it below the base path" $
    withPasswords backing (\o -> o {secureCookies = True, basePath = "/wiki/"}) $ \r -> do
      reply <- sendJson r methodPost (r.public <> "/wiki/" <> links.signIn) Credentials {login = "editor", password = Password "editor's password"}
      (snd <$> setCookie reply) `shouldBe` Just ["Path=/wiki/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict", "Secure"]

  it "refuses a wrong password, an unknown login and a login without a password alike, with a 401" $ withPasswords backing identity $ \r -> do
    for_ [("editor", "wrong"), ("nobody", "editor's password"), ("reader", "")] $ \(login, password) -> do
      reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login, password = Password password}
      jsonAs 401 reply `shouldReturn` Unauthenticated
      setCookie reply `shouldBe` Nothing

  it "refuses a login tried too often from an address with a 429, even with the right password" $ withPasswords backing identity $ \r -> do
    replicateM_ 5 $ sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "guess"}
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's password"}
    reply.status `shouldBe` 429
    (json reply :: IO ApiError) >>= (`shouldSatisfy` \case TooManyRequests why -> "try again in" `T.isInfixOf` why; _ -> False)
    header "Retry-After" reply `shouldSatisfy` maybe False (BC.all isDigit)
    -- Another login is not held to the editor's failures.
    _ <- signInAs r "admin" "admin's password"
    pass

  it "replaces the session the browser had" $ withPasswords backing identity $ \r -> do
    first' <- signInAs r "editor" "editor's password"
    reply <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), cookie first'] (encode Credentials {login = "admin", password = Password "admin's password"})
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
    (.status) <$> sendJson r methodPost (onAdmin r links.signIn) Credentials {login = "editor", password = Password "editor's password"} `shouldReturn` 400

  it "makes a user with a password, who signs in on the public listener" $ withPasswords backing identity $ \r -> do
    made :: Account <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "bea", displayName = "Bea", password = Password "bea's password", email = Nothing} >>= jsonAs 201
    (made.user.login.text, made.hasPassword, made.disabled) `shouldBe` ("bea", True, False)
    token <- signInAs r "bea" "bea's password"
    (me, _) <- sessionWith r [cookie token]
    (\u -> u.id) <$> me.user `shouldBe` Just made.user.id
    again <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "BEA", displayName = "", password = Password "another password", email = Nothing}
    (json again :: IO ApiError) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    short <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "cid", displayName = "", password = Password "short", email = Nothing}
    short.status `shouldBe` 400

  -- WP5.18 of docs/PLAN.md: a wiki may leave accounts with a password to
  -- the server's console. The setting is kept in the database, so it
  -- holds across a restart, and the console is never refused.
  it "leaves accounts with a password to the console while the wiki's settings say so, across a restart" $
    withDemoRestarted
      backing
      ( \r -> do
          settings :: WikiSettings <- getUrl r (onAdmin r links.admin.settings) >>= jsonAs 200
          settings.adminCreatesPasswordAccounts `shouldBe` True
          _ :: Account <- sendJson r methodPost (onAdmin r links.admin.createUser) (newAccount "bea") >>= jsonAs 201
          answered :: WikiSettings <- sendJson r methodPut (onAdmin r links.admin.setSettings) consoleOnly >>= jsonAs 200
          answered `shouldBe` consoleOnly
          (sendJson r methodPost (onAdmin r links.admin.createUser) (newAccount "cid") >>= jsonAs 403) `shouldReturn` Forbidden
          -- Refused before the address is looked at.
          (sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "cid", displayName = "", password = Password "cid's password", email = Just "not an address"} >>= jsonAs 403) `shouldReturn` Forbidden
          -- An administrator signed in on the public listener is refused the same.
          givePassword r "user-admin" "admin's password"
          admin <- signInAs r "admin" "admin's password"
          reply <- send r methodPost (onPublic r links.admin.createUser) [(hContentType, "application/json"), cookie admin] (encode (newAccount "cid"))
          jsonAs 403 reply `shouldReturn` Forbidden
          -- An existing user is given a password as before.
          givePassword r "user-editor" "editor's password"
      )
      ( \() again -> do
          (getUrl again (onAdmin again links.admin.settings) >>= jsonAs 200) `shouldReturn` consoleOnly
          (sendJson again methodPost (onAdmin again links.admin.createUser) (newAccount "cid") >>= jsonAs 403) `shouldReturn` Forbidden
          users :: Directory <- getUrl again (onAdmin again links.admin.directory) >>= jsonAs 200
          users.adminCreatesPasswordAccounts `shouldBe` False
          map (\u -> u.login.text) users.users `shouldBe` ["admin", "bea", "editor", "reader"]
          -- The console makes the account, which signs in.
          made <- runUsers (const (pure (Right (Password "cid's password")))) Users {place = placeOptionsOf again.place, command = AddUser "cid" Nothing False True}
          made `shouldSatisfy` isRight
          _ <- signInAs again "cid" "cid's password"
          -- Turned on again, the administration makes accounts again.
          _ :: WikiSettings <- sendJson again methodPut (onAdmin again links.admin.setSettings) WikiSettings {access = Open, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True} >>= jsonAs 200
          _ :: Account <- sendJson again methodPost (onAdmin again links.admin.createUser) (newAccount "dee") >>= jsonAs 201
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
    (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's password"} `shouldReturn` 401
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
changing r token current new =
  send r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json"), cookie token] (encode PasswordChange {current = Password <$> current, new = Password new})

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
    (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's password"} `shouldReturn` 401
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
    (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = Password "editor's password"} `shouldReturn` 429
    -- Another user's is their own.
    admin <- signInAs r "admin" "admin's password"
    (.status) <$> changing r admin (Just "admin's password") "a longer new password" `shouldReturn` 200

  it "refuses a new one that cannot be a password, before looking at the current one" $ withPasswords backing identity $ \r -> do
    here <- signInAs r "editor" "editor's password"
    changing r here (Just "a guess") "short" >>= jsonAs 400 >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    -- Not counted as a guess.
    replicateM_ 4 (changing r here (Just "a guess") "a longer new password")
    (.status) <$> changing r here (Just "editor's password") "a longer new password" `shouldReturn` 200

  it "is no one's to change who is not signed in, nor the operator's, nor without the application's header" $ withPasswords backing identity $ \r -> do
    let body = encode PasswordChange {current = Nothing, new = Password "a longer new password"}
    nobody <- send r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json")] body
    jsonAs 401 nobody `shouldReturn` Unauthenticated
    operator <- send r methodPut (onAdmin r links.account.changePassword) [(hContentType, "application/json")] body
    operator.status `shouldBe` 400
    here <- signInAs r "editor" "editor's password"
    bare <- sendBare r methodPut (onPublic r links.account.changePassword) [(hContentType, "application/json"), cookie here] (encode PasswordChange {current = Just (Password "editor's password"), new = Password "a longer new password"})
    bare.status `shouldBe` 403
    _ <- signInAs r "editor" "editor's password"
    pass

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
    let body = encode Credentials {login = "editor", password = Password "editor's password"}
    signIn <- sendBare r methodPost (onPublic r links.signIn) [(hContentType, "application/json")] body
    (signIn.status, setCookie signIn) `shouldBe` (403, Nothing)
    jsonAs 403 signIn `shouldReturn` Forbidden
    made <- sendBare r methodPost (onAdmin r links.admin.createUser) [(hContentType, "application/json")] (encode NewAccount {login = "eve", displayName = "", password = Password "eve's password", email = Nothing})
    made.status `shouldBe` 403
    -- Reading needs no header.
    (.status) <$> sendBare r methodGet (onPublic r links.session) [] "" `shouldReturn` 200

  it "are refused when the browser says they come from another site, header or not" $ withPasswords backing identity $ \r -> do
    reply <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), ("Sec-Fetch-Site", "cross-site")] (encode Credentials {login = "editor", password = Password "editor's password"})
    reply.status `shouldBe` 403
    same <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), ("Sec-Fetch-Site", "same-origin")] (encode Credentials {login = "editor", password = Password "editor's password"})
    same.status `shouldBe` 200
