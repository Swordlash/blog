-- | 'Model' is the threads of one page as the page view shows them
-- ("Wiki.App.View.Page", with "Wiki.App.View.Comments" drawing them), and
-- 'step' is the one place they change (WP5.121 of docs/PLAN.md, decision
-- 82). Every input is an 'Event': the page view showing a page or going
-- elsewhere, the answer to a read of the threads, a message of the live
-- channel about the page, a write the reader asked for in the comments
-- view, and its answer. Every output is an 'Effect': read the threads,
-- send a write, or look up the people they mention.
--
-- = Where it sits
--
-- The model is a part of the page view's state, stepped by its own
-- events: the page view turns what concerns the threads (its fetch taken,
-- a change of route, the feed's messages about the page, a write the
-- comments view asks for) into events, runs 'step' in one step of its
-- program, and carries out the effects; a read or a write is forked and
-- its answer comes back as one more event. The rest of the page view (its
-- fetch, the ticks, the chain's check, the people, the avatars) is as it
-- was. The comments view holds what is being written, asks for a write
-- ('Write'), and is told its answer by the page view.
--
-- The rules here are the page view's as they were before the machine,
-- unchanged: an answer to a read of the threads is taken only if no answer
-- to a later read was ("Wiki.App.View.Latest"), and only for the page
-- shown; the subscription's answer puts every read out behind it; an
-- event of the live channel and a write's result are applied to the
-- threads shown.
module Wiki.App.View.Comments.Machine
  ( Model (..)
  , Threads (..)
  , Request (..)
  , Event (..)
  , Effect (..)
  , initial
  , step
  , readyThreads
  )
where

import Data.Map.Strict qualified as Map
import Protolude hiding (State)
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.App.Backend (WikiError)
import Wiki.App.View.Latest (Ask, Asks, madeAfter, newAsk, noAsks, stillAnswerable, supersede, takes)
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Comment (Thread)
import Wiki.Core.Id (CommentId, CommentThreadId, PageId)

-- | A page's threads, as far as they have been read.
data Threads
  = ThreadsLoading
  | ThreadsFailed WikiError
  | ThreadsReady [Thread]
  deriving stock (Eq, Show)

-- | 'Model' is what the page view knows of the threads of the page it
-- shows.
data Model = Model
  { page :: Maybe PageId
  -- ^ The page shown, whose threads these are; 'Nothing' while the page
  -- view has none.
  , comments :: Bool
  -- ^ Whether the page shown has comments: not a home page, nor an older
  -- version ("Wiki.App.View.Page"'s @commentsHere@).
  , encrypted :: Bool
  -- ^ Whether the page is in an encrypted space: the live channel then
  -- tells only that its threads changed, and they are read again.
  , threads :: Threads
  , asks :: Asks
  -- ^ The reads of the threads made, and which one's answer is shown.
  , written :: Int
  -- ^ How many writes were sent: the number of the latest.
  , writes :: Map Int PageId
  -- ^ The writes sent on this visit of the page that have not been
  -- answered, by number, with the page each is for.
  , heard :: [(PageEvent, Asks)]
  -- ^ What the live channel told on this visit, the newest first, with
  -- the reads as they were then, while a read is out whose answer may be
  -- older ('taking').
  , closed :: Bool
  -- ^ Whether the page view has gone away: after that nothing changes and
  -- nothing is asked.
  }
  deriving stock (Eq, Show)

-- | 'Request' is a write to a page's threads that the reader asks for in
-- the comments view.
data Request
  = -- | Open a thread, about a quote of the page or about the whole page,
    -- with its first comment.
    OpenThread (Maybe Anchor) Text
  | Reply CommentThreadId Text
  | EditComment CommentThreadId CommentId Text
  | -- | Delete a comment. The only comment of a thread stands for the
    -- thread.
    DeleteComment CommentThreadId CommentId
  | DeleteThread CommentThreadId
  | -- | Resolve a thread about a quote, or reopen it.
    Resolve CommentThreadId Bool
  deriving stock (Eq, Show)

-- | 'Event' is everything that happens to the threads shown. A write is
-- asked for from a place @a@ (the comments view that asked), which its
-- 'Send' carries back.
data Event a
  = -- | The page view is mounted.
    Started
  | -- | The page view goes away.
    Finished
  | -- | The page view took a page it fetched (a new page, or the page
    -- shown read again): whether it has comments, and whether it is in an
    -- encrypted space.
    Fetched PageId Bool Bool
  | -- | The page view went to another page or version: nothing is shown
    -- until it is fetched.
    Left'
  | -- | The answer to the read made under this ticket, for this page.
    Loaded Ask PageId (Either WikiError [Thread])
  | -- | The reader asked for a write to this page's threads.
    Write a PageId Request
  | -- | The answer to the write sent under this number: the event the
    -- write made, or why it failed.
    Wrote Int (Either WikiError PageEvent)
  | -- | The live channel's event on a page.
    Heard PageId PageEvent
  | -- | The live channel's answer to the page's subscription: its threads
    -- as they are now.
    Replaced PageId [Thread]
  | -- | The reader asked to read the threads again (after a failure).
    Reload
  deriving stock (Eq, Show)

-- | 'Effect' is what a step asks the page view to do.
data Effect a
  = -- | Read the page's threads; the answer comes back as 'Loaded'.
    Load Ask PageId
  | -- | Send this write under this number. The answer comes back as
    -- 'Wrote', and the page view tells it to the comments view that asked.
    Send a Int PageId Request
  | -- | The threads shown changed: look up the people they mention.
    Changed
  deriving stock (Eq, Show)

-- | The threads before the page view is mounted: for the page it shows, if
-- any, with whether it has comments and is encrypted, and the threads
-- read at once if the backend could.
initial :: Maybe PageId -> Bool -> Bool -> Maybe (Either WikiError [Thread]) -> Model
initial page comments encrypted read' =
  Model {page, comments, encrypted, threads = maybe ThreadsLoading (either ThreadsFailed ThreadsReady) (read' >>= \r -> r <$ guard comments), asks = noAsks, written = 0, writes = mempty, heard = [], closed = False}

-- | The threads after an event, and what the page view is asked to do.
step :: Event a -> Model -> (Model, [Effect a])
step event m
  | m.closed = (m, [])
  | otherwise = case event of
      Started -> case m.threads of
        ThreadsLoading -> reading m
        _ -> (m, [])
      Finished -> (m {closed = True}, [])
      -- Another page is another visit: the answers to the writes sent on
      -- the last one are not taken.
      Fetched page comments encrypted ->
        reading (if m.page == Just page then m {comments, encrypted} else m {page = Just page, comments, encrypted, writes = mempty, heard = []})
      Left' -> (m {page = Nothing, threads = ThreadsLoading, asks = supersede m.asks, writes = mempty, heard = []}, [])
      -- The ticket is taken whichever page the answer is for; its threads
      -- only for the page shown.
      Loaded asked page answer -> case takes asked m.asks of
        Just after -> (taking asked page answer m {asks = after}, [Changed])
        Nothing -> (m, [Changed])
      Write place page request ->
        let n = m.written + 1
         in (m {written = n, writes = if m.page == Just page then Map.insert n page m.writes else m.writes}, [Send place n page request])
      -- The answer to a write is taken only on the visit of the page it was
      -- sent on.
      Wrote n answer -> case (Map.lookup n m.writes, answer) of
        (Just page, Right e) | m.page == Just page -> (m {writes = Map.delete n m.writes, threads = applied e m.threads}, [Changed])
        _ -> (m {writes = Map.delete n m.writes}, [])
      Heard page e
        | m.page /= Just page -> (m, [])
        | e == ThreadsChanged -> reading m
        | otherwise -> (m {threads = applied e m.threads, heard = heardNow e m}, [Changed])
      Replaced page ts
        | m.page /= Just page -> (m, [])
        | m.encrypted -> reading m
        | otherwise -> (m {threads = ThreadsReady ts, asks = supersede m.asks, heard = []}, [Changed])
      Reload -> reading m

-- | The answer to a read taken: for the page shown, its threads, with
-- what the live channel told since the read was asked applied again, in
-- the order told. The answer may have been read before or after each of
-- those changes was made, and nothing in it says which. Applied again, an
-- addition the answer holds is kept as the answer has it, a deletion is
-- one again, and an edit or a resolution is as told, which a later one
-- still on its way corrects. A failure is shown only where no threads are:
-- threads shown are kept, and the next read, or the channel, brings what
-- they lack.
taking :: Ask -> PageId -> Either WikiError [Thread] -> Model -> Model
taking asked page answer m
  | m.page /= Just page = m'
  | otherwise = case (answer, m.threads) of
      (Right ts, _) -> m' {threads = ThreadsReady (foldr applyEvent ts [e | (e, at) <- m.heard, not (asked `madeAfter` at)])}
      (Left _, ThreadsReady _) -> m'
      (Left e, _) -> m' {threads = ThreadsFailed e}
  where
    m' = m {heard = stillWanted m.asks m.heard}

-- | The channel's event kept, if a read is out whose answer it may be newer
-- than.
heardNow :: PageEvent -> Model -> [(PageEvent, Asks)]
heardNow e m = stillWanted m.asks ((e, m.asks) : m.heard)

-- | What the channel told that an answer still to be taken may be older
-- than: told while a read whose answer can still be taken was out.
stillWanted :: Asks -> [(PageEvent, Asks)] -> [(PageEvent, Asks)]
stillWanted now = filter (\(_, at) -> stillAnswerable at now)

-- | A read of the threads begun, for the page shown. A page with no
-- comments has none, at once, under its own ticket.
reading :: Model -> (Model, [Effect a])
reading m = case m.page of
  Nothing -> (m, [])
  Just page
    | m.comments -> (m {asks = after}, [Load ticket page])
    | otherwise -> case takes ticket after of
        Just taken -> (m {asks = taken, threads = ThreadsReady []}, [Changed])
        Nothing -> (m {asks = after}, [])
    where
      (ticket, after) = newAsk m.asks

-- | The threads after an event, if they are read.
applied :: PageEvent -> Threads -> Threads
applied e = \case
  ThreadsReady ts -> ThreadsReady (applyEvent e ts)
  other -> other

-- | The threads shown, if they are read.
readyThreads :: Model -> [Thread]
readyThreads m = case m.threads of
  ThreadsReady ts -> ts
  _ -> []
