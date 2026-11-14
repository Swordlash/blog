-- | The first three parts of the server's smoke test: the server's page
-- adopted, a walk through the wiki as its administrator, a visitor, a
-- user who signs in with a provider, and a fresh browser, and then every
-- route of the walk loaded afresh.
--
-- Each group of examples shares a page ('onWalkPage'): the
-- administrator's, which starts as nobody and signs in through the
-- header; a visitor's; and a browser that has seen nothing, signed in as
-- the administrator. Other browsers an example needs (another user's tab,
-- a second tab of the same page, a browser with JavaScript off) are opened
-- and closed within it.
module Server.Walk (spec) where

import Codec.Archive.Zip (findEntryByPath, toArchive)
import Control.Monad (forM_, unless)
import Crypto.Hash.Algorithms (SHA1)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.Aeson (Value (..), object, (.=))
import Data.Bits (shiftL, (.&.), (.|.))
import Data.ByteArray (convert)
import Data.ByteArray.Encoding (Base (..), convertFromBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isDigit, isSpace, toUpper)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Server.Provider (Provider (..), clientId)
import Server.Site
import System.Directory (getFileSize)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import Test.Hspec qualified as Hspec
import Wiki.Smoke.Api
import Wiki.Smoke.Browser
import Wiki.Smoke.Server
import Wiki.Smoke.Walk

spec :: Smoke -> SpecWith Playwright
spec smoke = do
  mainLoads <- Hspec.runIO (newIORef Nothing)
  visitorLoads <- Hspec.runIO (newIORef Nothing)
  freshLoads <- Hspec.runIO (newIORef Nothing)
  describe "the administrator's walk" $ onWalkPage serverContext (keepLoads mainLoads) (administrator smoke mainLoads)
  describe "a visitor" $ onWalkPage serverContext (keepLoads visitorLoads) (visitor smoke visitorLoads)
  describe "a browser that has seen nothing" $ onWalkPage serverContext (signedInFresh smoke freshLoads) (fresh smoke freshLoads)
  where
    keepLoads ref w = holdLoads w.page >>= writeIORef ref . Just
    signedInFresh s ref w = do
      readIORef s.admin >>= mapM_ (\a -> addCookies (pageContext w.page) [sessionCookie s.origin a])
      keepLoads ref w

-- | The page's gates, which its group's setup made.
loadsOf :: IORef (Maybe Loads) -> IO Loads
loadsOf ref = readIORef ref >>= orFail "the page has no gates: holdLoads in its setup"

----------------------------------------------------------------------
-- 1 and 2: the server's page, adopted, and the administrator's walk

