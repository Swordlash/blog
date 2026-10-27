-- | The editor's toolbar commands, as pure functions: each command takes
-- a page's Markdown and the selection in it, and returns the changed
-- Markdown and what to select afterwards. The browser only passes the text
-- and the selection in and out (decision 13: the toolbar writes Markdown
-- for an author who does not know it), so every command is tested here,
-- natively.
--
-- Commands come in four kinds.
--
-- * Inline ones ('Bold', 'Italic', 'Strikethrough', 'InlineCode',
--   'InlineMath', and 'Html' with a phrasing tag) wrap the selection in
--   their markers. With nothing selected they insert a placeholder between
--   the markers and select it, so that typing replaces it. On a selection
--   that is already wrapped, with the markers inside the selection
--   (@**word**@ selected) or just outside it (@word@ selected in
--   @**word**@), they remove the markers. Markers go around the words, not the spaces at either end
--   (@** word**@ is not emphasis), and around each paragraph of a selection
--   separately, since emphasis cannot span a blank line.
--
-- * Line ones ('BulletList', 'NumberedList', 'TaskList', 'Quote',
--   'Heading') change the start of every line the selection touches, and
--   remove their prefix again when every line already has it. A list
--   command turns a list of another kind into its own; 'Heading' cycles
--   through levels one to three and back to none.
--
-- * Block ones ('CodeBlock', 'DisplayMath', 'Mermaid', 'Tikz', 'Html'
--   'Details') put fences around the lines the selection touches, or a
--   template after the cursor's line when nothing is selected; on lines
--   already fenced they remove the fences.
--
-- * Templates ('Table', 'HorizontalRule') go after the line the selection
--   ends on.
--
-- * Colours ('TextColour', 'Highlight') wrap the selection in an element
--   whose class names a colour of the palette: @<span class="c-red">@ for
--   the text's colour, @<mark class="h-yellow">@ for a highlight. A class,
--   not a @style@, which the HTML allowlist refuses
--   ("Wiki.Core.Markdown.Html"); the stylesheet styles each class in
--   either theme. The selected words end up in exactly the chosen colour:
--   wrappers of the same kind in or around them are removed rather than
--   nested, and where the selection covers part of a wrapper, the part
--   outside keeps its colour in a wrapper of its own. Wrappers go around
--   each line separately, and around the line's text after a list item's
--   marker, a quote's @>@ or a heading's @#@: a tag pair across a line
--   break would take in the next line's marker and break its list or
--   quote, and an inline tag pair stays within its line (decision 13). See
--   'colour'.
--
-- A block is separated from the text around it by a blank line, without
-- which it would not be a block: a @---@ under a paragraph makes the
-- paragraph a heading, and text under a @<details>@ block would end up
-- inside it.
--
-- Offsets count characters (code points), as 'Text' does. A browser counts
-- UTF-16 code units, so the browser side converts both ways
-- ("Wiki.App.Editor.Browser").
module Wiki.Core.Markdown.Edit
  ( Selection (..)
  , cursor
  , Command (..)
  , HtmlTag (..)
  , htmlTagName
  , htmlTagLabel
  , Colour (..)
  , colourName
  , colourLabel
  , textColours
  , highlightColours
  , textColourClass
  , highlightClass
  , apply
  )
where

import Data.List (findIndex, lookup, span, zip3)
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Protolude hiding (link, list, replace)

-- | 'Selection': what is selected, from 'start' to 'end', in characters
-- from the start of the text. Nothing is selected when the two are equal;
-- then it is the cursor's position.
data Selection = Selection {start :: Int, end :: Int}
  deriving stock (Eq, Show)

-- | The cursor at an offset, with nothing selected.
cursor :: Int -> Selection
cursor at = Selection at at

