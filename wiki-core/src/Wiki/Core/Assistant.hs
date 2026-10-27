-- | The writing assistant's providers, models and settings, and what it
-- says when a provider refuses (WP4.19 of docs/PLAN.md, decision 21).
--
-- The assistant is bring-your-own-key: the user pastes an API key per
-- provider into the assistant's settings, which this browser keeps under
-- the user's id and sends to that provider only; the wiki's server never
-- sees it. What is kept is 'Settings': the provider chosen, and for each
-- provider its key, if one was given, the model to use, if one was chosen,
-- and the provider's list of models as it was last fetched with the key.
--
-- The models offered are the provider's own list, fetched with the key
-- (@GET /v1/models@) and kept with the time it was fetched, grouped
-- ('groupModels') into the recommended ones and all the others; without a
-- list (no key yet, no network, an error) they are the short list here
-- ('models'), which also names the ids it knows.
--
-- The prompt, the tools and the page's context are
-- "Wiki.Core.Assistant.Prompt"; the edits a model makes through its tools,
-- and the changes the author accepts or rejects, "Wiki.Core.Assistant.Edit".
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

-- | Whom the assistant asks. 'Scripted' is no provider: it is the scripted
-- one the browser tests (and the demo's smoke test) install before the
-- program starts, which replays what it is given; the settings offer it
-- only where one is installed, which a page served to anyone never has.
data Provider = Anthropic | OpenAI | Scripted
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The providers a user may chooseProvider from: the real ones, and the scripted
-- one where it is installed.
providers :: Bool -> [Provider]
providers scripted = [Anthropic, OpenAI] <> [Scripted | scripted]

-- | How a provider is named where it is kept and sent: in the settings'
-- JSON and to the browser's side.
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

-- | Where a provider's keys are made, for the settings' hint.
keyPage :: Provider -> Maybe Text
keyPage = \case
  Anthropic -> Just "https://platform.claude.com/settings/keys"
  OpenAI -> Just "https://platform.openai.com/api-keys"
  Scripted -> Nothing

-- | A model a provider offers, by the id its API takes and the name it is
-- shown by.
data Model = Model
  { id :: Text
  , label :: Text
  }
  deriving stock (Eq, Show)

-- | The models offered for a provider when there is no list of its own
-- to offer ('modelChoices': no key yet, no network, an error), the newest
-- general ones first, the first of them the default; and the names of the
-- ids they are, wherever those are shown ('modelLabel'). Any other model
-- the provider takes can be typed in instead.
--
-- Read on 2026-10-27 from the providers' own lists: Anthropic's "Models
-- overview" (platform.claude.com/docs/en/about-claude/models/overview),
-- which recommends Claude Opus 5.5 to start with, and OpenAI's "Models"
-- (developers.openai.com/api/docs/models), whose flagship models are the
-- GPT-6 family. The order of their kinds (Opus first, Sol first) is also
-- the order in which a fetched list's recommended models are offered
-- ('groupModels'), so that its first, the default, is of the same kind
-- as this list's.
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

-- | The default of the short list: the model asked when none was chosen
-- and there is no list of the provider's own.
defaultModel :: Provider -> Text
defaultModel p = maybe "" (\m -> m.id) (head (models p))

-- | A model as a provider's list gives it: its id, the name the provider
-- shows it by, if it gives one (Anthropic does, OpenAI does not), and when
-- it was made, in seconds since 1970, if it says.
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

-- | A provider's list of models as it was fetched with the user's key, and
-- when.
data ModelList = ModelList
  { listed :: [Listed]
  , fetchedAt :: UTCTime
  }
  deriving stock (Eq, Show)

-- | What the model pickers offer: the recommended models, the first of them
-- the default, and all the others the provider has for a chat; and then,
-- in the pickers, any other id typed in.
data ModelChoices = ModelChoices
  { recommended :: [Model]
  , others :: [Model]
  }
  deriving stock (Eq, Show)

-- | A provider's list grouped for the pickers. Pure, from the list alone,
-- so that a model a provider adds is offered without a change here.
--
-- Anthropic's models are all chat models. The recommended ones are, for
-- each family (the id's second part: @opus@, @sonnet@, @haiku@, @fable@),
-- its newest by the time it was made, of the ids without a date at the end
-- (a dated id is a snapshot an undated one stands for, or an older model);
-- all the others follow, newest first.
--
-- OpenAI's list has every model it serves: speech, images, embeddings and
-- the rest. Only ids starting @gpt-@ are kept, without the marks of a
-- model for something else than a chat (@audio@, @realtime@, @tts@,
-- @transcribe@, @search@, @image@, @instruct@, @embedding@, @moderation@,
-- @codex@, @chat-latest@) or of a dated snapshot (@-20@). The recommended
-- ones are those of the newest generation present (the version after
-- @gpt-@: 6.1 before 6, 6 before 5.1), and the @-mini@ and @-nano@ of its
-- major version (@gpt-5-mini@ beside @gpt-5.1@); all the others follow,
-- newest first by the time they were made, then by id, last first.
--
-- The recommended ones are offered kind by kind in the order of the short
-- list ('models': Opus, Sonnet, Haiku, Fable; Sol, Terra, Astra, Luna),
-- kinds it does not have after those, so that the default, the first, is
-- the kind the short list's is. The scripted provider's list is grouped as
-- Anthropic's, whose request it is sent.
--
-- The list of another service than OpenAI's own that speaks its API (the
-- 'Bool', 'baseUrlOf'), which has models of its own naming, is not
-- filtered: all its models are offered, newest first, and recommended
-- only those of the short list it has, if any.
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

-- | The version in an OpenAI model's id, as numbers: @[6, 1]@ for
-- @gpt-6.1-sol@, @[4]@ for @gpt-4o@.
gptVersion :: Text -> Maybe [Int]
gptVersion i = case T.splitOn "." (T.takeWhile (\c -> isDigit c || c == '.') (T.drop 4 i)) of
  parts | all (not . T.null) parts -> traverse readMaybe parts
  _ -> Nothing

-- | A listed model with its name: the short list's for an id it knows (its
-- names are the ones the rest of the wiki uses), else the provider's own,
-- else its id.
named :: Provider -> Listed -> Model
named p l = Model l.id (fromMaybe l.id (knownLabel p l.id <|> l.label))

