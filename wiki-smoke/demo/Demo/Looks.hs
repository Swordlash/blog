-- | The third part of the demo's smoke test: a page in a dark scheme and at
-- a phone's width (the administration's forms too, each one column), a
-- page shown as slides (moved through, reloaded, printed), a page's source
-- and a code block copied to the clipboard, and a comment on a selection.
-- Each in a context of its own.
module Demo.Looks (spec) where

import Data.Aeson (FromJSON (..), withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.Char (isDigit, isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Demo.Site
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Wiki.Smoke.Adoption
import Wiki.Smoke.Demo

spec :: Site -> SpecWith Playwright
spec site = do
  it "follows the dark scheme, and the light one, TikZ pictures too" $ onDemoPage demoContext {colorScheme = Just Dark} $ \page -> do
    gate <- hold page adoptionOptions.program
    _ <- load site gate page "/s/docs/p/markdown-guide/"
    night <- colours page
    expect (luminance night.background < 0.25) ("a dark scheme's background is " <> show night.background)
    expect (luminance night.text > 0.6) ("a dark scheme's text is " <> show night.text)
    expect (luminance night.sidebar < 0.25) ("a dark scheme's sidebar is " <> show night.sidebar)
    -- TeX's black is drawn in the text's colour, so a picture shows on a
    -- dark page. TikZJax draws it: a condition.
    waitFor (first (locator page "#app .wiki-tikz > svg")) Visible
    settle page
    darkInk <- ink page
    expect (luminance darkInk > 0.6) ("a dark scheme's TikZ lines are " <> show darkInk)
    emulateMedia page (Scheme Light)
    day <- colours page
    expect (luminance day.background > 0.75) ("a light scheme's background is " <> show day.background)
    expect (luminance day.text < 0.4) ("a light scheme's text is " <> show day.text)
    lightInk <- ink page
    expect (luminance lightInk < 0.4) ("a light scheme's TikZ lines are " <> show lightInk)
    nothingWrong page

  it "fits a page, the editor, a page's source and the administration's forms to a phone's width" $ onDemoPage demoContext {viewport = Just (390, 844), isMobile = True, hasTouch = True} $ \page -> do
    gate <- hold page adoptionOptions.program
    let fits what = evaluate page "document.documentElement.scrollWidth <= window.innerWidth" >>= (`expect` what)
    _ <- load site gate page "/s/docs/p/markdown-guide/"
    fits "a page is wider than a phone"
    isVisible (locator page "#app .search-input") `shouldReturn` True
    isVisible (locator page "#app .user-switcher-toggle") `shouldReturn` True
    -- The editor shows the Markdown there, its toolbar wrapped to the
    -- width, and the preview instead of it when asked.
    tap (locator page "#app .user-switcher-toggle")
    tap (locator page "#app .user-menu button[data-login=admin]")
    waitQuiet page
    textContent (locator page "#app .user-switcher-toggle") >>= (`shouldSatisfy` Text.isInfixOf "Ada Admin")
    tap (withText "Edit" (locator page "#app .page-view .actions a"))
    waitQuiet page
    editorReady page
    isVisible (locator page "#app .editor-toolbar") `shouldReturn` True
    isVisible (locator page "#app .editor-side-by-side") `shouldReturn` False
    fits "the editor is wider than a phone"
    tap (locator page "#app .editor-show-preview")
    waitQuiet page
    isVisible (first (locator page "#app .editor-preview .page-body h1")) `shouldReturn` True
    isVisible (editorText page) `shouldReturn` False
    fits "the editor's preview is wider than a phone"
    -- Back goes back in the session history, and the browser's popstate
    -- shows the text.
    afterEvent page "window" "popstate" (tap (locator page "#app .editor-back"))
    isVisible (editorText page) `shouldReturn` True
    isVisible (locator page "#app .editor-preview") `shouldReturn` False
    -- A page's source wraps its long lines rather than widening the page.
    _ <- load site gate page "/s/docs/source/"
    isVisible (locator page "#app .source-text") `shouldReturn` True
    fits "a page's source is wider than a phone"
    -- The administration's forms are one column at any width (WP5.5): on a
    -- phone too, each field under the one before, and none wider than it.
    _ <- load site gate page "/admin/users/"
    tap (locator page "#app .user-create-open")
    count (locator page "#app .user-create-fields") `shouldReturn` 1
    fits "the users are wider than a phone"
    besides page [".user-create-fields"] `shouldReturn` []
    -- The dialog of a user fits the phone too.
    tap (locator page "#app .user-row[data-login=reader] .user-manage")
    waitQuiet page
    count (locator page "#app .user-dialog") `shouldReturn` 1
    fits "the dialog of a user is wider than a phone"
    box <- boundingBox (locator page "#app .user-dialog")
    (width, height) <- viewportSize page
    case box of
      Just b -> expect (b.x >= 0 && b.x + b.width <= fromIntegral width && b.height <= fromIntegral height) ("the dialog of a user does not fit a phone's screen: " <> show b)
      Nothing -> expectationFailure "the dialog of a user is not drawn"
    -- Escape closes the dialog in the browser, which tells the program by
    -- the dialog's close event.
    afterEvent page "document.querySelector('#app .user-dialog')" "close" (press page "Escape")
    count (locator page "#app .user-dialog") `shouldReturn` 0
    -- The server's form, in its own section.
    _ <- load site gate page "/admin/server/"
    tap (locator page "#app .server-provider-add")
    count (locator page "#app .server-provider-form") `shouldReturn` 1
    fits "the administration is wider than a phone"
    besides page [".server-provider-form"] `shouldReturn` []
    nothingWrong page

  -- A page presented as slides: moved through by the keys with the slide
  -- in the address, which a reload comes back to; printed, one slide to a
  -- page. Then a slide's steps: shown one at a time, kept in the address
  -- across a reload, and printed one to a page when "each step on its own
  -- page" is ticked.
  it "moves a deck by its keys, keeps its slide and step in the address across a reload, and prints a slide, or a step, to a page" $ onDemoPage demoContext $ \page -> do
    gate <- hold page adoptionOptions.program
    let slides = "/s/docs/p/markdown-guide/presentations/slides/"
        current = locator page "#app .slide-frame.current"
        -- KaTeX sets the formula on the slide: a condition on its work.
        formulaSet = do
          waitFor (locator current ".wiki-math-display .katex-display") Visible
          settle page
    _ <- load site gate page slides
    textContent (locator page "#app .slides-view .slide-frame.current .slide-title") `shouldReturn` "Presentations"
    press page "ArrowRight"
    textContent (locator page "#app .slides-position") >>= (`shouldSatisfy` Text.isInfixOf "2 / 9")
    here site page `shouldReturn` (slides <> "?slide=2")
    press page "ArrowRight"
    formulaSet
    _ <- reloadAdopted gate page
    textContent (locator page "#app .slides-position") >>= (`shouldSatisfy` Text.isInfixOf "3 / 9")
    formulaSet
    emulateMedia page Print
    printed :: (Int, [Text]) <-
      evaluate
        page
        "[\
        \  [...document.querySelectorAll('#app .slide-frame')].filter((f) => f.checkVisibility()).length,\
        \  ['.wiki-header', '.wiki-sidebar', '.slides-controls'].filter((s) => document.querySelector(`#app ${s}`)?.checkVisibility()),\
        \]"
    printed `shouldBe` (9, [])
    pages <$> pdf page `shouldReturn` 9
    emulateMedia page Screen
    _ <- load site gate page (slides <> "?slide=7")
    textContent (locator current ".slide-title") `shouldReturn` "Steps"
    stepsShown page `shouldReturn` [False, False]
    press page "ArrowRight"
    here site page `shouldReturn` (slides <> "?slide=7&step=2")
    stepsShown page `shouldReturn` [True, False]
    _ <- reloadAdopted gate page
    textContent (locator current ".slide-title") `shouldReturn` "Steps"
    stepsShown page `shouldReturn` [True, False]
    check (locator page "#app .slides-print-steps input")
    emulateMedia page Print
    printedSteps :: (Int, Int) <-
      evaluate
        page
        "[\
        \  [...document.querySelectorAll('#app .slide-frame')].filter((f) => f.checkVisibility()).length,\
        \  [...document.querySelectorAll('#app .slide-frame:not(.slide-step-copy) .slide-step')].filter((e) => !e.checkVisibility({ visibilityProperty: true })).length,\
        \]"
    printedSteps `shouldBe` (13, 0)
    pages <$> pdf page `shouldReturn` 13
    nothingWrong page

  -- Copy puts the Markdown on the clipboard, as written. Headless Chromium
  -- lets a page at it only with the permissions granted.
  it "puts a page's source on the clipboard with Copy" $ onDemoPage demoContext {permissions = clipboard} $ \page -> do
    gate <- hold page adoptionOptions.program
    _ <- load site gate page "/s/docs/source/"
    source <- textContent (locator page "#app .source-text")
    expect ("# Tour\n" `Text.isPrefixOf` source) "the source is not the tour's Markdown"
    click (locator page "#app .source-view button.source-copy")
    waitQuiet page
    textContent (locator page "#app .source-copied") >>= (`shouldSatisfy` Text.isInfixOf "Copied")
    evaluate page "navigator.clipboard.readText()" `shouldReturn` source
    nothingWrong page

  -- A code block's Copy button works on the page as the server prerendered
  -- it, before the program runs: app.wasm is held back throughout, and the
  -- islands' script alone copies the code, as the fence holds it. No
  -- program runs, so the page is reached with 'goto' and nothing waits
  -- for one.
  it "puts a code block's code on the clipboard on the prerendered page, before the program runs" $ onDemoPage demoContext {permissions = clipboard} $ \page -> do
    _ <- hold page adoptionOptions.program
    goto page (address site.demo "/s/docs/p/markdown-guide/")
    let listing = first (withText "main = putStrLn" (locator page "#app .page-body .code-block"))
    code <- textContent (locator listing "pre > code")
    expect ("main :: IO ()\n" `Text.isPrefixOf` code && "\n" `Text.isSuffixOf` code) ("the first listing is not the guide's Haskell: " <> show code)
    click (locator listing "button.code-copy")
    -- The islands' script writes the clipboard, then marks the button.
    waitFor (locator listing "button.code-copy[data-copy='copied']") Attached
    evaluate page "navigator.clipboard.readText()" `shouldReturn` code
    evaluate page "typeof globalThis.wikiIslands" `shouldReturn` ("object" :: Text)
    nothingWrong page

  -- Comments: the first post's quote marked as it was prerendered, text
  -- selected in it commented on from the button beside it, and the comment
  -- and its mark there after a reload, kept in IndexedDB.
  it "marks a quote, comments on text selected, and keeps the comment across a reload" $ onDemoPage demoContext $ \page -> do
    gate <- hold page adoptionOptions.program
    _ <- load site gate page "/s/blog/p/hello-world/"
    textContent (locator page "#app mark.comment-mark[data-thread=\"thread-hello-1\"]") `shouldReturn` "a blog that is also a wiki"
    -- The selection is made in the page's own script, and the mouse's
    -- release that the program reads it on dispatched there: settle after.
    _ :: Maybe Bool <-
      evaluate
        page
        "(() => {\
        \  const walker = document.createTreeWalker(document.querySelector('#app .page-body'), NodeFilter.SHOW_TEXT);\
        \  for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {\
        \    const at = node.data.indexOf('in other spaces');\
        \    if (at < 0) continue;\
        \    const range = document.createRange();\
        \    range.setStart(node, at);\
        \    range.setEnd(node, at + 'in other spaces'.length);\
        \    getSelection().removeAllRanges();\
        \    getSelection().addRange(range);\
        \    node.parentElement.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));\
        \    return true;\
        \  }\
        \  return null;\
        \})()"
    settle page
    click (locator page "#app .comment-on-selection")
    fill (locator page "#app .comments-panel .new-thread textarea") "Spaces all the way down?"
    click (withText "Comment" (locator page "#app .comments-panel .new-thread button"))
    waitQuiet page
    let marked = withText "in other spaces" (locator page "#app mark.comment-mark")
    count marked `shouldReturn` 1
    _ <- reloadAdopted gate page
    count marked `shouldReturn` 1
    textContent (locator page "#app .comments-toggle") >>= (`shouldSatisfy` Text.isInfixOf "Comments (3)")
    nothingWrong page
  where
    clipboard = ["clipboard-read", "clipboard-write"]

-- | Run an action whose effect reaches the program through an event the
-- browser fires later, on a schedule of its own, and wait until the
-- program has handled that event. A dialog's close event comes at the next
-- animation frame after Escape closes the dialog; a popstate comes once a
-- @history.back()@ the page called has gone through. The driver's settle
-- after the action waits for a background-priority task and then for the
-- program to be idle, and the background task often runs before the next
-- animation frame: the program, which has heard nothing yet, is idle then,
-- and a read finds the page as it was. So a listener of the test's own,
-- added after the program's, resolves a promise on the event; the test
-- waits for the promise, and then settles, for whatever the program's own
-- listener started. A promise, and not 'waitForFunction': the page's
-- Content Security Policy forbids the eval that polling a function needs.
afterEvent :: Page -> Text -> Text -> IO () -> IO ()
afterEvent page target event act = do
  _ :: Bool <-
    evaluate
      page
      ("(() => { const target = " <> target <> "; globalThis.smokeHeard = new Promise((heard) => target.addEventListener('" <> event <> "', () => heard(true), { once: true })); return true; })()")
  act
  _ :: Bool <- evaluate page "globalThis.smokeHeard"
  settle page

-- | The colours of a page: its background, its text's, its sidebar's.
data Colours = Colours {background :: Text, text :: Text, sidebar :: Text}

instance FromJSON Colours where
  parseJSON = withObject "Colours" $ \o -> Colours <$> o .: "background" <*> o .: "text" <*> o .: "sidebar"

colours :: Page -> IO Colours
colours page =
  evaluate
    page
    "(() => {\
    \  const style = (selector) => getComputedStyle(document.querySelector(selector));\
    \  return {\
    \    background: style('body').backgroundColor,\
    \    text: style('#app .page-body p').color,\
    \    sidebar: style('#app .wiki-sidebar').backgroundColor,\
    \  };\
    \})()"

-- | The colour a TikZ picture's lines are drawn in.
ink :: Page -> IO Text
ink page = evaluate page "getComputedStyle(document.querySelector('#app .wiki-tikz > svg [stroke=\"currentColor\"]')).stroke"

-- | The relative luminance of a CSS colour written @rgb(r, g, b)@.
luminance :: Text -> Double
luminance colour = case map (read . Text.unpack) (filter (not . Text.null) (Text.split (not . isDigit) colour)) of
  r : g : b : _ -> (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
  _ -> -1

-- | Which of a slide's steps are shown, on the slide shown.
stepsShown :: Page -> IO [Bool]
stepsShown page = evaluate page "[...document.querySelectorAll('#app .slide-frame.current .slide-step')].map((e) => e.checkVisibility({ visibilityProperty: true }))"

-- | The fields of each form named that are beside the one before rather
-- than under it: the form's children shown, each lower than the one
-- before.
besides :: Page -> [Text] -> IO [Text]
besides page selectors =
  evaluateWith
    page
    "(selectors) => selectors.flatMap((selector) => {\
    \  const shown = [...document.querySelector(`#app ${selector}`).children].filter((c) => c.getClientRects().length > 0);\
    \  return shown.slice(1).flatMap((child, i) =>\
    \    child.getBoundingClientRect().top < shown[i].getBoundingClientRect().bottom - 0.5 ? [`${selector}: ${child.className}`] : []);\
    \})"
    selectors

-- | How many pages a PDF has: its objects of type Page (not Pages, the
-- tree of them).
pages :: ByteString -> Int
pages = go 0
  where
    go n bytes = case ByteString.breakSubstring "/Type" bytes of
      (_, rest)
        | ByteString.null rest -> n
        | otherwise ->
            let after = Char8.dropWhile isSpace (ByteString.drop 5 rest)
                isPage = "/Page" `ByteString.isPrefixOf` after && Char8.take 1 (ByteString.drop 5 after) /= "s"
             in go (if isPage then n + 1 else n) (ByteString.drop 5 rest)
