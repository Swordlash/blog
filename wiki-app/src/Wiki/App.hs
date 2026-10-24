-- | The wiki's application: the shell ("Wiki.App.Shell") and its views,
-- polymorphic in the monad like every component here, so that the same
-- application runs in the browser (@Main.hs@ picks the in-memory backend
-- over 'Halogen.VDom.DOM.Monad.BrowserDOM') and is rendered natively into
-- the page for each route ahead of the program (@Prerender.hs@, through
-- "Wiki.App.Static").
module Wiki.App
  ( component
  , input
  , serverInput
  , module Wiki.App.Route
  )
where

import Halogen.Router (Router)
import Protolude
import Wiki.App.Demo (tourPath)
import Wiki.App.DemoUsers (MonadDemoUsers, demoControls)
import Wiki.App.Route
import Wiki.App.Shell (component)
import Wiki.App.Shell qualified as Shell

-- | The shell's input for the demo: the router, the demo's tour for a
-- newcomer, and its controls.
input :: (MonadDemoUsers m) => Router Route -> Shell.Input m
input router = Shell.Input {router, welcome = Just (uncurry Page tourPath), demo = Just demoControls}

-- | The shell's input for a wiki a server keeps: the router alone. The
-- server's wiki is its owner's, with no tour in it, and people sign in to
-- it rather than switch.
serverInput :: Router Route -> Shell.Input m
serverInput router = Shell.Input {router, welcome = Nothing, demo = Nothing}
