-- | That the driver's waits hold on the wiki, on the built demo: the cases
-- the ported smoke tests rely on.
--
-- * After typing in the editor, 'waitQuiet' returns once the preview,
--   which follows the text after a pause in typing (a debounce, written
--   @liftIO (threadDelay n)@), shows what was typed.
-- * After a save, 'waitQuiet' returns once the save is done, with
--   \"Saved\" still shown: the notice's timer is @H.delay@, which
--   'waitQuiet' does not wait for.
-- * While the writing assistant's model works, its seconds counter ticks
--   (@H.delay@ too), and 'waitQuiet' returns between the ticks.
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
    it "waitQuiet returns while the model works and the seconds counter ticks" $ \page -> do
      openEditor page
      click (locator page "#app .editor-provider[data-provider='scripted']")
      waitQuiet page
      fill (locator page "#app .assistant-input") "Say something."
      click (locator page "#app .assistant-send")
      first' <- timed (waitQuiet page)
      report (printf "waitQuiet after Send: %.2f s" first')
      count (locator page "#app .assistant-message.from-model .assistant-thinking") `shouldReturn` 1
      -- The counter shows once the model has been quiet for 3 seconds: the
      -- ticker's timer, not the program's work, so a condition.
      waitFor (locator page "#app .assistant-waited") Visible
      settle page
      second' <- timed (waitQuiet page)
      report (printf "waitQuiet with the counter ticking: %.2f s" second')
      -- The model is still at work: the script holds the turn until it is
      -- stopped, so this holds however slow the machine.
      count (locator page "#app .assistant-message.from-model .assistant-thinking") `shouldReturn` 1
      count (locator page "#app .assistant-stopped") `shouldReturn` 0
      -- Stopped, the turn ends through the provider's callbacks, not a
      -- fiber of the program's waiting for it: its end is a condition.
      click (locator page "#app .assistant-stop")
      waitFor (locator page "#app .assistant-stopped") Visible
      settle page
      waitQuiet page
      count (locator page "#app .assistant-waited") `shouldReturn` 0
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
-- before the program starts, as no page served to anyone has it: one turn
-- that thinks, then holds until it is stopped, so that the seconds counter
-- shows and the model is still at work whenever the test reads the page.
assistantScript :: Text
assistantScript =
  "globalThis.wikiAssistantScript = {\
  \  lists: { scripted: [{ id: 'claude-opus-5-5', label: 'Claude Opus 5.5', created: 300 }] },\
  \  turns: [[{ thinking: 'Weighing the words.' }, { hold: true }]],\
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
