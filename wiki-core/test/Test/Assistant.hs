-- | The writing assistant's pure part: the settings and what an error says
-- ("Wiki.Core.Assistant"), the prompt and the page's context
-- ("Wiki.Core.Assistant.Prompt"), and the edits and tracked changes
-- ("Wiki.Core.Assistant.Edit").
module Test.Assistant (spec) where

import Data.Aeson (Value (..), decode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, nominalDay)
import Protolude
import Test.Hspec hiding (after, before, context, pending)
import Test.QuickCheck
import Wiki.Core.Assistant
import Wiki.Core.Assistant.Edit
import Wiki.Core.Assistant.Prompt
import Wiki.Core.Assistant.Reference (markdownReference)
import Wiki.Core.Url (Url (..))

spec :: Spec
spec = describe "Wiki.Core.Assistant" $ do
  settingsSpec
  modelsSpec
  errorSpec
  promptSpec
  requestSpec
  editSpec
  changeSpec

settingsSpec :: Spec
settingsSpec = describe "settings" $ do
  it "start with Anthropic, each provider's newest model, and no key" $ do
    defaultSettings.provider `shouldBe` Anthropic
    (settingsOf Anthropic defaultSettings).model `shouldBe` Nothing
    chosenModel Anthropic (settingsOf Anthropic defaultSettings) `shouldBe` "claude-opus-5-5"
    chosenModel OpenAI (settingsOf OpenAI defaultSettings) `shouldBe` "gpt-6.1-sol"
    (settingsOf Anthropic defaultSettings).key `shouldBe` Nothing

  it "offer the scripted provider only where one is installed" $ do
    providers False `shouldBe` [Anthropic, OpenAI]
    providers True `shouldBe` [Anthropic, OpenAI, Scripted]

  it "keep a key per provider, trimmed, and forget it" $ do
    let s = withKey OpenAI (Just "  sk-open \n") (withKey Anthropic (Just "sk-ant-1") defaultSettings)
    (settingsOf Anthropic s).key `shouldBe` Just (ApiKey "sk-ant-1")
    (settingsOf OpenAI s).key `shouldBe` Just (ApiKey "sk-open")
    (settingsOf OpenAI (withKey OpenAI Nothing s)).key `shouldBe` Nothing
    (settingsOf Anthropic (withKey OpenAI Nothing s)).key `shouldBe` Just (ApiKey "sk-ant-1")
    (settingsOf OpenAI (withKey OpenAI (Just "   ") s)).key `shouldBe` Nothing

  it "never show a key, so that none reaches a log, while its JSON is the bare text" $ do
    (show (settingsOf Anthropic (withKey Anthropic (Just "sk-ant-1") defaultSettings)) :: Text) `shouldSatisfy` (not . T.isInfixOf "sk-ant-1")
    encode (ApiKey "sk-ant-1") `shouldBe` "\"sk-ant-1\""

  it "keep a model per provider, an empty one being the default" $ do
    let s = withModel OpenAI "gpt-6-luna" (withModel Anthropic "claude-sonnet-5-5" defaultSettings)
    (settingsOf Anthropic s).model `shouldBe` Just "claude-sonnet-5-5"
    (settingsOf OpenAI s).model `shouldBe` Just "gpt-6-luna"
    (settingsOf OpenAI (withModel OpenAI " " s)).model `shouldBe` Nothing
    chosenModel OpenAI (settingsOf OpenAI (withModel OpenAI " " s)) `shouldBe` "gpt-6.1-sol"

  it "are ready with the chosen provider's key, and say what is missing" $ do
    let s = withKey Anthropic (Just "sk-a") defaultSettings
    ready s `shouldBe` Right (Ready Anthropic "claude-opus-5-5" (ApiKey "sk-a") "medium" Nothing)
    ready (chooseProvider OpenAI s) `shouldSatisfy` isLeft
    ready (chooseProvider Scripted defaultSettings) `shouldBe` Right (Ready Scripted "scripted" (ApiKey "") "medium" Nothing)

  it "are blank with nothing but defaults in them" $ do
    blankSettings defaultSettings `shouldBe` True
    blankSettings (withKey Anthropic Nothing (withKey Anthropic (Just "k") defaultSettings)) `shouldBe` True
    blankSettings (withKey Anthropic (Just "k") defaultSettings) `shouldBe` False
    blankSettings (chooseProvider OpenAI defaultSettings) `shouldBe` False
    blankSettings (withModel OpenAI "gpt-6-luna" defaultSettings) `shouldBe` False
    blankSettings (withModel OpenAI "" (withModel OpenAI "gpt-6-luna" defaultSettings)) `shouldBe` True

  it "keep a default effort per provider, medium when none is chosen, and only one the provider offers" $ do
    defaultEffort `shouldBe` "medium"
    effortOf (settingsOf Anthropic defaultSettings) `shouldBe` "medium"
    effortOf (settingsOf OpenAI defaultSettings) `shouldBe` "medium"
    let s = withEffort OpenAI "minimal" (withEffort Anthropic "xhigh" defaultSettings)
    effortOf (settingsOf Anthropic s) `shouldBe` "xhigh"
    effortOf (settingsOf OpenAI s) `shouldBe` "minimal"
    (settingsOf OpenAI (withEffort OpenAI "xhigh" s)).effort `shouldBe` Nothing
    effortOf (settingsOf OpenAI (withEffort OpenAI "xhigh" s)) `shouldBe` "medium"
    efforts Anthropic `shouldBe` ["low", "medium", "high", "xhigh", "max"]
    efforts OpenAI `shouldBe` ["minimal", "low", "medium", "high"]
    (\r -> r.effort) <$> ready (withKey Anthropic (Just "k") s) `shouldBe` Right "xhigh"
    blankSettings (withEffort Anthropic "max" defaultSettings) `shouldBe` False
    -- The default chosen is none chosen: such settings stay blank.
    blankSettings (withEffort Anthropic "medium" (withEffort Anthropic "max" defaultSettings)) `shouldBe` True

  it "keep the default effort as defaultEffort, only when one is chosen" $ do
    let s = withEffort Anthropic "high" (withKey Anthropic (Just "sk-a") defaultSettings)
    encode s `shouldBe` "{\"anthropic\":{\"defaultEffort\":\"high\",\"key\":\"sk-a\",\"model\":null},\"provider\":\"anthropic\"}"
    encode (withKey Anthropic (Just "sk-a") defaultSettings) `shouldBe` "{\"anthropic\":{\"key\":\"sk-a\",\"model\":null},\"provider\":\"anthropic\"}"
    decode (encode s) `shouldBe` Just s

  it "read the effort settings kept before WP5.11 as the new default" $ do
    -- The old field held the old default, low, for every provider with
    -- settings, or the effort last picked in the chat.
    let old = decode "{\"provider\":\"anthropic\",\"anthropic\":{\"key\":\"sk-a\",\"model\":null,\"effort\":\"low\"},\"openai\":{\"key\":null,\"model\":null,\"effort\":\"high\"}}"
    effortOf . settingsOf Anthropic <$> old `shouldBe` Just "medium"
    effortOf . settingsOf OpenAI <$> old `shouldBe` Just "medium"
    (\r -> r.effort) <$> (ready =<< maybeToEither "" old) `shouldBe` Right "medium"

  it "read settings kept before there was an effort, an address or a list" $
    decode "{\"provider\":\"openai\",\"openai\":{\"key\":\"sk-o\",\"model\":\"gpt-6-luna\"}}"
      `shouldBe` Just (chooseProvider OpenAI (withModel OpenAI "gpt-6-luna" (withKey OpenAI (Just "sk-o") defaultSettings)))

  it "go to JSON and back" $ do
    let s = chooseProvider OpenAI (withEffort OpenAI "high" (withModel OpenAI "custom-model" (withKey OpenAI (Just "sk-o") (withKey Anthropic (Just "sk-a") defaultSettings))))
    decode (encode s) `shouldBe` Just s
    decode (encode defaultSettings) `shouldBe` Just defaultSettings
    let listed = withBaseUrl OpenAI "https://models.github.ai/inference" (withModels Anthropic anthropicList today s)
    decode (encode listed) `shouldBe` Just listed

