-- | A presentation as a slide deck: its Markdown, read as slides.
--
-- A page is presented when it is a presentation ("Wiki.Core.PageKind"),
-- whatever its text says; the text says how the deck is cut. Its parsed
-- blocks ("Wiki.Core.Markdown.Ast") are split into slides at each heading
-- of level one or two at the top level of the page, its openers, as
-- pandoc's slide writers split at slide level 2: a @##@ heading opens a
-- slide and is its title, and a @#@ heading opens a title slide, which a
-- theme lays out as Beamer lays out a title page or a section page. A
-- heading of level three or more is a heading on its slide, and so is a
-- heading of any level inside a list, a quotation or a box. A thematic
-- break (@---@) is a horizontal rule on its slide. What comes before the
-- first opener is a slide without a title, unless it shows nothing (a
-- page's text starts with its title line, @# Title@, so there is usually
-- nothing before it). On each slide:
--
-- * the opener is its title, removed from its body;
-- * a box with the class @notes@ (@[[!notes]]@ … @[[/notes]]@) holds the
--   speaker's notes, removed from the body and shown to the speaker only;
-- * the footnotes the slide refers to are placed at its end, rather than
--   all at the end of the last slide;
-- * the slide is shown in steps ('steps'), as pandoc's slide writers show
--   it. A pause, @[[!pause]]@ on a line of its own ('Pause') or among the
--   words of a paragraph ('InlinePause'), starts the next step: the
--   content after it is shown from that step on. A box
--   with the class @incremental@ (@[[!incremental]]@ … @[[/incremental]]@)
--   shows the items of the lists
--   in it one at a time: the first item with what comes before the list,
--   each further item in a step of its own. A slide without either is one
--   step.
--
-- A heading spoiler at the page's top level (@## [[!spoiler]] Question@)
-- is its heading and its section as written, in a deck: a section is a
-- slide, and a slide cannot hide itself. So the heading of a heading
-- spoiler of level one or two opens a slide as any such heading does,
-- and the openers inside a level-one heading spoiler's section open
-- theirs.
--
-- The deck's look is set once, at the top level of the page, by the line
-- @[[!style]]{theme=dark aspect=4:3}@ (themes: @beamer@, the default,
-- @light@ and @dark@; aspects: @16:9@, the default, and @4:3@), an empty
-- box of the class 'styleClass'. It shows nothing, on the page or on a
-- slide. The first one counts; the editor warns of any other
-- ("Wiki.Core.Markdown.Problems").
--
-- Steps are counted as Beamer counts them, so that a Beamer PDF has one
-- page for each step the browser shows. Each block is shown from the step
-- of the last pause before it. The items of an incremental list take the
-- next steps in document order, nested lists' items included, and content
-- after the list without a pause is shown with the list's first item, as
-- in Beamer. A pause after such items starts the step after the last
-- item. A pause is read only where the Markdown reader reads one ('Pause'):
-- on the slide, in a box, an alert, a spoiler, a quotation and a list
-- item. A footnote, a table or code is shown whole, at the step of the
-- block it is.
--
-- A step changes nothing on a slide but what is visible: the slide's body
-- holds all of its content, and each piece shown from a later step than
-- the content around it is marked with its step ('stepMark', 'itemMark').
-- 'showingStep' turns the marks into the classes the stylesheet hides
-- with @visibility: hidden@, so content shown already does not move when
-- the next step appears.
--
-- Slides are rendered with the page's renderer, as one document split into
-- sections ('Wiki.Core.Markdown.Render.renderSections'). So a slide shows
-- everything a page does, and a formula on the fifth slide uses the macros
-- the first slide defined.
module Wiki.Core.Slides
  ( -- * Decks
    Deck (..)
  , Slide (..)
  , SlideTitle (..)
  , deckOf
  , titleBlock
  , styleClass

    -- * The page's top level, as a presentation reads it
  , deckLevel
  , isOpener
  , isLook

    -- * Steps
  , atStep
  , showingStep
  , stepMark
  , itemMark

    -- * Options
  , DeckOptions (..)
  , Theme (..)
  , Aspect (..)
  , defaultDeckOptions
  , themeName
  , aspectName

    -- * Rendering
  , RenderedSlide (..)
  , renderDeck
  , renderDeckWithIds

    -- * Slides in the source, for the editor
  , SlideSpan (..)
  , slideSpans
  , slideSpansParsed
  , fixedSlides
  , slideAtLine
  , moveSlide
  , slideChunks
  , parserLineStarts

    -- * Whether a slide's content fits
  , Fit (..)
  , fitOf
  , fitName
  , Measures
  , measuresFor
  , fitsNow
  )
where

import Data.IntSet qualified as IntSet
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Frame (FrameScheme (..))
import Wiki.Core.Markdown.Render (Options (..), renderSectionsWithIds)

