-- | The README's screenshots, taken from the built demo in headless
-- Chromium, so that they can be taken again whenever the wiki's look
-- changes:
--
-- > npm run screenshots       # after: npm run build-wasm; into docs/screenshots
--
-- Each view is opened in a fresh context ('onDemoPage') at a fixed size,
-- 1280 by 800, in the light scheme (the administration in the dark one
-- too); once the islands' libraries have drawn what the view shows
-- (KaTeX's formulas and fonts, Mermaid's diagrams, highlight.js's colours,
-- CodeMirror), a PNG of the window is written:
--
-- * @page.png@: the Markdown guide at its Mathematics section, formulas
--   and, under them, a diagram;
-- * @editor.png@: the editor on the Mathematics page, the preview beside it;
-- * @slides.png@: the Presentations deck at its slide of formulas;
-- * @spaces.png@: the front page, the directory of spaces;
-- * @admin-users.png@, @admin-users-dark.png@: the administration's users,
--   with a few more users made in it, in the light and the dark scheme;
-- * @admin-dialog.png@, @admin-dialog-dark.png@: the same with a user's
--   \"Manage\" dialog open;
-- * @admin-remove.png@, @admin-remove-dark.png@: a disabled user's dialog,
--   asking to remove the account, the login typed.
--
-- The pictures go to @WIKI_SCREENSHOTS_DIR@, which
-- @toolchain/smoke-suite.sh screenshots@ (npm run screenshots) sets to
-- @docs/screenshots@; without it, to a temporary directory, deleted at the
-- end, so that @cabal test@ after a wasm build changes no file of the
-- repository. The README shows them, and each must be under 300 KB, which
-- this suite checks as @wiki-app-test@'s Test.Readme does.
module Main (main) where

import Control.Monad (forM_, when)
import Data.Text (Text)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import System.Directory (createDirectoryIfMissing, getFileSize, makeAbsolute)
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Wiki.Smoke.Demo

main :: IO ()
main = do
  given <- lookupEnv "WIKI_SCREENSHOTS_DIR"
  let run out = do
        createDirectoryIfMissing True out
        withDemo "the README's screenshots" (spec out)
  case given of
    Just dir | not (null dir) -> makeAbsolute dir >>= run
    _ -> withSystemTempDirectory "wiki-screenshots" run

