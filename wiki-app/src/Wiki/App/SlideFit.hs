{-# LANGUAGE TemplateHaskell #-}

-- | 'FitWatch' is the measuring of slide cards laid out 1024 CSS pixels
-- wide (@jsbits/slide-fit.js@, WP5.97 of docs/PLAN.md): it scales the
-- cards in an element to the element's width, and measures how far each
-- card's content goes beyond its slide, again whenever the cards change.
-- The editor's preview of a presentation reads the measures; a viewer of
-- one embedded in a page uses the scaling alone.
module Wiki.App.SlideFit
  ( FitWatch
  , watchFits
  , stopFits
  , measureAgain
  )
where

import Halogen.JSBits (Callback, Safety (..), browserJS, freeCallback, inBrowser, jsValText, mkSyncCallback)
import Protolude
-- With its constructor: the FFI passes the value inside the newtype.
import Web.DOM.Internal.Types (Element (..))

$( browserJS
     ["jsbits/slide-fit.js"]
     [ ("js_fit_watch", "wiki_fit_watch", Safe, [t|Element -> Callback -> IO Int|])
     , ("js_fit_stop", "wiki_fit_stop", Safe, [t|Int -> IO ()|])
     , ("js_fit_again", "wiki_fit_again", Safe, [t|Int -> IO ()|])
     ]
 )

-- | A measuring started: its number in @jsbits/slide-fit.js@ and the
-- callback the measures come through, freed when it stops.
data FitWatch = FitWatch Int Callback

-- | Start measuring the cards in an element. Each measure is given to the
-- handler as JSON: for each card, in order, how far its content's bottom
-- is below its body's room and how far it is wider, in lines, or @null@
-- for a card not laid out. Natively there is no browser, and nothing is
-- measured.
watchFits :: (MonadIO m) => Element -> (Text -> IO ()) -> m (Maybe FitWatch)
watchFits element heard
  | inBrowser = liftIO $ do
      callback <- mkSyncCallback (heard . jsValText)
      i <- js_fit_watch element callback
      pure (Just (FitWatch i callback))
  | otherwise = pure Nothing

-- | Stop measuring, and free the callback.
stopFits :: (MonadIO m) => FitWatch -> m ()
stopFits (FitWatch i callback) = liftIO (js_fit_stop i >> freeCallback callback)

-- | Measure again soon: what the last measures were taken for changed,
-- though the cards' layout may not have (a blank line added, the theme's
-- name changed for the same colours), and nothing else would measure.
measureAgain :: (MonadIO m) => FitWatch -> m ()
measureAgain (FitWatch i _) = liftIO (js_fit_again i)
