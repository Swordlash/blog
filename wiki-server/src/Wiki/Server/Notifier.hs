-- | The thread that mails notifications (WP4.13 of docs/PLAN.md,
-- "Wiki.Core.Notification"): at once, or as a daily digest, as each user
-- chose, through the mail server the administration has set
-- ("Wiki.Server.Mail"), and only to a verified address.
--
-- A notification is made by the write it is about, in its transaction,
-- marked to be mailed if its user is mailed at all ("Wiki.Server.Storage").
-- This thread mails it later, never inside a transaction (sending a mail
-- may take half a minute): it is woken as notifications are made
-- ('wakeUp', which the storage's @notify@ calls), and looks every minute
-- besides, for the digest. Before it mails a notification it asks again
-- whether its user may read its page, since a grant may have been taken
-- away since it was made; one they may not read any more is not mailed.
--
-- A user mailed at once gets one mail of what is waiting for them when
-- the thread looks, usually one notification; a user mailed daily gets
-- the day's in one digest, grouped by page ('Wiki.Core.Notification.digest'),
-- once a day from 'digestHour' UTC. Without a mail server (or the wiki's
-- address its links start with) nothing can be mailed, and what waits is
-- let go rather than mailed late once one is set. A mail that fails is
-- logged and tried again at the next look. Once a day the thread also
-- deletes the notifications no longer kept
-- ('Wiki.Core.Notification.keptNotifications').
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

import Control.Concurrent.STM (TVar, modifyTVar', newTVarIO, readTVar, registerDelay)
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
import Wiki.Server.Storage (Storage, locatedFor, readServerSettings, withDatabase)
import Wiki.Server.Storage.Notifications (Pending (..), clearPending, lastDigest, loadPending, pruneNotifications, storeLastDigest, unsubscribeToken)

-- | What wakes the thread: counted up when notifications are made.
newtype Wake = Wake (TVar Int)

newWake :: IO Wake
newWake = Wake <$> newTVarIO 0

-- | Notifications were made: the thread looks now rather than within the
-- minute. It never waits.
wakeUp :: Wake -> IO ()
wakeUp (Wake v) = atomically (modifyTVar' v (+ 1))

-- | The thread, and what it needs.
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

-- | Until it is cancelled (the server stopping): look when woken, and every
-- minute.
runNotifier :: Notifier -> IO ()
runNotifier n = forever $ do
  let Wake v = n.wake
  seen <- atomically (readTVar v)
  getCurrentTime >>= \now ->
    mailRound n now `catch` \(e :: SomeException) ->
      logWith n.logger Error [("event", "notification-mail"), ("error", show e)]
  timer <- registerDelay 60_000_000
  atomically $ do
    woken <- (/= seen) <$> readTVar v
    late <- readTVar timer
    check (woken || late)

-- | One look: mail what is due, and once a day the digests and the
-- pruning.
mailRound :: Notifier -> UTCTime -> IO ()
mailRound n now = do
  mailer <- mailerFrom n.sendMail <$> readServerSettings n.storage
  last' <- withDatabase n.storage lastDigest
  let today = utctDay now
      digestDue = todHour (timeToTimeOfDay (utctDayTime now)) >= digestHour && last' < Just today
  pending <- withDatabase n.storage loadPending
  for_ pending $ \p -> do
    let ids = map (\x -> x.id) p.notifications
        mode = effectiveMailMode p.verified p.mail
    case (mailer, p.email, mode) of
      (Just m, Just email, MailAtOnce) | p.verified -> send m email False p
      (Just m, Just email, MailDaily) | p.verified -> when digestDue (send m email True p)
      -- Nothing can be mailed to them, now or later.
      _ -> withDatabase n.storage (`clearPending` ids)
  when digestDue $ withDatabase n.storage $ \c -> do
    storeLastDigest c today
    pruneNotifications c now
  where
    send m email isDigest p = do
      readable <- catMaybes <$> traverse (locatedFor n.storage p.user.id) p.notifications
      let ids = map (\x -> x.id) p.notifications
      if null readable
        then withDatabase n.storage (`clearPending` ids)
        else do
          token <- withDatabase n.storage (`unsubscribeToken` p.user.id)
          let pathOf l = Duplex.print route (Page l.space l.page)
              message = notificationMessage m.publicUrl email token isDigest (dropSlash . pathOf) (digest readable)
          m.deliver message >>= \case
            Right () -> do
              withDatabase n.storage (`clearPending` ids)
              logWith n.logger Info [("event", "notification-mail"), ("user", p.user.id.text), ("notifications", show (length readable)), ("digest", show isDigest)]
            Left why -> logWith n.logger Warning [("event", "notification-mail"), ("user", p.user.id.text), ("error", why)]
    -- The route's path is absolute; the wiki's address ends in a slash.
    dropSlash t = fromMaybe t (T.stripPrefix "/" t)
