{-# LANGUAGE QuasiQuotes #-}

-- | The sign-in control in the header of a wiki on a server: who is
-- signed in, and the way to sign in and out ("Wiki.App.Account"). Someone
-- not signed in sees "Sign in", which opens a small form under it (login,
-- password, and why the last attempt failed). Someone signed in sees their
-- name and "Sign out". The server's operator, who is the administrator
-- without signing in, sees only the name.
--
-- In an open wiki ("Wiki.Core.Access") there is "Create account" beside
-- "Sign in", which opens its own form (login, display name, password) and
-- signs the new user in as the account it creates (WP3.5 of docs/PLAN.md).
-- A closed wiki accepts accounts by invitation only, and has no such
-- button.
--
-- Where the server offers sign-in with providers (OpenID Connect, WP3.6 of
-- docs/PLAN.md: Google, GitHub and the others the session names), both
-- forms offer them too, as links. Signing in with one is a round trip
-- through the provider's pages, driven by the server ("Wiki.Api.Auth"),
-- which ends back at this page's address, signed in.
--
-- A signed-in user's name is a button, whatever the server signs in with,
-- which opens their sign-in methods. It shows their password, if any, with
-- a form to change it (or to set one, for a user who has none and whose
-- providers are gone: WP3.7 of docs/PLAN.md); the form asks for the
-- current password, the new one, and the new one again. A user who has no
-- password and signs in with one of the server's providers has none to set
-- and gets no form (WP5.6, 'passwordOffer'). It also shows the provider
-- accounts they sign in with, each of which they may disconnect unless it
-- is their last way to sign in, and a link to connect each provider they
-- have no account with yet. The server's operator has no account, and no
-- such button.
--
-- A user with a second factor (WP4.11 of docs/PLAN.md) is asked for its
-- code after their password, in the same form, which then has only the
-- code's field; a sign-in left waiting too long starts over at the
-- password. Under the sign-in form, "Forgot your password?" opens a form
-- that requests a reset by mail with a login or an e-mail address; the
-- answer is the same whether or not that matches anyone. The account panel
-- ends with the account's security ("Wiki.App.View.Security": sessions,
-- the second factor, the e-mail address).
--
-- Signing in or out tells the shell the new session ('AccountChanged'),
-- which reloads everything as that user. The shell can also open the form
-- with a message of its own ('Prompt'), when a session has ended by
-- itself.
--
-- The second factor's form and the reset form each sit in their own
-- container, which is always there, so that neither takes the place of
-- the sign-in form. Otherwise the sign-in form's login field (with what
-- was typed in it) would become their first field.
--
-- The inputs are uncontrolled (the component never writes their value),
-- so that a render arriving while someone types never loses a key; the
-- state records what is typed as it is typed. Messages in the form (the
-- shell's message, why an attempt failed) appear and disappear inside
-- containers that are always there, so that the inputs keep their
-- positions among the form's children and are never recreated, which
-- would lose what was typed in them.
module Wiki.App.View.SignIn
  ( Input (..)
  , Query (..)
  , Output (..)
  , component
  , passwordOffer
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.+), type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow, Router)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Account (LinkedIdentity (..), NewAccount (..), PasswordChange (..), SignInMethods (..), mayDisconnect, providerOnly)
import Wiki.Api.Auth (Purpose (..), startUrl)
import Wiki.Api.Security (resetLifetime)
import Wiki.App.Account (Accounts (..), SignInError (..), accountErrorText, codeErrorText, passwordErrorText, signInErrorText)
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.Route (Route (AssistantSettings))
import Wiki.App.Security (MonadSecurity)
import Wiki.App.View.Common (ariaBool, errorMessage)
import Wiki.App.View.NotificationSettings qualified as NotificationSettingsView
import Wiki.App.View.Security qualified as SecurityView
import Wiki.Core.Access (takesNewAccounts)
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (Email (..), Password (..), SignInProvider (..), Standing (..), User (..), minimumPasswordLength)

data Input m = Input
  { accounts :: Accounts m
  , session :: Session
  , here :: Text
  -- ^ The page's address, as the router writes it: where signing in with
  -- a provider returns to.
  , router :: Router Route
  -- ^ For the link to the writing assistant's settings.
  }

-- | Open the form, with the reason.
data Query a = Prompt Text a

-- | Someone signed in or out: the new session.
newtype Output = AccountChanged Session

-- | Which step of signing in the form is at.
data Step
  = -- | The login and the password.
    AtPassword
  | -- | The second factor's code, after a correct password.
    AtCode
  | -- | Requesting a password reset by mail.
    AtReset
  deriving stock (Eq)

