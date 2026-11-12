{-# LANGUAGE TemplateHaskell #-}

-- | Encrypted spaces in a browser (WP5.74b2 of docs/PLAN.md,
-- "Wiki.App.Encrypted", "Wiki.App.Backend.Http"'s encrypted spaces): a
-- space turned encrypted, a page written, read back and saved again, with
-- its history, and nothing of its title or text in what the server
-- stored; a second member waiting for the key, given it by the first
-- member's browser when it opens the space, and reading the page; the
-- search finding a word of an encrypted page in the browser, where the
-- server's finds nothing; the starred pages' titles decrypted in the
-- browser; a page over plain HTTP refusing; and a device
-- that does not hold the user's private key showing the space as locked,
-- with the unlock offered, and reading it once the key is there.
--
-- What must never reach the server is checked in the requests the page
-- sent: no draft of an encrypted page, and no plain comment, text it
-- quotes, attachment name or attachment bytes; no plain
-- page written by a tab that listed the spaces before the space was
-- encrypted; no space key sealed to a public key this device does not
-- hold; no grant to a reader whose public key is listed under another id;
-- and no search request limited to an encrypted space. The page and the
-- editor of an encrypted page offer comments and attachments, encrypted
-- in the browser, and no draft kept on leaving; one file uploaded twice is
-- two ciphertexts. A key held already is shared with readers who
-- came since, in parts of at most 500 grants, and the search finds a page
-- written since its last search once the space's pages are listed again.
--
-- The chain of versions (WP5.74b3): a page the server rolls back to an
-- older version than this browser read, or forks, or whose history it
-- leaves a version out of, is shown with what is wrong, under a banner
-- and without "Edit", and nothing is saved on top of it. A renewal of the
-- space's key leaves what was written before (pages, comments,
-- attachments) readable with the older page keys their ciphertexts name.
--
-- Over the backend over HTTP, with the test's server in fetch's place
-- ("Test.Browser.Http") and the server of encrypted spaces played beside
-- it (@jsbits\/test-encrypted.js@). The users' key pairs are made there as
-- their first sign-in makes them (a private key kept in this browser that
-- cannot be exported, its public half in the directory); the vault that
-- carries a private key to another device is "Test.Browser.Vault"'s.
module Test.Browser.Encrypted (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value (..), decodeStrict', encode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Http (Asked (..), answerWith, asked, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (clickButton)
import Test.Browser.Text (editorText)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (SpacesApi (..), WikiApi (..))
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Stars (StarredPage (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..))
import Wiki.App.Backend.Http (HttpEnv, HttpWiki, browserTransport, newHttpEnv, runHttpWiki)
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Encrypted (keepSeen, seenOf)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route qualified as R
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Encrypted (ChainProblem (..), Kept (..), Seen (..))
import Wiki.Core.Id (PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), searchQuery)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Standing (..))
import Wiki.Core.Version (Version (..), VersionInfo (..), VersionsQuery (..))

