{-# LANGUAGE QuasiQuotes #-}

-- | The account menu's switch of the signed-in user's personal space
-- (WP5.54 of docs/PLAN.md): "Enable personal space" while they have none,
-- or have one turned off, and "Disable personal space" while it is on.
-- The server's account panel ("Wiki.App.View.SignIn") and the demo's menu
-- of users ("Wiki.App.Shell") both show it.
--
-- Enabling makes the space the first time ('setPersonalSpace'): a space
-- named after the user, in the container "User subspaces", which the
-- sidebar lists and the header's Starred panel links to as "Your space".
-- Disabling asks first, and says what it does: the space is hidden from
-- everyone, and nothing in it is deleted. After either, the shell is told
-- that the wiki changed ('Changed'), so that it lists the spaces again.
--
-- The state of the space is read when the switch is shown, and again when
-- another user is signed in (the demo switches users without closing its
-- menu).
module Wiki.App.View.PersonalSpace
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.View.Common (ViewOutput (..), errorMessage)
import Wiki.Core.Id (UserId)
import Wiki.Core.Space (Space (..))

-- | The user the switch is for: the signed-in one.
newtype Input = Input {user :: Maybe UserId}

data State = State
  { input :: Input
  , space :: Maybe (Either WikiError (Maybe Space))
  -- ^ The user's personal space as the backend last gave it: 'Nothing'
  -- until it has answered.
  , confirming :: Bool
  -- ^ "Disable personal space" was pressed, and the question is shown.
  , busy :: Bool
  -- ^ A change has been asked for, and has not been answered yet.
  }

data Action
  = Initialize
  | Receive Input
  | Enable
  | AskDisable
  | Disable
  | Cancel

component :: forall query m. (MonadWiki m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, space = Nothing, confirming = False, busy = False}
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
        <div class="personal-space-switch">
          {{ body }}
        </div>
      |]
      where
        body = case st.space of
          Nothing -> [hh|<span class="loading">Personal space…</span>|]
          Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
          Just (Right own)
            | not (maybe False (\s -> s.active) own) ->
                [hh|<button type="button" class="personal-space-enable" disabled={{ st.busy }} onClick={{ const Enable }}>Enable personal space</button>|]
            | st.confirming ->
                [hh|
                  <div class="confirm personal-space-confirm" role="alertdialog">
                    <p>Disable your personal space? It is hidden from everyone, you included, until you enable it again. Nothing in it is deleted.</p>
                    <button type="button" class="danger personal-space-confirm-disable" disabled={{ st.busy }} onClick={{ const Disable }}>Disable</button>
                    <button type="button" onClick={{ const Cancel }}>Cancel</button>
                  </div>
                |]
            | otherwise ->
                [hh|<button type="button" class="personal-space-disable" disabled={{ st.busy }} onClick={{ const AskDisable }}>Disable personal space</button>|]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize -> load
      Receive input -> do
        old <- gets (\st -> st.input.user)
        modify (\st -> st {input})
        when (old /= input.user) $ do
          modify (\st -> st {space = Nothing, confirming = False})
          load
      Enable -> switch True
      AskDisable -> modify (\st -> st {confirming = True})
      Cancel -> modify (\st -> st {confirming = False})
      Disable -> switch False

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      own <- lift personalSpace
      modify (\st -> st {space = Just own})

    -- Turn the space on or off. The answer is the space as it is now;
    -- a refusal is shown in place of the switch.
    switch :: Bool -> H.HalogenM State Action Empty ViewOutput m ()
    switch enabled = do
      modify (\st -> st {busy = True})
      result <- lift (setPersonalSpace enabled)
      modify (\st -> st {space = Just (Just <$> result), busy = False, confirming = False})
      when (isRight result) (H.raise (Changed Nothing))
