-- | The header's bell as a machine ("Wiki.App.View.Bell.Machine"), run on
-- generated runs: the reader's clicks, the server's changes, the live
-- channel's messages, the answers to the bell's asks in any order, a new
-- revision of the wiki and the bell going away, anywhere.
--
-- A small model of the server ('Server') answers each ask. An ask has
-- three moments: the bell sends it, the server handles it (a read takes
-- the list as it is then, a mark changes it and takes it after), and the
-- answer comes back. The server handles asks in the order they were sent,
-- at any time before their answers come back; the answers come back in
-- any order ('Handle', 'Deliver'). That is the HTTP backend with one
-- server over one connection: a request sent later reaches the server
-- later, and the responses travel back on their own. The in-memory
-- backend is the case where each ask is handled at once. Runs where the
-- server handles asks in any order ('HandleOut', 'genUnordered') break
-- one rule, as the group of examples for them says.
--
-- What the bell shows is read from the model after every step, and must
-- hold:
--
-- * a notification shown read is never shown unread again: the server
--   never marks one unread, so an unread one shown after a read one is an
--   older answer taken over a newer one, or the reader's own mark undone;
-- * a notification once listed stays listed: this server never drops one;
-- * the count is the number of unread notifications listed;
-- * the buttons that mark are disabled exactly while a mark is out;
-- * nothing is asked or listened to after the bell went away;
-- * every ask is made under a new ticket, which the state names;
-- * once everything out has come back and one more read is answered, the
--   bell shows the server's list;
-- * once everything out has come back, the bell shows the server's list
--   with no read more, when every change of the server was the reader's
--   own or told over the live channel.
module Test.Bell
  ( spec

    -- * Shared with the component's tests
  , Step (..)
  , Server (..)
  , World (..)
  , Rule (..)
  , start
  , startCached
  , play
  , emptyServer
  , genRun
  , shrinkRun
  , made
  , handleRead
  , handleMark
  , noticeOf
  )
where

