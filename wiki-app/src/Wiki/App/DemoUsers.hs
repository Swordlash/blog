-- | Who the demo is being looked at as: the in-memory backend has no
-- passwords, so the shell offers its users to switch between instead of a
-- sign-in form. And, in the same menu, the demo's content as a whole: kept
-- in the browser, so a reload no longer starts it over, it is reset there,
-- and exported and imported as one file.
--
-- A class of its own, apart from 'Wiki.App.Backend.MonadWiki', so that the
-- switcher is written against a capability rather than the in-memory
-- backend: a backend with real accounts (Phase 2's @HttpWiki@) has no
-- instance, and the shell there offers a sign-in instead.
module Wiki.App.DemoUsers
  ( MonadDemoUsers (..)
  , Demo (..)
  , demoControls
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Data.Version (showVersion)
import Halogen.Query.HalogenM (HalogenM)
import Paths_wiki_app qualified as Paths
import Protolude
import Wiki.App.Backend.Mem (MemWiki, importMemWiki, memArchive, memKept, memUsers, resetMemWiki, switchUser)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Export (Archive)
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

  -- | Put the demo back as it was at the start, wherever it is kept, who is
  -- signed in included.
  resetDemo :: m ()
  default resetDemo :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m ()
  resetDemo = lift resetDemo

  -- | Whether changes outlive the page: kept in the browser, or lost when
  -- it is closed (a browser that keeps nothing for it).
  demoKept :: m Bool
  default demoKept :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m Bool
  demoKept = lift demoKept

  -- | The whole wiki as an export archive ("Wiki.Core.Export"), for the
  -- demo's "Export the wiki".
  exportDemo :: m Archive
  default exportDemo :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => m Archive
  exportDemo = lift exportDemo

  -- | Replace the whole wiki with an archive's, checked already, all of it
  -- or, if it cannot be kept, none of it and why.
  importDemo :: Archive -> m (Either Text ())
  default importDemo :: (MonadTrans t, m ~ t n, MonadDemoUsers n) => Archive -> m (Either Text ())
  importDemo = lift . importDemo

instance (MonadIO m) => MonadDemoUsers (MemWiki m) where
  listUsers = memUsers
  switchTo = switchUser
  resetDemo = resetMemWiki (demoState demoNow)
  demoKept = memKept
  exportDemo = memArchive ("wiki-app " <> toS (showVersion Paths.version))
  importDemo = importMemWiki

-- | A component's handlers switch through its monad.
instance (MonadDemoUsers m) => MonadDemoUsers (HalogenM st act slots output m)

-- | The class's methods as values: what the shell is handed when it runs
-- over a backend that has them, and not handed over one that has none
-- (the server's, whose people sign in rather than switch), so that the
-- shell does not ask its monad for an instance it may not have.
data Demo m = Demo
  { listUsers :: m [User]
  , switchTo :: Maybe UserId -> m ()
  , resetDemo :: m ()
  , demoKept :: m Bool
  , exportDemo :: m Archive
  , importDemo :: Archive -> m (Either Text ())
  }

-- | The demo's controls, from the monad's instance.
demoControls :: (MonadDemoUsers m) => Demo m
demoControls = Demo {listUsers, switchTo, resetDemo, demoKept, exportDemo, importDemo}
