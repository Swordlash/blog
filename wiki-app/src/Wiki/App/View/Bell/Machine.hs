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
-- The rules in this module are the component's as they were before the
-- machine, unchanged: an answer to a read is dropped when the wiki's
-- revision changed while the read was out, and the list it brings keeps
-- the notifications the live channel told of while the read was out.
module Wiki.App.View.Bell.Machine
  ( Model (..)
  , Event (..)
  , Effect (..)
  , Fetch (..)
  , Mark (..)
  , Sealer (..)
  , initial
  , step
  , unreadCount
  , listed
  )
where

import Protolude hiding (State)
import Text.Show (Show (showsPrec))
import Wiki.Api.Notifications (Notifications (..), ReadMark (..))
import Wiki.App.Backend (WikiError)
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
  , busy :: Bool
  -- ^ Whether a mark of notifications read is out: the buttons that mark
  -- are disabled.
  , heard :: [Notification]
  -- ^ The notifications the live channel told of since the list was last
  -- read. A read keeps those told of while it was out and not in its
  -- answer yet; the answer is the truth for those told of before it was
  -- asked.
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

-- | 'Fetch' is what a read of the notifications remembers until its answer:
-- the revision it was asked under, and the notifications the live channel
-- had told of when it was asked.
data Fetch = Fetch
  { revision :: Int
  , before :: [NotificationId]
  }
  deriving stock (Eq, Show)

-- | 'Mark' is what a mark of notifications read remembers until its
-- answer: the revision it was asked under.
newtype Mark = Mark {revision :: Int}
  deriving stock (Eq, Show)

-- | 'Sealer' gives a notification its title as the server names it, for a
-- page of an encrypted space: a new revision of the wiki may mean the
-- reader left such a space. A function, shown by its name alone.
newtype Sealer = Sealer (Notification -> Notification)

instance Show Sealer where
  showsPrec _ _ rest = "Sealer" <> rest

-- | 'Event' is everything that happens to the bell. @a@ is what a
-- followed link carries, for the component to follow it.
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
  | -- | The answer to a read of the notifications.
    Loaded Fetch (Either WikiError Notifications)
  | -- | The reader clicked "Mark read" on one notification.
    MarkClicked NotificationId
  | -- | The reader clicked "Mark all read".
    MarkAllClicked
  | -- | The answer to a mark of notifications read: the notifications after
    -- it.
    Marked Mark (Either WikiError Notifications)
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
  | -- | Read the notifications; the answer comes back as 'Loaded'.
    Load Fetch
  | -- | Mark notifications read; the answer comes back as 'Marked'.
    MarkRead Mark ReadMark
  | -- | Follow the link.
    Follow a
  deriving stock (Eq, Show)

-- | The bell before it is mounted, with the notifications read at once if
-- the backend could ('Nothing' otherwise), under a revision of the wiki.
initial :: Maybe (Either WikiError Notifications) -> Int -> Model
initial notices revision = Model {notices, open = False, busy = False, heard = [], revision, closed = False}

-- | The bell after an event, and what it asks to be done.
step :: Event a -> Model -> (Model, [Effect a])
step event m
  | m.closed = (m, [])
  | otherwise = case event of
      Started -> (m, Listen : [Load (fetchOf m) | isNothing m.notices])
      Finished -> (m {closed = True}, [Unlisten])
      Revised revision (Sealer seal)
        | revision /= m.revision ->
            let m' = m {revision, notices = fmap (\ns -> ns {items = map seal ns.items}) <$> m.notices}
             in (m', [Load (fetchOf m')])
        | otherwise -> (m, [])
      Toggled
        | m.open -> close m
        | otherwise -> (m {open = True}, [Watch, Load (fetchOf m)])
      Dismissed -> close m
      Told n ->
        ( m
            { notices = fmap (\ns -> if any (\x -> x.id == n.id) ns.items then ns else ns {unread = ns.unread + 1, items = n : ns.items}) <$> m.notices
            , heard = n : filter (\x -> x.id /= n.id) m.heard
            }
        , []
        )
      Reopened -> (m, [Load (fetchOf m)])
      Loaded asked answer
        | m.revision /= asked.revision -> (m, [])
        | otherwise -> case answer of
            Right ns ->
              let missing = [n | n <- m.heard, n.id `notElem` asked.before, all (\x -> x.id /= n.id) ns.items]
               in (m {notices = Just (Right ns {unread = ns.unread + length (filter (\n -> not n.read) missing), items = missing <> ns.items}), heard = missing}, [])
            Left _ -> (m {notices = Just answer}, [])
      MarkClicked i -> marking ReadMark {ids = [i], everything = False} m
      MarkAllClicked -> marking ReadMark {ids = [], everything = True} m
      Marked asked answer ->
        (m {busy = False, notices = if m.revision /= asked.revision then m.notices else either (const m.notices) (Just . Right) answer}, [])
      Followed i target ->
        let (closedList, unwatched) = close m
            unread = any (\n -> n.id == i && not n.read) (listed m)
            (marked, marks) = if unread then marking ReadMark {ids = [i], everything = False} closedList else (closedList, [])
         in (marked, unwatched <> [Follow target] <> marks)

-- | The list closed, and the watch for a press outside ended.
close :: Model -> (Model, [Effect a])
close m = (m {open = False}, [Unwatch | m.open])

-- | A mark of notifications read begun.
marking :: ReadMark -> Model -> (Model, [Effect a])
marking r m = (m {busy = True}, [MarkRead (Mark m.revision) r])

-- | What a read asked now remembers.
fetchOf :: Model -> Fetch
fetchOf m = Fetch {revision = m.revision, before = map (\n -> n.id) m.heard}

-- | How many notifications the bell counts as unread.
unreadCount :: Model -> Int
unreadCount m = case m.notices of
  Just (Right ns) -> ns.unread
  _ -> 0

-- | The notifications the list shows when it is open.
listed :: Model -> [Notification]
listed m = foldMap (foldMap (\ns -> ns.items)) m.notices
