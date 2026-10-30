-- | The server's settings as the API speaks them (WP4.4 of docs/PLAN.md):
-- a change's secrets kept, replaced or cleared, the checks a change must
-- pass, and the JSON of a change that leaves a secret out.
module Test.ServerSettings (spec) where

import Data.Aeson (decode, encode)
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings
import Wiki.Core.Markdown.Box (BoxColour (..), BoxIcon (..), BoxKind (..))
import Wiki.Core.Url (Url (..))

-- | Settings kept with their secrets as text, as the demo keeps them.
type Kept = ServerSettingsOf (Maybe Text)

mailWith :: Maybe Text -> Maybe s -> Maybe (MailSettingsOf (Maybe s))
mailWith user password = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user, password, from = "wiki@example.org"}

providerWithSecret :: Text -> Maybe s -> ProviderSettingsOf (Maybe s)
providerWithSecret name secret = ProviderSettings {name, kind = Google, clientId = "id.apps.googleusercontent.com", issuer = Nothing, secret}

kept :: Kept
kept =
  ServerSettings
    { publicUrl = Just (Url "https://wiki.example.org/")
    , mail = mailWith (Just "wiki") (Just "pw")
    , providers = [providerWithSecret "google" (Just "g"), providerWithSecret "other" (Just "o")]
    , assistantHosts = ["http://localhost:11434"]
    , boxes = []
    , homePage = defaultHomePage
    }

-- | A kind of box, blue with no icon, labelled as given.
box :: Text -> Text -> BoxKind
box name label = BoxKind {name, label, colour = Blue, icon = NoIcon}

