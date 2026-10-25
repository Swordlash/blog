-- | The schema's migrations: applied on an empty database, not again on one
-- that has them, all or none of them, and never over a newer schema.
module Test.Storage.Migrate (spec) where

import Database.SQLite.Simple (Connection, Only (..), execute_, query_, withConnection)
import Database.SQLite.Simple qualified as SQLite
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Wiki.Api.Admin (WikiSettings (..), defaultSettings)
import Wiki.Core.Access (Access (..))
import Wiki.Server.Storage (closeStorage, defaultConfig, openStorage, withStorage)
import Wiki.Server.Storage.Layout (databaseFile)
import Wiki.Server.Storage.Migrate
import Wiki.Server.Storage.Rows (loadSettings)

-- | A database in a temporary file of its own.
withFreshDatabase :: (FilePath -> Connection -> IO a) -> IO a
withFreshDatabase action = withSystemTempDirectory "wiki-migrate-test" $ \dir ->
  let file = dir </> "test.sqlite" in withConnection file (action file)

-- | The schema as SQLite holds it: what migrating must leave alone once it
-- is done.
schema :: Connection -> IO [(Text, Text, Maybe Text)]
schema c = query_ c "SELECT type, name, sql FROM sqlite_master ORDER BY type, name"

tableNames :: Connection -> IO [Text]
tableNames c = map fromOnly <$> query_ c "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"

