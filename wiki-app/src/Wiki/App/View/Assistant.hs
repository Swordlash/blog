{-# LANGUAGE QuasiQuotes #-}

-- | The writing assistant's panel in the editor (WP4.19 of docs/PLAN.md):
-- a chat with a model that edits the page, as code editors have them.
--
-- The panel is a list of messages, the user's and the model's (streamed
-- as they come), under it a row of shortcuts that fill the message in
-- (improve, fix grammar, shorten, expand, summarise, continue, translate),
-- and the message box with Send, or Stop while the model is at work.
-- Enter sends, Shift+Enter starts a new line.
--
-- What goes with a message: when the editor has a selection, it is
-- attached, shown as a chip ("lines 12–20") with a button to detach it,
-- and the model gets it with a paragraph around it; otherwise it gets the
-- page, its first 'bodyCap' characters, which the panel says when a page
-- is longer ("Wiki.Core.Assistant.Prompt"). The conversation lasts as
-- long as the editor (it is kept nowhere), and goes whole with each
-- message.
--
-- The model edits the page itself, through its tools, and the author
-- decides: each edit is made in the editor at once as a tracked change
-- ("Wiki.App.Editor.Browser", "Wiki.Core.Assistant.Edit"), shown with what
-- it replaced, and the tool answers the model that it was made, or why not
-- (its text not found, or found twice), and the model goes on. The changes
-- are accepted or rejected one by one on the change itself, or all at once
-- here. Nothing is written into the page that the author cannot reject, and
-- the page's Markdown is never saved by the assistant: what the author
-- saves is theirs (a save with changes still pending accepts them, which
-- the editor says beside Save).
--
-- Stop ends the model's turn, its request with it; the changes made by
-- then stay, to decide. Closing the panel stops the turn too; the panel
-- stays mounted, with its conversation, until the editor goes.
--
-- The panel reads the user's settings when it is first opened, and keeps
-- the provider and model it found for the editing session. Without a key
-- for the provider chosen, it says where to add one.
module Wiki.App.View.Assistant
  ( Input (..)
  , Query (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value)
import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.Subscription qualified as HS
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element)
import Web.Event.Event (Event, EventType (..))
import Wiki.App.Assistant (Heard (..), MonadAssistant (..), Opening (..), Talk, sendsMessage)
import Wiki.App.Backend (Session (..))
import Wiki.App.Editor.Browser (currentText, focusElement, proposeEdit, trackedChanges)
import Wiki.App.Route (Route (AssistantSettings))
import Wiki.App.View.Common (Context (..), attr)
import Wiki.Core.Assistant
  ( Model (..)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (..)
  , Settings (..)
  , errorText
  , models
  , providerLabel
  , ready
  , settingsOf
  )
import Wiki.Core.Assistant.Edit (Change (..), Decision (..), Refusal (..), answer, describeEdit, parseEdit)
import Wiki.Core.Assistant.Prompt
  ( Outcome (..)
  , PageContext (..)
  , Shortcut (..)
  , Span (..)
  , anthropicRequest
  , bodyCap
  , chipLabel
  , lineSpan
  , openAiRequest
  , pageContext
  , shortcutLabel
  , shortcutText
  , shortcuts
  , userTurn
  )
import Wiki.Core.User (User (id))

-- | What the editor tells the panel: where the page's text is, its title
-- and Markdown now, what is selected in it, and how many of the
-- assistant's changes are left to decide.
data Input = Input
  { context :: Context
  , host :: Maybe Element
  -- ^ CodeMirror's host: the editor's text ("Wiki.App.Editor.Browser").
  , title :: Text
  , body :: Text
  , selection :: Maybe Span
  , pending :: Int
  , decisions :: Map Int Decision
  -- ^ What the author decided of the assistant's changes, by id.
  }

-- | The panel was closed: the model's turn, if one is running, stops.
data Query a = Hide a

-- | The panel's own close button; and "Accept all" or "Reject all", which
-- the editor carries out, as it does a decision on one change.
data Output = Closed | DecideAll Decision

-- | A message of the conversation.
data Entry
  = -- | The user's: the message, the lines of the selection attached, if
    -- one was, and the page's length when it was cut to send it.
    FromUser Text (Maybe Text) (Maybe Int)
  | -- | The model's: its text, the edits it made or tried, and whether it
    -- is still at it.
    FromModel Text [Note] Ending
  | -- | What went wrong.
    Trouble Text

data Note = Made Text | NotMade Text Text

data Ending = Streaming | Ended | Stopped
  deriving stock (Eq)

data State = State
  { input :: Input
  , settings :: Maybe (Either Text Settings)
  -- ^ The user's settings, once read.
  , message :: Text
  , entries :: [Entry]
  , talk :: Maybe Talk
  -- ^ The chat, once the first message has opened it.
  , using :: Maybe Ready
  -- ^ What the chat asks with: kept for its errors, from which the key is
  -- taken out.
  , talking :: Bool
  , detached :: Maybe Span
  -- ^ A selection the user detached, which is not sent until another is
  -- made.
  , nextChange :: Int
  , made :: Map Int Text
  -- ^ The changes the model made that it has not been told the fate of,
  -- by id, as they were described.
  , absorbed :: [Int]
  -- ^ Changes a later change of the model's took in, which need no word.
  , listener :: Maybe (HS.Listener IO Heard)
  , field :: H.RefLabel
  }

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Typed Text
  | Shortcut Shortcut
  | Send
  | Stop
  | Detach
  | FromTalk Heard
  | Decided Decision
  | Close
  | Followed (Follow Route)

component :: forall m. (MonadAssistant m, MonadUUID m, MonadIO m) => H.Component Query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          field <- H.newRefLabel "assistant-message"
          pure
            State
              { input
              , settings = Nothing
              , message = ""
              , entries = []
              , talk = Nothing
              , using = Nothing
              , talking = False
              , detached = Nothing
              , nextChange = 1
              , made = mempty
              , absorbed = []
              , listener = Nothing
              , field
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="assistant" aria-label="Writing assistant">
          <header class="assistant-head">
            <h2>Assistant</h2>
            <span class="assistant-using">{{ usingLine st }}</span>
            <a class="assistant-settings-link" {{ Router.linkProps st.input.context.router Followed AssistantSettings }}>Settings</a>
            <button type="button" class="assistant-close" title="Close the assistant" aria-label="Close the assistant" onClick={{ const Close }}>×</button>
          </header>
          {{ setupNote st }}
          {% if st.input.pending > 0 %}
            <div class="assistant-changes" role="status">
              <span class="assistant-pending">{{ changesWord st.input.pending }} to accept or reject</span>
              <button type="button" class="assistant-accept-all" onClick={{ const (Decided Accept) }}>Accept all</button>
              <button type="button" class="assistant-reject-all" onClick={{ const (Decided Reject) }}>Reject all</button>
            </div>
          {% end %}
          <div class="assistant-log">
            <div class="assistant-messages" aria-live="polite">
              {% if null st.entries %}
                <p class="assistant-empty">Ask for a change to the page, or choose one below. Select text first to ask about it alone. Each change the assistant makes is shown in the page, for you to accept or reject.</p>
              {% end %}
              {% for e in st.entries %}
                {{ entryView e }}
              {% end %}
            </div>
          </div>
          <div class="assistant-shortcuts" role="group" aria-label="Shortcuts">
            {% for s in shortcuts %}
              <button type="button" class="assistant-shortcut" {{ attr "data-shortcut" (shortcutLabel s) }} disabled={{ st.talking }} onClick={{ const (Shortcut s) }}>{{ shortcutLabel s }}</button>
            {% end %}
          </div>
          <div class="assistant-scope">{{ scopeView st }}</div>
          <div class="assistant-compose">
            <textarea
              class="assistant-input"
              rows="3"
              placeholder="Ask for a change, or a question about the page"
              aria-label="Message to the assistant"
              value={{ st.message }}
              onValueInput={{ Typed }}
              {{ HE.preventingDefault (HE.handler' (EventType "keydown") sendKey) }}
              ref={{ st.field }}
            ></textarea>
            {% if st.talking %}
              <button type="button" class="assistant-stop" onClick={{ const Stop }}>Stop</button>
            {% else %}
              <button type="button" class="primary assistant-send" disabled={{ T.null (T.strip st.message) }} onClick={{ const Send }}>Send</button>
            {% end %}
          </div>
        </section>
      |]

    -- Enter sends; any other key is the message box's.
    sendKey :: Event -> Maybe Action
    sendKey ev = if sendsMessage ev then Just Send else Nothing

    usingLine :: State -> Text
    usingLine st = case st.settings of
      Just (Right s) ->
        let chosen = (settingsOf s.provider s).model
         in maybe chosen (\m -> m.label) (find (\m -> m.id == chosen) (models s.provider)) <> " \183 " <> providerLabel s.provider
      _ -> ""

    setupNote :: State -> Maybe (H.ComponentHTML Action Empty m)
    setupNote st = case st.settings of
      Nothing -> Just [hh|<p class="loading">Loading your settings…</p>|]
      Just (Left why) -> Just [hh|<p class="error assistant-setup" role="alert">{{ why }}</p>|]
      Just (Right s) -> case ready s of
        Left why ->
          Just
            [hh|
              <p class="assistant-setup">
                {{ why }}
                <a {{ Router.linkProps st.input.context.router Followed AssistantSettings }}>Open the assistant's settings</a>
              </p>
            |]
        Right _ -> Nothing

    -- What goes with the next message: the selection, with the way to
    -- leave it out, or the page.
    scopeView :: State -> H.ComponentHTML Action Empty m
    scopeView st = case attached st of
      Just sp ->
        [hh|
          <span class="assistant-chip">
            {{ chipLabel (lineSpan st.input.body sp) }}
            <button type="button" class="assistant-detach" title="Send without the selection" aria-label="Send without the selection" onClick={{ const Detach }}>×</button>
          </span>
        |]
      Nothing
        | T.length st.input.body > bodyCap -> [hh|<span class="assistant-whole">Nothing selected: the first {{ show bodyCap :: Text }} characters of the page go with your message.</span>|]
        | otherwise -> [hh|<span class="assistant-whole">Nothing selected: the page goes with your message.</span>|]

    entryView :: Entry -> H.ComponentHTML Action Empty m
    entryView = \case
      FromUser text chip cut ->
        [hh|
          <div class="assistant-message from-user">
            <p class="assistant-text">{{ text }}</p>
            {% for c in maybeToList chip %}
              <span class="assistant-chip">{{ c }}</span>
            {% end %}
            {% for n in maybeToList cut %}
              <p class="assistant-cut">Only the first {{ show bodyCap :: Text }} of the page's {{ show n :: Text }} characters were sent.</p>
            {% end %}
          </div>
        |]
      FromModel text notes ending ->
        [hh|
          <div class="assistant-message from-model{% if ending == Streaming %} streaming{% end %}">
            {% if not (T.null text) %}
              <p class="assistant-text">{{ text }}</p>
            {% end %}
            {% if ending == Streaming && T.null text && null notes %}
              <p class="assistant-thinking">Thinking…</p>
            {% end %}
            {% if not (null notes) %}
              <ul class="assistant-notes">
                {% for n in notes %}
                  {{ noteView n }}
                {% end %}
              </ul>
            {% end %}
            {% if ending == Stopped %}
              <p class="assistant-stopped">Stopped.</p>
            {% end %}
          </div>
        |]
      Trouble why -> [hh|<p class="error assistant-error" role="alert">{{ why }}</p>|]

    noteView :: Note -> H.ComponentHTML Action Empty m
    noteView = \case
      Made what -> [hh|<li class="assistant-made">{{ what }}</li>|]
      NotMade what why -> [hh|<li class="assistant-not-made">{{ what }}: not made, {{ why }}</li>|]

    handleQuery :: Query a -> H.HalogenM State Action Empty Output m (Maybe a)
    handleQuery (Hide next) = stop $> Just next

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Initialize -> do
        H.liftEffect prepareAssistant
        channel <- liftIO HS.create
        void (H.subscribe (FromTalk <$> channel.emitter))
        modify (\st -> st {listener = Just channel.listener})
        gets (\st -> (\u -> u.id) <$> st.input.context.session.user) >>= \case
          Nothing -> modify (\st -> st {settings = Just (Left "Sign in to use the assistant: its settings are kept for each user.")})
          Just user -> do
            settings <- lift (assistantSettings user)
            modify (\st -> st {settings = Just settings})
      Finalize -> gets (\st -> st.talk) >>= traverse_ (H.liftEffect . closeTalk)
      Receive input -> modify $ \st ->
        -- A detached selection stays detached until another is made.
        st {input, detached = if input.selection == st.input.selection then st.detached else Nothing}
      Typed t -> modify (\st -> st {message = t})
      Shortcut s -> do
        modify (\st -> st {message = shortcutText s})
        gets (\st -> st.field) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      Send -> send
      Stop -> stop
      Detach -> modify (\st -> st {detached = st.input.selection})
      FromTalk heard -> hear heard
      Decided d -> H.raise (DecideAll d)
      Close -> do
        stop
        H.raise Closed
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)

    stop :: H.HalogenM State Action Empty Output m ()
    stop = do
      st <- get
      when st.talking $ traverse_ (H.liftEffect . stopTalk) st.talk

    send :: H.HalogenM State Action Empty Output m ()
    send = do
      st <- get
      let text = T.strip st.message
      unless (st.talking || T.null text) $ case (st.settings, st.input.host) of
        (Just (Right s), Just host) -> case ready s of
          Left why -> addEntry (Trouble why)
          Right r -> do
            body <- H.liftEffect (currentText host)
            decided <- outcomes host
            let context = pageContext st.input.title body (attached st)
                (chip, cut) = case context of
                  Selected {lineRange} -> (Just (chipLabel lineRange), Nothing)
                  Whole {cutFrom} -> (Nothing, cutFrom)
            talk <- maybe (open r) pure st.talk
            modify $ \s' ->
              s'
                { entries = s'.entries <> [FromUser text chip cut, FromModel "" [] Streaming]
                , message = ""
                , talking = True
                , talk = Just talk
                , using = Just r
                , detached = Nothing
                }
            H.liftEffect (sayTo talk (userTurn decided context text))
        (Just (Left why), _) -> addEntry (Trouble why)
        _ -> pass

    -- The chat, opened with what the settings say, its turns heard of by
    -- the panel.
    open :: Ready -> H.HalogenM State Action Empty Output m Talk
    open r = do
      tell <- gets (\st -> maybe (const pass) HS.notify st.listener)
      H.liftEffect (openTalk Opening {ready = r, request = requestFor r} tell)

    hear :: Heard -> H.HalogenM State Action Empty Output m ()
    hear = \case
      HeardText t -> modifyModel (\text notes ending -> FromModel (text <> t) notes ending)
      HeardCall call name input -> do
        (said, told, ok) <- edit name input
        modifyModel (\text notes ending -> FromModel text (notes <> [said]) ending)
        gets (\st -> st.talk) >>= traverse_ (\talk -> H.liftEffect (answerCall talk call told ok))
      HeardDone -> finish Ended
      HeardStopped -> finish Stopped
      HeardFailed e -> do
        finish Ended
        key <- gets (\st -> (\r -> r.key) <$> st.using)
        addEntry (Trouble (errorText key e))

    -- A tool call's edit, made in the editor as a tracked change: what the
    -- conversation says of it, what the model is told, and whether it was
    -- made.
    edit :: Text -> Value -> H.HalogenM State Action Empty Output m (Note, Text, Bool)
    edit name input = case parseEdit name input of
      Left why -> pure (NotMade ("A call of " <> name) (refusalWords why), answer (Left why :: Either Refusal ()), False)
      Right e -> do
        st <- get
        case st.input.host of
          Nothing -> pure (NotMade (describeEdit e) "the editor is not ready", "Not applied: the editor is not ready. Try again later.", False)
          Just host ->
            H.liftEffect (proposeEdit host st.nextChange e) >>= \case
              Left why -> pure (NotMade (describeEdit e) (refusalWords why), answer (Left why :: Either Refusal ()), False)
              Right (r, taken) -> do
                modify $ \s ->
                  s
                    { nextChange = s.nextChange + 1
                    , made = Map.insert s.nextChange (describeEdit e) s.made
                    , absorbed = taken <> s.absorbed
                    }
                pure (Made (describeEdit e), answer (Right r), True)

    -- What became of the model's changes since it was last told: those
    -- decided, or gone without a decision (undone, or edited away), each
    -- told once; those still pending wait, and those a later change took
    -- in need no word.
    outcomes :: Element -> H.HalogenM State Action Empty Output m [(Text, Outcome)]
    outcomes host = do
      pending <- map (\c -> c.id) <$> H.liftEffect (trackedChanges host)
      st <- get
      let gone = Map.filterWithKey (\i _ -> i `notElem` pending) st.made
          outcome i = case Map.lookup i st.input.decisions of
            Just Accept -> Just Accepted
            Just Reject -> Just Rejected
            Nothing
              | i `elem` st.absorbed -> Nothing
              | otherwise -> Just Undone
      modify (\s -> s {made = Map.difference s.made gone})
      pure [(what, o) | (i, what) <- Map.toList gone, Just o <- [outcome i]]

    finish :: Ending -> H.HalogenM State Action Empty Output m ()
    finish ending = do
      modifyModel (\text notes _ -> FromModel text notes ending)
      modify (\st -> st {talking = False})

    -- The model's last message, changed, if the last entry is one.
    modifyModel :: (Text -> [Note] -> Ending -> Entry) -> H.HalogenM State Action Empty Output m ()
    modifyModel f = modify $ \st -> case unsnoc st.entries of
      Just (before, FromModel text notes ending) -> st {entries = before <> [f text notes ending]}
      _ -> st

    addEntry :: Entry -> H.HalogenM State Action Empty Output m ()
    addEntry e = modify (\st -> st {entries = st.entries <> [e]})

-- | The selection that goes with the next message, unless it was detached.
attached :: State -> Maybe Span
attached st = mfilter (\sp -> Just sp /= st.detached && sp.to > sp.from) st.input.selection

-- | The request a chat is opened with, by provider. The scripted provider
-- is sent Anthropic's, which its tests read.
requestFor :: Ready -> Value
requestFor r = case r.provider of
  OpenAI -> openAiRequest r.model
  Anthropic -> anthropicRequest r.model
  Scripted -> anthropicRequest r.model

-- | Why an edit was not made, for the conversation.
refusalWords :: Refusal -> Text
refusalWords = \case
  NotFound _ -> "the page has no such text"
  FoundMany _ n -> "the text is there " <> show n <> " times"
  EmptyQuote -> "it quoted nothing"
  UnknownTool _ -> "there is no such tool"
  Malformed _ -> "its input was not what the tool takes"

changesWord :: Int -> Text
changesWord 1 = "1 suggested change"
changesWord n = show n <> " suggested changes"
