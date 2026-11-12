-- | @wiki-server copy-database@ (WP5.80a of docs/PLAN.md): a wiki in SQLite
-- copied into the backing's database (on the SQLite group into another
-- SQLite file, on the PostgreSQL group into PostgreSQL), and the backing's
-- copied into SQLite; every table compared, row by row, with the source's;
-- and the copies refused. The tables are compared through a list of this
-- module's own, not the copy's, and that list and the copy's are each
-- compared with the tables a migrated database holds.
module Test.Storage.Copy
  ( unitSpec
  , spec
  )
where

import Data.List ((\\))
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, picosecondsToDiffTime)
import Database.Beam (Beamable, DatabaseEntity, FromBackendRow, QExpr, TableEntity, aggregate_, all_, default_, filter_, insert, insertExpressions, insertValues, max_, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (<-.), (==.))
import Database.SQLite.Simple qualified as SQLite
import Protolude
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing (..), choiceOf, placeOptionsOf, withConnectionTo, withEmptyPlace, withPlace)
import Test.Hspec
import Test.Storage.Fixture (decodableRecord, demoArchive, ok)
import Wiki.Server.CopyDatabase (CopyOptions (..), CopyOutcome (..), release, reserve, runCopy)
import Wiki.Server.Storage (Checked (..), Place (..), checkDatabase, defaultConfig, importArchive, inDataDir, withStorage, writing)
import Wiki.Server.Storage.Backend (Backend (..), Sqlite)
import Wiki.Server.Storage.Backup (lockDataDir, unlockDataDir)
import Wiki.Server.Storage.Copy (copiedName, copiedTables, parentsFirst)
import Wiki.Server.Storage.Layout (Database (..))
import Wiki.Server.Storage.Migrate (applySteps, migrate, stepsFor)
import Wiki.Server.Storage.Schema
import Wiki.Server.WaysIn (WaysIn (..))

-- | What needs no database: the order of a tree's rows, and the list of
-- tables.
unitSpec :: Spec
unitSpec = describe "copy-database" $ do
  it "writes a tree's rows after the rows they are under, and a row it cannot place last" $
    parentsFirst [("c", Just "b"), ("b", Just "a"), ("a", Nothing), ("x", Just "gone"), ("l1", Just "l2"), ("l2", Just "l1")]
      `shouldBe` ["a", "x", "b", "c", "l1", "l2"]
  it "names each table once" $
    let names = map copiedName copiedTables in ordNub names `shouldBe` names
  it "names in the comparison's list the tables the copy names" $
    sort (map fst (comparedTables @Sqlite)) `shouldBe` sort (map copiedName copiedTables)

