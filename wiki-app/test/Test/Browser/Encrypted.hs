{-# LANGUAGE TemplateHaskell #-}

-- | Encrypted spaces in a browser (WP5.74b2 of docs/PLAN.md,
-- "Wiki.App.Encrypted", "Wiki.App.Backend.Http"'s encrypted spaces): a
-- space turned encrypted, a page written, read back and saved again, with
-- its history, and nothing of its title or text in what the server
-- stored; a second member waiting for the key, given it by the first
-- member's browser when it opens the space, and reading the page; the
-- search finding a word of an encrypted page in the browser, where the
-- server's finds nothing; a page over plain HTTP refusing; and a device
-- that does not hold the user's private key showing the space as locked,
-- with the unlock offered, and reading it once the key is there.
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
import Test.Browser.Http (answerWith, serveDemo, serverStarts, startServer)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..))
import Wiki.App.Backend.Http (HttpEnv, HttpWiki, browserTransport, newHttpEnv, runHttpWiki)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State qualified as M
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route qualified as R
import Wiki.Core.Id (SpaceId (..), UserId (..))
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Search (SearchHit (..), searchQuery)
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
     ]
 )

js_key_pair :: JSText -> IO ()
js_key_pair a = if inBrowser then wait =<< js_key_pairPromise a else pure inert

js_forget_device :: JSText -> IO ()
js_forget_device a = if inBrowser then wait =<< js_forget_devicePromise a else pure inert

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
    unsafeIOToPageM (js_key_pair "user-reader")
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
    unsafeIOToPageM (js_forget_device "user-admin")
    serveDemo
    answerWith "GET" "api/v1/session" 200 =<< sessionOf "user-admin"
    ui <- startServer m (R.Space [secretSlug])
    eventually (find ui ".encrypted-space .encrypted-state" >>= (`shouldContainText` "does not hold your keys"))
    _ <- find ui ".encrypted-unlock-passkey"
    -- What an unlock of the vault puts on the device ("Wiki.App.Vault").
    unsafeIOToPageM (js_unlock_device "user-admin")
    find ui ".encrypted-retry" >>= click
    eventually (find ui "body" >>= (`shouldContainText` "Behind the lock"))
    length <$> findAll ui ".encrypted-space" `shouldReturn` 0
  where
    -- The server with the space, the admin and the reader its readers, and
    -- a key pair for the user who asks first, in a tab of theirs.
    encryptedSpace :: Text -> PageM s HttpEnv
    encryptedSpace user = do
      serverStarts
      unsafeIOToPageM (js_start (toJSText (decodeUtf8 (toS (encode secret)))) (toJSText ("[\"user-admin\",\"user-reader\"]" :: Text)))
      unsafeIOToPageM (js_key_pair (toJSText user))
      as user

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

shouldContainText :: Element s -> Text -> PageM s ()
shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)
