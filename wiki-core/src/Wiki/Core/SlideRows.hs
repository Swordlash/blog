-- | A presentation's source as rows, for the editor's slide-by-slide mode.
--
-- In that mode the editor shows a presentation as a list of rows, one per
-- slide, each with an editor of its own over the slide's Markdown. A
-- 'Row' is a range of the presentation's text, given by its text and a
-- 'RowKey' that stays with the row while the text changes, so that the
-- browser keeps the row's editor. The whole text stays the one thing that
-- is stored and saved: 'assemble' gives it back, byte for byte.
--
-- __Where the text is cut.__ A row starts at an opener, a heading that
-- opens a slide ("Wiki.Core.Slides": a heading of level one or two at the
-- presentation's top level), at the first character of the opener's first
-- line. What comes before the first opener is a row of its own, the
-- preamble. The line break just before an opener belongs to no row: it is
-- a separator. So a row's editor never holds the empty last line that is
-- really the start of the next opener's line, and typing there cannot join
-- a word to the next heading. The last row runs to the end of the text,
-- its final line break included.
--
-- __Why rows are re-cut one by one.__ A fresh cut of the whole text
-- ('cutRows') is made only when the slide mode starts. After an edit,
-- only the rows whose text changed are cut again, each on its own text
-- ('recut'). A code fence, a box or an HTML comment left open in one row
-- then runs to the end of that row and no further, and the rows below
-- keep their keys, their texts and their editors while the author writes
-- the closing line. The presentation itself is still read from the whole
-- text, where such a block takes in the slides after it: 'swallowed' says
-- which rows that happens to, so that the editor can warn of it.
--
-- __Characters.__ Offsets are counted in characters (code points), as
-- 'Text' counts them; the browser converts them to UTF-16 units. Lines are
-- found as the Markdown parser finds them, which is not quite as an editor
-- does: for commonmark 0.3.1 a carriage return and every line feed right
-- after it end one line (@\\r\\n\\n@ is a single line break to the parser,
-- two to CodeMirror). Rows are ranges of characters, so a text with
-- carriage returns cuts into rows too, and 'assemble' gives it back as it
-- was.
--
-- __Steps.__ 'moveRow', 'deleteRow' and 'newRow' change the rows as one
-- edit of the text each, and return that edit as a list of 'Edit's of the
-- old text, so that the editor applies it as one change, which one undo
-- reverts.
module Wiki.Core.SlideRows
  ( -- * Rows
    RowKey (..)
  , Row (..)
  , Rows (..)
  , cutRows
  , assemble
  , rowStarts
  , rowLines
  , fromLayout
  , changedSince
  , recut

    -- * Steps
  , Edit (..)
  , applyEdits
  , moveRow
  , deleteRow
  , newRow

    -- * Reading rows
  , rowAt
  , countPerRow
  , fixedRows
  , rowHeading
  , rowTitle
  , swallowed
  , swallowedFrom
  , leftOpenAt
  , openerStarts
  , openerStartsParsed
  )
where

import Data.IntSet qualified as IntSet
import Data.List (span, zip4)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Core.Markdown.Ast (Block (..), Inline, parseDeckSpans, plainText)
import Wiki.Core.Slides (deckLevel, parserLineStarts)

-- | 'RowKey' names a row while its text changes. The editor keeps a
-- counter of keys and never gives a key twice, so that a new row never
-- takes the place, and the editor, of a row that is gone.
newtype RowKey = RowKey Int
  deriving stock (Eq, Ord, Show)
  deriving newtype (Enum, NFData)

-- | 'Row' is one row of the slide mode: its key, and its text, from the
-- first character of its opener's first line (or of the text, for the
-- preamble) to the separator before the next row, or to the end of the
-- text for the last row.
data Row = Row
  { key :: RowKey
  , text :: Text
  }
  deriving stock (Eq, Show)

instance NFData Row where
  rnf r = rnf (r.key, r.text)

