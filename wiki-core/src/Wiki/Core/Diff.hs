-- | What changed between two versions of a page's Markdown: a diff of its
-- lines, and within a line that changed, of its words, so that a one-word
-- edit shows as that word rather than as a whole paragraph replaced (a
-- Markdown paragraph is often one long line).
--
-- Lines are compared whole, with Myers' algorithm (the shortest edit
-- script, as @diff@ and @git@ find it), after the lines both texts start
-- and end with are set aside, which is where most of a page is after an
-- edit. Where lines were taken out and others put in their place, the
-- first taken out is compared with the first put in, the second with the
-- second, and so on, word by word with the same algorithm; a pair with no
-- word in common is shown as two whole lines, since marking every word of
-- both would say nothing more.
--
-- Myers' algorithm takes time in proportion to the texts' length times the
-- number of lines that differ, and memory in proportion to the square of
-- that number; so it stops after 'maxLineEdits' lines of difference (and a
-- line's words after 'maxWordEdits'), and then the diff is every old line
-- taken out and every new one put in ('gaveUp'). Two versions of a 100 KB
-- page with a few edits in them are compared in milliseconds; two that
-- have nothing in common are given up on in a tenth of a second (natively;
-- a few times that in the browser).
--
-- Everything here is pure, and the view ("Wiki.App.View.History") renders
-- the result as Halogen HTML.
module Wiki.Core.Diff
  ( -- * Diffs
    Diff (..)
  , Line (..)
  , LineKind (..)
  , Segment (..)
  , diffText
  , unchanged

    -- * Reading one
  , splitLines
  , oldSide
  , newSide
  , lineText

    -- * Showing one
  , Hunk (..)
  , hunks

    -- * Limits
  , maxLineEdits
  , maxWordEdits
  )
where

import Data.Array.ST (STUArray, newArray, readArray, writeArray)
import Data.Array.Unboxed (UArray, bounds, listArray, (!))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude

-- | How one text became another, line by line.
data Diff = Diff
  { rows :: [Line]
  -- ^ Every line of both texts, in order: each old line kept or taken out,
  -- each new one kept or put in, the ones taken out before the ones put in
  -- their place.
  , gaveUp :: Bool
  -- ^ Whether the texts differ in too many lines to be compared within the
  -- limits, so that 'rows' is the whole old text taken out and the whole
  -- new one put in.
  }
  deriving stock (Eq, Show)

-- | What happened to a line.
data LineKind = Unchanged | Removed | Added
  deriving stock (Eq, Show)

-- | A line of the diff.
data Line = Line
  { kind :: LineKind
  , old :: Maybe Int
  -- ^ Its number in the old text, from 1; 'Nothing' for a line put in.
  , new :: Maybe Int
  -- ^ Its number in the new text; 'Nothing' for a line taken out.
  , segments :: [Segment]
  -- ^ Its text, in parts that changed and parts that did not. A line kept
  -- is one unchanged part; one taken out or put in has its changed words
  -- marked, or is changed whole. An empty line has no parts.
  }
  deriving stock (Eq, Show)

-- | A part of a line.
data Segment = Segment
  { changed :: Bool
  -- ^ Whether this part is what was taken out of the old line (in a line
  -- removed) or put into the new one (in a line added).
  , text :: Text
  }
  deriving stock (Eq, Show)

-- | The most lines two texts may differ in for 'diffText' to work out which:
-- beyond it, it gives up.
maxLineEdits :: Int
maxLineEdits = 1000

-- | The most words two lines compared word by word may differ in.
maxWordEdits :: Int
maxWordEdits = 300

-- | How the first text became the second.
diffText :: Text -> Text -> Diff
diffText before after = case editScript maxLineEdits (intern olds news) of
  Nothing ->
    Diff
      { rows = zipWith (\n t -> Line Removed (Just n) Nothing (whole True t)) [1 ..] olds <> zipWith (\n t -> Line Added Nothing (Just n) (whole True t)) [1 ..] news
      , gaveUp = True
      }
  Just steps -> Diff {rows = arrange (walk steps (zip [1 ..] olds) (zip [1 ..] news)), gaveUp = False}
  where
    olds = splitLines before
    news = splitLines after

-- | Whether nothing changed.
unchanged :: Diff -> Bool
unchanged d = all (\l -> l.kind == Unchanged) d.rows

-- | A text's lines: what is between its line breaks, with no empty line
-- after a break that ends the text. The empty text has none.
splitLines :: Text -> [Text]
splitLines t
  | T.null t = []
  | T.last t == '\n' = fromMaybe [] (initMay parts)
  | otherwise = parts
  where
    parts = T.splitOn "\n" t

-- | A line's text, its parts put together again.
lineText :: Line -> Text
lineText l = mconcat (map (\s -> s.text) l.segments)

-- | The old text's lines, from the diff: those kept and those taken out.
oldSide :: Diff -> [Text]
oldSide d = [lineText l | l <- d.rows, l.kind /= Added]

-- | The new text's lines: those kept and those put in.
newSide :: Diff -> [Text]
newSide d = [lineText l | l <- d.rows, l.kind /= Removed]

-- | A part of a diff to show: lines, or a number of unchanged lines left
-- out between them.
data Hunk = Shown [Line] | Hidden Int
  deriving stock (Eq, Show)

-- | The diff as it is shown: every line that changed, with this many
-- unchanged lines around it, and the rest of the unchanged lines left out,
-- counted. A diff with no change is all left out.
hunks :: Int -> [Line] -> [Hunk]
hunks context ls = map gather (groupBy ((==) `on` fst) (zip near ls))
  where
    changes = map (\l -> l.kind /= Unchanged) ls
    -- How far each line is from the nearest change before it, and after it.
    distance = drop 1 . scanl (\d c -> if c then 0 else d + 1) (context + 1)
    before = distance changes
    after = reverse (distance (reverse changes))
    near = zipWith (\b a -> min b a <= context) before after
    gather run = case run of
      (True, _) : _ -> Shown (map snd run)
      _ -> Hidden (length run)

--------------------------------------------------------------------------------
-- Lines

-- | A line kept, taken out or put in, before its words are compared.
data Raw = Kept Int Int Text | Gone Int Text | Come Int Text

-- | The lines, as the steps of the edit script take them from both texts.
walk :: [Step] -> [(Int, Text)] -> [(Int, Text)] -> [Raw]
walk steps olds news = case (steps, olds, news) of
  (Keep : rest, (o, t) : os, (n, _) : ns) -> Kept o n t : walk rest os ns
  (Delete : rest, (o, t) : os, _) -> Gone o t : walk rest os news
  (Insert : rest, _, (n, t) : ns) -> Come n t : walk rest olds ns
  _ -> []

-- | The diff's lines: in each run of changed lines, those taken out first,
-- then those put in, each compared word by word with the one in the same
-- place on the other side.
arrange :: [Raw] -> [Line]
arrange = \case
  [] -> []
  Kept o n t : rest -> Line Unchanged (Just o) (Just n) (whole False t) : arrange rest
  raws ->
    let (run, rest) = break isKept raws
        gone = [(o, t) | Gone o t <- run]
        come = [(n, t) | Come n t <- run]
        pairs = zipWith compareLines gone come
        removed = zipWith (\(o, _) segments -> Line Removed (Just o) Nothing segments) gone (map fst pairs <> map (whole True . snd) (drop (length pairs) gone))
        added = zipWith (\(n, _) segments -> Line Added Nothing (Just n) segments) come (map snd pairs <> map (whole True . snd) (drop (length pairs) come))
     in removed <> added <> arrange rest
  where
    isKept = \case
      Kept {} -> True
      _ -> False

-- | A line's text as one part.
whole :: Bool -> Text -> [Segment]
whole changed t = [Segment {changed, text = t} | not (T.null t)]

-- | An old line and the new one in its place, word by word: the old
-- line's parts, with what was taken out marked, and the new one's, with
-- what was put in marked. Two lines with no word in common, or too many
-- differences, are changed whole.
compareLines :: (Int, Text) -> (Int, Text) -> ([Segment], [Segment])
compareLines (_, before) (_, after) = case editScript maxWordEdits (intern olds news) of
  Just steps | sharesWords steps -> (segmentsOf Insert steps olds, segmentsOf Delete steps news)
  _ -> (whole True before, whole True after)
  where
    olds = tokens before
    news = tokens after
    -- Whether a word (not a space alone) is kept.
    sharesWords steps = any (T.any (not . isSpace)) [t | (Keep, t) <- zip (filter (/= Insert) steps) olds]

-- | One side's parts: its tokens, in the steps that are not the other
-- side's, marked unless they are kept; neighbours alike merged.
segmentsOf :: Step -> [Step] -> [Text] -> [Segment]
segmentsOf otherSide steps ts = merge (zipWith (\s t -> Segment {changed = s /= Keep, text = t}) (filter (/= otherSide) steps) ts)
  where
    merge = \case
      a : b : rest | a.changed == b.changed -> merge (Segment {changed = a.changed, text = a.text <> b.text} : rest)
      a : rest -> a : merge rest
      [] -> []

-- | A line's words, the spaces between them, and each other character by
-- itself: what lines are compared in. Put together they are the line.
tokens :: Text -> [Text]
tokens = T.groupBy (\a b -> kindOf a == kindOf b && kindOf a /= Other)
  where
    kindOf c
      | isAlphaNum c = Word
      | isSpace c = Space
      | otherwise = Other

data Token = Word | Space | Other
  deriving stock (Eq)

--------------------------------------------------------------------------------
-- Myers' algorithm

-- | A step of an edit script: an element kept, taken from the first
-- sequence, or put in from the second.
data Step = Keep | Delete | Insert
  deriving stock (Eq, Show)

-- | Two sequences of texts as numbers, equal for equal texts, so that
-- comparing two elements is comparing two numbers.
intern :: [Text] -> [Text] -> (UArray Int Int, UArray Int Int)
intern as bs = (array (map number as), array (map number bs))
  where
    numbers = foldl' (\m t -> Map.insertWith (\_ kept -> kept) t (Map.size m) m) Map.empty (as <> bs)
    number t = Map.findWithDefault 0 t numbers
    array xs = listArray (0, length xs - 1) xs

-- | The shortest edit script from one sequence to the other, if it takes at
-- most so many elements taken out and put in. The elements both start
-- and end with are set aside first.
editScript :: Int -> (UArray Int Int, UArray Int Int) -> Maybe [Step]
editScript limit (a, b) =
  (\middle -> replicate prefix Keep <> middle <> replicate suffix Keep)
    <$> myers limit (n - prefix - suffix) (m - prefix - suffix) (\i j -> a ! (prefix + i) == b ! (prefix + j))
  where
    n = size a
    m = size b
    size arr = let (lo, hi) = bounds arr in hi - lo + 1
    prefix = length (takeWhile (\i -> a ! i == b ! i) [0 .. min n m - 1])
    suffix = length (takeWhile (\i -> a ! (n - 1 - i) == b ! (m - 1 - i)) [0 .. min n m - prefix - 1])

-- | Myers' greedy algorithm ("An O(ND) Difference Algorithm and Its
-- Variations", 1986), over sequences of these lengths whose elements the
-- function compares: for each number of differences @d@ in turn, the
-- furthest each diagonal @k = x - y@ reaches, kept for every @d@ so that the
-- path can be followed back from the end.
myers :: Int -> Int -> Int -> (Int -> Int -> Bool) -> Maybe [Step]
myers limit n m eq
  | n == 0 = Just (replicate m Insert)
  | m == 0 = Just (replicate n Delete)
  | otherwise = runST $ do
      let most = min limit (n + m)
          offset = most + 1
      v <- newArray (0, 2 * offset) 0 :: ST s (STUArray s Int Int)
      let at k = readArray v (k + offset)
          -- The furthest each diagonal reaches with d differences, from
          -- those with d - 1; whether the end is reached.
          rounds d past
            | d > most = pure Nothing
            | otherwise = do
                before <- for [negate (d + 1) .. d + 1] at
                let snapshot = listArray (negate (d + 1), d + 1) before :: UArray Int Int
                done <- diagonals d (negate d)
                if done then pure (Just (backtrack n m ((d, snapshot) : past))) else rounds (d + 1) ((d, snapshot) : past)
          diagonals d k
            | k > d = pure False
            | otherwise = do
                down <- at (k + 1)
                right <- at (k - 1)
                let x0 = if k == negate d || (k /= d && right < down) then down else right + 1
                    x = snake x0 (x0 - k)
                writeArray v (k + offset) x
                if x >= n && x - k >= m then pure True else diagonals d (k + 2)
          snake x y
            | x < n && y < m && eq x y = snake (x + 1) (y + 1)
            | otherwise = x
      rounds 0 []

-- | The path to the end, followed back through the furthest points of each
-- round, the last round first.
backtrack :: Int -> Int -> [(Int, UArray Int Int)] -> [Step]
backtrack = go []
  where
    go acc x y = \case
      [] -> acc
      (d, v) : rest
        | d == 0 -> replicate x Keep <> acc
        | otherwise ->
            let k = x - y
                fromDown = k == negate d || (k /= d && v ! (k - 1) < v ! (k + 1))
                prevK = if fromDown then k + 1 else k - 1
                prevX = v ! prevK
                prevY = prevX - prevK
                -- Where the step of this round lands, before the snake.
                (midX, step) = if fromDown then (prevX, Insert) else (prevX + 1, Delete)
             in go (step : replicate (x - midX) Keep <> acc) prevX prevY rest
