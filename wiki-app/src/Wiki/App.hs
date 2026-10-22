-- | The wiki's application: the shell ("Wiki.App.Shell") and its views,
-- polymorphic in the monad like every component here, so that the same
-- application runs in the browser (@Main.hs@ picks the in-memory backend
-- over 'Halogen.VDom.DOM.Monad.BrowserDOM') and is rendered natively into
-- the page for each route ahead of the program (@Prerender.hs@, through
-- "Wiki.App.Static").
module Wiki.App
  ( component
  , input
  , module Wiki.App.Route
  )
where

import Halogen.Router (Router)
import Protolude
import Wiki.App.Demo (tourPath)
import Wiki.App.Route
import Wiki.App.Shell (component)
import Wiki.App.Shell qualified as Shell

-- | The shell's input for the demo: the router, and the demo's tour for a
-- newcomer.
input :: Router Route -> Shell.Input
input router = Shell.Input {router, welcome = Just (uncurry Page tourPath)}
