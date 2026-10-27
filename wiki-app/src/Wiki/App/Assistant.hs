{-# LANGUAGE TemplateHaskell #-}

-- | What the writing assistant (WP4.19 of docs/PLAN.md) takes from the
-- monad a component runs in: the user's settings, kept in this browser,
-- and a chat with a provider.
--
-- The settings (a key per provider, the provider chosen and each one's
-- model: "Wiki.Core.Assistant") are kept in this browser's IndexedDB, in a
-- database of their own ('assistantDatabase'), under the user's id, so that
-- another user of the same browser has settings of their own and sees no
-- one else's key. They are never sent to the wiki's server (there is no API
-- for them) and never logged; "Forget" takes a key away. They outlive
-- signing out of the wiki: they are this browser's and this user's, and
-- whoever signs in as the user again finds them, as a password manager
-- would; "Forget" is how they go.
--
-- A chat is one conversation with a provider ('openTalk'), which the
-- browser's side keeps for the editing session: each message sent
-- ('sayTo') runs one turn of the model's, which is heard of as it happens
-- ('Heard'): its text as it streams, each tool call, which the turn waits
-- on until it is answered ('answerCall'), and how the turn ended. A turn
-- can be stopped ('stopTalk'). The providers are Anthropic's and OpenAI's
-- SDKs, called from the browser with the user's key
-- (@web/src/assistant.js@, fetched the first time the assistant is used),
-- or the scripted provider a test installs ('scriptedInstalled'); see
-- @jsbits/assistant.js@.
--
-- In a browser ('BrowserDOM') all of this is real. In the in-memory
-- document the prerender and the native tests use ('MemDOM') the settings
-- are kept in its in-memory IndexedDB, as the browser's would be, and
-- there is no provider: a chat's every turn fails, saying so.
module Wiki.App.Assistant
  ( -- * The class
    MonadAssistant (..)
  , Talk
  , Opening (..)
  , Heard (..)
  , sendsMessage

    -- * Settings
  , assistantDatabase
  , readSettings
  , writeSettings
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Trans.Class (MonadTrans)
import Data.Aeson (FromJSON (..), Value (Object), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Type.Equality (type (~))
import Halogen.JSBits (Callback, JSText, Safety (..), browserJS, freeCallback, fromJSText, inBrowser, jsValText, mkSyncCallback, toJSText)
import Halogen.VDom.DOM.Monad (BrowserDOM)
import Halogen.VDom.DOM.Monad.Mem (MemDOM)
import Protolude
import Web.Event.Event (Event (..))
import Web.Storage.IndexedDB (Database (..), IndexedDBError (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Core.Assistant (AssistantError (..), ErrorKind (..), Ready (..), Settings, blankSettings, defaultSettings, providerKey)
import Wiki.Core.Id (UserId (..))

-- The chat's bindings return at once: a turn tells of itself through the
-- callback. "Test the key" waits for the provider's answer, so it is a
-- safe import, whose result is a thunk on wasm until it is forced.
$( browserJS
     ["jsbits/assistant.js"]
     [ ("js_open", "wiki_assistant_open", Unsafe, [t|JSText -> Callback -> IO Int|])
     , ("js_send", "wiki_assistant_send", Unsafe, [t|Int -> JSText -> JSText -> IO ()|])
     , ("js_answer", "wiki_assistant_answer", Unsafe, [t|Int -> Int -> JSText -> Bool -> IO ()|])
     , ("js_stop", "wiki_assistant_stop", Unsafe, [t|Int -> IO ()|])
     , ("js_close", "wiki_assistant_close", Unsafe, [t|Int -> IO ()|])
     , ("js_check", "wiki_assistant_check", Safe, [t|JSText -> IO JSText|])
     , ("js_scripted", "wiki_assistant_scripted", Unsafe, [t|IO Bool|])
     , ("js_secure", "wiki_assistant_secure", Unsafe, [t|IO Bool|])
     , ("js_prepare", "wiki_assistant_prepare", Unsafe, [t|IO ()|])
     , ("js_send_key", "wiki_assistant_send_key", Unsafe, [t|Event -> Bool|])
     ]
 )

-- | A chat, open: its number on the browser's side, the callback its
-- events come back through, which closing it lets go of, and where they go.
data Talk = Talk
  { chat :: Int
  , callback :: Maybe Callback
  , heard :: Heard -> IO ()
  }

-- | What a chat is opened with: the provider, the model and the key to ask
-- with, and the request without its conversation
-- ("Wiki.Core.Assistant.Prompt").
data Opening = Opening
  { ready :: Ready
  , request :: Value
  }

-- | What is heard of a turn of the model's.
data Heard
  = -- | Text it wrote, as it streams.
    HeardText Text
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
      "tool" -> HeardCall <$> o .: "call" <*> o .: "name" <*> o .: "input"
      "done" -> pure HeardDone
      "stopped" -> pure HeardStopped
      "error" -> HeardFailed <$> parseJSON (Object o)
      other -> pure (HeardFailed (AssistantError Failed Nothing ("An event of a kind not known: " <> other)))

-- | Whether a keydown in the message box sends the message: Enter, but not
-- with Shift (a new line) nor in the middle of composing a character.
-- Pure, so that the keydown's listener decides, and keeps Enter from
-- putting in a new line.
sendsMessage :: Event -> Bool
sendsMessage = js_send_key

-- | The writing assistant, in the monad a component runs in.
--
-- The settings' methods and 'checkKey' wait (on IndexedDB, on the
-- provider), so a component calls them with @lift@; the others return at
-- once, and are called with 'Halogen.liftEffect'.
--
-- An application monad over one that has an instance gets the methods
-- lifted, so @instance MonadAssistant App@ is enough for a transformer
-- stack.
class (Monad m) => MonadAssistant m where
  -- | Whether there is a browser here to keep the settings in and reach the
  -- providers from. A page rendered ahead of the program (the prerender,
  -- the server) has none, and leaves what the assistant shows as it is
  -- first rendered ("Loading…"), which the program then adopts as it is.
  assistantHere :: m Bool
  default assistantHere :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  assistantHere = lift assistantHere

  -- | A user's settings, or why they cannot be read (a browser that keeps
  -- nothing, in some private windows).
  assistantSettings :: UserId -> m (Either Text Settings)
  default assistantSettings :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> m (Either Text Settings)
  assistantSettings = lift . assistantSettings

  -- | Keep a user's settings, replacing what was kept.
  keepAssistantSettings :: UserId -> Settings -> m (Either Text ())
  default keepAssistantSettings :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> Settings -> m (Either Text ())
  keepAssistantSettings user = lift . keepAssistantSettings user

  -- | Whether a test installed the scripted provider.
  scriptedInstalled :: m Bool
  default scriptedInstalled :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  scriptedInstalled = lift scriptedInstalled

  -- | Whether the page is a secure context: served over HTTPS, or from the
  -- machine's own address.
  secureContext :: m Bool
  default secureContext :: (MonadTrans t, MonadAssistant n, m ~ t n) => m Bool
  secureContext = lift secureContext

  -- | Start fetching what the providers need, so that it is there by the
  -- first message.
  prepareAssistant :: m ()
  default prepareAssistant :: (MonadTrans t, MonadAssistant n, m ~ t n) => m ()
  prepareAssistant = lift prepareAssistant

  -- | Open a chat, whose turns are heard of through the function given.
  openTalk :: Opening -> (Heard -> IO ()) -> m Talk
  default openTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Opening -> (Heard -> IO ()) -> m Talk
  openTalk opening = lift . openTalk opening

  -- | Send a message of the user's (as "Wiki.Core.Assistant.Prompt"'s
  -- 'Wiki.Core.Assistant.Prompt.userTurn' makes it) with the request as it
  -- is now (the model and the effort chosen may have changed since the
  -- chat was opened), which runs one turn of the model's, unless one is
  -- running.
  sayTo :: Talk -> Value -> Text -> m ()
  default sayTo :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> Value -> Text -> m ()
  sayTo talk request = lift . sayTo talk request

  -- | Answer a tool call: what the model is told, and whether the edit was
  -- made.
  answerCall :: Talk -> Int -> Text -> Bool -> m ()
  default answerCall :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> Int -> Text -> Bool -> m ()
  answerCall talk call text ok = lift (answerCall talk call text ok)

  -- | Stop the turn that is running, if one is.
  stopTalk :: Talk -> m ()
  default stopTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> m ()
  stopTalk = lift . stopTalk

  -- | Close a chat: its turn stopped, and nothing more heard.
  closeTalk :: Talk -> m ()
  default closeTalk :: (MonadTrans t, MonadAssistant n, m ~ t n) => Talk -> m ()
  closeTalk = lift . closeTalk

  -- | "Test the key": the smallest request there is, the model looked up
  -- with the key, which costs nothing; what went wrong, if anything.
  checkKey :: Ready -> m (Maybe AssistantError)
  default checkKey :: (MonadTrans t, MonadAssistant n, m ~ t n) => Ready -> m (Maybe AssistantError)
  checkKey = lift . checkKey

instance (MonadAssistant m) => MonadAssistant (ReaderT r m)

-- | The browser's. Natively the bindings are inert stubs: nothing runs
-- 'BrowserDOM' there, but code written against it still type-checks.
instance MonadAssistant BrowserDOM where
  assistantHere = pure inBrowser
  assistantSettings = settingsIn
  keepAssistantSettings = keepIn
  scriptedInstalled = liftIO js_scripted
  secureContext = liftIO js_secure
  prepareAssistant = liftIO js_prepare
  openTalk opening heard = liftIO $ do
    callback <- mkSyncCallback (heard . heardOf . jsValText)
    chat <- js_open (toJSText (json (openingJSON opening))) callback
    pure Talk {chat, callback = Just callback, heard}
  sayTo talk request user = liftIO (js_send talk.chat (toJSText user) (toJSText (json request)))
  answerCall talk call text ok = liftIO (js_answer talk.chat call (toJSText text) ok)
  stopTalk talk = liftIO (js_stop talk.chat)
  closeTalk talk = liftIO $ do
    js_close talk.chat
    traverse_ freeCallback talk.callback
  checkKey r = liftIO $ do
    -- On wasm a safe import's result waits for its promise only when forced.
    answer <- evaluate . fromJSText =<< js_check (toJSText (json (object ["provider" .= providerKey r.provider, "model" .= r.model, "key" .= r.key])))
    pure $
      if T.null answer
        then Nothing
        else Just (either (\why -> AssistantError Failed Nothing (toS why)) identity (eitherDecodeStrict (encodeUtf8 answer)))

-- | The in-memory document's: settings kept as the browser's are, in its
-- in-memory IndexedDB (which the native tests read and write), and no
-- provider; and, being no browser, no assistant shown ('assistantHere').
instance MonadAssistant MemDOM where
  assistantHere = pure False
  assistantSettings = settingsIn
  keepAssistantSettings = keepIn
  scriptedInstalled = pure False
  secureContext = pure True
  prepareAssistant = pass
  openTalk _ heard = pure Talk {chat = 0, callback = Nothing, heard}
  sayTo talk _ _ = liftIO (talk.heard (HeardFailed (AssistantError Unreachable Nothing "There is no browser here to reach a provider from.")))
  answerCall _ _ _ _ = pass
  stopTalk _ = pass
  closeTalk _ = pass
  checkKey _ = pure (Just (AssistantError Unreachable Nothing "There is no browser here to reach a provider from."))

-- | The database the assistant's settings are kept in, apart from the
-- demo's wiki: one store, @settings@, keyed by the user's id, each value a
-- user's 'Settings' as JSON.
assistantDatabase :: Database
assistantDatabase = Database {name = "wiki-assistant", version = 1, stores = ["settings"]}

-- | A user's settings as kept in a database: the defaults if nothing is
-- kept (or what is kept cannot be read, as after a change of format).
readSettings :: (MonadIndexedDB m) => Database -> UserId -> m Settings
readSettings db user =
  IDB.get db "settings" user.text <&> \case
    Just bytes -> fromRight defaultSettings (eitherDecodeStrict bytes)
    Nothing -> defaultSettings

-- | Keep a user's settings in a database. Settings with nothing in them
-- (no key, nothing chosen) are not kept at all: what "Forget" leaves of the
-- last key is nothing.
writeSettings :: (MonadIndexedDB m) => Database -> UserId -> Settings -> m ()
writeSettings db user settings
  | blankSettings settings = IDB.delete db "settings" user.text
  | otherwise = IDB.put db "settings" user.text (BSL.toStrict (encode settings))

settingsIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> m (Either Text Settings)
settingsIn user = failingAs (readSettings assistantDatabase user)

keepIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> Settings -> m (Either Text ())
keepIn user settings = failingAs (writeSettings assistantDatabase user settings)

-- | An IndexedDB failure, said to the user.
failingAs :: (MonadUnliftIO m) => m a -> m (Either Text a)
failingAs action =
  withRunInIO (\run -> try (run action)) <&> first (\(IndexedDBError _ failure) -> "This browser could not keep the assistant's settings (" <> show failure <> ").")

heardOf :: Text -> Heard
heardOf text = either (\why -> HeardFailed (AssistantError Failed Nothing ("An event that could not be read: " <> toS why))) identity (eitherDecodeStrict (encodeUtf8 text))

openingJSON :: Opening -> Value
openingJSON o = object ["provider" .= providerKey o.ready.provider, "model" .= o.ready.model, "key" .= o.ready.key, "request" .= o.request]

json :: Value -> Text
json = decodeUtf8 . BSL.toStrict . encode
