-- | The spaces this browser visited last, which the directory of spaces
-- shows as "Recently visited".
--
-- Kept in the browser's local storage ("Web.Storage.Storage"), by space
-- id, the latest first and a handful at most: it is this browser's, as a
-- browser's history is, and neither the demo's wiki nor the server keeps
-- it. A space that has gone, or that whoever is asking may no longer view,
-- is left out when the list is shown, not when it is kept, so that it
-- comes back if they may view it again. The shell adds a space whenever it
-- shows one; the directory reads the list after its first render, which is
-- therefore the same in the browser as in a page rendered without one.
--
-- Only a browser keeps the list. Natively, local storage is one store for
-- the whole process, and the processes that render this application
-- natively are the prerender, which writes every route in turn, and the
-- server, which renders every reader's pages: a list kept there would put
-- one route's, or one reader's, visits into another's page. So natively
-- there is never a list, and nothing is kept.
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

-- | Where the list is kept.
recentKey :: Text
recentKey = "recent-spaces"

-- | How many spaces the list holds.
maxRecent :: Int
maxRecent = 6

-- | The list after a visit to a space: the space first, once, and the
-- oldest dropped beyond 'maxRecent'.
visited :: SpaceId -> [SpaceId] -> [SpaceId]
visited sid kept = take maxRecent (sid : filter (/= sid) kept)

-- | The list as this browser keeps it; empty if it keeps none, or one that
-- does not read.
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
