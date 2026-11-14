-- | The page's threads as a machine ("Wiki.App.View.Comments.Machine"),
-- run on generated runs: other people's comments and the reader's own
-- writes, the live channel's messages, the answers to the reads and the
-- writes in any order, the page view going to another page and back, the
-- page read again, the channel lost, and the view going away, anywhere.
--
-- = The model's server
--
-- Read from @wiki-server@'s handlers (@listThreadsTx@, @openThreadTx@,
-- @replyTx@, @editCommentTx@, @deleteCommentTx@, @deleteThreadTx@,
-- @setResolvedTx@) and its live channel (@Events.publish@, the
-- subscription's answer):
--
-- * a read lists every thread of the page, with no limit and no paging,
--   in the order they were opened, each with its comments in the order
--   they were made;
-- * a write is one transaction on the one writer; it is told to every tab
--   watching the page after it commits, the writer's own included, in the
--   order of the commits;
-- * deleting the only comment of a thread deletes the thread; the first
--   comment of a thread with replies is not deleted (the write is
--   refused); a write on a thread or a comment that is no longer there is
--   refused;
-- * the answer to a subscription is the threads as they are then, read on
--   the writer, so that every change after it is told after it; a tab
--   whose channel is lost subscribes again and is answered again;
-- * an ask has three moments: sent, handled by the server (a read takes
--   the threads as they are, a write changes them), answered. The server
--   handles the asks out in the order they were sent ('Handle'), or in
--   any order ('HandleOut'): reads run on the readers beside the writer,
--   so a read sent after a write may be handled before the write commits.
--
-- What the model leaves out: the pages of an encrypted space, whose
-- threads the server tells of only as "changed" and answers a
-- subscription to with none (the machine then reads them again); a failed
-- read (the network): a read's failure shows as a failure, a choice of
-- the view's. Comments' authors' names (the server names them as they are
-- now) and quotes (an anchor's text) are fixed.
--
-- Over the HTTP backend the threads go through its cache
-- ("Wiki.App.Backend.Http.Cache"), and the model's tab does the same with
-- the cache's own functions: a read the cache can answer is answered at
-- once from it; one sent is stored if the cache did not change since; a
-- write's answer is applied to the cached threads ('afterComment'); the
-- live channel's events too ('afterEvent'), its subscription's answer
-- replaces them ('withThreads'), and a lost channel drops them
-- ('forgetThreads').
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
-- * nothing is asked after the view went away;
-- * once everything out has come back and everything the channel had to
--   tell was told, the view shows the server's threads of its page.
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
import Wiki.App.View.Latest (Ask)
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
  -- ^ The messages the tab's channel has yet to deliver, the oldest
  -- first.
  , watched :: Maybe PageId
  -- ^ The page the tab watches: the server tells its events.
  }
  deriving stock (Show)

emptyServer :: Server
emptyServer = Server {count = 0, pages = Map.fromList [(pageA, []), (pageB, [])], untold = [], watched = Nothing}

threadsOn :: PageId -> Server -> [Thread]
threadsOn p s = Map.findWithDefault [] p s.pages

-- | A write committed: the threads changed by its event, and the event told
-- to the tab if it watches the page.
committed :: PageId -> PageEvent -> Server -> Server
committed p e s = s {pages = Map.adjust (applyEvent e) p s.pages, untold = s.untold <> [MHeard p e | s.watched == Just p]}

-- | 'Write' is a write to a page's threads, as the comments view sends it
-- or someone else does.
data Write
  = -- | A thread opened; inline (about a quote) or about the whole page.
    OpenW PageId Bool
  | ReplyW PageId CommentThreadId
  | EditW PageId CommentThreadId CommentId
  | ResolveW PageId CommentThreadId Bool
  | DeleteCommentW PageId CommentThreadId CommentId
  | DeleteThreadW PageId CommentThreadId
  deriving stock (Eq, Show)

