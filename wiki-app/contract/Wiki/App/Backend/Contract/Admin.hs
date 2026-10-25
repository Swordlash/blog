-- | What every 'MonadAdmin' backend does, as tests: the laws of
-- "Wiki.App.Backend.Admin", checked against the demo's content
-- ("Wiki.App.Demo"), whose @admin@ holds the global administer, whose
-- @editor@ is in the group @writers@ (which may edit the blog), and whose
-- @reader@ is in no group.
--
-- Run, as the backend's contract is ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), against the in-memory backend, the server's SQLite
-- storage, and the backend over HTTP against the server's API. Whoever
-- holds the global administer here is one of the wiki's users, granted it;
-- the server's operator, who holds it without being one, is the server's
-- own tests'.
module Wiki.App.Backend.Contract.Admin (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.Api.Account (Account (..), NewAccount (..))
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), WikiSettings (..), defaultSettings)
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderKind (..), ProviderSettingsOf (..), SecretState (..), Security (..), ServerSettingsChange, ServerSettingsOf (..), noServerSettings)
import Wiki.App.Backend
import Wiki.App.Backend.Admin
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), User (..))

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as
-- "Wiki.App.Backend.Contract"'s.
spec :: forall m -> (MonadWiki m, MonadAdmin m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadAdmin contract" $ do
  reading
  refusing
  administrators
  creators
  accounts
  groups
  membership
  letsIn
  serverSide

--------------------------------------------------------------------------------
-- Helpers

ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

shouldFailWith :: (HasCallStack, Show a) => Either WikiError a -> WikiError -> Expectation
shouldFailWith result e = case result of
  Left e' -> e' `shouldBe` e
  Right a -> expectationFailure ("expected " <> show e <> ", got Right " <> show a)

shouldBeInvalid :: (HasCallStack, Show a) => Either WikiError a -> Expectation
shouldBeInvalid = \case
  Left (Invalid _) -> pass
  other -> expectationFailure ("expected Invalid, got " <> show other)

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

-- | The id of the user with this login, as they see themself.
idOf :: (HasCallStack, MonadWiki m) => Run m -> As -> IO UserId
idOf run who = run who currentUser >>= maybe (assertFailure ("nobody is signed in as " <> show who)) (pure . (\u -> u.id))

-- | The directory, as the demo's administrator reads it.
directoryNow :: (HasCallStack, MonadAdmin m) => Run m -> IO Directory
directoryNow run = run admin directory >>= ok

-- | The group of this name, which must be there.
groupNamed :: (HasCallStack, MonadAdmin m) => Run m -> Text -> IO Group
groupNamed run name =
  directoryNow run >>= \d -> maybe (assertFailure ("no group " <> toS name)) pure (find (\g -> g.name == name) d.groups)

-- | The logins of a group's members.
membersOf :: (MonadAdmin m) => Run m -> Group -> IO [Text]
membersOf run g = do
  d <- directoryNow run
  let ids = Map.findWithDefault mempty g.id d.membership
  pure [u.login | u <- d.users, u.id `Set.member` ids]

-- | Whether someone holds the global administer, as their session says.
isAdministrator :: (MonadWiki m) => Run m -> As -> IO Bool
isAdministrator run who = any (\g -> g.permission == Administer) . (\s -> s.grants.global) <$> run who session

-- | What someone is granted on the blog, as their session says.
onBlog :: (HasCallStack, MonadWiki m) => Run m -> As -> IO [SpacePermission]
onBlog run who = do
  blog <- run admin (getSpace [either (panic . show) identity (mkSlug "blog")]) >>= ok
  s <- run who session
  pure [g.permission | g <- s.grants.spaces, g.space == blog.id]

--------------------------------------------------------------------------------
-- Reading

reading :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
reading = describe "directory" $ do
  it "lists every user by login, the administrators, and every group with its members" $ \(Fixture run) -> do
    adminId <- idOf run admin
    editorId <- idOf run editor
    d <- directoryNow run
    map (\u -> u.login) d.users `shouldBe` ["admin", "editor", "reader"]
    d.administrators `shouldBe` Set.singleton adminId
    d.creators `shouldBe` Set.singleton editorId
    (d.disabled, d.withPassword) `shouldBe` (mempty, mempty)
    -- No one signs in with a provider in a wiki that has just been made.
    d.identities `shouldBe` mempty
    map (\g -> g.name) d.groups `shouldBe` ["writers"]
    Map.elems d.membership `shouldBe` [Set.singleton editorId]
    Map.keys d.membership `shouldBe` map (\g -> g.id) d.groups

--------------------------------------------------------------------------------
-- Refusals

refusing :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
refusing = describe "refusals" $
  it "refuse everything to whoever does not hold the global administer, before looking for what they name" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    readerId <- idOf run reader
    let nobody = UserId "user-nobody"
        nothing = GroupId "group-nothing"
    for_ [Anonymous, editor, reader] $ \who -> do
      run who directory >>= (`shouldFailWith` Forbidden)
      run who (setAdministrator readerId True) >>= (`shouldFailWith` Forbidden)
      run who (setAdministrator nobody True) >>= (`shouldFailWith` Forbidden)
      run who (createGroup "") >>= (`shouldFailWith` Forbidden)
      run who (renameGroup writers.id "editors") >>= (`shouldFailWith` Forbidden)
      run who (renameGroup nothing "editors") >>= (`shouldFailWith` Forbidden)
      run who (deleteGroup writers.id) >>= (`shouldFailWith` Forbidden)
      run who (addMember writers.id readerId) >>= (`shouldFailWith` Forbidden)
      run who (addMember nothing nobody) >>= (`shouldFailWith` Forbidden)
      run who (removeMember writers.id readerId) >>= (`shouldFailWith` Forbidden)
      run who (setCreateSpaces readerId True) >>= (`shouldFailWith` Forbidden)
      run who (setCreateSpaces nobody True) >>= (`shouldFailWith` Forbidden)
      run who (createUser NewAccount {login = "", displayName = "", password = ""}) >>= (`shouldFailWith` Forbidden)
      run who (setPassword readerId "a good password") >>= (`shouldFailWith` Forbidden)
      run who (setPassword nobody "") >>= (`shouldFailWith` Forbidden)
      run who (setDisabled readerId True) >>= (`shouldFailWith` Forbidden)
      run who (unlinkUserIdentity readerId "github") >>= (`shouldFailWith` Forbidden)
      run who (unlinkUserIdentity nobody "github") >>= (`shouldFailWith` Forbidden)
    -- Nothing was changed.
    d <- directoryNow run
    map (\g -> g.name) d.groups `shouldBe` ["writers"]
    Set.size d.administrators `shouldBe` 1

--------------------------------------------------------------------------------
-- Administrators

administrators :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
administrators = describe "setAdministrator" $ do
  it "grants a user the global administer, and takes it away" $ \(Fixture run) -> do
    adminId <- idOf run admin
    editorId <- idOf run editor
    run admin (setAdministrator editorId True) >>= ok
    (\d -> d.administrators) <$> directoryNow run `shouldReturn` Set.fromList [adminId, editorId]
    isAdministrator run editor `shouldReturn` True
    -- They may administer the wiki now themselves.
    void (run editor directory >>= ok)
    run admin (setAdministrator editorId False) >>= ok
    (\d -> d.administrators) <$> directoryNow run `shouldReturn` Set.singleton adminId
    isAdministrator run editor `shouldReturn` False
    run editor directory >>= (`shouldFailWith` Forbidden)

  it "does nothing more when asked twice, and leaves the user's other grants alone" $ \(Fixture run) -> do
    editorId <- idOf run editor
    run admin (setAdministrator editorId True) >>= ok
    run admin (setAdministrator editorId True) >>= ok
    s <- run editor session
    sort (map (\g -> g.permission) s.grants.global) `shouldBe` [Administer, CreateSpaces]
    run admin (setAdministrator editorId False) >>= ok
    run admin (setAdministrator editorId False) >>= ok
    map (\g -> g.permission) . (\x -> x.grants.global) <$> run editor session `shouldReturn` [CreateSpaces]

  it "lets an administrator take it from themself" $ \(Fixture run) -> do
    adminId <- idOf run admin
    run admin (setAdministrator adminId False) >>= ok
    isAdministrator run admin `shouldReturn` False
    run admin directory >>= (`shouldFailWith` Forbidden)

  it "finds nobody for an id that is no user's" $ \(Fixture run) ->
    run admin (setAdministrator (UserId "user-nobody") True) >>= (`shouldFailWith` NotFound)

  it "finds no account at a provider that a user has not connected, nor a user for an id that is none" $ \(Fixture run) -> do
    readerId <- idOf run reader
    run admin (unlinkUserIdentity readerId "github") >>= (`shouldFailWith` NotFound)
    run admin (unlinkUserIdentity (UserId "user-nobody") "github") >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Creating spaces

creators :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
creators = describe "setCreateSpaces" $ do
  it "lets a user create top-level spaces, and no longer" $ \(Fixture run) -> do
    editorId <- idOf run editor
    readerId <- idOf run reader
    run reader (createSpace Nothing "Rita's") >>= (`shouldFailWith` Forbidden)
    run admin (setCreateSpaces readerId True) >>= ok
    run admin (setCreateSpaces readerId True) >>= ok
    void (run reader (createSpace Nothing "Rita's") >>= ok)
    (\d -> d.creators) <$> directoryNow run `shouldReturn` Set.fromList [editorId, readerId]
    run admin (setCreateSpaces editorId False) >>= ok
    run editor (createSpace Nothing "Edgar's") >>= (`shouldFailWith` Forbidden)
    (\d -> d.creators) <$> directoryNow run `shouldReturn` Set.singleton readerId
    -- Their other grants stay.
    isAdministrator run editor `shouldReturn` False
    onBlog run editor `shouldReturn` [Edit]

  it "finds nobody for an id that is no user's" $ \(Fixture run) ->
    run admin (setCreateSpaces (UserId "user-nobody") True) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Accounts

accounts :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
accounts = describe "createUser, setPassword and setDisabled" $ do
  it "make a user with a password, listed by login, their login the name if none is given" $ \(Fixture run) -> do
    made <- run admin (createUser NewAccount {login = " bea ", displayName = "", password = "bea's password"}) >>= ok
    (made.user.login, made.user.displayName, made.hasPassword, made.disabled) `shouldBe` ("bea", "bea", True, False)
    d <- directoryNow run
    map (\u -> u.login) d.users `shouldBe` ["admin", "bea", "editor", "reader"]
    d.withPassword `shouldBe` Set.singleton made.user.id
    named <- run admin (createUser NewAccount {login = "cid", displayName = " Cid ", password = "cid's password"}) >>= ok
    named.user.displayName `shouldBe` "Cid"

  it "refuse a login that is taken in any case, one that cannot be a login, and a short password" $ \(Fixture run) -> do
    let new login password = run admin (createUser NewAccount {login, displayName = "", password})
    new "EDITOR" "a good password" >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected a conflict, got " <> show other)
    new "" "a good password" >>= shouldBeInvalid
    new "two words" "a good password" >>= shouldBeInvalid
    new "~operator" "a good password" >>= shouldBeInvalid
    new "dee" "short" >>= shouldBeInvalid
    map (\u -> u.login) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]

  it "give a user a password, and refuse a short one" $ \(Fixture run) -> do
    readerId <- idOf run reader
    run admin (setPassword readerId "short") >>= shouldBeInvalid
    account <- run admin (setPassword readerId "rita's password") >>= ok
    (account.user.login, account.hasPassword) `shouldBe` ("reader", True)
    (\d -> d.withPassword) <$> directoryNow run `shouldReturn` Set.singleton readerId
    run admin (setPassword (UserId "user-nobody") "a good password") >>= (`shouldFailWith` NotFound)

  it "disable a login, whose user is then nobody, and enable it again" $ \(Fixture run) -> do
    readerId <- idOf run reader
    projects <- run admin (getSpace [slug "team", slug "projects"]) >>= ok
    account <- run admin (setDisabled readerId True) >>= ok
    account.disabled `shouldBe` True
    (\d -> d.disabled) <$> directoryNow run `shouldReturn` Set.singleton readerId
    -- Still in the directory, but signed in as nobody, and seeing what
    -- nobody sees.
    map (\u -> u.login) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]
    (\s -> s.user) <$> run reader session `shouldReturn` Nothing
    run reader (listPages projects.id) >>= (`shouldFailWith` Forbidden)
    enabled <- run admin (setDisabled readerId False) >>= ok
    enabled.disabled `shouldBe` False
    (\s -> (\u -> u.login) <$> s.user) <$> run reader session `shouldReturn` Just "reader"
    void (run reader (listPages projects.id) >>= ok)
    run admin (setDisabled (UserId "user-nobody") True) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Groups

