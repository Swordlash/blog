{-# LANGUAGE TemplateHaskell #-}

-- | Bringing an archive into a wiki that has content already, in two steps.
--
-- An archive ("Wiki.Core.Export") is brought into the server by merging, not
-- by replacing what is there (the demo's own import replaces everything).
-- First the client asks for a /preview/: the server reads the archive and
-- answers with an 'ImportPlan', the archive's spaces with their pages, each
-- marked against the server's content as new, as present on both sides, or
-- (for a page) as a conflict. The dialog shows the plan with a checkbox for
-- each space and page, all checked, and for each conflict a choice between
-- the server's page and the imported one, the server's by default. Then the
-- client /applies/ the import with the same archive and its
-- 'ImportChoices'; the server carries it out in one transaction and answers
-- with an 'ImportSummary'.
--
-- Spaces and pages are matched by path, which is what "present on both
-- sides" means: a space at the same path of slugs from the top level, a
-- page at the same path within that space. Ids are never matched: the
-- archive's are another wiki's. So the choices name spaces and pages by
-- path too.
--
-- The rules for what an import does are WP2.8's (docs/PLAN.md); in short: a
-- new space is made with its pages; a space on both sides is merged, its
-- pages added and its settings kept the server's unless the server's are
-- empty; a page on both sides is a conflict, resolved as chosen;
-- attachments follow their pages by content hash; positions follow the
-- archive's order after the server's. The archive's users, groups and
-- grants are not imported.
--
-- The server keeps nothing between the steps, so the archive is sent twice;
-- and the plan is computed again when the import is applied, against the
-- server's content as it is then. A conflict that has appeared since the
-- preview, and so has no choice made for it, keeps the server's page, as
-- the dialog's default would have.
module Wiki.Api.Import
  ( -- * The preview
    ImportPlan (..)
  , SpacePlan (..)
  , SpaceStatus (..)
  , PagePlan (..)
  , PageConflict (..)

    -- * The choices
  , ImportChoices (..)
  , importEverything
  , PageRef (..)
  , ConflictChoice (..)
  , Resolution (..)

    -- * The outcome
  , ImportSummary (..)
  )
where

import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Json (defaultOptions, deriveValueJSON)
import Wiki.Core.Slug (Slug)

-- | What an import of an archive would do: its spaces, each before its
-- subspaces (the order of the archive's tree, as @listSpaces@ gives a
-- wiki's), each with its pages.
newtype ImportPlan = ImportPlan {spaces :: [SpacePlan]}
  deriving stock (Eq, Show)

-- | One of the archive's spaces, as an import would treat it.
data SpacePlan = SpacePlan
  { path :: [Slug]
  -- ^ Its path from the top level, which says where it goes and is what it
  -- is matched by: its depth in the tree is the path's length.
  , name :: Text
  -- ^ Its name in the archive.
  , status :: SpaceStatus
  , pages :: [PagePlan]
  -- ^ Its pages, each before the pages under it, in the archive's order.
  }
  deriving stock (Eq, Show)

-- | Whether a space is new to the server.
data SpaceStatus
  = -- | The server has no space at its path: it is made.
    SpaceNew
  | -- | The server has a space at its path: the two are merged.
    SpaceMerged
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | One of the archive's pages, as an import would treat it.
data PagePlan = PagePlan
  { path :: [Slug]
  -- ^ Its path within its space.
  , title :: Text
  -- ^ Its title in the archive.
  , attachments :: Int
  -- ^ How many attachments it has in the archive.
  , conflict :: Maybe PageConflict
  -- ^ 'Nothing' for a page the server does not have, which is made; the
  -- server's page at the same path otherwise.
  }
  deriving stock (Eq, Show)

-- | The server's page at the path of an imported one, for the dialog to set
-- beside it.
data PageConflict = PageConflict
  { title :: Text
  -- ^ The server's page's title.
  , updatedAt :: UTCTime
  -- ^ When the server's page was last saved.
  , sameContent :: Bool
  -- ^ Whether the two have the same title, body and attachments, so that
  -- either choice gives the same page and the dialog can say so.
  }
  deriving stock (Eq, Show)

-- | What the dialog's checkboxes and conflict choices say. Everything not
-- left out is imported, and every conflict not chosen otherwise keeps the
-- server's page, so 'importEverything' (nothing left out, no choices) is
-- the dialog as it opens.
data ImportChoices = ImportChoices
  { skipSpaces :: [[Slug]]
  -- ^ The spaces left unchecked, by path: nothing of theirs is imported,
  -- their subspaces included. A space merged into the server's is left as
  -- the server has it.
  , skipPages :: [PageRef]
  -- ^ The pages left unchecked: they are not imported, nor the pages under
  -- them.
  , conflicts :: [ConflictChoice]
  -- ^ How conflicts are resolved; one not here keeps the server's page.
  }
  deriving stock (Eq, Show)

-- | Import all of an archive, and keep the server's page wherever both
-- have one.
importEverything :: ImportChoices
importEverything = ImportChoices {skipSpaces = [], skipPages = [], conflicts = []}

-- | A page of an archive, by the path of its space and its path in it.
data PageRef = PageRef
  { space :: [Slug]
  , page :: [Slug]
  }
  deriving stock (Eq, Ord, Show)

-- | How one conflict is resolved.
data ConflictChoice = ConflictChoice
  { page :: PageRef
  , resolution :: Resolution
  }
  deriving stock (Eq, Show)

-- | Which of two pages at the same path stays.
data Resolution
  = -- | The server's page stays as it is, and the imported one is dropped.
    KeepServer
  | -- | The imported page's title, body and attachments replace the
    -- server's; the page keeps its id and its place.
    TakeImported
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | What an import did, to show once it is done.
data ImportSummary = ImportSummary
  { spacesCreated :: Int
  , spacesMerged :: Int
  , pagesCreated :: Int
  , pagesReplaced :: Int
  -- ^ Conflicts resolved with 'TakeImported'.
  , pagesKept :: Int
  -- ^ Conflicts resolved with 'KeepServer'.
  , pagesSkipped :: Int
  -- ^ Pages left out, those of skipped spaces included.
  , attachments :: Int
  -- ^ Attachments brought in with the pages created or replaced.
  }
  deriving stock (Eq, Show)

-- The JSON instances, last, since declarations above name types declared
-- below them ("Wiki.Core.Json" says why that matters), each after those
-- of the types it holds.
deriveValueJSON defaultOptions ''SpaceStatus
deriveValueJSON defaultOptions ''PageConflict
deriveValueJSON defaultOptions ''PagePlan
deriveValueJSON defaultOptions ''SpacePlan
deriveValueJSON defaultOptions ''ImportPlan
deriveValueJSON defaultOptions ''PageRef
deriveValueJSON defaultOptions ''Resolution
deriveValueJSON defaultOptions ''ConflictChoice
deriveValueJSON defaultOptions ''ImportChoices
deriveValueJSON defaultOptions ''ImportSummary
