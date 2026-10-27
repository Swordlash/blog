-- | Who is editing which page, as the live channel records it
-- ("Wiki.Server.Events", WP4.12 of docs/PLAN.md): for each connection, the
-- pages its tab said it is editing, with the user it was opened as. None
-- of it is stored: it lives as long as the connections do, and a connection
-- that ends removes its entries ('leave'). That is how a closed tab, a lost
-- network and a stopping server all end someone's editing.
--
-- It is a plain value, which the hub keeps in a
-- 'Control.Concurrent.STM.TVar' and changes in the same transaction as the
-- connections it concerns, so that what a tab is told about a page's
-- editors always matches the value at that moment.
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

-- | A connection, by the number the hub assigned it.
type Key = Int

-- | Every connection that is editing something, with what it edits and as
-- whom.
newtype Presence = Presence (Map Key (Map PageId Author))
  deriving stock (Eq, Show)

-- | Nobody editing anything.
nobodyEditing :: Presence
nobodyEditing = Presence mempty

-- | A connection's tab is editing a page, as someone; and whether that
-- changed anything (a tab that says so twice changes nothing the second
-- time).
startEditing :: Key -> PageId -> Author -> Presence -> (Presence, Bool)
startEditing k page who (Presence p) =
  let before = Map.lookup page =<< Map.lookup k p
   in (Presence (Map.insertWith Map.union k (Map.singleton page who) p), before /= Just who)

-- | A connection's tab is no longer editing a page; and whether it was.
stopEditing :: Key -> PageId -> Presence -> (Presence, Bool)
stopEditing k page (Presence p) =
  let was = maybe False (Map.member page) (Map.lookup k p)
      dropped = Map.update (\pages -> let rest = Map.delete page pages in if Map.null rest then Nothing else Just rest) k p
   in (Presence dropped, was)

-- | A connection has ended: it edits nothing any more. The result is the
-- pages it was editing, whose subscribers must be told.
leave :: Key -> Presence -> (Presence, [PageId])
leave k (Presence p) = (Presence (Map.delete k p), maybe [] Map.keys (Map.lookup k p))

-- | Who is editing a page, as a connection is told: everyone editing it on
-- another connection, each person once (the same user in two tabs is one
-- editor), in the order their connections were made. A connection is never
-- told about itself, but is told about its own user editing in another
-- tab.
editorsFor :: Key -> PageId -> Presence -> [Author]
editorsFor k page (Presence p) =
  nubOrdOn (\a -> a.id) [who | (other, pages) <- Map.toAscList p, other /= k, Just who <- [Map.lookup page pages]]

-- | The pages a connection edits.
editedBy :: Key -> Presence -> [PageId]
editedBy k (Presence p) = maybe [] Map.keys (Map.lookup k p)
