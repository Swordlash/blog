-- | The administration's section on the server itself, in a browser
-- (WP4.4 of docs/PLAN.md, "Wiki.App.View.Server"): the public address, the
-- mail server and the providers set from their forms over the demo's wiki,
-- each secret typed once and never shown again, "Check" and the test
-- mail, which the demo says it cannot do; and over the backend over HTTP,
-- a provider checked by the server and a change saved that keeps the
-- secrets it does not touch.
module Test.Browser.Server (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (eitherDecodeStrict')
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Browser.Mount (start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.ServerSettings
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  demo m
  overHttp m

-- | The section's public address set, as typed.
setAddress :: Mounted s q o m -> Text -> PageM s ()
setAddress ui url = do
  find ui ".server-url-edit" >>= click
  find ui ".server-url-form input[name=url]" >>= (`typeText` url)
  find ui ".server-url-form button[type=submit]" >>= click
  eventually (find ui ".server-url-value" >>= (`shouldHaveText` (if "/" `T.isSuffixOf` url then url else url <> "/")))

-- | Choose the option at this index of a menu, from the keyboard.
choose :: Mounted s q o m -> Text -> Int -> PageM s ()
choose ui selector n = do
  menu <- find ui selector
  focus menu
  press "Home"
  replicateM_ n (press "ArrowDown")

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

demo :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m) => Spec
demo m = describe "over the demo's wiki" $ do
  it "sets the public address and a mail server, whose password it never shows again" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".server-url-value" >>= (`shouldContainText` "Not set")
    setAddress ui "https://wiki.example.org"
    find ui ".server-mail-none" >>= (`shouldContainText` "No mail server")
    find ui ".server-mail-edit" >>= click
    find ui ".server-mail-form input[name=host]" >>= (`typeText` "mail.example.org")
    find ui ".server-mail-form input[name=from]" >>= (`typeText` "wiki@example.org")
    find ui ".server-mail-form input[name=user]" >>= (`typeText` "wiki")
    find ui ".server-mail-form input[name=password]" >>= (`typeText` "a mail password")
    find ui ".server-mail-form button[type=submit]" >>= click
    eventually (find ui ".server-mail-password" >>= (`shouldHaveText` "set"))
    find ui ".server-mail-host" >>= (`shouldContainText` "mail.example.org:587")
    length <$> findAll ui ".admin-server input[type=password]" `shouldReturn` 0
    find ui ".admin-server" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "a mail password"))
    -- Changing it offers to replace the password or clear it, never shows
    -- it; a user without one is refused, and the form stays.
    find ui ".server-mail-edit" >>= click
    length <$> findAll ui ".server-mail-form input[name=password]" `shouldReturn` 0
    find ui ".server-mail-form .server-secret-state" >>= (`shouldHaveText` "Set")
    find ui ".server-mail-form .server-secret-clear" >>= click
    find ui ".server-mail-form .server-secret-state" >>= (`shouldHaveText` "Cleared when saved")
    find ui ".server-mail-form button[type=submit]" >>= click
    find ui ".admin-server .error" >>= (`shouldContainText` "needs its password")
    find ui ".server-mail-form input[name=user]" >>= clear
    find ui ".server-mail-form button[type=submit]" >>= click
    eventually (find ui ".server-mail-password" >>= (`shouldHaveText` "not set"))
    -- The demo sends no mail, and says so.
    find ui ".server-mail-test input[name=to]" >>= (`typeText` "ada@example.org")
    find ui ".server-mail-test button[type=submit]" >>= click
    find ui ".server-mail-test .error" >>= (`shouldContainText` "The demo sends no mail")
    find ui ".server-mail-remove" >>= click
    _ <- eventually (find ui ".server-mail-none")
    unmount ui

  it "adds a provider with its secret and redirect URI, keeps the secret through a change, and removes it" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".server-providers .empty" >>= (`shouldContainText` "No provider")
    setAddress ui "https://wiki.example.org/"
    find ui ".server-provider-add" >>= click
    find ui ".server-provider-form input[name=name]" >>= (`typeText` "corp")
    choose ui ".server-provider-form select[name=kind]" 3
    find ui ".server-provider-form input[name=client-id]" >>= (`typeText` "wiki")
    find ui ".server-provider-form input[name=issuer]" >>= (`typeText` "https://id.example.org/realms/corp")
    find ui ".server-provider-form input[name=secret]" >>= (`typeText` "the client secret")
    find ui ".server-provider-form .server-provider-redirect" >>= (`shouldContainText` "https://wiki.example.org/auth/corp/callback")
    -- Checked before it is saved: the demo cannot ask it.
    find ui ".server-provider-form .server-provider-form-check" >>= click
    find ui ".server-provider-form .server-provider-checked" >>= (`shouldContainText` "The demo asks no provider")
    find ui ".server-provider-form button[type=submit]" >>= click
    let row = ".server-provider[data-name=corp] "
    eventually (find ui (row <> ".server-provider-secret") >>= (`shouldHaveText` "set"))
    find ui (row <> ".server-provider-redirect") >>= (`shouldHaveText` "https://wiki.example.org/auth/corp/callback")
    find ui (row <> ".server-provider-kind") >>= (`shouldHaveText` "Corp (oidc)")
    find ui ".admin-server" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "the client secret"))
    find ui (row <> ".server-provider-check") >>= click
    find ui (row <> ".server-provider-checked") >>= (`shouldContainText` "The demo asks no provider")
    -- Changed: its name stays, its secret is kept.
    find ui (row <> ".server-provider-edit") >>= click
    find ui ".server-provider-form input[name=name]" >>= (`getProperty` "readOnly") >>= (`shouldBe` "true")
    length <$> findAll ui ".server-provider-form input[name=secret]" `shouldReturn` 0
    client <- find ui ".server-provider-form input[name=client-id]"
    clear client
    typeText client "wiki-2"
    find ui ".server-provider-form button[type=submit]" >>= click
    eventually (find ui (row <> ".server-provider-row dd") >>= (`shouldHaveText` "wiki-2"))
    find ui (row <> ".server-provider-secret") >>= (`shouldHaveText` "set")
    find ui (row <> ".server-provider-remove") >>= click
    eventually (length <$> findAll ui ".server-provider" `shouldReturn` 0)
    unmount ui

  it "says why settings cannot be, and keeps the form open" $ runPage $ do
    ui <- start m (Just "user-admin") Admin
    find ui ".server-provider-add" >>= click
    find ui ".server-provider-form input[name=name]" >>= (`typeText` "google")
    find ui ".server-provider-form input[name=client-id]" >>= (`typeText` "id")
    find ui ".server-provider-form input[name=secret]" >>= (`typeText` "s")
    find ui ".server-provider-form button[type=submit]" >>= click
    find ui ".admin-server .error" >>= (`shouldContainText` "The providers need the wiki's public address")
    _ <- find ui ".server-provider-form"
    find ui ".server-provider-form .server-cancel" >>= click
    eventually (length <$> findAll ui ".server-provider-form" `shouldReturn` 0)
    unmount ui

