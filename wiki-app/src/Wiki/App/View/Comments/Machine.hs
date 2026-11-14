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
-- = What an answer says
--
-- The machine infers nothing about what an answer covers from what its
-- threads and comments hold: no id, time or order says whether a read's
-- or a write's answer was made before or after a change the live channel
-- told. The live channel tells every change in the order it was made, and
-- its answer to the page's subscription is the threads as they were when
-- it subscribed, before every change it tells after. So:
--
-- * an event the channel tells is applied to the threads shown, a thread
--   or a reply added only when no thread or comment has its id;
-- * the subscription's answer replaces the threads and puts every read out
--   behind it;
-- * a read's answer is taken only if no answer to a later read was
--   ("Wiki.App.View.Latest"), and only for the page shown; what the
--   channel told since the read was asked is applied to it again, in the
--   order told ('taking'). A failed read is shown only where no threads
--   are; threads kept after it are marked behind ('behind'), and the
--   comments view says so, with a button to read them again;
-- * a write's answer is taken only on the visit of the page it was sent
--   on. When the channel told of what it made or changed since it was
--   sent, the threads have it already; otherwise it is applied only when
--   the threads are as they were when it was sent, and a read asked after
--   it follows, which puts it in its place ('wrote'). What the answer does
--   beside the threads is asked by the machine too, and only then: the
--   comments view that asked is told it ('Answered'), and a thread opened
--   about a quote is chosen ('Opened'). The page view carries these out
--   and decides nothing of its own after the wait.
module Wiki.App.View.Comments.Machine
  ( Model (..)
  , Writing (..)
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
import Wiki.Core.Comment (Comment (..), Thread (..))
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
  , writes :: Map Int Writing
  -- ^ The writes sent on this visit of the page that have not been
  -- answered, by number.
  , heard :: [(PageEvent, Asks)]
  -- ^ What the live channel told on this visit, the newest first, with
  -- the reads as they were then, while a read is out whose answer may be
  -- older ('taking').
  , following :: Maybe Ask
  -- ^ The read asked after a write's answer, while it is out.
  , writtenSince :: Bool
  -- ^ Whether another write was answered after that read was asked: one
  -- more read follows when its answer comes.
  , behind :: Bool
  -- ^ Whether the threads shown are known to be behind the server's: a
  -- read whose answer was needed failed, and no read's or subscription's
  -- answer was taken since. The comments view says so, with a button to
  -- read them again.
  , closed :: Bool
  -- ^ Whether the page view has gone away: after that nothing changes and
  -- nothing is asked.
  }
  deriving stock (Eq, Show)

