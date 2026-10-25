-- | The administration's users and groups ("Wiki.App.View.Admin") in a
-- browser, over the demo's wiki: an administrator marks another user as
-- one, who then has the administration, and unmarks them; nobody is
-- offered to unmark themself; groups are made, renamed and deleted, users
-- put in them and taken out, and what a group may do follows its members.
module Test.Browser.Admin (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, start, startKept)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "marks a user as an administrator, who then has the administration, and unmarks them" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    switchShouldBe ui "editor" False
    switchOf ui "editor" >>= click
    switchShouldBe ui "editor" True
    -- Edgar is an administrator now: he has the way here, and the page.
    switchTo ui "editor"
    _ <- find ui ".wiki-header a.admin-link"
    switchShouldBe ui "admin" True
    -- Ada again, who takes it back.
    switchTo ui "admin"
    switchOf ui "editor" >>= click
    switchShouldBe ui "editor" False
    switchTo ui "editor"
    find ui ".admin-view .error-forbidden" >>= (`shouldContainText` "for the wiki's administrators")
    eventually (length <$> findAll ui ".admin-link" `shouldReturn` 0)

  it "offers no administrator to unmark themself" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    switchShouldBe ui "admin" True
    own <- switchOf ui "admin"
    getAttribute own "disabled" `shouldReturn` Just ""
    find ui ".user-row[data-login=admin] .administrator-self" >>= (`shouldContainText` "That is you")
    -- Everyone else's switch works.
    other <- switchOf ui "reader"
    getAttribute other "disabled" `shouldReturn` Nothing
    length <$> findAll ui ".administrator-self" `shouldReturn` 1

  it "puts users in a group and takes them out, and the group's permissions follow its members" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    eventually (membersOf ui "writers" `shouldReturn` ["editor"])
    -- Choose Rita, the last of those who are not in it.
    select <- find ui "[data-group=writers] .group-add-user"
    focus select
    press "End"
    find ui "[data-group=writers] .group-add-button" >>= click
    eventually (membersOf ui "writers" `shouldReturn` ["editor", "reader"])
    -- Rita may edit the blog now, as the writers may.
    switchTo ui "reader"
    find ui ".space-tree a[href='#/s/blog/']" >>= click
    _ <- find ui ".space-view .actions a[href='#/s/blog/new-page/']"
    -- And no longer once she is taken out.
    eventually (length <$> findAll ui ".admin-link" `shouldReturn` 0)
    switchTo ui "admin"
    find ui ".wiki-header a.admin-link" >>= click
    find ui "[data-group=writers] .group-member[data-login=reader] .group-remove" >>= click
    eventually (membersOf ui "writers" `shouldReturn` ["editor"])
    switchTo ui "reader"
    find ui ".space-tree a[href='#/s/blog/']" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Blog")
    eventually (length <$> findAll ui ".space-view .actions a[href='#/s/blog/new-page/']" `shouldReturn` 0)

  it "makes, renames and deletes a group, asking first, and says why a name will not do" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".group-create-name" >>= (`typeText` "Reviewers")
    clickButton ui ".group-create button" "Create group"
    eventually (groupNames ui `shouldReturn` ["Reviewers", "writers"])
    find ui "[data-group=Reviewers] .group-empty" >>= (`shouldHaveText` "Nobody is in this group.")
    find ui "[data-group=Reviewers] .group-add-button" >>= click
    eventually (membersOf ui "Reviewers" `shouldReturn` ["admin"])
    -- Another group's name, in another case, is refused in place.
    find ui "[data-group=Reviewers] .group-rename-ask" >>= click
    field <- find ui "[data-group=Reviewers] .group-rename input"
    clear field
    typeText field "Writers"
    clickButton ui "[data-group=Reviewers] .group-rename button" "Rename"
    eventually (find ui ".admin-groups .error-invalid" >>= (`shouldContainText` "There is a group called writers already."))
    -- The form stays, with the name typed, to be changed.
    find ui "[data-group=Reviewers] .group-rename input" >>= (`getProperty` "value") >>= (`shouldBe` "Writers")
    -- A name of its own will do.
    clickButton ui "[data-group=Reviewers] .group-rename button" "Cancel"
    find ui "[data-group=Reviewers] .group-rename-ask" >>= click
    renamed <- find ui "[data-group=Reviewers] .group-rename input"
    clear renamed
    typeText renamed "Editors"
    clickButton ui "[data-group=Reviewers] .group-rename button" "Rename"
    eventually (groupNames ui `shouldReturn` ["Editors", "writers"])
    eventually (length <$> findAll ui ".admin-groups .error" `shouldReturn` 0)
    -- Deleting asks first; cancelled, the group stays.
    find ui "[data-group=Editors] .group-delete-ask" >>= click
    find ui "[data-group=Editors] .group-delete-confirm" >>= (`shouldContainText` "Delete the group Editors?")
    clickButton ui "[data-group=Editors] .group-delete-confirm button" "Cancel"
    eventually (groupNames ui `shouldReturn` ["Editors", "writers"])
    find ui "[data-group=Editors] .group-delete-ask" >>= click
    find ui "[data-group=Editors] .group-delete-confirm button.danger" >>= click
    eventually (groupNames ui `shouldReturn` ["writers"])

  it "keeps the groups and the administrators after a reload" $ runPage $ do
    let db = memDatabase "wiki-browser-test-admin"
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
    before <- startKept m db (Just "user-admin") Admin
    switchOf before "reader" >>= click
    switchShouldBe before "reader" True
    find before ".group-create-name" >>= (`typeText` "Readers")
    clickButton before ".group-create button" "Create group"
    eventually (groupNames before `shouldReturn` ["Readers", "writers"])
    unmount before
    after <- startKept m db (Just "user-admin") Admin
    switchShouldBe after "reader" True
    eventually (groupNames after `shouldReturn` ["Readers", "writers"])
    unmount after
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
  where
    switchOf ui login = find ui (".user-row[data-login=" <> login <> "] .administrator-switch")

    -- Whether a user's switch is on, once what was last asked has been
    -- made and read back.
    switchShouldBe ui login checked =
      eventually (switchOf ui login >>= \element -> getAttribute element "aria-checked" `shouldReturn` Just (if checked then "true" else "false"))

    shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

    -- Be someone else, from the demo's menu, staying where one is.
    switchTo ui login = do
      find ui ".user-switcher-toggle" >>= click
      find ui (".user-menu button[data-login=" <> login <> "]") >>= click

    membersOf ui name = findAll ui ("[data-group=" <> name <> "] .group-member") >>= traverse (`getAttribute'` "data-login")

    groupNames ui = findAll ui ".group-name" >>= traverse textContent

    getAttribute' element name = fromMaybe "" <$> getAttribute element name
