-- | Problems: the places in a page's Markdown that do not render as the
-- author meant, for the editor to mark in the text (WP5.65 of
-- docs/PLAN.md).
--
-- A 'Problem' is a range of source lines, a kind and a message. They come
-- from two sources.
--
-- * The parser's own, found here at once from the tree
--   ("Wiki.Core.Markdown.Ast"): a marker line the page shows in red (a
--   spoiler's or another block's, a block of the wiki's own not closed, a
--   pause where none is read), a spoiler that is not closed or that cuts
--   a section, and a
--   quotation that starts like a box's marker but is not one (@> [!]@,
--   @> [!Two words]@, @> [!TIP]Title@).
-- * The islands', found later by the libraries that draw them in the
--   browser: a formula KaTeX cannot parse, a diagram Mermaid cannot
--   parse, a picture TeX cannot draw. The browser says which island
--   failed by its 'IslandKey'. 'islands' gives each key's source lines, so
--   that the editor can turn the island's message into a 'Problem'
--   ('islandProblem').
--
-- The keys are found by rendering the page with "Wiki.Core.Markdown.Render"
-- itself, with island callbacks that only record the key. So they are the
-- keys the preview's islands have, however the renderer counts them
-- (formulas in a box's title, in a spoiler's description, a block of
-- macro definitions that shows nothing). The parser gives the line each
-- block of the page starts on, not the lines of the blocks inside it. An
-- island's lines are therefore those of the block of the page it is in,
-- narrowed to the lines where its source is written in that block when
-- they can be found.
--
-- This module reads the tree and never changes how a page is parsed or
-- rendered.
module Wiki.Core.Markdown.Problems
  ( Problem (..)
  , ProblemKind (..)
  , Severity (..)
  , kindName
  , IslandPlace (..)
  , Checked (..)
  , checkText
  , parserProblems
  , kindProblems
  , islandPlaces
  , islandProblem
  , allProblems
  )
where

import Data.List (span, zip3)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Core (HTML (..))
import Halogen.VDom.Types qualified as VDom
import Protolude
import Wiki.Core.Markdown.Ast qualified as A
import Wiki.Core.Markdown.Box (readAlertKind)
import Wiki.Core.Markdown.Folds (Fold, foldsParsed, isSpoiler)
import Wiki.Core.Markdown.Render (IslandKey (..), Options (..), defaultOptions, renderSections)
import Wiki.Core.PageKind (PageKind (..))
import Wiki.Core.Slides qualified as Slides

