{-# LANGUAGE TemplateHaskell #-}

-- | The little the shell asks of the browser that Halogen does not say: the
-- link a click in a rendered page landed on, scrolling to a heading or a
-- footnote, the document's title, where in the session history it is, and
-- the clipboard. See @jsbits/browser.js@. Natively there is no browser: no
-- click lands on a link, every entry of the history is the first, nothing is
-- copied, and the rest does nothing.
module Wiki.App.Browser
  ( followArticleClick
  , setDocumentTitle
  , historyEntry
  , historyGo
  , copyText
  )
where

import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (decodeComponent)
import Protolude
-- With its constructor: the FFI passes the value inside the newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..), preventDefault)
import Web.UIEvent.MouseEvent (MouseEvent, toEvent)
import Wiki.App.Route (Route, routeOfHref)

-- Copying waits for the browser's clipboard, so that binding is a safe
-- import, which waits for the promise; the rest return on the spot.
$( browserJS
     ["jsbits/browser.js"]
     [ ("js_clicked_href", "wiki_clicked_href", Unsafe, [t|Event -> IO JSText|])
     , ("js_scroll_to", "wiki_scroll_to", Unsafe, [t|JSText -> IO ()|])
     , ("js_set_title", "wiki_set_title", Unsafe, [t|JSText -> IO ()|])
     , ("js_history_entry", "wiki_history_entry", Unsafe, [t|IO Int|])
     , ("js_history_go", "wiki_history_go", Unsafe, [t|Int -> IO ()|])
     , ("js_copy_text", "wiki_copy_text", Safe, [t|Element -> JSText -> IO Bool|])
     ]
 )

-- | Follow a click on a link in HTML the application did not build link by
-- link (a page's Markdown, rendered by "Wiki.Core.Markdown"), given the
-- click on an element around it: a link to one of the router's own addresses
-- is followed by the router, without loading a page; a link to a place on
-- the page (@#fn-1@) scrolls there, since the page's @\<base href>@ would
-- otherwise send it to the base; anything else is left to the browser.
--
-- To be run in 'Halogen.liftEffect', since the browser follows the link as
-- soon as the handler returns.
followArticleClick :: (MonadIO m) => Router Route -> MouseEvent -> m ()
followArticleClick router click = liftIO $ do
  href <- fromJSText <$> js_clicked_href event
  case (routeOfHref router href, T.stripPrefix "#" href) of
    _ | T.null href -> pass
    (Just r, _) -> preventDefault event >> Router.navigate router r
    (Nothing, Just fragment) -> preventDefault event >> js_scroll_to (toJSText (decodeComponent fragment))
    (Nothing, Nothing) -> pass
  where
    event = toEvent click

-- | Title the browser's tab and its history entry.
setDocumentTitle :: (MonadIO m) => Text -> m ()
setDocumentTitle = liftIO . js_set_title . toJSText

-- | The number of the session history's current entry: entries the shell
-- has seen are numbered in order, so that 'historyGo' can return to one.
-- The router keeps no such number, nor any state of its own in the entry.
-- Natively 0, always.
historyEntry :: (MonadIO m) => m Int
historyEntry = liftIO js_history_entry

-- | Go this many entries forward in the session history (back, if
-- negative), as the browser's buttons do: the router hears it as it hears
-- them.
historyGo :: (MonadIO m) => Int -> m ()
historyGo = liftIO . js_history_go

-- | Put text on the clipboard, given the element that shows it, and say
-- whether it is there. If the browser will not copy it, the element's text
-- is left selected, for the reader to copy with the keyboard. This waits for
-- the browser, so a component calls it off its loop ('liftIO' in
-- 'Halogen.HalogenM', not 'Halogen.liftEffect'). Natively nothing is copied.
copyText :: (MonadIO m) => Element -> Text -> m Bool
copyText element text =
  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced.
  liftIO (evaluate =<< js_copy_text element (toJSText text))