modelsSpec :: Spec
modelsSpec = describe "the models offered" $ do
  it "group Anthropic's list: each family's newest undated model, Opus first, then the others, newest first" $ do
    let grouped = groupModels Anthropic False anthropicList
    map (\m -> m.id) grouped.recommended `shouldBe` ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    map (\m -> m.id) grouped.others
      `shouldBe` [ "claude-opus-5"
                 , "claude-sonnet-5"
                 , "claude-fable-5"
                 , "claude-opus-4-8"
                 , "claude-opus-4-7"
                 , "claude-sonnet-4-6"
                 , "claude-opus-4-6"
                 , "claude-opus-4-5-20251101"
                 , "claude-haiku-4-5-20251001"
                 ]
    -- Named as the short list names them, else as the provider does.
    map (\m -> m.label) (take 1 grouped.recommended) `shouldBe` ["Claude Opus 5.5"]
    map (\m -> m.label) (take 1 grouped.others) `shouldBe` ["Claude Opus 5"]

  it "group OpenAI's list: chat models only, the newest generation recommended, the others newest first" $ do
    let grouped = groupModels OpenAI False openAiList
    map (\m -> m.id) grouped.recommended `shouldBe` ["gpt-6.1-sol", "gpt-6.1-terra"]
    map (\m -> m.id) grouped.others
      `shouldBe` ["gpt-6-sol", "gpt-6-luna", "gpt-6-astra", "gpt-5.1", "gpt-5-pro", "gpt-5-nano", "gpt-5-mini", "gpt-5", "gpt-4.1", "gpt-4o-mini", "gpt-4o", "gpt-3.5-turbo"]
    -- An id the short list does not know is shown by itself.
    map (\m -> m.label) (take 1 grouped.others) `shouldBe` ["gpt-6-sol"]

  it "recommend the mini and nano of the newest major version beside its newest generation" $ do
    let older = filter (\l -> not ("gpt-6" `T.isPrefixOf` l.id)) openAiList
    map (\m -> m.id) (groupModels OpenAI False older).recommended `shouldBe` ["gpt-5.1", "gpt-5-nano", "gpt-5-mini"]
    let gpt6 = filter (\l -> not ("gpt-6.1" `T.isPrefixOf` l.id)) openAiList
    map (\m -> m.id) (groupModels OpenAI False gpt6).recommended `shouldBe` ["gpt-6-sol", "gpt-6-astra", "gpt-6-luna"]

  it "are a fetched list's, the first recommended the default, else the short list" $ do
    let fetched = withModels OpenAI openAiList today (withKey OpenAI (Just "sk-o") defaultSettings)
        ps = settingsOf OpenAI fetched
    (modelChoices OpenAI ps).recommended `shouldBe` (groupModels OpenAI False openAiList).recommended
    chosenModel OpenAI ps `shouldBe` "gpt-6.1-sol"
    -- Without a list, or with one that recommends nothing, the short one.
    modelChoices OpenAI (settingsOf OpenAI defaultSettings) `shouldBe` ModelChoices (models OpenAI) []
    modelChoices OpenAI (settingsOf OpenAI (withModels OpenAI [Listed "whisper-1" Nothing Nothing] today defaultSettings))
      `shouldBe` ModelChoices (models OpenAI) []
    -- A list whose families are newer than the short list's: its own.
    let newer = [Listed "claude-sonnet-6" (Just "Claude Sonnet 6") (Just 1900000000), Listed "claude-opus-6" (Just "Claude Opus 6") (Just 1890000000)] <> anthropicList
    chosenModel Anthropic (settingsOf Anthropic (withModels Anthropic newer today defaultSettings)) `shouldBe` "claude-opus-6"
    -- A model chosen is the one asked, listed or not; its name is the list's.
    let chosen = settingsOf OpenAI (withModel OpenAI "gpt-5-pro" fetched)
    chosenModel OpenAI chosen `shouldBe` "gpt-5-pro"
    modelLabel OpenAI chosen "gpt-6.1-terra" `shouldBe` "GPT-6.1 Terra"
    modelLabel OpenAI chosen "my-model" `shouldBe` "my-model"

  it "are fetched again when there is no list or it is more than a day old, and not kept past their key" $ do
    let ps at = settingsOf Anthropic (withModels Anthropic anthropicList at (withKey Anthropic (Just "k") defaultSettings))
    listStale today (settingsOf Anthropic defaultSettings) `shouldBe` True
    listStale today (ps today) `shouldBe` False
    listStale (addUTCTime (nominalDay - 60) today) (ps today) `shouldBe` False
    listStale (addUTCTime (nominalDay + 60) today) (ps today) `shouldBe` True
    let s = withModels Anthropic anthropicList today (withKey Anthropic (Just "k") defaultSettings)
    (settingsOf Anthropic (withKey Anthropic (Just "k") s)).fetched `shouldSatisfy` isJust
    (settingsOf Anthropic (withKey Anthropic (Just "another") s)).fetched `shouldBe` Nothing
    (settingsOf Anthropic (withKey Anthropic Nothing s)).fetched `shouldBe` Nothing
    blankSettings (withKey Anthropic Nothing s) `shouldBe` True

  it "take another address for OpenAI's API, with or without a key, and offer all its models" $ do
    let onMachine = chooseProvider OpenAI (withBaseUrl OpenAI " http://localhost:11434/v1/ " defaultSettings)
        ps = settingsOf OpenAI onMachine
    ps.baseUrl `shouldBe` Just (Url "http://localhost:11434/v1")
    -- A server on this machine needs no key.
    ready onMachine `shouldBe` Right (Ready OpenAI "gpt-6.1-sol" (ApiKey "") "medium" (Just (Url "http://localhost:11434/v1")))
    usable OpenAI ps `shouldBe` True
    usable Anthropic (settingsOf Anthropic (withBaseUrl Anthropic "http://localhost:1/v1" defaultSettings)) `shouldBe` False
    serviceName OpenAI ps `shouldBe` "localhost:11434"
    serviceName Anthropic ps `shouldBe` "Anthropic"
    -- Its models are its own: all of them, newest first, none dropped.
    let served = [Listed "llama4:8b" Nothing (Just 20), Listed "qwen3-coder" Nothing (Just 30), Listed "nomic-embed-text" Nothing (Just 10)]
        fetched = settingsOf OpenAI (withModels OpenAI served today onMachine)
    modelChoices OpenAI fetched `shouldBe` ModelChoices [] [Model "qwen3-coder" "qwen3-coder", Model "llama4:8b" "llama4:8b", Model "nomic-embed-text" "nomic-embed-text"]
    chosenModel OpenAI fetched `shouldBe` "qwen3-coder"
    -- Recommended, only those of the short list it has.
    (groupModels OpenAI True (Listed "gpt-6-luna" Nothing Nothing : served)).recommended `shouldBe` [Model "gpt-6-luna" "GPT-6 Luna"]
    -- Another address is another service: what was learnt goes.
    (settingsOf OpenAI (withBaseUrl OpenAI "https://models.github.ai/inference" (withModels OpenAI served today onMachine))).fetched `shouldBe` Nothing
    (settingsOf OpenAI (withBaseUrl OpenAI "" onMachine)).baseUrl `shouldBe` Nothing
    blankSettings (withBaseUrl OpenAI "" (withBaseUrl OpenAI "http://localhost:1" defaultSettings)) `shouldBe` True

  it "say which addresses are plain HTTP to another machine" $ do
    map insecureUrl ["https://models.github.ai/inference", "http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080", "HTTP://LocalHost/v1"]
      `shouldBe` [False, False, False, False, False]
    map insecureUrl ["http://192.168.1.20:11434/v1", "http://llm.corp.example/v1", "http://localhost.example.com/v1", "http://user@evil.example/v1"]
      `shouldBe` [True, True, True, True]

  it "remember a provider that could not be reached until it is" $ do
    let s = withReached Anthropic False (withKey Anthropic (Just "k") defaultSettings)
    (settingsOf Anthropic s).unreachable `shouldBe` True
    (settingsOf Anthropic (withReached Anthropic True s)).unreachable `shouldBe` False
    (settingsOf Anthropic (withModels Anthropic anthropicList today s)).unreachable `shouldBe` False
    (settingsOf Anthropic (withKey Anthropic (Just "another") s)).unreachable `shouldBe` False
    decode (encode s) `shouldBe` Just s

