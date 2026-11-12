-- | A row of a presentation's slide mode in the editor (WP5.103 of
-- docs/PLAN.md): a header that shows the slide's number, its title, its
-- fit and its problems, and, while the row is open, a CodeMirror over the
-- slide's Markdown ('Wiki.App.Editor.Browser.attachRow'). The row's edits
-- are the editor's: one text, one history. The editor ("Wiki.App.View.Editor")
-- lists the rows in a keyed list, each in a slot indexed by its key, so
-- that a row keeps its CodeMirror while the rows around it change.
--
-- A row is a child component because each needs an element of its own
-- for its CodeMirror, and a 'H.RefLabel' comes only from 'H.newRefLabel'
-- in a component's initial state.
module Wiki.App.View.SlideRow
  ( Head (..)
  , heads
  , Input (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.List (zip3)
import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Protolude hiding (State, head)
import Web.DOM.Internal.Types (Element)
import Web.Event.Event (EventType (..))
import Wiki.App.Editor.Browser (attachRow, detachRow, historyKey)
import Wiki.App.Editor.Problems (ProblemRange (..))
import Wiki.Core.SlideRows (Row (..), RowKey (..), Rows (..), rowHeading, rowStarts, swallowed)
import Wiki.Core.Slides (Fit (..), SlideSpan (..), fitName)

-- | 'Head' is what a row's header shows: its key, its number among the
-- presentation's slides (none for text before the first slide that makes
-- no slide, or for a row a block left open in a row above takes in), its
-- title, whether it is that text before the first slide, its fit, the
-- number of the slide that takes it in, if one does, and how many
-- problems it has.
data Head = Head
  { key :: RowKey
  , number :: Maybe Int
  , title :: Text
  , preamble :: Bool
  , fit :: Fit
  , partOf :: Maybe Int
  , problems :: Int
  }
  deriving stock (Eq, Show)

-- | The rows' headers, from the text the rows were cut from, its slides
-- and their fits as the presentation reads them ('Wiki.Core.Slides.slideSpans'
-- and 'Wiki.Core.Slides.fitsNow', in the same order), and its problems'
-- ranges in characters. A row has the fit of the slide that starts on its
-- first line; a row the presentation does not start a slide at
-- ('Wiki.Core.SlideRows.swallowed') has none, and is part of the slide of
-- the row above that takes it in.
heads :: Text -> Rows -> [SlideSpan] -> [Fit] -> [ProblemRange] -> [Head]
heads text rows spans fits problems = [headOf i row s e | (i, row, (s, e)) <- zip3 [0 :: Int ..] rows.rows (zip starts ends)]
  where
    starts = rowStarts rows
    ends = drop 1 starts <> [T.length text]
    taken = Map.fromList (swallowed rows)
    fitAt = Map.fromList [(sp.from, f) | (sp, f) <- zip spans fits]
    preambleIsSlide = any (isNothing . (\sp -> sp.level)) spans
    lineOf c = 1 + T.count "\n" (T.take c text)
    numbered = Map.fromList (numbers 0 (zip [0 :: Int ..] rows.rows))
    numbers n = \case
      [] -> []
      (i, row) : rest
        | Map.member i taken -> numbers n rest
        | isJust (rowHeading row) || (i == 0 && preambleIsSlide) -> (i, n + 1) : numbers (n + 1) rest
        | otherwise -> numbers n rest
    headOf i row s e =
      let opener = rowHeading row
       in Head
            { key = row.key
            , number = Map.lookup i numbered
            , title = maybe "" snd opener
            , preamble = isNothing opener
            , fit = if Map.member i taken then Unmeasured else fromMaybe Unmeasured (Map.lookup (lineOf s) fitAt)
            , partOf = Map.lookup i taken >>= (`Map.lookup` numbered)
            , problems = length [() | p <- problems, p.from >= s, p.from < e || (e == T.length text && p.from == e)]
            }

-- | A row's input: its header, whether it is open, the master (the
-- editor's CodeMirror's host) once it is in place, and whether the row
-- takes the focus as it opens (a jump to it: an undo, the next problem).
-- Before the master is in place, the row cannot be opened.
data Input = Input
  { head :: Head
  , open :: Bool
  , master :: Maybe Element
  , focus :: Bool
  }

