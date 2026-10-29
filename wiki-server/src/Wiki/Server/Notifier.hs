-- | The thread that mails notifications (WP4.13 of docs/PLAN.md,
-- "Wiki.Core.Notification"): at once, or as a daily digest, as each user
-- chose, through the mail server the administration has set
-- ("Wiki.Server.Mail"), and only to a verified address.
--
-- A notification is created by the write it is about, in that write's
-- transaction, and queued for mail if its user gets mail at all
-- ("Wiki.Server.Storage"). This thread mails it later, never inside a
-- transaction (sending a mail may take half a minute). It is woken when
-- notifications are created ('wakeUp', which the storage's @notify@
-- calls), and also checks every minute, for the digest. Before it mails a
-- notification it checks again whether its user may read its page, since
-- a grant may have been removed since it was created; a notification about
-- a page they can no longer read is not mailed.
--
-- A user who gets mail at once gets one mail with what is queued for them
-- when the thread checks, usually one notification. A user who gets mail
-- daily gets the day's notifications in one digest, grouped by page
-- ('Wiki.Core.Notification.digest'), once a day from 'digestHour' UTC.
-- Without a mail server (or the wiki's address for the links to start
-- with) nothing can be mailed, and the queue is cleared rather than mailed
-- late once a server is set. A mail that fails is logged and retried at the
-- next check. Once a day the thread also deletes the notifications no
-- longer kept ('Wiki.Core.Notification.keptNotifications').
module Wiki.Server.Notifier
  ( -- * Waking it
    Wake
  , newWake
  , wakeUp

    -- * The thread
  , Notifier
  , newNotifier
  , runNotifier
  , mailRound
  , digestHour
  )
where

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar, readTVarIO, registerDelay)
import Data.Text qualified as T
import Data.Time (UTCTime (..), getCurrentTime, timeToTimeOfDay, todHour, utctDay)
import Halogen.Router.Duplex qualified as Duplex
import Protolude
import Wiki.App.Route (Route (..), route)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Notification (MailMode (..), Notification (..), PageLocation (..), digest, effectiveMailMode)
import Wiki.Core.User (User (..))
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Mail (Mailer (..), SendMail, mailerFrom, notificationMessage)
import Wiki.Server.Storage (Storage, locatedFor, readServerSettings, reading, writing)
import Wiki.Server.Storage.Notifications (Pending (..), clearPending, lastDigest, loadPending, pruneNotifications, storeLastDigest, unqueueUsers, unsubscribeToken)

-- | What wakes the thread: incremented when notifications are created.
newtype Wake = Wake (TVar Int)

newWake :: IO Wake
newWake = Wake <$> newTVarIO 0

-- | Notifications were created: the thread checks now rather than within
-- the minute. It never waits.
wakeUp :: Wake -> IO ()
wakeUp (Wake v) = atomically (modifyTVar' v (+ 1))

-- | The notifier thread's state, and what it needs.
data Notifier = Notifier
  { storage :: Storage
  , logger :: Logger
  , sendMail :: SendMail
  , wake :: Wake
  }

newNotifier :: Logger -> SendMail -> Wake -> Storage -> Notifier
newNotifier logger sendMail wake storage = Notifier {storage, logger, sendMail, wake}

-- | The hour of the day, UTC, from which the day's digest is mailed.
digestHour :: Int
digestHour = 7

-- | Until it is cancelled (the server stopping), check when woken, and
-- every minute. Not when the server starts: what was due before it
-- stopped waits for the first minute, so that a starting server writes
-- nothing to its database it was not asked to (a digest's day, the
-- pruning) while whoever started it may still be working on the file.
runNotifier :: Notifier -> IO ()
runNotifier n = do
  readTVarIO v >>= waitFrom
  forever $ do
    seen <- readTVarIO v
    -- Failures are logged and retried at the next check; but the server
    -- stopping, which cancels the thread, ends it.
    now <- getCurrentTime
    try (mailRound n now) >>= \case
      Left e
        | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        | otherwise -> logWith n.logger Error [("event", "notification-mail"), ("error", show (e :: SomeException))]
      Right () -> pass
    waitFrom seen
  where
    Wake v = n.wake
    -- Wait until woken since the count was this, or a minute has passed.
    waitFrom seen = do
      timer <- registerDelay 60_000_000
      atomically $ do
        woken <- (/= seen) <$> readTVar v
        late <- readTVar timer
        check (woken || late)

-- | One check: mail what is due, and once a day the digests and the
-- pruning.
mailRound :: Notifier -> UTCTime -> IO ()
mailRound n now = do
  mailer <- mailerFrom n.sendMail <$> readServerSettings n.storage
  last' <- reading n.storage lastDigest
  let today = utctDay now
      digestDue = todHour (timeToTimeOfDay (utctDayTime now)) >= digestHour && last' < Just today
  (disabled, pending) <- reading n.storage loadPending
  unless (null disabled) $ writing n.storage (unqueueUsers disabled)
  for_ pending $ \p -> do
    let ids = map (\x -> x.id) p.notifications
        mode = effectiveMailMode p.verified p.mail
    case (mailer, p.email, mode) of
      (Just m, Just email, MailAtOnce) | p.verified -> send m email False p
      (Just m, Just email, MailDaily) | p.verified -> when digestDue (send m email True p)
      -- Nothing can be mailed to them, now or later.
      _ -> writing n.storage (clearPending ids)
  when digestDue $
    writing n.storage (storeLastDigest today >> pruneNotifications now)
  where
    send m email isDigest p = do
      readable <- catMaybes <$> traverse (locatedFor n.storage p.user.id) p.notifications
      let ids = map (\x -> x.id) p.notifications
      if null readable
        then writing n.storage (clearPending ids)
        else do
          token <- writing n.storage (unsubscribeToken p.user.id)
          let pathOf l = Duplex.print route (Page l.space l.page)
              message = notificationMessage m.publicUrl email token isDigest (dropSlash . pathOf) (digest readable)
          m.deliver message >>= \case
            Right () -> do
              writing n.storage (clearPending ids)
              logWith n.logger Info [("event", "notification-mail"), ("user", p.user.id.text), ("notifications", show (length readable)), ("digest", show isDigest)]
            Left why -> logWith n.logger Warning [("event", "notification-mail"), ("user", p.user.id.text), ("error", why)]
    -- The route's path is absolute; the wiki's address ends in a slash.
    dropSlash t = fromMaybe t (T.stripPrefix "/" t)
