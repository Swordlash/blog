-- | Problems: the places in a page's Markdown that do not render as the
-- author meant, for the editor to mark in the text (WP5.65 of
-- docs/PLAN.md).
--
-- A 'Problem' is a range of source lines, a kind and a message. They come
-- from two sources.
--
-- * The parser's own, found here at once from the tree
--   ("Wiki.Core.Markdown.Ast"): a spoiler's marker line the page shows in
--   red, a spoiler that is not closed or that cuts a section, and a
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
  , kindName
  , IslandPlace (..)
  , Checked (..)
  , checkText
  , parserProblems
  , islandPlaces
  , islandProblem
  , allProblems
  )
where

import Data.List (span, zipWith3)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Core (HTML (..))
import Halogen.VDom.Types qualified as VDom
import Protolude
import Wiki.Core.Markdown.Ast qualified as A
import Wiki.Core.Markdown.Box (readAlertKind)
import Wiki.Core.Markdown.Render (IslandKey (..), Options (..), defaultOptions, renderSections)

-- | 'Problem' is a place in a page's source that does not render as
-- written: its first and last line (from 1, the last one included), what
-- kind of thing is wrong, and what the library or the parser said.
data Problem = Problem
  { from :: Int
  , to :: Int
  , kind :: ProblemKind
  , message :: Text
  }
  deriving stock (Eq, Ord, Show)

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

-- | 'Checked' is what 'check' found in one text: the parser's problems,
-- and the place of each island that can fail, by its key.
data Checked = Checked
  { problems :: [Problem]
  , islands :: Map IslandKey IslandPlace
  }
  deriving stock (Eq, Show)

-- | Forcing a 'Checked' forces every problem and every place, so that the
-- editor can check a text on a worker thread and not on the component's
-- loop.
instance NFData Checked where
  rnf c =
    rnf [(p.from, p.to, p.kind, p.message) | p <- c.problems] `seq`
      rnf [(k.source, k.occurrence, p.from, p.to, p.kind) | (k, p) <- Map.toList c.islands]

instance NFData ProblemKind where
  rnf k = k `seq` ()

-- | The parser's problems in a text, and the places of its islands.
checkText :: Text -> Checked
checkText source = Checked {problems = parserProblems source, islands = islandPlaces source}

-- | The problems the parser finds in a text, in the order of their lines:
-- the spoilers' broken marker lines, the spoilers not closed or cutting a
-- section, and the quotations that start like a box's marker but are not
-- boxes. None when the text cannot be parsed, which CommonMark never
-- refuses. A heading spoiler (@## [[spoiler]] Question@) has no end marker
-- and is never wrong: the parser gives it no problem. A marker pair that
-- crosses the end of its section cuts a section, and is marked as any
-- other pair that does.
parserProblems :: Text -> [Problem]
parserProblems source = sort (spoilerLines <> spoilerHeads <> boxes)
  where
    (tree, markers) = case A.parseWithAllMarkers source of
      Right (bs, _, ms, _) -> (bs, ms)
      Left _ -> ([], [])
    spoilerLines =
      [ Problem {from = line, to = line, kind = Spoiler, message = sentence why}
      | A.SpoilerMarker line _ (A.Faulty _ why) <- markers
      ]
    spoilerHeads =
      [ Problem {from = h.line, to = h.line, kind = Spoiler, message = A.spoilerProblemText h problem}
      | A.Spoiler h _ <- concatMap everyBlock tree
      , Just problem <- [h.problem]
      ]
    -- Only a quotation of the page itself has a line: the parser gives
    -- none to the blocks inside another.
    boxes =
      [ Problem {from = line, to = line, kind = Box, message = why}
      | (Just line, A.BlockQuote (opening : _)) <- either (const []) identity (A.parseWithLines source)
      , Just why <- [boxMarkerProblem opening]
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
islandPlaces source = case A.parseWithLines source of
  Left _ -> Map.empty
  Right located -> Map.fromList (concat (zipWith3 placed located (extents located) (renderSections probe (map (pure . snd) located))))
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
    extents located =
      [ case start of
          Just s ->
            let next = fromMaybe (lineCount + 1) (head [l | (Just l, _) <- later, l > s])
             in (s, max s (lastNonBlank s (next - 1)))
          Nothing -> (1, lineCount)
      | ((start, _), later) <- zip located (drop 1 (tails located))
      ]
    lastNonBlank s e
      | e > s && blank e = lastNonBlank s (e - 1)
      | otherwise = min e lineCount

    placed :: (Maybe Int, A.Block) -> (Int, Int) -> [HH.HTML Probe Void] -> [(IslandKey, IslandPlace)]
    placed (_, b) (s, e) html =
      let found = concatMap widgets html
          whole = isIsland s b && length found == 1
       in [ (key, IslandPlace {from = lo, to = hi, kind})
          | (n, Probe key kind written) <- zip [0 :: Int ..] found
          , let earlier = length [() | Probe _ _ w <- take n found, w == written]
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

    -- The lines an island's source is written on within a block's lines:
    -- the n-th line (from 0) that holds its first line, for the n-th
    -- island of that source in the block. A formula is looked for after
    -- its opening delimiter first, so that a formula @x@ is not found in
    -- the word "example".
    locate :: ProblemKind -> Text -> Int -> (Int, Int) -> Maybe (Int, Int)
    locate kind written n (s, e) = do
      let pieces = T.lines written
          (leading, rest) = span (T.all isSpace) pieces
      firstLine <- head rest
      let stripped = T.strip firstLine
          delimited = if kind == Formula && null leading then [d <> firstLine | d <- ["$", "\\(", "\\["]] else []
          holding needle = [j | j <- [s .. e], needle `T.isInfixOf` lineAt j]
          candidates = filter (not . null) (map holding (delimited <> [stripped]))
      at <- head =<< head [drop n js | js <- candidates, length js > n]
      pure (at, min e (at + length rest - 1))

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
islandProblem place message = Problem {from = place.from, to = place.to, kind = place.kind, message}

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