-- | A write handled by the server, by someone: the server after it, and
-- its event, or why it was refused.
handleWrite :: Text -> Write -> Server -> (Server, Either WikiError PageEvent)
handleWrite who w s = case w of
  OpenW p inline ->
    let k = s.count + 1
        tid = CommentThreadId ("t" <> show k)
        t = Thread {id = tid, page = p, anchor = if inline then Just Anchor {exact = "quote", prefix = "", suffix = ""} else Nothing, resolved = False, createdAt = at k, comments = [commentOf k tid who]}
     in done p (ThreadOpened t) s {count = k}
  ReplyW p tid -> withThreadOf p tid $ \_ ->
    let k = s.count + 1 in done p (CommentAdded (commentOf k tid who)) s {count = k}
  EditW p tid cid -> withThreadOf p tid $ \t -> case find (\c -> c.id == cid) t.comments of
    Just c -> let k = s.count + 1 in done p (CommentEdited c {body = c.body <> ", edited " <> show k, editedAt = Just (at k)}) s {count = k}
    Nothing -> (s, Left NotFound)
  ResolveW p tid r -> withThreadOf p tid $ \t ->
    if isJust t.anchor then done p (ThreadResolved tid r) s else (s, Left (Invalid "A thread about the whole page is not resolved."))
  DeleteCommentW p tid cid -> withThreadOf p tid $ \t -> case t.comments of
    opening : _ : _ | opening.id == cid -> (s, Left (Invalid "The first comment of a thread with replies cannot be deleted."))
    [only] | only.id == cid -> done p (ThreadDeleted tid) s
    cs | any (\c -> c.id == cid) cs -> done p (CommentDeleted tid cid) s
    _ -> (s, Left NotFound)
  DeleteThreadW p tid -> withThreadOf p tid $ \_ -> done p (ThreadDeleted tid) s
  where
    withThreadOf p tid f = maybe (s, Left NotFound) f (find (\t -> t.id == tid) (threadsOn p s))
    done p e s' = (committed p e s', Right e)

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
  | -- | The reader opens a thread (the comments view sends it).
    ReaderOpens Bool
  | -- | The reader replies in the thread shown at this place.
    ReaderReplies Int
  | -- | The reader resolves or reopens the thread shown at this place.
    ReaderResolves Int
  | -- | The reader deletes the comment shown at this place.
    ReaderDeletes Int
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
  | -- | The answer at this place among those handled comes back.
    Deliver Int
  | -- | The page view goes to the other page.
    Navigate
  | -- | The page shown is read again (a save, a reload of the wiki).
    PageAgain
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
      , (2, ReaderReplies <$> chooseInt (0, 2))
      , (1, ReaderResolves <$> chooseInt (0, 2))
      , (1, ReaderDeletes <$> chooseInt (0, 3))
      , (6, pure Tell)
      , (1, pure Reconnect)
      , (5, pure Handle)
      , (2, HandleOut <$> chooseInt (0, 3))
      , (6, Deliver <$> chooseInt (0, 3))
      , (1, pure Navigate)
      , (1, pure PageAgain)
      , (1, pure Finish)
      ]

shrinkRun :: [Step] -> [[Step]]
shrinkRun = shrinkList $ \case
  HandleOut i -> Handle : (HandleOut <$> [0 .. i - 1])
  Deliver i -> Deliver <$> [0 .. i - 1]
  OtherReplies i -> OtherReplies <$> [0 .. i - 1]
  OtherEdits i -> OtherEdits <$> [0 .. i - 1]
  OtherDeletesComment i -> OtherDeletesComment <$> [0 .. i - 1]
  OtherDeletesThread i -> OtherDeletesThread <$> [0 .. i - 1]
  ReaderReplies i -> ReaderReplies <$> [0 .. i - 1]
  ReaderDeletes i -> ReaderDeletes <$> [0 .. i - 1]
  _ -> []

-- | An ask the view made, or the comments view: a read under its ticket,
-- or a write.
data Asked = ARead Ask PageId | AWrite Write
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
  }

-- | A run from its start: the page view on page A, over a backend that
-- answers nothing at once.
startOver :: Maybe Stored -> World
startOver cache =
  checked . fromTheCache $
    let (view, fx) = step (Fetched pageA True False) (initial (Just pageA) True False Nothing)
        w0 = World {view, server = emptyServer {watched = Just pageA, untold = [MReplaced pageA []]}, outs = [], shownPage = pageA, finished = False, tabCache = cache, trace = [], faults = [], seen = mempty}
     in effected "mounted on page A" fx w0

start, startCached :: World
start = startOver Nothing
startCached = startOver (Just (storedOf emptyCache))

-- | The world after the view took an event.
event :: Text -> Event -> World -> World
event what e w = checked . fromTheCache $ effected what fx w {view}
  where
    (view, fx) = step e w.view