type Slots = ("security" .== H.Slot (Const Void) Void ()) .+ ("notifications" .== H.Slot (Const Void) Void ())

data State m = State
  { input :: Input m
  , open :: Bool
  , step :: Step
  , typedCode :: Text
  , codeField :: H.RefLabel
  , resetField :: H.RefLabel
  , resetTold :: Maybe Text
  -- ^ Whether a reset was requested.
  , typedLogin :: Text
  , typedPassword :: Text
  , notice :: Maybe Text
  -- ^ Why the form was opened, if the shell gave a reason.
  , problem :: Maybe Text
  -- ^ Why the last attempt failed.
  , busy :: Bool
  , loginField :: H.RefLabel
  , registering :: Bool
  -- ^ Whether the form to create an account is open (and the sign-in form
  -- closed: only one at a time).
  , typedName :: Text
  , registerField :: H.RefLabel
  , accountOpen :: Bool
  -- ^ Whether the panel of the user's sign-in methods is open.
  , methods :: Maybe (Either WikiError SignInMethods)
  -- ^ The user's sign-in methods, once fetched ('Nothing' while they are
  -- being fetched).
  , changingPassword :: Bool
  -- ^ Whether the form to change their password is open.
  , typedCurrent :: Text
  , typedNew :: Text
  , typedRepeat :: Text
  , passwordProblem :: Maybe Text
  -- ^ Why the last change of password failed.
  , passwordTold :: Maybe Text
  -- ^ Whether the last change was made.
  , currentField :: H.RefLabel
  , newField :: H.RefLabel
  }

data Action
  = Receive Session Text
  | Toggle
  | Close
  | TypedLogin Text
  | TypedPassword Text
  | Submit
  | TypedCode Text
  | SubmitCode
  | ForgotPassword
  | SubmitReset
  | BackToPassword
  | SignOut
  | ToggleRegister
  | TypedName Text
  | Register
  | ToggleAccount
  | Disconnect Text
  | AskPassword
  | CancelPassword
  | TypedCurrent Text
  | TypedNew Text
  | TypedRepeat Text
  | SavePassword
  | Followed (Follow Route)

