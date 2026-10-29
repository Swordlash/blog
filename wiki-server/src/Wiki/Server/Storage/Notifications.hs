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
  , Audience (..)
  , loadAudience
  , pageMaker

    -- * Watches and choices
  , loadMarksOn
  , storeMark
  , Choices (..)
  , loadChoices
  , storeChoices

    -- * Notifications
  , insertNotification
  , loadNewest
  , unreadBySpace
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
import Database.Beam (QExpr, aggregate_, all_, as_, asc_, countAll_, default_, delete, desc_, filter_, group_, guard_, in_, insert, insertExpressions, insertValues, isNothing_, join_, just_, limit_, offset_, orderBy_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (<.), (==.), (>.), (||.))
import Database.Beam qualified as Beam
import Protolude
import Wiki.Api.Notifications (ReadMark (..))
import Wiki.Api.Security (UnsubscribeToken (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Kind (..), MailMode (..), Mark, Notification (..), WatchTarget (..), keptNotifications, mailModeName, readMailMode)
import Wiki.Core.User (Email (..), Login (..), Membership, User (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (chunksOf, holds, keepSetting, micro, settingValue, storeSetting)
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

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

-- | A 'Telling' from a user's row and the marks read.
tellingOf :: Map UserId Mark -> S.Users Identity -> Telling
tellingOf allMarks r =
  Telling
    { user = User {id = UserId r.id, login = Login r.login, displayName = r.display_name}
    , watchOwn = r.watch_own
    , marks = Map.findWithDefault mempty (UserId r.id) allMarks
    , mailing = isJust r.email_verified_at && (r.notification_mail >>= readMailMode) /= Just MailOff
    }

-- | 'Audience' says who could be told of something that happened to a
-- page: the page, the spaces of its chain, the users named because they
-- made the page or commented in its thread, and the logins it mentions.
data Audience = Audience
  { page :: PageId
  , spaces :: [SpaceId]
  , named :: [UserId]
  , mentioned :: [Text]
  }

-- | The ids a condition picks from a table, in groups of values: an empty
-- list asks nothing.
idsWhere :: (Monad m) => [a] -> ([a] -> m [Text]) -> m [Text]
idsWhere xs f = concat <$> traverse f (chunksOf 500 xs)

-- | The users who may sign in and could be told of something that
-- happened to a page, with their choices, and their groups. The rules of
-- "Wiki.Core.Notification" ('recipients') tell a user only for a watch on
-- the page or on one of its spaces, for making the page, for commenting in
-- its thread, or for a mention. So only those users are read, each reason
-- by its own query through an index, instead of every user and every
-- watch. Each user's marks hold only their watches of the page and of
-- those spaces, which are the only watches the rules look at.
loadAudience :: (Backend be) => Audience -> Db be ([Telling], Membership)
loadAudience a = do
  onPage <- runSelectReturningList (select ((\w -> w.user_id) <$> filter_ (\w -> w.page_id `holds` val_ a.page.text) (all_ wikiDb.watches)))
  onSpaces <- idsWhere a.spaces $ \chunk ->
    runSelectReturningList (select ((\w -> w.user_id) <$> filter_ (\w -> w.space_id `in_` map (\s -> just_ (val_ s.text)) chunk) (all_ wikiDb.watches)))
  mentioned <- idsWhere a.mentioned $ \chunk ->
    runSelectReturningList (select ((\u -> u.id) <$> filter_ (\u -> u.login `in_` map val_ chunk) (all_ wikiDb.users)))
  let candidates = ordNub (onPage <> onSpaces <> map (\u -> u.text) a.named <> mentioned)
  users <- fmap concat . for (chunksOf 500 candidates) $ \chunk ->
    runSelectReturningList (select (filter_ (\u -> u.disabled ==. val_ False &&. u.id `in_` map val_ chunk) (all_ wikiDb.users)))
  marks <-
    runSelectReturningList . select $
      filter_ (\w -> w.page_id `holds` val_ a.page.text ||. w.space_id `in_` map (\s -> just_ (val_ s.text)) a.spaces) (all_ wikiDb.watches)
  let active = map (\u -> u.id) users
  members <- fmap concat . for (chunksOf 500 active) $ \chunk ->
    runSelectReturningList (select (filter_ (\m -> m.user_id `in_` map val_ chunk) (all_ wikiDb.group_members)))
  pure
    ( map (tellingOf (marksOf marks)) (sortOn (\u -> u.id) users)
    , Map.fromListWith (<>) [(GroupId m.group_id, Set.singleton (UserId m.user_id)) | m <- members]
    )

-- | Who created a page: the author of its first version, if known. The
-- first version is the one saved when the page was created, so its time is
-- the page's creation time, and the primary key of @page_versions@ finds
-- it at once. A page an import made has its first version at another time,
-- with no author, so it has no maker either way.
pageMaker :: (Backend be) => PageId -> Db be (Maybe UserId)
pageMaker page = do
  author <- runSelectReturningOne . select $ do
    p <- filter_ (\p -> p.id ==. val_ page.text) (all_ wikiDb.pages)
    v <- join_ wikiDb.page_versions (\v -> v.page_id ==. p.id &&. v.updated_at ==. p.created_at)
    pure v.author
  pure (UserId <$> join author)

--------------------------------------------------------------------------------
-- Watches and choices

-- | The marks of watch rows, by user.
marksOf :: [S.Watches Identity] -> Map UserId Mark
marksOf rows = Map.fromListWith (<>) [(UserId w.user_id, Map.singleton t w.watching) | w <- rows, Just t <- [target w]]
  where
    target w = (WatchPage . PageId <$> w.page_id) <|> (WatchSpace . SpaceId <$> w.space_id)

-- | What a user chose to watch, or not to, of a page and of some spaces:
-- the marks the rules read to say whether the user watches the page or
-- the last of the spaces ("Wiki.Core.Notification"'s 'pageWatch' and
-- 'spaceWatch'), given the page, if it is one, and its chain of spaces.
-- Each query names the page or the spaces, so the database finds the rows
-- through the unique indexes on a user's watches.
loadMarksOn :: (Backend be) => UserId -> Maybe PageId -> [SpaceId] -> Db be Mark
loadMarksOn u page spaces = do
  onPage <- for (toList page) $ \p ->
    runSelectReturningList (select (filter_ (\w -> w.user_id ==. val_ u.text &&. w.page_id `holds` val_ p.text) (all_ wikiDb.watches)))
  onSpaces <-
    if null spaces
      then pure []
      else runSelectReturningList (select (filter_ (\w -> w.user_id ==. val_ u.text &&. w.space_id `in_` map (\s -> just_ (val_ s.text)) spaces) (all_ wikiDb.watches)))
  pure (Map.findWithDefault mempty u (marksOf (concat onPage <> onSpaces)))

-- | Choose to watch a page or a space, or not to.
storeMark :: (Backend be) => UserId -> WatchTarget -> Bool -> Db be ()
storeMark u t w = case t of
  WatchPage p -> do
    runDelete (delete wikiDb.watches (\x -> x.user_id ==. val_ u.text &&. x.page_id `holds` val_ p.text))
    runInsert (insert wikiDb.watches (insertValues [S.WatchRow {user_id = u.text, page_id = Just p.text, space_id = Nothing, watching = w}]))
  WatchSpace s -> do
    runDelete (delete wikiDb.watches (\x -> x.user_id ==. val_ u.text &&. x.space_id `holds` val_ s.text))
    runInsert (insert wikiDb.watches (insertValues [S.WatchRow {user_id = u.text, page_id = Nothing, space_id = Just s.text, watching = w}]))

-- | How a user wants to be notified, as they chose, and whether their
-- address is verified.
data Choices = Choices
  { mail :: Maybe MailMode
  , watchOwn :: Bool
  , verified :: Bool
  }

-- | A user's choices; 'Nothing' for a user who does not exist.
loadChoices :: (Backend be) => UserId -> Db be (Maybe Choices)
loadChoices u =
  fmap (\r -> Choices {mail = r.notification_mail >>= readMailMode, watchOwn = r.watch_own, verified = isJust r.email_verified_at})
    <$> runSelectReturningOne (select (filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))

-- | Take a user's notifications out of the mail queue.
unqueue :: (Backend be) => (forall s. S.Notifications (QExpr be s) -> QExpr be s Bool) -> Db be ()
unqueue cond = runUpdate (update wikiDb.notifications (\n -> n.mail <-. val_ False) (\n -> n.mail ==. val_ True &&. cond n))

-- | Turn a user's mail off, and remove their notifications from the mail
-- queue.
mailOff :: (Backend be) => UserId -> Db be ()
mailOff u = do
  runUpdate (update wikiDb.users (\r -> r.notification_mail <-. val_ (Just (mailModeName MailOff))) (\r -> r.id ==. val_ u.text))
  unqueue (\n -> n.user_id ==. val_ u.text)

-- | Store a user's choices. Turning mail off also removes their queued
-- notifications from the mail queue.
storeChoices :: (Backend be) => UserId -> MailMode -> Bool -> Db be ()
storeChoices u mail own = do
  runUpdate (update wikiDb.users (\r -> (r.notification_mail <-. val_ (Just (mailModeName mail))) <> (r.watch_own <-. val_ own)) (\r -> r.id ==. val_ u.text))
  when (mail == MailOff) $ unqueue (\n -> n.user_id ==. val_ u.text)

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
-- not. The database numbers it after the last one ('seq').
insertNotification :: (Backend be) => UserId -> Notification -> Bool -> Db be ()
insertNotification u n mail =
  runInsert . insert wikiDb.notifications $
    insertExpressions
      [ S.NotificationRow
          { seq = default_
          , id = val_ n.id.text
          , user_id = val_ u.text
          , kind = val_ (kindName n.kind)
          , page_id = val_ n.page.text
          , thread_id = val_ ((\t -> t.text) <$> n.thread)
          , actor = val_ n.actor.id.text
          , actor_name = val_ n.actor.name
          , title = val_ n.title
          , excerpt = val_ n.excerpt
          , created_at = val_ (micro n.createdAt)
          , read_at = val_ Nothing
          , mail = val_ mail
          }
      ]

notificationOf :: S.Notifications Identity -> Maybe Notification
notificationOf r =
  (\k -> Notification {id = NotificationId r.id, kind = k, page = PageId r.page_id, thread = CommentThreadId <$> r.thread_id, actor = Author {id = UserId r.actor, name = r.actor_name}, title = r.title, excerpt = r.excerpt, createdAt = r.created_at, read = isJust r.read_at, location = Nothing})
    <$> readKind r.kind

-- | Some of a user's notifications, the newest first, without where their
-- pages are now: at most a given number, after skipping a given number of
-- newer ones. With them, how many rows were read, which is less than the
-- number asked for only when no older notification is left.
loadNewest :: (Backend be) => UserId -> Int -> Int -> Db be (Int, [Notification])
loadNewest u most skipped = do
  rows <- runSelectReturningList (select (limit_ (fromIntegral most) (offset_ (fromIntegral skipped) (orderBy_ (\n -> desc_ n.seq) (filter_ (\n -> n.user_id ==. val_ u.text) (all_ wikiDb.notifications))))))
  pure (length rows, mapMaybe notificationOf rows)

-- | How many unread notifications a user has, by the space their page is
-- in. The caller adds up the counts of the spaces the user may read, so
-- that a notification about a page they may no longer read is not counted.
unreadBySpace :: (Backend be) => UserId -> Db be [(SpaceId, Int)]
unreadBySpace u = do
  rows <- runSelectReturningList . select . aggregate_ (\(space, _) -> (group_ space, as_ @Int64 countAll_)) $ do
    n <- filter_ (\n -> n.user_id ==. val_ u.text &&. isNothing_ n.read_at) (all_ wikiDb.notifications)
    p <- join_ wikiDb.pages (\p -> p.id ==. n.page_id)
    pure (p.space_id, n.id)
  pure [(SpaceId s, fromIntegral c) | (s, c) <- rows]

-- | Mark some of a user's notifications read, or all of them.
markNotificationsRead :: forall be. (Backend be) => UserId -> UTCTime -> ReadMark -> Db be ()
markNotificationsRead u now m = do
  let unread :: forall s. S.Notifications (QExpr be s) -> QExpr be s Bool
      unread n = n.user_id ==. val_ u.text &&. isNothing_ n.read_at
      readNow :: forall s. S.Notifications (Beam.QField s) -> Beam.QAssignment be s
      readNow n = n.read_at <-. val_ (Just (micro now))
  if m.everything
    then runUpdate (update wikiDb.notifications readNow unread)
    else for_ (chunksOf 500 m.ids) $ \chunk ->
      runUpdate (update wikiDb.notifications readNow (\n -> unread n &&. n.id `in_` map (\i -> val_ i.text) chunk))

--------------------------------------------------------------------------------
-- Mail

-- | A user's notifications queued for mail, the oldest first, with what
-- mailing them needs.
data Pending = Pending
  { user :: User
  , email :: Maybe Email
  , verified :: Bool
  , mail :: Maybe MailMode
  , notifications :: [Notification]
  }

-- | Every user who may sign in and has notifications queued for mail.
loadPending :: (Backend be) => Db be [Pending]
loadPending = do
  -- A user who may not sign in is mailed nothing, now or later.
  disabled <- runSelectReturningList (select ((\u -> u.id) <$> filter_ (\u -> u.disabled ==. val_ True) (all_ wikiDb.users)))
  for_ (chunksOf 500 disabled) $ \chunk -> unqueue (\n -> n.user_id `in_` map val_ chunk)
  waiting <- runSelectReturningList . select . aggregate_ (\n -> group_ n.user_id) $ filter_ (\n -> n.mail ==. val_ True) (all_ wikiDb.notifications)
  users <- fmap concat . for (chunksOf 500 waiting) $ \chunk ->
    runSelectReturningList (select (orderBy_ (\u -> asc_ u.id) (filter_ (\u -> u.id `in_` map val_ chunk) (all_ wikiDb.users))))
  for users $ \r -> do
    ns <- mapMaybe notificationOf <$> runSelectReturningList (select (orderBy_ (\n -> asc_ n.seq) (filter_ (\n -> n.user_id ==. val_ r.id &&. n.mail ==. val_ True) (all_ wikiDb.notifications))))
    pure
      Pending
        { user = User {id = UserId r.id, login = Login r.login, displayName = r.display_name}
        , email = Email <$> r.email
        , verified = isJust r.email_verified_at
        , mail = r.notification_mail >>= readMailMode
        , notifications = ns
        }

-- | Remove these notifications from the mail queue: they were mailed, or
-- will not be.
clearPending :: (Backend be) => [NotificationId] -> Db be ()
clearPending ids = for_ (chunksOf 500 ids) $ \chunk -> unqueue (\n -> n.id `in_` map (\i -> val_ i.text) chunk)

-- | Delete what is no longer kept: notifications older than the days
-- 'keptNotifications' keeps, and a user's beyond the most it keeps. The
-- users with too many are found by a count by user; for each, the seq of
-- the last one kept is read from the index on a user's notifications, and
-- the older ones are deleted.
pruneNotifications :: (Backend be) => UTCTime -> Db be ()
pruneNotifications now = do
  let (days, most) = keptNotifications
      cutoff = addUTCTime (negate (fromIntegral days * nominalDay)) now
  runDelete (delete wikiDb.notifications (\n -> n.created_at <. val_ (micro cutoff)))
  over <- runSelectReturningList . select $ do
    (u, n) <- aggregate_ (\n -> (group_ n.user_id, as_ @Int64 countAll_)) (all_ wikiDb.notifications)
    guard_ (n >. val_ (fromIntegral most))
    pure u
  for_ over $ \u -> do
    lastKept <- runSelectReturningOne (select (limit_ 1 (offset_ (fromIntegral (most - 1)) ((\n -> n.seq) <$> orderBy_ (\n -> desc_ n.seq) (filter_ (\n -> n.user_id ==. val_ u) (all_ wikiDb.notifications))))))
    for_ lastKept $ \s -> runDelete (delete wikiDb.notifications (\n -> n.user_id ==. val_ u &&. n.seq <. val_ s))

-- | The day the last digest was mailed, if one ever was.
lastDigest :: (Backend be) => Db be (Maybe Day)
lastDigest = (>>= readMaybe . (toS :: Text -> [Char])) <$> settingValue "notification-digest"

storeLastDigest :: (Backend be) => Day -> Db be ()
storeLastDigest day = storeSetting "notification-digest" (show day)

-- | The key the unsubscribe links are signed with: generated the first
-- time, and stored.
unsubscribeKey :: forall be. (Backend be) => Db be ByteString
unsubscribeKey = do
  fresh <- liftIO (getRandomBytes 32) :: Db be ByteString
  hex <- keepSetting "notification-key" (decodeUtf8 (convertToBase Base16 fresh))
  pure (fromRight fresh (convertFromBase Base16 (encodeUtf8 hex)))

-- | The MAC of a user's id, for their unsubscribe link.
mac :: ByteString -> UserId -> Text
mac key u = decodeUtf8 (convertToBase Base16 (hmac key (encodeUtf8 ("unsubscribe:" <> u.text)) :: HMAC SHA256))

-- | The secret of a user's unsubscribe link.
unsubscribeToken :: (Backend be) => UserId -> Db be UnsubscribeToken
unsubscribeToken u = (\key -> UnsubscribeToken (u.text <> "." <> mac key u)) <$> unsubscribeKey

-- | Turn off the mail of the user an unsubscribe link's secret names. The
-- result is whether it named one.
unsubscribeUser :: (Backend be) => UnsubscribeToken -> Db be Bool
unsubscribeUser token = case T.breakOnEnd "." token.text of
  (withDot, given)
    | Just u <- UserId <$> T.stripSuffix "." withDot
    , not (T.null u.text) -> do
        key <- unsubscribeKey
        if BA.constEq (encodeUtf8 given :: ByteString) (encodeUtf8 (mac key u) :: ByteString)
          then do
            there <- runSelectReturningOne (select ((\r -> r.id) <$> filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))
            if isJust there
              then mailOff u $> True
              else pure False
          else pure False
  _ -> pure False
