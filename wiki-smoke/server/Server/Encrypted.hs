-- | Encrypted spaces (WP5.74b2 and b3 of docs/PLAN.md, decisions 76 and
-- 80) against the real server, in real browsers, on 127.0.0.1, which a
-- browser treats as a secure page and so gives WebCrypto:
--
-- * The administrator signs in through the form, which makes her key pair
--   in that browser, makes a space, and encrypts it with the permissions'
--   "Encrypt this space…" and its confirmation.
-- * She writes a page through the forms: a first version, and a second
--   that no longer has the first's text. She reads the page back, and the
--   older text in its history; she attaches a file and comments on text
--   she selects.
-- * A reader signs in in a browser of her own, is granted the space, and
--   waits for its key; the administrator's browser shares it when she next
--   opens the space; the reader then reads the page, and her reply is
--   named under the administrator's bell by the page's title, decrypted.
-- * The administrator, in a browser that holds none of her keys (signed in
--   by her session's cookie alone), sees the space locked, and unlocks it
--   with her password in the space's own unlock form.
-- * After the reader's removal (a new key), the page nobody saved since is
--   read in a new browser and in the one opened before; a subspace made
--   then is encrypted with a key of its own, and its reader alone reads it.
-- * She exports the space through its "Export, decrypted here", which a
--   second server, on a fresh data directory of its own, imports; every
--   title, text, attachment and comment is there, plain. The second server
--   is outside the canary's watch: the export's plain text is the
--   reader's to keep.
-- * The detached preview, and the gate that asks each time the space is
--   opened ("Wiki.App.View.Encrypted"'s @sealScreen@).
-- * The canary ("Server.Canary"): none of the markers is found anywhere.
-- * A space written plain is encrypted page by page in her browser
--   (decision 80's conversion), read back, checked to have left no plain
--   text but in the backup made before it; then turned plain again, and
--   encrypted again; a decryption stopped halfway is turned back; both
--   browsers take each new chain of versions as such, not as a fork.
--
-- How it waits. Everything the browsers do here is the program's: the
-- key pair kept after the sign-in, a key shared with a reader when a
-- member opens the space (in the same requests as the space's list of
-- pages), a conversion's stages and commits: so after each action that
-- asks the server the suite waits until the page is quiet, and reads once.
-- Where the JavaScript test waited for a save's answer, the suite asks the
-- server's sealed routes how many versions, threads or pages it now has.
-- What is the server's own (the checkpoint that ends a conversion) and a
-- download are conditions.
module Server.Encrypted (spec) where

import Control.Monad (forM_)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.Aeson (Value (..), object, (.=))
import Data.ByteString qualified as ByteString
import Data.CaseInsensitive qualified as CaseInsensitive
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isPrefixOf, isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Halogen.Playwright hiding (title)
import Halogen.Playwright.Hspec
import Network.HTTP.Types (Method)
import Server.Canary
import Server.Site
import System.FilePath ((</>))
import Test.Hspec qualified as Hspec
import Wiki.Smoke.Api
import Wiki.Smoke.Browser
import Wiki.Smoke.Server
import Wiki.Smoke.Walk

-- | A browser of the walk's, watched by the canary: its context, its page,
-- and, when signed in, whose it is.
data Browser = Browser
  { context :: Context
  , page :: Page
  , watched :: Watched
  , session :: Session
  , userId :: Text
  }

-- | What the walk's examples share beyond the server.
data Walk = Walk
  { smoke :: Smoke
  , shown :: IORef [Text]
  -- ^ Every text read back in the browsers, which the canary's markers
  -- must be in.
  , ada :: IORef (Maybe Browser)
  , bea :: IORef (Maybe Browser)
  , elsewhere :: IORef (Maybe Browser)
  , ada2 :: IORef (Maybe Browser)
  , spaceId :: IORef Text
  , encryption :: IORef Value
  , pageAddress :: IORef Text
  , searchWord :: IORef Text
  , innerAddress :: IORef Text
  , inner :: IORef Value
  , convert :: IORef Text
  , since' :: IORef (Maybe Since)
  }

spec :: Smoke -> SpecWith Playwright
spec smoke = describe "encrypted spaces, and the canary" $ do
  walk <- Hspec.runIO $ do
    shown <- newIORef []
    browsers <- traverse (const (newIORef Nothing)) [1 :: Int .. 4]
    texts' <- traverse (const (newIORef "")) [1 :: Int .. 5]
    inner <- newIORef Null
    encryption <- newIORef Null
    since' <- newIORef Nothing
    case (browsers, texts') of
      ([a, b, e, a2], [sid, address', word, innerAddress, convert]) ->
        pure Walk {smoke, shown, ada = a, bea = b, elsewhere = e, ada2 = a2, spaceId = sid, encryption, pageAddress = address', searchWord = word, innerAddress, inner, convert, since'}
      _ -> fail "the walk's references"
  let step' = step smoke.chain
  encryptedWalk walk step'
  conversions walk step'

----------------------------------------------------------------------
-- Browsers, the API as someone, markers

-- | A browser of its own, watched by the canary: every request it sends
-- and every frame of its WebSockets.
watchedBrowser :: Walk -> Playwright -> IO (Context, Page, Watched)
watchedBrowser w pw = do
  ctx <- newContext pw serverContext
  watch w.smoke.canary ctx
  page <- newPage ctx
  watched <- watchPage w.smoke.canary page
  pure (ctx, page, watched)

-- | Signed in through the header's form, which makes the user's key pair
-- in this browser at the first sign-in with a password; the sign-in's
-- wait ends once the pair is kept, which the suite checks in IndexedDB.
signedIn :: Walk -> Playwright -> Text -> Text -> IO Browser
signedIn w pw login password = do
  (ctx, page, watched) <- watchedBrowser w pw
  withFailureContext page $ do
    visit page (address w.smoke "/")
    signInOn page login password `shouldReturn` SignedIn
    token <- find (\c -> c.name == "wiki_session") <$> cookies ctx >>= orFail (Text.unpack login <> ": no session cookie")
    me :: Value <- evaluate page "(async () => (await fetch('/api/v1/session')).json())()"
    userId <- text (me .! "user" .! "id")
    held :: Bool <-
      evaluateWith
        page
        "(slot) => new Promise((done) => {\
        \  const opened = indexedDB.open('wiki-assistant-keys', 1);\
        \  opened.onupgradeneeded = () => opened.result.createObjectStore('keys');\
        \  opened.onsuccess = () => {\
        \    const got = opened.result.transaction('keys', 'readonly').objectStore('keys').get(slot);\
        \    got.onsuccess = () => done(got.result instanceof CryptoKey);\
        \    got.onerror = () => done(false);\
        \  };\
        \  opened.onerror = () => done(false);\
        \})"
        ("identity:" <> userId)
    expect held (Text.unpack login <> "'s key pair is not kept in the browser")
    pure Browser {context = ctx, page, watched, session = Session token.value, userId}

-- | A watched browser with the session of another, signed in by its
-- cookie alone: it holds none of their keys.
withCookieOf :: Walk -> Playwright -> Browser -> IO Browser
withCookieOf w pw who = do
  (ctx, page, watched) <- watchedBrowser w pw
  addCookies ctx [sessionCookie w.smoke.origin who.session]
  pure Browser {context = ctx, page, watched, session = who.session, userId = who.userId}

-- | Close a browser of the walk's: its page checked, its frames taken
-- into what the canary has seen.
closeWalkBrowser :: Walk -> Browser -> IO ()
closeWalkBrowser w b = do
  withFailureContext b.page (nothingWrongOnServer b.page)
  unwatchPage w.smoke.canary b.watched
  closeContext b.context

-- | Ask the API as someone; the answer is recorded for the canary.
as :: Walk -> Browser -> Method -> Text -> Maybe Value -> [(Text, Text)] -> IO Reply
as w who method path body extra = do
  r <- api w.smoke.wiki (Just who.session) method path body [(CaseInsensitive.mk (Text.encodeUtf8 k), Text.encodeUtf8 v) | (k, v) <- extra]
  saw w.smoke.canary ("the test's " <> Text.decodeUtf8 method <> " " <> path) r.body
  pure r

-- | Ask the API as someone, outside the canary's watch: what the suite
-- writes plain on purpose, before a conversion.
raw :: Walk -> Browser -> Method -> Text -> Maybe Value -> [(Text, Text)] -> IO Reply
raw w who method path body extra = api w.smoke.wiki (Just who.session) method path body [(CaseInsensitive.mk (Text.encodeUtf8 k), Text.encodeUtf8 v) | (k, v) <- extra]

need :: IORef (Maybe a) -> String -> IO a
need ref what = readIORef ref >>= orFail (what <> " is not there: an earlier example did not pass")

-- | Keep what the browser shows now, for the canary's read-back.
readBack :: Walk -> Page -> IO ()
readBack w page = do
  t <- innerText (locator page "#app")
  atomicModifyIORef' w.shown (\xs -> (t : xs, ()))

markerOf :: Walk -> Text -> IO Text
markerOf w = marker w.smoke.canary

-- | The file attached to the encrypted page: an image whose name and
-- bytes are encrypted in the browser.
fileNameOf :: Walk -> IO Text
fileNameOf w = (<> ".svg") <$> markerOf w "attachment name"

fileBytesOf :: Walk -> IO Text
fileBytesOf w = (\m -> "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"7\" height=\"1\"><title>" <> m <> "</title></svg>") <$> markerOf w "attachment bytes"

-- | The file behind an attachment's link on the page: the link leads to an
-- object URL of the bytes, decrypted, which an SVG's link downloads,
-- never opens as a document; downloaded as a reader saves it, its bytes
-- are the file's, which the canary's read-back must find.
attachmentIn :: Walk -> Page -> IO Text
attachmentIn w p = do
  fileName <- fileNameOf w
  let link = withText fileName (locator p "#app .page-view .attachments a")
  count link `shouldReturn` 1
  href <- getAttribute link "href"
  expect (maybe False ("blob:" `Text.isPrefixOf`) href) ("the attachment's link is not decrypted: " <> show href)
  getAttribute link "download" `shouldReturn` Just fileName
  got <- download p (click link)
  bytes <- Text.decodeUtf8Lenient <$> downloadBytes got
  atomicModifyIORef' w.shown (\xs -> (bytes : xs, ()))
  pure bytes

-- | The comment and its mark, read from the server.
commentIn :: Walk -> Page -> IO ()
commentIn w p = do
  quote <- markerOf w "quote"
  comment <- markerOf w "comment"
  hasText (locator p "#app mark.comment-mark") quote
  click (locator p "#app .comments-toggle")
  waitQuiet p
  hasText (locator p "#app .comments-panel") comment

-- | The pages of an encrypted space, as the sealed routes list them.
sealedPages :: Walk -> Browser -> Text -> IO [Value]
sealedPages w who sid = as w who "GET" ("encrypted/spaces/" <> escape sid <> "/pages") Nothing [] >>= expectStatus 200 "the encrypted space's pages" >>= apiJson >>= list

-- | How many versions a page of an encrypted space has, by its slug; 0
-- when the server has no such page yet.
sealedVersions :: Walk -> Browser -> Text -> Text -> IO Int
sealedVersions w who sid slug = do
  pages <- sealedPages w who sid
  case find (\p -> p .! "slug" == String slug) pages of
    Nothing -> pure 0
    Just p -> do
      pid <- text (p .! "id")
      length <$> (as w who "GET" ("encrypted/pages/" <> escape pid <> "/versions") Nothing [] >>= expectStatus 200 "a sealed page's versions" >>= apiJson >>= list)

-- | The slug of the page the editor is at: @/s/<space path>/p/<slug>/edit/@.
editedSlug :: Page -> IO Text
editedSlug page = do
  path <- here page
  case reverse (filter (not . Text.null) (Text.splitOn "/" path)) of
    "edit" : slug : _ -> pure slug
    _ -> fail ("not an editor's address: " <> Text.unpack path)

-- | Save in the editor with Ctrl+S, and check through the sealed routes
-- that the server has one version more of the page.
savedSealed :: Walk -> Browser -> Text -> Page -> IO ()
savedSealed w who sid page = do
  slug <- editedSlug page
  before <- sealedVersions w who sid slug
  pressOn (editorText page) "Control+s"
  waitQuiet page
  sealedVersions w who sid slug `shouldReturn` before + 1

----------------------------------------------------------------------
-- The space, its page, its readers, the export, the gate, the canary

encryptedWalk :: Walk -> (String -> (Playwright -> IO ()) -> SpecWith Playwright) -> SpecWith Playwright
encryptedWalk w step' = do
  let smoke = w.smoke

  step' "encrypts a space through its permissions' \"Encrypt this space…\" and its confirmation" $ \pw -> do
    ada <- signedIn w pw adminLogin adminPassword
    writeIORef w.ada (Just ada)
    let page = ada.page
    withFailureContext page $ do
      click (locator page "#app .wiki-sidebar .new-space-link")
      fill (locator page "#app .new-space-view input") "Smoke secret"
      click (locator page "#app .new-space-view button.primary")
      waitQuiet page
      hasText (locator page "#app .sidebar-space-name") "Smoke secret"
      click (locator page "#app .space-pages-link")
      click (locator page "#app .space-settings-toggle")
      click (locator page "#app .space-permissions .encrypt-space")
      count (locator page "#app .space-permissions .encrypt-explained") `shouldReturn` 1
      click (locator page "#app .space-permissions .encrypt-confirm")
      waitQuiet page
      count (locator page "#app .space-permissions .encrypted-note") `shouldReturn` 1
      space <- as w ada "GET" "spaces/at/smoke-secret" Nothing [] >>= apiJson
      expect (not (isNull (space .! "encryption"))) ("the space is not encrypted: " <> show space)
      text (space .! "id") >>= writeIORef w.spaceId
      writeIORef w.encryption (space .! "encryption")
      nothingWrongOnServer page

  step' "writes a page of the encrypted space in two versions, and reads it back with its history" $ \_ -> do
    ada <- need w.ada "the administrator's browser"
    sid <- readIORef w.spaceId
    let page = ada.page
        editor = editorText page
    withFailureContext page $ do
      title <- markerOf w "title"
      -- A word the search looks for, which is no marker. The search
      -- page's address carries its words, and loading it sends them to the
      -- server, which searches the plain spaces with them: the server
      -- learns what a reader searched for, though never the encrypted
      -- pages nor which of them matched (the README's "What the server
      -- still sees"). A marker searched for would be found there by the
      -- canary, rightly.
      now <- getPOSIXTime
      let searchWord = "zebracrossing" <> tshow (floor (now * 1000) :: Integer)
      writeIORef w.searchWord searchWord
      -- The space's address shows its home page, made with it in this
      -- browser; its list of pages is under its settings.
      visit page (address smoke "/s/smoke-secret/")
      waitQuiet page
      hasText (locator page "#app .page-view .page-body") "Welcome to"
      visit page (address smoke "/s/smoke-secret/pages/")
      waitQuiet page
      click (withText "New page" (locator page "#app .space-view .actions a"))
      typeText (locator page "#app .new-page-title") title
      click (locator page "#app .new-page-view button.primary")
      waitQuiet page
      editorReady page
      pressOn editor "Control+End"
      pressOn editor "Enter"
      older <- markerOf w "older version"
      typeText editor ("At first: " <> older <> ".")
      -- A file attached, an image: its name and bytes encrypted in the
      -- browser. Its reference goes into this version, and the attachment
      -- stays the page's after the next.
      fileName <- fileNameOf w
      fileBytes <- fileBytesOf w
      setInputFiles (locator page "#app .editor-attach input[type=file]") [UploadBytes {name = fileName, mimeType = "image/svg+xml", bytes = Text.encodeUtf8 fileBytes}]
      waitQuiet page
      count (withText fileName (locator page "#app .editor-attachments a")) `shouldReturn` 1
      savedSealed w ada sid page
      -- The second version holds the title and a text of its own, and not
      -- the first's. The editor keeps the title line's "# "
      -- (web/src/editor.js): a selection of everything starts after it, so
      -- the title is typed alone.
      pressOn editor "Control+a"
      typeText editor title
      pressOn editor "Enter"
      pressOn editor "Enter"
      textMarker <- markerOf w "text"
      quote <- markerOf w "quote"
      typeText editor ("Now: " <> textMarker <> ", " <> quote <> " and " <> searchWord <> ".")
      savedSealed w ada sid page
      pageAddress <- Text.dropEnd (Text.length "edit/") <$> here page
      writeIORef w.pageAddress pageAddress
      visit page (address smoke pageAddress)
      waitQuiet page
      hasText (locator page "#app .page-view .page-body") textMarker
      readBack w page
      -- The history compares the latest version with the one before,
      -- whose text is the older marker.
      click (withText "History" (locator page "#app .page-view .actions a"))
      waitQuiet page
      hasText (locator page "#app .history-view") older
      readBack w page
      nothingWrongOnServer page

  step' "attaches a file and comments on selected text, encrypted in the browser, and reads both back decrypted" $ \_ -> do
    ada <- need w.ada "the administrator's browser"
    sid <- readIORef w.spaceId
    pageAddress <- readIORef w.pageAddress
    let page = ada.page
    withFailureContext page $ do
      fileBytes <- fileBytesOf w
      visit page (address smoke pageAddress)
      waitQuiet page
      attachmentIn w page `shouldReturn` fileBytes
      -- Text selected on the page, commented on: the comment and the text
      -- it quotes encrypted in the browser. The selection is made by
      -- script, and its mouseup is the program's to hear: settled after.
      quote <- markerOf w "quote"
      hasText (locator page "#app .page-view .page-body") quote
      _ :: Value <-
        evaluateWith
          page
          "(wanted) => {\
          \  const walker = document.createTreeWalker(document.querySelector('#app .page-body'), NodeFilter.SHOW_TEXT);\
          \  for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {\
          \    const at = node.data.indexOf(wanted);\
          \    if (at < 0) continue;\
          \    const range = document.createRange();\
          \    range.setStart(node, at);\
          \    range.setEnd(node, at + wanted.length);\
          \    getSelection().removeAllRanges();\
          \    getSelection().addRange(range);\
          \    node.parentElement.dispatchEvent(new MouseEvent('mouseup', { bubbles: true }));\
          \    return null;\
          \  }\
          \  return null;\
          \}"
          quote
      settle page
      click (locator page "#app .comment-on-selection")
      comment <- markerOf w "comment"
      fill (locator page "#app .comments-panel .new-thread textarea") comment
      pid <- pageIdAt w ada sid pageAddress
      threadsBefore <- threadCount w ada pid
      click (withText "Comment" (locator page "#app .comments-panel .new-thread button"))
      waitQuiet page
      threadCount w ada pid `shouldReturn` threadsBefore + 1
      hasText (locator page "#app mark.comment-mark") quote
      -- The comment and its mark, read again from the server.
      reload page
      waitStarted page
      waitQuiet page
      commentIn w page
      readBack w page
      nothingWrongOnServer page

  step' "makes a reader granted the space wait for its key, and read the page, its attachment and its comment once a member's browser has shared it" $ \pw -> do
    ada <- need w.ada "the administrator's browser"
    sid <- readIORef w.spaceId
    pageAddress <- readIORef w.pageAddress
    bea <- signedIn w pw readerUser.login readerUser.password
    writeIORef w.bea (Just bea)
    _ <- as w ada "PUT" ("spaces/" <> escape sid <> "/grants") (Just (grantTo bea.userId)) [] >>= expectStatus 204 "granting the reader the space"
    withFailureContext bea.page $ do
      visit bea.page (address smoke "/s/smoke-secret/")
      waitQuiet bea.page
      hasText (locator bea.page "#app .encrypted-state") "no member has shared its key with you yet"
    -- The administrator opens the space: her browser seals its key to the
    -- reader, in the requests that read the space's pages.
    withFailureContext ada.page $ do
      visit ada.page (address smoke "/s/smoke-secret/")
      waitQuiet ada.page
      hasText (locator ada.page "#app .page-view .page-body") "Welcome to"
    withFailureContext bea.page $ do
      fileBytes <- fileBytesOf w
      textMarker <- markerOf w "text"
      click (locator bea.page "#app .encrypted-retry")
      waitQuiet bea.page
      hasText (locator bea.page "#app .page-view .page-body") "Welcome to"
      visit bea.page (address smoke pageAddress)
      waitQuiet bea.page
      hasText (locator bea.page "#app .page-view .page-body") textMarker
      attachmentIn w bea.page `shouldReturn` fileBytes
      commentIn w bea.page
      readBack w bea.page
      nothingWrongOnServer bea.page

  -- The reader replies in the administrator's thread: the server tells the
  -- administrator, naming the page "an encrypted page", and her bell shows
  -- the page's title decrypted in her browser. The canary's check covers
  -- what the bell fetched: the notifications and the headings.
  step' "names the page the reader replied on by its title, decrypted, under the administrator's bell" $ \_ -> do
    ada <- need w.ada "the administrator's browser"
    bea <- need w.bea "the reader's browser"
    sid <- readIORef w.spaceId
    pageAddress <- readIORef w.pageAddress
    title <- markerOf w "title"
    textMarker <- markerOf w "text"
    reply <- markerOf w "reply"
    -- It mentions a login that is nobody's, a marker too: the browser
    -- names a mention in an encrypted space from the space's readers, and
    -- sends no login it found in decrypted text to the server.
    login <- markerOf w "login"
    pid <- pageIdAt w ada sid pageAddress
    withFailureContext bea.page $ do
      let replyBox = locator bea.page "#app .comments-panel .comment-reply"
      fill (locator replyBox "textarea") (reply <> " @" <> login)
      before <- commentCount w bea pid
      click (withText "Reply" (locator replyBox "button"))
      waitQuiet bea.page
      commentCount w bea pid `shouldReturn` before + 1
      hasText (locator bea.page "#app .comments-panel") reply
      readBack w bea.page
      nothingWrongOnServer bea.page
    withFailureContext ada.page $ do
      visit ada.page (address smoke pageAddress)
      waitQuiet ada.page
      hasText (locator ada.page "#app .page-view .page-body") textMarker
      click (locator ada.page "#app .notifications-toggle")
      waitQuiet ada.page
      hasText (locator ada.page "#app .notification-list .notification-page") title
      readBack w ada.page
      click (locator ada.page "#app .notifications-toggle")
      nothingWrongOnServer ada.page

  step' "shows the space locked in a browser without the keys, and its own form unlocks it with the password" $ \pw -> do
    ada <- need w.ada "the administrator's browser"
    pageAddress <- readIORef w.pageAddress
    textMarker <- markerOf w "text"
    fresh <- withCookieOf w pw ada
    writeIORef w.elsewhere (Just fresh)
    withFailureContext fresh.page $ do
      visit fresh.page (address smoke pageAddress)
      waitQuiet fresh.page
      hasText (locator fresh.page "#app .encrypted-state") "does not hold your keys"
      fill (locator fresh.page "#app .encrypted-unlock input[name=encrypted-password]") adminPassword
      click (locator fresh.page "#app .encrypted-unlock-password")
      waitQuiet fresh.page
      hasText (locator fresh.page "#app .page-view .page-body") textMarker
      readBack w fresh.page
      nothingWrongOnServer fresh.page

  -- The administrator revokes the reader in the space's permissions: her
  -- browser gives the space a new key at once, without the space being
  -- opened again. The page nobody saved since stays under its older page
  -- key, and is read, with its history, its attachment, its comment and
  -- in the search, in a new browser's tab, and in the tab of the browser
  -- opened before.
  step' "renews the key at a reader's removal, and the page nobody saved since reads in a new browser and in the one opened before, with its attachment, comment, history and search" $ \pw -> do
    ada <- need w.ada "the administrator's browser"
    bea <- need w.bea "the reader's browser"
    fresh <- need w.elsewhere "the browser without the keys"
    sid <- readIORef w.spaceId
    pageAddress <- readIORef w.pageAddress
    searchWord <- readIORef w.searchWord
    title <- markerOf w "title"
    textMarker <- markerOf w "text"
    older <- markerOf w "older version"
    fileBytes <- fileBytesOf w
    keyBefore <- as w ada "GET" ("encrypted/spaces/" <> escape sid) Nothing [] >>= apiJson
    withFailureContext ada.page $ do
      visit ada.page (address smoke "/s/smoke-secret/pages/")
      waitQuiet ada.page
      click (locator ada.page "#app .space-settings-toggle")
      click (locator ada.page ("#app .grant-row[data-subject=" <> readerUser.login <> "] .grant-revoke"))
      waitQuiet ada.page
    keyAfter <- as w ada "GET" ("encrypted/spaces/" <> escape sid) Nothing [] >>= apiJson
    expect (keyAfter .! "keyId" /= keyBefore .! "keyId") "the space's key was not renewed at the reader's removal"
    let readsAfter p who = withFailureContext p $ do
          visit p (address smoke "/s/smoke-secret/pages/")
          waitQuiet p
          hasText (locator p "#app .space-view") title
          visit p (address smoke pageAddress)
          waitQuiet p
          hasText (locator p "#app .page-view .page-body") textMarker
          attachmentIn w p `shouldReturn` fileBytes
          commentIn w p
          click (withText "History" (locator p "#app .page-view .actions a"))
          waitQuiet p
          hasText (locator p "#app .history-view") older
          visit p (address smoke ("/search/?q=" <> escape searchWord <> "&space=smoke-secret"))
          waitQuiet p
          hasText (locator p "#app .search-hits .search-hit-title") title
          readBack w p
          nothingWrongOnServer p
          report ("after the new key, " <> who <> " reads the page nobody saved since, its attachment, its comment, its history and its search")
    -- A browser that holds none of her keys yet: unlocked first.
    afterwards <- withCookieOf w pw ada
    withFailureContext afterwards.page $ do
      visit afterwards.page (address smoke pageAddress)
      waitQuiet afterwards.page
      fill (locator afterwards.page "#app .encrypted-unlock input[name=encrypted-password]") adminPassword
      click (locator afterwards.page "#app .encrypted-unlock-password")
      waitQuiet afterwards.page
      hasText (locator afterwards.page "#app .page-view .page-body") textMarker
    readsAfter afterwards.page "a new browser"
    readsAfter fresh.page "the browser opened before"
    closeWalkBrowser w afterwards
    -- The reader, removed, no longer has the space.
    _ <- pure bea
    pure ()

  -- Made after the reader's removal, so that no renewal of its key falls
  -- due: made from the encrypted space's "New subspace", it is encrypted
  -- with a key of its own, and its home page is made in her browser. Its
  -- name is plain, as every space's; its pages' titles and texts are not.
  step' "encrypts a subspace of the encrypted space with a key of its own, and a reader of it alone reads its page and not the space around it" $ \_ -> do
    ada <- need w.ada "the administrator's browser"
    bea <- need w.bea "the reader's browser"
    title <- markerOf w "title"
    innerTitle <- markerOf w "subspace title"
    innerText' <- markerOf w "subspace text"
    encryption <- readIORef w.encryption
    let page = ada.page
    innerAddress <- withFailureContext page $ do
      -- From the space's list of pages, once it shows a title decrypted
      -- here (the program runs): the form is the program's, not the page
      -- the server rendered.
      visit page (address smoke "/s/smoke-secret/pages/")
      waitQuiet page
      hasText (locator page "#app .space-view") title
      click (withText "New subspace" (locator page "#app .space-view .actions a"))
      fill (locator page "#app .new-space-view input") "Smoke inner"
      click (locator page "#app .new-space-view button.primary")
      waitQuiet page
      inner <- as w ada "GET" "spaces/at/smoke-secret/smoke-inner" Nothing [] >>= expectStatus 200 "the encrypted subspace" >>= apiJson
      expect (not (isNull (inner .! "encryption")) && not (isNull (inner .! "homePage")) && inner .! "encryption" /= encryption) ("the subspace is not encrypted with a key of its own: " <> show inner)
      writeIORef w.inner inner
      innerId <- text (inner .! "id")
      visit page (address smoke "/s/smoke-secret/smoke-inner/")
      waitQuiet page
      hasText (locator page "#app .page-view .page-body") "Welcome to"
      visit page (address smoke "/s/smoke-secret/smoke-inner/pages/")
      waitQuiet page
      click (withText "New page" (locator page "#app .space-view .actions a"))
      typeText (locator page "#app .new-page-title") innerTitle
      click (locator page "#app .new-page-view button.primary")
      waitQuiet page
      editorReady page
      pressOn (editorText page) "Control+End"
      pressOn (editorText page) "Enter"
      typeText (editorText page) ("Inside: " <> innerText' <> ".")
      savedSealed w ada innerId page
      Text.dropEnd (Text.length "edit/") <$> here page
    writeIORef w.innerAddress innerAddress
    -- The reader removed from the space is granted the subspace alone:
    -- the administrator's browser shares its key when she opens it, and
    -- the reader reads its page; the space around it stays closed to her.
    inner <- readIORef w.inner
    innerId <- text (inner .! "id")
    _ <- as w ada "PUT" ("spaces/" <> escape innerId <> "/grants") (Just (grantTo bea.userId)) [] >>= expectStatus 204 "granting the reader the subspace"
    withFailureContext page $ do
      visit page (address smoke "/s/smoke-secret/smoke-inner/pages/")
      waitQuiet page
      hasText (locator page "#app .space-view") innerTitle
      nothingWrongOnServer page
    withFailureContext bea.page $ do
      visit bea.page (address smoke innerAddress)
      waitQuiet bea.page
      hasText (locator bea.page "#app .page-view .page-body") innerText'
      readBack w bea.page
      nothingWrongOnServer bea.page
    around' <- as w bea "GET" "spaces/at/smoke-secret" Nothing []
    expect (around'.status /= 200) "the reader of the subspace alone reads the space around it"

  -- From the space's list of pages, once it shows a title decrypted here.
  -- Her browser holds both keys, so nothing is left out.
  step' "exports the space decrypted in the browser, which a server on a fresh data directory imports with its title, text, attachment, comment and subspace" $ \_ -> do
    ada <- need w.ada "the administrator's browser"
    title <- markerOf w "title"
    textMarker <- markerOf w "text"
    quote <- markerOf w "quote"
    comment <- markerOf w "comment"
    reply <- markerOf w "reply"
    login <- markerOf w "login"
    innerTitle <- markerOf w "subspace title"
    innerText' <- markerOf w "subspace text"
    fileName <- fileNameOf w
    fileBytes <- fileBytesOf w
    let page = ada.page
    exported <- withFailureContext page $ do
      visit page (address smoke "/s/smoke-secret/pages/")
      waitQuiet page
      hasText (locator page "#app .space-view") title
      click (locator page "#app .space-view .export-decrypted")
      hasText (locator page "#app .export-decrypted-panel") "older versions"
      got <- download page (click (locator page "#app .export-decrypted-confirm"))
      expect (decryptedName got.suggestedFilename) ("the export's file name: " <> show got.suggestedFilename)
      bytes <- downloadBytes got
      waitQuiet page
      done <- textContent (locator page "#app .export-decrypted-done")
      includes done "4 pages of 2 spaces" "the export's summary"
      expect (not ("Left out" `Text.isInfixOf` done)) ("the export left something out: " <> Text.unpack done)
      nothingWrongOnServer page
      pure bytes
    -- A second server, on a fresh data directory beside the first's,
    -- always on SQLite (the PostgreSQL run's database is the first
    -- server's, which the canary dumps), with the archive imported through
    -- its admin listener's merge import, which asks nobody to sign in. What
    -- it is sent and answers is not watched: the plain text there is what
    -- the export is for.
    withServer smoke.build (serverOptions (smoke.build.work </> "imported") SQLite) {guide = False} $ \second -> do
      adminRoot <- orFail "the second server named no admin listener" second.adminOrigin
      let apiRoot = adminRoot <> "/admin/api/v1"
      applied <-
        uploadAt smoke.wiki Nothing (apiRoot <> "/import/apply") "archive" "export.zip" "application/zip" exported [("choices", "{\"skipSpaces\":[],\"skipPages\":[],\"conflicts\":[]}")]
          >>= expectStatus 200 "the import of the export"
      includes (bodyText applied) "\"spacesCreated\":2" "the import's summary"
      let at' path = get smoke.wiki Nothing (apiRoot <> "/" <> path) >>= expectStatus 200 ("the second server's " <> Text.unpack path) >>= apiJson
          pagesOf' spacePath = do
            s <- at' ("spaces/at/" <> spacePath)
            sid <- text (s .! "id")
            ps <- at' ("spaces/" <> escape sid <> "/pages") >>= list
            pure (s, sid, ps)
      (outer, outerId, outerPages) <- pagesOf' "smoke-secret"
      outer .! "encryption" `shouldBe` Null
      summary <- orFail ("the page is not imported: " <> show (map (.! "title") outerPages)) (find (\p -> p .! "title" == String title) outerPages)
      slug <- text (summary .! "slug")
      imp <- at' ("spaces/" <> escape outerId <> "/pages/at/" <> slug)
      impBody <- text (imp .! "body")
      expect (textMarker `Text.isInfixOf` impBody && quote `Text.isInfixOf` impBody) "the imported page's text"
      attachments <- list (imp .! "attachments")
      described <- traverse (\a -> (,,) <$> text (a .! "name") <*> text (a .! "mediaType") <*> int (a .! "size")) attachments
      described `shouldBe` [(fileName, "image/svg+xml", ByteString.length (Text.encodeUtf8 fileBytes))]
      aid <- case attachments of
        a : _ -> text (a .! "id")
        [] -> fail "no attachment imported"
      bytes <- get smoke.wiki Nothing (apiRoot <> "/attachments/" <> escape aid <> "/" <> escape fileName) >>= expectStatus 200 "the imported attachment"
      Text.decodeUtf8Lenient bytes.body `shouldBe` fileBytes
      impId <- text (imp .! "id")
      threads <- at' ("pages/" <> escape impId <> "/threads") >>= list
      described' <- traverse (\t -> (,) (t .! "anchor" .! "exact") <$> (list (t .! "comments") >>= traverse (text . (.! "body")))) threads
      described' `shouldBe` [(String quote, [comment, reply <> " @" <> login])]
      case threads of
        t : _ -> do
          firstAuthor <-
            list (t .! "comments") >>= \cs -> case cs of
              c : _ -> text (c .! "author" .! "name")
              [] -> fail "no comment"
          expect ("Ada Admin" `Text.isInfixOf` firstAuthor) ("the imported comment's author: " <> show firstAuthor)
        [] -> fail "no thread imported"
      (_, innerId, innerPages) <- pagesOf' "smoke-secret/smoke-inner"
      innerSummary <- orFail "the subspace's page is not imported" (find (\p -> p .! "title" == String innerTitle) innerPages)
      innerSlug <- text (innerSummary .! "slug")
      innerPage <- at' ("spaces/" <> escape innerId <> "/pages/at/" <> innerSlug)
      text (innerPage .! "body") >>= \b -> includes b innerText' "the imported subspace page's text"

  step' "shows the page decrypted in its detached preview, and behind a gate that asks each time nothing until the password is typed, and nothing once left" $ \pw -> do
    ada <- need w.ada "the administrator's browser"
    bea <- need w.bea "the reader's browser"
    sid <- readIORef w.spaceId
    pageAddress <- readIORef w.pageAddress
    title <- markerOf w "title"
    textMarker <- markerOf w "text"
    comment <- markerOf w "comment"
    reply <- markerOf w "reply"
    -- What the server keeps and sends, to anyone.
    forM_ [(Just ada.session, "the administrator"), (Just bea.session, "the reader"), (Nothing, "nobody")] $ \(who, name) ->
      forM_ [pageAddress, "/s/smoke-secret/", "/sitemap.xml"] $ \path -> do
        r <- get smoke.wiki who path
        saw smoke.canary (path <> " as " <> name) r.body
    _ <- pure pw
    -- The page's preview detached from its editor, in a window of its own:
    -- the page as saved, decrypted there.
    preview <- newPage ada.context
    previewWatched <- watchPage smoke.canary preview
    withFailureContext preview $ do
      visit preview (address smoke (pageAddress <> "live-preview/"))
      waitQuiet preview
      hasText (locator preview "#app .live-preview-body") textMarker
      readBack w preview
      nothingWrongOnServer preview
    unwatchPage smoke.canary previewWatched
    closePage preview
    report "the page's detached preview shows it decrypted in its own window"
    -- Asking each time the space is opened: a page of it opened afresh
    -- shows nothing of it, and decrypts nothing, until the password is
    -- typed in its form.
    _ <- as w ada "PUT" ("encrypted/spaces/" <> escape sid <> "/entry") (Just (object ["entry" .= ("confirm-each-time" :: Text)])) [] >>= expectStatus 200 "asking each time the space is opened"
    gated <- newPage ada.context
    gatedWatched <- watchPage smoke.canary gated
    withFailureContext gated $ do
      visit gated (address smoke pageAddress)
      waitQuiet gated
      count (locator gated "#app .encrypted-confirm input[name=encrypted-password]") `shouldReturn` 1
      before <- innerText (locator gated "#app")
      forM_ [title, textMarker, comment, reply] $ \m -> expect (not (m `Text.isInfixOf` before)) (Text.unpack m <> " shown behind the gate")
      fill (locator gated "#app .encrypted-confirm input[name=encrypted-password]") adminPassword
      click (locator gated "#app .encrypted-confirm-password")
      waitQuiet gated
      hasText (locator gated "#app .page-view .page-body") textMarker
      readBack w gated
      -- Left for the front page: nothing of the space on it, taken off the
      -- screen before any request is made.
      click (locator gated "#app .wiki-brand")
      here gated `shouldReturn` "/"
      waitQuiet gated
      after <- innerText (locator gated "#app")
      forM_ [title, textMarker] $ \m -> expect (not (m `Text.isInfixOf` after)) (Text.unpack m <> " shown after leaving the gate")
      nothingWrongOnServer gated
    unwatchPage smoke.canary gatedWatched
    closePage gated
    _ <- as w ada "PUT" ("encrypted/spaces/" <> escape sid <> "/entry") (Just (object ["entry" .= ("at-once" :: Text)])) [] >>= expectStatus 200 "asking no more"
    report "a space that asks each time shows and decrypts nothing until the password is typed in its form, and nothing once left"

  step' "finds none of the encrypted space's markers in any file of the data directory, the database, or anything the browsers sent or the suite read" $ \_ -> do
    shown <- Text.unlines <$> readIORef w.shown
    checked <- assertNoCanary smoke.canary smoke.dataDir smoke.database shown
    report ("none of " <> tshow checked.markers <> " markers of the encrypted space is in any of " <> tshow checked.places <> " files, requests, frames and answers")
    report ("the places: " <> Text.intercalate ", " [tshow n <> " " <> k | (k, n) <- checked.kinds])

----------------------------------------------------------------------
-- A space that has pages, encrypted, and turned plain again

conversions :: Walk -> (String -> (Playwright -> IO ()) -> SpecWith Playwright) -> SpecWith Playwright
conversions w step' = do
  let smoke = w.smoke
      pm place = plainMarker smoke.canary ("convert " <> place)
      plainBytes = pm "bytes"
      plainBlob = Text.unpack (Text.pack (show (hashWith SHA256 (Text.encodeUtf8 plainBytes))))

  -- Written plain first, through the API, as any space is: a title, a
  -- text, an older version, a comment on a quote, an attachment's name and
  -- bytes. A backup is made of it, deliberately, before it is encrypted.
  -- Then the administrator encrypts it from its permissions, in her
  -- browser, page by page; afterwards no marker is in any file of the data
  -- directory but the backup and the attachment's plain file it names
  -- (kept by design until the backup is pruned), nor in the database's
  -- dump, nor in anything sent since.
  step' "encrypts a space that had pages page by page in its administrator's browser, read back decrypted with its history, comment and attachment, and none of its plain markers is left but in the backup made before" $ \pw -> do
    bea <- need w.bea "the reader's browser"
    ada2 <- signedIn w pw adminLogin adminPassword
    writeIORef w.ada2 (Just ada2)
    convert <- raw w ada2 "POST" "spaces" (Just (object ["parent" .= Null, "name" .= ("Smoke convert" :: Text)])) [] >>= expectStatus 201 "the space to convert" >>= apiJson
    convertId <- text (convert .! "id")
    writeIORef w.convert convertId
    created <- raw w ada2 "POST" ("spaces/" <> escape convertId <> "/pages") (Just (object ["parent" .= Null, "title" .= pm "title", "body" .= ("Once: " <> pm "older" <> ".")])) [] >>= expectStatus 201 "the page to convert"
    createdPage <- apiJson created
    pid <- text (createdPage .! "id")
    -- Two more pages, so that a conversion can be stopped halfway; and the
    -- reader of the first part, who reads the space too.
    forM_ [1 :: Int, 2] $ \n ->
      raw w ada2 "POST" ("spaces/" <> escape convertId <> "/pages") (Just (object ["parent" .= Null, "title" .= ("Filler " <> tshow n), "body" .= ("Filler." :: Text)])) [] >>= expectStatus 201 "a filler page"
    _ <- raw w ada2 "PUT" ("spaces/" <> escape convertId <> "/grants") (Just (grantTo bea.userId)) [] >>= expectStatus 204 "the reader of the space to convert"
    tag <- orFail "the page's version tag" (header "etag" created)
    _ <- raw w ada2 "PUT" ("pages/" <> escape pid) (Just (object ["title" .= pm "title", "body" .= ("Now: " <> pm "text" <> " and " <> pm "quote" <> ".")])) [("If-Match", tag)] >>= expectStatus 200 "the page's second version"
    _ <- raw w ada2 "POST" ("pages/" <> escape pid <> "/threads") (Just (object ["anchor" .= object ["exact" .= pm "quote", "prefix" .= ("and " :: Text), "suffix" .= ("." :: Text)], "body" .= pm "comment"])) [] >>= expectStatus 201 "the comment"
    _ <- upload smoke.wiki ada2.session ("pages/" <> escape pid <> "/attachments") "file" (pm "name" <> ".txt") "text/plain" (Text.encodeUtf8 plainBytes) [] >>= expectStatus 201 "the attachment"
    backup <- raw w ada2 "POST" "admin/server/backups/run" Nothing [] >>= expectStatus 200 "the backup before the conversion" >>= apiJson
    backupFile <- text (backup .! "last" .! "file")
    backup .! "last" .! "failure" `shouldBe` Null
    let converter = ada2.page
    withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      hasText (locator converter "#app .space-view") (pm "title")
      click (locator converter "#app .space-settings-toggle")
      click (locator converter "#app .space-permissions .encrypt-space")
      count (locator converter "#app .space-permissions .encrypt-pages") `shouldReturn` 1
      click (locator converter "#app .space-permissions .encrypt-confirm")
      -- Page by page in her browser: its stages, read-backs and commits
      -- are the program's requests.
      waitQuiet converter
    -- It is finished once the server's checkpoint after its last commit
    -- has run (decision 80), the server's own: a condition on its answer.
    convertedIn smoke ada2 True
    from <- since smoke.canary
    writeIORef w.since' (Just from)
    -- Read back in her browser, decrypted.
    withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      click (withText (pm "title") (locator converter "#app .space-view a"))
      waitQuiet converter
      hasText (locator converter "#app .page-view .page-body") (pm "text")
      let convertedLink = withText (pm "name") (locator converter "#app .page-view .attachments a")
      href <- getAttribute convertedLink "href"
      expect (maybe False ("blob:" `Text.isPrefixOf`) href) ("the converted attachment's link is not decrypted: " <> show href)
      got <- download converter (click convertedLink)
      Text.decodeUtf8Lenient <$> downloadBytes got `shouldReturn` plainBytes
      click (locator converter "#app .comments-toggle")
      waitQuiet converter
      hasText (locator converter "#app .comments-panel") (pm "comment")
      hasText (locator converter "#app mark.comment-mark") (pm "quote")
      click (withText "History" (locator converter "#app .page-view .actions a"))
      waitQuiet converter
      hasText (locator converter "#app .history-view") (pm "older")
      nothingWrongOnServer converter
    readerReads w "under the first encryption"
    let backups = smoke.dataDir </> "backups"
        leftOut f = (backups <> "/") `isPrefixOf` f || plainBlob `isSuffixOf` f
    places' <- assertGone smoke.canary smoke.dataDir smoke.database [pm p | p <- ["title", "older", "text", "quote", "comment", "name", "bytes"]] from leftOut
    -- The check looks where the text was: the attachment's plain file is
    -- there, left out as the backup names it, and so, on SQLite, is the
    -- text in the backup itself.
    plainFile <- ByteString.readFile (smoke.dataDir </> "attachments" </> take 2 plainBlob </> plainBlob)
    Text.decodeUtf8Lenient plainFile `shouldBe` plainBytes
    case smoke.database of
      SQLite -> do
        kept <- ByteString.readFile (backups </> Text.unpack backupFile)
        expect (Text.encodeUtf8 (pm "text") `ByteString.isInfixOf` kept) "the backup made before the conversion does not keep the plain text"
      PostgreSQL {} -> pure ()
    report ("none of 7 markers written plain before the conversion is in any of " <> tshow places' <> " files, requests and answers since, but for the backup made before it")

  step' "turns the space's encryption off page by page, every page plain again with its versions, comment and attachment" $ \_ -> do
    ada2 <- need w.ada2 "the converting browser"
    convertId <- readIORef w.convert
    let converter = ada2.page
    withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      hasText (locator converter "#app .space-view") (pm "title")
      click (locator converter "#app .space-settings-toggle")
      click (locator converter "#app .space-permissions .decrypt-space")
      count (locator converter "#app .space-permissions .decrypt-explained") `shouldReturn` 1
      click (locator converter "#app .space-permissions .decrypt-confirm")
      waitQuiet converter
    convertedIn smoke ada2 False
    plainAgain <- raw w ada2 "GET" ("spaces/" <> escape convertId <> "/pages") Nothing [] >>= apiJson >>= list
    back <- orFail ("the page read plain again: " <> show plainAgain) (find (\p -> p .! "title" == String (pm "title")) plainAgain)
    slug <- text (back .! "slug")
    backId <- text (back .! "id")
    backPage <- raw w ada2 "GET" ("spaces/" <> escape convertId <> "/pages/at/" <> slug) Nothing [] >>= apiJson
    text (backPage .! "body") >>= \b -> includes b (pm "text") "the page's text, plain again"
    attachmentNames <- list (backPage .! "attachments") >>= traverse (text . (.! "name"))
    attachmentNames `shouldBe` [pm "name" <> ".txt"]
    aid <-
      list (backPage .! "attachments") >>= \as' -> case as' of
        a : _ -> text (a .! "id")
        [] -> fail "no attachment"
    bodyText <$> raw w ada2 "GET" ("attachments/" <> escape aid <> "/" <> escape (pm "name" <> ".txt")) Nothing [] `shouldReturn` plainBytes
    backThreads <- raw w ada2 "GET" ("pages/" <> escape backId <> "/threads") Nothing [] >>= apiJson >>= list
    threadsShown <- traverse (\t -> (,) (t .! "anchor" .! "exact") <$> (list (t .! "comments") >>= traverse (text . (.! "body")))) backThreads
    threadsShown `shouldBe` [(String (pm "quote"), [pm "comment"])]
    length <$> (raw w ada2 "GET" ("pages/" <> escape backId <> "/versions") Nothing [] >>= apiJson >>= list) `shouldReturn` 2
    -- What the server derives from the text, as a save makes it: the
    -- server's search finds the page by its text again.
    found <- raw w ada2 "GET" ("search?q=" <> escape (pm "text") <> "&space=" <> escape convertId) Nothing [] >>= apiJson >>= list
    expect (any (\h -> h .! "page" == String backId) found) ("the server's search does not find the page plain again: " <> show found)
    -- In the tab that turned it off: read plain, its attachment the
    -- server's, its comment, its history, and a save by the plain route.
    withFailureContext converter $ do
      visit converter (address smoke ("/s/smoke-convert/p/" <> slug <> "/"))
      waitQuiet converter
      hasText (locator converter "#app .page-view .page-body") (pm "text")
      plainHref <- getAttribute (withText (pm "name") (locator converter "#app .page-view .attachments a")) "href"
      expect (not (maybe False ("blob:" `Text.isPrefixOf`) plainHref)) "the attachment's link, plain again, is not the server's"
      click (locator converter "#app .comments-toggle")
      waitQuiet converter
      hasText (locator converter "#app .comments-panel") (pm "comment")
      click (withText "History" (locator converter "#app .page-view .actions a"))
      waitQuiet converter
      hasText (locator converter "#app .history-view") (pm "older")
      visit converter (address smoke ("/s/smoke-convert/p/" <> slug <> "/"))
      click (withText "Edit" (locator converter "#app .page-view .actions a"))
      waitQuiet converter
      editorReady converter
      pressOn (editorText converter) "Control+End"
      typeText (editorText converter) " Saved plain."
      pressOn (editorText converter) "Control+s"
      waitQuiet converter
      nothingWrongOnServer converter
    savedPlain <- raw w ada2 "GET" ("spaces/" <> escape convertId <> "/pages/at/" <> slug) Nothing [] >>= apiJson
    text (savedPlain .! "body") >>= \b -> includes b "Saved plain." "a save of the page plain again, by the plain route"

  -- Encrypted again: each page a new chain of its versions, of an origin
  -- of its own, which her browser, that read the page under the first
  -- encryption, takes as such and not as a fork; she reads it and saves
  -- it, encrypted.
  step' "encrypts the space again, and a page read under its first encryption reads and saves with no fork reported, in her browser and in a reader's" $ \_ -> do
    ada2 <- need w.ada2 "the converting browser"
    convertId <- readIORef w.convert
    let converter = ada2.page
    withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      hasText (locator converter "#app .space-view") (pm "title")
      click (locator converter "#app .space-settings-toggle")
      click (locator converter "#app .space-permissions .encrypt-space")
      count (locator converter "#app .space-permissions .encrypt-pages") `shouldReturn` 1
      click (locator converter "#app .space-permissions .encrypt-confirm")
      waitQuiet converter
    convertedIn smoke ada2 True
    savedAgain w ada2 convertId " Saved again."
    readerReads w "encrypted again"

  -- Its encryption turned off, stopped halfway, and turned back: the
  -- pages decrypted meanwhile are encrypted again, each a new chain, which
  -- both browsers take as such.
  step' "turns back a decryption stopped halfway, and every page reads with no fork reported, in her browser and in a reader's, and saves" $ \_ -> do
    ada2 <- need w.ada2 "the converting browser"
    convertId <- readIORef w.convert
    let converter = ada2.page
    withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      click (locator converter "#app .space-settings-toggle")
      click (locator converter "#app .space-permissions .decrypt-space")
      click (locator converter "#app .space-permissions .decrypt-confirm")
      -- The conversion runs, page by page, while the program waits on its
      -- requests: the stop is there to be clicked.
      click (locator converter "#app .space-permissions .conversion-stop")
      click (locator converter "#app .space-permissions .conversion-reverse")
      waitQuiet converter
    convertedIn smoke ada2 True
    forM_ [pm "title", "Filler 1", "Filler 2"] $ \title -> withFailureContext converter $ do
      visit converter (address smoke "/s/smoke-convert/pages/")
      waitQuiet converter
      click (first (withText title (locator converter "#app .space-view a")))
      waitQuiet converter
      expect' (count (locator converter "#app .page-view .page-body")) (> 0) ("the page " <> Text.unpack title)
      count (locator converter "#app .encrypted-rollback") `shouldReturn` 0
    readerReads w "after a decryption turned back"
    savedAgain w ada2 convertId " Saved once more."
    withFailureContext converter (nothingWrongOnServer converter)
    closeWalkBrowser w ada2
    forM_ [w.ada, w.bea, w.elsewhere] $ \ref -> readIORef ref >>= mapM_ (closeWalkBrowser w)
  where
    expect' get' holds message = get' >>= \v -> expect (holds v) message

-- | The page of the converted space with the plain title, opened from the
-- space's list, edited, and saved encrypted: one version more on the
-- sealed route.
savedAgain :: Walk -> Browser -> Text -> Text -> IO ()
savedAgain w ada2 convertId typed = do
  let converter = ada2.page
      title = plainMarker w.smoke.canary "convert title"
  withFailureContext converter $ do
    visit converter (address w.smoke "/s/smoke-convert/pages/")
    waitQuiet converter
    click (first (withText title (locator converter "#app .space-view a")))
    waitQuiet converter
    hasText (locator converter "#app .page-view .page-body") (plainMarker w.smoke.canary "convert text")
    count (locator converter "#app .encrypted-rollback") `shouldReturn` 0
    click (first (withText "Edit" (locator converter "#app .page-view a")))
    waitQuiet converter
    editorReady converter
    pressOn (editorText converter) "End"
    typeText (editorText converter) typed
    savedSealed w ada2 convertId converter
    nothingWrongOnServer converter

-- | The reader reads the converted space's page, once a member's browser
-- (the converter's, opening the space) has shared the key with her; and
-- her browser takes no version for a fork.
readerReads :: Walk -> Text -> IO ()
readerReads w what = do
  ada2 <- need w.ada2 "the converting browser"
  bea <- need w.bea "the reader's browser"
  withFailureContext ada2.page $ do
    visit ada2.page (address w.smoke "/s/smoke-convert/")
    waitQuiet ada2.page
    expect' (count (locator ada2.page "#app .page-view .page-body")) (> 0) "the converted space's home page"
  withFailureContext bea.page $ do
    visit bea.page (address w.smoke "/s/smoke-convert/pages/")
    waitQuiet bea.page
    click (first (withText (plainMarker w.smoke.canary "convert title") (locator bea.page "#app .space-view a")))
    waitQuiet bea.page
    hasText (locator bea.page "#app .page-view .page-body") (plainMarker w.smoke.canary "convert text")
    count (locator bea.page "#app .encrypted-rollback") `shouldReturn` 0
    nothingWrongOnServer bea.page
  report ("the reader reads the page " <> what)
  where
    expect' get' holds message = get' >>= \v -> expect (holds v) message

-- | Wait until the server says the converted space is encrypted (or
-- plain) and no conversion is under way: the conversion is finished once
-- the server's checkpoint after its last commit has run, which is the
-- server's own, so a condition on its answer.
convertedIn :: Smoke -> Browser -> Bool -> IO ()
convertedIn smoke who encrypted =
  eventually who.page $ do
    s <- api smoke.wiki (Just who.session) "GET" "spaces/at/smoke-convert" Nothing [] >>= apiJson
    expect (isNull (s .! "conversion") && isNull (s .! "encryption") /= encrypted) ("the space is not " <> (if encrypted then "encrypted" else "plain") <> " yet: " <> show s)

-- | The page's id, from the sealed list of the space's pages, by the slug
-- in its address.
pageIdAt :: Walk -> Browser -> Text -> Text -> IO Text
pageIdAt w who sid pageAddress = do
  let slug = case reverse (filter (not . Text.null) (Text.splitOn "/" pageAddress)) of
        s : _ -> s
        [] -> ""
  pages <- sealedPages w who sid
  orFail ("no sealed page at " <> Text.unpack slug) (find (\p -> p .! "slug" == String slug) pages) >>= text . (.! "id")

threadCount :: Walk -> Browser -> Text -> IO Int
threadCount w who pid = length <$> (threadsOf w who pid)

commentCount :: Walk -> Browser -> Text -> IO Int
commentCount w who pid = sum <$> (threadsOf w who pid >>= traverse (fmap length . list . (.! "comments")))

threadsOf :: Walk -> Browser -> Text -> IO [Value]
threadsOf w who pid = as w who "GET" ("encrypted/pages/" <> escape pid <> "/threads") Nothing [] >>= expectStatus 200 "a sealed page's threads" >>= apiJson >>= list . (.! "threads")

-- | A grant of View on a space to a user.
grantTo :: Text -> Value
grantTo user = object ["subject" .= object ["tag" .= ("SubjectUser" :: Text), "contents" .= user], "permission" .= ("View" :: Text), "granted" .= True]

-- | @smoke-secret-decrypted-YYYY-MM-DD.zip@.
decryptedName :: Text -> Bool
decryptedName name = case Text.stripPrefix "smoke-secret-decrypted-" name >>= Text.stripSuffix ".zip" of
  Just date -> Text.length date == 10 && Text.count "-" date == 2
  Nothing -> False
