-- | 'Staging' is what the page view ("Wiki.App.View.Page") holds of a
-- page's ticks not saved yet (WP5.91 of docs/PLAN.md): the page they were
-- made on, its tasks, the ticks, the text with them written in, and what
-- the bar says about them. Every change to it is a 'step' on an 'Event',
-- so the rules that keep the reader's ticks are here, in pure code, and
-- tested on sequences of events.
--
-- = The invariant
--
-- Unsaved ticks leave the staging only through 'cleared', for one of the
-- reasons of 'Clearing':
--
-- * a save that succeeded and belongs to this visit of the page
--   ('SavedHere', by the event 'Saved');
-- * "Discard" ('Discarded');
-- * a route away that the reader confirmed when the shell asked
--   ('LeftConfirmed');
-- * a reload the reader asked for after the bar said it loses them
--   ('ReloadConfirmed');
-- * the reader no longer allowed to edit the page, or signed out, which
--   the bar says ('MayNoLongerEdit').
--
-- Nothing else drops them. A page fetched again ('Offered') keeps them:
-- moved onto it when it has the same tasks, or, when it has not, kept on
-- the page shown, which stays, with the bar offering the reload. A
-- failure ('Problem') is said and changes nothing else. A click the
-- staging cannot take leaves the ticks as they were.
module Wiki.App.View.Ticking
  ( Staging (..)
  , TickNote (..)
  , Clearing (..)
  , Event (..)
  , unstaged
  , step
  , boxState
  )
where

import Data.Map.Strict qualified as Map
import Protolude
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Markdown.Tasks (Task (..), Ticks, allTasks, applyTicks, rebaseTicks, tasksOf, tick, tickErrorText)
import Wiki.Core.Page (Page (body, id))

-- | 'Staging' is the page view's ticks not saved yet, with the page they
-- were made on.
data Staging = Staging
  { page :: Maybe Page
  -- ^ The page shown, the base the ticks were made on and are saved
  -- against. 'Nothing' until a page is shown.
  , tasks :: [Task]
  -- ^ The page's tasks, which a tick's rules walk.
  , ticks :: Ticks
  -- ^ The states the reader gave the page's tasks, where they differ from
  -- its text: what "Save" would change.
  , shown :: Text
  -- ^ The page's text with the ticks written in: what the page shows, and
  -- what "Save" saves.
  , saving :: Bool
  -- ^ Whether a save of the ticks is under way.
  , note :: Maybe TickNote
  -- ^ What the bar says happened to the ticks, if anything did.
  , drawn :: Map Int Int
  -- ^ How many times each task's box was drawn anew, by the task's
  -- index: after a click the staging did not take, the box is a new
  -- element showing the state it has ("Wiki.Core.Markdown.Render"'s
  -- 'Md.taskDrawn').
  }
  deriving stock (Eq, Show)

-- | 'TickNote' is what the bar of unsaved ticks says happened to them.
data TickNote
  = -- | The page was saved since the ticks were made, and has the same
    -- tasks: the ticks are kept on the new text, not saved yet.
    KeptOnNewer
  | -- | The page was saved elsewhere and its tasks are not the same: the
    -- ticks stay on the page shown, and cannot be saved on the new one.
    TasksChanged
  | -- | The ticks were dropped, for the reason given.
    Dropped Text
  | -- | Something went wrong (a write or a fetch failed): what. Nothing
    -- was lost.
    TickProblem Text
  deriving stock (Eq, Show)