-- | When the lists were fetched.
today :: UTCTime
today = UTCTime (fromGregorian 2026 10 27) 0

-- | Anthropic's list as it answered on 2026-10-27 (its ids and names, in its
-- order, newest first); the times are made up, in that order.
anthropicList :: [Listed]
anthropicList =
  zipWith
    (\n (i, name) -> Listed i (Just name) (Just (1800000000 - n * 1000000)))
    [0 ..]
    [ ("claude-haiku-5-5", "Claude Haiku 5.5")
    , ("claude-sonnet-5-5", "Claude Sonnet 5.5")
    , ("claude-opus-5-5", "Claude Opus 5.5")
    , ("claude-fable-5-1", "Claude Fable 5.1")
    , ("claude-opus-5", "Claude Opus 5")
    , ("claude-sonnet-5", "Claude Sonnet 5")
    , ("claude-fable-5", "Claude Fable 5")
    , ("claude-opus-4-8", "Claude Opus 4.8")
    , ("claude-opus-4-7", "Claude Opus 4.7")
    , ("claude-sonnet-4-6", "Claude Sonnet 4.6")
    , ("claude-opus-4-6", "Claude Opus 4.6")
    , ("claude-opus-4-5-20251101", "Claude Opus 4.5")
    , ("claude-haiku-4-5-20251001", "Claude Haiku 4.5")
    ]

