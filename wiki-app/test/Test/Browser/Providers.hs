-- | Signing in with a provider, in a browser (WP3.6 of docs/PLAN.md): the
-- links that start it, beside the forms that sign in and make an account
-- and on an invitation's page, where the session names providers, and
-- none where it does not; a signed-in user's panel of how they sign in,
-- which connects and disconnects, but not the last way in; and the
-- administration's account column, which says who signs in with what and
-- disconnects it.
--
-- Over the backend over HTTP with a server in fetch's place
-- ("Test.Browser.Http"), since signing in at all is a server's; the round
-- trip through a provider is the server's too, and tested there
-- (wiki-server's @Test.Server.Oidc@): here only the links that begin it.
module Test.Browser.Providers (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (slugs)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Account (InvitationInfo (..), InvitationToken (..), LinkedIdentity (..), SignInMethods (..))
import Wiki.Api.Admin (Directory (..))
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (Session (..), session)
import Wiki.App.Backend.Admin (MonadAdmin (directory))
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (Email (..), SignInProvider (..), Standing (..))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  signingIn m
  inviting m
  ownPanel m
  administration m

-- | The providers the server names.
named :: [SignInProvider]
named = [SignInProvider {name = "google", label = "Google"}, SignInProvider {name = "hub", label = "GitHub"}]

-- | Nobody, in a wiki of this access, offered these providers.
nobodyWith :: [SignInProvider] -> Access -> SessionInfo
nobodyWith providers access = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access}, standing = NotSignedIn, providers, exports = []}

-- | One of the demo's users, signed in, offered the providers.
signedInAs :: Text -> PageM s SessionInfo
signedInAs uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = named, exports = []}

hrefOf :: Element s -> PageM s Text
hrefOf e = fromMaybe "" <$> getAttribute e "href"

signingIn :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
signingIn m = describe "the forms that sign in and make an account" $ do
  it "offer each provider, as a link to the server's round trip that comes back to the page" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 (nobodyWith named Open)
    ui <- startServer m (Space (slugs ["blog"]))
    find ui ".sign-in-toggle" >>= click
    _ <- find ui ".sign-in-form .provider-link"
    links' <- findAll ui ".sign-in-form .provider-link"
    traverse textContent links' `shouldReturn` ["Sign in with Google", "Sign in with GitHub"]
    hrefs <- traverse hrefOf links'
    hrefs `shouldSatisfy` all (\h -> "next=" `T.isInfixOf` h && "blog" `T.isInfixOf` h)
    map (T.takeWhile (/= '?')) hrefs `shouldBe` ["auth/google/start", "auth/hub/start"]
    find ui ".register-toggle" >>= click
    _ <- find ui ".register-form .provider-link"
    made <- findAll ui ".register-form .provider-link"
    traverse textContent made `shouldReturn` ["Create account with Google", "Create account with GitHub"]
    unmount ui
    serverStops

  it "offer none where the server names none" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 (nobodyWith [] Open)
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    _ <- find ui ".sign-in-form input[name=login]"
    length <$> findAll ui ".provider-link" `shouldReturn` 0
    unmount ui
    serverStops

  it "offer them in a closed wiki too, which is signed in to that way" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 (nobodyWith named Closed)
    ui <- startServer m Home
    find ui ".closed-sign-in" >>= click
    _ <- find ui ".sign-in-form .provider-link"
    length <$> findAll ui ".sign-in-form .provider-link" `shouldReturn` 2
    length <$> findAll ui ".register-toggle" `shouldReturn` 0
    unmount ui
    serverStops

inviting :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
inviting m = describe "an invitation's page" $
  it "offers to make the account with a provider, carrying the invitation" $
    runPage $ do
      serverStarts
      serveDemo
      answerWith "GET" "api/v1/session" 200 (nobodyWith named Closed)
      answerWith "GET" "api/v1/invitations/s3cr3t" 200 InvitationInfo {email = Email "rita@example.org", expiresAt = demoNow}
      ui <- startServer m (Invite (InvitationToken "s3cr3t"))
      -- Once the invitation is read.
      _ <- find ui ".invitation-form .provider-link"
      links' <- findAll ui ".invitation-form .provider-link"
      traverse textContent links' `shouldReturn` ["Create my account with Google", "Create my account with GitHub"]
      hrefs <- traverse hrefOf links'
      hrefs `shouldSatisfy` all ("&invite=s3cr3t" `T.isSuffixOf`)
      unmount ui
      serverStops

