-- | What the dialog "What to migrate" works with, as pure data: the plan a
-- server answered an import's preview with ("Wiki.Api.Import") as a tree
-- of spaces and pages, what has been checked and unchecked in it, and the
-- choices that the dialog's state sends with the import.
--
-- The plan is a list, each space before its subspaces and each page before
-- the pages under it, matched by path; the dialog shows it as the tree the
-- paths make ('planTree'). Everything starts checked, and every conflict
-- keeps the server's page ('everything'), which sends 'importEverything'.
--
-- A box unchecked leaves out what it stands for and everything under it, as
-- the server does with a skipped space or page: so a space unchecked shows
-- its pages and subspaces unchecked too, and they cannot be checked while
-- it is not ('Mark'). What was unchecked under it is remembered: checking
-- the space again brings back the boxes as they were, rather than checking
-- everything under it.
module Wiki.App.Import
  ( -- * The plan as a tree
    SpaceNode (..)
  , PageNode (..)
  , planTree

    -- * What is checked
  , Selection
  , everything
  , setSpace
  , setPage
  , setResolution
  , selectAll
  , selectNone
  , Mark (..)
  , spaceMark
  , pageMark
  , resolutionOf

    -- * What is sent
  , choicesOf

    -- * Saying it
  , Tally (..)
  , tally
  , planSummary
  , selectionSummary
  , importSummary
  , counted
  )
where

import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Api.Import
import Wiki.Core.Slug (Slug)

-- | One of the plan's spaces, with its pages and its subspaces, in the
-- plan's order.
data SpaceNode = SpaceNode
  { plan :: SpacePlan
  , pages :: [PageNode]
  , subspaces :: [SpaceNode]
  }
  deriving stock (Eq, Show)

-- | One of a space's pages, with the pages under it.
data PageNode = PageNode
  { space :: [Slug]
  -- ^ The path of its space, which with its own path names it ('ref').
  , plan :: PagePlan
  , children :: [PageNode]
  }
  deriving stock (Eq, Show)

-- | The plan's spaces as the tree their paths make, in the plan's order. A
-- space whose parent is not in the plan (which a server does not answer,
-- since an archive holds the parents of its spaces) is shown at the top,
-- rather than not at all.
planTree :: ImportPlan -> [SpaceNode]
planTree p = map spaceNode (roots (\s -> s.path) p.spaces)
  where
    spaceNode s =
      SpaceNode
        { plan = s
        , pages = map (pageNode s.path s.pages) (roots (\x -> x.path) s.pages)
        , subspaces = map spaceNode (childrenIn (\x -> x.path) s.path p.spaces)
        }
    pageNode space siblings x =
      PageNode {space, plan = x, children = map (pageNode space siblings) (childrenIn (\y -> y.path) x.path siblings)}

-- | The items whose parent (their path but its last slug) is not among
-- them.
roots :: (a -> [Slug]) -> [a] -> [a]
roots pathOf xs = [x | x <- xs, initMay (pathOf x) `notElem` map (Just . pathOf) xs]

-- | The items one slug below a path.
childrenIn :: (a -> [Slug]) -> [Slug] -> [a] -> [a]
childrenIn pathOf parent xs = [x | x <- xs, initMay (pathOf x) == Just parent]

-- | What has been unchecked, and which conflicts take the imported page.
data Selection = Selection
  { skippedSpaces :: Set [Slug]
  , skippedPages :: Set PageRef
  , taken :: Set PageRef
  }
  deriving stock (Eq, Show)

-- | The dialog as it opens: everything checked, and every conflict keeping
-- the server's page.
everything :: Selection
everything = Selection {skippedSpaces = mempty, skippedPages = mempty, taken = mempty}

-- | Check or uncheck a space's box.
setSpace :: [Slug] -> Bool -> Selection -> Selection
setSpace path checked sel = sel {skippedSpaces = (if checked then Set.delete else Set.insert) path sel.skippedSpaces}

