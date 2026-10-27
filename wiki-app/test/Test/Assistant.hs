-- | The writing assistant's settings as this browser keeps them
-- ("Wiki.App.Assistant"), over the in-memory IndexedDB the native tests
-- have, which behaves as the browser's: each user's apart, under their id,
-- in a database of the assistant's own, a key forgotten on request, and
-- nothing kept once nothing is set.
module Test.Assistant (spec) where

import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Protolude
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant (..), assistantDatabase, readSettings, writeSettings)
import Wiki.Core.Assistant (Provider (..), ProviderSettings (..), Settings (..), chooseProvider, defaultSettings, settingsOf, withKey, withModel)
import Wiki.Core.Id (UserId (..))

spec :: Spec
spec = describe "Wiki.App.Assistant's settings" $ do
  let db = Database {name = "wiki-assistant-test", version = 1, stores = ["settings"]}
      fresh = run (IDB.deleteDatabase db.name)
      alice = UserId "user-alice"
      bob = UserId "user-bob"
      withKeys = withKey OpenAI (Just "sk-open") (withKey Anthropic (Just "sk-ant") defaultSettings)

  it "reads the defaults where nothing is kept" $ do
    fresh
    run (readSettings db alice) `shouldReturn` defaultSettings

  it "keeps a user's settings, and reads them back" $ do
    fresh
    let s = chooseProvider OpenAI (withModel OpenAI "gpt-6-luna" withKeys)
    run (writeSettings db alice s)
    run (readSettings db alice) `shouldReturn` s

  it "keeps each user's apart, under their id" $ do
    fresh
    run (writeSettings db alice withKeys)
    run (readSettings db bob) `shouldReturn` defaultSettings
    run (writeSettings db bob (withKey Anthropic (Just "sk-bob") defaultSettings))
    (\s -> (settingsOf Anthropic s).key) <$> run (readSettings db alice) `shouldReturn` Just "sk-ant"
    (\s -> (settingsOf Anthropic s).key) <$> run (readSettings db bob) `shouldReturn` Just "sk-bob"
    sort <$> run (IDB.keys db "settings") `shouldReturn` ["user-alice", "user-bob"]

  it "forgets a key on request, and keeps nothing once nothing is set" $ do
    fresh
    run (writeSettings db alice withKeys)
    run (writeSettings db alice (withKey OpenAI Nothing withKeys))
    s <- run (readSettings db alice)
    (settingsOf OpenAI s).key `shouldBe` Nothing
    (settingsOf Anthropic s).key `shouldBe` Just "sk-ant"
    run (writeSettings db alice (withKey Anthropic Nothing s))
    run (IDB.keys db "settings") `shouldReturn` []

  it "reads what it cannot read as the defaults" $ do
    fresh
    run (IDB.put db "settings" alice.text "not settings")
    run (readSettings db alice) `shouldReturn` defaultSettings

  it "is the class's, in a database of the assistant's own" $ do
    run (IDB.deleteDatabase assistantDatabase.name)
    run (keepAssistantSettings alice withKeys) `shouldReturn` Right ()
    run (assistantSettings alice) `shouldReturn` Right withKeys
    run (IDB.keys assistantDatabase "settings") `shouldReturn` ["user-alice"]
    assistantDatabase.name `shouldBe` "wiki-assistant"
    fmap (\s -> s.provider) <$> run (assistantSettings bob) `shouldReturn` Right Anthropic
  where
    run :: MemDOM a -> IO a
    run = runMemDOM