spec :: Spec
spec = describe "the server's settings" $ do
  describe "the home page" $ do
    it "defaults to the directory when older settings omit it" $
      ((\s -> s.homePage) <$> (decode "{\"providers\":[]}" :: Maybe ServerSettingsChange)) `shouldBe` Just defaultHomePage
    it "round trips the Markdown and independent section switches" $ do
      let home = HomePage {title = "Welcome", body = "# Start\r\n\n> [!exercise]\n> Work.", showSpaces = False, showRecent = True}
      decode (encode home) `shouldBe` Just home
      (checkServerSettings isJust (noServerSettings {homePage = home} :: Kept)) `shouldBe` Right noServerSettings {homePage = home}
    it "refuses an empty title and trims a title without changing Markdown" $ do
      checkHomePage defaultHomePage {title = "  "} `shouldSatisfy` isLeft
      checkHomePage defaultHomePage {title = " Welcome ", body = "  source\r\n"} `shouldBe` Right defaultHomePage {title = "Welcome", body = "  source\r\n"}
  describe "a change" $ do
    it "keeps each secret it leaves out, by the provider's name" $ do
      let change = ServerSettings {publicUrl = kept.publicUrl, mail = mailWith (Just "wiki") Nothing, providers = [providerWithSecret "other" Nothing, providerWithSecret "google" Nothing], assistantHosts = [], boxes = [], homePage = defaultHomePage}
          changed = applyChange identity kept change
      (\m -> m.password) <$> changed.mail `shouldBe` Just (Just "pw")
      map (\p -> (p.name, p.secret)) changed.providers `shouldBe` [("other", Just "o"), ("google", Just "g")]

    it "replaces a secret given, and clears an empty one" $ do
      let change = ServerSettings {publicUrl = kept.publicUrl, mail = mailWith Nothing (Just ""), providers = [providerWithSecret "google" (Just "new")], assistantHosts = [], boxes = [], homePage = defaultHomePage}
          changed = applyChange identity kept change
      (\m -> m.password) <$> changed.mail `shouldBe` Just Nothing
      map (\p -> p.secret) changed.providers `shouldBe` [Just "new"]

    it "drops what it leaves out, secrets and all" $ do
      let changed = applyChange identity kept noServerSettings
      changed `shouldBe` noServerSettings
      -- A provider added again under the name of one removed has no secret.
      (applyChange identity changed noServerSettings {providers = [providerWithSecret "google" Nothing]}).providers `shouldBe` [providerWithSecret "google" Nothing]

    it "is read with a secret left out as keeping it" $ do
      let json = "{\"publicUrl\":null,\"mail\":{\"host\":\"h\",\"port\":25,\"security\":\"plain\",\"user\":null,\"from\":\"f@example.org\"},\"providers\":[{\"name\":\"g\",\"kind\":\"google\",\"clientId\":\"c\",\"issuer\":null}]}"
      (decode json :: Maybe ServerSettingsChange)
        `shouldBe` Just ServerSettings {publicUrl = Nothing, mail = Just MailSettings {host = "h", port = 25, security = Plain, user = Nothing, password = Nothing, from = "f@example.org"}, providers = [ProviderSettings {name = "g", kind = Google, clientId = "c", issuer = Nothing, secret = Nothing}], assistantHosts = [], boxes = [], homePage = defaultHomePage}

    it "takes the assistant's hosts as the change gives them" $
      (applyChange identity kept (noServerSettings {assistantHosts = ["https://openrouter.ai"]} :: ServerSettingsChange)).assistantHosts `shouldBe` ["https://openrouter.ai"]

  describe "the checks" $ do
    let checked = checkServerSettings isJust
    it "take settings that can be, normalised" $
      ((\s -> s.publicUrl) <$> checked kept {publicUrl = Just (Url " https://wiki.example.org/team ")}) `shouldBe` Right (Just (Url "https://wiki.example.org/team/"))
    it "take nothing set" $ checked (noServerSettings :: Kept) `shouldBe` Right noServerSettings
    it "take the assistant's hosts as origins, each once, and refuse what is not one" $ do
      ((\s -> s.assistantHosts) <$> checked kept {assistantHosts = ["https://OpenRouter.ai/api/v1", " ", "https://openrouter.ai", "http://localhost:11434"]})
        `shouldBe` Right ["https://openrouter.ai", "http://localhost:11434"]
      checked kept {assistantHosts = ["https://a.example; script-src *"]} `shouldSatisfy` isLeft
    it "take kinds of box, named in lower case, an empty label made from the name" $
      ((\s -> s.boxes) <$> checked kept {boxes = [box " Exercise " "  ", box "fun-fact" " A fun fact "]})
        `shouldBe` Right [box "exercise" "Exercise", box "fun-fact" "A fun fact"]
    it "refuse a kind of box whose name is not letters and dashes, is one of the five, or is taken" $ do
      let refusedBox kinds why = either (why `T.isInfixOf`) (const False) (checked kept {boxes = kinds}) `shouldBe` True
      for_ ["note", "TIP", "Caution"] $ \n -> refusedBox [box n ""] "one of GitHub's five"
      for_ ["two words", "exercise2", "-x", "\233tude", "x_y", "title"] $ \n -> refusedBox [box n ""] "letters and dashes"
      refusedBox [box "" "Label"] "needs its name"
      refusedBox [box "exercise" "", box "Exercise" ""] "two kinds of box named exercise"
      refusedBox [box "exercise" (T.replicate 61 "x")] "longer than 60"
    it "read settings stored before boxes existed as having none" $
      ((\s -> s.boxes) <$> (decode "{\"publicUrl\":null,\"mail\":null,\"providers\":[]}" :: Maybe ServerSettingsChange)) `shouldBe` Just []
    it "refuse what cannot be, saying why" $ do
      let refused s why = either (why `T.isInfixOf`) (const False) (checked s) `shouldBe` True
      refused kept {publicUrl = Nothing} "The mail needs the wiki's public address"
      refused kept {mail = Nothing, publicUrl = Nothing} "The providers need the wiki's public address"
      refused kept {publicUrl = Just (Url "ftp://x/")} "starts with http:// or https://"
      refused kept {mail = mailWith (Just "wiki") Nothing} "needs its password"
      refused kept {providers = [providerWithSecret "google" Nothing]} "needs its client secret"
      refused kept {providers = [providerWithSecret "g" (Just "x"), providerWithSecret "g" (Just "y")]} "two providers named g"
      refused kept {providers = [ProviderSettings {name = "corp", kind = Generic, clientId = "c", issuer = Nothing, secret = Just "x"}]} "needs its issuer"
      refused kept {providers = [ProviderSettings {name = "corp", kind = Generic, clientId = "c", issuer = Just (Url "http://id.example.org"), secret = Just "x"}]} "must start with https://"
      refused kept {providers = [providerWithSecret "Bad Name" (Just "x")]} "lower-case letters"
      refused kept {providers = [ProviderSettings {name = "g", kind = Google, clientId = " ", issuer = Nothing, secret = Just "x"}]} "needs its client id"
      refused kept {providers = [ProviderSettings {name = "g", kind = Google, clientId = "1234-abcd", issuer = Nothing, secret = Just "x"}]} "The provider g's client id should end with .apps.googleusercontent.com, as Google writes it."
    it "take a Google client id only in the form Google writes it, and any other kind's as it is" $ do
      providerProblems ProviderSettings {name = "g", kind = Google, clientId = "1234-abcd.apps.googleusercontent.com", issuer = Nothing, secret = ()} `shouldBe` []
      providerProblems ProviderSettings {name = "g", kind = Google, clientId = "1234-abcd", issuer = Nothing, secret = ()}
        `shouldBe` ["The provider g's client id should end with .apps.googleusercontent.com, as Google writes it."]
      providerProblems ProviderSettings {name = "hub", kind = GitHub, clientId = "Iv1.abc", issuer = Nothing, secret = ()} `shouldBe` []
    it "let a provider on this machine be talked to over plain HTTP, for a test" $
      providerProblems ProviderSettings {name = "local", kind = Generic, clientId = "c", issuer = Just (Url "http://127.0.0.1:9000"), secret = ()} `shouldBe` []

  it "name a provider for its buttons, and give the redirect URI to register" $ do
    map (`providerLabel` "corp") [Google, Apple, GitHub, Generic] `shouldBe` ["Google", "Apple", "GitHub", "Corp"]
    redirectUri (Url "https://wiki.example.org/") "corp" `shouldBe` Url "https://wiki.example.org/auth/corp/callback"
