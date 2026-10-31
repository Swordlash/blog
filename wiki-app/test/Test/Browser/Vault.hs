{-# LANGUAGE TemplateHaskell #-}

-- | The assistant's keys across devices, in a browser (WP5.21 of
-- docs/PLAN.md, "Wiki.App.Assistant.Keys"): syncing turned on with a
-- passkey, the vault unlocked on a second device with one touch, a key
-- changed there picked up by the first without a touch, "ask for the
-- passkey each time", a passkey added and removed, a passkey without the
-- PRF extension refused, and syncing turned off (keeping the vault's
-- latest settings); only passkeys that can unlock offered; a vault made
-- elsewhere followed; another tab's key taken or let go of; no exportable
-- key left behind by a step that fails; and the settings stored as text
-- before the vault sealed.
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
import Test.Browser.Http (Asked (..), answerWith, asked, holdAt, release, serveDemo, serverStarts, serverStops, startServer)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.ServerSettings (defaultHomePage)
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
import Wiki.Core.Access (Access (..))
import Wiki.Core.Assistant (ApiKey (..), Provider (..), ProviderSettings (..), Settings, defaultSettings, settingsOf, withKey, withModel)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (Grants (..))
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
     , ("js_cancel_after", "wiki_test_passkeys_cancel_after", Unsafe, [t|Int -> IO ()|])
     , ("js_stash", "wiki_test_vault_server_stash", Unsafe, [t|IO ()|])
     , ("js_unstash", "wiki_test_vault_server_unstash", Unsafe, [t|IO ()|])
     , ("js_add_unwrapped", "wiki_test_vault_server_add_unwrapped", Unsafe, [t|IO ()|])
     , ("js_save_page_keys", "wiki_test_page_keys_save", Unsafe, [t|IO ()|])
     , ("js_restore_page_keys", "wiki_test_page_keys_restore", Unsafe, [t|IO ()|])
     , ("js_other_tab_drops", "wiki_test_other_tab_drops", Safe, [t|JSText -> IO ()|])
     , ("js_exportable", "wiki_test_exportable_keys_left", Safe, [t|IO Int|])
     , ("js_existing", "wiki_test_passkeys_existing", Unsafe, [t|IO JSText|])
     , ("js_offered", "wiki_test_passkeys_offered", Unsafe, [t|IO Bool|])
     , ("js_pick", "wiki_test_passkeys_pick", Unsafe, [t|IO ()|])
     , ("js_offers", "wiki_test_passkeys_offers", Unsafe, [t|IO Int|])
     , ("js_insecure", "wiki_test_passkeys_insecure", Unsafe, [t|IO ()|])
     ]
 )

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  vault m
  signing m

