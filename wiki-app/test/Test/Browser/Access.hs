-- | Whom the wiki lets in, in a browser (WP3.5 of docs/PLAN.md): the form
-- that makes an account in an open wiki, beside "Sign in"; a closed wiki,
-- which shows someone not signed in the way to sign in and nothing else,
-- and reads nothing else for them; an invitation's page, which makes its
-- account; and the administration's section, which closes and opens the
-- wiki, invites people, and leaves accounts with a password to the
-- server's console.
--
-- The forms of signing in are the server's, over the backend over HTTP
-- with a server in fetch's place ("Test.Browser.Http"); the
-- administration's section is the same over the demo's wiki.
module Test.Browser.Access (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (clickButton, slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Account (InvitationInfo (..), InvitationToken (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (Session (..), session)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (Email (..), Standing (..))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  registering m
  closed m
  invited m
  panel m

-- | Nobody, in a wiki of this access.
nobodyIn :: Access -> SessionInfo
nobodyIn access = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access}, standing = NotSignedIn, providers = [], exports = []}

-- | One of the demo's users, signed in.
signedInAs :: Text -> PageM s SessionInfo
signedInAs uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = []}

registering :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
registering m = describe "making an account" $ do
  it "is offered beside signing in in an open wiki, and signs its maker in" $ runPage $ do
    serverStarts
    serveDemo
    rita <- signedInAs "user-reader"
    answerWith "GET" "api/v1/session" 200 (nobodyIn Open)
    answerWith "POST" "api/v1/accounts" 200 rita
    ui <- startServer m Home
    find ui ".register-toggle" >>= click
    find ui ".register-form input[name=login]" >>= (`typeText` "rita")
    find ui ".register-form input[name=name]" >>= (`typeText` "Rita Reader")
    find ui ".register-form input[name=password]" >>= (`typeText` "a long password")
    find ui ".register-form button[type=submit]" >>= click
    find ui ".account .user-name" >>= (`shouldHaveText` "Rita Reader")
    length <$> findAll ui ".register-form" `shouldReturn` 0
    made <- filter (\r -> r.method == "POST") <$> asked
    map (\r -> (r.url, r.body)) made `shouldBe` [("api/v1/accounts", "{\"displayName\":\"Rita Reader\",\"login\":\"rita\",\"password\":\"a long password\"}")]
    unmount ui
    serverStops

  it "says why an account was not made, and keeps the form open" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 (nobodyIn Open)
    answerWith "POST" "api/v1/accounts" 409 (Conflict "There is a user with the login editor already.")
    ui <- startServer m Home
    find ui ".register-toggle" >>= click
    find ui ".register-form input[name=login]" >>= (`typeText` "editor")
    find ui ".register-form input[name=password]" >>= (`typeText` "a long password")
    find ui ".register-form button[type=submit]" >>= click
    find ui ".register-error" >>= (`shouldHaveText` "There is a user with the login editor already.")
    -- One form at a time: signing in closes this one.
    find ui ".sign-in-toggle" >>= click
    _ <- find ui ".sign-in-form"
    length <$> findAll ui ".register-form" `shouldReturn` 0
    unmount ui
    serverStops

closed :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
closed m = describe "a closed wiki" $
  it "shows someone not signed in the way to sign in and nothing else, and asks for nothing else" $
    runPage $ do
      serverStarts
      serveDemo
      answerWith "GET" "api/v1/session" 200 (nobodyIn Closed)
      ui <- startServer m (Space (slugs ["blog"]))
      find ui ".closed h1" >>= (`shouldHaveText` "Sign in to read this wiki")
      length <$> findAll ui ".wiki-sidebar" `shouldReturn` 0
      length <$> findAll ui ".register-toggle" `shouldReturn` 0
      length <$> findAll ui ".breadcrumbs" `shouldReturn` 0
      find ui ".closed-sign-in" >>= click
      _ <- find ui ".sign-in-form input[name=login]"
      map (\r -> r.url) <$> asked `shouldReturn` ["api/v1/session"]
      unmount ui
      serverStops

invited :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
invited m = describe "an invitation's page" $ do
  it "says whom it is for, makes its account, and shows the wiki as its maker" $ runPage $ do
    serverStarts
    serveDemo
    rita <- signedInAs "user-reader"
    answerWith "GET" "api/v1/session" 200 (nobodyIn Closed)
    answerWith "GET" "api/v1/invitations/s3cr3t" 200 InvitationInfo {email = Email "rita@example.org", expiresAt = demoNow}
    answerWith "POST" "api/v1/invitations/s3cr3t" 200 rita
    ui <- startServer m (Invite (InvitationToken "s3cr3t"))
    find ui ".invitation-form strong" >>= (`shouldHaveText` "rita@example.org")
    find ui ".invitation-form input[name=login]" >>= (`typeText` "rita")
    find ui ".invitation-form input[name=password]" >>= (`typeText` "a long password")
    -- The server's answer for the wiki as Rita is the demo's.
    answerWith "GET" "api/v1/session" 200 rita
    find ui ".invitation-form button[type=submit]" >>= click
    find ui ".account .user-name" >>= (`shouldHaveText` "Rita Reader")
    _ <- find ui ".directory"
    accepted <- filter (\r -> r.method == "POST") <$> asked
    map (\r -> r.url) accepted `shouldBe` ["api/v1/invitations/s3cr3t"]
    unmount ui
    serverStops

  it "says when it cannot be used" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 (nobodyIn Closed)
    answerWith "GET" "api/v1/invitations/used" 404 NotFound
    ui <- startServer m (Invite (InvitationToken "used"))
    find ui ".invitation-unusable" >>= (`shouldContainText` "This invitation cannot be used")
    length <$> findAll ui ".invitation-form" `shouldReturn` 0
    unmount ui
    serverStops

panel :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
panel m = describe "the administration's section on it" $ do
  it "closes the wiki, invites someone with a link to pass on, revokes it, and opens the wiki again" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    -- Open: no invitations.
    length <$> findAll ui ".admin-invitations" `shouldReturn` 0
    find ui ".access-choice input[value=closed]" >>= click
    _ <- find ui ".admin-invitations"
    find ui ".invite-form input[name=email]" >>= (`typeText` "bea@example.org")
    clickButton ui ".invite-form button" "Invite"
    shown <- find ui ".invitation-made .invitation-link" >>= (`getProperty` "value")
    shown `shouldSatisfy` T.isInfixOf "/invite/"
    find ui ".invitation-made" >>= (`shouldContainText` "bea@example.org is invited")
    _ <- find ui ".invitation-row[data-email='bea@example.org']"
    find ui ".invitation-row[data-email='bea@example.org'] .invitation-revoke" >>= click
    eventually (length <$> findAll ui ".invitation-row" `shouldReturn` 0)
    find ui ".admin-invitations .empty" >>= (`shouldHaveText` "Nobody is invited.")
    -- Nobody, in the demo, is shown the way in and nothing else.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login='']" >>= click
    find ui ".closed" >>= (`shouldContainText` "Choose who you are at the top right.")
    length <$> findAll ui ".wiki-sidebar" `shouldReturn` 0
    -- Ada again, who opens it.
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=admin]" >>= click
    find ui ".access-choice input[value=open]" >>= click
    eventually (length <$> findAll ui ".admin-invitations" `shouldReturn` 0)
    unmount ui

  it "lets new accounts create spaces" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    box <- find ui ".new-accounts-create-spaces input"
    getProperty box "checked" `shouldReturn` "false"
    find ui ".new-accounts-create-spaces" >>= (`shouldContainText` "Let every new account create spaces")
    find ui ".new-accounts-create-spaces .check-help" >>= (`shouldContainText` "by invitation or by signing in with a provider")
    click box
    eventually (find ui ".new-accounts-create-spaces input" >>= (`getProperty` "checked") >>= (`shouldBe` "true"))
    unmount ui

  it "leaves accounts with a password to the console, and the users' section says so in place of its form" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    box <- find ui ".admin-creates-password-accounts input"
    getProperty box "checked" `shouldReturn` "true"
    find ui ".admin-creates-password-accounts" >>= (`shouldContainText` "The administration may create accounts with a password")
    find ui ".admin-creates-password-accounts .check-help" >>= (`shouldContainText` "wiki-server users add")
    _ <- find ui ".user-create"
    length <$> findAll ui ".user-create-console" `shouldReturn` 0
    click box
    eventually (find ui ".admin-creates-password-accounts input" >>= (`getProperty` "checked") >>= (`shouldBe` "false"))
    find ui ".user-create-console" >>= (`shouldContainText` "on the server's console, with wiki-server users add, as")
    length <$> findAll ui ".user-create" `shouldReturn` 0
    -- On again, the form is back.
    find ui ".admin-creates-password-accounts input" >>= click
    _ <- find ui ".user-create"
    length <$> findAll ui ".user-create-console" `shouldReturn` 0
    unmount ui

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)
