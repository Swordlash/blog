{-# LANGUAGE TemplateHaskell #-}

-- | 'MonadAssistant': what the writing assistant (WP4.19 of docs/PLAN.md)
-- needs from the monad a component runs in. That is the user's settings,
-- stored in this browser, and chats with a provider.
--
-- The settings (a key per provider, the chosen provider and each
-- provider's model: "Wiki.Core.Assistant") are stored in this browser's
-- IndexedDB, in a separate database ('assistantDatabase'), under the
-- user's id, sealed in a vault (WP5.21, "Wiki.Core.Assistant.Vault"):
-- this class stores the device's record ('deviceRecord'), and seals and
-- opens it with a key the browser keeps and never exports ('sealWith',
-- 'deviceKey'). "Wiki.App.Assistant.Keys" reads and changes the settings
-- through it. So another user of the same browser has their own settings
-- and cannot see anyone else's key, and no key is stored as text. The
-- settings never reach the wiki's server in the clear and are never
-- logged. They are not deleted when the user signs out of the wiki: they
-- belong to this browser and this user, and the user finds them again on
-- signing in, as with a password manager. "Forget" is the way to delete a
-- key.
--
-- The vault can follow the user to their other devices, unlocked there by
-- a passkey: the class makes and uses passkeys ('createPasskey',
-- 'usePasskey') and wraps the vault's key with what a passkey's PRF
-- extension gives ('wrapWith', 'unwrapWith'), all in the browser
-- (@jsbits\/vault.js@). A key is held by the page and known here by a
-- number ('KeyRef'); its bytes never reach Haskell.
--
-- A chat is one conversation with a provider ('openTalk'), which the
-- browser-side code keeps for the editing session. Each message sent
-- ('sayTo') runs one turn of the model, whose events are reported as they
-- happen ('Heard'): its text as it streams, the summary of its thinking
-- as it streams, the start of each tool call, each whole tool call, which
-- the turn waits on until it is answered ('answerCall'), and how the turn
-- ended. A turn can be stopped ('stopTalk'). The providers are reached
-- through Anthropic's and OpenAI's SDKs, called from the browser with the
-- user's key (@web/src/assistant.js@, fetched the first time the
-- assistant is used), or through the scripted provider a test installs
-- ('scriptedInstalled'); see @jsbits/assistant.js@.
--
-- The provider's model list is fetched with the key ('listModels'), for
-- the model pickers ('Wiki.Core.Assistant.groupModels').
--
-- In a browser ('BrowserDOM') all of this is real. In the in-memory
-- document that the prerender and the native tests use ('MemDOM'), the
-- settings are stored in its in-memory IndexedDB, as the browser would
-- store them, and there is no provider: every turn of a chat fails with a
-- message saying so.
module Wiki.App.Assistant
  ( -- * The class
    MonadAssistant (..)
  , Talk
  , Opening (..)
  , Heard (..)
  , sendsMessage
  , closesPanel
  , clockTime

    -- * The vault in the browser
  , KeyRef
  , Made (..)
  , OfferTicket
  , Used (..)
  , PasskeyRefusal (..)

    -- * Settings
  , assistantDatabase
  , readRecord
  , writeRecord
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Trans.Class (MonadTrans)
import Data.Aeson (FromJSON (..), Object, ToJSON (..), Value (Object), eitherDecodeStrict, encode, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Pair, Parser, parseEither)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Type.Equality (type (~))
import Halogen.JSBits (Callback, JSText, Safety (..), browserJS, freeCallback, fromJSText, inBrowser, jsValText, mkSyncCallback, toJSText)
import Halogen.VDom.DOM.Monad (BrowserDOM)
import Halogen.VDom.DOM.Monad.Mem (MemDOM)
import Protolude
import Web.Event.Event (Event (..))
import Web.Storage.IndexedDB (Database (..), IndexedDBError (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.ContentPolicy (allowsConnect, extraHosts, originOf)
import Wiki.Api.Vault (AssertionOptions, AssertionResponse, RegistrationOptions, RegistrationResponse)
import Wiki.Core.Assistant (AssistantError (..), ErrorKind (..), Listed, Ready (..), providerKey)
import Wiki.Core.Assistant.Vault (CredentialId (..), Sealed (..), WrappedKey (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))

-- The chat's bindings return immediately: a turn reports its events
-- through the callback. "Test the key" and the model list wait for the
-- provider's response, so they are safe imports, whose result on wasm is
-- a thunk until it is forced. The vault's (jsbits/vault.js) answer with
-- WebCrypto's and WebAuthn's promises, so most are safe imports too; their
-- results are JSON, or a key's handle (0 for none). One splice holds both
-- files: a module has room for one.
$( browserJS
     ["jsbits/assistant.js", "jsbits/vault.js"]
     [ ("js_open", "wiki_assistant_open", Unsafe, [t|JSText -> Callback -> IO Int|])
     , ("js_send", "wiki_assistant_send", Unsafe, [t|Int -> JSText -> JSText -> IO ()|])
     , ("js_answer", "wiki_assistant_answer", Unsafe, [t|Int -> Int -> JSText -> Bool -> IO ()|])
     , ("js_stop", "wiki_assistant_stop", Unsafe, [t|Int -> IO ()|])
     , ("js_close", "wiki_assistant_close", Unsafe, [t|Int -> IO ()|])
     , ("js_check", "wiki_assistant_check", Safe, [t|JSText -> IO JSText|])
     , ("js_models", "wiki_assistant_models", Safe, [t|JSText -> IO JSText|])
     , ("js_scripted", "wiki_assistant_scripted", Unsafe, [t|IO Bool|])
     , ("js_secure", "wiki_assistant_secure", Unsafe, [t|IO Bool|])
     , ("js_prepare", "wiki_assistant_prepare", Unsafe, [t|IO ()|])
     , ("js_send_key", "wiki_assistant_send_key", Unsafe, [t|Event -> Bool|])
     , ("js_close_key", "wiki_assistant_close_key", Unsafe, [t|Event -> Bool|])
     , ("js_clock", "wiki_assistant_clock", Unsafe, [t|Double -> IO JSText|])
     , ("js_page_policy", "wiki_assistant_page_policy", Unsafe, [t|IO JSText|])
     , ("js_page_origin", "wiki_assistant_page_origin", Unsafe, [t|IO JSText|])
     , ("js_new_key", "wiki_vault_new_key", Safe, [t|Bool -> IO Int|])
     , ("js_seal", "wiki_vault_seal", Safe, [t|Int -> JSText -> JSText -> IO JSText|])
     , ("js_open_sealed", "wiki_vault_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO JSText|])
     , ("js_forget_key", "wiki_vault_forget_key", Unsafe, [t|Int -> IO ()|])
     , ("js_salt", "wiki_vault_salt", Unsafe, [t|IO JSText|])
     , ("js_keep_key", "wiki_vault_keep_key", Safe, [t|JSText -> Int -> Bool -> IO JSText|])
     , ("js_device_key", "wiki_vault_device_key", Safe, [t|JSText -> IO Int|])
     , ("js_drop_key", "wiki_vault_drop_key", Safe, [t|JSText -> IO ()|])
     , ("js_passkeys_here", "wiki_vault_passkeys_here", Unsafe, [t|IO Bool|])
     , ("js_sealing_here", "wiki_vault_sealing_here", Unsafe, [t|IO Bool|])
     , ("js_create", "wiki_vault_create", Safe, [t|JSText -> JSText -> JSText -> IO JSText|])
     , ("js_get", "wiki_vault_get", Safe, [t|JSText -> JSText -> JSText -> IO JSText|])
     , ("js_wrap", "wiki_vault_wrap", Safe, [t|Int -> Int -> JSText -> IO JSText|])
     , ("js_unwrap", "wiki_vault_unwrap", Safe, [t|Int -> JSText -> JSText -> JSText -> Bool -> IO JSText|])
     , ("js_discard", "wiki_vault_discard", Safe, [t|JSText -> JSText -> IO ()|])
     , ("js_conditional_here", "wiki_passkey_conditional_here", Safe, [t|IO Bool|])
     , ("js_passkey_sign_in", "wiki_passkey_sign_in", Safe, [t|JSText -> Bool -> Int -> IO JSText|])
     , ("js_passkey_offer_ticket", "wiki_passkey_offer_ticket", Unsafe, [t|IO Int|])
     , ("js_passkey_abort", "wiki_passkey_abort", Unsafe, [t|IO ()|])
     ]
 )

-- | 'KeyRef': a key the page holds (a vault key, or the key that wraps it
-- for a passkey), by its number in @jsbits\/vault.js@. Its bytes stay in
-- the browser.
newtype KeyRef = KeyRef Int
  deriving stock (Eq, Show)

-- | 'Made': a passkey just made: the browser's answer for the server to
-- check, whether the passkey has the PRF extension, and the key that
-- wraps the vault key for it, when its authenticator gave the PRF output
-- at once (otherwise a use of the passkey gives it).
data Made = Made
  { response :: RegistrationResponse
  , prf :: Bool
  , wrapping :: Maybe KeyRef
  }
  deriving stock (Show)

-- | 'Used': a passkey just used: the browser's answer for the server to
-- check, and the key that wraps the vault key for it, if the passkey
-- gave its PRF output.
data Used = Used
  { response :: AssertionResponse
  , wrapping :: Maybe KeyRef
  }
  deriving stock (Show)

-- | 'OfferTicket': the number of a login field's offer of passkeys, which
-- the offer starts with only while it is current ('offerTicket').
newtype OfferTicket = OfferTicket Int
  deriving stock (Eq, Show)

-- | 'PasskeyRefusal': why a passkey was not made or used.
data PasskeyRefusal
  = -- | The person closed the browser's dialog, or let it time out.
    Cancelled
  | -- | Anything else, in the browser's words.
    PasskeyFailed Text
  deriving stock (Eq, Show)

-- | 'Talk': an open chat. It holds the chat's number in the browser-side
-- code, the callback its events come back through, which closing the chat
-- frees, and the handler the events go to.
data Talk = Talk
  { chat :: Int
  , callback :: Maybe Callback
  , heard :: Heard -> IO ()
  , blocked :: Maybe AssistantError
  -- ^ Why no message can be sent, when the page's policy refuses the
  -- chat's address ('blockedBy'): each message then fails with it.
  }

-- | 'Opening': what a chat is opened with. The provider, the model and the
-- key to use, and the request without its conversation
-- ("Wiki.Core.Assistant.Prompt").
data Opening = Opening
  { ready :: Ready
  , request :: Value
  }

-- | 'Heard': an event of one turn of the model.
data Heard
  = -- | Text the model wrote, as it streams.
    HeardText Text
  | -- | A piece of the summary of its thinking, as it streams. Anthropic
    -- and OpenAI send one when the request asks for it
    -- ("Wiki.Core.Assistant.Prompt") and the model thought; a model that
    -- did not think sends none.
    HeardThinking Text
  | -- | The model began writing a call of the tool named. The whole call
    -- follows as 'HeardCall' once its input is written, which for a long
    -- edit takes a while.
    HeardToolStart Text
  | -- | A tool call, by its number in the chat: the tool's name and its
    -- input. The turn waits for 'answerCall'.
    HeardCall Int Text Value
  | -- | The turn ended.
    HeardDone
  | -- | The turn was stopped.
    HeardStopped
  | -- | The turn failed.
    HeardFailed AssistantError
  deriving stock (Eq, Show)

instance FromJSON Heard where
  parseJSON = withObject "Heard" $ \o ->
    o .: "type" >>= \case
      "text" -> HeardText <$> o .: "text"
      "thinking" -> HeardThinking <$> o .: "text"
      "tool-start" -> HeardToolStart <$> o .: "name"
      "tool" -> HeardCall <$> o .: "call" <*> o .: "name" <*> o .: "input"
      "done" -> pure HeardDone
      "stopped" -> pure HeardStopped
      "error" -> HeardFailed <$> parseJSON (Object o)
      other -> pure (HeardFailed (AssistantError Failed Nothing ("An event of a kind not known: " <> other)))

-- | Whether a keydown in the message box sends the message: Enter, but not
-- with Shift (a new line) nor while a character is being composed. It is
-- pure, so that the keydown listener can decide synchronously, and prevent
-- Enter from inserting a new line.
sendsMessage :: Event -> Bool
sendsMessage = js_send_key

-- | Whether a keydown in the message box closes the panel: Escape, but not
-- in the middle of composing a character, where Escape cancels the
-- composition.
closesPanel :: Event -> Bool
closesPanel = js_close_key

-- | The time of day of a moment, as the chat shows it beside a message:
-- in the browser's time zone, written the way the browser's language
-- writes a short time ("14:32", or "2:32 PM"). Natively, where there is
-- no browser, hours and minutes in UTC.
clockTime :: (MonadIO m) => UTCTime -> m Text
clockTime t
  | inBrowser = liftIO (fromJSText <$> js_clock (realToFrac (utcTimeToPOSIXSeconds t) * 1000))
  | otherwise = pure (toS (formatTime defaultTimeLocale "%H:%M" t))

-- | The writing assistant, in the monad a component runs in.
--
-- The settings' methods and 'checkKey' wait (on IndexedDB, on the
-- provider), so a component calls them with @lift@. The others return
-- immediately, and are called with 'Halogen.liftEffect'.
--
-- A monad transformer over a monad with an instance gets the methods
-- lifted, so @instance MonadAssistant App@ is enough for an application's
-- transformer stack.
class (Monad m) => MonadAssistant m where
  -- | Whether a browser is present to store the settings in and reach the
  -- providers from. A page rendered ahead of the program (by the prerender
  -- or the server) has none, and leaves the assistant's views as first
  -- rendered ("Loading…"), which the program then adopts unchanged.
  assistantHere :: m Bool
  default assistantHere :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  assistantHere = lift assistantHere

  -- | What this device stores for a user ("Wiki.Core.Assistant.Vault"'s
  -- 'Wiki.Core.Assistant.Vault.DeviceRecord', as JSON), if anything, or
  -- why it cannot be read (a browser that stores nothing, as in some
  -- private windows).
  deviceRecord :: UserId -> m (Either Text (Maybe ByteString))
  default deviceRecord :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> m (Either Text (Maybe ByteString))
  deviceRecord = lift . deviceRecord

  -- | Store what this device keeps for a user, replacing what it kept; or,
  -- with nothing, delete it.
  keepDeviceRecord :: UserId -> Maybe ByteString -> m (Either Text ())
  default keepDeviceRecord :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> Maybe ByteString -> m (Either Text ())
  keepDeviceRecord user = lift . keepDeviceRecord user

  -- | A new vault key (AES-GCM), which can be exported only if asked: to
  -- be wrapped for a passkey.
  newVaultKey :: Bool -> m KeyRef
  default newVaultKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => Bool -> m KeyRef
  newVaultKey = lift . newVaultKey

  -- | Seal text with a vault key, authenticating the given data with it.
  sealWith :: KeyRef -> Text -> Text -> m (Either Text Sealed)
  default sealWith :: (MonadTrans t, MonadAssistant n, m ~ t n) => KeyRef -> Text -> Text -> m (Either Text Sealed)
  sealWith key text = lift . sealWith key text

  -- | Open what 'sealWith' sealed, with the same key and data; or why not.
  openWith :: KeyRef -> Sealed -> Text -> m (Either Text Text)
  default openWith :: (MonadTrans t, MonadAssistant n, m ~ t n) => KeyRef -> Sealed -> Text -> m (Either Text Text)
  openWith key sealed = lift . openWith key sealed

  -- | Let the page forget a key it holds.
  forgetKey :: KeyRef -> m ()
  default forgetKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => KeyRef -> m ()
  forgetKey = lift . forgetKey

  -- | 32 random bytes, in base64url: a new vault's salt.
  newSalt :: m Text
  default newSalt :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Text
  newSalt = lift newSalt

  -- | Keep a vault key as this device's for a user: for the page's life,
  -- and in IndexedDB too unless told not to ("ask for the passkey each
  -- time"), as a key that cannot be exported.
  keepDeviceKey :: UserId -> KeyRef -> Bool -> m (Either Text ())
  default keepDeviceKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> KeyRef -> Bool -> m (Either Text ())
  keepDeviceKey user key = lift . keepDeviceKey user key

  -- | The vault key this device holds for a user, if any.
  deviceKey :: UserId -> m (Maybe KeyRef)
  default deviceKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> m (Maybe KeyRef)
  deviceKey = lift . deviceKey

  -- | Let go of this device's vault key for a user.
  dropDeviceKey :: UserId -> m ()
  default dropDeviceKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> m ()
  dropDeviceKey = lift . dropDeviceKey

  -- | Whether passkeys can be used here: a browser with WebAuthn, on a
  -- secure page.
  passkeysHere :: m Bool
  default passkeysHere :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  passkeysHere = lift passkeysHere

  -- | Whether settings can be sealed here: the browser offers WebCrypto,
  -- which it does only to a secure page (HTTPS, or the machine's own
  -- address). Where it does not, the settings are stored as text, as
  -- before the vault ("Wiki.App.Assistant.Keys").
  sealingHere :: m Bool
  default sealingHere :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  sealingHere = lift sealingHere

  -- | Make a passkey with the server's options, asking for its PRF on the
  -- salt, whose output gives the wrapping key with this HKDF info.
  createPasskey :: RegistrationOptions -> Text -> Text -> m (Either PasskeyRefusal Made)
  default createPasskey :: (MonadTrans t, MonadAssistant n, m ~ t n) => RegistrationOptions -> Text -> Text -> m (Either PasskeyRefusal Made)
  createPasskey options salt = lift . createPasskey options salt

  -- | Use one of the user's passkeys, with the server's options, asking
  -- for its PRF on the salt, as 'createPasskey'.
  usePasskey :: AssertionOptions -> Text -> Text -> m (Either PasskeyRefusal Used)
  default usePasskey :: (MonadTrans t, MonadAssistant n, m ~ t n) => AssertionOptions -> Text -> Text -> m (Either PasskeyRefusal Used)
  usePasskey options salt = lift . usePasskey options salt

  -- | Whether the browser offers saved passkeys in a login field
  -- (conditional mediation), for 'signInPasskey'.
  conditionalHere :: m Bool
  default conditionalHere :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  conditionalHere = lift conditionalHere

  -- | The ticket of a login field's offer about to ask the server for its
  -- challenge: the offer starts only if no abort nor dialog came since
  -- ('signInPasskey'). It returns at once.
  offerTicket :: m OfferTicket
  default offerTicket :: (MonadTrans t, MonadAssistant n, m ~ t n) => m OfferTicket
  offerTicket = lift offerTicket

  -- | Use a passkey to sign in with (WP5.30 of docs/PLAN.md), with the
  -- server's options, asking for no PRF: in the browser's dialog, which
  -- ends any offer, or, given a ticket, from the login field's offer, which
  -- waits until a passkey is picked there or 'abortSignInPasskey' is
  -- called, and does not start ('Cancelled') if either happened since the
  -- ticket was taken. The result is the browser's answer for the server
  -- to check.
  signInPasskey :: AssertionOptions -> Maybe OfferTicket -> m (Either PasskeyRefusal AssertionResponse)
  default signInPasskey :: (MonadTrans t, MonadAssistant n, m ~ t n) => AssertionOptions -> Maybe OfferTicket -> m (Either PasskeyRefusal AssertionResponse)
  signInPasskey options = lift . signInPasskey options

  -- | End the sign-in with a passkey under way, if any; it comes back
  -- 'Cancelled'.
  abortSignInPasskey :: m ()
  default abortSignInPasskey :: (MonadTrans t, MonadAssistant n, m ~ t n) => m ()
  abortSignInPasskey = lift abortSignInPasskey

  -- | Wrap a vault key (one that can be exported) with a passkey's
  -- wrapping key, authenticating the given data with it.
  wrapWith :: KeyRef -> KeyRef -> Text -> m (Either Text WrappedKey)
  default wrapWith :: (MonadTrans t, MonadAssistant n, m ~ t n) => KeyRef -> KeyRef -> Text -> m (Either Text WrappedKey)
  wrapWith wrapping key = lift . wrapWith wrapping key

  -- | Unwrap a vault key with a passkey's wrapping key, as one that can be
  -- exported only if asked.
  unwrapWith :: KeyRef -> WrappedKey -> Text -> Bool -> m (Either Text KeyRef)
  default unwrapWith :: (MonadTrans t, MonadAssistant n, m ~ t n) => KeyRef -> WrappedKey -> Text -> Bool -> m (Either Text KeyRef)
  unwrapWith wrapping wrapped info = lift . unwrapWith wrapping wrapped info

  -- | Tell the person's password manager that a passkey of this relying
  -- party is not the wiki's any more, where the browser can.
  discardPasskey :: Text -> CredentialId -> m ()
  default discardPasskey :: (MonadTrans t, MonadAssistant n, m ~ t n) => Text -> CredentialId -> m ()
  discardPasskey rpId = lift . discardPasskey rpId

  -- | Whether a test installed the scripted provider.
  scriptedInstalled :: m Bool
  default scriptedInstalled :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  scriptedInstalled = lift scriptedInstalled

  -- | Whether the page is a secure context: served over HTTPS, or from the
  -- local machine's address.
  secureContext :: m Bool
  default secureContext :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  secureContext = lift secureContext

  -- | Start fetching the code the providers need, so that it is loaded by
  -- the first message.
  prepareAssistant :: m ()
  default prepareAssistant :: (MonadTrans t, MonadAssistant n, m ~ t n) => m ()
  prepareAssistant = lift prepareAssistant

  -- | Open a chat, whose turn events are passed to the given function.
  openTalk :: Opening -> (Heard -> IO ()) -> m Talk
  default openTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Opening -> (Heard -> IO ()) -> m Talk
  openTalk opening = lift . openTalk opening

  -- | Send a user message (as 'Wiki.Core.Assistant.Prompt.userTurn' builds
  -- it) with the current request (the chosen model and effort may have
  -- changed since the chat was opened). This runs one turn of the model,
  -- unless a turn is already running.
  sayTo :: Talk -> Value -> Text -> m ()
  default sayTo :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> Value -> Text -> m ()
  sayTo talk request = lift . sayTo talk request

  -- | Answer a tool call: the result the model receives, and whether the
  -- edit was made.
  answerCall :: Talk -> Int -> Text -> Bool -> m ()
  default answerCall :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> Int -> Text -> Bool -> m ()
  answerCall talk call text ok = lift (answerCall talk call text ok)

  -- | Stop the running turn, if any.
  stopTalk :: Talk -> m ()
  default stopTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> m ()
  stopTalk = lift . stopTalk

  -- | Close a chat: its turn is stopped, and no more events arrive.
  closeTalk :: Talk -> m ()
  default closeTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> m ()
  closeTalk = lift . closeTalk

  -- | "Test the key": the smallest possible request, looking up the model
  -- with the key, which is free. The result is the error, if any.
  checkKey :: Ready -> m (Maybe AssistantError)
  default checkKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => Ready -> m (Maybe AssistantError)
  checkKey = lift . checkKey

  -- | The provider's models, every one in its list, fetched with the key
  -- (the scripted provider's come from its script); or the error. Any
  -- response, including a refusal, shows that the provider can be reached;
  -- an error of kind 'Unreachable' shows that it cannot.
  listModels :: Ready -> m (Either AssistantError [Listed])
  default listModels :: (MonadTrans t, MonadAssistant n, m ~ t n) => Ready -> m (Either AssistantError [Listed])
  listModels = lift . listModels

instance (MonadAssistant m) => MonadAssistant (ReaderT r m)

-- | The browser's instance. Natively the bindings are inert stubs: nothing
-- runs 'BrowserDOM' there, but code written against it still type-checks.
instance MonadAssistant BrowserDOM where
  assistantHere = pure inBrowser
  deviceRecord = recordIn
  keepDeviceRecord = keepRecordIn
  newVaultKey exportable = liftIO (KeyRef <$> (evaluate =<< js_new_key exportable))
  sealWith (KeyRef k) text info = liftIO $ do
    answer <- evaluate . fromJSText =<< js_seal k (toJSText text) (toJSText info)
    pure (answered (\o -> Sealed <$> o .: "nonce" <*> o .: "ciphertext") answer)
  openWith (KeyRef k) sealed info = liftIO $ do
    answer <- evaluate . fromJSText =<< js_open_sealed k (toJSText sealed.nonce) (toJSText sealed.ciphertext) (toJSText info)
    pure (answered (.: "text") answer)
  forgetKey (KeyRef k) = liftIO (js_forget_key k)
  newSalt = liftIO (fromJSText <$> js_salt)
  keepDeviceKey user (KeyRef k) onDisk = liftIO $ do
    failure <- evaluate . fromJSText =<< js_keep_key (toJSText user.text) k onDisk
    pure (if T.null failure then Right () else Left ("This browser could not keep the vault's key: " <> failure))
  deviceKey user = liftIO $ do
    k <- evaluate =<< js_device_key (toJSText user.text)
    pure (if k == 0 then Nothing else Just (KeyRef k))
  dropDeviceKey user = liftIO (evaluate =<< js_drop_key (toJSText user.text))
  passkeysHere = liftIO js_passkeys_here
  sealingHere = liftIO js_sealing_here
  createPasskey options salt info = liftIO $ do
    answer <- evaluate . fromJSText =<< js_create (toJSText (json (toJSON options))) (toJSText salt) (toJSText info)
    pure . passkeyAnswer answer $ \o -> Made <$> o .: "response" <*> o .: "prf" <*> (keyRefOf <$> o .: "wrapping")
  usePasskey options salt info = liftIO $ do
    answer <- evaluate . fromJSText =<< js_get (toJSText (json (toJSON options))) (toJSText salt) (toJSText info)
    pure . passkeyAnswer answer $ \o -> Used <$> o .: "response" <*> (keyRefOf <$> o .: "wrapping")
  wrapWith (KeyRef wrapping) (KeyRef k) info = liftIO $ do
    answer <- evaluate . fromJSText =<< js_wrap wrapping k (toJSText info)
    pure (answered (\o -> WrappedKey <$> o .: "nonce" <*> o .: "key") answer)
  unwrapWith (KeyRef wrapping) wrapped info exportable = liftIO $ do
    answer <- evaluate . fromJSText =<< js_unwrap wrapping (toJSText wrapped.nonce) (toJSText wrapped.key) (toJSText info) exportable
    pure (answered (\o -> KeyRef <$> o .: "handle") answer)
  discardPasskey rpId credential = liftIO (evaluate =<< js_discard (toJSText rpId) (toJSText credential.text))
  conditionalHere = liftIO (evaluate =<< js_conditional_here)
  offerTicket = liftIO (OfferTicket <$> js_passkey_offer_ticket)
  signInPasskey options ticket = liftIO $ do
    answer <- evaluate . fromJSText =<< js_passkey_sign_in (toJSText (json (toJSON options))) (isJust ticket) (maybe (-1) (\(OfferTicket n) -> n) ticket)
    pure . passkeyAnswer answer $ \o -> o .: "response"
  abortSignInPasskey = liftIO js_passkey_abort
  scriptedInstalled = liftIO js_scripted
  secureContext = liftIO js_secure
  prepareAssistant = liftIO js_prepare
  openTalk opening heard = liftIO $ do
    callback <- mkSyncCallback (heard . heardOf . jsValText)
    chat <- js_open (toJSText (json (openingJSON opening))) callback
    blocked <- blockedBy opening.ready
    pure Talk {chat, callback = Just callback, heard, blocked}
  sayTo talk request user = liftIO $ case talk.blocked of
    Just e -> talk.heard (HeardFailed e)
    Nothing -> js_send talk.chat (toJSText user) (toJSText (json request))
  answerCall talk call text ok = liftIO (js_answer talk.chat call (toJSText text) ok)
  stopTalk talk = liftIO (js_stop talk.chat)
  closeTalk talk = liftIO $ do
    js_close talk.chat
    traverse_ freeCallback talk.callback
  checkKey r =
    liftIO $
      blockedBy r >>= \case
        Just e -> pure (Just e)
        Nothing -> do
          -- On wasm a safe import's result waits for its promise only when forced.
          answer <- evaluate . fromJSText =<< js_check (toJSText (json (endpointJSON r ["model" .= r.model])))
          pure $
            if T.null answer
              then Nothing
              else Just (either (\why -> AssistantError Failed Nothing (toS why)) identity (eitherDecodeStrict (encodeUtf8 answer)))
  listModels r =
    liftIO $
      blockedBy r >>= \case
        Just e -> pure (Left e)
        Nothing -> do
          answer <- evaluate . fromJSText =<< js_models (toJSText (json (endpointJSON r [])))
          pure (listedOf answer)

-- | The in-memory document's instance: records stored as in the browser,
-- in its in-memory IndexedDB, but no WebCrypto to seal them with, no
-- passkeys and no provider. Since it is not a browser, no assistant is
-- shown ('assistantHere'), and nothing reads its settings.
instance MonadAssistant MemDOM where
  assistantHere = pure False
  deviceRecord = recordIn
  keepDeviceRecord = keepRecordIn
  newVaultKey _ = pure (KeyRef 0)
  sealWith _ _ _ = pure (Left noBrowser)
  openWith _ _ _ = pure (Left noBrowser)
  forgetKey _ = pass
  newSalt = pure ""
  keepDeviceKey _ _ _ = pure (Left noBrowser)
  deviceKey _ = pure Nothing
  dropDeviceKey _ = pass
  passkeysHere = pure False
  sealingHere = pure False
  createPasskey _ _ _ = pure (Left (PasskeyFailed noBrowser))
  usePasskey _ _ _ = pure (Left (PasskeyFailed noBrowser))
  wrapWith _ _ _ = pure (Left noBrowser)
  unwrapWith _ _ _ _ = pure (Left noBrowser)
  discardPasskey _ _ = pass
  conditionalHere = pure False
  offerTicket = pure (OfferTicket 0)
  signInPasskey _ _ = pure (Left (PasskeyFailed noBrowser))
  abortSignInPasskey = pass
  scriptedInstalled = pure False
  secureContext = pure True
  prepareAssistant = pass
  openTalk _ heard = pure Talk {chat = 0, callback = Nothing, heard, blocked = Nothing}
  sayTo talk _ _ = liftIO (talk.heard (HeardFailed (AssistantError Unreachable Nothing "There is no browser here to reach a provider from.")))
  answerCall _ _ _ _ = pass
  stopTalk _ = pass
  closeTalk _ = pass
  checkKey _ = pure (Just (AssistantError Unreachable Nothing "There is no browser here to reach a provider from."))
  listModels _ = pure (Left (AssistantError Unreachable Nothing "There is no browser here to reach a provider from."))

-- | Why the browser would refuse a request to another service's base URL,
-- if it would: the page's Content Security Policy ("Wiki.Api.ContentPolicy")
-- does not allow its address. Checked before a request is made, so that
-- the settings and the chat say why at once, instead of the SDK retrying
-- a refused connection and reporting the network as down. A page without
-- a policy, and the scripted provider of the tests (which sends nothing),
-- refuse nothing.
blockedBy :: Ready -> IO (Maybe AssistantError)
blockedBy r = case r.baseUrl of
  Nothing -> pure Nothing
  Just url ->
    js_scripted >>= \case
      True -> pure Nothing
      False -> do
        policy <- fromJSText <$> js_page_policy
        origin <- fromJSText <$> js_page_origin
        pure $
          if T.null policy || allowsConnect origin policy url.text
            then Nothing
            else Just (AssistantError Blocked Nothing (blockedMessage policy url))

-- | What the assistant says of an address the page does not allow: the
-- addresses it does allow, and who can add one.
blockedMessage :: Text -> Url -> Text
blockedMessage policy url =
  maybe url.text identity (originOf url.text)
    <> " is not among the addresses they allow: "
    <> T.intercalate ", " (extraHosts policy)
    <> ". On a wiki with a server, an administrator can add it to the assistant's hosts, in the administration's server settings."

-- | The database the assistant's settings are stored in, separate from the
-- demo's wiki: one store, @settings@, keyed by user id, each value what this
-- device keeps for a user ("Wiki.Core.Assistant.Vault"'s
-- 'Wiki.Core.Assistant.Vault.DeviceRecord', or, written before the vault,
-- the settings as text, which are sealed and replaced the first time they
-- are read). The vault's key is kept apart, by @jsbits\/vault.js@, in a
-- database of its own (@wiki-assistant-keys@), since IndexedDB stores a
-- WebCrypto key only as the key itself.
assistantDatabase :: Database
assistantDatabase = Database {name = "wiki-assistant", version = 1, stores = ["settings"]}

-- | What a database keeps for a user, if anything.
readRecord :: (MonadIndexedDB m) => Database -> UserId -> m (Maybe ByteString)
readRecord db user = IDB.get db "settings" user.text

-- | Store what is kept for a user in a database, or delete it.
writeRecord :: (MonadIndexedDB m) => Database -> UserId -> Maybe ByteString -> m ()
writeRecord db user = \case
  Nothing -> IDB.delete db "settings" user.text
  Just bytes -> IDB.put db "settings" user.text bytes

recordIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> m (Either Text (Maybe ByteString))
recordIn user = failingAs (readRecord assistantDatabase user)

keepRecordIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> Maybe ByteString -> m (Either Text ())
keepRecordIn user record = failingAs (writeRecord assistantDatabase user record)

-- | What the in-memory document says of what only a browser does.
noBrowser :: Text
noBrowser = "There is no browser here to keep the assistant's keys in."

-- | A key's handle from the browser: 0 for none.
keyRefOf :: Int -> Maybe KeyRef
keyRefOf k = if k == 0 then Nothing else Just (KeyRef k)

-- | An answer of @jsbits\/vault.js@: JSON with what was asked for, or
-- @{error}@.
answered :: (Object -> Parser a) -> Text -> Either Text a
answered parse answer =
  case eitherDecodeStrict (encodeUtf8 answer) >>= parseEither (withObject "Answer" (\o -> (Left <$> o .: "error") <|> (Right <$> parse o))) of
    Left why -> Left ("The browser's answer could not be read: " <> toS why)
    Right result -> result

-- | A passkey's answer: what was asked for, or why not, with a dialog the
-- person closed told apart.
passkeyAnswer :: Text -> (Object -> Parser a) -> Either PasskeyRefusal a
passkeyAnswer answer parse =
  case eitherDecodeStrict (encodeUtf8 answer) >>= parseEither (withObject "Answer" (\o -> (Left <$> refusal o) <|> (Right <$> parse o))) of
    Left why -> Left (PasskeyFailed ("The browser's answer could not be read: " <> toS why))
    Right result -> result
  where
    refusal o = do
      why <- o .: "error"
      cancelled <- o .:? "cancelled" .!= False
      pure (if cancelled then Cancelled else PasskeyFailed why)

-- | An IndexedDB failure, as a message to the user.
failingAs :: (MonadUnliftIO m) => m a -> m (Either Text a)
failingAs action =
  withRunInIO (\run -> try (run action)) <&> first (\(IndexedDBError _ failure) -> "This browser could not keep the assistant's settings (" <> show failure <> ").")

-- | Decode the browser's response to a model list request: @{models:
-- [...]}@, or @{error: {kind, status, message}}@.
listedOf :: Text -> Either AssistantError [Listed]
listedOf answer =
  case eitherDecodeStrict (encodeUtf8 answer) >>= parseEither (withObject "Models" (\o -> (Right <$> o .: "models") <|> (Left <$> o .: "error"))) of
    Left why -> Left (AssistantError Failed Nothing ("A list of models that could not be read: " <> toS why))
    Right listed -> listed

heardOf :: Text -> Heard
heardOf text = either (\why -> HeardFailed (AssistantError Failed Nothing ("An event that could not be read: " <> toS why))) identity (eitherDecodeStrict (encodeUtf8 text))

openingJSON :: Opening -> Value
openingJSON o = endpointJSON o.ready ["model" .= o.ready.model, "request" .= o.request]

-- | What the browser-side code needs to reach a provider: the provider,
-- the key (empty for a server that needs none) and the base URL of another
-- service, if any; with the given extra fields.
endpointJSON :: Ready -> [Pair] -> Value
endpointJSON r more = object (["provider" .= providerKey r.provider, "key" .= r.key, "baseUrl" .= r.baseUrl] <> more)

json :: Value -> Text
json = decodeUtf8 . BSL.toStrict . encode
