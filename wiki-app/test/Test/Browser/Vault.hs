{-# LANGUAGE TemplateHaskell #-}

-- | The assistant's keys across devices, in a browser (WP5.21 of
-- docs/PLAN.md, "Wiki.App.Assistant.Keys"): syncing turned on with a
-- passkey, the vault unlocked on a second device with one touch, a key
-- changed there picked up by the first without a touch, "ask for the
-- passkey each time", a passkey added and removed, a passkey without the
-- PRF extension refused, and syncing turned off; and the settings stored
-- as text before the vault sealed.
--
-- Over the backend over HTTP, with the test's server in fetch's place
-- ("Test.Browser.Http") and the vault's server played beside it, and
-- passkeys made by a stub in the place of @navigator.credentials@
-- (@jsbits\/test-passkeys.js@): the harness has no virtual authenticator.
-- The stub's PRF output is the same on every device, as a synced
-- passkey's is. The real dialog of a browser is checked by hand.
module Test.Browser.Vault (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value, decodeStrict, encode)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, serverStops, startServer)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant, assistantDatabase)
import Wiki.App.Assistant.Keys (Keys (..), readKeys)
import Wiki.App.Backend (Session (..), session)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Assistant (ApiKey (..), Provider (..), ProviderSettings (..), Settings, defaultSettings, settingsOf, withKey, withModel)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Standing (..))

