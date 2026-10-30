-- | The contract tests of 'MonadAdmin': what every administration backend
-- does, as tests of the rules of "Wiki.App.Backend.Admin", checked against
-- the demo's content ("Wiki.App.Demo"). There, @admin@ holds the global
-- administer, @editor@ is in the group @writers@ (which may edit the blog),
-- and @reader@ is in no group.
--
-- Like the backend's contract ("Wiki.App.Backend.Contract", whose
-- 'Fixture' it takes), it runs against the in-memory backend, the server's
-- SQLite storage, and the HTTP backend against the server's API. Here,
-- whoever holds the global administer is one of the wiki's users, granted
-- it. The server's operator, who holds it without being a user, is
-- covered by the server's own tests.
module Wiki.App.Backend.Contract.Admin (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Protolude hiding (reader)
import Test.HUnit (assertFailure)
import Test.Hspec
import Wiki.Api.Account (Account (..), NewAccount (..))
import Wiki.Api.Activity (Activity (..), firstPage)
import Wiki.Api.Admin (Directory (..), Invitation (..), Invitations (..), Invited (..), UserPage (..), UserQuery (..), UserSummary (..), WikiSettings (..), defaultSettings, pageOfDirectory)
import Wiki.Api.Backups (BackupSettingsOf (..), Backups (..), defaultBackupSettings)
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.ServerSettings (HomePage (..), MailSettingsOf (..), ProviderKind (..), ProviderSettingsOf (..), SecretState (..), Security (..), ServerSettingsChange, ServerSettingsOf (..), defaultHomePage, noServerSettings)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.App.Backend
import Wiki.App.Backend.Admin
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (id))
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, formerAuthor)
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxColour (..), BoxIcon (..), BoxKind (..))
import Wiki.Core.Notification (Notification (..), WatchTarget (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceAccess (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Group (..), Login (..), Password (..), User (..))
import Wiki.Core.Version (Author (..), VersionInfo (..), latestVersions)

admin, editor, reader :: As
admin = As "admin"
editor = As "editor"
reader = As "reader"

-- | The contract, for a backend made afresh for each example, as in
-- "Wiki.App.Backend.Contract".
spec :: forall m -> (MonadWiki m, MonadComments m, MonadNotifications m, MonadAdmin m) => (ActionWith (Fixture m) -> IO ()) -> Spec
spec _ withFixture = around withFixture $ describe "MonadAdmin contract" $ do
  reading
  paging
  refusing
  administrators
  creators
  accounts
  removing
  groups
  membership
  letsIn
  serverSide
  backingUp
  observing

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
  pure [u.login.text | u <- d.users, u.id `Set.member` ids]

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
    map (\u -> u.login.text) d.users `shouldBe` ["admin", "editor", "reader"]
    d.administrators `shouldBe` Set.singleton adminId
    d.creators `shouldBe` Set.singleton editorId
    (d.disabled, d.withPassword) `shouldBe` (mempty, mempty)
    -- Nobody signs in with a provider in a newly made wiki, so everyone may
    -- be given a password.
    (d.identities, d.providerOnly) `shouldBe` (mempty, mempty)
    map (\g -> g.name) d.groups `shouldBe` ["writers"]
    Map.elems d.membership `shouldBe` [Set.singleton editorId]
    Map.keys d.membership `shouldBe` map (\g -> g.id) d.groups

--------------------------------------------------------------------------------
-- A page of users

-- | A query for users, built whole.
users :: Int -> Int -> Text -> Bool -> Bool -> UserQuery
users offset limit search onlyAdministrators onlyDisabled = UserQuery {offset, limit, search, administrators = onlyAdministrators, disabled = onlyDisabled}

-- | The logins of a page's users.
loginsOf :: UserPage -> [Text]
loginsOf p = [u.user.login.text | u <- p.users]

paging :: (MonadWiki m, MonadAdmin m) => SpecWith (Fixture m)
paging = describe "userPage" $ do
  it "orders the users by login ignoring case, pages them, and counts them all" $ \(Fixture run) -> do
    for_ ["Zoe", "bob", "Carla"] $ \login ->
      run admin (createUser NewAccount {login, displayName = login <> " Example", password = Password "a good password", email = Nothing}) >>= ok
    page1 <- run admin (userPage (users 0 4 "" False False)) >>= ok
    loginsOf page1 `shouldBe` ["admin", "bob", "Carla", "editor"]
    (page1.total, page1.offset) `shouldBe` (6, 0)
    page2 <- run admin (userPage (users 4 4 "" False False)) >>= ok
    loginsOf page2 `shouldBe` ["reader", "Zoe"]
    (page2.total, page2.offset) `shouldBe` (6, 4)
    beyond <- run admin (userPage (users 8 4 "" False False)) >>= ok
    (loginsOf beyond, beyond.total) `shouldBe` ([], 6)

  it "orders logins with punctuation by their code points, as the application does" $ \(Fixture run) -> do
    for_ ["jsmith", "j.smith", "ja", "J.Zed"] $ \login ->
      run admin (createUser NewAccount {login, displayName = "", password = Password "a good password", email = Nothing}) >>= ok
    -- A database ordering by a language's rules would pass over the dots:
    -- ja, j.smith, jsmith, J.Zed.
    loginsOf <$> (run admin (userPage (users 0 25 "j" False False)) >>= ok) `shouldReturn` ["j.smith", "J.Zed", "ja", "jsmith"]
    loginsOf <$> (run admin (userPage (users 1 2 "j" False False)) >>= ok) `shouldReturn` ["J.Zed", "ja"]

  it "finds every word in the login or the display name, ignoring case" $ \(Fixture run) -> do
    loginsOf <$> (run admin (userPage (users 0 25 "EDI" False False)) >>= ok) `shouldReturn` ["editor"]
    loginsOf <$> (run admin (userPage (users 0 25 "rita" False False)) >>= ok) `shouldReturn` ["reader"]
    loginsOf <$> (run admin (userPage (users 0 25 "ad min" False False)) >>= ok) `shouldReturn` ["admin"]
    nobody <- run admin (userPage (users 0 25 "nobody" False False)) >>= ok
    (loginsOf nobody, nobody.total) `shouldBe` ([], 0)

  it "keeps only the administrators, or only the disabled accounts" $ \(Fixture run) -> do
    readerId <- idOf run reader
    void (run admin (setDisabled readerId True) >>= ok)
    loginsOf <$> (run admin (userPage (users 0 25 "" True False)) >>= ok) `shouldReturn` ["admin"]
    disabled <- run admin (userPage (users 0 25 "" False True)) >>= ok
    loginsOf disabled `shouldBe` ["reader"]
    (\u -> u.disabled) <$> disabled.users `shouldBe` [True]
    loginsOf <$> (run admin (userPage (users 0 25 "" True True)) >>= ok) `shouldReturn` []

  it "answers what the directory says, user by user, with every group" $ \(Fixture run) -> do
    writers <- groupNamed run "writers"
    page <- run admin (userPage (users 0 25 "" False False)) >>= ok
    d <- directoryNow run
    page `shouldBe` pageOfDirectory (users 0 25 "" False False) d
    (\u -> (u.user.login.text, u.administrator, u.createsSpaces, u.groups)) <$> page.users
      `shouldBe` [("admin", True, False, []), ("editor", False, True, [writers.id]), ("reader", False, False, [])]
    map (\g -> g.name) page.groups `shouldBe` ["writers"]

  it "refuses an offset below 0 and a limit outside 1 to 100, and anyone who does not administer the wiki first" $ \(Fixture run) -> do
    run admin (userPage (users 0 0 "" False False)) >>= shouldBeInvalid
    run admin (userPage (users 0 101 "" False False)) >>= shouldBeInvalid
    run admin (userPage (users (-1) 25 "" False False)) >>= shouldBeInvalid
    void (run admin (userPage (users 0 100 "" False False)) >>= ok)
    for_ [Anonymous, editor, reader] $ \who -> do
      run who (userPage (users 0 25 "" False False)) >>= (`shouldFailWith` Forbidden)
      run who (userPage (users 0 0 "" False False)) >>= (`shouldFailWith` Forbidden)

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
      run who (createUser NewAccount {login = "", displayName = "", password = Password "", email = Nothing}) >>= (`shouldFailWith` Forbidden)
      run who (setPassword readerId (Password "a good password")) >>= (`shouldFailWith` Forbidden)
      run who (setPassword nobody (Password "")) >>= (`shouldFailWith` Forbidden)
      run who (sendPasswordLink readerId) >>= (`shouldFailWith` Forbidden)
      run who (sendPasswordLink nobody) >>= (`shouldFailWith` Forbidden)
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
    -- They may now administer the wiki themselves.
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
accounts = describe "createUser, setPassword, sendPasswordLink and setDisabled" $ do
  it "make a user with a password, listed by login, their login the name if none is given" $ \(Fixture run) -> do
    made <- run admin (createUser NewAccount {login = " bea ", displayName = "", password = Password "bea's password", email = Nothing}) >>= ok
    (made.user.login.text, made.user.displayName, made.hasPassword, made.disabled) `shouldBe` ("bea", "bea", True, False)
    d <- directoryNow run
    map (\u -> u.login.text) d.users `shouldBe` ["admin", "bea", "editor", "reader"]
    d.withPassword `shouldBe` Set.singleton made.user.id
    named <- run admin (createUser NewAccount {login = "cid", displayName = " Cid ", password = Password "cid's password", email = Nothing}) >>= ok
    named.user.displayName `shouldBe` "Cid"

  it "refuse a login that is taken in any case, one that cannot be a login, and a short password" $ \(Fixture run) -> do
    let new login password = run admin (createUser NewAccount {login, displayName = "", password = Password password, email = Nothing})
    new "EDITOR" "a good password" >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected a conflict, got " <> show other)
    new "" "a good password" >>= shouldBeInvalid
    new "two words" "a good password" >>= shouldBeInvalid
    new "~operator" "a good password" >>= shouldBeInvalid
    new "dee" "short" >>= shouldBeInvalid
    map (\u -> u.login.text) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]

  it "give a user a password, and refuse a short one" $ \(Fixture run) -> do
    readerId <- idOf run reader
    run admin (setPassword readerId (Password "short")) >>= shouldBeInvalid
    account <- run admin (setPassword readerId (Password "rita's password")) >>= ok
    (account.user.login.text, account.hasPassword) `shouldBe` ("reader", True)
    (\d -> d.withPassword) <$> directoryNow run `shouldReturn` Set.singleton readerId
    run admin (setPassword (UserId "user-nobody") (Password "a good password")) >>= (`shouldFailWith` NotFound)

  -- A newly made wiki sends no mail (the demo never does, and the server
  -- only once its mail server is set): a link is refused with the reason,
  -- after the user is found. What a server that sends mail does with a link
  -- is covered by the server's tests (wiki-server's Test.Server.Hygiene).
  it "mail no link to choose a password where nothing is mailed, saying why, and find nobody for an id that is none" $ \(Fixture run) -> do
    readerId <- idOf run reader
    run admin (sendPasswordLink readerId) >>= shouldBeInvalid
    run admin (sendPasswordLink (UserId "user-nobody")) >>= (`shouldFailWith` NotFound)
    -- Nothing was changed.
    (\d -> d.withPassword) <$> directoryNow run `shouldReturn` mempty

  it "disable a login, whose user is then nobody, and enable it again" $ \(Fixture run) -> do
    readerId <- idOf run reader
    projects <- run admin (getSpace [slug "team", slug "projects"]) >>= ok
    account <- run admin (setDisabled readerId True) >>= ok
    account.disabled `shouldBe` True
    (\d -> d.disabled) <$> directoryNow run `shouldReturn` Set.singleton readerId
    -- Still in the directory, but they count as nobody signed in, and see
    -- what nobody sees.
    map (\u -> u.login.text) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]
    (\s -> s.user) <$> run reader session `shouldReturn` Nothing
    run reader (listPages projects.id) >>= (`shouldFailWith` NotFound)
    enabled <- run admin (setDisabled readerId False) >>= ok
    enabled.disabled `shouldBe` False
    (\s -> (\u -> u.login.text) <$> s.user) <$> run reader session `shouldReturn` Just "reader"
    void (run reader (listPages projects.id) >>= ok)
    run admin (setDisabled (UserId "user-nobody") True) >>= (`shouldFailWith` NotFound)

