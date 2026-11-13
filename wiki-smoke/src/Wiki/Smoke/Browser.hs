-- | Browsers on a real wiki-server, for the server's smoke suites: a
-- context signed in as someone or as nobody, signing in through the
-- header's form, and what a page of the server's may say on its console.
--
-- A password signs in through OPAQUE (WP5.74a of docs/PLAN.md), which the
-- application runs (with @\@serenity-kit/opaque@) and which never sends
-- the password, so a request of the suite's own cannot sign anyone in: the
-- suite signs in in a browser, through the form, and takes the session's
-- cookie from it ('signInThroughTheForm'). The sign-in, the user's keys
-- brought up to date on this device after it and the shell's reload as the
-- user are the program's work, waited for by 'waitQuiet'.
module Wiki.Smoke.Browser
  ( -- * Contexts
    serverContext
  , withSessionContext
  , sessionCookie

    -- * Signing in
  , Outcome (..)
  , signInOn
  , signInThroughTheForm

    -- * What a page may say
  , nothingWrongOnServer
  , expectedOnServer
  , holdsInPage
  , afterEvent
  )
where

import Control.Monad (unless)
import Data.Char (isAlphaNum)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Wiki.Smoke.Api (Session (..))
import Wiki.Smoke.Demo (nothingWrongExcept)

-- | A browser for a page of the server's: no service worker, whose own
-- requests and cached answers would pass none of the suite's routes (the
-- parts that test the worker let it in), and every dialog accepted:
-- leaving the editor with unsaved work asks, and the walk says leave.
serverContext :: ContextOptions
serverContext = defaultContextOptions {serviceWorkers = False, acceptDialogs = True}

-- | The cookie of a session, for a context of the wiki's origin.
sessionCookie :: Text -> Session -> Cookie
sessionCookie origin s = cookie "wiki_session" s.token origin

-- | A context with these options, signed in with the session given (or as
-- nobody), and a page in it, for the body; closed afterwards. A failure in
-- the body says what the page said, as 'inPage''s does.
withSessionContext :: (HasCallStack) => Playwright -> ContextOptions -> Text -> Maybe Session -> (Page -> IO a) -> IO a
withSessionContext pw options origin who body = withContext pw options $ \ctx -> do
  mapM_ (\s -> addCookies ctx [sessionCookie origin s]) who
  page <- newPage ctx
  withFailureContext page (body page)

-- | What a sign-in through the form came to.
data Outcome
  = -- | Signed in: the header has "Sign out".
    SignedIn
  | -- | The password was right, and a second factor is asked for.
    SecondFactor
  | -- | The form said why not.
    Refused
  deriving stock (Eq, Show)

-- | Sign in on a page that shows the header's form (a page of the wiki,
-- started, with nobody signed in): open the form, type the login and the
-- password, send it, and wait until the program is quiet (OPAQUE's
-- requests, the keys kept, the shell reloaded as the user); then what the
-- page shows of it.
signInOn :: (HasCallStack) => Page -> Text -> Text -> IO Outcome
signInOn page login password = do
  click (locator page "#app .sign-in-toggle")
  fill (locator page "#app .sign-in-form input[name=login]") login
  fill (locator page "#app .sign-in-form input[name=password]") password
  click (locator page "#app .sign-in-form button[type=submit]")
  waitQuiet page
  shown <-
    traverse
      (\(selector, outcome) -> (outcome,) . (> 0) <$> count (locator page selector))
      [("#app .sign-out", SignedIn), ("#app .sign-in-code-form", SecondFactor), ("#app .sign-in-form .sign-in-error", Refused)]
  case find snd shown of
    Just (outcome, _) -> pure outcome
    Nothing -> expectationFailure ("signing " <> Text.unpack login <> " in: nothing happened") >> pure Refused

