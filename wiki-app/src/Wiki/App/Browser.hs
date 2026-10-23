{-# LANGUAGE TemplateHaskell #-}

-- | The little the shell asks of the browser that Halogen does not say: the
-- link a click in a rendered page landed on, scrolling to a heading or a
-- footnote, the document's title, where in the session history it is, the
-- clipboard, and a time as the reader's clock and language write it; and the demo's zip files, made, read and saved (see
-- @jsbits/archive.js@). See @jsbits/browser.js@. Natively there is no browser: no
-- click lands on a link, every entry of the history is the first, nothing is
-- copied, and the rest does nothing.
module Wiki.App.Browser
  ( ArticleLink (..)
  , articleLink
  , followArticleLink
  , setDocumentTitle
  , historyEntry
  , historyGo
  , copyText
  , zipFiles
  , unzipFiles
  , download
  , localTime
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Halogen.JSBits (JSText, JSVal, Safety (..), browserJS, fromJSBytes, fromJSText, inBrowser, toJSBytes, toJSText)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (decodeComponent)
import Protolude
-- With its constructor: the FFI passes the value inside the newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..))
import Wiki.App.Route (Route, routeOfHref)

-- Copying waits for the browser's clipboard, so that binding is a safe
-- import, which waits for the promise; the rest return on the spot. The link
-- a click landed on is read in the click's listener, while the browser
-- dispatches it, and the click does not change meanwhile, so that binding is
-- pure.
$( browserJS
     ["jsbits/browser.js", "jsbits/archive.js"]
     [ ("js_clicked_href", "wiki_clicked_href", Unsafe, [t|Event -> JSText|])
     , ("js_scroll_to", "wiki_scroll_to", Unsafe, [t|JSText -> IO ()|])
     , ("js_set_title", "wiki_set_title", Unsafe, [t|JSText -> IO ()|])
     , ("js_history_entry", "wiki_history_entry", Unsafe, [t|IO Int|])
     , ("js_history_go", "wiki_history_go", Unsafe, [t|Int -> IO ()|])
     , ("js_copy_text", "wiki_copy_text", Safe, [t|Element -> JSText -> IO Bool|])
     , ("js_archive_new", "wiki_archive_new", Unsafe, [t|IO JSVal|])
     , ("js_archive_add", "wiki_archive_add", Unsafe, [t|JSVal -> JSText -> JSVal -> IO ()|])
     , ("js_archive_zip", "wiki_archive_zip", Unsafe, [t|JSVal -> IO JSVal|])
     , ("js_archive_unzip", "wiki_archive_unzip", Unsafe, [t|JSVal -> IO JSVal|])
     , ("js_archive_error", "wiki_archive_error", Unsafe, [t|JSVal -> IO JSText|])
     , ("js_archive_count", "wiki_archive_count", Unsafe, [t|JSVal -> IO Int|])
     , ("js_archive_path", "wiki_archive_path", Unsafe, [t|JSVal -> Int -> IO JSText|])
     , ("js_archive_bytes", "wiki_archive_bytes", Unsafe, [t|JSVal -> Int -> IO JSVal|])
     , ("js_download", "wiki_download", Unsafe, [t|JSText -> JSText -> JSVal -> IO ()|])
     , ("js_local_time", "wiki_local_time", Unsafe, [t|Double -> IO JSText|])
     ]
 )

-- | Where a click on a link in HTML the application did not build link by
-- link (a page's Markdown, rendered by "Wiki.Core.Markdown") leads, when it
-- is the application's to follow rather than the browser's.
data ArticleLink
  = -- | One of the router's own addresses, followed without loading a page.
    ToRoute Route
  | -- | A place on the page (@#fn-1@), by its id: the page's @\<base href>@
    -- would otherwise send the browser to the base.
    ToFragment Text

-- | Which of the application's links a click on an element around them
-- landed on, if any: 'Nothing' for anything the browser follows itself (a
-- link elsewhere, a download, a click with a modifier, no link at all).
--
-- Pure, so that a click's handler decides in the listener, while the
-- browser dispatches the click and can still be kept from following the
-- link ('Halogen.HTML.Events.preventingDefault'): asked later, from the
-- component's action, the browser may have followed it already. The answer
-- is read from the click as it is then, so the listener forces it, which
-- deciding between 'Nothing' and 'Just' does.
articleLink :: Router Route -> Event -> Maybe ArticleLink
articleLink router event = case (routeOfHref router href, T.stripPrefix "#" href) of
  _ | T.null href -> Nothing
  (Just r, _) -> Just (ToRoute r)
  (Nothing, Just fragment) -> Just (ToFragment (decodeComponent fragment))
  (Nothing, Nothing) -> Nothing
  where
    href = fromJSText (js_clicked_href event)

-- | Follow a link 'articleLink' found: by the router, or by scrolling to the
-- place on the page. The click's default is the listener's to prevent.
followArticleLink :: (MonadIO m) => Router Route -> ArticleLink -> m ()
followArticleLink router = \case
  ToRoute r -> Router.navigate router r
  ToFragment fragment -> liftIO (js_scroll_to (toJSText fragment))

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

-- | A zip file of these files, by path. Natively there is no zip here, and
-- the file is empty: the native programs zip with @zip-archive@.
zipFiles :: (MonadIO m) => [(Text, ByteString)] -> m ByteString
zipFiles files
  | not inBrowser = pure mempty
  | otherwise = liftIO $ do
      archive <- js_archive_new
      for_ files $ \(path, bytes) -> js_archive_add archive (toJSText path) =<< toJSBytes bytes
      fromJSBytes =<< js_archive_zip archive

-- | The files a zip file holds, by path, or why it cannot be read.
unzipFiles :: (MonadIO m) => ByteString -> m (Either Text (Map Text ByteString))
unzipFiles bytes
  | not inBrowser = pure (Left "there is no zip natively")
  | otherwise = liftIO $ do
      unzipped <- js_archive_unzip =<< toJSBytes bytes
      fromJSText <$> js_archive_error unzipped >>= \case
        "" -> do
          n <- js_archive_count unzipped
          fmap (Right . Map.fromList) . for [0 .. n - 1] $ \i ->
            (,) <$> (fromJSText <$> js_archive_path unzipped i) <*> (fromJSBytes =<< js_archive_bytes unzipped i)
        why -> pure (Left why)

-- | Hand bytes to the browser to save as a file of this name and media
-- type. Natively nothing is saved.
download :: (MonadIO m) => Text -> Text -> ByteString -> m ()
download name mediaType bytes = liftIO . when inBrowser $ js_download (toJSText name) (toJSText mediaType) =<< toJSBytes bytes

-- | A time as the reader reads one: in their time zone, written the way
-- their browser's language writes a date and a time. Natively, where there
-- is no reader, in UTC, and saying so.
localTime :: (MonadIO m) => UTCTime -> m Text
localTime t
  | inBrowser = liftIO (fromJSText <$> js_local_time (realToFrac (utcTimeToPOSIXSeconds t) * 1000))
  | otherwise = pure (toS (formatTime defaultTimeLocale "%-d %B %Y, %H:%M UTC" t))