-- | OpenAI's list as it answered on 2026-10-27, abridged to its chat models
-- and a few of each other kind (it had 134), without names, as OpenAI
-- gives none; the times are made up, the newest first in this order, but
-- for the models of one release, which share a time and are then ordered
-- by id.
openAiList :: [Listed]
openAiList =
  [ Listed i Nothing (Just t)
  | (i, t) <-
      [ ("gpt-6.1-sol", 1790000000)
      , ("gpt-6.1-terra", 1790000000)
      , ("gpt-6-sol", 1780000000)
      , ("gpt-6-astra", 1780000000)
      , ("gpt-6-luna", 1780000000)
      , ("gpt-5.1-codex", 1770000000)
      , ("gpt-5.1", 1770000000)
      , ("gpt-5-pro", 1760000000)
      , ("gpt-5-codex", 1758000000)
      , ("gpt-5-search-api", 1757000000)
      , ("gpt-5-2025-08-07", 1754000000)
      , ("gpt-5", 1754000000)
      , ("gpt-5-mini", 1754000000)
      , ("gpt-5-nano", 1754000000)
      , ("gpt-5-chat-latest", 1754000000)
      , ("gpt-image-1", 1745000000)
      , ("gpt-4.1", 1744000000)
      , ("gpt-4o-realtime-preview", 1730000000)
      , ("gpt-4o-mini-transcribe", 1740000000)
      , ("gpt-4o-mini-tts", 1740000000)
      , ("gpt-4o-audio-preview", 1730000000)
      , ("gpt-4o", 1715000000)
      , ("gpt-4o-mini", 1721000000)
      , ("gpt-3.5-turbo-instruct", 1690000000)
      , ("gpt-3.5-turbo", 1677000000)
      , ("o3", 1744000000)
      , ("o4-mini", 1744000000)
      , ("text-embedding-3-large", 1705000000)
      , ("omni-moderation-latest", 1731000000)
      , ("tts-1", 1681000000)
      , ("whisper-1", 1677000000)
      , ("dall-e-3", 1698000000)
      ]
  ]

