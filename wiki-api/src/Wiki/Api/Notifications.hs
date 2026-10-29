{-# LANGUAGE DeriveAnyClass #-}

-- | Notifications API (WP4.13 of docs/PLAN.md): mentions, watching and
-- notifications over HTTP, at @notifications…@. Each endpoint implements
-- an operation of @MonadNotifications@ (@wiki-app@'s
-- "Wiki.App.Backend.Notifications"), with its request and response
-- bodies. The rules are in "Wiki.Core.Notification".
--
-- Everything here belongs to the signed-in user. A visitor who is not
-- signed in is refused ('Wiki.Api.Error.Forbidden'), except for three
-- endpoints. The first resolves the logins a document mentions
-- ('NotificationsApi' @people@), and tells such a visitor nothing. The
-- second finds the users whose names start with some letters
-- ('NotificationsApi' @searchPeople@), for the editor's completion of
-- mentions, and finds nobody for such a visitor. The third is the link in
-- a notification mail that turns the mail off
-- (@unsubscribe@, at the API's top level, since it works without signing
-- in, even in a closed wiki).
module Wiki.Api.Notifications
  ( NotificationsApi (..)
  , Notifications (..)
  , ReadMark (..)
  , NotificationSettings (..)
  , NotificationSettingsChange (..)
  , Watching (..)
  , maxPeopleFound
  , minPeopleSearch
  , searchable
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Protolude
import Servant.API
import Wiki.Core.Id
import Wiki.Core.Notification (MailMode, Notification, Watch)
import Wiki.Core.User (User)
import Wiki.Core.Version (Author)

-- | 'NotificationsApi': the endpoints under @notifications@.
data NotificationsApi mode = NotificationsApi
  { list :: mode :- Get '[JSON] Notifications
  -- ^ @notifications@: the latest notifications, newest first, and the
  -- number of unread ones.
  , markRead :: mode :- "read" :> ReqBody '[JSON] ReadMark :> Post '[JSON] Notifications
  -- ^ @markRead@: mark some, or all, as read; the response is the list after the change.
  , settings :: mode :- "settings" :> Get '[JSON] NotificationSettings
  -- ^ @notificationSettings@.
  , setSettings :: mode :- "settings" :> ReqBody '[JSON] NotificationSettingsChange :> Put '[JSON] NotificationSettings
  -- ^ @setNotificationSettings@.
  , people :: mode :- "people" :> QueryParams "login" Text :> Get '[JSON] (Map Text Author)
  -- ^ @mentionable@: the given logins that belong to the wiki's users,
  -- each named like a comment's author; empty for a visitor who is not
  -- signed in.
  , searchPeople :: mode :- "people" :> "search" :> QueryParam' '[Required, Strict] "q" Text :> Get '[JSON] [User]
  -- ^ @mentionCandidates@: the users who may sign in whose login or
  -- display name starts with @q@, ignoring case, ordered by display name,
  -- at most 'maxPeopleFound'. The editor offers them when an \@ is typed.
  -- Only users whose login a mention can name are answered: those for
  -- which "Wiki.Core.Markdown.Ast"'s 'Wiki.Core.Markdown.Ast.mentionsWhole'
  -- holds, so that writing @\@login@ mentions the user chosen.
  --
  -- Empty for a visitor who is not signed in, and for a @q@ shorter than
  -- 'minPeopleSearch'. A signed-in user is otherwise never given a list of
  -- the wiki's users (only an administrator, or a space's administrator
  -- choosing whom to grant to, sees them all). The search does let them
  -- find users they did not know of, a few letters at a time; the shortest
  -- @q@ keeps that from being a list of everyone by one letter each.
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

-- | 'maxPeopleFound' is the most users 'searchPeople' answers with: as
-- many as a completion list shows without scrolling.
maxPeopleFound :: Int
maxPeopleFound = 10

-- | 'minPeopleSearch' is the fewest letters 'searchPeople' searches with:
-- two. One letter answers nobody.
minPeopleSearch :: Int
minPeopleSearch = 2

-- | Whether 'searchPeople' searches with these letters, or answers nobody:
-- they are at least 'minPeopleSearch' long.
searchable :: Text -> Bool
searchable letters = T.length letters >= minPeopleSearch

-- | 'Notifications': the user's latest notifications, newest first (at
-- most 'Wiki.Core.Notification.maxListed'), and the number of unread ones
-- among all their notifications.
data Notifications = Notifications
  { unread :: Int
  , items :: [Notification]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ReadMark': which notifications to mark as read: these, or all ('everything').
data ReadMark = ReadMark
  { ids :: [NotificationId]
  , everything :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NotificationSettings': how the user is notified. It holds their mail
-- setting (as chosen, or the default: immediately if they have a verified
-- address, otherwise none), whether they automatically watch the pages
-- they create and the threads they take part in, and what only the server
-- can say mail needs: a verified address, and a mail server.
data NotificationSettings = NotificationSettings
  { mail :: MailMode
  , watchOwn :: Bool
  , verifiedEmail :: Bool
  , mailing :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NotificationSettingsChange': the parts of 'NotificationSettings' the user chooses.
data NotificationSettingsChange = NotificationSettingsChange
  { mail :: MailMode
  , watchOwn :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Watching': whether to watch a page or a space.
newtype Watching = Watching {watching :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