groups :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
groups = describe "createGroup, renameGroup and deleteGroup" $ do
  it "make a group with nobody in it, listed by name" $ \(Fixture run) -> do
    made <- run admin (createGroup "  Readers ") >>= ok
    made.name `shouldBe` "Readers"
    d <- directoryNow run
    map (\g -> g.name) d.groups `shouldBe` ["Readers", "writers"]
    Map.member made.id d.membership `shouldBe` False

  it "refuse a blank name, and another group's in any case" $ \(Fixture run) -> do
    run admin (createGroup " ") >>= shouldBeInvalid
    run admin (createGroup "Writers") >>= shouldBeInvalid
    writers <- groupNamed run "writers"
    other <- run admin (createGroup "readers") >>= ok
    run admin (renameGroup other.id "WRITERS") >>= shouldBeInvalid
    run admin (renameGroup other.id "") >>= shouldBeInvalid
    -- A group may change the case of its own name.
    run admin (renameGroup writers.id "Writers") >>= ok >>= \g -> g.name `shouldBe` "Writers"

  it "rename a group, which keeps its members and its grants" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    renamed <- run admin (renameGroup writers.id "authors") >>= ok
    renamed `shouldBe` Group {id = writers.id, name = "authors"}
    membersOf run renamed `shouldReturn` ["editor"]
    onBlog run editor `shouldReturn` [Edit]

  it "delete a group with its membership and the grants to it, which a new group of the name does not get" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    editorId <- idOf run editor
    run admin (deleteGroup writers.id) >>= ok
    d <- directoryNow run
    d.groups `shouldBe` []
    d.membership `shouldBe` mempty
    s <- run editor session
    s.groups `shouldBe` mempty
    onBlog run editor `shouldReturn` []
    again <- run admin (createGroup "writers") >>= ok
    run admin (addMember again.id editorId) >>= ok
    onBlog run editor `shouldReturn` []

  it "find no group for an id that is no group's" $ \(Fixture run) -> do
    let nothing = GroupId "group-nothing"
    run admin (renameGroup nothing "x") >>= (`shouldFailWith` NotFound)
    run admin (deleteGroup nothing) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Membership