ownPanel :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
ownPanel m = describe "the panel of how a user signs in" $ do
  let google = LinkedIdentity {provider = "google", email = Just (Email "rita@example.org"), name = Just "Rita", linkedAt = demoNow}
      hub = LinkedIdentity {provider = "hub", email = Nothing, name = Nothing, linkedAt = demoNow}

  it "lists the user's accounts at providers, offers to connect the others, and keeps the last way in" $ runPage $ do
    serverStarts
    serveDemo
    rita <- signedInAs "user-reader"
    answerWith "GET" "api/v1/session" 200 rita
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = False, identities = [google]}
    ui <- startServer m Home
    find ui ".account-toggle" >>= (`shouldHaveText` "Rita Reader")
    find ui ".account-toggle" >>= click
    find ui ".account-password" >>= (`shouldContainText` "No password")
    find ui ".identity .identity-provider" >>= (`shouldHaveText` "Google")
    find ui ".identity .identity-email" >>= (`shouldHaveText` "rita@example.org")
    only <- find ui ".identity-disconnect"
    getAttribute only "disabled" `shouldReturn` Just ""
    -- She signs in with Google, which the server has: no password to set.
    length <$> findAll ui ".password-change-toggle" `shouldReturn` 0
    connect <- find ui ".identity-connect"
    textContent connect `shouldReturn` "Connect GitHub"
    hrefOf connect >>= (`shouldSatisfy` \h -> "auth/hub/start?" `T.isPrefixOf` h && "&link=1" `T.isSuffixOf` h)
    unmount ui
    serverStops

  it "disconnects one, and shows what is left" $ runPage $ do
    serverStarts
    serveDemo
    rita <- signedInAs "user-reader"
    answerWith "GET" "api/v1/session" 200 rita
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = True, identities = [google, hub]}
    answerWith "DELETE" "api/v1/account/identities/hub" 200 SignInMethods {password = True, identities = [google]}
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    eventually (length <$> findAll ui ".identity" `shouldReturn` 2)
    buttons <- findAll ui ".identity-disconnect"
    traverse (`getAttribute` "disabled") buttons `shouldReturn` [Nothing, Nothing]
    case buttons of
      [_, second'] -> click second'
      _ -> panic "two identities"
    eventually (length <$> findAll ui ".identity" `shouldReturn` 1)
    find ui ".identity-connect" >>= (`shouldHaveText` "Connect GitHub")
    gone <- filter (\r -> r.method == "DELETE") <$> asked
    map (\r -> r.url) gone `shouldBe` ["api/v1/account/identities/hub"]
    unmount ui
    serverStops

  it "is offered where the server names no provider too, with nothing to connect" $ runPage $ do
    serverStarts
    serveDemo
    rita <- signedInAs "user-reader"
    answerWith "GET" "api/v1/session" 200 SessionInfo {user = rita.user, groups = rita.groups, grants = rita.grants, standing = rita.standing, providers = [], exports = []}
    answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = True, identities = []}
    ui <- startServer m Home
    find ui ".account .user-name" >>= (`shouldHaveText` "Rita Reader")
    find ui ".account-toggle" >>= click
    find ui ".account-password" >>= (`shouldHaveText` "With your password")
    _ <- find ui ".password-change-toggle"
    length <$> findAll ui ".identity" `shouldReturn` 0
    length <$> findAll ui ".identity-connect" `shouldReturn` 0
    unmount ui
    serverStops