-- | The view's effects carried out: a read is an ask out (answered at once
-- by the cache when it can be).
effected :: Text -> [Effect] -> World -> World
effected what fx w =
  noted (what <> (if null loads then "" else " -> " <> T.intercalate ", " (map show loads))) $
    w
      { outs = w.outs <> [outOf a | a <- loads]
      , faults = w.faults <> [(AfterClose, "asked after the view went away: " <> what) | w.finished, not (null loads)]
      }
  where
    loads = [(t, p) | Load t p <- fx]
    outOf (t, p) = case w.tabCache of
      Just c | Just cached <- Map.lookup p c.cache.threads -> Out {asked = ARead t p, answer = Just (Left <$> cached), sent = Nothing}
      _ -> Out {asked = ARead t p, answer = Nothing, sent = w.tabCache}

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
  OtherOpens inline -> other (OpenW w.shownPage inline)
  OtherReplies i -> onServerThread i $ \t -> other (ReplyW w.shownPage t.id)
  OtherEdits i -> onServerComment i $ \t c -> other (EditW w.shownPage t.id c.id)
  OtherResolves i -> onServerThread i $ \t -> other (ResolveW w.shownPage t.id (not t.resolved))
  OtherDeletesComment i -> onServerComment i $ \t c -> other (DeleteCommentW w.shownPage t.id c.id)
  OtherDeletesThread i -> onServerThread i $ \t -> other (DeleteThreadW w.shownPage t.id)
  ReaderOpens inline -> byReader (OpenW w.shownPage inline)
  ReaderReplies i -> onShownThread i $ \t -> byReader (ReplyW w.shownPage t.id)
  ReaderResolves i -> onShownThread i $ \t -> if isJust t.anchor then byReader (ResolveW w.shownPage t.id (not t.resolved)) else w
  ReaderDeletes i -> case atMay [(t, c) | t <- readyThreads w.view, c <- t.comments] i of
    Just (t, c) -> byReader (DeleteCommentW w.shownPage t.id c.id)
    Nothing -> w
  Tell -> case w.server.untold of
    MHeard p e : rest -> event ("told " <> show e) (Heard p e) (changing (afterEvent p e) w {server = w.server {untold = rest}})
    MReplaced p ts : rest -> event ("subscription answered on " <> show p) (Replaced p ts) (changing (withThreads p (Right ts)) w {server = w.server {untold = rest}})
    [] -> w
  Reconnect ->
    noted "the channel is lost and opens again" $
      changing (forgetThreads w.shownPage) w {server = w.server {untold = [MReplaced p (threadsOn p w.server) | Just p <- [w.server.watched]]}}
  Handle -> handleAt 0 w
  HandleOut i -> handleAt i w
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
            w' = event "goes to the other page" Left' (changing (forgetThreads w.shownPage) w {shownPage = next})
            w'' = w' {server = w'.server {watched = Just next, untold = w'.server.untold <> [MReplaced next (threadsOn next w'.server)]}}
         in event ("shows " <> show next) (Fetched next True False) w''
  PageAgain
    | w.finished -> w
    | otherwise -> event "the page read again" (Fetched w.shownPage True False) w
  Finish -> event "goes away" Finished w {finished = True}
  where
    other wr = noted ("someone else: " <> show wr) w {server = fst (handleWrite "other" wr w.server)}
    byReader wr
      | w.finished || not (isReady w.view) = w
      | otherwise = noted ("the reader sends " <> show wr) w {outs = w.outs <> [Out {asked = AWrite wr, answer = Nothing, sent = Nothing}]}
    onServerThread i f = maybe w f (atMay (threadsOn w.shownPage w.server) i)
    onServerComment i f = maybe w (uncurry f) (atMay [(t, c) | t <- threadsOn w.shownPage w.server, c <- t.comments] i)
    onShownThread i f
      | w.finished = w
      | otherwise = maybe w f (atMay (readyThreads w.view) i)
    isReady m = case m.threads of
      ThreadsReady _ -> True
      _ -> False

-- | The world after the server handled the ask at this place among those
-- it has not handled.
handleAt :: Int -> World -> World
handleAt i w = case atMay [k | (k, o) <- zip [0 :: Int ..] w.outs, isNothing o.answer] i of
  Just k
    | Just o <- atMay w.outs k ->
        let (server, answer) = case o.asked of
              ARead _ p -> (w.server, Right (Left (threadsOn p w.server)))
              AWrite wr -> second (fmap Right) (handleWrite "reader" wr w.server)
         in noted ("the server handles " <> show o.asked) w {server, outs = [if j == k then x {answer = Just answer} else x | (j, x) <- zip [0 ..] w.outs]}
  _ -> w