knownLabel :: Provider -> Text -> Maybe Text
knownLabel p i = (\m -> m.label) <$> find (\m -> m.id == i) (models p)

-- | What the pickers offer for a provider: its own list, grouped, if one
-- was fetched and recommends anything (another service's, if it has
-- anything); else the short list, all of it recommended.
modelChoices :: Provider -> ProviderSettings -> ModelChoices
modelChoices p ps = case groupModels p elsewhere . (\l -> l.listed) <$> ps.fetched of
  Just grouped | not (null grouped.recommended) || elsewhere && not (null grouped.others) -> grouped
  _ -> ModelChoices {recommended = models p, others = []}
  where
    elsewhere = isJust (baseUrlOf p ps)

-- | The model asked: the one chosen, or else the first one offered
-- ('modelChoices'), a recommended one if there is one.
chosenModel :: Provider -> ProviderSettings -> Text
chosenModel p ps = fromMaybe (maybe (defaultModel p) (\m -> m.id) (head (choices.recommended <> choices.others))) ps.model
  where
    choices = modelChoices p ps

-- | The name a model is shown by: as the pickers name it, or its id.
modelLabel :: Provider -> ProviderSettings -> Text -> Text
modelLabel p ps i =
  maybe i (\m -> m.label) (find (\m -> m.id == i) (choices.recommended <> choices.others))
  where
    choices = modelChoices p ps

-- | Whether a provider's list is due to be fetched: there is none, or it is
-- more than a day old (a provider adds a model every few months, and the
-- list costs a request each time it is fetched).
listStale :: UTCTime -> ProviderSettings -> Bool
listStale now ps = maybe True (\l -> diffUTCTime now l.fetchedAt > nominalDay) ps.fetched

-- | How hard a provider's models may be asked to think before answering,
-- from the least: Anthropic's @output_config.effort@ (its Claude 5 models
-- think adaptively, as much as the effort asks), OpenAI's
-- @reasoning.effort@. The scripted provider is sent Anthropic's request.
efforts :: Provider -> [Text]
efforts = \case
  Anthropic -> ["low", "medium", "high", "xhigh", "max"]
  OpenAI -> ["minimal", "low", "medium", "high"]
  Scripted -> efforts Anthropic

-- | Low, on both providers: an edit of a page is quick work, and a model
-- that thinks less answers sooner and costs less; the panel offers more.
defaultEffort :: Text
defaultEffort = "low"

-- | What a user has set for one provider.
data ProviderSettings = ProviderSettings
  { key :: Maybe Text
  -- ^ The API key, if one was given.
  , model :: Maybe Text
  -- ^ The model chosen, if one was ('chosenModel').
  , effort :: Text
  -- ^ How hard the model thinks ('efforts').
  , baseUrl :: Maybe Text
  -- ^ Where the provider is asked, if not at its own address: for OpenAI,
  -- any service that speaks its API ('baseUrlOf').
  , fetched :: Maybe ModelList
  -- ^ The provider's list of models, as last fetched with the key.
  , unreachable :: Bool
  -- ^ Whether the last contact with the provider found no way to it: no
  -- answer at all, as when a network blocks its address. Any answer, a
  -- refusal included, clears it.
  }
  deriving stock (Eq, Show)

