{-# LANGUAGE TemplateHaskell #-}

-- | The writing assistant in a browser, in the editor, over the demo's
-- wiki, with the scripted provider (@jsbits/assistant.js@) answering as a
-- model would: a message sent with a selection, whose answer streams in and
-- whose tool call edits the page as a tracked change, accepted (and then
-- undone as usual) or rejected; two edits in one turn, an insertion at the
-- end, and Reject all; an edit whose text is not in the page, refused with
-- the tool's answer and followed by the model's text; a turn stopped, by
-- Stop and by closing the panel; an error shown without anything like a
-- key in it; and the settings page: keys kept per user, forgotten, and
-- tested. The providers themselves cannot be reached from here: they are
-- tested over their SDKs by toolchain/test-assistant.mjs.
module Test.Browser.Assistant (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value, decodeStrict, encode, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
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
import Wiki.Core.Assistant (Provider (..), ProviderSettings (..), Settings (..), chooseProvider, defaultSettings, settingsOf, withKey)
import Wiki.Core.Id (UserId (..))

$( browserJS
     ["jsbits/test-assistant.js"]
     [ ("js_script", "wiki_test_assistant_script", Unsafe, [t|JSText -> IO ()|])
     , ("js_forget", "wiki_test_assistant_forget", Unsafe, [t|IO ()|])
     , ("js_requests", "wiki_test_assistant_requests", Unsafe, [t|IO JSText|])
     , ("js_answers", "wiki_test_assistant_answers", Unsafe, [t|IO JSText|])
     , ("js_select", "wiki_test_editor_select", Unsafe, [t|Int -> Int -> IO Bool|])
     , ("js_choose", "wiki_test_choose", Unsafe, [t|JSText -> JSText -> IO Bool|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "sends a selection, streams the answer, and makes its edit a change that Accept keeps and Ctrl+Z undoes" $ runPage $ do
    script [[text "I will ", text "make it the very first.", replace "the first post" "the very first post", text " Done."]]
    ui <- openAssistant m
    _ <- unsafeIOToPageM (js_select 16 38)
    chip <- find ui ".assistant-scope .assistant-chip"
    chip `shouldHaveText` "line 3×"
    -- The effort, chosen under the message, goes with it, and is kept.
    find ui ".assistant-effort" >>= (`getProperty` "value") >>= (`shouldBe` "low")
    _ <- unsafeIOToPageM (js_choose (toJSText ".assistant-effort") (toJSText "high"))
    eventually $ (\s -> (settingsOf Scripted s).effort) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` "high")
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
    find ui ".assistant-stop" >>= click
    eventually $ find ui ".assistant-stopped" >>= (`shouldHaveText` "Stopped.")
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

  it "opens with a provider from its button, and switching starts a new conversation with the changes kept" $ runPage $ do
    script [[replace "## Why a wiki" "## Why", text "Retitled."]]
    ui <- openAssistant m
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    find ui ".editor-provider[data-provider='anthropic']" >>= (`getAttribute` "title") >>= (`shouldBe` Just "Chat with Claude")
    find ui ".editor-provider[data-provider='openai']" >>= (`getAttribute` "title") >>= (`shouldBe` Just "Chat with ChatGPT")
    send ui "Retitle it."
    eventually $ find ui ".assistant-message.from-model .assistant-text" >>= (`shouldHaveText` "Retitled.")
    -- Claude, which has no key here: the panel stays, its conversation
    -- ends, and it says where the key goes; the change is still to decide.
    find ui ".editor-provider[data-provider='anthropic']" >>= click
    eventually $ find ui ".assistant-notice" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The next message starts a new one with Anthropic (Claude).")
    find ui ".assistant-setup" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "There is no API key for Anthropic (Claude)")
    find ui ".editor-provider[data-provider='anthropic']" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    find ui scriptedButton >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "false")
    eventually $ (\s -> s.provider) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Anthropic)
    find ui ".cm-wiki-inserted" >>= (`shouldHaveText` "## Why")
    find ui ".assistant-pending" >>= (`shouldHaveText` "1 suggested change to accept or reject")
    -- Claude's models and efforts are offered under the message.
    findAll ui ".assistant-effort option" >>= traverse textContent >>= (`shouldBe` ["low", "medium", "high", "xhigh", "max"])
    find ui ".assistant-model-choice" >>= (`getProperty` "value") >>= (`shouldBe` "claude-opus-5-5")

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

  it "keeps a key for each user, forgets it, and tests it" $ runPage $ do
    script []
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
    -- Kept under the user's id, and only theirs.
    eventually $ (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Just "sk-ant-test-key")
    (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-admin") >>= (`shouldBe` Nothing)
    -- The page never shows a key once kept.
    outerHTML anthropic >>= (`shouldNotSatisfy'` T.isInfixOf "sk-ant-test-key")
    -- Forgotten, it is gone from the browser.
    findIn anthropic ".assistant-forget" >>= click
    eventually $ findIn anthropic ".assistant-key" >>= (`getProperty` "value") >>= (`shouldBe` "")
    eventually $ (\s -> (settingsOf Anthropic s).key) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Nothing)
    -- The scripted provider, chosen and tested: its script refuses, then
    -- accepts.
    find ui "input[name='assistant-provider'][value='scripted']" >>= click
    eventually $ (\s -> s.provider) <$> settingsFor m (UserId "user-editor") >>= (`shouldBe` Scripted)
    scripted <- find ui ".assistant-provider-settings[data-provider='scripted']"
    findIn scripted ".assistant-test" >>= click
    eventually $ findIn scripted ".assistant-check-works" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "The key works")

-- | The editor on the demo's first post, as its author, with the scripted
-- provider chosen and the panel open; and the page's Markdown.
openAssistantWith
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m, Text)
openAssistantWith m = do
  keep m (UserId "user-editor") (chooseProvider Scripted defaultSettings)
  (ui, _) <- startWith m (Just "user-editor") (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
  _ <- editorText ui
  original <- markdown ui
  find ui scriptedButton >>= click
  _ <- find ui ".assistant-input"
  eventually $ find ui ".assistant-using" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Scripted")
  pure (ui, original)

openAssistant
  :: forall m
  ->(MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m)
  => PageM s (Mounted s Shell.Query Void m)
openAssistant m = fst <$> openAssistantWith m

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
script turns = unsafeIOToPageM $ do
  js_forget
  js_script (toJSText (decodeUtf8 (BSL.toStrict (encode (object ["turns" .= turns])))))

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
