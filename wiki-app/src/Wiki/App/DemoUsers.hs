-- | Who the demo is being looked at as: the in-memory backend has no
-- passwords, so the shell offers its users to switch between instead of a
-- sign-in form.
--
-- A class of its own, apart from 'Wiki.App.Backend.MonadWiki', so that the
-- switcher is written against a capability rather than the in-memory
-- backend: a backend with real accounts (Phase 2's @HttpWiki@) has no
-- instance, and the shell there offers a sign-in instead.
module Wiki.App.DemoUsers
  ( MonadDemoUsers (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.App.Backend.Mem (MemWiki, memUsers, switchUser)
import Wiki.Core.Id (UserId)
import Wiki.Core.User (User)

-- | Switching between the users of a wiki without signing in.
class (Monad m) => MonadDemoUsers m where
  -- | Everyone who can be switched to, in the order to offer them.
  listUsers :: m [User]
  default listUsers :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m [User]
  listUsers = lift listUsers

  -- | Be this user from now on, or nobody.
  switchTo :: Maybe UserId -> m ()
  default switchTo :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => Maybe UserId -> m ()
  switchTo = lift . switchTo

instance (MonadIO m) => MonadDemoUsers (MemWiki m) where
  listUsers = memUsers
  switchTo = switchUser

-- | A component's handlers switch through its monad.
instance (MonadDemoUsers m) => MonadDemoUsers (HalogenM st act slots output m)