membership :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
membership = describe "addMember and removeMember" $ do
  it "put a user in a group, who then has what is granted to it" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    readerId <- idOf run reader
    onBlog run reader `shouldReturn` []
    run admin (addMember writers.id readerId) >>= ok
    membersOf run writers `shouldReturn` ["editor", "reader"]
    (\s -> s.groups) <$> run reader session `shouldReturn` Set.singleton writers.id
    onBlog run reader `shouldReturn` [Edit]

  it "take a user out of a group, who then has nothing of it" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    editorId <- idOf run editor
    run admin (removeMember writers.id editorId) >>= ok
    membersOf run writers `shouldReturn` []
    onBlog run editor `shouldReturn` []
    -- The group stays, empty.
    map (\g -> g.name) . (\d -> d.groups) <$> directoryNow run `shouldReturn` ["writers"]

  it "do nothing more for a member added twice, or one taken out who is not in" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    editorId <- idOf run editor
    readerId <- idOf run reader
    run admin (addMember writers.id editorId) >>= ok
    run admin (removeMember writers.id readerId) >>= ok
    membersOf run writers `shouldReturn` ["editor"]

  it "find nobody, or no group, for ids that are none" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    readerId <- idOf run reader
    run admin (addMember writers.id (UserId "user-nobody")) >>= (`shouldFailWith` NotFound)
    run admin (addMember (GroupId "group-nothing") readerId) >>= (`shouldFailWith` NotFound)
    run admin (removeMember (GroupId "group-nothing") readerId) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Whom the wiki lets in

