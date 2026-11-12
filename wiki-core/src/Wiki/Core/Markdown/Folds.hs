-- | Folds: the ranges of source lines the page's editor can fold (WP5.96
-- of docs/PLAN.md). A fold keeps its first line in sight and hides the
-- lines after it, down to its last line. Folding changes what the editor
-- shows, never the text.
--
-- Three kinds of range are found, all from the wiki's own parser
-- ("Wiki.Core.Markdown.Ast"), so that a fold ends where the page's
-- spoiler or section ends:
--
-- * a block spoiler, from its start marker's line,
--   @[[!spoiler]]{name}(Description)@, to its end marker's line;
-- * a heading spoiler's section, @## [[!spoiler]] Question@, from the
--   heading's line to the section's last line;
-- * any other heading's section, from the heading's line to the section's
--   last line: a section of the page, so not one of a heading inside a
--   block spoiler or a @div@, which is no section of the page.
--
-- A section starts at its heading's first line and ends just before the
-- first line of the next heading of the same or a higher level, or at the
-- end of the page or of the block spoiler or @div@ the heading is in,
-- without the blank lines at its end. A heading's lines are the parser's
-- ('A.parseWithSpans'): a setext heading (its title on one line or more,
-- @===@ or @---@ under it) starts at its title's first line, which stays
-- in sight when it is folded; the rest of its title and its underline
-- fold with the section. A setext heading is never a heading spoiler: its
-- first line, starting with @[[!spoiler]]@, is a marker line. An inline
-- spoiler,
-- @||hidden||@, lies within a line and cannot fold. A heading inside a
-- quotation, a box or a list item has no fold: its lines carry the
-- quotation's or the item's prefix, and the parser does not say where
-- they are. A block spoiler there folds, by its markers' lines.
--
-- Lines are counted from 1, with @\\n@ alone ending a line, as the editor
-- (CodeMirror) counts them. A text with a carriage return has no folds:
-- the parser ends a line there and the editor does not, so the two would
-- count different lines.
module Wiki.Core.Markdown.Folds
  ( Fold (..)
  , FoldKind (..)
  , folds
  , foldsParsed
  , spoilerFolds
  , isSpoiler
  )
where

import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Protolude
import Wiki.Core.Markdown.Ast qualified as A

-- | 'Fold' is a range of source lines the editor can fold: the first line,
-- which stays in sight, and the last one, both from 1 and included, and
-- what the range is. The last line is always after the first.
data Fold = Fold
  { from :: Int
  , to :: Int
  , kind :: FoldKind
  }
  deriving stock (Eq, Ord, Show)

-- | What a 'Fold' folds.
data FoldKind
  = -- | A block spoiler, from its start marker to its end marker.
    BlockSpoiler
  | -- | The section of a heading spoiler, of this level.
    HeadingSpoiler Int
  | -- | The section of another heading, of this level.
    Section Int
  deriving stock (Eq, Ord, Show)

-- | Forcing a 'Fold' forces its lines and kind, so that the editor can find
-- the folds on a worker thread.
instance NFData Fold where
  rnf f = rnf (f.from, f.to) `seq` (case f.kind of BlockSpoiler -> (); HeadingSpoiler n -> rnf n; Section n -> rnf n)

-- | Whether a fold is a spoiler's: the folds the editor offers in its own
-- controls (the gutter, the keys).
isSpoiler :: Fold -> Bool
isSpoiler f = case f.kind of
  Section _ -> False
  _ -> True

-- | The spoilers' folds of a text ('isSpoiler'), in the order of their
-- first lines.
spoilerFolds :: Text -> [Fold]
spoilerFolds = filter isSpoiler . folds

-- | Every fold of a text: block spoilers, heading spoilers and the other
-- headings' sections, in the order of their first lines, an outer fold
-- before the folds inside it.
folds :: Text -> [Fold]
folds source = foldsParsed source (either (const ([], [])) identity (A.parseWithLinesAndMarkers source))

-- | 'folds' of a text the caller has parsed already
-- ('A.parseWithLinesAndMarkers'), so that one parse serves both: the
-- blocks of the page with their lines, and the marker lines. Only the
-- insides of blocks that hold sections are parsed again.
foldsParsed :: Text -> ([(Maybe Int, A.Block)], [A.MarkerLine]) -> [Fold]
foldsParsed source (located, markers)
  | T.any (== '\r') source = []
  | otherwise = sortOn (\f -> (f.from, Down f.to)) (blockSpoilers <> inRegion True 0 (length sourceLines) located)
  where
    sourceLines = Seq.fromList (T.splitOn "\n" source)
    lineAt n = fromMaybe "" (Seq.lookup (n - 1) sourceLines)
    blank n = T.all isSpace (lineAt n)
    -- The line each closed block of the wiki's own ends on, by the line it
    -- starts on: a spoiler's, a div's, a deck's notes'.
    ends = Map.fromList [(start, line) | A.MarkerLine line _ (A.Ends start) <- markers]

    blockSpoilers =
      [ Fold {from = start, to = end, kind = BlockSpoiler}
      | A.MarkerLine start _ (A.Starts _ _) <- markers
      , Just end <- [Map.lookup start ends]
      , end > start
      ]

    -- The headings' folds among the lines after line @offset@, up to line
    -- @end@: lines read as a page of their own, which they are when they
    -- are the whole text, the inside of a block of the wiki's own (between
    -- its markers, without a prefix), or a heading spoiler's section. In
    -- a region of the page (the whole text, or a heading spoiler's section
    -- in one), a heading's section is a section of the page; in the inside
    -- of a block, only a heading spoiler folds.
    region :: Bool -> Int -> Int -> [Fold]
    region page offset end
      | end <= offset = []
      | otherwise = case A.parseWithLines (T.intercalate "\n" (map lineAt [offset + 1 .. end])) of
          Left _ -> []
          Right inside -> inRegion page offset end inside

    -- The folds of a region's blocks, as its parse placed them.
    inRegion :: Bool -> Int -> Int -> [(Maybe Int, A.Block)] -> [Fold]
    inRegion page offset end blocks =
      let placed = [(offset + l, b) | (Just l, b) <- blocks]
       in concat [inBlock page end placed (l, b) | (l, b) <- placed]

    -- The folds a block of a region starts, and those inside it.
    inBlock :: Bool -> Int -> [(Int, A.Block)] -> (Int, A.Block) -> [Fold]
    inBlock page end placed (l, b) = case b of
      A.Heading level _ _
        | page ->
            let next = [l' | (l', b') <- placed, l' > l, maybe False (<= level) (A.leadingHeading b')]
             in section l (sectionEnd l next) (Section level)
      A.Spoiler h (A.Heading level _ _ : _)
        | h.kind == A.OnHeading ->
            -- The parser has put the whole section in the spoiler, so the
            -- next block of the region ends it.
            let last' = sectionEnd l [l' | (l', _) <- placed, l' > l]
             in section l last' (HeadingSpoiler level) <> region page l last'
      A.Spoiler _ _ -> inside
      A.Div _ _ -> inside
      _ -> []
      where
        sectionEnd start next = lastNonBlank start (maybe end (subtract 1) (head next))
        inside = case Map.lookup l ends of
          Just e | e > l + 1 -> region False l (e - 1)
          _ -> []

    section start last' kind = [Fold {from = start, to = last', kind} | last' > start]

    lastNonBlank start n
      | n > start && blank n = lastNonBlank start (n - 1)
      | otherwise = n
