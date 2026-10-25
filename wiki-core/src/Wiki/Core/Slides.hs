-- | A page as a slide deck: the same Markdown, read as slides.
--
-- A page is not written differently to be presented. Its parsed blocks
-- ("Wiki.Core.Markdown.Ast") are cut at each thematic break (@---@) at the
-- top level of the page into slides; a break inside a list, a quotation or a
-- box stays a rule on its slide. On each slide:
--
-- * the first heading at the slide's top level is its title, taken out of
--   its body (a slide whose title is a level-one heading is a title slide,
--   which a theme lays out as Beamer lays out a title page or a section's
--   page);
-- * a fenced div with the class @notes@ (@::: notes@) holds the speaker's
--   notes, taken out of the body and shown to the speaker only;
-- * the footnotes it refers to are put at its end, rather than all at the
--   end of the last slide.
--
-- How the deck looks is said once, anywhere in the page, by a fenced div
-- with the class @slides@ and attributes: @::: {.slides theme=dark
-- aspect=4:3}@ then @:::@ (themes: @beamer@, the default, @light@
-- and @dark@; aspects: @16:9@, the default, and @4:3@). It shows nothing, on the page or on a slide.
-- A page with neither a break nor such a div is one slide, and not a deck
-- ('isDeck'): it can still be presented, but nothing offers it.
--
-- Slides are rendered with the page's renderer, one document cut into
-- sections ('Wiki.Core.Markdown.Render.renderSections'), so a slide shows
-- everything a page does, and a formula on the fifth slide is set with the
-- macros the first one defined.
module Wiki.Core.Slides
  ( -- * Decks
    Deck (..)
  , Slide (..)
  , SlideTitle (..)
  , deckOf
  , isDeck
  , titleBlock

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

-- | A page as slides, with how they are shown. There is always at least one
-- slide.
data Deck = Deck
  { options :: DeckOptions
  , slides :: [Slide]
  }
  deriving stock (Eq, Show)

-- | A slide: its title, if it has a heading, what it shows, and the
-- speaker's notes for it.
data Slide = Slide
  { title :: Maybe SlideTitle
  , body :: [Block]
  , notes :: [Block]
  }
  deriving stock (Eq, Show)

-- | The heading a slide is titled with, as it was written: its level, its
-- attributes (its @id@ among them) and its text.
data SlideTitle = SlideTitle
  { level :: Int
  , attributes :: Attributes
  , text :: [Inline]
  }
  deriving stock (Eq, Show)

-- | How a deck is shown: its theme and the shape of its slides.
data DeckOptions = DeckOptions
  { theme :: Theme
  , aspect :: Aspect
  }
  deriving stock (Eq, Show)

-- | The deck's look, a CSS class of the stylesheet's (@slides-theme-…@).
data Theme
  = -- | Beamer's look: a title bar, and a footer with the page's title and
    -- the slide's number. The default.
    Beamer
  | -- | Dark on light, the title as a plain heading, a quiet footer.
    Light
  | -- | Light on dark, as 'Light' is otherwise.
    Dark
  deriving stock (Eq, Show, Enum, Bounded)

-- | The shape of a slide, width to height.
data Aspect
  = -- | 16:9, a screen's. The default.
    Wide
  | -- | 4:3, an older projector's, and Beamer's default.
    Standard
  deriving stock (Eq, Show, Enum, Bounded)

defaultDeckOptions :: DeckOptions
defaultDeckOptions = DeckOptions {theme = Beamer, aspect = Wide}

-- | A theme's name, as the @theme@ attribute writes it and the stylesheet's
-- class ends.
themeName :: Theme -> Text
themeName = \case
  Beamer -> "beamer"
  Light -> "light"
  Dark -> "dark"

-- | An aspect's name, as the @aspect@ attribute writes it.
aspectName :: Aspect -> Text
aspectName = \case
  Wide -> "16:9"
  Standard -> "4:3"

-- | The page's blocks as a deck.
deckOf :: [Block] -> Deck
deckOf doc =
  Deck
    { options = maybe defaultDeckOptions optionsOf (head [attrs | Div attrs _ <- doc, isOptions attrs])
    , slides = withFootnotes notes (nonEmpty' (filter (not . emptySlide) (map slideOf (splitAtBreaks content))))
    }
  where
    notes = concat [ns | Footnotes ns <- doc]
    content = filter keep doc
    keep = \case
      Footnotes _ -> False
      Div attrs _ -> not (isOptions attrs)
      _ -> True
    -- A page of nothing but breaks is still one slide, empty.
    nonEmpty' = \case
      [] -> [Slide Nothing [] []]
      ss -> ss

-- | Whether a page is written as a deck: cut into slides, or saying how its
-- slides look. Any page can be shown as slides; this is whether it is meant
-- to be.
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
slideOf bs = Slide {title, body = before <> drop 1 rest, notes = concat [inner | Div attrs inner <- bs, isNotes attrs]}
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
emptySlide s = isNothing s.title && null s.body && null s.notes

isNotes :: Attributes -> Bool
isNotes attrs = "notes" `elem` classes attrs

isOptions :: Attributes -> Bool
isOptions attrs = "slides" `elem` classes attrs

-- | The options a @slides@ div's attributes give; what they leave out, or
-- name wrongly, is the default.
optionsOf :: Attributes -> DeckOptions
optionsOf attrs =
  DeckOptions
    { theme = fromMaybe defaultDeckOptions.theme (named themeName =<< attribute "theme" attrs)
    , aspect = fromMaybe defaultDeckOptions.aspect (named aspectName . T.replace "/" ":" =<< attribute "aspect" attrs)
    }
  where
    named :: (Enum a, Bounded a) => (a -> Text) -> Text -> Maybe a
    named name value = find (\a -> name a == T.toLower (T.strip value)) [minBound .. maxBound]

-- | Each footnote at the end of the first slide that refers to it, and
-- those no slide refers to at the end of the last.
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
    addNotes here s@Slide {title, body, notes = speaker} = if null here then s else Slide {title, body = body <> [Footnotes here], notes = speaker}

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

-- | A slide as HTML: its title (the heading), its body and its notes, each
-- to be put where the slide shows it.
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