letsIn :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
letsIn = describe "wikiSettings, invitations and the rest" $ do
  it "keep a wiki open by default, and refuse its settings to whoever does not administer it" $ \(Fixture run) -> do
    run admin wikiSettings >>= ok >>= (`shouldBe` defaultSettings)
    for_ [Anonymous, editor, reader] $ \who -> do
      run who wikiSettings >>= (`shouldFailWith` Forbidden)
      run who (setWikiSettings closedWiki) >>= (`shouldFailWith` Forbidden)
      run who invitations >>= (`shouldFailWith` Forbidden)
      run who (invite "bea@example.org") >>= (`shouldFailWith` Forbidden)
      run who (revokeInvitation (InvitationId "invitation-nothing")) >>= (`shouldFailWith` Forbidden)
    run admin wikiSettings >>= ok >>= (`shouldBe` defaultSettings)

  it "close a wiki to whoever has not signed in, public spaces included, and open it again" $ \(Fixture run) -> do
    run admin (setWikiSettings closedWiki) >>= ok >>= (`shouldBe` closedWiki)
    run admin wikiSettings >>= ok >>= (`shouldBe` closedWiki)
    nobody <- run Anonymous session
    (nobody.user, nobody.grants.access) `shouldBe` (Nothing, Closed)
    run Anonymous (getSpace [slug "blog"]) >>= (`shouldFailWith` Forbidden)
    -- Someone signed in reads the public spaces as before.
    (\s -> s.grants.access) <$> run reader session `shouldReturn` Closed
    run reader (getSpace [slug "blog"]) >>= ok >>= \s -> s.name `shouldBe` "Blog"
    _ <- run admin (setWikiSettings defaultSettings) >>= ok
    run Anonymous (getSpace [slug "blog"]) >>= ok >>= \s -> s.name `shouldBe` "Blog"
    (\s -> s.grants.access) <$> run Anonymous session `shouldReturn` Open

  it "keep whether new accounts create spaces" $ \(Fixture run) -> do
    let creating = WikiSettings {access = Open, newAccountsCreateSpaces = True}
    _ <- run admin (setWikiSettings creating) >>= ok
    run admin wikiSettings >>= ok >>= (`shouldBe` creating)

  it "invite an address, with the link's secret when it is not mailed, in place of any invitation it had" $ \(Fixture run) -> do
    made <- run admin (invite "  bea@example.org ") >>= ok
    (made.invitation.email, made.invitation.expired, isJust made.token) `shouldBe` ("bea@example.org", False, True)
    made.invitation.expiresAt `shouldSatisfy` (> made.invitation.createdAt)
    again <- run admin (invite "BEA@example.org") >>= ok
    again.token `shouldNotBe` made.token
    listed <- run admin invitations >>= ok
    map (\i -> i.email) listed.invitations `shouldBe` ["BEA@example.org"]
    _ <- run admin (invite "cy@example.org") >>= ok
    length . (\l -> l.invitations) <$> (run admin invitations >>= ok) `shouldReturn` 2

  it "refuse an address that is not one" $ \(Fixture run) ->
    for_ ["", "bea", "bea@", "@example.org", "bea@example", "b ea@example.org"] $ \e ->
      run admin (invite e) >>= shouldBeInvalid

  it "revoke an invitation, which is then gone" $ \(Fixture run) -> do
    made <- run admin (invite "bea@example.org") >>= ok
    run admin (revokeInvitation made.invitation.id) >>= ok
    (\l -> l.invitations) <$> (run admin invitations >>= ok) `shouldReturn` []
    run admin (revokeInvitation made.invitation.id) >>= (`shouldFailWith` NotFound)