--------------------------------------------------------------------------------
-- Removing an account

removing :: (MonadWiki m, MonadComments m, MonadNotifications m, MonadAdmin m) => SpecWith (Fixture m)
removing = describe "removeUser" $ do
  it "refuses an enabled login, one's own account, anyone but an administrator, and an id that is no user's" $ \(Fixture run) -> do
    editorId <- idOf run editor
    adminId <- idOf run admin
    readerId <- idOf run reader
    run admin (removeUser editorId) >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected a conflict, got " <> show other)
    run admin (removeUser adminId) >>= shouldBeInvalid
    void (run admin (setDisabled readerId True) >>= ok)
    run editor (removeUser readerId) >>= (`shouldFailWith` Forbidden)
    run admin (removeUser (UserId "user-nobody")) >>= (`shouldFailWith` NotFound)
    map (\u -> u.login.text) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]

  it "removes a disabled account with its groups and grants, keeps what they wrote under their login, and frees the login" $ \(Fixture run) -> do
    editorId <- idOf run editor
    editorName <- run editor currentUser >>= maybe (assertFailure "nobody is the editor") (pure . (\u -> u.displayName))
    blog <- run admin (getSpace [slug "blog"]) >>= ok
    void (run admin (setWatching (WatchSpace blog.id) True) >>= ok)
    made <- run editor (createPage blog.id Nothing "Field notes" "First words.") >>= ok
    saved <- run editor (savePage made.id made.updatedAt "Field notes" "Second words.") >>= ok
    void (run editor (saveDraft saved.id saved.updatedAt "Field notes" "Words not saved yet.") >>= ok)
    void (run editor (openThread saved.id Nothing "A note on these notes.") >>= ok)
    void (run admin (setSpaceGrant blog.id (SubjectUser editorId) AdministerSpace True) >>= ok)
    void (run admin (setCreateSpaces editorId True) >>= ok)
    void (run admin (setDisabled editorId True) >>= ok)
    run admin (removeUser editorId) >>= ok
    d <- directoryNow run
    map (\u -> u.login.text) d.users `shouldBe` ["admin", "reader"]
    Set.member editorId (d.creators <> d.disabled) `shouldBe` False
    writers <- groupNamed run "writers"
    membersOf run writers `shouldReturn` []
    access <- run admin (spaceAccess blog.id) >>= ok
    [g | g <- access.grants, g.subject == SubjectUser editorId] `shouldBe` []
    -- The page, its versions and the comment stay, by the login.
    let former = absentAuthor (formerAuthor "editor")
        authors = map (\v -> v.author) <$> (run admin (listVersions saved.id latestVersions) >>= ok)
        commenters = (\ts -> [c.author | t <- ts, c <- t.comments]) <$> (run admin (listThreads saved.id) >>= ok)
    authors `shouldReturn` [Just former, Just former]
    commenters `shouldReturn` [former]
    -- The administrator's notifications of what they did stay, by the name
    -- they had then.
    told <- (\n -> n.items) <$> (run admin notifications >>= ok)
    told `shouldNotBe` []
    [(n.actor.id, n.actor.name) | n <- told] `shouldBe` [(formerAuthor "editor", editorName) | _ <- told]
    -- The login may be taken by a new account, which is someone else.
    again <- run admin (createUser NewAccount {login = "editor", displayName = "Another editor", password = Password "a new editor's password", email = Nothing}) >>= ok
    again.user.id `shouldNotBe` editorId
    authors `shouldReturn` [Just former, Just former]
    commenters `shouldReturn` [former]

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
    run Anonymous (getSpace [slug "blog"]) >>= (`shouldFailWith` NotFound)
    -- Someone signed in reads the public spaces as before.
    (\s -> s.grants.access) <$> run reader session `shouldReturn` Closed
    run reader (getSpace [slug "blog"]) >>= ok >>= \s -> s.name `shouldBe` "Blog"
    _ <- run admin (setWikiSettings defaultSettings) >>= ok
    run Anonymous (getSpace [slug "blog"]) >>= ok >>= \s -> s.name `shouldBe` "Blog"
    (\s -> s.grants.access) <$> run Anonymous session `shouldReturn` Open

  it "keep whether new accounts create spaces" $ \(Fixture run) -> do
    let creating = WikiSettings {access = Open, newAccountsCreateSpaces = True, adminCreatesPasswordAccounts = True}
    _ <- run admin (setWikiSettings creating) >>= ok
    run admin wikiSettings >>= ok >>= (`shouldBe` creating)

  it "leave accounts with a password to the console while the setting is off, and nothing else" $ \(Fixture run) -> do
    let consoleOnly = WikiSettings {access = Open, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = False}
        bea = NewAccount {login = "bea", displayName = "", password = Password "bea's password", email = Nothing}
    (\d -> d.adminCreatesPasswordAccounts) <$> directoryNow run `shouldReturn` True
    run admin (setWikiSettings consoleOnly) >>= ok >>= (`shouldBe` consoleOnly)
    run admin wikiSettings >>= ok >>= (`shouldBe` consoleOnly)
    (\d -> d.adminCreatesPasswordAccounts) <$> directoryNow run `shouldReturn` False
    run admin (createUser bea) >>= (`shouldFailWith` Forbidden)
    -- Refused before the login and the password are looked at.
    run admin (createUser NewAccount {login = "", displayName = "", password = Password "", email = Nothing}) >>= (`shouldFailWith` Forbidden)
    map (\u -> u.login.text) . (\d -> d.users) <$> directoryNow run `shouldReturn` ["admin", "editor", "reader"]
    -- An existing user's password, a link to choose one, and invitations
    -- are as before: a link is refused only because nothing is mailed.
    readerId <- idOf run reader
    (\a -> a.hasPassword) <$> (run admin (setPassword readerId (Password "rita's password")) >>= ok) `shouldReturn` True
    run admin (sendPasswordLink readerId) >>= shouldBeInvalid
    void (run admin (invite "bea@example.org") >>= ok)
    -- Turned on again, the administration creates accounts again.
    run admin (setWikiSettings defaultSettings) >>= ok >>= (`shouldBe` defaultSettings)
    (\a -> a.user.login.text) <$> (run admin (createUser bea) >>= ok) `shouldReturn` "bea"

  it "invite an address, with the link's secret when it is not mailed, in place of any invitation it had" $ \(Fixture run) -> do
    made <- run admin (invite "  bea@example.org ") >>= ok
    (made.invitation.email.text, made.invitation.expired, isJust made.token) `shouldBe` ("bea@example.org", False, True)
    made.invitation.expiresAt `shouldSatisfy` (> made.invitation.createdAt)
    again <- run admin (invite "BEA@example.org") >>= ok
    again.token `shouldNotBe` made.token
    listed <- run admin invitations >>= ok
    map (\i -> i.email.text) listed.invitations `shouldBe` ["BEA@example.org"]
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
closedWiki = WikiSettings {access = Closed, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True}

