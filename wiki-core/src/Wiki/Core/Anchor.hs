{-# LANGUAGE TemplateHaskell #-}

-- | Where an inline comment is on a page: a quote of the page's text, found
-- again however the page changes around it, and marked where it is found.
--
-- An inline thread ("Wiki.Core.Comment") does not point into the page's
-- Markdown. A reader selects text in the rendered page, and mapping that
-- selection back to offsets in the source is fragile (a word in bold is
-- three characters further on in the source than on the page; a link's
-- text is somewhere in the middle of its Markdown). Instead the thread
-- carries a /text quote selector/, as the W3C's Web Annotation model has
-- it ('Anchor'): the text quoted, exactly, with a few characters before and
-- after it as its context. Decision 23 of docs/PLAN.md.
--
-- = The text
--
-- The text a quote is taken from and looked for in is the page's rendered
-- text ('renderedText'): the text nodes of the rendered document, in
-- order, joined with nothing between them, without what the islands draw
-- (code blocks, formulas, diagrams and pictures are child components,
-- whose content is a library's and not the page's text). It is exactly the
-- text of the article's DOM, read the same way by @jsbits/comments.js@:
-- the same nodes, made by the same renderer, so a quote taken in the
-- browser is found here character for character.
--
-- = Finding a quote again
--
-- 'locate' looks for the quote in the text as it is now. Found once, it is
-- there, wherever it moved: an edit elsewhere in the page changes nothing.
-- Found more than once, the context decides: the place whose text before
-- and after matches the anchor's prefix and suffix best, if one matches
-- better than every other. A quote the page no longer has, or has several
-- times with no context to tell them apart, is 'Orphaned': its thread is
-- kept, and shown without a highlight, with its quote.
--
-- = Marking it
--
-- 'highlight' wraps each quote found in @\<mark class="comment-mark"
-- data-thread="…">@ elements, in the rendered document itself, as plain
-- Halogen HTML: a pure function of the document and the threads, so that
-- the page the server renders and the page the program renders are the
-- same, and no JavaScript ever touches the article. A mark is put around
-- part of one text node, never more, so a quote across two paragraphs is
-- two marks, and no mark crosses an element's boundary.
module Wiki.Core.Anchor
  ( -- * Anchors
    Anchor (..)
  , contextLength
  , maxQuoteLength
  , anchorAt
  , checkAnchor

    -- * Finding them
  , Range (..)
  , Located (..)
  , locate
  , renderedText

    -- * Marking them
  , Marking (..)
  , highlight
  )
where

import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Core (HTML (..))
import Halogen.Query.Input (Input)
import Halogen.VDom.DOM.Prop (Prop (..))
import Halogen.VDom.Types (ElemName (..), VDom (..), runGraft)
import Protolude
import Wiki.Core.Id (CommentThreadId (..))
import Wiki.Core.Json (defaultOptions, deriveValueJSON)

-- | A quote of a page's rendered text: the text itself, exactly, and up to
-- 'contextLength' characters of the text just before it and just after
-- it, fewer where the text starts or ends sooner.
data Anchor = Anchor
  { exact :: Text
  , prefix :: Text
  , suffix :: Text
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''Anchor

-- | How much context an anchor keeps on each side: enough to tell one
-- occurrence of a phrase from another, little enough that an edit nearby
-- leaves most of it.
contextLength :: Int
contextLength = 32

-- | The longest quote a thread may have, in characters: a few paragraphs.
maxQuoteLength :: Int
maxQuoteLength = 2000

-- | The anchor of a range of a text.
anchorAt :: Text -> Range -> Anchor
anchorAt text r =
  Anchor
    { exact = T.take (r.end - r.start) (T.drop r.start text)
    , prefix = T.takeEnd contextLength (T.take r.start text)
    , suffix = T.take contextLength (T.drop r.end text)
    }

-- | An anchor as it is kept: a quote with something to read in it, at most
-- 'maxQuoteLength' long, and its context cut to 'contextLength' on each
-- side (the side nearest the quote kept); or why it cannot be.
checkAnchor :: Anchor -> Either Text Anchor
checkAnchor a
  | T.all isSpace a.exact = Left "A comment's quote cannot be blank."
  | T.length a.exact > maxQuoteLength = Left ("A comment's quote can be at most " <> show maxQuoteLength <> " characters long.")
  | otherwise = Right a {prefix = T.takeEnd contextLength a.prefix, suffix = T.take contextLength a.suffix}

-- | A part of a text, by the offsets of its first character and of the
-- character after its last, counted in characters.
data Range = Range
  { start :: Int
  , end :: Int
  }
  deriving stock (Eq, Ord, Show)

-- | Where a quote is now.
data Located
  = -- | There, at this range of the text.
    Found Range
  | -- | Nowhere, or nowhere in particular: the page no longer has the
    -- quote, or has it more than once with no context to choose between
    -- them.
    Orphaned
  deriving stock (Eq, Show)

-- | Where an anchor's quote is in a text (see "Finding a quote again"
-- above).
--
-- Each occurrence is scored by how much of the anchor's context it has:
-- the characters of the prefix that end the text before it, and of the
-- suffix that start the text after it. A context shorter than
-- 'contextLength' was cut short by the start or the end of the text, so an
-- occurrence that is just as near the start (or the end) scores one more,
-- for the edge it shares. The occurrence that scores best wins, if it
-- scores anything and no other scores as much.
locate :: Text -> Anchor -> Located
locate text a
  | T.null a.exact = Orphaned
  | otherwise = case occurrences of
      [] -> Orphaned
      [s] -> found s
      several -> case sortOn (Down . fst) [(score s, s) | s <- several] of
        (best, s) : (next, _) : _ | best > 0, best > next -> found s
        _ -> Orphaned
  where
    n = T.length a.exact
    found s = Found Range {start = s, end = s + n}
    -- Every occurrence, those that overlap another included ("oteno" is
    -- twice in "otenoteno"): 'T.breakOnAll' finds only those that do
    -- not, and would take the second of two such for no occurrence at all.
    occurrences = startingAt 0 text
    startingAt offset rest = case T.breakOn a.exact rest of
      (before, match)
        | T.null match -> []
        | otherwise ->
            let s = offset + T.length before
             in s : startingAt (s + 1) (T.drop (T.length before + 1) rest)
    score s =
      let before = T.take s text
          after = T.drop (s + n) text
          edge context side = if T.length context < contextLength && side == context then 1 else 0
       in commonSuffixLength a.prefix before
            + commonPrefixLength a.suffix after
            + edge a.prefix before
            + edge a.suffix after

commonPrefixLength :: Text -> Text -> Int
commonPrefixLength x y = maybe 0 (\(common, _, _) -> T.length common) (T.commonPrefixes x y)

commonSuffixLength :: Text -> Text -> Int
commonSuffixLength x y = commonPrefixLength (T.reverse x) (T.reverse y)

-- | A rendered document's text (see "The text" above): its text nodes, in
-- order, joined; nothing of a child component (an island).
renderedText :: [HH.HTML w i] -> Text
renderedText = T.concat . concatMap (\(HTML v) -> texts v)
  where
    texts :: VDom a w -> [Text]
    texts = \case
      Text t -> [t]
      Elem _ _ _ children -> concatMap texts children
      Keyed _ _ _ children -> concatMap (texts . snd) children
      Widget _ -> []
      Grafted g -> texts (runGraft g)

-- | A quote to mark: its thread, where it was found in the document's
-- 'renderedText', and whether it is the thread the reader has chosen
-- (marked @comment-mark-focused@ as well).
data Marking = Marking
  { thread :: CommentThreadId
  , range :: Range
  , focused :: Bool
  }
  deriving stock (Eq, Show)

-- | The document with each marking's text wrapped in marks (see "Marking
-- it" above): each text node cut where a marked range starts or ends, and
-- each piece of it in a range put in a @\<mark>@ of its own. Where ranges
-- overlap, a piece is marked once, for the thread whose quote starts
-- last (the innermost, as the reader sees it), and is focused if any of
-- them is.
highlight :: forall w i. [Marking] -> [HH.HTML w i] -> [HH.HTML w i]
highlight [] doc = doc
highlight markings doc = map HTML (evalState (concat <$> traverse (walk . (\(HTML v) -> v)) doc) 0)
  where
    walk :: VDom [Prop (Input i)] w -> State Int [VDom [Prop (Input i)] w]
    walk = \case
      Text t -> do
        start <- get
        put (start + T.length t)
        pure (pieces start t)
      Elem ns name props children -> (\cs -> [Elem ns name props cs]) . concat <$> traverse walk children
      Keyed ns name props children -> (\cs -> [Keyed ns name props (concat cs)]) <$> traverse walkKeyed children
      Widget w -> pure [Widget w]
      Grafted g -> walk (runGraft g)

    -- A keyed child that is cut in pieces keeps its key on the first.
    walkKeyed (key, child) = zipWith (\n v -> (if n == (0 :: Int) then key else key <> "~" <> show n, v)) [0 ..] <$> walk child

    -- The pieces of a text node that starts at this offset.
    pieces :: Int -> Text -> [VDom [Prop (Input i)] w]
    pieces start t =
      [ piece (T.take (y - x) (T.drop (x - start) t)) (covering x y)
      | (x, y) <- zip cuts (drop 1 cuts)
      , y > x
      ]
      where
        end = start + T.length t
        cuts =
          ordNub . sort $
            [start, end]
              <> [b | m <- markings, b <- [m.range.start, m.range.end], b > start, b < end]
        covering x y = [m | m <- markings, m.range.start <= x, y <= m.range.end]

    piece text = \case
      [] -> Text text
      ms ->
        let innermost = fromMaybe (panic "covered by none") (head (sortOn (Down . (\m -> m.range.start)) ms))
            classes = "comment-mark" <> (if any (\m -> m.focused) ms then " comment-mark-focused" else "")
         in Elem
              Nothing
              (ElemName "mark")
              [ Attribute Nothing (HH.AttrName "class") classes
              , Attribute Nothing (HH.AttrName "data-thread") innermost.thread.text
              ]
              [Text text]
