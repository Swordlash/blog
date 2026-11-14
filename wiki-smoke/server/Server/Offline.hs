-- | Reading offline (WP4.17 of docs/PLAN.md): a browser that lets the
-- service worker in reads a few pages, goes offline and reloads one, which
-- is shown from what the worker kept, saying "You are reading an offline
-- copy from …" with the offline notice; a page followed by a link offline
-- is shown from the API's answers kept; a page never read gets the
-- worker's offline page; back online, the page is the live one again; and
-- signing out lets go of what was kept.
--
-- Every other part runs with service workers blocked, so that what it
-- holds back or counts passes through the driver's routes, which a
-- worker's requests and its cache's answers do not. Here the worker is
-- under test: what it keeps, and when it has taken the page over, are its
-- own, waited for as conditions.
module Server.Offline (spec) where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.IORef (readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Server.Site
import Wiki.Smoke.Browser
import Wiki.Smoke.Demo (nothingWrongExcept)
import Wiki.Smoke.Walk

spec :: Smoke -> SpecWith Playwright
spec smoke = describe "reading offline, through the service worker" $
  -- A browser that lets the worker in, as a reader's does, signed in as
  -- the administrator.
  onWalkPage defaultContextOptions {acceptDialogs = True} signedIn $ do
    let step' = step smoke.chain
        firstPage = "/s/smoke-space/p/first-page/"

    step' "keeps the pages read and the API's answers read for them, but for what is never kept" $ \w -> do
      let reader = w.page
      visit reader (address smoke "/s/smoke-space/")
      hasText (locator reader "#app .sidebar-space-name") "Smoke space"
      -- The worker takes the page over once it is installed: its own.
      holdsInPage reader "navigator.serviceWorker.controller !== null"
      -- The page that installed the worker, which the worker did not serve,
      -- is kept when the page asks; one loaded since, as it is served. The
      -- worker's caches: a condition.
      eventually reader (keptPaths reader "pages" >>= \ps -> expect ("/s/smoke-space/" `elem` ps) "the first page is not kept")
      visit reader (address smoke firstPage)
      hasText (locator reader "#app .page-body") "Saved by someone else."
      eventually reader (keptPaths reader "pages" >>= \ps -> expect (firstPage `elem` ps) "a page is not kept")
      -- A link followed to another space: what the program reads for it is
      -- kept, but for what is never kept (who is asking, the
      -- administration, the account, notifications).
      toPublic reader
      eventually reader (keptPaths reader "answers" >>= \as -> expect (not (null as)) "nothing kept")
      answers <- keptPaths reader "answers"
      expect (all (not . neverKept) answers) ("kept what is never kept: " <> show answers)
      keptPages <- keptPaths reader "pages"
      report ("the worker kept " <> tshow (length keptPages) <> " pages and " <> tshow (length answers) <> " answers of the API")
      offlineFine reader

    -- Offline: the page reloaded is the copy kept, saying so, with the
    -- offline notice, and the program starts on it from the files kept.
    step' "shows a page read here offline from what the worker kept, saying since when, with the offline notice; a link followed from what was kept; a page never read, the offline page" $ \w -> do
      let reader = w.page
          copyLine = locator reader "#app .wiki-content > .offline-copy"
      setOffline (pageContext reader) True
      visit reader (address smoke firstPage)
      count copyLine `shouldReturn` 1
      hasText (locator reader "#app .offline-notice") "You are offline"
      hasText (locator reader "#app .page-body") "Saved by someone else."
      -- The time, in the reader's zone and language, once the island has
      -- written it: the browser's, a condition.
      holdsInPage reader "/^\\s*You are reading an offline copy from \\S.*\\.\\s*$/s.test(document.querySelector('#app .wiki-content > .offline-copy')?.textContent ?? '')"
      -- A link followed offline: shown from the API's answers kept, and
      -- the line goes, which was about the page served.
      toPublic reader
      count (locator reader "#app .offline-copy") `shouldReturn` 0
      -- A page never read here: the worker's offline page, with the pages
      -- it has. No program runs on it.
      goto reader (address smoke "/s/smoke-public/pages/")
      hasText (locator reader ".offline-page h1") "This page is not available offline"
      expect' (count (locator reader ".offline-page .offline-pages a")) (> 0) "the offline page lists no page"
      offlineFine reader

    step' "is the live page back online, and signing out lets go of the pages and answers kept" $ \w -> do
      let reader = w.page
      setOffline (pageContext reader) False
      visit reader (address smoke firstPage)
      hasText (locator reader "#app .page-body") "Saved by someone else."
      count (locator reader "#app .offline-copy") `shouldReturn` 0
      count (locator reader "#app .offline-notice") `shouldReturn` 0
      -- Signing out lets go of every page and answer kept as the
      -- administrator; what is read after, as nobody, is kept again.
      signingOut :: Text <- evaluate reader "new Date().toISOString()"
      click (locator reader "#app .sign-out")
      waitQuiet reader
      count (locator reader "#app .sign-in-toggle") `shouldReturn` 1
      -- The worker lets go of its caches when told: its own, a condition.
      eventually reader $ do
        after <- kept reader
        let older = [e | kind <- ["pages", "answers"], e <- Map.findWithDefault [] kind after, maybe False (< signingOut) e.at]
        older `shouldBe` []
        expect (not (null (Map.findWithDefault [] "app" after))) "the application's files let go of"
      offlineFine reader
  where
    -- The administrator's session, when the walk has one; without it the
    -- examples are pending anyway.
    signedIn w = readIORef smoke.admin >>= mapM_ (\s -> addCookies (pageContext w.page) [sessionCookie smoke.origin s])
    -- A link followed to the public space, from the space switcher.
    toPublic reader = do
      click (locator reader "#app .space-switcher-toggle")
      click (withText "Smoke public" (locator reader "#app .space-switcher-option"))
      waitQuiet reader
      hasText (locator reader "#app .sidebar-space-name") "Smoke public"
      expect' (count (locator reader "#app .wiki-content :is(.page-view, .space-view, .blog-view)")) (> 0) "the public space shows no view"
      count (locator reader "#app .wiki-content .error") `shouldReturn` 0
    neverKept path = any (\p -> ("/api/v1/" <> p) `Text.isInfixOf` path && boundary p path) ["session", "admin", "account", "notifications"]
    boundary p path = case Text.breakOn ("/api/v1/" <> p) path of
      (_, rest) -> case Text.uncons (Text.drop (Text.length ("/api/v1/" <> p)) rest) of
        Nothing -> True
        Just (c, _) -> c == '/'
    -- Offline, what the worker has not kept fails to load (the bell, the
    -- live channel), as it would without one: that is what offline is,
    -- and the page says so.
    offlineFine = nothingWrongExcept (\m -> expectedOnServer m || any (`Text.isInfixOf` m.text) ["ERR_INTERNET_DISCONNECTED", "Failed to load resource", "WebSocket"]) (const False)

expect' :: IO a -> (a -> Bool) -> String -> IO ()
expect' get' holds message = get' >>= \v -> expect (holds v) message

-- | An answer the worker keeps: its path, and when it was kept.
data Entry = Entry {path :: Text, at :: Maybe Text}
  deriving stock (Eq, Show)

instance FromJSON Entry where
  parseJSON = withObject "Entry" $ \o -> Entry <$> o .: "path" <*> o .:? "at"

-- | What the worker keeps of this wiki: each answer's path and when it was
-- kept, by the kind of cache (@pages@, @answers@, @app@).
kept :: Page -> IO (Map Text [Entry])
kept reader =
  evaluate
    reader
    "(async () => {\
    \  const found = {};\
    \  for (const name of await caches.keys()) {\
    \    const kind = name.split(' ')[0].replace(/^wiki-/, '');\
    \    const cache = await caches.open(name);\
    \    for (const request of await cache.keys()) {\
    \      (found[kind] ??= []).push({ path: new URL(request.url).pathname, at: (await cache.match(request)).headers.get('X-Wiki-Kept-At') });\
    \    }\
    \  }\
    \  return found;\
    \})()"

keptPaths :: Page -> Text -> IO [Text]
keptPaths reader kind = map (.path) . fromMaybe [] . Map.lookup kind <$> kept reader
