{-# LANGUAGE DeriveAnyClass #-}

-- | The steps of the schema written in Haskell
-- ("Wiki.Server.Storage.Migrate.Code", issue #202): numbered with the
-- schema files, run after the files before them in the same transaction,
-- recorded as the files are, and all or nothing with them. The steps here
-- are the tests' own, given to 'applySteps'; the program has none yet.
module Test.Storage.CodeSteps (unitSpec, spec) where

import Data.Text qualified as T
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, insert, insertValues, runInsert, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import System.IO.Error (userError)
import Test.Database (Backing, withConnectionTo)
import Test.Hspec
import Test.Storage.Fixture (withPlaceIn)
import Wiki.Server.Storage (Place)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate
import Wiki.Server.Storage.Schema (SchemaDb (..), WikiSchema (..), schemaDb)

-- | A place whose database is empty, with no table in it: what every test
-- here starts from, since each applies the schema itself. It is the one
-- place to change if the tests' places come already migrated.
emptyPlace :: Backing -> (Place -> IO a) -> IO a
emptyPlace = withPlaceIn

-- | The @settings@ table as the tests' steps pin it, at the version of the
-- schema they run after: a key and a value, both text. A real step in
-- code declares its tables so, and never through
-- "Wiki.Server.Storage.Schema".
data PinnedSetting f = PinnedSetting
  { key :: Columnar f Text
  , value :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PinnedSetting where
  newtype PrimaryKey PinnedSetting f = PinnedSettingKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PinnedSettingKey r.key

newtype PinnedDb f = PinnedDb
  { settings :: f (TableEntity PinnedSetting)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

pinnedDb :: DatabaseSettings be PinnedDb
pinnedDb = defaultDbSettings

-- | Every setting, by key.
settingsOf :: (Backend be) => Connection be -> IO [(Text, Text)]
settingsOf c = sort . map (\r -> (r.key, r.value)) <$> runDb c (runSelectReturningList (select (all_ pinnedDb.settings)))

-- | Write settings, in a transaction of their own.
writeSettings :: (Backend be) => Connection be -> [(Text, Text)] -> IO ()
writeSettings c rows = do
  begin True c
  runDb c (runInsert (insert pinnedDb.settings (insertValues [PinnedSetting {key = k, value = v} | (k, v) <- rows])))
  commitTransaction c

-- | A step in code that writes one setting: it needs the @settings@ table,
-- which the first schema file makes.
noteStep :: Int -> CodeStep
noteStep n =
  CodeStep
    { version = n
    , name = "note that it ran"
    , run = \c -> runDb c (runInsert (insert pinnedDb.settings (insertValues [PinnedSetting {key = "code-step", value = "ran"}])))
    }

-- | A step in code that rewrites every setting's value from an old syntax
-- to a new one, @[[x]]@ to @{{x}}@, with a rewriter of its own, as a step
-- that rewrites pages carries its own.
rewriteStep :: Int -> CodeStep
rewriteStep n = CodeStep {version = n, name = "rewrite the old markers", run = rewriteSettings}

-- | 'rewriteStep', failing once it has rewritten every row.
failingStep :: Int -> CodeStep
failingStep n = CodeStep {version = n, name = "rewrite, then fail", run = \c -> rewriteSettings c >> throwIO (userError "the step in code failed")}

-- | Rewrite every setting's value, @[[x]]@ to @{{x}}@: read each row, and
-- write its new value back.
rewriteSettings :: (Backend be) => Connection be -> IO ()
rewriteSettings c = runDb c $ do
  rows <- runSelectReturningList (select (all_ pinnedDb.settings))
  for_ rows $ \r ->
    runUpdate (update pinnedDb.settings (\s -> s.value <-. val_ (rewritten r.value)) (\s -> s.key ==. val_ r.key))
  where
    rewritten = T.replace "[[" "{{" . T.replace "]]" "}}"

-- | The versions a database records, in order.
versionsOf :: (Backend be) => Connection be -> IO [Int]
versionsOf c = sort . map (\v -> fromIntegral v.version) <$> runDb c (runSelectReturningList (select (all_ schemaDb.wiki_schema)))

-- | The numbers of the steps, and whether they are misnumbered, which
-- touches no database.
unitSpec :: Spec
unitSpec = describe "the schema's steps, in SQL and in code" $ do
  let file n = Migration {version = n, name = "000" <> show n <> "-file.sqlite.sql", statements = ""}
      code n = CodeStep {version = n, name = "code " <> show n, run = \_ -> pass}
  it "are the program's own numbered 1, 2, 3 and so on, the same on both databases" $ do
    misnumbered (stepsFor "sqlite") `shouldBe` Nothing
    misnumbered (stepsFor "postgres") `shouldBe` Nothing
    map stepNumber (stepsFor "postgres") `shouldBe` map stepNumber (stepsFor "sqlite")
    knownVersion "sqlite" `shouldBe` length (stepsFor "sqlite")
  it "put a step in code among the files by its number" $ do
    let steps = arrange [file 1, file 3] [code 2]
    map stepNumber steps `shouldBe` [1, 2, 3]
    misnumbered steps `shouldBe` Nothing
  it "name a number a step in code shares with a file" $
    misnumbered (arrange [file 1, file 2] [code 2]) `shouldBe` Just "step 2 is both 0002-file.sqlite.sql and code 2 (in code)"
  it "name a number no step has" $
    misnumbered (arrange [file 1, file 2] [code 4]) `shouldBe` Just "no step is numbered 3"
  it "name a number below 1" $
    misnumbered (arrange [file 1] [code 0]) `shouldBe` Just "a step is numbered 0, below 1"

spec :: Backing -> Spec
spec backing = describe "the schema's steps in code" $ do
  it "run after the files numbered before them, and are recorded as the files are" $
    emptyPlace backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
          n = length files
      applySteps (arrange files [noteStep (n + 1)]) c `shouldReturn` [1 .. n + 1]
      settingsOf c `shouldReturn` [("code-step", "ran")]
      schemaVersion c `shouldReturn` n + 1
      databaseVersion c `shouldReturn` n + 1
      versionsOf c `shouldReturn` [1 .. n + 1]
      -- Applied once only, in whatever order the steps are given.
      applySteps (reverse (arrange files [noteStep (n + 1)])) c `shouldReturn` []

  it "read and rewrite rows written before them, through tables of their own" $
    emptyPlace backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
          n = length files
      _ <- applySteps (arrange files []) c
      writeSettings c [("plain", "no marker"), ("quoted", "it's [[a]] and [[b]]")]
      applySteps (reverse (arrange files [rewriteStep (n + 1)])) c `shouldReturn` [n + 1]
      settingsOf c `shouldReturn` [("plain", "no marker"), ("quoted", "it's {{a}} and {{b}}")]

  it "that fail leave the database at the version before them, and what they wrote is undone" $
    emptyPlace backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
          n = length files
      _ <- applySteps (arrange files []) c
      writeSettings c [("quoted", "it's [[a]]")]
      result <- try @IOException (applySteps (arrange files [failingStep (n + 1)]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` n
      versionsOf c `shouldReturn` [1 .. n]
      settingsOf c `shouldReturn` [("quoted", "it's [[a]]")]
      -- And once the step is right, it is applied.
      applySteps (arrange files [rewriteStep (n + 1)]) c `shouldReturn` [n + 1]

  it "share the transaction of the files: a step in code that fails undoes the files applied before it" $
    emptyPlace backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
      result <- try @IOException (applySteps (arrange files [failingStep (length files + 1)]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 0
      runDb c tableNames `shouldReturn` []

  it "are refused when misnumbered, before the database is touched" $
    emptyPlace backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
      result <- try @StepsMisnumbered (applySteps (arrange files [noteStep (length files)]) c)
      case result of
        Left (StepsMisnumbered why) -> why `shouldSatisfy` T.isPrefixOf ("step " <> show (length files) <> " is both ")
        Right applied -> expectationFailure ("applied " <> show applied)
      runDb c tableNames `shouldReturn` []
