-- | Keeping an account safe, in a browser (WP4.11 of docs/PLAN.md): the
-- account panel's sessions, second factor and e-mail address; the second
-- step of signing in; "Forgot your password?"; the pages of a reset's link
-- and of an address's verification; the administration's account column;
-- and the demo's own panel, with its one session and the server's features
-- shown disabled.
--
-- Over the backend over HTTP with a server in fetch's place
-- ("Test.Browser.Http") for what a server does, and over the demo for its
-- panel.
module Test.Browser.Security (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerRaw, answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Account (SignInMethods (..))
import Wiki.Api.Admin (Directory (..))
import Wiki.Api.Security
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (Session (..), session)
import Wiki.App.Backend.Admin (MonadAdmin (directory))
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Security (qrRuns)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (Standing (..))

type Specs m = (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  demo m
  panel m
  signingIn m
  resets m
  administration m

-- | One of the demo's users, signed in.
signedInAs :: Text -> PageM s SessionInfo
signedInAs uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = []}

nobody :: SessionInfo
nobody = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access = Open}, standing = NotSignedIn, providers = [], exports = []}

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

-- | What was asked with a method, as address and body.
askedWith :: Text -> PageM s [(Text, Text)]
askedWith method = map (\r -> (r.url, r.body)) . filter (\r -> r.method == method) <$> asked

demo :: forall m -> (Specs m) => Spec
demo m = describe "the demo's account panel" $
  it "lists the demo's one session, this browser's, and shows a second factor and mail disabled, with a note" $
    runPage $ do
      ui <- start m (Just "user-editor") Home
      find ui ".user-switcher-toggle" >>= click
      find ui ".demo-account-toggle" >>= click
      eventually (length <$> findAll ui ".session-item" `shouldReturn` 1)
      find ui ".session-item .session-this" >>= (`shouldHaveText` "This browser")
      length <$> findAll ui ".session-end" `shouldReturn` 0
      find ui ".second-factor-unavailable" >>= (`shouldContainText` "this demo has none")
      start' <- find ui ".second-factor-start"
      getAttribute start' "disabled" `shouldReturn` Just ""
      find ui ".email-unavailable" >>= (`shouldContainText` "this demo sends none")
      edit <- find ui ".email-edit"
      getAttribute edit "disabled" `shouldReturn` Just ""
      unmount ui

