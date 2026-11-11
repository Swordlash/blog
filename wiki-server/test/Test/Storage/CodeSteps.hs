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
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Id (PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search (SearchHit (..), searchQuery)
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..), isHomeBody)
import Wiki.Core.User (Login (..), parseLogin)
import Wiki.Core.Version (VersionInfo (..), latestVersions)
import Wiki.Server.Storage (CheckProblem (..), Migrated (..), StoredWiki, Who (..), checkDatabase, defaultConfig, migrateDatabase, runStoredWiki, withStorage)
import Wiki.Server.Storage.Audit (loadAuditLog)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate
import Wiki.Server.Storage.Migrate.Code.Step0012 (homeBody, homeSearchText)
import Wiki.Server.Storage.Migrate.Code.Step0015 (Renamed (..), loginKept, renamedLogins)
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
    , run = \c -> [] <$ runDb c (runInsert (insert pinnedDb.settings (insertValues [PinnedSetting {key = "code-step", value = "ran"}])))
    }

-- | A step in code that rewrites every setting's value from an old syntax
-- to a new one, @[[x]]@ to @{{x}}@, with a rewriter of its own, as a step
-- that rewrites pages carries its own.
rewriteStep :: Int -> CodeStep
rewriteStep n = CodeStep {version = n, name = "rewrite the old markers", run = \c -> [] <$ rewriteSettings c}

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
      code n = CodeStep {version = n, name = "code " <> show n, run = \_ -> pure []}
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
  step0015UnitSpec

