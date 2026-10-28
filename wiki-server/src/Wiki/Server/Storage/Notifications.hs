-- | Notifications, watches and notification choices as the database
-- stores them (migration @0011-notifications.sql@, WP4.13 of
-- docs/PLAN.md): read and written row by row, for "Wiki.Server.Storage"'s
-- transactions, which apply the rules of "Wiki.Core.Notification" first,
-- and for the thread that mails notifications ("Wiki.Server.Notifier").
--
-- = The unsubscribe link
--
-- A notification mail carries a link that turns its reader's mail off
-- without signing in. Its secret is the user's id and an HMAC-SHA-256 of
-- it under a key of the wiki's own, generated at random the first time one
-- is needed and stored in the @settings@ table. So the link is the same in
-- every mail, needs no row of its own, cannot be altered into another
-- user's link, and allows only that one action (the MAC covers the
-- purpose's name and the id, and nothing else accepts it).
module Wiki.Server.Storage.Notifications
  ( -- * Who is told
    Telling (..)
  , loadTelling
  , Audience (..)
  , loadAudience
  , pageMaker

    -- * Watches and choices
  , loadMarks
  , storeMark
  , Choices (..)
  , loadChoices
  , storeChoices

    -- * Notifications
  , insertNotification
  , loadNotifications
  , markNotificationsRead

    -- * Mail
  , Pending (..)
  , loadPending
  , clearPending
  , pruneNotifications
  , unsubscribeToken
  , unsubscribeUser
  , lastDigest
  , storeLastDigest
  )
where

