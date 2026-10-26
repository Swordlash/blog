{-# LANGUAGE TemplateHaskell #-}

-- | Reading the wiki offline and installing it (WP4.17 of docs/PLAN.md),
-- as the application sees it: the service worker (@web\/src\/sw.js@) keeps
-- the application and the pages read, and serves a kept page when there is
-- no network, with a mark in its head that says when it was kept
-- ('offlineCopy'); the browser says whether it is online ('browserOnline');
-- the browser's offer to install the wiki, which @web\/index.js@ keeps from
-- whenever it comes, is shown when the reader asks ('installAvailable',
-- 'install', and 'installChanges' when it comes or goes); and what the
-- worker kept is let go when who is asking changes ('forgetReads').
--
-- See @jsbits/offline.js@. Natively there is no browser: no page is an
-- offline copy, the browser is online, nothing is offered, and nothing is
-- kept to let go of.
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
-- letting go of the kept pages for the browser's caches, so those two are
-- safe imports, which wait for their promises; the rest answer at once.
$( browserJS
     ["jsbits/offline.js"]
     [ ("js_offline_copy", "wiki_offline_copy", Unsafe, [t|IO JSText|])
     , ("js_browser_online", "wiki_browser_online", Unsafe, [t|IO Bool|])
     , ("js_install_available", "wiki_install_available", Unsafe, [t|IO Bool|])
     , ("js_install", "wiki_install", Safe, [t|IO Bool|])
     , ("js_forget_reads", "wiki_forget_reads", Safe, [t|IO ()|])
     ]
 )

-- | When the page was kept, if the service worker served it from what it
-- kept because there was no network: the time it put in the page's head.
-- The server never writes that mark, so a page from the network says
-- 'Nothing', and the program adopts it as it always did.
offlineCopy :: (MonadIO m) => m (Maybe UTCTime)
offlineCopy = liftIO (iso8601ParseM . toS . fromJSText <$> js_offline_copy)

-- | Whether the browser has a network to use (@navigator.onLine@), at
-- once; "Halogen.Query.Event.Window"'s 'Window.online' says when that
-- changes. Natively, always.
browserOnline :: (MonadIO m) => m Bool
browserOnline
  | inBrowser = liftIO js_browser_online
  | otherwise = pure True

-- | Whether the browser has offered to install the wiki, and the offer is
-- still open. Only Chromium makes one, once it finds the page installable.
installAvailable :: (MonadIO m) => m Bool
installAvailable = liftIO js_install_available

-- | Show the browser's offer to install the wiki, and say whether the
-- reader took it. This waits for the reader, so a component calls it off
-- its loop ('lift' in 'Halogen.HalogenM', not 'Halogen.liftEffect').
install :: (MonadIO m) => m Bool
install =
  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced.
  liftIO (evaluate =<< js_install)

-- | Whenever the browser's offer comes or goes ('installAvailable' then
-- says which), from the moment of subscribing.
installChanges :: (MonadBrowserDOM m, MonadUnliftIO m) => m (Emitter IO ())
installChanges = Window.windowEvent (EventType "wiki-installable") (const (Just ()))

-- | Let go of the pages and the API's answers the service worker keeps for
-- this wiki, which were read as whoever was signed in: signing out does.
forgetReads :: (MonadIO m) => m ()
forgetReads = liftIO (evaluate =<< js_forget_reads)
