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
-- user back to the readers waiting for a grant. A page moves within its
-- encrypted space, but not out of it or into it; a grant sent twice in one
-- request is made once; and a whole wiki's archive comes in with every
-- space plain. The whole wiki's export leaves an encrypted space out, an
-- import into one is refused, and the sitemap lists its pages, by their
-- random slugs, to its members only.
--
-- Comments, the text they quote, and attachments' names and bytes are
-- kept as the browser encrypted them, under ids it chose and the page's
-- current key, with no text in the rows other paths read; those told of a
-- comment get no title, excerpt or mention; and what was written before
-- a renewal is read under the older key it names.
module Test.Storage.Encrypted (spec) where

import Data.Aeson (eitherDecode)
import Data.ByteString qualified as BS
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (all_, delete, filter_, runDelete, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing)
import Test.Hspec
import Test.Storage.Fixture (demoArchive, ok, withPlaceIn)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Encrypted
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.Opaque (PasswordRecord (..))
import Wiki.Api.Opaque qualified as Opaque
import Wiki.Api.Upload (SealedUpload (..))
import Wiki.Api.Vault (NewPublicKey (..), VaultChange (..))
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Backlink (Backlink (..))
import Wiki.Core.Encrypted (Chain (..), Encapsulated (..), KeyGrant (..), PageKey (..), SealedAnchor (..), SealedComment (..), SealedContent (..), SealedHeading (..), SealedMeta (..), VersionTag (..), chainAfter, firstChain)
import Wiki.Core.Export qualified as Export
import Wiki.Core.Id (AttachmentId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId, UserId (..))
import Wiki.Core.Notification (Kind (..), Notification (..), WatchTarget (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Permission (Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Slug (mkSlug, slugText)
import Wiki.Core.Space (Space (..), SpaceProfile (..))
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Group (..), Password (..), User (..))
import Wiki.Core.Vault
import Wiki.Core.Version (VersionsQuery (..))
import Wiki.Server.Accounts (createAccount)
import Wiki.Server.Import (intoEncrypted)
import Wiki.Server.Opaque (defaultStretch)
import Wiki.Server.Reset (ResetMail (..), requestReset, resetPassword, setEmail, verifyEmail)
import Wiki.Server.Storage
import Wiki.Server.Storage.Rows (SitemapNode (..), StoredRecord (..))
import Wiki.Server.Storage.Schema (Comments (..), KeyGrants (..), PageKeys (..), PageLinks (..), Pages (..), PublicKeys (..), SealedVersions (..), Threads (..), Vaults (..), WikiDb (..), wikiDb)
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
    -- A page someone wrote beside the home page it was created with:
    -- refused, and both pages kept.
    written <- privateSpace st p.ada "Written"
    starter <- ok =<< as p.ada (homeOf written.id)
    plan <- ok =<< as p.ada (createPage written.id Nothing "Plan" "What we will do.")
    as p.ada (deletePage starter.id) >>= (`shouldSatisfy` invalid)
    as p.ada (encryptSpace written.id (encryptAs p.ada p.adaKey)) >>= (`shouldSatisfy` conflict)
    void (ok =<< as p.ada (getPage written.id [starter.slug]))
    void (ok =<< as p.ada (getPage written.id [plan.slug]))
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
    as p.ada (setSpaceProfile secret.id SpaceProfile {description = "", icon = Nothing, blog = True, boxNumbering = encrypted.boxNumbering}) >>= (`shouldSatisfy` refusedAsEncrypted)

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
    let secondContent = savedOn (contentOf 'a') 'c'
    saved <- ok =<< as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = secondContent})
    saved.content `shouldBe` secondContent
    as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = savedOn secondContent 'd'}) >>= (`shouldSatisfy` conflict)
    -- Read back by its path, listed, and its history.
    ((\x -> x.content) <$> (ok =<< as p.ada (sealedPageAt secret.id [made.slug]))) `shouldReturn` secondContent
    listed <- ok =<< as p.ada (sealedPages secret.id)
    [(s.id, s.heading.title, s.heading.chain) | s <- listed] `shouldBe` [(pid, secondContent.title, secondContent.chain)]
    contents <- ok =<< as p.ada (sealedContents secret.id)
    map (\x -> x.content) contents `shouldBe` [secondContent]
    versions <- ok =<< as p.ada (sealedVersions pid (VersionsQuery Nothing 50))
    [(v.number, v.heading.title, v.heading.chain) | v <- versions] `shouldBe` [(2, secondContent.title, secondContent.chain), (1, (contentOf 'a').title, Just firstChain)]
    first' <- ok =<< as p.ada (sealedVersionAt pid made.updatedAt)
    first'.content `shouldBe` contentOf 'a'
    -- A plain space's pages are not read through these routes.
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    as p.ada (sealedPages plain.id) >>= (`shouldSatisfy` conflict)
    -- Deleting the space takes its grants with it.
    ok =<< as p.ada (deleteSpace secret.id)
    count <- reading st (length <$> runSelectReturningList (select (all_ wikiDb.key_grants)))
    count `shouldBe` 0

  -- The chain of versions (WP5.74b3 of docs/PLAN.md): a version is taken
  -- only as the next of its page's chain, and a version of format 1,
  -- written before versions were chained, is read as it was and chained on.
  it "takes a version only as the next of its page's chain, and chains on from a version written before" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
        unchained c = chainedAs Nothing (contentOf c)
    -- A first version that is not the chain's first, or has none: refused.
    as p.ada (createSealedPage secret.id NewSealedPage {id = pid, parent = Nothing, pageKey = pageKeyOf, content = savedOn (contentOf 'z') 'a'}) >>= (`shouldSatisfy` conflict)
    as p.ada (createSealedPage secret.id NewSealedPage {id = pid, parent = Nothing, pageKey = pageKeyOf, content = unchained 'a'}) >>= (`shouldSatisfy` conflict)
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    -- A save that skips a number, names another version, or has no chain.
    let skipping = chainedAs (Just (Chain 3 (Just (contentOf 'a').tag))) (contentOf 'b')
        elsewhere = savedOn (contentOf 'z') 'b'
    for_ [skipping, elsewhere, unchained 'b'] $ \c ->
      as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = c}) >>= (`shouldSatisfy` conflict)
    -- A page whose latest version is of format 1, as b2 wrote it: read as
    -- it was, and the next version is the chain's first, naming it.
    writing st (runUpdate (update wikiDb.sealed_versions (\v -> mconcat [v.chain_number <-. val_ Nothing, v.previous_tag <-. val_ Nothing]) (\v -> v.page_id ==. val_ pid.text)))
    old <- ok =<< as p.ada (sealedPageAt secret.id [made.slug])
    old.content `shouldBe` unchained 'a'
    let chained = chainedAs (Just (Chain 1 (Just (contentOf 'a').tag))) (contentOf 'b')
    saved <- ok =<< as p.ada (saveSealedPage pid old.updatedAt SealedEdit {content = chained})
    saved.content.chain `shouldBe` Just (Chain 1 (Just (contentOf 'a').tag))
    third <- ok =<< as p.ada (saveSealedPage pid saved.updatedAt SealedEdit {content = savedOn chained 'c'})
    third.content.chain `shouldBe` Just (Chain 2 (Just chained.tag))

  -- A new key when a reader is removed (WP5.74b3 of docs/PLAN.md, item 2):
  -- every way a reader stops being one makes a rotation due, and while it
  -- is due nothing is sealed under the key, and the space's administrators
  -- are told once.
  describe "a new key when a reader stops being one" $ do
    let ways :: [(Text, Storage -> People -> Space -> IO ())]
        ways =
          [ ("a grant removed", \st p s -> void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectUser p.bob) View False)))
          ,
            ( "a group's member removed"
            , \st p s -> do
                g <- byGroup st p s
                void (ok =<< runStoredWiki st Administrator (removeMember g.id p.bob))
            )
          ,
            ( "a group's grant removed"
            , \st p s -> do
                g <- byGroup st p s
                void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectGroup g.id) View False))
            )
          ,
            ( "a group deleted"
            , \st p s -> do
                g <- byGroup st p s
                void (ok =<< runStoredWiki st Administrator (deleteGroup g.id))
            )
          , ("an account disabled", \st p _ -> void (ok =<< runStoredWiki st Administrator (setDisabled p.bob True)))
          ,
            ( "an account removed"
            , \st p _ -> do
                void (ok =<< runStoredWiki st Administrator (setDisabled p.bob True))
                void (ok =<< runStoredWiki st Administrator (removeUser p.bob))
            )
          ,
            ( "an administrator's own grant withdrawn"
            , \st p s -> do
                -- Bob administers the space; his grant to view it goes, and
                -- with it his grant to administer it.
                void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectUser p.bob) AdministerSpace True))
                void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectUser p.bob) View False))
                void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectUser p.bob) AdministerSpace False))
            )
          ,
            ( "a key pair retired by a reset"
            , \st p _ -> do
                now <- getCurrentTime
                writing st (runUpdate (update wikiDb.public_keys (\k -> mconcat [k.retired_at <-. val_ (Just now), k.retired_because <-. val_ (Just "reset")]) (\k -> k.user_id ==. val_ p.bob.text)))
            )
          ]
    for_ ways $ \(way, change) ->
      it ("is due after " <> toS way <> ", refuses every sealed write until then, and tells the administrators once") $ withEncrypted backing $ \st p secret -> do
        let as :: UserId -> StoredWiki IO a -> IO a
            as u = runStoredWiki st (AsUser u)
            pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
        made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
        -- Bob reads the space and holds its key.
        void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
        ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey]))
        (\x -> x.rotationDue) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` False
        change st p secret
        (\x -> x.rotationDue) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` True
        as p.ada (createSealedPage secret.id (newPage otherId Nothing 'b')) >>= (`shouldSatisfy` renewalRefused)
        as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = savedOn (contentOf 'a') 'c'}) >>= (`shouldSatisfy` renewalRefused)
        as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.dan p.danKey])) >>= (`shouldSatisfy` \r -> renewalRefused r || invalid r)
        -- Told once, under the bell: a reset outside the storage's
        -- transactions (played here by a row changed) tells nobody itself.
        told <- ok =<< as p.ada notifications
        length [n | n <- told.items, n.kind == KeyToRenew] `shouldBe` (if way == "a key pair retired by a reset" then 0 else 1)
        -- The rotation lifts it.
        rotateAs st p.ada secret
        (\x -> x.rotationDue) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` False

    -- The notices are published after the commit, as every notification
    -- is, to a subscriber of the storage's (the server's live channel):
    -- for a reader removed in the permissions, and for one whose password
    -- is reset through a link, by the reset's own path.
    it "publishes the notice to the administrators as it is made, for a reader removed and for a password reset" $ do
      published <- newIORef []
      let config = defaultConfig {notify = \told -> modifyIORef' published (<> told)}
      withPeopleIn config backing $ \st p -> do
        let as :: UserId -> StoredWiki IO a -> IO a
            as u = runStoredWiki st (AsUser u)
        secret <- encryptedOf st p
        void (ok =<< as p.ada (createSealedPage secret.id (newPage (PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f") Nothing 'a')))
        let readsAgain = do
              void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
              e <- ok =<< as p.ada (spaceEncryption secret.id)
              ok =<< as p.ada (grantSpaceKey secret.id (grantsAt e.keyId))
            grantsAt k = NewGrants {keyId = k, grants = [newGrant p.bob p.bobKey]}
            renewalsTo = (\told -> [u | (u, n) <- told, n.kind == KeyToRenew]) <$> readIORef published
        readsAgain
        void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View False))
        renewalsTo `shouldReturn` [p.ada]
        rotateAs st p.ada secret
        -- Bob again, then his password reset through a link: his key pair
        -- is retired, the key is due again, and Ada is told.
        readsAgain
        now <- getCurrentTime
        Right (Just (_, token)) <- setEmail st now p.bob "bob@example.org"
        verifyEmail st now token `shouldReturn` Right ()
        mails <- requestReset st now "bob"
        mail <- maybe (panic "no reset was mailed") pure (head mails)
        record <- recordHere st p.bob (Password "a password set again") >>= either panic pure
        resetPassword st now mail.token PasswordRecord {credential = p.bob.text, record = Opaque.Message record.record, stretch = defaultStretch} `shouldReturn` Right ()
        (\x -> x.rotationDue) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` True
        renewalsTo `shouldReturn` [p.ada, p.ada]

    it "takes a rotation that seals the new key to every reader and wraps every page key again, and keeps the old versions readable" $ withEncrypted backing $ \st p secret -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
          pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
      made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.dan) View True))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.dan) View False))
      rotateAs st p.ada secret
      e <- ok =<< as p.ada (spaceEncryption secret.id)
      grants <- reading st (runSelectReturningList (select (all_ wikiDb.key_grants)))
      -- The new key's grants alone, to the readers: Ada and Bob.
      sort [(g.key_id, g.recipient) | g <- grants] `shouldBe` sort [(e.keyId.text, p.ada.text), (e.keyId.text, p.bob.text)]
      read' <- ok =<< as p.ada (sealedPageAt secret.id [made.slug])
      -- The page's old key, wrapped again, and a new current one.
      map (\k -> k.keyId) read'.pageKeys `shouldBe` [read'.pageKey.keyId, pageKeyOf.keyId]
      all (\k -> k.spaceKeyId == e.keyId) read'.pageKeys `shouldBe` True
      read'.content `shouldBe` contentOf 'a'
      -- The next version is encrypted with the page's new key: one with
      -- the old is refused.
      as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = savedOn (contentOf 'a') 'c'}) >>= (`shouldSatisfy` conflict)
      let underNew = chainedAs (Just (chainAfter (contentOf 'a').tag (Just firstChain))) (contentUnder read'.pageKey.keyId 'c')
      saved <- ok =<< as p.ada (saveSealedPage pid made.updatedAt SealedEdit {content = underNew})
      saved.content.keyId `shouldBe` read'.pageKey.keyId
      first' <- ok =<< as p.ada (sealedVersionAt pid made.updatedAt)
      first'.content `shouldBe` contentOf 'a'

    it "refuses a rotation from one who may not make it, or that leaves out or adds a reader or a key" $ withEncrypted backing $ \st p secret -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
          pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
      void (ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a')))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) Edit True))
      ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey]))
      info <- ok =<< as p.ada (rotationInfo secret.id)
      let good = rotationOf 1 info
          rotation from' grants pages = Rotation {from = from', keyId = good.keyId, grants, pages}
          withGrants gs = rotation good.from gs good.pages
          withPages = rotation good.from good.grants
          onePage f = withPages [f x | x <- good.pages]
          rotated (x :: RotatedPage) current rewrapped = RotatedPage {page = x.page, current, rewrapped}
          refused r = as p.ada (rotateSpaceKey secret.id r)
      -- A reader who holds the key but does not administer the space; an
      -- administrator who does not hold it.
      as p.bob (rotateSpaceKey secret.id good) `shouldReturn` Left Forbidden
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.dan) AdministerSpace True))
      runStoredWiki st (AsUser p.dan) (rotateSpaceKey secret.id (rotationOf 1 info)) >>= (`shouldSatisfy` \r -> r == Left Forbidden || conflict r)
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.dan) AdministerSpace False))
      -- Not from the current key; a reader left out, a non-reader added, a
      -- reader's other public key.
      refused (rotation (KeyId (bytes16 'q')) good.grants good.pages) >>= (`shouldSatisfy` conflict)
      refused (withGrants (filter (\g -> g.recipient /= p.bob) good.grants)) >>= (`shouldSatisfy` conflict)
      refused (withGrants (good.grants <> [newGrant p.dan p.danKey])) >>= (`shouldSatisfy` conflict)
      refused (withGrants [if g.recipient == p.bob then newGrant p.bob p.danKey else g | g <- good.grants]) >>= (`shouldSatisfy` conflict)
      -- A page left out, a page's key left out, a new key under an old
      -- id, a key wrapped by another space key.
      refused (withPages []) >>= (`shouldSatisfy` conflict)
      refused (onePage (\x -> rotated x x.current [])) >>= (`shouldSatisfy` conflict)
      refused (onePage (\x -> rotated x pageKeyOf {spaceKeyId = good.keyId} x.rewrapped)) >>= (`shouldSatisfy` invalid)
      refused (onePage (\x -> rotated x PageKey {keyId = x.current.keyId, spaceKeyId = spaceKey, wrapped = x.current.wrapped} x.rewrapped)) >>= (`shouldSatisfy` invalid)
      -- Too large for one request.
      refused (withPages (replicate (maxRotatedKeys + 1) (fromMaybe (panic "no page") (head good.pages)))) >>= (`shouldSatisfy` invalid)
      -- Nothing changed; the good one is taken.
      (\x -> x.keyId) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` spaceKey
      ok =<< refused good
      (\x -> x.keyId) <$> (ok =<< as p.ada (spaceEncryption secret.id)) `shouldReturn` good.keyId

    -- The invariant over random sequences of changes to who reads the
    -- space, each followed by a rotation when one is due: after it, no
    -- grant of the current key names someone who is not a reader with
    -- that public key, and every page key is wrapped by the current key.
    it "keeps every grant of the current key with a reader, over random sequences of changes and rotations" $ do
      for_ [1 .. 3 :: Int] $ \seed -> withEncrypted backing $ \st p secret -> do
        let as :: UserId -> StoredWiki IO a -> IO a
            as u = runStoredWiki st (AsUser u)
        void (ok =<< as p.ada (createSealedPage secret.id (newPage (PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f") Nothing 'a')))
        g <- ok =<< runStoredWiki st Administrator (createGroup "Readers")
        void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectGroup g.id) View True))
        let steps =
              [ void (as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
              , void (as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View False))
              , void (runStoredWiki st Administrator (addMember g.id p.dan))
              , void (runStoredWiki st Administrator (removeMember g.id p.dan))
              , void (runStoredWiki st Administrator (addMember g.id p.bob))
              , void (runStoredWiki st Administrator (removeMember g.id p.bob))
              , void (runStoredWiki st Administrator (setDisabled p.dan True))
              , void (runStoredWiki st Administrator (setDisabled p.dan False))
              , void (as p.ada (setSpaceGrant secret.id (SubjectUser p.cyd) View True))
              ]
            shares = do
              e <- ok =<< as p.ada (spaceEncryption secret.id)
              unless (null e.pending || e.rotationDue) $
                ok =<< as p.ada (grantSpaceKey secret.id NewGrants {keyId = e.keyId, grants = [newGrant m.user m.keyId | m <- e.pending]})
        for_ (take 25 (randomPicks seed (length steps))) $ \i -> do
          fromMaybe pass (atMay steps i)
          shares
          due <- (\x -> x.rotationDue) <$> (ok =<< as p.ada (spaceEncryption secret.id))
          when due (rotateAs st p.ada secret)
          e <- ok =<< as p.ada (spaceEncryption secret.id)
          e.rotationDue `shouldBe` False
          info <- ok =<< as p.ada (rotationInfo secret.id)
          grants <- reading st (runSelectReturningList (select (filter_ (\x -> x.key_id ==. val_ e.keyId.text) (all_ wikiDb.key_grants))))
          let readers = Map.fromList [(m.user.text, m.keyId.text) | m <- info.readers]
          [(x.recipient, x.recipient_key_id) | x <- grants, Map.lookup x.recipient readers /= Just x.recipient_key_id] `shouldBe` []
          keys <- reading st (runSelectReturningList (select (all_ wikiDb.page_keys)))
          [x.key_id | x <- keys, x.space_key_id /= e.keyId.text] `shouldBe` []

  -- Backlinks (WP5.88 of docs/PLAN.md): the server cannot read what an
  -- encrypted page links to, so its pages have no list and are in none.
  it "gives a page of an encrypted space no backlinks, and lists none of its pages among another's" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    target <- ok =<< as p.ada (createPage plain.id Nothing "Target" "")
    source <- ok =<< as p.ada (createPage plain.id Nothing "Source" ("[it](/l/" <> pid.text <> "/), [its path](/secret/" <> slugText made.slug <> ") and [[Target]]"))
    as p.ada (pageBacklinks made.id) `shouldReturn` Right []
    map (\b -> b.page) <$> (ok =<< as p.ada (pageBacklinks target.id)) `shouldReturn` [source.id]
    -- No link is kept for a page of the encrypted space.
    kept <- reading st (runSelectReturningList (select (filter_ (\r -> r.source_id ==. val_ pid.text) (all_ wikiDb.page_links))))
    length kept `shouldBe` 0

  it "refuses every plain path that reads or writes a page's text in an encrypted space, and searches it not" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    -- A page of it other than its home page, which never moves.
    plainPage <- ok =<< as p.ada (createPage plain.id Nothing "Plain page" "Plain text.")
    let refused :: Text -> Either WikiError b -> (Text, Text)
        refused what result = (what, either (\e -> if refusedAsEncrypted (Left e :: Either WikiError ()) then "refused" else show e) (const "done") result)
    results <-
      sequence
        [ refused "list pages" <$> as p.ada (listPages secret.id)
        , refused "page" <$> as p.ada (getPage secret.id [made.slug])
        , refused "create page" <$> as p.ada (createPage secret.id Nothing "A title" "A text")
        , refused "save page" <$> as p.ada (savePage pid made.updatedAt "A title" "A text")
        , refused "move out" <$> as p.ada (movePage pid plain.id Nothing)
        , refused "move in" <$> as p.ada (movePage plainPage.id secret.id Nothing)
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

  -- Item 1 of WP5.74b3: comments, their anchors, and attachments' names
  -- and bytes, kept as the browser encrypted them.
  describe "comments and attachments" $ do
    let pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
        tid = CommentThreadId "1a2b3c4d-5e6f-4a1b-8c2d-3e4f5a6b7c8d"
        cid = CommentId "2b3c4d5e-6f7a-4b2c-9d3e-4f5a6b7c8d9e"
        rid = CommentId "3c4d5e6f-7a8b-4c3d-8e4f-5a6b7c8d9e0f"
        aid = AttachmentId "4d5e6f7a-8b9c-4d4e-9f5a-6b7c8d9e0f1a"
        bid = AttachmentId "5e6f7a8b-9c0d-4e5f-8a6b-7c8d9e0f1a2b"
        pageKeyId = KeyId (bytes16 'p')
        newThreadAs t k = NewSealedThread {id = t, anchor = Just (anchorUnder k 'q'), comment = NewSealedComment {id = cid, content = commentUnder k 'c'}}

    it "keeps a thread, its anchor and its comments as ciphertext, under ids the browser chose, and reads them back" $ withEncrypted backing $ \st p secret -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
      void (ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a')))
      made <- ok =<< as p.ada (openSealedThread pid (newThreadAs tid pageKeyId))
      (made.id, made.anchored, made.anchor, map (\c -> (c.id, c.content)) made.comments) `shouldBe` (tid, True, Just (anchorUnder pageKeyId 'q'), [(cid, commentUnder pageKeyId 'c')])
      replied <- ok =<< as p.ada (sealedReply pid tid NewSealedComment {id = rid, content = commentUnder pageKeyId 'r'})
      replied.content `shouldBe` commentUnder pageKeyId 'r'
      edited <- ok =<< as p.ada (sealedEditComment pid tid rid SealedCommentEdit {content = commentUnder pageKeyId 'e'})
      (edited.content, isJust edited.editedAt) `shouldBe` (commentUnder pageKeyId 'e', True)
      listed <- ok =<< as p.ada (sealedThreads pid)
      map (\t -> (t.id, map (\c -> c.content) t.comments)) listed.threads `shouldBe` [(tid, [commentUnder pageKeyId 'c', commentUnder pageKeyId 'e'])]
      -- The rows every other path reads hold no text of them.
      threadRows <- reading st (runSelectReturningList (select (all_ wikiDb.threads)))
      [(r.quote, r.prefix, r.suffix) | r <- threadRows] `shouldBe` [(Just "", Just "", Just "")]
      commentRows <- reading st (runSelectReturningList (select (all_ wikiDb.comments)))
      map (\r -> r.body) commentRows `shouldBe` ["", ""]
      -- An id that is not a UUID, an id used already, another key than the
      -- page's current one, a ciphertext of the wrong length: refused.
      as p.ada (openSealedThread pid (newThreadAs (CommentThreadId "my-thread") pageKeyId)) >>= (`shouldSatisfy` invalid)
      as p.ada (openSealedThread pid (newThreadAs tid pageKeyId)) >>= (`shouldSatisfy` conflict)
      as p.ada (sealedReply pid tid NewSealedComment {id = rid, content = commentUnder pageKeyId 'r'}) >>= (`shouldSatisfy` conflict)
      as p.ada (sealedReply pid tid NewSealedComment {id = CommentId otherId.text, content = commentUnder (KeyId (bytes16 'o')) 'r'}) >>= (`shouldSatisfy` conflict)
      as p.ada (sealedReply pid tid NewSealedComment {id = CommentId otherId.text, content = SealedComment {keyId = pageKeyId, tag = VersionTag (letters 16 'r'), body = Sealed (Nonce (bytes 12)) (Ciphertext (bytes 8))}}) >>= (`shouldSatisfy` invalid)
      -- Someone else may not write another's comment again.
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) Edit True))
      as p.bob (sealedEditComment pid tid rid SealedCommentEdit {content = commentUnder pageKeyId 'x'}) >>= (`shouldSatisfy` isLeft)
      -- The plain routes that carry a comment's text still refuse; those
      -- that carry none (resolving, deleting) are taken.
      as p.ada (listThreads pid) >>= (`shouldSatisfy` refusedAsEncrypted)
      as p.ada (openThread pid Nothing "A comment") >>= (`shouldSatisfy` refusedAsEncrypted)
      as p.ada (reply pid tid "A reply") >>= (`shouldSatisfy` refusedAsEncrypted)
      as p.ada (editComment pid tid cid "Again") >>= (`shouldSatisfy` refusedAsEncrypted)
      void (ok =<< as p.ada (setResolved pid tid True))
      map (\t -> t.resolved) <$> threadsOf (ok =<< as p.ada (sealedThreads pid)) `shouldReturn` [True]
      ok =<< as p.ada (deleteComment pid tid rid)
      map (\t -> length t.comments) <$> threadsOf (ok =<< as p.ada (sealedThreads pid)) `shouldReturn` [1]
      ok =<< as p.ada (deleteThread pid tid)
      threadsOf (ok =<< as p.ada (sealedThreads pid)) `shouldReturn` []
      sealedRows <- reading st (length <$> runSelectReturningList (select (all_ wikiDb.sealed_comments)))
      sealedRows `shouldBe` 0
      -- A plain space's pages have no encrypted threads.
      plain <- ok =<< as p.ada (createSpace Nothing "Plain")
      plainPage <- ok =<< as p.ada (createPage plain.id Nothing "Plain page" "Plain text.")
      as p.ada (sealedThreads plainPage.id) >>= (`shouldSatisfy` conflict)
      as p.ada (openSealedThread plainPage.id (newThreadAs (CommentThreadId otherId.text) pageKeyId)) >>= (`shouldSatisfy` conflict)

    it "tells of a comment by the page's id alone, with no title, excerpt or mention" $ withEncrypted backing $ \st p secret -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
      void (ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a')))
      void (ok =<< as p.bob (setWatching (WatchSpace secret.id) True))
      earlier <- length . (\n -> n.items) <$> (ok =<< as p.bob notifications)
      void (ok =<< as p.ada (openSealedThread pid (newThreadAs tid pageKeyId)))
      told <- drop earlier . reverse . (\n -> n.items) <$> (ok =<< as p.bob notifications)
      [(n.page, n.thread, n.title, n.excerpt) | n <- told] `shouldBe` [(pid, Just tid, "an encrypted page", "")]

    it "keeps an attachment's name and bytes as ciphertext, under an id the browser chose, and replaces the one it names" $ withEncrypted backing $ \st p secret -> withSystemTempDirectory "sealed-attachment" $ \dir -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
          file = dir </> "upload"
          ciphertext = BS.replicate 40 7
      BS.writeFile file ciphertext
      made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
      stored <- ok =<< as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = aid, meta = metaUnder pageKeyId 'm', replaces = Nothing} file)
      (stored.id, stored.size, stored.meta) `shouldBe` (aid, 40, metaUnder pageKeyId 'm')
      -- Its row has its id for a name and no media type of the file's.
      (row, path) <- ok =<< as p.ada (attachmentFile aid)
      (row.name.text, row.mediaType.text) `shouldBe` (aid.text, "application/octet-stream")
      traverse BS.readFile path `shouldReturn` Just ciphertext
      listed <- ok =<< as p.ada (sealedPageAt secret.id [made.slug])
      map (\a -> (a.id, a.meta)) listed.attachments `shouldBe` [(aid, metaUnder pageKeyId 'm')]
      -- Another, replacing the first.
      void (ok =<< as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = bid, meta = metaUnder pageKeyId 'n', replaces = Just aid} file))
      map (\a -> a.id) . (\x -> x.attachments) <$> (ok =<< as p.ada (sealedPageAt secret.id [made.slug])) `shouldReturn` [bid]
      -- An id that is not a UUID, an id used already, another key, an
      -- attachment replaced that is not the page's: refused.
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = AttachmentId "photo.png", meta = metaUnder pageKeyId 'm', replaces = Nothing} file) >>= (`shouldSatisfy` invalid)
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = bid, meta = metaUnder pageKeyId 'm', replaces = Nothing} file) >>= (`shouldSatisfy` conflict)
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = aid, meta = metaUnder (KeyId (bytes16 'o')) 'm', replaces = Nothing} file) >>= (`shouldSatisfy` conflict)
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = aid, meta = metaUnder pageKeyId 'm', replaces = Just (AttachmentId otherId.text)} file) >>= (`shouldSatisfy` invalid)
      -- A reader who may not edit uploads nothing.
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
      as p.bob (uploadSealedAttachmentFile pid SealedUpload {id = aid, meta = metaUnder pageKeyId 'm', replaces = Nothing} file) >>= (`shouldSatisfy` isLeft)
      -- The plain upload still refuses; deleting needs no text.
      as p.ada (uploadAttachment pid "a.txt" "text/plain" "bytes") >>= (`shouldSatisfy` refusedAsEncrypted)
      ok =<< as p.ada (deleteAttachment bid)
      (\x -> x.attachments) <$> (ok =<< as p.ada (sealedPageAt secret.id [made.slug])) `shouldReturn` []

    -- A comment and an attachment name the key of their page's they are
    -- encrypted with. A renewal gives the page a new current key and keeps
    -- the older ones, wrapped again: what was written before is read with
    -- the older key it names, which the page's keys still list.
    it "reads a comment and an attachment written before a renewal under the key they name, and takes new ones only under the new key" $ withEncrypted backing $ \st p secret -> withSystemTempDirectory "sealed-attachment" $ \dir -> do
      let as :: UserId -> StoredWiki IO a -> IO a
          as u = runStoredWiki st (AsUser u)
          file = dir </> "upload"
      BS.writeFile file (BS.replicate 40 7)
      made <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
      void (ok =<< as p.ada (openSealedThread pid (newThreadAs tid pageKeyId)))
      void (ok =<< as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = aid, meta = metaUnder pageKeyId 'm', replaces = Nothing} file))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
      ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey]))
      void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View False))
      -- Nothing is written while the key must be renewed.
      as p.ada (sealedReply pid tid NewSealedComment {id = rid, content = commentUnder pageKeyId 'r'}) >>= (`shouldSatisfy` renewalRefused)
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = bid, meta = metaUnder pageKeyId 'n', replaces = Nothing} file) >>= (`shouldSatisfy` renewalRefused)
      rotateAs st p.ada secret
      page <- ok =<< as p.ada (sealedPageAt secret.id [made.slug])
      let keyIds = map (\k -> k.keyId) page.pageKeys
      page.pageKey.keyId `shouldNotBe` pageKeyId
      pageKeyId `shouldSatisfy` (`elem` keyIds)
      map (\a -> a.meta.keyId) page.attachments `shouldBe` [pageKeyId]
      threads <- threadsOf (ok =<< as p.ada (sealedThreads pid))
      [(t.anchor, map (\c -> c.content.keyId) t.comments) | t <- threads] `shouldBe` [(Just (anchorUnder pageKeyId 'q'), [pageKeyId])]
      -- The threads come with every key of the page's, the older one among
      -- them, wrapped by the space's new key.
      answered <- ok =<< as p.ada (sealedThreads pid)
      sort (map (\k -> k.keyId) answered.pageKeys) `shouldBe` sort keyIds
      map (\k -> k.spaceKeyId) answered.pageKeys `shouldSatisfy` all (/= spaceKey)
      -- New ones are taken under the page's new key only.
      as p.ada (sealedReply pid tid NewSealedComment {id = rid, content = commentUnder pageKeyId 'r'}) >>= (`shouldSatisfy` conflict)
      void (ok =<< as p.ada (sealedReply pid tid NewSealedComment {id = rid, content = commentUnder page.pageKey.keyId 'r'}))
      as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = bid, meta = metaUnder pageKeyId 'n', replaces = Nothing} file) >>= (`shouldSatisfy` conflict)
      void (ok =<< as p.ada (uploadSealedAttachmentFile pid SealedUpload {id = bid, meta = metaUnder page.pageKey.keyId 'n', replaces = Nothing} file))

  it "tells a watcher of the space that a page was saved, by its id alone, with no title or excerpt" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
    void (ok =<< as p.bob (setWatching (WatchSpace secret.id) True))
    void (ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a')))
    told <- ok =<< as p.bob notifications
    [(n.page, n.title, n.excerpt) | n <- told.items] `shouldBe` [(pid, "an encrypted page", "")]

  it "moves a page within its encrypted space, and refuses a move to or from another space" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
        pid = PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f"
    parent <- ok =<< as p.ada (createSealedPage secret.id (newPage pid Nothing 'a'))
    child <- ok =<< as p.ada (createSealedPage secret.id (newPage otherId Nothing 'b'))
    -- Under another page of the space, and back to the top: the page's key
    -- and versions are as they were.
    moved <- ok =<< as p.ada (movePage child.id secret.id (Just parent.id))
    (moved.space, moved.parent) `shouldBe` (secret.id, Just parent.id)
    back <- ok =<< as p.ada (movePage child.id secret.id Nothing)
    back.parent `shouldBe` Nothing
    read' <- ok =<< as p.ada (sealedPageAt secret.id [child.slug])
    (read'.pageKey, read'.content) `shouldBe` (pageKeyOf, contentOf 'b')
    -- To a plain space: refused, as from one.
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    as p.ada (movePage child.id plain.id Nothing) >>= (`shouldSatisfy` refusedAsEncrypted)

  it "makes a grant sent twice in one request once, and refuses more than 500 at once" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
    ok =<< as p.ada (grantSpaceKey secret.id (grantsOf [newGrant p.bob p.bobKey, newGrant p.bob p.bobKey]))
    grants <- reading st (runSelectReturningList (select (all_ wikiDb.key_grants)))
    sort [g.recipient | g <- grants] `shouldBe` sort [p.ada.text, p.bob.text]
    -- Too many for one request: refused before any is looked at, so that a
    -- browser sends them in parts of at most 500.
    as p.ada (grantSpaceKey secret.id (grantsOf (replicate 501 (newGrant p.bob p.bobKey)))) `shouldReturn` Left (Invalid "At most 500 grants are made at once.")

  it "imports a whole wiki's archive with every space plain, whatever the archive says of their encryption" $
    withPlaceIn backing $ \at -> withStorage defaultConfig at $ \st -> do
      let marked = demoArchive {Export.spaces = [s {encryption = Just spaceKey} | s <- demoArchive.spaces]}
      importArchive st marked >>= (`shouldBe` Right ())
      spaces <- runStoredWiki st Administrator listSpaces
      (length spaces > 0, [s.id | s <- spaces, isJust s.encryption]) `shouldBe` (True, [])
      -- Its pages are read as the plain pages they are.
      blog <- maybe (panic "no blog") pure (find (\s -> s.slug == either (const (panic "slug")) identity (mkSlug "blog")) spaces)
      pages <- ok =<< runStoredWiki st Administrator (listPages blog.id)
      pages `shouldSatisfy` (not . null)

  -- The whole wiki's export holds plain text only: an encrypted space is
  -- left out, with its pages and its grants, and the plain spaces beside
  -- it are there (#209's tests, WP5.74b3 of docs/PLAN.md).
  it "leaves an encrypted space out of the whole wiki's export, with its pages and its grants" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    void (ok =<< as p.ada (createSealedPage secret.id (newPage (PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f") Nothing 'a')))
    void (ok =<< as p.ada (setSpaceGrant secret.id (SubjectUser p.bob) View True))
    plain <- ok =<< as p.ada (createSpace Nothing "Plain")
    archive <- ok =<< exportArchive st "test"
    let spaceIds = map (\s -> s.id) archive.spaces
    (secret.id `elem` spaceIds, plain.id `elem` spaceIds) `shouldBe` (False, True)
    [x.id | x <- archive.pages, x.space == secret.id] `shouldBe` []
    [g | g <- archive.grants.spaces, g.space == secret.id] `shouldBe` []

  it "refuses an import whose spaces would land in an encrypted space, or under it" $ withEncrypted backing $ \st _ secret -> do
    -- The demo's spaces, one of them at the encrypted space's address.
    let top = [s | s <- demoArchive.spaces, isNothing s.parent]
        moved = fromMaybe (panic "no top-level space in the demo") (head top)
        archive = demoArchive {Export.spaces = [if s.id == moved.id then s {Space.slug = secret.slug} else s | s <- demoArchive.spaces]}
    blocked <- reading st (intoEncrypted archive)
    blocked `shouldContain` [[secret.slug]]
    -- The demo's own addresses land in no encrypted space.
    reading st (intoEncrypted demoArchive) `shouldReturn` []

  -- The sitemap lists the pages of the spaces the reader may view, by
  -- their slugs, which are random in an encrypted space; nobody else gets
  -- the space at all.
  it "lists an encrypted space's pages in the sitemap by their random slugs, to its members only" $ withEncrypted backing $ \st p secret -> do
    let as :: UserId -> StoredWiki IO a -> IO a
        as u = runStoredWiki st (AsUser u)
    made <- ok =<< as p.ada (createSealedPage secret.id (newPage (PageId "6f1c9a2e-8b4d-4c3f-9e7a-1d2b3c4d5e6f") Nothing 'a'))
    mine <- as p.ada sitemapPages
    map (\n -> (n.id, n.slug)) (Map.findWithDefault [] secret.id mine) `shouldBe` [(made.id, made.slug)]
    Map.member secret.id <$> as p.dan sitemapPages `shouldReturn` False
    Map.member secret.id <$> runStoredWiki st Anonymous sitemapPages `shouldReturn` False

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
withPeople = withPeopleIn defaultConfig

-- | 'withPeople', on a storage of this configuration.
withPeopleIn :: Config -> Backing -> (Storage -> People -> IO a) -> IO a
withPeopleIn config backing action = withPlaceIn backing $ \at -> withStorage config at $ \st -> do
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
withEncrypted backing action = withPeople backing $ \st p -> encryptedOf st p >>= action st p

-- | Ada's encrypted space, made.
encryptedOf :: Storage -> People -> IO Space
encryptedOf st p = do
  s <- privateSpace st p.ada "Secret"
  ok =<< runStoredWiki st (AsUser p.ada) (encryptSpace s.id (encryptAs p.ada p.adaKey))

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

-- | A version encrypted with a page key, its ciphertexts made of a letter:
-- a page's first version.
contentUnder :: KeyId -> Char -> SealedContent
contentUnder k c =
  SealedContent
    { tag = VersionTag (bytes16 c)
    , keyId = k
    , chain = Just firstChain
    , title = Sealed (Nonce (bytes16' 12)) (Ciphertext (bytes16' 40))
    , body = Sealed (Nonce (bytes16' 12)) (Ciphertext (bytes16' 200))
    }
  where
    bytes16' n = toBase64Url (BS.replicate n (fromIntegral (ord c)))

-- | A version made of a letter, saved on top of another.
savedOn :: SealedContent -> Char -> SealedContent
savedOn previous c = chainedAs (Just (chainAfter previous.tag previous.chain)) (contentOf c)

-- | A version with another chain.
chainedAs :: Maybe Chain -> SealedContent -> SealedContent
chainedAs chain x = SealedContent {tag = x.tag, keyId = x.keyId, chain, title = x.title, body = x.body}

-- | The threads of an answer of the encrypted threads' route.
threadsOf :: IO SealedThreads -> IO [SealedThread]
threadsOf = fmap (\x -> x.threads)

-- | A comment encrypted with a page key, its ciphertexts made of a letter.
commentUnder :: KeyId -> Char -> SealedComment
commentUnder k c = SealedComment {keyId = k, tag = VersionTag (letters 16 c), body = Sealed (Nonce (letters 12 c)) (Ciphertext (letters 60 c))}

-- | An anchor encrypted with a page key, made of a letter.
anchorUnder :: KeyId -> Char -> SealedAnchor
anchorUnder k c = SealedAnchor {keyId = k, anchor = Sealed (Nonce (letters 12 c)) (Ciphertext (letters 50 c))}

-- | An attachment's name and media type encrypted with a page key, and the
-- nonce of its bytes, made of a letter.
metaUnder :: KeyId -> Char -> SealedMeta
metaUnder k c = SealedMeta {keyId = k, meta = Sealed (Nonce (letters 12 c)) (Ciphertext (letters 40 c)), bytesNonce = Nonce (letters 12 c)}

-- | So many bytes of a letter, in base64url.
letters :: Int -> Char -> Text
letters n c = toBase64Url (BS.replicate n (fromIntegral (ord c)))

newPage :: PageId -> Maybe PageId -> Char -> NewSealedPage
newPage pid parent c = NewSealedPage {id = pid, parent, pageKey = pageKeyOf, content = contentOf c}

otherId :: PageId
otherId = PageId "0d9e8f7a-6b5c-4d3e-8f1a-2b3c4d5e6f70"

--------------------------------------------------------------------------------
-- Rotations

-- | Bob reads the space through a group: the group's grant, and Bob in it,
-- in place of his own grant.
byGroup :: Storage -> People -> Space -> IO Group
byGroup st p s = do
  g <- ok =<< runStoredWiki st Administrator (createGroup "Readers")
  void (ok =<< runStoredWiki st Administrator (addMember g.id p.bob))
  void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectGroup g.id) View True))
  void (ok =<< runStoredWiki st (AsUser p.ada) (setSpaceGrant s.id (SubjectUser p.bob) View False))
  pure g

-- | A rotation as a browser would send it, from what the server lists: a
-- new key (its id made of the number given), sealed to every reader, every
-- page key wrapped again, and a new key for each page, of made-up bytes.
rotationOf :: Int -> RotationInfo -> Rotation
rotationOf n info =
  Rotation
    { from = info.keyId
    , keyId = newKey
    , grants = [newGrant m.user m.keyId | m <- info.readers]
    , pages =
        [ RotatedPage {page = x.page, current = pageKeyOf {keyId = KeyId (numbered (n * 1000 + i)), spaceKeyId = newKey}, rewrapped = [k {spaceKeyId = newKey} | k <- x.keys]}
        | (i, x) <- zip [1 ..] info.pages
        ]
    }
  where
    newKey = KeyId (numbered n)

-- | 16 bytes in base64url, made of a number.
numbered :: Int -> Text
numbered n = toBase64Url (BS.pack (map (\i -> fromIntegral ((toInteger n `div` (256 ^ i)) `mod` 256)) [0 .. 15 :: Int]))

-- | Rotate the space's key as someone, as their browser would.
rotateAs :: Storage -> UserId -> Space -> IO ()
rotateAs st u s = do
  info <- ok =<< runStoredWiki st (AsUser u) (rotationInfo s.id)
  used <- reading st (length <$> runSelectReturningList (select (all_ wikiDb.page_keys)))
  ok =<< runStoredWiki st (AsUser u) (rotateSpaceKey s.id (rotationOf (100 + used) info))

-- | So many numbers below a bound, from a seed: a linear congruential
-- generator, so that a sequence that fails is the same on the next run.
randomPicks :: Int -> Int -> [Int]
randomPicks seed bound = map (\x -> (x `div` 65536) `mod` bound) (drop 1 (iterate (\x -> (x * 1103515245 + 12345) `mod` 2147483648) seed))

-- | Whether a write was refused while the space's key must be renewed.
renewalRefused :: Either WikiError a -> Bool
renewalRefused = \case
  Left (Conflict why) -> "key must be renewed" `T.isInfixOf` why
  _ -> False

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
