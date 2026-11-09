-- | The search box in the shell's header: a page picker
-- ("Wiki.App.View.PagePicker") that opens the page picked, or the page of
-- all results ("Wiki.App.View.SearchResults").
--
-- From the keyboard: @/@ anywhere outside a field focuses the input, and
-- Escape closes the list. So does a press anywhere outside the box, even
-- one that leaves the focus in the input. Whatever navigates away (a hit,
-- the results page) closes the list and takes focus out of the box, so
-- that @/@ works again wherever the reader lands.
module Wiki.App.View.Search
  ( Input (..)
  , component
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Query.Event.Window qualified as WindowEvent
import Halogen.Router qualified as Router
import Halogen.Subscription (Emitter)
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.DOM.Element qualified as Element
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (defaultPreventedNow, preventDefault)
import Web.Event.Event qualified as Event
import Web.UIEvent.KeyboardEvent qualified as KeyboardEvent
import Wiki.App.Backend (MonadLoad (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.App.View.PagePicker qualified as Picker
import Wiki.App.View.Popup (pressedOutside)
import Wiki.Core.Search (SearchHit (..))

newtype Input = Input {context :: Context}

data State = State
  { input :: Input
  , box :: H.RefLabel
  }

data Action
  = Initialize
  | Receive Input
  | Shortcut
  | PressedOutside
  | FromPicker Picker.Output

type Slots = ("picker" .== H.Slot Picker.Query Picker.Output ())

component :: forall query output m. (MonadLoad m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          box <- H.newRefLabel "search-box"
          pure State {input, box}
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
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      HH.div
        [HP.ref st.box, HP.class_ "wiki-search", HP.attr (HH.AttrName "role") "search"]
        [HH.slot "picker" () Picker.component Picker.Input {context = st.input.context, place = Picker.InHeader} FromPicker]

    handleAction :: Action -> H.HalogenM State Action Slots output m ()
    handleAction = \case
      -- The "/" shortcut and the press outside the box are heard for as
      -- long as the box is shown: the subscriptions end with it.
      Initialize -> do
        ref <- gets (\st -> st.box)
        found <- H.getRef ref
        for_ found $ \element -> do
          slashes <- H.liftEffect (slashPressed element)
          void (H.subscribe (Shortcut <$ slashes))
          -- The list closes on a press outside the box; Escape is the
          -- picker's own, in its input.
          presses <- H.liftEffect (pressedOutside element)
          void (H.subscribe (PressedOutside <$ presses))
      Receive input -> modify (\st -> st {input})
      -- The browser was kept from typing the "/" in the listener; the box
      -- takes the focus now, with its text selected, to be typed over.
      Shortcut -> H.tell "picker" () Picker.Focus
      PressedOutside -> H.tell "picker" () Picker.Close
      FromPicker (Picker.Picked hit) -> go (Page hit.spacePath hit.pagePath)
      FromPicker (Picker.AllResults r) -> go r

    go :: Route -> H.HalogenM State Action Slots output m ()
    go r = do
      router <- gets (\st -> st.input.context.router)
      H.liftEffect (Router.navigate router r)
      H.tell "picker" () Picker.Leave

-- | The "/" shortcut: "/" pressed anywhere but in a field (where it is a
-- character to type), as GitHub and others have it. Whether a key is the
-- shortcut is decided in the window's listener, while the browser
-- dispatches the key, and the browser is told there not to type it; a key
-- an element has handled already, and kept from the browser, is left to
-- it. A page shown as slides covers the box, and takes its keys itself.
slashPressed :: (MonadBrowserDOM n, MonadUnliftIO n) => Element -> n (Emitter IO ())
slashPressed box = do
  HS.Emitter register <- WindowEvent.keyDown
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \pressed -> do
      connected <- box.isConnected
      when (connected && isShortcut pressed) $ do
        preventDefault (KeyboardEvent.toEvent pressed)
        push ()
    pure stop
  where
    isShortcut pressed =
      pressed.key == "/"
        && not (defaultPreventedNow (KeyboardEvent.toEvent pressed))
        && not (pressed.ctrlKey || pressed.metaKey || pressed.altKey)
        && isNothing (Event.target (KeyboardEvent.toEvent pressed) >>= Element.fromEventTarget >>= (`Element.closestNow` "input, textarea, select, [contenteditable], .slides-view"))