-- | 'Deck': a page as slides, with its display options. There is always at
-- least one slide.
data Deck = Deck
  { options :: DeckOptions
  , slides :: [Slide]
  }
  deriving stock (Eq, Show)

-- | 'Slide': its title, if it has a heading, its body, the speaker's
-- notes for it, and the number of steps it is shown in.
data Slide = Slide
  { title :: Maybe SlideTitle
  , body :: [Block]
  -- ^ Everything the slide shows, at its last step. The pieces shown from
  -- a later step are marked ('stepMark', 'itemMark'), and the pauses are
  -- gone.
  , notes :: [Block]
  , steps :: Int
  -- ^ How many steps the slide is shown in: at least 1.
  }
  deriving stock (Eq, Show)

-- | 'SlideTitle': the heading a slide's title comes from, as written: its
-- level, its attributes (including its @id@) and its text.
data SlideTitle = SlideTitle
  { level :: Int
  , attributes :: Attributes
  , text :: [Inline]
  }
  deriving stock (Eq, Show)

-- | 'DeckOptions': how a deck is shown, its theme and its slides' aspect ratio.
data DeckOptions = DeckOptions
  { theme :: Theme
  , aspect :: Aspect
  }
  deriving stock (Eq, Show)

-- | 'Theme': the deck's look, a CSS class in the stylesheet (@slides-theme-…@).
data Theme
  = -- | Beamer's look: a title bar, and a footer with the page's title and
    -- the slide's number. The default.
    Beamer
  | -- | Dark on light, the title as a plain heading, a quiet footer.
    Light
  | -- | Light on dark, otherwise like 'Light'.
    Dark
  deriving stock (Eq, Show, Enum, Bounded)

-- | 'Aspect': a slide's aspect ratio, width to height.
data Aspect
  = -- | 16:9, a screen's ratio. The default.
    Wide
  | -- | 4:3, an older projector's ratio, and Beamer's default.
    Standard
  deriving stock (Eq, Show, Enum, Bounded)

defaultDeckOptions :: DeckOptions
defaultDeckOptions = DeckOptions {theme = Beamer, aspect = Wide}

-- | A theme's name, as written in the @theme@ attribute and at the end of
-- the stylesheet's class.
themeName :: Theme -> Text
themeName = \case
  Beamer -> "beamer"
  Light -> "light"
  Dark -> "dark"

-- | An aspect's name, as written in the @aspect@ attribute.
aspectName :: Aspect -> Text
aspectName = \case
  Wide -> "16:9"
  Standard -> "4:3"