component :: forall m. (Typeable m, MonadUUID m, MonadIO m, MonadSecurity m, MonadNotifications m) => H.Component Query (Input m) Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loginField <- H.newRefLabel "sign-in-login"
          registerField <- H.newRefLabel "register-login"
          currentField <- H.newRefLabel "password-current"
          newField <- H.newRefLabel "password-new"
          codeField <- H.newRefLabel "sign-in-code"
          resetField <- H.newRefLabel "reset-login"
          pure
            State
              { input
              , open = False
              , step = AtPassword
              , typedCode = ""
              , codeField
              , resetField
              , resetTold = Nothing
              , typedLogin = ""
              , typedPassword = ""
              , notice = Nothing
              , problem = Nothing
              , busy = False
              , loginField
              , registering = False
              , typedName = ""
              , registerField
              , accountOpen = False
              , methods = Nothing
              , changingPassword = False
              , typedCurrent = ""
              , typedNew = ""
              , typedRepeat = ""
              , passwordProblem = Nothing
              , passwordTold = Nothing
              , currentField
              , newField
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.receive = \input -> Just (receive input)
              }
      }
  where
    -- The input changes when the shell's session does; the form stays as
    -- it is.
    receive :: Input m -> Action
    receive input = Receive input.session input.here

    render :: State m -> H.ComponentHTML Action Slots m
    render st = case st.input.session of
      Session {user = Just u, standing = SignedIn} ->
        [hh|
          <div class="account">
            <button type="button" class="user-name account-toggle" aria-expanded={{ ariaBool st.accountOpen }} onClick={{ const ToggleAccount }}>{{ u.displayName }}</button>
            <button type="button" class="sign-out" disabled={{ st.busy }} onClick={{ const SignOut }}>Sign out</button>
            {% if st.accountOpen %}
              {{ accountPanel st }}
            {% end %}
          </div>
        |]
      Session {user = Just u} -> [hh|<span class="user-name">{{ u.displayName }}</span>|]
      Session {user = Nothing} ->
        [hh|
          <div class="account">
            <button type="button" class="sign-in-toggle" aria-expanded={{ ariaBool st.open }} onClick={{ const Toggle }}>Sign in</button>
            {% if takesNewAccounts st.input.session.grants.access %}
              <button type="button" class="register-toggle" aria-expanded={{ ariaBool st.registering }} onClick={{ const ToggleRegister }}>Create account</button>
            {% end %}
            {% if st.registering %}
              {{ registerForm st }}
            {% end %}
            <div class="sign-in-step">
              {% if st.open && st.step == AtCode %}
                {{ codeForm st }}
              {% end %}
            </div>
            <div class="sign-in-step">
              {% if st.open && st.step == AtReset %}
                {{ resetForm st }}
              {% end %}
            </div>
            {% if st.open && st.step == AtPassword %}
              <form class="sign-in-form" aria-label="Sign in" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
                <div class="sign-in-told">
                  {% for n in maybeToList st.notice %}
                    <p class="sign-in-notice" role="status">{{ n }}</p>
                  {% end %}
                </div>
                <label class="field">
                  <span>Login</span>
                  <input type="text" name="login" autocomplete="username" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedLogin }} {{ HP.ref st.loginField }}>
                </label>
                <label class="field">
                  <span>Password</span>
                  <input type="password" name="password" autocomplete="current-password" required onValueInput={{ TypedPassword }}>
                </label>
                <div class="sign-in-told">
                  {% for p in maybeToList st.problem %}
                    <p class="error sign-in-error" role="alert">{{ p }}</p>
                  {% end %}
                </div>
                <div class="actions">
                  <button type="submit" class="primary" disabled={{ st.busy }}>Sign in</button>
                  <button type="button" onClick={{ const Close }}>Cancel</button>
                </div>
                <button type="button" class="link-button forgot-password" onClick={{ const ForgotPassword }}>Forgot your password?</button>
                {{ providerLinks st "Sign in with " }}
              </form>
            {% end %}
          </div>
        |]

    -- The second factor's code, once the password was right.
    codeForm :: State m -> H.ComponentHTML Action Slots m
    codeForm st =
      [hh|
        <form class="sign-in-code-form" aria-label="Second factor" {{ HE.preventingDefault (HE.onSubmit (const SubmitCode)) }}>
          <p class="sign-in-notice" role="status">Your account has a second factor: type the code your authenticator application shows, or one of your recovery codes.</p>
          <label class="field">
            <span>Code</span>
            <input type="text" name="code" autocomplete="one-time-code" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedCode }} {{ HP.ref st.codeField }}>
          </label>
          <div class="sign-in-told">
            {% for p in maybeToList st.problem %}
              <p class="error sign-in-error" role="alert">{{ p }}</p>
            {% end %}
          </div>
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Sign in</button>
            <button type="button" onClick={{ const Close }}>Cancel</button>
          </div>
        </form>
      |]

    -- A password reset by mail, requested with a login or an address.
    resetForm :: State m -> H.ComponentHTML Action Slots m
    resetForm st =
      [hh|
        <form class="reset-request-form" aria-label="Forgot your password?" {{ HE.preventingDefault (HE.onSubmit (const SubmitReset)) }}>
          <p>Give your login or your e-mail address. If your account has a verified address, a link to choose a new password is mailed there; it works once, for {{ show (round (resetLifetime / 60) :: Int) <> " minutes" :: Text }}.</p>
          <label class="field">
            <span>Login or e-mail address</span>
            <input type="text" name="login" autocomplete="username" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedLogin }} {{ HP.ref st.resetField }}>
          </label>
          <div class="sign-in-told">
            {% for t in maybeToList st.resetTold %}
              <p class="reset-told" role="status">{{ t }}</p>
            {% end %}
            {% for p in maybeToList st.problem %}
              <p class="error reset-request-error" role="alert">{{ p }}</p>
            {% end %}
          </div>
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Mail me a link</button>
            <button type="button" onClick={{ const BackToPassword }}>Back to sign in</button>
          </div>
        </form>
      |]

    -- Creating one's own account, in an open wiki: like the sign-in form,
    -- with a display name, and a new password.
    registerForm :: State m -> H.ComponentHTML Action Slots m
    registerForm st =
      [hh|
        <form class="register-form" aria-label="Create account" {{ HE.preventingDefault (HE.onSubmit (const Register)) }}>
          <label class="field">
            <span>Login</span>
            <input type="text" name="login" autocomplete="username" autocapitalize="none" spellcheck="false" required onValueInput={{ TypedLogin }} {{ HP.ref st.registerField }}>
          </label>
          <label class="field">
            <span>Display name</span>
            <input type="text" name="name" autocomplete="name" placeholder="Your login if blank" onValueInput={{ TypedName }}>
          </label>
          <label class="field">
            <span>Password</span>
            <input type="password" name="password" autocomplete="new-password" required minlength={{ minimumPasswordLength }} onValueInput={{ TypedPassword }}>
          </label>
          <div class="sign-in-told">
            {% for p in maybeToList st.problem %}
              <p class="error register-error" role="alert">{{ p }}</p>
            {% end %}
          </div>
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>Create account</button>
            <button type="button" onClick={{ const Close }}>Cancel</button>
          </div>
          {{ providerLinks st "Create account with " }}
        </form>
      |]

    -- The providers to sign in with, if the server has any: links to the
    -- server's round trip, which returns here.
    providerLinks :: State m -> Text -> H.ComponentHTML Action Slots m
    providerLinks st verb =
      [hh|
        <div class="sign-in-providers">
          {% for p in st.input.session.providers %}
            <a class="provider-link" href={{ startUrl p.name SignInWith st.input.here }}>{{ verb <> p.label }}</a>
          {% end %}
        </div>
      |]

    -- The signed-in user's sign-in methods, and the ways to change them.
    accountPanel :: State m -> H.ComponentHTML Action Slots m
    accountPanel st =
      [hh|
        <section class="account-panel" aria-label="How you sign in">
          <h2>How you sign in</h2>
          {{ body }}
          {{ HH.slot_ "security" () SecurityView.component () }}
          <section class="account-notifications" aria-label="Notifications">
            <h3>Notifications</h3>
            {{ HH.slot_ "notifications" () NotificationSettingsView.component () }}
          </section>
          <section class="account-assistant" aria-label="Writing assistant">
            <h3>Writing assistant</h3>
            <p class="account-note">Your own API keys for the editor's assistant, kept in this browser.</p>
            <a class="assistant-settings-entry" {{ Router.linkProps st.input.router Followed AssistantSettings }}>Assistant</a>
          </section>
        </section>
      |]
      where
        providers = st.input.session.providers
        labelOf name = maybe name (\p -> p.label) (find (\p -> p.name == name) providers)
        body = case st.methods of
          Nothing -> [hh|<p class="loading">Loading…</p>|]
          Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
          Just (Right m) ->
            [hh|
              <div class="account-methods">
                <p class="account-password">{{ if m.password then "With your password" else "No password: you sign in with the accounts below." :: Text }}</p>
                {% if st.changingPassword %}
                  {{ passwordForm st m }}
                {% else %}
                  {% for offered in maybeToList (passwordOffer providers m) %}
                    <button type="button" class="password-change-toggle" disabled={{ st.busy }} onClick={{ const AskPassword }}>
                      {{ offered }}
                    </button>
                  {% end %}
                {% end %}
                <div class="sign-in-told">
                  {% for t in maybeToList st.passwordTold %}
                    <p class="account-told" role="status">{{ t }}</p>
                  {% end %}
                </div>
                <ul class="identities">
                  {% for i in m.identities %}
                    <li class="identity">
                      <span class="identity-provider">{{ labelOf i.provider }}</span>
                      {% for e in maybeToList i.email %}
                        <span class="identity-email">{{ e.text }}</span>
                      {% end %}
                      <button
                        type="button"
                        class="identity-disconnect"
                        disabled={{ st.busy || not (mayDisconnect i.provider m) }}
                        title={{ if mayDisconnect i.provider m then "" else "Your only way to sign in" :: Text }}
                        onClick={{ const (Disconnect i.provider) }}
                      >
                        Disconnect
                      </button>
                    </li>
                  {% end %}
                </ul>
                <div class="identity-connects">
                  {% for p in filter (\p -> p.name `notElem` map (\i -> i.provider) m.identities) providers %}
                    <a class="identity-connect" href={{ startUrl p.name Connect st.input.here }}>{{ "Connect " <> p.label }}</a>
                  {% end %}
                </div>
                <div class="sign-in-told">
                  {% for p in maybeToList st.problem %}
                    <p class="error account-error" role="alert">{{ p }}</p>
                  {% end %}
                </div>
              </div>
            |]

    -- A new password, typed twice, and the current one where there is
    -- one. The inputs are removed with the form when it closes, together
    -- with what was typed in them.
    passwordForm :: State m -> SignInMethods -> H.ComponentHTML Action Slots m
    passwordForm st m =
      [hh|
        <form class="password-change" aria-label={{ verb }} {{ HE.preventingDefault (HE.onSubmit (const SavePassword)) }}>
          {% if m.password %}
            <label class="field">
              <span>Current password</span>
              <input type="password" name="current" autocomplete="current-password" required onValueInput={{ TypedCurrent }} {{ HP.ref st.currentField }}>
            </label>
          {% end %}
          <label class="field">
            <span>New password</span>
            <input type="password" name="new" autocomplete="new-password" required minlength={{ minimumPasswordLength }} onValueInput={{ TypedNew }} {{ HP.ref st.newField }}>
          </label>
          <label class="field">
            <span>New password again</span>
            <input type="password" name="repeat" autocomplete="new-password" required onValueInput={{ TypedRepeat }}>
          </label>
          <div class="sign-in-told">
            {% for p in maybeToList st.passwordProblem %}
              <p class="error password-error" role="alert">{{ p }}</p>
            {% end %}
          </div>
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.busy }}>{{ verb }}</button>
            <button type="button" onClick={{ const CancelPassword }}>Cancel</button>
          </div>
        </form>
      |]
      where
        verb :: Text
        verb = if m.password then "Change password" else "Set password"

    handleAction :: Action -> H.HalogenM (State m) Action Slots Output m ()
    handleAction = \case
      Receive session here -> modify (\st -> st {input = Input {accounts = st.input.accounts, session, here, router = st.input.router}})
      Followed f -> do
        modify (\st -> st {accountOpen = False})
        gets (\st -> st.input.router) >>= (`Router.follow` f)
      Toggle ->
        gets (\st -> st.open) >>= \case
          True -> close
          False -> openForm Nothing
      Close -> close
      TypedLogin typedLogin -> modify (\st -> st {typedLogin})
      TypedPassword typedPassword -> modify (\st -> st {typedPassword})
      Submit -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          result <- lift (st.input.accounts.signIn st.typedLogin (Password st.typedPassword))
          case result of
            Left SecondFactorNeeded -> do
              modify (\s -> s {busy = False, step = AtCode, typedPassword = "", typedCode = "", notice = Nothing, problem = Nothing})
              gets (\s -> s.codeField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
            Left e -> modify (\s -> s {busy = False, problem = Just (signInErrorText e)})
            Right s -> do
              modify (\x -> x {busy = False, open = False, typedPassword = "", notice = Nothing, problem = Nothing})
              H.raise (AccountChanged s)
      TypedCode typedCode -> modify (\st -> st {typedCode})
      SubmitCode -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          lift (st.input.accounts.confirmSecondFactor st.typedCode) >>= \case
            -- Waited too long, or too many wrong codes: back to the
            -- password.
            Left (SignInFailed (Invalid why)) -> modify (\s -> s {busy = False, step = AtPassword, typedCode = "", problem = Just why})
            Left e -> modify (\s -> s {busy = False, problem = Just (codeErrorText e)})
            Right s -> do
              modify (\x -> x {busy = False, open = False, step = AtPassword, typedCode = "", notice = Nothing, problem = Nothing})
              H.raise (AccountChanged s)
      ForgotPassword -> do
        modify (\st -> st {step = AtReset, typedLogin = "", typedPassword = "", notice = Nothing, problem = Nothing, resetTold = Nothing})
        gets (\st -> st.resetField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      BackToPassword -> do
        modify (\st -> st {step = AtPassword, typedLogin = "", problem = Nothing, resetTold = Nothing})
        gets (\st -> st.loginField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      SubmitReset -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing, resetTold = Nothing})
          lift (st.input.accounts.requestPasswordReset st.typedLogin) >>= \case
            Left e -> modify (\s -> s {busy = False, problem = Just (signInErrorText e)})
            Right () ->
              modify $ \s ->
                s
                  { busy = False
                  , resetTold = Just "If that is the login or the verified address of an account, a link to choose a new password has been mailed to its address. Look in your mail, and in its spam folder too."
                  }
      ToggleRegister ->
        gets (\st -> st.registering) >>= \case
          True -> close
          False -> do
            -- The other form's inputs are removed, together with what was
            -- typed in them.
            modify (\st -> st {registering = True, open = False, notice = Nothing, problem = Nothing, typedLogin = "", typedName = "", typedPassword = ""})
            gets (\st -> st.registerField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      TypedName typedName -> modify (\st -> st {typedName})
      Register -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          result <- lift (st.input.accounts.register NewAccount {login = st.typedLogin, displayName = st.typedName, password = Password st.typedPassword, email = Nothing})
          case result of
            Left e -> modify (\s -> s {busy = False, problem = Just (accountErrorText e)})
            Right s -> do
              modify (\x -> x {busy = False, registering = False, typedPassword = "", typedName = "", problem = Nothing})
              H.raise (AccountChanged s)
      ToggleAccount ->
        gets (\st -> st.accountOpen) >>= \case
          True -> modify (\st -> (forgetPassword st) {accountOpen = False, problem = Nothing, passwordTold = Nothing})
          False -> do
            modify (\st -> (forgetPassword st) {accountOpen = True, methods = Nothing, problem = Nothing, passwordTold = Nothing})
            st <- get
            result <- lift st.input.accounts.identities
            modify (\x -> x {methods = Just result})
      Disconnect provider -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          lift (st.input.accounts.unlinkIdentity provider) >>= \case
            Left e -> modify (\s -> s {busy = False, problem = Just (errorMessage e)})
            Right m -> modify (\s -> s {busy = False, methods = Just (Right m)})
      AskPassword -> do
        modify (\st -> (forgetPassword st) {changingPassword = True, passwordTold = Nothing})
        st <- get
        -- The current password's field, or the new one's where there is
        -- no current one.
        current <- H.getRef st.currentField
        new <- H.getRef st.newField
        traverse_ (H.liftEffect . focusElement) (current <|> new)
      CancelPassword -> modify forgetPassword
      TypedCurrent typedCurrent -> modify (\st -> st {typedCurrent})
      TypedNew typedNew -> modify (\st -> st {typedNew})
      TypedRepeat typedRepeat -> modify (\st -> st {typedRepeat})
      SavePassword -> do
        st <- get
        case st.methods of
          Just (Right m)
            | st.busy -> pass
            | st.typedNew /= st.typedRepeat ->
                modify (\s -> s {passwordProblem = Just "The new password and its repetition are not the same."})
            | otherwise -> do
                modify (\s -> s {busy = True, passwordProblem = Nothing})
                let change = PasswordChange {current = if m.password then Just (Password st.typedCurrent) else Nothing, new = Password st.typedNew}
                lift (st.input.accounts.changePassword change) >>= \case
                  Left e -> modify (\s -> s {busy = False, passwordProblem = Just (passwordErrorText e)})
                  Right after ->
                    modify $ \s ->
                      (forgetPassword s)
                        { busy = False
                        , methods = Just (Right after)
                        , passwordTold =
                            Just
                              ( if m.password
                                  then "Your password is changed. You stay signed in here, and anywhere else you were signed in is signed out."
                                  else "Your password is set: you may sign in with your login and it too."
                              )
                        }
          _ -> pass
      SignOut -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True})
          result <- lift st.input.accounts.signOut
          modify (\s -> s {busy = False})
          -- A sign-out that failed leaves the session as it was; the next
          -- request shows whether it still is.
          traverse_ (H.raise . AccountChanged) (rightToMaybe result)

    handleQuery :: Query a -> H.HalogenM (State m) Action Slots Output m (Maybe a)
    handleQuery (Prompt why next) = openForm (Just why) $> Just next

    openForm :: Maybe Text -> H.HalogenM (State m) Action Slots Output m ()
    openForm notice = do
      modify $ \st ->
        if st.open && st.step == AtPassword
          then st {notice, problem = Nothing}
          else st {open = True, step = AtPassword, registering = False, notice, problem = Nothing, typedLogin = "", typedPassword = "", typedCode = ""}
      gets (\st -> st.loginField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- Close the form to change the password, and clear what was typed in
    -- it.
    forgetPassword :: State m -> State m
    forgetPassword st = st {changingPassword = False, typedCurrent = "", typedNew = "", typedRepeat = "", passwordProblem = Nothing}

    close :: H.HalogenM (State m) Action Slots Output m ()
    close = modify (\st -> st {open = False, step = AtPassword, registering = False, notice = Nothing, problem = Nothing, typedPassword = "", typedCode = "", resetTold = Nothing})

-- | The button that opens the form for one's own password, if any:
-- "Change password…" for a user who has a password; "Set a password…" for
-- one who has none and no server provider to sign in with (theirs was
-- disconnected, or removed from the server); and none for one who signs in
-- with a server provider, who has no password to set (WP5.6 of
-- docs/PLAN.md). The server refuses that case the same way.
passwordOffer :: [SignInProvider] -> SignInMethods -> Maybe Text
passwordOffer providers m
  | m.password = Just "Change password…"
  | providerOnly (map (\p -> p.name) providers) m.password (map (\i -> i.provider) m.identities) = Nothing
  | otherwise = Just "Set a password…"
