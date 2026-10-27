-- | The spaces this browser visited last, which the directory of spaces
-- shows as "Recently visited".
--
-- The list is stored in the browser's local storage
-- ("Web.Storage.Storage"), by space id, the latest first, a handful at
-- most. It belongs to this browser, as a browser's history does; neither
-- the demo's wiki nor the server stores it. A space that no longer exists,
-- or that the current user may no longer view, is left out when the list
-- is shown, not when it is stored, so that it comes back if they may view
-- it again. The shell adds a space whenever it shows one. The directory
-- reads the list after its first render, so that render is the same in
-- the browser as in a page rendered without a list.
--
-- Only a browser stores the list. Natively, local storage is one store for
-- the whole process, and the processes that render this application
-- natively are the prerender, which writes every route in turn, and the
-- server, which renders every reader's pages. A list stored there would
-- put one route's, or one reader's, visits into another's page. So
-- natively there is never a list, and nothing is stored.
module Wiki.App.Recent
  ( recentKey
  , maxRecent
  , visited
  , readRecent
  , rememberVisit
  )
where

import Halogen.JSBits (inBrowser)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Core.Id (SpaceId)

-- | The local storage key the list is stored under.
recentKey :: Text
recentKey = "recent-spaces"

-- | How many spaces the list holds.
maxRecent :: Int
maxRecent = 6

-- | The list after a visit to a space: the space first, once, and the
-- oldest entries dropped beyond 'maxRecent'.
visited :: SpaceId -> [SpaceId] -> [SpaceId]
visited sid kept = take maxRecent (sid : filter (/= sid) kept)

-- | The list as this browser stores it; empty if there is none, or if it
-- does not parse.
readRecent :: (MonadBrowserDOM m) => m [SpaceId]
readRecent
  | inBrowser = fromMaybe [] . (>>= rightToMaybe) <$> Storage.getItem LocalStorage recentKey
  | otherwise = pure []

-- | Add a visit to a space to the list.
rememberVisit :: (MonadBrowserDOM m) => SpaceId -> m ()
rememberVisit sid = when inBrowser $ do
  kept <- readRecent
  let now = visited sid kept
  when (now /= kept) (Storage.setItem LocalStorage recentKey now)