-- | 'Rows' is a presentation's text as rows: the rows in order, and the
-- separators between them, one fewer than the rows. A separator is the
-- line break just before a row's opener: @\\n@, @\\r\\n@ or @\\r@. There is
-- always at least one row.
data Rows = Rows
  { rows :: [Row]
  , separators :: [Text]
  }
  deriving stock (Eq, Show)

instance NFData Rows where
  rnf r = rnf (r.rows, r.separators)

-- | 'Edit' is one change of a text: the characters from @from@ up to
-- @to@ (not included) replaced by @insert@. A list of edits is one change:
-- every offset is in the text before it, the edits are in order and do not
-- overlap, as a CodeMirror change spec ('applyEdits').
data Edit = Edit
  { from :: Int
  , to :: Int
  , insert :: Text
  }
  deriving stock (Eq, Show)

----------------------------------------------------------------------
-- Cutting

-- | The rows of a whole text, cut fresh: the preamble when the text does
-- not start with an opener, then a row at each opener. The keys are taken
-- from the counter, in order; the counter after them comes second.
cutRows :: RowKey -> Text -> (Rows, RowKey)
cutRows next source = (rowsFrom source (zip keys starts), plus next (length starts))
  where
    starts = 0 : filter (/= 0) (openerStarts source)
    keys = map (plus next) [0 .. length starts - 1]

-- | The text the rows are cut from: each row's text, with the separators
-- between them.
assemble :: Rows -> Text
assemble r = T.concat (concat (zipWith (\row sep -> [row.text, sep]) r.rows (r.separators <> repeat "")))

-- | The character each row starts at in the text 'assemble' gives.
rowStarts :: Rows -> [Int]
rowStarts r = scanl (+) 0 (zipWith (\row sep -> T.length row.text + T.length sep) r.rows r.separators)

-- | The line each row starts on in the text 'assemble' gives, from 1, as
-- an editor counts lines (a line feed ends one), found in one walk over
-- the rows.
rowLines :: Rows -> [Int]
rowLines r = scanl (+) 1 [T.count "\n" row.text + T.count "\n" sep | (row, sep) <- zip r.rows (r.separators <> repeat "")]

-- | The rows of a text as the browser's editor holds them after an edit:
-- each row's key and the character it now starts at, in order, mapped
-- through the edit. An edit the rows did not make (an undo, the Raw mode,
-- the assistant) can leave a start that no longer follows a line break,
-- or two rows at one place: such a start is dropped, and its text joins
-- the row above. The first row starts at the text's start, whatever its
-- start says. 'Nothing' for no rows. The rows are not re-cut: compare
-- them with the rows before ('changedSince') and re-cut the changed ones
-- ('recut').
fromLayout :: Text -> [(RowKey, Int)] -> Maybe Rows
fromLayout source = \case
  [] -> Nothing
  (key, _) : rest -> Just (rowsFrom source ((key, 0) : valid 0 rest))
  where
    valid previous = \case
      [] -> []
      (key, s) : rest
        | s > previous && IntSet.member s lineStarts -> (key, s) : valid s rest
        | otherwise -> valid previous rest
    -- Every character that follows a line break, found in one walk over
    -- the text (looking each row's start up by its index walked the text
    -- once for each row): after a line feed, or after a carriage return
    -- without a line feed after it. A start between the two characters of
    -- @\\r\\n@ is not a line's start.
    lineStarts = IntSet.fromDistinctAscList (breaks 1 (T.unpack source))
    breaks at = \case
      '\n' : more -> at : breaks (at + 1) more
      '\r' : more@('\n' : _) -> breaks (at + 1) more
      '\r' : more -> at : breaks (at + 1) more
      _ : more -> breaks (at + 1) more
      [] -> []

-- | The keys of the rows whose text is not what it was in the rows
-- before, new rows included: the rows to re-cut ('recut').
changedSince :: Rows -> Rows -> [RowKey]
changedSince before after = [r.key | r <- after.rows, Map.lookup r.key old /= Just r.text]
  where
    old = Map.fromList [(r.key, r.text) | r <- before.rows]