$( browserJS
     ["jsbits/test-encrypted.js"]
     [ ("js_start", "wiki_test_encrypted_start", Safe, [t|JSText -> JSText -> IO ()|])
     , ("js_as", "wiki_test_encrypted_as", Safe, [t|JSText -> IO ()|])
     , ("js_key_pairPromise", "wiki_test_encrypted_key_pair", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_forget_devicePromise", "wiki_test_encrypted_forget_device", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_unlock_devicePromise", "wiki_test_encrypted_unlock_device", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_stored", "wiki_test_encrypted_stored", Safe, [t|IO JSText|])
     , ("js_plain_http", "wiki_test_encrypted_plain_http", Safe, [t|Bool -> IO ()|])
     , ("js_foreign_keyPromise", "wiki_test_encrypted_foreign_key", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_misname_key", "wiki_test_encrypted_misname_key", Safe, [t|JSText -> IO ()|])
     , ("js_many_readersPromise", "wiki_test_encrypted_many_readers", Safe, [t|Int -> IO (Promise ())|])
     , ("js_grants", "wiki_test_encrypted_grants", Safe, [t|IO Int|])
     , ("js_roll_back", "wiki_test_encrypted_roll_back", Safe, [t|JSText -> IO ()|])
     , ("js_drop_version", "wiki_test_encrypted_drop_version", Safe, [t|JSText -> Int -> IO ()|])
     , ("js_seen_at", "wiki_test_encrypted_seen_at", Safe, [t|JSText -> JSText -> Int -> IO ()|])
     , ("js_history_without_latest", "wiki_test_encrypted_history_without_latest", Safe, [t|Bool -> IO ()|])
     , ("js_remove_reader", "wiki_test_encrypted_remove_reader", Safe, [t|JSText -> IO ()|])
     , ("js_rotations", "wiki_test_encrypted_rotations", Safe, [t|IO JSText|])
     , ("js_tamper_latest", "wiki_test_encrypted_tamper_latest", Safe, [t|Bool -> IO ()|])
     , ("js_attachment_bytes", "wiki_test_encrypted_attachment_bytes", Safe, [t|IO JSText|])
     , ("js_image_widthPromise", "wiki_test_encrypted_image_width", Safe, [t|JSText -> IO (Promise Int)|])
     ]
 )

js_image_width :: JSText -> IO Int
js_image_width a = if inBrowser then wait =<< js_image_widthPromise a else pure inert

-- | An image of so many pixels' width, as SVG, with a word in it.
svgOf :: Int -> Text -> ByteString
svgOf width word = encodeUtf8 ("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" <> show width <> "\" height=\"1\"><title>" <> word <> "</title></svg>")

js_key_pair :: JSText -> IO ()
js_key_pair a = if inBrowser then wait =<< js_key_pairPromise a else pure inert

js_forget_device :: JSText -> IO ()
js_forget_device a = if inBrowser then wait =<< js_forget_devicePromise a else pure inert

js_foreign_key :: JSText -> IO ()
js_foreign_key a = if inBrowser then wait =<< js_foreign_keyPromise a else pure inert

js_many_readers :: Int -> IO ()
js_many_readers a = if inBrowser then wait =<< js_many_readersPromise a else pure inert

js_unlock_device :: JSText -> IO ()
js_unlock_device a = if inBrowser then wait =<< js_unlock_devicePromise a else pure inert

type Specs m = (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m)

spec :: forall m -> (Specs m) => Spec
spec m = do
  it "turns a space encrypted, writes a page and reads it back with its history, and the server stores none of its text" $ runPage $ do
    env <- encryptedSpace "user-admin"
    run env (encryptSpace secret.id) >>= \case
      Right s -> s.encryption `shouldSatisfy` isJust
      Left e -> panic ("not encrypted: " <> show e)
    made <- ok =<< run env (createPage secret.id Nothing "Secret plans" "The launch is on *Tuesday*.")
    read' <- ok =<< run env (getPage secret.id [made.slug])
    (read'.title, read'.body) `shouldBe` ("Secret plans", "The launch is on *Tuesday*.")
    saved <- ok =<< run env (savePage made.id read'.updatedAt "Secret plans" "The launch moved to Wednesday.")
    saved.body `shouldBe` "The launch moved to Wednesday."
    listed <- ok =<< run env (listPages secret.id)
    map (\p -> p.title) listed `shouldBe` ["Secret plans"]
    history <- ok =<< run env (listVersions made.id (VersionsQuery Nothing 50))
    map (\v -> (v.number, v.title)) history `shouldBe` [(2, "Secret plans"), (1, "Secret plans")]
    first' <- ok =<< run env (getVersion made.id made.updatedAt)
    first'.body `shouldBe` "The launch is on *Tuesday*."
    -- A draft is not sent to the server.
    run env (saveDraft made.id saved.updatedAt "Secret plans" "a draft") >>= (`shouldSatisfy` isLeft)
    stored <- unsafeIOToPageM (fromJSText <$> js_stored)
    filter (`T.isInfixOf` stored) ["Secret plans", "Tuesday", "Wednesday", "a draft"] `shouldBe` []

  it "gives a second member the key through a pending grant, when a member opens the space" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Members only" "Shared with the reader.")
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    -- The reader has a key pair, but no grant yet.
    waiting <- as "user-reader"
    run waiting (keyState secret.id) `shouldReturn` Right WaitingForKey
    run waiting (getPage secret.id [made.slug]) >>= (`shouldSatisfy` isLeft)
    -- The admin opens the space in a new tab: the browser shares the key.
    admin <- as "user-admin"
    void (ok =<< run admin (listPages secret.id))
    reader' <- as "user-reader"
    run reader' (keyState secret.id) `shouldReturn` Right KeyReady
    page <- ok =<< run reader' (getPage secret.id [made.slug])
    (page.title, page.body) `shouldBe` ("Members only", "Shared with the reader.")

  it "shows the titles of starred pages in an encrypted space, decrypted in the browser from the empty ones the server lists" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    launch <- ok =<< run env (createPage secret.id Nothing "Launch notes" "The countdown starts at noon.")
    other <- ok =<< run env (createPage secret.id Nothing "Other notes" "Nothing to see.")
    _ <- run env listSpaces
    -- Past the page the server prerendered, as the shell is once it has
    -- shown it: only then is the list fetched and decrypted.
    run env endPreload
    stars <- ok =<< run env starred
    sortOn fst [(s.page, s.title) | s <- stars] `shouldBe` sortOn fst [(launch.id, "Launch notes"), (other.id, "Other notes")]

  it "finds a word of an encrypted page in the browser, where the server's search finds nothing" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Launch notes" "The countdown starts at noon.")
    void (ok =<< run env (createPage secret.id Nothing "Other notes" "Nothing to see."))
    -- The shell holds the list of spaces, which the search goes through.
    _ <- run env listSpaces
    hits <- run env (searchPages (searchQuery "countdown"))
    map (\h -> h.page) hits `shouldBe` [made.id]

  it "says that encrypted spaces need HTTPS, and makes nothing, over plain HTTP" $ runPage $ do
    env <- encryptedSpace "user-admin"
    unsafeIOToPageM (js_plain_http True)
    before <- run env (keyState secret.id)
    refused <- run env (encryptSpace secret.id)
    unsafeIOToPageM (js_plain_http False)
    before `shouldBe` Right NotEncrypted
    refused `shouldSatisfy` \case
      Left (Invalid why) -> "HTTPS" `T.isInfixOf` why
      _ -> False
    void (ok =<< run env (encryptSpace secret.id))
    unsafeIOToPageM (js_plain_http True)
    locked <- run env (keyState secret.id)
    unsafeIOToPageM (js_plain_http False)
    locked `shouldBe` Right NeedsHttps

  it "shows the space locked on a device without the user's keys, offers to unlock them, and reads it once they are here" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "Behind the lock" "Read me once unlocked."))
    -- A device that never held the admin's private key.
    unsafeIOToPageM (js_forget_device (toJSText ("user-admin" :: Text)))
    fresh <- as "user-admin"
    run fresh (keyState secret.id) `shouldReturn` Right KeysLocked
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Space [secretSlug])
    eventually (find ui ".encrypted-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "does not hold your keys"))
    _ <- find ui ".encrypted-unlock-passkey"
    -- What an unlock of the vault puts on the device ("Wiki.App.Vault").
    unsafeIOToPageM (js_unlock_device (toJSText ("user-admin" :: Text)))
    find ui ".encrypted-retry" >>= click
    eventually (find ui ".page-tree" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Behind the lock"))
    length <$> findAll ui ".encrypted-space" `shouldReturn` 0

  -- Item 1 of WP5.74b3: a comment, the text it quotes, and an
  -- attachment's name and bytes are encrypted in the browser, and only
  -- their ciphertext is sent and stored. A draft is still not sent.
  it "encrypts a comment, its anchor, an attachment's name and bytes, sends none as plain text, and reads them back" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Secret plans" "The launch is on Tuesday.")
    read' <- ok =<< run env (getPage secret.id [made.slug])
    attached <- ok =<< run env (uploadAttachment made.id "plans-for-tuesday.svg" "image/svg+xml" (svgOf 7 "Tuesday, attached"))
    let anchor = Anchor {exact = "launch", prefix = "The ", suffix = " is on"}
    thread <- ok =<< run env (openThread made.id (Just anchor) "A comment on Thursday")
    replied <- ok =<< run env (reply made.id thread.id "A reply on Friday")
    void (ok =<< run env (editComment made.id thread.id replied.id "Edited on Saturday"))
    run env (saveDraft made.id read'.updatedAt "Secret plans" "A draft about Sunday") >>= (`shouldSatisfy` isLeft)
    -- Read back, decrypted, in a new tab.
    other <- as "user-admin"
    page <- ok =<< run other (getPage secret.id [made.slug])
    map (\a -> (a.id, a.name.text, a.mediaType.text, a.size)) page.attachments `shouldBe` [(attached.id, "plans-for-tuesday.svg", "image/svg+xml", fromIntegral (BS.length (svgOf 7 "Tuesday, attached")))]
    threads <- ok =<< run other (listThreads made.id)
    map (\t -> (t.anchor, map (\c -> c.body) t.comments)) threads `shouldBe` [(Just anchor, ["A comment on Thursday", "Edited on Saturday"])]
    url <- run other (attachmentFrameUrl (fromMaybe attached (head page.attachments)))
    url `shouldBe` Nothing
    address <- run other (attachmentUrl (fromMaybe attached (head page.attachments)))
    address `shouldSatisfy` T.isPrefixOf "blob:"
    -- The decrypted bytes, loaded as the page loads an image.
    unsafeIOToPageM (js_image_width (toJSText address)) `shouldReturn` 7
    -- Nothing of them in what was sent, nor in what the server stored.
    let words' = ["Tuesday", "Thursday", "Friday", "Saturday", "Sunday", "launch", "plans-for"]
    sent <- asked
    [r.url | r <- sent, any (`T.isInfixOf` r.url) ["/draft"]] `shouldBe` []
    [r.url | r <- sent, any (`T.isInfixOf` r.url) ["/threads", "/attachments"], r.method /= "GET", not ("api/v1/encrypted/" `T.isPrefixOf` r.url)] `shouldBe` []
    [(r.url, w) | r <- sent, w <- words', w `T.isInfixOf` r.body || w `T.isInfixOf` r.url] `shouldBe` []
    stored <- unsafeIOToPageM (fromJSText <$> js_stored)
    filter (`T.isInfixOf` stored) words' `shouldBe` []

  -- The attachment of the same name is replaced, by the id this tab
  -- remembers for it, which is the latest: after a replacement and after
  -- a deletion too.
  it "replaces an attachment of the same name, again and again, and after a deletion" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "Again.")
    void (ok =<< run env (getPage secret.id [made.slug]))
    for_ [3, 4, 5 :: Int] $ \w -> void (ok =<< run env (uploadAttachment made.id "same.svg" "image/svg+xml" (svgOf w "Same")))
    page <- ok =<< run env (getPage secret.id [made.slug])
    map (\a -> a.name.text) page.attachments `shouldBe` ["same.svg"]
    for_ (head page.attachments) $ \a -> do
      ok =<< run env (deleteAttachment a.id)
      address <- run env (attachmentUrl a)
      address `shouldSatisfy` (not . T.isPrefixOf "blob:")
    again <- ok =<< run env (uploadAttachment made.id "same.svg" "image/svg+xml" (svgOf 6 "Same"))
    other <- as "user-admin"
    page' <- ok =<< run other (getPage secret.id [made.slug])
    map (\a -> a.id) page'.attachments `shouldBe` [again.id]
    address <- run other (attachmentUrl again)
    unsafeIOToPageM (js_image_width (toJSText address)) `shouldReturn` 6

  -- An object URL of an attachment's decrypted bytes is let go when
  -- another page's attachment is opened: the page view shows one page.
  -- A type the server would not show in the browser is downloaded.
  it "lets one page's attachment URLs go when another page's are made, and gives a download no type of its own" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    pageOne <- ok =<< run env (createPage secret.id Nothing "One" "First.")
    pageTwo <- ok =<< run env (createPage secret.id Nothing "Two" "Second.")
    void (ok =<< run env (getPage secret.id [pageOne.slug]))
    first' <- ok =<< run env (uploadAttachment pageOne.id "one.svg" "image/svg+xml" (svgOf 3 "One"))
    void (ok =<< run env (getPage secret.id [pageTwo.slug]))
    second' <- ok =<< run env (uploadAttachment pageTwo.id "two.svg" "text/html" (svgOf 4 "Two"))
    firstUrl <- run env (attachmentUrl first')
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` 3
    secondUrl <- run env (attachmentUrl second')
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` (-1)
    -- Given as text/html, the bytes are no image (and no page) here.
    unsafeIOToPageM (js_image_width (toJSText secondUrl)) `shouldReturn` (-1)

  -- The blob store keeps each upload's bytes under their hash: the same
  -- file uploaded twice is encrypted under a new nonce each time, so the
  -- server cannot tell it from two different files of one size.
  it "stores the same file uploaded twice as two different ciphertexts" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "Twice.")
    void (ok =<< run env (getPage secret.id [made.slug]))
    void (ok =<< run env (uploadAttachment made.id "one.txt" "text/plain" "The same bytes"))
    void (ok =<< run env (uploadAttachment made.id "two.txt" "text/plain" "The same bytes"))
    stored <- unsafeIOToPageM (fromJSText <$> js_attachment_bytes)
    case decodeStrict' (encodeUtf8 stored) :: Maybe [Text] of
      Just [a, b] -> a `shouldNotBe` b
      other -> panic ("two attachments expected, got " <> show other)

  it "writes encrypted, and sends no plain text, in a tab that listed the spaces before the space was encrypted" $ runPage $ do
    stale <- encryptedSpace "user-admin"
    -- A page of the space as it was before, read in that tab.
    answerWith "GET" (endpointUrl (\e -> e.spaces.pageAt secret.id [plainSlug])) 200 plainPage
    void (run stale listSpaces)
    void (ok =<< run stale (getPage secret.id [plainSlug]))
    -- Another tab encrypts the space and writes a page.
    other <- as "user-admin"
    void (ok =<< run other (encryptSpace secret.id))
    made <- ok =<< run other (createPage secret.id Nothing "Written elsewhere" "Read in the stale tab.")
    -- The stale tab writes encrypted, reads encrypted, and does not save the
    -- page it read before as plain text.
    mine <- ok =<< run stale (createPage secret.id Nothing "Written here" "Plain text never leaves.")
    page <- ok =<< run stale (getPage secret.id [made.slug])
    (page.title, page.body) `shouldBe` ("Written elsewhere", "Read in the stale tab.")
    run stale (savePage plainPage.id plainPage.updatedAt "Old home" "Edited after the encryption") >>= (`shouldSatisfy` isLeft)
    run stale (saveDraft plainPage.id plainPage.updatedAt "Old home" "Edited after the encryption") >>= (`shouldSatisfy` isLeft)
    sent <- asked
    [(r.method, r.url) | r <- sent, r.method /= "GET", not ("api/v1/encrypted/" `T.isPrefixOf` r.url)] `shouldBe` []
    [r.url | r <- sent, any (`T.isInfixOf` r.body) ["Written here", "Plain text", "Edited after"]] `shouldBe` []
    mine.title `shouldBe` "Written here"

  it "refuses to encrypt a space with a public key from the server that this device does not hold, and sends nothing" $ runPage $ do
    env <- encryptedSpace "user-admin"
    unsafeIOToPageM (js_foreign_key (toJSText ("user-admin" :: Text)))
    refused <- run env (encryptSpace secret.id)
    refused `shouldSatisfy` \case
      Left (Invalid why) -> "not the one this device holds" `T.isInfixOf` why
      _ -> False
    sent <- asked
    [r.url | r <- sent, r.method == "POST", "api/v1/encrypted/" `T.isPrefixOf` r.url] `shouldBe` []

  it "seals the key to no reader whose public key is listed under another id" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    unsafeIOToPageM (js_misname_key (toJSText ("user-reader" :: Text)))
    admin <- as "user-admin"
    void (ok =<< run admin (listPages secret.id))
    sent <- asked
    [r.url | r <- sent, "/grants" `T.isSuffixOf` r.url] `shouldBe` []

  it "shares the key held already with a reader who came since, in parts of at most 500" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (listPages secret.id))
    -- The reader's key pair, and 500 more readers, come after the admin's
    -- tab opened the key.
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    unsafeIOToPageM (js_many_readers 500)
    void (ok =<< run env (listPages secret.id))
    posts <- filter (\r -> "/grants" `T.isSuffixOf` r.url) <$> asked
    length posts `shouldBe` 2
    unsafeIOToPageM js_grants `shouldReturn` 502
    granted <- as "user-reader"
    run granted (keyState secret.id) `shouldReturn` Right KeyReady

  it "searches an encrypted space alone without asking the server, and finds a page written since the space was last searched" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "Launch notes" "The countdown starts at noon."))
    _ <- run env listSpaces
    let inSecret word = (searchQuery word) {space = Just secret.id, includeSubspaces = True}
    run env (searchPages (inSecret "zebra")) `shouldReturn` []
    other <- as "user-admin"
    made <- ok =<< run other (createPage secret.id Nothing "Crossing" "A zebra crossing.")
    -- The space's pages, listed again, show a page the search does not hold.
    void (ok =<< run env (listPages secret.id))
    map (\h -> h.page) <$> run env (searchPages (inSecret "zebra")) `shouldReturn` [made.id]
    sent <- asked
    [r.url | r <- sent, "api/v1/search" `T.isPrefixOf` r.url] `shouldBe` []

  it "shows a page the server rolled back to an older version than this browser read, under a banner, and saves nothing on top of it" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "First.")
    secondVersion <- ok =<< run env (savePage made.id made.updatedAt "Plans" "Second.")
    void (ok =<< run env (savePage made.id secondVersion.updatedAt "Plans" "Third."))
    -- The server serves the second version as the latest.
    unsafeIOToPageM (js_roll_back (toJSText made.id.text))
    later <- as "user-admin"
    page <- ok =<< run later (getPage secret.id [made.slug])
    page.body `shouldBe` "Second."
    run later (chainProblem made.id) `shouldReturn` Just (Older 3 2)
    before <- length <$> asked
    run later (savePage made.id page.updatedAt "Plans" "On top of the older one.") >>= (`shouldSatisfy` isLeft)
    sent <- drop before <$> asked
    [r.url | r <- sent, r.method /= "GET"] `shouldBe` []
    -- The page view shows the text under the banner, and no "Edit".
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Second."))
    eventually (find ui ".page-view .encrypted-rollback" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "older version of this page"))
    actions <- findAll ui ".page-actions a" >>= traverse textContent
    filter (T.isInfixOf "Edit") actions `shouldBe` []
    unmount ui

  it "finds a version the server sent under the number of another this browser read, and one left out of the history" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "First.")
    void (ok =<< run env (savePage made.id made.updatedAt "Plans" "The admin's second."))
    -- The reader, given the key, reads the page as the server serves it
    -- once it has dropped the admin's second version, and saves on top.
    unsafeIOToPageM (js_roll_back (toJSText made.id.text))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    admin <- as "user-admin"
    void (ok =<< run admin (listPages secret.id))
    readerFirst <- as "user-reader"
    first' <- ok =<< run readerFirst (getPage secret.id [made.slug])
    void (ok =<< run readerFirst (savePage made.id first'.updatedAt "Plans" "The reader's second."))
    -- The admin read another second version.
    forked <- as "user-admin"
    page <- ok =<< run forked (getPage secret.id [made.slug])
    page.body `shouldBe` "The reader's second."
    run forked (chainProblem made.id) `shouldReturn` Just (Forked 2)
    -- A browser that read the second version last is sent the fourth, with
    -- the third left out of the history: the fourth does not link down to
    -- the version read.
    readerTab <- as "user-reader"
    second' <- ok =<< run readerTab (getPage secret.id [made.slug])
    third <- ok =<< run readerTab (savePage made.id second'.updatedAt "Plans" "Third.")
    void (ok =<< run readerTab (savePage made.id third.updatedAt "Plans" "Fourth."))
    seenAt "user-reader" made.id 1
    unsafeIOToPageM (js_drop_version (toJSText made.id.text) 2)
    gapped <- as "user-reader"
    (\p -> p.body) <$> (ok =<< run gapped (getPage secret.id [made.slug])) `shouldReturn` "Fourth."
    run gapped (chainProblem made.id) `shouldReturn` Just (Gap 2)
    -- A browser that read none of it finds the same in the history.
    seenAt "user-reader" made.id (-1)
    history <- as "user-reader"
    void (ok =<< run history (getPage secret.id [made.slug]))
    run history (chainProblem made.id) `shouldReturn` Nothing
    map (\v -> v.number) <$> (ok =<< run history (listVersions made.id (VersionsQuery Nothing 50))) `shouldReturn` [3, 2, 1]
    run history (chainProblem made.id) `shouldReturn` Just (Gap 2)

  it "refuses a later version that the history does not join, from that very version, to the one this browser read" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "First.")
    -- The reader writes a second version, after the first the admin read.
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    readerTab <- as "user-reader"
    first' <- ok =<< run readerTab (getPage secret.id [made.slug])
    void (ok =<< run readerTab (savePage made.id first'.updatedAt "Plans" "The reader's second."))
    -- The history the server sends leaves the second version out, though
    -- it ends at the version the admin read.
    unsafeIOToPageM (js_history_without_latest True)
    admin <- as "user-admin"
    void (ok =<< run admin (getPage secret.id [made.slug]))
    unsafeIOToPageM (js_history_without_latest False)
    run admin (chainProblem made.id) `shouldReturn` Just (Unlinked 1 2)
    -- The second version is not remembered: a tab reading the page now,
    -- with the whole history, joins it to the first.
    honest <- as "user-admin"
    void (ok =<< run honest (getPage secret.id [made.slug]))
    run honest (chainProblem made.id) `shouldReturn` Nothing

  it "joins each page of a history to the one before it, and the history view says when they do not join" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "Version 1.")
    -- 52 versions, the second left out by the server: the first page of
    -- the history (50) ends at the third, and the next has the first alone.
    foldM_ (\p i -> ok =<< run env (savePage made.id p.updatedAt "Plans" ("Version " <> show (i :: Int) <> "."))) made [2 .. 52]
    unsafeIOToPageM (js_drop_version (toJSText made.id.text) 1)
    paged <- as "user-admin"
    void (ok =<< run paged (getPage secret.id [made.slug]))
    latest <- ok =<< run paged (listVersions made.id (VersionsQuery Nothing 50))
    run paged (chainProblem made.id) `shouldReturn` Nothing
    oldest <- maybe (panic "no versions") pure (lastMay latest)
    void (ok =<< run paged (listVersions made.id (VersionsQuery (Just oldest.updatedAt) 50)))
    run paged (chainProblem made.id) `shouldReturn` Just (Gap 1)
    -- The history view, after "Older…".
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.PageHistory [secretSlug] [made.slug] Nothing R.AgainstPrevious)
    _ <- eventually (find ui ".versions-older")
    length <$> findAll ui ".encrypted-rollback" `shouldReturn` 0
    find ui ".versions-older" >>= click
    eventually (find ui ".history-view .encrypted-rollback" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "version missing"))
    unmount ui

  it "remembers a version seen only forward, whatever another tab remembered meanwhile, and a fork not at all" $ runPage $ do
    let u = UserId "user-admin"
        pid = PageId "page-remembered"
    seenAt' u pid (Seen 3 "t3") `shouldReturn` KeptNow
    -- A tab that checked version 2 while another remembered 3.
    seenAt' u pid (Seen 2 "t2") `shouldReturn` KeptLater
    unsafeIOToPageM (seenOf u pid) `shouldReturn` Just (Seen 3 "t3")
    seenAt' u pid (Seen 3 "x3") `shouldReturn` KeptFork
    unsafeIOToPageM (seenOf u pid) `shouldReturn` Just (Seen 3 "t3")
    seenAt' u pid (Seen 4 "t4") `shouldReturn` KeptNow
    unsafeIOToPageM (seenOf u pid) `shouldReturn` Just (Seen 4 "t4")

  it "renews the key when a reader is removed, and the removed reader's tab, with the old key, opens nothing written after" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "Before the removal.")
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    readerTab <- as "user-reader"
    void (ok =<< run readerTab (getPage secret.id [made.slug]))
    unsafeIOToPageM (js_remove_reader (toJSText ("user-reader" :: Text)))
    -- The administrator's browser renews the key when it opens the space.
    admin <- as "user-admin"
    void (ok =<< run admin (listPages secret.id))
    rotations <- unsafeIOToPageM (fromJSText <$> js_rotations)
    (T.count "\"recipient\"" rotations, "user-reader" `T.isInfixOf` rotations) `shouldBe` (1, False)
    page <- ok =<< run admin (getPage secret.id [made.slug])
    void (ok =<< run admin (savePage made.id page.updatedAt "Plans" "After the removal."))
    -- The removed reader's tab still holds the old key, and the server
    -- still answers it: what was written after does not open with it.
    run readerTab (getPage secret.id [made.slug]) >>= (`shouldSatisfy` isLeft)
    -- What was written before still opens for the administrator.
    first' <- ok =<< run admin (getVersion made.id made.updatedAt)
    first'.body `shouldBe` "Before the removal."

  -- After a rotation, a page nobody saved since is under its older page
  -- key: every read opens each ciphertext with the key it names, in a new
  -- tab, in a tab open before the rotation, and on the opening that
  -- renews.
  it "reads the pages nobody saved since a renewal, in a new tab, in a tab open before it, and on the opening that renews" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Untouched" "A zebra crossing.")
    resaved <- ok =<< run env (savePage made.id made.updatedAt "Untouched" "A zebra crossing, twice.")
    attached <- ok =<< run env (uploadAttachment made.id "zebra.svg" "image/svg+xml" (svgOf 5 "Stripes."))
    void (ok =<< run env (openThread made.id Nothing "Before the renewal."))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    -- Tabs of the administrator's open before the renewal, holding the key.
    before <- as "user-admin"
    void (run before listSpaces)
    void (ok =<< run before (getPage secret.id [made.slug]))
    early <- as "user-admin"
    void (run early listSpaces)
    void (ok =<< run early (getPage secret.id [made.slug]))
    unsafeIOToPageM (js_remove_reader (toJSText ("user-reader" :: Text)))
    -- The opening that renews reads the list with the new wraps.
    renewing <- as "user-admin"
    map (\p -> p.title) <$> (ok =<< run renewing (listPages secret.id)) `shouldReturn` ["Untouched"]
    unsafeIOToPageM (fromJSText <$> js_rotations) >>= (`shouldSatisfy` (/= "[]"))
    let readsAll label tab = do
          void (run tab listSpaces)
          titles <- map (\p -> p.title) <$> (ok =<< run tab (listPages secret.id))
          (label, titles) `shouldBe` (label, ["Untouched"])
          page <- ok =<< run tab (getPage secret.id [made.slug])
          (label, page.body) `shouldBe` (label, "A zebra crossing, twice.")
          versions <- ok =<< run tab (listVersions made.id (VersionsQuery Nothing 50))
          (label, map (\v -> v.title) versions) `shouldBe` (label, ["Untouched", "Untouched"])
          first' <- ok =<< run tab (getVersion made.id made.updatedAt)
          (label, first'.body) `shouldBe` (label, "A zebra crossing.")
          hits <- run tab (searchPages ((searchQuery "zebra") {space = Just secret.id, includeSubspaces = True}))
          (label, map (\h -> h.page) hits) `shouldBe` (label, [made.id])
          -- The comment and the attachment are under the older page key,
          -- which their ciphertext names.
          threads <- ok =<< run tab (listThreads made.id)
          (label, map (\t -> map (\c -> c.body) t.comments) threads) `shouldBe` (label, [["Before the renewal."]])
          page' <- ok =<< run tab (getPage secret.id [made.slug])
          (label, map (\a -> a.name.text) page'.attachments) `shouldBe` (label, ["zebra.svg"])
          address <- run tab (attachmentUrl (fromMaybe attached (head page'.attachments)))
          width <- unsafeIOToPageM (js_image_width (toJSText address))
          (label, width) `shouldBe` (label, 5)
    fresh <- as "user-admin"
    readsAll ("a new tab" :: Text) fresh
    readsAll "a tab open before the renewal" before
    -- A reply written after the renewal is under the page's new key.
    threads <- ok =<< run fresh (listThreads made.id)
    for_ (head threads) $ \t -> void (ok =<< run fresh (reply made.id t.id "After the renewal."))
    stored <- unsafeIOToPageM (fromJSText <$> js_stored)
    let keysOf = case decodeStrict' (encodeUtf8 stored) of
          Just (Object o) -> [k | Just (Array ps) <- [KM.lookup "pages" o], Object p <- toList ps, Just (Array ts) <- [KM.lookup "threads" p], Object t <- toList ts, Just (Array cs) <- [KM.lookup "comments" t], Object c <- toList cs, Just (Object content) <- [KM.lookup "content" c], Just (String k) <- [KM.lookup "keyId" content]]
          _ -> []
    length (ordNub keysOf) `shouldBe` 2
    map (\t -> map (\c -> c.body) t.comments) <$> (ok =<< run before (listThreads made.id)) `shouldReturn` [["Before the renewal.", "After the renewal."]]
    -- A tab that read the page before the renewal, and reads its threads
    -- again without the page, as when it hears that they changed.
    map (\t -> map (\c -> c.body) t.comments) <$> (ok =<< run early (listThreads made.id)) `shouldReturn` [["Before the renewal.", "After the renewal."]]
    resaved.updatedAt `shouldSatisfy` (> made.updatedAt)

  it "renews the key at once when the administrator revokes a reader in the permissions dialog" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "Plans" "First."))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.SpacePages [secretSlug])
    find ui ".space-settings-toggle" >>= click
    eventually (find ui ".grant-row[data-subject=reader] .grant-revoke" >>= click)
    eventually (unsafeIOToPageM (fromJSText <$> js_rotations) >>= (`shouldSatisfy` (/= "[]")))
    rotations <- unsafeIOToPageM (fromJSText <$> js_rotations)
    "user-reader" `T.isInfixOf` rotations `shouldBe` False
    unmount ui

  it "refuses a save while the key must be renewed, saying why, until an administrator's browser renews it" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "First.")
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    unsafeIOToPageM (js_many_readers 1)
    void (ok =<< run env (listPages secret.id))
    unsafeIOToPageM (js_remove_reader (toJSText ("user-many-0" :: Text)))
    -- The reader, who does not administer the space, is told why.
    readerTab <- as "user-reader"
    page <- ok =<< run readerTab (getPage secret.id [made.slug])
    run readerTab (savePage made.id page.updatedAt "Plans" "Not yet.")
      >>= ( `shouldSatisfy`
              \case
                Left (Invalid why) -> "key must be renewed" `T.isInfixOf` why
                _ -> False
          )
    -- The administrator opens the space, and the key is renewed.
    admin <- as "user-admin"
    void (ok =<< run admin (listPages secret.id))
    readerAgain <- as "user-reader"
    page' <- ok =<< run readerAgain (getPage secret.id [made.slug])
    (\p -> p.body) <$> (ok =<< run readerAgain (savePage made.id page'.updatedAt "Plans" "Now.")) `shouldReturn` "Now."

  it "sends no new key when a wrap it would send does not open" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "One" "First page."))
    void (ok =<< run env (createPage secret.id Nothing "Two" "Second page."))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    unsafeIOToPageM (js_remove_reader (toJSText ("user-reader" :: Text)))
    -- The server lists each page with another page's latest title: the
    -- page key wrapped again does not open it.
    unsafeIOToPageM (js_tamper_latest True)
    admin <- as "user-admin"
    void (run admin (listPages secret.id))
    unsafeIOToPageM (js_tamper_latest False)
    unsafeIOToPageM (fromJSText <$> js_rotations) `shouldReturn` "[]"
    -- The server gives a public key for the administrator that is not
    -- hers: her own new grant does not open.
    unsafeIOToPageM (js_foreign_key (toJSText ("user-admin" :: Text)))
    again <- as "user-admin"
    void (run again (listPages secret.id))
    unsafeIOToPageM (fromJSText <$> js_rotations) `shouldReturn` "[]"
    sent <- asked
    [r.url | r <- sent, "/rotation" `T.isSuffixOf` r.url, r.method == "POST"] `shouldBe` []

  it "offers comments and attachments, and no kept draft, in an encrypted space's page and editor" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Secret plans" "The launch is on Tuesday.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Tuesday"))
    eventually (length <$> findAll ui ".comments-toggle" >>= (`shouldSatisfy` (> 0)))
    unmount ui
    editor <- startServer m (R.EditPage [secretSlug] [made.slug])
    text <- editorText editor
    length <$> findAll editor ".editor-attach" `shouldReturn` 1
    length <$> findAll editor ".tool[aria-label='Image or attachment']" `shouldReturn` 1
    typeText text " More."
    find editor ".editor-cancel" >>= click
    question <- find editor ".editor-cancel-confirm"
    textContent question >>= (`shouldSatisfy` T.isInfixOf "will be lost")
    map T.strip <$> (findAll editor ".editor-cancel-confirm button" >>= traverse textContent) `shouldReturn` ["Discard my changes", "Go on editing"]
    clickButton editor ".editor-cancel-confirm button" "Go on editing"
    sent <- asked
    [r.url | r <- sent, "/draft" `T.isSuffixOf` r.url, r.method /= "GET"] `shouldBe` []
    unmount editor
  where
    -- The server with the space, the admin and the reader its readers, and
    -- a key pair for the user who asks first, in a tab of theirs.
    encryptedSpace :: Text -> PageM s HttpEnv
    encryptedSpace user = do
      serverStarts
      unsafeIOToPageM (js_start (toJSText (decodeUtf8 (toS (encode secret)))) (toJSText ("[\"user-admin\",\"user-reader\"]" :: Text)))
      unsafeIOToPageM (js_key_pair (toJSText user))
      as user

-- | What this browser remembers of a page for a user, set to the version
-- at an index from the first, as if it had read that one last; nothing for
-- an index below 0.
seenAt :: Text -> PageId -> Int -> PageM s ()
seenAt user pid index = unsafeIOToPageM (js_seen_at (toJSText user) (toJSText pid.text) index)

-- | Remember a version seen, as a tab does ("Wiki.App.Encrypted"'s
-- 'keepSeen').
seenAt' :: UserId -> PageId -> Seen -> PageM s Kept
seenAt' u pid seen = unsafeIOToPageM (keepSeen u pid seen)

-- | A new tab of a user's, over the server, as the user asking.
as :: Text -> PageM s HttpEnv
as user = do
  answerWith "GET" "api/v1/session" 200 =<< sessionOf user
  unsafeIOToPageM (js_as (toJSText user))
  unsafeIOToPageM (newHttpEnv browserTransport)

-- | A program of the backend, in a tab.
run :: HttpEnv -> HttpWiki IO a -> PageM s a
run env program = unsafeIOToPageM (runHttpWiki env program)

-- | One of the demo's users, signed in.
sessionOf :: Text -> PageM s SessionInfo
sessionOf uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Nothing}

ok :: (Show e) => Either e a -> PageM s a
ok = either (\e -> panic ("expected success, got " <> show e)) pure

secretSlug :: Slug
secretSlug = either (const (panic "not a slug")) identity (mkSlug "secret")

plainSlug :: Slug
plainSlug = either (const (panic "not a slug")) identity (mkSlug "home")

-- | A plain page of the space, as the plain routes served it before the
-- space was encrypted.
plainPage :: Page
plainPage =
  Page
    { id = PageId "page-plain-home"
    , space = secret.id
    , parent = Nothing
    , title = "Home"
    , slug = plainSlug
    , body = "# Home"
    , attachments = []
    , createdAt = demoNow
    , updatedAt = demoNow
    , position = 0
    , template = False
    , createdBy = Nothing
    , updatedBy = Nothing
    }

-- | The space to encrypt: a private top-level space with nothing in it.
secret :: Space
secret =
  Space
    { id = SpaceId "space-secret"
    , name = "Secret"
    , slug = secretSlug
    , parent = Nothing
    , public = False
    , sealed = True
    , encryption = Nothing
    , owner = Nothing
    , active = True
    , personalContainer = False
    , mathMacros = ""
    , createdAt = demoNow
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    , boxNumbering = InPage
    }