administrator :: Smoke -> IORef (Maybe Loads) -> SpecWith Walker
administrator smoke loadsRef = do
  let step' = step smoke.chain

  -- The administrator's session, for what the walk asks the API itself
  -- and for the browsers that start signed in.
  step' "signs in the administrator the console made, through the header's form in a browser of her own" $ \w -> do
    (outcome, session) <- signInThroughTheForm w.browser smoke.origin adminLogin adminPassword
    outcome `shouldBe` SignedIn
    orFail "no session cookie" session >>= setAdminSession smoke

  -- The page's Content Security Policy (Wiki.Api.ContentPolicy): sent as a
  -- header, and the same text in the page's meta element, but for
  -- frame-ancestors, which only a header can carry. Every page below runs
  -- under it, and a violation is a console error, which fails the example.
  step' "sends every page with its Content Security Policy, the same in its header and its meta element" $ \_ -> do
    front <- get smoke.wiki Nothing "/" >>= expectStatus 200 "the front page"
    let html = bodyText front
    -- The page view's class list also says how wide it lays the page out
    -- (page-width-compact, as a page the server renders always is).
    expect (inOrder html ["class=\"wiki-home\"", "class=\"page-view", ">Spaces</h1>"]) "the front page's ordinary page view is not rendered"
    includes html "<section class=\"directory\">" "the front page's directory of spaces"
    expect (not ("Loading…" `Text.isInfixOf` html)) "the front page is the application loading"
    includes html "<script type=\"application/json\" id=\"wiki-preload\">" "what the front page carries for the program"
    let meta = Text.takeWhile (/= '"') (snd (Text.breakOnEnd "<meta http-equiv=\"Content-Security-Policy\" content=\"" html))
    includes meta "script-src 'self' 'wasm-unsafe-eval'" "the front page's policy"
    header "content-security-policy" front `shouldBe` Just (meta <> "; frame-ancestors 'none'")
    header "referrer-policy" front `shouldBe` Just "same-origin"
    header "permissions-policy" front `shouldBe` Just "camera=(), microphone=(), geolocation=()"
    wasm <- get smoke.wiki Nothing "/app.wasm"
    header "content-security-policy" wasm `shouldBe` Nothing

  step' "renders the front page, which the program adopts with nothing to repair and nothing asked" $ \w -> do
    loads <- loadsOf loadsRef
    atFront <- loadAdopted smoke loads w.page "/"
    adoptedCleanly "/" atFront 200 "There are no spaces you can see."
    count (locator w.page "#app .user-switcher") `shouldReturn` 0
    count (locator w.page "#app .admin-link") `shouldReturn` 0
    nothingWrongOnServer w.page

  -- Signing in, through the header's form, as the administrator the
  -- console made: the shell reloads as them, with the way to the
  -- administration.
  step' "signs in through the header as ada, the administrator made on the console" $ \w -> do
    let page = w.page
    signInOn page adminLogin adminPassword `shouldReturn` SignedIn
    hasText (locator page "#app .user-name") adminName
    count (locator page "#app .sign-out") `shouldReturn` 1
    count (locator page "#app .wiki-header a.admin-link") `shouldReturn` 1
    nothingWrongOnServer page

  step' "makes a space and a page through the forms, the page typed and saved with Ctrl+S" $ \w -> do
    let page = w.page
    -- A space, from the sidebar's link. It opens at its home page, made
    -- with it, in a sidebar of its own.
    click (locator page "#app .wiki-sidebar .new-space-link")
    fill (locator page "#app .new-space-view input") "Smoke space"
    click (locator page "#app .new-space-view button.primary")
    waitQuiet page
    hasText (locator page "#app .sidebar-space-name") "Smoke space"
    hasText (locator page "#app .page-view .page-title") "Home"
    here page `shouldReturn` "/s/smoke-space/"
    -- A page, from its title, from the space's list of pages.
    click (locator page "#app .space-pages-link")
    waitQuiet page
    hasText (locator page "#app .space-view h1") "Smoke space"
    click (withText "New page" (locator page "#app .space-view .actions a"))
    typeText (locator page "#app .new-page-title") "First page"
    click (locator page "#app .new-page-view button.primary")
    waitQuiet page
    editorReady page
    here page `shouldReturn` "/s/smoke-space/p/first-page/edit/"
    -- Typed and saved with Ctrl+S, which stays.
    typeText (editorText page) "Hello from the server's smoke test."
    pressOn (editorText page) "Control+s"
    waitQuiet page
    hasText (locator page "#app .editor-saved-notice") "Saved"
    nothingWrongOnServer page

  step' "uploads a file attached in the editor, serves it at its address and refers to it in the page" $ \w -> do
    let page = w.page
    setInputFiles (locator page "#app .editor-attach input[type=file]") [UploadBytes {name = "notes.txt", mimeType = "text/plain", bytes = "attached by the smoke test\n"}]
    waitQuiet page
    let attachment = withText "notes.txt" (locator page "#app .editor-attachments a")
    href <- getAttribute attachment "href" >>= orFail "the attachment's link has no address"
    s <- adminSession smoke
    served <- get smoke.wiki (Just s) ("/" <> Text.dropWhile (== '/') href) >>= expectStatus 200 "the attachment"
    served.body `shouldBe` "attached by the smoke test\n"
    typed <- markdownIn page
    includes typed "(attachment:notes.txt)" "the attachment's reference in the Markdown"
    -- Saved again, and the page as the server has it holds the reference:
    -- stronger than the save's answer, which the JavaScript test read.
    pressOn (editorText page) "Control+s"
    waitQuiet page
    hasText (locator page "#app .editor-saved-notice") "Saved"
    saved <- pageAt smoke "smoke-space" "first-page"
    text (saved .! "body") >>= \b -> includes b "(attachment:notes.txt)" "the page saved with the attachment's reference"
    nothingWrongOnServer page

  step' "keeps a draft as the typing stops, and the editor restores it after a reload, which adopts the page with nothing to repair" $ \w -> do
    let page = w.page
    pressOn (editorText page) "Control+End"
    typeText (editorText page) " Not saved yet."
    -- The draft is kept once the typing stops: a pause the program waits
    -- in, and then its request.
    waitQuiet page
    hasText (locator page "#app .editor-draft-status") "Draft saved"
    loads <- loadsOf loadsRef
    reloaded <- loadAdopted smoke loads page "/s/smoke-space/p/first-page/edit/"
    adoptedCleanly "the editor's address" reloaded 200 "Restored your unsaved draft"
    waitQuiet page
    hasText (locator page "#app .editor-draft-found") "Restored your unsaved draft"
    editorReady page
    typed <- markdownIn page
    expect ("Not saved yet." `Text.isSuffixOf` typed) ("the draft restored: " <> show typed)
    nothingWrongOnServer page

  -- Someone else saves the page meanwhile, through the API; the editor's
  -- save is then a conflict, shown in the conflict view with their
  -- version beside the work, which is kept until "Take theirs" is chosen.
  step' "opens the conflict view on a save over someone else's newer one, their version diffed beside the work, and takes theirs on request" $ \w -> do
    let page = w.page
    s <- adminSession smoke
    (current, tag) <- pageAtWithTag smoke "smoke-space" "first-page"
    pid <- text (current .! "id")
    body <- text (current .! "body")
    _ <- api smoke.wiki (Just s) "PUT" ("pages/" <> escape pid) (Just (object ["title" .= ("First page" :: Text), "body" .= (body <> "\n\nSaved by someone else.")])) [("If-Match", Text.encodeUtf8 tag)] >>= expectStatus 200 "the API's save"
    _ <- api smoke.wiki (Just s) "PUT" ("pages/" <> escape pid) (Just (object ["title" .= ("First page" :: Text), "body" .= ("stale" :: Text)])) [("If-Match", Text.encodeUtf8 tag)] >>= expectStatus 409 "a save with a stale version through the API"
    pressOn (editorText page) "Control+s"
    waitQuiet page
    hasText (locator page "#app .editor .editor-conflict") (adminName <> " saved this page")
    hasText (locator page "#app .editor-conflict-pane .diff-added") "Saved by someone else."
    work <- markdownIn page
    expect ("Not saved yet." `Text.isSuffixOf` work) "the conflict lost the work"
    click (withText "Take theirs" (locator page "#app .editor-conflict button"))
    waitQuiet page
    theirs <- markdownIn page
    expect ("Saved by someone else." `Text.isSuffixOf` theirs) ("their version taken after the conflict: " <> show theirs)
    count (locator page "#app .editor-conflict-pane") `shouldReturn` 0
    nothingWrongOnServer page

  step' "finds the page by search, in the box and on the page of results" $ \w -> do
    let page = w.page
    click (locator page "#app .editor-save-close")
    waitQuiet page
    hasText (locator page "#app .page-view .page-body") "Saved by someone else."
    _ :: Value <- evaluate page "(() => { document.activeElement?.blur(); return null; })()"
    settle page
    press page "/"
    typeKeys page "smoke"
    -- The search waits for the typing to stop, then asks the server.
    waitQuiet page
    hasText (locator page "#app .search-results .search-hit") "First page"
    press page "Enter"
    waitQuiet page
    hasText (locator page "#app .search-view .search-hit") "First page"
    nothingWrongOnServer page

  -- The page's history: every save a version, the latest first; version 2
  -- (the first text typed) restored, which the page then shows, then the
  -- version that was the latest restored in turn, so the page ends as it
  -- was, two versions on.
  step' "lists the page's versions, restores version 2 and then the latest again, each a version on top" $ \w -> do
    let page = w.page
        versionNames = allTextContents (locator page "#app .version-list li > a")
    click (first (withText "First page" (locator page "#app .search-view .search-hit")))
    waitQuiet page
    hasText (locator page "#app .page-view h1") "First page"
    click (withText "History" (locator page "#app .page-view .actions a"))
    waitQuiet page
    hasText (locator page "#app .history-view h1") "First page"
    here page `shouldReturn` "/s/smoke-space/p/first-page/history/"
    versions <- versionNames
    expect (length versions >= 4) ("the history lists " <> show (length versions) <> " versions")
    take 1 versions `shouldBe` ["Version " <> tshow (length versions) <> " (current)"]
    contentText page >>= \c -> includes c ("by " <> adminName) "the versions' author"
    let restore n shown' lacks = do
          click (withTextExact ("Version " <> tshow n) (locator page "#app .version-list li > a"))
          waitQuiet page
          hasText (locator page "#app .version-detail h2") ("Version " <> tshow n)
          click (locator page "#app button.restore")
          click (withText "Restore" (locator page "#app .restore-confirm button"))
          waitQuiet page
          hasText (locator page "#app .page-view .page-body") shown'
          forM_ lacks $ \l -> lacksText (locator page "#app .page-view .page-body") l
          click (withText "History" (locator page "#app .page-view .actions a"))
          waitQuiet page
          count (locator page "#app .history-view h1") `shouldReturn` 1
    restore (2 :: Int) "Hello from the server's smoke test." (Just "Saved by someone else.")
    length <$> versionNames `shouldReturn` length versions + 1
    restore (length versions) "Saved by someone else." Nothing
    take 1 <$> versionNames `shouldReturn` ["Version " <> tshow (length versions + 2) <> " (current)"]
    report ("the page's " <> tshow (length versions) <> " versions are listed, version 2 restored and then the latest again")
    nothingWrongOnServer page

  step' "downloads the server's export from the administration" $ \w -> do
    let page = w.page
    click (locator page "#app .wiki-header a.admin-link")
    click (locator page "#app .admin-nav-link[data-section=backups]")
    waitQuiet page
    count (locator page "#app .admin-view .import-sources .import-file") `shouldReturn` 1
    exported <- download page (click (locator page "#app .admin-view .demo-export"))
    expect (exportName exported.suggestedFilename) ("the export's name: " <> show exported.suggestedFilename)
    bytes <- downloadBytes exported
    ByteString.take 2 bytes `shouldBe` "PK"
    report ("the administration downloads the server's export, " <> exported.suggestedFilename)
    nothingWrongOnServer page

  -- A user, made in the administration's users with a password, who signs
  -- in; and a group, which the server keeps.
  step' "makes a user with a password in the administration, who signs in, and a group, which the server keeps" $ \w -> do
    let page = w.page
    click (locator page "#app .admin-nav-link[data-section=users]")
    waitQuiet page
    count (locator page ("#app .admin-view .user-row[data-login=" <> adminLogin <> "] .badge-administrator")) `shouldReturn` 1
    click (locator page "#app .admin-view .user-create-open")
    fill (locator page "#app .admin-view .user-create-login") "sam"
    fill (locator page "#app .admin-view .user-create-name") "Sam Smoke"
    fill (locator page "#app .admin-view .user-create-password") "sam's password"
    click (locator page "#app .admin-view .user-create button.primary")
    -- The administration's browser registers Sam's password through
    -- OPAQUE, which is requests.
    waitQuiet page
    hasText (locator page "#app .admin-view .user-row[data-login=sam] .user-sign-in") "With a password"
    -- Sam signs in with it from another browser, through OPAQUE too.
    (samOutcome, samSession) <- signInThroughTheForm w.browser smoke.origin "sam" "sam's password"
    samOutcome `shouldBe` SignedIn
    sam <- api smoke.wiki samSession "GET" "session" Nothing [] >>= apiJson
    sam .! "user" .! "displayName" `shouldBe` String "Sam Smoke"
    fst <$> signInThroughTheForm w.browser smoke.origin "sam" "not sam's password" `shouldReturn` Refused
    click (locator page "#app .admin-nav-link[data-section=groups]")
    waitQuiet page
    fill (locator page "#app .admin-view .group-create-name") "Smoke testers"
    click (locator page "#app .admin-view .group-create button.primary")
    waitQuiet page
    hasText (locator page "#app .admin-view .group-name") "Smoke testers"
    people <- asAdmin smoke "GET" "admin/directory" Nothing >>= expectStatus 200 "the directory" >>= apiJson
    groups <- list (people .! "groups") >>= traverse (text . (.! "name"))
    groups `shouldBe` ["Smoke testers"]
    nothingWrongOnServer page

  -- The server's settings, from the administration while the server
  -- runs: the wiki's public address, and the fake provider with its
  -- secret, typed once, never shown again, and checked against the
  -- provider.
  step' "sets the public address and adds a provider in the administration, which answers its check, its secret never shown" $ \w -> do
    let page = w.page
        section = "#app .admin-view .admin-server"
        fakeRow = section <> " .server-provider[data-name=fake]"
        public = smoke.origin <> "/"
    click (locator page "#app .admin-nav-link[data-section=server]")
    waitQuiet page
    click (locator page (section <> " .server-url-edit"))
    fill (locator page (section <> " .server-url-form input[name=url]")) public
    click (locator page (section <> " .server-url-form button[type=submit]"))
    waitQuiet page
    hasText (locator page (section <> " .server-url-value")) public
    click (locator page (section <> " .server-provider-add"))
    fill (locator page (section <> " .server-provider-form input[name=name]")) "fake"
    selectOption (locator page (section <> " .server-provider-form select[name=kind]")) ["oidc"]
    fill (locator page (section <> " .server-provider-form input[name=client-id]")) clientId
    fill (locator page (section <> " .server-provider-form input[name=issuer]")) smoke.provider.origin
    fill (locator page (section <> " .server-provider-form input[name=secret]")) smoke.provider.secret
    click (locator page (section <> " .server-provider-form button[type=submit]"))
    waitQuiet page
    hasText (locator page (fakeRow <> " .server-provider-secret")) "set"
    textContent (locator page (fakeRow <> " .server-provider-redirect")) `shouldReturn` (smoke.origin <> "/auth/fake/callback")
    click (locator page (fakeRow <> " .server-provider-check"))
    -- The server asks the provider's discovery document.
    waitQuiet page
    hasText (locator page (fakeRow <> " .server-provider-checked")) "It answered"
    sectionText <- textContent (locator page section)
    expect (not (smoke.provider.secret `Text.isInfixOf` sectionText)) "the provider's secret is shown"
    settings <- asAdmin smoke "GET" "admin/server" Nothing >>= expectStatus 200 "the server's settings"
    providers <- apiJson settings >>= \v -> list (v .! "providers") >>= traverse (\p -> (,) <$> text (p .! "name") <*> text (p .! "secret"))
    providers `shouldBe` [("fake", "set")]
    expect (not (smoke.provider.secret `Text.isInfixOf` bodyText settings)) "the API gives the provider's secret back"
    nothingWrongOnServer page

  -- Backups (WP4.9): none until they are turned on in the administration's
  -- "Backups and data"; then the first is made at once, and another by
  -- hand, each shown with its size. And the console's restore: refused
  -- the data directory of the running server, and done into a fresh one,
  -- with the attachments' files brought from the data directory's.
  step' "makes backups once turned on in the administration, and by hand, and restores one into a fresh data directory, not under the running server" $ \w -> do
    let page = w.page
        part = "#app .admin-view .server-backups"
    click (locator page "#app .admin-nav-link[data-section=backups]")
    waitQuiet page
    hasText (locator page (part <> " .backups-state")) "Off"
    before <- asAdmin smoke "GET" "admin/server/backups" Nothing >>= apiJson
    before .! "last" `shouldBe` Null
    click (locator page (part <> " .backups-edit"))
    check (locator page (part <> " .backups-form input[name=enabled]"))
    selectOption (locator page (part <> " .backups-form select[name=schedule]")) ["hours"]
    click (locator page (part <> " .backups-form button[type=submit]"))
    waitQuiet page
    hasText (locator page (part <> " .backups-state")) "On: every 6 hours"
    -- The first backup is made by the server once they are turned on, on
    -- its own, not by the page: a condition, on the server's answer.
    eventually page $ do
      made <- asAdmin smoke "GET" "admin/server/backups" Nothing >>= apiJson
      made .! "last" .! "failure" `shouldBe` Null
      expect (not (isNull (made .! "last" .! "file"))) "no backup made yet"
    click (locator page (part <> " .backups-now"))
    -- The view looks again every two seconds while a backup runs, a pause
    -- it waits in: quiet means the backup is made and shown.
    waitQuiet page
    hasText (locator page (part <> " .backups-last")) "by hand: made"
    backedUp <- asAdmin smoke "GET" "admin/server/backups" Nothing >>= apiJson
    backedUp .! "last" .! "trigger" `shouldBe` String "Manual"
    file <- text (backedUp .! "last" .! "file")
    size <- int (backedUp .! "last" .! "size")
    let backup = smoke.dataDir </> "backups" </> Text.unpack file
    fromIntegral <$> getFileSize backup `shouldReturn` size
    let built = smoke.build.built
        attachments = smoke.dataDir </> "attachments"
    (refusedCode, _, refusedSaid) <- restoreBackup built smoke.database backup smoke.dataDir attachments
    expect (refusedCode /= ExitSuccess && "A server is running on" `Text.isInfixOf` refusedSaid) ("a restore into the running server's data directory: " <> Text.unpack refusedSaid)
    (code, said, err) <- restoreBackup built (maybe smoke.database id smoke.restoreDatabase) backup (smoke.build.work </> "restored") attachments
    expect (code == ExitSuccess && "Restored" `Text.isInfixOf` said && not ("Warning" `Text.isInfixOf` said)) ("the restore said: " <> Text.unpack said <> Text.unpack err)
    nothingWrongOnServer page

  -- A second space, made public in its permissions; the first stays
  -- private.
  step' "makes a space public in its settings' permissions" $ \w -> do
    let page = w.page
    _ <- asAdmin smoke "POST" "spaces" (Just (object ["parent" .= Null, "name" .= ("Smoke public" :: Text)])) >>= expectStatus 201 "the public space"
    visit page (address smoke "/s/smoke-public/pages/")
    hasText (locator page "#app .space-view h1") "Smoke public"
    click (locator page "#app .space-view .space-settings-toggle")
    click (locator page "#app .space-permissions .public-switch[aria-checked=false]")
    waitQuiet page
    hasText (locator page "#app .space-view .badge") "Public"
    nothingWrongOnServer page

  -- Its profile: a description and an emoji, and an image uploaded for
  -- its icon, which the server serves; and shown as a blog, from the same
  -- settings, with a post of its own.
  step' "gives a space a description, an emoji and an uploaded image the server serves, and shows it as a blog" $ \w -> do
    let page = w.page
    fill (locator page "#app .space-settings .space-description-field") "Where the smoke test writes in public."
    check (locator page "#app .icon-kind-emoji input")
    fill (locator page "#app .icon-emoji") "🔥"
    click (locator page "#app .space-profile-form button.primary")
    waitQuiet page
    hasText (locator page "#app .settings-saved") "Saved"
    hasText (locator page "#app .sidebar-space .space-icon-emoji") "🔥"
    setInputFiles (locator page "#app .space-settings .icon-upload input[type=file]") [UploadBytes {name = "smoke.png", mimeType = "image/png", bytes = pixel}]
    waitQuiet page
    let icon = locator page "#app .sidebar-space img.space-icon-image"
    iconSrc <- getAttribute icon "src" >>= orFail "the icon has no address"
    expect (iconAddress iconSrc) ("the icon's address: " <> show iconSrc)
    -- Relative to the page's base, as the browser fetched it.
    resolved :: Text <- evaluateWith page "(src) => new URL(src, document.baseURI).href" iconSrc
    s <- adminSession smoke
    served <- get smoke.wiki (Just s) resolved >>= expectStatus 200 "the icon"
    served.body `shouldBe` pixel
    -- The image decoded by the browser: not the program's, a condition.
    holdsInPage page "(() => { const img = document.querySelector('#app .sidebar-space img.space-icon-image'); return img !== null && img.complete && img.naturalWidth === 1; })()"
    check (locator page "#app .space-settings .space-blog")
    click (locator page "#app .space-profile-form button.primary")
    waitQuiet page
    hasText (locator page "#app .settings-saved") "Saved"
    publicSpace <- asAdmin smoke "GET" "spaces/at/smoke-public" Nothing >>= apiJson >>= text . (.! "id")
    _ <- asAdmin smoke "POST" ("spaces/" <> escape publicSpace <> "/pages") (Just (object ["parent" .= Null, "title" .= ("Smoke post" :: Text), "body" .= ("The smoke test's *first* post." :: Text)])) >>= expectStatus 201 "the post"
    nothingWrongOnServer page