spec :: Spec
spec = describe "migrations" $ do
  it "are numbered from 1 with no gaps, as their files are" $ do
    map (\m -> m.version) migrations `shouldBe` [1 .. length migrations]
    map (\m -> m.name) (take 1 migrations) `shouldBe` ["0001-initial.sql"]

  it "make the whole schema in an empty database, and say which they applied" $
    withFreshDatabase $ \_ c -> do
      schemaVersion c `shouldReturn` 0
      migrate c `shouldReturn` [1 .. length migrations]
      schemaVersion c `shouldReturn` length migrations
      tables <- tableNames c
      for_ ["users", "groups", "group_members", "global_grants", "space_grants", "spaces", "pages", "page_versions", "attachments", "drafts", "sessions", "settings", "invitations", "identities", "schema_version"] $ \t ->
        tables `shouldContain` [t]
      rows <- query_ c "SELECT version FROM schema_version ORDER BY version"
      map fromOnly rows `shouldBe` [1 .. length migrations]

  it "bring a database of the first schema up to accounts: its users kept, with no password and not disabled" $
    withFreshDatabase $ \_ c -> do
      applyMigrations (take 1 migrations) c `shouldReturn` [1]
      execute_ c "INSERT INTO users (id, login, display_name) VALUES ('user-1', 'ada', 'Ada')"
      execute_ c "INSERT INTO global_grants (subject_kind, subject_id, permission) VALUES ('user', 'user-1', 'administer')"
      migrate c `shouldReturn` [2 .. length migrations]
      rows <- query_ c "SELECT id, login, display_name, password_hash, disabled FROM users"
      rows `shouldBe` [("user-1" :: Text, "ada" :: Text, "Ada" :: Text, Nothing :: Maybe Text, 0 :: Int)]
      tableNames c >>= (`shouldContain` ["sessions"])
      -- A session goes with its user.
      execute_ c "PRAGMA foreign_keys = ON"
      execute_ c "INSERT INTO sessions (id_hash, user_id, created_at, last_seen_at, expires_at) VALUES ('h', 'user-1', 'a', 'b', 'c')"
      execute_ c "DELETE FROM users WHERE id = 'user-1'"
      query_ c "SELECT count(*) FROM sessions" `shouldReturn` [Only (0 :: Int)]

  it "bring a database of accounts up to settings: an open wiki, and no invitation" $
    withFreshDatabase $ \_ c -> do
      applyMigrations (take 2 migrations) c `shouldReturn` [1, 2]
      execute_ c "INSERT INTO users (id, login, display_name) VALUES ('user-1', 'ada', 'Ada')"
      migrate c `shouldReturn` [3 .. length migrations]
      tables <- tableNames c
      for_ ["settings", "invitations"] $ \t -> tables `shouldContain` [t]
      query_ c "SELECT count(*) FROM settings" `shouldReturn` [Only (0 :: Int)]
      loadSettings c `shouldReturn` defaultSettings
      defaultSettings.access `shouldBe` Open
      query_ c "SELECT count(*) FROM users" `shouldReturn` [Only (1 :: Int)]

  it "bring a database of settings up to identities: none, each a user's, and gone with them" $
    withFreshDatabase $ \_ c -> do
      applyMigrations (take 3 migrations) c `shouldReturn` [1, 2, 3]
      execute_ c "INSERT INTO users (id, login, display_name) VALUES ('user-1', 'ada', 'Ada')"
      migrate c `shouldReturn` [4 .. length migrations]
      tableNames c >>= (`shouldContain` ["identities"])
      query_ c "SELECT count(*) FROM identities" `shouldReturn` [Only (0 :: Int)]
      execute_ c "PRAGMA foreign_keys = ON"
      execute_ c "INSERT INTO identities (provider, subject, user_id, linked_at) VALUES ('github', '42', 'user-1', 'now')"
      -- A provider's account is one user's at most.
      (try (execute_ c "INSERT INTO identities (provider, subject, user_id, linked_at) VALUES ('github', '42', 'user-1', 'later')") :: IO (Either SomeException ())) >>= (`shouldSatisfy` isLeft)
      execute_ c "DELETE FROM users WHERE id = 'user-1'"
      query_ c "SELECT count(*) FROM identities" `shouldReturn` [Only (0 :: Int)]

  it "apply nothing a second time, and change nothing" $
    withFreshDatabase $ \_ c -> do
      _ <- migrate c
      migrated <- schema c
      migrate c `shouldReturn` []
      schema c `shouldReturn` migrated
      count <- query_ c "SELECT count(*) FROM schema_version"
      count `shouldBe` [Only (length migrations)]

  it "run when the storage is opened, and find the database migrated the next time" $
    withSystemTempDirectory "wiki-migrate-test" $ \dir -> do
      withStorage defaultConfig dir (const pass)
      withStorage defaultConfig dir (const pass)
      withConnection (databaseFile dir) $ \c -> do
        schemaVersion c `shouldReturn` length migrations
        count <- query_ c "SELECT count(*) FROM schema_version"
        count `shouldBe` [Only (length migrations)]

  it "apply every pending step or none: a step that fails leaves the database as it was" $
    withFreshDatabase $ \_ c -> do
      let steps =
            [ Migration {version = 1, name = "0001-good.sql", statements = "CREATE TABLE first (x INTEGER);"}
            , Migration {version = 2, name = "0002-bad.sql", statements = "CREATE TABLE second (x INTEGER); CREATE TABLE ("}
            ]
      result <- try @SQLite.SQLError (applyMigrations steps c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 0
      tableNames c `shouldReturn` []
      -- And once the step is right, both are applied.
      applyMigrations (take 1 steps <> [Migration {version = 2, name = "0002-good.sql", statements = "CREATE TABLE second (x INTEGER);"}]) c `shouldReturn` [1, 2]

  it "apply only the steps after the database's version" $
    withFreshDatabase $ \_ c -> do
      let stepOne = Migration {version = 1, name = "0001.sql", statements = "CREATE TABLE first (x INTEGER);"}
          stepTwo = Migration {version = 2, name = "0002.sql", statements = "CREATE TABLE second (x INTEGER);"}
      applyMigrations [stepOne] c `shouldReturn` [1]
      applyMigrations [stepOne, stepTwo] c `shouldReturn` [2]
      tableNames c `shouldReturn` ["first", "schema_version", "second"]

  it "refuse a database a newer program has migrated, and leave it alone" $
    withSystemTempDirectory "wiki-migrate-test" $ \dir -> do
      withStorage defaultConfig dir (const pass)
      let newer = length migrations + 1
      withConnection (databaseFile dir) $ \c ->
        execute_ c (SQLite.Query ("INSERT INTO schema_version (version, applied_at) VALUES (" <> show newer <> ", 'later')"))
      result <- try (openStorage defaultConfig dir >>= closeStorage)
      result `shouldBe` Left SchemaTooNew {found = newer, known = length migrations}
      withConnection (databaseFile dir) $ \c -> schemaVersion c `shouldReturn` newer
