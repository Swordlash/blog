{-# LANGUAGE QuasiQuotes #-}

-- | An invitation's page (@\/invite\/\<secret>\/@, WP3.5 of docs/PLAN.md):
-- who the invitation is for, and the form that creates the account, with
-- the login, display name and password the invited person chooses.
-- Creating it signs them in ('Accepted'), and the shell shows them the
-- wiki. Where the server offers sign-in with providers (WP3.6 of
-- docs/PLAN.md), the account may be created with one instead, through a
-- link to the server's round trip that carries the invitation
-- ("Wiki.Api.Auth"); the user then signs in with that provider.
--
-- An invitation that cannot be used (used already, revoked, expired) says
-- so. So does the page shown to someone signed in, who already has an
-- account. A wiki that signs nobody in (the demo, which has no such
-- accounts) says that it accepts no invitations.
--
-- The invitation is fetched as the shell loads a route's data: in the
-- initial state where the backend answers at once (the server's
-- prerender, whose response the page carries), otherwise in the
-- initializer. The inputs are uncontrolled, like the sign-in form's
-- ("Wiki.App.View.SignIn").
module Wiki.App.View.Invite
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
import Wiki.Api.Account (InvitationInfo (..), InvitationToken, NewAccount (..))
import Wiki.Api.Auth (Purpose (..), startUrl)
import Wiki.App.Account (Accounts (..), accountErrorText)
import Wiki.App.Backend (MonadLoad (..), Session (..), WikiError (..))
import Wiki.App.View.Common (failureView)
import Wiki.Core.User (Email (..), Password (..), SignInProvider (..), User (..), minimumPasswordLength)

data Input m = Input
  { accounts :: Maybe (Accounts m)
  -- ^ Signing in and creating accounts, on a backend where people do.
  , token :: InvitationToken
  , session :: Session
  , home :: Text
  -- ^ The address of the wiki's home page, where creating the account
  -- with a provider returns to.
  }

-- | The account was created, and this is the new user's session.
newtype Output = Accepted Session

data Loaded
  = Loading
  | Failed WikiError
  | Ready InvitationInfo

data State m = State
  { input :: Input m
  , loaded :: Loaded
  , typedLogin :: Text
  , typedName :: Text
  , typedPassword :: Text
  , problem :: Maybe Text
  , busy :: Bool
  }

data Action
  = Initialize
  | Receive Session
  | Retry
  | TypedLogin Text
  | TypedName Text
  | TypedPassword Text
  | Submit

component :: forall query m. (Typeable m, MonadLoad m) => H.Component query (Input m) Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- case input.accounts of
            Nothing -> pure Loading
            Just a -> maybe Loading (either Failed Ready) <$> atOnce (a.invitationFor input.token)
          pure State {input, loaded, typedLogin = "", typedName = "", typedPassword = "", problem = Nothing, busy = False}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = \input -> Just (Receive input.session)
              }
      }
  where
    render :: State m -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="invitation">
          <h1>An invitation</h1>
          {{ body }}
        </section>
      |]
      where
        body = case (st.input.accounts, st.input.session.user, st.loaded) of
          (Nothing, _, _) ->
            [hh|<p class="invitation-unusable">Invitations make accounts on a wiki a server keeps, and this demo has none: choose who you are at the top right instead.</p>|]
          (_, Just u, _) ->
            [hh|<p class="invitation-unusable">You are signed in as {{ u.displayName }}, and so have an account already. Sign out to use this invitation for another.</p>|]
          (_, _, Loading) -> [hh|<p class="loading">Loading…</p>|]
          (_, _, Failed NotFound) ->
            [hh|<p class="invitation-unusable" role="alert">This invitation cannot be used: it has been used already, it has been revoked, or it has expired. Ask whoever invited you for a new one.</p>|]
          (_, _, Failed e) -> failureView e Retry
          (_, _, Ready info) -> form info

        form :: InvitationInfo -> H.ComponentHTML Action Empty m
        form info =
          [hh|
            <form class="invitation-form" aria-label="Create your account" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
              <p>You are invited to this wiki as <strong>{{ info.email.text }}</strong>. Choose how you will sign in.</p>
              <label class="field">
                <span>Login</span>
                <input type="text" name="login" autocomplete="username" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedLogin }}>
              </label>
              <label class="field">
                <span>Display name</span>
                <input type="text" name="name" autocomplete="name" placeholder="As your pages will show you; your login if blank" onValueInput={{ TypedName }}>
              </label>
              <label class="field">
                <span>Password</span>
                <input type="password" name="password" autocomplete="new-password" required minlength={{ minimumPasswordLength }} onValueInput={{ TypedPassword }}>
              </label>
              <div class="invitation-told">
                {% for p in maybeToList st.problem %}
                  <p class="error invitation-error" role="alert">{{ p }}</p>
                {% end %}
              </div>
              <div class="actions">
                <button type="submit" class="primary" disabled={{ st.busy }}>Create my account</button>
              </div>
              {% if not (null st.input.session.providers) %}
                <div class="sign-in-providers">
                  <p>Or sign in with an account you have elsewhere:</p>
                  {% for p in st.input.session.providers %}
                    <a class="provider-link" href={{ startUrl p.name (AcceptInvitation st.input.token) st.input.home }}>{{ "Create my account with " <> p.label }}</a>
                  {% end %}
                </div>
              {% end %}
            </form>
          |]

    handleAction :: Action -> H.HalogenM (State m) Action Empty Output m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive session -> modify (\st -> st {input = st.input {session}})
      TypedLogin t -> modify (\st -> st {typedLogin = t})
      TypedName t -> modify (\st -> st {typedName = t})
      TypedPassword t -> modify (\st -> st {typedPassword = t})
      Submit -> do
        st <- get
        for_ st.input.accounts $ \a -> unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          lift (a.acceptInvitation st.input.token NewAccount {login = st.typedLogin, displayName = st.typedName, password = Password st.typedPassword, email = Nothing}) >>= \case
            Left e -> modify (\s -> s {busy = False, problem = Just (accountErrorText e)})
            Right s -> do
              modify (\x -> x {busy = False, typedPassword = ""})
              H.raise (Accepted s)

    load :: H.HalogenM (State m) Action Empty Output m ()
    load =
      gets (\st -> st.input) >>= \input -> for_ input.accounts $ \a -> do
        result <- lift (a.invitationFor input.token)
        modify (\st -> st {loaded = either Failed Ready result})