----------------------------------------------------------------------
-- 2: a visitor, a closed wiki, a provider

visitor :: Smoke -> IORef (Maybe Loads) -> SpecWith Walker
visitor smoke loadsRef = do
  let step' = step smoke.chain

  -- Someone who is not signed in sees the public space only, and no way to
  -- the administration, which the server refuses them too.
  step' "shows a visitor who is not signed in the public space and nothing else, and no administration" $ \w -> do
    let page = w.page
    visit page (address smoke "/")
    waitQuiet page
    hasText (locator page "#app .wiki-sidebar a") "Smoke public"
    allTextContents (locator page "#app .directory .space-card-name") `shouldReturn` ["Smoke public"]
    textContent (locator page "#app .directory .space-card-description") `shouldReturn` "Where the smoke test writes in public."
    count (locator page "#app .admin-link") `shouldReturn` 0
    count (locator page "#app .sign-in-toggle") `shouldReturn` 1
    (.status) <$> get smoke.wiki Nothing "/s/smoke-space/" `shouldReturn` 404
    (.status) <$> get smoke.wiki Nothing "/api/v1/admin/directory" `shouldReturn` 403
    nothingWrongOnServer page

  -- A page's permanent address (WP5.81) sends the visitor to the page's
  -- own address, which the browser keeps the fragment on; one of a private
  -- page answers as an address that names nothing, as an id no page has.
  step' "leads a visitor from a page's permanent address to the page, the fragment kept, and a private page's to nothing, as a missing one's" $ \w -> do
    let page = w.page
    hidden <- pagesOf smoke "smoke-space" >>= orFail "no page in the private space" . safeHead >>= text . (.! "id")
    post <- pageAt smoke "smoke-public" "smoke-post"
    postId <- text (post .! "id")
    postVersion <- text (post .! "updatedAt")
    redirected <- getManual smoke.wiki Nothing ("/l/" <> escape postId <> "/")
    (redirected.status, header "location" redirected) `shouldBe` (302, Just "/s/smoke-public/p/smoke-post/")
    -- With the version "Copy permanent link" names, to that version.
    pinned <- getManual smoke.wiki Nothing ("/l/" <> escape postId <> "/?version=" <> escape postVersion)
    pinned.status `shouldBe` 302
    expect (maybe False ("/s/smoke-public/p/smoke-post/?version=" `Text.isPrefixOf`) (header "location" pinned)) ("not to the version: " <> show (header "location" pinned))
    visit page (address smoke ("/l/" <> escape postId <> "/#first"))
    here page `shouldReturn` "/s/smoke-public/p/smoke-post/"
    full <- url page
    expect ("#first" `Text.isSuffixOf` full) ("the permanent address's fragment: " <> show full)
    privately <- getManual smoke.wiki Nothing ("/l/" <> escape hidden <> "/")
    let nobody = Text.replicate (Text.length hidden) "x"
    nowhere <- getManual smoke.wiki Nothing ("/l/" <> nobody <> "/")
    (privately.status, nowhere.status) `shouldBe` (404, 404)
    Text.replace hidden "ID" (bodyText privately) `shouldBe` Text.replace nobody "ID" (bodyText nowhere)
    nothingWrongOnServer page

  -- The public blog, as a visitor and a feed reader find it: its page
  -- adopted with nothing to repair, the head announcing its feeds and
  -- describing it, its Atom and RSS feeds with the post whole, the
  -- sitemap with its pages and nothing private.
  step' "lists a public blog's posts, describes them to link previews, and has feeds and a sitemap, nothing private in them" $ \w -> do
    let page = w.page
    loads <- loadsOf loadsRef
    blog <- loadAdopted smoke loads page "/s/smoke-public/"
    adoptedCleanly "the public blog" blog 200 "Smoke post"
    includes blog.shown "No comments" "the blog's posts"
    click (withText "Smoke post" (locator page "#app .post-link"))
    waitQuiet page
    hasText (locator page "#app .post-date") "Posted"
    postPage <- bodyText <$> get smoke.wiki Nothing "/s/smoke-public/p/smoke-post/"
    forM_
      [ "<meta property=\"og:title\" content=\"Smoke post\">"
      , "<meta name=\"description\" content=\"The smoke test's first post.\">"
      , "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"Smoke public (Atom)\" href=\"/s/smoke-public/feed.xml\">"
      ]
      (\tag -> includes postPage tag "the post's head")
    atom <- get smoke.wiki Nothing "/s/smoke-public/feed.xml" >>= expectStatus 200 "the public blog's Atom feed"
    expect (maybe False ("application/atom+xml" `Text.isPrefixOf`) (header "content-type" atom)) "the Atom feed's type"
    includes (bodyText atom) "<title>Smoke post</title>" "the Atom feed"
    includes (bodyText atom) "&lt;em&gt;first&lt;/em&gt;" "the Atom feed"
    rss <- get smoke.wiki Nothing "/s/smoke-public/feed.rss" >>= expectStatus 200 "the public blog's RSS feed"
    includes (bodyText rss) "<guid isPermaLink=\"true\">" "the RSS feed's items"
    (.status) <$> get smoke.wiki Nothing "/s/smoke-space/feed.xml" `shouldReturn` 404
    sitemap <- bodyText <$> get smoke.wiki Nothing "/sitemap.xml"
    includes sitemap "/s/smoke-public/p/smoke-post/</loc>" "the sitemap"
    expect (not ("smoke-space" `Text.isInfixOf` sitemap)) "the sitemap lists a private space"
    nothingWrongOnServer page

  -- A closed wiki: someone who is not signed in is shown the way to sign
  -- in and nothing else, rendered so by the server and adopted with
  -- nothing to repair; an invitation's link makes them an account, and the
  -- wiki opens again for everyone.
  step' "shows a visitor of a closed wiki only the way to sign in; an invitation makes them an account, and the wiki opens again" $ \w -> do
    _ <- asAdmin smoke "PUT" "admin/settings" (Just (settings "Closed")) >>= expectStatus 200 "closing the wiki"
    (.status) <$> get smoke.wiki Nothing "/api/v1/spaces" `shouldReturn` 401
    (.status) <$> get smoke.wiki Nothing "/s/smoke-public/feed.xml" `shouldReturn` 404
    (.status) <$> get smoke.wiki Nothing "/sitemap.xml" `shouldReturn` 404
    inBrowser smoke w.browser Nobody $ \outsider -> do
      loads <- holdLoads outsider
      shut <- loadAdopted smoke loads outsider "/s/smoke-public/"
      adoptedCleanly "a closed wiki's page" shut 401 "Sign in to read this wiki"
      expect (not ("Smoke public" `Text.isInfixOf` shut.shown)) "a closed wiki's page shows its spaces"
      count (locator outsider "#app .wiki-sidebar") `shouldReturn` 0
      invited <- asAdmin smoke "POST" "admin/invitations" (Just (object ["email" .= ("ivy@example.org" :: Text)])) >>= expectStatus 201 "the invitation" >>= apiJson
      token <- text (invited .! "token")
      invitation <- loadAdopted smoke loads outsider ("/invite/" <> token <> "/")
      invitation.status `shouldBe` Just 200
      unless (null invitation.repairs) $ expectationFailure ("adopting the invitation's page repaired it:\n" <> unlines (map (Text.unpack . describeRepair) invitation.repairs))
      waitQuiet outsider
      fill (locator outsider "#app .invitation-form input[name=login]") "ivy"
      fill (locator outsider "#app .invitation-form input[name=name]") "Ivy Invited"
      fill (locator outsider "#app .invitation-form input[name=password]") "ivy's password"
      click (locator outsider "#app .invitation-form button[type=submit]")
      waitQuiet outsider
      hasText (locator outsider "#app .account .user-name") "Ivy Invited"
      hasText (locator outsider "#app .wiki-sidebar a") "Smoke public"
      said <- serverLog smoke.server
      expect (not (token `Text.isInfixOf` said)) "the invitation's secret is in the server's log"
    _ <- asAdmin smoke "PUT" "admin/settings" (Just (settings "Open")) >>= expectStatus 200 "opening the wiki"
    (.status) <$> get smoke.wiki Nothing "/api/v1/spaces" `shouldReturn` 200

  step' "signs in with a provider, there and back, landing signed in as a new account on the page it left, with no password to set until the administration gives one; her sessions, and a second factor" $ \w ->
    inBrowser smoke w.browser Nobody $ \olive -> do
      visit olive (address smoke "/s/smoke-public/")
      click (locator olive "#app .sign-in-toggle")
      click (withText "Sign in with Fake" (locator olive "#app .sign-in-form .provider-link"))
      -- The browser goes to the provider and back through redirects of
      -- two sites: not the program's, so a condition, on the page the
      -- server renders for her session at the end; then her program
      -- starts on it.
      waitFor (withText "Olive Oidc" (locator olive "#app .account .account-toggle")) Visible
      waitStarted olive
      here olive `shouldReturn` "/s/smoke-public/"
      -- The server rendered that page for her session: the cookie came
      -- with it.
      landed :: Value <- evaluate olive "(async () => (await fetch('api/v1/session')).json())()"
      landed .! "user" .! "login" `shouldBe` String "olive"
      click (locator olive "#app .account-toggle")
      waitQuiet olive
      hasText (locator olive "#app .identity .identity-provider") "Fake"
      getAttribute (locator olive "#app .identity-disconnect") "disabled" `shouldReturn` Just ""
      -- She signs in with a provider and has no password: none to set
      -- (WP5.6), in the panel or through the API, nor from the
      -- administration. Asked outside her page, whose console would report
      -- the refusal.
      count (locator olive "#app .password-change-toggle") `shouldReturn` 0
      oliveSession <- find (\c -> c.name == "wiki_session") <$> cookies (pageContext olive) >>= orFail "no session cookie for Olive"
      ownRefused <-
        api
          smoke.wiki
          (Just (Session oliveSession.value))
          "PUT"
          "account/password"
          (Just (object ["current" .= Null, "password" .= object ["credential" .= ("user-olive" :: Text), "record" .= ("AAAA" :: Text), "stretch" .= object ["opsLimit" .= (1 :: Int), "memLimit" .= (8192 :: Int)]]]))
          []
      ownRefused.status `shouldBe` 400
      oliveId <- text (landed .! "user" .! "id")
      providerOnly <- asAdmin smoke "GET" "admin/directory" Nothing >>= apiJson >>= texts . (.! "providerOnly")
      expect (oliveId `elem` providerOnly) "the directory does not say she has no password to set"
      -- The administration disconnects her provider: she has no way in
      -- (her session ends with it), and it gives her a password, typed
      -- since this server sends no mail, which the dialog says.
      inBrowser smoke w.browser Admin $ \administration -> do
        visit administration (address smoke "/admin/users/?q=olive")
        waitQuiet administration
        hasText (locator administration "#app .admin-view .user-row[data-login=olive] .user-sign-in") "With Fake"
        click (locator administration "#app .admin-view .user-row[data-login=olive] .user-manage")
        waitQuiet administration
        let dialog = locator administration "#app .user-dialog[data-login=olive]"
        hasText (locator dialog ".identity-unlink") "Disconnect Fake"
        count (locator dialog ".password-ask") `shouldReturn` 0
        click (locator dialog ".identity-unlink")
        waitQuiet administration
        hasText (locator dialog ".password-hint") "The server sends no mail"
        click (withText "Set password" (locator dialog ".password-ask"))
        fill (locator dialog ".password-new") "olive's own password"
        click (locator dialog ".password-form button.primary")
        waitQuiet administration
        hasText (locator dialog ".account-state") "With a password"
        -- Escape closes the modal dialog, whose close event the browser
        -- fires with the next animation frame: the press settles after
        -- that frame and the program's handling of the event.
        press administration "Escape"
        waitQuiet administration
        hasText (locator administration "#app .admin-view .user-row[data-login=olive] .user-sign-in") "With a password"
      -- She signs in with it in her browser, from the header's form.
      reload olive
      waitStarted olive
      signInOn olive "olive" "olive's own password" `shouldReturn` SignedIn
      hasText (locator olive "#app .account .account-toggle") "Olive Oidc"
      click (locator olive "#app .account-toggle")
      waitQuiet olive
      hasText (locator olive "#app .account-password") "With your password"
      hasText (locator olive "#app .password-change-toggle") "Change password"
      (outcome, outside) <- signInThroughTheForm w.browser smoke.origin "olive" "olive's own password"
      outcome `shouldBe` SignedIn
      outsideSession <- orFail "no session cookie for the password's sign-in" outside
      report "a user who signs in with a provider has no password to set, until the administration disconnects it and gives her one, which she signs in with"
      -- Her sessions: this browser's, marked, and the one just signed in
      -- from outside it, which "Sign out everywhere" ends while hers stays.
      -- The panel reads them when it opens: closed and opened again.
      click (locator olive "#app .account-toggle")
      click (locator olive "#app .account-toggle")
      waitQuiet olive
      count (locator olive "#app .session-item") `shouldReturn` 2
      hasText (locator olive "#app .session-current .session-this") "This browser"
      click (locator olive "#app .sessions-end-others")
      waitQuiet olive
      count (locator olive "#app .session-item") `shouldReturn` 1
      ended <- api smoke.wiki (Just outsideSession) "GET" "session" Nothing [] >>= apiJson
      ended .! "user" `shouldBe` Null
      -- A second factor, from the QR code's secret as text, confirmed with
      -- a code computed here as her application would; then her password
      -- alone no longer signs her in. Her password first: a browser left
      -- signed in does not set one up.
      click (locator olive "#app .second-factor-start")
      fill (locator olive "#app .totp-password-form input[name=password]") "olive's own password"
      click (locator olive "#app .totp-password-form button[type=submit]")
      waitQuiet olive
      secret <- Text.filter (not . isSpace) <$> textContent (locator olive "#app .totp-secret code")
      rects <- count (locator olive "#app .totp-qr rect")
      expect (rects > 50) "the QR code is not drawn"
      code <- totpNow secret
      fill (locator olive "#app .totp-confirm input[name=code]") code
      click (locator olive "#app .totp-confirm button[type=submit]")
      waitQuiet olive
      count (locator olive "#app .recovery-code-list li") `shouldReturn` 10
      click (locator olive "#app .recovery-kept")
      waitQuiet olive
      count (locator olive "#app .second-factor-on") `shouldReturn` 1
      fst <$> signInThroughTheForm w.browser smoke.origin "olive" "olive's own password" `shouldReturn` SecondFactor
      said <- serverLog smoke.server
      issued <- readIORef smoke.provider.issued
      forM_ (smoke.provider.secret : issued) $ \secret' ->
        expect (not (secret' `Text.isInfixOf` said)) "a provider's code, token or secret is in the server's log"
      report "her sessions are listed in the panel and signed out everywhere but here; a second factor set up there is asked for after her password"
  where
    settings :: Text -> Value
    settings access = object ["access" .= access, "newAccountsCreateSpaces" .= False, "adminCreatesPasswordAccounts" .= True]

----------------------------------------------------------------------
-- 2 and 3: a browser that has seen nothing

fresh :: Smoke -> IORef (Maybe Loads) -> SpecWith Walker
fresh smoke loadsRef = do
  let step' = step smoke.chain

  step' "finds the space, the page, its edits and its attachment on the server, in a fresh browser" $ \w -> do
    let page = w.page
    loads <- loadsOf loadsRef
    loaded <- loadAdopted smoke loads page "/s/smoke-space/p/first-page/"
    unless (null loaded.repairs) $ expectationFailure ("adopting the server's page at a page's address repaired it:\n" <> unlines (map (Text.unpack . describeRepair) loaded.repairs))
    waitQuiet page
    hasText (locator page "#app .page-view h1") "First page"
    shown' <- contentText page
    forM_ ["Hello from the server's smoke test.", "Saved by someone else.", "notes.txt"] $ \t -> includes shown' t "the page"
    hasText (locator page "#app .wiki-sidebar a") "Smoke space"
    nothingWrongOnServer page

  -- The page as a Word document, from its "Export" menu: made by the
  -- pandoc linked into the server, fetched by the application and saved
  -- from a blob: URL under the page's title.
  step' "exports the page as a Word document from its Export menu" $ \w -> do
    let page = w.page
    click (locator page "#app .page-view .export-menu summary")
    docx <- download page (click (locator page "#app .export-formats button.export-docx"))
    docx.suggestedFilename `shouldBe` "first-page.docx"
    bytes <- downloadBytes docx
    ByteString.take 2 bytes `shouldBe` "PK"
    expect (isJust (findEntryByPath "word/document.xml" (toArchive (LazyByteString.fromStrict bytes)))) "the exported document has no word/document.xml"
    nothingWrongOnServer page

  -- Comments, live over the server's WebSocket: a second tab on the page
  -- subscribes to it, the first comments on the page, and the second shows
  -- the comment without being reloaded.
  step' "shows a comment made in one tab in another on the same page, over the WebSocket" $ \w -> do
    let page = w.page
    inBrowser smoke w.browser Admin $ \watcher -> do
      visit watcher (address smoke "/s/smoke-space/p/first-page/")
      waitQuiet watcher
      count (locator watcher "#app .page-comments") `shouldReturn` 1
      -- The server's answer to the tab's subscription, with the page's
      -- threads: from here on every comment on the page is told to this
      -- tab. A frame on its way: a condition.
      subscribed <- waitForWebSocket watcher (\f -> not f.sent && "\"subscribed\"" `Text.isInfixOf` f.payload)
      expect ("/api/v1/events" `Text.isSuffixOf` subscribed.url) ("a WebSocket at " <> show subscribed.url)
      fill (locator page "#app .page-comments .comment-new textarea") "Live from the *smoke* test."
      click (withText "Comment" (locator page "#app .page-comments .comment-new button"))
      waitQuiet page
      hasText (locator page "#app .page-comments .comment-body em") "smoke"
      -- Pushed to the other tab over the WebSocket: a condition there.
      waitFor (withText "smoke" (locator watcher "#app .page-comments .comment-body em")) Visible
      settle watcher
    (.status) <$> get smoke.wiki Nothing "/api/v1/events" `shouldReturn` 426
    nothingWrongOnServer page

  -- Who is editing, over the same WebSocket, between two users: Sam, given
  -- Edit on the space, shows the page while Ada opens its editor in
  -- another tab. Sam's page says that she is editing, and Sam's editor
  -- names her and asks before starting; her closing the editor ends it,
  -- and so does her tab going away. A save of hers shows in Sam's tab
  -- without a reload. Each change reaches Sam's tab as a push: a
  -- condition there.
  step' "names one user's editor in another's page and editor until it closes or its tab goes, and shows a save in the other tab live; and a mention under the bell" $ \w -> do
    smokeSpace <- asAdmin smoke "GET" "spaces/at/smoke-space" Nothing >>= apiJson >>= text . (.! "id")
    users <- asAdmin smoke "GET" "admin/directory" Nothing >>= apiJson >>= list . (.! "users")
    samId <- orFail "no Sam in the directory" (find (\u -> u .! "login" == String "sam") users) >>= text . (.! "id")
    _ <-
      asAdmin smoke "PUT" ("spaces/" <> escape smokeSpace <> "/grants") (Just (object ["subject" .= object ["tag" .= ("SubjectUser" :: Text), "contents" .= samId], "permission" .= ("Edit" :: Text), "granted" .= True]))
        >>= expectStatus 204 "Sam's grant to edit the smoke space"
    samSession <- signInThroughTheForm w.browser smoke.origin "sam" "sam's password" >>= orFail "no session cookie for Sam" . snd
    let editing = adminName <> " is editing this page."
        pushed page' found = waitFor found Visible >> settle page'
    inBrowser smoke w.browser (As samSession) $ \samTab -> do
      visit samTab (address smoke "/s/smoke-space/p/first-page/")
      waitQuiet samTab
      hasText (locator samTab "#app .user-name") "Sam Smoke"
      count (locator samTab "#app .page-view .page-body") `shouldReturn` 1
      ada@(_, adaTab) <- openBrowser smoke w.browser Admin
      withFailureContext adaTab $ do
        visit adaTab (address smoke "/s/smoke-space/p/first-page/edit/")
        waitQuiet adaTab
        editorReady adaTab
      pushed samTab (withText editing (locator samTab "#app .page-actions .page-editors"))
      -- Sam's editor, opened, names Ada and asks before starting. The
      -- page's view stopped watching the page as it closed, and the tab
      -- forgot who edits it; the editor watches it again once it has read
      -- the page, and learns that Ada edits it from the server's answer to
      -- that subscription, over the WebSocket: a push, which 'waitQuiet'
      -- does not wait for, so a condition. The page's view, back, learns
      -- it the same way.
      click (locator samTab "#app .page-actions a[href$='/first-page/edit/']")
      waitQuiet samTab
      pushed samTab (withText "Open the editor anyway?" (locator samTab "#app .editor-presence-warning"))
      hasText (locator samTab "#app .editor-presence-warning") (editing <> " Open the editor anyway?")
      click (withText "Back to the page" (locator samTab "#app .editor-presence-warning button"))
      waitQuiet samTab
      pushed samTab (withText editing (locator samTab "#app .page-actions .page-editors"))
      -- Ada closes her editor: the presence ends.
      withFailureContext adaTab $ do
        click (locator adaTab "#app .editor-cancel")
        waitQuiet adaTab
        count (locator adaTab "#app .page-view .page-body") `shouldReturn` 1
      waitFor (locator samTab "#app .page-live") Hidden
      settle samTab
      -- She opens it again, and her tab goes away without a word: so does
      -- the presence, with the connection.
      withFailureContext adaTab $ do
        click (locator adaTab "#app .page-actions a[href$='/first-page/edit/']")
        waitQuiet adaTab
        editorReady adaTab
      pushed samTab (withText editing (locator samTab "#app .page-actions .page-editors"))
      closeBrowser ada
      waitFor (locator samTab "#app .page-live") Hidden
      settle samTab
      -- A save of hers, made elsewhere, shows in Sam's tab without a
      -- reload: the push, then Sam's program reads the page.
      (shownPage, tag) <- pageAtWithTag smoke "smoke-space" "first-page"
      pid <- text (shownPage .! "id")
      body <- text (shownPage .! "body")
      s <- adminSession smoke
      _ <- api smoke.wiki (Just s) "PUT" ("pages/" <> escape pid) (Just (object ["title" .= ("First page" :: Text), "body" .= (body <> "\n\nSaved while Sam reads.")])) [("If-Match", Text.encodeUtf8 tag)] >>= expectStatus 200 "the save Sam's tab shows"
      waitFor (withText "Saved while Sam reads." (locator samTab "#app .page-view .page-body")) Visible
      waitQuiet samTab
      report "two users' tabs on a page: one's editor is named in the other's page and editor, until it closes or its tab goes; a save shows in the other tab live"
      -- A mention (WP4.13): Ada's comment names Sam, who is told at once
      -- under the bell in his tab, over the WebSocket, and sees the
      -- mention as a link.
      _ <- api smoke.wiki (Just s) "POST" ("pages/" <> escape pid <> "/threads") (Just (object ["anchor" .= Null, "body" .= ("Over to you, @sam." :: Text)])) [] >>= expectStatus 201 "the comment that mentions Sam"
      waitFor (withText "1" (locator samTab "#app .notifications-count")) Visible
      waitQuiet samTab
      click (locator samTab "#app .notifications-toggle")
      waitQuiet samTab
      hasText (locator samTab "#app .notification-list .notification-what") (adminName <> " mentioned you")
      -- The comment itself reaches Sam's page in a push of its own, about
      -- the page's threads, apart from the notification's: a condition.
      pushed samTab (withText "@sam" (locator samTab "#app .page-comments a.mention"))
      hasText (locator samTab "#app .page-comments a.mention") "@sam"
      report "a comment that mentions a user is told under the bell in their tab, over the WebSocket, and links to them"
    nothingWrongOnServer w.page

  -- 3. Every route of the walk, rendered by the server.
  step' "renders every address of the walk, with its content before app.wasm, and adopts it with nothing to repair or ask" $ \w -> do
    loads <- loadsOf loadsRef
    forM_ walked $ \(path, status, expected) -> do
      loaded <- loadAdopted smoke loads w.page path
      adoptedCleanly path loaded status expected
    report (tshow (length walked) <> " addresses of the walk are rendered by the server, with their content before app.wasm, and adopted with nothing to repair or ask")
    nothingWrongOnServer w.page

  -- Without JavaScript, the page is there all the same.
  step' "reads a page as the server rendered it with JavaScript off" $ \w -> do
    s <- adminSession smoke
    withSessionContext w.browser defaultContextOptions {javaScriptEnabled = False} smoke.origin (Just s) $ \reader -> do
      gotoStatus reader (address smoke "/s/smoke-space/p/first-page/") `shouldReturn` Just 200
      readable <- textContent (locator reader "#app .page-body")
      includes readable "Hello from the server's smoke test." "the page without JavaScript"
      includes readable "Saved by someone else." "the page without JavaScript"

-- | Every route the walk went through, its status, and a text it shows
-- before the program runs.
walked :: [(Text, Int, Text)]
walked =
  [ ("/", 200, "Smoke space")
  , ("/s/smoke-public/", 200, "Smoke public")
  , ("/s/smoke-public/pages/", 200, "Where the smoke test writes in public.")
  , ("/s/smoke-space/", 200, "Welcome to Smoke space.")
  , ("/s/smoke-space/pages/", 200, "Space settings")
  , ("/s/smoke-space/p/first-page/", 200, "Saved by someone else.")
  , ("/s/smoke-space/p/first-page/source/", 200, "(attachment:notes.txt)")
  , ("/s/smoke-space/p/first-page/history/", 200, "Version 1")
  , -- A document is not presented: its address of slides says so.
    ("/s/smoke-space/p/first-page/slides/", 200, "is a document, not a presentation")
  , ("/s/smoke-space/p/first-page/edit/", 200, "Editing First page")
  , ("/s/smoke-space/new-page/", 200, "New page")
  , ("/new-space/", 200, "New space")
  , ("/search/?q=smoke", 200, "First page")
  , ("/admin/", 200, "wiki-server")
  , ("/admin/users/", 200, "Manage")
  , ("/admin/groups/", 200, "Smoke testers")
  , ("/unsubscribe/not-a-secret/", 200, "Stop the mail")
  , ("/whats-new/", 200, "What's new?")
  , ("/s/smoke-space/p/no-such-page/", 404, "There is nothing here")
  , ("/no/such/address", 404, "Not found")
  ]

----------------------------------------------------------------------
-- Small things

-- | Whether the parts are in the text in this order.
inOrder :: Text -> [Text] -> Bool
inOrder _ [] = True
inOrder t (p : ps) = case Text.breakOn p t of
  (_, rest) | Text.null rest -> False
  (_, rest) -> inOrder (Text.drop (Text.length p) rest) ps

-- | @wiki-YYYY-MM-DD.zip@.
exportName :: Text -> Bool
exportName name = case Text.stripPrefix "wiki-" name >>= Text.stripSuffix ".zip" of
  Just date -> Text.length date == 10 && and [if i `elem` [4, 7] then c == '-' else isDigit c | (i, c) <- zip [0 :: Int ..] (Text.unpack date)]
  Nothing -> False

-- | @api/v1/spaces/<id>/icon/<64 hex>@.
iconAddress :: Text -> Bool
iconAddress src = case Text.splitOn "/" src of
  ["api", "v1", "spaces", sid, "icon", digest] -> not (Text.null sid) && Text.length digest == 64 && Text.all (`elem` ("0123456789abcdef" :: String)) digest
  _ -> False

-- | A PNG of one pixel.
pixel :: ByteString
pixel = Base64.decodeLenient "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

safeHead :: [a] -> Maybe a
safeHead = \case
  x : _ -> Just x
  [] -> Nothing

-- | The code of an authenticator application for a base32 secret now (RFC
-- 6238: HMAC-SHA-1 of the 30-second step, six digits), as the suite's own,
-- second implementation of the server's.
totpNow :: Text -> IO Text
totpNow secret = do
  now <- getPOSIXTime
  key <- either fail pure (convertFromBase Base32 (padded (Text.encodeUtf8 (Text.map toUpper secret))) :: Either String ByteString)
  let step30 = floor (now / 30) :: Word64
      counter = ByteString.pack [fromIntegral (step30 `div` (2 ^ (8 * k))) | k <- [7, 6 .. 0 :: Int]]
      mac = convert (hmac key counter :: HMAC SHA1) :: ByteString
      offset = fromIntegral (ByteString.last mac .&. 0x0f)
      byte i = fromIntegral (ByteString.index mac (offset + i)) :: Word64
      value = (((byte 0 .&. 0x7f) `shiftL` 24) .|. (byte 1 `shiftL` 16) .|. (byte 2 `shiftL` 8) .|. byte 3) `mod` 1000000
      digits = show value
  pure (Text.pack (replicate (6 - length digits) '0' <> digits))
  where
    padded b = b <> ByteString.replicate ((8 - ByteString.length b `mod` 8) `mod` 8) 61