-- | What a user has set: the provider the assistant asks, and each
-- provider's key, model and effort.
data Settings = Settings
  { provider :: Provider
  , byProvider :: Map Provider ProviderSettings
  }
  deriving stock (Eq, Show)

-- | Nothing set yet: Anthropic, with no key and no model chosen.
defaultSettings :: Settings
defaultSettings = Settings {provider = Anthropic, byProvider = mempty}

-- | Nothing set for a provider.
noSettings :: ProviderSettings
noSettings = ProviderSettings {key = Nothing, model = Nothing, effort = defaultEffort, baseUrl = Nothing, fetched = Nothing, unreachable = False}

-- | Whether settings hold nothing but what nothing set holds: no key, the
-- first provider, no model chosen, every effort its default, no address of
-- another service, and nothing learnt of a provider. Such settings need not
-- be kept.
blankSettings :: Settings -> Bool
blankSettings s = s.provider == Anthropic && all (== noSettings) (Map.elems s.byProvider)

-- | A provider's settings, its defaults where nothing was set.
settingsOf :: Provider -> Settings -> ProviderSettings
settingsOf p s = Map.findWithDefault noSettings p s.byProvider

-- | A provider's settings changed. (A function of a 'ProviderSettings'
-- takes and builds it whole, by position: its fields share their names
-- with 'Ready''s, which makes a record update of it ambiguous.)
alter :: Provider -> (ProviderSettings -> ProviderSettings) -> Settings -> Settings
alter p f s = s {byProvider = Map.insert p (f (settingsOf p s)) s.byProvider}

-- | A provider's key set, or taken away ("Forget"). A key is kept as it was
-- pasted but for the spaces and line breaks around it, which a copy often
-- brings and no key has. What was learnt with the key it replaces (its
-- list of models, whether the provider could be reached) goes with that
-- key: another key may be another account's, with other models.
withKey :: Provider -> Maybe Text -> Settings -> Settings
withKey p k = alter p $ \(ProviderSettings old m e b f u) ->
  let new = trimmed k
   in if new == old then ProviderSettings old m e b f u else ProviderSettings new m e b Nothing False

-- | A provider's model set; an empty one is none chosen, the default.
withModel :: Provider -> Text -> Settings -> Settings
withModel p m = alter p $ \(ProviderSettings k _ e b f u) -> ProviderSettings k (trimmed (Just m)) e b f u

-- | A provider's effort set; one it does not offer is its default.
withEffort :: Provider -> Text -> Settings -> Settings
withEffort p e = alter p $ \(ProviderSettings k m _ b f u) -> ProviderSettings k m (if e `elem` efforts p then e else defaultEffort) b f u

-- | A provider's address set ('baseUrlOf'), an empty one being its own;
-- what was learnt at the old one goes with it, as with a key.
withBaseUrl :: Provider -> Text -> Settings -> Settings
withBaseUrl p url = alter p $ \(ProviderSettings k m e old f u) ->
  let new = T.dropWhileEnd (== '/') <$> trimmed (Just url)
   in if new == old then ProviderSettings k m e old f u else ProviderSettings k m e new Nothing False

-- | A provider's list of models, as fetched at the time given: which says
-- too that the provider was reached.
withModels :: Provider -> [Listed] -> UTCTime -> Settings -> Settings
withModels p listing at = alter p $ \(ProviderSettings k m e b _ _) -> ProviderSettings k m e b (Just (ModelList listing at)) False

-- | Whether the last contact with a provider reached it.
withReached :: Provider -> Bool -> Settings -> Settings
withReached p reached = alter p $ \(ProviderSettings k m e b f _) -> ProviderSettings k m e b f (not reached)

trimmed :: Maybe Text -> Maybe Text
trimmed = mfilter (not . T.null) . fmap T.strip

chooseProvider :: Provider -> Settings -> Settings
chooseProvider p s = Settings {provider = p, byProvider = s.byProvider}

-- | The address of another service than the provider's own, for OpenAI's
-- API: any that speaks it (Azure OpenAI, GitHub Models, OpenRouter, a
-- server on this machine such as Ollama or LM Studio). Only OpenAI's
-- settings have one.
baseUrlOf :: Provider -> ProviderSettings -> Maybe Text
baseUrlOf p ps = if p == OpenAI then ps.baseUrl else Nothing

