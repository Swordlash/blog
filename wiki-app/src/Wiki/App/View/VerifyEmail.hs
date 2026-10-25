{-# LANGUAGE QuasiQuotes #-}

-- | The page of a link mailed to verify an e-mail address
-- (@\/verify-email\/\<secret>\/@, WP4.11 of docs/PLAN.md): a button that
-- confirms the address is the user's, so that it may receive a password
-- reset. A button rather than a confirmation on arrival, so that a mail
-- program that fetches links to look at them confirms nothing, and so that
-- the page the server renders is the program's first render.
--
-- It needs nobody signed in: the link's secret is the proof. A link that
-- has been used, has expired, or whose address is no longer the user's says
-- so; the demo, which sends no mail, says that it verifies nothing.
module Wiki.App.View.VerifyEmail
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Security (MailToken)
import Wiki.App.Account (Accounts (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.View.Common (errorMessage)

data Input m = Input
  { accounts :: Maybe (Accounts m)
  , token :: MailToken
  }

data Outcome
  = Waiting
  | Verified
  | Failed Text

data State m = State
  { input :: Input m
  , outcome :: Outcome
  , busy :: Bool
  }

data Action = Confirm

component :: forall query output m. (Monad m) => H.Component query (Input m) output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, outcome = Waiting, busy = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction}
      }
  where
    render :: State m -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="email-verification">
          <h1>Your e-mail address</h1>
          {{ body }}
        </section>
      |]
      where
        body = case (st.input.accounts, st.outcome) of
          (Nothing, _) -> [hh|<p class="verify-unusable">This demo sends no mail, and so verifies no address.</p>|]
          (_, Verified) -> [hh|<p class="verify-done" role="status">Your e-mail address is verified: a password reset can be mailed to it now.</p>|]
          (_, outcome) ->
            [hh|
              <div class="verify-form">
                <p>Confirm that this address is yours, so that a password reset can be mailed to it.</p>
                {% for why in failure outcome %}
                  <p class="error verify-error" role="alert">{{ why }}</p>
                {% end %}
                <div class="actions">
                  <button type="button" class="primary verify-confirm" disabled={{ st.busy }} onClick={{ const Confirm }}>Confirm my address</button>
                </div>
              </div>
            |]
        failure = \case
          Failed why -> [why]
          _ -> []

    handleAction :: Action -> H.HalogenM (State m) Action Empty output m ()
    handleAction Confirm = do
      st <- get
      for_ st.input.accounts $ \a -> unless st.busy $ do
        modify (\s -> s {busy = True})
        result <- lift (a.verifyEmail st.input.token)
        modify $ \s ->
          s
            { busy = False
            , outcome = case result of
                Right () -> Verified
                Left NotFound -> Failed "This link no longer works: it has been used, it has expired, or the address is no longer your account's. Give your address again in your account's panel for a new one."
                Left e -> Failed (errorMessage e)
            }
