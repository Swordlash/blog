-- | Encrypted spaces in the storage (WP5.74b2 of docs/PLAN.md,
-- "Wiki.Core.Encrypted"), on each database, with ciphertexts of made-up
-- bytes of the right lengths: the server reads none of them.
--
-- A private space with nothing written in it is turned encrypted, its
-- untouched home page deleted, and its key granted to its creator; its
-- readers with a public key wait for a grant, those without one are
-- listed as waiting, and only a holder of the key may grant it, only to
-- readers, only of the current key. Pages are written and read as
-- ciphertext, with empty titles and texts in the rows every other path
-- reads, and a random slug. Every plain path that reads or writes a
-- page's text refuses an encrypted space with a reason; the server's
-- search leaves it out; notifications carry no title and no excerpt; a
-- reader who is not a member gets nothing; and a password reset sends its
-- user back to the readers waiting for a grant.
module Test.Storage.Encrypted (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (all_, delete, filter_, runDelete, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import Test.Database (Backing)
import Test.Hspec
import Test.Storage.Fixture (ok, withPlaceIn)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Encrypted
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.Vault (NewPublicKey (..), VaultChange (..))
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Encrypted (Encapsulated (..), KeyGrant (..), PageKey (..), SealedContent (..), SealedHeading (..), VersionTag (..))
import Wiki.Core.Id (PageId (..), SpaceId, UserId (..))
import Wiki.Core.Notification (Notification (..), WatchTarget (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space (Space (..), SpaceProfile (..))
import Wiki.Core.User (Password (..), User (..))
import Wiki.Core.Vault
import Wiki.Core.Version (VersionsQuery (..))
import Wiki.Server.Accounts (createAccount)
import Wiki.Server.Storage
import Wiki.Server.Storage.Schema (Pages (..), PublicKeys (..), Vaults (..), WikiDb (..), wikiDb)
import Wiki.Server.Vault (keyIdOf, storeVault)
import Wiki.Server.WebAuthn (toBase64Url)

spec :: Backing -> Spec
spec backing = describe "encrypted spaces in the storage" $ do
  it "turns a private space with nothing written in it encrypted, and only such a space" $ withPeople backing $ \st p -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    -- A subspace not private from its parent: refused. (A top-level space
    -- is made private as it is encrypted.)
    above <- ok =<< as p.ada (createSpace Nothing "Above")
    open <- ok =<< as p.ada (createSpace (Just above.id) "Open")
    -- Not private: refused.
    as p.ada (encryptSpace open.id (encryptAs p.ada p.adaKey)) `shouldReturn` Left (Conflict "Only a private space can be encrypted: make it private from its parent first.")
    void (ok =<< as p.ada (setSpaceSealed open.id True))
    -- Public: refused.
    void (ok =<< as p.ada (setSpacePublic open.id True))
    as p.ada (encryptSpace open.id (encryptAs p.ada p.adaKey)) `shouldReturn` Left (Conflict "A public space cannot be encrypted: anyone may read it.")
    void (ok =<< as p.ada (setSpacePublic open.id False))
    -- Its home page written to: refused, since the server has read it.
    home <- ok =<< as p.ada (homeOf open.id)
    void (ok =<< as p.ada (savePage home.id home.updatedAt "Home" "A secret written in plain text."))
    as p.ada (encryptSpace open.id (encryptAs p.ada p.adaKey)) >>= (`shouldSatisfy` conflict)
    -- Sealed to someone else's key, or with a part of the wrong length.
    secret <- privateSpace st p.ada "Secret"
    as p.ada (encryptSpace secret.id (encryptAs p.ada p.bobKey)) >>= (`shouldSatisfy` invalid)
    as p.ada (encryptSpace secret.id EncryptSpace {keyId = spaceKey, grant = NewGrant {recipient = p.ada, recipientKeyId = p.adaKey, enc = Encapsulated (bytes 32), sealed = Ciphertext (bytes 47)}}) >>= (`shouldSatisfy` invalid)
    -- A reader who does not administer it: refused.
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) Edit True))
    as p.bob (encryptSpace secret.id (encryptAs p.bob p.bobKey)) `shouldReturn` Left Forbidden
    -- Its untouched home page goes, and its first key is the creator's.
    encrypted <- ok =<< as p.ada (encryptSpace secret.id (encryptAs p.ada p.adaKey))
    (encrypted.encryption, encrypted.homePage) `shouldBe` (Just spaceKey, Nothing)
    as p.ada (listSpaces <&> map (\s -> (s.id, s.encryption))) >>= (`shouldContain` [(secret.id, Just spaceKey)])
    e <- ok =<< as p.ada (spaceEncryption secret.id)
    (e.keyId, (\g -> (g.recipient, g.recipientKeyId)) <$> e.grant) `shouldBe` (spaceKey, Just (p.ada, p.adaKey))
    -- Once only, and never back.
    as p.ada (encryptSpace secret.id (encryptAs p.ada p.adaKey)) `shouldReturn` Left (Conflict "This space is encrypted already.")
    as p.ada (setSpaceSealed secret.id False) >>= (`shouldSatisfy` refusedAsEncrypted)
    as p.ada (setSpacePublic secret.id True) >>= (`shouldSatisfy` refusedAsEncrypted)
    as p.ada (createSpace (Just secret.id) "Inside") >>= (`shouldSatisfy` refusedAsEncrypted)
    as p.ada (setSpaceProfile secret.id SpaceProfile {description = "", icon = Nothing, homePage = Nothing, blog = True, boxNumbering = encrypted.boxNumbering}) >>= (`shouldSatisfy` refusedAsEncrypted)

  it "lists the readers waiting for the key, and lets only a holder of the key grant it to them" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.cyd) View True))
    -- Bob has a public key and waits for a grant; Cyd has none yet.
    e <- ok =<< as p.ada (spaceEncryption secret.id)
    (map (\m -> (m.user, m.keyId)) e.pending, e.waiting) `shouldBe` ([(p.bob, p.bobKey)], [p.cyd])
    -- Bob holds no grant: he is told of nobody, and may grant nothing.
    b <- ok =<< as p.bob (spaceEncryption secret.id)
    (isJust b.grant, b.pending, b.waiting) `shouldBe` (False, [], [])
    as p.bob (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey])) `shouldReturn` Left Forbidden
    -- Not to someone who does not read the space, not of an older key, and
    -- not to a public key that is not the reader's current one.
    as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.dan p.danKey])) `shouldReturn` Left (Invalid "A space's key is granted only to its readers.")
    as p.ada (grantSpaceKey secret.id NewGrants {keyId = KeyId (bytes16 'o'), grants = [newGrant p.bob p.bobKey]}) >>= (`shouldSatisfy` conflict)
    as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.danKey])) >>= (`shouldSatisfy` conflict)
    -- Ada holds it: Bob gets it, once however often it is sent.
    ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey]))
    ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey]))
    b' <- ok =<< as p.bob (spaceEncryption secret.id)
    ((\g -> (g.recipient, g.recipientKeyId)) <$> b'.grant) `shouldBe` Just (p.bob, p.bobKey)
    (\x -> x.pending) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` []
    -- A reset retires Bob's key: his grant opens for nobody, and he waits
    -- again, for his new key.
    now <- getCurrentTime
    writing st (runUpdate (update wikiDb.public_keys (\k -> mconcat [k.retired_at <-. val_ (Just now), k.retired_because <-. val_ (Just "reset")]) (\k -> k.user_id ==. val_ p.bob.text)))
    (\x -> x.grant) <$> (ok =<< as p.bob (spaceEncryption secret.id)) `shouldReturn` Nothing
    (sort . (\x -> x.waiting)) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` sort [p.bob, p.cyd]
    fresh <- giveKey st p.bob 'f'
    (map (\m -> (m.user, m.keyId)) . (\x -> x.pending)) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` [(p.bob, fresh)]

  it "keeps a global administrator who is not a member out of the key, and a reader who is not one out of the space" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    e <- ok =<< as p.ada (spaceEncryption secret.id)
    (e.pending, e.waiting) `shouldBe` ([], [])
    as p.dan (spaceEncryption secret.id) `shouldReturn` Left NotFound
    as p.dan (sealedPages secret.id) `shouldReturn` Left NotFound
    as p.dan (listSpaces <&> map (\s -> s.id)) >>= (`shouldNotContain` [secret.id])
    -- The operator reads the space's record, but holds no grant.
    o <- ok =<< runStoredWiki st Administrator (spaceEncryption secret.id)
    o.grant `shouldBe` Nothing

  it "writes and reads pages as ciphertext, with empty titles and texts where the rest of the server reads them" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    (made.id, made.content, made.pageKey) `shouldBe` (pid, contentOf 'a', pageKeyOf)
    -- The slug is random, never made from a title the server never had.
    T.length (slugText made.slug) `shouldBe` 12
    rows <- reading st (runSelectReturningList (select (filter_ (\r -> r.id ==. val_ pid.text) (all_ wikiDb.pages))))
    [(r.title, r.body, r.search_text) | r <- rows] `shouldBe` [("", "", "")]
    -- The same id again, an id that is not a UUID, a page key under an
    -- older space key, a version under another page key: refused.
    as p.ada (createSealedPage secret.id (newPage pid Nothing 'b')) >>= (`shouldSatisfy` conflict)
    as p.ada (createSealedPage secret.id (newPage (PageId "my-title") Nothing 'b')) >>= (`shouldSatisfy` invalid)
    as p.ada (createSealedPage secret.id NewSealedPage {id = otherId, parent = Nothing, pageKey = pageKeyOf {spaceKeyId = KeyId (bytes16 'o')}, content = contentOf 'b'}) >>= (`shouldSatisfy` conflict)
    as p.ada (createSealedPage secret.id NewSealedPage {id = otherId, parent = Nothing, pageKey = pageKeyOf, content = contentUnder (KeyId (bytes16 'o')) 'b'}) >>= (`shouldSatisfy` invalid)
    -- A save over the version read; one over an older version refused.
    saved <- ok =<< as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = contentOf 'c'})
    saved.content `shouldBe` contentOf 'c'
    as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = contentOf 'd'}) >>= (`shouldSatisfy` conflict)
    -- Read back by its path, listed, and its history.
    ((\x -> x.content) <$> (ok =<< as p.ada (sealedPageAt secret.id [made.slug]))) `shouldReturn` contentOf 'c'
    listed <- ok =<< as p.ada (sealedPages secret.id)
    [(s.id, s.heading.title) | s <- listed] `shouldBe` [(pid, (contentOf 'c').title)]
    contents <- ok =<< as p.ada (sealedContents secret.id)
    map (\x -> x.content) contents `shouldBe` [contentOf 'c']
    versions <- ok =<< as p.ada (sealedVersions pid (VersionsQuery Nothing 50))
    [(v.number, v.heading.title) | v <- versions] `shouldBe` [(2, (contentOf 'c').title), (1, (contentOf 'a').title)]
    first' <- ok =<< as p.ada (sealedVersionAt pid made.updatedAt)
    first'.content `shouldBe` contentOf 'a'
    -- A plain space's pages are not read through these routes.
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    as p.ada (sealedPages plain.id) >>= (`shouldSatisfy` conflict)
    -- Deleting the space takes its grants with it.
    ok =<< as p.ada (deleteSpace secret.id)
    count <- reading st (length <$> runSelectReturningList (select (all_ wikiDb.key_grants)))
    count `shouldBe` 0

  it "refuses every plain path that reads or writes a page's text in an encrypted space, and searches it not" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    plainHome <- ok =<< as p.ada (homeOf plain.id)
    let refused :: Text -> Either WikiError b -> (Text, Text)
        refused what result = (what, either (\e -> if refusedAsEncrypted (Left e :: Either WikiError ()) then "refused" else show e) (const "done") result)
    results <-
      sequence
        [ refused "list pages" <$> as p.ada (listPages secret.id)
        , refused "page" <$> as p.ada (getPage secret.id [made.slug])
        , refused "create page" <$> as p.ada (createPage secret.id Nothing "A title" "A text")
        , refused "save page" <$> as p.ada (savePage pid made.updatedAt "A title" "A text")
        , refused "move out" <$> as p.ada (movePage pid plain.id Nothing)
        , refused "move in" <$> as p.ada (movePage plainHome.id secret.id Nothing)
        , refused "template" <$> as p.ada (setPageTemplate pid True)
        , refused "attachment" <$> as p.ada (uploadAttachment pid "a.txt" "text/plain" "bytes")
        , refused "get draft" <$> as p.ada (getDraft pid)
        , refused "save draft" <$> as p.ada (saveDraft pid made.updatedAt "A title" "A text")
        , refused "history" <$> as p.ada (listVersions pid (VersionsQuery Nothing 50))
        , refused "version" <$> as p.ada (getVersion pid made.updatedAt)
        , refused "restore" <$> as p.ada (restoreVersion pid made.updatedAt made.updatedAt)
        , refused "posts" <$> as p.ada (postDetails secret.id)
        , refused "comments" <$> as p.ada (listThreads pid)
        , refused "comment" <$> as p.ada (openThread pid Nothing "A comment")
        , refused "page export" <$> as p.ada (exportedPage pid)
        , refused "space export" <$> as p.ada (spacePages secret.id)
        , refused "feed" <$> as p.ada (feedPosts secret.id [pid])
        ]
    [(w, r) | (w, r) <- results, r /= "refused"] `shouldBe` []
    -- The server's search leaves the space out, even by its id.
    hits <- as p.ada (searchPages (searchQuery "") {text = "anything", space = Just secret.id})
    hits `shouldBe` []
    -- Deleting a page and moving it among its siblings need no text.
    ok =<< as p.ada (deletePage pid)

  it "tells a watcher of the space that a page was saved, by its id alone" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
    void (ok =<< as p.bob (setWatching (WatchSpace secret.id) True))
    void (ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a')))
    told <- ok =<< as p.bob notifications
    [(n.page, n.title, n.excerpt) | n <- told.items] `shouldBe` [(pid, "", "")]

  it "takes no plain title or text for a page of an encrypted space" $ do
    -- A title or a text given as text, not as a ciphertext, does not parse.
    let body = "{\"id\":\"6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f\",\"parent\":null,\"pageKey\":{\"keyId\":\"a\",\"spaceKeyId\":\"b\",\"wrapped\":{\"nonce\":\"n\",\"key\":\"k\"}},\"content\":{\"tag\":\"t\",\"keyId\":\"a\",\"title\":\"My plain title\",\"body\":\"My plain text\"}}"
    isLeft (eitherDecode body :: Either [Char] NewSealedPage) `shouldBe` True
    isLeft (eitherDecode "{\"content\":{\"title\":\"x\",\"body\":\"y\"}}" :: Either [Char] SealedEdit) `shouldBe` True

-- | A space's only page, its home page, as a new space has it.
homeOf :: (MonadWiki m) => SpaceId -> m (Either WikiError Page)
homeOf sid =
  listPages sid >>= \case
    Right [h] -> getPage sid [h.slug]
    Right _ -> pure (Left NotFound)
    Left e -> pure (Left e)

--------------------------------------------------------------------------------
-- The people

-- | 'People': Ada, who makes the space; Bob and Dan, who have public keys;
-- Cyd, who has none yet.
data People = People
  { ada :: UserId
  , adaKey :: KeyId
  , bob :: UserId
  , bobKey :: KeyId
  , cyd :: UserId
  , dan :: UserId
  , danKey :: KeyId
  }

withPeople :: Backing -> (Storage -> People -> IO a) -> IO a
withPeople backing action = withPlaceIn backing $ \at -> withStorage defaultConfig at $ \st -> do
  let person login = (\a -> a.user.id) <$> (ok =<< createAccount st login (T.toTitle login) (Just (Password "correct horse")))
  ada <- person "ada"
  bob <- person "bob"
  cyd <- person "cyd"
  dan <- person "dan"
  ok =<< runStoredWiki st Administrator (setCreateSpaces ada True)
  adaKey <- giveKey st ada 'a'
  bobKey <- giveKey st bob 'b'
  danKey <- giveKey st dan 'd'
  action st People {ada, adaKey, bob, bobKey, cyd, dan, danKey}

-- | A storage with the people and Ada's encrypted space.
withEncrypted :: Backing -> (Storage -> People -> Space -> IO a) -> IO a
withEncrypted backing action = withPeople backing $ \st p -> do
  s <- privateSpace st p.ada "Secret"
  encrypted <- ok =<< runStoredWiki st (AsUser p.ada) (encryptSpace s.id (encryptAs p.ada p.adaKey))
  action st p encrypted

-- | A new private space of someone's.
privateSpace :: Storage -> UserId -> Text -> IO Space
privateSpace st u name = do
  s <- ok =<< runStoredWiki st (AsUser u) (createSpace Nothing name)
  ok =<< runStoredWiki st (AsUser u) (setSpaceSealed s.id True)

-- | Give a user a key pair: a vault holding it, and its public key in the
-- directory, made of a letter; the key's id. A vault there already (one
-- whose key a reset retired) is replaced, as the next sign-in after a
-- reset replaces it.
giveKey :: Storage -> UserId -> Char -> IO KeyId
giveKey st u c = do
  now <- getCurrentTime
  let public = PublicKey (toBase64Url (BS.replicate 32 (fromIntegral (ord c))))
      keyId = fromMaybe (KeyId "") (keyIdOf public)
      vault = Vault {format = vaultFormat, salt = Salt (bytes 32), items = Map.singleton identityItem Item {keyId = Just keyId, sealed = Sealed (Nonce (bytes 12)) (Ciphertext (bytes 64))}, wraps = Map.singleton ByPassword (WrappedKey (Nonce (bytes 12)) (Ciphertext (bytes 48)))}
  writing st (runDelete (delete wikiDb.vaults (\v -> v.user_id ==. val_ u.text)))
  void (ok =<< storeVault st now u Nothing VaultChange {vault, publicKey = Just NewPublicKey {keyId, publicKey = public}})
  pure keyId

--------------------------------------------------------------------------------
-- Ciphertexts

-- | So many bytes of one letter, in base64url.
bytes :: Int -> Text
bytes n = toBase64Url (BS.replicate n 120)

bytes16 :: Char -> Text
bytes16 c = toBase64Url (BS.replicate 16 (fromIntegral (ord c)))

spaceKey :: KeyId
spaceKey = KeyId (bytes16 's')

newGrant :: UserId -> KeyId -> NewGrant
newGrant u k = NewGrant {recipient = u, recipientKeyId = k, enc = Encapsulated (bytes 32), sealed = Ciphertext (bytes 48)}

grantsOf :: [NewGrant] -> NewGrants
grantsOf = NewGrants spaceKey

encryptAs :: UserId -> KeyId -> EncryptSpace
encryptAs u k = EncryptSpace {keyId = spaceKey, grant = newGrant u k}

pageKeyOf :: PageKey
pageKeyOf = PageKey {keyId = KeyId (bytes16 'p'), spaceKeyId = spaceKey, wrapped = WrappedKey (Nonce (bytes 12)) (Ciphertext (bytes 48))}

-- | A version, its ciphertexts made of a letter.
contentOf :: Char -> SealedContent
contentOf = contentUnder (KeyId (bytes16 'p'))

-- | A version encrypted with a page key, its ciphertexts made of a letter.
contentUnder :: KeyId -> Char -> SealedContent
contentUnder k c =
  SealedContent
    { tag = VersionTag (bytes16 c)
    , keyId = k
    , title = Sealed (Nonce (bytes16' 12)) (Ciphertext (bytes16' 40))
    , body = Sealed (Nonce (bytes16' 12)) (Ciphertext (bytes16' 200))
    }
  where
    bytes16' n = toBase64Url (BS.replicate n (fromIntegral (ord c)))

newPage :: PageId -> Maybe PageId -> Char -> NewSealedPage
newPage pid parent c = NewSealedPage {id = pid, parent, pageKey = pageKeyOf, content = contentOf c}

otherId :: PageId
otherId = PageId "0d9e8f7a-6b5c-4d3e-8f1a-2b3c4d5e6f70"

--------------------------------------------------------------------------------
-- Refusals

conflict :: Either WikiError a -> Bool
conflict = \case
  Left (Conflict _) -> True
  _ -> False

invalid :: Either WikiError a -> Bool
invalid = \case
  Left (Invalid _) -> True
  _ -> False

-- | Whether a plain operation was refused because the space is encrypted.
refusedAsEncrypted :: Either WikiError a -> Bool
refusedAsEncrypted = \case
  Left (Conflict why) -> "is not possible in an encrypted space" `T.isInfixOf` why
  _ -> False
