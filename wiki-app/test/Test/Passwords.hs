-- | What the views offer for a password (WP5.6 of docs/PLAN.md), as the
-- views decide it: the password's control in the administration's dialog
-- for a user ("Wiki.App.View.UserDialog"), which mails a link where it can, types a
-- password where it cannot and says why, and offers nothing to a user who
-- signs in with a provider and has no password to set; the button in the
-- menu under a signed-in user's name ("Wiki.App.View.SignIn"), which
-- offers no "Set a password…" to such a user; and what the panel's second
-- factor and address say to a user without a password
-- ("Wiki.App.View.Security"). That the views render what
-- these say is the browser suite's (@Test.Browser.Admin@,
-- @Test.Browser.Providers@).
module Test.Passwords (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.Account (LinkedIdentity (..), SignInMethods (..))
import Wiki.Api.Admin (Directory (..), summaryOf)
import Wiki.Api.Security (AccountEmail (..), EmailState (..))
import Wiki.App.View.Security (addressText, factorOffText)
import Wiki.App.View.SignIn (passwordOffer)
import Wiki.App.View.UserDialog (NoLink (..), PasswordControl (..), passwordControl)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Email (..), Login (..), SignInProvider (..), User (..))

spec :: Spec
spec = describe "what the views offer for a password" $ do
  adminRow
  ownMenu
  ownSafety

-- | Ada has a password and a verified address; Bea a password and an
-- address she has not verified; Cy no address; Dee signs in with Google,
-- which the server has, and has no password; Eve has no password and an
-- account at a provider the server no longer has; Fay is disabled, with a
-- verified address.
people :: Directory
people = mailingOr True

-- | The people, with the server mailing or not.
mailingOr :: Bool -> Directory
mailingOr mailing =
  Directory
    { users = [person "ada", person "bea", person "cy", person "dee", person "eve", person "fay"]
    , administrators = mempty
    , creators = mempty
    , disabled = Set.fromList [uid "fay"]
    , withPassword = Set.fromList (map uid ["ada", "bea", "cy", "fay"])
    , identities = Map.fromList [(uid "dee", ["google"]), (uid "eve", ["gone"])]
    , providerOnly = Set.fromList [uid "dee"]
    , secondFactor = mempty
    , emails =
        Map.fromList
          [ (uid "ada", AccountEmail {email = Email "ada@example.org", verified = True})
          , (uid "bea", AccountEmail {email = Email "bea@example.org", verified = False})
          , (uid "dee", AccountEmail {email = Email "dee@example.org", verified = True})
          , (uid "eve", AccountEmail {email = Email "eve@example.org", verified = True})
          , (uid "fay", AccountEmail {email = Email "fay@example.org", verified = True})
          ]
    , mailing
    , adminCreatesPasswordAccounts = True
    , groups = []
    , membership = mempty
    }
  where
    person login = User {id = uid login, login = Login login, displayName = login}

uid :: Text -> UserId
uid login = UserId ("user-" <> login)

-- | What the dialog offers for the password of the user with this id.
control :: Directory -> UserId -> PasswordControl
control d u = maybe (panic "no such user") (passwordControl d.mailing . summaryOf d) (find (\x -> x.id == u) d.users)

adminRow :: Spec
adminRow = describe "the password's control in the administration's dialog for a user" $ do
  it "mails a link to a verified address where the server sends mail" $
    control people (uid "ada") `shouldBe` SendLink "ada@example.org"

  it "types a password where there is no verified address, and says so" $ do
    control people (uid "bea") `shouldBe` TypePassword NoVerifiedAddress
    control people (uid "cy") `shouldBe` TypePassword NoVerifiedAddress

  it "types one for everyone where the server sends no mail, and says so" $
    for_ ["ada", "bea", "cy", "eve", "fay"] $ \login ->
      (login, control (mailingOr False) (uid login)) `shouldBe` (login, TypePassword NoMail)

  it "offers nothing to a user who signs in with a provider the server has, and has no password" $ do
    control people (uid "dee") `shouldBe` NoPasswordControl
    control (mailingOr False) (uid "dee") `shouldBe` NoPasswordControl

  it "treats a user whose provider is gone as any other, who has no way in" $
    control people (uid "eve") `shouldBe` SendLink "eve@example.org"

  it "types a password for a disabled user, whom a link does not work for" $
    control people (uid "fay") `shouldBe` TypePassword LoginDisabled

ownMenu :: Spec
ownMenu = describe "the button in the menu under a user's name" $ do
  let google = SignInProvider {name = "google", label = "Google"}
      at provider = LinkedIdentity {provider, email = Nothing, name = Nothing, linkedAt = UTCTime (fromGregorian 2026 10 27) 0}
  it "changes the password of a user who has one, with a provider or without" $ do
    passwordOffer [google] SignInMethods {password = True, identities = []} `shouldBe` Just "Change password…"
    passwordOffer [google] SignInMethods {password = True, identities = [at "google"]} `shouldBe` Just "Change password…"

  it "sets none for a user who signs in with a provider the server has, and has no password" $
    passwordOffer [google] SignInMethods {password = False, identities = [at "google"]} `shouldBe` Nothing

  it "sets one for a user with no password and no provider the server has: no way in otherwise" $ do
    passwordOffer [google] SignInMethods {password = False, identities = []} `shouldBe` Just "Set a password…"
    passwordOffer [google] SignInMethods {password = False, identities = [at "gone"]} `shouldBe` Just "Set a password…"
    passwordOffer [] SignInMethods {password = False, identities = [at "google"]} `shouldBe` Just "Set a password…"

ownSafety :: Spec
ownSafety = describe "the panel's second factor and address" $ do
  let stateOf email verified asksPassword = EmailState {email = Email <$> email, verified, mailing = True, mailError = Nothing, asksPassword}
  it "speak of the password of a user who has one" $ do
    factorOffText True `shouldBe` "Off: your password alone signs you in."
    addressText (stateOf Nothing False True) `shouldBe` "None: a forgotten password can then only be reset by an administrator."
    addressText (stateOf (Just "ada@example.org") True True) `shouldBe` "ada@example.org, verified: a forgotten password can be reset by mail."

  it "speak of the provider's account of a user who has no password, and of no password to reset" $ do
    factorOffText False `shouldBe` "Off: signing in with your provider's account asks for no code."
    addressText (stateOf Nothing False False) `shouldBe` "None: you sign in with your provider's account, and have no password to reset."
    addressText (stateOf (Just "dee@example.org") True False) `shouldBe` "dee@example.org, verified: the wiki's mail to you goes there."
    for_ [False, True] $ \withOne ->
      addressText (stateOf (Just "dee@example.org") False withOne) `shouldBe` "dee@example.org, not verified yet: follow the link mailed to it."
