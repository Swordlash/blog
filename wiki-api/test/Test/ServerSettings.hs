-- | The server's settings as the API speaks them (WP4.4 of docs/PLAN.md):
-- a change's secrets kept, replaced or cleared, the checks a change must
-- pass, and the JSON of a change that leaves a secret out.
module Test.ServerSettings (spec) where

import Data.Aeson (decode)
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings

-- | Settings kept with their secrets as text, as the demo keeps them.
type Kept = ServerSettingsOf (Maybe Text)

mailWith :: Maybe Text -> Maybe s -> Maybe (MailSettingsOf (Maybe s))
mailWith user password = Just MailSettings {host = "mail.example.org", port = 587, security = StartTls, user, password, from = "wiki@example.org"}

providerWithSecret :: Text -> Maybe s -> ProviderSettingsOf (Maybe s)
providerWithSecret name secret = ProviderSettings {name, kind = Google, clientId = "id", issuer = Nothing, secret}

kept :: Kept
kept =
  ServerSettings
    { publicUrl = Just "https://wiki.example.org/"
    , mail = mailWith (Just "wiki") (Just "pw")
    , providers = [providerWithSecret "google" (Just "g"), providerWithSecret "other" (Just "o")]
    }

spec :: Spec
spec = describe "the server's settings" $ do
  describe "a change" $ do
    it "keeps each secret it leaves out, by the provider's name" $ do
      let change = ServerSettings {publicUrl = kept.publicUrl, mail = mailWith (Just "wiki") Nothing, providers = [providerWithSecret "other" Nothing, providerWithSecret "google" Nothing]}
          changed = applyChange identity kept change
      (\m -> m.password) <$> changed.mail `shouldBe` Just (Just "pw")
      map (\p -> (p.name, p.secret)) changed.providers `shouldBe` [("other", Just "o"), ("google", Just "g")]

    it "replaces a secret given, and clears an empty one" $ do
      let change = ServerSettings {publicUrl = kept.publicUrl, mail = mailWith Nothing (Just ""), providers = [providerWithSecret "google" (Just "new")]}
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
        `shouldBe` Just ServerSettings {publicUrl = Nothing, mail = Just MailSettings {host = "h", port = 25, security = Plain, user = Nothing, password = Nothing, from = "f@example.org"}, providers = [ProviderSettings {name = "g", kind = Google, clientId = "c", issuer = Nothing, secret = Nothing}]}

  describe "the checks" $ do
    let checked = checkServerSettings isJust
    it "take settings that can be, normalised" $
      ((\s -> s.publicUrl) <$> checked kept {publicUrl = Just " https://wiki.example.org/team "}) `shouldBe` Right (Just "https://wiki.example.org/team/")
    it "take nothing set" $ checked (noServerSettings :: Kept) `shouldBe` Right noServerSettings
    it "refuse what cannot be, saying why" $ do
      let refused s why = either (why `T.isInfixOf`) (const False) (checked s) `shouldBe` True
      refused kept {publicUrl = Nothing} "The mail needs the wiki's public address"
      refused kept {mail = Nothing, publicUrl = Nothing} "The providers need the wiki's public address"
      refused kept {publicUrl = Just "ftp://x/"} "starts with http:// or https://"
      refused kept {mail = mailWith (Just "wiki") Nothing} "needs its password"
      refused kept {providers = [providerWithSecret "google" Nothing]} "needs its client secret"
      refused kept {providers = [providerWithSecret "g" (Just "x"), providerWithSecret "g" (Just "y")]} "two providers named g"
      refused kept {providers = [ProviderSettings {name = "corp", kind = Generic, clientId = "c", issuer = Nothing, secret = Just "x"}]} "needs its issuer"
      refused kept {providers = [ProviderSettings {name = "corp", kind = Generic, clientId = "c", issuer = Just "http://id.example.org", secret = Just "x"}]} "must start with https://"
      refused kept {providers = [providerWithSecret "Bad Name" (Just "x")]} "lower-case letters"
      refused kept {providers = [ProviderSettings {name = "g", kind = Google, clientId = " ", issuer = Nothing, secret = Just "x"}]} "needs its client id"
    it "let a provider on this machine be talked to over plain HTTP, for a test" $
      providerProblems ProviderSettings {name = "local", kind = Generic, clientId = "c", issuer = Just "http://127.0.0.1:9000", secret = ()} `shouldBe` []

  it "name a provider for its buttons, and give the redirect URI to register" $ do
    map (`providerLabel` "corp") [Google, Apple, GitHub, Generic] `shouldBe` ["Google", "Apple", "GitHub", "Corp"]
    redirectUri "https://wiki.example.org/" "corp" `shouldBe` "https://wiki.example.org/auth/corp/callback"
