-- | The stars' backend interface: 'MonadStars' is every read and write of
-- the pages a user starred (WP5.44 of docs/PLAN.md). A star is a user's
-- bookmark of a page. The header's "Starred" list shows the starred pages,
-- and a page's star button adds the page to the list or takes it off.
--
-- It is a separate class from 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Notifications.MonadNotifications' is, and like it every
-- backend implements it: the demo's in-memory backend (saved in
-- IndexedDB), the HTTP backend (the API's @stars…@ endpoints,
-- "Wiki.Api.Stars") and the server's storage. They pass the same contract
-- tests (@Wiki.App.Backend.Contract.Stars@ in @wiki-app:contract@).
--
-- = Who may
--
-- Stars belong to the signed-in user, and nobody else sees them. Someone
-- not signed in, and the server's operator (who is not a user), are
-- refused with 'Forbidden'. Starring a page needs permission to view it,
-- checked first, as everywhere: a page that is not there, or that the user
-- may not view, is 'NotFound', even to someone not signed in. A user stars
-- at most 'Wiki.Api.Stars.maxStars' pages; one more is 'Invalid'.
--
-- = The list
--
-- The list is in the order the pages were starred, the first starred
-- first, so that a page keeps its place in it. Each entry has the page's
-- title and place as they are now. A page that was deleted is not listed,
-- and its star is gone with it. A page the user may no longer view is not
-- listed either, but its star is kept: the page is listed again if the
-- user may view it again.
module Wiki.App.Backend.Stars
  ( MonadStars (..)
  , isStarred
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Stars (StarredPage (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (PageId)

-- | 'MonadStars' is the backend interface for the signed-in user's starred
-- pages.
--
-- Every method has a default that lifts it through a monad transformer,
-- as 'Wiki.App.Backend.MonadWiki''s do, so that a component's handlers
-- call them in 'HalogenM'.
class (Monad m) => MonadStars m where
  -- | The starred pages the user may view, in the order they were starred.
  starred :: m (Either WikiError [StarredPage])
  default starred :: (MonadTrans t, m ~ t n, MonadStars n) => m (Either WikiError [StarredPage])
  starred = lift starred

  -- | Star a page ('True'), or take its star away. Doing either twice
  -- changes nothing more and succeeds. The result is the list afterwards,
  -- as 'starred' gives it.
  setStarred :: PageId -> Bool -> m (Either WikiError [StarredPage])
  default setStarred :: (MonadTrans t, m ~ t n, MonadStars n) => PageId -> Bool -> m (Either WikiError [StarredPage])
  setStarred p = lift . setStarred p

-- | A component's handlers reach the backend through its monad.
instance (MonadStars m) => MonadStars (HalogenM st act slots output m)

-- | Whether a page is in a list of starred pages.
isStarred :: PageId -> [StarredPage] -> Bool
isStarred p = any (\s -> s.page == p)
