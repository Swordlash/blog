-- | The editor's toolbar, as pure functions: each command takes a page's
-- Markdown and the selection in it, and gives back the Markdown changed and
-- what to select afterwards. The browser only moves the text and the
-- selection in and out (decision 13: the toolbar writes Markdown for an
-- author who does not know it), so every command is tested here, natively.
--
-- Commands come in four kinds.
--
-- * Inline ones ('Bold', 'Italic', 'Strikethrough', 'InlineCode',
--   'InlineMath', and 'Html' with a phrasing tag) wrap the selection in
--   their markers. With nothing selected they insert a placeholder between
--   the markers and select it, so that typing replaces it. On a selection
--   that is wrapped already, inside it (@**word**@ selected) or just around
--   it (@word@ selected in @**word**@), they take the markers away. Markers
--   go around the words, not the spaces at either end (@** word**@ is not
--   emphasis), and around each paragraph of a selection on its own, since
--   emphasis cannot cross a blank line.
--
-- * Line ones ('BulletList', 'NumberedList', 'TaskList', 'Quote',
--   'Heading') change the start of every line the selection touches, and
--   take their prefix away again when every line has it already. A list
--   command turns a list of another kind into its own; 'Heading' cycles
--   through levels one to three and back to none.
--
-- * Block ones ('CodeBlock', 'DisplayMath', 'Mermaid', 'Tikz', 'Html' 'Details')
--   put fences around the lines the selection touches, or a template after
--   the cursor's line when nothing is selected; on lines fenced already they
--   take the fences away.
--
-- * Templates ('Table', 'HorizontalRule') go after the line the selection
--   ends on.
--
-- A block is kept apart from the text around it by a blank line, without
-- which it would not be one: a @---@ under a paragraph makes the paragraph a
-- heading, and text under a @<details>@ block would end up inside it.
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
  , apply
  )
where

import Data.List (findIndex, span, zip3)
import Data.Text qualified as T
import Protolude hiding (link, list, replace)

-- | What is selected, from 'start' to 'end', in characters from the start of
-- the text. Nothing is selected when the two are equal: then it is where the
-- cursor is.
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
  | -- | An image by its address. (An attachment is uploaded instead, and its
    -- reference put in by the editor.)
    Image
  | -- | A table of three columns.
    Table
  | HorizontalRule
  | Html HtmlTag
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

-- | What the toolbar's menu calls it.
htmlTagLabel :: HtmlTag -> Text
htmlTagLabel = \case
  Mark -> "Highlight"
  Kbd -> "Keyboard key"
  Sup -> "Superscript"
  Sub -> "Subscript"
  Underline -> "Underline"
  Small -> "Small print"
  Details -> "Collapsible section"

-- | Apply a command to the text with this selection: the text it makes, and
-- what is selected in it afterwards.
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
-- replaced by a text. A command is a list of them, in order and apart.
data Replacement = Replacement Int Int Text

replace :: [Replacement] -> Text -> Text
replace reps text = go 0 reps
  where
    go at = \case
      [] -> T.drop at text
      Replacement pos len new : rest -> slice at pos <> new <> go (pos + len) rest
    slice a b = T.take (b - a) (T.drop a text)

-- | Which side of text put in at an offset the offset ends up on.
data Bias = Before | After

-- | Where an offset in the text ends up after the replacements: moved by
-- what was put in or taken out before it; inside a part that was replaced,
-- as far into the new text as it was into the old.
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
-- text, and the plain ones that are recognised and taken away.
data Markers = Markers {forText :: Text -> (Text, Text), plain :: (Text, Text)}

-- | The same marker on both sides.
wrapIn :: Text -> Markers
wrapIn marker = Markers (const (marker, marker)) (marker, marker)

wrapIn' :: Text -> Text -> Markers
wrapIn' open close = Markers (const (open, close)) (open, close)

