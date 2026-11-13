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
  , titleOf
  , Input (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.List (span, zip3, zip5)
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
import Wiki.App.Editor.Browser (attachRow, detachRow, dragCarries, historyKey, markDragged, moveKey, pointerAfter)
import Wiki.App.Editor.Problems (ProblemRange (..))
import Wiki.Core.SlideRows (Row (..), RowKey (..), Rows (..), rowHeading, rowLines, rowStarts, swallowed)
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
heads text rows spans fits problems = [headOf i row opener line count | (i, row, opener, line, count) <- zip5 [0 :: Int ..] rows.rows openers startLines counts]
  where
    -- Each row read once, and the whole text walked once: this runs after
    -- every pause in the typing, on the page's one thread, so its time
    -- must grow with the text's length and no faster.
    openers = map rowHeading rows.rows
    starts = rowStarts rows
    ends = drop 1 starts <> [T.length text]
    startLines = rowLines rows
    -- The problems that start in each row: a problem at the text's very
    -- end is the last row's.
    counts = countIn (zip starts ends) (sort [p.from | p <- problems])
    countIn ranges froms = case ranges of
      [] -> []
      (s, e) : rest ->
        let (inside, after) = span (\f -> f < e || (e == T.length text && f == e)) (dropWhile (< s) froms)
         in length inside : countIn rest after
    taken = Map.fromList (swallowed rows)
    fitAt = Map.fromList [(sp.from, f) | (sp, f) <- zip spans fits]
    preambleIsSlide = any (isNothing . (\sp -> sp.level)) spans
    numbered = Map.fromList (numbers 0 (zip3 [0 :: Int ..] rows.rows openers))
    numbers n = \case
      [] -> []
      (i, _, opener) : rest
        | Map.member i taken -> numbers n rest
        | isJust opener || (i == 0 && preambleIsSlide) -> (i, n + 1) : numbers (n + 1) rest
        | otherwise -> numbers n rest
    headOf i row opener line count =
      Head
        { key = row.key
        , number = Map.lookup i numbered
        , title = maybe "" snd opener
        , preamble = isNothing opener
        , fit = if Map.member i taken then Unmeasured else fromMaybe Unmeasured (Map.lookup line fitAt)
        , partOf = Map.lookup i taken >>= (`Map.lookup` numbered)
        , problems = count
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
  , movable :: Bool
  -- ^ Whether the row can be moved and deleted: not one of the rows that
  -- stay first ('Wiki.Core.SlideRows.fixedRows').
  , dropMark :: Maybe Bool
  -- ^ Where a row dragged over this one would go: before it ('False') or
  -- after it ('True'), drawn as a line.
  }

-- | What a row tells the editor: its header was clicked (to open or close
-- it); Ctrl+Z ('True') or Ctrl+Y ('False') was pressed on its header,
-- which are the editor's undo and redo; Alt+Up (-1) or Alt+Down (1) was
-- pressed on its header or its handle; its delete button or its "+" (a new
-- slide after it) was pressed; its handle started a drag; a drag is over
-- it, in its upper half or its lower one ('True'), or dropped there; or
-- the drag ended.
data Output
  = Toggled RowKey
  | History Bool
  | Moved RowKey Int
  | Deleted RowKey
  | AddedAfter RowKey
  | DragStarted RowKey
  | DraggedOver RowKey Bool
  | DroppedOn RowKey Bool
  | DragEnded

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
  | MoveBy Int
  | Delete
  | AddAfter
  | DragStart
  | DragOver Bool
  | Drop Bool
  | DragEnd

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
          number = maybe "" (\n -> " " <> show n) h.number
          ready = isJust st.input.master
          movable = st.input.movable && ready
       in HH.div
            ( [ HP.class_ (HH.ClassName ("slide-row" <> (if st.input.open then " open" else "") <> dropClass st.input.dropMark))
              , HP.attr (HH.AttrName "data-fit") (fitName h.fit)
              , HP.attr (HH.AttrName "data-row-key") (show k)
              ]
                <> if ready
                  then
                    [ HE.preventingDefault (HE.handler' (EventType "dragover") (\ev -> if dragCarries slideType ev then Just (DragOver (pointerAfter ev)) else Nothing))
                    , HE.preventingDefault (HE.handler' (EventType "drop") (\ev -> if dragCarries slideType ev then Just (Drop (pointerAfter ev)) else Nothing))
                    ]
                  else []
            )
            -- One card: its header, the first line, holds the handle (or a
            -- blank of its width in a row that does not move), the button
            -- that opens the row (the chevron, the number, the title, and at
            -- the right what is said of the slide and its fit), and the
            -- delete button (or a blank of its width), so that the rows'
            -- numbers, titles and fit dots stand in columns. The body is
            -- the rest of the card. The "+" hangs in the gap below it.
            [ HH.div
                [HP.class_ (HH.ClassName "slide-row-head")]
                ( [ if movable
                      then
                        HH.span
                          [ HP.class_ (HH.ClassName "slide-row-handle")
                          , HP.attr (HH.AttrName "draggable") "true"
                          , HP.attr (HH.AttrName "role") "button"
                          , HP.attr (HH.AttrName "tabindex") "0"
                          , HP.attr (HH.AttrName "aria-label") ("Move slide" <> number <> " (Alt+Up, Alt+Down)")
                          , HP.attr (HH.AttrName "title") "Drag to move, or Alt+Up and Alt+Down"
                          , HE.handler' (EventType "dragstart") (\ev -> if markDragged ev h.key then Just DragStart else Just DragStart)
                          , HE.handler' (EventType "dragend") (const (Just DragEnd))
                          , HE.preventingDefault (HE.handler' (EventType "keydown") (\ev -> (Pressed <$> historyKey ev) <|> (MoveBy <$> moveKey ev)))
                          ]
                          [HH.text "\x2807"]
                      else blank "slide-row-handle-space"
                  , HH.button
                      [ HP.attr (HH.AttrName "type") "button"
                      , HP.class_ (HH.ClassName "slide-row-toggle")
                      , HP.attr (HH.AttrName "aria-expanded") (if st.input.open then "true" else "false")
                      , HP.attr (HH.AttrName "aria-controls") body
                      , HP.disabled (not ready)
                      , HE.onClick (const Clicked)
                      , HE.preventingDefault (HE.handler' (EventType "keydown") (\ev -> (Pressed <$> historyKey ev) <|> (if st.input.movable then MoveBy <$> moveKey ev else Nothing)))
                      ]
                      ( [ HH.span [HP.class_ (HH.ClassName "slide-row-number")] [HH.text (maybe "" (\n -> show n <> ".") h.number)]
                        , HH.span [HP.class_ (HH.ClassName "slide-row-title"), HP.id ("slide-row-title-" <> show k)] [HH.text (titleOf h)]
                        ]
                          <> [HH.span [HP.class_ (HH.ClassName "slide-row-part")] [HH.text ("part of slide " <> show n)] | Just n <- [h.partOf]]
                          <> [HH.span [HP.class_ (HH.ClassName "slide-row-problems")] [HH.text (problemsPhrase h.problems)] | h.problems > 0]
                          <> [ -- Where a search's matches in the slide will be told.
                               HH.span [HP.class_ (HH.ClassName "slide-row-matches")] []
                             , HH.span [HP.class_ (HH.ClassName ("slide-row-fit slide-fit-" <> fitName h.fit)), HP.attr (HH.AttrName "aria-hidden") "true"] []
                             , HH.span [HP.class_ (HH.ClassName "visually-hidden")] [HH.text (", " <> fitPhrase h)]
                             ]
                      )
                  , if movable
                      then
                        HH.button
                          [ HP.attr (HH.AttrName "type") "button"
                          , HP.class_ (HH.ClassName "slide-row-delete")
                          , HP.attr (HH.AttrName "aria-label") ("Delete slide" <> number)
                          , HP.attr (HH.AttrName "title") "Delete this slide (Ctrl+Z brings it back)"
                          , HE.onClick (const Delete)
                          ]
                          [HH.text "\x00d7"]
                      else blank "slide-row-delete-space"
                  ]
                )
            , HH.div [HP.class_ (HH.ClassName "slide-row-body editor-cm"), HP.id body, HP.ref st.host, HP.hidden (not st.input.open)] []
            , HH.button
                [ HP.attr (HH.AttrName "type") "button"
                , HP.class_ (HH.ClassName "slide-row-add")
                , HP.attr (HH.AttrName "aria-label") ("New slide after slide" <> number)
                , HP.attr (HH.AttrName "title") "A new slide after this one"
                , HP.disabled (not ready)
                , HE.onClick (const AddAfter)
                ]
                [HH.text "+"]
            ]
      where
        -- The room of a control a row does not have.
        blank name = HH.span [HP.class_ (HH.ClassName name), HP.attr (HH.AttrName "aria-hidden") "true"] []

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Sync -> sync
      -- The editor renders its rows again at each of its own changes, a
      -- keystroke's too: a row whose input is the same does nothing.
      Receive input -> do
        old <- gets (\st -> st.input)
        unless (same old input) $ modify (\st -> st {input}) >> sync
      Gone -> gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . detachRow)
      Clicked -> gets (\st -> st.input.head.key) >>= H.raise . Toggled
      Pressed undoing -> H.raise (History undoing)
      MoveBy by -> key >>= \k -> H.raise (Moved k by)
      Delete -> key >>= H.raise . Deleted
      AddAfter -> key >>= H.raise . AddedAfter
      DragStart -> key >>= H.raise . DragStarted
      DragOver after -> do
        k <- key
        mark <- gets (\st -> st.input.dropMark)
        unless (mark == Just after) $ H.raise (DraggedOver k after)
      Drop after -> key >>= \k -> H.raise (DroppedOn k after)
      DragEnd -> H.raise DragEnded

    key :: H.HalogenM State Action Empty Output m RowKey
    key = gets (\st -> st.input.head.key)

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

-- | Whether two inputs of a row show the same: the master compared only by
-- whether it is there, which it is from one load to the next.
same :: Input -> Input -> Bool
same a b = a.head == b.head && a.open == b.open && a.focus == b.focus && isJust a.master == isJust b.master && a.movable == b.movable && a.dropMark == b.dropMark

-- | The class of the line a dragged row would be dropped at.
dropClass :: Maybe Bool -> Text
dropClass = \case
  Nothing -> ""
  Just False -> " drop-before"
  Just True -> " drop-after"

-- | The type of a drag's data that a slide's row carries.
slideType :: Text
slideType = "application/x-wiki-slide"

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
