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
  , serverInputWith
  , module Wiki.App.Route
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Time (getCurrentTime)
import Data.Version (showVersion)
import Halogen.Router (Router)
import Paths_wiki_app qualified as Paths
import Protolude
import Web.Storage.IndexedDB (Database, MonadIndexedDB)
import Wiki.App.Backend.Http (HttpWiki, applyImport, previewImport)
import Wiki.App.Backend.Mem (memWikiFound, readMemWiki)
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Browser (zipFiles)
import Wiki.App.Demo (demoDatabase, tourPath)
import Wiki.App.DemoUsers (MonadDemoUsers, demoControls)
import Wiki.App.Route
import Wiki.App.Shell (component)
import Wiki.App.Shell qualified as Shell
import Wiki.App.View.Import (Migration (..))
import Wiki.Core.Export (writeArchive)

-- | The shell's input for the demo: the router, the demo's tour for a
-- newcomer, and its controls.
input :: (MonadDemoUsers m) => Router Route -> Shell.Input m
input router = Shell.Input {router, welcome = Just (uncurry Page tourPath), demo = Just demoControls, migration = Nothing}

-- | The shell's input for a wiki a server keeps: the router, and the
-- import into the server, which offers the wiki the demo left in this
-- browser ('demoDatabase') as a source. The server's wiki is its owner's,
-- with no tour in it, and people sign in to it rather than switch.
serverInput :: (MonadIndexedDB m, MonadUnliftIO m) => Router Route -> Shell.Input (HttpWiki m)
serverInput = serverInputWith demoDatabase

-- | 'serverInput', with the demo's wiki looked for in this database: the
-- browser tests' own.
serverInputWith :: (MonadIndexedDB m, MonadUnliftIO m) => Database -> Router Route -> Shell.Input (HttpWiki m)
serverInputWith db router =
  Shell.Input
    { router
    , welcome = Nothing
    , demo = Nothing
    , migration =
        Just
          Migration
            { previewImport
            , applyImport
            , findDemoData = memWikiFound db
            , readDemoData =
                readMemWiki db >>= \case
                  Left why -> pure (Left why)
                  Right wiki -> do
                    now <- liftIO getCurrentTime
                    Right <$> zipFiles (writeArchive (toArchive now ("wiki-app " <> toS (showVersion Paths.version)) wiki))
            }
    }
