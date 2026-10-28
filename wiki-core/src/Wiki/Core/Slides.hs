-- | A page as a slide deck: the same Markdown, read as slides.
--
-- A page needs no special writing to be presented. Its parsed blocks
-- ("Wiki.Core.Markdown.Ast") are split into slides at each thematic break
-- (@---@) at the top level of the page; a break inside a list, a quotation
-- or a box stays a horizontal rule on its slide. On each slide:
--
-- * the first heading at the slide's top level is its title, removed from
--   its body (a slide whose title is a level-one heading is a title slide,
--   which a theme lays out as Beamer lays out a title page or a section
--   page);
-- * a fenced div with the class @notes@ (@::: notes@) holds the speaker's
--   notes, removed from the body and shown to the speaker only;
-- * the footnotes the slide refers to are placed at its end, rather than
--   all at the end of the last slide;
-- * the slide is shown in steps ('steps'), as pandoc's slide writers show
--   it. A pause, @. . .@ alone in a paragraph ('Pause'), starts the next
--   step: the content after it is shown from that step on. A box with the
--   class @incremental@ (@::: incremental@) shows the items of the lists
--   in it one at a time: the first item with what comes before the list,
--   each further item in a step of its own. A slide without either is one
--   step.
--
-- The deck's look is set once, anywhere in the page, by a fenced div with
-- the class @slides@ and attributes: @::: {.slides theme=dark aspect=4:3}@
-- then @:::@ (themes: @beamer@, the default, @light@ and @dark@; aspects:
-- @16:9@, the default, and @4:3@). The div shows nothing, on the page or on
-- a slide. A page with neither a break nor such a div is one slide, and
-- not a deck ('isDeck'): it can still be presented, but no button offers
-- it.
--
-- Steps are counted as Beamer counts them, so that a Beamer PDF has one
-- page for each step the browser shows. Each block is shown from the step
-- of the last pause before it. The items of an incremental list take the
-- next steps in document order, nested lists' items included, and content
-- after the list without a pause is shown with the list's first item, as
-- in Beamer. A pause after such items starts the step after the last
-- item. A pause is read only where the Markdown reader reads one ('Pause'),
-- and a quotation, a footnote, a table or code is shown whole, at the step
-- of the block it is.
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
  , isDeck
  , titleBlock

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
  )
where

import Data.IntSet qualified as IntSet
import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Protolude
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Render (Options, renderSections)

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
deckOf doc =
  Deck
    { options = maybe defaultDeckOptions optionsOf (head [attrs | Div attrs _ <- doc, isOptions attrs])
    , slides = map cutSteps (withFootnotes notes (nonEmpty' (filter (not . emptySlide) (map slideOf (splitAtBreaks content)))))
    }
  where
    notes = concat [ns | Footnotes ns <- doc]
    content = filter keep doc
    keep = \case
      Footnotes _ -> False
      Div attrs _ -> not (isOptions attrs)
      _ -> True
    -- A page with nothing but breaks is still one slide, an empty one.
    nonEmpty' = \case
      [] -> [Slide Nothing [] [] 1]
      ss -> ss

-- | Whether a page is written as a deck: split into slides, or setting its
-- slides' look. Any page can be shown as slides; this says whether the
-- page is meant to be.
isDeck :: [Block] -> Bool
isDeck doc = any isBreak doc || or [isOptions attrs | Div attrs _ <- doc]
  where
    isBreak = \case
      ThematicBreak -> True
      _ -> False

-- | A slide's title as the heading it was written as, for rendering.
titleBlock :: SlideTitle -> Block
titleBlock t = Heading t.level t.attributes t.text

-- | The blocks between the top level's thematic breaks.
splitAtBreaks :: [Block] -> [[Block]]
splitAtBreaks bs = case break isBreak bs of
  (before, []) -> [before]
  (before, _ : after) -> before : splitAtBreaks after
  where
    isBreak = \case
      ThematicBreak -> True
      _ -> False

slideOf :: [Block] -> Slide
slideOf bs = Slide {title, body = before <> drop 1 rest, notes = concat [inner | Div attrs inner <- bs, isNotes attrs], steps = 1}
  where
    shown = filter (not . notesDiv) bs
    (before, rest) = break isHeading shown
    title = case rest of
      Heading level attributes text : _ -> Just SlideTitle {level, attributes, text}
      _ -> Nothing
    isHeading = \case
      Heading {} -> True
      _ -> False
    notesDiv = \case
      Div attrs _ -> isNotes attrs
      _ -> False

emptySlide :: Slide -> Bool
emptySlide s = isNothing s.title && all (== Pause) s.body && null s.notes

isNotes :: Attributes -> Bool
isNotes attrs = "notes" `elem` classes attrs

isOptions :: Attributes -> Bool
isOptions attrs = "slides" `elem` classes attrs

-- | The options a @slides@ div's attributes set. An option the attributes
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
      Alert _ bs -> footnoteRefs bs
      _ -> []
    ofInlines = concatMap $ \case
      FootnoteRef n _ -> [n]
      Emph xs -> ofInlines xs
      Strong xs -> ofInlines xs
      Strikeout xs -> ofInlines xs
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
    -- A pause shows what follows after everything before it: one step
    -- later, or after the last item of an incremental list, whichever is
    -- later.
    pause c = let at = max (c.shown + 1) c.next in c {shown = at, next = at}

-- | A block shown from a step, with the steps inside it: in a box, in an
-- alert, and in a list's items.
blockSteps :: Bool -> Int -> Block -> State Counter Block
blockSteps incremental at = \case
  Div attrs bs -> Div attrs <$> piecesOf (incrementalIn attrs) at bs
  Alert kind bs -> Alert kind <$> piecesOf incremental at bs
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
stepMark at = Div [("class", "slide-step"), ("data-step", show at)]

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
      Alert kind bs -> [Alert kind (blocks bs)]
      List kind items -> case [ListItem task (blocks bs) | ListItem task bs <- items, shown bs] of
        [] -> []
        shownItems -> [List kind shownItems]
      other -> [other]
    shown bs = and [at <= k | Div attrs _ <- bs, Just (True, at) <- [markOf attrs]]

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
      Alert kind bs -> Alert kind (map block bs)
      List kind items -> List kind [ListItem task (map block bs) | ListItem task bs <- items]
      other -> other

-- | 'RenderedSlide': a slide as HTML, its title (the heading), its body and
-- its notes, each placed where the slide view shows it.
data RenderedSlide w i = RenderedSlide
  { title :: [HH.HTML w i]
  , body :: [HH.HTML w i]
  , notes :: [HH.HTML w i]
  }

-- | The deck's slides as HTML, rendered as one document
-- ('renderSections').
renderDeck :: Options page w i -> Deck -> [RenderedSlide w i]
renderDeck opts deck = triples (renderSections opts (concat [[foldMap (pure . titleBlock) s.title, s.body, s.notes] | s <- deck.slides]))
  where
    triples = \case
      title : body : notes : rest -> RenderedSlide {title, body, notes} : triples rest
      _ -> []
