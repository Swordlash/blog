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
-- Fetched when the panel opens, like the rest of the panel: the server
-- never prerenders it.
module Wiki.App.View.NotificationSettings
  ( component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..))
import Wiki.App.Backend (WikiError)
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.View.Common (errorMessage)
import Wiki.Core.Notification (MailMode (..), mailModeName)

data State = State
  { settings :: Maybe (Either WikiError NotificationSettings)
  , problem :: Maybe WikiError
  , busy :: Bool
  }

data Action = Initialize | ChooseMail MailMode | SetWatchOwn Bool

component :: forall query input output m. (MonadNotifications m) => H.Component query input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \_ -> pure State {settings = Nothing, problem = Nothing, busy = False}
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

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> do
        settings <- lift notificationSettings
        modify (\st -> st {settings = Just settings})
      ChooseMail mail -> changing (\s -> NotificationSettingsChange {mail, watchOwn = s.watchOwn})
      SetWatchOwn watchOwn -> changing (\s -> NotificationSettingsChange {mail = s.mail, watchOwn})

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
