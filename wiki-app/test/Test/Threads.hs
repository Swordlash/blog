-- | The page's threads as a machine ("Wiki.App.View.Comments.Machine"),
-- run on generated runs: other people's comments and the reader's own
-- writes, the live channel's messages, the answers to the reads and the
-- writes in any order, a read that fails, the page view going to another
-- page and back, the page read again, the channel lost, and the view going
-- away, anywhere.
--
-- = The model's server
--
-- Read from @wiki-server@'s handlers (@listThreadsTx@, @openThreadTx@,
-- @replyTx@, @editCommentTx@, @deleteCommentTx@, @deleteThreadTx@,
-- @setResolvedTx@), its tables (migration 0001) and its live channel
-- (@Events.publish@, @enqueue@, the subscription's answer):
--
-- * a read lists every thread of the page, with no limit and no paging,
--   in the order they were opened, each with its comments in the order
--   they were made;
-- * a write is one transaction on the one writer; it is told to every tab
--   watching the page after it commits, the writer's own included, in the
--   order of the commits;
-- * every way the server deletes: a comment; a thread, with its comments
--   (the delete cascades); the only comment of a thread, which deletes the
--   thread; the first comment of a thread with replies is not deleted (the
--   write is refused); a write on a thread or a comment that is no longer
--   there is refused. A page deleted deletes its threads too (the
--   cascade), and the page view then leaves the page: not modelled. A
--   user removed keeps their comments (a comment's author is no foreign
--   key);
-- * the ids of threads and comments are random (@newId@) and never given
--   again. The tables' @seq@, a thread's place among its page's and a
--   comment's among its thread's, is one more than the greatest left, so
--   it is given again after a delete; the client never sees it, and
--   nothing on the client reads a comment's time or an id for an order;
-- * every bounded buffer between the server and the view: a read has no
--   limit, and the HTTP backend's cache keeps whole lists; a connection's
--   outbox holds 256 messages, and a tab that falls behind loses what did
--   not fit and is closed, and subscribes again (the model's outbox holds
--   'outbox', then the tab reconnects once it has read what fit;
--   'Reconnect' loses the rest too);
-- * the answer to a subscription is the threads as they are then, read on
--   the writer, so that every change after it is told after it; a tab
--   whose channel is lost subscribes again and is answered again;
-- * an ask has three moments: sent, handled by the server (a read takes
--   the threads as they are, a write changes them), answered. The server
--   handles the asks out in the order they were sent ('Handle'), or in
--   any order ('HandleOut'): reads run on the readers beside the writer,
--   so a read sent after a write may be handled before the write commits.
--   A read may fail ('HandleFail', the network);
-- * a write's answer is what the page view makes of it
--   ("Wiki.App.View.Page"'s @sendWrite@): the server's thread or comment,
--   and for a deletion, which answers with nothing, the comment deleted.
--
-- What the model leaves out: the pages of an encrypted space, whose
-- threads the server tells of only as "changed" and answers a
-- subscription to with none (the machine then reads them again); a write
-- that fails without the server seeing it (its outcome is told by the
-- channel, if it was made). Comments' authors' names (the server names
-- them as they are now) and quotes (an anchor's text) are fixed, and the
-- server checks no author.
--
-- Over the HTTP backend the threads go through its cache
-- ("Wiki.App.Backend.Http.Cache"), and the model's tab does the same with
-- the cache's own functions: a read the cache can answer is answered at
-- once from it; one sent is stored if the cache did not change since; a
-- write removes the page's threads ('afterComment'); the live channel's
-- events go through 'afterEvent', its subscription's answer replaces them
-- ('withThreads'), and a lost channel drops them ('forgetThreads').
--
-- = The rules
--
-- What the view shows is read after every step, and must hold:
--
-- * no thread of another page is shown;
-- * a comment shown is not lost while the server still has it, the view
--   still shows the same page, and no message the channel has still to
--   deliver brings it back;
-- * a comment's text shown is never older than a text shown before, unless
--   a message the channel has still to deliver brings the newer one;
-- * a comment shown is on the server, unless a message the channel has
--   still to deliver removes it;
-- * a failed read is shown only where no threads are;
-- * a write's answer empties the form it came from (or shows why it
--   failed), and, for a thread opened about a quote, stops the quoting and
--   chooses the thread, once, on the visit of the page it was sent on, and
--   does none of these on another visit, of the same page or another; it
--   empties no form of a comments view mounted after the write was sent
--   (the panel closed and opened again);
-- * every effect of a step is carried out before the next event: the page
--   view's runner of the effects never waits between them;
-- * nothing is asked after the view went away;
-- * after a read whose answer the view needed failed, with threads shown,
--   the view says its threads are behind, until a read's or a
--   subscription's answer is taken;
-- * once everything out has come back and everything the channel had to
--   tell was told, the view shows the server's threads of its page, the
--   reader's writes in their places, or says its threads are behind: a
--   read that fails leaves the threads as they were.
module Test.Threads
  ( spec
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck (Gen, Property, chooseInt, counterexample, forAllShrinkShow, frequency, listOf, shrinkList, (===))
import Test.QuickCheck qualified as QC
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Http.Cache (Cache (threads), Reading (..), Stored (..), afterComment, afterEvent, changedBy, emptyCache, forgetThreads, storedAnswer, storedOf, withThreads)
import Wiki.App.View.Comments.Machine
import Wiki.App.View.Latest (Ask, takes)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id (CommentId (..), CommentThreadId (..), PageId (..), UserId (..))
import Wiki.Core.Version (Author (..))

-- | The two pages a run goes between.
pageA, pageB :: PageId
pageA = PageId "page-a"
pageB = PageId "page-b"

-- | Someone's comment, numbered, in a thread.
commentOf :: Int -> CommentThreadId -> Text -> Comment
commentOf k tid who =
  Comment
    { id = CommentId ("c" <> show k)
    , thread = tid
    , author = Author {id = UserId who, name = who, avatar = Nothing}
    , body = "Comment " <> show k
    , createdAt = at k
    , editedAt = Nothing
    }

at :: Int -> UTCTime
at k = addUTCTime (fromIntegral k) (UTCTime (fromGregorian 2026 11 14) 0)

-- | A quote of the page, numbered, for a thread about it.
quoteOf :: Int -> Anchor
quoteOf k = Anchor {exact = "quote " <> show k, prefix = "", suffix = ""}

-- | A message on the tab's live channel.
data Message
  = MHeard PageId PageEvent
  | MReplaced PageId [Thread]
  deriving stock (Show)

-- | 'Server' is the pages' threads on the server, and what the live
-- channel has still to tell the tab.
data Server = Server
  { count :: Int
  -- ^ How many ids the server has given: the next one's number.
  , pages :: Map PageId [Thread]
  , untold :: [Message]
  -- ^ The messages in the tab's outbox, the oldest first.
  , fellBehind :: Bool
  -- ^ Whether the outbox was full when a message came: the tab is closed
  -- once it has read what fit, and subscribes again.
  , watched :: Maybe PageId
  -- ^ The page the tab watches: the server tells its events.
  }
  deriving stock (Show)

-- | How many messages the model's outbox holds (the server's holds 256,
-- @outboxSize@).
outbox :: Int
outbox = 4

emptyServer :: Server
emptyServer = Server {count = 0, pages = Map.fromList [(pageA, []), (pageB, [])], untold = [], fellBehind = False, watched = Nothing}

threadsOn :: PageId -> Server -> [Thread]
threadsOn p s = Map.findWithDefault [] p s.pages

-- | A write committed: the threads changed by its event, and the event told
-- to the tab if it watches the page and its outbox has room.
committed :: PageId -> PageEvent -> Server -> Server
committed p e s
  | s.watched /= Just p = s'
  | length s.untold >= outbox = s' {fellBehind = True}
  | otherwise = s' {untold = s.untold <> [MHeard p e]}
  where
    s' = s {pages = Map.adjust (applyEvent e) p s.pages}

-- | A write handled by the server, by someone: the server after it, and
-- its event, or why it was refused.
handleWrite :: Text -> PageId -> Request -> Server -> (Server, Either WikiError PageEvent)
handleWrite who p w s = case w of
  OpenThread anchor _ ->
    let k = s.count + 1
        tid = CommentThreadId ("t" <> show k)
        t = Thread {id = tid, page = p, anchor, resolved = False, createdAt = at k, comments = [commentOf k tid who]}
     in done (ThreadOpened t) s {count = k}
  Reply tid _ -> withThreadOf tid $ \_ ->
    let k = s.count + 1 in done (CommentAdded (commentOf k tid who)) s {count = k}
  EditComment tid cid _ -> withThreadOf tid $ \t -> case find (\c -> c.id == cid) t.comments of
    Just c -> let k = s.count + 1 in done (CommentEdited c {body = c.body <> ", edited " <> show k, editedAt = Just (at k)}) s {count = k}
    Nothing -> (s, Left NotFound)
  Resolve tid r -> withThreadOf tid $ \t ->
    if isJust t.anchor then done (ThreadResolved tid r) s else (s, Left (Invalid "A thread about the whole page is not resolved."))
  DeleteComment tid cid -> withThreadOf tid $ \t -> case t.comments of
    opening : _ : _ | opening.id == cid -> (s, Left (Invalid "The first comment of a thread with replies cannot be deleted."))
    [only] | only.id == cid -> done (ThreadDeleted tid) s
    cs | any (\c -> c.id == cid) cs -> done (CommentDeleted tid cid) s
    _ -> (s, Left NotFound)
  DeleteThread tid -> withThreadOf tid $ \_ -> done (ThreadDeleted tid) s
  where
    withThreadOf tid f = maybe (s, Left NotFound) f (find (\t -> t.id == tid) (threadsOn p s))
    done e s' = (committed p e s', Right e)

-- | The answer the page view makes of a write's: the server's event, but
-- for a deletion, which answers with nothing ("Wiki.App.View.Page"'s
-- @sendWrite@).
answerOf :: Request -> PageEvent -> PageEvent
answerOf request e = case request of
  DeleteComment tid cid -> CommentDeleted tid cid
  DeleteThread tid -> ThreadDeleted tid
  _ -> e

-- | 'Step' is one thing that happens in a run. A step that cannot happen
-- in the state it comes to is skipped, so that a run shrinks to any of its
-- parts.
data Step
  = -- | Someone else opens a thread on the page shown.
    OtherOpens Bool
  | -- | Someone else replies in the thread at this place on the server.
    OtherReplies Int
  | -- | Someone else edits the comment at this place on the server.
    OtherEdits Int
  | -- | Someone else resolves or reopens the thread at this place.
    OtherResolves Int
  | -- | Someone else deletes the comment at this place.
    OtherDeletesComment Int
  | -- | Someone else deletes the thread at this place.
    OtherDeletesThread Int
  | -- | The reader opens a thread (the comments view asks for it): about
    -- the quote being commented on, or about the whole page.
    ReaderOpens Bool
  | -- | The reader selects this quote of the page and comments on it: the
    -- panel opens with a new thread about it.
    Quote Int
  | -- | The reader chooses the thread shown at this place.
    Choose Int
  | -- | The lookup of the people the threads mention answers.
    PeopleFound
  | -- | The reader replies in the thread shown at this place.
    ReaderReplies Int
  | -- | The reader edits the comment shown at this place.
    ReaderEdits Int
  | -- | The reader resolves or reopens the thread shown at this place.
    ReaderResolves Int
  | -- | The reader deletes the comment shown at this place.
    ReaderDeletes Int
  | -- | The reader deletes the thread shown at this place.
    ReaderDeletesThread Int
  | -- | The live channel delivers its oldest message.
    Tell
  | -- | The live channel is lost and opens again: what it had to tell is
    -- lost, the page is subscribed to again, and answered.
    Reconnect
  | -- | The server handles the oldest ask it has not handled.
    Handle
  | -- | The server handles the ask at this place among those it has not
    -- handled.
    HandleOut Int
  | -- | The oldest read the server has not handled fails.
    HandleFail
  | -- | The answer at this place among those handled comes back.
    Deliver Int
  | -- | The page view goes to the other page.
    Navigate
  | -- | The page shown is read again (a save, a reload of the wiki).
    PageAgain
  | -- | The reader closes the panel of comments and opens it again: a new
    -- comments view, with empty forms.
    Reopen
  | -- | The page view goes away.
    Finish
  deriving stock (Eq, Show)

genRun :: Gen [Step]
genRun =
  listOf $
    frequency
      [ (3, OtherOpens <$> QC.arbitrary)
      , (3, OtherReplies <$> chooseInt (0, 2))
      , (1, OtherEdits <$> chooseInt (0, 3))
      , (1, OtherResolves <$> chooseInt (0, 2))
      , (1, OtherDeletesComment <$> chooseInt (0, 3))
      , (1, OtherDeletesThread <$> chooseInt (0, 2))
      , (2, ReaderOpens <$> QC.arbitrary)
      , (2, Quote <$> chooseInt (0, 1))
      , (1, Choose <$> chooseInt (0, 2))
      , (4, pure PeopleFound)
      , (2, ReaderReplies <$> chooseInt (0, 2))
      , (1, ReaderEdits <$> chooseInt (0, 3))
      , (1, ReaderResolves <$> chooseInt (0, 2))
      , (1, ReaderDeletes <$> chooseInt (0, 3))
      , (1, ReaderDeletesThread <$> chooseInt (0, 2))
      , (6, pure Tell)
      , (1, pure Reconnect)
      , (5, pure Handle)
      , (2, HandleOut <$> chooseInt (0, 3))
      , (1, pure HandleFail)
      , (6, Deliver <$> chooseInt (0, 3))
      , (1, pure Navigate)
      , (1, pure PageAgain)
      , (1, pure Reopen)
      , (1, pure Finish)
      ]

shrinkRun :: [Step] -> [[Step]]
shrinkRun = shrinkList $ \case
  HandleOut i -> Handle : (HandleOut <$> [0 .. i - 1])
  HandleFail -> [Handle]
  Deliver i -> Deliver <$> [0 .. i - 1]
  OtherReplies i -> OtherReplies <$> [0 .. i - 1]
  OtherEdits i -> OtherEdits <$> [0 .. i - 1]
  OtherDeletesComment i -> OtherDeletesComment <$> [0 .. i - 1]
  OtherDeletesThread i -> OtherDeletesThread <$> [0 .. i - 1]
  ReaderReplies i -> ReaderReplies <$> [0 .. i - 1]
  ReaderEdits i -> ReaderEdits <$> [0 .. i - 1]
  ReaderDeletes i -> ReaderDeletes <$> [0 .. i - 1]
  ReaderDeletesThread i -> ReaderDeletesThread <$> [0 .. i - 1]
  Quote i -> Quote <$> [0 .. i - 1]
  Choose i -> Choose <$> [0 .. i - 1]
  _ -> []

-- | An ask the view made: a read under its ticket, or a write under its
-- number, with the visit it was sent on, the comments view that sent it,
-- and the session of quoting it was written in.
data Asked = ARead Ask PageId | AWrite Int PageId Request Int Int (Maybe Int)
  deriving stock (Show)

-- | An ask out, and its answer once handled.
data Out = Out
  { asked :: Asked
  , answer :: Maybe (Either WikiError (Either [Thread] PageEvent))
  , sent :: Maybe Stored
  -- ^ Over the cache, for a read sent to the server: the cache when it
  -- was sent.
  }
  deriving stock (Show)

-- | A run under way.
data World = World
  { view :: Model
  , server :: Server
  , outs :: [Out]
  , shownPage :: PageId
  -- ^ The page the view is on, or going to.
  , finished :: Bool
  , tabCache :: Maybe Stored
  -- ^ The HTTP backend's cache, when the view is over it.
  , trace :: [Text]
  , faults :: [(Rule, Text)]
  , seen :: Map CommentId (Text, PageId)
  -- ^ Every comment shown on this visit of its page, with the newest text
  -- shown.
  , owed :: Bool
  -- ^ Whether a read of the threads shown whose answer the view needed
  -- failed, with no read's or subscription's answer taken since: the view
  -- must say its threads are behind.
  , visit :: Int
  -- ^ How many times the view went to another page: the visit shown.
  , quoteSession :: Maybe Int
  -- ^ The session of quoting open: each time the reader comments on a
  -- quote is another, the same quote too, until it is given up.
  , quoteSessions :: Int
  -- ^ How many sessions of quoting were opened.
  , mounted :: Int
  -- ^ The comments view mounted now: a view mounted anew (the panel closed
  -- and opened again) is another.
  , asksOfView :: [ViewAsk]
  -- ^ What the page view was asked to do on the comments' view and its
  -- page for writes' answers, the oldest first.
  , waiting :: Bool
  -- ^ Whether the page view's runner of the machine's effects waits (on a
  -- lookup of people), with effects of a step still to carry out.
  , held :: [Effect Int]
  -- ^ Those effects, the oldest first.
  }

-- | A run from its start: the page view on page A, over a backend that
-- answers nothing at once.
startOver :: Maybe Stored -> World
startOver cache =
  checked Nothing . fromTheCache $
    let (view, fx) = step (Fetched pageA True False) (initial (Just pageA) True False Nothing)
        w0 = World {view, server = emptyServer {watched = Just pageA, untold = [MReplaced pageA []]}, outs = [], shownPage = pageA, finished = False, tabCache = cache, trace = [], faults = [], seen = mempty, owed = False, visit = 0, quoteSession = Nothing, quoteSessions = 0, mounted = 0, asksOfView = [], waiting = False, held = []}
     in effected "mounted on page A" fx w0

start, startCached :: World
start = startOver Nothing
startCached = startOver (Just (storedOf emptyCache))

-- | The world after the view took an event. The step's effects are
-- carried out after it; one of an earlier step still held then runs after
-- this event, which the rule 'Waited' names.
event :: Text -> Event Int -> World -> World
event what e w = checked (Just w.view.threads) . fromTheCache $ effected what fx w {view, faults = w.faults <> [(Waited, "effects of an earlier step are still to be carried out at: " <> what) | w.waiting, not w.finished]}
  where
    (view, fx) = step e w.view

-- | The view's effects carried out by the page view's runner
-- ("Wiki.App.View.Page"'s @threadsStep@), in order: a read or a write is
-- an ask out (a read answered at once by the cache when it can be). The
-- runner looks up the people the threads mention on 'Changed' in a fork
-- of its own, and carries out the effects after it at once: it never
-- waits between effects ('Waited').
effected :: Text -> [Effect Int] -> World -> World
effected what fx w0 = noted (what <> (if null made then "" else " -> " <> T.intercalate ", " made)) w1
  where
    (w1, made) = foldl' (\(w, names) e -> second (names <>) (carry what e w)) (w0, []) fx

-- | One effect carried out, or held while the runner waits, with what it
-- asked, named.
carry :: Text -> Effect Int -> World -> (World, [Text])
carry what e w
  | w.waiting = (w {held = w.held <> [e]}, [])
  | otherwise = case e of
      Load t p -> asking (show (t, p)) (readOut t p)
      Send sender n p r -> asking ("write " <> show n) Out {asked = AWrite n p r w.visit sender w.quoteSession, answer = Nothing, sent = Nothing}
      Answered asker _ _ -> (w {asksOfView = w.asksOfView <> [TellForm | asker == w.mounted]}, [])
      Changed -> (w, [])
  where
    asking name o = (w {outs = w.outs <> [o], faults = w.faults <> [(AfterClose, "asked after the view went away: " <> what) | w.finished]}, [name])
    readOut t p = case w.tabCache of
      Just c | Just cached <- Map.lookup p c.cache.threads -> Out {asked = ARead t p, answer = Just (Left <$> cached), sent = Nothing}
      _ -> Out {asked = ARead t p, answer = Nothing, sent = w.tabCache}

-- | The lookup of people answered: the runner carries out what it held,
-- if the view is still there.
lookedUp :: World -> World
lookedUp w
  | not w.waiting = w
  -- The view gone, its program is cancelled with what it held.
  | w.finished = w {waiting = False, held = []}
  | otherwise = fromTheCache (effected "the people looked up" w.held w {waiting = False, held = []})

-- | The world after a read the cache answered came back: the cache answers
-- at once, so its answer is the next the view takes.
fromTheCache :: World -> World
fromTheCache w = case [k | (k, o) <- zip [0 :: Int ..] w.outs, isJust w.tabCache, isNothing o.sent, isJust o.answer, isRead o.asked] of
  k : _ -> deliver k w
  [] -> w
  where
    isRead = \case
      ARead _ _ -> True
      _ -> False

-- | The cache after a change, when the view is over it.
changing :: (Cache -> Cache) -> World -> World
changing f w = w {tabCache = changedBy f <$> w.tabCache}

noted :: Text -> World -> World
noted what w = w {trace = (what <> "    [" <> summary w.view <> "]") : w.trace}

summary :: Model -> Text
summary m = case m.threads of
  ThreadsLoading -> "loading"
  ThreadsFailed e -> "failed: " <> show e
  ThreadsReady ts -> T.intercalate " " [tid <> (if t.resolved then "(resolved)" else "") <> ":" <> T.intercalate "," [cid <> (if isJust c.editedAt then "'" else "") | c <- t.comments, let CommentId cid = c.id] | t <- ts, let CommentThreadId tid = t.id]

-- | The world after a step.
play :: World -> Step -> World
play w = \case
  OtherOpens inline -> other (OpenThread (if inline then Just (quoteOf 0) else Nothing) "")
  OtherReplies i -> onServerThread i $ \t -> other (Reply t.id "")
  OtherEdits i -> onServerComment i $ \t c -> other (EditComment t.id c.id "")
  OtherResolves i -> onServerThread i $ \t -> other (Resolve t.id (not t.resolved))
  OtherDeletesComment i -> onServerComment i $ \t c -> other (DeleteComment t.id c.id)
  OtherDeletesThread i -> onServerThread i $ \t -> other (DeleteThread t.id)
  ReaderOpens False -> byReader (OpenThread Nothing "")
  ReaderOpens True -> maybe w (\a -> byReader (OpenThread (Just a) "")) (quotingOf w)
  Quote k
    | w.finished || not (isReady w.view) -> w
    | otherwise -> quoted (quoteOf k) w
  Choose i -> onShownThread i $ \t -> chosen t.id w
  PeopleFound -> lookedUp w
  ReaderReplies i -> onShownThread i $ \t -> byReader (Reply t.id "")
  ReaderEdits i -> onShownComment i $ \t c -> byReader (EditComment t.id c.id "")
  ReaderResolves i -> onShownThread i $ \t -> if isJust t.anchor then byReader (Resolve t.id (not t.resolved)) else w
  ReaderDeletes i -> onShownComment i $ \t c -> byReader (DeleteComment t.id c.id)
  ReaderDeletesThread i -> onShownThread i $ \t -> byReader (DeleteThread t.id)
  Tell -> case w.server.untold of
    MHeard p e : rest -> event ("told " <> show e) (Heard p e) (changing (afterEvent p e) w {server = w.server {untold = rest}})
    MReplaced p ts : rest -> event ("subscription answered on " <> show p) (Replaced p ts) (changing (withThreads p (Right ts)) w {server = w.server {untold = rest}, owed = w.owed && p /= w.shownPage})
    []
      | w.server.fellBehind -> noted "the channel fell behind, is closed and opens again" (reconnected w)
      | otherwise -> w
  Reconnect -> noted "the channel is lost and opens again" (reconnected w)
  Handle -> handleAt 0 w
  HandleOut i -> handleAt i w
  HandleFail -> case [k | (k, o) <- zip [0 :: Int ..] w.outs, isNothing o.answer, ARead _ _ <- [o.asked]] of
    k : _ -> noted "a read fails" w {outs = [if j == k then x {answer = Just (Left (Unreachable "the network"))} else x | (j, x) <- zip [0 ..] w.outs]}
    [] -> w
  Deliver i -> case atMay [k | (k, o) <- zip [0 :: Int ..] w.outs, isJust o.answer] i of
    Just k -> deliver k w
    Nothing -> w
  Navigate
    | w.finished -> w
    | otherwise ->
        let next = if w.shownPage == pageA then pageB else pageA
            -- The page view stops watching the old page and watches the new
            -- one: the server answers the new subscription after what it
            -- had queued.
            w' = event "goes to the other page" Left' (changing (forgetThreads w.shownPage) w {shownPage = next, owed = False, visit = w.visit + 1, quoteSession = Nothing})
            w'' = w' {server = w'.server {watched = Just next, untold = w'.server.untold <> [MReplaced next (threadsOn next w'.server)]}}
         in event ("shows " <> show next) (Fetched next True False) w''
  PageAgain
    | w.finished -> w
    | otherwise -> event "the page read again" (Fetched w.shownPage True False) w
  Reopen
    | w.finished -> w
    | otherwise -> closed (noted "the panel closed and opened again" w {mounted = w.mounted + 1})
  Finish -> event "goes away" Finished w {finished = True}
  where
    other wr = noted ("someone else: " <> show wr) w {server = fst (handleWrite "other" w.shownPage wr w.server)}
    byReader wr
      | w.finished || not (isReady w.view) = w
      | otherwise = event ("the reader asks for " <> show wr) (Write w.mounted w.shownPage wr) w
    onServerThread i f = maybe w f (atMay (threadsOn w.shownPage w.server) i)
    onServerComment i f = maybe w (uncurry f) (atMay [(t, c) | t <- threadsOn w.shownPage w.server, c <- t.comments] i)
    onShownThread i f
      | w.finished = w
      | otherwise = maybe w f (atMay (readyThreads w.view) i)
    onShownComment i f
      | w.finished = w
      | otherwise = maybe w (uncurry f) (atMay [(t, c) | t <- readyThreads w.view, c <- t.comments] i)
    isReady m = case m.threads of
      ThreadsReady _ -> True
      _ -> False

