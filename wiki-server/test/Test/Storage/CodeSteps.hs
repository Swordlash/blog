{-# LANGUAGE DeriveAnyClass #-}

-- | The steps of the schema written in Haskell
-- ("Wiki.Server.Storage.Migrate.Code", issue #202): numbered with the
-- schema files, run after the files before them in the same transaction,
-- recorded as the files are, and all or nothing with them. Most steps here
-- are the tests' own, given to 'applySteps'. The program's own are tested
-- at the end, on rows written at the schema before them.
module Test.Storage.CodeSteps (unitSpec, spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, insert, insertValues, runInsert, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import System.IO.Error (userError)
import Test.Database (Backing, withConnectionTo)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture (withEmptyPlaceIn)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search (SearchHit (..), searchQuery)
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..), isHomeBody)
import Wiki.Core.Version (VersionInfo (..), latestVersions)
import Wiki.Server.Storage (StoredWiki, Who (..), defaultConfig, runStoredWiki, withStorage)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate
import Wiki.Server.Storage.Migrate.Code.Step0012 (homeBody, homeSearchText)
import Wiki.Server.Storage.Schema (SchemaDb (..), WikiSchema (..), schemaDb)

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

-- | A row of @spaces@ as the tests write it at version 11, before step 12:
-- the columns with no default, and the two that mark the kinds of space
-- that have no home page.
data OldSpace f = OldSpace
  { id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , name :: Columnar f Text
  , slug :: Columnar f Text
  , public :: Columnar f Bool
  , math_macros :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , subspace_order :: Columnar f Text
  , page_order :: Columnar f Text
  , home_page :: Columnar f (Maybe Text)
  , personal_container :: Columnar f Bool
  , key_id :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table OldSpace where
  newtype PrimaryKey OldSpace f = OldSpaceKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = OldSpaceKey r.id

-- | A row of @pages@ as it is at version 11 and 12, but for PostgreSQL's
-- generated @search_words@.
data OldPage f = OldPage
  { id :: Columnar f Text
  , space_id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , title :: Columnar f Text
  , slug :: Columnar f Text
  , body :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , updated_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , template :: Columnar f Bool
  , search_text :: Columnar f Text
  , search_fold :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

deriving stock instance Eq (OldPage Identity)

deriving stock instance Show (OldPage Identity)

instance Table OldPage where
  newtype PrimaryKey OldPage f = OldPageKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = OldPageKey r.id

-- | A row of @page_versions@ as it is at version 11 and 12.
data OldVersion f = OldVersion
  { page_id :: Columnar f Text
  , updated_at :: Columnar f UTCTime
  , title :: Columnar f Text
  , body :: Columnar f Text
  , author :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table OldVersion where
  data PrimaryKey OldVersion f = OldVersionKey (Columnar f Text) (Columnar f UTCTime)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = OldVersionKey r.page_id r.updated_at

data OldDb f = OldDb
  { spaces :: f (TableEntity OldSpace)
  , pages :: f (TableEntity OldPage)
  , page_versions :: f (TableEntity OldVersion)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

oldDb :: DatabaseSettings be OldDb
oldDb = defaultDbSettings

-- | A space of the tests at version 11: top-level, private, with no home
-- page.
oldSpace :: Text -> Text -> Text -> OldSpace Identity
oldSpace i name slug =
  OldSpace
    { id = i
    , parent = Nothing
    , name
    , slug
    , public = False
    , math_macros = ""
    , created_at = long
    , position = 0
    , subspace_order = "name"
    , page_order = "by-hand"
    , home_page = Nothing
    , personal_container = False
    , key_id = Nothing
    }

-- | A page of the tests at version 11: its id, its space, the page it is
-- under, its slug, its position, and whether it is a template.
oldPage :: Text -> Text -> Maybe Text -> Text -> Int32 -> Bool -> OldPage Identity
oldPage i space parent slug position template =
  OldPage
    { id = i
    , space_id = space
    , parent
    , title = "Page " <> slug
    , slug
    , body = "Text of " <> slug <> "."
    , created_at = long
    , updated_at = long
    , position
    , template
    , search_text = "Text of " <> slug <> "."
    , search_fold = "page " <> slug <> "\ntext of " <> slug <> "."
    }

-- | A time long before the tests run.
long :: UTCTime
long = UTCTime (fromGregorian 2026 1 1) 0

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
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
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
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
          n = length files
      _ <- applySteps (arrange files []) c
      writeSettings c [("plain", "no marker"), ("quoted", "it's [[a]] and [[b]]")]
      applySteps (reverse (arrange files [rewriteStep (n + 1)])) c `shouldReturn` [n + 1]
      settingsOf c `shouldReturn` [("plain", "no marker"), ("quoted", "it's {{a}} and {{b}}")]

  it "that fail leave the database at the version before them, and what they wrote is undone" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
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
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
      result <- try @IOException (applySteps (arrange files [failingStep (length files + 1)]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 0
      runDb c tableNames `shouldReturn` []

  step0012Spec backing

  it "are refused when misnumbered, before the database is touched" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
      result <- try @StepsMisnumbered (applySteps (arrange files [noteStep (length files)]) c)
      case result of
        Left (StepsMisnumbered why) -> why `shouldSatisfy` T.isPrefixOf ("step " <> show (length files) <> " is both ")
        Right applied -> expectationFailure ("applied " <> show applied)
      runDb c tableNames `shouldReturn` []

-- | Step 12 ("Wiki.Server.Storage.Migrate.Code.Step0012"): every space but
-- the container of personal spaces and an encrypted space gets a home
-- page, written on rows of version 11 in an empty database.
step0012Spec :: Backing -> SpecWith ()
step0012Spec backing = describe "step 12, every space has a home page" $ do
  it "gives each space with none the default one, at the next free slug and before its top-level pages, and leaves the rest alone" $
    withEmptyPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        let files = migrationsFor (schemaSuffix c)
        void (applySteps (arrange (filter (\m -> m.version <= 11) files) []) c)
        begin True c
        runDb c $ do
          runInsert . insert oldDb.spaces $
            insertValues
              [ oldSpace "empty" "Empty" "empty"
              , -- Set to "None" once, with the page it was made with still
                -- at home, a template at home-2, and positions set by
                -- hand among its top-level pages.
                oldSpace "kept" "Zażółć *gęślą* jaźń" "zazolc"
              , oldSpace "negative" "By hand" "by-hand"
              , (oldSpace "container" "User subspaces" "users") {personal_container = True}
              , (oldSpace "secret" "Secret" "secret") {key_id = Just "k1"}
              , oldSpace "homed" "Homed" "homed"
              ]
          runInsert . insert oldDb.pages $
            insertValues
              [ oldPage "kept-home" "kept" Nothing "home" 3 False
              , oldPage "kept-other" "kept" Nothing "notes" 5 False
              , oldPage "kept-template" "kept" Nothing "home-2" 7 True
              , -- Under a top-level page: not one of the siblings the
                -- home page's slug and position are chosen among.
                oldPage "kept-under" "kept" (Just "kept-home") "under" 1 False
              , oldPage "negative-intro" "negative" Nothing "intro" (-4) False
              , oldPage "secret-page" "secret" Nothing "x7f3" 0 False
              , oldPage "homed-start" "homed" Nothing "start" 0 False
              ]
          runUpdate (update oldDb.spaces (\x -> x.home_page <-. val_ (Just "homed-start")) (\x -> x.id ==. val_ "homed"))
        commitTransaction c
        written <- runDb c (runSelectReturningList (select (all_ oldDb.pages)))
        applySteps (stepsFor (schemaSuffix c)) c `shouldReturn` [12 .. knownVersion (schemaSuffix c)]
        spaces <- Map.fromList . map (\x -> (x.id, x.home_page)) <$> runDb c (runSelectReturningList (select (all_ oldDb.spaces)))
        pages <- runDb c (runSelectReturningList (select (all_ oldDb.pages)))
        versions <- runDb c (runSelectReturningList (select (all_ oldDb.page_versions)))
        let new = [x | x <- pages, x.id `notElem` map (\y -> y.id) written]
            homeOf sid = find (\x -> Just x.id == join (Map.lookup sid spaces)) new
        -- The pages there before are as they were.
        sortOn (\x -> x.id) [x | x <- pages, x.id `elem` map (\y -> y.id) written] `shouldBe` sortOn (\x -> x.id) written
        -- One new page for each of the three spaces with none, each the
        -- space's home page now, with one version, by nobody.
        length new `shouldBe` 3
        for_ ["empty", "kept", "negative"] $ \sid -> case homeOf sid of
          Nothing -> expectationFailure ("no home page for " <> toS sid)
          Just home -> do
            (home.space_id, home.parent, home.title, home.template) `shouldBe` (sid, Nothing, "Home", False)
            home.created_at `shouldBe` home.updated_at
            isHomeBody home.body `shouldBe` True
            [(v.updated_at, v.title, v.body, v.author) | v <- versions, v.page_id == home.id] `shouldBe` [(home.updated_at, "Home", home.body, Nothing)]
        let placed sid = (\x -> (x.slug, x.position, x.body, x.search_text)) <$> homeOf sid
        placed "empty" `shouldBe` Just ("home", 0, homeBody "Empty", homeSearchText "Empty")
        placed "kept" `shouldBe` Just ("home-3", 2, homeBody "Zażółć *gęślą* jaźń", homeSearchText "Zażółć *gęślą* jaźń")
        placed "negative" `shouldBe` Just ("home", -5, homeBody "By hand", homeSearchText "By hand")
        -- The container, the encrypted space and the space that had a home
        -- page keep what they had.
        (Map.lookup "container" spaces, Map.lookup "secret" spaces, Map.lookup "homed" spaces) `shouldBe` (Just Nothing, Just Nothing, Just (Just "homed-start"))
      -- The live program reads each new page as the home page a new space
      -- is made with, and finds it in a search, its name's diacritics and
      -- all.
      withStorage defaultConfig at $ \st -> do
        let asAdministrator :: StoredWiki IO a -> IO a
            asAdministrator = runStoredWiki st Administrator
            slug t = either (panic . show) identity (mkSlug t)
        kept <- asAdministrator (getSpace [slug "zazolc"]) >>= either (assertFailure . show) pure
        home <- asAdministrator (getPage kept.id [slug "home-3"]) >>= either (assertFailure . show) pure
        kept.homePage `shouldBe` Just home.id
        (home.title, isHomeBody home.body) `shouldBe` ("Home", True)
        listed <- asAdministrator (listVersions home.id latestVersions) >>= either (assertFailure . show) pure
        map (\v -> v.author) listed `shouldBe` [Nothing]
        for_ ["zazolc", "GĘŚLĄ jazn", "welcome"] $ \q -> do
          hits <- asAdministrator (searchPages (searchQuery q))
          map (\h -> h.page) hits `shouldContain` [home.id]

  it "runs once, and finds nothing to do in a database whose spaces all have home pages" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let known = knownVersion (schemaSuffix c)
      migrate c `shouldReturn` [1 .. known]
      runDb c (runSelectReturningList (select (all_ oldDb.pages))) `shouldReturn` []
      migrate c `shouldReturn` []
