-- | 'Model' is what the viewer of a presentation in a page
-- ("Wiki.App.View.DeckViewer") knows, and 'step' is the one place it
-- changes (WP5.121 of docs/PLAN.md, decision 82). Every input is an
-- 'Event': the viewer started or closed, a new input, the link rendered,
-- the link come near the window, the answer to a read of the embedded
-- page, a move through the slides. Every output is an 'Effect': watch the
-- link, stop a watch, read the page, let go of a read's addresses.
--
-- = Where it sits
--
-- The model is the viewer's state; the component runs 'step' in one step
-- of its program and carries out the effects. The handles the effects make
-- (the browser's watch, the callback it tells through, the owner a read's
-- addresses are made under) are kept by the component under the numbers
-- the model gives them; whether a watch runs, which reads are out and
-- whose addresses are shown are the model's.
--
-- The rules are main's as they were, translated without a change, but for
-- two guards taken out to show the races they closed: a watch is started
-- whenever one is asked for, and the answer to a read is taken whatever
-- reading it was made for.
module Wiki.App.View.DeckViewer.Machine
  ( Model (..)
  , Reading (..)
  , Target (..)
  , Loaded (..)
  , Move (..)
  , Event (..)
  , Effect (..)
  , initial
  , step
  , stepsAt
  )
where

import Data.Map.Strict qualified as Map
import Protolude hiding (First, Last)
import Wiki.Core.Slides (Deck (..), Slide (..))

-- | 'Reading' is what one reading of an embedded page is for: a session of
-- the reader's, a revision of the shell, and the page named. A change of
-- any of them is another reading: what was read for one is not shown for
-- the other.
data Reading s l = Reading
  { session :: s
  , revision :: Int
  , link :: l
  }
  deriving stock (Eq, Show)

-- | What the viewer shows: an embedded page, read for a reading, with what
-- a read needs from the page that embeds it (@h@); or the page view's own
-- presentation (@x@, its deck).
data Target s l h x
  = Linked (Reading s l) h
  | Shown (Loaded x)
  deriving stock (Show)

-- | What the viewer has: the link, or a presentation to show, with its
-- deck.
data Loaded x = Link | Ready x Deck
  deriving stock (Eq, Show)

-- | A move through the deck's steps.
data Move = First | Back | Forward | Last
  deriving stock (Eq, Show, Enum, Bounded)