panel :: forall m -> (Specs m) => Spec
panel m = describe "the account panel" $ do
  let sessions =
        [ SessionSummary {id = SessionRef "here", createdAt = demoNow, lastSeenAt = demoNow, address = "100.64.0.7", current = True}
        , SessionSummary {id = SessionRef "there", createdAt = demoNow, lastSeenAt = demoNow, address = "100.64.0.9", current = False}
        ]
      off = SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = True}
      noAddress = EmailState {email = Nothing, verified = False, mailing = True, mailError = Nothing, asksPassword = True}
      opened = do
        serverStarts
        serveDemo
        rita <- signedInAs "user-reader"
        answerWith "GET" "api/v1/session" 200 rita
        answerWith "GET" "api/v1/account/identities" 200 SignInMethods {password = True, identities = []}
        answerWith "GET" "api/v1/account/sessions" 200 sessions
        answerWith "GET" "api/v1/account/second-factor" 200 off
        answerWith "GET" "api/v1/account/email" 200 noAddress

  it "lists the user's sessions, this one marked, and signs out another, or all but this one" $ runPage $ do
    opened
    answerWith "DELETE" "api/v1/account/sessions/there" 200 (take 1 sessions)
    answerWith "DELETE" "api/v1/account/sessions" 200 (take 1 sessions)
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    eventually (length <$> findAll ui ".session-item" `shouldReturn` 2)
    find ui ".session-current .session-this" >>= (`shouldHaveText` "This browser")
    find ui ".session-current .session-address" >>= (`shouldHaveText` "100.64.0.7")
    find ui ".session-end" >>= click
    eventually (length <$> findAll ui ".session-item" `shouldReturn` 1)
    askedWith "DELETE" `shouldReturn` [("api/v1/account/sessions/there", "")]
    find ui ".sessions-end-others" >>= (`shouldHaveText` "Sign out everywhere")
    unmount ui
    serverStops

  it "sets up a second factor: the secret as a QR code of rectangles and as text, a code, then the recovery codes once" $ runPage $ do
    opened
    let qr = ["1111111001", "1000001010", "1011101100"]
        enrolment = TotpEnrolment {secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", uri = "otpauth://totp/Wiki:reader?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", qr}
    answerWith "POST" "api/v1/account/second-factor/totp" 200 enrolment
    answerRaw "PUT" "api/v1/account/second-factor/totp" 401 "{\"error\":\"Unauthenticated\"}"
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    find ui ".second-factor-off" >>= (`shouldContainText` "Off")
    find ui ".second-factor-start" >>= click
    -- Her password first, which she has.
    find ui ".totp-password-form input[name=password]" >>= (`typeText` "rita's password")
    find ui ".totp-password-form button[type=submit]" >>= click
    _ <- find ui ".totp-qr"
    askedWith "POST" `shouldReturn` [("api/v1/account/second-factor/totp", "{\"password\":\"rita's password\"}")]
    -- A light square, and a rectangle for each run of dark modules.
    length <$> findAll ui ".totp-qr rect" `shouldReturn` 1 + length (qrRuns qr)
    find ui ".totp-secret code" >>= (`shouldHaveText` "GEZD GNBV GY3T QOJQ GEZD GNBV GY3T QOJQ")
    find ui ".totp-confirm input[name=code]" >>= (`typeText` "123456")
    find ui ".totp-confirm button[type=submit]" >>= click
    find ui ".second-factor-error" >>= (`shouldContainText` "That code is not right")
    answerWith "PUT" "api/v1/account/second-factor/totp" 200 RecoveryCodes {codes = ["abcd-efgh-ijkl-mnop", "qrst-uvwx-yz23-4567"]}
    answerWith "GET" "api/v1/account/second-factor" 200 SecondFactorState {enabled = True, recoveryCodesLeft = 2, asksPassword = True}
    find ui ".totp-confirm button[type=submit]" >>= click
    eventually (length <$> findAll ui ".recovery-code-list li" `shouldReturn` 2)
    askedWith "PUT" `shouldReturn` replicate 2 ("api/v1/account/second-factor/totp", "{\"code\":\"123456\"}")
    find ui ".recovery-kept" >>= click
    find ui ".second-factor-on" >>= (`shouldContainText` "You have 2 recovery codes left.")
    length <$> findAll ui ".recovery-code-list" `shouldReturn` 0
    unmount ui
    serverStops

  it "gives an e-mail address, which a mailed link is to verify" $ runPage $ do
    opened
    answerWith "PUT" "api/v1/account/email" 200 EmailState {email = Just "rita@example.org", verified = False, mailing = True, mailError = Nothing, asksPassword = True}
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    find ui ".email-current" >>= (`shouldContainText` "None")
    find ui ".email-edit" >>= click
    find ui ".email-form input[name=email]" >>= (`typeText` "rita@example.org")
    find ui ".email-form input[name=password]" >>= (`typeText` "rita's password")
    find ui ".email-form button[type=submit]" >>= click
    find ui ".email-told" >>= (`shouldHaveText` "A link to verify it has been mailed to rita@example.org.")
    find ui ".email-current" >>= (`shouldContainText` "not verified yet")
    _ <- find ui ".email-resend"
    askedWith "PUT" `shouldReturn` [("api/v1/account/email", "{\"email\":\"rita@example.org\",\"password\":\"rita's password\"}")]
    unmount ui
    serverStops

signingIn :: forall m -> (Specs m) => Spec
signingIn m = describe "signing in with a second factor" $
  it "asks for the code after the password, in the same place, and signs in with it" $
    runPage $ do
      serverStarts
      serveDemo
      ada <- signedInAs "user-admin"
      answerWith "GET" "api/v1/session" 200 nobody
      answerRaw "POST" "api/v1/session" 401 "{\"error\":\"SecondFactorRequired\"}"
      answerRaw "POST" "api/v1/session/second-factor" 401 "{\"error\":\"Unauthenticated\"}"
      ui <- startServer m Home
      find ui ".sign-in-toggle" >>= click
      find ui ".sign-in-form input[name=login]" >>= (`typeText` "ada")
      find ui ".sign-in-form input[name=password]" >>= (`typeText` "correct horse")
      find ui ".sign-in-form button[type=submit]" >>= click
      find ui ".sign-in-code-form input[name=code]" >>= (`typeText` "000000")
      length <$> findAll ui ".sign-in-form" `shouldReturn` 0
      find ui ".sign-in-code-form button[type=submit]" >>= click
      find ui ".sign-in-code-form .sign-in-error" >>= (`shouldContainText` "That code is not right")
      answerWith "POST" "api/v1/session/second-factor" 200 ada
      find ui ".sign-in-code-form input[name=code]" >>= clear
      find ui ".sign-in-code-form input[name=code]" >>= (`typeText` "287082")
      find ui ".sign-in-code-form button[type=submit]" >>= click
      find ui ".account .user-name" >>= (`shouldHaveText` "Ada Admin")
      length <$> findAll ui ".sign-in-code-form" `shouldReturn` 0
      map snd <$> askedWith "POST" `shouldReturn` ["{\"login\":\"ada\",\"password\":\"correct horse\"}", "{\"code\":\"000000\"}", "{\"code\":\"287082\"}"]
      unmount ui
      serverStops

resets :: forall m -> (Specs m) => Spec
resets m = describe "a password reset" $ do
  it "is asked for under the sign-in form, and says what happens without telling whether the login exists" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "POST" "api/v1/password-reset" 204 ""
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    find ui ".forgot-password" >>= (`shouldHaveText` "Forgot your password?")
    find ui ".forgot-password" >>= click
    find ui ".reset-request-form input[name=login]" >>= (`typeText` "rita")
    find ui ".reset-request-form button[type=submit]" >>= click
    find ui ".reset-told" >>= (`shouldContainText` "If that is the login or the verified address of an account")
    askedWith "POST" `shouldReturn` [("api/v1/password-reset", "{\"login\":\"rita\"}")]
    find ui ".reset-request-form button[type=button]" >>= click
    _ <- find ui ".sign-in-form input[name=login]"
    unmount ui
    serverStops

  it "says so where the server sends no mail" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "POST" "api/v1/password-reset" 400 "{\"error\":\"Invalid\",\"message\":\"This wiki does not send mail, so it cannot reset a password by mail.\"}"
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    find ui ".forgot-password" >>= click
    find ui ".reset-request-form input[name=login]" >>= (`typeText` "rita")
    find ui ".reset-request-form button[type=submit]" >>= click
    find ui ".reset-request-error" >>= (`shouldContainText` "does not send mail")
    unmount ui
    serverStops

  it "sets a new password on the link's page, then offers to sign in with it" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "POST" "api/v1/password-reset/s3cr3t" 204 ""
    ui <- startServer m (ResetPassword (MailToken "s3cr3t"))
    find ui ".reset-form input[name=new]" >>= (`typeText` "a brand new password")
    find ui ".reset-form input[name=repeat]" >>= (`typeText` "a brand new password")
    find ui ".reset-form button[type=submit]" >>= click
    find ui ".reset-done" >>= (`shouldContainText` "Your password is set")
    askedWith "POST" `shouldReturn` [("api/v1/password-reset/s3cr3t", "{\"password\":\"a brand new password\"}")]
    find ui ".reset-sign-in" >>= click
    find ui ".sign-in-notice" >>= (`shouldHaveText` "Sign in with your new password.")
    unmount ui
    serverStops

  it "says when the link no longer works" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    ui <- startServer m (ResetPassword (MailToken "used"))
    find ui ".reset-form input[name=new]" >>= (`typeText` "a brand new password")
    find ui ".reset-form input[name=repeat]" >>= (`typeText` "a brand new password")
    find ui ".reset-form button[type=submit]" >>= click
    find ui ".reset-error" >>= (`shouldContainText` "This link no longer works")
    unmount ui
    serverStops

  it "verifies an address on its link's page, with a button" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    answerRaw "POST" "api/v1/email-verification/s3cr3t" 204 ""
    ui <- startServer m (VerifyEmail (MailToken "s3cr3t"))
    -- Nothing is asked before the button is pressed.
    askedWith "POST" `shouldReturn` []
    find ui ".verify-confirm" >>= click
    find ui ".verify-done" >>= (`shouldContainText` "is verified")
    unmount ui
    serverStops

administration :: forall m -> (Specs m) => Spec
administration m = describe "the administration's accounts" $ do
  let people = unsafeIOToPageM $ do
        wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId "user-admin")})
        runMemWiki wiki ((,) <$> session <*> directory)
      withSecurity d =
        Directory
          { users = d.users
          , administrators = d.administrators
          , creators = d.creators
          , disabled = d.disabled
          , withPassword = d.withPassword
          , identities = d.identities
          , providerOnly = d.providerOnly
          , secondFactor = Set.singleton (UserId "user-editor")
          , emails = Map.fromList [(UserId "user-editor", AccountEmail {email = "edgar@example.org", verified = False})]
          , mailing = True
          , adminCreatesPasswordAccounts = d.adminCreatesPasswordAccounts
          , groups = d.groups
          , membership = d.membership
          }

  it "say who has a second factor and an address, take a second factor away, and give a new user an address" $ runPage $ do
    serverStarts
    serveDemo
    (me, listed) <- people
    answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = []}
    for_ listed $ \d -> answerWith "GET" "api/v1/admin/directory" 200 (withSecurity d)
    answerRaw "DELETE" "api/v1/admin/users/user-editor/second-factor" 204 ""
    ui <- startServer m Admin
    find ui ".user-row[data-login=editor] .account-second-factor" >>= (`shouldHaveText` "With a second factor")
    find ui ".user-row[data-login=editor] .account-email" >>= (`shouldHaveText` "edgar@example.org (not verified)")
    length <$> findAll ui ".user-row[data-login=reader] .second-factor-remove" `shouldReturn` 0
    find ui ".user-row[data-login=editor] .second-factor-remove" >>= click
    eventually (askedWith "DELETE" `shouldReturn` [("api/v1/admin/users/user-editor/second-factor", "")])
    field <- find ui ".user-create-email"
    getAttribute field "disabled" `shouldReturn` Nothing
    unmount ui
    serverStops

  it "keep the new user's address field disabled where the server sends no mail, saying why" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    field <- find ui ".user-create-email"
    getAttribute field "disabled" `shouldReturn` Just ""
    find ui ".user-create-email-note" >>= (`shouldContainText` "sends no mail")
    unmount ui
