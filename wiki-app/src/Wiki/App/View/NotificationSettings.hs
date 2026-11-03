{-# LANGUAGE QuasiQuotes #-}

-- | The signed-in user's notification settings (WP4.13 of docs/PLAN.md),
-- in the account panel: notifications mailed never, at once, or as a daily
-- digest, and whether they watch the pages they create and the threads
-- they take part in. Each choice is saved as it is made.
--
-- Mail needs a verified address and a server that sends mail. Without
-- either, the mail choice is shown disabled, saying what is missing (the
-- demo has neither).
--
-- Under the choices, the user's own feed of notifications (WP5.31): an
-- Atom feed for a feed reader, at a secret address the user makes here,
-- copies, and replaces with a new one when they want the old to stop
-- answering. The demo has none, and says so.
--
-- Fetched when the panel opens, like the rest of the panel: the server
-- never prerenders it.
module Wiki.App.View.NotificationSettings
  ( component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Notifications (FeedAddress (..), NotificationSettings (..), NotificationSettingsChange (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Browser (absoluteUrl, copyText)
import Wiki.App.View.Common (errorMessage)
import Wiki.Core.Notification (MailMode (..), mailModeName)

data State = State
  { settings :: Maybe (Either WikiError NotificationSettings)
  , problem :: Maybe WikiError
  , busy :: Bool
  , feed :: Maybe (Either WikiError Feed)
  -- ^ The feed's address, once fetched: none yet, or the address as a
  -- full URL for a feed reader; 'Invalid' where there is no feed.
  , feedProblem :: Maybe WikiError
  , copied :: Bool
  , feedField :: H.RefLabel
  -- ^ The field showing the address, which "Copy" copies from.
  }

-- | The user's feed, as the panel shows it: its address as a full URL, or
-- none made yet.
newtype Feed = Feed (Maybe Text)

data Action = Initialize | ChooseMail MailMode | SetWatchOwn Bool | MakeFeed | CopyFeed

component :: forall query input output m. (MonadNotifications m, MonadIO m, MonadUUID m) => H.Component query input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> do
          feedField <- H.newRefLabel "notification-feed"
          pure State {settings = Nothing, problem = Nothing, busy = False, feed = Nothing, feedProblem = Nothing, copied = False, feedField}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st = case st.settings of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
      Just (Right s) ->
        [hh|
          <div class="notification-settings">
            <fieldset class="notification-mail" disabled={{ not (canMail s) || st.busy }}>
              <legend>Mail me what I am told of</legend>
              {% for (mode, label) in modes %}
                <label class="choice">
                  <input type="radio" name="notification-mail" value={{ mailModeName mode }} checked={{ s.mail == mode }} onChange={{ const (ChooseMail mode) }}>
                  <span>{{ label }}</span>
                </label>
              {% end %}
            </fieldset>
            {% for told in maybeToList (mailNote s) %}
              <p class="account-note notification-mail-note">{{ told }}</p>
            {% end %}
            <label class="choice notification-watch-own">
              <input type="checkbox" checked={{ s.watchOwn }} disabled={{ st.busy }} onChange={{ const (SetWatchOwn (not s.watchOwn)) }}>
              <span>Watch the pages I make and the threads I comment in</span>
            </label>
            {% for e in maybeToList st.problem %}
              <p class="error" role="alert">{{ errorMessage e }}</p>
            {% end %}
            {{ feedBlock st }}
          </div>
        |]
      where
        modes :: [(MailMode, Text)]
        modes = [(MailOff, "Never"), (MailAtOnce, "At once"), (MailDaily, "Once a day, in a digest")]
        canMail s = s.verifiedEmail && s.mailing
        mailNote s
          | not s.mailing = Just "This wiki sends no mail: its administrators have not set a mail server up." :: Maybe Text
          | not s.verifiedEmail = Just "Mail goes only to a verified address: give yours under E-mail address and follow the link mailed to it."
          | otherwise = Nothing

    -- The feed's block: what a feed is, then the address with "Copy" and
    -- "Make a new address", or the one button that makes it; or why there
    -- is none.
    feedBlock :: State -> H.ComponentHTML Action Empty m
    feedBlock st =
      [hh|
        <section class="notification-feed" aria-label="Your notifications as a feed">
          <h4>Your notifications as a feed</h4>
          {{ inner }}
          {% for e in maybeToList st.feedProblem %}
            <p class="error" role="alert">{{ errorMessage e }}</p>
          {% end %}
        </section>
      |]
      where
        inner = case st.feed of
          Nothing -> [hh|<p class="loading">Loading…</p>|]
          Just (Left (Invalid why)) -> [hh|<p class="account-note notification-feed-note">{{ why }}</p>|]
          Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
          Just (Right (Feed Nothing)) ->
            [hh|
              <div class="notification-feed-make">
                <p class="account-note">An Atom feed of what you are told of here, for a feed reader: the latest fifty, each a title and a link to the page.</p>
                <button type="button" class="notification-feed-renew" disabled={{ st.busy }} onClick={{ const MakeFeed }}>Make an address</button>
              </div>
            |]
          Just (Right (Feed (Just url))) ->
            [hh|
              <div class="notification-feed-made">
                <div class="notification-feed-row">
                  <input type="text" class="notification-feed-address" readonly value={{ url }} aria-label="The feed's address" {{ HP.ref st.feedField }}>
                  <button type="button" class="notification-feed-copy" onClick={{ const CopyFeed }}>Copy</button>
                </div>
                {% if st.copied %}<p class="account-note notification-feed-copied">Copied.</p>{% end %}
                <p class="account-note">Whoever has this address reads your notifications: keep it to yourself. A new address stops the old one.</p>
                <button type="button" class="notification-feed-renew" disabled={{ st.busy }} onClick={{ const MakeFeed }}>Make a new address</button>
              </div>
            |]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> do
        settings <- lift notificationSettings
        modify (\st -> st {settings = Just settings})
        lift feedAddress >>= showFeed
      ChooseMail mail -> changing (\s -> NotificationSettingsChange {mail, watchOwn = s.watchOwn})
      SetWatchOwn watchOwn -> changing (\s -> NotificationSettingsChange {mail = s.mail, watchOwn})
      MakeFeed -> do
        modify (\st -> st {busy = True, feedProblem = Nothing, copied = False})
        result <- lift renewFeedAddress
        modify (\st -> st {busy = False})
        case result of
          Left e -> modify (\st -> st {feedProblem = Just e})
          Right made -> showFeed (Right made)
      CopyFeed ->
        gets (\st -> (st.feedField, st.feed)) >>= \case
          (field, Just (Right (Feed (Just url)))) ->
            H.getRef field
              >>= traverse_
                ( \element -> do
                    ok <- liftIO (copyText element url)
                    modify (\st -> st {copied = ok})
                )
          _ -> pass

    -- The address as the server gives it is a path under the wiki's root;
    -- a feed reader needs it whole, as this page was loaded.
    showFeed :: Either WikiError FeedAddress -> H.HalogenM State Action Empty output m ()
    showFeed = \case
      Left e -> modify (\st -> st {feed = Just (Left e)})
      Right (FeedAddress address) -> do
        url <- traverse absoluteUrl address
        modify (\st -> st {feed = Just (Right (Feed url))})

    changing :: (NotificationSettings -> NotificationSettingsChange) -> H.HalogenM State Action Empty output m ()
    changing f =
      gets (\st -> st.settings) >>= \case
        Just (Right s) -> do
          modify (\st -> st {busy = True, problem = Nothing})
          result <- lift (setNotificationSettings (f s))
          modify $ \st -> case result of
            Right new -> st {busy = False, settings = Just (Right new)}
            Left e -> st {busy = False, problem = Just e}
        _ -> pass
