{-# LANGUAGE QuasiQuotes #-}

-- | The page of the link a notification's mail carries
-- (@\/unsubscribe\/\<secret>\/@, WP4.13 of docs/PLAN.md): a button that
-- turns the user's notification mail off. A button rather than doing it on
-- arrival, so that a mail program that fetches links to look at them turns
-- nothing off, and so that the page the server renders is the program's
-- first render.
--
-- It needs nobody signed in, in a closed wiki too: the link's secret names
-- the user and does that one thing. One that names nobody says so; the
-- demo, which sends no mail, says that too.
module Wiki.App.View.Unsubscribe
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Security (MailToken)
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.View.Common (errorMessage)

newtype Input = Input {token :: MailToken}

data Outcome
  = Waiting
  | Done
  | Failed Text

data State = State
  { input :: Input
  , outcome :: Outcome
  , busy :: Bool
  }

data Action = Confirm

component :: forall query output m. (MonadNotifications m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, outcome = Waiting, busy = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="unsubscribe">
          <h1>Notification mail</h1>
          {{ body }}
        </section>
      |]
      where
        body = case st.outcome of
          Done -> [hh|<p class="unsubscribe-done" role="status">Done: you are mailed no notifications from now on. You still see them under the bell when you sign in, and can choose to be mailed again in your account's settings.</p>|]
          outcome ->
            [hh|
              <div class="unsubscribe-form">
                <p>Stop mailing me what I am told of in this wiki: mentions, comments and changes of the pages I watch.</p>
                {% for why in failure outcome %}
                  <p class="error unsubscribe-error" role="alert">{{ why }}</p>
                {% end %}
                <div class="actions">
                  <button type="button" class="primary unsubscribe-confirm" disabled={{ st.busy }} onClick={{ const Confirm }}>Stop the mail</button>
                </div>
              </div>
            |]
        failure = \case
          Failed why -> [why]
          _ -> []

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction Confirm = do
      st <- get
      unless st.busy $ do
        modify (\s -> s {busy = True})
        result <- lift (unsubscribe st.input.token)
        modify $ \s ->
          s
            { busy = False
            , outcome = case result of
                Right () -> Done
                Left NotFound -> Failed "This link does not name anyone: copy the whole of it from the mail, or choose how you are mailed in your account's settings."
                Left e -> Failed (errorMessage e)
            }
