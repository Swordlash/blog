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
--
-- A space that asks each time it is opened ('Wiki.Core.Space.ConfirmEach')
-- is shown here until the reader confirms ('ConfirmFirst'): with a passkey
-- where their vault has one and this browser can use passkeys, with their
-- password otherwise. A user who has neither here (one who signs in with a
-- provider, without a passkey on this device) is told that the space
-- cannot be opened here. Confirming unlocks the user's keys again, as
-- above, and only then opens the space's gate in this tab ('confirmWith').
module Wiki.App.View.Encrypted
  ( Input (..)
  , component
  , confirmWith
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Vault (StoredVault (..))
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Assistant.Sync (MonadVault)
import Wiki.App.Backend (Session (..), WikiError (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..), keyStateText)
import Wiki.App.Editor.Browser (clearField)
import Wiki.App.Vault (UserKeys (..), loadUserKeys, unlockWithPasskey, unlockWithPassword)
import Wiki.App.View.Common (Context (..), ViewOutput (..), errorMessage)
import Wiki.Core.Id (SpaceId, UserId)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Password (..), User (..))
import Wiki.Core.Vault (Unlock (..), passkeyWraps, wrapFor)

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
  , ways :: Maybe Ways
  -- ^ How the reader may confirm, for a space that asks each time, once
  -- known.
  }

-- | 'Ways': how a reader may confirm for a space that asks each time: with
-- a passkey, where the vault has one and this browser can use passkeys,
-- and with the password, where it unlocks the vault. Both are offered
-- when both are there: a passkey not on this device (a security key left
-- at home) fails, and the password is then the way in.
data Ways = Ways
  { passkey :: Bool
  , password :: Bool
  }
  deriving stock (Eq)

data Action
  = Initialize
  | Receive Input
  | UnlockByPasskey
  | UnlockByPassword
  | Typed Text
  | Again
  | ConfirmByPasskey
  | ConfirmByPassword

component :: forall query m. (MonadEncryption m, MonadAssistant m, MonadVault m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          passwordField <- H.newRefLabel "encrypted-password"
          pure State {input, keys = Nothing, typed = "", passwordField, busy = False, told = Nothing, ways = Nothing}
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
          {% if st.keys == Just ConfirmFirst %}
            <div class="encrypted-confirm">
              <p class="encrypted-confirm-why">It guards against someone using your unlocked computer. It does not stop someone who opens the browser's developer tools on a device where your keys are unlocked.</p>
              {% if maybe False (\w -> w.passkey) st.ways %}
                <button type="button" class="primary encrypted-confirm-passkey" disabled={{ st.busy }} onClick={{ const ConfirmByPasskey }}>Open with a passkey</button>
              {% end %}
              {% if maybe False (\w -> w.password) st.ways %}
                <label class="field">
                  <span>Your password</span>
                  <input type="password" name="encrypted-password" autocomplete="current-password" onValueInput={{ Typed }} {{ HP.ref st.passwordField }}>
                </label>
                <button type="button" class="primary encrypted-confirm-password" disabled={{ st.busy || T.null st.typed }} onClick={{ const ConfirmByPassword }}>Open with your password</button>
              {% end %}
              {% if st.ways == Just Ways {passkey = False, password = False} %}
                <p class="encrypted-confirm-none">It cannot be opened on this device: no passkey of yours opens your keys in this browser, and they do not open with a password. Open it on a device with your passkey.</p>
              {% end %}
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
      Initialize -> askKeys
      Receive input -> modify (\st -> st {input}) >> askKeys
      Typed t -> modify (\st -> st {typed = t})
      Again -> H.raise (Changed Nothing)
      UnlockByPasskey -> unlocking (fmap void . unlockWithPasskey)
      UnlockByPassword -> do
        typed <- takeTyped
        unlocking (\u -> void <$> unlockWithPassword u (Password typed))
      ConfirmByPasskey -> do
        sid <- gets (\st -> st.input.space.id)
        unlocking (\u -> confirmWith sid u Nothing)
      ConfirmByPassword -> do
        sid <- gets (\st -> st.input.space.id)
        typed <- takeTyped
        unlocking (\u -> confirmWith sid u (Just (Password typed)))
      where
        askKeys = do
          sid <- gets (\st -> st.input.space.id)
          lift (keyState sid) >>= \case
            Left e -> modify (\st -> st {told = Just (errorMessage e)})
            Right k -> do
              modify (\st -> st {keys = Just k})
              when (k == ConfirmFirst) findWay
        -- How this reader may confirm here: a passkey where their vault
        -- has one and this browser can use passkeys, and the password where
        -- it unlocks the vault, both when both are there.
        findWay =
          gets (\st -> st.input.context.session.user)
            >>= traverse_
              ( \u -> do
                  here <- lift passkeysHere
                  lift (loadUserKeys u.id) >>= \case
                    Left why -> modify (\st -> st {told = Just why})
                    Right keys -> do
                      let vault = (\v -> v.vault) <$> keys.vault
                          ways = Ways {passkey = here && maybe False (not . null . passkeyWraps) vault, password = isJust (vault >>= wrapFor ByPassword)}
                      modify (\st -> st {ways = Just ways})
              )
        -- The password goes with this one attempt, however it ends.
        takeTyped = do
          typed <- gets (\st -> st.typed)
          modify (\st -> st {typed = ""})
          gets (\st -> st.passwordField) >>= H.getRef >>= traverse_ (H.liftEffect . clearField)
          pure typed
        unlocking act =
          gets (\st -> st.input.context.session.user) >>= \case
            Nothing -> modify (\st -> st {told = Just (keyStateText SignInFirst)})
            Just u -> do
              modify (\st -> st {busy = True, told = Nothing})
              result <- lift (act u.id)
              modify (\st -> st {busy = False})
              case result of
                Left why -> modify (\st -> st {told = Just why})
                Right () -> H.raise (Changed Nothing)

-- | Confirm for a space that asks each time it is opened: unlock the
-- user's keys again, with a passkey ('Nothing') or the password, which is
-- proved to the server again, and only once that succeeded open the
-- space's gate in this tab ('confirmedEntry'). The one place a gate is
-- opened.
confirmWith :: (MonadEncryption m, MonadAssistant m, MonadVault m) => SpaceId -> UserId -> Maybe Password -> m (Either Text ())
confirmWith sid u how =
  maybe (unlockWithPasskey u) (unlockWithPassword u) how >>= \case
    Left why -> pure (Left why)
    Right _ -> confirmedEntry sid $> Right ()
