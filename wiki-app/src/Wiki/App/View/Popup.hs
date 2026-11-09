-- | Closing a popup when the reader turns away from it: a press of the
-- pointer outside it, or Escape. The header's menus (Starred, the bell,
-- the demo's menu of users), the sidebar's space switcher and the editor's
-- toolbar menus all close this way, and the search box's list closes on a
-- press outside.
--
-- A popup is watched through its holder: the element that holds both the
-- popup and the button that opens it. A press on that button is a press
-- inside, so the button's own click is what closes the popup. Otherwise
-- the press would close the popup and the click would open it again.
--
-- A component starts the watch with 'watchPopup' each time its popup
-- opens, and ends it with 'H.unsubscribe' when the popup closes. The
-- holder can be a different element at each opening (the space switcher
-- is made again with the sidebar), so the element is looked up when the
-- popup opens, not when the component starts.
module Wiki.App.View.Popup
  ( watchPopup
  , pressedOutside
  , escapePressed
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Halogen qualified as H
import Halogen.Query.Event.Window qualified as WindowEvent
import Halogen.Subscription (Emitter)
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude
import Web.DOM.Element qualified as Element
import Web.DOM.Internal.Types (Element (..), toNode)
import Web.Event.Event (EventType (..), defaultPreventedNow)
import Web.Event.Event qualified as Event
import Web.UIEvent.KeyboardEvent qualified as KeyboardEvent

-- | Watch a popup that has just opened: a press outside its holder, or
-- Escape, sends the action given, which closes the popup. Call it after
-- the state change that opened the popup: that change's render has put
-- the holder in the page, so the ref finds it. The result is the
-- subscription, for the component to end when the popup closes; it is
-- 'Nothing' when the holder is not in the page.
watchPopup
  :: (MonadBrowserDOM m, MonadUnliftIO m)
  => H.RefLabel
  -> action
  -> H.HalogenM st action slots output m (Maybe H.SubscriptionId)
watchPopup holder close = do
  found <- H.getRef holder
  for found $ \element -> do
    presses <- H.liftEffect (pressedOutside element)
    escapes <- H.liftEffect (escapePressed element)
    H.subscribe (close <$ (presses <|> escapes))

-- | A press anywhere outside an element, heard on the document. A press,
-- not a click: a click needs the pointer let go on the same element, and a
-- selection dragged out of the popup is not meant to close it. A press, not
-- a loss of focus: a press on something that keeps the focus where it is
-- (a toolbar button that prevents its mousedown's default) takes no focus
-- from the popup, and the popup must close all the same.
--
-- The press is heard as it bubbles up to the document, and whether it
-- landed inside is decided in the listener, while the browser dispatches
-- the press, before a render can move the element pressed. A press that
-- something stopped on its way up is not heard (docs/PLAN.md, "Known gaps
-- and notes").
pressedOutside :: (MonadBrowserDOM n, MonadUnliftIO n) => Element -> n (Emitter IO ())
pressedOutside holder = do
  HS.Emitter register <- WindowEvent.documentEvent (EventType "pointerdown") Just
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \press -> do
      connected <- holder.isConnected
      case Event.target press >>= Element.fromEventTarget of
        Just target | connected -> do
          inside <- holder.contains (toNode target)
          unless inside (push ())
        _ -> pass
    pure stop

-- | Escape pressed anywhere in the page, while the element is in it. A key
-- an element has handled already, and kept from the browser, is left to
-- that element: the editor closes its own menu on Escape, and a dialog
-- that takes Escape keeps it.
escapePressed :: (MonadBrowserDOM n, MonadUnliftIO n) => Element -> n (Emitter IO ())
escapePressed holder = do
  HS.Emitter register <- WindowEvent.keyDown
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \pressed -> do
      connected <- holder.isConnected
      when (connected && pressed.key == "Escape" && not (defaultPreventedNow (KeyboardEvent.toEvent pressed))) (push ())
    pure stop
