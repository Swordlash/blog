-- | Removing a user's account (WP5.25 of docs/PLAN.md), as the storage
-- does it: the account goes with everything that belongs to it, the page
-- versions and comments the user wrote stay under their login, the login
-- is free again, the activity log records the removal, and the console's
-- @wiki-server users remove@ does the same. The rules every backend keeps
-- (who may, and which accounts) are the contract's
-- ("Wiki.App.Backend.Contract.Admin").
module Test.Storage.Removal (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (val_, (&&.), (==.))
import Protolude
import Test.Database (Backing, placeOptionsOf)
import Test.Hspec
import Test.Storage.Fixture (countWhere, ok, path, tableRows, withDemo, withPlaceIn)
import Wiki.Api.Account (Account (..))
import Wiki.Api.Notifications (Notifications (..))
import Wiki.Api.Vault (NewPublicKey (..), PasskeyInfo (..), VaultChange (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (removeUser, setCreateSpaces))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.Core.Assistant.Vault (Item (..), KeyId (..), PublicKey (..), Sealed (..), Unlock (..), Vault (..), WrappedKey (..), identityItem, vaultFormat, withItem, withSealed)
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, formerAuthor)
import Wiki.Core.Id (SpaceId (..), UserId (..))
import Wiki.Core.Notification (Notification (..), WatchTarget (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Password (..), User (..))
import Wiki.Core.Version (Author (..), VersionInfo (..), latestVersions)
import Wiki.Server.Accounts (createAccount, setDisabled, setPassword, signInUser)
import Wiki.Server.Console (Users (..), UsersCommand (..), runUsers)
import Wiki.Server.SecondFactor (enrol)
import Wiki.Server.Storage (Storage, Who (..), defaultConfig, reading, runStoredWiki, userByLogin, withStorage)
import Wiki.Server.Storage.Rows (permissionsGeneration)
import Wiki.Server.Storage.Schema (AuditLog (..), Pages (..), Spaces (..), WikiDb (..), wikiDb)
import Wiki.Server.Vault (keyIdOf, registerPasskey, storeVault)
import Wiki.Server.WebAuthn (NewCredential (..))

spec :: Backing -> Spec
spec backing = describe "removing an account" $ do
  it "deletes the account with what belongs to it, and keeps what they wrote under their login" $ withDemo backing $ \st -> do
    editor <- userNamed st "editor"
    adminId <- (\u -> u.id) <$> userNamed st "admin"
    let u = editor.id
        asEditor :: (forall m. (MonadWiki m, MonadComments m, MonadNotifications m, MonadStars m) => m a) -> IO a
        asEditor program = runStoredWiki st (AsUser u) program
        asAdmin :: (forall m. (MonadWiki m, MonadAdmin m, MonadComments m, MonadNotifications m) => m a) -> IO a
        asAdmin program = runStoredWiki st (AsUser adminId) program
    now <- getCurrentTime
    -- Everything a user can have: a session, a second factor, a passkey
    -- and the vault it opens (with their key pair, whose public key is in
    -- the directory), a draft, a watch and its notification, a star, a
    -- membership (the demo's writers) and grants of their own. And the
    -- administrator watches the blog, for notifications of what the user
    -- did there.
    void (ok =<< setPassword st u (Password "editor's password"))
    signInUser st now "127.0.0.1" u >>= either (const (expectationFailure "the editor does not sign in")) (const pass)
    void (ok =<< enrol st now u)
    passkey <- ok =<< registerPasskey st now u Nothing NewCredential {credentialId = "a passkey", publicKey = "its public key", algorithm = -7, signCount = 0}
    let vault = withSealed Sealed {nonce = "bm9uY2UtMTJieXRl", ciphertext = "c2VhbGVk"} Vault {format = vaultFormat, salt = "c2FsdC1vZi10aGlydHktdHdvLWJ5dGVzLWZvci1wcmY", items = mempty, wraps = Map.singleton (ByPasskey passkey.id) (WrappedKey "bm9uY2UtMTJieXRl" "YSB2YXVsdCBrZXkgd3JhcHBlZCwgYW5kIHRoZSB0YWcgb2YgaXRzIHdyYXBwaW5n")}
    let key = PublicKey "YW4gWDI1NTE5IHB1YmxpYyBrZXksIDMyIGJ5dGVzISE"
        keyId = fromMaybe (KeyId "") (keyIdOf key)
        pair = Item {keyId = Just keyId, sealed = Sealed {nonce = "bm9uY2UtMTJieXRl", ciphertext = "YSBrZXkgcGFpciBzZWFsZWQ6IGl0cyBwa2NzOCBhbmQgaXRzIHRhZywgc2l4dHktZm91ciBieXRlcyBvZiBpdA"}}
    void (ok =<< storeVault st now u Nothing VaultChange {vault = withItem identityItem pair vault, publicKey = Just NewPublicKey {keyId, publicKey = key}})
    blog <- ok =<< asEditor (getSpace (path "blog"))
    void (ok =<< asAdmin (setWatching (WatchSpace blog.id) True))
    made <- ok =<< asEditor (createPage blog.id Nothing "Field notes" "First words.")
    saved <- ok =<< asEditor (savePage made.id made.updatedAt "Field notes" "Second words.")
    void (ok =<< asEditor (saveDraft saved.id saved.updatedAt "Field notes" "Words not saved yet."))
    void (ok =<< asEditor (openThread saved.id Nothing "A note on these notes."))
    void (ok =<< asEditor (setWatching (WatchSpace blog.id) True))
    void (ok =<< asEditor (setStarred saved.id True))
    latest <- ok =<< asAdmin (savePage saved.id saved.updatedAt "Field notes" "The administrator's words.")
    void (ok =<< asAdmin (setSpaceGrant blog.id (SubjectUser u) AdministerSpace True))
    void (ok =<< asAdmin (setCreateSpaces u True))
    tablesMentioning u.text st
      `shouldReturn` [ "audit_log"
                     , "comments"
                     , "drafts"
                     , "global_grants"
                     , "group_members"
                     , "notifications"
                     , "page_versions"
                     , "passkeys"
                     , "public_keys"
                     , "sessions"
                     , "space_grants"
                     , "stars"
                     , "totp"
                     , "users"
                     , "vault_items"
                     , "vaults"
                     , "watches"
                     ]
    -- An enabled login is refused, and nothing changes.
    asAdmin (removeUser u) >>= \case
      Left (Conflict _) -> pass
      other -> expectationFailure ("expected a conflict, got " <> show other)
    void (ok =<< setDisabled st u True)
    -- Read as the user, so that the permission context of this generation
    -- is kept in memory.
    void (asEditor session)
    generation <- reading st permissionsGeneration
    ok =<< asAdmin (removeUser u)
    -- The removal bumped the generation, so the next read does not take
    -- the context kept before it: the user is nobody, and their grant on
    -- the blog is gone.
    reading st permissionsGeneration >>= (`shouldSatisfy` (> generation))
    (\s -> s.user) <$> asEditor session `shouldReturn` Nothing
    asEditor (spaceAccess blog.id) >>= (`shouldSatisfy` isLeft)
    -- Only the activity log still names the account's id: what it says
    -- happened stays true.
    tablesMentioning u.text st `shouldReturn` ["audit_log"]
    userByLogin st "editor" `shouldReturn` Nothing
    reading st (countWhere wikiDb.audit_log (\a -> a.action ==. val_ "user.remove" &&. a.subject_name ==. val_ "editor" &&. a.subject_id ==. val_ (Just u.text)))
      `shouldReturn` 1
    -- The page and what the user wrote on it stay, under their login.
    let former = absentAuthor (formerAuthor "editor")
        authors = map (\v -> (\a -> a.name) <$> v.author) <$> (ok =<< asAdmin (listVersions saved.id latestVersions))
    authors `shouldReturn` [Just "Ada Admin", Just former.name, Just former.name]
    (\ts -> [c.author | t <- ts, c <- t.comments]) <$> (ok =<< asAdmin (listThreads saved.id))
      `shouldReturn` [former]
    -- The administrator's notifications of what the user did stay, by the
    -- name they had, under their login.
    told <- (\n -> n.items) <$> (ok =<< asAdmin notifications)
    told `shouldNotBe` []
    [(a.id, a.name) | x <- told, let { a = x.actor }] `shouldBe` [(formerAuthor "editor", editor.displayName) | _ <- told]
    (\p -> p.updatedAt) <$> (ok =<< asAdmin (getPage blog.id (path "field-notes"))) `shouldReturn` latest.updatedAt
    -- The login is free again, for an account that is someone else.
    again <- ok =<< createAccount st "editor" "Another editor" (Just (Password "another password"))
    again.user.id `shouldNotBe` u
    authors `shouldReturn` [Just "Ada Admin", Just former.name, Just former.name]

  it "deletes their personal space with the account" $ withDemo backing $ \st -> do
    editor <- userNamed st "editor"
    adminId <- (\u -> u.id) <$> userNamed st "admin"
    mine <- ok =<< runStoredWiki st (AsUser editor.id) (setPersonalSpace True)
    void (ok =<< runStoredWiki st (AsUser editor.id) (createPage mine.id Nothing "Notes" "Mine."))
    void (ok =<< setDisabled st editor.id True)
    ok =<< runStoredWiki st (AsUser adminId) (removeUser editor.id)
    runStoredWiki st (AsUser adminId) (getSpace (path "users/editor")) `shouldReturn` Left NotFound
    reading st (countWhere wikiDb.spaces (\s -> s.id ==. val_ mine.id.text)) `shouldReturn` 0
    reading st (countWhere wikiDb.pages (\p -> p.space_id ==. val_ mine.id.text)) `shouldReturn` 0
    reading st (countWhere wikiDb.audit_log (\a -> a.action ==. val_ "user.remove" &&. a.subject_name ==. val_ "editor"))
      `shouldReturn` 1

  it "is the console's users remove, which asks for the login to be disabled first" $
    withPlaceIn backing $ \at -> do
      let run command = runUsers (\_ -> pure (Left "not asked")) Users {place = placeOptionsOf at, command}
      withStorage defaultConfig at $ \st -> void (ok =<< createAccount st "bea" "Bea" (Just (Password "bea's password")))
      run (RemoveUser "bea") >>= \case
        Left why -> why `shouldSatisfy` T.isInfixOf "disable the login first"
        Right said -> expectationFailure ("expected a refusal, got " <> show said)
      void (run (SetUserDisabled "bea" True))
      run (RemoveUser "bea") >>= \case
        Right [said] -> said `shouldSatisfy` T.isInfixOf "is removed"
        other -> expectationFailure ("expected the account removed, got " <> show other)
      run (RemoveUser "bea") `shouldReturn` Left "There is no user with the login bea."
      run ListUsers >>= \case
        Right listed -> listed `shouldSatisfy` any (T.isInfixOf "There are no users yet")
        Left why -> expectationFailure (toS why)
  where
    userNamed st login = userByLogin st login >>= maybe (panic ("no user " <> login)) pure

-- | The tables of which a row holds this text, by name.
tablesMentioning :: Text -> Storage -> IO [Text]
tablesMentioning text st = sort . map fst . filter (any (T.isInfixOf text) . snd) <$> tableRows st
