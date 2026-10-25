{-# LANGUAGE QuasiQuotes #-}

-- | Who is signed in, in the header of a wiki a server keeps, and the way
-- in and out ("Wiki.App.Account"): for someone not signed in, "Sign in",
-- which opens a small form under it (login, password, and why the last
-- attempt failed); for someone signed in, their name and "Sign out"; for
-- the server's operator, who is the administrator without signing in, only
-- the name.
--
-- In an open wiki ("Wiki.Core.Access") there is "Create account" beside
-- "Sign in", which opens a form of its own (login, display name, password)
-- and signs its maker in as the account it makes (WP3.5 of docs/PLAN.md);
-- a closed wiki takes accounts by invitation only, and has no such button.
--
-- Where the server signs in with providers (OpenID Connect, WP3.6 of
-- docs/PLAN.md: Google, GitHub and the rest the session names), both forms
-- offer them too, as links: signing in with one is a round trip through
-- the provider's pages that the server drives ("Wiki.Api.Auth"), and that
-- ends back at this page's address, signed in.
--
-- A user signed in has their name as a button, whatever the server signs
-- in with, that opens how they sign in: their password, if any, with a
-- form to change it (or to set one, for a user who signs in only with a
-- provider's account: WP3.7 of docs/PLAN.md), which asks for the one they
-- have, the new one and the new one again; the providers' accounts they
-- sign in with, each of which they may disconnect unless it is their last
-- way in; and a link to connect each provider they have no account of
-- yet. The server's operator has no account, and no such button.
--
-- Signing in or out tells the shell the new session ('AccountChanged'),
-- which reloads everything as that reader. The shell can also open the
-- form with a word of its own ('Prompt'): when a session has ended by
-- itself.
--
-- The inputs are not controlled (the component never writes their value),
-- so that a render arriving while someone types never loses a key; what
-- was typed is kept as it is typed. What the form says (the shell's word,
-- why an attempt failed) comes and goes inside containers that are always
-- there, so that the inputs keep their places among the form's children
-- and are never rebuilt with what was typed in them lost.
module Wiki.App.View.SignIn
  ( Input (..)
  , Query (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Account (LinkedIdentity (..), NewAccount (..), PasswordChange (..), SignInMethods (..), mayDisconnect)
import Wiki.Api.Auth (Purpose (..), startUrl)
import Wiki.App.Account (Accounts (..), accountErrorText, passwordErrorText, signInErrorText)
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.View.Common (ariaBool, errorMessage)
import Wiki.Core.Access (takesNewAccounts)
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (SignInProvider (..), Standing (..), User (..), minimumPasswordLength)

data Input m = Input
  { accounts :: Accounts m
  , session :: Session
  , here :: Text
  -- ^ The page's address, as the router writes it: where signing in with
  -- a provider comes back to.
  }

-- | Open the form, saying why.
data Query a = Prompt Text a

-- | Someone signed in or out: who is asking now.
newtype Output = AccountChanged Session

data State m = State
  { input :: Input m
  , open :: Bool
  , typedLogin :: Text
  , typedPassword :: Text
  , notice :: Maybe Text
  -- ^ Why the form was opened, if the shell said.
  , problem :: Maybe Text
  -- ^ Why the last attempt failed.
  , busy :: Bool
  , loginField :: H.RefLabel
  , registering :: Bool
  -- ^ Whether the form to create an account is open (and the sign-in form
  -- closed: one at a time).
  , typedName :: Text
  , registerField :: H.RefLabel
  , accountOpen :: Bool
  -- ^ Whether the panel of how the user signs in is open.
  , methods :: Maybe (Either WikiError SignInMethods)
  -- ^ How they sign in, once read ('Nothing' while it is).
  , changingPassword :: Bool
  -- ^ Whether the form to change their password is open.
  , typedCurrent :: Text
  , typedNew :: Text
  , typedRepeat :: Text
  , passwordProblem :: Maybe Text
  -- ^ Why the last change of password failed.
  , passwordTold :: Maybe Text
  -- ^ That the last one was made.
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

component :: forall m. (MonadUUID m, MonadIO m) => H.Component Query (Input m) Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loginField <- H.newRefLabel "sign-in-login"
          registerField <- H.newRefLabel "register-login"
          currentField <- H.newRefLabel "password-current"
          newField <- H.newRefLabel "password-new"
          pure
            State
              { input
              , open = False
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

    render :: State m -> H.ComponentHTML Action Empty m
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
            {% if st.open %}
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
                {{ providerLinks st "Sign in with " }}
              </form>
            {% end %}
          </div>
        |]

    -- Making oneself an account, in an open wiki: as the sign-in form, with
    -- a display name, and a password that is new.
    registerForm :: State m -> H.ComponentHTML Action Empty m
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
    -- server's round trip, which comes back here.
    providerLinks :: State m -> Text -> H.ComponentHTML Action Empty m
    providerLinks st verb =
      [hh|
        <div class="sign-in-providers">
          {% for p in st.input.session.providers %}
            <a class="provider-link" href={{ startUrl p.name SignInWith st.input.here }}>{{ verb <> p.label }}</a>
          {% end %}
        </div>
      |]

    -- How the user signed in signs in, and the ways to change it.
    accountPanel :: State m -> H.ComponentHTML Action Empty m
    accountPanel st =
      [hh|
        <section class="account-panel" aria-label="How you sign in">
          <h2>How you sign in</h2>
          {{ body }}
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
                  <button type="button" class="password-change-toggle" disabled={{ st.busy }} onClick={{ const AskPassword }}>
                    {{ if m.password then "Change password…" else "Set a password…" :: Text }}
                  </button>
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
                        <span class="identity-email">{{ e }}</span>
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
    -- one. The inputs go with the form when it closes, and what was typed
    -- in them with them.
    passwordForm :: State m -> SignInMethods -> H.ComponentHTML Action Empty m
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

    handleAction :: Action -> H.HalogenM (State m) Action Empty Output m ()
    handleAction = \case
      Receive session here -> modify (\st -> st {input = Input {accounts = st.input.accounts, session, here}})
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
          result <- lift (st.input.accounts.signIn st.typedLogin st.typedPassword)
          case result of
            Left e -> modify (\s -> s {busy = False, problem = Just (signInErrorText e)})
            Right s -> do
              modify (\x -> x {busy = False, open = False, typedPassword = "", notice = Nothing, problem = Nothing})
              H.raise (AccountChanged s)
      ToggleRegister ->
        gets (\st -> st.registering) >>= \case
          True -> close
          False -> do
            -- The other form's inputs are gone, and what was typed in them
            -- with them.
            modify (\st -> st {registering = True, open = False, notice = Nothing, problem = Nothing, typedLogin = "", typedName = "", typedPassword = ""})
            gets (\st -> st.registerField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      TypedName typedName -> modify (\st -> st {typedName})
      Register -> do
        st <- get
        unless st.busy $ do
          modify (\s -> s {busy = True, problem = Nothing})
          result <- lift (st.input.accounts.register NewAccount {login = st.typedLogin, displayName = st.typedName, password = st.typedPassword})
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
        -- The current password's field, or the new one's where there is no
        -- current one.
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
                let change = PasswordChange {current = if m.password then Just st.typedCurrent else Nothing, new = st.typedNew}
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
          -- A sign-out that could not be made leaves the session as it
          -- was; the next request says whether it still is.
          traverse_ (H.raise . AccountChanged) (rightToMaybe result)

    handleQuery :: Query a -> H.HalogenM (State m) Action Empty Output m (Maybe a)
    handleQuery (Prompt why next) = openForm (Just why) $> Just next

    openForm :: Maybe Text -> H.HalogenM (State m) Action Empty Output m ()
    openForm notice = do
      modify $ \st ->
        if st.open
          then st {notice, problem = Nothing}
          else st {open = True, registering = False, notice, problem = Nothing, typedLogin = "", typedPassword = ""}
      gets (\st -> st.loginField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- The form to change the password closed, and what was typed in it
    -- forgotten.
    forgetPassword :: State m -> State m
    forgetPassword st = st {changingPassword = False, typedCurrent = "", typedNew = "", typedRepeat = "", passwordProblem = Nothing}

    close :: H.HalogenM (State m) Action Empty Output m ()
    close = modify (\st -> st {open = False, registering = False, notice = Nothing, problem = Nothing, typedPassword = ""})