errorSpec :: Spec
errorSpec = describe "an error" $ do
  it "says what the provider's kind of error means, with its words and status" $ do
    let e = AssistantError {kind = BadKey, status = Just 401, message = "invalid x-api-key"}
    errorText Nothing e `shouldBe` "The provider did not accept the key. The provider said: invalid x-api-key (401)"

  it "never shows the key, nor anything that looks like one" $ do
    let key = "sk-proj-abcdefghijklmnop1234"
        e = AssistantError {kind = BadKey, status = Just 401, message = "Incorrect API key provided: " <> key <> ". Also sk-proj-****1234 was seen."}
        shown = errorText (Just (ApiKey key)) e
    shown `shouldNotSatisfy` T.isInfixOf key
    shown `shouldNotSatisfy` T.isInfixOf "1234"
    shown `shouldSatisfy` T.isInfixOf "[your key]"

  it "reads the browser's side's kinds" $ do
    decode "{\"kind\":\"rate_limit\",\"status\":429,\"message\":\"slow down\"}" `shouldBe` Just (AssistantError RateLimited (Just 429) "slow down")
    decode "{\"kind\":\"connection\",\"message\":\"Connection error.\"}" `shouldBe` Just (AssistantError Unreachable Nothing "Connection error.")
    decode "{\"kind\":\"what\"}" `shouldBe` Just (AssistantError Failed Nothing "")

  it "is redacted whatever the key and the message" $ property $ \(PrintableString k) (PrintableString before) (PrintableString after) ->
    let key = "sk-" <> T.filter (/= ' ') (toS k) <> "Zz9"
     in not (key `T.isInfixOf` redact (Just (ApiKey key)) (toS before <> key <> toS after))

