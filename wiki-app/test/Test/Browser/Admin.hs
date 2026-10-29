{-# LANGUAGE TemplateHaskell #-}

-- | The administration in a browser, over the demo's wiki: its sections,
-- each a page of its own reached from the navigation, the address
-- following; the users, a page at a time, searched and filtered from the
-- address; the "Manage" dialog of a user ("Wiki.App.View.UserDialog"),
-- which opens with the user's state, saves each change at once, asks before
-- a dangerous one, keeps the focus, and closes on Escape and on its
-- backdrop, giving the focus back to its button; and through it, an
-- administrator marking another user as one, who then has the
-- administration, letting a user create spaces, giving a password,
-- disabling and enabling a login, removing a disabled account once its
-- login is typed, and putting a user in a group. Groups are
-- made, renamed and deleted in their own section, and what a group may do
-- follows its members.
module Test.Browser.Admin (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, start, startChanged, startKept)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (AdminSection (..), Route (..), UserFilter (..), UserListing (..), adminSections, allUsers, sectionName, sectionTitle)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), User (..))

$( browserJS
     ["jsbits/test-location.js", "jsbits/test-focus.js"]
     [ ("js_location_hash", "wiki_test_location_hash", Unsafe, [t|IO JSText|])
     , ("js_focused_matches", "wiki_test_focused_matches", Unsafe, [t|JSText -> IO Bool|])
     , ("js_go_to_fragment", "wiki_test_go_to_fragment", Unsafe, [t|JSText -> IO ()|])
     , ("js_click_itself", "wiki_test_click_itself", Unsafe, [t|JSText -> IO ()|])
     , ("js_drag_out", "wiki_test_drag_out", Unsafe, [t|JSText -> JSText -> IO ()|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  describe "its sections" $ do
    it "opens the first section from /admin/, and puts that section's address in its place" $ runPage $ do
      ui <- start m (Just "user-admin") Home
      unsafeIOToPageM (js_go_to_fragment (toJSText "#/admin/"))
      eventually (find ui ".admin-view h1" >>= (`shouldHaveText` "Overview"))
      eventually (locationHash `shouldReturn` "#/admin/overview/")
      find ui ".admin-nav-link[aria-current=page]" >>= (`shouldHaveText` "Overview")
      find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Overview")

    it "mounts each section alone from the navigation, the address and the title following" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin Overview)
      for_ adminSections $ \section -> do
        find ui (".admin-nav-link[data-section=" <> sectionName section <> "]") >>= click
        eventually (find ui ".admin-view h1" >>= (`shouldHaveText` sectionTitle section))
        eventually (locationHash `shouldReturn` ("#/admin/" <> sectionName section <> "/"))
        find ui ".admin-nav-link[aria-current=page]" >>= (`shouldHaveText` sectionTitle section)
        -- One section's view at a time.
        length <$> findAll ui ".admin-view" `shouldReturn` 1
        length <$> findAll ui ".admin-view .admin-users" `shouldReturn` (if sectionName section == "users" then 1 else 0)
        length <$> findAll ui ".admin-view .admin-groups" `shouldReturn` (if section == Groups then 1 else 0)
        length <$> findAll ui ".admin-view .server-settings" `shouldReturn` (if section == Server then 1 else 0)
      find ui ".admin-nav-link[data-section=users]" >>= click
      eventually (length <$> findAll ui ".user-row" `shouldReturn` 3)

  describe "the users, a page at a time" $ do
    it "pages through the users, at the page size chosen, which the browser keeps" $ runPage $ do
      ui <- startChanged m (withUsers 60) (Just "user-admin") (Admin (Users allUsers))
      eventually (length <$> findAll ui ".user-row" `shouldReturn` 25)
      find ui ".users-count" >>= (`shouldHaveText` "1–25 of 63")
      find ui ".pager .pager-page[aria-current=page]" >>= (`shouldHaveText` "1")
      -- The next page, by its number.
      clickPage ui "2"
      eventually (find ui ".users-count" >>= (`shouldHaveText` "26–50 of 63"))
      locationHash `shouldReturn` "#/admin/users/?page=2"
      find ui ".pager .pager-page[aria-current=page]" >>= (`shouldHaveText` "2")
      -- The last, by its arrow.
      find ui ".pager a.pager-step[title=Last]" >>= click
      eventually (find ui ".users-count" >>= (`shouldHaveText` "51–63 of 63"))
      length <$> findAll ui ".user-row" `shouldReturn` 13
      length <$> findAll ui ".pager a.pager-step[title=Next]" `shouldReturn` 0
      -- 50 a page, from the first page, kept for the next visit.
      select <- find ui ".users-page-size-select"
      focus select
      press "ArrowDown"
      eventually (find ui ".users-count" >>= (`shouldHaveText` "1–50 of 63"))
      eventually (locationHash `shouldReturn` "#/admin/users/")
      kept <- unsafeIOToPageM (runTest (Storage.getItem LocalStorage "admin-users-page-size" :: m (Maybe (Either Text Int))))
      kept `shouldBe` Just (Right 50)

    it "puts a page number below the first, or past the last, back in range in the address" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users UserListing {search = "", page = 0, only = Everyone}))
      eventually (locationHash `shouldReturn` "#/admin/users/")
      find ui ".users-count" >>= (`shouldHaveText` "1–3 of 3")
      ui2 <- startChanged m (withUsers 60) (Just "user-admin") (Admin (Users UserListing {search = "", page = 9, only = Everyone}))
      eventually (locationHash `shouldReturn` "#/admin/users/?page=3")
      eventually (find ui2 ".users-count" >>= (`shouldHaveText` "51–63 of 63"))

    it "keeps what is typed in the search box when a pause writes it into the address" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      box <- find ui ".users-search-input"
      typeText box "rita "
      eventually (locationHash `shouldReturn` "#/admin/users/?q=rita")
      getProperty box "value" `shouldReturn` "rita "
      typeText box "reader"
      getProperty box "value" `shouldReturn` "rita reader"
      eventually (locationHash `shouldReturn` "#/admin/users/?q=rita%20reader")
      eventually (map' ui ".user-row" "data-login" `shouldReturn` ["reader"])

    it "searches by login and display name, with the words and the page in the address" $ runPage $ do
      ui <- startChanged m (withUsers 60) (Just "user-admin") (Admin (Users allUsers))
      find ui ".users-search-input" >>= (`typeText` "Person 4")
      -- Every word, in either: Person 4, 14, 24, 34, 40 to 49 and 54.
      eventually (find ui ".users-count" >>= (`shouldHaveText` "1–15 of 15"))
      eventually (locationHash `shouldReturn` "#/admin/users/?q=Person%204")
      -- A page of users kept in the address comes back as it was.
      ui2 <- startChanged m (withUsers 60) (Just "user-admin") (Admin (Users (UserListing "person" 2 Everyone)))
      eventually (find ui2 ".users-count" >>= (`shouldHaveText` "26–50 of 60"))
      find ui2 ".users-search-input" >>= (`getProperty` "value") >>= (`shouldBe` "person")
      -- A filter, into the address too.
      select <- find ui2 ".users-filter"
      focus select
      press "ArrowDown"
      eventually (find ui2 ".users-count" >>= (`shouldHaveText` "No users"))
      eventually (locationHash `shouldReturn` "#/admin/users/?q=person&show=administrators")
      find ui2 ".users-empty" >>= (`shouldHaveText` "No user matches.")

  describe "the Manage dialog" $ do
    it "opens with the user's state, keeps the focus, and closes on Escape, giving the focus back" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      dialog <- manage ui "editor"
      getAttribute dialog "open" `shouldReturn` Just ""
      getAttribute dialog "aria-modal" `shouldReturn` Just "true"
      find ui ".user-dialog h2" >>= (`shouldHaveText` "Edgar Editor")
      switchShouldBe ui ".administrator-switch" False
      switchShouldBe ui ".creator-switch" True
      find ui ".user-dialog [data-group=writers]" >>= (`shouldContainText` "writers")
      find ui ".user-dialog .account-state" >>= (`shouldHaveText` "No password yet")
      eventually (focusedIs ".user-dialog *" `shouldReturn` True)
      -- The rest of the page is inert: it cannot take the focus.
      find ui ".users-search-input" >>= focus
      focusedIs ".user-dialog *" `shouldReturn` True
      press "Escape"
      eventually (length <$> findAll ui ".user-dialog" `shouldReturn` 0)
      eventually (focusedIs ".user-row[data-login=editor] .user-manage" `shouldReturn` True)

    it "closes on its backdrop, and on Done" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      _ <- manage ui "reader"
      find ui ".user-dialog .user-dialog-done" >>= click
      eventually (length <$> findAll ui ".user-dialog" `shouldReturn` 0)
      _ <- manage ui "reader"
      -- A selection made in the dialog and let go over the backdrop is not
      -- a click on the backdrop: the dialog stays.
      unsafeIOToPageM (js_drag_out (toJSText ".user-dialog .user-dialog-login .user-login") (toJSText ".user-dialog"))
      settle
      length <$> findAll ui ".user-dialog" `shouldReturn` 1
      -- The dialog element itself is clicked only on the backdrop around
      -- its body.
      unsafeIOToPageM (js_click_itself (toJSText ".user-dialog"))
      eventually (length <$> findAll ui ".user-dialog" `shouldReturn` 0)

    it "saves a change at once, says so, and refreshes the row" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      length <$> findAll ui ".user-row[data-login=editor] .badge-administrator" `shouldReturn` 0
      _ <- manage ui "editor"
      find ui ".user-dialog .administrator-switch" >>= click
      switchShouldBe ui ".administrator-switch" True
      find ui ".user-dialog-saved" >>= (`shouldHaveText` "Saved.")
      eventually (length <$> findAll ui ".user-row[data-login=editor] .badge-administrator" `shouldReturn` 1)

    it "keeps showing a user a change took off the page, as they are now" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      _ <- manage ui "editor"
      find ui ".user-dialog .administrator-switch" >>= click
      switchShouldBe ui ".administrator-switch" True
      press "Escape"
      eventually (length <$> findAll ui ".user-dialog" `shouldReturn` 0)
      -- Only the administrators: Ada and Edgar.
      select <- find ui ".users-filter"
      focus select
      press "ArrowDown"
      eventually (map' ui ".user-row" "data-login" `shouldReturn` ["admin", "editor"])
      _ <- manage ui "editor"
      find ui ".user-dialog .administrator-switch" >>= click
      -- Edgar leaves the page, and the dialog shows him as he is now, its
      -- switch off and ready for the next change.
      eventually (map' ui ".user-row" "data-login" `shouldReturn` ["admin"])
      switchShouldBe ui ".administrator-switch" False
      eventually (find ui ".user-dialog .administrator-switch" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing))
      length <$> findAll ui ".user-dialog .badge-administrator" `shouldReturn` 0

    it "asks before disabling a login, and enables it again without asking, which the switcher follows" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      _ <- manage ui "reader"
      find ui ".user-dialog .disable-toggle" >>= click
      find ui ".user-dialog .disable-confirm" >>= (`shouldContainText` "Disable Rita Reader's login?")
      clickButton ui ".user-dialog .disable-confirm button" "Cancel"
      eventually (length <$> findAll ui ".user-dialog .disable-confirm" `shouldReturn` 0)
      find ui ".user-row[data-login=reader]" >>= (`shouldNotHaveClass` "user-disabled")
      find ui ".user-dialog .disable-toggle" >>= click
      find ui ".user-dialog .disable-confirm-button" >>= click
      eventually (find ui ".user-row[data-login=reader]" >>= (`shouldHaveClass` "user-disabled"))
      find ui ".user-dialog-saved" >>= (`shouldContainText` "Rita Reader can no longer sign in")
      find ui ".user-dialog .badge-disabled" >>= (`shouldHaveText` "Disabled")
      press "Escape"
      find ui ".user-switcher-toggle" >>= click
      eventually (length <$> findAll ui ".user-menu button[data-login=reader]" `shouldReturn` 0)
      find ui ".user-switcher-toggle" >>= click
      _ <- manage ui "reader"
      find ui ".user-dialog .disable-toggle" >>= (`shouldHaveText` "Enable login")
      find ui ".user-dialog .disable-toggle" >>= click
      eventually (find ui ".user-row[data-login=reader]" >>= (`shouldNotHaveClass` "user-disabled"))
      press "Escape"
      switchTo ui "reader"
      find ui ".user-switcher-toggle" >>= (`shouldContainText` "Rita Reader")

    it "removes a disabled account once its login is typed, and says so above the table" $ runPage $ do
      ui <- start m (Just "user-admin") (Admin (Users allUsers))
      _ <- manage ui "reader"
      -- An enabled login cannot be removed: the dialog says what comes first.
      length <$> findAll ui ".user-dialog .user-remove" `shouldReturn` 0
      find ui ".user-dialog .user-remove-hint" >>= (`shouldHaveText` "To remove the account, disable the login first.")
      find ui ".user-dialog .disable-toggle" >>= click
      find ui ".user-dialog .disable-confirm-button" >>= click
      eventually (find ui ".user-row[data-login=reader]" >>= (`shouldHaveClass` "user-disabled"))
      eventually (find ui ".user-dialog .user-remove" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing))
      length <$> findAll ui ".user-dialog .user-remove-hint" `shouldReturn` 0
      -- Asked, then cancelled: nothing happens.
      find ui ".user-dialog .user-remove" >>= click
      find ui ".user-dialog .remove-confirm" >>= (`shouldContainText` "Remove Rita Reader's account? This cannot be undone.")
      clickButton ui ".user-dialog .remove-confirm button" "Cancel"
      eventually (length <$> findAll ui ".user-dialog .remove-confirm" `shouldReturn` 0)
      -- Asked again: the field for the login has the focus, and the button
      -- waits for the login exactly.
      find ui ".user-dialog .user-remove" >>= click
      eventually (focusedIs ".user-dialog .remove-confirm-login" `shouldReturn` True)
      button <- find ui ".user-dialog .remove-confirm-button"
      getAttribute button "disabled" `shouldReturn` Just ""
      find ui ".user-dialog .remove-confirm-login" >>= (`typeText` "Reader")
      press "Enter"
      settle
      length <$> findAll ui ".user-dialog" `shouldReturn` 1
      getAttribute button "disabled" `shouldReturn` Just ""
      find ui ".user-dialog .remove-confirm-login" >>= \field -> focus field >> replicateM_ 6 (press "Backspace") >> typeText field "reader"
      eventually (getAttribute button "disabled" `shouldReturn` Nothing)
      click button
      -- The dialog closes, the table says so, and Rita is gone, from the
      -- table and from the demo's switcher.
      eventually (length <$> findAll ui ".user-dialog" `shouldReturn` 0)
      eventually (find ui ".admin-told" >>= (`shouldContainText` "Rita Reader's account (reader) is removed"))
      eventually (map' ui ".user-row" "data-login" `shouldReturn` ["admin", "editor"])
      find ui ".user-switcher-toggle" >>= click
      eventually (length <$> findAll ui ".user-menu button[data-login=reader]" `shouldReturn` 0)

  it "marks a user as an administrator, who then has the administration, and unmarks them" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    _ <- manage ui "editor"
    switchShouldBe ui ".administrator-switch" False
    find ui ".user-dialog .administrator-switch" >>= click
    switchShouldBe ui ".administrator-switch" True
    press "Escape"
    -- Edgar is an administrator now: he has the way here, and the page.
    switchTo ui "editor"
    _ <- find ui ".wiki-header a.admin-link"
    eventually (length <$> findAll ui ".user-row" `shouldReturn` 3)
    -- Ada again, who takes it back.
    switchTo ui "admin"
    _ <- manage ui "editor"
    find ui ".user-dialog .administrator-switch" >>= click
    switchShouldBe ui ".administrator-switch" False
    press "Escape"
    switchTo ui "editor"
    find ui ".admin-view .error-forbidden" >>= (`shouldContainText` "for the wiki's administrators")
    eventually (length <$> findAll ui ".admin-link" `shouldReturn` 0)

  it "offers no administrator to unmark themself, nor to disable their own login" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    _ <- manage ui "admin"
    switchShouldBe ui ".administrator-switch" True
    own <- find ui ".user-dialog .administrator-switch"
    getAttribute own "disabled" `shouldReturn` Just ""
    find ui ".user-dialog .user-dialog-permissions" >>= (`shouldContainText` "That is you")
    find ui ".user-dialog .disable-self" >>= (`shouldContainText` "You cannot disable your own login")
    length <$> findAll ui ".user-dialog .disable-toggle" `shouldReturn` 0
    length <$> findAll ui ".user-dialog .user-remove" `shouldReturn` 0
    press "Escape"
    -- Everyone else's switch works.
    _ <- manage ui "reader"
    other <- find ui ".user-dialog .administrator-switch"
    getAttribute other "disabled" `shouldReturn` Nothing

  it "shows that an administrator creates spaces, by the rules, without a switch to turn off" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    _ <- manage ui "admin"
    switchShouldBe ui ".creator-switch" True
    own <- find ui ".user-dialog .creator-switch"
    getAttribute own "disabled" `shouldReturn` Just ""
    find ui ".user-dialog .user-dialog-permissions" >>= (`shouldContainText` "An administrator creates spaces anyway.")
    press "Escape"
    _ <- manage ui "reader"
    switchShouldBe ui ".creator-switch" False
    find ui ".user-dialog .administrator-switch" >>= click
    switchShouldBe ui ".creator-switch" True
    eventually (find ui ".user-dialog .creator-switch" >>= (`getAttribute` "disabled") >>= (`shouldBe` Just ""))
    find ui ".user-dialog .administrator-switch" >>= click
    switchShouldBe ui ".creator-switch" False
    eventually (find ui ".user-dialog .creator-switch" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing))

  it "lets a user create spaces, who then is offered to, and no longer" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    _ <- manage ui "reader"
    find ui ".user-dialog .creator-switch" >>= click
    switchShouldBe ui ".creator-switch" True
    eventually (length <$> findAll ui ".user-row[data-login=reader] .badge-creator" `shouldReturn` 1)
    press "Escape"
    switchTo ui "reader"
    find ui ".wiki-header .wiki-brand" >>= click
    _ <- find ui ".wiki-sidebar .new-space-link"
    switchTo ui "admin"
    find ui ".wiki-header a.admin-link" >>= click
    find ui ".admin-nav-link[data-section=users]" >>= click
    _ <- manage ui "reader"
    find ui ".user-dialog .creator-switch" >>= click
    switchShouldBe ui ".creator-switch" False
    press "Escape"
    switchTo ui "reader"
    find ui ".wiki-header .wiki-brand" >>= click
    eventually (length <$> findAll ui ".wiki-sidebar .new-space-link" `shouldReturn` 0)

  it "makes a user with a password, an administrator if asked, and refuses a login that is taken" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    find ui ".user-create-open" >>= click
    find ui ".user-create-login" >>= (`typeText` "bea")
    find ui ".user-create-name" >>= (`typeText` "Bea Builder")
    find ui ".user-create-password" >>= (`typeText` "bea's password")
    find ui ".user-create-administrator input" >>= click
    clickButton ui ".user-create .actions button" "Create user"
    eventually (find ui ".user-row[data-login=bea] .user-sign-in" >>= (`shouldHaveText` "With a password"))
    find ui ".user-row[data-login=bea] .badge-administrator" >>= (`shouldHaveText` "Administrator")
    find ui ".admin-told" >>= (`shouldContainText` "Bea Builder (bea) can sign in now.")
    -- The form is closed once the user is made, and empty when opened again.
    length <$> findAll ui ".user-create" `shouldReturn` 0
    find ui ".user-create-open" >>= click
    find ui ".user-create-login" >>= (`getProperty` "value") >>= (`shouldBe` "")
    find ui ".user-create-password" >>= (`getProperty` "value") >>= (`shouldBe` "")
    -- A login that is taken, in any case, is refused in place, and what was
    -- typed stays to be changed.
    find ui ".user-create-login" >>= (`typeText` "EDITOR")
    find ui ".user-create-password" >>= (`typeText` "a good password")
    clickButton ui ".user-create .actions button" "Create user"
    eventually (find ui ".admin-users .error-conflict" >>= (`shouldContainText` "There is a user with the login EDITOR already."))
    find ui ".user-create-login" >>= (`getProperty` "value") >>= (`shouldBe` "EDITOR")
    -- So is a password that is too short.
    login <- find ui ".user-create-login"
    clear login
    typeText login "dee"
    password <- find ui ".user-create-password"
    clear password
    typeText password "short"
    clickButton ui ".user-create .actions button" "Create user"
    eventually (find ui ".admin-users .error-invalid" >>= (`shouldContainText` "at least 8 characters"))
    eventually (length <$> findAll ui ".user-row[data-login=dee]" `shouldReturn` 0)
    -- Bea may be switched to, and is an administrator.
    switchTo ui "bea"
    _ <- find ui ".wiki-header a.admin-link"
    pass

  it "gives a user a password, typed where no link can be mailed" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    find ui ".user-row[data-login=reader] .user-sign-in" >>= (`shouldHaveText` "No password yet")
    _ <- manage ui "reader"
    find ui ".user-dialog .password-ask" >>= (`shouldHaveText` "Set password…")
    -- The demo sends no mail, which the dialog says.
    find ui ".user-dialog .password-hint" >>= (`shouldHaveText` "The server sends no mail: type a password for them")
    length <$> findAll ui ".password-link-ask" `shouldReturn` 0
    find ui ".user-dialog .password-ask" >>= click
    find ui ".user-dialog .password-new" >>= (`typeText` "short")
    clickButton ui ".user-dialog .password-form button" "Save password"
    eventually (find ui ".user-dialog .error-invalid" >>= (`shouldContainText` "at least 8 characters"))
    new <- find ui ".user-dialog .password-new"
    clear new
    typeText new "rita's password"
    clickButton ui ".user-dialog .password-form button" "Save password"
    eventually (find ui ".user-dialog .account-state" >>= (`shouldHaveText` "With a password"))
    find ui ".user-dialog-saved" >>= (`shouldContainText` "Rita Reader has a new password")
    find ui ".user-dialog .password-ask" >>= (`shouldHaveText` "Reset password…")
    eventually (find ui ".user-row[data-login=reader] .user-sign-in" >>= (`shouldHaveText` "With a password"))

  it "puts a user in a group from the dialog and takes them out, and the group's permissions follow its members" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin (Users allUsers))
    _ <- manage ui "reader"
    find ui ".user-dialog .user-dialog-groups .empty" >>= (`shouldHaveText` "In no group.")
    clickButton ui ".user-dialog .user-dialog-group-add button" "Add to the group"
    eventually (find ui ".user-dialog [data-group=writers]" >>= (`shouldContainText` "writers"))
    press "Escape"
    -- Rita may edit the blog now, as the writers may.
    switchTo ui "reader"
    find ui ".wiki-header .wiki-brand" >>= click
    find ui ".wiki-sidebar a[href$='#/s/blog/']" >>= click
    find ui ".space-pages-link" >>= click
    _ <- find ui ".space-view .actions a[href$='#/s/blog/new-page/']"
    -- And no longer once she is taken out, in the groups' section.
    switchTo ui "admin"
    find ui ".wiki-header a.admin-link" >>= click
    find ui ".admin-nav-link[data-section=groups]" >>= click
    eventually (membersOf ui "writers" `shouldReturn` ["editor", "reader"])
    find ui "[data-group=writers] .group-member[data-login=reader] .group-remove" >>= click
    eventually (membersOf ui "writers" `shouldReturn` ["editor"])
    switchTo ui "reader"
    find ui ".wiki-header .wiki-brand" >>= click
    find ui ".wiki-sidebar a[href$='#/s/blog/']" >>= click
    find ui ".space-pages-link" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Blog")
    eventually (length <$> findAll ui ".space-view .actions a[href$='#/s/blog/new-page/']" `shouldReturn` 0)

  it "makes, renames and deletes a group, asking first, and says why a name will not do" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin Groups)
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
    before <- startKept m db (Just "user-admin") (Admin (Users allUsers))
    _ <- manage before "reader"
    find before ".user-dialog .administrator-switch" >>= click
    switchShouldBe before ".administrator-switch" True
    press "Escape"
    find before ".admin-nav-link[data-section=groups]" >>= click
    find before ".group-create-name" >>= (`typeText` "Readers")
    clickButton before ".group-create button" "Create group"
    eventually (groupNames before `shouldReturn` ["Readers", "writers"])
    unmount before
    after <- startKept m db (Just "user-admin") (Admin Groups)
    eventually (groupNames after `shouldReturn` ["Readers", "writers"])
    find after ".admin-nav-link[data-section=users]" >>= click
    eventually (find after ".user-row[data-login=reader] .badge-administrator" >>= (`shouldHaveText` "Administrator"))
    unmount after
    unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: m ()))
  where
    -- Open a user's dialog from their row's "Manage", and give it back.
    manage ui login = do
      find ui (".user-row[data-login=" <> login <> "] .user-manage") >>= click
      find ui (".user-dialog[data-login=" <> login <> "]")

    -- Whether a switch in the open dialog is on, once what was last asked
    -- has been made and read back.
    switchShouldBe ui selector checked =
      eventually (find ui (".user-dialog " <> selector) >>= \element -> getAttribute element "aria-checked" `shouldReturn` Just (if checked then "true" else "false"))

    shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

    -- Be someone else, from the demo's menu, staying where one is.
    switchTo ui login = do
      find ui ".user-switcher-toggle" >>= click
      find ui (".user-menu button[data-login=" <> login <> "]") >>= click

    clickPage ui n = findAll ui ".pager .pager-page" >>= filterM (\e -> (== n) <$> textContent e) >>= traverse_ click . take 1

    membersOf ui name = findAll ui ("[data-group=" <> name <> "] .group-member") >>= traverse (`getAttribute'` "data-login")

    groupNames ui = findAll ui ".group-name" >>= traverse textContent

    getAttribute' element name = fromMaybe "" <$> getAttribute element name

    map' ui selector name = findAll ui selector >>= traverse (`getAttribute'` name)

    locationHash = unsafeIOToPageM (fromJSText <$> js_location_hash)

    focusedIs selector = unsafeIOToPageM (js_focused_matches (toJSText selector))

-- | The demo with this many more users, Person 1 to Person n, with logins
-- @person-01@ and so on, so that the users fill more than one page.
withUsers :: Int -> MemState -> MemState
withUsers n st = st {users = Map.union st.users (Map.fromList [(u.id, u) | u <- extra])}
  where
    extra = [User {id = UserId ("user-person-" <> two i), login = Login ("person-" <> two i), displayName = "Person " <> show i} | i <- [1 .. n]]
    two i = T.justifyRight 2 '0' (show i)
