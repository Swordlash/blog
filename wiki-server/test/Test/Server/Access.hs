-- | Whom the wiki lets in, over real HTTP (WP3.5 of docs/PLAN.md): an open
-- wiki, where anyone reads the public spaces and makes themself an account;
-- a closed one, where someone who has not signed in is answered 401 and
-- shown the way to sign in, and accounts come by invitation; the switch
-- between them, which the next request sees; and an invitation's whole
-- way, made, mailed or not, accepted once, revoked, expired.
--
-- The demo's wiki is the server's, as in "Test.Server.Accounts": Blog and
-- Docs public, Team private, the operator on the admin listener changes the
-- settings without a cookie.
module Test.Server.Access (spec) where

import Data.Aeson (Value, encode)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Database.SQLite.Simple (execute, withConnection)
import Network.HTTP.Types (Header, hContentType, methodDelete, methodPost, methodPut)
import Protolude
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), InvitationsApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (InvitationInfo (..), InvitationToken (..), NewAccount (..))
import Wiki.Api.Admin (Invitation (..), Invitations (..), Invited (..), NewInvitation (..), WikiSettings (..), defaultSettings)
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), noServerSettings)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (InvitationId (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Standing (..), User (..))
import Wiki.Server.Mail (Message (..))
import Wiki.Server.Storage.Layout (databaseFile)

spec :: Spec
spec = describe "whom the wiki lets in, over HTTP" $ do
  open
  closed
  switching
  invitations
  mailed

onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

-- | The settings changed by the operator, on the admin listener.
settle :: (HasCallStack) => Running -> WikiSettings -> IO ()
settle r s = do
  answered :: WikiSettings <- sendJson r methodPut (onAdmin r links.admin.setSettings) s >>= jsonAs 200
  answered `shouldBe` s

closeWiki :: (HasCallStack) => Running -> IO ()
closeWiki r = settle r closedSettings

closedSettings :: WikiSettings
closedSettings = WikiSettings {access = Closed, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True}

-- | Who the public listener takes a request with these headers for.
sessionOf :: (HasCallStack) => Running -> [Header] -> IO SessionInfo
sessionOf r hs = getUrlWith r (onPublic r links.session) hs >>= jsonAs 200

spaceNames :: (HasCallStack) => Running -> [Header] -> IO [Text]
spaceNames r hs = map (\s -> s.name) <$> (getUrlWith r (onPublic r links.spaces.list) hs >>= jsonAs 200 :: IO [Space])

-- | Make oneself an account: the reply.
register :: Running -> [Header] -> Text -> Text -> IO Reply
register r hs login password =
  send r methodPost (onPublic r links.register) ((hContentType, "application/json") : hs) (jsonBody NewAccount {login, displayName = "", password, email = Nothing})

jsonBody :: NewAccount -> LByteString
jsonBody = encode

-- | The session cookie a reply sets.
cookieOf :: (HasCallStack) => Reply -> IO Header
cookieOf reply = maybe (panic ("no session cookie: " <> show reply)) (pure . cookie . fst) (setCookie reply)

-- | Invite an address as the operator: the invitation made.
inviteAs :: (HasCallStack) => Running -> Text -> IO Invited
inviteAs r email = sendJson r methodPost (onAdmin r links.admin.invite) NewInvitation {email} >>= jsonAs 201

accept :: Running -> Text -> Text -> Text -> IO Reply
accept r token login password =
  send r methodPost (onPublic r (links.invitations.accept (InvitationToken token))) [(hContentType, "application/json")] (jsonBody NewAccount {login, displayName = "Invited", password, email = Nothing})

details :: Running -> Text -> IO Reply
details r token = getUrl r (onPublic r (links.invitations.details (InvitationToken token)))

open :: Spec
open = describe "an open wiki" $ do
  it "says so to someone not signed in, and shows them the public spaces" $ withDemoRunning identity $ \r -> do
    me <- sessionOf r []
    (me.user, me.grants.access) `shouldBe` (Nothing, Open)
    spaceNames r [] `shouldReturn` ["Blog", "Docs"]

  it "lets anyone make an account, signed in at once and holding no grant" $ withDemoRunning identity $ \r -> do
    reply <- register r [] "newcomer" "a long password"
    info :: SessionInfo <- jsonAs 200 reply
    ((\u -> u.login) <$> info.user, info.standing, info.grants.global) `shouldBe` (Just "newcomer", SignedIn, [])
    c <- cookieOf reply
    me <- sessionOf r [c]
    (\u -> u.login) <$> me.user `shouldBe` Just "newcomer"
    spaceNames r [c] `shouldReturn` ["Blog", "Docs"]
    made <- send r methodPost (onPublic r links.spaces.create) [(hContentType, "application/json"), c] "{\"parent\":null,\"name\":\"Mine\"}"
    made.status `shouldBe` 403
    -- And signs in with that password afterwards.
    _ <- signInAs r "newcomer" "a long password"
    pass

  it "gives a new account create-spaces when the settings say so" $ withDemoRunning identity $ \r -> do
    settle r WikiSettings {access = Open, newAccountsCreateSpaces = True, adminCreatesPasswordAccounts = True}
    reply <- register r [] "maker" "a long password"
    info :: SessionInfo <- jsonAs 200 reply
    info.grants.global `shouldSatisfy` any (\g -> g.permission == CreateSpaces)
    c <- cookieOf reply
    made <- send r methodPost (onPublic r links.spaces.create) [(hContentType, "application/json"), c] "{\"parent\":null,\"name\":\"Mine\"}"
    made.status `shouldBe` 201

  it "refuses a login that is taken, whatever its case, and a password too short" $ withDemoRunning identity $ \r -> do
    (register r [] "EDITOR" "a long password" >>= jsonAs 409) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    (register r [] "someone" "short" >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)

  it "refuses an account made from another site's page, without the application's header" $ withDemoRunning identity $ \r -> do
    reply <- sendBare r methodPost (onPublic r links.register) [(hContentType, "application/json")] (jsonBody NewAccount {login = "csrf", displayName = "", password = "a long password", email = Nothing})
    reply.status `shouldBe` 403

  it "limits how many accounts are tried from one address" $ withDemoRunning identity $ \r -> do
    for_ [1 :: Int .. 5] $ \n -> register r [] ("guest" <> show n) (if n == 3 then "short" else "a long password")
    reply <- register r [] "guest6" "a long password"
    reply.status `shouldBe` 429
    header "Retry-After" reply `shouldSatisfy` isJust

  it "is refused to the admin listener, where nobody signs in" $ withDemoRunning identity $ \r -> do
    reply <- send r methodPost (onAdmin r links.register) [(hContentType, "application/json")] (jsonBody NewAccount {login = "x", displayName = "", password = "a long password", email = Nothing})
    reply.status `shouldBe` 400

closed :: Spec
closed = describe "a closed wiki" $ do
  it "answers someone not signed in 401 on the API, but for what signing in needs" $ withDemoRunning identity $ \r -> do
    closeWiki r
    for_ [links.spaces.list, links.spaces.atPath [], links.search (Just "tour") Nothing False Nothing False, links.admin.directory] $ \address ->
      (getUrl r (onPublic r address) >>= jsonAs 401) `shouldReturn` Unauthenticated
    _ <- getUrl r (onPublic r links.info) >>= jsonAs @Value 200
    me <- sessionOf r []
    (me.user, me.grants.access, me.standing) `shouldBe` (Nothing, Closed, NotSignedIn)
    (register r [] "newcomer" "a long password" >>= jsonAs 403) `shouldReturn` Forbidden
    (details r "no-such-invitation" >>= jsonAs 404) `shouldReturn` NotFound

  it "renders the way to sign in at every route, with a 401, and nothing of the wiki" $ withDemoRunning identity $ \r -> do
    closeWiki r
    for_ ["/", "/s/blog/", "/s/docs/p/tour/", "/search/?q=tour", "/admin/", "/no/such/route/"] $ \path -> do
      reply <- getUrl r (r.public <> path)
      (path, reply.status) `shouldBe` (path, 401)
      let page = decodeUtf8 (BSL.toStrict reply.body)
      page `shouldSatisfy` T.isInfixOf "Sign in to read this wiki"
      page `shouldSatisfy` (not . T.isInfixOf "Hello, world")
      page `shouldSatisfy` (not . T.isInfixOf ">Blog<")
    -- The application's own files are served all the same: the page that
    -- signs one in needs them.
    (\x -> x.status) <$> getUrl r (r.public <> "/app.wasm") `shouldReturn` 200

  it "shows a signed-in user the public spaces, as before" $ withDemoRunning identity $ \r -> do
    givePassword r "user-editor" "editor's password"
    closeWiki r
    c <- cookie <$> signInAs r "editor" "editor's password"
    spaceNames r [c] `shouldReturn` ["Blog", "Docs"]
    me <- sessionOf r [c]
    me.grants.access `shouldBe` Closed
    reply <- getUrlWith r (r.public <> "/s/blog/") [c]
    reply.status `shouldBe` 200
    decodeUtf8 (BSL.toStrict reply.body) `shouldSatisfy` T.isInfixOf "Blog"

  it "still serves the operator on the admin listener" $ withDemoRunning identity $ \r -> do
    closeWiki r
    names <- map (\s -> s.name) <$> (getUrl r (onAdmin r links.spaces.list) >>= jsonAs 200 :: IO [Space])
    names `shouldBe` ["Blog", "Docs", "Team", "Projects"]
    (\x -> x.status) <$> getUrl r (r.admin <> "/admin/s/team/") `shouldReturn` 200

  it "lets nobody but an administrator change the settings" $ withDemoRunning identity $ \r -> do
    givePassword r "user-editor" "editor's password"
    c <- cookie <$> signInAs r "editor" "editor's password"
    (sendJson r methodPut (onPublic r links.admin.setSettings) closedSettings >>= jsonAs 403) `shouldReturn` Forbidden
    reply <- send r methodPut (onPublic r links.admin.setSettings) [(hContentType, "application/json"), c] "{\"access\":\"Closed\",\"newAccountsCreateSpaces\":false,\"adminCreatesPasswordAccounts\":true}"
    reply.status `shouldBe` 403
    spaceNames r [] `shouldReturn` ["Blog", "Docs"]

switching :: Spec
switching = describe "the switch between them" $ do
  it "is seen by the very next request, either way, and read back as it was set" $ withDemoRunning identity $ \r -> do
    spaceNames r [] `shouldReturn` ["Blog", "Docs"]
    closeWiki r
    (getUrl r (onPublic r links.spaces.list) >>= jsonAs 401) `shouldReturn` Unauthenticated
    (getUrl r (onAdmin r links.admin.settings) >>= jsonAs 200) `shouldReturn` closedSettings
    settle r defaultSettings
    spaceNames r [] `shouldReturn` ["Blog", "Docs"]
    (\x -> x.status) <$> getUrl r (r.public <> "/") `shouldReturn` 200

  it "lasts across a restart of the server" $
    withDemoRestarted closeWiki $ \() again ->
      (getUrl again (onPublic again links.spaces.list) >>= jsonAs 401) `shouldReturn` Unauthenticated

invitations :: Spec
invitations = describe "an invitation, where the server mails nothing" $ do
  it "is made with its link's secret, makes one account, once, and signs its maker in" $ withDemoRunning identity $ \r -> do
    closeWiki r
    made <- inviteAs r "bea@example.org"
    made.invitation.email `shouldBe` "bea@example.org"
    made.mailError `shouldBe` Nothing
    token <- maybe (panic "no secret") pure made.token
    listed :: Invitations <- getUrl r (onAdmin r links.admin.invitations) >>= jsonAs 200
    (listed.mailing, map (\i -> (i.email, i.expired)) listed.invitations) `shouldBe` (False, [("bea@example.org", False)])
    info :: InvitationInfo <- details r token >>= jsonAs 200
    info.email `shouldBe` "bea@example.org"
    -- Its page is for them, closed wiki or not.
    page <- getUrl r (r.public <> "/invite/" <> token <> "/")
    page.status `shouldBe` 200
    decodeUtf8 (BSL.toStrict page.body) `shouldSatisfy` T.isInfixOf "Create my account"
    reply <- accept r token "bea" "a long password"
    signedIn :: SessionInfo <- jsonAs 200 reply
    ((\u -> (u.login, u.displayName)) <$> signedIn.user) `shouldBe` Just ("bea", "Invited")
    c <- cookieOf reply
    spaceNames r [c] `shouldReturn` ["Blog", "Docs"]
    -- Used up.
    (accept r token "bea2" "a long password" >>= jsonAs 404) `shouldReturn` NotFound
    (details r token >>= jsonAs 404) `shouldReturn` NotFound
    (\x -> x.status) <$> getUrl r (r.public <> "/invite/" <> token <> "/") `shouldReturn` 404
    gone :: Invitations <- getUrl r (onAdmin r links.admin.invitations) >>= jsonAs 200
    gone.invitations `shouldBe` []
    -- Its secret is in no line of the log.
    logged <- readIORef r.logged
    filter (T.isInfixOf token) logged `shouldBe` []
    logged `shouldSatisfy` any (T.isInfixOf "invitations/…")

  it "leaves the invitation as it was when the login is taken" $ withDemoRunning identity $ \r -> do
    made <- inviteAs r "bea@example.org"
    token <- maybe (panic "no secret") pure made.token
    (accept r token "editor" "a long password" >>= jsonAs 409) >>= (`shouldSatisfy` \case Conflict _ -> True; _ -> False)
    (accept r token "bea" "a long password") >>= jsonAs @SessionInfo 200 >>= \s -> (\u -> u.login) <$> s.user `shouldBe` Just "bea"

  it "gives the account create-spaces when the settings say so" $ withDemoRunning identity $ \r -> do
    settle r WikiSettings {access = Closed, newAccountsCreateSpaces = True, adminCreatesPasswordAccounts = True}
    made <- inviteAs r "bea@example.org"
    token <- maybe (panic "no secret") pure made.token
    info :: SessionInfo <- accept r token "bea" "a long password" >>= jsonAs 200
    info.grants.global `shouldSatisfy` any (\g -> g.permission == CreateSpaces)

  it "is refused once revoked, and revoking it again finds nothing" $ withDemoRunning identity $ \r -> do
    made <- inviteAs r "bea@example.org"
    token <- maybe (panic "no secret") pure made.token
    revoked <- send r methodDelete (onAdmin r (links.admin.revokeInvitation made.invitation.id)) [] ""
    revoked.status `shouldBe` 204
    (details r token >>= jsonAs 404) `shouldReturn` NotFound
    (accept r token "bea" "a long password" >>= jsonAs 404) `shouldReturn` NotFound
    (send r methodDelete (onAdmin r (links.admin.revokeInvitation made.invitation.id)) [] "" >>= jsonAs 404) `shouldReturn` NotFound

  it "is refused once it has expired, and listed as expired" $ withDemoRunning identity $ \r -> do
    made <- inviteAs r "bea@example.org"
    token <- maybe (panic "no secret") pure made.token
    past <- addUTCTime (-60) <$> getCurrentTime
    withConnection (databaseFile r.dataDir) $ \c ->
      execute c "UPDATE invitations SET expires_at = ? WHERE id = ?" (T.pack (iso8601Show past), made.invitation.id.text)
    (details r token >>= jsonAs 404) `shouldReturn` NotFound
    (accept r token "bea" "a long password" >>= jsonAs 404) `shouldReturn` NotFound
    listed :: Invitations <- getUrl r (onAdmin r links.admin.invitations) >>= jsonAs 200
    map (\i -> i.expired) listed.invitations `shouldBe` [True]

  it "replaces the invitation an address had, whose link no longer works" $ withDemoRunning identity $ \r -> do
    first' <- inviteAs r "bea@example.org"
    second' <- inviteAs r "BEA@example.org"
    old <- maybe (panic "no secret") pure first'.token
    (details r old >>= jsonAs 404) `shouldReturn` NotFound
    new <- maybe (panic "no secret") pure second'.token
    _ <- details r new >>= jsonAs @InvitationInfo 200
    listed :: Invitations <- getUrl r (onAdmin r links.admin.invitations) >>= jsonAs 200
    length listed.invitations `shouldBe` 1

  it "is refused to an address that is not one, and to anyone not an administrator" $ withDemoRunning identity $ \r -> do
    (sendJson r methodPost (onAdmin r links.admin.invite) NewInvitation {email = "not an address"} >>= jsonAs 400) >>= (`shouldSatisfy` \case Invalid _ -> True; _ -> False)
    (sendJson r methodPost (onPublic r links.admin.invite) NewInvitation {email = "bea@example.org"} >>= jsonAs 403) `shouldReturn` Forbidden
    (getUrl r (onPublic r links.admin.invitations) >>= jsonAs 403) `shouldReturn` Forbidden
    (send r methodDelete (onPublic r (links.admin.revokeInvitation (InvitationId "i"))) [] "" >>= jsonAs 403) `shouldReturn` Forbidden

mailed :: Spec
mailed = describe "an invitation, where the server mails them" $ do
  let mailingThrough host r = setServer r noServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just MailSettings {host, port = 587, security = StartTls, user = Nothing, password = Nothing, from = "Wiki <wiki@example.org>"}}
  it "is mailed with its link, which the panel is not given" $ withDemoRunning identity $ \r -> do
    _ <- mailingThrough "mail.test" r
    made <- inviteAs r "bea@example.org"
    (made.token, made.mailError) `shouldBe` (Nothing, Nothing)
    listed :: Invitations <- getUrl r (onAdmin r links.admin.invitations) >>= jsonAs 200
    listed.mailing `shouldBe` True
    sent <- readIORef r.outbox
    map (\m -> m.to) sent `shouldBe` ["bea@example.org"]
    let mailedLink = head [w | m <- sent, w <- T.words m.body, "https://wiki.example.org/invite/" `T.isPrefixOf` w]
    token <- maybe (panic "no link in the mail") (pure . T.dropEnd 1 . T.drop (T.length "https://wiki.example.org/invite/")) mailedLink
    info :: InvitationInfo <- details r token >>= jsonAs 200
    info.email `shouldBe` "bea@example.org"
    _ <- accept r token "bea" "a long password" >>= jsonAs @SessionInfo 200
    -- The mail's body is not something a Show writes.
    show sent `shouldSatisfy` (not . T.isInfixOf token)

  it "gives the panel the link when the mail cannot be sent, and says why" $
    withDemoRunning identity $ \r -> do
      _ <- mailingThrough "unreachable.test" r
      made <- inviteAs r "bea@example.org"
      made.mailError `shouldSatisfy` maybe False (T.isInfixOf "did not answer")
      token <- maybe (panic "no secret") pure made.token
      _ <- details r token >>= jsonAs @InvitationInfo 200
      pass