-- | 'Problem' is a place in a page's source that does not render as
-- written: its first and last line (from 1, the last one included), what
-- kind of thing is wrong, and what the library or the parser said.
data Problem = Problem
  { from :: Int
  , to :: Int
  , kind :: ProblemKind
  , severity :: Severity
  , message :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | 'Severity' is how much a 'Problem' matters, which the editor shows by
-- its colour.
data Severity
  = -- | What is written does not render as meant: a marker shown in red,
    -- a formula that cannot be typeset. Red.
    Error
  | -- | What is written renders, but not as its kind of page reads it: a
    -- marker of presentations in a document, which shows nothing or a
    -- plain box there, or a heading that opens no slide. Yellow.
    Warning
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | What a 'Problem' is in.
data ProblemKind
  = -- | A formula, typeset by KaTeX.
    Formula
  | -- | A Mermaid diagram.
    Diagram
  | -- | A TikZ picture, drawn by TeX.
    Picture
  | -- | A block spoiler's marker, or the spoiler it starts.
    Spoiler
  | -- | The marker of another of the wiki's own blocks
    -- (@[[!notes]]@, @[[!pause]]@ and the others), or the block it
    -- starts.
    Marker
  | -- | A box's marker, @> [!KIND]@.
    Box
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The kind's name as the editor shows it beside a problem's message.
kindName :: ProblemKind -> Text
kindName = \case
  Formula -> "formula"
  Diagram -> "diagram"
  Picture -> "picture"
  Spoiler -> "spoiler"
  Marker -> "block"
  Box -> "box"

-- | 'IslandPlace' is where an island that can fail is written in the
-- source: its first and last line, and its kind. Listings are not among
-- them: a language the highlighter does not know is shown as plain text,
-- which is no error.
data IslandPlace = IslandPlace
  { from :: Int
  , to :: Int
  , kind :: ProblemKind
  }
  deriving stock (Eq, Show)

-- | 'Checked' is what 'checkText' found in one text: the parser's
-- problems, the place of each island that can fail, by its key, and the
-- spoilers the editor offers to fold ("Wiki.Core.Markdown.Folds"), found
-- from the same parse.
data Checked = Checked
  { problems :: [Problem]
  , islands :: Map IslandKey IslandPlace
  , folds :: [Fold]
  }
  deriving stock (Eq, Show)

-- | Forcing a 'Checked' forces every problem and every place, so that the
-- editor can check a text on a worker thread and not on the component's
-- loop.
instance NFData Checked where
  rnf c =
    rnf [(p.from, p.to, p.kind, p.severity, p.message) | p <- c.problems]
      `seq` rnf [(k.source, k.occurrence, p.from, p.to, p.kind) | (k, p) <- Map.toList c.islands]
      `seq` rnf c.folds

instance NFData ProblemKind where
  rnf k = k `seq` ()

instance NFData Severity where
  rnf k = k `seq` ()

-- | The problems in a page's text, the parser's ('parserProblems') and
-- those of its kind ('kindProblems'), the places of its islands, and its
-- spoilers' folds, from one parse of the text.
checkText :: PageKind -> Text -> Checked
checkText pageKind source =
  Checked
    { problems = sort (problemsParsed parsed <> kindProblemsParsed pageKind (deck, markers))
    , islands = islandsIn source located
    , folds = filter isSpoiler (foldsParsed source parsed)
    }
  where
    (located, markers, deck) = either (const ([], [], [])) identity (A.parseWithLinesMarkersAndDeck source)
    parsed = (located, markers)

-- | The problems the parser finds in a text, in the order of their lines:
-- the broken marker lines of spoilers and of the other blocks of the
-- wiki's own, the spoilers not closed or cutting a section, and the
-- quotations that start like a box's marker but are not boxes. None when the text cannot be parsed, which CommonMark never
-- refuses. A heading spoiler (@## [[!spoiler]] Question@) has no end marker
-- and is never wrong: the parser gives it no problem. A marker pair that
-- crosses the end of its section cuts a section, and is marked as any
-- other pair that does.
parserProblems :: Text -> [Problem]
parserProblems source = problemsParsed (either (const ([], [])) identity (A.parseWithLinesAndMarkers source))

-- | 'parserProblems' of a text parsed already.
problemsParsed :: ([(Maybe Int, A.Block)], [A.MarkerLine]) -> [Problem]
problemsParsed (located, markers) = sort (markerLines <> spoilerHeads <> boxes <> misplacedPauses)
  where
    tree = map snd located
    markerLines =
      [ Problem {from = line, to = line, kind = if spoilerLine written then Spoiler else Marker, severity = Error, message = sentence why}
      | A.MarkerLine line _ (A.Faulty written why) <- markers
      ]
    spoilerLine written = case A.markerAt written of
      Just (A.Opening A.SpoilerName) -> True
      Just (A.Closing A.SpoilerName) -> True
      _ -> False
    spoilerHeads =
      [ Problem {from = h.line, to = h.line, kind = Spoiler, severity = Error, message = A.spoilerProblemText h problem}
      | A.Spoiler h _ <- concatMap everyBlock tree
      , Just problem <- [h.problem]
      ]
    misplacedPauses =
      [ Problem {from = line, to = line, kind = Marker, severity = Error, message = sentence why}
      | A.MisplacedPause line _ why <- A.allInlines tree
      ]
    -- Only a quotation of the page itself has a line: the parser gives
    -- none to the blocks inside another.
    boxes =
      [ Problem {from = line, to = line, kind = Box, severity = Error, message = why}
      | (Just line, A.BlockQuote (opening : _)) <- located
      , Just why <- [boxMarkerProblem opening]
      ]

-- | The warnings of a page's kind ("Wiki.Core.PageKind") in its text, in
-- the order of their lines. The parser reads every page alike, so what
-- only a presentation reads is not an error in a document: it is shown
-- there as a document shows it (a pause and the look as nothing, the
-- speaker's notes and an incremental list as a box), and the editor
-- warns that it does nothing more there.
--
-- * In a document, or a page of a kind this program does not know: each
--   @[[!pause]]@, @[[!style]]@, @[[!notes]]@ and @[[!incremental]]@, and
--   each list with the class @incremental@.
-- * In a presentation: a heading of level one or two that is not at the
--   page's top level, which is a heading on its slide and opens none (its
--   line is that of the block of the top level it is in, since the parser
--   gives no line to the blocks inside another); a @[[!style]]@ not at
--   the top level, which is not read; and each @[[!style]]@ after the
--   first, which is not read either.
kindProblems :: PageKind -> Text -> [Problem]
kindProblems pageKind source = kindProblemsParsed pageKind (either (const ([], [])) (\(_, ms, deck) -> (deck, ms)) (A.parseWithLinesMarkersAndDeck source))

-- | 'kindProblems' of a text parsed already: the page's blocks as a
-- presentation reads them, each with the line it starts on
-- ('A.parseDeckSpans'), and its marker lines. What is at the top level
-- is decided where the slides decide it ('Slides.deckLevel'): the
-- warnings about a presentation and its slides never disagree.
kindProblemsParsed :: PageKind -> ([(Maybe Int, A.Block)], [A.MarkerLine]) -> [Problem]
kindProblemsParsed pageKind (deck, markers) = case pageKind of
  Presentation -> sort (nestedOpeners <> laterStyles)
  _ -> sort documentMarkers
  where
    warn line message = Problem {from = line, to = line, kind = Marker, severity = Warning, message}
    documentMarkers =
      [ warn line message
      | A.MarkerLine line _ role <- markers
      , Just message <- [presentationOnly role]
      ]
        <> [warn line (fromMaybe "" (presentationOnly A.Pauses)) | A.InlinePause line _ <- A.allInlines tree]
    tree = map snd deck
    located = Slides.deckLevel deck
    presentationOnly = \case
      A.Pauses -> Just "[[!pause]] makes steps of a slide in a presentation; a document shows nothing for it"
      A.SetsStyle -> Just "[[!style]] sets a presentation's look; a document shows nothing for it"
      A.Opens attrs
        | "notes" `elem` A.classes attrs -> Just "[[!notes]] holds a presentation's speaker notes; a document shows them as a box"
        | "incremental" `elem` A.classes attrs -> Just "An incremental list shows its items one at a time in a presentation; a document shows an ordinary box"
      A.TakesAttributes attrs
        | "incremental" `elem` A.classes attrs -> Just "An incremental list shows its items one at a time in a presentation; a document shows an ordinary list"
      _ -> Nothing
    -- The lines of the look's markers at the top level, in order, and
    -- every look's marker line.
    topStyles = [line | (Just line, b) <- located, Slides.isLook b]
    styleLines = [line | A.MarkerLine line _ A.SetsStyle <- markers]
    laterStyles =
      [warn line "Only the first [[!style]] at the top level sets the presentation's look: this one is not read" | line <- drop 1 topStyles]
        <> [warn line "[[!style]] is read only at the top level of the page, not inside another block" | line <- styleLines, line `notElem` topStyles]
    nestedOpeners =
      [ warn line "A heading of level one or two opens a slide only at the top level of the page: one inside this block is a heading on its slide"
      | (Just line, b) <- located
      , not (Slides.isOpener b)
      , or [level <= 2 | A.Heading level _ _ <- drop 1 (everyBlock b)]
      ]

-- | A block, and every block inside it, in the order of the source.
everyBlock :: A.Block -> [A.Block]
everyBlock b = b : concatMap everyBlock (inside b)
  where
    inside = \case
      A.BlockQuote bs -> bs
      A.List _ items -> concat [bs | A.ListItem _ bs <- items]
      A.Div _ bs -> bs
      A.Alert _ _ bs -> bs
      A.Spoiler _ bs -> bs
      A.Footnotes notes -> concat [bs | A.Footnote _ _ bs <- notes]
      _ -> []

-- | Why a quotation's first block, which starts with @[!@ and a @]@ later,
-- is not a box's marker, when it starts so: the parser leaves such a
-- quotation a quotation, and the page shows the marker as text.
boxMarkerProblem :: A.Block -> Maybe Text
boxMarkerProblem = \case
  A.Para (A.Str t : _) -> marker t
  A.Plain (A.Str t : _) -> marker t
  _ -> Nothing
  where
    marker t = do
      rest <- T.stripPrefix "[!" t
      let (written, close) = T.breakOn "]" (T.takeWhile (/= '\n') rest)
          name = fromMaybe written (T.stripSuffix "*" written)
          after = T.drop 1 close
      guard (not (T.null close))
      case readAlertKind name of
        _ | T.null name -> Just "A box's marker needs a kind, as in [!NOTE]: this quotation is not a box"
        Nothing -> Just ("“" <> name <> "” is not a kind of box: a kind is one word of letters and dashes, starting with a letter. This quotation is not a box")
        Just _
          | Just (c, _) <- T.uncons after
          , not (isSpace c) ->
              Just "A box's title is set off from its marker by a space, as in [!NOTE] Title: this quotation is not a box"
          | otherwise -> Nothing

-- | Where each island that can fail is written in a text, by its key: a
-- formula, a diagram or a picture. The keys are the renderer's own
-- (see the module's header).
islandPlaces :: Text -> Map IslandKey IslandPlace
islandPlaces source = either (const Map.empty) (islandsIn source) (A.parseWithLines source)

-- | 'islandPlaces' of a text whose blocks are parsed already, each with
-- the line it starts on.
islandsIn :: Text -> [(Maybe Int, A.Block)] -> Map IslandKey IslandPlace
islandsIn source located =
  let blocks = zip3 located (extents located) (map (concatMap widgets) (renderSections probe (map (pure . snd) located)))
      -- A paragraph split around its display math is several blocks
      -- in a row on the same lines, and its formulas are counted across
      -- them, in order: each block's islands come after the sources of
      -- the islands of the blocks before it on those lines.
      sameLines = groupBy (\(_, l, _) (_, l', _) -> l == l') blocks
      before earlier = [written | (_, _, found) <- earlier, Probe _ _ written <- found]
   in Map.fromList (concat [placed (before earlier) block | run <- sameLines, (earlier, block) <- zip (inits run) run])
  where
    sourceLines = T.lines source
    lineCount = max 1 (length sourceLines)
    lineAt n = fromMaybe "" (head (drop (n - 1) sourceLines))
    blank n = T.all isSpace (lineAt n)

    -- Each block's first and last line: from the line it starts on to the
    -- line before the next block that starts after it, without the blank
    -- lines at its end. A block without a line (the footnotes, which come
    -- last) may be anywhere.
    extents :: [(Maybe Int, A.Block)] -> [(Int, Int)]
    extents starts =
      [ case start of
          Just s ->
            let next = fromMaybe (lineCount + 1) (head [l | (Just l, _) <- later, l > s])
             in (s, max s (lastNonBlank s (next - 1)))
          Nothing -> (1, lineCount)
      | ((start, _), later) <- zip starts (drop 1 (tails starts))
      ]
    lastNonBlank s e
      | e > s && blank e = lastNonBlank s (e - 1)
      | otherwise = min e lineCount

    placed :: [Text] -> ((Maybe Int, A.Block), (Int, Int), [Probe]) -> [(IslandKey, IslandPlace)]
    placed before ((_, b), (s, e), found) =
      let whole = isIsland s b && length found == 1
       in [ (key, IslandPlace {from = lo, to = hi, kind})
          | (n, Probe key kind written) <- zip [0 :: Int ..] found
          , let earlier = length [() | w <- before <> [w | Probe _ _ w <- take n found], w == written]
                (lo, hi)
                  | whole = (s, e)
                  | otherwise = fromMaybe (s, e) (locate kind written earlier (s, e))
          ]

    -- Whether a block of the page is the island itself, written as a
    -- fence: its lines are the island's, the fence's lines included.
    -- Display math in a paragraph is a block of its own too, which starts
    -- where the paragraph does; its lines are found like a formula's.
    isIsland s = \case
      A.Mermaid _ -> True
      A.Tikz _ -> True
      A.MathBlock _ -> any (`T.isPrefixOf` T.stripStart (lineAt s)) ["```", "~~~"]
      _ -> False

    -- The lines an island's source is written on within a block's lines,
    -- for the n-th island (from 0) of that source in the block.
    --
    -- A formula is looked for whole: an opening delimiter, the source
    -- exactly as the parser gives it (what lies between the delimiters,
    -- line breaks included), and the closing delimiter, in the block's
    -- lines joined by line breaks. So a formula @\\frac{1}@ is not found
    -- in @$\\frac{1}{2}$@, nor @x@ in the word "example". The matches of
    -- every delimiter are taken in the order of the source, one for each
    -- formula written, and the n-th is the n-th island's.
    --
    -- A source found otherwise (a diagram, a picture, or a formula the
    -- whole search misses, such as a math fence in a list or a formula
    -- over the lines of a quotation, whose markers are not in its source)
    -- is placed at the line of the n-th occurrence of its first line.
    locate :: ProblemKind -> Text -> Int -> (Int, Int) -> Maybe (Int, Int)
    locate kind written n (s, e) = whole <|> byFirstLine
      where
        -- The block's lines, a formula's code spans blanked out: the
        -- source of a formula written in code is no formula.
        block = (if kind == Formula then blankCodeSpans else identity) (T.intercalate "\n" [lineAt j | j <- [s .. e]])
        blockLines = T.splitOn "\n" block
        -- The line of an offset into the block.
        lineOf offset = s + T.count "\n" (T.take offset block)

        whole = do
          guard (kind == Formula)
          (offset, size) <- head (drop n (formulasWritten written))
          pure (lineOf offset, lineOf (offset + size - 1))

        -- Where the source is written as a formula in the block: each
        -- match's offset and length, in the order of the block, without
        -- overlaps, the longer delimiter first (@$$x$$@ holds @$x$@). A
        -- dollar after a backslash is an escape, not a delimiter.
        formulasWritten tex =
          let matches =
                [ (offset, T.length needle)
                | (open, close) <- [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
                , let needle = open <> tex <> close
                , (before, _) <- T.breakOnAll needle block
                , let offset = T.length before
                , not ("$" `T.isPrefixOf` open && "\\" `T.isSuffixOf` before)
                ]
              apart = \case
                (o, l) : rest -> (o, l) : apart (dropWhile (\(o', _) -> o' < o + l) rest)
                [] -> []
           in apart (sortOn (\(o, l) -> (o, Down l)) matches)

        byFirstLine = do
          let (_, rest) = span (T.all isSpace) (T.lines written)
          firstLine <- head rest
          let stripped = T.strip firstLine
              holding = [j | (j, l) <- zip [s .. e] blockLines, _ <- T.breakOnAll stripped l]
          at <- head (drop n holding)
          pure (at, min e (at + length rest - 1))

-- | A text with each code span made spaces, its line breaks kept, so that
-- every offset into the text, and every line, stays where it was. A code
-- span is read as CommonMark reads one: a run of backticks opens it, the
-- next run of exactly as many closes it, and a run with no such closer is
-- text. Inside a span a backslash escapes nothing. A run of three or more
-- at the start of a line, after white space or a list's or quotation's
-- marker, is a fence of a block in the text (a list item's fence), and is
-- left as it is with what it holds: a math fence's source is found there.
blankCodeSpans :: Text -> Text
blankCodeSpans = T.pack . go True . T.unpack
  where
    go :: Bool -> [Char] -> [Char]
    go lineStart = \case
      [] -> []
      text@('`' : _) ->
        let (run, after) = span (== '`') text
            size = length run
         in if lineStart && size >= 3
              then run <> go False after
              else case closing size [] after of
                Just (inside, rest) -> map blank (run <> inside <> run) <> go False rest
                Nothing -> run <> go False after
      c : rest -> c : go (c == '\n' || (lineStart && (isSpace c || isDigit c || c `elem` (">-*+.)" :: [Char])))) rest
    -- What lies before the next run of exactly @size@ backticks, and what
    -- comes after that run.
    closing size seen text = case break (== '`') text of
      (_, []) -> Nothing
      (before, rest) ->
        let (run, after) = span (== '`') rest
         in if length run == size then Just (seen <> before, after) else closing size (seen <> before <> run) after
    blank c = if c == '\n' then '\n' else ' '

-- | What the probe's islands are: the key, the kind and the source.
data Probe = Probe IslandKey ProblemKind Text

-- | The renderer's options with islands that record their keys and draw
-- nothing. Listings record nothing: they cannot fail.
probe :: Options Text Probe Void
probe =
  defaultOptions
    { codeBlock = \_ _ _ _ _ -> HH.text ""
    , mathInline = \k _ tex -> island k Formula tex
    , mathDisplay = \k _ tex -> island k Formula tex
    , mermaid = \k src -> island k Diagram src
    , tikz = \k src -> island k Picture src
    , -- An html fence's frame cannot fail: HTML the allowlist drops
      -- raises no problem, as in raw HTML.
      htmlBlock = \_ _ _ _ -> HH.text ""
    }
  where
    island k kind written = HTML (VDom.Widget (Probe k kind written))

-- | The probe's islands in some HTML, in order.
widgets :: HH.HTML Probe Void -> [Probe]
widgets (HTML v) = go v
  where
    go = \case
      VDom.Text _ -> []
      VDom.Elem _ _ _ children -> concatMap go children
      VDom.Keyed _ _ _ children -> concatMap (go . snd) children
      VDom.Widget w -> [w]
      VDom.Grafted g -> go (VDom.runGraft g)

-- | An island's problem, at its place, with the library's message.
islandProblem :: IslandPlace -> Text -> Problem
islandProblem place message = Problem {from = place.from, to = place.to, kind = place.kind, severity = Error, message}

-- | Every problem of a checked text: the parser's, and those of the
-- islands that failed, by key with their messages, that are still in the
-- text (an island whose source changed has another key, and its problem
-- is gone), in the order of their lines.
allProblems :: Checked -> Map IslandKey Text -> [Problem]
allProblems c failed =
  sort (c.problems <> [islandProblem place message | (key, message) <- Map.toList failed, Just place <- [Map.lookup key c.islands]])

-- | A reason as a sentence: its first letter in upper case.
sentence :: Text -> Text
sentence t = case T.uncons t of
  Just (c, rest) -> T.cons (toUpper c) rest
  Nothing -> t