administration :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
administration m = describe "the administration's accounts" $ do
  it "say who signs in with which provider, and disconnect one" $
    runPage $ do
      serverStarts
      serveDemo
      (me, people) <- demoPeople
      answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = named, exports = []}
      for_ people $ \d -> answerWith "GET" "api/v1/admin/directory" 200 (withIdentities d)
      answerWith "DELETE" "api/v1/admin/users/user-editor/identities/hub" 204 ()
      ui <- startServer m Admin
      find ui ".user-row[data-login=editor] .account-state" >>= (`shouldHaveText` "Signs in with GitHub")
      find ui ".user-row[data-login=reader] .account-state" >>= (`shouldHaveText` "No password yet")
      find ui ".user-row[data-login=editor] .identity-unlink" >>= (`shouldHaveText` "Disconnect GitHub")
      find ui ".user-row[data-login=editor] .identity-unlink" >>= click
      eventually $ do
        gone <- filter (\r -> r.method == "DELETE") <$> asked
        map (\r -> r.url) gone `shouldBe` ["api/v1/admin/users/user-editor/identities/hub"]
      unmount ui
      serverStops

  it "offer no password to a user who signs in with a provider, mail a link to a verified address, and type one otherwise, saying why" $
    runPage $ do
      serverStarts
      serveDemo
      (me, people) <- demoPeople
      answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = named, exports = []}
      for_ people $ \d -> answerWith "GET" "api/v1/admin/directory" 200 (mailingTo True (withIdentities d))
      answerWith "POST" "api/v1/admin/users/user-reader/password-link" 204 ()
      ui <- startServer m Admin
      -- Edgar signs in with GitHub and has no password: nothing to set.
      _ <- find ui ".user-row[data-login=editor] .identity-unlink"
      length <$> findAll ui ".user-row[data-login=editor] .password-ask" `shouldReturn` 0
      length <$> findAll ui ".user-row[data-login=editor] .password-link-ask" `shouldReturn` 0
      -- The administrator has no verified address: a password is typed.
      find ui ".user-row[data-login=admin] .password-ask" >>= (`shouldHaveText` "Set password…")
      find ui ".user-row[data-login=admin] .password-hint" >>= (`shouldHaveText` "No verified address: type a password for them")
      -- Rita has one: a link is mailed there, once asked whether to.
      length <$> findAll ui ".user-row[data-login=reader] .password-ask" `shouldReturn` 0
      find ui ".user-row[data-login=reader] .password-link-ask" >>= (`shouldHaveText` "Send a password link…")
      find ui ".user-row[data-login=reader] .password-link-ask" >>= click
      find ui ".user-row[data-login=reader] .password-link-confirm" >>= (`shouldContainText` "rita@example.org")
      find ui ".user-row[data-login=reader] .password-link-send" >>= click
      find ui ".admin-told" >>= (`shouldContainText` "mailed to Rita Reader, at rita@example.org")
      sent <- filter (\r -> r.method == "POST") <$> asked
      map (\r -> r.url) sent `shouldBe` ["api/v1/admin/users/user-reader/password-link"]
      length <$> findAll ui ".password-link-confirm" `shouldReturn` 0
      unmount ui
      serverStops

  it "type a password for everyone where the server sends no mail, saying why" $
    runPage $ do
      serverStarts
      serveDemo
      (me, people) <- demoPeople
      answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = named, exports = []}
      for_ people $ \d -> answerWith "GET" "api/v1/admin/directory" 200 (mailingTo False (withIdentities d))
      ui <- startServer m Admin
      find ui ".user-row[data-login=reader] .password-ask" >>= (`shouldHaveText` "Set password…")
      find ui ".user-row[data-login=reader] .password-hint" >>= (`shouldHaveText` "The server sends no mail: type a password for them")
      length <$> findAll ui ".password-link-ask" `shouldReturn` 0
      unmount ui
      serverStops
  where
    demoPeople = unsafeIOToPageM $ do
      wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
      runMemWiki wiki ((,) <$> session <*> directory)
    withIdentities d = Directory {users = d.users, administrators = d.administrators, creators = d.creators, disabled = d.disabled, withPassword = d.withPassword, identities = Map.fromList [(UserId "user-editor", ["hub"])], providerOnly = Set.singleton (UserId "user-editor"), secondFactor = d.secondFactor, emails = d.emails, mailing = d.mailing, adminCreatesPasswordAccounts = d.adminCreatesPasswordAccounts, groups = d.groups, membership = d.membership}
    -- Rita has a verified address, and the server mails or not.
    mailingTo mailing d = Directory {users = d.users, administrators = d.administrators, creators = d.creators, disabled = d.disabled, withPassword = d.withPassword, identities = d.identities, providerOnly = d.providerOnly, secondFactor = d.secondFactor, emails = Map.fromList [(UserId "user-reader", AccountEmail {email = Email "rita@example.org", verified = True})], mailing, adminCreatesPasswordAccounts = d.adminCreatesPasswordAccounts, groups = d.groups, membership = d.membership}

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)