-- | What a toolbar button or a shortcut does.
data Command
  = Bold
  | Italic
  | Strikethrough
  | InlineCode
  | InlineMath
  | -- | No heading, then levels one, two, three, and none again.
    Heading
  | BulletList
  | NumberedList
  | TaskList
  | Quote
  | -- | A fenced code block, with the cursor where its language goes.
    CodeBlock
  | DisplayMath
  | Mermaid
  | -- | A TikZ picture: the body of a @tikzpicture@.
    Tikz
  | Link
  | -- | An image by its URL. (An attachment is uploaded instead, and the
    -- editor inserts its reference.)
    Image
  | -- | A table of three columns.
    Table
  | HorizontalRule
  | Html HtmlTag
  | -- | The text in a colour, or, for 'Nothing', in none (the page's own).
    TextColour (Maybe Colour)
  | -- | A highlight in a colour, or, for 'Nothing', none.
    Highlight (Maybe Colour)
  deriving stock (Eq, Show)

-- | The HTML the toolbar offers: elements of the allowlist
-- ("Wiki.Core.Markdown.Html") that Markdown has no syntax for. All are
-- inline but 'Details', a block.
data HtmlTag = Mark | Kbd | Sup | Sub | Underline | Small | Details
  deriving stock (Eq, Show, Enum, Bounded)

-- | The element's name.
htmlTagName :: HtmlTag -> Text
htmlTagName = \case
  Mark -> "mark"
  Kbd -> "kbd"
  Sup -> "sup"
  Sub -> "sub"
  Underline -> "u"
  Small -> "small"
  Details -> "details"

-- | The toolbar menu's label for it. @<mark>@ is "Mark" rather than
-- "Highlight", which is the palette's name for its row of highlights
-- ('Highlight'), so that the two are not confused.
htmlTagLabel :: HtmlTag -> Text
htmlTagLabel = \case
  Mark -> "Mark"
  Kbd -> "Keyboard key"
  Sup -> "Superscript"
  Sub -> "Subscript"
  Underline -> "Underline"
  Small -> "Small print"
  Details -> "Collapsible section"

-- | A colour of the toolbar's palette. The text colours are 'textColours'
-- and the highlights 'highlightColours'; the stylesheet styles those, in
-- the light theme and the dark one, and no others.
data Colour = Red | Orange | Yellow | Green | Teal | Blue | Purple | Pink | Grey
  deriving stock (Eq, Show, Enum, Bounded)

-- | The colour's name, as used in its class.
colourName :: Colour -> Text
colourName = T.toLower . show

-- | The palette's label for it.
colourLabel :: Colour -> Text
colourLabel = show

-- | The colours text can be written in: none of them pale, so that each is
-- readable on the page's background.
textColours :: [Colour]
textColours = [Red, Orange, Green, Teal, Blue, Purple, Pink, Grey]

-- | The colours of a highlight: pale ones in the light theme, deep ones in
-- the dark theme, so that the text on them is readable.
highlightColours :: [Colour]
highlightColours = [Yellow, Green, Blue, Pink, Purple]

-- | The class of text in this colour: @c-red@.
textColourClass :: Colour -> Text
textColourClass c = "c-" <> colourName c

-- | The class of a highlight in this colour: @h-yellow@.
highlightClass :: Colour -> Text
highlightClass c = "h-" <> colourName c

-- | Apply a command to the text with this selection. The result is the
-- new text, and what is selected in it afterwards.
apply :: Command -> Text -> Selection -> (Text, Selection)
apply command text selection = case command of
  Bold -> inline (wrapIn "**") "bold text"
  Italic -> inline (wrapIn "_") "italic text"
  Strikethrough -> inline (wrapIn "~~") "struck text"
  InlineCode -> inline codeSpan "code"
  InlineMath -> inline (wrapIn "$") "x^2"
  Html Details -> details text sel
  Html tag -> inline (wrapIn' ("<" <> htmlTagName tag <> ">") ("</" <> htmlTagName tag <> ">")) (htmlPlaceholder tag)
  Heading -> heading text sel
  BulletList -> list Bullet text sel
  NumberedList -> list Numbered text sel
  TaskList -> list Task text sel
  Quote -> quote text sel
  CodeBlock -> fenced (Fence "```" "```" "" False) text sel
  DisplayMath -> fenced (Fence "$$" "$$" "E = mc^2" True) text sel
  Mermaid -> fenced (Fence "```mermaid" "```" "graph LR\n  A --> B" True) text sel
  Tikz -> fenced (Fence "```tikz" "```" "\\draw[->] (0,0) -- (2,1) node[right] {$x$};" True) text sel
  Link -> link "" "link text" text sel
  Image -> link "!" "description" text sel
  Table -> template tableTemplate (Just (2, T.length "Column 1")) text sel
  HorizontalRule -> template "---" Nothing text sel
  TextColour c -> colour textWrapper (textColourClass <$> c) text sel
  Highlight c -> colour highlightWrapper (highlightClass <$> c) text sel
  where
    sel = normalise text selection
    inline :: Markers -> Text -> (Text, Selection)
    inline markers placeholder = wrapInline markers placeholder text sel

-- | The selection inside the text, start first.
normalise :: Text -> Selection -> Selection
normalise text (Selection a b) = Selection (min a' b') (max a' b')
  where
    clamp = max 0 . min (T.length text)
    a' = clamp a
    b' = clamp b

htmlPlaceholder :: HtmlTag -> Text
htmlPlaceholder = \case
  Mark -> "highlighted text"
  Kbd -> "Ctrl"
  Sup -> "superscript"
  Sub -> "subscript"
  Underline -> "underlined text"
  Small -> "small print"
  Details -> "Details"

tableTemplate :: Text
tableTemplate =
  T.intercalate
    "\n"
    [ "| Column 1 | Column 2 | Column 3 |"
    , "| -------- | -------- | -------- |"
    , "| Text     | Text     | Text     |"
    ]

-- Replacing parts of the text

-- | A change to one part of the text: at an offset, so many characters
-- replaced by a text. A command is a list of them, in order and not
-- overlapping.
data Replacement = Replacement Int Int Text

replace :: [Replacement] -> Text -> Text
replace reps text = go 0 reps
  where
    go at = \case
      [] -> T.drop at text
      Replacement pos len new : rest -> slice at pos <> new <> go (pos + len) rest
    slice a b = T.take (b - a) (T.drop a text)

-- | Which side of text inserted at an offset the offset ends up on.
data Bias = Before | After

-- | Where an offset in the text ends up after the replacements: shifted by
-- what was inserted or removed before it; inside a replaced part, as far
-- into the new text as it was into the old.
moved :: Bias -> [Replacement] -> Int -> Int
moved bias reps p = go 0 reps
  where
    go delta = \case
      [] -> p + delta
      Replacement pos len new : rest
        | pos > p -> p + delta
        | pos == p && len == 0 -> case bias of
            Before -> p + delta
            After -> go (delta + T.length new) rest
        | pos == p -> p + delta
        | pos + len <= p -> go (delta + T.length new - len) rest
        | otherwise -> pos + delta + min (p - pos) (T.length new)

-- Inline commands

-- | What an inline command puts around a text: the markers made for the
-- text, and the plain markers that are recognised and removed.
data Markers = Markers {forText :: Text -> (Text, Text), plain :: (Text, Text)}

-- | The same marker on both sides.
wrapIn :: Text -> Markers
wrapIn marker = Markers (const (marker, marker)) (marker, marker)

wrapIn' :: Text -> Text -> Markers
wrapIn' open close = Markers (const (open, close)) (open, close)

-- | Backticks around code: more of them than the longest run in the code,
-- and, where the code starts or ends with a backtick, a space inside them
-- on both sides (CommonMark removes one space only when there is one at
-- each end). Single backticks are the ones removed.
codeSpan :: Markers
codeSpan = Markers forCode ("`", "`")
  where
    forCode code =
      let longest = foldr (max . T.length) 0 (filter ("`" `T.isPrefixOf`) (T.group code))
          fence = T.replicate (longest + 1) "`"
          pad = if T.isPrefixOf "`" code || T.isSuffixOf "`" code then " " else ""
       in (fence <> pad, pad <> fence)

-- | Wrap the selection's paragraphs in the markers, or unwrap them; with
-- nothing selected, insert the placeholder wrapped and select it.
wrapInline :: Markers -> Text -> Text -> Selection -> (Text, Selection)
wrapInline markers placeholder text sel@(Selection s e)
  | s == e || null spans =
      let (before, after) = markers.forText placeholder
          at = e
       in ( replace [Replacement at 0 (before <> placeholder <> after)] text
          , Selection (at + T.length before) (at + T.length before + T.length placeholder)
          )
  | all wrappedInside spans = unwrapWith (concatMap inside spans)
  | all wrappedAround spans = unwrapWith (concatMap around spans)
  | otherwise = unwrapWith (concatMap wrap spans)
  where
    spans = paragraphSpans text sel
    firstStart = maybe s fst (head spans)
    lastEnd = maybe e snd (lastMay spans)
    piece (a, b) = T.take (b - a) (T.drop a text)
    (open, close) = markers.plain
    wrappedInside part@(a, b) =
      b - a >= T.length open + T.length close
        && T.isPrefixOf open (piece part)
        && T.isSuffixOf close (piece part)
    inside (a, b) = [Replacement a (T.length open) "", Replacement (b - T.length close) (T.length close) ""]
    wrappedAround (a, b) = T.isSuffixOf open (T.take a text) && T.isPrefixOf close (T.drop b text)
    around (a, b) = [Replacement (a - T.length open) (T.length open) "", Replacement b (T.length close) ""]
    wrap part@(a, b) =
      let (before, after) = markers.forText (piece part)
       in [Replacement a 0 before, Replacement b 0 after]
    -- The same words selected afterwards, without the markers.
    unwrapWith reps = (replace reps text, Selection (moved After reps firstStart) (moved Before reps lastEnd))

-- | The parts of the selection to wrap separately: its runs of lines with
-- no blank line between them, without the white space at either end. None
-- when it is all white space.
paragraphSpans :: Text -> Selection -> [(Int, Int)]
paragraphSpans text (Selection s e) = mapMaybe trimmed (groups (lineSpans (T.take (e - s) (T.drop s text))))
  where
    -- The selected text's lines, by offset in the whole text.
    lineSpans selected = zip (scanl (\at l -> at + T.length l + 1) s ls) ls
      where
        ls = T.splitOn "\n" selected
    groups = \case
      [] -> []
      ls ->
        let (blank, rest) = span (T.all isSpace . snd) ls
            (run, rest') = break (T.all isSpace . snd) rest
         in [run | not (null run)] <> (if null blank && null run then [] else groups rest')
    trimmed run = case (head run, lastMay run) of
      (Just (a, firstLine), Just (b, lastLine)) ->
        let lo = a + T.length (T.takeWhile isSpace firstLine)
            hi = b + T.length (T.dropWhileEnd isSpace lastLine)
         in if lo < hi then Just (lo, hi) else Nothing
      _ -> Nothing

-- Lines

-- | A line of the text: where it starts, and its text without the newline.
data Line = Line {at :: Int, line :: Text}

allLines :: Text -> [Line]
allLines text = zipWith Line (scanl (\at l -> at + T.length l + 1) 0 ls) ls
  where
    ls = T.splitOn "\n" text

-- | The lines the selection touches. A selection that ends at the start of a
-- line, as one made by selecting whole lines does, does not touch that one.
touched :: Text -> Selection -> [Line]
touched text (Selection s e) = filter (\l -> l.at <= e' && s <= l.at + T.length l.line) (allLines text)
  where
    e' = if e > s && T.isSuffixOf "\n" (T.take e text) then e - 1 else e

-- | The lines a line command changes: the selected lines that have
-- something on them, or all of them when none has.
targets :: [Line] -> [Line]
targets ls = case filter (not . T.all isSpace . (\l -> l.line)) ls of
  [] -> ls
  nonBlank -> nonBlank

-- | The selection after line replacements: the same text selected, or the
-- cursor after a prefix inserted where it was.
afterLines :: Selection -> [Replacement] -> Selection
afterLines (Selection s e) reps
  | s == e = cursor (moved After reps s)
  | otherwise = Selection (moved Before reps s) (moved After reps e)

data ListKind = Bullet | Numbered | Task
  deriving stock (Eq)

-- | A line's indentation, and the list item marker after it, if any: the
-- marker's kind and length.
listMarker :: Text -> (Int, Maybe (ListKind, Int))
listMarker l = (T.length indent, marker)
  where
    (indent, rest) = T.span (\c -> c == ' ' || c == '\t') l
    marker
      | Just m <- bulletOf rest
      , Just task <- T.stripPrefix "[" (T.drop m rest)
      , Just after <- T.stripPrefix "] " (T.drop 1 task)
      , T.take 1 task `elem` [" ", "x", "X"] =
          Just (Task, T.length rest - T.length after)
      | Just m <- bulletOf rest = Just (Bullet, m)
      | otherwise =
          let digits = T.takeWhile isDigit rest
              after = T.drop (T.length digits) rest
           in if not (T.null digits) && T.length digits <= 9 && (T.isPrefixOf ". " after || T.isPrefixOf ") " after)
                then Just (Numbered, T.length digits + 2)
                else Nothing
    bulletOf r = case T.unpack (T.take 2 r) of
      [c, ' '] | c `elem` ['-', '*', '+'] -> Just 2
      _ -> Nothing

-- | Make every touched line an item of a list of this kind, or, when each
-- already is, plain lines.
list :: ListKind -> Text -> Selection -> (Text, Selection)
list kind text sel = (replace reps text, afterLines sel reps)
  where
    ls = targets (touched text sel)
    markers = map (listMarker . (\l -> l.line)) ls
    already = all (\(_, m) -> fmap fst m == Just kind) markers
    reps
      | already = [Replacement (l.at + indent) len "" | (l, (indent, Just (_, len))) <- zip ls markers]
      | otherwise =
          [ Replacement (l.at + indent) (maybe 0 snd m) (prefix n)
          | (n, l, (indent, m)) <- zip3 [1 :: Int ..] ls markers
          ]
    prefix n = case kind of
      Bullet -> "- "
      Task -> "- [ ] "
      Numbered -> show n <> ". "

-- | Quote every touched line, or, when each already is, unquote them.
quote :: Text -> Selection -> (Text, Selection)
quote text sel = (replace reps text, afterLines sel reps)
  where
    ls = touched text sel
    quoted l = T.isPrefixOf ">" l.line
    reps
      | all quoted ls = [Replacement l.at (if T.isPrefixOf "> " l.line then 2 else 1) "" | l <- ls]
      | otherwise = [Replacement l.at 0 (if T.all isSpace l.line then ">" else "> ") | l <- ls, not (quoted l)]

-- | Set every touched line to the heading level after the first line's:
-- none, one, two, three, then none again.
heading :: Text -> Selection -> (Text, Selection)
heading text sel = (replace reps text, afterLines sel reps)
  where
    ls = targets (touched text sel)
    levelOf l =
      let hashes = T.takeWhile (== '#') l.line
          after = T.drop (T.length hashes) l.line
       in if T.length hashes `elem` [1 .. 6] && (T.null after || T.isPrefixOf " " after)
            then (T.length hashes, T.length hashes + min 1 (T.length after))
            else (0, 0)
    next = case fst . levelOf <$> head ls of
      Just level | level >= 1 && level < 3 -> level + 1
      Just 0 -> 1
      _ -> 0
    reps = [Replacement l.at (snd (levelOf l)) (if next == 0 then "" else T.replicate next "#" <> " ") | l <- ls]

-- Blocks

-- | What goes before and after a block inserted between these two texts
-- so that it is a separate block: a blank line on each side, unless the
-- text already has one there or ends there.
blockSeparators :: Text -> Text -> (Text, Text)
blockSeparators before after = (pre, post)
  where
    pre
      | T.all isSpace before || T.isSuffixOf "\n\n" before = ""
      | T.isSuffixOf "\n" before = "\n"
      | otherwise = "\n\n"
    post
      | T.all isSpace after || T.isPrefixOf "\n\n" after = ""
      | T.isPrefixOf "\n" after = "\n"
      | otherwise = "\n\n"

-- | Where a template goes: after the line the selection ends on.
endOfLine :: Text -> Selection -> Int
endOfLine text (Selection _ e) = e + T.length (T.takeWhile (/= '\n') (T.drop e text))

-- | Insert a block after the line the selection ends on, and select part
-- of it afterwards (an offset into the block and a length), if given, or
-- put the cursor after it.
template :: Text -> Maybe (Int, Int) -> Text -> Selection -> (Text, Selection)
template block select text sel = (replace [Replacement at 0 new] text, selected)
  where
    at = endOfLine text sel
    (pre, post) = blockSeparators (T.take at text) (T.drop at text)
    new = pre <> block <> post
    begin = at + T.length pre
    selected = case select of
      Just (offset, len) -> Selection (begin + offset) (begin + offset + len)
      Nothing -> cursor (begin + T.length block)

-- | Fences around lines: the opening line, the closing one, what goes
-- between them when nothing is selected, and whether that is selected
-- afterwards (otherwise the cursor goes at the end of the opening line,
-- where a code block's language is written).
data Fence = Fence {open :: Text, close :: Text, placeholder :: Text, selectInside :: Bool}

-- | Fence the lines the selection touches, or unfence lines already fenced
-- (the selection's first and last lines, or those just around it); with
-- nothing selected, insert an empty block after the cursor's line.
fenced :: Fence -> Text -> Selection -> (Text, Selection)
fenced fence text sel@(Selection s e)
  | s == e = case fence.selectInside of
      True -> template block (Just (T.length fence.open + 1, T.length fence.placeholder)) text sel
      False -> template block (Just (T.length fence.open, 0)) text sel
  | otherwise = case touched text sel of
      [] -> (text, sel)
      ls@(firstLine : _) ->
        let lastLine = fromMaybe firstLine (lastMay ls)
            top = fromMaybe 0 (index firstLine)
            bottom = fromMaybe top (index lastLine)
         in if bottom > top && opens top && closes bottom
              then unfence top bottom
              else
                if top > 0 && opens (top - 1) && closes (bottom + 1)
                  then unfence (top - 1) (bottom + 1)
                  else wrapLines firstLine lastLine
  where
    block = fence.open <> "\n" <> fence.placeholder <> "\n" <> fence.close
    all' = allLines text
    index l = findIndex (\m -> m.at == l.at) all'
    -- Whether a fence line opens or closes a block depends on how many came
    -- before it: a closing @```@ looks like an opening one.
    marker = if T.isPrefixOf "```" fence.open then "```" else fence.open
    isFence l = T.isPrefixOf marker (T.strip l.line)
    fencesBefore i = length (filter isFence (take i all'))
    lineAt i = all' `atMay` i
    opens i = case lineAt i of
      Just l -> T.isPrefixOf fence.open (T.strip l.line) && even (fencesBefore i)
      Nothing -> False
    closes i = case lineAt i of
      Just l -> T.strip l.line == fence.close && odd (fencesBefore i)
      Nothing -> False
    -- Remove the opening line and the closing one, selecting what was
    -- between them.
    unfence i j = case (lineAt i, lineAt j) of
      (Just o, Just c)
        | j == i + 1 -> (replace [Replacement o.at (c.at + T.length c.line - o.at) ""] text, cursor o.at)
        | otherwise ->
            let reps = [Replacement o.at (T.length o.line + 1) "", Replacement (c.at - 1) (T.length c.line + 1) ""]
             in (replace reps text, Selection o.at (c.at - 1 - (T.length o.line + 1)))
      _ -> (text, sel)
    wrapLines firstLine lastLine =
      let lo = firstLine.at
          hi = lastLine.at + T.length lastLine.line
          content = T.take (hi - lo) (T.drop lo text)
          (pre, post) = blockSeparators (T.take lo text) (T.drop hi text)
          begin = lo + T.length pre
          new = pre <> fence.open <> "\n" <> content <> "\n" <> fence.close <> post
          selected
            | fence.selectInside = Selection (begin + T.length fence.open + 1) (begin + T.length fence.open + 1 + T.length content)
            | otherwise = cursor (begin + T.length fence.open)
       in (replace [Replacement lo (hi - lo) new] text, selected)

-- | A collapsible section: @<details>@ around the touched lines, with a
-- @<summary>@ to name it, which is selected. An HTML block ends at a blank
-- line, so the lines are inserted without the blank ones among them.
-- Lines that already are such a section are unwrapped.
details :: Text -> Selection -> (Text, Selection)
details text sel@(Selection s e)
  | s == e = template sectionTemplate (Just (T.length "<details>\n<summary>", T.length summary)) text sel
  | otherwise = case touched text sel of
      [] -> (text, sel)
      ls@(firstLine : _) ->
        let lastLine = fromMaybe firstLine (lastMay ls)
            lo = firstLine.at
            hi = lastLine.at + T.length lastLine.line
            inner = drop 1 (take (length ls - 1) ls)
            withoutSummary = case inner of
              l : rest | T.isPrefixOf "<summary" (T.strip l.line) -> rest
              _ -> inner
         in if length ls >= 2 && T.isPrefixOf "<details" (T.strip firstLine.line) && T.strip lastLine.line == "</details>"
              then
                let content = T.intercalate "\n" (map (\l -> l.line) withoutSummary)
                 in (replace [Replacement lo (hi - lo) content] text, Selection lo (lo + T.length content))
              else
                let content = T.intercalate "\n" [l.line | l <- ls, not (T.all isSpace l.line)]
                    (pre, post) = blockSeparators (T.take lo text) (T.drop hi text)
                    opening = "<details>\n<summary>"
                    begin = lo + T.length pre + T.length opening
                    new = pre <> opening <> summary <> "</summary>\n" <> content <> "\n</details>" <> post
                 in (replace [Replacement lo (hi - lo) new] text, Selection begin (begin + T.length summary))
  where
    summary = htmlPlaceholder Details
    sectionTemplate = "<details>\n<summary>" <> summary <> "</summary>\nWhat opens on a click.\n</details>"

-- Links

-- | A link (or, with @!@ before it, an image). Around a selection, which
-- becomes its text, with the URL selected to be typed; around a selected
-- URL, with a placeholder for the text selected; or, with nothing
-- selected, a placeholder for both, with the text selected. A selection
-- that is already a link's text is unwrapped.
link :: Text -> Text -> Text -> Selection -> (Text, Selection)
link bang placeholder text (Selection s e)
  | s == e =
      let new = bang <> "[" <> placeholder <> "](" <> address <> ")"
          begin = s + T.length bang + 1
       in (replace [Replacement s 0 new] text, Selection begin (begin + T.length placeholder))
  | Just close <- linkAround = (replace [Replacement (s - T.length opening) (T.length opening) "", Replacement e close ""] text, Selection (s - T.length opening) (e - T.length opening))
  | isAddress selected =
      let new = bang <> "[" <> placeholder <> "](" <> selected <> ")"
          begin = s + T.length bang + 1
       in (replace [Replacement s (e - s) new] text, Selection begin (begin + T.length placeholder))
  | otherwise =
      let reps = [Replacement s 0 (bang <> "["), Replacement e 0 ("](" <> address <> ")")]
          begin = e + T.length bang + 1 + 2
       in (replace reps text, Selection begin (begin + T.length address))
  where
    address = "https://"
    opening = bang <> "["
    selected = T.take (e - s) (T.drop s text)
    isAddress t = not (T.any isSpace t) && any (`T.isPrefixOf` t) ["http://", "https://", "mailto:"]
    -- How many characters follow the selection up to the end of the link,
    -- if it is a link's text: @](@, the URL, @)@.
    linkAround
      | T.isSuffixOf opening (T.take s text) && (bang /= "" || not (T.isSuffixOf "![" (T.take s text))) =
          let rest = T.drop e text
           in case T.stripPrefix "](" rest of
                Just target | (addr, closing) <- T.break (\c -> c == ')' || c == '\n') target, T.isPrefixOf ")" closing -> Just (2 + T.length addr + 1)
                _ -> Nothing
      | otherwise = Nothing

-- Colours

-- | A kind of colour wrapper: its element, the prefix of the classes that
-- name its colours, and whether the element without a class also counts
-- as one. A bare @<mark>@ is a highlight (the HTML menu's, in the default
-- colour), so choosing a colour for it gives it a class; a bare @<span>@
-- has no colour.
data Wrapper = Wrapper {element :: Text, prefix :: Text, bare :: Bool}

textWrapper, highlightWrapper :: Wrapper
textWrapper = Wrapper "span" "c-" False
highlightWrapper = Wrapper "mark" "h-" True

-- | A wrapper's colour: its class, or nothing for a bare one.
type Paint = Text

openTag :: Wrapper -> Paint -> Text
openTag w paint
  | T.null paint = "<" <> w.element <> ">"
  | otherwise = "<" <> w.element <> " class=\"" <> paint <> "\">"

closeTag :: Wrapper -> Text
closeTag w = "</" <> w.element <> ">"

-- | Put the selected words in this colour, or in none ('Nothing').
--
-- On each line the selection touches, the words selected on it (without
-- the white space at either end, or a block's marker at the start of the
-- line, 'blockPrefix') end up in exactly the requested colour. Every
-- wrapper of this kind the selection reaches into is split: its selected
-- text takes the new colour, and the rest keeps the old one, in a wrapper
-- of its own. So re-colouring a coloured word replaces its class instead of
-- nesting another wrapper in it, re-colouring part of it splits it in two
-- or three, and choosing no colour removes the wrapper. Adjacent text of
-- one colour ends up in one wrapper. The text outside the wrappers reached
-- is left as it is.
--
-- With nothing selected, the cursor inside a wrapper's text stands for all
-- of it, so that a colour can be changed or removed without selecting the
-- word first. Anywhere else, a colour inserts a placeholder in its wrapper
-- and selects it, as the other inline commands do, and no colour does
-- nothing.
--
-- Only the wrappers this command writes are recognised (@<span
-- class="c-…">@, or @<mark>@ with or without @class="h-…"@), each with its
-- closing tag on the same line. Other elements on the line (the other
-- kind's wrappers, @<b>@, a @<span>@ of another class) are kept whole: a
-- wrapper goes around an element whose text is all in its colour, or
-- inside it otherwise, so that the elements stay properly nested. A tag
-- that is not closed on its line, or closes nothing, counts as text.
colour :: Wrapper -> Maybe Paint -> Text -> Selection -> (Text, Selection)
colour w wanted text sel@(Selection s e)
  | s == e = maybe placeholder (\(lo, hi) -> fromMaybe (text, sel) (paintRange lo hi)) wrapperAtCursor
  | otherwise = fromMaybe placeholder (paintRange s e)
  where
    ls = allLines text
    placeholder = case wanted of
      Nothing -> (text, sel)
      Just paint ->
        let opening = openTag w paint
            placeholderText = if w.bare then "highlighted text" else "coloured text"
            begin = outsideTags + T.length opening
         in (replace [Replacement outsideTags 0 (opening <> placeholderText <> closeTag w)] text, Selection begin (begin + T.length placeholderText))
    -- Where the placeholder goes: at the end of the selection, or after
    -- the tag the selection ends in.
    outsideTags = fromMaybe e $ do
      l <- find (\l -> l.at <= e && e <= l.at + T.length l.line) ls
      tag <- find (\p -> l.at + p.from < e && e < l.at + p.to) (piecesOf w l.line)
      pure (l.at + tag.to)
    -- The text of the innermost wrapper the cursor is in, if any.
    wrapperAtCursor = do
      l <- find (\l -> l.at <= s && s <= l.at + T.length l.line) ls
      let at = s - l.at
          around = [inner | (_, inner@(lo, hi)) <- wrappersOf (readLine w l.line), lo <= at, at <= hi]
      (lo, hi) <- lastMay (sortOn fst around)
      pure (l.at + lo, l.at + hi)
    -- Paint every line from lo to hi; nothing when there are no words.
    paintRange lo hi =
      let painted = [paintLine w wanted l.line (max lo l.at - l.at) (min hi (l.at + T.length l.line) - l.at) | l <- ls]
          newLines = map fst painted
          starts = scanl (\at l -> at + T.length l + 1) 0 newLines
          spans = [(at + a, at + b) | (at, Just (a, b)) <- zip starts (map snd painted)]
       in case (head spans, lastMay spans) of
            (Just (a, _), Just (_, b)) -> Just (T.intercalate "\n" newLines, Selection a b)
            _ -> Nothing

-- | A part of a line as this command reads it: a character, a tag that
-- opens an element (with, for a wrapper of the command's kind, its
-- colour), a tag that closes an element, or a tag that stands alone
-- (@<br>@, @<img>@, @<x/>@).
data Piece = Piece {from :: Int, to :: Int, kind :: PieceKind}

data PieceKind = Letter | Opening Text (Maybe Paint) | Closing Text | Lone

-- | A line as this command reads it: its pieces, the elements on it (each
-- opening tag that is closed on the line, by its start, with its closing
-- tag), and the colour each piece is in.
data Line' = Line'
  { pieces :: [Piece]
  , pairs :: [(Int, Piece)]
  , paints :: [(Int, Maybe Paint)]
  }

-- | Read a line. An opening tag is closed by the next closing tag with its
-- name once every element opened after it has closed; a tag that is not
-- matched, opening or closing, counts as text.
readLine :: Wrapper -> Text -> Line'
readLine w line = Line' {pieces = ps, pairs, paints = colours [] ps}
  where
    ps = piecesOf w line
    pairs = go [] ps
      where
        go stack = \case
          [] -> []
          p : rest -> case p.kind of
            Opening _ _ -> go (p : stack) rest
            Closing name
              | o : outer <- stack
              , Opening open _ <- o.kind
              , open == name ->
                  (o.from, p) : go outer rest
            _ -> go stack rest
    closings = map ((\p -> p.from) . snd) pairs
    -- The colours of the elements open around a piece, innermost first:
    -- 'Nothing' for an element that is not a wrapper.
    colours stack = \case
      [] -> []
      p : rest ->
        (p.from, asum stack) : case p.kind of
          Opening _ paint | isJust (lookup p.from pairs) -> colours (paint : stack) rest
          Closing _ | p.from `elem` closings -> colours (drop 1 stack) rest
          _ -> colours stack rest

-- | The wrappers of a line: the part of the line each covers, tags
-- included, and the part its text covers.
wrappersOf :: Line' -> [((Int, Int), (Int, Int))]
wrappersOf l = [((p.from, c.to), (p.to, c.from)) | p@Piece {kind = Opening _ (Just _)} <- l.pieces, Just c <- [lookup p.from l.pairs]]

-- | A line's pieces.
piecesOf :: Wrapper -> Text -> [Piece]
piecesOf w = go 0
  where
    go at rest = case tagAt w rest of
      Just (len, k) -> Piece at (at + len) k : go (at + len) (T.drop len rest)
      Nothing
        | T.null rest -> []
        | otherwise -> Piece at (at + 1) Letter : go (at + 1) (T.drop 1 rest)

-- | The tag at the start of the text, if any: its length and its kind.
-- Element names are read in any case, as in HTML.
tagAt :: Wrapper -> Text -> Maybe (Int, PieceKind)
tagAt w t
  | Just r <- T.stripPrefix "</" t
  , Just name <- nameOf r
  , (blank, r') <- T.span isSpace (T.drop (T.length name) r)
  , T.isPrefixOf ">" r' =
      Just (2 + T.length name + T.length blank + 1, Closing (T.toLower name))
  | Just r <- T.stripPrefix "<" t
  , Just name <- nameOf r
  , Just (c, _) <- T.uncons (T.drop (T.length name) r)
  , isSpace c || c == '>' || c == '/'
  , (attributes, closing) <- T.break (== '>') (T.drop (T.length name) r)
  , not (T.null closing) =
      let element = T.toLower name
          len = 1 + T.length name + T.length attributes + 1
       in Just $
            if T.isSuffixOf "/" attributes || element `elem` voidElements
              then (len, Lone)
              else (len, Opening element (if element == w.element then paintOf attributes else Nothing))
  | otherwise = Nothing
  where
    nameOf r = case T.takeWhile (\c -> isAsciiLetter c || isDigit c || c == '-') r of
      name | Just (c, _) <- T.uncons name, isAsciiLetter c -> Just name
      _ -> Nothing
    isAsciiLetter c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    voidElements = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]
    -- The colour the attributes give: one class of the wrapper's and
    -- nothing else, or no attributes at all where a bare element is a
    -- wrapper.
    paintOf attributes = case T.strip attributes of
      "" | w.bare -> Just ""
      a -> do
        value <- classValue a
        name <- T.stripPrefix w.prefix value
        guard (not (T.null name) && T.all (\c -> (c >= 'a' && c <= 'z') || isDigit c || c == '-') name)
        pure value
    -- The value of a lone class attribute, quoted or not.
    classValue a = do
      guard (T.toLower (T.take 5 a) == "class")
      r <- T.stripPrefix "=" (T.stripStart (T.drop 5 a))
      let r' = T.stripStart r
      case T.uncons r' of
        Just (q, quoted) | q == '"' || q == '\'' -> do
          let (value, after) = T.break (== q) quoted
          guard (T.drop 1 after == "" && not (T.null after))
          pure value
        _ -> do
          guard (not (T.any isSpace r'))
          pure r'

-- | The tree of what is rewritten in a line: its text, and the elements
-- other than wrappers, with their contents. The wrappers are removed, to be
-- put back where the colours require them.
data Node = Leaf Piece | Element Piece [Node] Piece

-- | Paint one line from @a@ to @b@, offsets in the line. The result is the
-- new line, and where the painted words are in it, if there were any.
--
-- The part of the line rewritten is what the selection touches, plus the
-- wrappers it reaches into, plus every element with one tag in that part
-- and the other outside it, so that the part holds whole elements. Its
-- text is written with each run of one colour in one wrapper: inside the
-- other elements where an element's text is not all one colour, and around
-- them where it is, so the elements stay nested as they were.
paintLine :: Wrapper -> Maybe Paint -> Text -> Int -> Int -> (Text, Maybe (Int, Int))
paintLine w wanted line a b = case (head chosen, lastMay chosen) of
  (Just firstLeaf, Just lastLeaf)
    | a < b ->
        let painted p
              | p.from >= firstLeaf.from && p.to <= lastLeaf.to = wanted
              | otherwise = fromMaybe Nothing (lookup p.from l.paints)
            (body, placed) = emit painted Nothing lo (tree region)
            at p = fromMaybe lo (lookup p.from placed)
         in (T.take lo line <> body <> T.drop hi line, Just (at firstLeaf, at lastLeaf + (lastLeaf.to - lastLeaf.from)))
  _ -> (line, Nothing)
  where
    l = readLine w line
    reached = [outer | (outer@(o, c), _) <- wrappersOf l, o < b, c > a]
    touched' = [(p.from, p.to) | p <- l.pieces, p.from < b, p.to > a]
    (lo, hi) = widen (foldr (min . fst) a (reached <> touched'), foldr (max . snd) b (reached <> touched'))
    -- Include each element with one tag inside the part and the other
    -- outside.
    widen (x, y) =
      let inside p = p.from >= x && p.to <= y
          crossing = [(o.from, c.to) | o <- l.pieces, Just c <- [lookup o.from l.pairs], inside o /= inside c]
          x' = foldr (min . fst) x crossing
          y' = foldr (max . snd) y crossing
       in if (x', y') == (x, y) then (x, y) else widen (x', y')
    region = [p | p <- l.pieces, p.from >= lo, p.to <= hi]
    isWrapper p = case p.kind of
      Opening _ (Just _) -> isJust (lookup p.from l.pairs)
      _ -> False
    wrapperClosings = [c.from | (o, c) <- l.pairs, Just p <- [find (\q -> q.from == o) l.pieces], isWrapper p]
    -- The region's pieces as a tree, without the wrappers' tags.
    tree = fst . build
      where
        build = \case
          [] -> ([], [])
          p : rest
            | isWrapper p || p.from `elem` wrapperClosings -> build rest
            | Just c <- lookup p.from l.pairs ->
                let (inner, afterInner) = build rest
                    (siblings, remaining) = build (drop 1 afterInner)
                 in (Element p inner c : siblings, remaining)
            | Closing _ <- p.kind, p.from `elem` map ((\q -> q.from) . snd) l.pairs -> ([], p : rest)
            | otherwise -> let (siblings, remaining) = build rest in (Leaf p : siblings, remaining)
    leaves = \case
      Leaf p -> [p]
      Element _ inner _ -> concatMap leaves inner
    isText p = case p.kind of
      Letter -> True
      Lone -> True
      _ -> isNothing (lookup p.from l.pairs) && notElem p.from (map ((\q -> q.from) . snd) l.pairs)
    start = max a (blockPrefix line)
    blank p = case p.kind of
      Letter -> T.all isSpace (slice p)
      _ -> False
    chosen = reverse (dropWhile blank (reverse (dropWhile blank [p | p <- region, isText p, p.from >= start, p.to <= b])))
    slice p = T.take (p.to - p.from) (T.drop p.from line)
    -- The colour a node is entirely in, if any: an element with no text in
    -- it takes its opening tag's colour.
    colourOf painted = \case
      Leaf p -> Just (painted p)
      Element o inner _ -> case map painted (concatMap leaves inner) of
        [] -> Just (painted o)
        c : cs -> if all (== c) cs then Just c else Nothing
    -- Write the nodes from an offset, in a wrapper of the colour around
    -- them ('Nothing' for none). The result is their text, and where each
    -- piece of text ended up, by where it was.
    emit painted around at nodes = foldl' step ("", [], at) (NE.groupBy sameColour nodes) & \(t, placed, _) -> (t, placed)
      where
        sameColour x y = isJust (colourOf painted x) && colourOf painted x == colourOf painted y
        step (t, placed, o) run =
          let (t', placed') = case colourOf painted (NE.head run) of
                Just c
                  | c /= around ->
                      let opening = maybe "" (openTag w) c
                          closing = maybe "" (const (closeTag w)) c
                          (inner, innerPlaced) = nodesText c (o + T.length opening) (toList run)
                       in (opening <> inner <> closing, innerPlaced)
                _ -> nodesText around o (toList run)
           in (t <> t', placed <> placed', o + T.length t')
        nodesText c o = foldl' (\(t, placed) node -> let (t', placed') = nodeText c (o + T.length t) node in (t <> t', placed <> placed')) ("", [])
        nodeText c o = \case
          Leaf p -> (slice p, [(p.from, o)])
          Element open inner close ->
            let (t, placed) = emit painted c (o + T.length (slice open)) inner
             in (slice open <> t <> slice close, placed)

-- | How much of a line is its block's syntax rather than its text: a
-- quote's @>@s, then a list item's marker or a heading's @#@s, with the
-- space after each.
blockPrefix :: Text -> Int
blockPrefix l = T.length l - T.length (afterMarker (afterQuotes l))
  where
    afterQuotes t = case T.stripPrefix ">" (T.dropWhile (== ' ') t) of
      Just r -> afterQuotes (fromMaybe r (T.stripPrefix " " r))
      Nothing -> t
    afterMarker t = case listMarker t of
      (indent, Just (_, len)) -> T.drop (indent + len) t
      _ ->
        let r = T.dropWhile (== ' ') t
            hashes = T.takeWhile (== '#') r
            rest = T.drop (T.length hashes) r
         in if T.length hashes `elem` [1 .. 6] && T.isPrefixOf " " rest then T.drop 1 rest else t