-- | Step 15's rule and its new logins, which touch no database.
step0015UnitSpec :: Spec
step0015UnitSpec = describe "step 15's rule of a login" $ do
  it "is today's rule of a stored login: it keeps what parseLogin keeps as it is, and nothing else" $ do
    -- When parseLogin changes, this fails: the step keeps its rule of
    -- 2026-11-06, and the test is changed to say how the two now differ.
    let corpus =
          ["ada", "Ada", "rita@example.org", "_a_", "a", "0", "user-1a2b3c4d", "a!~", T.replicate 64 "a", T.replicate 65 "a", "", " ", " ada", "ada ", "ada lovelace", "ada\tb", "ada\nb", "a\DELb", "a\x85" <> "b", "a\xa0" <> "b", "łucja", "zoë", "иван", "日本", "___", "...", "~x", "x~", "~", "a\x2028" <> "b"]
            <> [T.singleton c <> "a" | c <- ['\0' .. '\x7f']]
    [t | t <- corpus, loginKept t /= (parseLogin t == Right (Login t))] `shouldBe` []
  it "gives user- and the first eight ASCII letters and digits of the id, in the order of the ids" $
    renamedLogins [("1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", "łucja"), ("0f0f0f0f-0000-4000-8000-000000000000", "zoë"), ("u", "ada")]
      `shouldBe` [ Renamed {user = "0f0f0f0f-0000-4000-8000-000000000000", was = "zoë", now = "user-0f0f0f0f"}
                 , Renamed {user = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d", was = "łucja", now = "user-1a2b3c4d"}
                 ]
  it "never gives two users one login, nor one a kept login has in another case, nor one the rule refuses" $ do
    -- Thousands of users whose ids share their first eight letters and
    -- digits, in both cases, beside kept logins that take some of the new
    -- ones, and ids with no ASCII letter or digit.
    let broken = [("deadbeef-" <> show n, "ł" <> show n) | n <- [1 .. 3000 :: Int]] <> [("DEADBEEF-" <> show n, "ż" <> show n) | n <- [1 .. 50 :: Int]] <> [(T.replicate n "-", "ę" <> show n) | n <- [1 .. 20]]
        kept = [("k" <> show n, l) | (n, l) <- zip [1 :: Int ..] ["USER-DEADBEEF", "user-deadbeef-3", "User-1", "ada"]]
        renamed = renamedLogins (kept <> broken)
        logins = map snd kept <> map (\r -> r.now) renamed
    length renamed `shouldBe` length broken
    all (\r -> loginKept r.now && isRight (parseLogin r.now)) renamed `shouldBe` True
    length (ordNub (map T.toLower logins)) `shouldBe` length logins
    -- Ids sort by their characters: DEADBEEF-1, DEADBEEF-10, DEADBEEF-11.
    take 3 [r.now | r <- renamed, "DEADBEEF" `T.isPrefixOf` r.user] `shouldBe` ["user-DEADBEEF-2", "user-DEADBEEF-4", "user-DEADBEEF-5"]
    [r.now | r <- renamed, T.all (== '-') r.user] `shouldBe` ["user-2", "user-3", "user-4"] <> ["user-" <> show n | n <- [5 .. 21 :: Int]]
  it "renames the same users the same way, whatever order they are read in" $ do
    let users = [("b", "ł"), ("a", "ż"), ("c", "ok"), ("A", "ę")]
    renamedLogins (reverse users) `shouldBe` renamedLogins users

spec :: Backing -> Spec
spec backing = describe "the schema's steps in code" $ do
  -- The program's own steps, files and code, and a test's step after the
  -- last of them.
  it "run after the files numbered before them, and are recorded as the files are" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let steps = stepsFor (schemaSuffix c)
          n = knownVersion (schemaSuffix c)
      applySteps (steps <> arrange [] [noteStep (n + 1)]) c `shouldReturn` [1 .. n + 1]
      settingsOf c `shouldReturn` [("code-step", "ran")]
      schemaVersion c `shouldReturn` n + 1
      databaseVersion c `shouldReturn` n + 1
      versionsOf c `shouldReturn` [1 .. n + 1]
      -- Applied once only, in whatever order the steps are given.
      applySteps (reverse (steps <> arrange [] [noteStep (n + 1)])) c `shouldReturn` []

  it "read and rewrite rows written before them, through tables of their own" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let steps = stepsFor (schemaSuffix c)
          n = knownVersion (schemaSuffix c)
      _ <- applySteps steps c
      writeSettings c [("plain", "no marker"), ("quoted", "it's [[a]] and [[b]]")]
      applySteps (reverse (steps <> arrange [] [rewriteStep (n + 1)])) c `shouldReturn` [n + 1]
      settingsOf c `shouldReturn` [("plain", "no marker"), ("quoted", "it's {{a}} and {{b}}")]

  it "that fail leave the database at the version before them, and what they wrote is undone" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let steps = stepsFor (schemaSuffix c)
          n = knownVersion (schemaSuffix c)
      _ <- applySteps steps c
      writeSettings c [("quoted", "it's [[a]]")]
      result <- try @IOException (applySteps (steps <> arrange [] [failingStep (n + 1)]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` n
      versionsOf c `shouldReturn` [1 .. n]
      settingsOf c `shouldReturn` [("quoted", "it's [[a]]")]
      -- And once the step is right, it is applied.
      applySteps (steps <> arrange [] [rewriteStep (n + 1)]) c `shouldReturn` [n + 1]

  it "share the transaction of the files: a step in code that fails undoes the files applied before it" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let steps = stepsFor (schemaSuffix c)
      result <- try @IOException (applySteps (steps <> arrange [] [failingStep (knownVersion (schemaSuffix c) + 1)]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 0
      runDb c tableNames `shouldReturn` []

  step0012Spec backing
  step0013Spec backing
  step0015Spec backing

  it "are refused when misnumbered, before the database is touched" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      let files = migrationsFor (schemaSuffix c)
          lastFile = maybe 0 (\m -> m.version) (lastMay files)
      result <- try @StepsMisnumbered (applySteps (arrange files [noteStep lastFile]) c)
      case result of
        Left (StepsMisnumbered why) -> why `shouldSatisfy` T.isPrefixOf ("step " <> show lastFile <> " is both ")
        Right applied -> expectationFailure ("applied " <> show applied)
      runDb c tableNames `shouldReturn` []

-- | The steps numbered up to this one.
upTo :: Int -> [Step] -> [Step]
upTo n = filter (\s -> stepNumber s <= n)

-- | Where each page is: its parent, its slug and its position, by id.
placesOf :: (Backend be) => Connection be -> IO (Map Text (Maybe Text, Text, Int32))
placesOf c = Map.fromList . map (\p -> (p.id, (p.parent, p.slug, p.position))) <$> runDb c (runSelectReturningList (select (all_ oldDb.pages)))

-- | Rows at version 12, as step 13 finds them: a space ordered by hand
-- with two top-level pages beside its home page, and two pages under the
-- home page, one with a top-level page's slug and one with the slug the
-- first would be renamed to; a space whose home page is under a top-level
-- page; a space whose home page is its root already; an encrypted space
-- with two top-level pages; and the container of personal spaces.
writeVersion12 :: (Backend be) => Connection be -> IO ()
writeVersion12 c = do
  void (applySteps (upTo 12 (stepsFor (schemaSuffix c))) c)
  begin True c
  runDb c $ do
    runInsert . insert oldDb.spaces $
      insertValues
        [ oldSpace "plain" "Plain" "plain"
        , oldSpace "nested" "Nested" "nested"
        , oldSpace "rooted" "Rooted" "rooted"
        , (oldSpace "secret" "Secret" "secret") {key_id = Just "k1"}
        , (oldSpace "container" "User subspaces" "users") {personal_container = True}
        ]
    runInsert . insert oldDb.pages $
      insertValues
        [ oldPage "p-home" "plain" Nothing "home" 0 False
        , oldPage "p-about" "plain" Nothing "about" 1 False
        , oldPage "p-notes" "plain" Nothing "notes" 2 False
        , oldPage "p-c" "plain" (Just "p-home") "notes" 0 False
        , oldPage "p-d" "plain" (Just "p-home") "notes-2" 1 False
        , oldPage "p-deep" "plain" (Just "p-c") "deep" 0 False
        , oldPage "n-top" "nested" Nothing "top" 0 False
        , oldPage "n-home" "nested" (Just "n-top") "home" 0 False
        , oldPage "n-x" "nested" (Just "n-home") "x" 0 False
        , oldPage "r-home" "rooted" Nothing "home" 0 False
        , oldPage "r-a" "rooted" (Just "r-home") "a" 0 False
        , oldPage "s-1" "secret" Nothing "x7f3" 0 False
        , oldPage "s-2" "secret" Nothing "q9z1" 1 False
        ]
    for_ [("plain", "p-home"), ("nested", "n-home"), ("rooted", "r-home")] $ \(sid, home) ->
      runUpdate (update oldDb.spaces (\x -> x.home_page <-. val_ (Just home)) (\x -> x.id ==. val_ sid))
  commitTransaction c

-- | Step 13 ("Wiki.Server.Storage.Migrate.Code.Step0013"): each space's home
-- page becomes the root of its pages, written on rows of version 12 in an
-- empty database.
step0013Spec :: Backing -> SpecWith ()
step0013Spec backing = describe "step 13, the home page is the root of a space's pages" $ do
  it "puts the other top-level pages under the home page, renames a clashing page under it, and leaves the rest alone" $
    withEmptyPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        writeVersion12 c
        written <- runDb c (runSelectReturningList (select (all_ oldDb.pages)))
        applySteps (upTo 13 (stepsFor (schemaSuffix c))) c `shouldReturn` [13]
        places <- placesOf c
        let placed i = Map.lookup i places
        -- The home page alone at the top; the top-level pages under it,
        -- with their slugs and positions; the home page's own pages after
        -- them, the one with a top-level page's slug at the next free one.
        placed "p-home" `shouldBe` Just (Nothing, "home", 0)
        placed "p-about" `shouldBe` Just (Just "p-home", "about", 1)
        placed "p-notes" `shouldBe` Just (Just "p-home", "notes", 2)
        placed "p-c" `shouldBe` Just (Just "p-home", "notes-3", 3)
        placed "p-d" `shouldBe` Just (Just "p-home", "notes-2", 4)
        placed "p-deep" `shouldBe` Just (Just "p-c", "deep", 0)
        -- A home page under a page comes out from under it, and that page
        -- goes under the home page.
        placed "n-home" `shouldBe` Just (Nothing, "home", 0)
        placed "n-top" `shouldBe` Just (Just "n-home", "top", 0)
        placed "n-x" `shouldBe` Just (Just "n-home", "x", 1)
        -- A space rooted already, an encrypted one, and the container keep
        -- what they had.
        placed "r-home" `shouldBe` Just (Nothing, "home", 0)
        placed "r-a" `shouldBe` Just (Just "r-home", "a", 0)
        placed "s-1" `shouldBe` Just (Nothing, "x7f3", 0)
        placed "s-2" `shouldBe` Just (Nothing, "q9z1", 1)
        -- No page's text, title or search text changes.
        after' <- runDb c (runSelectReturningList (select (all_ oldDb.pages)))
        sortOn fst [(p.id, (p.title, p.body, p.search_text, p.search_fold, p.updated_at)) | p <- after']
          `shouldBe` sortOn fst [(p.id, (p.title, p.body, p.search_text, p.search_fold, p.updated_at)) | p <- written]
        -- The steps after it, which the program and its check need.
        void (applySteps (stepsFor (schemaSuffix c)) c)
      -- The live program reads every page at its address from under the
      -- home page, and an old address through the rule for old ones.
      checkDatabase at >>= (`shouldSatisfy` isRight)
      withStorage defaultConfig at $ \st -> do
        let asAdministrator :: StoredWiki IO a -> IO a
            asAdministrator = runStoredWiki st Administrator
            slug t = either (panic . show) identity (mkSlug t)
            at' sid path = fmap (\p -> p.id.text) <$> asAdministrator (getPage (SpaceId sid) (map slug path))
        at' "plain" [] `shouldReturn` Right "p-home"
        at' "plain" ["notes"] `shouldReturn` Right "p-notes"
        at' "plain" ["notes-3"] `shouldReturn` Right "p-c"
        at' "plain" ["notes-3", "deep"] `shouldReturn` Right "p-deep"
        -- The old addresses of the pages under the home page.
        at' "plain" ["home"] `shouldReturn` Right "p-home"
        at' "plain" ["home", "notes-2"] `shouldReturn` Right "p-d"
        -- The renamed page's old address now leads to the page that was
        -- at the top and kept the slug, and its pages' old addresses lead
        -- nowhere (a known gap).
        at' "plain" ["home", "notes"] `shouldReturn` Right "p-notes"
        at' "plain" ["home", "notes", "deep"] `shouldReturn` Left NotFound
        at' "nested" [] `shouldReturn` Right "n-home"
        at' "nested" ["top"] `shouldReturn` Right "n-top"
        at' "nested" ["x"] `shouldReturn` Right "n-x"

  it "is undone with the rest of the migration when a later step fails" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      writeVersion12 c
      before' <- placesOf c
      result <- try @IOException (applySteps (upTo 13 (stepsFor (schemaSuffix c)) <> arrange [] [failingStep 14]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 12
      placesOf c `shouldReturn` before'

  it "is refused by the storage and reported by the check when a space has a second page with no parent" $
    withEmptyPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        writeVersion12 c
        void (applySteps (stepsFor (schemaSuffix c)) c)
        -- A second root, which only a row's update can make.
        begin True c
        runScript c "UPDATE pages SET parent = NULL WHERE id = 'p-about';"
        commitTransaction c
      checkDatabase at >>= \case
        Left (BrokenRecords [line]) -> line `shouldSatisfy` T.isInfixOf "p-about"
        other -> expectationFailure ("the check said " <> show other)
      withStorage defaultConfig at $ \st -> do
        made <- runStoredWiki st Administrator (createPage (SpaceId "plain") Nothing "Another" "")
        made `shouldSatisfy` either (\case Invalid why -> "home page" `T.isInfixOf` why; _ -> False) (const False)

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
        applySteps (upTo 12 (stepsFor (schemaSuffix c))) c `shouldReturn` [12]
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

-- | A row of @users@ as the tests write it at version 14, before step 15:
-- the columns with no default.
data OldUser f = OldUser
  { id :: Columnar f Text
  , login :: Columnar f Text
  , display_name :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table OldUser where
  newtype PrimaryKey OldUser f = OldUserKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = OldUserKey r.id

newtype UsersDb f = UsersDb
  { users :: f (TableEntity OldUser)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

usersDb :: DatabaseSettings be UsersDb
usersDb = defaultDbSettings

-- | A database at version 14, as step 15 finds it, with these users, each
-- an id and a login.
writeVersion14 :: (Backend be) => Connection be -> [(Text, Text)] -> IO ()
writeVersion14 c users = do
  void (applySteps (upTo 14 (stepsFor (schemaSuffix c))) c)
  begin True c
  runDb c (runInsert (insert usersDb.users (insertValues [OldUser {id = i, login = l, display_name = "Name of " <> i} | (i, l) <- users])))
  commitTransaction c

-- | Every user's login, by id.
loginsOf :: (Backend be) => Connection be -> IO [(Text, Text)]
loginsOf c = sort . map (\u -> (u.id, u.login)) <$> runDb c (runSelectReturningList (select (all_ usersDb.users)))

-- | Step 15 ("Wiki.Server.Storage.Migrate.Code.Step0015"): every login
-- breaking the rule of a login gets @user-@ and eight of its id, written
-- on rows of version 14 in an empty database.
step0015Spec :: Backing -> SpecWith ()
step0015Spec backing = describe "step 15, every login is ASCII" $ do
  it "changes nothing, says nothing and writes no entry where every login follows the rule" $
    withEmptyPlaceIn backing $ \at -> do
      let users = [("u1", "ada"), ("u2", "Bob"), ("u3", "rita@example.org")]
      withConnectionTo at $ \c -> writeVersion14 c users
      migrated <- migrateDatabase at
      (migrated.from, migrated.said) `shouldBe` (14, [])
      withConnectionTo at $ \c -> do
        loginsOf c `shouldReturn` users
        runDb c loadAuditLog `shouldReturn` []

  it "renames a login beyond ASCII to user- and eight of its id, says so, and writes it in the audit log; the check then passes" $
    withEmptyPlaceIn backing $ \at -> do
      let lucja = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
      withConnectionTo at $ \c -> writeVersion14 c [(lucja, "łucja"), ("u2", "ada")]
      migrated <- migrateDatabase at
      migrated.said
        `shouldBe` ["Renamed the login \"łucja\" of the user 1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d to \"user-1a2b3c4d\": a login has only ASCII letters, digits and punctuation now. The user signs in with the same password under the new login."]
      withConnectionTo at $ \c -> do
        loginsOf c `shouldReturn` [(lucja, "user-1a2b3c4d"), ("u2", "ada")]
        entries <- runDb c loadAuditLog
        [(e.actor, e.action, e.subject, e.detail, e.address) | e <- entries]
          `shouldBe` [(Actor {id = UserId "~administrator", login = Login "administrator"}, "user.rename", Subject {kind = "user", id = Just lucja, name = "user-1a2b3c4d"}, Map.fromList [("was", "łucja")], "migration")]
      checkDatabase at >>= (`shouldSatisfy` isRight)

  it "gives the next free login to two users whose new logins collide, to one whose id has no ASCII letter or digit, and past a login taken in another case" $
    withEmptyPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        writeVersion14
          c
          [ ("deadbeef-0000-4000-8000-000000000000", "łucja")
          , ("deadbeef-1111-4000-8000-000000000000", "zoë")
          , ("ąę-ł", "żaneta")
          , ("k1", "USER-DEADBEEF")
          , ("k2", "User-1")
          , ("x1", "~tilde")
          , ("x2", "___")
          , ("x3", T.replicate 65 "a")
          ]
        applySteps (upTo 15 (stepsFor (schemaSuffix c))) c `shouldReturn` [15]
        loginsOf c
          `shouldReturn` sort
            [ ("deadbeef-0000-4000-8000-000000000000", "user-deadbeef-2")
            , ("deadbeef-1111-4000-8000-000000000000", "user-deadbeef-3")
            , ("ąę-ł", "user-2")
            , ("k1", "USER-DEADBEEF")
            , ("k2", "User-1")
            , ("x1", "user-x1")
            , ("x2", "user-x2")
            , ("x3", "user-x3")
            ]
        runDb c (length <$> loadAuditLog) `shouldReturn` 6
        void (applySteps (stepsFor (schemaSuffix c)) c)
      checkDatabase at >>= (`shouldSatisfy` isRight)

  it "is undone with the rest of the migration when a later step fails" $
    withEmptyPlaceIn backing $ \at -> withConnectionTo at $ \c -> do
      writeVersion14 c [("u1", "łucja")]
      result <- try @IOException (applySteps (upTo 15 (stepsFor (schemaSuffix c)) <> arrange [] [failingStep 16]) c)
      result `shouldSatisfy` isLeft
      schemaVersion c `shouldReturn` 14
      loginsOf c `shouldReturn` [("u1", "łucja")]
      runDb c loadAuditLog `shouldReturn` []

  it "leaves a login written by hand afterwards to the check, which refuses it, naming the account" $
    withEmptyPlaceIn backing $ \at -> do
      withConnectionTo at $ \c -> do
        writeVersion14 c [("u1", "ada")]
        void (applySteps (stepsFor (schemaSuffix c)) c)
      checkDatabase at >>= (`shouldSatisfy` isRight)
      withConnectionTo at $ \c -> do
        begin True c
        runDb c (runUpdate (update usersDb.users (\u -> u.login <-. val_ "łucja") (\u -> u.id ==. val_ "u1")))
        commitTransaction c
      checkDatabase at
        `shouldReturn` Left (BrokenRecords ["The account łucja (u1) has a login the rules of a login refuse: A login has only ASCII letters, digits and punctuation."])
