-- | Who is asking, over real HTTP: signing in and out on the public
-- listener, the session's cookie, the rules each principal is held to, the
-- administrator of the admin listener, and the checks that keep other
-- sites' pages and guessers out (decisions 8, 11, 19 and 20 of
-- docs/PLAN.md).
--
-- The demo's wiki is the server's: Blog and Docs public, Team private; the
-- editor edits Blog through their group, the reader views Team's Projects,
-- the admin holds the global administer. None of them has a password until
-- the administrator gives them one, on the admin listener, without a
-- cookie, as the console or the panel would.
module Test.Server.Accounts (spec) where

import Data.Aeson (encode)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Network.HTTP.Types (Header, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Protolude
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), NewAccount (..), NewPassword (..))
import Wiki.Api.Admin (Directory (..), ServerStatus)
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.Types (NewPage (..), SessionInfo (..))
import Wiki.Core.Id (SpaceId, UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Standing (..), User (..))
import Wiki.Server.Options (ServeOptions (..))

spec :: Spec
spec = describe "accounts over HTTP" $ do
  signingIn
  rules
  administration
  endings
  pages
  guards

-- | An address of the API on a listener.
onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | A session's cookie, as a browser sends it back.
cookie :: Text -> Header
cookie token = ("Cookie", "theme=dark; wiki_session=" <> encodeUtf8 token)

-- | The session id a response's @Set-Cookie@ gives, and the attributes it
-- gives it with.
setCookie :: Reply -> Maybe (Text, [Text])
setCookie reply = case T.splitOn "; " . decodeUtf8 <$> header "Set-Cookie" reply of
  Just (first' : attributes) | Just value <- T.stripPrefix "wiki_session=" first' -> Just (value, attributes)
  _ -> Nothing

-- | Give a demo user a password, as the administrator on the admin
-- listener.
givePassword :: Running -> Text -> Text -> IO ()
givePassword r uid password = do
  reply <- sendJson r methodPut (onAdmin r (links.admin.setPassword (UserId uid))) NewPassword {password}
  account :: Account <- jsonAs 200 reply
  account.hasPassword `shouldBe` True

-- | Sign in on the public listener: the session id its cookie carries.
signInAs :: (HasCallStack) => Running -> Text -> Text -> IO Text
signInAs r login password = do
  reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login, password}
  info :: SessionInfo <- jsonAs 200 reply
  info.standing `shouldBe` SignedIn
  maybe (panic ("no session cookie: " <> show reply)) (pure . fst) (setCookie reply)

-- | Who the public listener takes a request with this cookie for.
sessionWith :: Running -> [Header] -> IO (SessionInfo, Reply)
sessionWith r hs = do
  reply <- getUrlWith r (onPublic r links.session) hs
  (,reply) <$> jsonAs 200 reply

-- | The demo with passwords for the editor and the admin.
withPasswords :: (ServeOptions -> ServeOptions) -> (Running -> IO a) -> IO a
withPasswords change test = withDemoRunning change $ \r -> do
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