-- | Sign someone in through the header's form in a browser of its own,
-- which is closed afterwards: what came of it, and the session's cookie,
-- if any. The page must have nothing wrong on it.
signInThroughTheForm :: (HasCallStack) => Playwright -> Text -> Text -> Text -> IO (Outcome, Maybe Session)
signInThroughTheForm pw origin login password = withContext pw serverContext $ \ctx -> do
  page <- newPage ctx
  withFailureContext page $ do
    visit page (origin <> "/")
    outcome <- signInOn page login password
    token <- find (\c -> c.name == "wiki_session") <$> cookies ctx
    nothingWrongOnServer page
    pure (outcome, (\c -> Session c.value) <$> token)

-- | Wait until a JavaScript expression holds in the page, asking it again
-- until the page's timeout: a condition on what is not the program's (the
-- service worker, an image decoded). The driver's 'waitForFunction' has the
-- page evaluate the expression from text, which a page of the server's
-- refuses (its Content Security Policy allows no @unsafe-eval@), and the
-- refusal is an uncaught error of the page's; 'evaluate' goes through the
-- DevTools protocol, which the policy does not cover. Settled after, as
-- every condition is.
holdsInPage :: (HasCallStack) => Page -> Text -> IO ()
holdsInPage page expression = do
  eventually page $ do
    holds :: Bool <- evaluate page expression
    unless holds $ expectationFailure ("not yet: " <> Text.unpack expression)
  settle page

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
--
-- The target is JavaScript that names the element or object the event
-- comes to (@window@, @document.querySelector('#app .user-dialog')@).
afterEvent :: Page -> Text -> Text -> IO () -> IO ()
afterEvent page target event act = do
  _ :: Bool <-
    evaluate
      page
      ("(() => { const target = " <> target <> "; globalThis.smokeHeard = new Promise((heard) => target.addEventListener('" <> event <> "', () => heard(true), { once: true })); return true; })()")
  act
  _ :: Bool <- evaluate page "globalThis.smokeHeard"
  settle page

-- | Fail if a page of the server's threw an error or wrote one on its
-- console, but for what the walk makes happen on purpose
-- ('expectedOnServer').
nothingWrongOnServer :: (HasCallStack) => Page -> Expectation
nothingWrongOnServer = nothingWrongExcept expectedOnServer serviceWorkerInSandbox

-- | The console errors a page of the server's writes when nothing is
-- wrong: an address that is not there, served with a 404 (the walk loads
-- some on purpose), a conflict's 409, and a closed wiki's page to a
-- visitor, a 401, each named in Chromium's message; and whatever an
-- interactive SVG's frame writes, an address with @?interactive@: what
-- its sandbox and its policy refuse, and the hostile SVG of the walk
-- tries everything.
expectedOnServer :: ConsoleMessage -> Bool
expectedOnServer m =
  any (`statusIn` m.text) ["401", "404", "409"]
    || maybe False ("?interactive" `Text.isInfixOf`) m.url

-- | Playwright blocks service workers by reading
-- @navigator.serviceWorker@ in every frame, which throws in a frame
-- sandboxed without the wiki's origin (an interactive SVG's): its own
-- error, not the wiki's.
serviceWorkerInSandbox :: Text -> Bool
serviceWorkerInSandbox thrown =
  "Failed to read the 'serviceWorker' property from 'Navigator'" `Text.isInfixOf` thrown && "sandboxed" `Text.isInfixOf` thrown

-- | Whether a status is named in a text as a word of its own, as the
-- script's @\\b404\\b@ read it.
statusIn :: Text -> Text -> Bool
statusIn status = go
  where
    go t = case Text.breakOn status t of
      (_, rest) | Text.null rest -> False
      (before, rest) ->
        let after = Text.drop (Text.length status) rest
            alone = maybe True (not . isAlphaNum . snd) (Text.unsnoc before) && maybe True (not . isAlphaNum . fst) (Text.uncons after)
         in alone || go (Text.drop 1 rest)
