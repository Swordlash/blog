-- | What the administration asks of wherever the wiki is kept: its people
-- and their accounts, who of them administers it and who may create
-- spaces, and its groups with their members.
--
-- A class of its own beside 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.DemoUsers.MonadDemoUsers' is, since it is what the
-- administration panel needs and nothing else does; but unlike the demo's
-- switcher every backend has it: the in-memory one of the demo
-- ("Wiki.App.Backend.Mem"), the one over HTTP ("Wiki.App.Backend.Http",
-- through the API's @admin\/…@ endpoints) and the server's own storage.
-- They pass the same contract (@Wiki.App.Backend.Contract.Admin@ in
-- @wiki-app:contract@).
--
-- = Who may
--
-- Every method needs the global 'Wiki.Core.Permission.Administer': the
-- server's operator, who always holds it, or a user granted it. Anyone else
-- is refused with 'Forbidden' before anything they named is looked for, so
-- that whoever may not administer the wiki learns nothing from it, not
-- even which ids are someone's. After that the errors come as
-- "Wiki.App.Backend" orders them: 'NotFound' for an id that names nobody,
-- then 'Invalid'.
--
-- An administrator may take the global administer from themself: the
-- backend allows it, since the operator on the server's admin listener can
-- always give it back. The panel does not offer it (an administrator who
-- did it by mistake would be locked out of the panel at once), which is a
-- rule of the panel's and not of the backend's.
--
-- = What changes what
--
-- Marking and unmarking an administrator changes the user's own grant of
-- the global administer and nothing else; a grant of it to a group is left
-- alone. Letting a user create spaces, or no longer, is the same with the
-- global create-spaces. Deleting a group deletes its membership and every grant to it,
-- global and on spaces, so that a group made later is never handed another's
-- permissions. Adding a member who is in the group already, and removing
-- one who is not, change nothing and succeed. A group's name is not blank,
-- and no two groups have names that differ only in case.
--
-- = Accounts
--
-- A user made here signs in with a password, kept by the server as a hash
-- (decision 8). Their login follows 'Wiki.Core.User.checkLogin' and is no
-- other user's in any case ('Conflict' otherwise); a blank display name is
-- the login; a password follows 'Wiki.Core.User.checkPassword' ('Invalid'
-- otherwise). A new password, and disabling a login, end the user's
-- sessions; a disabled user cannot sign in, stays in the 'directory', and
-- keeps their pages and grants. The demo's backend has no passwords and
-- keeps only whether a user has one, which it checks as the server does,
-- so that its administration behaves alike; a disabled user is nobody
-- there, and is not offered to switch to.
module Wiki.App.Backend.Admin
  ( MonadAdmin (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Account (Account, NewAccount)
import Wiki.Api.Admin (Directory)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (GroupId, UserId)
import Wiki.Core.User (Group)

-- | The wiki's people, as an administrator sees and changes them.
--
-- The methods have lifted defaults, as 'Wiki.App.Backend.MonadWiki''s do,
-- so that a component's handlers call them in 'HalogenM'.
class (Monad m) => MonadAdmin m where
  -- | Every user, by login, which of them is granted the global administer,
  -- and every group, by name, with its members.
  directory :: m (Either WikiError Directory)
  default directory :: (MonadTrans t, m ~ t n, MonadAdmin n) => m (Either WikiError Directory)
  directory = lift directory

  -- | Grant a user the global administer, or take it from them.
  setAdministrator :: UserId -> Bool -> m (Either WikiError ())
  default setAdministrator :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setAdministrator u = lift . setAdministrator u

  -- | Grant a user the global create-spaces, or take it from them.
  setCreateSpaces :: UserId -> Bool -> m (Either WikiError ())
  default setCreateSpaces :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError ())
  setCreateSpaces u = lift . setCreateSpaces u

  -- | A new user, who signs in with the password given: their account.
  createUser :: NewAccount -> m (Either WikiError Account)
  default createUser :: (MonadTrans t, m ~ t n, MonadAdmin n) => NewAccount -> m (Either WikiError Account)
  createUser = lift . createUser

  -- | Give a user a new password, ending their sessions: their account.
  setPassword :: UserId -> Text -> m (Either WikiError Account)
  default setPassword :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Text -> m (Either WikiError Account)
  setPassword u = lift . setPassword u

  -- | Disable a user's login, ending their sessions, or enable it again:
  -- their account.
  setDisabled :: UserId -> Bool -> m (Either WikiError Account)
  default setDisabled :: (MonadTrans t, m ~ t n, MonadAdmin n) => UserId -> Bool -> m (Either WikiError Account)
  setDisabled u = lift . setDisabled u

  -- | A new group, with this name and nobody in it.
  createGroup :: Text -> m (Either WikiError Group)
  default createGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => Text -> m (Either WikiError Group)
  createGroup = lift . createGroup

  -- | Give a group another name.
  renameGroup :: GroupId -> Text -> m (Either WikiError Group)
  default renameGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> Text -> m (Either WikiError Group)
  renameGroup g = lift . renameGroup g

  -- | Delete a group, its membership and the grants to it.
  deleteGroup :: GroupId -> m (Either WikiError ())
  default deleteGroup :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> m (Either WikiError ())
  deleteGroup = lift . deleteGroup

  -- | Put a user in a group.
  addMember :: GroupId -> UserId -> m (Either WikiError ())
  default addMember :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> UserId -> m (Either WikiError ())
  addMember g = lift . addMember g

  -- | Take a user out of a group.
  removeMember :: GroupId -> UserId -> m (Either WikiError ())
  default removeMember :: (MonadTrans t, m ~ t n, MonadAdmin n) => GroupId -> UserId -> m (Either WikiError ())
  removeMember g = lift . removeMember g

-- | A component's handlers reach the backend through its monad.
instance (MonadAdmin m) => MonadAdmin (HalogenM st act slots output m)