-- | 'Clearing' is why ticks may leave the staging: the only reasons there
-- are (the module's Haddock).
data Clearing
  = -- | The reader chose "Discard".
    Discarded
  | -- | The shell asked before a route away, and the reader chose Leave.
    LeftConfirmed
  | -- | The bar said a reload loses the ticks, and the reader asked for it.
    ReloadConfirmed
  | -- | The reader may no longer edit the page (their rights changed, or
    -- they signed out).
    MayNoLongerEdit
  deriving stock (Eq, Show, Enum, Bounded)

-- | 'Event' is what happens to the page view that concerns its ticks.
data Event
  = -- | The reader set a task's box (by its index), which was enabled.
    Clicked Int Bool
  | -- | The reader clicked a task's box the view does not take now: the
    -- box is drawn anew with the state it has.
    Refused Int
  | -- | A save of the ticks began.
    Saving
  | -- | This visit's save of the ticks succeeded: the page as saved.
    Saved Page
  | -- | This visit's save met a newer version of the page: nothing was
    -- saved, and the page as it is now is fetched next.
    Conflicted
  | -- | This visit's save failed otherwise: why. Nothing was saved.
    SaveFailed Text
  | -- | The page as fetched now, for this visit of it.
    Offered Page
  | -- | Something else failed (a fetch): what.
    Problem Text
  | -- | The ticks leave the staging, for this reason.
    Clear Clearing
  | -- | The reader dismissed what the bar said.
    Dismissed
  deriving stock (Eq, Show)

-- | No page and no ticks: a view that has not shown its page yet.
unstaged :: Staging
unstaged = Staging {page = Nothing, tasks = [], ticks = mempty, shown = "", saving = False, note = Nothing, drawn = mempty}

-- | The staging after an event.
step :: Event -> Staging -> Staging
step event s = case event of
  Clicked i v -> case s.page of
    Nothing -> redrawn i v s
    Just p -> redrawn i v $ case applyTicks (tick s.tasks s.ticks i v) p.body of
      Right shown -> s {ticks = tick s.tasks s.ticks i v, shown, note = mfilter (not . problem) s.note}
      Left e -> s {note = Just (TickProblem (tickErrorText e))}
  Refused i -> s {drawn = Map.insertWith (+) i 1 s.drawn}
  Saving -> s {saving = True, note = Nothing}
  Saved p -> cleared Nothing s {page = Just p, tasks = tasksIn p.body}
  Conflicted -> s {saving = False}
  SaveFailed why -> s {saving = False, note = Just (TickProblem why)}
  Offered p
    | Map.null s.ticks -> shownAs p s
    | Just old <- s.page, old == p -> s
    -- The same text (the page made a template, or the reload of another
    -- change): the ticks as they are.
    | Just old <- s.page, old.id == p.id, old.body == p.body -> shownAs p s
    | Just old <- s.page
    , old.id == p.id
    , Just moved <- rebaseTicks s.tasks (tasksIn p.body) s.ticks
    , Right shown <- applyTicks moved p.body ->
        (shownAs p s {ticks = moved}) {shown, note = Just KeptOnNewer}
    | otherwise -> s {note = Just TasksChanged}
  Problem why -> s {note = Just (TickProblem why)}
  Clear why -> cleared (Just why) s
  Dismissed -> s {note = Nothing}
  where
    problem = \case
      TickProblem _ -> True
      _ -> False
    -- A box clicked whose state is not the one clicked after the step is
    -- drawn anew.
    redrawn i v after
      | boxState after i == Just v = after
      | otherwise = after {drawn = Map.insertWith (+) i 1 after.drawn}

-- | The one place ticks leave the staging: for a reason of 'Clearing', or
-- for a save of this visit that succeeded ('Nothing'). Leaving the page
-- forgets the page too; the others keep it, with its text as it is.
cleared :: Maybe Clearing -> Staging -> Staging
cleared why s = case why of
  Just LeftConfirmed -> unstaged
  Just MayNoLongerEdit
    | not (Map.null s.ticks) -> plain {note = Just (Dropped ("You may no longer edit this page, so " <> were <> " dropped."))}
  _ -> plain {note = Nothing}
  where
    plain = s {ticks = mempty, shown = maybe "" (\p -> p.body) s.page, saving = False}
    count = Map.size s.ticks
    were = if count == 1 then "your tick was" else "your " <> show count <> " ticks were"

-- | The staging showing this page, with ticks that are already the
-- page's (none, or those moved onto it): its text with them written in.
shownAs :: Page -> Staging -> Staging
shownAs p s = s {page = Just p, tasks = tasksIn p.body, shown = either (const p.body) identity (applyTicks s.ticks p.body)}

-- | The state the staging gives the task with this index: its tick, or
-- else its page's text's. 'Nothing' for an index the page has no task of.
boxState :: Staging -> Int -> Maybe Bool
boxState s i = Map.lookup i s.ticks <|> head [t.done | t <- allTasks s.tasks, t.index == i]

-- | The tasks of a page's text, none if it cannot be parsed.
tasksIn :: Text -> [Task]
tasksIn = either (const []) tasksOf . Md.parseMarkdown
