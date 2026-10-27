{-# LANGUAGE TemplateHaskell #-}

-- | Reading the wiki offline and installing it as an application (WP4.17
-- of docs/PLAN.md), as the application uses them. The service worker
-- (@web\/src\/sw.js@) stores the application and the pages read, and
-- serves a stored page when there is no network, with a mark in its head
-- that says when it was stored ('offlineCopy'). The browser says whether
-- it is online ('browserOnline'). The browser's offer to install the wiki,
-- which @web\/index.js@ holds on to from whenever it arrives, is shown when
-- the reader asks ('installAvailable', 'install', and 'installChanges'
-- when the offer arrives or goes away). The worker's stored pages are
-- deleted when the signed-in user changes ('forgetReads').
--
-- See @jsbits/offline.js@. Natively there is no browser: no page is an
-- offline copy, the browser is online, nothing is offered, and there is
-- nothing stored to delete.
module Wiki.App.Offline
  ( offlineCopy
  , browserOnline
  , installAvailable
  , install
  , installChanges
  , forgetReads
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, inBrowser)
import Halogen.Query.Event.Window qualified as Window
import Halogen.Subscription (Emitter)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude
import Web.Event.Event (EventType (..))

-- Installing waits for the reader's answer to the browser's question, and
-- deleting the stored pages waits for the browser's caches, so those two
-- are safe imports, which wait for their promises; the rest return at once.
$( browserJS
     ["jsbits/offline.js"]
     [ ("js_offline_copy", "wiki_offline_copy", Unsafe, [t|IO JSText|])
     , ("js_browser_online", "wiki_browser_online", Unsafe, [t|IO Bool|])
     , ("js_install_available", "wiki_install_available", Unsafe, [t|IO Bool|])
     , ("js_install", "wiki_install", Safe, [t|IO Bool|])
     , ("js_forget_reads", "wiki_forget_reads", Safe, [t|IO ()|])
     ]
 )

-- | When the page was stored, if the service worker served it from its
-- stored copy because there was no network: the time it put in the page's
-- head. The server never writes that mark, so a page from the network
-- gives 'Nothing', and the program adopts it as usual.
offlineCopy :: (MonadIO m) => m (Maybe UTCTime)
offlineCopy = liftIO (iso8601ParseM . toS . fromJSText <$> js_offline_copy)

-- | Whether the browser has a network to use (@navigator.onLine@), right
-- now; "Halogen.Query.Event.Window"'s 'Window.online' reports when that
-- changes. Natively, always true.
browserOnline :: (MonadIO m) => m Bool
browserOnline
  | inBrowser = liftIO js_browser_online
  | otherwise = pure True

-- | Whether the browser has offered to install the wiki, and the offer is
-- still open. Only Chromium makes one, once it finds the page installable.
installAvailable :: (MonadIO m) => m Bool
installAvailable = liftIO js_install_available

-- | Show the browser's offer to install the wiki, and say whether the
-- reader accepted it. This waits for the reader, so a component calls it
-- off its loop ('lift' in 'Halogen.HalogenM', not 'Halogen.liftEffect').
install :: (MonadIO m) => m Bool
install =
  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced.
  liftIO (evaluate =<< js_install)

-- | An event whenever the browser's offer arrives or goes away
-- ('installAvailable' then says which), from the moment of subscribing.
installChanges :: (MonadBrowserDOM m, MonadUnliftIO m) => m (Emitter IO ())
installChanges = Window.windowEvent (EventType "wiki-installable") (const (Just ()))

-- | Delete the pages and API responses the service worker stored for this
-- wiki, which were read as the user who was signed in. Signing out does
-- this.
forgetReads :: (MonadIO m) => m ()
forgetReads = liftIO (evaluate =<< js_forget_reads)
