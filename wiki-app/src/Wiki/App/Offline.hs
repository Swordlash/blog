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
-- Natively there is no browser: no page is an offline copy, the browser is
-- online, nothing is offered, and there is nothing stored to delete.
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
import Data.Coerce (coerce)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Halogen.JSBits (Inert, JSVal, inBrowser)
import Halogen.JSBits.Fields (Member (..), jsFields)
import Halogen.JSBits.Promise (FromJS, JSError, Promise (..), wait)
import Halogen.Query.Event.Window qualified as WindowEvent
import Halogen.Subscription (Emitter)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (wait)
import Web.DOM.Element qualified as Element
import Web.DOM.Internal.Types (Window (..))
import Web.Event.Event (EventTarget (..), EventType (..))
import Web.Event.Event qualified as Event
import Web.HTML.Window qualified as Window
import Web.URL qualified as URL

-- | The window as the page's loader (@web/index.js@) adds to it: the
-- browser's offer to install the wiki, kept from the moment it comes
-- until it is shown.
newtype Installing = Installing Window
  deriving newtype (Inert)

-- | The browser's offer to install the page: a @BeforeInstallPromptEvent@.
newtype InstallPrompt = InstallPrompt JSVal
  deriving newtype (Inert)

-- | What the reader answered the offer with.
newtype Choice = Choice JSVal
  deriving newtype (Inert, FromJS)

$( jsFields
     ''Installing
     [ -- The offer, while one is open; the loader sets it, and 'install'
       -- takes it.
       Writable "wikiInstallPrompt" [t|Maybe InstallPrompt|]
     ]
 )

$( jsFields
     ''InstallPrompt
     [ -- Show the browser's own dialog; resolved once it is shown.
       Method "prompt" [t|IO (Promise ())|]
     , -- The reader's answer, once given.
       Live "userChoice" [t|Promise Choice|]
     ]
 )

$( jsFields
     ''Choice
     [ -- @"accepted"@ or @"dismissed"@.
       Fixed "outcome" ''Text
     ]
 )

-- | When the page was stored, if the service worker served it from its
-- stored copy because there was no network: the time it put in the page's
-- head, @\<meta name="wiki-offline-copy">@. The server never writes that
-- mark, so a page from the network gives 'Nothing', and the program
-- adopts it as usual.
offlineCopy :: (MonadIO m) => m (Maybe UTCTime)
offlineCopy = liftIO $ do
  w <- Window.window
  marked <- w.document.querySelector "meta[name=\"wiki-offline-copy\"]" >>= traverse (`Element.getAttribute` "content")
  pure (join marked >>= iso8601ParseM . toS)

-- | Whether the browser has a network to use (@navigator.onLine@), right
-- now; "Halogen.Query.Event.Window"'s 'WindowEvent.online' reports when
-- that changes. Natively, always true.
browserOnline :: (MonadIO m) => m Bool
browserOnline
  | inBrowser = liftIO $ Window.window >>= \w -> w.navigator.onLine
  | otherwise = pure True

-- | Whether the browser has offered to install the wiki, and the offer is
-- still open. Only Chromium makes one, once it finds the page installable.
installAvailable :: (MonadIO m) => m Bool
installAvailable = liftIO $ Installing <$> Window.window >>= fmap isJust . (.wikiInstallPrompt)

-- | Show the browser's offer to install the wiki, and say whether the
-- reader accepted it. An offer is shown once: whatever the answer, it is
-- spent, and the browser makes another if the page is still installable;
-- the page hears @wiki-installable@ ('installChanges') either way. This
-- waits for the reader, so a component calls it off its loop ('lift' in
-- 'Halogen.HalogenM', not 'Halogen.liftEffect').
install :: (MonadIO m) => m Bool
install = liftIO $ do
  page <- Installing <$> Window.window
  page.wikiInstallPrompt >>= \case
    Nothing -> pure False
    Just offer -> do
      page.wikiInstallPrompt_set Nothing
      answer <- try @JSError $ do
        offer.prompt >>= wait
        choice <- offer.userChoice >>= wait
        pure (choice.outcome == "accepted")
      told <- Event.newEvent (EventType "wiki-installable") False
      _ <- (coerce page :: EventTarget).dispatchEvent told
      pure (either (const False) identity answer)

-- | An event whenever the browser's offer arrives or goes away
-- ('installAvailable' then says which), from the moment of subscribing.
installChanges :: (MonadBrowserDOM m, MonadUnliftIO m) => m (Emitter IO ())
installChanges = WindowEvent.windowEvent (EventType "wiki-installable") (const (Just ()))

-- | Delete the pages and API responses the service worker stored for this
-- wiki (the caches named @wiki-pages …@ and @wiki-answers …@ for the place
-- the page is served at), which were read as the user who was signed in.
-- Signing out does this. A browser that keeps nothing for the page has no
-- caches, and a refusal to look leaves them as they are.
forgetReads :: (MonadIO m) => m ()
forgetReads = liftIO $ do
  w <- Window.window
  found <- w.caches
  for_ found $ \caches -> void . try @JSError $ do
    base <- w.document.baseURI
    scope <- URL.parse "./" (Just base) >>= traverse URL.href
    names <- caches.keys >>= wait
    for_ (filter (keptHere scope) names) $ \name -> caches.delete name >>= wait
  where
    keptHere scope name =
      ("wiki-pages " `T.isPrefixOf` name || "wiki-answers " `T.isPrefixOf` name)
        && maybe False (\here -> (" " <> here) `T.isSuffixOf` name) scope
