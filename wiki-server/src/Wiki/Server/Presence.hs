-- | Who is editing which page, as the live channel keeps it ("Wiki.Server.Events",
-- WP4.12 of docs/PLAN.md): for each connection, the pages its tab said it
-- edits, with who it was opened as. Nothing of it is written down: it lives
-- as long as the connections do, and a connection that ends takes its share
-- with it ('leave'), which is how a closed tab, a lost network and a
-- stopping server all end someone's editing.
--
-- It is a plain value, kept by the hub in a 'Control.Concurrent.STM.TVar'
-- and changed in the same transaction as the connections it is about, so
-- that what a tab is told of a page's editors is always what the value
-- says at that moment.
module Wiki.Server.Presence
  ( Presence
  , Key
  , nobodyEditing
  , startEditing
  , stopEditing
  , leave
  , editorsFor
  , editedBy
  )
where

import Data.Containers.ListUtils (nubOrdOn)
import Data.Map.Strict qualified as Map
import Protolude
import Wiki.Core.Id (PageId)
import Wiki.Core.Version (Author (..))

-- | A connection, by the number the hub gave it.
type Key = Int

-- | Every connection that edits something, with what it edits and as whom.
newtype Presence = Presence (Map Key (Map PageId Author))
  deriving stock (Eq, Show)

-- | Nobody editing anything.
nobodyEditing :: Presence
nobodyEditing = Presence mempty

-- | A connection's tab edits a page, as someone; and whether that changed
-- anything (a tab that says so twice changes nothing the second time).
startEditing :: Key -> PageId -> Author -> Presence -> (Presence, Bool)
startEditing k page who (Presence p) =
  let before = Map.lookup page =<< Map.lookup k p
   in (Presence (Map.insertWith Map.union k (Map.singleton page who) p), before /= Just who)

-- | A connection's tab no longer edits a page; and whether it did.
stopEditing :: Key -> PageId -> Presence -> (Presence, Bool)
stopEditing k page (Presence p) =
  let was = maybe False (Map.member page) (Map.lookup k p)
      dropped = Map.update (\pages -> let rest = Map.delete page pages in if Map.null rest then Nothing else Just rest) k p
   in (Presence dropped, was)

-- | A connection has ended: it edits nothing any more. The pages it edited,
-- whose subscribers are to be told.
leave :: Key -> Presence -> (Presence, [PageId])
leave k (Presence p) = (Presence (Map.delete k p), maybe [] Map.keys (Map.lookup k p))

-- | Who edits a page, as a connection is told: everyone editing it on
-- another connection, each person once (the same user in two tabs is one
-- editor), in the order their connections were made. A connection never
-- hears of itself, but does hear of its own user editing in another tab.
editorsFor :: Key -> PageId -> Presence -> [Author]
editorsFor k page (Presence p) =
  nubOrdOn (\a -> a.id) [who | (other, pages) <- Map.toAscList p, other /= k, Just who <- [Map.lookup page pages]]

-- | The pages a connection edits.
editedBy :: Key -> Presence -> [PageId]
editedBy k (Presence p) = maybe [] Map.keys (Map.lookup k p)
