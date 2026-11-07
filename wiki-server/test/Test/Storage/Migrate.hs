-- | The schema's versions ("Wiki.Server.Storage.Migrate"): one initial
-- schema for each database, applied to an empty database, not again to one
-- that has it, all of a step or none of it, and never over a newer schema
-- or the schema of an earlier wiki-server, which is refused with what to
-- do instead.
module Test.Storage.Migrate (spec) where

import Data.List qualified as List
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.Beam (all_, insert, insertValues, runInsert, runSelectReturningList, select)
import Protolude
import Test.Database (Backing (..), withConnectionTo)
import Test.Hspec
import Test.Storage.Fixture (demoArchive, ok, withPlaceIn)
import Wiki.Api.Vault (StoredVault (..))
import Wiki.Core.Assistant.Vault (Sealed (..), Vault (..), VaultTag (..), vaultFormat, withSealed)
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Storage (CheckProblem (..), Migrated (..), Place, TableRead (..), checkDatabase, closeStorage, defaultConfig, importArchive, migrateDatabase, openStorage, withStorage)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate
import Wiki.Server.Storage.Rows (micro)
import Wiki.Server.Storage.Schema (SchemaDb (..), WikiSchema (..), schemaDb)
import Wiki.Server.Vault (storedVault)

-- | The tables of the wiki's schema, the same on both databases.
wikiTables :: [Text]
wikiTables =
  [ "attachments"
  , "audit_log"
  , "comments"
  , "drafts"
  , "email_verifications"
  , "global_grants"
  , "group_members"
  , "groups"
  , "identities"
  , "invitations"
  , "key_grants"
  , "notifications"
  , "page_keys"
  , "page_versions"
  , "pages"
  , "passkeys"
  , "permissions_generation"
  , "public_keys"
  , "recovery_codes"
  , "reset_tokens"
  , "sealed_versions"
  , "sessions"
  , "settings"
  , "sign_in_providers"
  , "space_grants"
  , "spaces"
  , "stars"
  , "threads"
  , "totp"
  , "users"
  , "vault_items"
  , "vaults"
  , "watches"
  , "wiki_schema"
  ]

-- | The versions a database records, in order.
versionsOf :: (Backend be) => Connection be -> IO [Int]
versionsOf c = sort . map (\v -> fromIntegral v.version) <$> runDb c (runSelectReturningList (select (all_ schemaDb.wiki_schema)))

-- | The tables of a database, in order.
tablesOf :: (Backend be) => Connection be -> IO [Text]
tablesOf c = sort <$> runDb c tableNames

-- | A first step of a made-up schema for a database: it makes the table
-- of versions, as a real first step does, and one more table.
firstStep :: (Backend be) => Connection be -> Migration
firstStep c =
  Migration
    { version = 1
    , name = "0001-first." <> schemaSuffix c <> ".sql"
    , statements = "CREATE TABLE wiki_schema (version INTEGER PRIMARY KEY NOT NULL, applied_at " <> timeType <> " NOT NULL); CREATE TABLE first (x INTEGER);"
    }
  where
    timeType = if schemaSuffix c == "postgres" then "TIMESTAMPTZ" else "TEXT"

-- | Open a storage on a place, expecting it refused with an exception of
-- this type.
refusedWith :: forall e. (Exception e) => Place -> IO e
refusedWith at =
  try @e (openStorage defaultConfig at >>= closeStorage) >>= \case
    Left e -> pure e
    Right () -> panic "the storage opened"

