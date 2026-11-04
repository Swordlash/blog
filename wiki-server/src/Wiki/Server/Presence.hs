-- | Who is editing and who is reading which page, as the live channel
-- records it ("Wiki.Server.Events"): for each connection, the pages its
-- tab said it is editing (WP4.12 of docs/PLAN.md) and the pages it is
-- subscribed to, which it is reading (WP5.55), with whom it was opened as.
-- None of it is stored: it lives as long as the connections do, and a
-- connection that ends removes its entries ('leave', 'leaveReading').
-- That is how a closed tab, a lost network and a stopping server all end
-- someone's editing and reading.
--
-- It is a plain value, which the hub keeps in a
-- 'Control.Concurrent.STM.TVar' and changes in the same transaction as the
-- connections it concerns, so that what a tab is told about a page's
-- editors and readers always matches the value at that moment.
module Wiki.Server.Presence
  ( Presence
  , Key
  , PageReader (..)
  , nobodyEditing
  , startEditing
  , stopEditing
  , leave
  , editorsFor
  , editedBy

    -- * Readers
  , startReading
  , stopReading
  , leaveReading
  , readersFor
  )
where

import Data.Containers.ListUtils (nubOrdOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Protolude
import Wiki.Api.Events (Readers (..), maxReaders)
import Wiki.Core.Id (PageId, UserId)
import Wiki.Core.Version (Author (..))

-- | A connection, by the number the hub assigned it.
type Key = Int

-- | 'PageReader' is who a connection reads as: a signed-in user, named as an
-- editor is, or a visitor who has not signed in, who has no name and is
-- counted, one for each connection.
data PageReader = Named Author | Visitor
  deriving stock (Eq, Show)

-- | Every connection that is editing or reading something, with what it
-- edits and reads, and as whom.
data Presence = Presence
  { editing :: Map Key (Map PageId Author)
  , reading :: Map Key (Map PageId PageReader)
  }
  deriving stock (Eq, Show)

-- | Nobody editing or reading anything.
nobodyEditing :: Presence
nobodyEditing = Presence mempty mempty

-- | A connection's tab is editing a page, as someone; and whether that
-- changed anything (a tab that says so twice changes nothing the second
-- time).
startEditing :: Key -> PageId -> Author -> Presence -> (Presence, Bool)
startEditing k page who p =
  let before = Map.lookup page =<< Map.lookup k p.editing
   in (p {editing = Map.insertWith Map.union k (Map.singleton page who) p.editing}, before /= Just who)

-- | A connection's tab is no longer editing a page; and whether it was.
stopEditing :: Key -> PageId -> Presence -> (Presence, Bool)
stopEditing k page p =
  let was = maybe False (Map.member page) (Map.lookup k p.editing)
   in (p {editing = dropPage k page p.editing}, was)

-- | A connection has ended: it edits nothing any more. The result is the
-- pages it was editing, whose subscribers must be told.
leave :: Key -> Presence -> (Presence, [PageId])
leave k p = (p {editing = Map.delete k p.editing}, maybe [] Map.keys (Map.lookup k p.editing))

-- | Who is editing a page, as a connection is told: everyone editing it on
-- another connection, each person once (the same user in two tabs is one
-- editor), in the order their connections were made. A connection is never
-- told about itself, but is told about its own user editing in another
-- tab.
editorsFor :: Key -> PageId -> Presence -> [Author]
editorsFor k page p =
  nubOrdOn (\a -> a.id) [who | (other, pages) <- Map.toAscList p.editing, other /= k, Just who <- [Map.lookup page pages]]

-- | The pages a connection edits.
editedBy :: Key -> Presence -> [PageId]
editedBy k p = maybe [] Map.keys (Map.lookup k p.editing)

-- | A connection's tab reads a page, as someone: it subscribed to it. The
-- result says whether the page's readers changed: a second tab of a user
-- who reads the page already does not change them, a visitor's does.
startReading :: Key -> PageId -> PageReader -> Presence -> (Presence, Bool)
startReading k page who p =
  let p' = p {reading = Map.insertWith Map.union k (Map.singleton page who) p.reading}
   in (p', readersOf page p /= readersOf page p')

-- | A connection's tab no longer reads a page; and whether that changed
-- the page's readers.
stopReading :: Key -> PageId -> Presence -> (Presence, Bool)
stopReading k page p =
  let p' = p {reading = dropPage k page p.reading}
   in (p', readersOf page p /= readersOf page p')

-- | A connection has ended: it reads nothing any more. The result is the
-- pages whose readers that changed, whose subscribers must be told.
leaveReading :: Key -> Presence -> (Presence, [PageId])
leaveReading k p =
  let p' = p {reading = Map.delete k p.reading}
      read' = maybe [] Map.keys (Map.lookup k p.reading)
   in (p', [page | page <- read', readersOf page p /= readersOf page p'])

-- | Who reads a page, as a connection is told: the signed-in users of the
-- other connections reading it, each once, the connection's own user left
-- out (in whichever tab they read), the first 'maxReaders' of them by
-- name; how many there are; and how many connections of visitors read it,
-- the connection itself excepted.
readersFor :: Key -> PageId -> Presence -> Readers
readersFor k page p =
  Readers {some = take maxReaders (sortOn (\a -> (T.toCaseFold a.name, a.id)) named), total = length named, visitors}
  where
    own = case Map.elems <$> Map.lookup k p.reading of
      Just (Named a : _) -> Just a.id
      _ -> Nothing
    others = [who | (other, pages) <- Map.toAscList p.reading, other /= k, Just who <- [Map.lookup page pages]]
    named = nubOrdOn (\a -> a.id) [a | Named a <- others, Just a.id /= own]
    visitors = length [() | Visitor <- others]

-- | What a page's readers are, for telling whether they changed: the users
-- by id, and how many visitors' connections.
readersOf :: PageId -> Presence -> (Set UserId, Int)
readersOf page p =
  let found = mapMaybe (Map.lookup page) (Map.elems p.reading)
   in (Set.fromList [a.id | Named a <- found], length [() | Visitor <- found])

-- | A connection's map of pages without one of them, and without the
-- connection once it has none left.
dropPage :: Key -> PageId -> Map Key (Map PageId a) -> Map Key (Map PageId a)
dropPage k page = Map.update (\pages -> let rest = Map.delete page pages in if Map.null rest then Nothing else Just rest) k
