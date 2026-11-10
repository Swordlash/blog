{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Migrate.Code.Step0012' is step 12 of the schema,
-- the first written in Haskell ('CodeStep'): every space has a home page
-- (WP5.78 of docs/PLAN.md, issue #201).
--
-- Before it, a space could have no home page: its administrator could
-- choose "None" in its settings, or delete the page or move it to another
-- space. After it, every space has one, except two kinds: the container of
-- personal spaces, which has no pages, and an encrypted space, where the
-- server cannot write a page. The step gives each other space with none
-- the page a new space is made with, as 'Wiki.Core.Space.defaultHomePage'
-- makes it: titled "Home", its text a welcome that names the space, with
-- one version, by no user.
--
-- The step follows the rules of 'CodeStep'. It reads and writes the three
-- tables it needs through row shapes declared here, as the tables are at
-- version 11, and never through "Wiki.Server.Storage.Schema". It carries
-- its own copy of the page's title and text, and of the text a search
-- reads, so that a change to the live defaults or to the live Markdown
-- parser does not change what it writes.
module Wiki.Server.Storage.Migrate.Code.Step0012
  ( step0012
  , homeTitle
  , homeBody
  , homeSearchText
  , homeSlug
  , homePosition
  )
where

import Control.Monad.UUID (generateV4)
import Data.Text qualified as T
import Data.Time (UTCTime (..), getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, filter_, insert, insertValues, isNothing_, runInsert, runSelectReturningList, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Protolude
import Wiki.Core.Search (foldText)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))

-- | The step: give every space with no home page, but the two kinds, the
-- default one.
step0012 :: CodeStep
step0012 = CodeStep {version = 12, name = "every space has a home page", run = giveHomePages}

--------------------------------------------------------------------------------
-- The tables, as they are at version 11

-- | A row of @spaces@: the columns the step reads, and @home_page@, which
-- it writes.
data SpaceRow f = SpaceRow
  { id :: Columnar f Text
  , name :: Columnar f Text
  , home_page :: Columnar f (Maybe Text)
  , personal_container :: Columnar f Bool
  -- ^ The container of personal spaces (migration 7), which gets none.
  , key_id :: Columnar f (Maybe Text)
  -- ^ Set for an encrypted space (migration 11), which gets none.
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SpaceRow where
  newtype PrimaryKey SpaceRow f = SpaceKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SpaceKey r.id

-- | A row of @pages@, whole but for PostgreSQL's @search_words@, which the
-- database makes from @search_fold@.
data PageRow f = PageRow
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

instance Table PageRow where
  newtype PrimaryKey PageRow f = PageKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PageKey r.id

-- | A row of @page_versions@. The author is a user's id, or @NULL@ for a
-- version no user saved, as an imported page's first version is.
data VersionRow f = VersionRow
  { page_id :: Columnar f Text
  , updated_at :: Columnar f UTCTime
  , title :: Columnar f Text
  , body :: Columnar f Text
  , author :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table VersionRow where
  data PrimaryKey VersionRow f = VersionKey (Columnar f Text) (Columnar f UTCTime)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = VersionKey r.page_id r.updated_at

data StepDb f = StepDb
  { spaces :: f (TableEntity SpaceRow)
  , pages :: f (TableEntity PageRow)
  , page_versions :: f (TableEntity VersionRow)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

stepDb :: DatabaseSettings be StepDb
stepDb = defaultDbSettings

--------------------------------------------------------------------------------
-- The page

-- | The home page's title, as a new space's was at version 12.
homeTitle :: Text
homeTitle = "Home"

-- | The home page's Markdown for a space of this name, as a new space's
-- was at version 12: a welcome that names the space. The live
-- 'Wiki.Core.Space.isHomeBody' recognises it as a home page nobody has
-- written yet, which a blog's view leaves out.
homeBody :: Text -> Text
homeBody name =
  T.unlines
    [ "Welcome to **" <> T.strip name <> "**."
    , ""
    , "This is the space's home page, the page it opens at. Edit it to say what the space is for and where to start reading."
    ]

-- | The text a search reads of 'homeBody', made without a Markdown parser:
-- the body's words without its syntax, on one line, as
-- 'Wiki.Core.Search.bodyText' gives them. The step writes the body itself,
-- so its syntax is known: two lines and the bold around the name. The
-- name is taken as plain text. A name with Markdown in it (@*x*@, a
-- backtick) keeps those characters here, where the parser would have left
-- them out; a search still finds the name's words, and the next save of
-- the page makes the text again with the parser of its day.
homeSearchText :: Text -> Text
homeSearchText name =
  T.unwords (T.words ("Welcome to " <> T.strip name <> ". This is the space's home page, the page it opens at. Edit it to say what the space is for and where to start reading."))

-- | The home page's slug among the slugs of the space's top-level pages:
-- @home@, or @home-2@, @home-3@ and so on where it is taken. A space set
-- to have no home page may still hold the page it was made with, at
-- @home@; a second @home@ would break the unique index on siblings' slugs.
homeSlug :: [Text] -> Text
homeSlug taken = fromMaybe "home" (find (`notElem` taken) ("home" : ["home-" <> show n | n <- [2 :: Int ..]]))

-- | The home page's position among the space's top-level pages: before
-- them all, so that a space ordered by hand lists it first; 0 in a space
-- with none.
homePosition :: [Int32] -> Int32
homePosition = maybe 0 (subtract 1) . minimumMay

--------------------------------------------------------------------------------
-- The step

giveHomePages :: forall be. (Backend be) => Connection be -> IO ()
giveHomePages c = do
  now <- toMicroseconds <$> getCurrentTime
  runDb c $ do
    homeless <-
      runSelectReturningList . select $
        filter_ (\s -> isNothing_ s.home_page &&. s.personal_container ==. val_ False &&. isNothing_ s.key_id) (all_ stepDb.spaces)
    for_ homeless $ \space -> do
      topLevel <- runSelectReturningList . select $ filter_ (\p -> p.space_id ==. val_ space.id &&. isNothing_ p.parent) (all_ stepDb.pages)
      pid <- liftIO (UUID.toText <$> generateV4)
      let searchText = homeSearchText space.name
          body = homeBody space.name
      runInsert . insert stepDb.pages $
        insertValues
          [ PageRow
              { id = pid
              , space_id = space.id
              , parent = Nothing
              , title = homeTitle
              , slug = homeSlug (map (\p -> p.slug) topLevel)
              , body
              , created_at = now
              , updated_at = now
              , position = homePosition (map (\p -> p.position) topLevel)
              , template = False
              , search_text = searchText
              , -- The fold is the live one ('foldText'): the search folds
                -- each query with the live one, and compares the two. It
                -- is not Markdown and has no syntax to go stale. A change
                -- to the fold changes what every page's must be, which a
                -- step of its own would then write.
                search_fold = foldText homeTitle <> "\n" <> foldText searchText
              }
          ]
      runInsert (insert stepDb.page_versions (insertValues [VersionRow {page_id = pid, updated_at = now, title = homeTitle, body, author = Nothing}]))
      runUpdate (update stepDb.spaces (\s -> s.home_page <-. val_ (Just pid)) (\s -> s.id ==. val_ space.id))

-- | A time to the microsecond, the finest both databases keep, so that the
-- page's time and its version's are the same once read back.
toMicroseconds :: UTCTime -> UTCTime
toMicroseconds t = t {utctDayTime = fromIntegral (floor (utctDayTime t * 1000000) :: Integer) / 1000000}