overHttp :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m) => Spec
overHttp m = describe "over HTTP" $
  it "checks a provider through the server, and saves a change that keeps the secrets it does not touch" $
    runPage $ do
      serverStarts
      serveDemo
      let corp = ProviderSettings {name = "corp", kind = Generic, clientId = "wiki", issuer = Just "https://id.example.org/realms/corp", secret = Set}
          set = ServerSettings {publicUrl = Just "https://wiki.example.org/", mail = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user = Just "wiki", password = Set, from = "wiki@example.org"}, providers = [corp]}
          found = Discovered {issuer = "https://id.example.org/realms/corp", authorization = "https://id.example.org/auth", token = "https://id.example.org/token", userinfo = Nothing}
      answerWith "GET" "api/v1/admin/server" 200 set
      answerWith "POST" "api/v1/admin/server/providers/corp/check" 200 ProviderCheck {redirectUri = Just "https://wiki.example.org/auth/corp/callback", clientSecret = Set, discovered = Just found, problem = Nothing}
      answerWith "PUT" "api/v1/admin/server" 200 set
      ui <- startServer m Admin
      let row = ".server-provider[data-name=corp] "
      eventually (find ui (row <> ".server-provider-check")) >>= click
      find ui (row <> ".server-provider-checked") >>= (`shouldContainText` "It answered: people can sign in with it.")
      find ui (row <> ".server-provider-checked") >>= (`shouldContainText` "https://id.example.org/token")
      find ui (row <> ".server-provider-edit") >>= click
      find ui ".server-provider-form button[type=submit]" >>= click
      eventually $ do
        puts <- filter (\r -> r.method == "PUT") <$> asked
        map (\r -> (r.url, eitherDecodeStrict' (encodeUtf8 r.body))) puts
          `shouldBe` [("api/v1/admin/server", Right ((const Nothing <$> set) :: ServerSettingsChange))]
      unmount ui
      serverStops
