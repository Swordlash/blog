{-# LANGUAGE QuasiQuotes #-}

-- | 'NewKindDialog' is the editor's "New kind…" dialog (WP5.41 of
-- docs/PLAN.md): an administrator defines a kind of box without leaving
-- the page being written (the owner, 2026-11-02). Its form is the one the
-- administration's Editor section shows ("Wiki.App.View.BoxKindForm").
--
-- The dialog reads the server's settings when it opens, and saving writes
-- them with the new kind after the others, as the administration's "Add a
-- kind of box" does. The server checks the kind (a name already taken, one
-- of GitHub's five) and a refusal is shown in the dialog, which stays
-- open. Once saved, the dialog closes and tells the editor ('Saved'),
-- which writes a box of the new kind and has the shell read the session
-- again, so that the kind is in the Box menu and pages draw it at once.
--
-- It is a @\<dialog>@ shown as a modal ('showDialog'), as the
-- administration's user dialog is: the rest of the page is inert, Escape
-- closes it, and so does a click that starts on the backdrop. It does not
-- close while the settings are being written: closing removes the
-- component, and the editor would not hear of the saved kind.
module Wiki.App.View.NewKindDialog
  ( Input (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.Api.ServerSettings (ServerSettings, ServerSettingsChange, ServerSettingsOf (..))
import Wiki.App.Backend (WikiError)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Browser (closeDialog, showDialog)
import Wiki.App.View.BoxKindForm qualified as BoxKindForm
import Wiki.App.View.Common
import Wiki.Core.Markdown.Box (BoxKind (..))

newtype Input = Input {context :: Context}

-- | What the dialog tells the editor.
data Output
  = -- | This kind was saved, and the dialog has closed.
    Saved BoxKind
  | -- | The dialog closed without saving.
    Closed

type Slots = ("kindForm" .== H.Slot (Const Void) BoxKindForm.Output ())

data State = State
  { input :: Input
  , element :: H.RefLabel
  , settings :: Maybe (Either WikiError ServerSettings)
  -- ^ The server's settings, once read.
  , saving :: Bool
  -- ^ The settings are being written; the dialog does not close.
  , refusal :: Maybe WikiError
  , pressedOnBackdrop :: Bool
  -- ^ Whether the pointer went down on the backdrop: only a click that
  -- starts there closes the dialog, not a selection let go outside.
  }

data Action
  = Initialize
  | Close
  | ClickedDialog
  | Pressed Bool
  | Inside
  | ClosedByBrowser
  | FromForm BoxKindForm.Output

component :: forall query m. (MonadAdmin m, MonadUUID m, MonadIO m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          element <- H.newRefLabel "new-kind-dialog"
          pure State {input, element, settings = Nothing, saving = False, refusal = Nothing, pressedOnBackdrop = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <dialog
          class="new-kind-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="new-kind-title"
          onClick={{ const ClickedDialog }}
          {{ HP.ref st.element }}
          {{ [HE.handler (EventType "close") (const ClosedByBrowser), HE.onPointerDown (const (Pressed True))] <> [HE.preventingDefault (HE.handler (EventType "cancel") (const Inside)) | st.saving] }}
        >
          <div class="new-kind-dialog-body" {{ [HE.stoppingPropagation (HE.onClick (const Inside)), HE.stoppingPropagation (HE.onPointerDown (const (Pressed False)))] }}>
            <header class="new-kind-dialog-header">
              <h2 id="new-kind-title">A new kind of box</h2>
              <button type="button" class="new-kind-dialog-close" aria-label="Close" disabled={{ st.saving }} onClick={{ const Close }}>×</button>
            </header>
            <p class="admin-intro">
              Its boxes get this title, colour and icon on every page, as the administration's Editor section shows them.
            </p>
            {{ errorView <$> st.refusal }}
            {{ body }}
          </div>
        </dialog>
      |]
      where
        body = case st.settings of
          Nothing -> [hh|<p class="loading">Loading…</p>|]
          Just (Left e) -> errorView e
          Just (Right _) -> HH.slot "kindForm" () BoxKindForm.component BoxKindForm.Input {kind = Nothing, busy = st.saving} FromForm

    handleAction :: Action -> H.HalogenM State Action Slots Output m ()
    handleAction = \case
      Initialize -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . showDialog)
        result <- lift serverSettings
        modify (\st -> st {settings = Just result})
      Close -> unlessM (gets (\st -> st.saving)) $ do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
        H.raise Closed
      Inside -> pass
      Pressed onBackdrop -> modify (\st -> st {pressedOnBackdrop = onBackdrop})
      ClickedDialog -> do
        onBackdrop <- gets (\st -> st.pressedOnBackdrop)
        modify (\st -> st {pressedOnBackdrop = False})
        when onBackdrop (handleAction Close)
      ClosedByBrowser -> unlessM (gets (\st -> st.saving)) (H.raise Closed)
      FromForm BoxKindForm.Cancelled -> handleAction Close
      FromForm (BoxKindForm.Submitted kind) ->
        gets (\st -> st.settings) >>= \case
          Just (Right s) -> do
            modify (\st -> st {saving = True, refusal = Nothing})
            lift (setServerSettings ((unchanged s) {boxes = s.boxes <> [kind]})) >>= \case
              Left e -> modify (\st -> st {saving = False, refusal = Just e})
              Right new -> do
                modify (\st -> st {saving = False, settings = Just (Right new)})
                gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
                -- The kind as the server keeps it: its name in lower case,
                -- its label filled in.
                H.raise (Saved (fromMaybe kind (find (\b -> b.name == kind.name) new.boxes)))
          _ -> pass

-- | The settings as read, as a change that changes nothing: every secret
-- kept.
unchanged :: ServerSettings -> ServerSettingsChange
unchanged = fmap (const Nothing)