-- | Whether an address is plain HTTP to another machine than this one,
-- which anyone on the way can read: a key sent there is no longer the
-- user's alone. HTTP to this machine (a local server) is not.
insecureUrl :: Text -> Bool
insecureUrl url = case T.stripPrefix "http://" (T.toLower (T.strip url)) of
  Nothing -> False
  Just rest -> hostOf rest `notElem` ["localhost", "127.0.0.1", "[::1]"]
  where
    hostOf rest =
      let authority = T.takeWhile (`notElem` ("/?#" :: [Char])) rest
          afterUser = snd (T.breakOnEnd "@" authority)
       in if "[" `T.isPrefixOf` afterUser then T.takeWhile (/= ']') afterUser <> "]" else T.takeWhile (/= ':') afterUser

-- | Whether a provider can be asked: the scripted one always, another with
-- a key, and OpenAI's API at another address without one too (a server on
-- this machine needs none).
usable :: Provider -> ProviderSettings -> Bool
usable p ps = p == Scripted || isJust ps.key || isJust (baseUrlOf p ps)

-- | Whom a message that the provider cannot be reached names: the
-- provider, or the host of the other address it is asked at.
serviceName :: Provider -> ProviderSettings -> Text
serviceName p ps = case baseUrlOf p ps of
  Just url -> T.takeWhile (`notElem` ("/?#" :: [Char])) (snd (T.breakOnEnd "://" url))
  Nothing -> case p of
    Anthropic -> "Anthropic"
    OpenAI -> "OpenAI"
    Scripted -> "the scripted provider"

-- | What the assistant asks with: the provider, the model, the key (empty
-- for a server that takes none), the effort, and the address of another
-- service, if it is asked at one.
data Ready = Ready
  { provider :: Provider
  , model :: Text
  , key :: Text
  , effort :: Text
  , baseUrl :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | The provider chosen, its model and its key; or what is missing, said
-- to the user.
ready :: Settings -> Either Text Ready
ready s = readyFor s.provider s

-- | A provider, its model and its key, whether it is the one chosen or not
-- (its list of models is fetched with them); or what is missing.
readyFor :: Provider -> Settings -> Either Text Ready
readyFor p s
  | usable p ps = Right Ready {provider = p, model = chosenModel p ps, key = fromMaybe "" ps.key, effort = ps.effort, baseUrl = baseUrlOf p ps}
  | otherwise = Left ("There is no API key for " <> providerLabel p <> " yet: add one in the assistant's settings.")
  where
    ps = settingsOf p s

-- | Kept as one JSON object: the provider chosen, and an object per
-- provider that has settings, by its 'providerKey': its @key@, @model@,
-- @effort@ and @baseUrl@, its list as @models@ with the time it was
-- fetched as @modelsAt@, and @unreachable@ when it is so.
instance ToJSON Settings where
  toJSON s =
    object $
      ("provider" .= providerKey s.provider)
        : [ Key.fromText (providerKey p) .= object (["key" .= ps.key, "model" .= ps.model, "effort" .= ps.effort] <> learnt ps)
          | (p, ps) <- Map.toList s.byProvider
          ]
    where
      learnt :: ProviderSettings -> [Pair]
      learnt ps =
        maybe [] (\u -> ["baseUrl" .= u]) ps.baseUrl
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
      -- What settings kept before a field was read as the field's default.
      providerSettings = withObject "ProviderSettings" $ \o -> do
        listing <- o .:? "models"
        at <- o .:? "modelsAt"
        ProviderSettings
          <$> o
          .:? "key"
          <*> o .:? "model"
          <*> (o .:? "effort" .!= defaultEffort)
          <*> o .:? "baseUrl"
          <*> pure (ModelList <$> listing <*> at)
          <*> (o .:? "unreachable" .!= False)

-- | What went wrong with a request, as the provider's SDK typed it.
data ErrorKind
  = -- | The key was refused (401).
    BadKey
  | -- | The key may not do this (403).
    NotAllowed
  | -- | No such model, or the key may not use it (404).
    NoSuchModel
  | -- | Too many requests, or the account's credit or limits (429).
    RateLimited
  | -- | The provider is overloaded or failing (5xx).
    Overloaded
  | -- | The provider could not be reached: the network, or a timeout.
    Unreachable
  | -- | The model declined to answer (Anthropic's @refusal@).
    Declined
  | -- | The request was refused as malformed (400, 422).
    BadRequest
  | -- | Anything else.
    Failed
  deriving stock (Eq, Show, Enum, Bounded)

-- | An error, as the browser's side reports it: its kind, the HTTP status
-- if there was an answer, and the provider's own message.
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

-- | What the panel and the settings say of an error: what it means, then
-- the provider's own words and the status, with the key taken out of them
-- ('redact') wherever it appears, since a provider may quote it back.
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

-- | A message with the key taken out: the key itself, wherever it appears,
-- and anything that looks like a key or a part of one (a word starting
-- @sk-@, as both providers' keys do, which a provider may quote back
-- masked but for its ends).
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