-- | The quote the reader comments on, and the thread chosen: the
-- machine's.
quotingOf :: World -> Maybe Anchor
quotingOf w = (\q -> q.anchor) <$> w.view.quoting

focusedOf :: World -> Maybe CommentThreadId
focusedOf w = w.view.focused

-- | The reader comments on a quote: the page view's @CommentOnSelection@.
quoted :: Anchor -> World -> World
quoted a w = event ("the reader comments on " <> a.exact) (Quoted a) w {quoteSession = Just (w.quoteSessions + 1), quoteSessions = w.quoteSessions + 1}

-- | The reader chooses a thread: the comments view's @Focus@.
chosen :: CommentThreadId -> World -> World
chosen tid = event ("the reader chooses " <> show tid) (Chose tid)

-- | The panel closed: the page view's @Close@.
closed :: World -> World
closed w = event "the panel closes" Closed w {quoteSession = Nothing}

-- | The channel closed and open again: what it had to tell is lost, the
-- page is subscribed to again, and the backend drops its threads.
reconnected :: World -> World
reconnected w = changing (forgetThreads w.shownPage) w {server = w.server {untold = [MReplaced p (threadsOn p w.server) | Just p <- [w.server.watched]], fellBehind = False}}

-- | The world after the server handled the ask at this place among those
-- it has not handled.
handleAt :: Int -> World -> World
handleAt i w = case atMay [k | (k, o) <- zip [0 :: Int ..] w.outs, isNothing o.answer] i of
  Just k
    | Just o <- atMay w.outs k ->
        let (server, answer) = case o.asked of
              ARead _ p -> (w.server, Right (Left (threadsOn p w.server)))
              AWrite _ p r _ _ _ -> second (fmap Right) (handleWrite "reader" p r w.server)
         in noted ("the server handles " <> show o.asked) w {server, outs = [if j == k then x {answer = Just answer} else x | (j, x) <- zip [0 ..] w.outs]}
  _ -> w