promptSpec :: Spec
promptSpec = describe "the page's context" $ do
  let page = "# Title\n\nFirst paragraph.\n\nSecond one,\nover two lines.\n\nThird.\n\nFourth."
      spanOf t = let (b, _) = T.breakOn t page in Span (T.length b) (T.length b + T.length t)

  it "counts the lines a selection is on" $ do
    lineSpan page (spanOf "Second one,\nover two lines.") `shouldBe` (5, 6)
    lineSpan page (spanOf "First") `shouldBe` (3, 3)
    -- Whole lines selected with the last line break end on the line before.
    lineSpan page (spanOf "Second one,\n") `shouldBe` (5, 5)
    chipLabel (5, 6) `shouldBe` "lines 5\8211\&6"
    chipLabel (3, 3) `shouldBe` "line 3"

  it "sends a selection with its paragraph and one more on each side" $
    pageContext "Title" page (Just (spanOf "two lines"))
      `shouldBe` Selected
        { title = "Title"
        , lineRange = (6, 6)
        , before = "First paragraph.\n\nSecond one,\nover "
        , selected = "two lines"
        , after = ".\n\nThird."
        }

  it "sends the page's start and end when the selection is near them" $ do
    beforeOf (pageContext "Title" page (Just (spanOf "Title"))) `shouldBe` "# "
    afterOf (pageContext "Title" page (Just (spanOf "Fourth"))) `shouldBe` "."

  it "cuts the text around a selection" $ do
    let long = T.replicate 5000 "x" <> "SELECTED" <> T.replicate 5000 "y"
        context = pageContext "T" long (Just (Span 5000 5008))
    T.length (beforeOf context) `shouldBe` contextCap
    T.length (afterOf context) `shouldBe` contextCap

  it "sends the page without a selection, or with an empty one" $ do
    pageContext "Title" page Nothing `shouldBe` Whole "Title" page Nothing
    pageContext "Title" page (Just (Span 4 4)) `shouldBe` Whole "Title" page Nothing

  it "cuts a long page and says so" $ do
    let long = T.replicate (bodyCap + 10) "a"
        context = pageContext "Long" long Nothing
    context `shouldBe` Whole "Long" (T.take bodyCap long) (Just (bodyCap + 10))
    userTurn [] context "Shorten it." `shouldSatisfy` T.isInfixOf ("Only the first " <> show bodyCap <> " of its " <> show (bodyCap + 10) <> " characters")

  it "puts the title, the page's text and the request in a message" $ do
    let turn = userTurn [] (pageContext "Hello" page (Just (spanOf "Third."))) "Fix it."
    turn `shouldSatisfy` T.isPrefixOf "The page is titled \"Hello\"."
    turn `shouldSatisfy` T.isInfixOf "<selection>\nThird.\n</selection>"
    turn `shouldSatisfy` T.isInfixOf "line 8"
    turn `shouldSatisfy` T.isSuffixOf "<request>\nFix it.\n</request>"
    userTurn [] (pageContext "Hello" page Nothing) "Hi" `shouldSatisfy` T.isInfixOf ("<page>\n" <> page <> "\n</page>")

  it "says which of the model's changes the user rejected or undid since its last message" $ do
    let context = pageContext "Hello" page Nothing
        thanks = "Inserted \8220## Thanks\8221 at the end"
        turn = userTurn [(thanks, Rejected), ("Replaced \8220a\8221 with \8220b\8221", Accepted), ("Removed \8220c\8221", Undone)] context "And now?"
    turn `shouldSatisfy` T.isInfixOf ("Since your last message, the user decided on your changes")
    turn `shouldSatisfy` T.isInfixOf ("- Rejected (what it replaced is back): " <> thanks)
    turn `shouldSatisfy` T.isInfixOf "- Accepted: Replaced \8220a\8221 with \8220b\8221"
    turn `shouldSatisfy` T.isInfixOf "- Undone by the user: Removed \8220c\8221"
    -- Before the page, after the title.
    fst (T.breakOn "Since your last message" turn) `shouldSatisfy` T.isPrefixOf "The page is titled"
    snd (T.breakOn "Since your last message" turn) `shouldSatisfy` T.isInfixOf "<page>"

  it "says nothing of decisions when there were none, or only acceptances" $ do
    let context = pageContext "Hello" page Nothing
    userTurn [] context "Hi" `shouldNotSatisfy` T.isInfixOf "Since your last message"
    userTurn [("Replaced \8220a\8221 with \8220b\8221", Accepted)] context "Hi" `shouldNotSatisfy` T.isInfixOf "Since your last message"
    userTurn [] context "Hi" `shouldBe` userTurn [("x", Accepted)] context "Hi"

  it "has a shortcut for each of the plan's actions" $ do
    map shortcutLabel shortcuts `shouldBe` ["Improve", "Fix grammar", "Shorten", "Expand", "Summarise", "Continue", "Translate"]
    shortcutText Translate `shouldSatisfy` T.isSuffixOf "into "
  where
    beforeOf = \case
      Selected {before} -> before
      Whole {} -> "(the whole page)"
    afterOf = \case
      Selected {after} -> after
      Whole {} -> "(the whole page)"