-- | The rows after an edit, with the changed rows re-cut, each on its own
-- text: the rows not changed are not read again.
--
-- A changed row that holds an opener after its first one is split there.
-- A changed row that no longer starts with an opener (its heading was
-- deleted or demoted, or text was put before it) gives the text before its
-- first opener to the row above, which is then cut again too: the joined
-- text can make a new opener of a setext heading (@Text@ then @---@). The
-- first row keeps what comes before the first opener.
--
-- Keys: a row that still starts where a row started keeps that row's key.
-- A row whose start is gone gives its key to the first new row inside its
-- old range, if any. The editor with the focus never changes: the row
-- that holds the cursor (a character of the text) takes the key of the
-- row that held it, so that typing @## @ in the middle of a row splits off
-- the text above the cursor as a new row, and the cursor's part keeps the
-- row's editor. The other rows get new keys from the counter; the counter
-- after them comes second.
--
-- The text does not change: 'assemble' of the result is 'assemble' of the
-- argument.
recut :: RowKey -> Maybe Int -> [RowKey] -> Rows -> (Rows, RowKey)
recut next cursor changed r = (rowsFrom source (zip keys starts), next')
  where
    source = assemble r
    old = zip (map (.key) r.rows) (rowStarts r)
    dirty = Set.fromList changed
    starts = recutStarts source [(s, Set.member k dirty) | (k, s) <- old]
    (keys, next') = assignKeys next cursor old starts

-- | The rows' starts after a re-cut, from the old starts, each with
-- whether its row changed (see 'recut').
recutStarts :: Text -> [(Int, Bool)] -> [Int]
recutStarts source = go []
  where
    -- The end of a row: the separator before the next row, or the text's
    -- end.
    endBefore = \case
      (s, _) : _ -> s - separatorLength source s
      [] -> T.length source
    -- The rows done, last first, and the rows to do. A changed row is cut
    -- on its own text; when it does not start with an opener and a row is
    -- above it, the row above takes the text before its first opener and
    -- is done again, as a changed row.
    go done = \case
      [] -> reverse done
      (s, False) : rest -> go (s : done) rest
      (s, True) : rest ->
        let found = map (+ s) (openerStarts (slice s (endBefore rest) source))
            pieces = [(o, False) | o <- found, o /= s]
         in case done of
              above : done' | s `notElem` found -> go done' ((above, True) : pieces <> rest)
              _ -> go (s : done) (pieces <> rest)

-- | The keys of the rows at the new starts, as 'recut' gives them, and the
-- counter after the new keys.
assignKeys :: RowKey -> Maybe Int -> [(RowKey, Int)] -> [Int] -> ([RowKey], RowKey)
assignKeys next cursor old new = fresh next withCursor
  where
    byStart = Map.fromList [(s, k) | (k, s) <- old]
    newStarts = Set.fromList new
    -- A row whose start is gone: its key goes to the first new row that
    -- starts inside its old range.
    inherited =
      Map.fromList
        [ (s', k)
        | ((k, s), end) <- zip old (map snd (drop 1 old) <> [maxBound])
        , not (Set.member s newStarts)
        , Just s' <- [find (> s) new]
        , s' < end
        ]
    found = [Map.lookup s byStart <|> Map.lookup s inherited | s <- new]
    withCursor = case cursor of
      Just c
        | Just (focused, _) <- lastMay [x | x@(_, s) <- old, s <= c]
        , Just at <- lastMay [i | (i, s) <- zip [0 :: Int ..] new, s <= c] ->
            [ if i == at then Just focused else if k == Just focused then Nothing else k
            | (i, k) <- zip [0 ..] found
            ]
      _ -> found
    fresh n = \case
      [] -> ([], n)
      Just k : rest -> first (k :) (fresh n rest)
      Nothing : rest -> first (n :) (fresh (succ n) rest)

----------------------------------------------------------------------
-- Steps

-- | A text with the edits applied, all at once: each edit's offsets are in
-- the text as it was.
applyEdits :: [Edit] -> Text -> Text
applyEdits edits source = go 0 edits
  where
    go at = \case
      [] -> T.drop at source
      e : rest -> slice at e.from source <> e.insert <> go e.to rest

-- | Move the row at one index to be the row at another, as one edit: its
-- text, with the separator after it, is taken out and put back at its new
-- place, so that each row's text is the same, only in another order, and
-- the row keeps its key. The rows that stay first ('fixedRows') do not
-- move, and none moves before them: 'Nothing' then, and for an index out
-- of range or a move to the same place.
--
-- Line breaks are added where the rows would otherwise run together, as
-- 'Wiki.Core.Slides.moveSlide' adds them: one at the end of the last row
-- when a row comes after it, and, when an opener would not stay an opener
-- after the row now above it, a blank line before each row whose title is
-- a setext heading and that follows another row than before. So the text
-- is 'moveSlide''s wherever 'moveSlide' moves, but for one case: a
-- preamble that is not a slide (blank lines, a look, a pause) is not one
-- of 'moveSlide''s slides, and 'moveSlide' puts no blank line after it,
-- where a move of rows does. 'moveSlide' also refuses a move after which a
-- block left open would take in other slides; a row moves all the same,
-- and 'swallowed' says what the presentation does with it.
moveRow :: Int -> Int -> Rows -> Maybe (Rows, [Edit])
moveRow i j r
  | i == j || i < fixed || j < fixed || i >= count || j >= count = Nothing
  | otherwise = Just (joinedRows r (reorderAt i j (chunks r i)))
  where
    count = length r.rows
    fixed = fixedRows r

-- | Delete the row at an index, as one edit: its text and the separator
-- after it, or, for the last row, its text alone, so that the row above
-- becomes the last and ends with the line break that came before the
-- deleted row. A blank line is added before the next row when its opener
-- is a setext heading that would otherwise join the row above. The rows
-- that stay first ('fixedRows') are not deleted, nor is the only row:
-- 'Nothing' then, and for an index out of range.
deleteRow :: Int -> Rows -> Maybe (Rows, [Edit])
deleteRow i r
  | i < fixedRows r || i >= count || count < 2 = Nothing
  | otherwise = Just (joinedRows r [c | c@(k, _, _) <- chunks r (-1), k /= i])
  where
    count = length r.rows

-- | A new row, with the given key, at an index: a heading of level two with
-- the title, apart from the row above by a blank line, and from the row
-- below by one too. The index is kept after the rows that stay first
-- ('fixedRows') and at most after the last row. The title starts three
-- characters after the new row's start (after @## @).
newRow :: RowKey -> Text -> Int -> Rows -> (Rows, [Edit])
newRow key title at r = joinedRows r (take at' before <> [(-1, key, [Put heading])] <> drop at' before)
  where
    at' = max (fixedRows r) (min (length r.rows) at)
    nl = lineEndingOf (assemble r)
    before = gapAbove (chunks r (-1))
    heading = "## " <> title <> nl <> (if at' < length r.rows then nl else "")
    -- A blank line between the row above and the new row, unless the row
    -- above ends with one, or is empty.
    gapAbove cs = case splitAt (at' - 1) cs of
      (above, (k, key', ps) : below)
        | at' > 0 ->
            let t = piecesText (assemble r) ps
                ended = if lineEnded t then t else t <> nl
                gap = if T.null t || endsBlank ended then "" else nl
             in above <> [(k, key', ps <> [Put (T.drop (T.length t) ended <> gap)])] <> below
      _ -> cs

-- | A piece of a new text: a range of the old text, or text put in.
data Piece = Kept Int Int | Put Text

-- | Each row's chunk, its text and the separator after it, as a range of
-- the old text, with its index and key; the chunk at the given index as
-- text put in, since it is moved.
chunks :: Rows -> Int -> [(Int, RowKey, [Piece])]
chunks r moved =
  [ (k, row.key, if k == moved then [Put (slice a b source)] else [Kept a b])
  | (k, row, a, b) <- zip4 [0 ..] r.rows starts (drop 1 starts <> [T.length source])
  ]
  where
    source = assemble r
    starts = rowStarts r

-- | The rows of chunks put one after the other, each chunk but the last
-- ending with a line break, and the edits that make the old text the new.
-- When an opener does not stay an opener after a chunk that was not above
-- it before, a blank line goes before each such chunk whose opener is a
-- setext heading, and the chunk above it does not end with a blank line
-- ('Wiki.Core.Slides.moveSlide''s rule).
joinedRows :: Rows -> [(Int, RowKey, [Piece])] -> (Rows, [Edit])
joinedRows r placed = (rowsFrom new (zip (map fst groups) starts), toEdits (T.length old) (concatMap snd groups))
  where
    old = assemble r
    nl = lineEndingOf old
    plain = joined False placed
    groups = if all holds (zip plain (drop 1 plain)) then map dropIndex plain else map dropIndex (joined True placed)
    dropIndex (_, key, ps) = (key, ps)
    texts = [piecesText old ps | (_, ps) <- groups]
    new = T.concat texts
    starts = scanl (+) 0 (map T.length (fromMaybe [] (initMay texts)))
    -- Whether the opener of a chunk put after another than before stays an
    -- opener.
    holds ((k, _, ps), (k', _, ps'))
      | k' == k + 1 = True
      | otherwise = let above = piecesText old ps in T.length above `elem` openerStarts (above <> piecesText old ps')
    joined apart = \case
      (k, key, ps) : rest@((k', _, ps') : _) ->
        let t = piecesText old ps
            ended = if lineEnded t then [] else [Put nl]
            endedText = t <> T.concat [x | Put x <- ended]
            gap = [Put nl | apart && k' /= k + 1 && setext (piecesText old ps') && not (endsBlank endedText)]
         in (k, key, ps <> ended <> gap) : joined apart rest
      rest -> rest

-- | The text of some pieces of a new text.
piecesText :: Text -> [Piece] -> Text
piecesText old = T.concat . map piece
  where
    piece = \case
      Kept a b -> slice a b old
      Put t -> t

-- | The edits that make a text of some length the pieces' text, when the
-- pieces' ranges of it are in order and do not overlap.
toEdits :: Int -> [Piece] -> [Edit]
toEdits total = go 0 ""
  where
    go at added = \case
      [] -> edit at total added []
      Put t : rest -> go at (added <> t) rest
      Kept a b : rest -> edit at a added (go b "" rest)
    edit a b t rest
      | a == b && T.null t = rest
      | otherwise = Edit {from = a, to = b, insert = t} : rest

-- | A list with the element at one index taken out and put back at
-- another.
reorderAt :: Int -> Int -> [a] -> [a]
reorderAt i j xs = take j rest <> take 1 (drop i xs) <> drop j rest
  where
    rest = take i xs <> drop (i + 1) xs

----------------------------------------------------------------------
-- Reading rows

-- | The index of the row a character of the text is in: the last row that
-- starts at or before it. A character at the end of a row's text, where
-- the separator starts, is in that row.
rowAt :: Rows -> Int -> Int
rowAt r offset = max 0 (length (takeWhile (<= offset) (rowStarts r)) - 1)

-- | How many of some characters of a text (the starts of the editor's
-- search's matches) are in each row of a layout, the rows given by their
-- keys and starts in the order of the text, as the editor holds them: a
-- character is in the last row that starts at or before it. One walk over
-- the rows and the characters, sorted first.
countPerRow :: [(RowKey, Int)] -> [Int] -> [(RowKey, Int)]
countPerRow layout = go layout . sort
  where
    go rows' at = case rows' of
      [] -> []
      [(key, start)] -> [(key, length (dropWhile (< start) at))]
      (key, start) : more@((_, next) : _) ->
        let (inside, after) = span (< next) (dropWhile (< start) at)
         in (key, length inside) : go more after

-- | How many of the first rows stay where they are: the preamble, and the
-- title slide, a first opener of level one. These rows are neither moved
-- nor deleted, and no row is moved or put before them
-- ('Wiki.Core.Slides.fixedSlides''s rule, where a preamble that is not a
-- slide is a row all the same).
fixedRows :: Rows -> Int
fixedRows r = case map rowHeading (take 2 r.rows) of
  Nothing : Just (1, _) : _ -> 2
  Nothing : _ -> 1
  Just (1, _) : _ -> 1
  _ -> 0

-- | A row's opener, read from the row's text alone: its level and its
-- title as plain text (emphasis and links without their marks, code and
-- math as written). 'Nothing' for the preamble.
rowHeading :: Row -> Maybe (Int, Text)
rowHeading row = case openers row.text of
  (0, level, title) : _ -> Just (level, plainText title)
  _ -> Nothing

-- | A row's title ('rowHeading'), empty for the preamble and for an empty
-- heading.
rowTitle :: Row -> Text
rowTitle = maybe "" snd . rowHeading

-- | The rows that the presentation, read from the whole text, does not
-- start a slide at, each with the index of the row above whose slide
-- takes it in: a block left open in that row (a code fence, a box, an
-- HTML comment) runs on through the rows below it. Empty exactly when the
-- rows are where a fresh cut of the whole text ('cutRows') puts them.
swallowed :: Rows -> [(Int, Int)]
swallowed r = swallowedFrom (openerStarts (assemble r)) r

-- | 'swallowed', from the starts of the openers of the rows' whole text
-- ('openerStarts', or 'openerStartsParsed' of a parse the caller has):
-- the whole text is not parsed again.
swallowedFrom :: [Int] -> Rows -> [(Int, Int)]
swallowedFrom starts r = go 0 (zip [0 ..] (rowStarts r))
  where
    whole = Set.fromList (0 : starts)
    go holder = \case
      [] -> []
      (k, s) : rest
        | Set.member s whole -> go k rest
        | otherwise -> (k, holder) : go holder rest

-- | Where a row leaves a block open (a code fence, a box, an HTML
-- comment), which takes the slides after it into its own in the whole
-- text: the first character of the line that opens it, read from the row's
-- own text. 'Nothing' when the row leaves nothing open, and when the line
-- would be the row's first, its opener.
--
-- The row's text is parsed once, with a heading put after it on a line of
-- its own after a blank line, as the next slide's would be. When that
-- heading opens no slide, a block left open has taken it in: the last
-- block of the top level that starts before it (a block opened and closed
-- before that one is over by then). The parser says on which line that
-- block starts. One parse per row, so that the time is linear in the
-- row's length: this runs after every pause in the typing, on the page's
-- one thread, while the author writes a long code block whose fence is not
-- closed yet.
leftOpenAt :: Row -> Maybe Int
leftOpenAt row = case parseDeckSpans probe of
  Left _ -> Nothing
  Right spans ->
    let located = [(l, b) | (Just (l, _), b) <- deckLevel spans]
        opensSlide = any (\(l, b) -> l == probeLine && isOpener b) located
     in case lastMay [l | (l, _) <- located, l < probeLine] of
          Just l | not opensSlide, l > 1 -> atMay lineStarts (l - 1)
          _ -> Nothing
  where
    probe = row.text <> "\n\n## Probe\n"
    lineStarts = parserLineStarts probe
    -- The probe's line, from 1, as the parser counts lines.
    probeLine = length (takeWhile (<= T.length row.text + 2) lineStarts)
    isOpener = \case
      Heading level _ _ -> level <= 2
      _ -> False

-- | The character each opener of a text starts at: the first character of
-- the line of each heading of level one or two at the presentation's top
-- level ('Wiki.Core.Slides.deckLevel'), a setext heading's first line.
-- None when the text cannot be parsed.
openerStarts :: Text -> [Int]
openerStarts source = [s | (s, _, _) <- openers source]

-- | 'openerStarts' of a text parsed already: its blocks as
-- 'parseDeckSpans' gives them, each with the line it starts on, as the
-- editor's check reads them ("Wiki.Core.Markdown.Problems"), so that one
-- parse of a text serves the check and the rows.
openerStartsParsed :: Text -> [(Maybe Int, Block)] -> [Int]
openerStartsParsed source spans = [s | (s, _, _) <- openersParsed source spans]

-- | The openers of a text: each one's first character, level and title.
openers :: Text -> [(Int, Int, [Inline])]
openers source = either (const []) (openersParsed source . map (first (fmap fst))) (parseDeckSpans source)

-- | 'openers' of a text parsed already, each block with the line it
-- starts on.
openersParsed :: Text -> [(Maybe Int, Block)] -> [(Int, Int, [Inline])]
openersParsed source spans = atLines (parserLineStarts source) 1 [(l, level, xs) | (Just l, Heading level _ xs) <- deckLevel spans, level <= 2]
  where
    -- The lines are in order: walk the lines' starts once.
    atLines starts n = \case
      [] -> []
      (l, level, xs) : rest -> case drop (l - n) starts of
        s : starts' -> (s, level, xs) : atLines (s : starts') l rest
        [] -> []

----------------------------------------------------------------------
-- Text

-- | The rows at the given starts of a text, each start but the first just
-- after a line break.
rowsFrom :: Text -> [(RowKey, Int)] -> Rows
rowsFrom source located = uncurry Rows (go source located)
  where
    go rest = \case
      [] -> ([], [])
      [(key, _)] -> ([Row {key, text = rest}], [])
      (key, s) : more@((_, s') : _) ->
        let (chunk, rest') = T.splitAt (s' - s) rest
            n = if "\r\n" `T.isSuffixOf` chunk then 2 else 1
            (body, sep) = T.splitAt (T.length chunk - n) chunk
         in bimap (Row {key, text = body} :) (sep :) (go rest' more)

-- | How long the line break before a character is: two for @\\r\\n@, one
-- otherwise.
separatorLength :: Text -> Int -> Int
separatorLength source s = if s >= 2 && slice (s - 2) s source == "\r\n" then 2 else 1

-- | The line break a text uses first, @\\n@ when it has none: what the
-- steps write between rows.
lineEndingOf :: Text -> Text
lineEndingOf source = case T.break (\c -> c == '\n' || c == '\r') source of
  (_, rest)
    | "\r\n" `T.isPrefixOf` rest -> "\r\n"
    | "\r" `T.isPrefixOf` rest -> "\r"
    | otherwise -> "\n"

-- | Whether a text ends with a line break.
lineEnded :: Text -> Bool
lineEnded t = "\n" `T.isSuffixOf` t || "\r" `T.isSuffixOf` t

-- | Whether a text that ends with a line break has a blank line last, as
-- an editor counts lines.
endsBlank :: Text -> Bool
endsBlank t = case reverse (editorLines t) of
  _ : lastLine : _ : _ -> T.all isSpace lastLine
  _ -> False

-- | A text's lines as an editor counts them: ended by @\\r\\n@, @\\r@ or
-- @\\n@.
editorLines :: Text -> [Text]
editorLines = T.splitOn "\n" . T.replace "\r" "\n" . T.replace "\r\n" "\n"

-- | Whether a row's text starts with a setext heading rather than an ATX
-- one (a hash after at most three spaces), as 'Wiki.Core.Slides.moveSlide'
-- tells them apart.
setext :: Text -> Bool
setext t = not ("#" `T.isPrefixOf` T.dropWhile (== ' ') (T.take 4 t))

-- | The characters of a text from one offset up to another.
slice :: Int -> Int -> Text -> Text
slice a b = T.take (b - a) . T.drop a

-- | A key so many after another.
plus :: RowKey -> Int -> RowKey
plus (RowKey k) n = RowKey (k + n)