--------------------------------------------------------------------------------
-- The server's own settings

-- | Settings with an address, a mail server with this password and user,
-- and a provider with this secret.
serverWith :: Maybe Text -> Maybe Text -> Maybe Text -> ServerSettingsChange
serverWith user password secret =
  ServerSettings
    { publicUrl = Just (Url "https://wiki.example.org/")
    , mail = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user, password, from = "wiki@example.org"}
    , providers = [ProviderSettings {name = "google", kind = Google, clientId = "id.apps.googleusercontent.com", issuer = Nothing, secret}]
    , assistantHosts = []
    , boxes = []
    , homePage = defaultHomePage
    }

-- | Settings as they are, with no kinds of box.
withoutBoxes :: ServerSettingsOf s -> ServerSettingsOf s
withoutBoxes ServerSettings {publicUrl, mail, providers, assistantHosts} = ServerSettings {publicUrl, mail, providers, assistantHosts, boxes = [], homePage = defaultHomePage}

-- | Settings with nothing set but these kinds of box.
boxesOnly :: [BoxKind] -> ServerSettingsChange
boxesOnly boxes = ServerSettings {publicUrl = Nothing, mail = Nothing, providers = [], assistantHosts = [], boxes, homePage = defaultHomePage}

serverSide :: (MonadAdmin m, MonadWiki m, MonadComments m) => SpecWith (Fixture m)
serverSide = describe "serverSettings and setServerSettings" $ do
  it "reuses page saves, attachments, drafts and versions for the home document" $ \(Fixture run) -> do
    (space, page) <- run admin getHomeDocument >>= ok
    spaces <- run admin listSpaces
    map (\x -> x.id) spaces `shouldNotContain` [space.id]
    initialVersions <- run admin (listVersions page.id latestVersions) >>= ok
    saved <- run admin (savePage page.id page.updatedAt "Welcome" "Shared **content**.") >>= ok
    (_, readBack) <- run Anonymous getHomeDocument >>= ok
    readBack.body `shouldBe` saved.body
    run editor (savePage page.id saved.updatedAt "Changed" "No") >>= (`shouldFailWith` Forbidden)
    for_ [Anonymous, editor, reader] $ \who -> run who (setHomePage defaultHomePage) >>= (`shouldFailWith` Forbidden)
    _ <- run admin (saveDraft page.id saved.updatedAt "Draft" "Unsaved") >>= ok
    draft <- run admin (getDraft page.id) >>= ok
    draft `shouldSatisfy` isJust
    attachment <- run admin (uploadAttachment page.id "home.txt" "text/plain" "kept") >>= ok
    (_, attached) <- run admin getHomeDocument >>= ok
    map (\x -> x.id) attached.attachments `shouldContain` [attachment.id]
    versions <- run Anonymous (listVersions page.id latestVersions) >>= ok
    length versions `shouldBe` length initialVersions + 1
    run admin (listThreads page.id) >>= (`shouldFailWith` NotFound)
    run admin (openThread page.id Nothing "Disabled") >>= (`shouldFailWith` NotFound)
    restored <- run admin (restoreVersion page.id page.updatedAt saved.updatedAt) >>= ok
    restored.title `shouldBe` page.title
    run admin (getDraft page.id) >>= ok >>= (`shouldBe` Nothing)
    run admin (movePage page.id space.id Nothing) >>= shouldBeInvalid
    run admin (deletePage page.id) >>= shouldBeInvalid
    run admin (createPage space.id Nothing "Child" "") >>= shouldBeInvalid

  it "changes options without replaying stale content or forging the document reference" $ \(Fixture run) -> do
    old <- run admin session
    (_, page) <- run admin getHomeDocument >>= ok
    saved <- run admin (savePage page.id page.updatedAt "Newer title" "Newer content") >>= ok
    let stale = old.homePage {SS.title = "Stale", SS.body = "Stale", SS.showSpaces = False, SS.document = Nothing}
    options <- run admin (setHomePage stale) >>= ok
    options.title `shouldBe` saved.title
    options.body `shouldBe` saved.body
    options.document `shouldBe` old.homePage.document
    options.showSpaces `shouldBe` False
    _ <- run admin (setServerSettings noServerSettings {SS.homePage = stale}) >>= ok
    (_, final) <- run admin getHomeDocument >>= ok
    final.updatedAt `shouldBe` saved.updatedAt
    final.body `shouldBe` "Newer content"
    run admin (setHomePage stale {SS.title = " "}) >>= shouldBeInvalid

  it "exposes only the opted-in home document to closed-wiki visitors and revokes it" $ \(Fixture run) -> do
    (_, page) <- run admin getHomeDocument >>= ok
    initialVersions <- run admin (listVersions page.id latestVersions) >>= ok
    _ <- run admin (savePage page.id page.updatedAt "Public landing" "Welcome") >>= ok
    _ <- run admin (setWikiSettings closedWiki) >>= ok
    run Anonymous getHomeDocument >>= (`shouldFailWith` NotFound)
    run Anonymous session >>= (`shouldBe` defaultHomePage) . (\s -> s.homePage)
    settings <- run admin session
    _ <- run admin (setHomePage settings.homePage {SS.showAnonymous = True}) >>= ok
    visitor <- run Anonymous session
    visitor.grants.access `shouldBe` Closed
    visitor.homePage.showAnonymous `shouldBe` True
    (_, shown) <- run Anonymous getHomeDocument >>= ok
    shown.body `shouldBe` "Welcome"
    run Anonymous listSpaces `shouldReturn` []
    run Anonymous (listVersions page.id latestVersions) >>= ok >>= (\vs -> length vs `shouldBe` length initialVersions + 1)
    run Anonymous (savePage page.id shown.updatedAt "No" "No") >>= (`shouldFailWith` Forbidden)
    _ <- run admin (setHomePage settings.homePage {SS.showAnonymous = False}) >>= ok
    run Anonymous getHomeDocument >>= (`shouldFailWith` NotFound)
    run Anonymous (listVersions page.id latestVersions) >>= (`shouldFailWith` NotFound)

  -- The demo defines a kind of box, which the Markdown guide shows; a
  -- server has none until its administrator defines one.
  it "have nothing set at first but kinds of box, and are refused to whoever does not administer the wiki" $ \(Fixture run) -> do
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings) . withoutBoxes
    for_ [Anonymous, editor, reader] $ \who -> do
      run who serverSettings >>= (`shouldFailWith` Forbidden)
      run who (setServerSettings (serverWith Nothing Nothing (Just "s"))) >>= (`shouldFailWith` Forbidden)
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings) . withoutBoxes

  it "keep what is written, and say of each secret only whether it is set" $ \(Fixture run) -> do
    set <- run admin (setServerSettings (serverWith (Just "wiki") (Just "pw") (Just "s"))) >>= ok
    run admin serverSettings >>= ok >>= (`shouldBe` set)
    set {SS.homePage = defaultHomePage} `shouldBe` (maybe NotSet (const Set) <$> serverWith (Just "wiki") (Just "pw") (Just "s"))

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
    run admin (setServerSettings (serverWith Nothing Nothing (Just "s")) {publicUrl = Just (Url "wiki.example.org")}) >>= shouldBeInvalid
    run admin (setServerSettings (serverWith (Just "wiki") Nothing (Just "s"))) >>= shouldBeInvalid
    run admin serverSettings >>= ok >>= (`shouldBe` noServerSettings) . withoutBoxes

  it "keep the kinds of box written, named in lower case, and refuse one of GitHub's five" $ \(Fixture run) -> do
    set <- run admin (setServerSettings (boxesOnly [BoxKind {name = " Aside ", label = "", colour = Grey, icon = Star}])) >>= ok
    set.boxes `shouldBe` [BoxKind {name = "aside", label = "Aside", colour = Grey, icon = Star}]
    run admin serverSettings >>= ok >>= (`shouldBe` set.boxes) . (\s -> s.boxes)
    run admin (setServerSettings (boxesOnly [BoxKind {name = "note", label = "", colour = Red, icon = NoIcon}])) >>= shouldBeInvalid
    run admin (setServerSettings (boxesOnly [BoxKind {name = "fun fact", label = "", colour = Red, icon = NoIcon}])) >>= shouldBeInvalid
    run admin serverSettings >>= ok >>= (`shouldBe` set.boxes) . (\s -> s.boxes)