requestSpec :: Spec
requestSpec = describe "the requests" $ do
  it "embed the authors' reference, docs/markdown.md" $ do
    markdownReference `shouldSatisfy` T.isPrefixOf "# Writing pages"
    markdownReference `shouldSatisfy` T.isInfixOf "```mermaid"
    markdownReference `shouldSatisfy` T.isInfixOf "[[toc]]"

  it "put the reference first in Anthropic's system prompt, marked for caching, and nothing that changes" $ do
    let request = anthropicRequest "claude-opus-5-5" "low"
    field "model" request `shouldBe` Just (String "claude-opus-5-5")
    case field "system" request of
      Just (Array blocks) -> do
        toList blocks `shouldBe` [cachedBlock markdownReference, cachedBlock instructions]
      other -> expectationFailure ("no system blocks: " <> show other)
    field "tools" request `shouldBe` Just anthropicTools
    -- The same for every request with the same model: what is cached.
    encode (anthropicRequest "claude-opus-5-5" "low") `shouldBe` encode request
    field "messages" request `shouldBe` Nothing
    -- Adaptive thinking, with its summary shown, and no budget.
    field "thinking" request `shouldBe` Just (object ["type" .= ("adaptive" :: Text), "display" .= ("summarized" :: Text)])
    -- The effort, as Anthropic takes it.
    field "output_config" request `shouldBe` Just (object ["effort" .= ("low" :: Text)])
    field "output_config" (anthropicRequest "claude-opus-5-5" "max") `shouldBe` Just (object ["effort" .= ("max" :: Text)])

  it "start OpenAI's instructions with the reference, keep nothing at OpenAI, and change nothing" $ do
    let request = openAiRequest "gpt-6.1-sol" "low"
    case field "instructions" request of
      Just (String text) -> do
        text `shouldSatisfy` T.isPrefixOf markdownReference
        text `shouldSatisfy` T.isSuffixOf instructions
      other -> expectationFailure ("no instructions: " <> show other)
    field "store" request `shouldBe` Just (Bool False)
    -- The effort, and a summary of the reasoning, for the panel.
    field "reasoning" request `shouldBe` Just (object ["effort" .= ("low" :: Text), "summary" .= ("auto" :: Text)])
    field "reasoning" (openAiRequest "gpt-6.1-sol" "minimal") `shouldBe` Just (object ["effort" .= ("minimal" :: Text), "summary" .= ("auto" :: Text)])
    field "max_output_tokens" request `shouldBe` Nothing
    field "tools" request `shouldBe` Just openAiTools
    encode (openAiRequest "gpt-6.1-sol" "low") `shouldBe` encode request

  it "offer the two tools, every field required, as OpenAI's strict mode wants" $ do
    let names = \case
          Array tools -> [n | Object o <- toList tools, Just (String n) <- [KM.lookup "name" o]]
          _ -> []
    names anthropicTools `shouldBe` ["replace", "insert"]
    names openAiTools `shouldBe` ["replace", "insert"]
    case openAiTools of
      Array tools -> for_ tools $ \case
        Object o -> do
          KM.lookup "strict" o `shouldBe` Just (Bool True)
          case KM.lookup "parameters" o of
            Just (Object p) -> do
              KM.lookup "additionalProperties" p `shouldBe` Just (Bool False)
              let required = case KM.lookup "required" p of
                    Just (Array r) -> sort [t | String t <- toList r]
                    _ -> []
                  properties = case KM.lookup "properties" p of
                    Just (Object ps) -> sort (map Key.toText (KM.keys ps))
                    _ -> []
              required `shouldBe` properties
            _ -> expectationFailure "no parameters"
        _ -> expectationFailure "a tool that is no object"
      _ -> expectationFailure "no tools"
  where
    field name = \case
      Object o -> KM.lookup name o
      _ -> Nothing
    cachedBlock text = object ["type" .= ("text" :: Text), "text" .= text, "cache_control" .= object ["type" .= ("ephemeral" :: Text)]]

editSpec :: Spec
editSpec = describe "an edit" $ do
  let page = "One cat. Two cats.\n\nA dog."

  it "is read from a tool call" $ do
    parseEdit "replace" (object ["old_text" .= ("A dog." :: Text), "new_text" .= ("A fox." :: Text)]) `shouldBe` Right (Replace "A dog." "A fox.")
    parseEdit "insert" (object ["anchor" .= ("end" :: Text), "where" .= ("after" :: Text), "text" .= ("\n\nMore." :: Text)]) `shouldBe` Right (Insert AtEnd After "\n\nMore.")
    parseEdit "insert" (object ["anchor" .= ("A dog." :: Text), "where" .= ("before" :: Text), "text" .= ("X" :: Text)]) `shouldBe` Right (Insert (AtText "A dog.") Before "X")
    parseEdit "insert" (object ["anchor" .= ("end" :: Text), "where" .= ("under" :: Text), "text" .= ("X" :: Text)]) `shouldSatisfy` isMalformed
    parseEdit "replace" (object ["old" .= ("x" :: Text)]) `shouldSatisfy` isMalformed
    parseEdit "delete" (toJSON ([] :: [Int])) `shouldBe` Left (UnknownTool "delete")

  it "replaces text the page has once" $ do
    plan (Replace "A dog." "A fox.") page `shouldBe` Right (Replacement 20 26 "A fox.")
    apply (Replacement 20 26 "A fox.") page `shouldBe` "One cat. Two cats.\n\nA fox."

  it "is refused when its text is not there, or is there more than once" $ do
    plan (Replace "A cow." "x") page `shouldBe` Left (NotFound "A cow.")
    plan (Replace "cat" "x") page `shouldBe` Left (FoundMany "cat" 2)
    plan (Replace "" "x") page `shouldBe` Left EmptyQuote
    answer (plan (Replace "cat" "x") page) `shouldSatisfy` T.isInfixOf "occurs 2 times"
    answer (plan (Replace "A cow." "x") page) `shouldSatisfy` T.isInfixOf "does not contain"
    answer (plan (Replace "A dog." "x") page) `shouldSatisfy` T.isPrefixOf "Applied."

  it "inserts at the start, at the end, and before or after text" $ do
    let made e = (`apply` page) <$> plan e page
    made (Insert AtStart Before "# Pets\n\n") `shouldBe` Right ("# Pets\n\n" <> page)
    made (Insert AtEnd After "\n\nThe end.") `shouldBe` Right (page <> "\n\nThe end.")
    made (Insert (AtText "Two cats.") Before "Then: ") `shouldBe` Right "One cat. Then: Two cats.\n\nA dog."
    made (Insert (AtText "Two cats.") After " Three.") `shouldBe` Right "One cat. Two cats. Three.\n\nA dog."
    made (Insert (AtText "cat") After "!") `shouldBe` Left (FoundMany "cat" 2)

  it "counts occurrences that do not overlap" $ do
    occurrences "aa" "aaaa" `shouldBe` [0, 2]
    occurrences "x" "" `shouldBe` []
    occurrences "é" "café é" `shouldBe` [3, 5]

  it "is described for the conversation" $ do
    describeEdit (Replace "A dog." "A fox.") `shouldBe` "Replaced \8220A dog.\8221 with \8220A fox.\8221"
    describeEdit (Insert AtEnd After "x") `shouldBe` "Inserted \8220x\8221 at the end"
    describeEdit (Replace "gone" "") `shouldBe` "Removed \8220gone\8221"
  where
    isMalformed = \case
      Left (Malformed _) -> True
      _ -> False

