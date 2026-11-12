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
-- sent: no attachment, comment or draft of an encrypted page; no plain
-- page written by a tab that listed the spaces before the space was
-- encrypted; no space key sealed to a public key this device does not
-- hold; no grant to a reader whose public key is listed under another id;
-- and no search request limited to an encrypted space. The page and the
-- editor of an encrypted page offer no comments, no attachments and no
-- draft kept on leaving. A key held already is shared with readers who
-- came since, in parts of at most 500 grants, and the search finds a page
-- written since its last search once the space's pages are listed again.
--
-- The chain of versions (WP5.74b3): a page the server rolls back to an
-- older version than this browser read, or forks, or whose history it
-- leaves a version out of, is shown with what is wrong, under a banner
-- and without "Edit", and nothing is saved on top of it.
--
-- Over the backend over HTTP, with the test's server in fetch's place
-- ("Test.Browser.Http") and the server of encrypted spaces played beside
-- it (@jsbits\/test-encrypted.js@). The users' key pairs are made there as
-- their first sign-in makes them (a private key kept in this browser that
-- cannot be exported, its public half in the directory); the vault that
-- carries a private key to another device is "Test.Browser.Vault"'s.
module Test.Browser.Encrypted (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (encode)
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
     ]
 )

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

  it "sends nothing of an encrypted page for an attachment, a comment or a draft" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Secret plans" "The launch is on Tuesday.")
    read' <- ok =<< run env (getPage secret.id [made.slug])
    run env (uploadAttachment made.id "plans.txt" "text/plain" "Tuesday, attached") >>= (`shouldSatisfy` isLeft)
    run env (openThread made.id (Just Anchor {exact = "launch", prefix = "The ", suffix = " is on"}) "A comment on Tuesday") >>= (`shouldSatisfy` isLeft)
    run env (saveDraft made.id read'.updatedAt "Secret plans" "A draft about Tuesday") >>= (`shouldSatisfy` isLeft)
    sent <- asked
    [r.url | r <- sent, any (`T.isInfixOf` r.url) ["/attachments", "/threads", "/draft"]] `shouldBe` []
    [r.url | r <- sent, any (`T.isInfixOf` r.body) ["Tuesday", "launch", "Secret plans"]] `shouldBe` []

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

  it "offers no comments, attachments or kept draft in an encrypted space's page and editor" $ runPage $ do
    env <- encryptedSpace "user-admin"
    void (ok =<< run env (encryptSpace secret.id))
    made <- ok =<< run env (createPage secret.id Nothing "Secret plans" "The launch is on Tuesday.")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Page [secretSlug] [made.slug])
    eventually (find ui ".page-view .page-body" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Tuesday"))
    length <$> findAll ui ".comments-toggle" `shouldReturn` 0
    length <$> findAll ui ".comments-panel" `shouldReturn` 0
    unmount ui
    editor <- startServer m (R.EditPage [secretSlug] [made.slug])
    text <- editorText editor
    length <$> findAll editor ".editor-attach" `shouldReturn` 0
    length <$> findAll editor ".tool[aria-label='Image or attachment']" `shouldReturn` 0
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
