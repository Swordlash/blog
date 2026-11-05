-- | The page "What's new?"'s backend interface: 'MonadWhatsNew' reads the
-- version and build date of the server and the newest changelog entries
-- it was built with (WP5.66 of docs/PLAN.md, "Wiki.Api.WhatsNew").
--
-- It is a separate class from 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Stars.MonadStars' is. The HTTP backend reads the API's
-- @whats-new@ and caches the answer, which changes only when the server is
-- replaced. The demo's in-memory backend has no changelog: it answers
-- 'NotFound', and its session says the page is off, so that nothing links
-- to it.
module Wiki.App.Backend.WhatsNew
  ( MonadWhatsNew (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.WhatsNew (WhatsNew)
import Wiki.App.Backend (WikiError (..))

-- | 'MonadWhatsNew' is the backend interface for the page "What's new?".
--
-- The method has a default that lifts it through a monad transformer, as
-- 'Wiki.App.Backend.MonadWiki''s do, so that a component's handlers call
-- it in 'HalogenM'.
class (Monad m) => MonadWhatsNew m where
  -- | The server's version, build date and newest changelog entries, the
  -- newest first; 'NotFound' where there are none to show (the demo, or a
  -- server started with @--no-whats-new@).
  whatsNew :: m (Either WikiError WhatsNew)
  default whatsNew :: (MonadTrans t, m ~ t n, MonadWhatsNew n) => m (Either WikiError WhatsNew)
  whatsNew = lift whatsNew

-- | A component's handlers reach the backend through its monad.
instance (MonadWhatsNew m) => MonadWhatsNew (HalogenM st act slots output m)