$( browserJS
     ["jsbits/test-passkeys.js"]
     [ ("js_install", "wiki_test_passkeys_install", Unsafe, [t|Bool -> Bool -> IO ()|])
     , ("js_uninstall", "wiki_test_passkeys_uninstall", Unsafe, [t|IO ()|])
     , ("js_touches", "wiki_test_passkeys_touches", Unsafe, [t|IO Int|])
     , ("js_vault_server", "wiki_test_vault_server_start", Unsafe, [t|IO ()|])
     , ("js_vault_state", "wiki_test_vault_server_state", Unsafe, [t|IO JSText|])
     , ("js_leave", "wiki_test_device_leave", Safe, [t|JSText -> IO ()|])
     , ("js_new_device", "wiki_test_device_new", Safe, [t|IO ()|])
     , ("js_return", "wiki_test_device_return", Safe, [t|JSText -> IO ()|])
     , ("js_reload", "wiki_test_device_reload", Unsafe, [t|IO ()|])
     , ("js_stores_key", "wiki_test_device_stores_key", Safe, [t|JSText -> IO Bool|])
     , ("js_record", "wiki_test_device_record", Safe, [t|JSText -> IO JSText|])
     , ("js_scripted", "wiki_test_passkeys_scripted", Unsafe, [t|IO ()|])
     ]
 )

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  it "turns syncing on with a passkey, and sends the server the keys sealed only" $ runPage $ do
    ui <- opened m True True
    anthropic <- find ui ".assistant-provider-settings[data-provider='anthropic']"
    find ui ".assistant-sync-off-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: off")
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")
    -- One touch: the passkey gave its PRF output as it was made.
    touches `shouldReturn` 1
    length <$> findAll ui ".assistant-passkey" `shouldReturn` 1
    kept <- vaultState
    field ["revision"] kept `shouldBe` Just (Aeson.Number 1)
    (isJust . field ["passkeys", "0", "wrapped", "key"]) kept `shouldBe` True
    -- The key: kept here, sealed; sent to the server sealed only.
    findIn anthropic ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")
    sentKey `shouldReturn` False
    record <- unsafeIOToPageM (evaluate . fromJSText =<< js_record (toJSText "user-editor"))
    record `shouldSatisfy` (\r -> not (T.null r) && not (secretKey `T.isInfixOf` r))
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    closed ui

  it "unlocks on a second device with one touch, keeping a key typed there while it was locked" $ runPage $ do
    first' <- opened m True True
    turnOn first'
    unmount first'
    leave "first"
    ui <- reopened m
    eventually $ find ui ".assistant-sync-locked" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "locked in this browser")
    find ui ".assistant-type-here" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "or type a key here")
    -- A key typed here meanwhile stays here.
    openai <- find ui ".assistant-provider-settings[data-provider='openai']"
    findIn openai ".assistant-key" >>= (`typeText` "test-key-openai-typed-here")
    findIn openai ".assistant-key-form button" >>= click
    eventually $ findIn openai ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")
    field ["revision"] <$> vaultState `shouldReturn` Just (Aeson.Number 1)
    before <- touches
    find ui ".assistant-unlock" >>= click
    eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")
    touches `shouldReturn` (before + 1)
    -- The vault's key for Anthropic, and the one typed here for OpenAI,
    -- stored on the server with it.
    keys <- settingsHere m
    ((settingsOf Anthropic keys).key, (settingsOf OpenAI keys).key) `shouldBe` (Just (ApiKey secretKey), Just (ApiKey "test-key-openai-typed-here"))
    field ["revision"] <$> vaultState `shouldReturn` Just (Aeson.Number 2)
    sentKey `shouldReturn` False
    closed ui

  it "takes a key changed on another device when the wiki opens, without a touch" $ runPage $ do
    first' <- opened m True True
    turnOn first'
    unmount first'
    leave "first"
    other <- reopened m
    eventually (find other ".assistant-unlock") >>= click
    _ <- eventually $ find other ".assistant-sync-on"
    anthropic <- find other ".assistant-provider-settings[data-provider='anthropic']"
    findIn anthropic ".assistant-forget" >>= click
    eventually $ findIn anthropic ".assistant-key" >>= (`typeText` "test-key-anthropic-changed")
    findIn anthropic ".assistant-key-form button" >>= click
    eventually $ findIn anthropic ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")
    unmount other
    leave "second"
    back "first"
    before <- touches
    ui <- reopened m
    _ <- eventually $ find ui ".assistant-sync-on"
    touches `shouldReturn` before
    (\s -> (settingsOf Anthropic s).key) <$> settingsHere m `shouldReturn` Just (ApiKey "test-key-anthropic-changed")
    sentKey `shouldReturn` False
    closed ui

  it "asks for the passkey each time the wiki opens, when told to, and keeps no key then" $ runPage $ do
    ui <- opened m True True
    turnOn ui
    find ui ".assistant-ask-each-time" >>= click
    eventually $ unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` False
    unmount ui
    -- The wiki opened again: the page holds no key, and none is stored.
    unsafeIOToPageM js_reload
    again <- reopened m
    _ <- eventually $ find again ".assistant-sync-locked"
    before <- touches
    find again ".assistant-unlock" >>= click
    _ <- eventually $ find again ".assistant-sync-on"
    touches `shouldReturn` (before + 1)
    find again ".assistant-ask-each-time" >>= (`getProperty` "checked") >>= (`shouldBe` "true")
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` False
    -- Told not to any more: the key is stored again.
    find again ".assistant-ask-each-time" >>= click
    eventually $ unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    closed again

  it "adds a passkey on an unlocked device, and removes one, with its copy of the key" $ runPage $ do
    ui <- opened m True True
    turnOn ui
    before <- touches
    find ui ".assistant-add-passkey" >>= click
    eventually $ length <$> findAll ui ".assistant-passkey" `shouldReturn` 2
    -- A passkey the vault knows gives the vault's key, then the new one is made.
    touches `shouldReturn` (before + 2)
    kept <- vaultState
    (isJust (field ["passkeys", "1", "wrapped", "key"] kept), field ["revision"] kept) `shouldBe` (True, Just (Aeson.Number 2))
    findAll ui ".assistant-remove-passkey" >>= \case
      remove : _ -> click remove
      [] -> panic "no Remove"
    eventually $ length <$> findAll ui ".assistant-passkey" `shouldReturn` 1
    (length . fromMaybe [] . (>>= arrayOf) . field ["passkeys"]) <$> vaultState `shouldReturn` 1
    closed ui

  it "makes a passkey whose PRF output comes only when it is used, with one more touch" $ runPage $ do
    ui <- opened m True False
    turnOn ui
    touches `shouldReturn` 2
    closed ui

  it "refuses a passkey without the PRF extension, says why, and removes it" $ runPage $ do
    ui <- opened m False False
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-problem" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "This passkey cannot sync the keys")
    kept <- vaultState
    (field ["vault"] kept, length . fromMaybe [] . (>>= arrayOf) $ field ["passkeys"] kept) `shouldBe` (Just Aeson.Null, 0)
    find ui ".assistant-sync-off-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "off")
    closed ui

  it "turns syncing off with no passkey, and keeps the keys in this browser" $ runPage $ do
    ui <- opened m True True
    turnOn ui
    before <- touches
    find ui ".assistant-sync-off" >>= click
    eventually $ find ui ".assistant-sync-off-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "off")
    touches `shouldReturn` before
    kept <- vaultState
    (field ["vault"] kept, length . fromMaybe [] . (>>= arrayOf) $ field ["passkeys"] kept) `shouldBe` (Just Aeson.Null, 0)
    (\s -> (settingsOf Anthropic s).key) <$> settingsHere m `shouldReturn` Just (ApiKey secretKey)
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    closed ui

  it "seals the settings stored as text before the vault, and keeps no key as text" $ runPage $ do
    unsafeIOToPageM (evaluate =<< js_new_device)
    let old = withModel Anthropic "claude-test" (withKey Anthropic (Just secretKey) defaultSettings)
    unsafeIOToPageM (runTest (IDB.put assistantDatabase "settings" "user-editor" (BSL.toStrict (encode old)) :: m ()))
    settingsHere m `shouldReturn` old
    record <- unsafeIOToPageM (evaluate . fromJSText =<< js_record (toJSText "user-editor"))
    record `shouldSatisfy` (\r -> "\"device\"" `T.isInfixOf` r && not (secretKey `T.isInfixOf` r))
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    unsafeIOToPageM (evaluate =<< js_new_device)
  where
    secretKey :: Text
    secretKey = "test-key-anthropic-one"
    touches :: PageM s Int
    touches = unsafeIOToPageM js_touches
    vaultState :: PageM s Value
    vaultState = unsafeIOToPageM (fromMaybe Aeson.Null . decodeStrict . encodeUtf8 . fromJSText <$> js_vault_state)
    leave, back :: Text -> PageM s ()
    leave name = unsafeIOToPageM (evaluate =<< js_leave (toJSText name))
    back name = unsafeIOToPageM (evaluate =<< js_return (toJSText name))
    -- Whether anything sent to the server holds a key in the clear.
    sentKey :: PageM s Bool
    sentKey = any (\r -> any (`T.isInfixOf` r.body) [secretKey, "test-key-openai", "test-key-anthropic-changed"]) <$> asked
    closed :: Mounted s Shell.Query Void m -> PageM s ()
    closed ui = do
      unmount ui
      unsafeIOToPageM js_uninstall
      serverStops