signingIn :: Spec
signingIn = describe "signing in" $ do
  it "answers with the session, and a cookie that is HttpOnly, SameSite=Strict, at the base path, for two weeks" $ withPasswords identity $ \r -> do
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
    info :: SessionInfo <- jsonAs 200 reply
    ((\u -> u.login) <$> info.user, info.standing) `shouldBe` (Just "editor", SignedIn)
    (snd <$> setCookie reply) `shouldBe` Just ["Path=/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict"]
    token <- maybe (panic "no cookie") (pure . fst) (setCookie reply)
    (me, _) <- sessionWith r [cookie token]
    ((\u -> u.displayName) <$> me.user, me.standing) `shouldBe` (Just "Edgar Editor", SignedIn)

  it "marks the cookie Secure under --secure-cookies, and sets it below the base path" $
    withPasswords (\o -> o {secureCookies = True, basePath = "/wiki/"}) $ \r -> do
      reply <- sendJson r methodPost (r.public <> "/wiki/" <> links.signIn) Credentials {login = "editor", password = "editor's password"}
      (snd <$> setCookie reply) `shouldBe` Just ["Path=/wiki/", "Max-Age=1209600", "HttpOnly", "SameSite=Strict", "Secure"]

  it "refuses a wrong password, an unknown login and a login without a password alike, with a 401" $ withPasswords identity $ \r -> do
    for_ [("editor", "wrong"), ("nobody", "editor's password"), ("reader", "")] $ \(login, password) -> do
      reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login, password}
      jsonAs 401 reply `shouldReturn` Unauthenticated
      setCookie reply `shouldBe` Nothing

  it "refuses a login tried too often from an address with a 429, even with the right password" $ withPasswords identity $ \r -> do
    replicateM_ 5 $ sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "guess"}
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
    reply.status `shouldBe` 429
    (json reply :: IO ApiError) >>= (`shouldSatisfy` \case TooManyRequests why -> "try again in" `T.isInfixOf` why; _ -> False)
    header "Retry-After" reply `shouldSatisfy` maybe False (BC.all isDigit)
    -- Another login is not held to the editor's failures.
    _ <- signInAs r "admin" "admin's password"
    pass

  it "replaces the session the browser had" $ withPasswords identity $ \r -> do
    first' <- signInAs r "editor" "editor's password"
    reply <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), cookie first'] (encode Credentials {login = "admin", password = "admin's password"})
    second' <- maybe (panic "no cookie") (pure . fst) (setCookie reply)
    (old, _) <- sessionWith r [cookie first']
    old.user `shouldBe` Nothing
    (new, _) <- sessionWith r [cookie second']
    (\u -> u.login) <$> new.user `shouldBe` Just "admin"

rules :: Spec
rules = describe "each principal" $ do
  it "anonymous reads the public spaces and nothing else, and writes nothing" $ withPasswords identity $ \r -> do
    spaces :: [Space] <- getUrl r (onPublic r links.spaces.list) >>= jsonAs 200
    map (\s -> s.name) spaces `shouldBe` ["Blog", "Docs"]
    (.status) <$> spaceAt r [] "team" `shouldReturn` 403
    blog <- spaceIdAt r [] "blog"
    (.status) <$> newPage r [] blog `shouldReturn` 403
    (me, _) <- sessionWith r []
    (me.user, me.standing) `shouldBe` (Nothing, NotSignedIn)

  it "a user signed in writes where they are granted to, and gets 403 elsewhere" $ withPasswords identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    blog <- spaceIdAt r [cookie token] "blog"
    docs <- spaceIdAt r [cookie token] "docs"
    made <- newPage r [cookie token] blog
    made.status `shouldBe` 201
    (\(p :: Page) -> p.title) <$> json made `shouldReturn` "From a session"
    (.status) <$> newPage r [cookie token] docs `shouldReturn` 403
    (.status) <$> spaceAt r [cookie token] "team" `shouldReturn` 403
    -- Nor does a cookie make anyone an administrator.
    (.status) <$> getUrlWith r (onPublic r links.admin.status) [cookie token] `shouldReturn` 403

  it "an administrator signed in may do everything, the administration included" $ withPasswords identity $ \r -> do
    token <- signInAs r "admin" "admin's password"
    (.status) <$> spaceAt r [cookie token] "team" `shouldReturn` 200
    (.status) <$> getUrlWith r (onPublic r links.admin.status) [cookie token] `shouldReturn` 200

  it "is the administrator for everyone under --trust-network, which signs nobody in" $ withPasswords trusted $ \r -> do
    (me, _) <- sessionWith r []
    ((\u -> u.login) <$> me.user, me.standing) `shouldBe` (Just "administrator", Operator)
    reply <- sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"}
    reply.status `shouldBe` 400
    setCookie reply `shouldBe` Nothing

administration :: Spec
administration = describe "the administrator on the admin listener" $ do
  it "needs no cookie, and takes none: the operator is whoever reaches it" $ withPasswords identity $ \r -> do
    _ :: ServerStatus <- getUrl r (onAdmin r links.admin.status) >>= jsonAs 200
    editor <- signInAs r "editor" "editor's password"
    me :: SessionInfo <- getUrlWith r (onAdmin r links.session) [cookie editor] >>= jsonAs 200
    ((\u -> u.login) <$> me.user, me.standing) `shouldBe` (Just "administrator", Operator)
    (.status) <$> sendJson r methodPost (onAdmin r links.signIn) Credentials {login = "editor", password = "editor's password"} `shouldReturn` 400

  it "makes a user with a password, who signs in on the public listener" $ withPasswords identity $ \r -> do
    made :: Account <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "bea", displayName = "Bea", password = "bea's password"} >>= jsonAs 201
    (made.user.login, made.hasPassword, made.disabled) `shouldBe` ("bea", True, False)
    token <- signInAs r "bea" "bea's password"
    (me, _) <- sessionWith r [cookie token]
    (\u -> u.id) <$> me.user `shouldBe` Just made.user.id
    again <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "BEA", displayName = "", password = "another password"}
    (json again :: IO ApiError) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    short <- sendJson r methodPost (onAdmin r links.admin.createUser) NewAccount {login = "cid", displayName = "", password = "short"}
    short.status `shouldBe` 400

  it "is refused the account operations on the public listener unless an administrator is signed in" $ withPasswords identity $ \r -> do
    let attempt hs = send r methodPut (onPublic r (links.admin.setDisabled (UserId "user-reader"))) ((hContentType, "application/json") : hs) (encode AccountDisabled {disabled = True})
    (.status) <$> attempt [] `shouldReturn` 403
    editor <- signInAs r "editor" "editor's password"
    (.status) <$> attempt [cookie editor] `shouldReturn` 403
    admin <- signInAs r "admin" "admin's password"
    (attempt [cookie admin] >>= jsonAs 200) >>= \(a :: Account) -> a.disabled `shouldBe` True
    (.status) <$> sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "nobody"))) AccountDisabled {disabled = True} `shouldReturn` 404