-- | 'Writing' is a write sent on this visit of the page, until its answer
-- comes.
data Writing = Writing
  { page :: PageId
  , told :: [PageEvent]
  -- ^ What the live channel told about the page since the write was sent.
  , quiet :: Bool
  -- ^ Whether the threads shown are as they were when the write was sent:
  -- nothing told, no read's answer taken, no subscription answered.
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
  | -- | The answer to the write sent under this number, from the place
    -- that asked for it ('Send' gives both): the event the write made, or
    -- why it failed.
    Wrote a Int Request (Either WikiError PageEvent)
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
    -- 'Wrote'.
    Send a Int PageId Request
  | -- | Tell the comments view in this place the answer to the write it
    -- asked for: its form emptied, or why the write failed shown. Asked
    -- only on the visit of the page the write was sent on.
    Answered a Request (Maybe WikiError)
  | -- | The write opened this thread about a quote: stop quoting, and
    -- choose the thread. Asked only on the visit of the page the write was
    -- sent on.
    Opened CommentThreadId
  | -- | The threads shown changed: look up the people they mention.
    Changed
  deriving stock (Eq, Show)

-- | The threads before the page view is mounted: for the page it shows, if
-- any, with whether it has comments and is encrypted, and the threads
-- read at once if the backend could.
initial :: Maybe PageId -> Bool -> Bool -> Maybe (Either WikiError [Thread]) -> Model
initial page comments encrypted read' =
  Model {page, comments, encrypted, threads = maybe ThreadsLoading (either ThreadsFailed ThreadsReady) (read' >>= \r -> r <$ guard comments), asks = noAsks, written = 0, writes = mempty, heard = [], following = Nothing, writtenSince = False, behind = False, closed = False}

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
        reading (if m.page == Just page then m {comments, encrypted} else (elsewhere m) {page = Just page, comments, encrypted})
      Left' -> ((elsewhere m) {page = Nothing, threads = ThreadsLoading, asks = supersede m.asks}, [])
      -- The ticket is taken whichever page the answer is for; its threads
      -- only for the page shown.
      Loaded asked page answer -> case takes asked m.asks of
        Just after ->
          let m' = taking asked page answer m {asks = after}
              (m'', fx) = followed asked (if m'.threads /= m.threads then unquiet m' else m')
           in (m'', Changed : fx)
        Nothing -> second (Changed :) (followed asked m)
      Write place page request ->
        let n = m.written + 1
            writing = Writing {page, told = [], quiet = True}
         in (m {written = n, writes = if m.page == Just page then Map.insert n writing m.writes else m.writes}, [Send place n page request])
      -- The answer of a write sent on another visit, of this page or
      -- another, changes nothing and asks nothing: the forms it came from
      -- were emptied when the page changed.
      Wrote place n request answer -> case Map.lookup n m.writes of
        Just w
          | m.page == Just w.page ->
              let (m', fx) = wrote w answer m {writes = Map.delete n m.writes}
               in (m', fx <> [Answered place request (leftToMaybe answer)] <> [Opened t.id | Right (ThreadOpened t) <- [answer], isJust t.anchor])
        _ -> (m {writes = Map.delete n m.writes}, [])
      Heard page e
        | m.page /= Just page -> (m, [])
        | e == ThreadsChanged -> reading m
        | otherwise -> (m {threads = applied e m.threads, heard = heardNow e m, writes = map (\w -> w {told = e : w.told, quiet = False}) m.writes}, [Changed])
      Replaced page ts
        | m.page /= Just page -> (m, [])
        | m.encrypted -> reading m
        | otherwise -> (unquiet m {threads = ThreadsReady ts, asks = supersede m.asks, heard = [], behind = False}, [Changed])
      Reload -> reading m

-- | The model on another visit, or none: what was kept about the last
-- one's reads and writes forgotten.
elsewhere :: Model -> Model
elsewhere m = m {writes = mempty, heard = [], following = Nothing, writtenSince = False, behind = False}

-- | The writes out, with the threads shown changed since they were sent.
unquiet :: Model -> Model
unquiet m = m {writes = map (\w -> w {quiet = False}) m.writes}

-- | The answer to a write sent on this visit, taken. Nothing says where
-- the write's commit falls among what the channel told, so:
--
-- * when the channel told of the thread or the comment the write made or
--   changed since the write was sent ('about'), the threads have it in its
--   place already: nothing more;
-- * otherwise, when the threads shown are as they were when the write was
--   sent, its event is applied, so that the reader sees it at once;
-- * either way, a read asked after the answer follows: its answer was read
--   after the write was made, and it puts the write in its place among
--   what others made meanwhile. A write that failed may have been made
--   too, and is followed by a read as well.
wrote :: Writing -> Either WikiError PageEvent -> Model -> (Model, [Effect a])
wrote w answer m = case answer of
  Right e
    | any (about e) w.told -> (m, [])
    | w.quiet -> second (Changed :) (follow m {threads = applied e m.threads, heard = heardNow e m})
  _ -> follow m

-- | Whether an event the channel told is about what a write's answer made
-- or changed: the write's own event told back, or a later change to the
-- same thread or comment, or its deletion.
about :: PageEvent -> PageEvent -> Bool
about answer told = case answer of
  ThreadOpened t -> onThread t.id
  CommentAdded c -> onComment c
  CommentEdited c -> told == answer || gone c
  CommentDeleted tid cid -> told == answer || told == CommentDeleted tid cid || told == ThreadDeleted tid
  ThreadDeleted tid -> told == ThreadDeleted tid
  ThreadResolved tid _ -> told == answer || told == ThreadDeleted tid
  _ -> False
  where
    onThread tid = case told of
      ThreadOpened t -> t.id == tid
      CommentAdded c -> c.thread == tid
      CommentEdited c -> c.thread == tid
      CommentDeleted t _ -> t == tid
      ThreadResolved t _ -> t == tid
      ThreadDeleted t -> t == tid
      _ -> False
    onComment c = case told of
      CommentAdded x -> x.id == c.id
      CommentEdited x -> x.id == c.id
      _ -> gone c
    gone c = case told of
      CommentDeleted _ cid -> cid == c.id
      ThreadDeleted tid -> tid == c.thread
      _ -> False

-- | A read asked after a write's answer: one at a time, and one more when
-- its answer comes if another write was answered meanwhile.
follow :: Model -> (Model, [Effect a])
follow m = case m.following of
  Just _ -> (m {writtenSince = True}, [])
  Nothing -> let (m', fx) = reading m in (m' {following = head [t | Load t _ <- fx]}, fx)

-- | The model after the answer to a read came, taken or not: when it was
-- the read that followed a write, one more follows if another write was
-- answered since it was asked.
followed :: Ask -> Model -> (Model, [Effect a])
followed asked m
  | m.following /= Just asked = (m, [])
  | m.writtenSince = follow m {following = Nothing, writtenSince = False}
  | otherwise = (m {following = Nothing}, [])

-- | The answer to a read taken: for the page shown, its threads, with
-- what the live channel told since the read was asked applied again, in
-- the order told. The answer may have been read before or after each of
-- those changes was made, and nothing in it says which. Applied again, an
-- addition the answer holds is kept as the answer has it, a deletion is
-- one again, and an edit or a resolution is as told, which a later one
-- still on its way corrects. A failure is shown only where no threads are:
-- threads shown are kept, and marked behind the server's ('behind'), until
-- a read's or a subscription's answer is taken.
taking :: Ask -> PageId -> Either WikiError [Thread] -> Model -> Model
taking asked page answer m
  | m.page /= Just page = m'
  | otherwise = case (answer, m.threads) of
      (Right ts, _) -> m' {behind = False, threads = ThreadsReady (foldr applyEvent ts [e | (e, at) <- m.heard, not (asked `madeAfter` at)])}
      (Left _, ThreadsReady _) -> m' {behind = True}
      (Left e, _) -> m' {behind = False, threads = ThreadsFailed e}
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
