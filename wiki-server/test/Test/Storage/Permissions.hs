-- | The permission context the storage keeps in memory (WP5.24 of
-- docs/PLAN.md). The permission context is every space, every grant, and
-- the active user with their groups: what a permission check reads. A read
-- transaction takes it from memory when the database's generation
-- (@permissions_generation@) is the one kept with it, and reads it from the
-- database otherwise.
--
-- The generation goes up with every write that changes the permission
-- context: a change to @spaces@, @global_grants@, @space_grants@ or
-- @group_members@, a user added or deleted, or a change to a user's
-- @login@, @display_name@ or @disabled@ (the columns the permission context
-- reads; 'Wiki.Server.Storage.Rows.bumpPermissions' lists them). A change
-- to a user's other columns (password, e-mail, notification settings) does
-- not move it. The first test runs every write the storage has once, in turn,
-- and checks two things after each: the generation went up exactly for the
-- writes listed as changing the permission context, and the permission
-- context read afresh from the database did not change without the
-- generation going up. A new write that changes the permission context but
-- forgets the generation fails the second check as soon as it is listed
-- here.
--
-- The other tests check that a reader sees each kind of change at its next
-- read: a grant given through the storage, a grant given by another
-- process (a second storage on the same database, as the console opens
-- one), a user put in a group or taken out of it, and a user disabled by
-- another process, who is refused at once.
module Test.Storage.Permissions (spec) where

