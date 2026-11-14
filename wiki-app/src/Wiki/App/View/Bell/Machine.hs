-- | 'Model' is what the header's bell ("Wiki.App.View.Bell") knows, and
-- 'step' is the one place it changes (WP5.118 of docs/PLAN.md). Every
-- input is an 'Event': a click, an answer of the backend, a message of the
-- live channel, a change of the bell's input, the bell going away. Every
-- output is an 'Effect' as data: ask the backend, listen to the live
-- channel, follow a link. The component turns its actions into events,
-- runs 'step' in one step of its program, and carries out the effects;
-- an answer comes back as one more event.
--
-- A step does not wait. So no step can read the state, wait for the
-- backend, and write the state from what it read: what the bell must
-- remember across an ask is in the ask's effect and comes back in its
-- answer's event, where the step that takes the answer decides.
--
-- = Which answer is taken
--
-- A read of the notifications and a mark of some read both answer with
-- the whole list, so they are one kind of ask ("Wiki.App.View.Latest"):
-- an answer is taken only if no answer to a later ask was taken already.
-- So an older list never replaces a newer one, and a read sent before the
-- reader's mark and answered after it does not put the notification back
-- unread. A new revision of the wiki puts every ask out behind it
-- ('supersede') and reads again: a list read under the old revision may
-- name pages by titles decrypted for a space the reader has left.
--
-- A list taken keeps the notifications the live channel told of after
-- its ask was made and that it does not have yet: the server sent the
-- message after it had answered. For those told of before the ask was
-- made, the list is the truth, and may leave one out (a page the reader
-- may no longer read).
--
-- The buttons that mark are disabled while any mark is out ('busy'), and
-- enabled again only when the last one has come back.
module Wiki.App.View.Bell.Machine
  ( Model (..)
  , Event (..)
  , Effect (..)
  , Sealer (..)
  , initial
  , step
  , busy
  , unreadCount
  , listed
  )
where

import Protolude hiding (State)
import Text.Show (Show (showsPrec))
import Wiki.Api.Notifications (Notifications (..), ReadMark (..))
import Wiki.App.Backend (WikiError)
import Wiki.App.View.Latest (Ask, Asks, madeAfter, newAsk, noAsks, supersede, takes)
import Wiki.Core.Id (NotificationId)
import Wiki.Core.Notification (Notification (..))

