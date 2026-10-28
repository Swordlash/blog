{-# LANGUAGE TemplateHaskell #-}

-- | 'MonadAssistant': what the writing assistant (WP4.19 of docs/PLAN.md)
-- needs from the monad a component runs in. That is the user's settings,
-- stored in this browser, and chats with a provider.
--
-- The settings (a key per provider, the chosen provider and each
-- provider's model: "Wiki.Core.Assistant") are stored in this browser's
-- IndexedDB, in a separate database ('assistantDatabase'), under the
-- user's id. So another user of the same browser has their own settings
-- and cannot see anyone else's key. The settings are never sent to the
-- wiki's server (there is no API for them) and never logged. They are not
-- deleted when the user signs out of the wiki: they belong to this
-- browser and this user, and the user finds them again on signing in, as
-- with a password manager. "Forget" is the way to delete a key.
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

    -- * Settings
  , updateAssistantSettings
  , assistantDatabase
  , readSettings
  , writeSettings
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Trans.Class (MonadTrans)
import Data.Aeson (FromJSON (..), Value (Object), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Pair, parseEither)
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
import Wiki.Core.Assistant (AssistantError (..), ErrorKind (..), Listed, Ready (..), Settings, blankSettings, defaultSettings, providerKey)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Url (Url (..))

-- The chat's bindings return immediately: a turn reports its events
-- through the callback. "Test the key" and the model list wait for the
-- provider's response, so they are safe imports, whose result on wasm is
-- a thunk until it is forced.
$( browserJS
     ["jsbits/assistant.js"]
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
     ]
 )

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

  -- | A user's settings, or why they cannot be read (a browser that stores
  -- nothing, as in some private windows).
  assistantSettings :: UserId -> m (Either Text Settings)
  default assistantSettings :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> m (Either Text Settings)
  assistantSettings = lift . assistantSettings

  -- | Store a user's settings, replacing the stored ones.
  keepAssistantSettings :: UserId -> Settings -> m (Either Text ())
  default keepAssistantSettings :: (MonadTrans t, MonadAssistant n, m ~ t n) => UserId -> Settings -> m (Either Text ())
  keepAssistantSettings user = lift . keepAssistantSettings user

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
  assistantSettings = settingsIn
  keepAssistantSettings = keepIn
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

-- | The in-memory document's instance: settings stored as in the browser,
-- in its in-memory IndexedDB (which the native tests read and write), and
-- no provider. Since it is not a browser, no assistant is shown
-- ('assistantHere').
instance MonadAssistant MemDOM where
  assistantHere = pure False
  assistantSettings = settingsIn
  keepAssistantSettings = keepIn
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
-- demo's wiki: one store, @settings@, keyed by user id, each value a
-- user's 'Settings' as JSON.
assistantDatabase :: Database
assistantDatabase = Database {name = "wiki-assistant", version = 1, stores = ["settings"]}

-- | A user's settings as stored in a database: the defaults if nothing is
-- stored (or the stored value cannot be decoded, as after a format change).
readSettings :: (MonadIndexedDB m) => Database -> UserId -> m Settings
readSettings db user =
  IDB.get db "settings" user.text <&> \case
    Just bytes -> fromRight defaultSettings (eitherDecodeStrict bytes)
    Nothing -> defaultSettings

-- | Change a user's stored settings, and store the result. The stored
-- settings are read again first, so that a change made elsewhere since
-- this caller read them (the editor fetching a provider's model list while
-- the panel changes the model) is not lost. The result is the settings
-- after the change.
updateAssistantSettings :: (MonadAssistant m) => UserId -> (Settings -> Settings) -> m (Either Text Settings)
updateAssistantSettings user f =
  assistantSettings user >>= \case
    Left why -> pure (Left why)
    Right s -> let new = f s in (new <$) <$> keepAssistantSettings user new

-- | Store a user's settings in a database. Settings with nothing set (no
-- key, nothing chosen) are deleted instead, so that "Forget" on the last
-- key leaves nothing stored.
writeSettings :: (MonadIndexedDB m) => Database -> UserId -> Settings -> m ()
writeSettings db user settings
  | blankSettings settings = IDB.delete db "settings" user.text
  | otherwise = IDB.put db "settings" user.text (BSL.toStrict (encode settings))

settingsIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> m (Either Text Settings)
settingsIn user = failingAs (readSettings assistantDatabase user)

keepIn :: (MonadIndexedDB m, MonadUnliftIO m) => UserId -> Settings -> m (Either Text ())
keepIn user settings = failingAs (writeSettings assistantDatabase user settings)

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
