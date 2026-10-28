-- | The writing assistant's settings as this browser keeps them
-- ("Wiki.App.Assistant"), over the in-memory IndexedDB the native tests
-- have, which behaves as the browser's: each user's apart, under their id,
-- in a database of the assistant's own, a key forgotten on request,
-- nothing kept once nothing is set, a provider's list of models and
-- address kept with the rest, and a change made to them as they are kept.
module Test.Assistant (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Protolude
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant (..), assistantDatabase, readSettings, updateAssistantSettings, writeSettings)
import Wiki.Core.Assistant
  ( ApiKey (..)
  , AssistantError (..)
  , ErrorKind (..)
  , Listed (..)
  , ModelName (..)
  , Provider (..)
  , ProviderSettings (..)
  , Settings (..)
  , chooseProvider
  , defaultSettings
  , readyFor
  , settingsOf
  , withBaseUrl
  , withKey
  , withModel
  , withModels
  , withReached
  )
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
    (\s -> (settingsOf Anthropic s).key) <$> run (readSettings db alice) `shouldReturn` Just (ApiKey "sk-ant")
    (\s -> (settingsOf Anthropic s).key) <$> run (readSettings db bob) `shouldReturn` Just (ApiKey "sk-bob")
    sort <$> run (IDB.keys db "settings") `shouldReturn` ["user-alice", "user-bob"]

  it "forgets a key on request, and keeps nothing once nothing is set" $ do
    fresh
    run (writeSettings db alice withKeys)
    run (writeSettings db alice (withKey OpenAI Nothing withKeys))
    s <- run (readSettings db alice)
    (settingsOf OpenAI s).key `shouldBe` Nothing
    (settingsOf Anthropic s).key `shouldBe` Just (ApiKey "sk-ant")
    run (writeSettings db alice (withKey Anthropic Nothing s))
    run (IDB.keys db "settings") `shouldReturn` []

  it "reads what it cannot read as the defaults" $ do
    fresh
    run (IDB.put db "settings" alice.text "not settings")
    run (readSettings db alice) `shouldReturn` defaultSettings

  it "keeps a provider's list of models, its address and whether it was reached" $ do
    fresh
    let at = UTCTime (fromGregorian 2026 10 27) 0
        s = withReached Anthropic False (withModels OpenAI [Listed (ModelName "llama4:8b") Nothing (Just 20)] at (withBaseUrl OpenAI "http://localhost:11434/v1" withKeys))
    run (writeSettings db alice s)
    run (readSettings db alice) `shouldReturn` s

  it "changes the settings as they are kept now, not as they were read" $ do
    run (IDB.deleteDatabase assistantDatabase.name)
    run (keepAssistantSettings alice withKeys) `shouldReturn` Right ()
    -- Kept since by someone else: a provider found unreachable.
    run (keepAssistantSettings alice (withReached OpenAI False withKeys)) `shouldReturn` Right ()
    run (updateAssistantSettings alice (withModel OpenAI "gpt-6-luna"))
      `shouldReturn` Right (withModel OpenAI "gpt-6-luna" (withReached OpenAI False withKeys))
    run (assistantSettings alice) `shouldReturn` Right (withModel OpenAI "gpt-6-luna" (withReached OpenAI False withKeys))

  it "reaches no provider in the in-memory document" $
    case readyFor Anthropic withKeys of
      Left why -> expectationFailure (toS why)
      Right r -> (either (\e -> Just e.kind) (const Nothing) <$> run (listModels r)) `shouldReturn` Just Unreachable

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