changeSpec :: Spec
changeSpec = describe "tracked changes" $ do
  let page = "One cat. Two cats.\n\nA dog."
      -- An edit made as the browser makes it: planned against the page as
      -- it is, and tracked.
      edit i e (text, pending) = case plan e text of
        Right r -> track i r text pending
        Left why -> panic (show why)
      rejectAll (text, pending) = foldl' (flip apply) text (settle Reject pending)

  it "keeps what an edit replaced" $ do
    let (after, pending) = edit 1 (Replace "A dog." "A fox, quick.") (page, [])
    pending `shouldBe` [Change {id = 1, from = 20, to = 33, removed = "A dog."}]
    T.take 13 (T.drop 20 after) `shouldBe` "A fox, quick."

  it "puts the page back as it was when every change is rejected" $ do
    let s = edit 3 (Insert AtEnd After "\n\nThe end.") (edit 2 (Insert AtStart Before "# Pets\n\n") (edit 1 (Replace "A dog." "A fox.") (page, [])))
    length (snd s) `shouldBe` 3
    rejectAll s `shouldBe` page

  it "keeps the page as it is when changes are accepted" $ do
    let (after, pending) = edit 2 (Replace "One cat." "A cat.") (edit 1 (Replace "A dog." "A fox.") (page, []))
    settle Accept pending `shouldBe` []
    after `shouldBe` "A cat. Two cats.\n\nA fox."

  it "rejects one change and leaves the other" $ do
    let (after, pending) = edit 2 (Replace "One cat." "A cat.") (edit 1 (Replace "A dog." "A fox.") (page, []))
        first' = filter (\c -> c.id == 1) pending
    foldl' (flip apply) after (settle Reject first') `shouldBe` "A cat. Two cats.\n\nA dog."

  it "takes in a change an edit overlaps, so that rejecting goes back to before the edit" $ do
    let s1 = edit 1 (Replace "A dog." "A fox jumps.") (page, [])
        (after, pending) = edit 2 (Replace "fox jumps" "fox leaps") s1
    map (\c -> c.id) pending `shouldBe` [2]
    after `shouldBe` "One cat. Two cats.\n\nA fox leaps."
    rejectAll (after, pending) `shouldBe` "One cat. Two cats.\n\nA fox jumps."

  it "keeps changes side by side apart" $ do
    let (_, pending) = edit 2 (Replace "Two cats." "Two dogs.") (edit 1 (Replace "One cat." "One dog.") (page, []))
    length pending `shouldBe` 2

  it "takes in a removal next to another removal" $ do
    let s1 = edit 1 (Replace "One cat. " "") (page, [])
        (after, pending) = edit 2 (Replace "Two cats." "") s1
    after `shouldBe` "\n\nA dog."
    length pending `shouldBe` 1
    rejectAll (after, pending) `shouldBe` "Two cats.\n\nA dog."

  it "rejects any set of changes back to the page as it was" $ property $ \(Positive n) -> do
    let steps = take (min 6 n) [Insert AtEnd After (" " <> show i) | i <- [1 :: Int ..]]
        s = foldl' (\acc (i, e) -> edit i e acc) (page, []) (zip [1 ..] steps)
    rejectAll s `shouldBe` page
