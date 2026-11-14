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
  , counts
  , withTold
  , ReadMark (..)
  , NotificationSettings (..)
  , NotificationSettingsChange (..)
  , Watching (..)
  , FeedAddress (..)
  , feedPath
  , feedAddressOf
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
import Wiki.Core.Notification (MailMode, Notification (..), Watch)
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
  , feed :: mode :- "feed" :> Get '[JSON] FeedAddress
  -- ^ @feedAddress@: the address of the user's own feed of notifications,
  -- or none while they have made none.
  , renewFeed :: mode :- "feed" :> Post '[JSON] FeedAddress
  -- ^ @renewFeedAddress@: make the feed's address, or a new one in place of
  -- the old, which answers nothing from then on.
  }
  deriving stock (Generic)

-- | 'FeedAddress': where the signed-in user reads their notifications as
-- an Atom feed (WP5.31 of docs/PLAN.md): the path under the wiki's root,
-- @me/notifications.atom?token=\<secret>@ ('feedAddressOf'), or 'Nothing'
-- while the user has made none. The secret is the user's alone: whoever
-- has the address reads their notifications, so it is shown to them in
-- the account panel and appears in no other answer.
newtype FeedAddress = FeedAddress {address :: Maybe Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The path of the feed of notifications under the wiki's root, as the
-- server serves it: its segments.
feedPath :: [Text]
feedPath = ["me", "notifications.atom"]

-- | The feed's address for a secret: the path under the wiki's root.
feedAddressOf :: Text -> Text
feedAddressOf secret = T.intercalate "/" feedPath <> "?token=" <> secret

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

-- | Whether a list of notifications counts this one already: it lists it,
-- or lists one made after it in the server's order ('position'), so the
-- server answered after this one was made. The server lists only its
-- newest ('Wiki.Core.Notification.maxListed') and counts every unread one
-- beside them, so a notification made before the newest listed is
-- counted, listed or not; one the list does not count was made after the
-- server answered (told over the live channel since). The times do not
-- say this: a notification's time may be taken before its transaction
-- waits for the writer, so one made later may be timed earlier. Where a
-- position is not known (a server or a list from before positions), the
-- notification is taken as not counted: at worst counted twice until the
-- next read, never left out.
counts :: Notifications -> Notification -> Bool
counts ns n = any (\x -> x.id == n.id || maybe False (\p -> maybe False (>= p) x.position) n.position) ns.items

-- | The list with the notifications the live channel told of that it does
-- not count ('counts') put first, the unread among them counted.
withTold :: [Notification] -> Notifications -> Notifications
withTold told ns = Notifications {unread = ns.unread + length (filter (\n -> not n.read) missing), items = missing <> ns.items}
  where
    missing = filter (not . counts ns) told

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
