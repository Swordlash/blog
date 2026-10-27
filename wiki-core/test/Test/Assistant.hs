-- | The writing assistant's pure part: the settings and what an error says
-- ("Wiki.Core.Assistant"), the prompt and the page's context
-- ("Wiki.Core.Assistant.Prompt"), and the edits and tracked changes
-- ("Wiki.Core.Assistant.Edit").
module Test.Assistant (spec) where

import Data.Aeson (Value (..), decode, encode, object, toJSON, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text qualified as T
import Protolude
import Test.Hspec hiding (after, before, context, pending)
import Test.QuickCheck
import Wiki.Core.Assistant
import Wiki.Core.Assistant.Edit
import Wiki.Core.Assistant.Prompt
import Wiki.Core.Assistant.Reference (markdownReference)

spec :: Spec
spec = describe "Wiki.Core.Assistant" $ do
  settingsSpec
  errorSpec
  promptSpec
  requestSpec
  editSpec
  changeSpec

settingsSpec :: Spec
settingsSpec = describe "settings" $ do
  it "start with Anthropic, each provider's newest model, and no key" $ do
    defaultSettings.provider `shouldBe` Anthropic
    (settingsOf Anthropic defaultSettings).model `shouldBe` "claude-opus-5-5"
    (settingsOf OpenAI defaultSettings).model `shouldBe` "gpt-6.1-sol"
    (settingsOf Anthropic defaultSettings).key `shouldBe` Nothing

  it "offer the scripted provider only where one is installed" $ do
    providers False `shouldBe` [Anthropic, OpenAI]
    providers True `shouldBe` [Anthropic, OpenAI, Scripted]

  it "keep a key per provider, trimmed, and forget it" $ do
    let s = withKey OpenAI (Just "  sk-open \n") (withKey Anthropic (Just "sk-ant-1") defaultSettings)
    (settingsOf Anthropic s).key `shouldBe` Just "sk-ant-1"
    (settingsOf OpenAI s).key `shouldBe` Just "sk-open"
    (settingsOf OpenAI (withKey OpenAI Nothing s)).key `shouldBe` Nothing
    (settingsOf Anthropic (withKey OpenAI Nothing s)).key `shouldBe` Just "sk-ant-1"
    (settingsOf OpenAI (withKey OpenAI (Just "   ") s)).key `shouldBe` Nothing

  it "keep a model per provider, an empty one being the default" $ do
    let s = withModel OpenAI "gpt-6-luna" (withModel Anthropic "claude-sonnet-5-5" defaultSettings)
    (settingsOf Anthropic s).model `shouldBe` "claude-sonnet-5-5"
    (settingsOf OpenAI s).model `shouldBe` "gpt-6-luna"
    (settingsOf OpenAI (withModel OpenAI " " s)).model `shouldBe` "gpt-6.1-sol"

  it "are ready with the chosen provider's key, and say what is missing" $ do
    let s = withKey Anthropic (Just "sk-a") defaultSettings
    ready s `shouldBe` Right (Ready Anthropic "claude-opus-5-5" "sk-a")
    ready (chooseProvider OpenAI s) `shouldSatisfy` isLeft
    ready (chooseProvider Scripted defaultSettings) `shouldBe` Right (Ready Scripted "scripted" "")

  it "are blank with nothing but defaults in them" $ do
    blankSettings defaultSettings `shouldBe` True
    blankSettings (withKey Anthropic Nothing (withKey Anthropic (Just "k") defaultSettings)) `shouldBe` True
    blankSettings (withKey Anthropic (Just "k") defaultSettings) `shouldBe` False
    blankSettings (chooseProvider OpenAI defaultSettings) `shouldBe` False
    blankSettings (withModel OpenAI "gpt-6-luna" defaultSettings) `shouldBe` False

  it "go to JSON and back" $ do
    let s = chooseProvider OpenAI (withModel OpenAI "custom-model" (withKey OpenAI (Just "sk-o") (withKey Anthropic (Just "sk-a") defaultSettings)))
    decode (encode s) `shouldBe` Just s
    decode (encode defaultSettings) `shouldBe` Just defaultSettings

errorSpec :: Spec
errorSpec = describe "an error" $ do
  it "says what the provider's kind of error means, with its words and status" $ do
    let e = AssistantError {kind = BadKey, status = Just 401, message = "invalid x-api-key"}
    errorText Nothing e `shouldBe` "The provider did not accept the key. The provider said: invalid x-api-key (401)"

  it "never shows the key, nor anything that looks like one" $ do
    let key = "sk-proj-abcdefghijklmnop1234"
        e = AssistantError {kind = BadKey, status = Just 401, message = "Incorrect API key provided: " <> key <> ". Also sk-proj-****1234 was seen."}
        shown = errorText (Just key) e
    shown `shouldNotSatisfy` T.isInfixOf key
    shown `shouldNotSatisfy` T.isInfixOf "1234"
    shown `shouldSatisfy` T.isInfixOf "[your key]"

  it "reads the browser's side's kinds" $ do
    decode "{\"kind\":\"rate_limit\",\"status\":429,\"message\":\"slow down\"}" `shouldBe` Just (AssistantError RateLimited (Just 429) "slow down")
    decode "{\"kind\":\"connection\",\"message\":\"Connection error.\"}" `shouldBe` Just (AssistantError Unreachable Nothing "Connection error.")
    decode "{\"kind\":\"what\"}" `shouldBe` Just (AssistantError Failed Nothing "")

  it "is redacted whatever the key and the message" $ property $ \(PrintableString k) (PrintableString before) (PrintableString after) ->
    let key = "sk-" <> T.filter (/= ' ') (toS k) <> "Zz9"
     in not (key `T.isInfixOf` redact (Just key) (toS before <> key <> toS after))

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
    userTurn context "Shorten it." `shouldSatisfy` T.isInfixOf ("Only the first " <> show bodyCap <> " of its " <> show (bodyCap + 10) <> " characters")

  it "puts the title, the page's text and the request in a message" $ do
    let turn = userTurn (pageContext "Hello" page (Just (spanOf "Third."))) "Fix it."
    turn `shouldSatisfy` T.isPrefixOf "The page is titled \"Hello\"."
    turn `shouldSatisfy` T.isInfixOf "<selection>\nThird.\n</selection>"
    turn `shouldSatisfy` T.isInfixOf "line 8"
    turn `shouldSatisfy` T.isSuffixOf "<request>\nFix it.\n</request>"
    userTurn (pageContext "Hello" page Nothing) "Hi" `shouldSatisfy` T.isInfixOf ("<page>\n" <> page <> "\n</page>")

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
    let request = anthropicRequest "claude-opus-5-5"
    field "model" request `shouldBe` Just (String "claude-opus-5-5")
    case field "system" request of
      Just (Array blocks) -> do
        toList blocks `shouldBe` [cachedBlock markdownReference, cachedBlock instructions]
      other -> expectationFailure ("no system blocks: " <> show other)
    field "tools" request `shouldBe` Just anthropicTools
    -- The same for every request with the same model: what is cached.
    encode (anthropicRequest "claude-opus-5-5") `shouldBe` encode request
    field "messages" request `shouldBe` Nothing
    field "thinking" request `shouldBe` Nothing

  it "start OpenAI's instructions with the reference, keep nothing at OpenAI, and change nothing" $ do
    let request = openAiRequest "gpt-6.1-sol"
    case field "instructions" request of
      Just (String text) -> do
        text `shouldSatisfy` T.isPrefixOf markdownReference
        text `shouldSatisfy` T.isSuffixOf instructions
      other -> expectationFailure ("no instructions: " <> show other)
    field "store" request `shouldBe` Just (Bool False)
    field "reasoning" request `shouldBe` Just (object ["effort" .= ("low" :: Text)])
    field "max_output_tokens" request `shouldBe` Nothing
    field "tools" request `shouldBe` Just openAiTools
    encode (openAiRequest "gpt-6.1-sol") `shouldBe` encode request

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
