-- | The writing assistant's providers, models and settings, and the
-- messages it shows when a provider refuses a request (WP4.19 of
-- docs/PLAN.md, decision 21).
--
-- The assistant is bring-your-own-key. The user pastes an API key per
-- provider into the assistant's settings. The browser stores the key under
-- the user's id and sends it only to that provider; the wiki's server
-- never sees it. The stored value is 'Settings': the chosen provider, and
-- for each provider its key, if one was given, the chosen model, if any,
-- and the provider's model list as last fetched with the key.
--
-- The models offered are the provider's own list, fetched with the key
-- (@GET /v1/models@) and stored with the time of the fetch, grouped
-- ('groupModels') into the recommended models and all the others. Without
-- a fetched list (no key yet, no network, an error) the models offered are
-- the short list in this module ('models'), which also gives names to the
-- ids it knows.
--
-- The prompt, the tools and the page's context are in
-- "Wiki.Core.Assistant.Prompt"; the edits a model makes through its tools,
-- and the changes the author accepts or rejects, are in
-- "Wiki.Core.Assistant.Edit".
module Wiki.Core.Assistant
  ( -- * Providers and models
    Provider (..)
  , providers
  , providerKey
  , providerFromKey
  , providerLabel
  , keyPage
  , Model (..)
  , models
  , defaultModel
  , Listed (..)
  , ModelList (..)
  , ModelChoices (..)
  , groupModels
  , modelChoices
  , chosenModel
  , modelLabel
  , listStale
  , efforts
  , defaultEffort
  , effortOf

    -- * Settings
  , Settings (..)
  , ProviderSettings (..)
  , defaultSettings
  , blankSettings
  , settingsOf
  , withKey
  , withModel
  , withEffort
  , withModels
  , withBaseUrl
  , withReached
  , chooseProvider
  , baseUrlOf
  , insecureUrl
  , usable
  , serviceName
  , Ready (..)
  , ready
  , readyFor

    -- * Errors
  , ErrorKind (..)
  , AssistantError (..)
  , errorText
  , redact
  )
where

import Control.Monad (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Pair, Parser)
import Data.List (elemIndex, nubBy)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, diffUTCTime, nominalDay)
import Protolude