-- | Check or uncheck a page's box.
setPage :: PageRef -> Bool -> Selection -> Selection
setPage ref checked sel = sel {skippedPages = (if checked then Set.delete else Set.insert) ref sel.skippedPages}

-- | Choose which page stays where both sides have one.
setResolution :: PageRef -> Resolution -> Selection -> Selection
setResolution ref r sel = sel {taken = (if r == TakeImported then Set.insert else Set.delete) ref sel.taken}

-- | Every box checked again; the conflicts stay as chosen.
selectAll :: Selection -> Selection
selectAll sel = sel {skippedSpaces = mempty, skippedPages = mempty}

-- | Every space's box unchecked, so that checking one brings in that
-- space alone, with its pages as they were checked; the conflicts stay as
-- chosen.
selectNone :: ImportPlan -> Selection -> Selection
selectNone p sel = sel {skippedSpaces = Set.fromList [s.path | s <- p.spaces]}

-- | How a box is shown.
data Mark = Mark
  { checked :: Bool
  -- ^ Whether what it stands for is imported.
  , enabled :: Bool
  -- ^ Whether it can be changed: not while something above it is left
  -- out, which leaves it out too.
  }
  deriving stock (Eq, Show)

-- | A space's box: unchecked, and fixed, under a space left out.
spaceMark :: Selection -> [Slug] -> Mark
spaceMark sel path
  | spaceAbove sel path = Mark {checked = False, enabled = False}
  | otherwise = Mark {checked = path `Set.notMember` sel.skippedSpaces, enabled = True}

-- | A page's box: unchecked, and fixed, in a space left out or under a page
-- left out.
pageMark :: Selection -> PageRef -> Mark
pageMark sel ref
  | spaceLeftOut sel ref.space || pageAbove sel ref = Mark {checked = False, enabled = False}
  | otherwise = Mark {checked = ref `Set.notMember` sel.skippedPages, enabled = True}

-- | Which page stays where both sides have one.
resolutionOf :: Selection -> PageRef -> Resolution
resolutionOf sel ref = if ref `Set.member` sel.taken then TakeImported else KeepServer

-- | Whether a space above this one (not the space itself) is left out.
spaceAbove :: Selection -> [Slug] -> Bool
spaceAbove sel path = any (`Set.member` sel.skippedSpaces) (properPrefixes path)

-- | Whether a space is left out, by its own box or one above it.
spaceLeftOut :: Selection -> [Slug] -> Bool
spaceLeftOut sel path = path `Set.member` sel.skippedSpaces || spaceAbove sel path

-- | Whether a page above this one in its space is left out.
pageAbove :: Selection -> PageRef -> Bool
pageAbove sel ref = any (\p -> PageRef {space = ref.space, page = p} `Set.member` sel.skippedPages) (properPrefixes ref.page)

-- | Whether a page is imported.
pageIncluded :: Selection -> PageRef -> Bool
pageIncluded sel ref = (pageMark sel ref).checked

-- | The non-empty paths above a path.
properPrefixes :: [a] -> [[a]]
properPrefixes path = [take n path | n <- [1 .. length path - 1]]

-- | The choices the dialog's state sends with the import, in the plan's
-- order: each box unchecked that is not under one unchecked already (the
-- server leaves out what is under a skipped space or page by itself), and
-- each conflict that takes the imported page, among those imported. The
-- dialog as it opens sends 'importEverything'.
choicesOf :: ImportPlan -> Selection -> ImportChoices
choicesOf p sel =
  ImportChoices
    { skipSpaces = [s.path | s <- p.spaces, s.path `Set.member` sel.skippedSpaces, not (spaceAbove sel s.path)]
    , skipPages =
        [ ref
        | (ref, _) <- pagesOf p
        , ref `Set.member` sel.skippedPages
        , not (spaceLeftOut sel ref.space)
        , not (pageAbove sel ref)
        ]
    , conflicts =
        [ ConflictChoice {page = ref, resolution = TakeImported}
        | (ref, x) <- pagesOf p
        , isJust x.conflict
        , ref `Set.member` sel.taken
        , pageIncluded sel ref
        ]
    }

