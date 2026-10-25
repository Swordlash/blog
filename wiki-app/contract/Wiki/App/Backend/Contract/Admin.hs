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
import Wiki.Api.Admin (Directory (..))
import Wiki.App.Backend
import Wiki.App.Backend.Admin
import Wiki.App.Backend.Contract (As (..), Fixture (..), Run)
import Wiki.Core.Id
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..))
import Wiki.Core.Slug (mkSlug)
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
  groups
  membership

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