spec :: Backing -> Spec
spec backing = describe "the schema's versions" $ do
  it "are numbered from 1 with no gaps, the same for both databases, as their files are" $ do
    let numbers suffix = map (\m -> m.version) (migrationsFor suffix)
    numbers "sqlite" `shouldBe` [1 .. length (migrationsFor "sqlite")]
    numbers "postgres" `shouldBe` numbers "sqlite"
    map (\m -> m.name) (take 1 (migrationsFor "sqlite")) `shouldBe` ["0001-initial.sqlite.sql"]
    map (\m -> m.name) (take 1 (migrationsFor "postgres")) `shouldBe` ["0001-initial.postgres.sql"]

  it "make the whole schema in an empty database, and say which they applied" $
    withPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let steps = migrationsFor (schemaSuffix c)
      schemaVersion c `shouldReturn` 0
      migrate c `shouldReturn` [1 .. length steps]
      schemaVersion c `shouldReturn` length steps
      tablesOf c `shouldReturn` wikiTables
      versionsOf c `shouldReturn` [1 .. length steps]

  it "apply nothing a second time, and change nothing" $
    withPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      _ <- migrate c
      tables <- tablesOf c
      versions <- versionsOf c
      migrate c `shouldReturn` []
      tablesOf c `shouldReturn` tables
      versionsOf c `shouldReturn` versions

  it "run when the storage is opened, and find the database migrated the next time" $
    withPlaceIn backing $ \at -> do
      withStorage defaultConfig at (const pass)
      withStorage defaultConfig at (const pass)
      withConnectionTo at $ \c -> do
        let steps = migrationsFor (schemaSuffix c)
        schemaVersion c `shouldReturn` length steps
        versionsOf c `shouldReturn` [1 .. length steps]

  it "move each vault of the assistant to the user's vault, its settings as its assistant item, at the same tag" $
    withPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        -- The schema of WP5.74a, with one user's vault in it as WP5.21
        -- stored it.
        void (applyMigrations (take 9 (migrationsFor (schemaSuffix c))) c)
        runScript c "INSERT INTO users (id, login, display_name) VALUES ('user-old', 'old', 'Old');"
        runScript c "INSERT INTO assistant_vaults (user_id, format, salt, nonce, ciphertext, revision, updated_at) VALUES ('user-old', 1, 'c2FsdA', 'bm9uY2U', 'c2VhbGVk', 7, CURRENT_TIMESTAMP);"
      withStorage defaultConfig at $ \st ->
        storedVault st (UserId "user-old")
          `shouldReturn` Just
            StoredVault
              { tag = VaultTag "\"7\""
              , vault = withSealed Sealed {nonce = "bm9uY2U", ciphertext = "c2VhbGVk"} Vault {format = vaultFormat, salt = "c2FsdA", items = mempty, wraps = mempty}
              }

  it "apply every pending step or none: a step that fails leaves the database as it was" $
    withPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let bad = Migration {version = 2, name = "0002-bad.sql", statements = "CREATE TABLE second (x INTEGER); CREATE TABLE ("}
          good = Migration {version = 2, name = "0002-good.sql", statements = "CREATE TABLE second (x INTEGER);"}
      result <- try @SomeException (applyMigrations [firstStep c, bad] c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 0
      tablesOf c `shouldReturn` []
      -- And once the step is right, both are applied.
      applyMigrations [firstStep c, good] c `shouldReturn` [1, 2]

  it "apply only the steps after the database's version" $
    withPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let secondStep = Migration {version = 2, name = "0002.sql", statements = "CREATE TABLE second (x INTEGER);"}
      applyMigrations [firstStep c] c `shouldReturn` [1]
      applyMigrations [firstStep c, secondStep] c `shouldReturn` [2]
      tablesOf c `shouldReturn` ["first", "second", "wiki_schema"]

  it "refuse a database a newer program has migrated, and leave it alone" $
    withPlaceIn backing $ \at -> do
      withStorage defaultConfig at (const pass)
      known <- withConnectionTo at schemaVersion
      let newer = known + 1
      now <- micro <$> getCurrentTime
      withConnectionTo at $ \c -> runDb c (runInsert (insert schemaDb.wiki_schema (insertValues [SchemaRow {version = fromIntegral newer, applied_at = now}])))
      refusedWith at `shouldReturn` SchemaTooNew {found = newer, known}
      withConnectionTo at schemaVersion `shouldReturn` newer

  it "refuse the database of an earlier wiki-server, saying to export and import, and leave it alone" $
    withPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        begin True c
        runScript c "CREATE TABLE schema_version (version INTEGER PRIMARY KEY NOT NULL, applied_at TEXT NOT NULL); CREATE TABLE users (id TEXT PRIMARY KEY NOT NULL);"
        commitTransaction c
      refused <- refusedWith @OldSchema at
      let said = T.pack (displayException refused)
      said `shouldSatisfy` T.isInfixOf "earlier wiki-server"
      said `shouldSatisfy` T.isInfixOf "Export"
      said `shouldSatisfy` T.isInfixOf "import"
      withConnectionTo at tablesOf `shouldReturn` ["schema_version", "users"]

  it "refuse a database that holds tables of something else, naming them" $
    withPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        begin True c
        runScript c "CREATE TABLE invoices (id INTEGER);"
        commitTransaction c
      refused <- refusedWith @OldSchema at
      displayException refused `shouldSatisfy` List.isInfixOf "invoices"
      withConnectionTo at tablesOf `shouldReturn` ["invoices"]

  -- wiki-server migrate and check, which the deploy runs with the new
  -- program before it starts the new server (WP5.73 of docs/PLAN.md).
  describe "by hand (wiki-server migrate, wiki-server check)" $ do
    it "migrate an empty database to this program's version, then find nothing to do" $
      withPlaceIn backing $ \at -> do
        known <- withConnectionTo at (\c -> pure (length (migrationsFor (schemaSuffix c))))
        migrateDatabase at `shouldReturn` Migrated {from = 0, to = known}
        migrateDatabase at `shouldReturn` Migrated {from = known, to = known}

    it "check a wiki with every table and record read, and change nothing" $
      withPlaceIn backing $ \at -> do
        withStorage defaultConfig at $ \st -> importArchive st demoArchive >>= ok
        tables0 <- withConnectionTo at tablesOf
        checked <- checkDatabase at
        case checked of
          Left problem -> panic ("the check failed: " <> show problem)
          Right tables -> do
            sort (map (\t -> t.table) tables) `shouldBe` filter (/= "wiki_schema") wikiTables
            all (isRight . (\t -> t.rows)) tables `shouldBe` True
            [n | TableRead "users" (Right n) <- tables] `shouldSatisfy` all (> 0)
        withConnectionTo at tablesOf `shouldReturn` tables0

    it "refuse to check a database not at this program's version, which it does not migrate" $
      withPlaceIn backing $ \at -> do
        known <- withConnectionTo at (\c -> pure (length (migrationsFor (schemaSuffix c))))
        checkDatabase at `shouldReturn` Left (NotMigrated 0 known)
        withConnectionTo at tablesOf `shouldReturn` []

    it "name a record that does not read: a space whose slug is not one" $
      withPlaceIn backing $ \at -> do
        withStorage defaultConfig at $ \st -> importArchive st demoArchive >>= ok
        withConnectionTo at $ \c -> do
          begin True c
          runScript c "UPDATE spaces SET slug = 'Not A Slug' WHERE slug = 'docs';"
          commitTransaction c
        checkDatabase at >>= \case
          Left (UnreadableRecords why) -> why `shouldSatisfy` T.isInfixOf "Not A Slug"
          other -> panic ("expected a record that does not read, got " <> show other)

    -- SQLite keeps whatever a column is given, so a value the row decoder
    -- cannot read can be written there; PostgreSQL's column types refuse it.
    case backing of
      OnSqlite ->
        it "name a table whose rows do not read, and still read the others" $
          withPlaceIn backing $ \at -> do
            withStorage defaultConfig at $ \st -> importArchive st demoArchive >>= ok
            withConnectionTo at $ \c -> do
              begin True c
              runScript c "UPDATE pages SET updated_at = 'no time at all';"
              commitTransaction c
            checkDatabase at >>= \case
              Left (UnreadableTables tables) -> do
                [t.table | t <- tables, isLeft t.rows] `shouldBe` ["pages"]
                length [t | t <- tables, isRight t.rows] `shouldBe` length tables - 1
              other -> panic ("expected a table that does not read, got " <> show other)
      _ -> pass