-- | Every page of the plan, by reference, in the plan's order.
pagesOf :: ImportPlan -> [(PageRef, PagePlan)]
pagesOf p = [(PageRef {space = s.path, page = x.path}, x) | s <- p.spaces, x <- s.pages]

-- | How much of a plan is what.
data Tally = Tally
  { spacesNew :: Int
  , spacesMerged :: Int
  , pagesNew :: Int
  , pagesConflicting :: Int
  , pagesSame :: Int
  -- ^ Conflicts whose two pages are the same.
  }
  deriving stock (Eq, Show)

-- | How much of a plan, or of what a selection imports of it, is what.
tally :: ImportPlan -> Selection -> Tally
tally p sel =
  Tally
    { spacesNew = length [s | s <- spaces, s.status == SpaceNew]
    , spacesMerged = length [s | s <- spaces, s.status == SpaceMerged]
    , pagesNew = length [x | x <- pages, isNothing x.conflict]
    , pagesConflicting = length [x | x <- pages, Just c <- [x.conflict], not c.sameContent]
    , pagesSame = length [x | x <- pages, Just c <- [x.conflict], c.sameContent]
    }
  where
    spaces = [s | s <- p.spaces, not (spaceLeftOut sel s.path)]
    pages = [x | (ref, x) <- pagesOf p, pageIncluded sel ref]

-- | What a plan holds, for a person to read: "4 spaces (1 new, 3 already
-- here) and 12 pages (9 new, 2 in conflict, 1 the same on both sides)".
planSummary :: ImportPlan -> Text
planSummary p = described (tally p everything)

-- | What the selection imports, for a person to read before they apply it.
selectionSummary :: ImportPlan -> Selection -> Text
selectionSummary p sel = case tally p sel of
  t | t.spacesNew + t.spacesMerged == 0 -> "Nothing is checked: the import would bring in nothing."
  t -> "Checked: " <> described t <> taking <> "."
  where
    taken = length (choicesOf p sel).conflicts
    taking
      | taken == 0 = ""
      | otherwise = "; " <> counted taken "conflict takes" "conflicts take" <> " the imported page"

described :: Tally -> Text
described t =
  counted (t.spacesNew + t.spacesMerged) "space" "spaces"
    <> parts [counted t.spacesNew "new" "new" | t.spacesNew > 0] [counted t.spacesMerged "already here" "already here" | t.spacesMerged > 0]
    <> " and "
    <> counted (t.pagesNew + t.pagesConflicting + t.pagesSame) "page" "pages"
    <> parts
      [counted t.pagesNew "new" "new" | t.pagesNew > 0]
      ( [counted t.pagesConflicting "in conflict" "in conflict" | t.pagesConflicting > 0]
          <> [counted t.pagesSame "the same on both sides" "the same on both sides" | t.pagesSame > 0]
      )
  where
    parts a b = case a <> b of
      [] -> ""
      xs -> " (" <> T.intercalate ", " xs <> ")"

-- | What an import did, for a person to read, a line for each kind of
-- thing it did.
importSummary :: ImportSummary -> [Text]
importSummary s =
  filter
    (not . T.null)
    [ line s.spacesCreated "space created" "spaces created"
    , line s.spacesMerged "space merged with the server's" "spaces merged with the server's"
    , line s.pagesCreated "page created" "pages created"
    , line s.pagesReplaced "page replaced by the imported one" "pages replaced by the imported ones"
    , line s.pagesKept "page kept as the server had it" "pages kept as the server had them"
    , line s.pagesSkipped "page left out" "pages left out"
    , line s.attachments "attachment brought in" "attachments brought in"
    ]
  where
    line n singular plural = if n == 0 then "" else counted n singular plural

-- | A number of things, with the word for one or for more.
counted :: Int -> Text -> Text -> Text
counted n singular plural = show n <> " " <> if n == 1 then singular else plural