spec :: FilePath -> Demo -> Spec
spec out demo = playwright $ do
  -- A page with formulas and a diagram: the Markdown guide, scrolled to its
  -- Mathematics section, under which is the Diagrams section's flowchart.
  it "page.png: the Markdown guide's formulas and a diagram" $ onDemoPage demoContext $ \page -> do
    visit page (address demo "/s/docs/p/markdown-guide/")
    waitQuiet page
    formulasSet page "#app .page-body"
    waitFor (first (locator page "#app .page-body .wiki-mermaid > svg")) Visible
    waitFor (first (locator page "#app .page-body .wiki-code code.hljs")) Visible
    waitForFunction page "document.fonts.check('16px \"KaTeX_Main\"')"
    -- The heading at the top, below whatever stays at the top of the
    -- window as it scrolls (the header, the page's actions), with a little
    -- room above, or less room where that keeps the whole of the diagram
    -- under it in the window.
    _ :: Maybe Bool <-
      evaluate
        page
        "(() => {\
        \  const heading = document.getElementById('mathematics');\
        \  heading.scrollIntoView({ block: 'start' });\
        \  const stuck = [...document.querySelectorAll('#app *')]\
        \    .filter((e) => ['sticky', 'fixed'].includes(getComputedStyle(e).position))\
        \    .map((e) => e.getBoundingClientRect())\
        \    .filter((r) => r.top < 200 && r.width > window.innerWidth / 3)\
        \    .reduce((bottom, r) => Math.max(bottom, r.bottom), 0);\
        \  window.scrollBy(0, heading.getBoundingClientRect().top - stuck - 16);\
        \  const diagram = document.querySelector('#app .page-body .wiki-mermaid > svg').getBoundingClientRect();\
        \  const below = diagram.bottom - (window.innerHeight - 12);\
        \  if (below > 0) window.scrollBy(0, Math.min(below, heading.getBoundingClientRect().top - stuck));\
        \  return null;\
        \})()"
    shoot page "page.png"

  -- The editor, with the preview beside the Markdown: the "Side by side"
  -- button, which a wide window offers, pressed.
  it "editor.png: the editor with the preview beside it" $ onDemoPage demoContext $ \page -> do
    visit page (address demo "/s/docs/p/markdown-guide/mathematics/edit/")
    waitQuiet page
    waitFor (locator page "#app .editor-cm .cm-content") Visible
    click (locator page "#app .editor-side-by-side")
    getAttribute (locator page "#app .editor-side-by-side") "aria-pressed" `shouldReturn` Just "true"
    formulasSet page "#app .editor-preview"
    shoot page "editor.png"

  -- A deck, at its third slide: a formula inline and one on its own.
  it "slides.png: the deck's slide of formulas" $ onDemoPage demoContext $ \page -> do
    visit page (address demo "/s/docs/p/markdown-guide/presentations/slides/?slide=3")
    waitQuiet page
    waitFor (locator page "#app .slide-frame.current .wiki-math-display .katex-display") Visible
    formulasSet page "#app .slide-frame.current"
    mouseMove page 640 400
    shoot page "slides.png"

  -- The front page: the directory of spaces, as a newcomer sees it.
  it "spaces.png: the directory of spaces" $ onDemoPage demoContext $ \page -> do
    visit page (address demo "/")
    waitQuiet page
    count (locator page "#app .space-card") >>= (`shouldSatisfy` (> 0))
    shoot page "spaces.png"

  -- The administration's users and a user's dialog, light and dark.
  administration "light" Light ""
  administration "dark" Dark "-dark"
  where
    administration :: String -> ColorScheme -> String -> SpecWith Playwright
    administration name scheme suffix =
      describe ("the administration's users, in the " <> name <> " scheme") $
        onOnePage demoContext {colorScheme = Just scheme} (\_ -> pure ()) $
          do
            it "adds four users to the demo's three, and disables Dora" $ \page -> do
              -- The demo's users, read from its IndexedDB.
              visit page (address demo "/admin/users/")
              waitQuiet page
              count (locator page "#app .user-row") >>= (`shouldSatisfy` (> 0))
              forM_ moreUsers $ \(login, name', administrator) -> do
                click (locator page "#app .user-create-open")
                fill (locator page "#app .user-create-login") login
                fill (locator page "#app .user-create-name") name'
                fill (locator page "#app .user-create-password") (login <> "'s password")
                when administrator $ check (locator page "#app .user-create-administrator input")
                click (locator page "#app .user-create button.primary")
                waitQuiet page
                count (locator page ("#app .user-row[data-login=" <> login <> "]")) `shouldReturn` 1
              -- Dora's login disabled, from her dialog, which asks first.
              click (locator page "#app .user-row[data-login=dora] .user-manage")
              click (locator page "#app .user-dialog .disable-toggle")
              click (locator page "#app .user-dialog .disable-confirm-button")
              waitQuiet page
              count (locator page "#app .user-row[data-login=dora].user-disabled") `shouldReturn` 1
              press page "Escape"
              count (locator page "#app .user-dialog") `shouldReturn` 0
              nothingThrown page

            it ("admin-users" <> suffix <> ".png: the users") $ \page -> do
              mouseMove page 1270 790
              shoot' page ("admin-users" <> suffix <> ".png")

            -- Dora's dialog again, asking to remove her account, her login
            -- typed.
            it ("admin-remove" <> suffix <> ".png: a disabled user's dialog, asking to remove the account") $ \page -> do
              click (locator page "#app .user-row[data-login=dora] .user-manage")
              click (locator page "#app .user-dialog .user-remove")
              fill (locator page "#app .user-dialog .remove-confirm-login") "dora"
              isEnabled (locator page "#app .user-dialog .remove-confirm-button") `shouldReturn` True
              _ :: Maybe Bool <-
                evaluateOn
                  (locator page "#app .user-dialog")
                  "(dialog) => { for (const e of [dialog, dialog.querySelector('.user-dialog-body')]) e.scrollTop = e.scrollHeight; return null; }"
                  ()
              settle page
              shoot' page ("admin-remove" <> suffix <> ".png")
              press page "Escape"
              count (locator page "#app .user-dialog") `shouldReturn` 0

            -- Edgar's dialog: in a group, creating spaces, no password yet.
            it ("admin-dialog" <> suffix <> ".png: a user's dialog") $ \page -> do
              click (locator page "#app .user-row[data-login=editor] .user-manage")
              -- The user's groups, read from the demo's IndexedDB.
              waitQuiet page
              count (locator page "#app .user-dialog[data-login=editor] .user-dialog-groups") `shouldReturn` 1
              _ :: Maybe Bool <- evaluateOn (locator page "#app .user-dialog") "(dialog) => { dialog.querySelector('button')?.blur(); return null; }" ()
              settle page
              shoot' page ("admin-dialog" <> suffix <> ".png")

    -- A picture of the window, once the fonts the page asked for have
    -- loaded, its images are decoded and two frames have been drawn, so
    -- that what the libraries drew last is on the screen; it must be under
    -- 300 KB. The page must have thrown nothing.
    shoot :: Page -> FilePath -> IO ()
    shoot page name = do
      shoot' page name
      nothingThrown page

    shoot' :: Page -> FilePath -> IO ()
    shoot' page name = do
      _ :: Maybe Bool <-
        evaluate
          page
          "(async () => {\
          \  await document.fonts.ready;\
          \  await Promise.all([...document.images].map((i) => i.decode().catch(() => null)));\
          \  await new Promise((frame) => requestAnimationFrame(() => requestAnimationFrame(frame)));\
          \  return null;\
          \})()"
      settle page
      let file = out </> name
      screenshotWith page defaultScreenshotOptions {fullPage = False} file
      size <- getFileSize file
      report (name <> ": " <> show (size `div` 1024) <> " KB")
      size `shouldSatisfy` (< limit)

    limit = 300 * 1024

    report = putStrLn . ("      " <>)

-- | Wait until every formula under an element is set by KaTeX, none left
-- as its source. KaTeX is an island's library, not the program's: a
-- condition with a deadline.
formulasSet :: Page -> Text -> IO ()
formulasSet page within =
  waitForFunctionWith
    page
    "(within) => {\
    \  const formulas = [...document.querySelectorAll(within + ' .wiki-math')];\
    \  return formulas.length > 0 && formulas.every((f) => f.querySelector('.katex'));\
    \}"
    within

-- | The users the administration's screenshots add to the demo's three,
-- made with its "New user" form, so that the table looks like a wiki's:
-- login, name, and whether an administrator.
moreUsers :: [(Text, Text, Bool)]
moreUsers =
  [ ("bea", "Bea Builder", True)
  , ("carl", "Carl Coder", False)
  , ("dora", "Dora Designer", False)
  , ("eve", "Eve Operations", False)
  ]
