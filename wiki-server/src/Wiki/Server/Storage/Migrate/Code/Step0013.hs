{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Migrate.Code.Step0013' is step 13 of the schema,
-- written in Haskell ('CodeStep'): each space's home page becomes the root
-- of its pages (WP5.78 of docs/PLAN.md, part b; issue #201).
--
-- Before it, a space had any number of top-level pages, and its home page
-- could be one of them or a page under another. After it, the home page is
-- the only page of the space with no parent, and every other page is
-- under it. The home page has no segment in addresses, so a page that was
-- top-level keeps its address. The step changes, for each space with a
-- home page:
--
-- * the home page, which is taken from under its parent if it had one;
-- * every other top-level page, which goes under the home page with its
--   slug, keeping its position;
-- * the pages that were under the home page, which come after those: their
--   positions move past the others'. One whose slug a top-level page has
--   gets the next free slug (@notes-2@, @notes-3@ and so on), since the
--   top-level page's address must not change.
--
-- The container of personal spaces and an encrypted space have no home
-- page and are left alone. So is a space whose home page is not one of its
-- own pages, which no program has made, and a space where nothing changes.
-- No page's text, title or history changes.
--
-- The step follows the rules of 'CodeStep'. It reads and writes the two
-- tables it needs through row shapes declared here, as the tables are at
-- version 12, and never through "Wiki.Server.Storage.Schema". It carries
-- its own copy of the rule, and of how a free slug is chosen
-- ('Wiki.Core.Slug.freshSlug'), so that a change to the live ones does not
-- change what it writes. Each change is one row, written in an order that
-- keeps the unique index on siblings' slugs true after every statement:
-- PostgreSQL checks it there, not at the end of the transaction. When a
-- space still has a page with no parent but its home page afterwards, the
-- step fails, and the whole migration with it.
module Wiki.Server.Storage.Migrate.Code.Step0013
  ( step0013
  , PageAt (..)
  , rooting
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, filter_, isJust_, isNothing_, runSelectReturningList, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Protolude
import System.IO.Error (userError)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))

-- | The step: make each space's home page the root of its pages.
step0013 :: CodeStep
step0013 = CodeStep {version = 13, name = "the home page is the root of a space's pages", run = \c -> [] <$ rootPages c}

--------------------------------------------------------------------------------
-- The tables, as they are at version 12

-- | A row of @spaces@: the columns the step reads.
data SpaceRow f = SpaceRow
  { id :: Columnar f Text
  , home_page :: Columnar f (Maybe Text)
  , personal_container :: Columnar f Bool
  -- ^ The container of personal spaces (migration 7), which has no home
  -- page.
  , key_id :: Columnar f (Maybe Text)
  -- ^ Set for an encrypted space (migration 11), which has no home page.
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SpaceRow where
  newtype PrimaryKey SpaceRow f = SpaceKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SpaceKey r.id

-- | A row of @pages@: where a page is, the columns the step reads and
-- writes.
data PageRow f = PageRow
  { id :: Columnar f Text
  , space_id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , slug :: Columnar f Text
  , position :: Columnar f Int32
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PageRow where
  newtype PrimaryKey PageRow f = PageKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PageKey r.id

data StepDb f = StepDb
  { spaces :: f (TableEntity SpaceRow)
  , pages :: f (TableEntity PageRow)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

stepDb :: DatabaseSettings be StepDb
stepDb = defaultDbSettings

--------------------------------------------------------------------------------
-- The rule

-- | 'PageAt' is where a page of a space is: its id, its parent, its slug
-- and its position among its siblings.
data PageAt = PageAt
  { page :: Text
  , parent :: Maybe Text
  , slug :: Text
  , position :: Int32
  }
  deriving stock (Eq, Show)

-- | 'rooting' is what the step changes in one space: given its home page's
-- id and where each of its pages is, the pages that move, each where it
-- goes, in the order to write them. Empty when the home page is not among
-- the pages, or is the only page with no parent already.
--
-- The order keeps siblings' slugs unique after each write. The pages under
-- the home page are renamed first, to slugs nobody under it has or will
-- have. The other top-level pages then go under it, where their slugs are
-- free. The home page leaves its parent last, when nothing else is at the
-- top level.
rooting :: Text -> [PageAt] -> [PageAt]
rooting homeId pages = case find (\p -> p.page == homeId) pages of
  Nothing -> []
  Just home
    | null others && isNothing home.parent -> []
    | otherwise -> [q | p <- below, let { q = moved p }, q /= p] <> [at p (Just homeId) p.slug p.position | p <- others] <> [at home Nothing home.slug home.position | isJust home.parent]
  where
    others = [p | p <- pages, isNothing p.parent, p.page /= homeId]
    below = [p | p <- pages, p.parent == Just homeId]
    kept = Set.fromList (map (\p -> p.slug) others)
    -- The pages under the home page whose slug a top-level page has, in
    -- the order of their slugs and ids, each given the next slug free among
    -- all the home page's pages to be.
    clashing = sortOn (\p -> (p.slug, p.page)) [p | p <- below, p.slug `Set.member` kept]
    renamed = snd (foldl' rename (kept <> Set.fromList (map (\p -> p.slug) below), Map.empty) clashing)
    rename (taken, done) p = let s = freeSlug taken p.slug in (Set.insert s taken, Map.insert p.page s done)
    -- How far the pages under the home page move, so that every one of
    -- them comes after every page that was top-level.
    past = case (maximumMay (map (\p -> p.position) others), minimumMay (map (\p -> p.position) below)) of
      (Just top, Just low) -> max 0 (top - low + 1)
      _ -> 0
    moved p = at p p.parent (Map.findWithDefault p.slug p.page renamed) (p.position + past)
    at p parent slug position = PageAt {page = p.page, parent, slug, position}

-- | The slug, or the first of @slug-2@, @slug-3@ and so on that is not
-- taken: the step's copy of 'Wiki.Core.Slug.freshSlug' as it is at
-- version 13.
freeSlug :: Set Text -> Text -> Text
freeSlug taken base = fromMaybe base (find (`Set.notMember` taken) (base : [base <> "-" <> show n | n <- [2 :: Int ..]]))

--------------------------------------------------------------------------------
-- The step

rootPages :: forall be. (Backend be) => Connection be -> IO ()
rootPages c = do
  homed <-
    runDb c . runSelectReturningList . select $
      filter_ (\s -> isJust_ s.home_page &&. s.personal_container ==. val_ False &&. isNothing_ s.key_id) (all_ stepDb.spaces)
  for_ homed $ \space -> for_ space.home_page $ \homeId -> do
    rows <- runDb c (runSelectReturningList (select (filter_ (\p -> p.space_id ==. val_ space.id) (all_ stepDb.pages))))
    let at = [PageAt {page = r.id, parent = r.parent, slug = r.slug, position = r.position} | r <- rows]
        changes = rooting homeId at
    runDb c . for_ changes $ \p ->
      runUpdate (update stepDb.pages (\r -> mconcat [r.parent <-. val_ p.parent, r.slug <-. val_ p.slug, r.position <-. val_ p.position]) (\r -> r.id ==. val_ p.page))
    -- The rule leaves one page with no parent: the home page. One more
    -- means the step went wrong, and the migration stops before it is
    -- committed.
    unless (null changes) $ do
      roots <- runDb c (runSelectReturningList (select (filter_ (\p -> p.space_id ==. val_ space.id &&. isNothing_ p.parent) (all_ stepDb.pages))))
      unless (map (\r -> r.id) roots == [homeId]) $
        throwIO (userError ("step 13: the space " <> toS space.id <> " still has pages with no parent but its home page"))