-- | What a row tells the editor: its header was clicked (to open or close
-- it), or Ctrl+Z ('True') or Ctrl+Y ('False') was pressed on it, which
-- are the editor's undo and redo.
data Output
  = Toggled RowKey
  | History Bool

data State = State
  { input :: Input
  , host :: H.RefLabel
  , attached :: Bool
  }

data Action
  = Sync
  | Receive Input
  | Gone
  | Clicked
  | Pressed Bool

component :: forall query m. (MonadIO m, MonadUUID m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> (\host -> State {input, host, attached = False}) <$> H.newRefLabel "slide-row-host"
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Sync
              , H.receive = Just . Receive
              , H.finalize = Just Gone
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      let h = st.input.head
          RowKey k = h.key
          body = "slide-row-body-" <> show k
       in HH.div
            [HP.class_ (HH.ClassName ("slide-row" <> (if st.input.open then " open" else ""))), HP.attr (HH.AttrName "data-fit") (fitName h.fit)]
            [ HH.button
                [ HP.attr (HH.AttrName "type") "button"
                , HP.class_ (HH.ClassName "slide-row-toggle")
                , HP.attr (HH.AttrName "aria-expanded") (if st.input.open then "true" else "false")
                , HP.attr (HH.AttrName "aria-controls") body
                , HP.disabled (isNothing st.input.master)
                , HE.onClick (const Clicked)
                , HE.handler' (EventType "keydown") (fmap Pressed . historyKey)
                ]
                ( [ HH.span [HP.class_ (HH.ClassName "slide-row-number")] [HH.text (maybe "" (\n -> show n <> ".") h.number)]
                  , HH.span [HP.class_ (HH.ClassName "slide-row-title")] [HH.text (titleOf h)]
                  , HH.span [HP.class_ (HH.ClassName ("slide-row-fit slide-fit-" <> fitName h.fit)), HP.attr (HH.AttrName "aria-hidden") "true"] []
                  , HH.span [HP.class_ (HH.ClassName "visually-hidden")] [HH.text (", " <> fitPhrase h)]
                  ]
                    <> [HH.span [HP.class_ (HH.ClassName "slide-row-part")] [HH.text ("part of slide " <> show n)] | Just n <- [h.partOf]]
                    <> [HH.span [HP.class_ (HH.ClassName "slide-row-problems")] [HH.text (problemsPhrase h.problems)] | h.problems > 0]
                )
            , HH.div [HP.class_ (HH.ClassName "slide-row-body editor-cm"), HP.id body, HP.ref st.host, HP.hidden (not st.input.open)] []
            ]

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Sync -> sync
      Receive input -> modify (\st -> st {input}) >> sync
      Gone -> gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . detachRow)
      Clicked -> gets (\st -> st.input.head.key) >>= H.raise . Toggled
      Pressed undoing -> H.raise (History undoing)

    -- The row's CodeMirror put in while the row is open and the master is
    -- there, and let go of when it closes.
    sync :: H.HalogenM State Action Empty Output m ()
    sync = do
      st <- get
      found <- H.getRef st.host
      case (st.input.open, st.attached, st.input.master, found) of
        (True, False, Just master, Just host) -> do
          H.liftEffect (attachRow master host st.input.head.key st.input.focus)
          modify (\s -> s {attached = True})
        (False, True, _, Just host) -> do
          H.liftEffect (detachRow host)
          modify (\s -> s {attached = False})
        _ -> pass

-- | A header's title: the opener's, "(untitled)" for an empty heading, and
-- for text before the first slide, what it is.
titleOf :: Head -> Text
titleOf h
  | h.preamble && isJust h.number = "Before the first heading"
  | h.preamble = "Before the first slide"
  | T.null (T.strip h.title) = "(untitled)"
  | otherwise = h.title

-- | What a header says of its slide's fit, to be read aloud, and of the
-- slide that takes it in.
fitPhrase :: Head -> Text
fitPhrase h = case h.partOf of
  Just n -> "part of slide " <> show n <> " in the presentation"
  Nothing -> case h.fit of
    Fits -> "fits"
    Tight -> "may be cut slightly"
    Overflowing -> "is cut when presented"
    Unmeasured -> "not measured yet"

problemsPhrase :: Int -> Text
problemsPhrase 1 = "1 problem"
problemsPhrase n = show n <> " problems"
