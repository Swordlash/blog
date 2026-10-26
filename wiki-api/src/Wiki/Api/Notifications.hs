{-# LANGUAGE DeriveAnyClass #-}

-- | Mentions, watching and notifications over HTTP (WP4.13 of
-- docs/PLAN.md), at @notifications…@, each operation one of
-- @MonadNotifications@'s (@wiki-app@'s "Wiki.App.Backend.Notifications"),
-- with its request and response bodies. The rules are
-- "Wiki.Core.Notification"'s.
--
-- Everything here is the signed-in user's own: someone not signed in is
-- refused ('Wiki.Api.Error.Forbidden'), but for the logins a document
-- mentions ('NotificationsApi' @people@), which they are told nothing of,
-- and the link a notification's mail carries to turn the mail off
-- (@unsubscribe@, at the API's top level, since it works without signing
-- in, in a closed wiki too).
module Wiki.Api.Notifications
  ( NotificationsApi (..)
  , Notifications (..)
  , ReadMark (..)
  , NotificationSettings (..)
  , NotificationSettingsChange (..)
  , Watching (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Servant.API
import Wiki.Core.Id
import Wiki.Core.Notification (MailMode, Notification, Watch)
import Wiki.Core.Version (Author)

-- | Below @notifications@.
data NotificationsApi mode = NotificationsApi
  { list :: mode :- Get '[JSON] Notifications
  -- ^ @notifications@: the latest, the newest first, and how many are
  -- unread.
  , markRead :: mode :- "read" :> ReqBody '[JSON] ReadMark :> Post '[JSON] Notifications
  -- ^ @markRead@: some, or all, marked read; the list as it then is.
  , settings :: mode :- "settings" :> Get '[JSON] NotificationSettings
  -- ^ @notificationSettings@.
  , setSettings :: mode :- "settings" :> ReqBody '[JSON] NotificationSettingsChange :> Put '[JSON] NotificationSettings
  -- ^ @setNotificationSettings@.
  , people :: mode :- "people" :> QueryParams "login" Text :> Get '[JSON] (Map Text Author)
  -- ^ @mentionable@: of these logins, those of the wiki's users, each
  -- named as a comment's author is; nothing for someone not signed in.
  , pageWatch :: mode :- "watches" :> "pages" :> Capture "page" PageId :> Get '[JSON] Watch
  -- ^ @watching@ a page.
  , setPageWatch :: mode :- "watches" :> "pages" :> Capture "page" PageId :> ReqBody '[JSON] Watching :> Put '[JSON] Watch
  -- ^ @setWatching@ a page.
  , spaceWatch :: mode :- "watches" :> "spaces" :> Capture "space" SpaceId :> Get '[JSON] Watch
  -- ^ @watching@ a space.
  , setSpaceWatch :: mode :- "watches" :> "spaces" :> Capture "space" SpaceId :> ReqBody '[JSON] Watching :> Put '[JSON] Watch
  -- ^ @setWatching@ a space.
  }
  deriving stock (Generic)

-- | The latest of the user's notifications, the newest first (at most
-- 'Wiki.Core.Notification.maxListed'), and how many of all they have are
-- unread.
data Notifications = Notifications
  { unread :: Int
  , items :: [Notification]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Which notifications to mark read: these, or ('everything') all.
data ReadMark = ReadMark
  { ids :: [NotificationId]
  , everything :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How the user is told: how they are mailed (as chosen, or by default:
-- at once with a verified address, otherwise not), whether they watch
-- what they make and the threads they are in, and what mail needs that
-- only the server can give: a verified address, and a mail server.
data NotificationSettings = NotificationSettings
  { mail :: MailMode
  , watchOwn :: Bool
  , verifiedEmail :: Bool
  , mailing :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What the user chooses of 'NotificationSettings'.
data NotificationSettingsChange = NotificationSettingsChange
  { mail :: MailMode
  , watchOwn :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether to watch a page or a space.
newtype Watching = Watching {watching :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