-- | The backups (WP4.9 of docs/PLAN.md): off until an administrator turns
-- them on, and visible to administrators only. Their stored and checked
-- settings, and a backup being made, are covered by the server's tests;
-- the demo makes none.
backingUp :: (MonadAdmin m) => SpecWith (Fixture m)
backingUp = describe "backups, setBackupSettings and backUpNow" $
  it "are off at first, with none made, and refused to whoever does not administer the wiki" $ \(Fixture run) -> do
    b <- run admin backups >>= ok
    (b.settings, b.last, b.running) `shouldBe` (defaultBackupSettings, Nothing, False)
    b.settings.enabled `shouldBe` False
    for_ [Anonymous, editor, reader] $ \who -> do
      run who backups >>= (`shouldFailWith` Forbidden)
      run who (setBackupSettings defaultBackupSettings {enabled = True}) >>= (`shouldFailWith` Forbidden)
      run who backUpNow >>= (`shouldFailWith` Forbidden)

-- | The audit log and the server's status (WP4.10 of docs/PLAN.md): what
-- each backend has of them differs (the demo keeps no log and has no
-- server), but only an administrator of the wiki reads either.
observing :: (MonadAdmin m) => SpecWith (Fixture m)
observing = describe "activity and serverStatus" $
  it "are refused to whoever does not administer the wiki" $ \(Fixture run) -> do
    for_ [editor, reader] $ \who -> do
      run who (activity firstPage) >>= (`shouldFailWith` Forbidden)
      run who serverStatus >>= (`shouldFailWith` Forbidden)
    logged <- run admin (activity firstPage) >>= ok
    length logged.entries `shouldSatisfy` (<= 50)
