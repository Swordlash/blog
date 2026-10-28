-- | The vault's format ("Wiki.Core.Assistant.Vault"): what is sealed and
-- what stays in the clear, the vault and a device's record written and
-- read back, a vault of a newer format refused, a removed passkey's
-- wrapped key gone, the old settings told from a record, and the
-- settings merged when a device unlocks the vault.
module Test.Vault (spec) where

import Data.Aeson (decode, encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Core.Assistant
import Wiki.Core.Assistant.Vault

-- | Settings with keys, a model, an effort, a base URL, and what was
-- learnt from a provider. The keys are made up for the test.
full :: Settings
full =
  withModels Anthropic [Listed (ModelName "claude-test") Nothing (Just 1)] (UTCTime (fromGregorian 2026 10 28) 0)
    $ withReached OpenAI False
    $ withBaseUrl OpenAI "http://localhost:11434/v1"
    $ withEffort Anthropic "high"
    $ withModel Anthropic "claude-test"
    $ withKey OpenAI (Just "test-key-openai")
    $ withKey Anthropic (Just "test-key-anthropic") defaultSettings

-- | Whether some JSON, as written, contains a text.
contains :: ByteString -> BSL.ByteString -> Bool
contains part whole = not (BS.null (snd (BS.breakSubstring part (BSL.toStrict whole))))

vault :: Vault
vault =
  Vault
    { format = vaultFormat
    , salt = "c2FsdA"
    , sealed = Sealed {nonce = "bm9uY2U", ciphertext = "Y2lwaGVy"}
    , wrapped = Map.fromList [(CredentialId "Y3JlZC0x", WrappedKey "bjE" "azE"), (CredentialId "Y3JlZC0y", WrappedKey "bjI" "azI")]
    }

spec :: Spec
spec = describe "Wiki.Core.Assistant.Vault" $ do
  describe "what is sealed" $ do
    it "is the keys, the models, the efforts and the base URLs, without what was learnt" $ do
      let secrets = secretsOf full
      (settingsOf Anthropic secrets).key `shouldBe` Just (ApiKey "test-key-anthropic")
      (settingsOf Anthropic secrets).model `shouldBe` Just (ModelName "claude-test")
      (settingsOf Anthropic secrets).effort `shouldBe` Just "high"
      (settingsOf OpenAI secrets).baseUrl `shouldBe` (settingsOf OpenAI full).baseUrl
      (settingsOf Anthropic secrets).fetched `shouldBe` Nothing
      (settingsOf OpenAI secrets).unreachable `shouldBe` False

    it "leaves in the clear only what was learnt, and no key" $ do
      let learnt = learntOf full
      all (\ps -> isNothing ps.key && isNothing ps.baseUrl && isNothing ps.model) (Map.elems learnt.byProvider) `shouldBe` True
      encode learnt `shouldSatisfy` (not . contains "test-key")
      (settingsOf Anthropic learnt).fetched `shouldBe` (settingsOf Anthropic full).fetched
      (settingsOf OpenAI learnt).unreachable `shouldBe` True

    it "makes the settings whole again" $
      joinSettings (secretsOf full) (learntOf full) `shouldBe` full

  describe "the vault" $ do
    it "is read back as it is written" $
      decode (encode vault) `shouldBe` Just vault

    it "is written with its format, salt, sealed settings and wrapped keys by credential id" $
      decode (encode vault)
        `shouldBe` Just
          ( object
              [ "format" .= (1 :: Int)
              , "salt" .= ("c2FsdA" :: Text)
              , "nonce" .= ("bm9uY2U" :: Text)
              , "ciphertext" .= ("Y2lwaGVy" :: Text)
              , "wrapped" .= object ["Y3JlZC0x" .= object ["nonce" .= ("bjE" :: Text), "key" .= ("azE" :: Text)], "Y3JlZC0y" .= object ["nonce" .= ("bjI" :: Text), "key" .= ("azI" :: Text)]]
              ]
          )

    it "is refused when a newer wiki wrote it, or it is no vault's format" $ do
      let at n = encode (object ["format" .= (n :: Int), "salt" .= ("s" :: Text), "nonce" .= ("n" :: Text), "ciphertext" .= ("c" :: Text)])
      (decode (at 2) :: Maybe Vault) `shouldBe` Nothing
      (decode (at 0) :: Maybe Vault) `shouldBe` Nothing
      (\v -> v.wrapped) <$> (decode (at 1) :: Maybe Vault) `shouldBe` Just mempty

    it "loses a removed passkey's wrapped key, and keeps the others" $ do
      let removed = withoutPasskey (CredentialId "Y3JlZC0x") vault
      wrappedFor (CredentialId "Y3JlZC0x") removed `shouldBe` Nothing
      wrappedFor (CredentialId "Y3JlZC0y") removed `shouldBe` Just (WrappedKey "bjI" "azI")
      encode removed `shouldSatisfy` (not . contains "Y3JlZC0x")
      removed.sealed `shouldBe` vault.sealed

    it "keeps its salt and wrapped keys when its settings are sealed again" $ do
      let again = withSealed (Sealed "bmV3" "bmV3IGNpcGhlcg") vault
      (again.salt, again.wrapped, sealedOf again) `shouldBe` (vault.salt, vault.wrapped, Sealed "bmV3" "bmV3IGNpcGhlcg")
      wrappedFor (CredentialId "Y3JlZC0z") (withWrapped (CredentialId "Y3JlZC0z") (WrappedKey "bjM" "azM") vault) `shouldBe` Just (WrappedKey "bjM" "azM")

  describe "a device's record" $ do
    let record = DeviceRecord {sealed = Just (Sealed "bg" "Yw"), server = Just ServerCopy {tag = VaultTag "\"3\"", vault}, learnt = learntOf full, askEachTime = True}
    it "is read back as it is written, and holds no key in the clear" $ do
      readStored (BSL.toStrict (encode record)) `shouldBe` Right (Current record)
      encode record `shouldSatisfy` (not . contains "test-key")

    it "is told from the settings stored as text before the vault, which are read as such" $
      readStored (BSL.toStrict (encode full)) `shouldBe` Right (OldSettings full)

    it "is refused when a newer wiki wrote it" $
      readStored "{\"device\":2}" `shouldSatisfy` isLeft

    it "reads as nothing set, with no key kept, when written empty" $
      readStored (BSL.toStrict (encode emptyRecord)) `shouldBe` Right (Current emptyRecord)

  describe "unlocking on a device that was used locked" $ do
    it "keeps the vault's key for a provider, and takes a key typed here for a provider the vault has none for" $ do
      let fromVault = withKey Anthropic (Just "vault-key") defaultSettings
          typedHere = withKey OpenAI (Just "typed-key") (withKey Anthropic (Just "typed-anthropic") defaultSettings)
          merged = mergeUnlocked fromVault typedHere
      (settingsOf Anthropic merged).key `shouldBe` Just (ApiKey "vault-key")
      (settingsOf OpenAI merged).key `shouldBe` Just (ApiKey "typed-key")
      merged.provider `shouldBe` fromVault.provider
