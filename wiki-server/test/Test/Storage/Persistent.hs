-- | The users, groups and grants as persistent reads and writes them
-- ("Wiki.Server.Storage.Rows", WP5.7 of docs/PLAN.md, a spike), on both
-- databases the same code is for: SQLite, over the connection the storage
-- opens, and PostgreSQL, when a server is named by WIKI_TEST_POSTGRES (a
-- libpq connection string; toolchain/with-postgres.sh starts one, CI a
-- service container). Without one, the PostgreSQL examples are pending.
--
-- Each example runs on a database of its own, made by the migrations of
-- its kind: a file in a temporary directory, or a schema of its own on the
-- server, dropped afterwards. Each read or write runs in a transaction of
-- its own, as an operation of the storage's would.
module Test.Storage.Persistent (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, picosecondsToDiffTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Database.Persist (PersistValue (..))
import Database.Persist qualified as P
import Database.Persist.Postgresql (openSimpleConn)
import Database.Persist.Sql (Single (..), rawExecute, rawSql, runSqlConn)
import Database.PostgreSQL.Simple qualified as PG
import Database.SQLite.Simple (Only (..), execute_, open, query_)
import Database.SQLite.Simple qualified as SQLite
import Protolude
import System.Environment (lookupEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Wiki.Api.Account (Account (..), LinkedIdentity (..))
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.User (Group (..), User (..))
import Wiki.Server.Storage.Entities
import Wiki.Server.Storage.Migrate (Migration (..), migrate, migrateSql, migrations, postgresMigrations)
import Wiki.Server.Storage.Rows
import Wiki.Server.Storage.Sql (Db (..), closeDb, openDb, runSql)

-- | How an example runs a read or write: in a transaction of its own.
newtype Run = Run (forall a. Sql a -> IO a)

-- | A database to run an example on, made afresh and gone afterwards.
type Fresh = (Run -> IO ()) -> IO ()

spec :: Spec
spec = describe "the users, groups and grants through persistent" $ do
  describe "on SQLite" (rows onSqlite)
  describe "on PostgreSQL" (rows onPostgres)
  shared
  branches

--------------------------------------------------------------------------------
-- The databases

-- | A database in a temporary file, migrated as the storage migrates one,
-- with the pragmas it sets that the rows rely on (foreign keys), through
-- the storage's own pair of connections.
onSqlite :: Fresh
onSqlite action = withSystemTempDirectory "wiki-persistent-test" $ \dir -> do
  c <- open (dir </> "test.sqlite")
  execute_ c "PRAGMA foreign_keys = ON"
  _ <- migrate c
  -- persistent's own transaction here, where the storage begins it with
  -- sqlite-simple (Wiki.Server.Storage): the same connection either way.
  bracket (openDb c) closeDb $ \d -> action (Run (`runSqlConn` d.backend))

-- | A schema of its own on the server WIKI_TEST_POSTGRES names, migrated
-- by PostgreSQL's branch of the migrations, and dropped afterwards; pending
-- where no server is named.
onPostgres :: Fresh
onPostgres action =
  (mfilter (not . null) <$> lookupEnv "WIKI_TEST_POSTGRES") >>= \case
    Nothing -> pendingWith "no PostgreSQL server: WIKI_TEST_POSTGRES names none (sh toolchain/with-postgres.sh starts one)"
    Just server -> do
      -- A name no other run's schema has: the time, to its last digit.
      schema <- ("wiki_test_" <>) . T.filter isDigit . show <$> getPOSIXTime
      bracket (PG.connectPostgreSQL (encodeUtf8 (T.pack server))) PG.close $ \pg -> do
        backend <- openSimpleConn (\_ _ _ _ -> pass) pg
        let run :: Sql a -> IO a
            run q = runSqlConn q backend
        -- The server's notices (a drop that cascades) are no test's output.
        run $ do
          rawExecute "SET client_min_messages TO WARNING" []
          rawExecute ("CREATE SCHEMA " <> schema) []
          rawExecute ("SET search_path TO " <> schema) []
        (run (migrateSql postgresMigrations) >> action (Run run))
          `finally` run (rawExecute ("DROP SCHEMA " <> schema <> " CASCADE") [])

--------------------------------------------------------------------------------
-- What the rows do, on either

rows :: Fresh -> Spec
rows fresh = around fresh $ do
  it "keep users, and find them by id, by login and as active" $ \(Run run) -> do
    run (traverse_ insertUser [ada, bob])
    run (loadUser ada.id) `shouldReturn` Just ada
    run (loadUser (UserId "nobody")) `shouldReturn` Nothing
    run (loadUserByLogin "bob") `shouldReturn` Just bob
    run loadUsers `shouldReturn` [ada, bob]
    run (updateDisabled bob.id True)
    run (loadActiveUser bob.id) `shouldReturn` Nothing
    run (loadActiveUser ada.id) `shouldReturn` Just ada

  it "make an account only with a login no one has, whatever its case" $ \(Run run) -> do
    made <- run (insertAccount ada.id "Ada" "Ada Lovelace" (Just "$argon2id$hash"))
    made `shouldBe` Right Account {user = User {id = ada.id, login = "Ada", displayName = "Ada Lovelace"}, hasPassword = True, disabled = False}
    run (insertAccount bob.id "aDA" "Not Ada" Nothing) `shouldReturn` Left "aDA"
    run (loadUser bob.id) `shouldReturn` Nothing
    run (loadAccountByLogin "ADA") `shouldReturn` Just (fromRight' made, Just "$argon2id$hash")
    run (loadPasswordHash ada.id) `shouldReturn` Just (Just "$argon2id$hash")
    run (loadPasswordHash bob.id) `shouldReturn` Nothing

  it "list accounts by login without case, with who is an administrator" $ \(Run run) -> do
    run $ do
      traverse_ (\(u, l) -> insertAccount (UserId u) l l Nothing) [("u1", "carol"), ("u2", "Bob"), ("u3", "alice")]
      insertGrants Grants {global = [GlobalGrant {subject = SubjectUser (UserId "u1"), permission = Administer}, GlobalGrant {subject = SubjectUser (UserId "u3"), permission = CreateSpaces}], spaces = [], access = Open}
      -- A group's grant with a user's id is no user's.
      insertGrants Grants {global = [GlobalGrant {subject = SubjectGroup (GroupId "u2"), permission = Administer}], spaces = [], access = Open}
    listed <- run loadAccountList
    map (\(a, admin) -> (a.user.login, admin)) listed `shouldBe` [("alice", False), ("Bob", False), ("carol", True)]

  it "say who is disabled, who has a password, and whose address is verified" $ \(Run run) -> do
    run $ do
      void (insertAccount ada.id ada.login ada.displayName (Just "hash"))
      void (insertAccount bob.id bob.login bob.displayName Nothing)
      insertUser carol
      updateDisabled bob.id True
      P.update (UserRowKey ada.id.text) [UserRowEmail P.=. Just "ada@example.org", UserRowEmailVerifiedAt P.=. Just (Stamp at)]
      P.update (UserRowKey bob.id.text) [UserRowEmail P.=. Just "bob@example.org"]
    run loadAccountFlags `shouldReturn` (Set.fromList [bob.id], Set.fromList [ada.id])
    run (loadAccount bob.id) `shouldReturn` Just Account {user = bob, hasPassword = False, disabled = True}
    run loadEmails
      `shouldReturn` Map.fromList [(ada.id, AccountEmail {email = "ada@example.org", verified = True}), (bob.id, AccountEmail {email = "bob@example.org", verified = False})]

  it "keep groups and their members, each member once" $ \(Run run) -> do
    run $ do
      traverse_ insertUser [ada, bob]
      traverse_ insertGroup [writers, readers]
      insertMember writers.id ada.id
      insertMember writers.id ada.id
      insertMember writers.id bob.id
      insertMember readers.id bob.id
    run (loadGroupsOf bob.id) `shouldReturn` Set.fromList [writers.id, readers.id]
    run loadMembership `shouldReturn` Map.fromList [(writers.id, Set.fromList [ada.id, bob.id]), (readers.id, Set.fromList [bob.id])]
    run (deleteMember writers.id bob.id >> renameGroupRow readers.id "Everyone")
    run (loadGroupsOf bob.id) `shouldReturn` Set.fromList [readers.id]
    run loadGroups `shouldReturn` [Group {id = readers.id, name = "Everyone"}, writers]

  it "keep grants in the order they were given, each once, and take them back" $ \(Run run) -> do
    run (traverse_ insertUser [ada, bob] >> insertGroup writers >> insertSpace' "space-1")
    let given =
          Grants
            { global = [GlobalGrant {subject = SubjectUser bob.id, permission = CreateSpaces}, GlobalGrant {subject = SubjectUser ada.id, permission = Administer}]
            , spaces = [SpaceGrant {space = SpaceId "space-1", subject = SubjectGroup writers.id, permission = Edit}, SpaceGrant {space = SpaceId "space-1", subject = SubjectUser ada.id, permission = View}]
            , access = Open
            }
    run (insertGrants given)
    -- Given again, a grant keeps its place.
    run (insertGrants given {global = reverse given.global, spaces = reverse given.spaces})
    run loadGrants `shouldReturn` given
    run (deleteGlobalGrant (GlobalGrant {subject = SubjectUser bob.id, permission = CreateSpaces}) >> deleteSpaceGrant (SpaceGrant {space = SpaceId "space-1", subject = SubjectUser ada.id, permission = View}))
    run loadGrants `shouldReturn` given {global = drop 1 given.global, spaces = take 1 given.spaces}
    run (grantCreateSpaces bob.id)
    (\g -> g.global) <$> run loadGrants `shouldReturn` [GlobalGrant {subject = SubjectUser ada.id, permission = Administer}, GlobalGrant {subject = SubjectUser bob.id, permission = CreateSpaces}]

  it "delete a group with its members and the grants to it, and nobody else's" $ \(Run run) -> do
    run $ do
      traverse_ insertUser [ada, bob]
      traverse_ insertGroup [writers, readers]
      insertSpace' "space-1"
      insertMember writers.id ada.id
      insertMember readers.id bob.id
      insertGrants
        Grants
          { global = [GlobalGrant {subject = SubjectGroup writers.id, permission = CreateSpaces}, GlobalGrant {subject = SubjectUser ada.id, permission = Administer}]
          , spaces = [SpaceGrant {space = SpaceId "space-1", subject = SubjectGroup writers.id, permission = Edit}, SpaceGrant {space = SpaceId "space-1", subject = SubjectGroup readers.id, permission = View}]
          , access = Open
          }
      deleteGroupRows writers.id
    run loadGroups `shouldReturn` [readers]
    run loadMembership `shouldReturn` Map.fromList [(readers.id, Set.fromList [bob.id])]
    run loadGrants
      `shouldReturn` Grants
        { global = [GlobalGrant {subject = SubjectUser ada.id, permission = Administer}]
        , spaces = [SpaceGrant {space = SpaceId "space-1", subject = SubjectGroup readers.id, permission = View}]
        , access = Open
        }

  it "keep identities at providers, with the time they were linked to the last digit" $ \(Run run) -> do
    now <- getCurrentTime
    run $ do
      traverse_ insertUser [ada, bob]
      insertIdentity now ada.id "google" "g-1" (Just "ada@example.org") (Just "Ada")
      insertIdentity at ada.id "github" "42" Nothing Nothing
      insertIdentity at bob.id "github" "43" Nothing Nothing
    found <- run (identityOf "google" "g-1")
    (\i -> (i.user, i.identity)) <$> found `shouldBe` Just (ada.id, LinkedIdentity {provider = "google", email = Just "ada@example.org", name = Just "Ada", linkedAt = now})
    map (\i -> i.provider) <$> run (identitiesOf ada.id) `shouldReturn` ["github", "google"]
    run (refreshIdentity "github" "42" (Just "new@example.org") (Just "Ada L."))
    (>>= \i -> i.identity.email) <$> run (identityOf "github" "42") `shouldReturn` Just "new@example.org"
    run loadIdentityProviders `shouldReturn` Map.fromList [(ada.id, ["github", "google"]), (bob.id, ["github"])]
    run (deleteIdentity ada.id "google") `shouldReturn` True
    run (deleteIdentity ada.id "google") `shouldReturn` False
    isJust <$> run (identityOf "google" "g-1") `shouldReturn` False

  it "tell who has no password to set: none, and an identity at a provider the server has" $ \(Run run) -> do
    run $ do
      void (insertAccount ada.id ada.login ada.displayName Nothing)
      void (insertAccount bob.id bob.login bob.displayName (Just "hash"))
      insertUser carol
      insertIdentity at ada.id "github" "42" Nothing Nothing
      insertIdentity at bob.id "github" "43" Nothing Nothing
    run (noPasswordToSet ["github"] ada.id) `shouldReturn` True
    run (noPasswordToSet ["google"] ada.id) `shouldReturn` False
    run (noPasswordToSet ["github"] bob.id) `shouldReturn` False
    run (noPasswordToSet ["github"] carol.id) `shouldReturn` False

  it "tell and take away second factors, and end a user's sessions" $ \(Run run) -> do
    run $ do
      traverse_ insertUser [ada, bob]
      P.insert_ TotpRow {userId = UserRowKey ada.id.text, secret = "S", createdAt = Stamp at, enabledAt = Just (Stamp at), lastCounter = Nothing}
      P.insert_ TotpRow {userId = UserRowKey bob.id.text, secret = "S", createdAt = Stamp at, enabledAt = Nothing, lastCounter = Nothing}
      P.insert_ RecoveryCodeRow {userId = UserRowKey ada.id.text, codeHash = "c", usedAt = Nothing}
      for_ [("s-a", ada), ("s-b", bob)] $ \(key, u) ->
        P.insertKey (SessionRowKey key) SessionRow {userId = UserRowKey u.id.text, createdAt = Stamp at, lastSeenAt = Stamp at, expiresAt = Stamp at, publicId = Just key, address = ""}
    run (totpEnabled ada.id) `shouldReturn` True
    run (totpEnabled bob.id) `shouldReturn` False
    run loadSecondFactorUsers `shouldReturn` Set.fromList [ada.id]
    run (deleteSecondFactor ada.id) `shouldReturn` True
    run (deleteSecondFactor bob.id) `shouldReturn` False
    run (P.count ([] :: [P.Filter RecoveryCodeRow])) `shouldReturn` 0
    run (deleteSessionsOf ada.id)
    map P.entityKey <$> run (P.selectList ([] :: [P.Filter SessionRow]) []) `shouldReturn` [SessionRowKey "s-b"]
  where
    -- A space for the grants on it to refer to: a row of a table that is
    -- no entity of the spike's, written in SQL both databases take, the
    -- flag bound as persistent binds a Bool (an integer on SQLite).
    insertSpace' :: Text -> Sql ()
    insertSpace' sid =
      rawExecute
        "INSERT INTO spaces (id, parent, name, slug, public, math_macros, created_at, position, subspace_order, page_order) VALUES (?, NULL, ?, ?, ?, '', '2026-10-27T00:00:00Z', 0, 'name', 'name')"
        [PersistText sid, PersistText sid, PersistText sid, PersistBool False]
    fromRight' = either (panic . show) identity

ada, bob, carol :: User
ada = User {id = UserId "user-1", login = "ada", displayName = "Ada"}
bob = User {id = UserId "user-2", login = "bob", displayName = "Bob"}
carol = User {id = UserId "user-3", login = "carol", displayName = "Carol"}

writers, readers :: Group
writers = Group {id = GroupId "group-w", name = "Writers"}
readers = Group {id = GroupId "group-r", name = "Readers"}

-- | A time with more digits than a microsecond, which a time column must
-- give back as they were.
at :: UTCTime
at = UTCTime (fromGregorian 2026 10 27) (picosecondsToDiffTime 43200123456789012)

--------------------------------------------------------------------------------
-- One connection

-- | persistent and sqlite-simple on the storage's one connection
-- ("Wiki.Server.Storage.Sql"): one transaction, whichever began it.
shared :: Spec
shared = describe "on the storage's SQLite connection" $ do
  it "write in the transaction sqlite-simple began, and are rolled back with it" $
    withSystemTempDirectory "wiki-persistent-test" $ \dir -> do
      c <- open (dir </> "test.sqlite")
      _ <- migrate c
      bracket (openDb c) closeDb $ \d -> do
        execute_ c "BEGIN IMMEDIATE"
        runSql d (insertUser ada)
        query_ c "SELECT login FROM users" `shouldReturn` [Only ("ada" :: Text)]
        execute_ c "ROLLBACK"
        runSql d (loadUser ada.id) `shouldReturn` Nothing
        execute_ c "BEGIN IMMEDIATE"
        execute_ c "INSERT INTO users (id, login, display_name) VALUES ('user-1', 'ada', 'Ada')"
        runSql d (loadUser ada.id) `shouldReturn` Just ada
        execute_ c "COMMIT"

  it "close the connection with the statements persistent prepared on it" $
    withSystemTempDirectory "wiki-persistent-test" $ \dir -> do
      c <- open (dir </> "test.sqlite")
      _ <- migrate c
      d <- openDb c
      runSql d (insertUser ada >> void (loadUser ada.id) >> void loadGrants)
      -- SQLite refuses to close a connection with a statement left
      -- prepared on it, and sqlite-simple says so with an exception.
      closeDb d

--------------------------------------------------------------------------------
-- The two branches of the migrations

branches :: Spec
branches = describe "PostgreSQL's branch of the migrations" $ do
  it "has a step for each of SQLite's, of the same name" $
    map (\m -> (m.version, m.name)) postgresMigrations `shouldBe` map (\m -> (m.version, m.name)) migrations

  it "has no question mark, which postgresql-simple would take for a parameter" $
    filter (T.isInfixOf "?" . (\m -> m.statements)) postgresMigrations `shouldBe` []

  around onPostgres $
    it "makes the tables and columns SQLite's makes, and applies no step twice" $ \(Run run) -> do
      run (migrateSql postgresMigrations) `shouldReturn` []
      columns <- run (rawSql "SELECT table_name::text, column_name::text FROM information_schema.columns WHERE table_schema = current_schema()" [])
      sqlite <- sqliteColumns
      -- The grants' rowid is SQLite's without a name, a column of
      -- PostgreSQL's.
      Set.fromList [(t, c) | (Single t, Single c) <- columns]
        `shouldBe` (sqlite <> Set.fromList [("global_grants", "rowid"), ("space_grants", "rowid")])
  where
    sqliteColumns :: IO (Set (Text, Text))
    sqliteColumns = withSystemTempDirectory "wiki-persistent-test" $ \dir ->
      SQLite.withConnection (dir </> "test.sqlite") $ \c -> do
        _ <- migrate c
        Set.fromList
          <$> query_ c "SELECT m.name, p.name FROM sqlite_master m JOIN pragma_table_info(m.name) p WHERE m.type = 'table'"
