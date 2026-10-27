{-# LANGUAGE QuasiQuotes #-}

-- | The writing assistant's panel in the editor (WP4.19 of docs/PLAN.md):
-- a chat with a model that edits the page, as code editors have them.
--
-- The panel is a list of messages, the user's and the model's (streamed
-- as they come), under it a row of shortcuts that fill the message in
-- (improve, fix grammar, shorten, expand, summarise, continue, translate),
-- and the message box, with the provider's model and effort under it
-- (kept per provider with the user's settings, and taking effect from the
-- next message), and Send, or Stop while the model is at work. Enter
-- sends, Shift+Enter starts a new line. The editor's buttons open it with
-- a provider ('UseProvider'); another provider than the conversation's
-- starts a new conversation.
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
-- The user's settings are the editor's, which reads them, keeps them as
-- the panel changes them ('ChangeSettings'), and asks each provider with a key
-- for its list of models when it opens. Without a key for the provider
-- chosen, the panel says where to add one. The models it offers are the
-- provider's own list, grouped into the recommended ones and all the
-- others ("Wiki.Core.Assistant"'s 'Wiki.Core.Assistant.modelChoices'), or
-- the short one the wiki has until there is a list. A provider that could
-- not be reached the last time it was asked (a network that blocks it)
-- is said to be so, with "Try again" ('Retry'); a message that gets an
-- answer says that it can be reached again, one that gets none that it
-- cannot ('Reached').
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
import Data.Set qualified as Set
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
import Wiki.App.Editor.Browser (currentText, focusElement, proposeEdit, trackedChanges)
import Wiki.App.Route (Route (AssistantSettings))
import Wiki.App.View.Common (Context (..), attr)
import Wiki.Core.Assistant
  ( AssistantError (kind)
  , ErrorKind (Unreachable)
  , Model (..)
  , ModelChoices (..)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (..)
  , Settings (..)
  , baseUrlOf
  , chosenModel
  , efforts
  , errorText
  , modelChoices
  , modelLabel
  , providerLabel
  , ready
  , serviceName
  , settingsOf
  , withEffort
  , withModel
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

-- | What the editor tells the panel: where the page's text is, its title
-- and Markdown now, what is selected in it, and how many of the
-- assistant's changes are left to decide.
data Input = Input
  { context :: Context
  , settings :: Maybe (Either Text Settings)
  -- ^ The user's settings, once the editor has read them.
  , problem :: Maybe Text
  -- ^ Why a change of them could not be kept, if it could not.
  , checking :: Set Provider
  -- ^ The providers the editor is asking for their list of models.
  , host :: Maybe Element
  -- ^ CodeMirror's host: the editor's text ("Wiki.App.Editor.Browser").
  , title :: Text
  , body :: Text
  , selection :: Maybe Span
  , pending :: Int
  , decisions :: Map Int Decision
  -- ^ What the author decided of the assistant's changes, by id.
  }

-- | The panel was closed: the model's turn, if one is running, stops. Or
-- it was opened with a provider (the editor's buttons for each), which
-- the editor makes the one the assistant asks: if the conversation was
-- with another, it ends, and a new one starts with the next message
-- (a conversation cannot go from one provider to another: Anthropic's
-- thinking blocks mean nothing to OpenAI). The changes made by then stay,
-- to decide: they are the editor's, not the conversation's.
data Query a = Hide a | UseProvider Provider a

-- | The panel's own close button; "Accept all" or "Reject all", which the
-- editor carries out, as it does a decision on one change; a change of the
-- settings (a model, an effort), which the editor keeps; "Try again" for a
-- provider that could not be reached; and whether a message reached its
-- provider.
data Output
  = Closed
  | DecideAll Decision
  | ChangeSettings (Settings -> Settings)
  | Retry Provider
  | Reached Provider Bool

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
  | -- | What the panel says of the conversation itself.
    Notice Text

data Note = Made Text | NotMade Text Text

data Ending = Streaming | Ended | Stopped
  deriving stock (Eq)

data State = State
  { input :: Input
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
  , otherModel :: Bool
  -- ^ Whether "Other…" is chosen for the model, which shows its field.
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
  | ChooseModel Text
  | TypedModel Text
  | ChooseEffort Text
  | TryAgain Provider

component :: forall m. (MonadAssistant m, MonadUUID m, MonadIO m) => H.Component Query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          field <- H.newRefLabel "assistant-message"
          pure
            State
              { input
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
              , otherModel = False
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
            {{ choicesView st }}
            <div class="assistant-send-row">
              {% if st.talking %}
                <button type="button" class="assistant-stop" onClick={{ const Stop }}>Stop</button>
              {% else %}
                <button type="button" class="primary assistant-send" disabled={{ T.null (T.strip st.message) }} onClick={{ const Send }}>Send</button>
              {% end %}
            </div>
          </div>
        </section>
      |]

    -- The model and the effort of the provider the assistant asks, under the
    -- message: the provider's own, kept in its settings (the settings page
    -- shows the same model), taking effect from the next message. The
    -- models are grouped: the recommended ones, all the others the provider
    -- has for a chat, and "Other…", any id typed in.
    choicesView :: State -> Maybe (H.ComponentHTML Action Empty m)
    choicesView st = case st.input.settings of
      Just (Right s) ->
        let ps = settingsOf s.provider s
            choices = modelChoices s.provider ps
            chosen = chosenModel s.provider ps
            listed = chosen `elem` map (\m -> m.id) (choices.recommended <> choices.others)
            other = st.otherModel || not listed
            option m = [hh|<option value={{ m.id }} selected={{ not other && chosen == m.id }}>{{ m.label }}</option>|]
         in Just
              [hh|
                <div class="assistant-choices">
                  <label class="assistant-choice">
                    <span>Model</span>
                    <select class="assistant-model-choice" disabled={{ st.talking }} onValueChange={{ ChooseModel }}>
                      {% if not (null choices.recommended) %}
                        <optgroup label="Recommended">
                          {% for m in choices.recommended %}
                            {{ option m }}
                          {% end %}
                        </optgroup>
                      {% end %}
                      {% if not (null choices.others) %}
                        <optgroup label="All models">
                          {% for m in choices.others %}
                            {{ option m }}
                          {% end %}
                        </optgroup>
                      {% end %}
                      <option value="" selected={{ other }}>Other…</option>
                    </select>
                  </label>
                  {% if other %}
                    <input type="text" class="assistant-model-other" spellcheck="false" aria-label="The model's id" placeholder="A model's id" value={{ if listed then "" else chosen }} disabled={{ st.talking }} onValueChange={{ TypedModel }}>
                  {% end %}
                  <label class="assistant-choice">
                    <span>Effort</span>
                    <select class="assistant-effort" disabled={{ st.talking }} onValueChange={{ ChooseEffort }}>
                      {% for e in efforts s.provider %}
                        <option value={{ e }} selected={{ ps.effort == e }}>{{ e }}</option>
                      {% end %}
                    </select>
                  </label>
                </div>
              |]
      _ -> Nothing

    -- Enter sends; any other key is the message box's.
    sendKey :: Event -> Maybe Action
    sendKey ev = if sendsMessage ev then Just Send else Nothing

    usingLine :: State -> Text
    usingLine st = case st.input.settings of
      Just (Right s) ->
        let ps = settingsOf s.provider s
            -- Another service than OpenAI's own is named by its address.
            service = if isJust (baseUrlOf s.provider ps) then serviceName s.provider ps else providerLabel s.provider
         in modelLabel s.provider ps (chosenModel s.provider ps) <> " \183 " <> service
      _ -> ""

    setupNote :: State -> Maybe (H.ComponentHTML Action Empty m)
    setupNote st = case st.input.settings of
      Nothing -> Just [hh|<p class="loading">Loading your settings…</p>|]
      Just (Left why) -> Just [hh|<p class="error assistant-setup" role="alert">{{ why }}</p>|]
      Just (Right s)
        | (settingsOf s.provider s).unreachable ->
            let ps = settingsOf s.provider s
             in Just
                  [hh|
                    <p class="assistant-setup assistant-unreachable" role="alert">
                      Cannot reach {{ serviceName s.provider ps }} from this network.
                      <button type="button" class="assistant-try-again" disabled={{ Set.member s.provider st.input.checking }} onClick={{ const (TryAgain s.provider) }}>Try again</button>
                    </p>
                  |]
        | Just why <- st.input.problem -> Just [hh|<p class="error assistant-setup" role="alert">{{ why }}</p>|]
      Just (Right s) -> case ready s of
        Left why ->
          Just
            [hh|
              <p class="assistant-setup">
                {{ why <> " " }}
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
      Notice what -> [hh|<p class="assistant-notice" role="status">{{ what }}</p>|]

    noteView :: Note -> H.ComponentHTML Action Empty m
    noteView = \case
      Made what -> [hh|<li class="assistant-made">{{ what }}</li>|]
      NotMade what why -> [hh|<li class="assistant-not-made">{{ what }}: not made, {{ why }}</li>|]

    handleQuery :: Query a -> H.HalogenM State Action Empty Output m (Maybe a)
    handleQuery = \case
      Hide next -> stop $> Just next
      UseProvider p next -> useProvider p $> Just next

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Initialize -> do
        H.liftEffect prepareAssistant
        channel <- liftIO HS.create
        void (H.subscribe (FromTalk <$> channel.emitter))
        modify (\st -> st {listener = Just channel.listener})
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
      ChooseModel "" -> modify (\st -> st {otherModel = True})
      ChooseModel m -> do
        modify (\st -> st {otherModel = False})
        changeSettings (\s -> withModel s.provider m s)
      TypedModel m -> unless (T.null (T.strip m)) $ changeSettings (\s -> withModel s.provider m s)
      ChooseEffort e -> changeSettings (\s -> withEffort s.provider e s)
      TryAgain p -> H.raise (Retry p)

    -- The provider the editor's button asked for (which the editor makes
    -- the one the assistant asks): if the conversation was with another,
    -- it ends, and a new one starts with the next message.
    useProvider :: Provider -> H.HalogenM State Action Empty Output m ()
    useProvider p = do
      st <- get
      for_ st.using $ \r -> when (r.provider /= p) $ do
        -- The chat closed stops its turn, and is heard of no more.
        for_ st.talk (H.liftEffect . closeTalk)
        when st.talking (finish Stopped)
        modify (\s' -> s' {talk = Nothing, using = Nothing, otherModel = False})
        addEntry (Notice ("The conversation with " <> providerLabel r.provider <> " ended. The next message starts a new one with " <> providerLabel p <> "."))

    -- Change the user's settings: the editor keeps them.
    changeSettings :: (Settings -> Settings) -> H.HalogenM State Action Empty Output m ()
    changeSettings = H.raise . ChangeSettings

    stop :: H.HalogenM State Action Empty Output m ()
    stop = do
      st <- get
      when st.talking $ traverse_ (H.liftEffect . stopTalk) st.talk

    send :: H.HalogenM State Action Empty Output m ()
    send = do
      st <- get
      let text = T.strip st.message
      unless (st.talking || T.null text) $ case (st.input.settings, st.input.host) of
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
            H.liftEffect (sayTo talk (requestFor r) (userTurn decided context text))
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
      HeardDone -> do
        finish Ended
        reached True
      HeardStopped -> finish Stopped
      HeardFailed e -> do
        finish Ended
        key <- gets (\st -> (\r -> r.key) <$> st.using)
        addEntry (Trouble (errorText key e))
        -- Any answer, a refusal included, is from the provider; none is
        -- that it cannot be reached.
        reached (e.kind /= Unreachable)

    -- Whether the provider of the conversation was reached, told to the
    -- editor when it changes what is known.
    reached :: Bool -> H.HalogenM State Action Empty Output m ()
    reached yes = do
      st <- get
      for_ st.using $ \r -> case st.input.settings of
        Just (Right s) | (settingsOf r.provider s).unreachable == yes -> H.raise (Reached r.provider yes)
        _ -> pass

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
  OpenAI -> openAiRequest r.model r.effort
  Anthropic -> anthropicRequest r.model r.effort
  Scripted -> anthropicRequest r.model r.effort

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
