{-# LANGUAGE TemplateHaskell #-}

-- | The little the shell asks of the browser that Halogen does not say: the
-- link a click in a rendered page landed on, scrolling to a heading or a
-- footnote, and the document's title. See @jsbits/browser.js@. Natively there
-- is no browser: no click lands on a link, and the rest does nothing.
module Wiki.App.Browser
  ( followArticleClick
  , setDocumentTitle
  )
where

import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (decodeComponent)
import Protolude
import Web.Event.Event (Event (..), preventDefault)
import Web.UIEvent.MouseEvent (MouseEvent, toEvent)
import Wiki.App.Route (Route, routeOfHref)

$( browserJS
     ["jsbits/browser.js"]
     [ ("js_clicked_href", "wiki_clicked_href", Unsafe, [t|Event -> IO JSText|])
     , ("js_scroll_to", "wiki_scroll_to", Unsafe, [t|JSText -> IO ()|])
     , ("js_set_title", "wiki_set_title", Unsafe, [t|JSText -> IO ()|])
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