import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess)
import Test.QuickCheck (Gen, Property, chooseInt, counterexample, forAllShrinkShow, frequency, listOf, shrinkList, (.&&.), (===))
import Test.QuickCheck qualified as QC
import Wiki.Api.Notifications (Notifications (..), ReadMark (..))
import Wiki.App.Backend.Http.Cache (Cache (notices), Stored (..), askingNotices, changedBy, emptyCache, forgetNotices, markedAnswer, storedNotices, storedOf, withNotice, withNotices)
import Wiki.App.View.Bell.Machine
import Wiki.App.View.Latest (madeAfter)
import Wiki.Core.Id (NotificationId (..), PageId (..), UserId (..))
import Wiki.Core.Notification (Kind (..), Notification (..), PageLocation (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Version (Author (..))

-- | 'Server' is the reader's notifications on the server, and what the
-- live channel has still to tell the tab of them.
data Server = Server
  { count :: Int
  -- ^ How many notifications the server has made: the next one's number.
  , notes :: [Notification]
  -- ^ The reader's notifications, the newest first.
  , untold :: [Notification]
  -- ^ The notifications the live channel has yet to tell the tab of, the
  -- oldest first.
  }
  deriving stock (Show)

emptyServer :: Server
emptyServer = Server {count = 0, notes = [], untold = []}

-- | The server after it made one more notification for the reader, to be
-- told over the live channel.
made :: Server -> Server
made s = s {count = s.count + 1, notes = n : s.notes, untold = s.untold <> [n]}
  where
    n = noticeOf (s.count + 1)

-- | The notification numbered so.
noticeOf :: Int -> Notification
noticeOf k =
  Notification
    { id = NotificationId ("n" <> show k)
    , kind = Replied
    , page = PageId ("page-" <> show k)
    , thread = Nothing
    , actor = Author {id = UserId "user-reader", name = "Rita Reader", avatar = Nothing}
    , title = "Page " <> show k
    , excerpt = ""
    , createdAt = UTCTime (fromGregorian 2026 11 14) (fromIntegral k)
    , read = False
    , location = Just PageLocation {space = [slug "blog"], page = [slug ("page-" <> show k)]}
    }
  where
    slug = either (panic . show) identity . mkSlug

-- | The server's answer to a read: its list as it is now.
handleRead :: Server -> Notifications
handleRead s = Notifications {unread = length (filter (\n -> not n.read) s.notes), items = s.notes}

-- | A mark handled by the server: its list after the mark, and the answer.
handleMark :: ReadMark -> Server -> (Server, Notifications)
handleMark r s = (s', handleRead s')
  where
    s' = s {notes = map (\n -> if r.everything || n.id `elem` r.ids then n {read = True} else n) s.notes}

-- | 'Step' is one thing that happens in a run. A step that cannot happen
-- in the state it comes to (a click on a button not shown, an answer when
-- nothing is out) is skipped, so that a run shrinks to any of its parts.
data Step
  = -- | The reader clicks the bell.
    ClickBell
  | -- | The reader presses outside the open list.
    PressOutside
  | -- | The reader clicks "Mark read" on the unread notification at this
    -- place among those listed unread.
    ClickMark Int
  | -- | The reader clicks "Mark all read".
    ClickMarkAll
  | -- | The reader follows the link of the notification at this place.
    ClickLink Int
  | -- | The server makes a notification for the reader.
    Make
  | -- | The reader marks the unread notification at this place read in
    -- another tab: the server changes, and nothing tells this tab.
    ReadElsewhere Int
  | -- | The live channel tells the oldest notification it has to tell.
    Tell
  | -- | The live channel closes and opens again: what it had to tell is
    -- lost, and the bell is told it reopened.
    Reconnect
  | -- | The server handles the oldest ask it has not handled.
    Handle
  | -- | The server handles the ask at this place among those it has not
    -- handled, out of the order they were sent: only in the runs of
    -- 'genUnordered'.
    HandleOut Int
  | -- | The handled answer at this place among those handled comes back.
    Deliver Int
  | -- | The bell is given a new revision of the wiki.
    Revise
  | -- | The bell goes away.
    Finish
  deriving stock (Eq, Show)

-- | A run's steps.
genRun :: Gen [Step]
genRun = listOf (genStep [])

-- | A run's steps, the server handling asks in any order.
genUnordered :: Gen [Step]
genUnordered = listOf (genStep [(4, HandleOut <$> chooseInt (0, 3))])

genStep :: [(Int, Gen Step)] -> Gen Step
genStep more =
  frequency $
    more
      <> [ (4, pure ClickBell)
         , (1, pure PressOutside)
         , (3, ClickMark <$> chooseInt (0, 3))
         , (1, pure ClickMarkAll)
         , (1, ClickLink <$> chooseInt (0, 3))
         , (4, pure Make)
         , (2, ReadElsewhere <$> chooseInt (0, 3))
         , (4, pure Tell)
         , (1, pure Reconnect)
         , (6, pure Handle)
         , (6, Deliver <$> chooseInt (0, 3))
         , (1, pure Revise)
         , (1, pure Finish)
         ]

shrinkRun :: [Step] -> [[Step]]
shrinkRun = shrinkList shrinkStep
  where
    shrinkStep = \case
      ClickMark i -> ClickMark <$> [0 .. i - 1]
      ClickLink i -> ClickLink <$> [0 .. i - 1]
      ReadElsewhere i -> ReadElsewhere <$> [0 .. i - 1]
      Deliver i -> Deliver <$> [0 .. i - 1]
      HandleOut i -> Handle : (HandleOut <$> [0 .. i - 1])
      _ -> []

-- | An ask the bell made, and its answer once the server handled it.
data Out = Out
  { ask :: Effect ()
  , answer :: Maybe Notifications
  , sent :: Maybe (Int, Stored, [NotificationId])
  -- ^ Over the HTTP backend's cache, for a read sent to the server: the
  -- cache as it was when the read was sent, and the notifications the
  -- live channel had told of then ("Wiki.App.Backend.Http"'s
  -- @fetchedNotices@).
  }
  deriving stock (Show)

-- | 'Tab' is what the HTTP backend keeps in the tab for the bell: its
-- cache, with the changes counted ("Wiki.App.Backend.Http.Cache"), and
-- every notification the live channel told of. A read is answered from
-- the cache when the cache has the notifications; otherwise it is sent,
-- and its answer, with what the channel told while it was out, is stored
-- if the cache did not change meanwhile. A message of the channel adds
-- its notification to the cached ones ('withNotice'), the channel
-- reopened forgets them ('forgetNotices'), a mark's answer replaces them
-- ('withNotices'): each a change.
data Tab = Tab
  { stored :: Stored
  , told :: [Notification]
  }
  deriving stock (Show)

-- | A run under way: the bell, the server, the asks out, and what was
-- seen so far.
data World = World
  { bell :: Model
  , server :: Server
  , outs :: [Out]
  -- ^ The asks out, in the order they were made.
  , listening :: Int
  -- ^ 'Listen's less 'Unlisten's.
  , finished :: Bool
  , revisions :: Int
  , trace :: [Text]
  -- ^ What happened, the latest first, for a counterexample.
  , faults :: [(Rule, Text)]
  -- ^ What broke a rule, the first first.
  , seenRead :: Map NotificationId Bool
  -- ^ Every notification listed so far, and whether it was ever listed
  -- read.
  , tab :: Maybe Tab
  -- ^ The HTTP backend's cache, when the bell is over it; 'Nothing' for a
  -- backend that asks the server every time.
  }

-- | A run from its start: the bell mounted, over a backend that could not
-- answer at once.
start :: World
start = startOver Nothing

-- | A run from its start, over the HTTP backend's cache, empty.
startCached :: World
startCached = startOver (Just Tab {stored = storedOf emptyCache, told = []})

startOver :: Maybe Tab -> World
startOver tab = afterEvent "mounted" Started World {bell = initial Nothing 0, server = emptyServer, outs = [], listening = 0, finished = False, revisions = 0, trace = [], faults = [], seenRead = mempty, tab}

-- | The tab's cache after a change.
changing :: (Cache -> Cache) -> World -> World
changing f w = w {tab = fmap (\t -> t {stored = changedBy f t.stored}) w.tab}

-- | The world after a step.
play :: World -> Step -> World
play w = \case
  ClickBell -> afterEvent "clicks the bell" Toggled w
  PressOutside
    | w.bell.open -> afterEvent "presses outside" Dismissed w
    | otherwise -> w
  ClickMark i
    | w.bell.open && not (busy w.bell), Just n <- atMay [n | n <- listed w.bell, not n.read] i -> afterEvent ("marks " <> idText n <> " read") (MarkClicked n.id) w
    | otherwise -> w
  ClickMarkAll
    | w.bell.open && not (busy w.bell) && unreadCount w.bell > 0 -> afterEvent "marks all read" MarkAllClicked w
    | otherwise -> w
  ClickLink i
    | w.bell.open, Just n <- atMay (listed w.bell) i -> afterEvent ("follows " <> idText n) (Followed n.id ()) w
    | otherwise -> w
  Make -> noted ("the server makes n" <> show (w.server.count + 1)) w {server = made w.server}
  ReadElsewhere i -> case atMay [n | n <- w.server.notes, not n.read] i of
    Just n -> noted ("another tab marks " <> idText n <> " read") w {server = fst (handleMark ReadMark {ids = [n.id], everything = False} w.server)}
    Nothing -> w
  Tell -> case w.server.untold of
    n : rest -> afterEvent ("told " <> idText n) (Told n) (changing (withNotice n) w {server = w.server {untold = rest}, tab = fmap (\t -> t {told = take 50 (n : t.told)}) w.tab})
    [] -> w
  Reconnect -> afterEvent "reconnected" Reopened (changing forgetNotices w {server = w.server {untold = []}})
  Handle -> handleAt 0 w
  HandleOut i -> handleAt i w
  Deliver i -> case atMay [(k, o, a) | (k, o) <- zip [0 :: Int ..] w.outs, Just a <- [o.answer]] i of
    Just (k, o, a) ->
      let w' = w {outs = [x | (j, x) <- zip [0 ..] w.outs, j /= k]}
       in case o.ask of
            Load f -> case (w'.tab, o.sent) of
              -- Over the cache, a read sent to the server: its answer
              -- with what the channel told meanwhile, stored if the cache
              -- did not change since it was sent.
              (Just t, Just (asked, sentAt, toldBefore)) ->
                let missing = [n | n <- t.told, n.id `notElem` toldBefore, all (\x -> x.id /= n.id) a.items]
                    merged = Notifications {unread = a.unread + length (filter (\n -> not n.read) missing), items = missing <> a.items}
                    t' = t {stored = storedNotices asked sentAt (withNotices (Right merged)) t.stored}
                 in afterEvent ("answer to " <> askText o.ask <> ": " <> listText merged) (Loaded f (Right merged)) w' {tab = Just t'}
              _ -> afterEvent ("answer to " <> askText o.ask) (Loaded f (Right a)) w'
            MarkRead m _ -> afterEvent ("answer to " <> askText o.ask) (Marked m (Right a)) w' {tab = (\t -> t {stored = maybe identity (\(_, sentAt, _) -> markedAnswer sentAt (Right a)) o.sent t.stored}) <$> w'.tab}
            _ -> w
    Nothing -> w
  Revise -> afterEvent ("revision " <> show (w.revisions + 1)) (Revised (w.revisions + 1) (Sealer identity)) w {revisions = w.revisions + 1}
  Finish -> afterEvent "goes away" Finished w {finished = True}

-- | The world after the server handled the ask at this place among those
-- it has not handled: a read takes the list as it is, a mark changes it.
handleAt :: Int -> World -> World
handleAt i w = case atMay [k | (k, o) <- zip [0 :: Int ..] w.outs, isNothing o.answer] i of
  Just k
    | Just o <- atMay w.outs k ->
        let (server, answer) = case o.ask of
              MarkRead _ r -> handleMark r w.server
              _ -> (w.server, handleRead w.server)
         in noted ("the server handles " <> askText o.ask <> ": " <> listText answer) w {server, outs = [if j == k then x {answer = Just answer} else x | (j, x) <- zip [0 ..] w.outs]}
  _ -> w

-- | The world after the bell took an event, with its effects carried out
-- and the rules checked.
afterEvent :: Text -> Event () -> World -> World
afterEvent what event w =
  fromTheCache
    . checked
    . noted (what <> effectsText)
    $ w
      { bell
      , outs = w.outs <> [outOf e | e <- effects, isAsk e]
      , tab = counted <$> w.tab
      , listening = w.listening + length (filter (== Listen) effects) - length (filter (== Unlisten) effects)
      , faults =
          w.faults
            <> [(QuietAfterClose, what <> ": " <> show effects <> " after the bell went away") | w.finished, not (null effects), what /= "goes away"]
            <> [(AsksNamed, what <> ": " <> show e <> " is not a new ask the state names") | e <- effects, Just t <- [ticketOf e], not (t `madeAfter` w.bell.asks) || t `madeAfter` bell.asks]
      }
  where
    (bell, effects) = step event w.bell
    -- The tab with the reads it sends to the server counted.
    counted t = foldl' (\t' e -> case (e, t'.stored.cache.notices) of (Load _, Nothing) -> t' {stored = snd (askingNotices t'.stored)}; _ -> t') t effects
    -- An ask out. Over the cache, a read the cache can answer is answered
    -- at once, from it, and goes to no server.
    outOf e = case (e, w.tab) of
      (Load _, Just t) -> case t.stored.cache.notices of
        Just (Right known) -> Out {ask = e, answer = Just known, sent = Nothing}
        _ -> let (asked, sentAt) = askingNotices t.stored in Out {ask = e, answer = Nothing, sent = Just (asked, sentAt, map (\n -> n.id) t.told)}
      (MarkRead _ _, Just t) -> Out {ask = e, answer = Nothing, sent = Just (0, t.stored, [])}
      _ -> Out {ask = e, answer = Nothing, sent = Nothing}
    effectsText = if null effects then "" else " -> " <> T.intercalate ", " (map effectText effects)
    isAsk = isJust . ticketOf
    ticketOf = \case
      Load t -> Just t
      MarkRead t _ -> Just t
      _ -> Nothing

-- | The world after the answers the cache gave came back. Over the HTTP
-- backend a read the cache can answer returns at once: its answer is the
-- next thing the bell takes, before any other answer can come.
fromTheCache :: World -> World
fromTheCache w = case [k | (k, o) <- zip [0 :: Int ..] w.outs, isJust w.tab, isNothing o.sent, isJust o.answer, isLoad o.ask] of
  k : _ -> case atMay w.outs k of
    Just Out {ask = Load f, answer = Just a} -> afterEvent "answer to a read, from the cache" (Loaded f (Right a)) w {outs = [x | (j, x) <- zip [0 ..] w.outs, j /= k]}
    _ -> w
  [] -> w
  where
    isLoad = \case
      Load _ -> True
      _ -> False

-- | The world with what the bell shows checked against the rules.
checked :: World -> World
checked w = w {faults = w.faults <> problems, seenRead = Map.unionWith (||) w.seenRead (Map.fromList [(n.id, n.read) | n <- shown])}
  where
    shown = listed w.bell
    marksOut = not w.finished && any (\o -> case o.ask of MarkRead _ _ -> True; _ -> False) w.outs
    problems =
      [(ReadStaysRead, idText n <> " was shown read, and is shown unread again") | n <- shown, not n.read, Map.lookup n.id w.seenRead == Just True]
        <> [(NothingLost, "listed before and gone: " <> T.intercalate ", " gone) | let gone = [unId i | i <- Map.keys w.seenRead, i `notElem` map (\n -> n.id) shown], not (null gone), isJust (rightNotices w.bell)]
        <> [(CountMatches, "the count says " <> show (unreadCount w.bell) <> ", and " <> show (length (filter (\n -> not n.read) shown)) <> " are listed unread") | isJust (rightNotices w.bell), unreadCount w.bell /= length (filter (\n -> not n.read) shown)]
        <> [(BusyWhileMarking, "the buttons that mark are " <> (if busy w.bell then "disabled with no mark out" else "enabled with a mark out")) | not w.finished, busy w.bell /= marksOut]
        <> [(ListedOnce, "a notification is listed twice") | let ids = map (\n -> n.id) shown, nub ids /= ids]
        <> [(QuietAfterClose, "listening after the bell went away") | w.finished, w.listening /= 0]

-- | 'Rule' is each rule a run is checked against, as the module's Haddock
-- lists them.
data Rule
  = ReadStaysRead
  | NothingLost
  | CountMatches
  | BusyWhileMarking
  | ListedOnce
  | QuietAfterClose
  | AsksNamed
  deriving stock (Eq, Show, Enum, Bounded)

rightNotices :: Model -> Maybe Notifications
rightNotices m = case m.notices of
  Just (Right ns) -> Just ns
  _ -> Nothing

noted :: Text -> World -> World
noted what w = w {trace = (what <> "    [" <> summary w.bell <> "]") : w.trace}

-- | What the bell shows, in short: the count, and each notification with
-- a star when unread.
summary :: Model -> Text
summary m =
  "count " <> show (unreadCount m) <> ", list " <> listText Notifications {unread = 0, items = listed m} <> (if busy m then ", busy" else "") <> (if m.open then ", open" else "")

listText :: Notifications -> Text
listText ns = "[" <> T.intercalate " " [idText n <> (if n.read then "" else "*") | n <- ns.items] <> "]"

idText :: Notification -> Text
idText n = unId n.id

unId :: NotificationId -> Text
unId (NotificationId t) = t

askText :: Effect () -> Text
askText = \case
  Load _ -> "a read"
  MarkRead _ r -> "a mark of " <> (if r.everything then "all" else T.intercalate " " (map unId r.ids))
  e -> show e

effectText :: Effect () -> Text
effectText = \case
  Load _ -> "read"
  MarkRead _ r -> "mark " <> (if r.everything then "all" else T.intercalate " " (map unId r.ids))
  e -> T.toLower (show e)

-- | The run settled: everything the channel has to tell told, every ask
-- out handled and answered (the oldest answer first), then one more read,
-- as the channel reopening asks, handled and answered.
settled :: World -> World
settled = finalRead . quieted
  where
    finalRead w = drained (afterEvent "reconnected, to settle" Reopened (changing forgetNotices w))

-- | The run quieted: everything the channel has to tell told, and every
-- ask out handled and answered, the oldest answer first.
quieted :: World -> World
quieted = drained . tellAll
  where
    tellAll w = if null w.server.untold then w else tellAll (play w Tell)

drained :: World -> World
drained w
  | null w.outs = w
  | any (isNothing . (.answer)) w.outs = drained (play w Handle)
  | otherwise = drained (play w (Deliver 0))

-- | A run's outcome against one rule, as QuickCheck shows it: the run,
-- then what broke the rule.
verdict :: Rule -> World -> Property
verdict rule w =
  counterexample (toS (T.unlines (reverse w.trace)))
    . counterexample (toS (T.unlines ("Broken:" : [t | (r, t) <- w.faults, r == rule])))
    $ null [() | (r, _) <- w.faults, r == rule]

-- | How many runs each property tries, at least: more when hspec is given
-- @--qc-max-success@ (a nightly run with many more, say 1,000,000, takes
-- the same option). Fewer let real faults through. At 2,000 runs, 30 runs
-- of the suite found the mark's answer stored while a later read was out
-- (fixed in ba46d6c1) twice, about once in 30,000 runs of that property:
-- the 12,000 runs 76d971ff's message counts had missed it. And no count
-- would have found what fefbc37b broke over the HTTP backend's cache,
-- whatever its message says of 160,000 runs: the cache was not in the
-- model yet. The rule a run checks matters more than how many runs. The
-- whole module costs about a second natively per 2,000 runs of each
-- property; the suite is native only (the machine is pure, and wasm would
-- check nothing the compiler makes different).
cases :: Int
cases = 20_000

spec :: Spec
spec = describe "Wiki.App.View.Bell.Machine" $ modifyMaxSuccess (max cases) $ do
  for_ [minBound .. maxBound] $ \rule ->
    it (ruleText rule) $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          verdict rule (foldl' play start (if rule == QuietAfterClose then run <> [Finish] <> run else run))

  it "shows the server's list once everything out has come back and one more read is answered" $
    QC.property $
      forAllShrinkShow genRun shrinkRun show $ \run ->
        settles settled (foldl' play start (filter (/= Finish) run))

  it "shows the server's list once everything out has come back, when every change was the reader's or told" $
    QC.property $
      forAllShrinkShow genRun shrinkRun show $ \run ->
        settles quieted (foldl' play start (filter (`notElem` [Finish]) (filter (not . elsewhere) run)))

  describe "over the HTTP backend's cache" $ do
    for_ [minBound .. maxBound] $ \rule ->
      it (ruleText rule) $
        QC.property $
          forAllShrinkShow genRun shrinkRun show $ \run ->
            verdict rule (foldl' play startCached (if rule == QuietAfterClose then run <> [Finish] <> run else run))

    it "keeps a notification the channel told when a mark handled before it was made is answered last" $ do
      -- n2 is told while a read is out; the backend merges it into the
      -- read's answer, and the bell takes that list; the reader's mark,
      -- asked after the read and handled before n2 was made, comes last.
      let w = foldl' play startCached [Reconnect, Handle, Reconnect, ClickBell, Handle, Deliver 0, Handle, Make, Tell, Handle, ClickLink 0, Handle, Make, Deliver 0, Tell, Deliver 0, Deliver 1]
      [t | (NothingLost, t) <- w.faults] `shouldBe` []

    it "shows the server's list once everything out has come back and the channel reopened" $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          settles settled (foldl' play startCached (filter (/= Finish) run))

    it "shows the server's list once everything out has come back, when every change was the reader's or told" $
      QC.property $
        forAllShrinkShow genRun shrinkRun show $ \run ->
          settles quieted (foldl' play startCached (filter (`notElem` [Finish]) (filter (not . elsewhere) run)))

  -- What the model assumes of the server: it handles the asks in the
  -- order they were sent ('Handle'), as one server reached over one
  -- connection does. Over HTTP/2, or two connections, a read and a mark
  -- sent in that order may be handled the other way round ('HandleOut').
  -- Then every rule but one still holds: the bell takes the answer to the
  -- later ask, which may be the older list, and a notification it listed
  -- goes until the live channel tells of it (the run below). A read
  -- flag cannot go back ('known' in the machine), but a list's members
  -- can: the server may drop one (a page no longer readable), so the bell
  -- cannot keep what an answer leaves out. Only an order of the server's
  -- own (a version on the list) would close it.
  describe "when the server handles asks in any order" $ do
    it "is known to lose a notification it listed until the channel tells of it" $
      [t | (NothingLost, t) <- (foldl' play start [ClickBell, HandleOut 1, Make, Handle, Deliver 0, Deliver 0]).faults] `shouldNotBe` []

    for_ [rule | rule <- [minBound .. maxBound], rule /= NothingLost] $ \rule ->
      it (ruleText rule) $
        QC.property $
          forAllShrinkShow genUnordered shrinkRun show $ \run ->
            verdict rule (foldl' play start (if rule == QuietAfterClose then run <> [Finish] <> run else run))

    it "shows the server's list once everything out has come back, when every change was the reader's or told" $
      QC.property $
        forAllShrinkShow genUnordered shrinkRun show $ \run ->
          settles quieted (foldl' play start (filter (`notElem` [Finish]) (filter (not . elsewhere) run)))

-- | Whether a run, settled, shows the server's list and count, with no
-- mark out.
settles :: (World -> World) -> World -> Property
settles settle w0 = counterexample (toS (T.unlines (reverse w.trace))) (shown === truth .&&. unreadCount w.bell === length (filter (not . snd) truth) .&&. busy w.bell === False)
  where
    w = settle w0
    shown = [(n.id, n.read) | n <- listed w.bell]
    truth = [(n.id, n.read) | n <- w.server.notes]

-- | Whether a step changes the server in a way nothing tells the tab of.
elsewhere :: Step -> Bool
elsewhere = \case
  ReadElsewhere _ -> True
  _ -> False

-- | What a rule says, as an example's name.
ruleText :: Rule -> [Char]
ruleText = \case
  ReadStaysRead -> "never shows unread a notification it showed read, on any run"
  NothingLost -> "never loses a notification it listed, on any run"
  CountMatches -> "counts the unread notifications it lists, on any run"
  BusyWhileMarking -> "disables the buttons that mark exactly while a mark is out, on any run"
  ListedOnce -> "lists each notification once, on any run"
  QuietAfterClose -> "asks nothing and stops listening once it has gone away"
  AsksNamed -> "makes every ask under a new ticket its state names, on any run"
