-- | The notifications' backend interface: 'MonadNotifications' is every
-- read and write of mentions, watches and notifications (WP4.13 of
-- docs/PLAN.md). The rules are in "Wiki.Core.Notification".
--
-- It is a separate class from 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Comments.MonadComments' is, and like it every backend
-- implements it: the demo's in-memory backend (saved in IndexedDB, with
-- the bell but no mail and no live channel), the HTTP backend (the API's
-- @notifications…@ endpoints, "Wiki.Api.Notifications") and the server's
-- storage. They pass the same contract tests
-- (@Wiki.App.Backend.Contract.Notifications@ in @wiki-app:contract@).
--
-- Notifications are created by the writes they are about, in the same
-- transaction, as the rules say: a save of a page
-- ('Wiki.App.Backend.savePage', 'Wiki.App.Backend.restoreVersion') and a
-- comment ('Wiki.App.Backend.Comments.openThread', @reply@,
-- @editComment@). Nothing in this class creates one.
--
-- = Who may
--
-- Everything belongs to the signed-in user. Someone not signed in is
-- refused with 'Forbidden' everywhere except 'mentionable' (which names
-- nobody to them) and 'unsubscribe'. Watching a page or a space needs
-- permission to view it, checked first, as everywhere: a page or a space
-- that is not there, or that the user may not view, is 'NotFound', even
-- to someone not signed in. A notification about a page the user may no
-- longer read is not listed.
module Wiki.App.Backend.Notifications
  ( MonadNotifications (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Notifications (NotificationSettings, NotificationSettingsChange, Notifications, ReadMark)
import Wiki.Api.Security (MailToken)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Notification (Watch, WatchTarget)
import Wiki.Core.Version (Author)

-- | 'MonadNotifications' is the backend interface for the signed-in
-- user's notifications and watches.
--
-- Every method has a default that lifts it through a monad transformer,
-- as 'Wiki.App.Backend.MonadWiki''s do, so that a component's handlers
-- call them in 'HalogenM'.
class (Monad m) => MonadNotifications m where
  -- | Which of these logins belong to wiki users who may sign in, each
  -- named as a comment's author is: what a mention links to. Someone not
  -- signed in gets nobody, so they learn nothing about who the wiki's users
  -- are. This read cannot be refused: on the HTTP backend it throws
  -- 'Unreachable', as 'Wiki.App.Backend.listSpaces' does.
  mentionable :: [Text] -> m (Map Text Author)
  default mentionable :: (MonadTrans t, m ~ t n, MonadNotifications n) => [Text] -> m (Map Text Author)
  mentionable = lift . mentionable

  -- | The latest notifications about pages the user may read, the newest
  -- first, each with where its page is now, and how many are unread.
  notifications :: m (Either WikiError Notifications)
  default notifications :: (MonadTrans t, m ~ t n, MonadNotifications n) => m (Either WikiError Notifications)
  notifications = lift notifications

  -- | Mark some notifications read, or all of them. The result is the
  -- notifications afterwards.
  markRead :: ReadMark -> m (Either WikiError Notifications)
  default markRead :: (MonadTrans t, m ~ t n, MonadNotifications n) => ReadMark -> m (Either WikiError Notifications)
  markRead = lift . markRead

  -- | Whether the user watches a page or a space, and the reason.
  watching :: WatchTarget -> m (Either WikiError Watch)
  default watching :: (MonadTrans t, m ~ t n, MonadNotifications n) => WatchTarget -> m (Either WikiError Watch)
  watching = lift . watching

  -- | Choose to watch a page or a space, or not to, overriding whatever
  -- would otherwise decide. The result is whether they now watch it.
  setWatching :: WatchTarget -> Bool -> m (Either WikiError Watch)
  default setWatching :: (MonadTrans t, m ~ t n, MonadNotifications n) => WatchTarget -> Bool -> m (Either WikiError Watch)
  setWatching t = lift . setWatching t

  -- | How the user wants to be notified.
  notificationSettings :: m (Either WikiError NotificationSettings)
  default notificationSettings :: (MonadTrans t, m ~ t n, MonadNotifications n) => m (Either WikiError NotificationSettings)
  notificationSettings = lift notificationSettings

  -- | Change how the user wants to be notified. The result is the new
  -- settings.
  setNotificationSettings :: NotificationSettingsChange -> m (Either WikiError NotificationSettings)
  default setNotificationSettings :: (MonadTrans t, m ~ t n, MonadNotifications n) => NotificationSettingsChange -> m (Either WikiError NotificationSettings)
  setNotificationSettings = lift . setNotificationSettings

  -- | Follow the unsubscribe link in a notification mail: mail to the user
  -- the link names is turned off. 'NotFound' for a link that is not a
  -- real one; 'Invalid' where nothing is mailed (the demo).
  unsubscribe :: MailToken -> m (Either WikiError ())
  default unsubscribe :: (MonadTrans t, m ~ t n, MonadNotifications n) => MailToken -> m (Either WikiError ())
  unsubscribe = lift . unsubscribe

-- | A component's handlers reach the backend through its monad.
instance (MonadNotifications m) => MonadNotifications (HalogenM st act slots output m)
