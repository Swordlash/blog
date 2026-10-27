-- | The administration's users and groups ("Wiki.App.View.Admin") in a
-- browser, over the demo's wiki: an administrator marks another user as
-- one, who then has the administration, and unmarks them; nobody is
-- offered to unmark themself; a user is let create spaces, and an
-- administrator is shown to whatever their own grant; users are made
-- with a password, given one, and disabled and enabled again; groups are
-- made, renamed and deleted, users put in them and taken out, and what a
-- group may do follows its members.
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

  it "shows that an administrator creates spaces, by the rules, without a switch to turn off" $ runPage $ do
    -- The demo's administrator holds the global administer and no
    -- create-spaces grant of her own.
    ui <- start m (Just "user-admin") Admin
    creatorShouldBe ui "admin" True
    own <- find ui ".user-row[data-login=admin] .creator-switch"
    getAttribute own "disabled" `shouldReturn` Just ""
    find ui ".user-row[data-login=admin] .creator-administrator" >>= (`shouldHaveText` "An administrator creates spaces anyway.")
    length <$> findAll ui ".creator-administrator" `shouldReturn` 1
    -- Whoever is made an administrator is shown so too, and is not when no
    -- longer one.
    creatorShouldBe ui "reader" False
    switchOf ui "reader" >>= click
    switchShouldBe ui "reader" True
    creatorShouldBe ui "reader" True
    eventually (length <$> findAll ui ".creator-administrator" `shouldReturn` 2)
    switchOf ui "reader" >>= click
    switchShouldBe ui "reader" False
    creatorShouldBe ui "reader" False
    eventually (find ui ".user-row[data-login=reader] .creator-switch" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing))
    -- She is offered a new space all the same.
    find ui ".wiki-header .wiki-brand" >>= click
    _ <- find ui ".wiki-sidebar .new-space-link"
    unmount ui

  it "lets a user create spaces, who then is offered to, and no longer" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    creatorShouldBe ui "editor" True
    creatorShouldBe ui "reader" False
    find ui ".user-row[data-login=reader] .creator-switch" >>= click
    creatorShouldBe ui "reader" True
    switchTo ui "reader"
    _ <- find ui ".wiki-sidebar .new-space-link"
    switchTo ui "admin"
    find ui ".wiki-header a.admin-link" >>= click
    find ui ".user-row[data-login=reader] .creator-switch" >>= click
    creatorShouldBe ui "reader" False
    switchTo ui "reader"
    eventually (length <$> findAll ui ".wiki-sidebar .new-space-link" `shouldReturn` 0)

  it "makes a user with a password, an administrator if asked, and refuses a login that is taken" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".user-create-login" >>= (`typeText` "bea")
    find ui ".user-create-name" >>= (`typeText` "Bea Builder")
    find ui ".user-create-password" >>= (`typeText` "bea's password")
    find ui ".user-create-administrator input" >>= click
    clickButton ui ".user-create button" "Create user"
    eventually (find ui ".user-row[data-login=bea] .account-state" >>= (`shouldHaveText` "Signs in with a password"))
    switchShouldBe ui "bea" True
    find ui ".admin-told" >>= (`shouldContainText` "Bea Builder (bea) can sign in now.")
    -- The form is emptied once the user is made.
    find ui ".user-create-login" >>= (`getProperty` "value") >>= (`shouldBe` "")
    find ui ".user-create-password" >>= (`getProperty` "value") >>= (`shouldBe` "")
    -- Bea may be switched to, and is an administrator.
    switchTo ui "bea"
    _ <- find ui ".wiki-header a.admin-link"
    -- A login that is taken, in any case, is refused in place, and what was
    -- typed stays to be changed.
    find ui ".user-create-login" >>= (`typeText` "EDITOR")
    find ui ".user-create-password" >>= (`typeText` "a good password")
    clickButton ui ".user-create button" "Create user"
    eventually (find ui ".admin-users .error-conflict" >>= (`shouldContainText` "There is a user with the login EDITOR already."))
    find ui ".user-create-login" >>= (`getProperty` "value") >>= (`shouldBe` "EDITOR")
    -- So is a password that is too short.
    login <- find ui ".user-create-login"
    clear login
    typeText login "dee"
    password <- find ui ".user-create-password"
    clear password
    typeText password "short"
    clickButton ui ".user-create button" "Create user"
    eventually (find ui ".admin-users .error-invalid" >>= (`shouldContainText` "at least 8 characters"))
    eventually (length <$> findAll ui ".user-row[data-login=dee]" `shouldReturn` 0)

  it "gives a user a password, and disables and enables their login, which the switcher follows" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".user-row[data-login=reader] .account-state" >>= (`shouldHaveText` "No password yet")
    find ui ".user-row[data-login=reader] .password-ask" >>= (`shouldHaveText` "Set password…")
    -- The demo sends no mail, which the button says.
    find ui ".user-row[data-login=reader] .password-hint" >>= (`shouldHaveText` "The server sends no mail: type a password for them")
    length <$> findAll ui ".password-link-ask" `shouldReturn` 0
    find ui ".user-row[data-login=reader] .password-ask" >>= click
    find ui ".user-row[data-login=reader] .password-new" >>= (`typeText` "short")
    clickButton ui ".user-row[data-login=reader] .password-form button" "Save password"
    eventually (find ui ".admin-users .error-invalid" >>= (`shouldContainText` "at least 8 characters"))
    new <- find ui ".user-row[data-login=reader] .password-new"
    clear new
    typeText new "rita's password"
    clickButton ui ".user-row[data-login=reader] .password-form button" "Save password"
    eventually (find ui ".user-row[data-login=reader] .account-state" >>= (`shouldHaveText` "Signs in with a password"))
    find ui ".admin-told" >>= (`shouldContainText` "Rita Reader has a new password")
    find ui ".user-row[data-login=reader] .password-ask" >>= (`shouldHaveText` "Reset password…")
    -- Nobody is offered to disable their own login.
    own <- find ui ".user-row[data-login=admin] .disable-toggle"
    getAttribute own "disabled" `shouldReturn` Just ""
    find ui ".user-row[data-login=admin] .disable-self" >>= (`shouldContainText` "You cannot disable your own login")
    -- Disabled, Rita is not offered to switch to; enabled, she is again.
    find ui ".user-row[data-login=reader] .disable-toggle" >>= click
    eventually (find ui ".user-row[data-login=reader] .account-state" >>= (`shouldHaveText` "Disabled"))
    find ui ".user-row[data-login=reader]" >>= (`shouldHaveClass` "user-disabled")
    find ui ".user-switcher-toggle" >>= click
    eventually (length <$> findAll ui ".user-menu button[data-login=reader]" `shouldReturn` 0)
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-row[data-login=reader] .disable-toggle" >>= (`shouldHaveText` "Enable")
    find ui ".user-row[data-login=reader] .disable-toggle" >>= click
    eventually (find ui ".user-row[data-login=reader] .account-state" >>= (`shouldHaveText` "Signs in with a password"))
    switchTo ui "reader"
    find ui ".user-switcher-toggle" >>= (`shouldContainText` "Rita Reader")

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
    find ui ".wiki-sidebar a[href$='#/s/blog/']" >>= click
    find ui ".space-pages-link" >>= click
    _ <- find ui ".space-view .actions a[href$='#/s/blog/new-page/']"
    -- And no longer once she is taken out.
    eventually (length <$> findAll ui ".admin-link" `shouldReturn` 0)
    switchTo ui "admin"
    find ui ".wiki-header a.admin-link" >>= click
    find ui "[data-group=writers] .group-member[data-login=reader] .group-remove" >>= click
    eventually (membersOf ui "writers" `shouldReturn` ["editor"])
    switchTo ui "reader"
    find ui ".wiki-sidebar a[href$='#/s/blog/']" >>= click
    find ui ".space-pages-link" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Blog")
    eventually (length <$> findAll ui ".space-view .actions a[href$='#/s/blog/new-page/']" `shouldReturn` 0)

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

    creatorShouldBe ui login checked =
      eventually (find ui (".user-row[data-login=" <> login <> "] .creator-switch") >>= \element -> getAttribute element "aria-checked" `shouldReturn` Just (if checked then "true" else "false"))

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