endings :: Spec
endings = describe "a session" $ do
  it "ends when its user signs out, and the cookie is cleared" $ withPasswords identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    reply <- send r methodDelete (onPublic r links.signOut) [cookie token] ""
    info :: SessionInfo <- jsonAs 200 reply
    (info.user, info.standing) `shouldBe` (Nothing, NotSignedIn)
    setCookie reply `shouldBe` Just ("", ["Path=/", "Max-Age=0", "HttpOnly", "SameSite=Strict"])
    (me, _) <- sessionWith r [cookie token]
    me.user `shouldBe` Nothing

  it "ends when its user is disabled: the next request is nobody's, and clears the cookie" $ withPasswords identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    blog <- spaceIdAt r [cookie token] "blog"
    _ :: Account <- sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "user-editor"))) AccountDisabled {disabled = True} >>= jsonAs 200
    (me, reply) <- sessionWith r [cookie token]
    (me.user, me.standing) `shouldBe` (Nothing, NotSignedIn)
    setCookie reply `shouldBe` Just ("", ["Path=/", "Max-Age=0", "HttpOnly", "SameSite=Strict"])
    (.status) <$> newPage r [cookie token] blog `shouldReturn` 403
    -- Still one of the wiki's people, in the administration's directory.
    people :: Directory <- getUrl r (onAdmin r links.admin.directory) >>= jsonAs 200
    map (\u -> u.login) people.users `shouldContain` ["editor"]
    -- Enabled again, they sign in again; the old session stays ended.
    _ :: Account <- sendJson r methodPut (onAdmin r (links.admin.setDisabled (UserId "user-editor"))) AccountDisabled {disabled = False} >>= jsonAs 200
    (stale, _) <- sessionWith r [cookie token]
    stale.user `shouldBe` Nothing
    _ <- signInAs r "editor" "editor's password"
    pass

  it "ends when its user is given a new password" $ withPasswords identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    givePassword r "user-editor" "a new password"
    (me, _) <- sessionWith r [cookie token]
    me.user `shouldBe` Nothing
    (.status) <$> sendJson r methodPost (onPublic r links.signIn) Credentials {login = "editor", password = "editor's password"} `shouldReturn` 401
    _ <- signInAs r "editor" "a new password"
    pass

  it "is nobody's when the cookie names none, and that cookie is cleared" $ withPasswords identity $ \r -> do
    for_ [T.replicate 43 "A", "not-a-session-id"] $ \token -> do
      (me, reply) <- sessionWith r [cookie token]
      me.user `shouldBe` Nothing
      (fst <$> setCookie reply) `shouldBe` Just ""
    (_, plain) <- sessionWith r []
    setCookie plain `shouldBe` Nothing