-- | The assistant's settings page over the test's server, signed in as the
-- demo's editor, on a new device, with the vault's server empty and
-- passkeys with the PRF extension or without, whose output comes as they
-- are made or only when used; and a key kept for Anthropic.
opened :: forall m -> (Specs m) => Bool -> Bool -> PageM s (Mounted s Shell.Query Void m)
opened m prf atCreate = do
  serverStarts
  serveDemo
  unsafeIOToPageM js_scripted
  me <- signedInAs "user-editor"
  answerWith "GET" "api/v1/session" 200 me
  unsafeIOToPageM js_vault_server
  unsafeIOToPageM (js_install prf atCreate)
  unsafeIOToPageM (evaluate =<< js_new_device)
  ui <- startServer m AssistantSettings
  anthropic <- eventually (find ui ".assistant-provider-settings[data-provider='anthropic']")
  findIn anthropic ".assistant-key" >>= (`typeText` "test-key-anthropic-one")
  findIn anthropic ".assistant-key-form button" >>= click
  eventually $ findIn anthropic ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")
  pure ui

-- | The settings page again, as when the wiki opens on this device.
reopened :: forall m -> (Specs m) => PageM s (Mounted s Shell.Query Void m)
reopened m = startServer m AssistantSettings

-- | Turn syncing on, and wait until it is.
turnOn :: Mounted s q o n -> PageM s ()
turnOn ui = do
  find ui ".assistant-sync-on-button" >>= click
  eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")

-- | The editor's settings as this device keeps them now.
settingsHere :: forall m -> (Specs m) => PageM s Settings
settingsHere m = unsafeIOToPageM (either (const defaultSettings) (\k -> k.settings) <$> runTest (readKeys (UserId "user-editor") :: m (Either Text Keys)))

-- | One of the demo's users, signed in.
signedInAs :: Text -> PageM s SessionInfo
signedInAs uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = []}

-- | A field of JSON, by its path of keys (an array's items by number).
field :: [Text] -> Value -> Maybe Value
field path value = foldM step value path
  where
    step (Aeson.Object o) k = KeyMap.lookup (Key.fromText k) o
    step (Aeson.Array a) k = readMaybe k >>= \i -> toList a `atMay` i
    step _ _ = Nothing

arrayOf :: Value -> Maybe [Value]
arrayOf = \case
  Aeson.Array a -> Just (toList a)
  _ -> Nothing