-- | Signing in with a passkey, and the account's passkeys (WP5.30 of
-- docs/PLAN.md): the button and the login field's offer sign in with the
-- stub's passkey alone; the second factor's form takes one in place of the
-- code; the account panel lists, adds and removes them; over plain HTTP
-- there is neither.
signing :: forall m -> (Specs m) => Spec
signing m = describe "signing in with a passkey" $ do
  it "signs in with the button, and with the passkey the login field offers" $ runPage $ do
    (ui, id') <- signedOut m
    me <- signedInAs "user-editor"
    answerWith "PUT" "api/v1/session/passkey" 200 me
    find ui ".sign-in-toggle" >>= click
    -- The login field offers the passkey as the form opens; the button
    -- ends that offer and opens the dialog.
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    find ui ".passkey-sign-in" >>= click
    find ui ".account .user-name" >>= (`shouldHaveText` "Edgar Editor")
    unsafeIOToPageM js_offered `shouldReturn` False
    sent <- filter (\r -> r.method == "PUT" && r.url == "api/v1/session/passkey") <$> asked
    map (\r -> (field ["id"] =<< decodeStrict (encodeUtf8 r.body), field ["userHandle"] =<< decodeStrict (encodeUtf8 r.body))) sent
      `shouldBe` [(Just (Aeson.String id'), Just (Aeson.String "dXNlci1lZGl0b3I"))]
    unmount ui
    unsafeIOToPageM js_uninstall
    serverStops
    -- Picked in the login field instead.
    (again, _) <- signedOut m
    answerWith "PUT" "api/v1/session/passkey" 200 me
    find again ".sign-in-toggle" >>= click
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    unsafeIOToPageM js_pick
    find again ".account .user-name" >>= (`shouldHaveText` "Edgar Editor")
    closedSignedIn again

  it "says why a passkey did not sign in, and offers it again" $ runPage $ do
    (ui, _) <- signedOut m
    answerWith "PUT" "api/v1/session/passkey" 400 (Aeson.object ["error" Aeson..= ("Invalid" :: Text), "message" Aeson..= ("This passkey is not one of this wiki's: it may have been removed. Sign in with your password." :: Text)])
    find ui ".sign-in-toggle" >>= click
    find ui ".passkey-sign-in" >>= click
    find ui ".sign-in-form .sign-in-error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "not one of this wiki's")
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    -- Closing the form ends the offer.
    find ui ".sign-in-toggle" >>= click
    eventually $ unsafeIOToPageM js_offered `shouldReturn` False
    closedSignedIn ui

  it "starts no offer in the login field whose challenge arrives after the form closed" $ runPage $ do
    (ui, _) <- signedOut m
    holdAt "POST" "api/v1/session/passkey"
    find ui ".sign-in-toggle" >>= click
    eventually $ length . filter (\r -> r.url == "api/v1/session/passkey") <$> asked `shouldReturn` 1
    find ui ".sign-in-toggle" >>= click
    release
    -- The challenge arrived after the form it was for closed. The form
    -- opened again starts its own offer, and only that one.
    find ui ".sign-in-toggle" >>= click
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    unsafeIOToPageM js_offers `shouldReturn` 1
    closedSignedIn ui

  it "opens no passkey dialog whose challenge arrives after the form closed" $ runPage $ do
    (ui, _) <- signedOut m
    find ui ".sign-in-toggle" >>= click
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    holdAt "POST" "api/v1/session/passkey"
    find ui ".passkey-sign-in" >>= click
    eventually $ length . filter (\r -> r.url == "api/v1/session/passkey") <$> asked `shouldReturn` 2
    find ui ".sign-in-toggle" >>= click
    release
    -- The form opened again offers in the field; no dialog was opened, and
    -- nobody signed in.
    find ui ".sign-in-toggle" >>= click
    eventually $ unsafeIOToPageM js_offered `shouldReturn` True
    touches `shouldReturn` 0
    length . filter (\r -> r.method == "PUT") <$> asked `shouldReturn` 0
    closedSignedIn ui

  it "completes a password's sign-in with a passkey in place of the code" $ runPage $ do
    (ui, id') <- signedOut m
    me <- signedInAs "user-editor"
    answerWith "POST" "api/v1/session" 401 (Aeson.object ["error" Aeson..= ("SecondFactorRequired" :: Text)])
    answerWith "POST" "api/v1/session/second-factor/passkey" 200 (Aeson.object ["challenge" Aeson..= ("Y2hhbGxlbmdl" :: Text), "rpId" Aeson..= ("localhost" :: Text), "allow" Aeson..= [id']])
    answerWith "PUT" "api/v1/session/second-factor/passkey" 401 (Aeson.object ["error" Aeson..= ("Unauthenticated" :: Text)])
    find ui ".sign-in-toggle" >>= click
    find ui ".sign-in-form input[name=login]" >>= (`typeText` "editor")
    find ui ".sign-in-form input[name=password]" >>= (`typeText` "editor's password")
    find ui ".sign-in-form button[type=submit]" >>= click
    find ui ".sign-in-code-form .passkey-code" >>= click
    find ui ".sign-in-code-form .sign-in-error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "That passkey was not accepted")
    answerWith "PUT" "api/v1/session/second-factor/passkey" 200 me
    find ui ".sign-in-code-form .passkey-code" >>= click
    find ui ".account .user-name" >>= (`shouldHaveText` "Edgar Editor")
    closedSignedIn ui

  it "lists the account's passkeys, adds one with a name, and removes one" $ runPage $ do
    serverStarts
    serveDemo
    me <- signedInAs "user-editor"
    answerWith "GET" "api/v1/session" 200 me
    answerAccount
    unsafeIOToPageM js_vault_server
    unsafeIOToPageM (js_install True True)
    _ <- unsafeIOToPageM js_existing
    ui <- startServer m Home
    find ui ".account-toggle" >>= click
    eventually $ length <$> findAll ui ".passkey-item" `shouldReturn` 1
    find ui ".passkey-name" >>= (`shouldHaveText` "My laptop")
    find ui ".passkey-add input[name=passkey-name]" >>= (`typeText` "My phone")
    find ui ".passkey-add input[name=passkey-password]" >>= (`typeText` "editor's password")
    find ui ".passkey-add button[type=submit]" >>= click
    eventually $ length <$> findAll ui ".passkey-item" `shouldReturn` 2
    map (T.strip) <$> (findAll ui ".passkey-name" >>= traverse textContent) `shouldReturn` ["My laptop", "My phone"]
    -- Made without the PRF extension: a passkey to sign in with.
    sent <- filter (\r -> r.method == "PUT" && r.url == "api/v1/account/passkeys/registration") <$> asked
    map (\r -> field ["name"] =<< decodeStrict (encodeUtf8 r.body)) sent `shouldBe` [Just (Aeson.String "My phone")]
    -- Making it asked for the password, since it signs the user in.
    begun <- filter (\r -> r.method == "POST" && r.url == "api/v1/account/passkeys/registration") <$> asked
    map (\r -> field ["password"] =<< decodeStrict (encodeUtf8 r.body)) begun `shouldBe` [Just (Aeson.String "editor's password")]
    findAll ui ".passkey-remove" >>= \case
      remove : _ -> click remove
      [] -> panic "no Remove"
    eventually $ length <$> findAll ui ".passkey-item" `shouldReturn` 1
    find ui ".passkey-name" >>= (`shouldHaveText` "My phone")
    closedSignedIn ui

  it "offers no passkey on a page served over plain HTTP, and says why" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "GET" "api/v1/session" 200 nobody
    unsafeIOToPageM js_vault_server
    unsafeIOToPageM (js_install True True)
    unsafeIOToPageM js_insecure
    ui <- startServer m Home
    find ui ".sign-in-toggle" >>= click
    _ <- find ui ".sign-in-form input[name=login]"
    length <$> findAll ui ".passkey-sign-in" `shouldReturn` 0
    unsafeIOToPageM js_offered `shouldReturn` False
    unmount ui
    me <- signedInAs "user-editor"
    answerWith "GET" "api/v1/session" 200 me
    answerAccount
    signedIn <- startServer m Home
    find signedIn ".account-toggle" >>= click
    find signedIn ".passkeys-unavailable" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "served over HTTPS")
    closedSignedIn signedIn
  where
    -- The wiki over the test's server with nobody signed in, the vault's
    -- server keeping one passkey of the editor's, which the stub has too:
    -- the page, and the passkey's id.
    signedOut :: forall m -> (Specs m) => PageM s (Mounted s Shell.Query Void m, Text)
    signedOut m' = do
      serverStarts
      serveDemo
      answerWith "GET" "api/v1/session" 200 nobody
      answerWith "POST" "api/v1/session/passkey" 200 (Aeson.object ["challenge" Aeson..= ("Y2hhbGxlbmdl" :: Text), "rpId" Aeson..= ("localhost" :: Text), "allow" Aeson..= ([] :: [Text])])
      unsafeIOToPageM js_vault_server
      unsafeIOToPageM (js_install True True)
      id' <- fromJSText <$> unsafeIOToPageM js_existing
      ui <- startServer m' Home
      pure (ui, id')
    touches :: PageM s Int
    touches = unsafeIOToPageM js_touches
    -- What the account panel fetches besides the passkeys.
    answerAccount = do
      answerWith "GET" "api/v1/account/identities" 200 (Aeson.object ["password" Aeson..= True, "identities" Aeson..= ([] :: [Text])])
      answerWith "GET" "api/v1/account/sessions" 200 ([] :: [Text])
      answerWith "GET" "api/v1/account/second-factor" 200 (Aeson.object ["enabled" Aeson..= False, "recoveryCodesLeft" Aeson..= (0 :: Int), "asksPassword" Aeson..= True])
      answerWith "GET" "api/v1/account/email" 200 (Aeson.object ["email" Aeson..= Aeson.Null, "verified" Aeson..= False, "mailing" Aeson..= False, "mailError" Aeson..= Aeson.Null, "asksPassword" Aeson..= True])
    closedSignedIn :: Mounted s Shell.Query Void m -> PageM s ()
    closedSignedIn ui = do
      unmount ui
      unsafeIOToPageM js_uninstall
      serverStops

vault :: forall m -> (Specs m) => Spec
vault m = do
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
    replaceKey other "test-key-anthropic-changed"
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

  it "refuses a passkey without the PRF extension for the keys, says why, and keeps it to sign in with" $ runPage $ do
    ui <- opened m False False
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-problem" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "It was kept to sign in with")
    kept <- vaultState
    (field ["vault"] kept, length . fromMaybe [] . (>>= arrayOf) $ field ["passkeys"] kept) `shouldBe` (Just Aeson.Null, 1)
    find ui ".assistant-sync-off-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "off")
    closed ui

  it "turns syncing on with a passkey the user has already, making none" $ runPage $ do
    ui <- opened m True True
    existing <- fromJSText <$> unsafeIOToPageM js_existing
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")
    -- One touch: the passkey used, none made.
    touches `shouldReturn` 1
    kept <- vaultState
    (field ["passkeys", "0", "id"] kept, length . fromMaybe [] . (>>= arrayOf) $ field ["passkeys"] kept, isJust (field ["passkeys", "0", "wrapped", "key"] kept))
      `shouldBe` (Just (Aeson.String existing), 1, True)
    closed ui

  it "turns syncing off with no passkey, and keeps the keys in this browser" $ runPage $ do
    ui <- opened m True True
    turnOn ui
    before <- touches
    find ui ".assistant-sync-off" >>= click
    eventually $ find ui ".assistant-sync-off-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "off")
    touches `shouldReturn` before
    -- The passkey stays, to sign in with, without its copy of the key.
    kept <- vaultState
    (field ["vault"] kept, length . fromMaybe [] . (>>= arrayOf) $ field ["passkeys"] kept, field ["passkeys", "0", "wrapped"] kept) `shouldBe` (Just Aeson.Null, 1, Just Aeson.Null)
    (\s -> (settingsOf Anthropic s).key) <$> settingsHere m `shouldReturn` Just (ApiKey secretKey)
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    closed ui

  it "keeps the vault's latest settings when syncing is turned off on a device that did not change them" $ runPage $ do
    first' <- opened m True True
    turnOn first'
    unmount first'
    leave "first"
    other <- reopened m
    eventually (find other ".assistant-unlock") >>= click
    _ <- eventually $ find other ".assistant-sync-on"
    replaceKey other "test-key-anthropic-changed"
    unmount other
    leave "second"
    back "first"
    ui <- reopened m
    _ <- eventually $ find ui ".assistant-sync-on"
    find ui ".assistant-sync-off" >>= click
    _ <- eventually $ find ui ".assistant-sync-off-state"
    (\s -> (settingsOf Anthropic s).key) <$> settingsHere m `shouldReturn` Just (ApiKey "test-key-anthropic-changed")
    -- And so after a reload, with the key this device keeps.
    unmount ui
    unsafeIOToPageM js_reload
    (\s -> (settingsOf Anthropic s).key) <$> settingsHere m `shouldReturn` Just (ApiKey "test-key-anthropic-changed")
    unsafeIOToPageM js_uninstall
    serverStops

  it "offers for unlocking only the passkeys that hold a copy of the vault's key" $ runPage $ do
    first' <- opened m True True
    turnOn first'
    unmount first'
    leave "first"
    unsafeIOToPageM js_add_unwrapped
    ui <- reopened m
    before <- touches
    eventually (find ui ".assistant-unlock") >>= click
    eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")
    touches `shouldReturn` (before + 1)
    closed ui

  it "follows the vault another device made meanwhile, when asked to turn syncing on" $ runPage $ do
    first' <- opened m True True
    turnOn first'
    unmount first'
    leave "first"
    -- This device opens the page before the other device's vault exists.
    unsafeIOToPageM js_stash
    ui <- reopened m
    _ <- eventually $ find ui ".assistant-sync-off-state"
    unsafeIOToPageM js_unstash
    before <- touches
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-problem" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "another device of yours syncs them")
    _ <- eventually $ find ui ".assistant-unlock"
    find ui ".assistant-sync-locked" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "locked in this browser")
    touches `shouldReturn` before
    closed ui

  it "takes the key another tab stored, and lets go of the one another tab let go of" $ runPage $ do
    ui <- opened m True True
    -- This tab, as another one, holds the key from before syncing.
    unsafeIOToPageM js_save_page_keys
    turnOn ui
    unsafeIOToPageM js_restore_page_keys
    keys <- unsafeIOToPageM (runTest (readKeys (UserId "user-editor") :: m (Either Text Keys)))
    ((\k -> k.locked) <$> keys, (\k -> (settingsOf Anthropic k.settings).key) <$> keys) `shouldBe` (Right False, Right (Just (ApiKey secretKey)))
    closed ui
    -- Another tab lets go of the key: this one seals what is typed next
    -- under a key it stores, not under the one let go of.
    again <- opened m True True
    unsafeIOToPageM (evaluate =<< js_other_tab_drops (toJSText "user-editor"))
    openai <- find again ".assistant-provider-settings[data-provider='openai']"
    findIn openai ".assistant-key" >>= (`typeText` "test-key-openai-typed-here")
    findIn openai ".assistant-key-form button" >>= click
    eventually $ findIn openai ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")
    unsafeIOToPageM (evaluate =<< js_stores_key (toJSText "user-editor")) `shouldReturn` True
    closed again

  it "leaves no key that can be exported in the page when a step fails" $ runPage $ do
    ui <- opened m True True
    turnOn ui
    exportable `shouldReturn` 0
    -- Adding a passkey: the vault's key is unwrapped, and the new
    -- passkey's dialog closed.
    unsafeIOToPageM (js_cancel_after 1)
    find ui ".assistant-add-passkey" >>= click
    eventually $ find ui ".assistant-sync-problem" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "dialog was closed")
    exportable `shouldReturn` 0
    -- Turning on: a new vault key made, and the passkey's dialog closed.
    find ui ".assistant-sync-off" >>= click
    _ <- eventually $ find ui ".assistant-sync-off-state"
    unsafeIOToPageM (js_cancel_after 0)
    find ui ".assistant-sync-on-button" >>= click
    eventually $ find ui ".assistant-sync-problem" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "dialog was closed")
    exportable `shouldReturn` 0
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
    exportable :: PageM s Int
    exportable = unsafeIOToPageM (evaluate =<< js_exportable)
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

-- | Forget the key kept for Anthropic, and keep another.
replaceKey :: Mounted s q o n -> Text -> PageM s ()
replaceKey ui key = do
  anthropic <- find ui ".assistant-provider-settings[data-provider='anthropic']"
  findIn anthropic ".assistant-forget" >>= click
  eventually $ findIn anthropic ".assistant-key" >>= (`typeText` key)
  findIn anthropic ".assistant-key-form button" >>= click
  eventually $ findIn anthropic ".assistant-key-kept" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "A key is kept")

-- | Turn syncing on, and wait until it is.
turnOn :: Mounted s q o n -> PageM s ()
turnOn ui = do
  find ui ".assistant-sync-on-button" >>= click
  eventually $ find ui ".assistant-sync-on" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Sync across devices: on")

-- | The editor's settings as this device keeps them now.
settingsHere :: forall m -> (Specs m) => PageM s Settings
settingsHere m = unsafeIOToPageM (either (const defaultSettings) (\k -> k.settings) <$> runTest (readKeys (UserId "user-editor") :: m (Either Text Keys)))

-- | Nobody signed in, in an open wiki.
nobody :: SessionInfo
nobody = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access = Open}, standing = NotSignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage}

-- | One of the demo's users, signed in.
signedInAs :: Text -> PageM s SessionInfo
signedInAs uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage}

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