-- | Backticks around code: more of them than the code has in a row, and,
-- where the code starts or ends with one, a space inside them on both sides
-- (CommonMark takes one space away only when there is one at each end).
-- Single backticks are the ones taken away.
codeSpan :: Markers
codeSpan = Markers forCode ("`", "`")
  where
    forCode code =
      let longest = foldr (max . T.length) 0 (filter ("`" `T.isPrefixOf`) (T.group code))
          fence = T.replicate (longest + 1) "`"
          pad = if T.isPrefixOf "`" code || T.isSuffixOf "`" code then " " else ""
       in (fence <> pad, pad <> fence)

-- | Wrap the selection's paragraphs in the markers, or unwrap them; with
-- nothing selected, put in the placeholder wrapped and select it.
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

-- | The parts of the selection to wrap one by one: its runs of lines with
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

-- | The lines a line command changes: those of the selection with something
-- on them, or all of them when none has.
targets :: [Line] -> [Line]
targets ls = case filter (not . T.all isSpace . (\l -> l.line)) ls of
  [] -> ls
  nonBlank -> nonBlank

-- | The selection after line replacements: the same text selected, the
-- cursor after a prefix put in where it was.
afterLines :: Selection -> [Replacement] -> Selection
afterLines (Selection s e) reps
  | s == e = cursor (moved After reps s)
  | otherwise = Selection (moved Before reps s) (moved After reps e)

data ListKind = Bullet | Numbered | Task
  deriving stock (Eq)

-- | A line's indentation, and the list item marker after it, if any: its
-- kind and length.
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

-- | Make every line touched an item of a list of this kind, or, when each is
-- already, plain lines.
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

-- | Quote every line touched, or, when each is already, none.
quote :: Text -> Selection -> (Text, Selection)
quote text sel = (replace reps text, afterLines sel reps)
  where
    ls = touched text sel
    quoted l = T.isPrefixOf ">" l.line
    reps
      | all quoted ls = [Replacement l.at (if T.isPrefixOf "> " l.line then 2 else 1) "" | l <- ls]
      | otherwise = [Replacement l.at 0 (if T.all isSpace l.line then ">" else "> ") | l <- ls, not (quoted l)]

-- | The next heading level for every line touched, after the first one's:
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

-- | What goes before and after a block put in between these two texts so
-- that it is a block of its own: a blank line on each side, unless the text
-- has one there already or ends there.
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

-- | A block put in after the line the selection ends on; what is selected in
-- it afterwards, if anything (an offset into the block and a length), or the
-- cursor after it.
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
-- afterwards (or else the cursor goes at the end of the opening line, where
-- a code block's language is written).
data Fence = Fence {open :: Text, close :: Text, placeholder :: Text, selectInside :: Bool}

-- | Fence the lines the selection touches, or unfence lines fenced already
-- (the selection's first and last, or those just around it); with nothing
-- selected, put in an empty block after the cursor's line.
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
    -- A fence line opens a block or closes one depending on how many came
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
    -- Take away the opening line and the closing one, selecting what was
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

-- | A collapsible section: @<details>@ around the lines touched, with a
-- @<summary>@ to name it, which is selected. An HTML block ends at a blank
-- line, so the lines are put in without the blank ones among them. Lines
-- that are such a section already are unwrapped.
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

-- | A link (or, with @!@ before it, an image): around the selection, which
-- becomes its text, with the address selected to be typed; around an
-- address selected, with a placeholder for the text selected; or, with
-- nothing selected, a placeholder for both, the text selected. A selection
-- that is a link's text already is unwrapped.
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
    -- How much follows the selection to the end of the link, if it is a
    -- link's text: @](@, the address, @)@.
    linkAround
      | T.isSuffixOf opening (T.take s text) && (bang /= "" || not (T.isSuffixOf "![" (T.take s text))) =
          let rest = T.drop e text
           in case T.stripPrefix "](" rest of
                Just target | (addr, closing) <- T.break (\c -> c == ')' || c == '\n') target, T.isPrefixOf ")" closing -> Just (2 + T.length addr + 1)
                _ -> Nothing
      | otherwise = Nothing