closedWiki :: WikiSettings
closedWiki = WikiSettings {access = Closed, newAccountsCreateSpaces = False}

--------------------------------------------------------------------------------
-- The server's own settings

-- | Settings with an address, a mail server with these password and user,
-- and a provider with this secret.
serverWith :: Maybe Text -> Maybe Text -> Maybe Text -> ServerSettingsChange
serverWith user password secret =
  ServerSettings
    { publicUrl = Just "https://wiki.example.org/"
    , mail = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user, password, from = "wiki@example.org"}
    , providers = [ProviderSettings {name = "google", kind = Google, clientId = "id.example", issuer = Nothing, secret}]
    }

serverSide :: (MonadAdmin m) => SpecWith (Fixture m)
serverSide = describe "serverSettings and setServerSettings" $ do
  it "have nothing set at first, and are refused to whoever does not administer the wiki" $ \(Fixture run) -> do
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings)
    for_ [Anonymous, editor, reader] $ \who -> do
      run who serverSettings >>= (`shouldFailWith` Forbidden)
      run who (setServerSettings (serverWith Nothing Nothing (Just "s"))) >>= (`shouldFailWith` Forbidden)
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings)

  it "keep what is written, and say of each secret only whether it is set" $ \(Fixture run) -> do
    set <- run admin (setServerSettings (serverWith (Just "wiki") (Just "pw") (Just "s"))) >>= ok
    run admin serverSettings >>= ok >>= (`shouldBe` set)
    set `shouldBe` (maybe NotSet (const Set) <$> serverWith (Just "wiki") (Just "pw") (Just "s"))

  it "keep a secret left out, clear an empty one, and drop one with what it was for" $ \(Fixture run) -> do
    _ <- run admin (setServerSettings (serverWith (Just "wiki") (Just "pw") (Just "s"))) >>= ok
    kept <- run admin (setServerSettings (serverWith (Just "wiki") Nothing Nothing)) >>= ok
    ((\m -> m.password) <$> kept.mail, map (\p -> p.secret) kept.providers) `shouldBe` (Just Set, [Set])
    cleared <- run admin (setServerSettings (serverWith Nothing (Just "") Nothing)) >>= ok
    (\m -> m.password) <$> cleared.mail `shouldBe` Just NotSet
    _ <- run admin (setServerSettings noServerSettings) >>= ok
    run admin (setServerSettings (serverWith Nothing Nothing Nothing)) >>= shouldBeInvalid

  it "refuse settings that cannot be, and keep none of them" $ \(Fixture run) -> do
    run admin (setServerSettings (serverWith Nothing Nothing (Just "s")) {publicUrl = Nothing}) >>= shouldBeInvalid
    run admin (setServerSettings (serverWith Nothing Nothing (Just "s")) {publicUrl = Just "wiki.example.org"}) >>= shouldBeInvalid
    run admin (setServerSettings (serverWith (Just "wiki") Nothing (Just "s"))) >>= shouldBeInvalid
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings)
