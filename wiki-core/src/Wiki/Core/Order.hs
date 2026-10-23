{-# LANGUAGE DeriveAnyClass #-}

-- | The order a space lists its children in: its subspaces in one order,
-- its pages (and the pages under each of them) in another, each chosen in
-- the space's settings.
--
-- Everything that lists children, the backend's lists, the sidebar, the
-- space's page list, the front page, goes through 'orderSiblings', so that a
-- space's pages are in the same order wherever they are shown. The order is
-- total: whatever the mode, siblings that it cannot tell apart are taken by
-- name, then by slug, which siblings never share; so ordering twice is
-- ordering once, and a backend that orders its lists and a view that orders
-- them again agree.
--
-- __By name__ is natural order ('naturalCompare'): a run of digits counts
-- as the number it writes, so that \"Part 2\" comes before \"Part 11\", which
-- is how a blog written in order is numbered. __By date__ is by the time
-- the child was made, newest or oldest first. __By hand__ is by a position
-- each child carries ('Sibling'), which whoever may edit the space moves
-- ('reposition', 'renumber'); a new child is given the position after the
-- others ('nextPosition'), so it goes last.
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

-- | How a space orders one kind of its children.
data ChildOrder
  = -- | By name or title, in natural order ('naturalCompare'): the default.
    ByName
  | -- | By when they were made, the newest first.
    NewestFirst
  | -- | By when they were made, the oldest first.
    OldestFirst
  | -- | By the positions they were put in by hand.
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

-- | An order as a person reads it, in a menu or a sentence.
orderName :: ChildOrder -> Text
orderName = \case
  ByName -> "By name"
  NewestFirst -> "By date, newest first"
  OldestFirst -> "By date, oldest first"
  ByHand -> "By hand"

--------------------------------------------------------------------------------
-- Ordering

-- | A node of a tree that a space orders: a space among its siblings, or a
-- page among its.
class (TreeNode a) => Sibling a where
  -- | What it is called, which 'ByName' orders by.
  siblingName :: a -> Text

  -- | When it was made, which 'NewestFirst' and 'OldestFirst' order by.
  siblingCreatedAt :: a -> UTCTime

  -- | Where it was put by hand, which 'ByHand' orders by: the smaller
  -- first. Positions need not be consecutive, nor different: a tie is
  -- broken by name.
  siblingPosition :: a -> Int

-- | Siblings in an order. Those the order cannot tell apart (two made at
-- the same time, two at the same position) are taken by name, then by slug
-- (and, for nodes that are not siblings and share a slug, by id).
orderSiblings :: (Sibling a, Ord (NodeId a)) => ChildOrder -> [a] -> [a]
orderSiblings order = sortOn (\a -> (primary a, naturalKey (siblingName a), nodeSlug a, nodeId a))
  where
    primary a = case order of
      ByName -> Unkeyed
      NewestFirst -> Newest (Down (siblingCreatedAt a))
      OldestFirst -> Oldest (siblingCreatedAt a)
      ByHand -> Position (siblingPosition a)

-- | What comes before the name in an order. One sort uses one of these for
-- every sibling, so how two of them compare never matters.
data Primary
  = Unkeyed
  | Newest (Down UTCTime)
  | Oldest UTCTime
  | Position Int
  deriving stock (Eq, Ord)

-- | The children of a parent ('Nothing' for the roots), in an order.
childrenInOrder :: (Sibling a, Ord (NodeId a), Foldable f) => ChildOrder -> f a -> Maybe (NodeId a) -> [a]
childrenInOrder order nodes parent = orderSiblings order (childrenOf nodes parent)

-- | A whole tree as one list, each node followed by the nodes under it,
-- siblings in the order the function gives for their parent ('Nothing' for
-- the roots). A node whose parent is not among the nodes is taken as a
-- root. (Nodes whose parents go round in a circle, which no backend lets
-- happen, are under no root and left out.)
treeOrder :: (Sibling a, Ord (NodeId a)) => (Maybe (NodeId a) -> ChildOrder) -> [a] -> [a]
treeOrder orderOf nodes = concatMap subtree roots
  where
    byParent = Map.fromListWith (flip (<>)) [(nodeParent n, [n]) | n <- nodes]
    ids = Set.fromList (map nodeId nodes)
    roots = orderSiblings (orderOf Nothing) [n | n <- nodes, maybe True (`Set.notMember` ids) (nodeParent n)]
    subtree n = n : concatMap subtree (orderSiblings (orderOf (Just (nodeId n))) (Map.findWithDefault [] (Just (nodeId n)) byParent))

--------------------------------------------------------------------------------
-- Natural order

-- | What natural order compares a name by: its runs of digits as numbers
-- and the rest of it ignoring case, then the zeros its numbers were
-- written with (fewer first: \"7\" before \"07\"), then the name as it is
-- written, so that two names compare equal only when they are the same.
data NaturalKey = NaturalKey [Chunk] [Int] Text
  deriving stock (Eq, Ord, Show)

-- | A run of digits, as its number (the count of its digits after its
-- leading zeros, then those digits, which compare as the number does
-- however long it is), or a run of anything else, case folded. Digits come
-- before letters, as they do in ASCII.
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

-- | A move of one child among its siblings, by hand.
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
-- id moved; unchanged if none has it, or if it cannot move that way (up
-- from the top, down from the bottom).
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

-- | Positions for siblings in the order given: 0, 1, 2, …, by id.
renumber :: (Ord k) => (a -> k) -> [a] -> Map k Int
renumber key xs = Map.fromList (zip (map key xs) [0 ..])

-- | The position that puts a new child after the siblings it joins.
nextPosition :: (Sibling a) => [a] -> Int
nextPosition = maybe 0 (+ 1) . maximumMay . map siblingPosition
