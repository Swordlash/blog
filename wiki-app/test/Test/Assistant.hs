-- | The writing assistant's settings as a device keeps them
-- ("Wiki.App.Assistant", "Wiki.App.Assistant.Keys"), over the in-memory
-- document the native tests have. Its IndexedDB behaves as the browser's:
-- each user's record apart, under their id, in a database of the
-- assistant's own, deleted on request. It has no WebCrypto, so it cannot
-- seal the settings: a change fails there rather than store a key as
-- text. The settings sealed, per user, forgotten, synced and unlocked are
-- the browser tests' (Test.Browser.Assistant, Test.Browser.Vault).
module Test.Assistant (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Halogen.VDom.DOM.Monad (MemDOM, runMemDOM)
import Protolude
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant (..), assistantDatabase, readRecord, writeRecord)
import Wiki.App.Assistant.Keys (Keys (..), changeKeys, readKeys)
import Wiki.Core.Assistant
  ( AssistantError (..)
  , ErrorKind (..)
  , Provider (..)
  , defaultSettings
  , readyFor
  , withKey
  )
import Wiki.Core.Id (UserId (..))

spec :: Spec
spec = describe "Wiki.App.Assistant's settings" $ do
  let db = Database {name = "wiki-assistant-test", version = 1, stores = ["settings"]}
      fresh = run (IDB.deleteDatabase db.name)
      alice = UserId "user-alice"
      bob = UserId "user-bob"
      withKeys = withKey OpenAI (Just "test-key-open") (withKey Anthropic (Just "test-key-ant") defaultSettings)

  it "keeps each user's record apart, under their id, and deletes it on request" $ do
    fresh
    run (readRecord db alice) `shouldReturn` Nothing
    run (writeRecord db alice (Just "alice's"))
    run (writeRecord db bob (Just "bob's"))
    run (readRecord db alice) `shouldReturn` Just "alice's"
    sort <$> run (IDB.keys db "settings") `shouldReturn` ["user-alice", "user-bob"]
    run (writeRecord db alice Nothing)
    run (IDB.keys db "settings") `shouldReturn` ["user-bob"]

  it "reads the defaults where nothing is kept, in a database of the assistant's own" $ do
    run (IDB.deleteDatabase assistantDatabase.name)
    assistantDatabase.name `shouldBe` "wiki-assistant"
    fmap (\k -> (k.settings, k.locked, k.synced)) <$> run (readKeys alice) `shouldReturn` Right (defaultSettings, False, False)

  it "stores no key as text where it cannot seal it" $ do
    run (IDB.deleteDatabase assistantDatabase.name)
    run (changeKeys alice (const withKeys)) >>= (`shouldSatisfy` isLeft)
    run (IDB.keys assistantDatabase "settings") `shouldReturn` []

  it "leaves the settings stored as text before the vault for a browser to seal" $ do
    -- The in-memory document cannot seal them, so it refuses to read
    -- them, and leaves them as they were for a browser to seal.
    run (IDB.deleteDatabase assistantDatabase.name)
    let old = BSL.toStrict (encode withKeys)
    run (keepDeviceRecord alice (Just old)) `shouldReturn` Right ()
    run (readKeys alice) >>= (`shouldSatisfy` isLeft)
    run (deviceRecord alice) `shouldReturn` Right (Just old)

  it "reaches no provider in the in-memory document" $
    case readyFor Anthropic withKeys of
      Left why -> expectationFailure (toS why)
      Right r -> (either (\e -> Just e.kind) (const Nothing) <$> run (listModels r)) `shouldReturn` Just Unreachable
  where
    run :: MemDOM a -> IO a
    run = runMemDOM