-- | The page's blocks as a deck.
deckOf :: [Block] -> Deck
deckOf page =
  Deck
    { options = maybe defaultDeckOptions optionsOf (head [attrs | b@(Div attrs _) <- doc, isLook b])
    , slides = map cutSteps (withFootnotes notes (nonEmpty' (filter (not . emptySlide) (map slideOf (splitAtOpeners content)))))
    }
  where
    notes = concat [ns | Footnotes ns <- doc]
    content = filter keep doc
    keep = \case
      Footnotes _ -> False
      b -> not (isLook b)
    -- A page with nothing but breaks is still one slide, an empty one.
    nonEmpty' = \case
      [] -> [Slide Nothing [] [] 1]
      ss -> ss
    doc = map snd (deckLevel (map ((),) page))

-- | 'deckLevel' is the page's top level as a presentation reads it: its
-- blocks, with each heading spoiler among them (not those inside a
-- quotation, a box or a list) as its heading and then its section's
-- blocks, as written ('Wiki.Core.Markdown.Ast.OnHeading'), and the
-- heading spoilers in those sections the same. Each block keeps what it
-- carries; a block of a section the parser gathered into its spoiler
-- carries the spoiler's.
--
-- This is the one place the slides' top level is decided: 'deckOf' cuts
-- the slides and reads the look from it, and the editor's warnings of a
-- presentation ("Wiki.Core.Markdown.Problems") and its list of slides
-- read the same blocks, with their own lines, from
-- 'Wiki.Core.Markdown.Ast.parseDeckSpans', whose heading spoilers have
-- no section gathered into them. An opener is a heading of level one or
-- two among these blocks ('isOpener'), and the look is the first
-- @[[!style]]@ among them ('isLook').
deckLevel :: [(a, Block)] -> [(a, Block)]
deckLevel = concatMap $ \(at, b) -> case b of
  Spoiler h bs | h.kind == OnHeading -> deckLevel [(at, x) | x <- bs]
  _ -> [(at, b)]

-- | Whether a block of 'deckLevel' is the line @[[!style]]{…}@, which sets
-- a presentation's look: the first one does.
isLook :: Block -> Bool
isLook = \case
  Div attrs [] -> isOptions attrs
  _ -> False

-- | A slide's title as the heading it was written as, for rendering.
titleBlock :: SlideTitle -> Block
titleBlock t = Heading t.level t.attributes t.text

-- | The blocks before the first opener, then each opener with the blocks
-- up to the next: the slides' blocks ('isOpener').
splitAtOpeners :: [Block] -> [[Block]]
splitAtOpeners bs = case break isOpener bs of
  (before, []) -> [before]
  (before, opener : after) -> before : go opener after
  where
    go opener rest = case break isOpener rest of
      (inside, []) -> [opener : inside]
      (inside, next : after) -> (opener : inside) : go next after

-- | Whether a block of 'deckLevel' opens a slide: a heading of level one
-- or two.
isOpener :: Block -> Bool
isOpener = \case
  Heading level _ _ -> level <= 2
  _ -> False

-- | A slide of its blocks: its opener the title, and none for the blocks
-- before the first opener.
slideOf :: [Block] -> Slide
slideOf bs = Slide {title, body, notes = concat [inner | Div attrs inner <- bs, isNotes attrs], steps = 1}
  where
    shown = filter (not . notesDiv) bs
    (title, body) = case shown of
      Heading level attributes text : rest | level <= 2 -> (Just SlideTitle {level, attributes, text}, rest)
      _ -> (Nothing, shown)
    notesDiv = \case
      Div attrs _ -> isNotes attrs
      _ -> False

emptySlide :: Slide -> Bool
emptySlide s = isNothing s.title && all (== Pause) s.body && null s.notes

isNotes :: Attributes -> Bool
isNotes attrs = "notes" `elem` classes attrs

isOptions :: Attributes -> Bool
isOptions attrs = styleClass `elem` classes attrs

-- | The options the attributes of @[[!style]]@ set. An option the attributes
-- leave out, or set to an unknown value, gets the default.
optionsOf :: Attributes -> DeckOptions
optionsOf attrs =
  DeckOptions
    { theme = fromMaybe defaultDeckOptions.theme (named themeName =<< attribute "theme" attrs)
    , aspect = fromMaybe defaultDeckOptions.aspect (named aspectName . T.replace "/" ":" =<< attribute "aspect" attrs)
    }
  where
    named :: (Enum a, Bounded a) => (a -> Text) -> Text -> Maybe a
    named name value = find (\a -> name a == T.toLower (T.strip value)) [minBound .. maxBound]

-- | Each footnote placed at the end of the first slide that refers to it,
-- and the footnotes no slide refers to at the end of the last slide.
withFootnotes :: [Footnote] -> [Slide] -> [Slide]
withFootnotes [] slides = slides
withFootnotes notes slides = case go IntSet.empty slides of
  (placed, ss) -> case unsnoc ss of
    Just (start, final) | unplaced@(_ : _) <- [n | n@(Footnote k _ _) <- notes, not (IntSet.member k placed)] -> start <> [addNotes unplaced final]
    _ -> ss
  where
    go placed = \case
      [] -> (placed, [])
      s : rest ->
        let refs = footnoteRefs (foldMap (pure . titleBlock) s.title <> s.body <> s.notes)
            here = [n | n@(Footnote k _ _) <- notes, k `elem` refs, not (IntSet.member k placed)]
            placed' = IntSet.union placed (IntSet.fromList [k | Footnote k _ _ <- here])
         in second (addNotes here s :) (go placed' rest)
    addNotes here s@Slide {title, body, notes = speaker, steps} = if null here then s else Slide {title, body = body <> [Footnotes here], notes = speaker, steps}

-- | The numbers of the footnotes some blocks refer to, in order.
footnoteRefs :: [Block] -> [Int]
footnoteRefs = concatMap ofBlock
  where
    ofBlock = \case
      Para xs -> ofInlines xs
      Plain xs -> ofInlines xs
      Heading _ _ xs -> ofInlines xs
      BlockQuote bs -> footnoteRefs bs
      List _ items -> concat [footnoteRefs bs | ListItem _ bs <- items]
      Table _ header rows -> concatMap ofInlines header <> concatMap (concatMap ofInlines) rows
      Div _ bs -> footnoteRefs bs
      Alert _ box bs -> foldMap ofInlines box.title <> footnoteRefs bs
      Spoiler h bs -> ofInlines h.description <> footnoteRefs bs
      _ -> []
    ofInlines = concatMap $ \case
      FootnoteRef n _ -> [n]
      Emph xs -> ofInlines xs
      Strong xs -> ofInlines xs
      Strikeout xs -> ofInlines xs
      Hidden xs -> ofInlines xs
      Link _ _ _ xs -> ofInlines xs
      Image _ _ _ xs -> ofInlines xs
      _ -> []

----------------------------------------------------------------------
-- Steps

-- | 'Counter': where the cutting of a slide into steps is, in document
-- order. It mirrors Beamer's counter of pauses, so that the steps are
-- Beamer's overlays.
data Counter = Counter
  { shown :: Int
  -- ^ The step the content read now is shown from: the step of the last
  -- pause, or of the list item it is in.
  , next :: Int
  -- ^ The step the next item of an incremental list is shown from.
  , highest :: Int
  -- ^ The last step anything is shown from so far.
  }

-- | A slide cut into steps: its pauses taken out, the pieces shown from a
-- later step marked, and its steps counted.
cutSteps :: Slide -> Slide
cutSteps s = case runState (piecesOf False 1 s.body) (Counter 1 1 1) of
  (body, counter) -> s {body, steps = counter.highest}

-- | Some blocks, shown from the step @shownFrom@ on (their box's or their list
-- item's), as pieces: each run of blocks shown from a later step is
-- wrapped in a 'stepMark'. The flag says whether the lists are
-- incremental here.
piecesOf :: Bool -> Int -> [Block] -> State Counter [Block]
piecesOf incremental shownFrom bs = do
  read' <- for bs $ \case
    Pause -> Nothing <$ modify pause
    b -> do
      at <- gets (\c -> c.shown)
      reach at
      b' <- blockSteps incremental at b
      pure (Just (at, b'))
  pure (concatMap marked (groupBy ((==) `on` fst) (catMaybes read')))
  where
    marked = \case
      run@((at, _) : _) | at > shownFrom -> [stepMark at (map snd run)]
      run -> map snd run

-- | A pause shows what follows after everything before it: one step
-- later, or after the last item of an incremental list, whichever is
-- later.
pause :: Counter -> Counter
pause c = let at = max (c.shown + 1) c.next in c {shown = at, next = at}

-- | The inlines of a paragraph shown from the step @shownFrom@ on, with
-- the pauses among them ('InlinePause'): each run of inlines shown from a
-- later step is marked ('Marked', as 'stepMark' marks blocks), and the
-- pauses are gone. The blocks after the paragraph go on from its last
-- pause, as after a pause on a line of its own.
inlineSteps :: Int -> [Inline] -> State Counter [Inline]
inlineSteps shownFrom xs = do
  read' <- for xs $ \case
    InlinePause _ _ -> Nothing <$ modify pause
    x -> do
      at <- gets (\c -> c.shown)
      reach at
      pure (Just (at, x))
  pure (concatMap marked (groupBy ((==) `on` fst) (catMaybes read')))
  where
    marked = \case
      run@((at, _) : _) | at > shownFrom -> [Marked (stepAttributes at) (map snd run)]
      run -> map snd run

-- | A block shown from a step, with the steps inside it: in a box, in an
-- alert, in a spoiler, in a quotation, and in a list's items.
blockSteps :: Bool -> Int -> Block -> State Counter Block
blockSteps incremental at = \case
  Div attrs bs -> Div attrs <$> piecesOf (incrementalIn attrs) at bs
  Alert kind title bs -> Alert kind title <$> piecesOf incremental at bs
  BlockQuote bs -> BlockQuote <$> piecesOf incremental at bs
  Spoiler h bs -> Spoiler h <$> piecesOf incremental at bs
  Para xs | any isInlinePause xs -> Para <$> inlineSteps at xs
  Plain xs | any isInlinePause xs -> Plain <$> inlineSteps at xs
  List kind items -> List kind <$> traverse item items
  other -> pure other
  where
    incrementalIn attrs
      | "incremental" `elem` classes attrs = True
      | "nonincremental" `elem` classes attrs = False
      | otherwise = incremental
    -- An item is shown from the next step in an incremental list, and
    -- otherwise from the step the list has reached. Its content is shown
    -- with it, up to a pause in it; after the item, the content goes on
    -- from where it was before, or from that pause.
    item (ListItem task bs) = do
      before <- gets (\c -> c.shown)
      itemAt <- if incremental then state (\c -> (c.next, c {next = c.next + 1})) else pure before
      modify (\c -> c {shown = itemAt})
      reach itemAt
      bs' <- piecesOf incremental itemAt bs
      modify (\c -> c {shown = if c.shown /= itemAt then c.shown else before})
      pure (ListItem task (bs' <> [itemMark itemAt | itemAt > at]))

reach :: Int -> State Counter ()
reach at = modify (\c -> c {highest = max c.highest at})

-- | The mark of blocks shown from a step: a box with the class
-- @slide-step@ and the step in @data-step@. It is rendered as a @div@
-- around them ('showingStep').
stepMark :: Int -> [Block] -> Block
stepMark at = Div (stepAttributes at)

-- | The attributes of the mark of a piece shown from a step: the class
-- @slide-step@ and the step.
stepAttributes :: Int -> Attributes
stepAttributes at = [("class", "slide-step"), ("data-step", show at)]

isInlinePause :: Inline -> Bool
isInlinePause = \case
  InlinePause _ _ -> True
  _ -> False

-- | The mark of a list item shown from a step: an empty box with the class
-- @slide-step-item@ and the step in @data-step@, last in the item. The
-- stylesheet hides the item that has it, marker and all, which a box
-- around the item's content could not do.
itemMark :: Int -> Block
itemMark at = Div [("class", "slide-step-item"), ("data-step", show at)] []

-- | Which mark a box is, and the step it shows its content from: 'True'
-- for an item's mark.
markOf :: Attributes -> Maybe (Bool, Int)
markOf attrs = do
  at <- readMaybe . T.unpack =<< attribute "data-step" attrs
  case classes attrs of
    "slide-step" : _ -> Just (False, at)
    "slide-step-item" : _ -> Just (True, at)
    _ -> Nothing

-- | A slide's body as shown at a step: what is shown from a later step is
-- left out, and the marks are taken away.
atStep :: Int -> Slide -> [Block]
atStep k s = blocks s.body
  where
    blocks = concatMap $ \case
      Div attrs bs | Just (item, at) <- markOf attrs -> if item || at > k then [] else blocks bs
      Div attrs bs -> [Div attrs (blocks bs)]
      Alert kind title bs -> [Alert kind title (blocks bs)]
      BlockQuote bs -> [BlockQuote (blocks bs)]
      Spoiler h bs -> [Spoiler h (blocks bs)]
      List kind items -> case [ListItem task (blocks bs) | ListItem task bs <- items, shown bs] of
        [] -> []
        shownItems -> [List kind shownItems]
      Para xs -> [Para (concatMap inline xs)]
      Plain xs -> [Plain (concatMap inline xs)]
      other -> [other]
    shown bs = and [at <= k | Div attrs _ <- bs, Just (True, at) <- [markOf attrs]]
    inline = \case
      Marked attrs xs | Just (_, at) <- markOf attrs -> if at > k then [] else xs
      x -> [x]

-- | A slide as presented at a step: everything in it, the pieces shown
-- from a later step given the class @slide-step-later@, which the
-- stylesheet hides. The structure does not change from step to step, only
-- the classes, so moving between steps redraws nothing.
showingStep :: Int -> Slide -> Slide
showingStep k s = Slide {title = s.title, body = map block s.body, notes = s.notes, steps = s.steps}
  where
    block = \case
      Div attrs bs | Just (item, at) <- markOf attrs -> Div [("class", T.unwords ((if item then "slide-step-item" else "slide-step") : ["slide-step-later" | at > k])), ("data-step", show at)] (map block bs)
      Div attrs bs -> Div attrs (map block bs)
      Alert kind title bs -> Alert kind title (map block bs)
      BlockQuote bs -> BlockQuote (map block bs)
      Spoiler h bs -> Spoiler h (map block bs)
      List kind items -> List kind [ListItem task (map block bs) | ListItem task bs <- items]
      Para xs -> Para (map inline xs)
      Plain xs -> Plain (map inline xs)
      other -> other
    inline = \case
      Marked attrs xs | Just (_, at) <- markOf attrs -> Marked [("class", T.unwords ("slide-step" : ["slide-step-later" | at > k])), ("data-step", show at)] xs
      x -> x

-- | 'RenderedSlide': a slide as HTML, its title (the heading), its body and
-- its notes, each placed where the slide view shows it.
data RenderedSlide w i = RenderedSlide
  { title :: [HH.HTML w i]
  , body :: [HH.HTML w i]
  , notes :: [HH.HTML w i]
  }

-- | The deck's slides as HTML, rendered as one document
-- ('renderSections'). An @html@ fence's frame on a slide is drawn in the
-- colours of the deck's theme ('slideScheme'), and one in the notes, which
-- are shown beside the slide in the page's colours, in the system's: the
-- deck is rendered once for each, and each part taken from its own. The
-- two renders are one document each, so their islands have the same keys.
renderDeck :: Options page w i -> Deck -> [RenderedSlide w i]
renderDeck = renderDeckWithIds ""

-- | 'renderDeck', every id the slides write (a heading's, a footnote's and
-- its references') and every link to a place in them starting with a
-- prefix ('Wiki.Core.Markdown.Render.renderSectionsWithIds'): a viewer of
-- a presentation in a page keeps its ids apart from the page's and from
-- another viewer's.
renderDeckWithIds :: Text -> Options page w i -> Deck -> [RenderedSlide w i]
renderDeckWithIds prefix opts deck = zipWith fromBoth (triples (render opts {frameScheme = slideScheme deck.options.theme})) (triples (render opts))
  where
    render o = renderSectionsWithIds o (map (prefix,) (concat [[foldMap (pure . titleBlock) s.title, s.body, s.notes] | s <- deck.slides]))
    fromBoth onSlide inPage = RenderedSlide {title = onSlide.title, body = onSlide.body, notes = inPage.notes}
    triples = \case
      title : body : notes : rest -> RenderedSlide {title, body, notes} : triples rest
      _ -> []

-- | The colours a slide of this theme is drawn in, whatever the system
-- prefers (the stylesheet's @.slide@): dark for the dark theme, light for
-- the others.
slideScheme :: Theme -> FrameScheme
slideScheme = \case
  Dark -> DarkScheme
  Beamer -> LightScheme
  Light -> LightScheme

----------------------------------------------------------------------
-- Slides in the source

-- | 'SlideSpan' is a slide as the editor finds it in a presentation's
-- source: its lines, from 1 and both included, as CodeMirror counts them
-- (@\\n@ alone ends a line), the level of its opener ('Nothing' for what
-- comes before the first opener), and its title's text. The last line is
-- the last that is not blank before the next slide's first.
data SlideSpan = SlideSpan
  { from :: Int
  , to :: Int
  , level :: Maybe Int
  , title :: Text
  }
  deriving stock (Eq, Show)

-- | Forcing a 'SlideSpan' forces its lines, level and title, so that the
-- editor can find the slides on a worker thread.
instance NFData SlideSpan where
  rnf sp = rnf (sp.from, sp.to, sp.level, sp.title)

-- | The slides of a presentation's source, in order, as the editor lists
-- and folds them: one for each opener among the blocks 'deckLevel' gives
-- ('isOpener'), read from 'parseDeckSpans', so that the editor's slides
-- are those 'deckOf' cuts; and, first, what comes before the first
-- opener, when 'deckOf' makes a slide of it. A setext heading's slide
-- starts at its title's first line.
--
-- The parser and CodeMirror count lines differently in a text with a
-- carriage return: for the parser a @\\r@ ends a line, with every line
-- feed right after it ('parserLineStarts'); for CodeMirror only a line
-- feed does. The parser's lines are made CodeMirror's here, so that a
-- text with @\\r\\n@ line breaks has its slides on the lines the editor
-- shows (its rows' fits, the preview following the cursor). None when
-- two slides would start on one line of CodeMirror's (a lone @\\r@
-- between them, the slide of what comes before the first opener
-- included): the editor then has no slides to mark or follow.
slideSpans :: Text -> [SlideSpan]
slideSpans source = slideSpansParsed source (either (const []) (map (first (fmap fst))) (parseDeckSpans source))

-- | 'slideSpans' of a text the caller has parsed already, as
-- 'parseDeckSpans' or 'Wiki.Core.Markdown.Ast.parseWithLinesMarkersAndDeck'
-- gives its blocks, each with its first line: one parse serves the
-- editor's check of the text and its slides.
slideSpansParsed :: Text -> [(Maybe Int, Block)] -> [SlideSpan]
slideSpansParsed source spans
  | not (and (zipWith (<) allStarts (drop 1 allStarts))) = []
  | otherwise =
      let ends = map (subtract 1) (drop 1 starts) <> [lineCount]
          preamble = [SlideSpan {from = 1, to = lastNonBlank 1 (maybe lineCount (subtract 1) (head starts)), level = Nothing, title = ""} | untitled]
       in preamble <> [SlideSpan {from = l, to = lastNonBlank l e, level = Just lvl, title} | ((l, lvl, title), e) <- zip openers ends]
  where
    -- The slide of what comes before the first opener, when 'deckOf' makes
    -- one: not of a look, footnotes or pauses alone.
    untitled = case (deckOf (map snd spans)).slides of
      s : _ -> isNothing s.title && not (null s.body && null s.notes)
      [] -> False
    -- Every slide's first line, that slide of what comes before the first
    -- opener's included: no two may be the same line of CodeMirror's.
    allStarts = [1 | untitled] <> starts
    found = [(l, lvl, plainText xs) | (Just l, Heading lvl _ xs) <- deckLevel spans, lvl <= 2]
    openers = zipWith (\l (_, lvl, title) -> (l, lvl, title)) (editorLines [l | (l, _, _) <- found]) found
    starts = [l | (l, _, _) <- openers]
    -- CodeMirror's line of each of the parser's lines given, from 1, in
    -- order: the same lines in a text without a carriage return.
    editorLines
      | T.any (== '\r') source = atLines 1 (scanl (+) 1 (map (T.count "\n") (pieces (parserLineStarts source) source)))
      | otherwise = identity
    -- The table's entries for ascending lines, walking the table once.
    atLines n table = \case
      [] -> []
      l : ls -> case drop (l - n) table of
        t : table' -> t : atLines l (t : table') ls
        [] -> l : atLines n table ls
    -- The text cut at the parser's lines' starts, one piece a line but
    -- the last, in one walk over the text.
    pieces starts' rest = case starts' of
      a : more@(b : _) -> let (piece, rest') = T.splitAt (b - a) rest in piece : pieces more rest'
      _ -> []
    sourceLines = T.splitOn "\n" source
    lineCount = length sourceLines
    lineAt n = fromMaybe "" (atMay sourceLines (n - 1))
    blank n = T.all isSpace (lineAt n)
    lastNonBlank start n
      | n > start && blank n = lastNonBlank start (n - 1)
      | otherwise = n

-- | How many of a presentation's first slides stay where they are when
-- slides are moved: what comes before the first opener, and the title
-- slide, a level-one opener that is the first.
fixedSlides :: [SlideSpan] -> Int
fixedSlides spans = length (takeWhile fixed (zip [0 :: Int ..] spans))
  where
    firstOpener = length (takeWhile (isNothing . (.level)) spans)
    fixed (i, sp) = isNothing sp.level || (i == firstOpener && sp.level == Just 1)

-- | The character each line of a text starts at, as the Markdown parser
-- counts lines: commonmark 0.3.1's tokenizer ends a line at a line feed,
-- and at a carriage return together with every line feed right after it
-- (it groups characters with @Data.Text.groupBy@, which compares each
-- character with the first of the group).
parserLineStarts :: Text -> [Int]
parserLineStarts = (0 :) . go 0 . T.unpack
  where
    go i = \case
      '\n' : rest -> (i + 1) : go (i + 1) rest
      '\r' : rest ->
        let feeds = length (takeWhile (== '\n') rest)
            next = i + 1 + feeds
         in next : go next (drop feeds rest)
      _ : rest -> go (i + 1) rest
      [] -> []

-- | The index of the slide a line is on, if any: the last slide that
-- starts on or before it.
slideAtLine :: [SlideSpan] -> Int -> Maybe Int
slideAtLine spans line = lastMay [i | (i, sp) <- zip [0 ..] spans, sp.from <= line]

-- | A presentation's source as its slides' chunks ('slideSpans'): the
-- text before the first slide (blank lines, when no slide starts on the
-- first line), then each slide's text from its first line up to the next
-- slide's first, the blank lines between them included. Their
-- concatenation is the text, byte for byte. A text without slides is one
-- chunk.
slideChunks :: Text -> (Text, [Text])
slideChunks source = case slideSpans source of
  [] -> (source, [])
  spans ->
    let offsets = map lineStart (map (.from) spans) <> [T.length source]
        before = T.take (fromMaybe 0 (head offsets)) source
        chunk a b = T.take (b - a) (T.drop a source)
     in (before, zipWith chunk offsets (drop 1 offsets))
  where
    -- The character the line starts at.
    lineStart n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" source)))

-- | Move a presentation's slide, by its index in 'slideSpans', to be the
-- slide at another index: its whole text, from its first line up to the
-- next slide's, blank lines included, and nothing else, so that every
-- slide's text is the same, only in another order. The slides that stay
-- first ('fixedSlides') do not move, and none moves before them: a move
-- that would is no move. A text with no slides, or an index out of range,
-- is left as it is, and so is a text with a carriage return: the line
-- breaks a move adds are line feeds. (The editor moves rows with
-- "Wiki.Core.SlideRows", which keeps a text's own line breaks.)
--
-- Line breaks are added where the slides would otherwise run together,
-- and nowhere else. The last slide's text, which may end without one,
-- gets a line break when another slide comes after it. A slide whose
-- title is a setext heading (@Title@, then @---@) can still be read as the
-- end of the paragraph or the list above it: when the moved text does not
-- have the same slides in the new order, a blank line goes before each
-- such slide that the move put after another and that has none
-- ('joined'). When even that does not give the same slides (a last slide
-- with a fence or a box left open, which would take in the slides moved
-- after it), the move is no move.
moveSlide :: Int -> Int -> Text -> Text
moveSlide i j source
  | T.any (== '\r') source = source
  | i == j || i < fixed || j < fixed || i >= count || j >= count = source
  | sameSlides plain = plain
  | sameSlides apart = apart
  | otherwise = source
  where
    spans = slideSpans source
    count = length spans
    fixed = fixedSlides spans
    (before, chunks) = slideChunks source
    order = reorder [0 .. count - 1]
    placed = [(k, c) | k <- order, Just c <- [atMay chunks k]]
    plain = before <> joined False placed
    apart = before <> joined True placed
    -- The same slides, in the new order: each with its level, its title
    -- and its lines as they were.
    sameSlides text = map (written text) (slideSpans text) == map (written source) (reorder spans)
    written text sp = (sp.level, sp.title, take (sp.to - sp.from + 1) (drop (sp.from - 1) (T.splitOn "\n" text)))
    reorder :: [a] -> [a]
    reorder xs = case atMay xs i of
      Nothing -> xs
      Just x -> let rest = take i xs <> drop (i + 1) xs in take j rest <> [x] <> drop j rest

-- | Slides' texts, each with its index in the text before the move, one
-- after the other, each but the last ending with a line break and, when
-- asked, with a blank line before a slide whose title is a setext
-- heading, where the move put it after another slide than before
-- ('moveSlide').
joined :: Bool -> [(Int, Text)] -> Text
joined apartSetext = \case
  [] -> ""
  [(_, c)] -> c
  (k, c) : next@(k', c') : rest ->
    let ended = if "\n" `T.isSuffixOf` c then c else c <> "\n"
        moved = k' /= k + 1
        apart = if apartSetext && moved && setext c' && not (endsBlank ended) then ended <> "\n" else ended
     in apart <> joined apartSetext (next : rest)
  where
    -- A slide's text starts with its opener's first line: an ATX heading
    -- starts with a hash after at most three spaces, a setext one not.
    setext c = not ("#" `T.isPrefixOf` T.dropWhile (== ' ') (T.take 4 c))
    -- Whether a text that ends with a line break has a blank line last.
    endsBlank t = case reverse (T.splitOn "\n" t) of
      _ : lastLine : _ : _ -> T.all isSpace lastLine
      _ -> False

----------------------------------------------------------------------
-- Whether a slide's content fits

-- | 'Fit' is whether a slide's content fits on it, as the editor's
-- preview measures it on a card 1024 CSS pixels wide at the deck's aspect
-- (WP5.97 of docs/PLAN.md): the smallest size a deck is promised to be
-- shown at, where what is sized in pixels (an image's width, a frame's
-- height) takes the largest share of the slide.
data Fit
  = -- | Not measured yet, or measured for a text that has changed since:
    -- never taken for 'Fits'.
    Unmeasured
  | -- | Half a line or more to spare.
    Fits
  | -- | Less than half a line to spare, or up to one line cut: it may be
    -- cut slightly.
    Tight
  | -- | More than a line cut.
    Overflowing
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The fit of a slide from what the preview measured on its body: how far
-- the bottom of its content is below the bottom of the body's room, and
-- how far its content is wider than the body, both in lines of the body's
-- text (negative when there is room to spare). The room goes down to the
-- bottom of the body's padding: the body shows what runs into its padding
-- and cuts what runs out of it, so that edge is where a slide is cut, and
-- the half line a slide that fits has to spare is counted from it.
fitOf :: Double -> Double -> Fit
fitOf below wider
  | below > 1 || wider > 1 = Overflowing
  | below > -0.5 || wider > 0 = Tight
  | otherwise = Fits

-- | A fit's name, as the editor's marks and the preview's classes write
-- it.
fitName :: Fit -> Text
fitName = \case
  Unmeasured -> "unmeasured"
  Fits -> "fits"
  Tight -> "tight"
  Overflowing -> "overflowing"

-- | 'Measures' is whether each slide of a presentation fits, as the
-- preview measured it for a text, kept with what each fit depends on in
-- that text: the slide's own lines, and the lines that set the deck's
-- look (@[[!style]]@), which set the shape and the type of every slide.
data Measures = Measures
  { look :: [Text]
  , measured :: [([Text], Fit)]
  }
  deriving stock (Eq, Show)

-- | The measures of a text: the fits by the slides' places in the deck.
measuresFor :: Text -> [Fit] -> Measures
measuresFor text fits =
  Measures
    { look = lookLines text
    , measured = zip (map (slideLines text) (slideSpans text)) (fits <> repeat Unmeasured)
    }

-- | Whether each slide of a text (its 'slideSpans') fits, as far as the
-- measures say: a slide's fit holds while its lines and the look are
-- those it was measured with, at the same place in the deck; a slide
-- changed since, or not measured, is 'Unmeasured'.
fitsNow :: Maybe Measures -> Text -> [SlideSpan] -> [Fit]
fitsNow measures text spans = case measures of
  Just m | m.look == lookLines text -> [current (atMay m.measured i) sp | (i, sp) <- zip [0 ..] spans]
  _ -> map (const Unmeasured) spans
  where
    current found sp = case found of
      Just (written, fit) | written == slideLines text sp -> fit
      _ -> Unmeasured

-- | The lines of a text that set a deck's look.
lookLines :: Text -> [Text]
lookLines = filter ("[[!style]]" `T.isPrefixOf`) . map T.stripStart . T.splitOn "\n"

-- | A slide's lines in a text.
slideLines :: Text -> SlideSpan -> [Text]
slideLines text sp = take (sp.to - sp.from + 1) (drop (sp.from - 1) (T.splitOn "\n" text))
