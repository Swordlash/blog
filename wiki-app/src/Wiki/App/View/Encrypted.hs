{-# LANGUAGE QuasiQuotes #-}

-- | The view of an encrypted space whose pages this browser cannot read
-- now (WP5.74 of docs/PLAN.md, "Wiki.App.Backend.Encrypted"): the shell
-- shows it in the space's place when the space's pages did not load. It
-- says why ('KeyState'): the page is not over HTTPS, nobody is signed in,
-- this device does not hold the user's keys yet, or no member has shared
-- the space's key with the user yet.
--
-- When this device does not hold the user's keys, it offers to unlock them
-- here, as the account's security does ("Wiki.App.Vault"): with a passkey
-- (one touch), or with the password, which is proved to the server again.
-- Once unlocked, or on "Try again", it tells the shell, which loads the
-- space again ('Changed').
module Wiki.App.View.Encrypted
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Assistant.Sync (MonadVault)
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..), keyStateText)
import Wiki.App.Editor.Browser (clearField)
import Wiki.App.Vault (unlockWithPasskey, unlockWithPassword)
import Wiki.App.View.Common (Context (..), ViewOutput (..), errorMessage)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Password (..), User (..))

-- | The view's input: the space, and why its pages did not load.
data Input = Input
  { context :: Context
  , space :: Space
  , problem :: WikiError
  }

data State = State
  { input :: Input
  , keys :: Maybe KeyState
  -- ^ Whether this browser can read the space now, once asked.
  , typed :: Text
  , passwordField :: H.RefLabel
  , busy :: Bool
  , told :: Maybe Text
  }

data Action
  = Initialize
  | Receive Input
  | UnlockByPasskey
  | UnlockByPassword
  | Typed Text
  | Again

component :: forall query m. (MonadEncryption m, MonadAssistant m, MonadVault m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          passwordField <- H.newRefLabel "encrypted-password"
          pure State {input, keys = Nothing, typed = "", passwordField, busy = False, told = Nothing}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="encrypted-space" aria-label="Encrypted space">
          <h1>{{ st.input.space.name }}</h1>
          <p class="encrypted-state" role="status">{{ stateText }}</p>
          {% if st.keys == Just KeysLocked %}
            <div class="encrypted-unlock">
              <button type="button" class="encrypted-unlock-passkey" disabled={{ st.busy }} onClick={{ const UnlockByPasskey }}>Unlock with a passkey</button>
              <label class="field">
                <span>Or your password</span>
                <input type="password" name="encrypted-password" autocomplete="current-password" onValueInput={{ Typed }} {{ HP.ref st.passwordField }}>
              </label>
              <button type="button" class="encrypted-unlock-password" disabled={{ st.busy || T.null st.typed }} onClick={{ const UnlockByPassword }}>Unlock with your password</button>
            </div>
          {% end %}
          {% for t in maybeToList st.told %}
            <p class="error encrypted-error" role="alert">{{ t }}</p>
          {% end %}
          <button type="button" class="retry encrypted-retry" disabled={{ st.busy }} onClick={{ const Again }}>Try again</button>
        </section>
      |]
      where
        stateText = case st.keys of
          Nothing -> "This space is encrypted. Checking this browser's keys…"
          -- The key is held, so something else kept the pages from
          -- loading: that is what to say.
          Just KeyReady -> errorMessage st.input.problem
          Just NotEncrypted -> errorMessage st.input.problem
          Just k -> keyStateText k

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize -> check
      Receive input -> modify (\st -> st {input}) >> check
      Typed t -> modify (\st -> st {typed = t})
      Again -> H.raise (Changed Nothing)
      UnlockByPasskey -> unlocking unlockWithPasskey
      UnlockByPassword -> do
        typed <- gets (\st -> st.typed)
        -- The password goes with this one attempt, however it ends.
        modify (\st -> st {typed = ""})
        gets (\st -> st.passwordField) >>= H.getRef >>= traverse_ (H.liftEffect . clearField)
        unlocking (\u -> unlockWithPassword u (Password typed))
      where
        check = do
          sid <- gets (\st -> st.input.space.id)
          lift (keyState sid) >>= \case
            Left e -> modify (\st -> st {told = Just (errorMessage e)})
            Right k -> modify (\st -> st {keys = Just k})
        unlocking act =
          gets (\st -> st.input.context.session.user) >>= \case
            Nothing -> modify (\st -> st {told = Just (keyStateText SignInFirst)})
            Just u -> do
              modify (\st -> st {busy = True, told = Nothing})
              result <- lift (act u.id)
              modify (\st -> st {busy = False})
              case result of
                Left why -> modify (\st -> st {told = Just why})
                Right _ -> H.raise (Changed Nothing)