-- | The copies, with the backing as the target (and as the source of the
-- copy into SQLite).
spec :: Backing -> Spec
spec backing = describe "copy-database" $ do
  it "copies every table of the schema but wiki_schema" $
    withSystemTempDirectory "wiki-copy" $ \dir -> withEmptyPlace backing dir $ \at -> do
      tables <- withConnectionTo at $ \c -> migrate c >> runDb c tableNames
      sort (map copiedName copiedTables) `shouldBe` sort (tables \\ ["wiki_schema"])

  it "copies a wiki in SQLite with rows in every table, each table the same as the source's" $
    withSqliteWiki $ \source -> withTarget $ \target -> do
      original <- withConnectionTo source (\c -> runDb c everyRow)
      [t | (t, []) <- original] `shouldBe` []
      outcome <- runCopy (copying source target)
      outcome `shouldSatisfy` isCopied
      copied <- withConnectionTo target (\c -> runDb c everyRow)
      for_ (zip original copied) $ \((t, rows), (t', rows')) -> do
        t' `shouldBe` t
        (t, rows') `shouldBe` (t, rows)
      withConnectionTo source (\c -> runDb c everyRow) `shouldReturn` original
      checkDatabase target >>= either (\p -> expectationFailure ("the copy does not check: " <> show p)) (const pass)

  -- An account with no way in (the demo's, which have no password) is
  -- what the check says of a wiki, never why it refuses one (WP5.85).
  it "copies a wiki whose accounts have no way in, and the copy's check says the same of them" $
    withSqliteWiki $ \source -> withTarget $ \target -> do
      fromSource <- checkDatabase source >>= either (\p -> panic ("the source does not check: " <> show p)) pure
      fromSource.ways.none `shouldSatisfy` (not . null)
      runCopy (copying source target) >>= (`shouldSatisfy` isCopied)
      inCopy <- checkDatabase target >>= either (\p -> panic ("the copy does not check: " <> show p)) pure
      inCopy.ways `shouldBe` fromSource.ways

  it "gives a row made after the copy an id past the copied ones" $
    withSqliteWiki $ \source -> withTarget $ \target -> do
      runCopy (copying source target) >>= (`shouldSatisfy` isCopied)
      withConnectionTo target $ \c -> do
        let largestGlobal = runDb c (largestOf (\r -> r.seq) wikiDb.global_grants)
            largestSpace = runDb c (largestOf (\r -> r.seq) wikiDb.space_grants)
            largestNotification = runDb c (largestOf (\r -> r.seq) wikiDb.notifications)
        globalBefore <- largestGlobal
        spaceBefore <- largestSpace
        notificationBefore <- largestNotification
        globalBefore `shouldBe` 1000
        runDb c $ do
          runInsert (insert wikiDb.global_grants (insertExpressions [GlobalGrantRow {seq = default_, subject_kind = val_ "group", subject_id = val_ "copy-g1", permission = val_ "create-spaces"}]))
          runInsert (insert wikiDb.space_grants (insertExpressions [SpaceGrantRow {seq = default_, space_id = val_ "copy-space", subject_kind = val_ "group", subject_id = val_ "copy-g1", permission = val_ "view"}]))
          runInsert (insert wikiDb.notifications (insertExpressions [notificationOf default_ "copy-n2"]))
        largestGlobal `shouldReturn` globalBefore + 1
        largestSpace `shouldReturn` spaceBefore + 1
        largestNotification `shouldReturn` notificationBefore + 1

  it "copies the backing's wiki into SQLite" $
    withSystemTempDirectory "wiki-copy-source" $ \dir -> withPlace backing dir $ \source -> do
      fill source
      withSystemTempDirectory "wiki-copy-target" $ \out -> do
        let target = inDataDir out
        original <- withConnectionTo source (\c -> runDb c everyRow)
        runCopy (copying source target) >>= (`shouldSatisfy` isCopied)
        withConnectionTo target (\c -> runDb c everyRow) `shouldReturn` original

  it "refuses a source at another version of the schema, and says to migrate it" $
    withSystemTempDirectory "wiki-copy" $ \dir -> withTarget $ \target -> do
      let source = inDataDir dir
          file = fileOf source
      SQLite.withConnection file $ \c -> void (applySteps (take 3 (stepsFor "sqlite")) c)
      runCopy (copying source target) >>= \case
        CopyNotMigrated why -> why `shouldSatisfy` T.isInfixOf "wiki-server migrate"
        other -> expectationFailure ("not refused as not migrated: " <> show other)
      tablesOf target `shouldReturn` []

  it "refuses a target that is not empty, and leaves it as it was" $
    withSqliteWiki $ \source -> withSystemTempDirectory "wiki-copy-target" $ \dir -> withPlace backing dir $ \target -> do
      _ <- withConnectionTo target migrate
      original <- withConnectionTo target (\c -> runDb c everyRow)
      runCopy (copying source target) >>= \case
        CopyRefused why -> why `shouldSatisfy` (\w -> T.isInfixOf "not empty" w || T.isInfixOf "already" w)
        other -> expectationFailure ("not refused: " <> show other)
      withConnectionTo target (\c -> runDb c everyRow) `shouldReturn` original

  it "refuses a SQLite file that is there already, and leaves it and its database alone" $
    withSystemTempDirectory "wiki-copy-source" $ \dir -> withPlace backing dir $ \source -> do
      fill source
      withSystemTempDirectory "wiki-copy-target" $ \out -> do
        -- Another wiki's database, at the path the copy is told to make.
        let other = inDataDir out
        fill other
        original <- withConnectionTo other (\c -> runDb c everyRow)
        runCopy (copying source other) >>= \case
          CopyRefused why -> why `shouldSatisfy` T.isInfixOf "already"
          outcome -> expectationFailure ("not refused: " <> show outcome)
        withConnectionTo other (\c -> runDb c everyRow) `shouldReturn` original

  it "deletes when it fails only the SQLite file it made, not one put in its place meanwhile" $
    withSystemTempDirectory "wiki-copy-target" $ \out -> do
      let file = out </> "copy.sqlite"
      made <- reserve file >>= either (\o -> panic ("not reserved: " <> show o)) pure
      -- Another process's database at the path, after the copy made its
      -- file there: the copy's file is gone, and this one is not it.
      removeFile file
      writeFile file "another database"
      release made
      readFile file `shouldReturn` "another database"
      -- The file the copy made is deleted, with SQLite's files beside it.
      removeFile file
      mine <- reserve file >>= either (\o -> panic ("not reserved: " <> show o)) pure
      writeFile (file <> "-wal") ""
      release mine
      doesFileExist file `shouldReturn` False
      doesFileExist (file <> "-wal") `shouldReturn` False

  it "refuses a source a server is running on" $
    withSqliteWiki $ \source -> withTarget $ \target ->
      bracket (lockDataDir source.dataDir >>= either (panic . ("cannot lock: " <>)) pure) unlockDataDir $ \_ -> do
        runCopy (copying source target) >>= \case
          CopyRefused why -> why `shouldSatisfy` T.isInfixOf "A server is running"
          other -> expectationFailure ("not refused: " <> show other)
        tablesOf target `shouldReturn` []

  it "refuses a source that is not there, and makes no file of it" $
    withSystemTempDirectory "wiki-copy" $ \dir -> withTarget $ \target -> do
      runCopy (copying (inDataDir dir) target) >>= (`shouldSatisfy` \case CopyRefused _ -> True; _ -> False)
      doesFileExist (dir </> "wiki.sqlite") `shouldReturn` False

  it "stops at a row the target refuses, names it by its key, and leaves the target empty" $
    withSqliteWiki $ \source -> withTarget $ \target -> do
      -- A session of a user who is not there: SQLite took it with its
      -- foreign keys off, and the target refuses it.
      let file = fileOf source
      SQLite.withConnection file $ \c -> do
        SQLite.execute_ c "PRAGMA foreign_keys = OFF"
        runDb c (runInsert (insert wikiDb.sessions (insertValues [SessionRow {id_hash = "copy-orphan", user_id = "nobody", created_at = time 0, last_seen_at = time 0, expires_at = time 9, public_id = "copy-orphan-public", address = "127.0.0.1"}])))
      runCopy (copying source target) >>= \case
        CopyFailed why -> do
          why `shouldSatisfy` T.isInfixOf "id_hash = \"copy-orphan\""
          why `shouldSatisfy` T.isInfixOf "sessions"
        other -> expectationFailure ("not refused: " <> show other)
      tablesOf target `shouldReturn` []

  it "cuts a time finer than a microsecond to the microsecond, and says so" $
    withSqliteWiki $ \source -> withTarget $ \target -> do
      let fine = addUTCTime 0.000000789 (time 0)
      SQLite.withConnection (fileOf source) $ \c ->
        runDb c (runInsert (insert wikiDb.sessions (insertValues [SessionRow {id_hash = "copy-fine", user_id = "copy-u1", created_at = fine, last_seen_at = time 0, expires_at = time 9, public_id = "copy-fine-public", address = "127.0.0.1"}])))
      runCopy (copying source target) >>= \case
        Copied lines' -> lines' `shouldSatisfy` elem "sessions: 2 rows, 1 of them with a time cut to the microsecond"
        other -> expectationFailure ("not copied: " <> show other)
      times <- withConnectionTo target $ \c -> runDb c (runSelectReturningList (select ((\s -> s.created_at) <$> filter_ (\s -> s.id_hash ==. val_ "copy-fine") (all_ wikiDb.sessions))))
      times `shouldBe` [time 0]

  it "refuses a text PostgreSQL cannot keep, naming the row" $ case backing of
    OnSqlite -> pendingWith "SQLite keeps the character NUL in a text: only PostgreSQL refuses it"
    _ -> withSqliteWiki $ \source -> withTarget $ \target -> do
      let file = fileOf source
      SQLite.withConnection file $ \c ->
        runDb c (runInsert (insert wikiDb.settings (insertValues [SettingRow {key = "copy-nul", value = "a\0b"}])))
      runCopy (copying source target) >>= \case
        CopyFailed why -> do
          why `shouldSatisfy` T.isInfixOf "key = \"copy-nul\""
          why `shouldSatisfy` T.isInfixOf "NUL"
        other -> expectationFailure ("not refused: " <> show other)
      tablesOf target `shouldReturn` []
  where
    -- A target on the backing: an empty database, made for the example.
    withTarget :: (Place -> IO a) -> IO a
    withTarget act = withSystemTempDirectory "wiki-copy-target" $ \dir -> withEmptyPlace backing dir act

-- | A wiki in SQLite, in a data directory of its own, with rows in every
-- table.
withSqliteWiki :: (Place -> IO a) -> IO a
withSqliteWiki act = withSystemTempDirectory "wiki-copy-source" $ \dir -> do
  let source = inDataDir dir
  fill source
  act source

-- | Fill a place with the demo's wiki, and a row of this module's own in
-- every table.
fill :: Place -> IO ()
fill at = withStorage defaultConfig at $ \st -> do
  _ <- importArchive st demoArchive >>= ok
  writing st everyTable

-- | The options of a copy of a place's database into another's.
copying :: Place -> Place -> CopyOptions
copying source target = CopyOptions {place = placeOptionsOf source, target = choiceOf target.database}

isCopied :: CopyOutcome -> Bool
isCopied = \case
  Copied _ -> True
  _ -> False

-- | A SQLite place's file.
fileOf :: Place -> FilePath
fileOf at = case at.database of
  SqliteFile file -> file
  PostgresAt _ -> panic "a SQLite place was expected"

-- | The largest number of a column of numbers, 0 for none.
largestOf :: (Backend be, Beamable t) => (forall s. t (QExpr be s) -> QExpr be s Int64) -> DatabaseEntity be WikiDb (TableEntity t) -> Db be Int64
largestOf column entity = fromMaybe 0 . join <$> runSelectReturningOne (select (aggregate_ (\r -> max_ (column r)) (all_ entity)))

-- | The tables a place's database holds.
tablesOf :: Place -> IO [Text]
tablesOf at = withConnectionTo at (\c -> runDb c tableNames)

-- | A time of the rows written here, to the microsecond, as the storage
-- writes times: noon and a fraction on a day of 2026, and so many hours
-- later.
time :: Int -> UTCTime
time hours = addUTCTime (fromIntegral (hours * 3600)) (UTCTime (fromGregorian 2026 11 10) (picosecondsToDiffTime 43200123456000000))

-- | A notification of this module's, numbered by the database, for a row
-- made after the copy.
notificationOf :: (Backend be) => QExpr be s Int64 -> Text -> Notifications (QExpr be s)
notificationOf number i =
  NotificationRow
    { seq = number
    , id = val_ i
    , user_id = val_ "copy-u1"
    , kind = val_ "changed"
    , page_id = val_ "copy-page"
    , thread_id = val_ Nothing
    , actor = val_ "copy-u2"
    , actor_name = val_ "Copy Two"
    , title = val_ "Copied"
    , excerpt = val_ ""
    , created_at = val_ (time 5)
    , read_at = val_ Nothing
    , mail = val_ False
    }

-- | A row in every table of the schema, beside the demo's: accounts with a
-- password, an OPAQUE record and a second factor, a group with grants, a
-- space with a subspace and an encrypted one, pages in a tree with
-- versions, drafts, attachments and comments, the vault, the keys, and the
-- rest. A sequence's numbers leave gaps, as deleted rows leave them.
everyTable :: (Backend be) => Db be ()
everyTable = do
  let row entity rows = runInsert (insert entity (insertValues rows))
  row
    wikiDb.users
    [ UserRow {id = "copy-u1", login = "copy.one", display_name = "Copy Ünë", password_hash = Just "$argon2id$v=19$m=65536,t=3,p=1$c2FsdA$aGFzaA", disabled = False, email = Just "one@example.org", email_verified_at = Just (time 1), notification_mail = Just "daily", watch_own = True, feed_token = Just "copy-feed", avatar_blob = Nothing, avatar_media_type = Nothing, opaque_record = Just decodableRecord, opaque_stretch = Just "t=3,m=65536"}
    , UserRow {id = "copy-u2", login = "copy.two", display_name = "Copy Two", password_hash = Nothing, disabled = True, email = Nothing, email_verified_at = Nothing, notification_mail = Nothing, watch_own = False, feed_token = Nothing, avatar_blob = Just "0123abcd", avatar_media_type = Just "image/png", opaque_record = Nothing, opaque_stretch = Nothing}
    ]
  row wikiDb.groups [GroupRow {id = "copy-g1", name = "Copiers"}]
  row wikiDb.group_members [MemberRow {group_id = "copy-g1", user_id = "copy-u1"}]
  row wikiDb.global_grants [GlobalGrantRow {seq = 1000, subject_kind = "user", subject_id = "copy-u1", permission = "administer"}]
  row
    wikiDb.spaces
    [ space "copy-space" Nothing "copy-space" Nothing Nothing
    , space "copy-sub" (Just "copy-space") "copy-sub" Nothing Nothing
    , space "copy-sealed" Nothing "copy-sealed" Nothing (Just "copy-space-key")
    ]
  row wikiDb.space_grants [SpaceGrantRow {seq = 2000, space_id = "copy-space", subject_kind = "group", subject_id = "copy-g1", permission = "edit"}]
  -- The child before the page it is under, as a page moved under a newer
  -- one is.
  row
    wikiDb.pages
    [ page "copy-child" (Just "copy-late") "child"
    , page "copy-page" Nothing "home"
    , page "copy-late" (Just "copy-page") "late"
    ]
  -- A space's home page, once its pages are there.
  runUpdate (update wikiDb.spaces (\s -> s.home_page <-. val_ (Just "copy-page")) (\s -> s.id ==. val_ "copy-space"))
  row
    wikiDb.page_versions
    [ VersionRow {page_id = "copy-page", updated_at = time 0, title = "Home", body = "# Home\n", author = Just "copy-u1"}
    , VersionRow {page_id = "copy-page", updated_at = time 1, title = "", body = "", author = Nothing}
    ]
  row wikiDb.attachments [AttachmentRow {id = "copy-att", page_id = "copy-page", name = "logo.png", media_type = "image/png", size = 1234, url = Just "https://example.org/logo.png", blob = Nothing, ordinal = 0}]
  row wikiDb.drafts [DraftRow {page_id = "copy-page", author = "copy-u1", title = "Home", body = "draft", base = time 0, saved_at = time 2}]
  row wikiDb.threads [ThreadRow {id = "copy-thread", page_id = "copy-page", quote = Just "Home", prefix = Just "", suffix = Just "", resolved = True, created_at = time 2, seq = 1}]
  row wikiDb.comments [CommentRow {id = "copy-comment", thread_id = "copy-thread", author = "copy-u1", body = "A comment", created_at = time 2, edited_at = Just (time 3), seq = 1}]
  row
    wikiDb.watches
    [ WatchRow {user_id = "copy-u1", page_id = Just "copy-page", space_id = Nothing, watching = True}
    , WatchRow {user_id = "copy-u2", page_id = Nothing, space_id = Just "copy-space", watching = False}
    ]
  row wikiDb.stars [StarRow {user_id = "copy-u1", page_id = "copy-page", position = 0}]
  row wikiDb.notifications [NotificationRow {seq = 3000, id = "copy-n1", user_id = "copy-u1", kind = "commented", page_id = "copy-page", thread_id = Just "copy-thread", actor = "copy-u2", actor_name = "Copy Two", title = "Home", excerpt = "A comment", created_at = time 2, read_at = Just (time 3), mail = True}]
  row wikiDb.sessions [SessionRow {id_hash = "copy-session", user_id = "copy-u1", created_at = time 0, last_seen_at = time 1, expires_at = time 48, public_id = "copy-session-public", address = "192.0.2.1"}]
  row wikiDb.invitations [InvitationRow {id = "copy-invitation", email = "new@example.org", token_hash = "copy-invitation-hash", created_at = time 0, expires_at = time 72}]
  row wikiDb.identities [IdentityRow {provider = "github", subject = "12345", user_id = "copy-u1", email = Just "one@example.org", display_name = Just "One", linked_at = time 1}]
  row wikiDb.totp [TotpRow {user_id = "copy-u1", secret = "JBSWY3DPEHPK3PXP", created_at = time 0, enabled_at = Just (time 1), last_counter = Just 58000000}]
  row wikiDb.recovery_codes [RecoveryCodeRow {user_id = "copy-u1", code_hash = "copy-code", used_at = Nothing}]
  row wikiDb.reset_tokens [ResetTokenRow {token_hash = "copy-reset", user_id = "copy-u2", created_at = time 0, expires_at = time 1, used_at = Just (time 1)}]
  row wikiDb.email_verifications [EmailVerificationRow {token_hash = "copy-verify", user_id = "copy-u1", email = "one@example.org", created_at = time 0, expires_at = time 24}]
  row wikiDb.passkeys [PasskeyRow {credential_id = "copy-credential", user_id = "copy-u1", public_key = "copy-public-key", algorithm = -7, sign_count = 4294967296, name = "Laptop", created_at = time 0, last_used_at = Just (time 2), wrapped_nonce = Just "nonce", wrapped_key = Just "wrapped"}]
  row wikiDb.vaults [VaultRow {user_id = "copy-u1", salt = "salt", password_nonce = Just "nonce", password_key = Just "key", revision = 7, updated_at = time 2}]
  row wikiDb.vault_items [VaultItemRow {user_id = "copy-u1", name = "identity", key_id = Just "copy-key", nonce = "nonce", ciphertext = "ciphertext"}]
  row
    wikiDb.public_keys
    [ PublicKeyRow {key_id = "copy-key", user_id = "copy-u1", public_key = "public", created_at = time 1, retired_at = Nothing, retired_because = Nothing}
    , PublicKeyRow {key_id = "copy-old-key", user_id = "copy-u1", public_key = "old", created_at = time 0, retired_at = Just (time 1), retired_because = Just "replaced"}
    ]
  row wikiDb.key_grants [KeyGrantRow {resource_kind = "space", resource_id = "copy-sealed", key_id = "copy-space-key", recipient = "copy-u1", recipient_key_id = "copy-key", enc = "enc", sealed = "sealed", created_at = time 1}]
  row wikiDb.page_keys [PageKeyRow {page_id = "copy-late", key_id = "copy-page-key", space_key_id = "copy-space-key", nonce = "nonce", wrapped = "wrapped", current = True}]
  row wikiDb.sealed_versions [SealedVersionRow {page_id = "copy-page", updated_at = time 1, tag = "tag", key_id = "copy-page-key", title_nonce = "n1", title = "t", body_nonce = "n2", body = "b", chain_number = Just 2, previous_tag = Just "earlier-tag"}]
  row wikiDb.sealed_threads [SealedThreadRow {thread_id = "copy-thread", key_id = "copy-page-key", anchored = True, anchor_nonce = Just "n", anchor = Just "a"}]
  row wikiDb.sealed_comments [SealedCommentRow {comment_id = "copy-comment", key_id = "copy-page-key", tag = "tag", nonce = "n", body = "b"}]
  row wikiDb.sealed_attachments [SealedAttachmentRow {attachment_id = "copy-att", key_id = "copy-page-key", meta_nonce = "n", meta = "m", bytes_nonce = "b", staged_blob = Just "copy-staged-blob"}]
  row wikiDb.staged_plain [StagedPlainRow {page_id = "copy-page", kind = "comment", item = "copy-comment", updated_at = Nothing, title = Nothing, body = Just "Staged ünïcode", quote = Nothing, prefix = Nothing, suffix = Nothing, name = Nothing, media_type = Nothing, blob = Nothing}]
  row wikiDb.settings [SettingRow {key = "copy-setting", value = "ünïcode ✓"}]
  row wikiDb.sign_in_providers [ProviderRow {name = "copy-github", position = 0, kind = "github", client_id = "copy-client", issuer = Nothing, secret = Nothing}]
  row wikiDb.audit_log [AuditRow {id = "copy-audit", at = time 1, actor_id = "copy-u1", actor_login = "copy.one", action = "space.create", subject_kind = "space", subject_id = Just "copy-space", subject_name = "Copy", detail = "{}", address = "192.0.2.1"}]
  where
    space i parent slug home key =
      SpaceRow
        { id = i
        , parent
        , name = "Space " <> i
        , slug
        , public = isNothing parent
        , math_macros = ""
        , created_at = time 0
        , position = 0
        , subspace_order = "name"
        , page_order = "by-hand"
        , home_page = home
        , icon = Nothing
        , description = "A space to copy"
        , blog = False
        , box_numbering = "in-page"
        , sealed = isJust parent
        , owner = Nothing
        , active = True
        , personal_container = False
        , key_id = key
        , conversion = if isJust key then Just "encrypting" else Nothing
        }
    page i parent slug =
      PageRow
        { id = i
        , space_id = "copy-space"
        , parent
        , title = "Page " <> slug
        , slug
        , body = "Text of " <> slug <> ", with ünïcode"
        , created_at = time 0
        , updated_at = time 1
        , position = 0
        , template = slug == "late"
        , kind = if slug == "late" then "presentation" else "document"
        , search_text = "Page " <> slug
        , search_fold = "page " <> slug
        , converted = slug == "late"
        }

-- | Every table's rows, shown and sorted, by the table's name: what the
-- copy must leave the same. Its list is this module's, not the copy's.
everyRow :: (Backend be) => Db be [(Text, [Text])]
everyRow = traverse (\(name, rows) -> (name,) <$> rows) comparedTables

-- | Every table of the schema but @wiki_schema@, with its rows.
comparedTables :: forall be. (Backend be) => [(Text, Db be [Text])]
comparedTables =
  [ ("users", rowsIn wikiDb.users)
  , ("groups", rowsIn wikiDb.groups)
  , ("group_members", rowsIn wikiDb.group_members)
  , ("global_grants", rowsIn wikiDb.global_grants)
  , ("space_grants", rowsIn wikiDb.space_grants)
  , ("sessions", rowsIn wikiDb.sessions)
  , ("invitations", rowsIn wikiDb.invitations)
  , ("identities", rowsIn wikiDb.identities)
  , ("totp", rowsIn wikiDb.totp)
  , ("recovery_codes", rowsIn wikiDb.recovery_codes)
  , ("reset_tokens", rowsIn wikiDb.reset_tokens)
  , ("email_verifications", rowsIn wikiDb.email_verifications)
  , ("passkeys", rowsIn wikiDb.passkeys)
  , ("vaults", rowsIn wikiDb.vaults)
  , ("vault_items", rowsIn wikiDb.vault_items)
  , ("public_keys", rowsIn wikiDb.public_keys)
  , ("key_grants", rowsIn wikiDb.key_grants)
  , ("page_keys", rowsIn wikiDb.page_keys)
  , ("sealed_versions", rowsIn wikiDb.sealed_versions)
  , ("sealed_threads", rowsIn wikiDb.sealed_threads)
  , ("sealed_comments", rowsIn wikiDb.sealed_comments)
  , ("sealed_attachments", rowsIn wikiDb.sealed_attachments)
  , ("staged_plain", rowsIn wikiDb.staged_plain)
  , ("spaces", rowsIn wikiDb.spaces)
  , ("pages", rowsIn wikiDb.pages)
  , ("page_versions", rowsIn wikiDb.page_versions)
  , ("attachments", rowsIn wikiDb.attachments)
  , ("drafts", rowsIn wikiDb.drafts)
  , ("threads", rowsIn wikiDb.threads)
  , ("comments", rowsIn wikiDb.comments)
  , ("watches", rowsIn wikiDb.watches)
  , ("stars", rowsIn wikiDb.stars)
  , ("page_links", rowsIn wikiDb.page_links)
  , ("notifications", rowsIn wikiDb.notifications)
  , ("settings", rowsIn wikiDb.settings)
  , ("sign_in_providers", rowsIn wikiDb.sign_in_providers)
  , ("audit_log", rowsIn wikiDb.audit_log)
  , ("permissions_generation", rowsIn wikiDb.permissions_generation)
  ]

-- | One table's rows, shown and sorted.
rowsIn :: (Backend be, Beamable t, FromBackendRow be (t Identity), Show (t Identity)) => DatabaseEntity be WikiDb (TableEntity t) -> Db be [Text]
rowsIn table = sort . map show <$> runSelectReturningList (select (all_ table))
