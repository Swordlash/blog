{-# LANGUAGE QuasiQuotes #-}

-- | Who is signed in, in the header of a wiki a server keeps, and the way
-- in and out ("Wiki.App.Account"): for someone not signed in, "Sign in",
-- which opens a small form under it (login, password, and why the last
-- attempt failed); for someone signed in, their name and "Sign out"; for
-- the server's operator, who is the administrator without signing in, only
-- the name.
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
import Wiki.App.Account (Accounts (..), signInErrorText)
import Wiki.App.Backend (Session (..))
import Wiki.App.Editor.Browser (focusElement)
import Wiki.App.View.Common (ariaBool)
import Wiki.Core.User (Standing (..), User (..))

data Input m = Input
  { accounts :: Accounts m
  , session :: Session
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
  }

data Action
  = Receive Session
  | Toggle
  | Close
  | TypedLogin Text
  | TypedPassword Text
  | Submit
  | SignOut

component :: forall m. (MonadUUID m, MonadIO m) => H.Component Query (Input m) Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loginField <- H.newRefLabel "sign-in-login"
          pure State {input, open = False, typedLogin = "", typedPassword = "", notice = Nothing, problem = Nothing, busy = False, loginField}
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
    receive input = Receive input.session

    render :: State m -> H.ComponentHTML Action Empty m
    render st = case st.input.session of
      Session {user = Just u, standing = SignedIn} ->
        [hh|
          <div class="account">
            <span class="user-name">{{ u.displayName }}</span>
            <button type="button" class="sign-out" disabled={{ st.busy }} onClick={{ const SignOut }}>Sign out</button>
          </div>
        |]
      Session {user = Just u} -> [hh|<span class="user-name">{{ u.displayName }}</span>|]
      Session {user = Nothing} ->
        [hh|
          <div class="account">
            <button type="button" class="sign-in-toggle" aria-expanded={{ ariaBool st.open }} onClick={{ const Toggle }}>Sign in</button>
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
              </form>
            {% end %}
          </div>
        |]

    handleAction :: Action -> H.HalogenM (State m) Action Empty Output m ()
    handleAction = \case
      Receive session -> modify (\st -> st {input = Input {accounts = st.input.accounts, session}})
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
      modify (\st -> st {open = True, notice, problem = Nothing})
      gets (\st -> st.loginField) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    close :: H.HalogenM (State m) Action Empty Output m ()
    close = modify (\st -> st {open = False, notice = Nothing, problem = Nothing, typedPassword = ""})