-- | 'Model' is what the viewer knows.
data Model s l h x = Model
  { target :: Target s l h x
  , generation :: Int
  -- ^ How many times what the viewer shows was dropped for another
  -- reading.
  , loaded :: Loaded x
  , current :: Int
  -- ^ The slide shown, from 1.
  , shownStep :: Int
  -- ^ Its step shown, from 1.
  , watching :: Maybe Int
  -- ^ The watch of the link coming near the window, by number, while it
  -- runs.
  , watches :: Int
  -- ^ How many watches were started: the number of the latest.
  , fetches :: Map Int Int
  -- ^ The reads of the embedded page out, by number, with the generation
  -- each was made in.
  , fetched :: Int
  -- ^ How many reads were made: the number of the latest.
  , shownOwner :: Maybe Int
  -- ^ The read whose addresses (of the page's attachments) are the ones
  -- shown.
  , pendingOwners :: [Int]
  -- ^ The reads out whose addresses are being made.
  , closed :: Bool
  }
  deriving stock (Show)

-- | 'Event' is everything that happens to the viewer.
data Event s l h x
  = -- | The viewer is mounted, its first render done.
    Started
  | -- | The viewer goes away.
    Finished
  | -- | A new input.
    Received (Target s l h x)
  | -- | The link is rendered after a change of reading: it can be watched.
    Rendered
  | -- | The watch under this number told that the link came near the
    -- window.
    Near Int
  | -- | The answer to the read under this number: a presentation the
    -- reader may read, or 'Nothing' for the link.
    Fetched Int (Maybe (x, Deck))
  | -- | The reader moved through the slides.
    Go Move
  deriving stock (Show)

-- | 'Effect' is what a step asks the component to do. None of them waits.
data Effect l h
  = -- | Watch the link under this number, telling the number.
    Watch Int
  | -- | Stop the watch under this number.
    Unwatch Int
  | -- | Read the page named, under this number, with an owner of its own
    -- for its addresses; the answer comes back as 'Fetched'.
    Fetch Int l h
  | -- | Let go of the addresses made under this read's owner.
    Release Int
  | -- | Tell 'Rendered' once the link is rendered: in the action after
    -- this one, when the element the viewer's ref holds is the link's.
    WhenRendered
  deriving stock (Eq, Show)

-- | The viewer before it starts: the page view's presentation shown at
-- once, an embedded page as its link.
initial :: Target s l h x -> Model s l h x
initial target =
  Model {target, generation = 0, loaded = shownOf target, current = 1, shownStep = 1, watching = Nothing, watches = 0, fetches = mempty, fetched = 0, shownOwner = Nothing, pendingOwners = [], closed = False}

-- | The viewer after an event, and what the component is asked to do.
step :: (Eq s, Eq l) => Event s l h x -> Model s l h x -> (Model s l h x, [Effect l h])
step event m
  | m.closed = (m, [])
  | otherwise = case event of
      Started -> watched m
      Finished ->
        let (m', unwatch) = unwatched m
            (m'', release) = released m'
         in (m'' {closed = True}, unwatch <> release)
      Received target -> case (target, m.target) of
        (Shown _, _) -> (clamped m {target, loaded = shownOf target}, [])
        (Linked new _, Linked old _)
          | new == old -> (m {target}, [])
        (Linked _ _, _) ->
          let (m', unwatch) = unwatched m
              (m'', release) = released m'
           in (m'' {target, loaded = Link, current = 1, shownStep = 1, generation = m.generation + 1}, unwatch <> release <> [WhenRendered])
      Rendered -> watched m
      -- Only the watch running is heard: one stopped since may have told
      -- before it was stopped, for an earlier reading.
      Near w
        | m.watching /= Just w -> (m, [])
        | otherwise -> case m.target of
            Linked reading host ->
              let f = m.fetched + 1
               in (m {watching = Nothing, fetched = f, fetches = Map.insert f m.generation m.fetches, pendingOwners = f : m.pendingOwners}, [Fetch f reading.link host])
            Shown _ -> (m {watching = Nothing}, [])
      -- An answer read for an earlier reading is not shown, and its
      -- addresses are let go.
      Fetched f answer
        | Map.lookup f m.fetches == Just m.generation -> settled f True m {fetches = Map.delete f m.fetches, loaded = maybe Link (uncurry Ready) answer}
        | otherwise -> settled f False m {fetches = Map.delete f m.fetches}
      Go move -> (moved move m, [])

-- | The link watched, for an embedded page.
watched :: Model s l h x -> (Model s l h x, [Effect l h])
watched m = case (m.target, m.watching) of
  (Linked _ _, Nothing) -> let w = m.watches + 1 in (m {watching = Just w, watches = w}, [Watch w])
  _ -> (m, [])

-- | The watch running stopped.
unwatched :: Model s l h x -> (Model s l h x, [Effect l h])
unwatched m = (m {watching = Nothing}, [Unwatch w | Just w <- [m.watching]])

-- | Every read's addresses let go: those shown and those being made.
released :: Model s l h x -> (Model s l h x, [Effect l h])
released m = (m {shownOwner = Nothing, pendingOwners = []}, map Release (maybeToList m.shownOwner <> m.pendingOwners))

-- | A read answered: its owner no longer pending. Taken, its addresses are
-- the ones shown and those shown before are let go; dropped, its own are.
settled :: Int -> Bool -> Model s l h x -> (Model s l h x, [Effect l h])
settled f taken m
  | taken = (m {shownOwner = Just f, pendingOwners = pending}, [Release o | Just o <- [m.shownOwner], o /= f])
  | otherwise = (m {pendingOwners = pending}, [Release f])
  where
    pending = filter (/= f) m.pendingOwners

-- | What the viewer has from its target alone.
shownOf :: Target s l h x -> Loaded x
shownOf = \case
  Shown l -> l
  Linked _ _ -> Link

-- | The slide and step shown kept within the deck.
clamped :: Model s l h x -> Model s l h x
clamped m = case m.loaded of
  Ready _ deck ->
    let current = max 1 (min m.current (length deck.slides))
     in m {current, shownStep = max 1 (min m.shownStep (stepsAt deck current))}
  Link -> m

-- | How many steps a slide of a deck has, from 1.
stepsAt :: Deck -> Int -> Int
stepsAt deck n = maybe 1 (\s -> s.steps) (head (drop (n - 1) deck.slides))

-- | The slide and step after a move, within the deck.
moved :: Move -> Model s l h x -> Model s l h x
moved move m = case m.loaded of
  Link -> m
  Ready _ deck ->
    let count = length deck.slides
        (current, shownStep) = case move of
          First -> (1, 1)
          Last -> (count, stepsAt deck count)
          Forward
            | m.shownStep < stepsAt deck m.current -> (m.current, m.shownStep + 1)
            | m.current < count -> (m.current + 1, 1)
            | otherwise -> (m.current, m.shownStep)
          Back
            | m.shownStep > 1 -> (m.current, m.shownStep - 1)
            | m.current > 1 -> (m.current - 1, stepsAt deck (m.current - 1))
            | otherwise -> (m.current, m.shownStep)
     in m {current, shownStep}
