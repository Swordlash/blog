-- | Mentions, watching and notifications, as the application asks for them
-- (WP4.13 of docs/PLAN.md): the rules are "Wiki.Core.Notification"'s.
--
-- A class of its own beside 'Wiki.App.Backend.MonadWiki', as
-- 'Wiki.App.Backend.Comments.MonadComments' is, and like it every backend
-- has it: the demo's in memory (and in IndexedDB, with the bell but no
-- mail and no live channel), the one over HTTP (the API's
-- @notifications…@, "Wiki.Api.Notifications") and the server's storage.
-- They pass the same contract (@Wiki.App.Backend.Contract.Notifications@
-- in @wiki-app:contract@).
--
-- Notifications are made by the writes they are about: a save of a page
-- ('Wiki.App.Backend.savePage', 'Wiki.App.Backend.restoreVersion') and a
-- comment ('Wiki.App.Backend.Comments.openThread', @reply@,
-- @editComment@), as the rules say, in the same transaction. Nothing here
-- makes one.
--
-- = Who may
--
-- Everything is the signed-in user's own: someone not signed in is
-- 'Forbidden' everywhere but 'mentionable' (which names nobody to them)
-- and 'unsubscribe'. Watching a page or a space takes viewing it, checked
-- first as everywhere ('NotFound', then 'Forbidden'). A notification of a
-- page the user may no longer read is not listed.
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

-- | The signed-in user's notifications, and what they watch.
--
-- The methods have lifted defaults, as 'Wiki.App.Backend.MonadWiki''s do,
-- so that a component's handlers call them in 'HalogenM'.
class (Monad m) => MonadNotifications m where
  -- | Of these logins, those of the wiki's users who may sign in, each
  -- named as a comment's author is: what a mention links to. Nobody, to
  -- someone not signed in, who is told nothing of who the wiki's users
  -- are. A read that cannot be refused: over HTTP it throws
  -- 'Unreachable', as 'Wiki.App.Backend.listSpaces' does.
  mentionable :: [Text] -> m (Map Text Author)
  default mentionable :: (MonadTrans t, m ~ t n, MonadNotifications n) => [Text] -> m (Map Text Author)
  mentionable = lift . mentionable

  -- | The latest notifications, the newest first, of pages the user may
  -- read, each with where its page is now, and how many are unread.
  notifications :: m (Either WikiError Notifications)
  default notifications :: (MonadTrans t, m ~ t n, MonadNotifications n) => m (Either WikiError Notifications)
  notifications = lift notifications

  -- | Mark some read, or all: the notifications then.
  markRead :: ReadMark -> m (Either WikiError Notifications)
  default markRead :: (MonadTrans t, m ~ t n, MonadNotifications n) => ReadMark -> m (Either WikiError Notifications)
  markRead = lift . markRead

  -- | Whether the user watches a page or a space, and why.
  watching :: WatchTarget -> m (Either WikiError Watch)
  default watching :: (MonadTrans t, m ~ t n, MonadNotifications n) => WatchTarget -> m (Either WikiError Watch)
  watching = lift . watching

  -- | Choose to watch a page or a space, or not to, over whatever would
  -- otherwise decide: whether they watch it then.
  setWatching :: WatchTarget -> Bool -> m (Either WikiError Watch)
  default setWatching :: (MonadTrans t, m ~ t n, MonadNotifications n) => WatchTarget -> Bool -> m (Either WikiError Watch)
  setWatching t = lift . setWatching t

  -- | How the user is told.
  notificationSettings :: m (Either WikiError NotificationSettings)
  default notificationSettings :: (MonadTrans t, m ~ t n, MonadNotifications n) => m (Either WikiError NotificationSettings)
  notificationSettings = lift notificationSettings

  -- | Choose how: the settings then.
  setNotificationSettings :: NotificationSettingsChange -> m (Either WikiError NotificationSettings)
  default setNotificationSettings :: (MonadTrans t, m ~ t n, MonadNotifications n) => NotificationSettingsChange -> m (Either WikiError NotificationSettings)
  setNotificationSettings = lift . setNotificationSettings

  -- | Follow a notification mail's link: the mail of the user it names is
  -- turned off. 'NotFound' for a link that is not one; 'Invalid' where
  -- nothing is mailed (the demo).
  unsubscribe :: MailToken -> m (Either WikiError ())
  default unsubscribe :: (MonadTrans t, m ~ t n, MonadNotifications n) => MailToken -> m (Either WikiError ())
  unsubscribe = lift . unsubscribe

-- | A component's handlers reach the backend through its monad.
instance (MonadNotifications m) => MonadNotifications (HalogenM st act slots output m)
