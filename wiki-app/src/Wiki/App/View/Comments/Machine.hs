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

import Protolude hiding (State)
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.App.Backend (WikiError)
import Wiki.App.View.Latest (Ask, Asks, newAsk, noAsks, supersede, takes)
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
  Model {page, comments, encrypted, threads = maybe ThreadsLoading (either ThreadsFailed ThreadsReady) (read' >>= \r -> r <$ guard comments), asks = noAsks, written = 0, closed = False}

-- | The threads after an event, and what the page view is asked to do.
step :: Event a -> Model -> (Model, [Effect a])
step event m
  | m.closed = (m, [])
  | otherwise = case event of
      Started -> case m.threads of
        ThreadsLoading -> reading m
        _ -> (m, [])
      Finished -> (m {closed = True}, [])
      Fetched page comments encrypted -> reading m {page = Just page, comments, encrypted}
      Left' -> (m {page = Nothing, threads = ThreadsLoading, asks = supersede m.asks}, [])
      -- The ticket is taken whichever page the answer is for; its threads
      -- only for the page shown.
      Loaded asked page answer -> case takes asked m.asks of
        Just after -> (m {asks = after, threads = if m.page == Just page then either ThreadsFailed ThreadsReady answer else m.threads}, [Changed])
        Nothing -> (m, [Changed])
      Write place page request -> let n = m.written + 1 in (m {written = n}, [Send place n page request])
      Wrote _ (Right e) -> (m {threads = applied e m.threads}, [Changed])
      Wrote _ (Left _) -> (m, [])
      Heard page e
        | m.page /= Just page -> (m, [])
        | e == ThreadsChanged -> reading m
        | otherwise -> (m {threads = applied e m.threads}, [Changed])
      Replaced page ts
        | m.page /= Just page -> (m, [])
        | m.encrypted -> reading m
        | otherwise -> (m {threads = ThreadsReady ts, asks = supersede m.asks}, [Changed])
      Reload -> reading m

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
