-- | The writing assistant's providers, models and settings, and what it
-- says when a provider refuses (WP4.19 of docs/PLAN.md, decision 21).
--
-- The assistant is bring-your-own-key: the user pastes an API key per
-- provider into the assistant's settings, which this browser keeps under
-- the user's id and sends to that provider only; the wiki's server never
-- sees it. What is kept is 'Settings': the provider chosen, and for each
-- provider its key, if one was given, and the model to use.
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
  , chooseProvider
  , Ready (..)
  , ready

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
import Data.Aeson.Types (Parser)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
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

-- | The models the settings offer for a provider, the newest general ones
-- first, the first of them the default; any other the provider takes can be
-- typed in instead.
--
-- Read on 2026-10-27 from the providers' own lists: Anthropic's "Models
-- overview" (platform.claude.com/docs/en/about-claude/models/overview),
-- which recommends Claude Opus 5.5 to start with, and OpenAI's "Models"
-- (developers.openai.com/api/docs/models), whose flagship models are the
-- GPT-6 family. Read them again when a provider announces a new
-- generation, and change them here only: nothing else names a model.
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

defaultModel :: Provider -> Text
defaultModel p = maybe "" (\m -> m.id) (head (models p))

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
  , model :: Text
  , effort :: Text
  -- ^ How hard the model thinks ('efforts').
  }
  deriving stock (Eq, Show)

-- | What a user has set: the provider the assistant asks, and each
-- provider's key, model and effort.
data Settings = Settings
  { provider :: Provider
  , byProvider :: Map Provider ProviderSettings
  }
  deriving stock (Eq, Show)

-- | Nothing set yet: Anthropic, with its default model and no key.
defaultSettings :: Settings
defaultSettings = Settings {provider = Anthropic, byProvider = mempty}

-- | Whether settings hold nothing but what nothing set holds: no key, the
-- first provider, every model and effort its default. Such settings need
-- not be kept.
blankSettings :: Settings -> Bool
blankSettings s = s.provider == Anthropic && all blank (Map.toList s.byProvider)
  where
    blank (p, ps) = isNothing ps.key && ps.model == defaultModel p && ps.effort == defaultEffort

-- | A provider's settings, its defaults where nothing was set.
settingsOf :: Provider -> Settings -> ProviderSettings
settingsOf p s = Map.findWithDefault (ProviderSettings Nothing (defaultModel p) defaultEffort) p s.byProvider

-- | A provider's key set, or taken away ("Forget"). A key is kept as it was
-- pasted but for the spaces and line breaks around it, which a copy often
-- brings and no key has.
withKey :: Provider -> Maybe Text -> Settings -> Settings
withKey p k s = s {byProvider = Map.insert p ProviderSettings {key = mfilter (not . T.null) (T.strip <$> k), model = ps.model, effort = ps.effort} s.byProvider}
  where
    ps :: ProviderSettings
    ps = settingsOf p s

-- | A provider's model set; an empty one is its default.
withModel :: Provider -> Text -> Settings -> Settings
withModel p m s = s {byProvider = Map.insert p ProviderSettings {key = ps.key, model = if T.null (T.strip m) then defaultModel p else T.strip m, effort = ps.effort} s.byProvider}
  where
    ps :: ProviderSettings
    ps = settingsOf p s

-- | A provider's effort set; one it does not offer is its default.
withEffort :: Provider -> Text -> Settings -> Settings
withEffort p e s = s {byProvider = Map.insert p ProviderSettings {key = ps.key, model = ps.model, effort = if e `elem` efforts p then e else defaultEffort} s.byProvider}
  where
    ps :: ProviderSettings
    ps = settingsOf p s

chooseProvider :: Provider -> Settings -> Settings
chooseProvider p s = Settings {provider = p, byProvider = s.byProvider}

-- | What the assistant asks with: the provider, the model, the key and the
-- effort.
data Ready = Ready
  { provider :: Provider
  , model :: Text
  , key :: Text
  , effort :: Text
  }
  deriving stock (Eq, Show)

-- | The provider chosen, its model and its key; or what is missing, said
-- to the user. The scripted provider needs no key.
ready :: Settings -> Either Text Ready
ready s = case s.provider of
  Scripted -> Right (Ready Scripted chosen.model "" chosen.effort)
  p -> case chosen.key of
    Just k -> Right (Ready p chosen.model k chosen.effort)
    Nothing -> Left ("There is no API key for " <> providerLabel p <> " yet: add one in the assistant's settings.")
  where
    chosen = settingsOf s.provider s

-- | Kept as one JSON object: the provider chosen, and an object per
-- provider that has settings, by its 'providerKey'.
instance ToJSON Settings where
  toJSON s =
    object $
      ("provider" .= providerKey s.provider)
        : [ Key.fromText (providerKey p) .= object ["key" .= ps.key, "model" .= ps.model, "effort" .= ps.effort]
          | (p, ps) <- Map.toList s.byProvider
          ]

instance FromJSON Settings where
  parseJSON = withObject "Settings" $ \o -> do
    provider <- o .: "provider" >>= providerFrom
    byProvider <- fmap (Map.fromList . catMaybes) . for [minBound .. maxBound] $ \p ->
      o .:? Key.fromText (providerKey p) >>= traverse (fmap (p,) . providerSettings p)
    pure Settings {provider, byProvider}
    where
      providerFrom :: Text -> Parser Provider
      providerFrom k = maybe (fail ("no such provider: " <> toS k)) pure (providerFromKey k)
      providerSettings p = withObject "ProviderSettings" $ \o ->
        -- Settings kept before there was an effort read with the default.
        ProviderSettings <$> o .:? "key" <*> (o .:? "model" .!= defaultModel p) <*> (o .:? "effort" .!= defaultEffort)

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