import Crypto.Hash.Algorithms (SHA256)
import Crypto.MAC.HMAC (HMAC (..), hmac)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertFromBase, convertToBase)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (Day, UTCTime, addUTCTime, nominalDay)
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, execute_, query, queryWith, query_, (:.) (..))
import Database.SQLite.Simple.FromRow (RowParser, field)
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude
import Wiki.Api.Notifications (ReadMark (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), MailMode (..), Mark, Notification (..), WatchTarget (..), keptNotifications, mailModeName, readMailMode)
import Wiki.Core.User (Membership, User (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Storage.Rows (Stamp (..), stamp)

--------------------------------------------------------------------------------
-- Who is told

-- | A user who may sign in, in the form the notification rules take.
data Telling = Telling
  { user :: User
  , watchOwn :: Bool
  , marks :: Mark
  , mailing :: Bool
  -- ^ Whether their notifications are queued for mail: they have a
  -- verified address, and mail is not off for them.
  }

-- | A user's row as 'tellingOf' reads it: id, login, display name,
-- whether they watch their own pages, whether their address is verified,
-- and their mail mode.
type TellingRow = (Text, Text, Text, Int, Int, Maybe Text)

-- | A 'Telling' from a user's row and everyone's marks.
tellingOf :: Map UserId Mark -> TellingRow -> Telling
tellingOf allMarks (i, login, displayName, own, verified, mail) =
  Telling
    { user = User {id = UserId i, login, displayName}
    , watchOwn = own /= 0
    , marks = Map.findWithDefault mempty (UserId i) allMarks
    , mailing = verified /= 0 && (mail >>= readMailMode) /= Just MailOff
    }

-- | Every user who may sign in, with their watches and choices.
loadTelling :: Connection -> IO [Telling]
loadTelling c = do
  users <- query_ c "SELECT id, login, display_name, watch_own, email_verified_at IS NOT NULL, notification_mail FROM users WHERE disabled = 0 ORDER BY id"
  allMarks <- loadAllMarks c
  pure (map (tellingOf allMarks) users)

-- | 'Audience' says who could be told of something that happened to a
-- page: the page, the spaces of its chain, the users named because they
-- made the page or commented in its thread, and the logins it mentions.
data Audience = Audience
  { page :: PageId
  , spaces :: [SpaceId]
  , named :: [UserId]
  , mentioned :: [Text]
  }

-- | The users who may sign in and could be told of something that
-- happened to a page, with their choices, and their groups. The rules of
-- "Wiki.Core.Notification" ('recipients') tell a user only for a watch on
-- the page or on one of its spaces, for making the page, for commenting in
-- its thread, or for a mention. So only those users are read, through
-- indexes, instead of every user and every watch. Each user's marks hold
-- only their watches of the page and of those spaces, which are the only
-- watches the rules look at.
loadAudience :: Connection -> Audience -> IO ([Telling], Membership)
loadAudience c a = do
  users <- query c ("SELECT u.id, u.login, u.display_name, u.watch_own, u.email_verified_at IS NOT NULL, u.notification_mail FROM users u WHERE u.disabled = 0 AND u.id IN (" <> candidates <> ") ORDER BY u.id") params
  marks <- query c ("SELECT user_id, page_id, space_id, watching FROM watches WHERE " <> watched) watchParams
  members <- query c ("SELECT m.group_id, m.user_id FROM group_members m JOIN users u ON u.id = m.user_id WHERE u.disabled = 0 AND m.user_id IN (" <> candidates <> ")") params
  pure
    ( map (tellingOf (marksOf marks)) users
    , Map.fromListWith (<>) [(GroupId g, Set.singleton (UserId u)) | (g, u) <- members]
    )
  where
    -- The ids of the users who could be told: a union of one indexed
    -- query for each reason, because SQLite reads a whole table for a
    -- single query whose condition is the reasons joined with OR. A reason
    -- with no values is left out, as SQLite's plan for @IN ()@ is a read
    -- of the whole table.
    reasons =
      ("SELECT user_id FROM watches WHERE page_id = ?", [toField a.page.text])
        : [ (q <> " IN (" <> T.intercalate ", " (map (const "?") vs) <> ")", vs)
          | (q, vs) <-
              [ ("SELECT user_id FROM watches WHERE space_id", map (\x -> toField x.text) a.spaces)
              , ("SELECT id FROM users WHERE id", map (\u -> toField u.text) a.named)
              , ("SELECT id FROM users WHERE login", map toField a.mentioned)
              ]
          , not (null vs)
          ]
    candidates = Query (T.intercalate " UNION " (map fst reasons))
    params = concatMap snd reasons
    -- The watches of the page and of its spaces.
    (watched, watchParams) = (Query ("page_id = ?" <> T.concat [" OR space_id = ?" | _ <- a.spaces]), toField a.page.text : map (\x -> toField x.text) a.spaces)

-- | Who created a page: the author of its first version, if known. The
-- first version is the one saved when the page was created, so its time is
-- the page's creation time, and the primary key of @page_versions@ finds
-- it at once. A page an import made has its first version at another time,
-- with no author, so it has no maker either way.
pageMaker :: Connection -> PageId -> IO (Maybe UserId)
pageMaker c page =
  (>>= \(Only author) -> UserId <$> author)
    . head
    <$> query c "SELECT v.author FROM pages p JOIN page_versions v ON v.page_id = p.id AND v.updated_at = p.created_at WHERE p.id = ?" (Only page.text)

--------------------------------------------------------------------------------
-- Watches and choices

loadAllMarks :: Connection -> IO (Map UserId Mark)
loadAllMarks c = marksOf <$> query_ c "SELECT user_id, page_id, space_id, watching FROM watches"

-- | The marks of watch rows (user, page, space, watching), by user.
marksOf :: [(Text, Maybe Text, Maybe Text, Int)] -> Map UserId Mark
marksOf rows = Map.fromListWith (<>) [(UserId u, Map.singleton t (w /= 0)) | (u, p, s, w) <- rows, Just t <- [target p s]]
  where
    target p s = (WatchPage . PageId <$> p) <|> (WatchSpace . SpaceId <$> s)

-- | What a user chose to watch, or not to.
loadMarks :: Connection -> UserId -> IO Mark
loadMarks c u = Map.findWithDefault mempty u <$> loadAllMarks c

-- | Choose to watch a page or a space, or not to.
storeMark :: Connection -> UserId -> WatchTarget -> Bool -> IO ()
storeMark c u t w = case t of
  WatchPage p -> do
    execute c "DELETE FROM watches WHERE user_id = ? AND page_id = ?" (u.text, p.text)
    execute c "INSERT INTO watches (user_id, page_id, watching) VALUES (?, ?, ?)" (u.text, p.text, fromEnum w)
  WatchSpace s -> do
    execute c "DELETE FROM watches WHERE user_id = ? AND space_id = ?" (u.text, s.text)
    execute c "INSERT INTO watches (user_id, space_id, watching) VALUES (?, ?, ?)" (u.text, s.text, fromEnum w)

-- | How a user wants to be notified, as they chose, and whether their
-- address is verified.
data Choices = Choices
  { mail :: Maybe MailMode
  , watchOwn :: Bool
  , verified :: Bool
  }

-- | A user's choices; 'Nothing' for a user who does not exist.
loadChoices :: Connection -> UserId -> IO (Maybe Choices)
loadChoices c u =
  head
    . map (\(mail, own, verified) -> Choices {mail = mail >>= readMailMode, watchOwn = own /= (0 :: Int), verified = verified /= (0 :: Int)})
    <$> query c "SELECT notification_mail, watch_own, email_verified_at IS NOT NULL FROM users WHERE id = ?" (Only u.text)

-- | Turn a user's mail off, and remove their notifications from the mail
-- queue.
mailOff :: Connection -> UserId -> IO ()
mailOff c u = do
  execute c "UPDATE users SET notification_mail = 'off' WHERE id = ?" (Only u.text)
  execute c "UPDATE notifications SET mail = 0 WHERE user_id = ? AND mail = 1" (Only u.text)

-- | Store a user's choices. Turning mail off also removes their queued
-- notifications from the mail queue.
storeChoices :: Connection -> UserId -> MailMode -> Bool -> IO ()
storeChoices c u mail own = do
  execute c "UPDATE users SET notification_mail = ?, watch_own = ? WHERE id = ?" (mailModeName mail, fromEnum own, u.text)
  when (mail == MailOff) $ execute c "UPDATE notifications SET mail = 0 WHERE user_id = ? AND mail = 1" (Only u.text)

--------------------------------------------------------------------------------
-- Notifications

kindName :: Kind -> Text
kindName = \case
  Mentioned -> "mentioned"
  Replied -> "replied"
  Commented -> "commented"
  Changed -> "changed"

readKind :: Text -> Maybe Kind
readKind t = find ((== t) . kindName) [minBound .. maxBound]

-- | Add a notification for a user, as their newest, queued for mail or
-- not.
insertNotification :: Connection -> UserId -> Notification -> Bool -> IO ()
insertNotification c u n mail =
  execute
    c
    "INSERT INTO notifications (id, user_id, kind, page_id, thread_id, actor, actor_name, title, excerpt, created_at, seq, read_at, mail) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, (SELECT coalesce(max(seq) + 1, 0) FROM notifications), NULL, ?)"
    ( (n.id.text, u.text, kindName n.kind, n.page.text, (\t -> t.text) <$> n.thread, n.actor.id.text)
        :. (n.actor.name, n.title, n.excerpt, Stamp n.createdAt, fromEnum mail)
    )

-- | A notification's columns, as 'notificationRow' reads them.
notificationColumns :: Query
notificationColumns = "SELECT id, kind, page_id, thread_id, actor, actor_name, title, excerpt, created_at, read_at IS NOT NULL FROM notifications "

notificationRow :: RowParser (Maybe Notification)
notificationRow = do
  i <- field
  kind <- field
  page <- field
  thread <- field
  actor <- field
  actorName <- field
  title <- field
  excerpt <- field
  createdAt <- stamp
  wasRead <- field
  pure $
    (\k -> Notification {id = NotificationId i, kind = k, page = PageId page, thread = CommentThreadId <$> thread, actor = Author {id = UserId actor, name = actorName}, title, excerpt, createdAt, read = wasRead /= (0 :: Int), location = Nothing})
      <$> readKind kind

-- | A user's notifications, the newest first, without where their pages
-- are now, which the caller looks up.
loadNotifications :: Connection -> UserId -> IO [Notification]
loadNotifications c u =
  catMaybes <$> queryWith notificationRow c (notificationColumns <> "WHERE user_id = ? ORDER BY seq DESC") (Only u.text)

-- | Mark some of a user's notifications read, or all of them.
markNotificationsRead :: Connection -> UserId -> UTCTime -> ReadMark -> IO ()
markNotificationsRead c u now m
  | m.everything = execute c "UPDATE notifications SET read_at = ? WHERE user_id = ? AND read_at IS NULL" (Stamp now, u.text)
  | otherwise = for_ m.ids $ \i -> execute c "UPDATE notifications SET read_at = ? WHERE user_id = ? AND id = ? AND read_at IS NULL" (Stamp now, u.text, i.text)

--------------------------------------------------------------------------------
-- Mail

-- | A user's notifications queued for mail, the oldest first, with what
-- mailing them needs.
data Pending = Pending
  { user :: User
  , email :: Maybe Text
  , verified :: Bool
  , mail :: Maybe MailMode
  , notifications :: [Notification]
  }

-- | Every user who may sign in and has notifications queued for mail.
loadPending :: Connection -> IO [Pending]
loadPending c = do
  -- A user who may not sign in is mailed nothing, now or later.
  execute_ c "UPDATE notifications SET mail = 0 WHERE mail = 1 AND user_id IN (SELECT id FROM users WHERE disabled = 1)"
  users <- query_ c "SELECT id, login, display_name, email, email_verified_at IS NOT NULL, notification_mail FROM users WHERE id IN (SELECT user_id FROM notifications WHERE mail = 1)"
  for users $ \(i, login, displayName, email, verified, mail :: Maybe Text) -> do
    ns <- catMaybes <$> queryWith notificationRow c (notificationColumns <> "WHERE user_id = ? AND mail = 1 ORDER BY seq") (Only i)
    pure Pending {user = User {id = UserId i, login, displayName}, email, verified = verified /= (0 :: Int), mail = mail >>= readMailMode, notifications = ns}

-- | Remove these notifications from the mail queue: they were mailed, or
-- will not be.
clearPending :: Connection -> [NotificationId] -> IO ()
clearPending c ids = for_ ids $ \i -> execute c "UPDATE notifications SET mail = 0 WHERE id = ?" (Only i.text)

-- | Delete what is no longer kept: notifications older than the days
-- 'keptNotifications' keeps, and a user's beyond the most it keeps.
pruneNotifications :: Connection -> UTCTime -> IO ()
pruneNotifications c now = do
  let (days, most) = keptNotifications
      cutoff = addUTCTime (negate (fromIntegral days * nominalDay)) now
  old <- query_ c "SELECT id, created_at FROM notifications" :: IO [(Text, Stamp)]
  for_ [i | (i, Stamp t) <- old, t < cutoff] $ \i -> execute c "DELETE FROM notifications WHERE id = ?" (Only i)
  execute
    c
    "DELETE FROM notifications WHERE id IN (SELECT id FROM (SELECT id, row_number() OVER (PARTITION BY user_id ORDER BY seq DESC) AS n FROM notifications) WHERE n > ?)"
    (Only most)

-- | The day the last digest was mailed, if one ever was.
lastDigest :: Connection -> IO (Maybe Day)
lastDigest c = (>>= (\(Only v) -> readMaybe (toS v :: [Char]))) . head <$> (query_ c "SELECT value FROM settings WHERE key = 'notification-digest'" :: IO [Only Text])

storeLastDigest :: Connection -> Day -> IO ()
storeLastDigest c day =
  execute c "INSERT INTO settings (key, value) VALUES ('notification-digest', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value" (Only (show day :: Text))

-- | The key the unsubscribe links are signed with: generated the first
-- time, and stored.
unsubscribeKey :: Connection -> IO ByteString
unsubscribeKey c = do
  fresh <- getRandomBytes 32 :: IO ByteString
  execute c "INSERT OR IGNORE INTO settings (key, value) VALUES ('notification-key', ?)" (Only (decodeUtf8 (convertToBase Base16 fresh) :: Text))
  rows <- query_ c "SELECT value FROM settings WHERE key = 'notification-key'" :: IO [Only Text]
  pure $ case rows of
    Only hex : _ -> fromRight fresh (convertFromBase Base16 (encodeUtf8 hex))
    [] -> fresh

-- | The MAC of a user's id, for their unsubscribe link.
mac :: ByteString -> UserId -> Text
mac key u = decodeUtf8 (convertToBase Base16 (hmac key (encodeUtf8 ("unsubscribe:" <> u.text)) :: HMAC SHA256))

-- | The secret of a user's unsubscribe link.
unsubscribeToken :: Connection -> UserId -> IO Text
unsubscribeToken c u = (\key -> u.text <> "." <> mac key u) <$> unsubscribeKey c

-- | Turn off the mail of the user an unsubscribe link's secret names. The
-- result is whether it named one.
unsubscribeUser :: Connection -> Text -> IO Bool
unsubscribeUser c token = case T.breakOnEnd "." token of
  (withDot, given)
    | Just u <- UserId <$> T.stripSuffix "." withDot
    , not (T.null u.text) -> do
        key <- unsubscribeKey c
        if BA.constEq (encodeUtf8 given :: ByteString) (encodeUtf8 (mac key u) :: ByteString)
          then do
            there <- query c "SELECT count(*) FROM users WHERE id = ?" (Only u.text) :: IO [Only Int]
            if there == [Only 1]
              then mailOff c u $> True
              else pure False
          else pure False
  _ -> pure False
