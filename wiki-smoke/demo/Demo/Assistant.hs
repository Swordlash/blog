-- | The fifth part of the demo's smoke test: the writing assistant (WP4.19,
-- WP5.11), with the scripted provider. Its settings from the user menu,
-- with a key kept and a default effort, and its panel in the editor:
-- "Thinking" and the edit's status while the model works, the times of
-- the messages, the model's edit tracked in the text and accepted, and
-- Close.
--
-- No provider can be reached from here, and no key is at hand: the page
-- gets the scripted provider the browser tests use
-- (@wiki-app/jsbits/assistant.js@), installed before the program starts,
-- as no page served to anyone has it. The providers' own island is loaded
-- all the same, to see that the bundle runs in a browser.
--
-- The turn is the program's work while it lasts (the panel waits for its
-- end in a fiber), so 'waitQuiet' after Send returns once the answer has
-- ended. What the panel shows while the model works comes at the pace of
-- the provider's script, and is waited for as conditions.
module Demo.Assistant (spec) where

import Data.Text (Text)
import Data.Text qualified as Text
import Demo.Site
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Wiki.Smoke.Demo

spec :: Site -> SpecWith Playwright
spec site =
  it "keeps a key with its models and a default effort, and its panel shows the model at work, its edit tracked and accepted" $ onDemoPage demoContext $ \page -> do
    addInitScript (pageContext page) script
    visit page (address site.demo "/")
    waitQuiet page
    count (withText "Spaces" (locator page "#app .wiki-home .page-view h1")) `shouldReturn` 1
    -- The settings, from the user menu: the demo starts as admin.
    click (locator page "#app .user-switcher-toggle")
    click (locator page "#app .user-menu .assistant-settings-entry")
    waitQuiet page
    count (withText "Writing assistant" (locator page "#app .assistant-settings h1")) `shouldReturn` 1
    crumb page `shouldReturn` "Writing assistant"
    textContent (locator page "#app .assistant-intro") >>= (`shouldSatisfy` Text.isInfixOf "billed by its provider")
    -- The demo, served from this machine, is a secure context.
    count (locator page "#app .assistant-insecure") `shouldReturn` 0
    evaluate page "(async () => typeof (await globalThis.wikiIslands.assistant()).startChat)()" `shouldReturn` ("function" :: Text)
    check (locator page "#app input[name='assistant-provider'][value='scripted']")
    click (locator page "#app .assistant-provider-settings[data-provider='scripted'] .assistant-test")
    waitQuiet page
    count (locator page "#app .assistant-check-works") `shouldReturn` 1
    -- A key for Claude, kept, its list of models fetched with it (from the
    -- script, which answers for every provider on this page).
    let claude = locator page "#app .assistant-provider-settings[data-provider='anthropic']"
    fill (locator claude ".assistant-key") "sk-ant-smoke"
    click (locator claude ".assistant-key-form button[type='submit']")
    waitQuiet page
    textContent (locator claude ".assistant-listed") >>= (`shouldSatisfy` Text.isInfixOf "2 models fetched")
    -- The scripted provider's default effort, high, for new conversations.
    let effort = locator page "#app .assistant-provider-settings[data-provider='scripted'] .assistant-default-effort"
    inputValue effort `shouldReturn` "medium"
    selectOption effort ["high"]
    waitQuiet page
    isDisabled effort `shouldReturn` False
    -- The editor's panel: a message, the model's edit a tracked change in
    -- the text, accepted.
    visit page (address site.demo "/s/blog/p/hello-world/edit/")
    waitQuiet page
    editorReady page
    -- The providers' bubbles over the text, with their logos: Claude's,
    -- which has a key, not ChatGPT's, which has none; the scripted
    -- provider's is there as the page has its script.
    let bubble provider = locator page ("#app .editor-provider[data-provider='" <> provider <> "']")
    getAttribute (bubble "anthropic") "title" `shouldReturn` Just "Chat with Claude"
    count (locator (bubble "anthropic") "svg path") `shouldReturn` 1
    count (bubble "openai") `shouldReturn` 0
    click (bubble "scripted")
    waitQuiet page
    textContent (locator page "#app .assistant-using") >>= (`shouldSatisfy` Text.isInfixOf "Scripted")
    -- Its models, as its list has them, grouped.
    groups :: [(Text, [Text])] <-
      evaluateAll
        (locator page "#app .assistant-model-choice optgroup")
        "(groups) => groups.map((g) => [g.label, [...g.children].map((o) => o.textContent)])"
        ()
    groups `shouldBe` [("Recommended", ["Claude Opus 5.5", "Claude Sonnet 5.5"]), ("All models", ["Claude Opus 4.8"])]
    -- The effort under the message starts at the settings' default; one
    -- chosen there goes with the message.
    inputValue (locator page "#app .assistant-effort") `shouldReturn` "high"
    selectOption (locator page "#app .assistant-effort") ["low"]
    fill (locator page "#app .assistant-input") "Retitle the second heading."
    click (locator page "#app .assistant-send")
    -- While the model works: "Thinking" with its summary, then the status
    -- of the edit it is writing, each when the provider's script gets to
    -- it. Send reads the clock (in a liftIO) before it shows "Thinking",
    -- and the driver's settle does not wait for a liftIO; waitQuiet would,
    -- but it waits for the whole turn too, which is counted as the
    -- program's work. So the line itself is waited for.
    let fromModel = locator page "#app .assistant-message.from-model"
    waitFor (withText "Thinking" (locator fromModel ".assistant-thinking")) Attached
    waitFor (withText "Weighing the heading." (locator fromModel ".assistant-thinking-text")) Attached
    waitFor (withText "Editing the page" (locator fromModel ".assistant-status")) Visible
    -- The answer, once it has ended.
    waitQuiet (withTimeout 60000 page)
    count (withText "## Why this is a wiki" (locator page "#app .cm-wiki-inserted")) `shouldReturn` 1
    count (withText "## Why a wiki" (locator page "#app .cm-wiki-removed")) `shouldReturn` 1
    textContent (locator fromModel ".assistant-text") >>= (`shouldSatisfy` Text.isInfixOf "Retitled. Done.")
    -- The time of each message, and how long the answer took.
    count (locator fromModel ".assistant-took") `shouldReturn` 1
    count (locator page "#app .assistant-message .assistant-time") `shouldReturn` 2
    click (locator page "#app .assistant-accept-all")
    count (locator page "#app .cm-wiki-inserted") `shouldReturn` 0
    markdownIn page >>= (`shouldSatisfy` maybe False (Text.isInfixOf "\n## Why this is a wiki\n"))
    evaluate page "globalThis.wikiAssistantScript.requests[0].request.output_config.effort" `shouldReturn` ("low" :: Text)
    -- Close, in the panel's header.
    click (withText "Close" (locator page "#app .assistant-head .assistant-close"))
    isVisible (locator page "#app .editor-assistant") `shouldReturn` False
    nothingWrong page

-- | The scripted provider's lists of models and its one turn: a thought,
-- a text, an edit made after a pause, and the end.
script :: Text
script =
  "(() => {\
  \  const model = (id, label, created) => ({ id, label, created });\
  \  globalThis.wikiAssistantScript = {\
  \    lists: {\
  \      scripted: [model('claude-opus-5-5', 'Claude Opus 5.5', 300), model('claude-sonnet-5-5', 'Claude Sonnet 5.5', 250), model('claude-opus-4-8', 'Claude Opus 4.8', 200)],\
  \      anthropic: [model('claude-opus-5-5', 'Claude Opus 5.5', 300), model('claude-haiku-4-5-20251001', 'Claude Haiku 4.5', 100)],\
  \    },\
  \    turns: [\
  \      [\
  \        { thinking: 'Weighing the heading.', wait: 1500 },\
  \        { text: 'Retitled. ' },\
  \        { tool: 'replace', input: { old_text: '## Why a wiki', new_text: '## Why this is a wiki' }, pause: 1500 },\
  \        { text: 'Done.' },\
  \      ],\
  \    ],\
  \  };\
  \})();"