import Protolude
import Test.Database (Backing)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Account (NewAccount (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Id
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (Grants (..), SpacePermission (..), Subject (..))
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.User (Group (..), Login (..), Password (..), User (..))
import Wiki.Server.Accounts qualified as Accounts
import Wiki.Server.Storage
import Wiki.Server.Storage.Rows (loadAccountFlags, loadGrants, loadMembership, loadSpaces, loadUsers, permissionsGeneration)

spec :: Backing -> Spec
spec backing = describe "the permission context kept in memory" $ do
  it "has its generation bumped by every write that changes the permission context, and by no other" $ withDemo backing $ \st -> do
    -- The import of the demo's wiki gave users, groups, spaces and grants.
    reading st permissionsGeneration >>= (`shouldSatisfy` (> 0))
    ritaId <- userId st "reader"
    let admin :: StoredWiki IO a -> IO a
        admin = runStoredWiki st Administrator
    docs <- admin (getSpace (path "docs")) >>= ok
    space <- admin (createSpace Nothing "Fresh") >>= ok
    page <- admin (createPage space.id Nothing "A page" "Text.") >>= ok
    other <- admin (createPage space.id Nothing "Another page" "Text.") >>= ok
    crew <- admin (createGroup "Fresh group") >>= ok
    let writes :: [(Text, Bool, IO ())]
        writes =
          [ ("createSpace", True, void (admin (createSpace Nothing "Fresher") >>= ok))
          , ("renameSpace", True, void (admin (renameSpace space.id "Renamed") >>= ok))
          , ("setSpacePublic", True, void (admin (setSpacePublic space.id True) >>= ok))
          , ("setSpaceMathMacros", True, void (admin (setSpaceMathMacros space.id "\\R: \\mathbb{R}") >>= ok))
          , ("setSpaceProfile", True, void (admin (setSpaceProfile space.id SpaceProfile {description = "Kept.", icon = Just (IconEmoji "x"), homePage = Nothing, blog = False}) >>= ok))
          , ("uploadSpaceIcon", True, void (admin (uploadSpaceIcon space.id "image/png" "png bytes") >>= ok))
          , ("setSpaceGrant", True, void (admin (setSpaceGrant space.id (SubjectUser ritaId) View True) >>= ok))
          , ("setSpaceOrder", True, void (admin (setSpaceOrder space.id ChildPages ByHand) >>= ok))
          , ("moveSpace", True, void (admin (moveSpace space.id (Just docs.id)) >>= ok))
          , ("setSpaceOrder of subspaces", True, void (admin (setSpaceOrder docs.id ChildSpaces ByHand) >>= ok))
          , ("createSpace of a subspace", True, void (admin (createSpace (Just docs.id) "Sibling") >>= ok))
          , ("shiftSpace", True, admin (getSpace (path "docs/sibling")) >>= ok >>= \sibling -> void (admin (shiftSpace sibling.id ShiftUp) >>= ok))
          , ("createPage", False, void (admin (createPage space.id Nothing "Third page" "Text.") >>= ok))
          , ("savePage", False, admin (getPage space.id (path "a-page")) >>= ok >>= \p -> void (admin (savePage p.id p.updatedAt p.title "More text.") >>= ok))
          , ("shiftPage", False, void (admin (shiftPage other.id ShiftUp) >>= ok))
          , ("setPageTemplate", False, void (admin (setPageTemplate other.id True) >>= ok))
          , ("uploadAttachment", False, void (admin (uploadAttachment page.id "a.png" "image/png" "png bytes") >>= ok))
          , ("saveDraft", False, admin (getPage space.id (path "a-page")) >>= ok >>= \p -> void (admin (saveDraft p.id p.updatedAt p.title "Draft.") >>= ok))
          , ("discardDraft", False, void (admin (discardDraft page.id) >>= ok))
          , ("setWatching", False, void (runStoredWiki st (AsUser ritaId) (setWatching (WatchPage page.id) True) >>= ok))
          , ("movePage within its space", False, void (admin (movePage other.id space.id (Just page.id)) >>= ok))
          , ("movePage to another space", False, void (admin (movePage other.id docs.id Nothing) >>= ok))
          , ("deletePage", False, void (admin (deletePage other.id) >>= ok))
          , ("setSpaceProfile with a home page", True, void (admin (setSpaceProfile space.id SpaceProfile {description = "", icon = Nothing, homePage = Just page.id, blog = False}) >>= ok))
          , ("deletePage of a home page", True, void (admin (deletePage page.id) >>= ok))
          , ("createGroup", False, void (admin (createGroup "Another group") >>= ok))
          , ("renameGroup", False, void (admin (renameGroup crew.id "Renamed group") >>= ok))
          , ("addMember", True, void (admin (addMember crew.id ritaId) >>= ok))
          , ("removeMember", True, void (admin (removeMember crew.id ritaId) >>= ok))
          , ("deleteGroup", True, void (admin (deleteGroup crew.id) >>= ok))
          , ("setAdministrator", True, void (admin (setAdministrator ritaId True) >>= ok))
          , ("setCreateSpaces", True, void (admin (setCreateSpaces ritaId True) >>= ok))
          , ("createUser", True, void (admin (createUser NewAccount {login = "fresh", displayName = "Fresh", password = Password "a long enough password", email = Nothing}) >>= ok))
          , ("setPassword", False, void (admin (setPassword ritaId (Password "another long password")) >>= ok))
          , ("setDisabled", True, void (admin (setDisabled ritaId True) >>= ok))
          , ("setDisabled again", True, void (admin (setDisabled ritaId False) >>= ok))
          , ("setWikiSettings", False, void (admin wikiSettings >>= ok >>= \w -> admin (setWikiSettings w) >>= ok))
          , ("Accounts.setDisabled", True, void (Accounts.setDisabled st ritaId True >>= ok))
          , ("Accounts.setDisabled again", True, void (Accounts.setDisabled st ritaId False >>= ok))
          , ("Accounts.setAdministrator", True, void (Accounts.setAdministrator st ritaId False >>= ok))
          , ("Accounts.setPassword", False, void (Accounts.setPassword st ritaId (Password "a third long password") >>= ok))
          , ("deleteSpace", True, void (admin (deleteSpace space.id) >>= ok))
          ]
    for_ writes $ \(name, bumps, write) -> do
      earlier <- reading st permissionsGeneration
      held <- freshContext st
      write
      later <- reading st permissionsGeneration
      changed <- (/= held) <$> freshContext st
      when (changed && later == earlier) $
        assertFailure (toS name <> " changed the permission context without bumping its generation")
      when (bumps /= (later > earlier)) $
        assertFailure (toS name <> (if bumps then " did not bump" else " bumped") <> " the generation")

  it "sees a grant given through the storage at the next read" $ withDemo backing $ \st -> do
    rita <- whoFor st (As "reader")
    ritaId <- userId st "reader"
    team <- runStoredWiki st Administrator (getSpace (path "team")) >>= ok
    -- Twice, so that the second read is from memory.
    replicateM_ 2 $ runStoredWiki st rita (spaceHome team.id) `shouldReturn` Left NotFound
    _ <- runStoredWiki st Administrator (setSpaceGrant team.id (SubjectUser ritaId) View True) >>= ok
    replicateM_ 2 $ runStoredWiki st rita (spaceHome team.id) >>= (`shouldSatisfy` isRight)
    _ <- runStoredWiki st Administrator (setSpaceGrant team.id (SubjectUser ritaId) View False) >>= ok
    runStoredWiki st rita (spaceHome team.id) `shouldReturn` Left NotFound

  it "sees a grant given by another process at the next read" $ withDemo backing $ \st -> do
    rita <- whoFor st (As "reader")
    ritaId <- userId st "reader"
    team <- runStoredWiki st Administrator (getSpace (path "team")) >>= ok
    replicateM_ 2 $ runStoredWiki st rita (spaceHome team.id) `shouldReturn` Left NotFound
    withStorageAside (storagePlace st) $ \console ->
      void (runStoredWiki console Administrator (setSpaceGrant team.id (SubjectUser ritaId) View True) >>= ok)
    runStoredWiki st rita (spaceHome team.id) >>= (`shouldSatisfy` isRight)
    -- Another process's administrator is seen at once as well.
    runStoredWiki st rita (setSpacePublic team.id True) `shouldReturn` Left Forbidden
    withStorageAside (storagePlace st) $ \console -> void (Accounts.setAdministrator console ritaId True >>= ok)
    runStoredWiki st rita (setSpacePublic team.id True) >>= (`shouldSatisfy` isRight)

  it "sees a user put in a group, or taken out of it, at the next read" $ withDemo backing $ \st -> do
    rita <- whoFor st (As "reader")
    ritaId <- userId st "reader"
    team <- runStoredWiki st Administrator (getSpace (path "team")) >>= ok
    crew <- runStoredWiki st Administrator (createGroup "Team readers") >>= ok
    _ <- runStoredWiki st Administrator (setSpaceGrant team.id (SubjectGroup crew.id) View True) >>= ok
    replicateM_ 2 $ runStoredWiki st rita (spaceHome team.id) `shouldReturn` Left NotFound
    _ <- runStoredWiki st Administrator (addMember crew.id ritaId) >>= ok
    replicateM_ 2 $ runStoredWiki st rita (spaceHome team.id) >>= (`shouldSatisfy` isRight)
    _ <- runStoredWiki st Administrator (removeMember crew.id ritaId) >>= ok
    runStoredWiki st rita (spaceHome team.id) `shouldReturn` Left NotFound

  it "refuses a user disabled by another process at once" $ withDemo backing $ \st -> do
    rita <- whoFor st (As "reader")
    ritaId <- userId st "reader"
    replicateM_ 2 $ runStoredWiki st rita session >>= \s -> (\u -> u.login.text) <$> s.user `shouldBe` Just "reader"
    withStorageAside (storagePlace st) $ \console -> void (Accounts.setDisabled console ritaId True >>= ok)
    runStoredWiki st rita session >>= \s -> s.user `shouldBe` Nothing
    withStorageAside (storagePlace st) $ \console -> void (Accounts.setDisabled console ritaId False >>= ok)
    runStoredWiki st rita session >>= \s -> (\u -> u.login.text) <$> s.user `shouldBe` Just "reader"
  where
    userId st login = userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) (\u -> pure u.id)
    -- A read of a space's home, which needs the right to view the space.
    spaceHome sid = fmap (const ()) <$> listPages sid

-- | The permission context as the database holds it now: every space and
-- grant, every user with whether they are disabled, and every group's
-- members.
freshContext :: Storage -> IO (Map SpaceId Space, Grants, [User], Set UserId, Map GroupId (Set UserId))
freshContext st = reading st ((,,,,) <$> loadSpaces <*> loadGrants <*> loadUsers <*> (fst <$> loadAccountFlags) <*> loadMembership)