pages :: Spec
pages = describe "the pages the server renders" $ do
  it "show a signed-in user as signed in from the first paint, carry them in the preload, and are private" $ withPasswords identity $ \r -> do
    token <- signInAs r "editor" "editor's password"
    reply <- getUrlWith r (r.public <> "/") [cookie token]
    reply.status `shouldBe` 200
    let html = decodeUtf8 (BSL.toStrict reply.body)
        app = fst (T.breakOn "<script" (snd (T.breakOn "<div id=\"app\">" html)))
    app `shouldSatisfy` T.isInfixOf "<span class=\"user-name\">Edgar Editor</span>"
    app `shouldSatisfy` T.isInfixOf "class=\"sign-out\""
    app `shouldNotSatisfy` T.isInfixOf "sign-in-toggle"
    html `shouldSatisfy` T.isInfixOf "\"standing\":\"SignedIn\""
    header "Cache-Control" reply `shouldBe` Just "private, no-cache"
    header "Vary" reply `shouldBe` Just "Cookie"
    -- A private space's page renders for whoever may see it.
    team <- getUrlWith r (r.public <> "/s/team/") [cookie token]
    team.status `shouldBe` 403
    admin <- signInAs r "admin" "admin's password"
    (.status) <$> getUrlWith r (r.public <> "/s/team/") [cookie admin] `shouldReturn` 200

  it "show nobody the way to sign in" $ withPasswords identity $ \r -> do
    reply <- getUrl r (r.public <> "/")
    let html = decodeUtf8 (BSL.toStrict reply.body)
    html `shouldSatisfy` T.isInfixOf "class=\"sign-in-toggle\""
    html `shouldSatisfy` T.isInfixOf "\"standing\":\"NotSignedIn\""

  it "answer the API privately too" $ withPasswords identity $ \r -> do
    reply <- getUrl r (onPublic r links.session)
    (header "Cache-Control" reply, header "Vary" reply) `shouldBe` (Just "private, no-cache", Just "Cookie")

guards :: Spec
guards = describe "requests from other sites" $ do
  it "are refused when they change something without the application's header, on both listeners" $ withPasswords identity $ \r -> do
    let body = encode Credentials {login = "editor", password = "editor's password"}
    signIn <- sendBare r methodPost (onPublic r links.signIn) [(hContentType, "application/json")] body
    (signIn.status, setCookie signIn) `shouldBe` (403, Nothing)
    jsonAs 403 signIn `shouldReturn` Forbidden
    made <- sendBare r methodPost (onAdmin r links.admin.createUser) [(hContentType, "application/json")] (encode NewAccount {login = "eve", displayName = "", password = "eve's password"})
    made.status `shouldBe` 403
    -- Reading needs no header.
    (.status) <$> sendBare r methodGet (onPublic r links.session) [] "" `shouldReturn` 200

  it "are refused when the browser says they come from another site, header or not" $ withPasswords identity $ \r -> do
    reply <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), ("Sec-Fetch-Site", "cross-site")] (encode Credentials {login = "editor", password = "editor's password"})
    reply.status `shouldBe` 403
    same <- send r methodPost (onPublic r links.signIn) [(hContentType, "application/json"), ("Sec-Fetch-Site", "same-origin")] (encode Credentials {login = "editor", password = "editor's password"})
    same.status `shouldBe` 200
