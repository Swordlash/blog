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
module Test.Browser.Encrypted
  ( spec
  , memberSpace
  , recordDecryptions
  , decryptedSince
  , secret
  , secretSlug
  , run
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (Value (..), decodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Http (Asked (..), answerWith, asked, holdAt, offline, release, serveDemo, serverStarts, startServer, startServerOver, tellServer)
import Test.Browser.Mount (clickButton)
import Test.Browser.Text (editorText)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (EncryptedApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Events (PageEvent (..), ServerMessage (..))
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Stars (StarredPage (..))
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..), keyStateText)
import Wiki.App.Backend.Http (HeldNow (..), HttpEnv, HttpWiki, PageRead (..), browserTransport, cacheOf, heldNow, newHttpEnv, newHttpEnvWith, ownersHeld, runHttpWiki)
import Wiki.App.Backend.Http.Cache (Cache (..), emptyCache, withSpaces)
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Browser (unzipFiles)
import Wiki.App.DecryptedExport (DecryptedExport (..), LeftOut (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Encrypted (keepSeen, seenOf)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route qualified as R
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Encrypted (ChainProblem (..), Kept (..), Seen (..), encryptedPageTitle)
import Wiki.Core.Export (readArchive)
import Wiki.Core.Export qualified as Export
import Wiki.Core.Id (AttachmentId (..), NotificationId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Notification (Kind (..), Notification (..), PageLocation (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..), searchQuery)
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space (Entry (..), Space (..))
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Login (..), Standing (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..), VersionsQuery (..))

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
     , ("js_watch_blobs", "wiki_test_encrypted_watch_blobs", Safe, [t|IO ()|])
     , ("js_add_reader", "wiki_test_encrypted_add_reader", Safe, [t|JSText -> JSText -> IO ()|])
     , ("js_strip_home", "wiki_test_encrypted_strip_home", Safe, [t|JSText -> IO ()|])
     , ("js_made", "wiki_test_encrypted_made", Safe, [t|IO JSText|])
     , ("js_blobs", "wiki_test_encrypted_blobs", Safe, [t|IO JSText|])
     , ("js_record_decryptions", "wiki_test_encrypted_record_decryptions", Safe, [t|IO ()|])
     , ("js_swap_staged", "wiki_test_encrypted_swap_staged", Safe, [t|JSText -> IO ()|])
     , ("js_hold_decryptions", "wiki_test_encrypted_hold_decryptions", Safe, [t|JSText -> IO ()|])
     , ("js_decryptions_held", "wiki_test_encrypted_decryptions_held", Safe, [t|IO Int|])
     , ("js_release_decryptions", "wiki_test_encrypted_release_decryptions", Safe, [t|IO Int|])
     , ("js_decryptions_done", "wiki_test_encrypted_decryptions_done", Safe, [t|IO Int|])
     , ("js_committed", "wiki_test_encrypted_committed", Safe, [t|IO JSText|])
     , ("js_go_to", "wiki_test_encrypted_go_to", Safe, [t|JSText -> IO ()|])
     , ("js_settle", "wiki_test_encrypted_settle", Safe, [t|JSText -> JSText -> IO ()|])
     , ("js_sealed_again", "wiki_test_encrypted_sealed_again", Safe, [t|JSText -> IO ()|])
     , ("js_history_back", "wiki_test_encrypted_history_back", Safe, [t|IO ()|])
     , ("js_member", "wiki_test_encrypted_member", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_tell_dropped", "wiki_test_encrypted_tell_dropped", Safe, [t|JSText -> IO ()|])
     , ("js_live", "wiki_test_encrypted_live", Safe, [t|JSText -> IO ()|])
     , ("js_document_title", "wiki_test_encrypted_document_title", Safe, [t|IO JSText|])
     , ("js_converting", "wiki_test_encrypted_converting", Safe, [t|JSText -> JSText -> IO ()|])
     , ("js_made_plain", "wiki_test_encrypted_made_plain", Safe, [t|JSText -> JSText -> JSText -> IO ()|])
     , ("js_reader_users", "wiki_test_encrypted_reader_users", Safe, [t|JSText -> IO ()|])
     , ("js_headings_asked", "wiki_test_encrypted_headings_asked", Safe, [t|IO JSText|])
     , ("js_decrypted", "wiki_test_encrypted_decrypted", Safe, [t|IO JSText|])
     ]
 )

js_image_width :: JSText -> IO Int
js_image_width a = if inBrowser then wait =<< js_image_widthPromise a else pure inert

-- | The object URLs the page made since 'js_watch_blobs', with their
-- types and whether they were let go.
blobsNow :: PageM s (Map Text (Text, Bool))
blobsNow = unsafeIOToPageM (fromJSText <$> js_blobs) <&> \raw -> fromMaybe mempty (decodeStrict' (encodeUtf8 raw))

typeIn :: Map Text (Text, Bool) -> Text -> Maybe Text
typeIn blobs url = fst <$> Map.lookup url blobs

revokedIn :: Map Text (Text, Bool) -> Text -> Bool
revokedIn blobs url = maybe False snd (Map.lookup url blobs)

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
    -- With the space's home page, made with it in this browser.
    listed <- ok =<< run env (listPages secret.id)
    map (\p -> p.title) listed `shouldBe` ["Home", "Secret plans"]
    history <- ok =<< run env (listVersions made.id (VersionsQuery Nothing 50))
    map (\v -> (v.number, v.title)) history `shouldBe` [(2, "Secret plans"), (1, "Secret plans")]
    first' <- ok =<< run env (getVersion made.id made.updatedAt)
    first'.body `shouldBe` "The launch is on *Tuesday*."
    -- A draft is not sent to the server.
    run env (saveDraft made.id saved.updatedAt "Secret plans" "a draft") >>= (`shouldSatisfy` isLeft)
    stored <- unsafeIOToPageM (fromJSText <$> js_stored)
    filter (`T.isInfixOf` stored) ["Secret plans", "Tuesday", "Wednesday", "a draft"] `shouldBe` []

  it "makes a presentation in an encrypted space, its kind read back in its page and its space's list" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPageOf Kind.Presentation secret.id Nothing "Launch talk" "# Launch talk")
    made.kind `shouldBe` Kind.Presentation
    read' <- ok =<< run env (getPage secret.id [made.slug])
    (read'.title, read'.kind) `shouldBe` ("Launch talk", Kind.Presentation)
    listed <- ok =<< run env (listPages secret.id)
    -- Beside the space's home page, a document.
    [(p.title, p.kind) | p <- listed] `shouldBe` [("Home", Kind.Document), ("Launch talk", Kind.Presentation)]

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
    sortOn fst [(s.page, s.title) | s <- stars, s.title /= "Home"] `shouldBe` sortOn fst [(launch.id, "Launch notes"), (other.id, "Other notes")]

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
    address <- urlIn other ((fromMaybe attached (head page.attachments)))
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
      address <- urlIn env (a)
      address `shouldSatisfy` (not . T.isPrefixOf "blob:")
    again <- ok =<< run env (uploadAttachment made.id "same.svg" "image/svg+xml" (svgOf 6 "Same"))
    other <- as "user-admin"
    page' <- ok =<< run other (getPage secret.id [made.slug])
    map (\a -> a.id) page'.attachments `shouldBe` [again.id]
    address <- urlIn other (again)
    unsafeIOToPageM (js_image_width (toJSText address)) `shouldReturn` 6

  -- An object URL of an attachment's decrypted bytes lives as long as
  -- the owner that asked for it, and no longer: another owner's asking
  -- lets nothing go, and an owner let go gets no URL. What a link leads to
  -- is a download unless the browser may show it by itself.
  it "holds an attachment's URLs for the owner that asked, lets them go with it, and links to a download unless the type is shown" $ runPage $ do
    unsafeIOToPageM js_watch_blobs
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    pageOne <- ok =<< run env (createPage secret.id Nothing "One" "First.")
    pageTwo <- ok =<< run env (createPage secret.id Nothing "Two" "Second.")
    void (ok =<< run env (getPage secret.id [pageOne.slug]))
    first' <- ok =<< run env (uploadAttachment pageOne.id "one.svg" "image/svg+xml" (svgOf 3 "One"))
    void (ok =<< run env (getPage secret.id [pageTwo.slug]))
    second' <- ok =<< run env (uploadAttachment pageTwo.id "two.svg" "image/svg+xml" (svgOf 4 "Two"))
    html <- ok =<< run env (uploadAttachment pageTwo.id "page.html" "text/html" (svgOf 5 "Html"))
    plain <- ok =<< run env (uploadAttachment pageTwo.id "notes.txt" "text/plain" "Plain words.")
    ownerOne <- run env newUrlOwner
    two <- run env newUrlOwner
    firstUrl <- run env (attachmentUrl ownerOne first')
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` 3
    secondUrl <- run env (attachmentUrl two second')
    unsafeIOToPageM (js_image_width (toJSText secondUrl)) `shouldReturn` 4
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` 3
    -- What each URL is: an SVG shown as an image, and downloaded by its
    -- link; HTML never shown nor opened; plain text shown as text.
    let typesOf a = do
          shown <- run env (attachmentUrl two a)
          linked <- fromMaybe shown <$> run env (attachmentDownloadUrl two a)
          blobs <- blobsNow
          pure (typeIn blobs shown, typeIn blobs linked)
    typesOf second' `shouldReturn` (Just "image/svg+xml", Just "application/octet-stream")
    typesOf html `shouldReturn` (Just "application/octet-stream", Just "application/octet-stream")
    typesOf plain `shouldReturn` (Just "text/plain", Just "text/plain")
    -- The first owner let go: its URL no longer loads, and it gets no new
    -- one; the second's still load.
    run env (releaseUrls ownerOne)
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` (-1)
    run env (attachmentUrl ownerOne first') `shouldReturn` ""
    unsafeIOToPageM (js_image_width (toJSText secondUrl)) `shouldReturn` 4

  -- The page view holds the URLs of the page it shows: going to another
  -- page lets them go. A page whose answer comes after the reader went on
  -- makes none, and lets nothing of the page shown go. No link of the page
  -- leads to an SVG's object URL as a document.
  it "lets a page's URLs go when the view shows another, and a late answer for the page left lets nothing of the one shown go" $ runPage $ do
    unsafeIOToPageM js_watch_blobs
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    pageOne <- ok =<< run env (createPage secret.id Nothing "One" "First.")
    pageTwo <- ok =<< run env (createPage secret.id Nothing "Two" "Second.")
    pageThree <- ok =<< run env (createPage secret.id Nothing "Three" "Third.")
    let withImage p name width = do
          read' <- ok =<< run env (getPage secret.id [p.slug])
          void (ok =<< run env (uploadAttachment p.id name "image/svg+xml" (svgOf width name)))
          again <- ok =<< run env (getPage secret.id [p.slug])
          ok =<< run env (savePage p.id again.updatedAt read'.title ("![" <> name <> "](attachment:" <> name <> ")\n\n[the file](attachment:" <> name <> ")"))
    void (withImage pageOne "one.svg" 3)
    void (withImage pageTwo "two.svg" 4)
    void (withImage pageThree "three.svg" 5)
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    let imageOf ui = do
          img <- eventually (find ui ".page-view .page-body img")
          src <- eventually (getAttribute img "src" >>= maybe (panic "no src") pure >>= \u -> u <$ (u `shouldSatisfy` T.isPrefixOf "blob:"))
          pure src
        go ui title = do
          links <- findAll ui ".wiki-sidebar .page-tree a"
          named <- filterM (\l -> (== title) . T.strip <$> textContent l) links
          maybe (panic ("no link to " <> title)) click (head named)
    ui <- startServer m (R.Page [secretSlug] [pageOne.slug])
    oneSrc <- imageOf ui
    unsafeIOToPageM (js_image_width (toJSText oneSrc)) `shouldReturn` 3
    -- Another page: the first page's URL is let go.
    go ui "Two"
    eventually (find ui ".page-view .page-title-row" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Two"))
    void (imageOf ui)
    eventually (unsafeIOToPageM (js_image_width (toJSText oneSrc)) `shouldReturn` (-1))
    -- The third page's answer is held; the reader goes back to the second
    -- before it comes.
    let threeAt = endpointUrl (\e -> e.encrypted.pageAt secret.id [pageThree.slug])
    holdAt "GET" threeAt
    go ui "Three"
    -- Asked for, and held.
    eventually ((\sent -> [r.url | r <- sent, r.url == threeAt]) <$> asked >>= (`shouldSatisfy` (not . null)))
    go ui "Two"
    eventually (find ui ".page-view .page-title-row" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Two"))
    twoAgain <- imageOf ui
    release
    unsafeIOToPageM (threadDelay 500_000)
    find ui ".page-view .page-title-row" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Two")
    unsafeIOToPageM (js_image_width (toJSText twoAgain)) `shouldReturn` 4
    -- Its links, the file's and the attachments list's, still lead to its
    -- bytes, as a download: none to an SVG as a document.
    blobs <- blobsNow
    hrefs <- traverse (\a -> getAttribute a "href") =<< findAll ui ".page-view a[href^='blob:']"
    [(h, typeIn blobs h, revokedIn blobs h) | Just h <- hrefs] `shouldSatisfy` all (\(_, t, gone) -> t == Just "application/octet-stream" && not gone)
    length (catMaybes hrefs) `shouldSatisfy` (>= 2)
    -- No URL of the third page was made after its answer came late.
    filter (\(_, (t, gone)) -> t == "image/svg+xml" && not gone) (Map.toList blobs) `shouldSatisfy` ((== 1) . length)
    unmount ui

  -- The slides closed while a page's attachments are being decrypted: the
  -- addresses already made are let go with the view, and the one still
  -- coming makes none.
  it "lets the slides' attachment URLs go when the slides close while the next attachment is held back" $ runPage $ do
    unsafeIOToPageM js_watch_blobs
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    -- A presentation: a document's address of slides shows no slides.
    made <- ok =<< run env (createPageOf Kind.Presentation secret.id Nothing "Deck" "First.")
    void (ok =<< run env (getPage secret.id [made.slug]))
    a <- ok =<< run env (uploadAttachment made.id "a.svg" "image/svg+xml" (svgOf 3 "A"))
    b <- ok =<< run env (uploadAttachment made.id "b.svg" "image/svg+xml" (svgOf 4 "B"))
    again <- ok =<< run env (getPage secret.id [made.slug])
    void (ok =<< run env (savePage made.id again.updatedAt "Deck" "## One\n\n![a](attachment:a.svg)\n\n![b](attachment:b.svg)"))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    holdAt "GET" ("api/v1/attachments/" <> b.id.text <> "/" <> b.id.text)
    ui <- startServer m (R.PageSlides [secretSlug] [made.slug] 1 1)
    -- The first attachment's URL is made; the second's bytes are held.
    let images = (\blobs -> [u | (u, (t, gone)) <- Map.toList blobs, t == "image/svg+xml", not gone]) <$> blobsNow
    eventually (images >>= (`shouldSatisfy` ((== 1) . length)))
    firstUrl <- fromMaybe "" . head <$> images
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` 3
    unmount ui
    release
    unsafeIOToPageM (threadDelay 500_000)
    unsafeIOToPageM (js_image_width (toJSText firstUrl)) `shouldReturn` (-1)
    blobs <- blobsNow
    [u | (u, (_, gone)) <- Map.toList blobs, not gone] `shouldBe` []
    a.id `shouldNotBe` b.id

  -- What a view registers to hold attachments' addresses, the view lets go
  -- when it closes: the page view, the editor, the slides and the live
  -- preview, mounted and unmounted again and again, on a plain page and on
  -- an encrypted one with an attachment, leave the tab's owners as many as
  -- before.
  it "leaves no owner of addresses behind a view that closes, on a plain page and an encrypted one" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    -- A presentation, so that its address of slides shows its slides.
    made <- ok =<< run env (createPageOf Kind.Presentation secret.id Nothing "Deck" "First.")
    void (ok =<< run env (getPage secret.id [made.slug]))
    attached <- ok =<< run env (uploadAttachment made.id "a.svg" "image/svg+xml" (svgOf 3 "A"))
    again <- ok =<< run env (getPage secret.id [made.slug])
    void (ok =<< run env (savePage made.id again.updatedAt "Deck" "![a](attachment:a.svg)"))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    tab <- unsafeIOToPageM (newHttpEnv browserTransport)
    let held = unsafeIOToPageM (ownersHeld tab)
        docs = either (const (panic "not a slug")) identity . mkSlug
        -- Each view, and what shows it is open: on the encrypted page, its
        -- attachment decrypted, so that it holds an owner with addresses.
        plain = [(R.Page [docs "docs"] [docs "tour"], ".page-view .page-body"), (R.EditPage [docs "docs"] [docs "tour"], ".editor"), (R.PageSlides [docs "docs"] [docs "tour"] 1 1, ".slides-not-presentation"), (R.LivePreview [docs "docs"] [docs "tour"], ".live-preview-body")]
        sealed = [(R.Page [secretSlug] [made.slug], ".page-view img[src^='blob:']"), (R.EditPage [secretSlug] [made.slug], ".editor-attachments a[href^='blob:']"), (R.PageSlides [secretSlug] [made.slug] 1 1, ".slides-view img[src^='blob:']"), (R.LivePreview [secretSlug] [made.slug], ".live-preview-body img[src^='blob:']")]
    before <- held
    -- Unmounting runs a view's finalizer on the component tree's loop, after
    -- the unmount returns: 'settle' lets the loop run what is queued, the
    -- finalizer among it, before the owners are counted. Each view, closed,
    -- leaves the count where it was: an owner left behind is found at the
    -- view that left it.
    let openAndClose (route, shown) = do
          ui <- startServerOver m tab route
          _ <- eventuallyWithin 8000 (find ui shown)
          unmount ui
          settle
          (route,) <$> held `shouldReturn` (route, before)
    for_ [1 .. 5 :: Int] $ \_ -> for_ (plain <> sealed) openAndClose
    -- Closed while their fetches are still out: the encrypted page's, and its
    -- attachment's bytes, held back, once each view is there. What they
    -- would have made, they make for no owner once they come.
    let pageAt = endpointUrl (\e -> e.encrypted.pageAt secret.id [made.slug])
        askedFor = length . filter (\r -> r.url == pageAt) <$> asked
    holdAt "GET" pageAt
    holdAt "GET" ("api/v1/attachments/" <> attached.id.text <> "/" <> attached.id.text)
    for_ (map fst sealed) $ \route -> do
      n <- askedFor
      ui <- startServerOver m tab route
      -- The view asked for the page, and waits for it.
      eventually (askedFor >>= (`shouldSatisfy` (> n)))
      unmount ui
      settle
      (route,) <$> held `shouldReturn` (route, before)
    release
    settle
    held `shouldReturn` before

  -- The live channel says only that a page's threads changed: the page
  -- reads them again, and shows another reader's comment, decrypted,
  -- without a reload.
  it "shows another reader's comment as it is made, read again and decrypted on hearing that the threads changed" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Plans" "The launch is on Tuesday.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Tuesday"))
    -- A comment about the whole page is shown below it.
    _ <- eventually (find ui ".page-comments")
    -- Another tab of the reader's writes a comment; the server tells the
    -- page only that the threads changed.
    other <- as "user-admin"
    void (ok =<< run other (getPage secret.id [made.slug]))
    void (ok =<< run other (openThread made.id Nothing "Written in another tab."))
    let event = Event made.id ThreadsChanged
    decodeUtf8 (toS (encode event)) `shouldSatisfy` (not . T.isInfixOf "Written")
    tellServer event
    eventually (find ui ".page-comments" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Written in another tab."))
    unmount ui

  -- Item 5 of WP5.74b3: a subspace of an encrypted space is made
  -- encrypted, with a key of its own and its home page, in this browser;
  -- a reader of the subspace alone reads it, and not its parent, and
  -- opening it asks nothing of the parent's key.
  it "makes a subspace of an encrypted space encrypted, which a reader of it alone reads, and not its parent" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    inner <- ok =<< run env (createSpace (Just secret.id) "Inner")
    (inner.parent, isJust inner.encryption, isJust inner.homePage, inner.encryption /= secret.encryption) `shouldBe` (Just secret.id, True, True, True)
    sent <- asked
    [r.url | r <- sent, r.method == "POST", r.url == "api/v1/spaces"] `shouldBe` []
    unsafeIOToPageM (fromJSText <$> js_made) `shouldReturn` "[1,0]"
    void (run env listSpaces)
    made <- okAt "the subspace's page" =<< run env (createPage inner.id Nothing "Inner plans" "Only the inner circle.")
    -- A reader of the subspace alone: its key shared by the admin's
    -- browser, its page read; the parent refused.
    unsafeIOToPageM (js_key_pair (toJSText ("user-editor" :: Text)))
    unsafeIOToPageM (js_add_reader (toJSText inner.id.text) (toJSText ("user-editor" :: Text)))
    void (okAt "the admin's listing" =<< run env (listPages inner.id))
    before <- length <$> asked
    solo <- as "user-editor"
    void (run solo listSpaces)
    page <- okAt "the reader's page" =<< run solo (getPage inner.id [made.slug])
    (page.title, page.body) `shouldBe` ("Inner plans", "Only the inner circle.")
    run solo (listPages secret.id) >>= (`shouldSatisfy` isLeft)
    soloAsked <- drop before <$> asked
    [r.url | r <- soloAsked, ("api/v1/encrypted/spaces/" <> secret.id.text) `T.isPrefixOf` r.url] `shouldSatisfy` all (\u -> u /= "api/v1/encrypted/spaces/" <> secret.id.text)

  -- Item 3 of #213: the export decrypted in the browser. The archive's
  -- files hold the pages' texts, the attachment's bytes and the comment,
  -- decrypted; 'readArchive' takes them; nothing plain is sent to the
  -- server meanwhile. A reader who does not hold the subspace's key gets
  -- the space without it, and is told so.
  it "exports a space decrypted in the browser, which readArchive takes, and leaves out a subspace whose key is not held" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Export plans" "The launch is on *Tuesday*.")
    void (ok =<< run env (uploadAttachment made.id "plans.svg" "image/svg+xml" (svgOf 7 "Attached words")))
    void (ok =<< run env (openThread made.id (Just (Anchor "Tuesday" "on *" "*.")) "A comment on Tuesday"))
    inner <- ok =<< run env (createSpace (Just secret.id) "Inner")
    void (run env listSpaces)
    void (ok =<< run env (createPage inner.id Nothing "Inner plans" "Only the inner circle."))
    before <- length <$> asked
    exported <- okAt "the export" =<< run env (exportDecrypted secret.id)
    sentDuring <- drop before <$> asked
    let plain = ["Export plans", "Tuesday", "Attached words", "A comment on Tuesday", "Inner plans", "inner circle"]
    [(r.url, w) | r <- sentDuring, w <- plain, w `T.isInfixOf` (r.url <> r.body)] `shouldBe` []
    exported.leftOut `shouldBe` []
    files <- unsafeIOToPageM (unzipFiles exported.bytes) >>= either (\why -> panic ("not a zip file: " <> why)) pure
    let holding needle = [path | (path, bytes) <- Map.toList files, encodeUtf8 needle `BS.isInfixOf` bytes]
    -- The page's text in its page.md, the comment in its comments.json,
    -- the attachment's bytes in its file, the subspace's page in its own
    -- directory under the space's.
    filter ("page.md" `T.isSuffixOf`) (holding "The launch is on *Tuesday*.") `shouldSatisfy` (== 1) . length
    filter ("comments.json" `T.isSuffixOf`) (holding "A comment on Tuesday") `shouldSatisfy` (== 1) . length
    filter ("attachments/plans.svg" `T.isSuffixOf`) (holding "Attached words") `shouldSatisfy` (== 1) . length
    filter (\p -> "/spaces/inner/" `T.isInfixOf` p && "page.md" `T.isSuffixOf` p) (holding "Only the inner circle.") `shouldSatisfy` (== 1) . length
    back <- either (\why -> panic ("refused: " <> why)) pure (readArchive files)
    sort [p.title | p <- back.pages] `shouldBe` ["Export plans", "Home", "Home", "Inner plans"]
    (back.users, [s.encryption | s <- back.spaces]) `shouldBe` ([], [Nothing, Nothing])
    [(t.anchor, map (\c -> c.body) t.comments) | ts <- Map.elems back.threads, t <- ts] `shouldBe` [(Just (Anchor "Tuesday" "on *" "*."), ["A comment on Tuesday"])]
    -- The reader gets the space's key from the administrator's next
    -- opening of it, and not the subspace's: her export leaves it out.
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    admin <- as "user-admin"
    void (run admin listSpaces)
    run admin (keyState secret.id) `shouldReturn` Right KeyReady
    readerTab <- as "user-reader"
    void (run readerTab listSpaces)
    hers <- okAt "the reader's export" =<< run readerTab (exportDecrypted secret.id)
    hers.leftOut `shouldBe` [LeftOut {name = "Inner", why = keyStateText WaitingForKey}]
    sort [p.title | p <- hers.archive.pages] `shouldBe` ["Export plans", "Home"]

  -- A space encrypted before encrypted spaces had home pages gets one from
  -- its administrator's browser when she opens it; a reader's does not
  -- make one. Every page keeps its address.
  it "gives an encrypted space made without a home page one when an administrator opens it, and every page keeps its address" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    top <- ok =<< run env (createPage secret.id Nothing "Top" "At the top.")
    nested <- ok =<< run env (createPage secret.id (Just top.id) "Nested" "Below it.")
    unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    readerTab <- as "user-reader"
    void (run readerTab listSpaces)
    homeless <- ok =<< run readerTab (getSpace [secretSlug])
    homeless.homePage `shouldBe` Nothing
    unsafeIOToPageM (fromJSText <$> js_made) `shouldReturn` "[0,0]"
    admin <- as "user-admin"
    void (run admin listSpaces)
    space <- ok =<< run admin (getSpace [secretSlug])
    isJust space.homePage `shouldBe` True
    unsafeIOToPageM (fromJSText <$> js_made) `shouldReturn` "[0,1]"
    (\p -> p.body) <$> (ok =<< run admin (getPage secret.id [top.slug, nested.slug])) `shouldReturn` "Below it."
    (\p -> p.title) <$> (ok =<< run admin (getPage secret.id [])) `shouldReturn` "Home"
    -- Opened again: made once.
    again <- as "user-admin"
    void (run again listSpaces)
    void (ok =<< run again (getSpace [secretSlug]))
    unsafeIOToPageM (fromJSText <$> js_made) `shouldReturn` "[0,1]"
    -- The reader's tab, which read the space before it had its home page,
    -- reads it again with it, and finds the nested page at its address.
    -- (The test's server answers as the user named last.)
    void (as "user-reader")
    (\s -> isJust s.homePage) <$> (ok =<< run readerTab (getSpace [secretSlug])) `shouldReturn` True
    (\p -> p.body) <$> (ok =<< run readerTab (getPage secret.id [top.slug, nested.slug])) `shouldReturn` "Below it."

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
        o = Just "o1"
    seenAt' u pid (Seen 3 "t3" o) `shouldReturn` KeptNow
    -- A tab that checked version 2 while another remembered 3.
    seenAt' u pid (Seen 2 "t2" o) `shouldReturn` KeptLater
    unsafeIOToPageM (seenOf u pid) `shouldReturn` [Seen 3 "t3" o]
    seenAt' u pid (Seen 3 "x3" o) `shouldReturn` KeptFork
    unsafeIOToPageM (seenOf u pid) `shouldReturn` [Seen 3 "t3" o]
    seenAt' u pid (Seen 4 "t4" o) `shouldReturn` KeptNow
    unsafeIOToPageM (seenOf u pid) `shouldReturn` [Seen 4 "t4" o]
    -- The page encrypted again: a chain of its own after the first, which
    -- stays as it was read; a version of the first, from a tab that read
    -- it late, changes nothing.
    seenAt' u pid (Seen 1 "n1" (Just "o2")) `shouldReturn` KeptNow
    seenAt' u pid (Seen 5 "t5" o) `shouldReturn` KeptLater
    unsafeIOToPageM (seenOf u pid) `shouldReturn` [Seen 4 "t4" o, Seen 1 "n1" (Just "o2")]

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
    map (\p -> p.title) <$> (ok =<< run renewing (listPages secret.id)) `shouldReturn` ["Home", "Untouched"]
    unsafeIOToPageM (fromJSText <$> js_rotations) >>= (`shouldSatisfy` (/= "[]"))
    let readsAll label tab = do
          void (run tab listSpaces)
          titles <- map (\p -> p.title) <$> (ok =<< run tab (listPages secret.id))
          (label, titles) `shouldBe` (label, ["Home", "Untouched"])
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
          address <- urlIn tab ((fromMaybe attached (head page'.attachments)))
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

  -- #213: a space that asks for a passkey or the password each
  -- time it is opened. Nothing of it is decrypted from the reader's
  -- coming in until they confirm, and nothing of it is held once they
  -- leave: no key, no page decrypted, no attachment's name or address.
  -- Outside it, a starred page of it is "an encrypted page".
  it "decrypts nothing of a space that asks each time before the reader confirms, and holds nothing of it once they leave" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Behind the gate" "Read me once confirmed.")
    void (ok =<< run env (createPage secret.id Nothing "Second room" "Also behind it."))
    attached <- ok =<< run env (uploadAttachment made.id "gate.txt" "text/plain" "The gate's notes.")
    gated <- ok =<< run env (setEntry secret.id ConfirmEach)
    gated.entry `shouldBe` ConfirmEach
    unsafeIOToPageM js_record_decryptions
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    tab <- unsafeIOToPageM (newHttpEnv browserTransport)
    ui <- startServerOver m tab (R.Page [secretSlug] [made.slug])
    eventually (find ui ".encrypted-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "asks for a passkey or your password each time"))
    -- This device has no vault to unlock: it cannot be opened here.
    _ <- eventually (find ui ".encrypted-confirm-none")
    run tab (keyState secret.id) `shouldReturn` Right ConfirmFirst
    decryptedSince `shouldReturn` []
    (\h -> h.keys) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` mempty
    -- Confirmed, as the view does once the keys were unlocked again
    -- ('Wiki.App.View.Encrypted.confirmWith'): the page is decrypted, its
    -- attachment too, and the stars name it.
    run tab (confirmedEntry secret.id)
    find ui ".encrypted-retry" >>= click
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Read me once confirmed."))
    opened <- decryptedSince
    filter (T.isInfixOf secret.id.text) opened `shouldSatisfy` (not . null)
    run tab endPreload
    stars <- ok =<< run tab starred
    [s.title | s <- stars, s.page == made.id] `shouldBe` ["Behind the gate"]
    inside <- unsafeIOToPageM (heldNow tab)
    (inside.keys, inside.confirmed) `shouldBe` (Set.singleton secret.id, Set.singleton secret.id)
    -- Inside, after a write, which empties the backend's cache: another
    -- page of the space opens without asking again.
    shown <- ok =<< run tab (getPage secret.id [made.slug])
    void (ok =<< run tab (savePage made.id shown.updatedAt "Behind the gate" "Read me once confirmed."))
    links <- findAll ui ".wiki-sidebar .page-tree a"
    named <- filterM (\l -> (== "Second room") . T.strip <$> textContent l) links
    maybe (panic "no link to the second page") click (head named)
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Also behind it."))
    length <$> findAll ui ".encrypted-space" `shouldReturn` 0
    -- Left for the front page: nothing of the space is held, its pages and
    -- attachments are refused, the page shows nothing of them, and they are
    -- named as a notification names them.
    find ui ".wiki-brand" >>= click
    eventually $ unsafeIOToPageM (heldNow tab) `shouldReturn` HeldNow {keys = mempty, found = mempty, confirmed = mempty, attachments = 0, urls = 0}
    shell <- find ui ".wiki"
    eventually (textContent shell >>= (`shouldSatisfy` \t -> not (any (`T.isInfixOf` t) ["Behind the gate", "Read me once confirmed.", "Second room", "Also behind it.", "gate.txt"])))
    run tab (getPage secret.id [made.slug]) >>= (`shouldSatisfy` isLeft)
    run tab (listPages secret.id) >>= (`shouldSatisfy` isLeft)
    run tab (listThreads made.id) >>= (`shouldSatisfy` isLeft)
    urlIn tab attached >>= (`shouldSatisfy` (not . T.isPrefixOf "blob:"))
    after <- ok =<< run tab starred
    [s.title | s <- stars, s.page == made.id] `shouldBe` ["Behind the gate"]
    [s.title | s <- after, s.page == made.id] `shouldBe` ["an encrypted page"]
    unsafeIOToPageM js_record_decryptions
    run tab (searchPages (searchQuery "confirmed")) `shouldReturn` []
    -- Back in the space: asked again, and nothing decrypted until then.
    unmount ui
    again <- startServerOver m tab (R.Space [secretSlug])
    _ <- eventually (find again ".encrypted-confirm-none")
    filter (T.isInfixOf secret.id.text) <$> decryptedSince `shouldReturn` []
    -- A key that was being opened when the reader left is not held once
    -- it opens: confirmed again, the answer with the reader's grant held
    -- back, and the space left before it comes.
    let grantAt = endpointUrl (\e -> e.encrypted.space secret.id)
        askedFor = length . filter (\r -> r.url == grantAt) <$> asked
    n <- askedFor
    holdAt "GET" grantAt
    run tab (confirmedEntry secret.id)
    find again ".encrypted-retry" >>= click
    eventually (askedFor >>= (`shouldSatisfy` (> n)))
    find again ".wiki-brand" >>= click
    eventually ((\h -> h.confirmed) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` mempty)
    release
    -- The grant was opened (HPKE's opening names no additional data), and
    -- the key it gave was not held.
    eventually (decryptedSince >>= (`shouldSatisfy` elem ""))
    (\h -> h.keys) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` mempty
    filter (T.isInfixOf secret.id.text) <$> decryptedSince `shouldReturn` []
    unmount again

  -- Another tab's sign-out lets go of the user's keys there, and tells this
  -- tab, which lets go of everything it opened with them at once: its
  -- spaces' keys, pages and addresses, and its confirmations. Its own
  -- sign-out does the same ('Wiki.App.Backend.Http.startOver').
  it "lets go of every encrypted space it holds, at once, when another tab signs out" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Open in a tab" "Read in the tab left open.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    tab <- unsafeIOToPageM (newHttpEnv browserTransport)
    ui <- startServerOver m tab (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Read in the tab left open."))
    (\h -> h.keys) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` Set.singleton secret.id
    -- Signed out in another tab: the server's answer for this browser, and
    -- the other tab's message.
    answerWith "GET" "api/v1/session" 200 signedOut
    unsafeIOToPageM (js_tell_dropped (toJSText ("vault:user-admin" :: Text)))
    shell <- find ui ".wiki"
    eventually (textContent shell >>= (`shouldSatisfy` \t -> not (any (`T.isInfixOf` t) ["Open in a tab", "Read in the tab left open."])))
    _ <- eventually (find ui ".sign-in-toggle")
    unsafeIOToPageM (heldNow tab) `shouldReturn` HeldNow {keys = mempty, found = mempty, confirmed = mempty, attachments = 0, urls = 0}
    run tab (getPage secret.id [made.slug]) >>= (`shouldSatisfy` isLeft)
    unmount ui

  -- #213, the review's P1: when the keys go, what is shown of an encrypted
  -- space goes from the screen before anything waits on the network, and
  -- an editor's changes not saved with it, said once: offline, the reload
  -- after it fails, and nothing decrypted stays. A plain page's editor
  -- keeps its changes as before.
  describe "the screen when the keys go, offline" $ do
    let openEditor gated = do
          env <- encryptedSpace "user-admin"
          void (ok =<< run env (encryptSpace secret.id))
          made <- ok =<< run env (createPage secret.id Nothing "Secret draft" "Saved text.")
          when gated (void (ok =<< run env (setEntry secret.id ConfirmEach)))
          serveDemo
          answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
          tab <- unsafeIOToPageM (newHttpEnv browserTransport)
          when gated $ do
            void (run tab listSpaces)
            run tab (confirmedEntry secret.id)
          pure (tab, made)
        typed ui = do
          text <- eventually (editorText ui)
          typeText text " Unsaved canary."
          eventually (find ui ".wiki" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Unsaved canary"))
        gone ui = do
          eventually (find ui ".wiki" >>= textContent >>= (`shouldSatisfy` \t -> not (any (`T.isInfixOf` t) ["Unsaved canary", "Saved text.", "Secret draft"])))
          eventually (find ui ".dropped-unsaved" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "dropped"))

    it "takes an encrypted editor's unsaved text off the screen when another tab signs out" $ runPage $ do
      (tab, made) <- openEditor False
      ui <- startServerOver m tab (R.EditPage [secretSlug] [made.slug])
      typed ui
      offline True
      unsafeIOToPageM (js_tell_dropped (toJSText ("vault:user-admin" :: Text)))
      gone ui
      unmount ui

    it "takes an encrypted editor's unsaved text off the screen at this tab's sign-out" $ runPage $ do
      (tab, made) <- openEditor False
      ui <- startServerOver m tab (R.EditPage [secretSlug] [made.slug])
      typed ui
      offline True
      find ui ".account-toggle" >>= click
      find ui ".account .sign-out" >>= click
      gone ui
      unmount ui

    it "takes an encrypted editor's unsaved text off the screen when the reader leaves its gate" $ runPage $ do
      (tab, made) <- openEditor True
      ui <- startServerOver m tab (R.EditPage [secretSlug] [made.slug])
      typed ui
      offline True
      unsafeIOToPageM (js_go_to (toJSText ("/" :: Text)))
      find ui ".leave-confirm .danger" >>= click
      eventually (find ui ".wiki" >>= textContent >>= (`shouldSatisfy` \t -> not (any (`T.isInfixOf` t) ["Unsaved canary", "Saved text."])))
      unmount ui

    it "keeps a plain page's unsaved text when another tab signs out" $ runPage $ do
      _ <- encryptedSpace "user-admin"
      serveDemo
      answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
      let docs = either (const (panic "not a slug")) identity . mkSlug
      ui <- startServer m (R.EditPage [docs "docs"] [docs "tour"])
      text <- eventually (editorText ui)
      typeText text " Plain unsaved."
      offline True
      unsafeIOToPageM (js_tell_dropped (toJSText ("vault:user-admin" :: Text)))
      unsafeIOToPageM (threadDelay 500_000)
      find ui ".wiki" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Plain unsaved.")
      length <$> findAll ui ".dropped-unsaved" `shouldReturn` 0
      unmount ui

  -- #213: what the tab's title said of an encrypted space goes with the
  -- screen when the keys go: the wiki's bare name until the reload sets
  -- the title again, never the page's title, decrypted, which the tab's
  -- title and the history's entry otherwise keep.
  it "titles the tab with the wiki's bare name the moment the keys go, never with the page's title" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Titled secret" "Body of it.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    tab <- unsafeIOToPageM (newHttpEnv browserTransport)
    ui <- startServerOver m tab (R.Page [secretSlug] [made.slug])
    let title = unsafeIOToPageM (fromJSText <$> js_document_title)
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Body of it."))
    eventually (title >>= (`shouldSatisfy` T.isInfixOf "Titled secret"))
    -- The reload after the keys go, held at its first request.
    holdAt "GET" "api/v1/session"
    unsafeIOToPageM (js_tell_dropped (toJSText ("vault:user-admin" :: Text)))
    eventually (find ui ".wiki" >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "Body of it.")))
    title `shouldReturn` "Wiki"
    release
    unmount ui

  -- The preview of a page detached from its editor, in a window of its own,
  -- shows nothing of a page of an encrypted space once its editor goes:
  -- the editor's reader may have left the space or signed out.
  it "keeps nothing of an encrypted page in its detached preview once the editor goes" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Previewed" "As saved.")
    void (ok =<< run env (setEntry secret.id ConfirmEach))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    tab <- unsafeIOToPageM (newHttpEnv browserTransport)
    run tab (confirmedEntry secret.id)
    ui <- startServerOver m tab (R.LivePreview [secretSlug] [made.slug])
    eventually (find ui ".live-preview-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "As saved."))
    let key = secret.id.text <> "/" <> slugText made.slug
        say message = unsafeIOToPageM (js_live (toJSText (decodeUtf8 (toS (encode message)) :: Text)))
    say (object ["key" .= key, "text" .= ("# Previewed\n\nTyped behind the gate." :: Text), "title" .= ("Previewed" :: Text)])
    eventually (find ui ".live-preview-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Typed behind the gate."))
    say (object ["key" .= key, "closed" .= True])
    eventually (find ui ".live-preview-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "nothing of the page is kept here"))
    find ui ".live-preview-body" >>= textContent >>= (`shouldSatisfy` \t -> not (any (`T.isInfixOf` t) ["Typed behind the gate.", "As saved.", "Previewed"]))
    unmount ui

  -- #213: the titles under the bell, asked for by the pages' ids alone and
  -- decrypted where this tab holds the space's key; "an encrypted page"
  -- where it does not, and behind a gate the reader has not confirmed,
  -- where nothing of a title is decrypted.
  it "shows a decrypted title under the bell with the key, an encrypted page without it, and decrypts none behind a gate not confirmed" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Under the bell" "Changed.")
    let notice =
          Notification
            { id = NotificationId "n1"
            , kind = Changed
            , page = made.id
            , thread = Nothing
            , actor = Author {id = UserId "user-admin", name = "Ada Admin", avatar = Nothing}
            , title = encryptedPageTitle
            , excerpt = ""
            , createdAt = demoNow
            , read = False
            , location = Just PageLocation {space = [secretSlug], page = [made.slug]}
            }
        bellOf tab = do
          run tab endPreload
          void (run tab listSpaces)
          map (\n -> n.title) . (\ns -> ns.items) <$> (ok =<< run tab notifications)
    answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 1, items = [notice]}
    -- The key held: the title, decrypted; and the request named the page
    -- alone.
    admin <- as "user-admin"
    bellOf admin `shouldReturn` ["Under the bell"]
    headingsAsked <- unsafeIOToPageM (fromJSText <$> js_headings_asked)
    headingsAsked `shouldBe` decodeUtf8 (toS (encode [[made.id]]))
    -- A reader with no key pair yet, to whom no key can be shared: what
    -- the server says.
    waiting <- as "user-reader"
    bellOf waiting `shouldReturn` [encryptedPageTitle]
    -- Behind a gate not confirmed: what the server says, and no title
    -- decrypted; once confirmed, the title.
    gated <- as "user-admin"
    void (ok =<< run gated (setEntry secret.id ConfirmEach))
    recordDecryptions
    bellOf gated `shouldReturn` [encryptedPageTitle]
    filter (T.isInfixOf secret.id.text) <$> decryptedSince `shouldReturn` []
    stars <- ok =<< run gated starred
    [s.title | s <- stars, s.page == made.id] `shouldBe` [encryptedPageTitle]
    run gated (confirmedEntry secret.id)
    bellOf gated `shouldReturn` ["Under the bell"]
    -- In the bell itself, outside the space, after the reader left it.
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 1, items = [notice]}
    ui <- startServerOver m gated (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Changed."))
    -- The tab's title names the space alone, which the browser keeps in
    -- its history: once the route has set it, after the page shows
    -- (the title waits for the page's backlinks), never the page's.
    eventually (unsafeIOToPageM (fromJSText <$> js_document_title) >>= (`shouldSatisfy` T.isInfixOf "Secret"))
    unsafeIOToPageM (fromJSText <$> js_document_title) >>= (`shouldSatisfy` (not . T.isInfixOf "Under the bell"))
    -- Inside: the bell and the stars show the title, decrypted.
    find ui ".notifications-toggle" >>= click
    eventually (find ui ".notification-list .notification-page" >>= (`shouldHaveText` "Under the bell"))
    find ui ".notifications-toggle" >>= click
    find ui ".starred-toggle" >>= click
    eventually (find ui ".starred-list" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Under the bell"))
    find ui ".starred-toggle" >>= click
    -- Left, with the lists' next reads held back: what the bell and the
    -- stars hold already names the page as the server does, before any
    -- answer comes.
    holdAt "GET" "api/v1/notifications"
    holdAt "GET" "api/v1/stars"
    find ui ".wiki-brand" >>= click
    eventually ((\h -> h.confirmed) <$> unsafeIOToPageM (heldNow gated) `shouldReturn` mempty)
    find ui ".notifications-toggle" >>= click
    eventually (find ui ".notification-list .notification-page" >>= (`shouldHaveText` encryptedPageTitle))
    find ui ".notifications-toggle" >>= click
    find ui ".starred-toggle" >>= click
    eventually (find ui ".starred-list" >>= textContent >>= (`shouldSatisfy` \t -> encryptedPageTitle `T.isInfixOf` t && not ("Under the bell" `T.isInfixOf` t)))
    find ui ".starred-toggle" >>= click
    release
    find ui ".notifications-toggle" >>= click
    eventually (find ui ".notification-list .notification-page" >>= (`shouldHaveText` encryptedPageTitle))
    unsafeIOToPageM (fromJSText <$> js_document_title) >>= (`shouldSatisfy` (not . T.isInfixOf "Under the bell"))
    unmount ui

  -- #213, the review's P2: titles decrypted while the reader leaves the
  -- space's gate, WebCrypto still at work, are given back by nothing once
  -- WebCrypto is done: not by the backend, which holds nothing of the
  -- space after, nor by the bell and the stars on the page, which name the
  -- page as the server does.
  it "gives back no title decrypted while the reader left the space's gate, and holds nothing of the space after" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Under the bell" "Changed.")
    let notice =
          Notification
            { id = NotificationId "n1"
            , kind = Changed
            , page = made.id
            , thread = Nothing
            , actor = Author {id = UserId "user-admin", name = "Ada Admin", avatar = Nothing}
            , title = encryptedPageTitle
            , excerpt = ""
            , createdAt = demoNow
            , read = False
            , location = Just PageLocation {space = [secretSlug], page = [made.slug]}
            }
        held = unsafeIOToPageM js_decryptions_held
        -- Every decryption held let go, and done, and what it gave handed
        -- on to whatever waited for it.
        releaseAll = do
          released <- unsafeIOToPageM js_release_decryptions
          eventually (unsafeIOToPageM js_decryptions_done >>= (`shouldSatisfy` (>= released)))
          unsafeIOToPageM (threadDelay 300_000)
    answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 1, items = [notice]}
    gated <- as "user-admin"
    void (ok =<< run gated (setEntry secret.id ConfirmEach))
    run gated endPreload
    spaces <- run gated listSpaces
    run gated (confirmedEntry secret.id)
    -- The backend: the bell's and the stars' titles asked for, their
    -- decryption held; the gate left; then the decryption done.
    unsafeIOToPageM (js_hold_decryptions (toJSText secret.id.text))
    bell <- unsafeIOToPageM newEmptyMVar
    starList <- unsafeIOToPageM newEmptyMVar
    void (unsafeIOToPageM (forkIO (runHttpWiki gated notifications >>= putMVar bell)))
    void (unsafeIOToPageM (forkIO (runHttpWiki gated starred >>= putMVar starList)))
    eventually (held >>= (`shouldSatisfy` (>= 2)))
    void (run gated (readerAt spaces Nothing))
    releaseAll
    titles <- map (\n -> n.title) . (\ns -> ns.items) <$> (ok =<< unsafeIOToPageM (takeMVar bell))
    titles `shouldBe` [encryptedPageTitle]
    stars <- ok =<< unsafeIOToPageM (takeMVar starList)
    [s.title | s <- stars, s.page == made.id] `shouldBe` [encryptedPageTitle]
    after <- unsafeIOToPageM (heldNow gated)
    (Set.member secret.id after.keys, Set.member secret.id after.found, after.attachments, after.urls) `shouldBe` (False, False, 0, 0)
    -- The page: the bell open inside the space, its titles' decryption
    -- held, the reader gone to the front page by the browser's history
    -- (no press on the page, which would close the bell), and the
    -- decryption done: the open list names the page as the server does.
    -- Then the same of the stars, back in the space.
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    answerWith "GET" "api/v1/notifications" 200 Notifications {unread = 1, items = [notice]}
    run gated (confirmedEntry secret.id)
    ui <- startServerOver m gated (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Changed."))
    let leave = do
          unsafeIOToPageM (js_go_to (toJSText ("/" :: Text)))
          eventually ((\h -> h.confirmed) <$> unsafeIOToPageM (heldNow gated) `shouldReturn` mempty)
    unsafeIOToPageM (js_hold_decryptions (toJSText secret.id.text))
    find ui ".notifications-toggle" >>= click
    eventually (held >>= (`shouldSatisfy` (>= 1)))
    leave
    releaseAll
    find ui ".notification-list .notification-page" >>= (`shouldHaveText` encryptedPageTitle)
    find ui ".notifications-toggle" >>= click
    unsafeIOToPageM js_history_back
    run gated (confirmedEntry secret.id)
    unsafeIOToPageM (js_hold_decryptions (toJSText secret.id.text))
    find ui ".starred-toggle" >>= click
    eventually (held >>= (`shouldSatisfy` (>= 1)))
    leave
    releaseAll
    find ui ".starred-list" >>= textContent >>= (`shouldSatisfy` \t -> encryptedPageTitle `T.isInfixOf` t && not ("Under the bell" `T.isInfixOf` t))
    unsafeIOToPageM (fromJSText <$> js_document_title) >>= (`shouldSatisfy` (not . T.isInfixOf "Under the bell"))
    unmount ui

  -- #213: the controls the server would refuse are not drawn, by the rule
  -- the server's checks call ("Wiki.Core.Offered"): in an encrypted space,
  -- the plain-only ones, which can never apply there; during a conversion,
  -- every one that writes, with the conversion's reason said above the
  -- view.
  it "draws no control an encrypted space refuses, and during a conversion none that writes, saying why" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Controls" "Some text.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Some text."))
    -- Writes are offered; the plain-only ones are not.
    _ <- find ui ".page-view .comments-toggle, .page-view .page-kind"
    length <$> findAll ui ".use-as-template" `shouldReturn` 0
    length <$> findAll ui ".conversion-notice" `shouldReturn` 0
    unmount ui
    settings <- startServer m (R.SpacePages [secretSlug])
    find settings ".space-settings-toggle" >>= click
    _ <- eventually (find settings ".entry-switch")
    length <$> findAll settings ".space-blog" `shouldReturn` 0
    length <$> findAll settings ".public-switch" `shouldReturn` 0
    unmount settings
    -- A conversion running: nothing that writes, and why.
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("encrypting" :: Text)))
    during <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find during ".conversion-notice" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "being encrypted"))
    eventually (find during ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Some text."))
    for_ [".page-kind", ".use-as-template", ".comment-new", ".comment-on-selection"] $ \c -> (c,) . length <$> findAll during c `shouldReturn` (c, 0)
    unmount during

  -- #213: a mention in an encrypted page is named from the space's readers,
  -- asked for by the space alone: no login found in the decrypted text is
  -- sent to the server, and one not among the readers is shown as written.
  it "names the people an encrypted page mentions from its space's readers, sending no login it found" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    readerInfo <- sessionOf "user-reader"
    let rita = fromMaybe (panic "no rita") readerInfo.user
    made <- ok =<< run env (createPage secret.id Nothing "Mentions" ("Ask @" <> rita.login.text <> " and @nobody-here."))
    unsafeIOToPageM (js_reader_users (toJSText (decodeUtf8 (toS (encode [rita])) :: Text)))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    mention <- eventually (find ui ".page-view .page-body a.mention")
    eventually (getAttribute mention "title" `shouldReturn` Just rita.displayName)
    find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "@nobody-here")
    sent <- asked
    [r.url | r <- sent, "notifications/people" `T.isInfixOf` r.url || "nobody-here" `T.isInfixOf` (r.url <> r.body)] `shouldBe` []
    unmount ui

  -- A page this tab read encrypted, made plain since by another tab's
  -- conversion: read plain now, it is no longer taken for an encrypted
  -- page, whose writes this tab would refuse or send to the encrypted
  -- routes.
  it "takes a page read encrypted and made plain elsewhere as plain, from its plain read on" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Soon plain" "Encrypted.")
    tab <- as "user-admin"
    void (ok =<< run tab (getPage secret.id [made.slug]))
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("decrypting" :: Text)))
    unsafeIOToPageM (js_made_plain (toJSText made.id.text) (toJSText ("Soon plain" :: Text)) (toJSText ("Plain now." :: Text)))
    read' <- ok =<< run tab (getPage secret.id [made.slug])
    read'.body `shouldBe` "Plain now."
    -- Its comments are asked for by the plain route, as the page's.
    void (run tab (listThreads made.id))
    sent <- asked
    [r.url | r <- sent, ("pages/" <> made.id.text <> "/threads") `T.isSuffixOf` r.url, not ("encrypted" `T.isInfixOf` r.url)] `shouldSatisfy` (not . null)
    [r.url | r <- sent, ("encrypted/pages/" <> made.id.text <> "/threads") `T.isSuffixOf` r.url] `shouldBe` []

  -- #213, the review's P2: a tab open while another browser changed the
  -- space's state reads it as it is now, at its next read, with no reload:
  -- the server's refusal says the space is not in the state the tab
  -- believed, and the tab reads the spaces again and sends the read once
  -- more by the route they name. A write is not sent again.
  describe "a tab left in a space's old state" $ do
    let setUp = do
          env <- encryptedSpace "user-admin"
          void (ok =<< run env (encryptSpace secret.id))
          unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
          first' <- ok =<< run env (createPage secret.id Nothing "First" "First text.")
          second' <- ok =<< run env (createPage secret.id Nothing "Second" "Second text.")
          pure (first', second')
        madePlain p = unsafeIOToPageM (js_made_plain (toJSText p.id.text) (toJSText ("Plain " <> p.title)) (toJSText ("Plain " <> p.body)))
        settled how = unsafeIOToPageM (js_settle (toJSText secret.id.text) (toJSText (how :: Text)))
        converting way = unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText (way :: Text)))
        opened who = do
          tab <- as who
          run tab endPreload
          void (run tab listSpaces)
          pure tab
        titles tab = map (\p -> p.title) <$> (ok =<< run tab (listPages secret.id))

    it "reads a space whose encryption another browser turned off, plain, and writes nothing to it encrypted" $ runPage $ do
      (first', second') <- setUp
      tab <- opened "user-admin"
      read' <- ok =<< run tab (getPage secret.id [first'.slug])
      read'.body `shouldBe` "First text."
      editing <- ok =<< run tab (getPage secret.id [second'.slug])
      -- Turned off elsewhere, to the end.
      traverse_ madePlain [first', second']
      settled "plain"
      again <- ok =<< run tab (getPage secret.id [first'.slug])
      (again.title, again.body) `shouldBe` ("Plain First", "Plain First text.")
      sort <$> titles tab `shouldReturn` ["Plain First", "Plain Second"]
      (\h -> Set.member secret.id h.keys) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` False
      -- A save from an editor opened before: refused, and nothing sent
      -- again by another route.
      before <- length <$> asked
      run tab (savePage second'.id editing.updatedAt "Second" "Typed before.") >>= (`shouldSatisfy` isLeft)
      sent <- drop before <$> asked
      [r.url | r <- sent, r.method == "PUT"] `shouldSatisfy` all (\u -> not ("api/v1/pages/" `T.isPrefixOf` u))
      [r.body | r <- sent] `shouldSatisfy` all (not . T.isInfixOf "Typed before.")

    it "shows a space another browser encrypted as locked to a reader without its key, and sends nothing plain" $ runPage $ do
      (first', second') <- setUp
      traverse_ madePlain [first', second']
      settled "plain"
      tab <- opened "user-reader"
      ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [first'.slug]))) `shouldReturn` "Plain First text."
      -- Encrypted elsewhere, to the end.
      settled "encrypted"
      run tab (getPage secret.id [first'.slug]) >>= \case
        Left e -> show e `shouldSatisfy` (not . T.isInfixOf "Plain")
        Right p -> panic ("read: " <> show p)

    it "reads the mixed state of a conversion another browser started since this tab listed the space" $ runPage $ do
      (first', second') <- setUp
      tab <- opened "user-admin"
      sort <$> titles tab `shouldReturn` ["First", "Second"]
      -- Decrypted elsewhere, its first page so far.
      converting "decrypting"
      madePlain first'
      sort <$> titles tab `shouldReturn` ["Plain First", "Second"]
      ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [first'.slug]))) `shouldReturn` "Plain First text."
      ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [second'.slug]))) `shouldReturn` "Second text."

    it "reads a page a conversion turned back elsewhere encrypted again" $ runPage $ do
      (first', _) <- setUp
      converting "decrypting"
      madePlain first'
      tab <- opened "user-admin"
      ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [first'.slug]))) `shouldReturn` "Plain First text."
      -- Turned back elsewhere: the page encrypted again.
      converting "encrypting"
      unsafeIOToPageM (js_sealed_again (toJSText first'.id.text))
      ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [first'.slug]))) `shouldReturn` "First text."
      sort <$> titles tab `shouldReturn` ["First", "Second"]

  -- #213, the review's P2: every read of a page by its id ('PageRead', the
  -- list a native test keeps complete against the API's routes of a page),
  -- on a tab left open while the page changed state, ends after one more
  -- try with the page's content, or with the refusal a tab opened afresh
  -- would get: never the same refusal twice. A page encrypted since: the
  -- page is learnt, and read by the encrypted route, with the key; without
  -- it, refused as a locked page is. A page made plain since: read by the
  -- plain route.
  describe "a page's reads by its id, on a tab left open while the page changed state" $
    for_ [minBound .. maxBound] $ \read' -> do
      let readBy :: HttpEnv -> Page -> PageRead -> PageM s (Either WikiError ())
          readBy tab page = \case
            ReadHistory -> void <$> run tab (listVersions page.id (VersionsQuery Nothing 50))
            ReadVersion -> void <$> run tab (getVersion page.id page.updatedAt)
            ReadThreads -> void <$> run tab (listThreads page.id)
          setUp way = do
            env <- encryptedSpace "user-admin"
            void (ok =<< run env (encryptSpace secret.id))
            unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
            made <- ok =<< run env (createPage secret.id Nothing "Doc" "First.")
            latest <- ok =<< run env (savePage made.id made.updatedAt "Doc" "Second.")
            unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText (way :: Text)))
            pure latest
          madePlain page = unsafeIOToPageM (js_made_plain (toJSText page.id.text) (toJSText ("Doc" :: Text)) (toJSText ("Plain." :: Text)))
      it ("reads a page encrypted since this tab read it plain, by the encrypted route, the page learnt: " <> show read') $ runPage $ do
        latest <- setUp "encrypting"
        madePlain latest
        for_ [("user-admin" :: Text, True), ("user-reader", False)] $ \(who, holds) -> do
          unsafeIOToPageM (js_made_plain (toJSText latest.id.text) (toJSText ("Doc" :: Text)) (toJSText ("Plain." :: Text)))
          tab <- as who
          run tab endPreload
          void (run tab listSpaces)
          -- The page read as it was: plain.
          ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [latest.slug]))) `shouldReturn` "Plain."
          -- Encrypted since, elsewhere.
          unsafeIOToPageM (js_sealed_again (toJSText latest.id.text))
          readBy tab latest read' >>= \case
            Right () | holds -> pass
            Left (Invalid _) | not holds -> pass
            other -> panic (who <> ": " <> show other)
      it ("reads a page made plain since this tab read it encrypted, by the plain route: " <> show read') $ runPage $ do
        latest <- setUp "decrypting"
        tab <- as "user-admin"
        run tab endPreload
        void (run tab listSpaces)
        -- The page read as it was: encrypted.
        ((\p -> p.body) <$> (ok =<< run tab (getPage secret.id [latest.slug]))) `shouldReturn` "Second."
        -- Made plain since, elsewhere.
        madePlain latest
        readBy tab latest read' >>= (`shouldSatisfy` isRight)

  -- #213, the review's P2: a conversion paused halfway leaves pages of
  -- both kinds in one space, a page of one kind under a page of the other.
  -- Each way round, with the key and without it, both are in the tree, the
  -- page below's address goes through the page above, and it reads: plain
  -- for anyone, encrypted for the reader who holds the key. Without the
  -- key an encrypted page is named "an encrypted page", never by a title.
  for_ [("an encryption", "encrypting" :: Text, True), ("a decryption", "decrypting", False)] $ \(what, way, parentSealed) ->
    it ("keeps the tree of " <> what <> " paused halfway whole and its links working, with the space's key and without it") $ runPage $ do
      env <- encryptedSpace "user-admin"
      void (ok =<< run env (encryptSpace secret.id))
      unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
      parent <- ok =<< run env (createPage secret.id Nothing "Parent title" "Parent text.")
      child <- ok =<< run env (createPage secret.id (Just parent.id) "Child title" "Child text.")
      -- An encryption goes the oldest first: the parent is encrypted, the
      -- child still plain. A decryption too: the parent is plain again,
      -- the child still encrypted.
      let (plainOne, sealedOne) = if parentSealed then (child, parent) else (parent, child)
      unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText way))
      unsafeIOToPageM (js_made_plain (toJSText plainOne.id.text) (toJSText ("Plain " <> plainOne.title)) (toJSText ("Plain " <> plainOne.body)))
      for_ [("user-admin" :: Text, True), ("user-reader", False)] $ \(who, holds) -> do
        tab <- as who
        run tab endPreload
        spaces <- run tab listSpaces
        s <- maybe (panic "the space is not listed") pure (head [x | x <- spaces, x.id == secret.id])
        listed <- ok =<< run tab (listPages secret.id)
        let byId = Map.fromList [(p.id, p) | p <- listed]
            titleOf i = (\p -> p.title) <$> Map.lookup i byId
        titleOf plainOne.id `shouldBe` Just ("Plain " <> plainOne.title)
        titleOf sealedOne.id `shouldBe` Just (if holds then sealedOne.title else encryptedPageTitle)
        [p.title | p <- listed, not holds, p.title == sealedOne.title] `shouldBe` []
        (\p -> p.parent) <$> Map.lookup child.id byId `shouldBe` Just (Just parent.id)
        path <- maybe (panic "the child has no path") pure (Space.pagePath s (`Map.lookup` byId) child.id)
        path `shouldBe` [p.slug | i <- [parent.id, child.id], Just p <- [Map.lookup i byId]]
        read' <- run tab (getPage secret.id path)
        case (parentSealed, holds, read') of
          -- The child plain: read plain by anyone.
          (True, _, Right page) -> (page.title, page.body) `shouldBe` ("Plain Child title", "Plain Child text.")
          -- The child encrypted: read by the key's holder; refused without.
          (False, True, Right page) -> (page.title, page.body) `shouldBe` ("Child title", "Child text.")
          (False, False, Left _) -> pass
          other -> panic ("not as expected: " <> show other)
        -- The page above, as its kind reads.
        above <- run tab (getPage secret.id (take 1 path))
        case (parentSealed, holds, above) of
          (False, _, Right page) -> page.title `shouldBe` "Plain Parent title"
          (True, True, Right page) -> page.title `shouldBe` "Parent title"
          (True, False, Left _) -> pass
          other -> panic ("not as expected above: " <> show other)

  -- #213, the review's P2: a space that asks each time it is opened, in
  -- the middle of turning its encryption off, shows nothing of a page made
  -- plain already before the reader confirms, by any route: the page's
  -- own, its permanent link, the list, its history and comments, the
  -- search. The same holds with the tab's cache emptied by a write, which
  -- empties the cached list of spaces with everything else: the gate is
  -- decided from what the tab last knew of the space, not from the cache.
  -- Confirmed, the reader reads it, plain.
  it "shows nothing of a page a decryption made plain while the space's gate is not confirmed, by any route, with the list of spaces cached or emptied by a write" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Sealed title" "Sealed text.")
    void (ok =<< run env (setEntry secret.id ConfirmEach))
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("decrypting" :: Text)))
    unsafeIOToPageM (js_made_plain (toJSText made.id.text) (toJSText ("Plain title" :: Text)) (toJSText ("Plain text." :: Text)))
    tab <- as "user-admin"
    run tab endPreload
    void (run tab listSpaces)
    let shown :: (Show a) => Either WikiError a -> Bool
        shown = \case
          Right x -> "Plain" `T.isInfixOf` show x
          Left _ -> False
        -- A write that fails, of a page that is not there: it empties the
        -- tab's cache all the same, the list of spaces with it.
        emptied = void (run tab (deletePage (PageId "nowhere")))
        -- Each read below, with 'before' run first: some of them read the
        -- list of spaces again into the cache.
        nothingShown before = do
          -- The page's route, and its permanent link: where it is, then
          -- there.
          before
          (shown <$> run tab (getPage secret.id [made.slug])) `shouldReturn` False
          before
          at <- ok =<< run tab (pageLocation made.id)
          before
          (shown <$> run tab (getPage secret.id at.page)) `shouldReturn` False
          -- The list, its history and its comments.
          before
          (shown <$> run tab (listPages secret.id)) `shouldReturn` False
          before
          (shown <$> run tab (listVersions made.id (VersionsQuery Nothing 50))) `shouldReturn` False
          before
          run tab (listThreads made.id) >>= (`shouldSatisfy` isLeft)
          -- The search.
          before
          hits <- run tab (searchPages (searchQuery "Plain"))
          [h | h <- hits, h.page == made.id] `shouldBe` []
    -- The list of spaces cached, as the shell holds it.
    nothingShown pass
    (\c -> isJust c.spaces) <$> unsafeIOToPageM (cacheOf tab) `shouldReturn` True
    -- The cache emptied before each read.
    nothingShown emptied
    -- Confirmed: the page made plain reads plain.
    run tab (confirmedEntry secret.id)
    read' <- ok =<< run tab (getPage secret.id [made.slug])
    (read'.title, read'.body) `shouldBe` ("Plain title", "Plain text.")

  -- #264's first review, P1: a tab whose cached list of spaces does not
  -- name a space that asks each time (made, or opened to the reader, since
  -- the list was read), and reads the space's record by itself, decides
  -- the space's gate from the list as the server gives it now, never from
  -- the record alone: nothing of the space is decrypted, and no key held,
  -- before the reader confirms. The same for a subspace that does not ask
  -- itself, under a parent that does: its gate is the parent's.
  it "decrypts nothing of a space that asks each time, or of a subspace under it, that the cached list did not name, before the reader confirms" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Outer plans" "Behind the outer gate.")
    inner <- ok =<< run env (createSpace (Just secret.id) "Inner")
    innerMade <- ok =<< run env (createPage inner.id Nothing "Inner plans" "Behind the parent's gate.")
    void (ok =<< run env (setEntry secret.id ConfirmEach))
    -- The reader's keys, shared by the administrator's browser.
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (confirmedEntry secret.id >> listPages secret.id))
    void (ok =<< run env (listPages inner.id))
    -- The reader's tab, started with a list of spaces that names neither.
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-reader"
    unsafeIOToPageM (js_as (toJSText ("user-reader" :: Text)))
    tab <- unsafeIOToPageM (newHttpEnvWith browserTransport (withSpaces [] emptyCache))
    run tab endPreload
    recordDecryptions
    -- Each space's record, read by itself.
    void (ok =<< run tab (getSpace [secretSlug]))
    void (ok =<< run tab (getSpace [secretSlug, inner.slug]))
    let shown :: (Show a) => Either WikiError a -> Bool
        shown = \case
          Right x -> any (`T.isInfixOf` show x) ["plans", "Behind"]
          Left _ -> False
    (shown <$> run tab (getPage secret.id [made.slug])) `shouldReturn` False
    (shown <$> run tab (listPages secret.id)) `shouldReturn` False
    (shown <$> run tab (getPage inner.id [innerMade.slug])) `shouldReturn` False
    (shown <$> run tab (listPages inner.id)) `shouldReturn` False
    stars <- ok =<< run tab starred
    [s.title | s <- stars, s.page `elem` [made.id, innerMade.id]] `shouldSatisfy` all (== encryptedPageTitle)
    (\h -> h.keys) <$> unsafeIOToPageM (heldNow tab) `shouldReturn` mempty
    filter (\d -> any (`T.isInfixOf` d) [secret.id.text, inner.id.text]) <$> decryptedSince `shouldReturn` []
    -- Confirmed: both read.
    run tab (confirmedEntry secret.id)
    page <- ok =<< run tab (getPage inner.id [innerMade.slug])
    page.body `shouldBe` "Behind the parent's gate."

  -- #264's first review, P2: a space a list of spaces read afresh leaves
  -- out (deleted, or no longer open to the reader) is let go: its key and
  -- its pages decrypted for the search, and the search finds nothing of
  -- it, though the tab searched it before.
  it "lets go of an encrypted space a list read afresh leaves out, and its search finds nothing of it" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Kept" "A walrus on the ice.")
    unsafeIOToPageM (js_key_pair (toJSText ("user-reader" :: Text)))
    void (ok =<< run env (listPages secret.id))
    tab <- as "user-reader"
    run tab endPreload
    void (run tab listSpaces)
    void (ok =<< run tab (getSpace [secretSlug]))
    void (ok =<< run tab (getPage secret.id [made.slug]))
    map (\h -> h.page) <$> run tab (searchPages (searchQuery "walrus")) `shouldReturn` [made.id]
    before <- unsafeIOToPageM (heldNow tab)
    (Set.member secret.id before.keys, Set.member secret.id before.found) `shouldBe` (True, True)
    -- The reader is taken out of the space; a write empties the tab's
    -- cache, and the next search reads the list afresh.
    unsafeIOToPageM (js_remove_reader (toJSText ("user-reader" :: Text)))
    void (run tab (deletePage (PageId "nowhere")))
    hits <- run tab (searchPages (searchQuery "walrus"))
    [h | h <- hits, h.page == made.id] `shouldBe` []
    after <- unsafeIOToPageM (heldNow tab)
    (Set.member secret.id after.keys, Set.member secret.id after.found) `shouldBe` (False, False)

  -- Turning encryption off checks a page's history as an export does,
  -- before anything of it is staged: a history the server rolled back
  -- after this browser read the page is refused, and nothing of the page
  -- is sent to be made plain.
  it "refuses to turn plain a page whose history the server rolled back, staging nothing of it" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Rolled" "First.")
    void (ok =<< run env (savePage made.id made.updatedAt "Rolled" "Second."))
    unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
    tab <- as "user-admin"
    void (ok =<< run tab (getPage secret.id [made.slug]))
    unsafeIOToPageM (js_roll_back (toJSText made.id.text))
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("decrypting" :: Text)))
    run tab (convertNext secret.id) >>= \case
      Left (Invalid why) -> why `shouldSatisfy` T.isInfixOf "older version"
      other -> panic ("not refused: " <> show other)
    sent <- asked
    [r.url | r <- sent, "conversion/pages" `T.isInfixOf` r.url] `shouldBe` []

  -- #213, the review's P2: a whole history whose oldest versions the
  -- server left out joins version by version, and its latest is the one
  -- read: its beginning is what gives it away. Not made plain, nothing of
  -- it staged; and the history view says so.
  it "refuses to turn plain a page whose history the server cut short at its beginning, and the history says so" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Cut" "First.")
    second' <- ok =<< run env (savePage made.id made.updatedAt "Cut" "Second.")
    void (ok =<< run env (savePage made.id second'.updatedAt "Cut" "Third."))
    unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
    tab <- as "user-admin"
    void (ok =<< run tab (getPage secret.id [made.slug]))
    -- The first version left out.
    unsafeIOToPageM (js_drop_version (toJSText made.id.text) 0)
    history <- as "user-admin"
    void (ok =<< run history (getPage secret.id [made.slug]))
    length <$> (ok =<< run history (listVersions made.id (VersionsQuery Nothing 50))) `shouldReturn` 2
    run history (chainProblem made.id) `shouldReturn` Just (Truncated 2)
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("decrypting" :: Text)))
    run tab (convertNext secret.id) >>= \case
      Left (Invalid why) -> why `shouldSatisfy` T.isInfixOf "begins at version 2"
      other -> panic ("not refused: " <> show other)
    sent <- asked
    [r.url | r <- sent, "conversion/pages" `T.isInfixOf` r.url] `shouldBe` []

  -- #213: two browsers converting one space. Bytes staged for an
  -- attachment that are not those this browser sent (another browser's
  -- late upload, under another key) are caught when the page is read
  -- back: by the hash and size the server names them by, and by the bytes
  -- read back themselves. The page is not committed.
  it "commits no page whose staged attachment is not what this browser sent, by its hash or by the bytes read back" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Attached" "Text.")
    void (ok =<< run env (uploadAttachment made.id "notes.txt" "text/plain" "The notes."))
    unsafeIOToPageM (js_strip_home (toJSText secret.id.text))
    unsafeIOToPageM (js_converting (toJSText secret.id.text) (toJSText ("decrypting" :: Text)))
    tab <- as "user-admin"
    let committed = unsafeIOToPageM (fromJSText <$> js_committed)
    for_ ["named", "served" :: Text] $ \how -> do
      unsafeIOToPageM (js_swap_staged (toJSText how))
      run tab (convertNext secret.id) >>= \case
        Left (Invalid why) -> why `shouldSatisfy` T.isInfixOf "attachments is not what this browser staged"
        other -> panic ("not refused (" <> how <> "): " <> show other)
      committed `shouldReturn` "[]"
    -- The bytes as sent: committed.
    unsafeIOToPageM (js_swap_staged (toJSText ("" :: Text)))
    void (ok =<< run tab (convertNext secret.id))
    committed `shouldReturn` decodeUtf8 (toS (encode [made.id]))

  -- A conversion just started shows how far it is, and Stop, while its
  -- pages are converted: here held at its first page.
  it "shows a conversion's progress and Stop from its start" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "Turned plain" "Text."))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.SpacePages [secretSlug])
    find ui ".space-settings-toggle" >>= click
    eventually (find ui ".decrypt-space") >>= click
    confirm <- eventually (find ui ".decrypt-confirm")
    eventually (getAttribute confirm "disabled" `shouldReturn` Nothing)
    holdAt "GET" (endpointUrl (\e -> e.encrypted.conversion secret.id))
    click confirm
    eventually (find ui ".conversion-progress" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "left"))
    _ <- find ui ".conversion-stop"
    release
    unmount ui

  it "turns asking each time on in the space's permissions, and asks the administrator who turned it on too" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    void (ok =<< run env (createPage secret.id Nothing "Plans" "First."))
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.SpacePages [secretSlug])
    find ui ".space-settings-toggle" >>= click
    switch <- eventually (find ui ".entry-switch")
    getAttribute switch "aria-checked" `shouldReturn` Just "false"
    click switch
    eventually (find ui ".encrypted-state" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "asks for a passkey or your password each time"))
    stored <- unsafeIOToPageM (fromJSText <$> js_stored)
    "confirm-each-time" `T.isInfixOf` stored `shouldBe` True
    unmount ui

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

-- | Record every decryption the page makes from now on ('decryptedSince').
recordDecryptions :: PageM s ()
recordDecryptions = unsafeIOToPageM js_record_decryptions

-- | The space to encrypt, over the encrypted spaces' server played here,
-- with a user of the vault's own server (as "Test.Browser.Vault" plays it)
-- as its reader and administrator, by the id and public key that server
-- keeps for them; and a tab of theirs.
memberSpace :: Text -> Text -> Text -> PageM s HttpEnv
memberSpace user keyId publicKey = do
  unsafeIOToPageM (js_start (toJSText (decodeUtf8 (toS (encode secret)))) (toJSText ("[]" :: Text)))
  unsafeIOToPageM (js_member (toJSText secret.id.text) (toJSText user) (toJSText keyId) (toJSText publicKey))
  as user

-- | The additional data of every decryption the page made since
-- 'js_record_decryptions'.
decryptedSince :: PageM s [Text]
decryptedSince = unsafeIOToPageM (fromMaybe [] . decodeStrict' . encodeUtf8 . fromJSText <$> js_decrypted)

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

-- | An attachment's URL in a tab, held by an owner of its own, which the
-- test never lets go.
urlIn :: HttpEnv -> Attachment -> PageM s Text
urlIn env a = run env (newUrlOwner >>= \o -> attachmentUrl o a)

-- | A program of the backend, in a tab.
run :: HttpEnv -> HttpWiki IO a -> PageM s a
run env program = unsafeIOToPageM (runHttpWiki env program)

-- | Nobody signed in, in an open wiki.
signedOut :: SessionInfo
signedOut = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access = Open}, standing = NotSignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Nothing}

-- | One of the demo's users, signed in.
sessionOf :: Text -> PageM s SessionInfo
sessionOf uid = unsafeIOToPageM $ do
  wiki <- newMemWiki ((demoState demoNow) {M.current = Just (UserId uid)})
  me <- runMemWiki wiki session
  pure SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = SignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Nothing}

okAt :: (Show e) => Text -> Either e a -> PageM s a
okAt what = either (\e -> panic (what <> ": expected success, got " <> show e)) pure

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
    , kind = Kind.Document
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
    , conversion = Nothing
    , entry = EnterAtOnce
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
