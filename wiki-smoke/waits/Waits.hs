-- | That the driver's waits hold on the wiki, on the built demo: the cases
-- the ported smoke tests rely on.
--
-- * After typing in the editor, 'waitQuiet' returns once the preview,
--   which follows the text after a pause in typing (a debounce, written
--   @liftIO (threadDelay n)@), shows what was typed.
-- * After a save, 'waitQuiet' returns once the save is done, with
--   \"Saved\" still shown: the notice's timer is @H.delay@, which
--   'waitQuiet' does not wait for.
-- * After Send to the writing assistant, 'waitQuiet' returns once the
--   model's answer has ended: the turn arrives through an emitter, and the
--   panel keeps a fiber waiting for its end, so the turn counts as the
--   program's work. Its seconds counter (@H.delay@) does not.
-- * While a turn is held, the program says a fiber is waiting; once it is
--   stopped, 'waitQuiet' returns with the turn shown as stopped.
--
-- Each reads the page once after 'waitQuiet', with no retry, so that a wait
-- that returned too early fails. Run it slowed down as well
-- (@HALOGEN_PLAYWRIGHT_THROTTLE=4@), as the smoke tests' throttled run will.
module Main (main) where

import Control.Monad (unless)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTime)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Text.Printf (printf)
import Wiki.Smoke.Demo

main :: IO ()
main = withDemo "the driver's waits, on the wiki" spec

spec :: Demo -> Spec
spec demo = playwright $ do
  describe "the editor" $ onOnePage demoContext (\_ -> pure ()) $ do
    it "waitQuiet after typing returns once the preview shows what was typed" $ \page -> do
      openEditor page
      click (locator page "#app .editor-side-by-side")
      let text = editorText page
      pressOn text "Control+End"
      typeText text "\n\nQuiet words for the preview."
      seconds <- timed (waitQuiet page)
      report (printf "waitQuiet after typing: %.2f s (the preview's pause, then the draft's)" seconds)
      count (withText "Quiet words for the preview." (locator page "#app .editor-preview p")) `shouldReturn` 1

    it "waitQuiet after a save returns with \"Saved\" still shown" $ \page -> do
      click (locator page "#app .editor-save")
      seconds <- timed (waitQuiet page)
      report (printf "waitQuiet after Save: %.2f s, the notice shown for 3 s" seconds)
      textContent (locator page "#app .editor-saved-notice") `shouldReturn` "Saved"
      -- The notice still goes, after its 3 seconds: a timer, not the
      -- program's work, so a condition with a deadline.
      _ <- awaitText (locator page "#app .editor-saved-notice") Text.null
      nothingThrown page

  describe "the writing assistant" $ onOnePage demoContext (\page -> addInitScript (pageContext page) assistantScript) $ do
    it "waitQuiet after Send returns once the answer has ended" $ \page -> do
      openEditor page
      click (locator page "#app .editor-provider[data-provider='scripted']")
      waitQuiet page
      fill (locator page "#app .assistant-input") "Say something."
      click (locator page "#app .assistant-send")
      -- The script thinks for 4 seconds, longer than the panel waits before
      -- its seconds counter shows, then answers.
      seconds <- timed (waitQuiet (withTimeout 60000 page))
      report (printf "waitQuiet after Send: %.2f s (the model's 4 s, the counter ticking)" seconds)
      count (locator page "#app .assistant-message.from-model .assistant-took") `shouldReturn` 1
      textContent (locator page "#app .assistant-message.from-model .assistant-text") `shouldReturn` "Done."
      count (locator page "#app .assistant-message.from-model .assistant-thinking") `shouldReturn` 0
      nothingThrown page

    it "counts a held turn as a waiting fiber, and waitQuiet returns once it is stopped" $ \page -> do
      fill (locator page "#app .assistant-input") "Say more."
      click (locator page "#app .assistant-send")
      count (locator page "#app .assistant-message.from-model .assistant-thinking") `shouldReturn` 1
      -- The second turn holds until it is stopped: the panel's fiber waits.
      waiting <- maybe 0 (\a -> a.waiting) <$> activity page
      waiting `shouldSatisfy` (>= 1)
      -- The counter shows once the model has been quiet for 3 seconds: the
      -- ticker's timer, not the program's work, so a condition.
      waitFor (locator page "#app .assistant-waited") Visible
      settle page
      count (locator page "#app .assistant-stopped") `shouldReturn` 0
      click (locator page "#app .assistant-stop")
      seconds <- timed (waitQuiet page)
      report (printf "waitQuiet after Stop: %.2f s" seconds)
      count (locator page "#app .assistant-stopped") `shouldReturn` 1
      count (locator page "#app .assistant-waited") `shouldReturn` 0
      count (locator page "#app .assistant-message.from-model .assistant-thinking") `shouldReturn` 0
      nothingThrown page
  where
    openEditor page = do
      visit page (address demo "/s/blog/p/hello-world/edit/")
      -- The page and its draft, read from the demo's IndexedDB.
      waitQuiet page
      -- CodeMirror, an island the program does not draw.
      waitFor (editorText page) Visible

    editorText page = locator page "#app .editor-cm .cm-content"

-- | The scripted provider (wiki-app's @jsbits/assistant.js@), installed
-- before the program starts, as no page served to anyone has it. Two turns:
-- one that thinks for 4 seconds and answers, and one that thinks, then holds
-- until it is stopped, so that the model is still at work whenever the test
-- reads the page.
assistantScript :: Text
assistantScript =
  "globalThis.wikiAssistantScript = {\
  \  lists: { scripted: [{ id: 'claude-opus-5-5', label: 'Claude Opus 5.5', created: 300 }] },\
  \  turns: [\
  \    [{ thinking: 'Weighing the words.', wait: 4000 }, { text: 'Done.' }],\
  \    [{ thinking: 'Weighing more words.' }, { hold: true }],\
  \  ],\
  \};"

-- | How long an action took, in seconds.
timed :: IO () -> IO Double
timed action = do
  start <- getMonotonicTime
  action
  end <- getMonotonicTime
  pure (end - start)

report :: String -> IO ()
report line = unless (null line) (putStrLn ("      " <> line))
