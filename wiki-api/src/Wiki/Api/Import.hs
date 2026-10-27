{-# LANGUAGE DeriveAnyClass #-}

-- | Import API types: importing an archive into a wiki that already has
-- content, in two steps.
--
-- The server imports an archive ("Wiki.Core.Export") by merging it with
-- the existing content, not by replacing it (the demo's own import
-- replaces everything). First the client requests a /preview/. The server
-- reads the archive and responds with an 'ImportPlan': the archive's
-- spaces with their pages, each compared with the server's content and
-- marked as new, as present on both sides, or (for a page) as a conflict.
-- The dialog shows the plan with a checkbox for each space and page, all
-- checked, and for each conflict a choice between the server's page and
-- the imported one, the server's by default. Then the client /applies/
-- the import, sending the same archive and its 'ImportChoices'. The server
-- runs the import in one transaction and responds with an 'ImportSummary'.
--
-- Spaces and pages are matched by path, which is what "present on both
-- sides" means: a space at the same path of slugs from the top level, a
-- page at the same path within that space. Ids are never matched, since
-- the archive's ids are another wiki's. So the choices also name spaces
-- and pages by path.
--
-- The rules for an import are WP2.8's (docs/PLAN.md). In short: a new
-- space is created with its pages; a space on both sides is merged, its
-- pages added and the server's settings kept unless they are empty; a page
-- on both sides is a conflict, resolved as chosen; attachments follow
-- their pages, matched by content hash; positions follow the archive's
-- order, after the server's. The archive's users, groups and grants are
-- not imported.
--
-- The server stores nothing between the two steps, so the archive is sent
-- twice. The plan is computed again when the import is applied, against
-- the server's content at that time. A conflict that appeared after the
-- preview has no choice made for it, so it keeps the server's page, as
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

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Slug (Slug)

-- | 'ImportPlan': what importing an archive would do. It lists the
-- archive's spaces, each before its subspaces (the order of the archive's
-- tree, as @listSpaces@ returns a wiki's), each with its pages.
newtype ImportPlan = ImportPlan {spaces :: [SpacePlan]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpacePlan': one of the archive's spaces, as an import would treat it.
data SpacePlan = SpacePlan
  { path :: [Slug]
  -- ^ Its path from the top level, which says where it goes and is what
  -- it is matched by. Its depth in the tree is the path's length.
  , name :: Text
  -- ^ Its name in the archive.
  , status :: SpaceStatus
  , pages :: [PagePlan]
  -- ^ Its pages, each before the pages under it, in the archive's order.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceStatus': whether a space is new to the server.
data SpaceStatus
  = -- | The server has no space at its path: the space is created.
    SpaceNew
  | -- | The server has a space at its path: the two are merged.
    SpaceMerged
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PagePlan': one of the archive's pages, as an import would treat it.
data PagePlan = PagePlan
  { path :: [Slug]
  -- ^ Its path within its space.
  , title :: Text
  -- ^ Its title in the archive.
  , attachments :: Int
  -- ^ The number of its attachments in the archive.
  , conflict :: Maybe PageConflict
  -- ^ 'Nothing' for a page the server does not have, which is created;
  -- otherwise the server's page at the same path.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PageConflict': the server's page at the path of an imported page, for
-- the dialog to show next to it.
data PageConflict = PageConflict
  { title :: Text
  -- ^ The title of the server's page.
  , updatedAt :: UTCTime
  -- ^ When the server's page was last saved.
  , sameContent :: Bool
  -- ^ Whether the two pages have the same title, body and attachments, so
  -- that either choice gives the same page and the dialog can say so.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ImportChoices': the state of the dialog's checkboxes and conflict
-- choices. Everything not left out is imported, and every conflict without
-- a choice keeps the server's page, so 'importEverything' (nothing left
-- out, no choices) is the dialog's initial state.
data ImportChoices = ImportChoices
  { skipSpaces :: [[Slug]]
  -- ^ The unchecked spaces, by path: nothing in them is imported,
  -- including their subspaces. A space that would be merged stays as the
  -- server has it.
  , skipPages :: [PageRef]
  -- ^ The unchecked pages: they are not imported, nor are the pages under
  -- them.
  , conflicts :: [ConflictChoice]
  -- ^ How conflicts are resolved. A conflict not listed keeps the server's page.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Import all of an archive, and keep the server's page wherever both
-- sides have one.
importEverything :: ImportChoices
importEverything = ImportChoices {skipSpaces = [], skipPages = [], conflicts = []}

-- | 'PageRef': a page of an archive, by its space's path and its path in the space.
data PageRef = PageRef
  { space :: [Slug]
  , page :: [Slug]
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ConflictChoice': how one conflict is resolved.
data ConflictChoice = ConflictChoice
  { page :: PageRef
  , resolution :: Resolution
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Resolution': which of two pages at the same path is kept.
data Resolution
  = -- | The server's page stays as it is, and the imported one is dropped.
    KeepServer
  | -- | The imported page's title, body and attachments replace the
    -- server's; the page keeps its id and its position.
    TakeImported
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ImportSummary': what an import did, shown when it is finished.
data ImportSummary = ImportSummary
  { spacesCreated :: Int
  , spacesMerged :: Int
  , pagesCreated :: Int
  , pagesReplaced :: Int
  -- ^ Conflicts resolved with 'TakeImported'.
  , pagesKept :: Int
  -- ^ Conflicts resolved with 'KeepServer'.
  , pagesSkipped :: Int
  -- ^ Pages left out, including those of skipped spaces.
  , attachments :: Int
  -- ^ Attachments imported with the pages created or replaced.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