-- | The world after the answer at this place in the asks out came back.
deliver :: Int -> World -> World
deliver k w = case atMay w.outs k of
  Just Out {asked, answer = Just a, sent} ->
    let w' = w {outs = [x | (j, x) <- zip [0 ..] w.outs, j /= k]}
     in case (asked, a) of
          (ARead t p, Left e) -> owing (\w'' -> if needed t p w' && isJust (readyThreadsOf w''.view) then True else w''.owed) (event "the read failed" (Loaded t p (Left e)) w')
          (ARead t p, Right (Left ts)) ->
            let stored = case (w'.tabCache, sent) of
                  (Just now', Just sentAt) -> Just (storedAnswer PlainRead sentAt (withThreads p (Right ts)) now')
                  _ -> w'.tabCache
             in event ("the answer to the read of " <> show p) (Loaded t p (Right ts)) w' {tabCache = stored, owed = w'.owed && not (needed t p w')}
          (ARead t p, Right (Right _)) -> event "a read" (Loaded t p (Right [])) w'
          -- The backend applies the write's answer to its cache, then the
          -- page view takes it.
          (AWrite n p r v sender ses, Right (Right e)) ->
            let e' = answerOf r e
             in answeredOnce v sender ses (Right e') w' (event ("the answer to write " <> show n <> ": " <> show e') (Wrote sender n r (Right e')) (changing (afterComment p) w'))
          -- A write is never answered with a list.
          (AWrite {}, Right (Left _)) -> w'
          (AWrite n p r v sender ses, Left e) -> answeredOnce v sender ses (Left e) w' (event ("write " <> show n <> " refused: " <> show e) (Wrote sender n r (Left e)) (changing (afterComment p) w'))
  _ -> w

-- | 'ViewAsk' is what a write's answer asks of the page view beside its
-- threads: tell the comments view that asked (its form emptied, or the
-- reason shown), and, for a thread opened about a quote, stop quoting and
-- choose the thread.
data ViewAsk = TellForm | ChooseOpened
  deriving stock (Eq, Ord, Show)

-- | The quote a thread a write's answer opened is about.
anchorOf :: Either WikiError PageEvent -> Maybe Anchor
anchorOf = \case
  Right (ThreadOpened t) -> t.anchor
  _ -> Nothing

-- | The world checked against the rule that a write's answer asks the
-- view for its effects once on the visit it was sent on, and for none on
-- another; that it empties a form only of the comments view that sent it,
-- not of one mounted since; and that a thread it opened about a quote ends
-- the quoting and is chosen only in the session of quoting it was written
-- in, not in a later one, of the same quote or another.
answeredOnce :: Int -> Int -> Maybe Int -> Either WikiError PageEvent -> World -> World -> World
answeredOnce sentOn sentFrom sentIn answer was now
  | now.finished = now
  | sort made == sort wanted = now
  | otherwise = now {faults = now.faults <> [(AnsweredOnce, "the answer to a write sent on visit " <> show sentOn <> " by comments view " <> show sentFrom <> ", taken on visit " <> show now.visit <> " with comments view " <> show now.mounted <> ", asked the view for " <> show made <> ", not " <> show wanted)]}
  where
    made = drop (length was.asksOfView) now.asksOfView <> [ChooseOpened | (quotingOf was, focusedOf was) /= (quotingOf now, focusedOf now)]
    wanted = if sentOn == now.visit then [TellForm | sentFrom == now.mounted, isNothing (anchorOf answer) || (isJust sentIn && sentIn == was.quoteSession)] <> [ChooseOpened | Just a <- [anchorOf answer], quotingOf was == Just a, isJust sentIn, sentIn == was.quoteSession] else []

-- | Whether the answer to this read of this page is the view's to take: on
-- the page shown, and no answer to a later read taken.
needed :: Ask -> PageId -> World -> Bool
needed t p w = p == w.shownPage && w.view.page == Just p && isJust (takes t w.view.asks)

-- | The world with whether a read the view needed is owed set, and checked.
owing :: (World -> Bool) -> World -> World
owing f w = said w {owed = f w}

-- | The world checked against the rule that a view owed a read says its
-- threads are behind.
said :: World -> World
said w = w {faults = w.faults <> [(Unsaid, "a read the view needed failed, and it does not say its threads are behind") | w.owed, not w.finished, not w.view.behind]}

-- | The world with what the view shows checked against the rules, given
-- what it showed before the step, if the step was the view's.
checked :: Maybe Threads -> World -> World
checked shownBefore w = w {faults = w.faults <> problems, seen = seen'}
  where
    shown = readyThreads w.view
    shownComments = [(c, t.page) | t <- shown, c <- t.comments]
    onServer = [c.id | t <- threadsOn w.shownPage w.server, c <- t.comments]
    -- The comments a message the channel has still to deliver brings: a
    -- comment gone only until the next message is not lost (the
    -- subscription's answer is the threads as they were when the page was
    -- subscribed to, and every change after it comes after it). A tab that
    -- fell behind subscribes again once it has read what fit: every
    -- comment of its page, as it is then, is on its way.
    onTheWay = concatMap brings w.server.untold <> [c | w.server.fellBehind, c <- onServer]
    brings = \case
      MHeard _ (ThreadOpened t) -> map (\c -> c.id) t.comments
      MHeard _ (CommentAdded c) -> [c.id]
      MHeard _ (CommentEdited c) -> [c.id]
      MReplaced _ ts -> [c.id | t <- ts, c <- t.comments]
      _ -> []
    editsOnTheWay = [c.id | MHeard _ (CommentEdited c) <- w.server.untold] <> [c.id | w.server.fellBehind, (c, _) <- shownComments]
    -- A visit ends when the view goes elsewhere: what was seen on it is
    -- forgotten.
    current = if w.view.page == Just w.shownPage then w.seen else mempty
    seen' = Map.union (Map.fromList [(c.id, (c.body, p)) | (c, p) <- shownComments]) current
    problems
      | w.finished = []
      | w.owed && not w.view.behind = [(Unsaid, "a read the view needed failed, and it does not say its threads are behind")]
      | otherwise =
          [(OtherPage, "a thread of another page is shown: " <> show t.id) | t <- shown, Just t.page /= w.view.page || t.page /= w.shownPage]
            <> [ (Lost, "a comment shown before is gone while the server has it: " <> show cid)
               | isJust (readyThreadsOf w.view)
               , cid <- Map.keys current
               , cid `notElem` map (\(c, _) -> c.id) shownComments
               , cid `elem` onServer
               , cid `notElem` onTheWay
               ]
            <> [ (Older, "a comment's text went back: " <> show c.id <> " " <> c.body <> " after " <> earlier)
               | (c, _) <- shownComments
               , Just (earlier, _) <- [Map.lookup c.id current]
               , earlier /= c.body
               , editsOf c.body < editsOf earlier
               , c.id `notElem` editsOnTheWay
               ]
            <> [ (FailureOverThreads, "a failed read is shown in place of the threads")
               | Just (ThreadsReady _) <- [shownBefore]
               , ThreadsFailed _ <- [w.view.threads]
               ]
            <> [ (Ghost, "a comment the server deleted is shown: " <> show c.id)
               | w.view.page == Just w.shownPage
               , not w.server.fellBehind
               , null [() | MReplaced p _ <- w.server.untold, p == w.shownPage]
               , (c, _) <- shownComments
               , c.id `notElem` onServer
               , null [() | MHeard _ (CommentDeleted _ cid) <- w.server.untold, cid == c.id]
               , null [() | MHeard _ (ThreadDeleted tid) <- w.server.untold, tid == c.thread]
               ]

readyThreadsOf :: Model -> Maybe [Thread]
readyThreadsOf m = case m.threads of
  ThreadsReady ts -> Just ts
  _ -> Nothing

-- | How many edits a comment's text in the model has seen: its text grows
-- by one mark at each.
editsOf :: Text -> Int
editsOf = T.count ", edited"

-- | The run settled: everything the channel had to tell told, every ask
-- handled and answered, the oldest first.
settled :: World -> World
settled w0 = drained (tellAll w0)
  where
    tellAll w
      | w.waiting = tellAll (lookedUp w)
      | null w.server.untold && not w.server.fellBehind = w
      | otherwise = tellAll (play w Tell)

drained :: World -> World
drained w
  | w.waiting = drained (lookedUp w)
  | null w.outs = w
  | any (isNothing . (.answer)) w.outs = drained (handleAt 0 w)
  | otherwise = settled (deliver 0 w)

-- | Whether a run, settled, shows the server's threads of its page.
settles :: World -> Property
settles w0 =
  counterexample (toS (T.unlines (reverse w.trace))) $
    w.view.behind QC..||. shape (readyThreadsOf w.view) === shape (Just (threadsOn w.shownPage w.server))
  where
    w = settled w0
    shape = fmap (map (\t -> (t.id, t.resolved, [(c.id, c.body) | c <- t.comments])))

-- | 'Rule' is each rule a run is checked against, as the module's Haddock
-- lists them.
data Rule = OtherPage | Lost | Older | Ghost | FailureOverThreads | Unsaid | AnsweredOnce | Waited | AfterClose
  deriving stock (Eq, Show, Enum, Bounded)

ruleText :: Rule -> [Char]
ruleText = \case
  OtherPage -> "shows no thread of another page, on any run"
  Lost -> "loses no comment the server still has, on any run"
  Older -> "shows no comment's text older than one it showed, on any run"
  Ghost -> "shows no comment the server deleted, on any run"
  Unsaid -> "says its threads are behind after a read it needed failed, until it takes another, on any run"
  Waited -> "carries out every effect of a step before the next event, on any run"
  AnsweredOnce -> "carries out a write's answer in the comments view and the page once on the visit it was sent on, and never on another, on any run"
  FailureOverThreads -> "shows a failed read only where it shows no threads, on any run"
  AfterClose -> "asks nothing once it has gone away"

verdict :: Rule -> World -> Property
verdict rule w =
  counterexample (toS (T.unlines (reverse w.trace)))
    . counterexample (toS (T.unlines ("Broken:" : [t | (r, t) <- w.faults, r == rule])))
    $ null [() | (r, _) <- w.faults, r == rule]

cases :: Int
cases = 20_000

spec :: Spec
spec = describe "Wiki.App.View.Comments.Machine" $ modifyMaxSuccess (max cases) $ do
  for_ [("", start), (", over the HTTP backend's cache", startCached)] $ \(how, w0) -> do
    for_ [minBound .. maxBound] $ \rule ->
      it (ruleText rule <> how) $
        QC.property $
          forAllShrinkShow genRun shrinkRun show $ \run ->
            verdict rule (foldl' play w0 (if rule == AfterClose then run <> [Finish] <> run else run))

    it ("keeps a comment the channel told while a read was out, the known race" <> how) $
      -- A read asked after the subscription's answer, handled before
      -- someone else's comment was made, answered after the channel told
      -- of it (WP5.95's open case).
      [t | (Lost, t) <- (foldl' play w0 [Tell, PageAgain, Handle, Handle, OtherOpens True, Tell, Deliver 1]).faults] `shouldBe` []

    it ("leaves a new visit's forms alone when a write sent on an earlier visit of the page is answered" <> how) $
      -- Codex on #284: the reader writes on page A, goes to B and back to
      -- A, and the old write's answer emptied the new visit's form.
      [t | (AnsweredOnce, t) <- (foldl' play w0 [Handle, Tell, ReaderOpens False, Deliver 0, Navigate, Navigate, Handle, Deliver 0]).faults] `shouldBe` []

    it ("keeps the thread chosen on another page when the lookup after an earlier subscription's answer comes" <> how) $
      -- Codex on #284: the subscription's answer on A is taken, the people
      -- are looked up, the reader goes to B and chooses a thread there;
      -- the lookup answers, and A's threads unfocus B's.
      focusedOf (foldl' play w0 [Tell, Navigate, OtherOpens False, Tell, Tell, Choose 0, PeopleFound]) `shouldBe` Just (CommentThreadId "t1")

    it ("leaves a new quote alone when a thread about an old one is answered after the panel was reopened" <> how) $
      -- Codex on #284: the reader comments on a quote, sends, closes the
      -- panel, opens it again on another quote; the old write's answer
      -- stopped the new quoting and chose the old thread.
      let w = foldl' play w0 [Tell, PeopleFound, Quote 0, ReaderOpens True, Handle, Handle, Reopen, Quote 1, Deliver 1, PeopleFound]
       in (quotingOf w, focusedOf w) `shouldBe` (Just (quoteOf 1), Nothing)

    it ("leaves a new session of the same quote alone when the thread of an old one is answered" <> how) $
      -- Codex on #284: the reader comments on a quote, sends, closes the
      -- panel, comments on the same quote again; the old write's answer
      -- ended the new session and chose the old thread.
      let w = foldl' play w0 [Tell, PeopleFound, Quote 0, ReaderOpens True, Handle, Handle, Reopen, Quote 0, Deliver 1, PeopleFound]
       in (quotingOf w, focusedOf w) `shouldBe` (Just (quoteOf 0), Nothing)

    it ("shows the server's threads once everything out has come back" <> how) $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          settles (foldl' play w0 (filter (/= Finish) run))
