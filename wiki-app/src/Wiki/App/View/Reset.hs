{-# LANGUAGE QuasiQuotes #-}

-- | A password reset's page (@\/reset-password\/\<secret>\/@, WP4.11 of
-- docs/PLAN.md): the link mailed to someone who asked for one, with a form
-- for a new password, typed twice. Setting it ends every session the user
-- had and signs nobody in, so that a second factor, if they have one, is
-- still asked for; the page then offers to sign in ('SignInWanted').
--
-- Nothing is fetched before the form is sent: the link's secret is checked
-- when the password is set, and a link that was used or has expired is
-- reported then. So the page the server prerenders is the form itself, as
-- the program renders it. Someone signed in is told to sign out first,
-- since the reset would sign them out without warning. A wiki that signs
-- nobody in (the demo) says that it has no passwords to reset. The inputs
-- are uncontrolled, like the sign-in form's ("Wiki.App.View.SignIn").
module Wiki.App.View.Reset
  ( Input (..)
  , Output (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Security (ResetToken)
import Wiki.App.Account (Accounts (..))
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.View.Common (errorMessage)
import Wiki.Core.User (Password (..), User (..), minimumPasswordLength)

data Input m = Input
  { accounts :: Maybe (Accounts m)
  -- ^ Signing in and out, on a backend where people do.
  , token :: ResetToken
  , session :: Session
  }

-- | The password is set: open the sign-in form.
data Output = SignInWanted

data State m = State
  { input :: Input m
  , typedPassword :: Text
  , typedRepeat :: Text
  , problem :: Maybe Text
  , busy :: Bool
  , done :: Bool
  }

data Action
  = Receive Session
  | TypedPassword Text
  | TypedRepeat Text
  | Submit
  | SignIn

component :: forall query m. (Typeable m, Monad m) => H.Component query (Input m) Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, typedPassword = "", typedRepeat = "", problem = Nothing, busy = False, done = False}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.receive = \input -> Just (Receive input.session)
              }
      }
  where
    render :: State m -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="password-reset">
          <h1>A new password</h1>
          {{ body }}
        </section>
      |]
      where
        body = case (st.input.accounts, st.input.session.user) of
          (Nothing, _) ->
            [hh|<p class="reset-unusable">Passwords are reset on a wiki a server keeps, and this demo has none: choose who you are at the top right instead.</p>|]
          (_, Just u) ->
            [hh|<p class="reset-unusable">You are signed in as {{ u.displayName }}. Sign out first to set a new password with this link.</p>|]
          _
            | st.done ->
                [hh|
                  <div class="reset-done">
                    <p role="status">Your password is set, and you are signed out everywhere you were signed in. Sign in with your new password.</p>
                    <div class="actions">
                      <button type="button" class="primary reset-sign-in" onClick={{ const SignIn }}>Sign in</button>
                    </div>
                  </div>
                |]
            | otherwise ->
                [hh|
                  <form class="reset-form" aria-label="Choose a new password" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
                    <p>Choose a new password for your account. Setting it signs you out everywhere you are signed in.</p>
                    <label class="field">
                      <span>New password</span>
                      <input type="password" name="new" autocomplete="new-password" required minlength={{ minimumPasswordLength }} onValueInput={{ TypedPassword }}>
                    </label>
                    <label class="field">
                      <span>New password again</span>
                      <input type="password" name="repeat" autocomplete="new-password" required onValueInput={{ TypedRepeat }}>
                    </label>
                    <div class="reset-told">
                      {% for p in maybeToList st.problem %}
                        <p class="error reset-error" role="alert">{{ p }}</p>
                      {% end %}
                    </div>
                    <div class="actions">
                      <button type="submit" class="primary" disabled={{ st.busy }}>Set password</button>
                    </div>
                  </form>
                |]

    handleAction :: Action -> H.HalogenM (State m) Action Empty Output m ()
    handleAction = \case
      Receive session -> modify (\st -> st {input = st.input {session}})
      TypedPassword t -> modify (\st -> st {typedPassword = t})
      TypedRepeat t -> modify (\st -> st {typedRepeat = t})
      SignIn -> H.raise SignInWanted
      Submit -> do
        st <- get
        for_ st.input.accounts $ \a -> case () of
          _
            | st.busy -> pass
            | st.typedPassword /= st.typedRepeat ->
                modify (\s -> s {problem = Just "The new password and its repetition are not the same."})
            | otherwise -> do
                modify (\s -> s {busy = True, problem = Nothing})
                lift (a.resetPassword st.input.token (Password st.typedPassword)) >>= \case
                  Right () -> modify (\s -> s {busy = False, done = True, typedPassword = "", typedRepeat = ""})
                  Left NotFound ->
                    modify (\s -> s {busy = False, problem = Just "This link no longer works: it has been used, or it has expired. Ask for a new one with \"Forgot your password?\" under the sign-in form."})
                  Left e -> modify (\s -> s {busy = False, problem = Just (errorMessage e)})
