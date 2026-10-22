-- | Who the demo is being looked at as: the in-memory backend has no
-- passwords, so the shell offers its users to switch between instead of a
-- sign-in form. And, in the same menu, starting the demo over: its content
-- is kept in the browser, so a reload no longer does.
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
import Wiki.App.Backend.Mem (MemWiki, memKept, memUsers, resetMemWiki, switchUser)
import Wiki.App.Demo (demoNow, demoState)
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

  -- | Put the demo's content back as it was at the start, wherever it is
  -- kept, staying who one is.
  resetDemo :: m ()
  default resetDemo :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m ()
  resetDemo = lift resetDemo

  -- | Whether changes outlive the page: kept in the browser, or lost when
  -- it is closed (a browser that keeps nothing for it).
  demoKept :: m Bool
  default demoKept :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m Bool
  demoKept = lift demoKept

instance (MonadIO m) => MonadDemoUsers (MemWiki m) where
  listUsers = memUsers
  switchTo = switchUser
  resetDemo = resetMemWiki (demoState demoNow)
  demoKept = memKept

-- | A component's handlers switch through its monad.
instance (MonadDemoUsers m) => MonadDemoUsers (HalogenM st act slots output m)
