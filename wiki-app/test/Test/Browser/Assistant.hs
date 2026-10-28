{-# LANGUAGE TemplateHaskell #-}

-- | The writing assistant in a browser, in the editor, over the demo's
-- wiki, with the scripted provider (@jsbits/assistant.js@) answering as a
-- model would: a message sent with a selection, whose answer streams in and
-- whose tool call edits the page as a tracked change, accepted (and then
-- undone as usual) or rejected; two edits in one turn, an insertion at the
-- end, and Reject all; an edit whose text is not in the page, refused with
-- the tool's answer and followed by the model's text; a turn stopped, by
-- Stop and by closing the panel; what the panel shows while the model
-- works: "Thinking" with its dots, the seconds waited and the thinking's
-- summary, a status line while a tool call is written, a cursor at the
-- end of streaming text, and the time and duration of each message;
-- Close and Escape; the effort, from the settings' default and changed
-- for one conversation; an error shown without anything like a key in
-- it; the models offered, the provider's own list grouped; a bubble per
-- provider with a key, or one without any; a provider that cannot be
-- reached, said so and tried again; OpenAI's API at another address
-- without a key; and the settings page: keys kept per user, forgotten,
-- and tested, the list of models fetched with a key, and the default
-- effort per provider. The
-- providers themselves cannot be reached from here (the script answers
-- for all of them on a test's page): they are tested over their SDKs by
-- toolchain/test-assistant.mjs.
module Test.Browser.Assistant (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value, decodeStrict, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, replace)
import Test.Browser.Mount (slugs, startWith)
import Test.Browser.Text (editorText, markdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Assistant (ApiKey (..), Provider (..), ProviderSettings (..), Settings (..), chooseProvider, defaultSettings, settingsOf, withBaseUrl, withEffort, withKey)
import Wiki.Core.Id (UserId (..))

$( browserJS
     ["jsbits/test-assistant.js"]
     [ ("js_script", "wiki_test_assistant_script", Unsafe, [t|JSText -> IO ()|])
     , ("js_forget", "wiki_test_assistant_forget", Unsafe, [t|IO ()|])
     , ("js_requests", "wiki_test_assistant_requests", Unsafe, [t|IO JSText|])
     , ("js_answers", "wiki_test_assistant_answers", Unsafe, [t|IO JSText|])
     , ("js_select", "wiki_test_editor_select", Unsafe, [t|Int -> Int -> IO Bool|])
     , ("js_choose", "wiki_test_choose", Unsafe, [t|JSText -> JSText -> IO Bool|])
     , ("js_lists", "wiki_test_assistant_lists", Unsafe, [t|JSText -> IO Bool|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "sends a selection, streams the answer, and makes its edit a change that Accept keeps and Ctrl+Z undoes" $ runPage $ do
    script [[text "I will ", text "make it the very first.", replace "the first post" "the very first post", text " Done."]]
    ui <- openAssistant m
    _ <- unsafeIOToPageM (js_select 16 38)
    chip <- find ui ".assistant-scope .assistant-chip"
    chip `shouldHaveText` "line 3×"
    -- The effort starts at the default, medium. One chosen under the
    -- message goes with the message, and the settings keep their default.
    find ui ".assistant-effort" >>= (`getProperty` "value") >>= (`shouldBe` "medium")
    _ <- unsafeIOToPageM (js_choose (toJSText ".assistant-effort") (toJSText "high"))
    eventually $ find ui ".assistant-effort" >>= (`getProperty` "value") >>= (`shouldBe` "high")
    send ui "Make it sound newer."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "I will make it the very first. Done.")
    find ui ".assistant-made" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Replaced")
    find ui ".assistant-message.from-user .assistant-chip" >>= (`shouldHaveText` "line 3")
    -- The page has the new text, shown as a change with what it replaced.
    find ui ".cm-wiki-inserted" >>= (`shouldHaveText` "the very first post")
    find ui ".cm-wiki-removed" >>= (`shouldHaveText` "the first post")
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "This is the very first post of a blog")
    find ui ".assistant-pending" >>= (`shouldHaveText` "1 suggested change to accept or reject")
    find ui ".editor-pending-note" >>= (`shouldHaveText` "Saving accepts the suggested change.")
    -- What the model was sent: the reference first, then the selection
    -- with the text around it, and the request.
    [request] <- requests
    fieldText ["request", "system", "0", "text"] request `shouldSatisfy` maybe False (T.isPrefixOf "# Writing pages")
    fieldText ["request", "output_config", "effort"] request `shouldBe` Just "high"
    (\s -> (settingsOf Scripted s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)
    let user = fromMaybe "" (fieldText ["user"] request)
    user `shouldSatisfy` T.isInfixOf "<selection>\nThis is the first post\n</selection>"
    user `shouldSatisfy` T.isInfixOf "<before>\n# Hello, world\n\n\n</before>"
    user `shouldSatisfy` T.isInfixOf "<request>\nMake it sound newer.\n</request>"
    -- Accepted: the text stays, the change goes.
    find ui ".assistant-accept-all" >>= click
    eventually $ length <$> findAll ui ".cm-wiki-inserted" `shouldReturn` 0
    length <$> findAll ui ".cm-wiki-removed" `shouldReturn` 0
    length <$> findAll ui ".assistant-pending" `shouldReturn` 0
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "the very first post")
    -- And undoing goes back to before the edit, as any edit.
    editorText ui >>= click
    press "Control+z"
    eventually $ markdown ui >>= (`shouldSatisfy` T.isInfixOf "This is the first post of a blog")

  it "rejects a change from the change itself, putting back what it replaced, and tells the model so" $ runPage $ do
    script [[replace "## Why a wiki" "## Why this is a wiki", text "Retitled."], [text "Noted."]]
    ui <- openAssistant m
    send ui "Change the heading."
    eventually $ find ui ".cm-wiki-inserted" >>= (`shouldHaveText` "## Why this is a wiki")
    find ui ".cm-wiki-change-reject" >>= click
    eventually $ length <$> findAll ui ".cm-wiki-inserted" `shouldReturn` 0
    markdown ui >>= (`shouldSatisfy` T.isInfixOf "\n## Why a wiki\n")
    markdown ui >>= (`shouldNotSatisfy'` T.isInfixOf "Why this is")
    -- The model is told, with the next message, that the user threw its
    -- change away, so that it does not look for it.
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Retitled.")
    send ui "And now?"
    eventually $ length <$> requests `shouldReturn` 2
    [before, after] <- requests
    fromMaybe "" (fieldText ["user"] before) `shouldNotSatisfy'` T.isInfixOf "Since your last message"
    let told = fromMaybe "" (fieldText ["user"] after)
    told `shouldSatisfy` T.isInfixOf "Since your last message, the user decided on your changes"
    told `shouldSatisfy` T.isInfixOf "- Rejected (what it replaced is back): Replaced \8220## Why a wiki\8221 with \8220## Why this is a wiki\8221"

  it "makes two edits in one turn, one an insertion at the end, and Reject all takes both back" $ runPage $ do
    script [[replace "spaces in other spaces" "spaces inside other spaces", insert "end" "after" "\n\nThat is all.\n", text "Two changes."]]
    (ui, original) <- openAssistantWith m
    send ui "Polish it."
    eventually $ find ui ".assistant-pending" >>= (`shouldHaveText` "2 suggested changes to accept or reject")
    length <$> findAll ui ".assistant-made" `shouldReturn` 2
    markdown ui >>= (`shouldSatisfy` T.isSuffixOf "That is all.\n")
    -- Nothing was selected: the page went with the message.
    [request] <- requests
    fromMaybe "" (fieldText ["user"] request) `shouldSatisfy` T.isInfixOf "<page>\n# Hello, world"
    find ui ".assistant-reject-all" >>= click
    eventually $ markdown ui `shouldReturn` original

  it "answers a replacement of text the page does not have with why, and the model goes on" $ runPage $ do
    script [[replace "a sentence nowhere" "anything", text "Sorry, I could not find it."]]
    (ui, original) <- openAssistantWith m
    send ui "Fix it."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Sorry, I could not find it.")
    find ui ".assistant-not-made" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "the page has no such text")
    [answered] <- answers
    fieldText ["text"] answered `shouldSatisfy` maybe False (T.isInfixOf "does not contain")
    fieldBool "ok" answered `shouldBe` Just False
    markdown ui `shouldReturn` original
    length <$> findAll ui ".cm-wiki-inserted" `shouldReturn` 0

  it "stops a turn with Stop, and keeps the change made by then" $ runPage $ do
    script [[replace "## Why a wiki" "## Why", text "Working", hold, text "never"]]
    ui <- openAssistant m
    send ui "Go on."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Working")
    -- The streaming text ends in a cursor, which goes when the message ends.
    _ <- find ui ".assistant-message.from-model .assistant-text .assistant-cursor"
    find ui ".assistant-stop" >>= click
    eventually $ find ui ".assistant-stopped" >>= (`shouldHaveText` "Stopped.")
    length <$> findAll ui ".assistant-cursor" `shouldReturn` 0
    find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Working")
    find ui ".cm-wiki-inserted" >>= (`shouldHaveText` "## Why")
    _ <- find ui ".assistant-send"
    pass

  it "stops a turn when the panel is closed, and keeps the conversation" $ runPage $ do
    script [[text "Thinking it over", hold, text "never"], [text "Again."]]
    ui <- openAssistant m
    send ui "Go on."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Thinking it over")
    -- The provider's button again closes the panel; once more opens it.
    find ui scriptedButton >>= click
    find ui ".editor-assistant" >>= shouldBeHidden
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "false")
    find ui scriptedButton >>= click
    eventually $ find ui ".assistant-stopped" >>= (`shouldHaveText` "Stopped.")
    -- The conversation goes on where it was.
    send ui "Once more."
    eventually $ length <$> findAll ui ".assistant-message.from-user" `shouldReturn` 2
    eventually $ findAll ui ".assistant-message.from-model .assistant-text" >>= traverse textContent >>= (`shouldBe` ["Thinking it over", "Again."])

  it "shows Thinking with three dots until the first text, the seconds waited, and the thinking's summary, kept as Thought" $ runPage $ do
    script [[thinking "Weighing the words.", quiet 4000, text "Here it is."]]
    ui <- openAssistant m
    send ui "Go on."
    eventually $ find ui ".assistant-message.from-model .assistant-thinking" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "Thinking")
    length <$> findAll ui ".assistant-message.from-model .assistant-dots span" `shouldReturn` 3
    length <$> findAll ui ".assistant-message.from-model .assistant-text" `shouldReturn` 0
    -- The summary of the thinking, collapsed under the line; a click opens it.
    eventually $ find ui "details.assistant-thinking .assistant-thinking-text" >>= (`shouldHaveText` "Weighing the words.")
    find ui "details.assistant-thinking" >>= (`getProperty` "open") >>= (`shouldBe` "false")
    find ui "details.assistant-thinking summary" >>= click
    find ui "details.assistant-thinking" >>= (`getProperty` "open") >>= (`shouldBe` "true")
    -- After a few seconds without anything from the model, the seconds
    -- waited, beside the dots.
    waited <- eventuallyWithin 5000 $ find ui ".assistant-thinking .assistant-waited" >>= textContent
    waited `shouldSatisfy` T.isSuffixOf " s"
    -- The first text ends the wait: the line goes, and the summary stays
    -- at the top of the message as Thought.
    eventuallyWithin 5000 $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Here it is.")
    eventually $ length <$> findAll ui ".assistant-thinking" `shouldReturn` 0
    find ui ".assistant-thought-text" >>= (`shouldHaveText` "Weighing the words.")

  it "says the page is being edited while the model writes a tool call, and shows the edit's note once it is made" $ runPage $ do
    script [[pausing 1500 (replace "## Why a wiki" "## Why"), text "Retitled."]]
    ui <- openAssistant m
    send ui "Retitle it."
    eventually $ find ui ".assistant-message.from-model .assistant-status" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "Editing the page")
    length <$> findAll ui ".assistant-made" `shouldReturn` 0
    eventuallyWithin 4000 $ find ui ".assistant-made" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Replaced")
    length <$> findAll ui ".assistant-status" `shouldReturn` 0
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Retitled.")

  it "shows the time of each message, and how long a finished answer took" $ runPage $ do
    script [[quiet 1200, text "Done."]]
    ui <- openAssistant m
    send ui "Hello?"
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Done.")
    asked <- find ui ".assistant-message.from-user .assistant-time" >>= textContent
    asked `shouldSatisfy` (\t -> T.isInfixOf ":" t && T.any isDigit t)
    find ui ".assistant-message.from-model .assistant-time" >>= textContent >>= (`shouldBe` asked)
    eventually $ find ui ".assistant-message.from-model .assistant-took" >>= textContent >>= (`shouldSatisfy` (`elem` ["1 s", "2 s", "3 s"]))

  it "closes with Close in its header, and with Escape in the message box" $ runPage $ do
    script []
    ui <- openAssistant m
    close <- find ui ".assistant-head .assistant-close"
    close `shouldHaveText` "Close"
    click close
    eventually $ find ui ".editor-assistant" >>= shouldBeHidden
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "false")
    find ui scriptedButton >>= click
    eventually $ find ui ".editor-assistant" >>= shouldBeVisible
    find ui ".assistant-input" >>= focus
    press "Escape"
    eventually $ find ui ".editor-assistant" >>= shouldBeHidden
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "false")

  it "starts the chat's effort at the settings' default, and a change in the chat stays with the conversation" $ runPage $ do
    script [[text "One."], [text "Two."]]
    keep m (UserId "user-editor") (withEffort Scripted "xhigh" (chooseProvider Scripted defaultSettings))
    ui <- openAssistantKept m
    find ui ".assistant-effort" >>= (`getProperty` "value") >>= (`shouldBe` "xhigh")
    send ui "First."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "One.")
    eventually $ find ui ".assistant-effort" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing)
    _ <- unsafeIOToPageM (js_choose (toJSText ".assistant-effort") (toJSText "low"))
    eventually $ find ui ".assistant-effort" >>= (`getProperty` "value") >>= (`shouldBe` "low")
    send ui "Second."
    eventually $ length <$> requests `shouldReturn` 2
    [firstAsked, secondAsked] <- requests
    fieldText ["request", "output_config", "effort"] firstAsked `shouldBe` Just "xhigh"
    fieldText ["request", "output_config", "effort"] secondAsked `shouldBe` Just "low"
    -- The settings keep their default.
    (\s -> (settingsOf Scripted s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Just "xhigh")

  it "opens with a provider from its button, and switching starts a new conversation with the changes kept" $ runPage $ do
    script [[replace "## Why a wiki" "## Why", text "Retitled."], [text "Claude here."]]
    keep m (UserId "user-editor") (withKey Anthropic (Just "sk-ant-test") (chooseProvider Scripted defaultSettings))
    ui <- openAssistantKept m
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    -- A bubble for each provider with a key: Claude's, not ChatGPT's.
    find ui ".editor-provider[data-provider='anthropic']" >>= (`getAttribute` "title") >>= (`shouldBe` Just "Chat with Claude")
    length <$> findAll ui ".editor-provider[data-provider='openai']" `shouldReturn` 0
    send ui "Retitle it."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Retitled.")
    -- Claude: the panel stays, its conversation ends; the change is still
    -- to decide.
    find ui ".editor-provider[data-provider='anthropic']" >>= click
    eventually $ find ui ".assistant-notice" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The next message starts a new one with Anthropic (Claude).")
    find ui ".editor-provider[data-provider='anthropic']" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "false")
    eventually $ (\s -> s.provider) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Anthropic)
    find ui ".cm-wiki-inserted" >>= (`shouldHaveText` "## Why")
    find ui ".assistant-pending" >>= (`shouldHaveText` "1 suggested change to accept or reject")
    -- Claude's models and efforts are offered under the message.
    findAll ui ".assistant-effort option" >>= traverse textContent >>= (`shouldBe` ["low", "medium", "high", "xhigh", "max"])
    find ui ".assistant-model-choice" >>= (`getProperty` "value") >>= (`shouldBe` "claude-opus-5-5")
    -- The next message goes to Claude, with its key.
    send ui "Hello?"
    eventually $ length <$> requests `shouldReturn` 2
    [_, toClaude] <- requests
    fieldText ["provider"] toClaude `shouldBe` Just "anthropic"
    fieldText ["key"] toClaude `shouldBe` Just "sk-ant-test"

  it "shows a provider's error as it gave it, without anything like a key" $ runPage $ do
    script [[failing "authentication" 401 "invalid x-api-key: sk-ant-api03-abcdefgh1234"]]
    ui <- openAssistant m
    send ui "Hello?"
    shown <- eventually $ find ui ".assistant-error" >>= textContent
    shown `shouldSatisfy` T.isInfixOf "The provider did not accept the key."
    shown `shouldSatisfy` T.isInfixOf "(401)"
    shown `shouldNotSatisfy'` T.isInfixOf "abcdefgh1234"
    _ <- find ui ".assistant-send"
    pass

  it "offers the provider's own models, grouped, the first recommended the default, and asks the one chosen" $ runPage $ do
    scriptWith [[text "Hello."]] (object ["scripted" .= scriptedModels])
    ui <- openAssistant m
    -- Asked for when the editor opened, and kept.
    eventually $ findAll ui ".assistant-model-choice optgroup" >>= traverse (`getAttribute` "label") >>= (`shouldBe` [Just "Recommended", Just "All models"])
    findAll ui ".assistant-model-choice optgroup[label='Recommended'] option" >>= traverse textContent >>= (`shouldBe` ["Claude Opus 5.5", "Claude Sonnet 5.5"])
    findAll ui ".assistant-model-choice optgroup[label='All models'] option" >>= traverse textContent >>= (`shouldBe` ["Claude Opus 4.8", "Claude Haiku 4.5"])
    find ui ".assistant-model-choice" >>= (`getProperty` "value") >>= (`shouldBe` "claude-opus-5-5")
    eventually $ (\s -> isJust (settingsOf Scripted s).fetched) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` True)
    _ <- unsafeIOToPageM (js_choose (toJSText ".assistant-model-choice") (toJSText "claude-opus-4-8"))
    eventually $ (\s -> (settingsOf Scripted s).model) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Just "claude-opus-4-8")
    send ui "Hello?"
    eventually $ length <$> requests `shouldReturn` 1
    [request] <- requests
    fieldText ["request", "model"] request `shouldBe` Just "claude-opus-4-8"

  it "shows one Assistant bubble to a user without a key, which opens the panel to say where keys go" $ runPage $ do
    unsafeIOToPageM js_forget
    keep m (UserId "user-editor") defaultSettings
    (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    _ <- editorText ui
    bubble <- eventually $ find ui ".editor-provider[data-provider='assistant']"
    getAttribute bubble "title" >>= (`shouldBe` Just "Assistant")
    length <$> findAll ui ".editor-provider" `shouldReturn` 1
    click bubble
    eventually $ find ui ".assistant-setup" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "There is no API key for Anthropic (Claude)")
    find ui ".assistant-setup a" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Open the assistant's settings")

  it "dims a provider that cannot be reached, says so in the panel, and tries again" $ runPage $ do
    let blocked = object ["error" .= object ["kind" .= ("connection" :: Text), "message" .= ("Failed to fetch" :: Text)]]
    scriptWith [[failing "connection" 0 "Failed to fetch"], [text "Back."]] (object ["anthropic" .= blocked])
    keep m (UserId "user-editor") (withKey Anthropic (Just "sk-ant-test") defaultSettings)
    (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    _ <- editorText ui
    let claude = ".editor-provider[data-provider='anthropic']"
    eventually $ find ui claude >>= (`getAttribute` "class") >>= (`shouldBe` Just "editor-provider unreachable")
    find ui claude >>= (`getAttribute` "title") >>= (`shouldBe` Just "Cannot reach Anthropic from this network")
    eventually $ (\s -> (settingsOf Anthropic s).unreachable) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` True)
    -- It still opens, and the panel says why, with a way to try again,
    -- which finds it now.
    find ui claude >>= click
    find ui ".assistant-unreachable" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Cannot reach Anthropic from this network.")
    setLists (object ["anthropic" .= scriptedModels])
    -- Once the check the opening made is over.
    eventually $ find ui ".assistant-try-again" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing)
    find ui ".assistant-try-again" >>= click
    eventually $ length <$> findAll ui ".assistant-unreachable" `shouldReturn` 0
    find ui claude >>= (`getAttribute` "class") >>= (`shouldBe` Just "editor-provider")
    -- A message that gets no answer says it again; one that gets one, not.
    send ui "Hello?"
    eventually $ find ui ".assistant-error" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "could not be reached")
    eventually $ find ui claude >>= (`getAttribute` "class") >>= (`shouldBe` Just "editor-provider unreachable")
    send ui "Again?"
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Back.")
    eventually $ find ui claude >>= (`getAttribute` "class") >>= (`shouldBe` Just "editor-provider")

  it "asks OpenAI's API at another address, without a key" $ runPage $ do
    scriptWith [[text "From the local server."]] (object ["openai" .= [object ["id" .= ("llama4:8b" :: Text), "created" .= (20 :: Int)], object ["id" .= ("nomic-embed-text" :: Text), "created" .= (10 :: Int)]]])
    keep m (UserId "user-editor") (chooseProvider OpenAI (withBaseUrl OpenAI "http://localhost:11434/v1" defaultSettings))
    (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    _ <- editorText ui
    onMachine <- eventually $ find ui ".editor-provider[data-provider='openai']"
    getAttribute onMachine "title" >>= (`shouldBe` Just "Chat through localhost:11434")
    click onMachine
    -- Its own models, every one, none of OpenAI's names.
    eventually $ findAll ui ".assistant-model-choice optgroup[label='All models'] option" >>= traverse textContent >>= (`shouldBe` ["llama4:8b", "nomic-embed-text"])
    send ui "Hello?"
    eventually $ length <$> requests `shouldReturn` 1
    [request] <- requests
    fieldText ["provider"] request `shouldBe` Just "openai"
    fieldText ["baseUrl"] request `shouldBe` Just "http://localhost:11434/v1"
    fieldText ["key"] request `shouldBe` Just ""
    fieldText ["model"] request `shouldBe` Just "llama4:8b"

  it "keeps a key for each user, forgets it, and tests it" $ runPage $ do
    scriptWith [] (object ["anthropic" .= take 2 scriptedModels])
    keep m (UserId "user-editor") (withKey Anthropic Nothing defaultSettings)
    keep m (UserId "user-admin") (withKey Anthropic Nothing defaultSettings)
    (ui, _) <- startWith m (Just "user-editor") AssistantSettings
    find ui ".assistant-settings h1" >>= (`shouldHaveText` "Writing assistant")
    find ui ".assistant-intro" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "billed by its provider")
    find ui ".assistant-intro" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Markdown reference")
    -- The test page is the machine's own: a secure context.
    length <$> findAll ui ".assistant-insecure" `shouldReturn` 0
    anthropic <- find ui ".assistant-provider-settings[data-provider='anthropic']"
    findIn anthropic ".assistant-key" >>= (`typeText` "sk-ant-test-key")
    findIn anthropic ".assistant-key-form button" >>= click
    eventually $ findIn anthropic ".assistant-key-kept" >>= (`shouldHaveText` "A key is kept for Anthropic (Claude) in this browser.")
    -- Its list of models, fetched with it, and fetched again on request.
    eventually $ findIn anthropic ".assistant-listed" >>= (`shouldHaveText` "2 models fetched from Anthropic (Claude), 2 of them offered for a chat.")
    findAllIn anthropic ".assistant-model-choice optgroup[label='Recommended'] option" >>= traverse textContent >>= (`shouldBe` ["Claude Opus 5.5", "Claude Sonnet 5.5"])
    setLists (object ["anthropic" .= scriptedModels])
    findIn anthropic ".assistant-refresh" >>= click
    eventually $ findIn anthropic ".assistant-listed" >>= (`shouldHaveText` "4 models fetched from Anthropic (Claude), 4 of them offered for a chat.")
    findAllIn anthropic ".assistant-model-choice optgroup[label='All models'] option" >>= traverse textContent >>= (`shouldBe` ["Claude Opus 4.8", "Claude Haiku 4.5"])
    -- Kept under the user's id, and only theirs.
    eventually $ (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Just (ApiKey "sk-ant-test-key"))
    (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-admin") >>= (`shouldBe` Nothing)
    -- The page never shows a key once kept.
    outerHTML anthropic >>= (`shouldNotSatisfy'` T.isInfixOf "sk-ant-test-key")
    -- Forgotten, it is gone from the browser.
    findIn anthropic ".assistant-forget" >>= click
    eventually $ findIn anthropic ".assistant-key" >>= (`getProperty` "value") >>= (`shouldBe` "")
    eventually $ (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)
    (\s -> (settingsOf Anthropic s).fetched) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)
    -- The scripted provider, chosen and tested: its script refuses, then
    -- accepts.
    find ui "input[name='assistant-provider'][value='scripted']" >>= click
    eventually $ (\s -> s.provider) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Scripted)
    scripted <- find ui ".assistant-provider-settings[data-provider='scripted']"
    findIn scripted ".assistant-test" >>= click
    eventually $ findIn scripted ".assistant-check-works" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The key works")

  it "chooses each provider's default effort on the settings page, medium unless one is chosen" $ runPage $ do
    scriptWith [] (object ["anthropic" .= take 2 scriptedModels])
    keep m (UserId "user-editor") (withKey Anthropic (Just "sk-ant-test") defaultSettings)
    (ui, _) <- startWith m (Just "user-editor") AssistantSettings
    anthropic <- find ui ".assistant-provider-settings[data-provider='anthropic']"
    findIn anthropic ".assistant-default-effort" >>= (`getProperty` "value") >>= (`shouldBe` "medium")
    findAllIn anthropic ".assistant-default-effort option" >>= traverse textContent >>= (`shouldBe` ["low", "medium (default)", "high", "xhigh", "max"])
    openai <- find ui ".assistant-provider-settings[data-provider='openai']"
    findAllIn openai ".assistant-default-effort option" >>= traverse textContent >>= (`shouldBe` ["minimal", "low", "medium (default)", "high"])
    let choose effort = do
          eventually $ findIn anthropic ".assistant-default-effort" >>= (`getAttribute` "disabled") >>= (`shouldBe` Nothing)
          void (unsafeIOToPageM (js_choose (toJSText ".assistant-provider-settings[data-provider='anthropic'] .assistant-default-effort") (toJSText effort)))
    choose "high"
    eventually $ (\s -> (settingsOf Anthropic s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Just "high")
    (\s -> (settingsOf OpenAI s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)
    -- The default chosen again is kept as none chosen.
    choose "medium"
    eventually $ (\s -> (settingsOf Anthropic s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)

-- | The editor on the demo's first post, as its author, with the scripted
-- provider chosen and the panel open; and the page's Markdown.
openAssistantWith
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m, Text)
openAssistantWith m = do
  keep m (UserId "user-editor") (chooseProvider Scripted defaultSettings)
  openAssistantKeptWith m

-- | The same with the settings kept as they are.
openAssistantKeptWith
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m, Text)
openAssistantKeptWith m = do
  (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
  _ <- editorText ui
  original <- markdown ui
  find ui scriptedButton >>= click
  _ <- find ui ".assistant-input"
  eventually $ find ui ".assistant-using" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Scripted")
  pure (ui, original)

openAssistant
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m)
openAssistant m = fst <$> openAssistantWith m

openAssistantKept
  :: forall m
  ->(Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m)
openAssistantKept m = fst <$> openAssistantKeptWith m

-- | The scripted provider's button, which a test's page has.
scriptedButton :: Text
scriptedButton = ".editor-provider[data-provider='scripted']"

-- | Type a message, and send it.
send :: Mounted s q o n -> Text -> PageM s ()
send ui message = do
  find ui ".assistant-input" >>= (`typeText` message)
  find ui ".assistant-send" >>= click

keep :: forall m -> (MonadBrowserTest m, MonadAssistant m) => UserId -> Settings -> PageM s ()
keep m user settings = void (unsafeIOToPageM (runTest (keepAssistantSettings user settings :: m (Either Text ()))))

settingsFor :: forall m -> (MonadBrowserTest m, MonadAssistant m) => UserId -> PageM s Settings
settingsFor m user = unsafeIOToPageM (either (const defaultSettings) identity <$> runTest (assistantSettings user :: m (Either Text Settings)))

-- | Install the scripted provider's script: the steps of each turn.
script :: [[Value]] -> PageM s ()
script turns = scriptWith turns (object [])

-- | The same, with the providers' lists of models, by provider.
scriptWith :: [[Value]] -> Value -> PageM s ()
scriptWith turns lists = unsafeIOToPageM $ do
  js_forget
  js_script (toJSText (decodeUtf8 (BSL.toStrict (encode (object ["turns" .= turns, "lists" .= lists])))))

-- | The providers' lists of models changed, the rest of the script kept.
setLists :: Value -> PageM s ()
setLists lists = void (unsafeIOToPageM (js_lists (toJSText (decodeUtf8 (BSL.toStrict (encode lists))))))

-- | A provider's list of models, as Anthropic's names them, newest first:
-- two recommended (Opus and Sonnet, newest of their families without a
-- date) and two others.
scriptedModels :: [Value]
scriptedModels =
  [ object ["id" .= i, "label" .= l, "created" .= t]
  | (i, l, t) <-
      [ ("claude-opus-5-5" :: Text, "Claude Opus 5.5" :: Text, 300 :: Int)
      , ("claude-sonnet-5-5", "Claude Sonnet 5.5", 250)
      , ("claude-opus-4-8", "Claude Opus 4.8", 200)
      , ("claude-haiku-4-5-20251001", "Claude Haiku 4.5", 100)
      ]
  ]

-- | What the scripted provider was sent, and what its tools were answered.
requests, answers :: PageM s [Value]
requests = unsafeIOToPageM (decoded <$> js_requests)
answers = unsafeIOToPageM (decoded <$> js_answers)

decoded :: JSText -> [Value]
decoded = fromMaybe [] . decodeStrict . encodeUtf8 . fromJSText

-- | Steps of a script.
text :: Text -> Value
text t = object ["text" .= t]

replace :: Text -> Text -> Value
replace old new = object ["tool" .= ("replace" :: Text), "input" .= object ["old_text" .= old, "new_text" .= new]]

insert :: Text -> Text -> Text -> Value
insert anchor place t = object ["tool" .= ("insert" :: Text), "input" .= object ["anchor" .= anchor, "where" .= place, "text" .= t]]

hold :: Value
hold = object ["hold" .= True]

-- | A summary of thinking, streamed.
thinking :: Text -> Value
thinking t = object ["thinking" .= t]

-- | A pause of so many milliseconds, before the next step.
quiet :: Int -> Value
quiet ms = object ["wait" .= ms]

-- | A tool call that the model takes so many milliseconds to write: the
-- call starts, and is made after the pause.
pausing :: Int -> Value -> Value
pausing ms (Aeson.Object o) = Aeson.Object (o <> KeyMap.fromList [("pause", Aeson.toJSON ms)])
pausing _ other = other

failing :: Text -> Int -> Text -> Value
failing kind status message = object ["error" .= object ["kind" .= kind, "status" .= status, "message" .= message]]

-- | A text at a path into a JSON value, by keys and array indices.
fieldText :: [Text] -> Value -> Maybe Text
fieldText path v = case at path v of
  Just (Aeson.String t) -> Just t
  _ -> Nothing

fieldBool :: Text -> Value -> Maybe Bool
fieldBool name v = case at [name] v of
  Just (Aeson.Bool b) -> Just b
  _ -> Nothing

at :: [Text] -> Value -> Maybe Value
at [] v = Just v
at (k : ks) v = case v of
  Aeson.Object o -> Aeson.parseMaybe (Aeson..: Key.fromText k) o >>= at ks
  Aeson.Array a -> readMaybe k >>= \i -> (toList a `atMay` i) >>= at ks
  _ -> Nothing

shouldNotSatisfy' :: (Show a) => a -> (a -> Bool) -> PageM s ()
shouldNotSatisfy' x p = x `shouldSatisfy` (not . p)
