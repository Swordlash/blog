{-# LANGUAGE DeriveAnyClass #-}

-- | Child orders: the order a space lists its children in. Its subspaces
-- have one order, and its pages (and the pages under each page) another.
-- Both are chosen in the space's settings.
--
-- Everything that lists children (the backend's lists, the sidebar, the
-- space's page list, the front page) sorts them with 'orderSiblings', so
-- that a space's pages are in the same order wherever they are shown. The
-- order is total: whatever the mode, siblings that compare equal are
-- sorted by name, then by slug, and siblings never share a slug. So sorting
-- twice gives the same result as sorting once, and a backend that sorts its
-- lists and a view that sorts them again agree.
--
-- __By name__ is natural order ('naturalCompare'): a run of digits compares
-- as the number it writes, so that \"Part 2\" comes before \"Part 11\", as
-- the posts of a blog are often numbered. __By date__ is by the time the
-- child was created, newest or oldest first. __By hand__ is by a position
-- stored in each child ('Sibling'), which anyone who may edit the space
-- can change ('reposition', 'renumber'). A new child gets the position
-- after the others ('nextPosition'), so it comes last.
module Wiki.Core.Order
  ( -- * Modes
    ChildOrder (..)
  , Children (..)
  , orderName

    -- * Ordering
  , Sibling (..)
  , orderSiblings
  , childrenInOrder
  , treeOrder

    -- * Natural order
  , naturalCompare
  , NaturalKey
  , naturalKey

    -- * Positions, by hand
  , Shift (..)
  , reposition
  , renumber
  , nextPosition
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Path (TreeNode (..), childrenOf)

-- | 'ChildOrder': how a space sorts one kind of its children.
data ChildOrder
  = -- | By name or title, in natural order ('naturalCompare'): the default.
    ByName
  | -- | By creation time, the newest first.
    NewestFirst
  | -- | By creation time, the oldest first.
    OldestFirst
  | -- | By the positions set by hand.
    ByHand
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Which of a space's children an order is for.
data Children
  = -- | Its subspaces.
    ChildSpaces
  | -- | Its pages, and the pages under each of them.
    ChildPages
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | An order's name, for a person to read in a menu or a sentence.
orderName :: ChildOrder -> Text
orderName = \case
  ByName -> "By name"
  NewestFirst -> "By date, newest first"
  OldestFirst -> "By date, oldest first"
  ByHand -> "By hand"

--------------------------------------------------------------------------------
-- Ordering

-- | 'Sibling': a node of a tree that a space sorts, either a space among
-- its sibling spaces or a page among its sibling pages.
class (TreeNode a) => Sibling a where
  -- | Its name or title, which 'ByName' sorts by.
  siblingName :: a -> Text

  -- | Its creation time, which 'NewestFirst' and 'OldestFirst' sort by.
  siblingCreatedAt :: a -> UTCTime

  -- | Its position set by hand, which 'ByHand' sorts by: smaller first.
  -- Positions need not be consecutive, nor distinct: a tie is broken by
  -- name.
  siblingPosition :: a -> Int

-- | Siblings sorted in an order. Siblings the order cannot tell apart (two
-- created at the same time, two at the same position) are sorted by name,
-- then by slug (and, for nodes that are not siblings and share a slug, by
-- id).
orderSiblings :: (Sibling a, Ord (NodeId a)) => ChildOrder -> [a] -> [a]
orderSiblings order = sortOn (\a -> (primary a, naturalKey (siblingName a), nodeSlug a, nodeId a))
  where
    primary a = case order of
      ByName -> Unkeyed
      NewestFirst -> Newest (Down (siblingCreatedAt a))
      OldestFirst -> Oldest (siblingCreatedAt a)
      ByHand -> Position (siblingPosition a)

-- | The sort key that comes before the name in an order. One sort uses the
-- same constructor for every sibling, so how two constructors compare never
-- matters.
data Primary
  = Unkeyed
  | Newest (Down UTCTime)
  | Oldest UTCTime
  | Position Int
  deriving stock (Eq, Ord)

-- | The children of a parent ('Nothing' for the top level), in an order.
childrenInOrder :: (Sibling a, Ord (NodeId a), Foldable f) => ChildOrder -> f a -> Maybe (NodeId a) -> [a]
childrenInOrder order nodes parent = orderSiblings order (childrenOf nodes parent)

-- | A whole tree as one list, each node followed by the nodes under it,
-- with siblings in the order the function returns for their parent
-- ('Nothing' for the top level). A node whose parent is not in the list
-- counts as top-level. (Nodes whose parents form a cycle, which no backend
-- allows, are under no top-level node and are left out.)
treeOrder :: (Sibling a, Ord (NodeId a)) => (Maybe (NodeId a) -> ChildOrder) -> [a] -> [a]
treeOrder orderOf nodes = concatMap subtree roots
  where
    byParent = Map.fromListWith (flip (<>)) [(nodeParent n, [n]) | n <- nodes]
    ids = Set.fromList (map nodeId nodes)
    roots = orderSiblings (orderOf Nothing) [n | n <- nodes, maybe True (`Set.notMember` ids) (nodeParent n)]
    subtree n = n : concatMap subtree (orderSiblings (orderOf (Just (nodeId n))) (Map.findWithDefault [] (Just (nodeId n)) byParent))

--------------------------------------------------------------------------------
-- Natural order

-- | 'NaturalKey': the key natural order compares a name by. First its runs
-- of digits as numbers and the rest case-insensitively, then the leading
-- zeros of its numbers (fewer first: \"7\" before \"07\"), then the name as
-- written, so that two names compare equal only when they are identical.
data NaturalKey = NaturalKey [Chunk] [Int] Text
  deriving stock (Eq, Ord, Show)

-- | A run of digits, as its number, or a run of other characters, case
-- folded. A number is stored as the count of its digits after its leading
-- zeros, then those digits, which compare as the number does however long
-- it is. Digits come before letters, as they do in ASCII.
data Chunk
  = Number Int Text
  | Letters Text
  deriving stock (Eq, Ord, Show)

-- | A name's 'NaturalKey'.
naturalKey :: Text -> NaturalKey
naturalKey name = NaturalKey (map chunk runs) [T.length r - T.length (T.dropWhile (== '0') r) | r <- runs, isDigitRun r] name
  where
    runs = T.groupBy (\a b -> isAsciiDigit a == isAsciiDigit b) name
    isDigitRun r = maybe False (isAsciiDigit . fst) (T.uncons r)
    chunk r
      | isDigitRun r = let n = T.dropWhile (== '0') r in Number (T.length n) n
      | otherwise = Letters (T.toCaseFold r)
    isAsciiDigit c = c >= '0' && c <= '9'

-- | Natural order: @a2@ before @a11@, @Beta@ between @alpha@ and @gamma@.
-- See 'NaturalKey'.
naturalCompare :: Text -> Text -> Ordering
naturalCompare = comparing naturalKey

--------------------------------------------------------------------------------
-- Positions

-- | 'Shift': a move of one child among its siblings, by hand.
data Shift
  = -- | Before the sibling before it.
    ShiftUp
  | -- | After the sibling after it.
    ShiftDown
  | -- | Before all of them.
    ShiftToTop
  | -- | After all of them.
    ShiftToBottom
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The siblings, in the order they are shown, with the one that has this
-- id moved. Unchanged if no sibling has the id, or if the move is
-- impossible (up from the top, down from the bottom).
reposition :: (Eq k) => (a -> k) -> Shift -> k -> [a] -> [a]
reposition key how k xs = case break ((== k) . key) xs of
  (_, []) -> xs
  (before, x : after) -> case how of
    ShiftUp -> case unsnoc before of
      Nothing -> xs
      Just (earlier, y) -> earlier <> [x, y] <> after
    ShiftDown -> case after of
      [] -> xs
      y : later -> before <> [y, x] <> later
    ShiftToTop -> x : before <> after
    ShiftToBottom -> before <> after <> [x]

-- | Positions for the siblings in the given order: 0, 1, 2, …, by id.
renumber :: (Ord k) => (a -> k) -> [a] -> Map k Int
renumber key xs = Map.fromList (zip (map key xs) [0 ..])

-- | The position that puts a new child after its siblings.
nextPosition :: (Sibling a) => [a] -> Int
nextPosition = maybe 0 (+ 1) . maximumMay . map siblingPosition