-- | 'Model' is the bell's state, without what only the component holds
-- (the router, the element the list is in, the watch for a press outside).
data Model = Model
  { notices :: Maybe (Either WikiError Notifications)
  -- ^ The latest notifications as the bell shows them, or why they could
  -- not be read; 'Nothing' until the first answer.
  , open :: Bool
  -- ^ Whether the list is open under the bell.
  , asks :: Asks
  -- ^ The reads and marks made, and which one's answer is shown.
  , marking :: Int
  -- ^ How many marks of notifications read are out.
  , heard :: [(Notification, Asks)]
  -- ^ The notifications the live channel told of since the list was last
  -- taken, each with the asks as they were when it was told.
  , revision :: Int
  -- ^ The revision of the wiki the bell was last given
  -- ("Wiki.App.View.Common"'s 'Context').
  , closed :: Bool
  -- ^ Whether the bell has gone away: after that no event changes
  -- anything and no effect is made. Halogen's runtime does not run a
  -- component's program after its finalizer; this says the same of the
  -- machine.
  }
  deriving stock (Eq, Show)

-- | 'Sealer' gives a notification its title as the server names it, for a
-- page of an encrypted space: a new revision of the wiki may mean the
-- reader left such a space. A function, shown by its name alone.
newtype Sealer = Sealer (Notification -> Notification)

instance Show Sealer where
  showsPrec _ _ rest = "Sealer" <> rest

-- | 'Event' is everything that happens to the bell. @a@ is what a followed
-- link carries, for the component to follow it.
data Event a
  = -- | The bell is mounted.
    Started
  | -- | The bell goes away.
    Finished
  | -- | The bell was given a revision of the wiki, with the sealer of its
    -- titles under it.
    Revised Int Sealer
  | -- | The reader clicked the bell.
    Toggled
  | -- | The reader pressed outside the list, or Escape.
    Dismissed
  | -- | The live channel told of a new notification.
    Told Notification
  | -- | The live channel opened again after it had closed: what it told
    -- meanwhile was lost.
    Reopened
  | -- | The answer to the read made under this ticket.
    Loaded Ask (Either WikiError Notifications)
  | -- | The reader clicked "Mark read" on one notification.
    MarkClicked NotificationId
  | -- | The reader clicked "Mark all read".
    MarkAllClicked
  | -- | The answer to the mark made under this ticket: the notifications
    -- after it.
    Marked Ask (Either WikiError Notifications)
  | -- | The reader followed a notification's link.
    Followed NotificationId a
  deriving stock (Show)

-- | 'Effect' is what a step asks the component to do.
data Effect a
  = -- | Listen to the live channel for notifications, and hear what it
    -- tells, until 'Unlisten'.
    Listen
  | Unlisten
  | -- | Watch for a press outside the list or Escape, until 'Unwatch'.
    Watch
  | Unwatch
  | -- | Read the notifications; the answer comes back as 'Loaded' with the
    -- ticket.
    Load Ask
  | -- | Mark notifications read; the answer comes back as 'Marked' with
    -- the ticket.
    MarkRead Ask ReadMark
  | -- | Follow the link.
    Follow a
  deriving stock (Eq, Show)

-- | The bell before it is mounted, with the notifications read at once if
-- the backend could ('Nothing' otherwise), under a revision of the wiki.
initial :: Maybe (Either WikiError Notifications) -> Int -> Model
initial notices revision = Model {notices, open = False, asks = noAsks, marking = 0, heard = [], revision, closed = False}

-- | The bell after an event, and what it asks to be done.
step :: Event a -> Model -> (Model, [Effect a])
step event m
  | m.closed = (m, [])
  | otherwise = case event of
      Started
        | isNothing m.notices -> (Listen :) <$> reading m
        | otherwise -> (m, [Listen])
      Finished -> (m {closed = True}, [Unlisten])
      Revised revision (Sealer seal)
        | revision /= m.revision ->
            reading m {revision, asks = supersede m.asks, notices = fmap (\ns -> ns {items = map seal ns.items}) <$> m.notices}
        | otherwise -> (m, [])
      Toggled
        | m.open -> close m
        | otherwise -> (Watch :) <$> reading m {open = True}
      Dismissed -> close m
      Told n ->
        ( m
            { notices = fmap (\ns -> if any (\x -> x.id == n.id) ns.items then ns else ns {unread = ns.unread + 1, items = n : ns.items}) <$> m.notices
            , heard = (n, m.asks) : filter (\(x, _) -> x.id /= n.id) m.heard
            }
        , []
        )
      Reopened -> reading m
      Loaded asked answer -> (taking asked answer m, [])
      MarkClicked i -> marking ReadMark {ids = [i], everything = False} m
      MarkAllClicked -> marking ReadMark {ids = [], everything = True} m
      Marked asked answer ->
        let m' = m {marking = max 0 (m.marking - 1)}
         in (either (const m') (\_ -> taking asked answer m') answer, [])
      Followed i target ->
        let (closedList, unwatched) = close m
            unread = any (\n -> n.id == i && not n.read) (listed m)
            (marked, marks) = if unread then marking ReadMark {ids = [i], everything = False} closedList else (closedList, [])
         in (marked, unwatched <> [Follow target] <> marks)

-- | The answer to an ask taken, if no answer to a later ask was: the list
-- with what the live channel told after the ask was made and the list
-- does not have.
taking :: Ask -> Either WikiError Notifications -> Model -> Model
taking asked answer m = case takes asked m.asks of
  Nothing -> m
  Just after -> case answer of
    Right ns ->
      let kept = [(n, at) | (n, at) <- m.heard, not (asked `madeAfter` at), all (\x -> x.id /= n.id) ns.items]
          missing = map fst kept
       in m {asks = after, notices = Just (Right ns {unread = ns.unread + length (filter (\n -> not n.read) missing), items = missing <> ns.items}), heard = kept}
    Left _ -> m {asks = after, notices = Just answer}

-- | The list closed, and the watch for a press outside ended.
close :: Model -> (Model, [Effect a])
close m = (m {open = False}, [Unwatch | m.open])

-- | A read of the notifications begun.
reading :: Model -> (Model, [Effect a])
reading m = let (ticket, after) = newAsk m.asks in (m {asks = after}, [Load ticket])

-- | A mark of notifications read begun.
marking :: ReadMark -> Model -> (Model, [Effect a])
marking r m = let (ticket, after) = newAsk m.asks in (m {asks = after, marking = m.marking + 1}, [MarkRead ticket r])

-- | Whether a mark is out: the buttons that mark are disabled.
busy :: Model -> Bool
busy m = m.marking > 0

-- | How many notifications the bell counts as unread.
unreadCount :: Model -> Int
unreadCount m = case m.notices of
  Just (Right ns) -> ns.unread
  _ -> 0

-- | The notifications the list shows when it is open.
listed :: Model -> [Notification]
listed m = foldMap (foldMap (\ns -> ns.items)) m.notices