-- | The world after the answer at this place in the asks out came back.
deliver :: Int -> World -> World
deliver k w = case atMay w.outs k of
  Just Out {asked, answer = Just a, sent} ->
    let w' = w {outs = [x | (j, x) <- zip [0 ..] w.outs, j /= k]}
     in case (asked, a) of
          (ARead t p, Left e) -> event "a read fails" (Loaded t p (Left e)) w'
          (ARead t p, Right (Left ts)) ->
            let stored = case (w'.tabCache, sent) of
                  (Just now', Just sentAt) -> Just (storedAnswer PlainRead sentAt (withThreads p (Right ts)) now')
                  _ -> w'.tabCache
             in event ("the answer to the read of " <> show p) (Loaded t p (Right ts)) w' {tabCache = stored}
          (ARead t p, Right (Right _)) -> event "a read" (Loaded t p (Right [])) w'
          (AWrite wr, Right (Right e)) ->
            -- The comments view reports the write's result to the page
            -- view, after the backend applied it to the cached threads.
            event ("the reader's write answered: " <> show e) (Did e) (changing (afterComment (pageOfWrite wr) (Right e)) w')
          (AWrite _, Right (Left _)) -> noted "a write" w'
          (AWrite wr, Left e) -> noted ("the reader's write refused: " <> show e) (changing (afterComment (pageOfWrite wr) (Left e)) w')
  _ -> w

pageOfWrite :: Write -> PageId
pageOfWrite = \case
  OpenW p _ -> p
  ReplyW p _ -> p
  EditW p _ _ -> p
  ResolveW p _ _ -> p
  DeleteCommentW p _ _ -> p
  DeleteThreadW p _ -> p

-- | The world with what the view shows checked against the rules.
checked :: World -> World
checked w = w {faults = w.faults <> problems, seen = seen'}
  where
    shown = readyThreads w.view
    shownComments = [(c, t.page) | t <- shown, c <- t.comments]
    onServer = [c.id | t <- threadsOn w.shownPage w.server, c <- t.comments]
    -- The comments a message the channel has still to deliver brings: a
    -- comment gone only until the next message is not lost (the
    -- subscription's answer is the threads as they were when the page was
    -- subscribed to, and every change after it comes after it).
    onTheWay = concatMap brings w.server.untold
    brings = \case
      MHeard _ (ThreadOpened t) -> map (\c -> c.id) t.comments
      MHeard _ (CommentAdded c) -> [c.id]
      MHeard _ (CommentEdited c) -> [c.id]
      MReplaced _ ts -> [c.id | t <- ts, c <- t.comments]
      _ -> []
    editsOnTheWay = [c.id | MHeard _ (CommentEdited c) <- w.server.untold]
    -- A visit ends when the view goes elsewhere: what was seen on it is
    -- forgotten.
    current = if w.view.page == Just w.shownPage then w.seen else mempty
    seen' = Map.union (Map.fromList [(c.id, (c.body, p)) | (c, p) <- shownComments]) current
    problems
      | w.finished = []
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
    tellAll w = if null w.server.untold then w else tellAll (play w Tell)

drained :: World -> World
drained w
  | null w.outs = w
  | any (isNothing . (.answer)) w.outs = drained (handleAt 0 w)
  | otherwise = drained (deliver 0 w)

-- | Whether a run, settled, shows the server's threads of its page.
settles :: World -> Property
settles w0 =
  counterexample (toS (T.unlines (reverse w.trace))) $
    shape (readyThreadsOf w.view) === shape (Just (threadsOn w.shownPage w.server))
  where
    w = settled w0
    shape = fmap (map (\t -> (t.id, t.resolved, [(c.id, c.body) | c <- t.comments])))

-- | 'Rule' is each rule a run is checked against, as the module's Haddock
-- lists them.
data Rule = OtherPage | Lost | Older | AfterClose
  deriving stock (Eq, Show, Enum, Bounded)

ruleText :: Rule -> [Char]
ruleText = \case
  OtherPage -> "shows no thread of another page, on any run"
  Lost -> "loses no comment the server still has, on any run"
  Older -> "shows no comment's text older than one it showed, on any run"
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

    it ("shows the server's threads once everything out has come back" <> how) $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          settles (foldl' play w0 (filter (/= Finish) run))
