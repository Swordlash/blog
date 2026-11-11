-- | Tasks: the items of a page's lists that start with a box, @- [ ]@
-- (to do) or @- [x]@ (done), and the ticks a reader makes in the page
-- before saving them (WP5.91 of docs/PLAN.md).
--
-- A task is named by its index: its place among the page's tasks in the
-- order of the tree, from 0. The tree's order is the order a walk of the
-- blocks meets the tasks, each item before the items in it, and the
-- footnotes' tasks last, since the footnotes come last
-- ("Wiki.Core.Markdown.Ast"'s 'parseWithTasks'). The renderer gives each
-- box this index ("Wiki.Core.Markdown.Render"), whatever order a sorted
-- list shows its items in, so a click names the task the source has at
-- that place.
--
-- 'Ticks' are the states a reader gave some tasks that differ from the
-- text's. 'tick' applies the rules for a task with tasks under it.
-- 'applyTicks' writes the ticks into the text: it changes the boxes and
-- nothing else, and refuses rather than write anything it cannot check.
module Wiki.Core.Markdown.Tasks
  ( -- * The tasks of a page
    Task (..)
  , tasksOf
  , allTasks
  , taskLabel

    -- * Ticks
  , Ticks
  , tick
  , rebaseTicks

    -- * Writing them
  , TickError (..)
  , tickErrorText
  , applyTicks
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Wiki.Core.Markdown.Ast

-- | 'Task' is one task of a page, with the tasks under it.
data Task = Task
  { index :: Int
  -- ^ Its place among the page's tasks, in the order of the tree.
  , done :: Bool
  -- ^ Whether its box is ticked in the text.
  , label :: Text
  -- ^ The item's own text, without its markup ('taskLabel'): its box's
  -- accessible name, not its identity.
  , content :: [Block]
  -- ^ The item's blocks as the parser gives them, every box in them
  -- written to do ('withoutBoxes'): what the task is, which
  -- 'rebaseTicks' compares.
  , under :: [Task]
  -- ^ The tasks under it: those in its item's blocks that are under no
  -- other task of the item. A task in a list in a non-task item of the
  -- item is under it too.
  }
  deriving stock (Eq, Show)

-- | The tasks of a page's blocks, each with the tasks under it, in the
-- order of the tree.
tasksOf :: [Block] -> [Task]
tasksOf doc = evalState (inBlocks doc) 0
  where
    inBlocks :: [Block] -> State Int [Task]
    inBlocks = fmap concat . traverse inBlock
    inBlock = \case
      BlockQuote bs -> inBlocks bs
      List _ items -> concat <$> traverse inItem items
      Div _ bs -> inBlocks bs
      Alert _ _ bs -> inBlocks bs
      Spoiler _ bs -> inBlocks bs
      Footnotes notes -> concat <$> traverse (\(Footnote _ _ bs) -> inBlocks bs) notes
      -- Every other block, named, so that a block added later is a
      -- decision of its own here: none of them holds a list.
      Para _ -> pure []
      Plain _ -> pure []
      Heading {} -> pure []
      ThematicBreak -> pure []
      Pause -> pure []
      CodeBlock {} -> pure []
      Mermaid _ -> pure []
      Tikz _ -> pure []
      MathBlock _ -> pure []
      Table {} -> pure []
      MarkerError _ _ -> pure []
      RawHtmlBlock _ -> pure []
      TableOfContents -> pure []
    inItem (ListItem task bs) = case task of
      Nothing -> inBlocks bs
      Just done -> do
        index <- state (\n -> (n, n + 1))
        under <- inBlocks bs
        pure [Task {index, done, label = taskLabel bs, content = withoutBoxes bs, under}]

-- | Every task of a forest, in the order of the tree: a task before the
-- tasks under it.
allTasks :: [Task] -> [Task]
allTasks = concatMap (\t -> t : allTasks t.under)

-- | A task item's own text, without its markup: its first paragraph's.
-- The page's box is labelled with it.
taskLabel :: [Block] -> Text
taskLabel = \case
  Para xs : _ -> T.strip (plainText xs)
  Plain xs : _ -> T.strip (plainText xs)
  _ -> ""

-- | 'Ticks' are the states a reader gave some of a page's tasks, by their
-- index, that differ from the states in the text: what saving would
-- change. A reader who ticks a box and unticks it again leaves no tick.
type Ticks = Map Int Bool

-- | The ticks after a reader sets a task's box: the task with this index
-- gets the state, and so do the tasks under it, at every depth. Then the
-- tasks above it, the nearest first: ticked, each one is ticked when all
-- the tasks directly under it are, and the walk stops at the first that
-- is not; unticked, every one of them is unticked. Nothing else changes,
-- so a page whose boxes disagree with these rules keeps them until a box
-- on their path is set. An index the page has no task of changes
-- nothing.
tick :: [Task] -> Ticks -> Int -> Bool -> Ticks
tick forest ticks i want = case pathTo forest of
  Nothing -> ticks
  Just (above, t) ->
    let own = Map.fromList [(d.index, want) | d <- allTasks [t]]
        set = up (own `Map.union` ticks) above
     in Map.filterWithKey (\k s -> Map.lookup k written /= Just s) set
  where
    written = Map.fromList [(t.index, t.done) | t <- allTasks forest]
    stateIn m t = Map.findWithDefault t.done t.index m
    -- The tasks above the one with the index, the nearest first, and it.
    pathTo :: [Task] -> Maybe ([Task], Task)
    pathTo ts = asum (map go ts)
      where
        go t
          | t.index == i = Just ([], t)
          | otherwise = first (<> [t]) <$> pathTo t.under
    -- The tasks above, the nearest first. Once one is left as it is, the
    -- walk stops: that one is under each of the others.
    up m = \case
      [] -> m
      a : rest
        | not want -> up (Map.insert a.index False m) rest
        | all (stateIn m) a.under -> up (Map.insert a.index True m) rest
        | otherwise -> m

-- | The ticks made on one text, moved to another: the text the page has
-- now, after someone else saved it. They are moved only when the two
-- texts have the same tasks: as many, under each other in the same way,
-- and each with the same content, compared as the parser's tree of the
-- item ('content'), all of it (every paragraph, a link's address, an
-- image, code, the tasks under it), with only the boxes' states left
-- out. Any other change in a task makes it another task. White space
-- and line breaks that parse to the same tree are the same. The text
-- outside the tasks may change freely. Something the parser numbers
-- across the page (a footnote's number, a heading's or a box's id in a
-- task) may change with the text outside, and then the tasks are not
-- the same: the safe side. Each tick then names the same task, and keeps
-- the state the reader gave it unless the new text already has it; a
-- box the other editor ticked or unticked keeps their state unless the
-- reader's own tick names it. 'Nothing' when the tasks are not the same,
-- and the ticks cannot be trusted to name the tasks the reader meant.
rebaseTicks :: [Task] -> [Task] -> Ticks -> Maybe Ticks
rebaseTicks old new ticks
  | shape old == shape new = Just (Map.filterWithKey (\k s -> Map.lookup k written /= Just s) ticks)
  | otherwise = Nothing
  where
    shape = map (\t -> t {done = False, under = shape t.under})
    written = Map.fromList [(t.index, t.done) | t <- allTasks new]

-- | Why 'applyTicks' wrote nothing.
data TickError
  = -- | The text cannot be parsed.
    Unreadable ParseError
  | -- | The text has no task with this index.
    NoSuchTask Int
  | -- | The box of the task with this index is not where the parser
    -- found the task, as a bracket, a space, a tab or an @x@, and a
    -- bracket.
    BoxNotFound Int
  | -- | The text with the ticks written is not the text with only those
    -- boxes changed, as its parse shows. This is a mistake of this module,
    -- and the check keeps it from reaching a save.
    NotOnlyBoxes
  deriving stock (Eq, Show)

-- | What a reader is told when ticks cannot be written.
tickErrorText :: TickError -> Text
tickErrorText = \case
  Unreadable (ParseError why) -> "The page's Markdown could not be read: " <> why
  NoSuchTask i -> "The page has no task " <> show (i + 1) <> "."
  BoxNotFound i -> "The box of task " <> show (i + 1) <> " was not found in the page's Markdown."
  NotOnlyBoxes -> "The ticks could not be written without changing more than the boxes."

-- | The text with each task the ticks name set to its tick's state: its
-- box written @[x]@ when ticked and @[ ]@ when not. A box already in that
-- state is left as written (@[X]@ stays), so no ticks give the text back
-- byte for byte. Nothing else changes: not the line endings, not the
-- indentation, not another character.
--
-- The box is found where the parser found the task: on the line of the
-- task's bullet ('TaskBox'), after the bullet and the spaces after it,
-- not by a search of the text, which would find boxes in code and in
-- HTML. A box between brackets is a space or more, a tab, or an @x@ in
-- either case, as commonmark-extensions reads one. The whole result is
-- parsed again and checked: the same tree, but for the boxes named,
-- which have their new states. Anything that does not fit is an error,
-- and nothing is written.
applyTicks :: Ticks -> Text -> Either TickError Text
applyTicks ticks source
  | Map.null ticks = Right source
  | otherwise = do
      (doc, boxes) <- first Unreadable (parseWithTasks source)
      let tasks = allTasks (tasksOf doc)
          found = zip tasks boxes
      when (length tasks /= length boxes) (Left NotOnlyBoxes)
      edits <- for (Map.toList ticks) $ \(i, want) -> case atMay found i of
        Nothing -> Left (NoSuchTask i)
        Just (t, box)
          | t.done == want -> Right Nothing
          | otherwise -> maybe (Left (BoxNotFound i)) (\(at, len) -> Right (Just (at, len, if want then "x" else " "))) (boxAt starts source box)
      -- The last box first, so that the places of the others hold.
      let written = foldl' (flip edit) source (sortOn (\(at, _, _) -> Down at) (catMaybes edits))
          expected = [Map.findWithDefault t.done t.index ticks | t <- tasks]
      (doc', _) <- first (const NotOnlyBoxes) (parseWithTasks written)
      unless (map (\t -> t.done) (allTasks (tasksOf doc')) == expected && withoutBoxes doc' == withoutBoxes doc) (Left NotOnlyBoxes)
      Right written
  where
    starts = lineStarts source
    edit (at, len, new) t = T.take at t <> new <> T.drop (at + len) t

-- | Blocks with every task in them written to do: to compare two trees
-- but for their boxes.
withoutBoxes :: [Block] -> [Block]
withoutBoxes = map $ \case
  BlockQuote bs -> BlockQuote (withoutBoxes bs)
  List kind items -> List kind [ListItem (False <$ task) (withoutBoxes bs) | ListItem task bs <- items]
  Div attrs bs -> Div attrs (withoutBoxes bs)
  Alert kind h bs -> Alert kind h (withoutBoxes bs)
  Spoiler h bs -> Spoiler h (withoutBoxes bs)
  Footnotes notes -> Footnotes [Footnote n l (withoutBoxes bs) | Footnote n l bs <- notes]
  other -> other

-- | Where each line of a text starts, as an offset in characters, from
-- the first line. A line ends at @\\r\\n@, at @\\r@ or at @\\n@, as
-- commonmark counts lines.
lineStarts :: Text -> [Int]
lineStarts t = 0 : go 0 (T.unpack t)
  where
    go at = \case
      '\r' : '\n' : rest -> (at + 2) : go (at + 2) rest
      '\r' : rest -> (at + 1) : go (at + 1) rest
      '\n' : rest -> (at + 1) : go (at + 1) rest
      _ : rest -> go (at + 1) rest
      [] -> []

-- | The box of a task whose bullet is at this place: the offset of what
-- is between its brackets, and its length. 'Nothing' when the characters
-- there are not a bullet, spaces, @[@, a box's inside and @]@.
boxAt :: [Int] -> Text -> TaskBox -> Maybe (Int, Int)
boxAt starts source box = do
  lineStart <- atMay starts (box.taskLine - 1)
  let line = T.takeWhile (\c -> c /= '\r' && c /= '\n') (T.drop lineStart source)
  bullet <- columnAt line box.taskColumn
  let afterBullet = T.drop bullet line
  marker <- case T.uncons afterBullet of
    Just (c, _) | c `elem` ['-', '+', '*'] -> Just 1
    Just (c, _) | isDigit c -> do
      let digits = T.length (T.takeWhile isDigit afterBullet)
      guard (T.take 1 (T.drop digits afterBullet) `elem` [".", ")"])
      Just (digits + 1)
    _ -> Nothing
  let afterMarker = T.drop marker afterBullet
      spaces = T.length (T.takeWhile (\c -> c == ' ' || c == '\t') afterMarker)
      open = bullet + marker + spaces
  guard (spaces > 0 && T.take 1 (T.drop open line) == "[")
  let rest = T.drop (open + 1) line
      inside
        | T.take 1 rest `elem` ["x", "X", "\t"] = 1
        | otherwise = T.length (T.takeWhile (== ' ') rest)
  guard (inside > 0 && T.take 1 (T.drop inside rest) == "]")
  Just (lineStart + open + 1, inside)

-- | The offset in a line of the character at a column, counted from 1 as
-- commonmark counts it: a tab goes on to the column after the next
-- multiple of four. 'Nothing' when no character starts at that column.
columnAt :: Text -> Int -> Maybe Int
columnAt line target = go 0 1 (T.unpack line)
  where
    go at column = \case
      _ | column == target -> Just at
      _ | column > target -> Nothing
      c : rest -> go (at + 1) (if c == '\t' then column + 4 - (column - 1) `mod` 4 else column + 1) rest
      [] -> Nothing