-- | 'Provider': the service the assistant sends requests to. 'Scripted' is
-- not a real provider: it is the scripted provider that the browser tests
-- (and the demo's smoke test) install before the program starts, and it
-- replays the responses it is given. The settings offer it only where it
-- is installed, which is never the case on a page served to the public.
data Provider = Anthropic | OpenAI | Scripted
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The providers a user may choose from: the real ones, and the scripted
-- one where it is installed.
providers :: Bool -> [Provider]
providers scripted = [Anthropic, OpenAI] <> [Scripted | scripted]

-- | A provider's name where it is stored and sent: in the settings' JSON
-- and to the browser-side JavaScript.
providerKey :: Provider -> Text
providerKey = \case
  Anthropic -> "anthropic"
  OpenAI -> "openai"
  Scripted -> "scripted"

providerFromKey :: Text -> Maybe Provider
providerFromKey k = find ((== k) . providerKey) [minBound .. maxBound]

providerLabel :: Provider -> Text
providerLabel = \case
  Anthropic -> "Anthropic (Claude)"
  OpenAI -> "OpenAI"
  Scripted -> "Scripted (for tests)"

-- | The URL of the page where a provider's API keys are created, for the settings' hint.
keyPage :: Provider -> Maybe Text
keyPage = \case
  Anthropic -> Just "https://platform.claude.com/settings/keys"
  OpenAI -> Just "https://platform.openai.com/api-keys"
  Scripted -> Nothing

-- | 'Model': a model a provider offers, by the id its API takes and the
-- name it is shown with.
data Model = Model
  { id :: Text
  , label :: Text
  }
  deriving stock (Eq, Show)

-- | The models offered for a provider when there is no fetched list
-- ('modelChoices': no key yet, no network, an error), the newest general
-- models first, the first one the default; also the names of these ids,
-- wherever they are shown ('modelLabel'). The user can type in any other
-- model the provider accepts.
--
-- Taken on 2026-10-27 from the providers' own lists: Anthropic's "Models
-- overview" (platform.claude.com/docs/en/about-claude/models/overview),
-- which recommends Claude Opus 5.5 to start with, and OpenAI's "Models"
-- (developers.openai.com/api/docs/models), whose flagship models are the
-- GPT-6 family. The order of the model families here (Opus first, Sol
-- first) is also the order in which a fetched list's recommended models
-- are offered ('groupModels'), so that its first model, the default, is
-- of the same family as this list's first.
models :: Provider -> [Model]
models = \case
  Anthropic ->
    [ Model "claude-opus-5-5" "Claude Opus 5.5"
    , Model "claude-sonnet-5-5" "Claude Sonnet 5.5"
    , Model "claude-haiku-5-5" "Claude Haiku 5.5"
    , Model "claude-fable-5-1" "Claude Fable 5.1"
    ]
  OpenAI ->
    [ Model "gpt-6.1-sol" "GPT-6.1 Sol"
    , Model "gpt-6.1-terra" "GPT-6.1 Terra"
    , Model "gpt-6-astra" "GPT-6 Astra"
    , Model "gpt-6-luna" "GPT-6 Luna"
    ]
  Scripted -> [Model "scripted" "Its script"]

-- | The default model of the short list: the model used when none was
-- chosen and there is no fetched list.
defaultModel :: Provider -> Text
defaultModel p = maybe "" (\m -> m.id) (head (models p))

-- | 'Listed': a model as a provider's list gives it. It holds its id, the
-- name the provider shows it with, if any (Anthropic gives one, OpenAI
-- does not), and its creation time, in seconds since 1970, if given.
data Listed = Listed
  { id :: Text
  , label :: Maybe Text
  , created :: Maybe Int64
  }
  deriving stock (Eq, Show)

instance ToJSON Listed where
  toJSON l = object (["id" .= l.id] <> maybe [] (\x -> ["label" .= x]) l.label <> maybe [] (\x -> ["created" .= x]) l.created)

instance FromJSON Listed where
  parseJSON = withObject "Listed" $ \o -> Listed <$> o .: "id" <*> o .:? "label" <*> o .:? "created"

-- | 'ModelList': a provider's model list as it was fetched with the user's
-- key, and the time of the fetch.
data ModelList = ModelList
  { listed :: [Listed]
  , fetchedAt :: UTCTime
  }
  deriving stock (Eq, Show)

-- | 'ModelChoices': what the model pickers offer. The recommended models,
-- the first of them the default, and all the other chat models of the
-- provider. The pickers also accept any other id typed in.
data ModelChoices = ModelChoices
  { recommended :: [Model]
  , others :: [Model]
  }
  deriving stock (Eq, Show)

-- | A provider's list grouped for the pickers. The function is pure and
-- uses only the list, so that a model a provider adds is offered without
-- a change here.
--
-- Anthropic's models are all chat models. The recommended ones are, for
-- each family (the id's second part: @opus@, @sonnet@, @haiku@, @fable@),
-- the newest by creation time among the ids without a date at the end (a
-- dated id is a snapshot of an undated one, or an older model). All the
-- others follow, newest first.
--
-- OpenAI's list has every model it serves: speech, images, embeddings and
-- the rest. Only ids starting with @gpt-@ are kept, and among them none
-- with a marker of a model for something other than chat (@audio@,
-- @realtime@, @tts@, @transcribe@, @search@, @image@, @instruct@,
-- @embedding@, @moderation@, @codex@, @chat-latest@) or of a dated
-- snapshot (@-20@). The recommended ones are those of the newest
-- generation present (the version after @gpt-@: 6.1 before 6, 6 before
-- 5.1), and the @-mini@ and @-nano@ models of its major version
-- (@gpt-5-mini@ next to @gpt-5.1@). All the others follow, newest first by
-- creation time, then by id in descending order.
--
-- The recommended models are offered family by family in the order of the
-- short list ('models': Opus, Sonnet, Haiku, Fable; Sol, Terra, Astra,
-- Luna), with families not in the short list after those, so that the
-- default, the first, is of the same family as the short list's default.
-- The scripted provider's list is grouped like Anthropic's, since it
-- receives Anthropic's request.
--
-- The list of a service other than OpenAI that implements OpenAI's API
-- (the 'Bool', see 'baseUrlOf') has models with names of its own, and is
-- not filtered: all its models are offered, newest first, and the
-- recommended ones are only those of the short list it has, if any.
groupModels :: Provider -> Bool -> [Listed] -> ModelChoices
groupModels p elsewhere listing =
  ModelChoices
    { recommended = map (named p) (sortOn rank picked)
    , others = map (named p) (sortOn newest [l | l <- kept, l.id `notElem` map (\r -> r.id) picked])
    }
  where
    unique = nubBy (\a b -> a.id == b.id) listing
    kept = case p of
      OpenAI | not elsewhere -> filter (forChat . (\l -> l.id)) unique
      _ -> unique
    picked = case p of
      _ | elsewhere -> [l | l <- kept, isJust (knownLabel p l.id)]
      OpenAI ->
        let versions = mapMaybe (\l -> gptVersion l.id) kept
            newestVersion = maximumMay versions
            major = take 1 <$> newestVersion
            small l = variant l.id `elem` ["mini", "nano"] && (take 1 <$> gptVersion l.id) == major
         in [l | l <- kept, isJust newestVersion && gptVersion l.id == newestVersion || small l]
      _ ->
        mapMaybe
          (head . sortOn newest)
          (Map.elems (Map.fromListWith (<>) [(variant l.id, [l]) | l <- kept, not (dated l.id)]))
    rank l = (fromMaybe (length known) (elemIndex (variant l.id) known), newest l)
    known = ordNub (map (variant . (\m -> m.id)) (models p))
    newest l = (Down l.created, Down l.id)
    variant i = case p of
      OpenAI -> T.dropWhile (== '-') (T.dropWhile (\c -> isDigit c || c == '.') (T.drop 4 i))
      _ -> fromMaybe i (atMay (T.splitOn "-" i) 1)
    dated i = case lastMay (T.splitOn "-" i) of
      Just end -> T.length end == 8 && T.all isDigit end
      Nothing -> False
    forChat i = "gpt-" `T.isPrefixOf` i && not (any (`T.isInfixOf` i) notForChat)
    notForChat = ["audio", "realtime", "tts", "transcribe", "search", "image", "instruct", "embedding", "moderation", "codex", "chat-latest", "-20"]

-- | The version numbers in an OpenAI model's id: @[6, 1]@ for
-- @gpt-6.1-sol@, @[4]@ for @gpt-4o@.
gptVersion :: Text -> Maybe [Int]
gptVersion i = case T.splitOn "." (T.takeWhile (\c -> isDigit c || c == '.') (T.drop 4 i)) of
  parts | all (not . T.null) parts -> traverse readMaybe parts
  _ -> Nothing

-- | A listed model with its name: the short list's name for an id it knows
-- (those are the names the rest of the wiki uses), else the provider's
-- own name, else its id.
named :: Provider -> Listed -> Model
named p l = Model l.id (fromMaybe l.id (knownLabel p l.id <|> l.label))

knownLabel :: Provider -> Text -> Maybe Text
knownLabel p i = (\m -> m.label) <$> find (\m -> m.id == i) (models p)

-- | What the pickers offer for a provider: its own fetched list, grouped,
-- if there is one and it recommends anything (for another service, if it
-- has any model); else the whole short list, all recommended.
modelChoices :: Provider -> ProviderSettings -> ModelChoices
modelChoices p ps = case groupModels p elsewhere . (\l -> l.listed) <$> ps.fetched of
  Just grouped | not (null grouped.recommended) || elsewhere && not (null grouped.others) -> grouped
  _ -> ModelChoices {recommended = models p, others = []}
  where
    elsewhere = isJust (baseUrlOf p ps)

-- | The model to use: the chosen one, or else the first one offered
-- ('modelChoices'), which is a recommended one if there is one.
chosenModel :: Provider -> ProviderSettings -> Text
chosenModel p ps = fromMaybe (maybe (defaultModel p) (\m -> m.id) (head (choices.recommended <> choices.others))) ps.model
  where
    choices = modelChoices p ps

-- | The name a model is shown with: its name in the pickers, or its id.
modelLabel :: Provider -> ProviderSettings -> Text -> Text
modelLabel p ps i =
  maybe i (\m -> m.label) (find (\m -> m.id == i) (choices.recommended <> choices.others))
  where
    choices = modelChoices p ps

-- | Whether a provider's model list should be fetched: there is none, or
-- it is more than a day old (a provider adds a model every few months, and
-- each fetch costs a request).
listStale :: UTCTime -> ProviderSettings -> Bool
listStale now ps = maybe True (\l -> diffUTCTime now l.fetchedAt > nominalDay) ps.fetched

-- | The reasoning efforts a provider's models accept, lowest first:
-- Anthropic's @output_config.effort@ (its Claude 5 models think
-- adaptively, as much as the effort asks), OpenAI's @reasoning.effort@.
-- The scripted provider receives Anthropic's request.
efforts :: Provider -> [Text]
efforts = \case
  Anthropic -> ["low", "medium", "high", "xhigh", "max"]
  OpenAI -> ["minimal", "low", "medium", "high"]
  Scripted -> efforts Anthropic

-- | The effort a new conversation starts with when the user has chosen
-- none in the settings: medium, for both providers. The owner found low
-- too shallow for editing a whole page. The settings page changes it per
-- provider ('withEffort'), and the chat's picker changes it for one
-- conversation.
defaultEffort :: Text
defaultEffort = "medium"

-- | The effort a new conversation with a provider starts with: the one
-- chosen in the settings, or else 'defaultEffort'.
effortOf :: ProviderSettings -> Text
effortOf ps = fromMaybe defaultEffort ps.effort

-- | 'ProviderSettings': what a user has set for one provider.
data ProviderSettings = ProviderSettings
  { key :: Maybe Text
  -- ^ The API key, if one was given.
  , model :: Maybe Text
  -- ^ The chosen model, if any ('chosenModel').
  , effort :: Maybe Text
  -- ^ The effort chosen for new conversations ('efforts'), if any.
  -- 'Nothing' means 'defaultEffort' ('effortOf').
  , baseUrl :: Maybe Text
  -- ^ The base URL requests go to, if not the provider's own: for OpenAI,
  -- any service that implements its API ('baseUrlOf').
  , fetched :: Maybe ModelList
  -- ^ The provider's model list, as last fetched with the key.
  , unreachable :: Bool
  -- ^ Whether the last request to the provider got no response at all, as
  -- when a network blocks its address. Any response, including a refusal,
  -- clears it.
  }
  deriving stock (Eq, Show)

-- | 'Settings': what a user has set. The provider the assistant uses, and
-- each provider's key, model and effort.
data Settings = Settings
  { provider :: Provider
  , byProvider :: Map Provider ProviderSettings
  }
  deriving stock (Eq, Show)

-- | The settings before anything is set: Anthropic, with no key and no model chosen.
defaultSettings :: Settings
defaultSettings = Settings {provider = Anthropic, byProvider = mempty}

-- | The settings of a provider before anything is set.
noSettings :: ProviderSettings
noSettings = ProviderSettings {key = Nothing, model = Nothing, effort = Nothing, baseUrl = Nothing, fetched = Nothing, unreachable = False}

-- | Whether settings are the same as 'defaultSettings': no key, the first
-- provider, no model chosen, no effort chosen, no base URL of another
-- service, and nothing learnt about a provider. Such settings need not be
-- stored.
blankSettings :: Settings -> Bool
blankSettings s = s.provider == Anthropic && all (== noSettings) (Map.elems s.byProvider)

-- | A provider's settings, with its defaults where nothing was set.
settingsOf :: Provider -> Settings -> ProviderSettings
settingsOf p s = Map.findWithDefault noSettings p s.byProvider

-- | The settings with one provider's settings changed. (The function
-- builds the 'ProviderSettings' whole, by position, because its field
-- names are shared with 'Ready''s, which makes a record update ambiguous.)
alter :: Provider -> (ProviderSettings -> ProviderSettings) -> Settings -> Settings
alter p f s = s {byProvider = Map.insert p (f (settingsOf p s)) s.byProvider}

-- | The settings with a provider's key set, or removed ("Forget"). A key is
-- stored as pasted, except for surrounding spaces and line breaks, which a
-- copy often adds and no key contains. What was learnt with the replaced
-- key (its model list, whether the provider could be reached) is
-- discarded with it: a new key may belong to another account, with other
-- models.
withKey :: Provider -> Maybe Text -> Settings -> Settings
withKey p k = alter p $ \(ProviderSettings old m e b f u) ->
  let new = trimmed k
   in if new == old then ProviderSettings old m e b f u else ProviderSettings new m e b Nothing False

-- | The settings with a provider's model set; an empty one means none chosen, the default.
withModel :: Provider -> Text -> Settings -> Settings
withModel p m = alter p $ \(ProviderSettings k _ e b f u) -> ProviderSettings k (trimmed (Just m)) e b f u

-- | The settings with a provider's default effort for new conversations
-- set. The default itself, or an effort the provider does not offer, is
-- stored as no effort chosen. So settings that hold only the default stay
-- blank, and a later change of 'defaultEffort' reaches them.
withEffort :: Provider -> Text -> Settings -> Settings
withEffort p e = alter p $ \(ProviderSettings k m _ b f u) -> ProviderSettings k m (if e `elem` efforts p && e /= defaultEffort then Just e else Nothing) b f u

-- | The settings with a provider's base URL set ('baseUrlOf'), an empty
-- one meaning the provider's own. What was learnt at the old URL is
-- discarded, as with a key.
withBaseUrl :: Provider -> Text -> Settings -> Settings
withBaseUrl p url = alter p $ \(ProviderSettings k m e old f u) ->
  let new = T.dropWhileEnd (== '/') <$> trimmed (Just url)
   in if new == old then ProviderSettings k m e old f u else ProviderSettings k m e new Nothing False

-- | The settings with a provider's model list, fetched at the given time.
-- A fetched list also means the provider was reached.
withModels :: Provider -> [Listed] -> UTCTime -> Settings -> Settings
withModels p listing at = alter p $ \(ProviderSettings k m e b _ _) -> ProviderSettings k m e b (Just (ModelList listing at)) False

-- | The settings with whether the last request to a provider reached it.
withReached :: Provider -> Bool -> Settings -> Settings
withReached p reached = alter p $ \(ProviderSettings k m e b f _) -> ProviderSettings k m e b f (not reached)

trimmed :: Maybe Text -> Maybe Text
trimmed = mfilter (not . T.null) . fmap T.strip

chooseProvider :: Provider -> Settings -> Settings
chooseProvider p s = Settings {provider = p, byProvider = s.byProvider}

-- | The base URL of a service other than OpenAI that implements OpenAI's
-- API (Azure OpenAI, GitHub Models, OpenRouter, a server on this machine
-- such as Ollama or LM Studio). Only OpenAI's settings have one.
baseUrlOf :: Provider -> ProviderSettings -> Maybe Text
baseUrlOf p ps = if p == OpenAI then ps.baseUrl else Nothing

-- | Whether a URL is plain HTTP to a machine other than this one, which
-- anyone on the network path can read: a key sent there is no longer
-- private to the user. HTTP to this machine (a local server) is not.
insecureUrl :: Text -> Bool
insecureUrl url = case T.stripPrefix "http://" (T.toLower (T.strip url)) of
  Nothing -> False
  Just rest -> hostOf rest `notElem` ["localhost", "127.0.0.1", "[::1]"]
  where
    hostOf rest =
      let authority = T.takeWhile (`notElem` ("/?#" :: [Char])) rest
          afterUser = snd (T.breakOnEnd "@" authority)
       in if "[" `T.isPrefixOf` afterUser then T.takeWhile (/= ']') afterUser <> "]" else T.takeWhile (/= ':') afterUser

-- | Whether requests can be sent to a provider: always to the scripted
-- one, to another with a key, and also without a key to OpenAI's API at
-- another base URL (a server on this machine needs none).
usable :: Provider -> ProviderSettings -> Bool
usable p ps = p == Scripted || isJust ps.key || isJust (baseUrlOf p ps)

-- | The service named in a message saying the provider cannot be reached:
-- the provider, or the host of its other base URL.
serviceName :: Provider -> ProviderSettings -> Text
serviceName p ps = case baseUrlOf p ps of
  Just url -> T.takeWhile (`notElem` ("/?#" :: [Char])) (snd (T.breakOnEnd "://" url))
  Nothing -> case p of
    Anthropic -> "Anthropic"
    OpenAI -> "OpenAI"
    Scripted -> "the scripted provider"

-- | 'Ready': what a request needs. The provider, the model, the key (empty
-- for a server that needs none), the effort, and the base URL of another
-- service, if one is used.
data Ready = Ready
  { provider :: Provider
  , model :: Text
  , key :: Text
  , effort :: Text
  , baseUrl :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | The chosen provider, its model and its key; or a message to the user
-- saying what is missing.
ready :: Settings -> Either Text Ready
ready s = readyFor s.provider s

-- | A provider, its model and its key, whether or not it is the chosen
-- provider (its model list is fetched with them); or what is missing.
readyFor :: Provider -> Settings -> Either Text Ready
readyFor p s
  | usable p ps = Right Ready {provider = p, model = chosenModel p ps, key = fromMaybe "" ps.key, effort = effortOf ps, baseUrl = baseUrlOf p ps}
  | otherwise = Left ("There is no API key for " <> providerLabel p <> " yet: add one in the assistant's settings.")
  where
    ps = settingsOf p s

-- | Stored as one JSON object: the chosen provider, and an object per
-- provider that has settings, under its 'providerKey'. Each has its
-- @key@ and @model@, its @defaultEffort@ when one was chosen, its
-- @baseUrl@, its model list as @models@ with the fetch time as
-- @modelsAt@, and @unreachable@ when it is set.
--
-- The effort is stored as @defaultEffort@. Settings stored before WP5.11
-- have an @effort@ field instead. That field held the effort last picked
-- in the chat, or the old default, low, for every provider. It is not
-- read: such settings read as the new default, medium, until the user
-- chooses an effort on the settings page.
instance ToJSON Settings where
  toJSON s =
    object $
      ("provider" .= providerKey s.provider)
        : [ Key.fromText (providerKey p) .= object (["key" .= ps.key, "model" .= ps.model] <> learnt ps)
          | (p, ps) <- Map.toList s.byProvider
          ]
    where
      learnt :: ProviderSettings -> [Pair]
      learnt ps =
        maybe [] (\e -> ["defaultEffort" .= e]) ps.effort
          <> maybe [] (\u -> ["baseUrl" .= u]) ps.baseUrl
          <> maybe [] (\l -> ["models" .= l.listed, "modelsAt" .= l.fetchedAt]) ps.fetched
          <> ["unreachable" .= True | ps.unreachable]

instance FromJSON Settings where
  parseJSON = withObject "Settings" $ \o -> do
    provider <- o .: "provider" >>= providerFrom
    byProvider <- fmap (Map.fromList . catMaybes) . for [minBound .. maxBound] $ \p ->
      o .:? Key.fromText (providerKey p) >>= traverse (fmap (p,) . providerSettings)
    pure Settings {provider, byProvider}
    where
      providerFrom :: Text -> Parser Provider
      providerFrom k = maybe (fail ("no such provider: " <> toS k)) pure (providerFromKey k)
      -- A field missing in settings stored before the field existed gets its default.
      providerSettings = withObject "ProviderSettings" $ \o -> do
        listing <- o .:? "models"
        at <- o .:? "modelsAt"
        ProviderSettings
          <$> o
          .:? "key"
          <*> o .:? "model"
          <*> o .:? "defaultEffort"
          <*> o .:? "baseUrl"
          <*> pure (ModelList <$> listing <*> at)
          <*> (o .:? "unreachable" .!= False)

-- | 'ErrorKind': what went wrong with a request, as the provider's SDK classifies it.
data ErrorKind
  = -- | The key was refused (401).
    BadKey
  | -- | The key may not do this (403).
    NotAllowed
  | -- | No such model, or the key may not use it (404).
    NoSuchModel
  | -- | Too many requests, or the account's credit or limits are exhausted (429).
    RateLimited
  | -- | The provider is overloaded or failing (5xx).
    Overloaded
  | -- | The provider could not be reached: a network error, or a timeout.
    Unreachable
  | -- | The model declined to answer (Anthropic's @refusal@).
    Declined
  | -- | The request was refused as malformed (400, 422).
    BadRequest
  | -- | Anything else.
    Failed
  deriving stock (Eq, Show, Enum, Bounded)

-- | 'AssistantError': an error as the browser-side JavaScript reports it.
-- It holds the error's kind, the HTTP status if there was a response, and
-- the provider's own message.
data AssistantError = AssistantError
  { kind :: ErrorKind
  , status :: Maybe Int
  , message :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON AssistantError where
  parseJSON = withObject "AssistantError" $ \o ->
    AssistantError <$> (o .: "kind" >>= kindOf) <*> o .:? "status" <*> (o .:? "message" .!= "")
    where
      kindOf = withText "ErrorKind" $ \case
        "authentication" -> pure BadKey
        "permission" -> pure NotAllowed
        "not_found" -> pure NoSuchModel
        "rate_limit" -> pure RateLimited
        "overloaded" -> pure Overloaded
        "connection" -> pure Unreachable
        "refusal" -> pure Declined
        "bad_request" -> pure BadRequest
        _ -> pure Failed

-- | The message the panel and the settings show for an error: what it
-- means, then the provider's own message and the status, with the key
-- removed ('redact') wherever it appears, since a provider may quote it.
errorText :: Maybe Text -> AssistantError -> Text
errorText key e =
  meaning <> (if T.null said then "" else " The provider said: " <> said) <> maybe "" (\s -> " (" <> show s <> ")") e.status
  where
    said = redact key (T.strip e.message)
    meaning = case e.kind of
      BadKey -> "The provider did not accept the key."
      NotAllowed -> "The key may not do this."
      NoSuchModel -> "The provider has no such model, or the key may not use it."
      RateLimited -> "The provider is limiting requests, or the account's credit or limits are used up."
      Overloaded -> "The provider is overloaded or failing; try again in a while."
      Unreachable -> "The provider could not be reached."
      Declined -> "The model declined to answer."
      BadRequest -> "The provider refused the request."
      Failed -> "The request failed."

-- | A message with the key removed: the key itself, wherever it appears,
-- and anything that looks like a key or a part of one (a word starting
-- with @sk-@, as both providers' keys do, which a provider may quote
-- masked except for its ends).
redact :: Maybe Text -> Text -> Text
redact key = T.intercalate " " . map hideWord . T.splitOn " " . maybe identity hideKey key
  where
    hideKey k
      | T.length k < 4 = identity
      | otherwise = T.replace k "[your key]"
    hideWord w = case T.breakOn "sk-" w of
      (before, rest) | not (T.null rest) -> before <> "[a key]" <> T.dropWhile keyChar (T.drop 3 rest)
      _ -> w
    keyChar c = isAlphaNum c || c `elem` ("-_*." :: [Char])
