{-# LANGUAGE TemplateHaskell #-}

-- | The few browser features the shell needs that Halogen does not
-- provide: the link a click in a rendered page landed on, scrolling to a
-- heading or a footnote, the document's title, the position in the
-- session history, the clipboard, and a time written in the reader's time
-- zone and language. Also the demo's zip files: making, reading and saving
-- them (see @jsbits/archive.js@). See @jsbits/browser.js@. Natively there
-- is no browser: no click lands on a link, every history entry is the
-- first, nothing is copied, and the rest does nothing.
module Wiki.App.Browser
  ( ArticleLink (..)
  , articleLink
  , followArticleLink
  , setDocumentTitle
  , historyEntry
  , historyGo
  , copyText
  , absoluteUrl
  , zipFiles
  , unzipFiles
  , download
  , localTime
  , consoleWarn
  , keepHeights
  , keepContents
  , revealFragment
  , PageBackend (..)
  , pageBackend

    -- * Comments
  , Selected (..)
  , readSelection
  , clickedThread
  , reveal
  )
where

import Data.Aeson (FromJSON (..), decodeStrict', withObject, (.:))
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
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Id (CommentThreadId (..))

-- Copying waits for the browser's clipboard, so that binding is a safe
-- import, which waits for the promise; the rest return at once. The link a
-- click landed on is read in the click's listener, while the browser
-- dispatches it, and the click does not change meanwhile, so that binding
-- is pure.
$( browserJS
     ["jsbits/browser.js", "jsbits/archive.js", "jsbits/comments.js", "jsbits/layout.js", "jsbits/toc.js"]
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
     , ("js_page_backend", "wiki_page_backend", Unsafe, [t|IO JSText|])
     , ("js_console_warn", "wiki_console_warn", Unsafe, [t|JSText -> IO ()|])
     , ("js_absolute_url", "wiki_absolute_url", Unsafe, [t|JSText -> IO JSText|])
     , ("js_comment_selection", "wiki_comment_selection", Unsafe, [t|Element -> IO JSText|])
     , ("js_clicked_thread", "wiki_clicked_thread", Unsafe, [t|Event -> JSText|])
     , ("js_reveal", "wiki_reveal", Unsafe, [t|JSText -> IO ()|])
     , ("js_keep_heights", "wiki_keep_heights", Unsafe, [t|IO ()|])
     , ("js_keep_contents", "wiki_keep_contents", Unsafe, [t|IO ()|])
     , ("js_reveal_fragment", "wiki_reveal_fragment", Unsafe, [t|IO ()|])
     ]
 )

-- | Where a click on a link leads, in HTML the application did not build
-- element by element (a page's Markdown, rendered by
-- "Wiki.Core.Markdown"), when the application should follow it rather
-- than the browser.
data ArticleLink
  = -- | One of the router's own addresses, followed without loading a page.
    ToRoute Route
  | -- | A place on the page (@#fn-1@), by its id. Without this, the page's
    -- @\<base href>@ would send the browser to the base address.
    ToFragment Text

-- | Which of the application's links a click landed on, given an element
-- around them, if any. 'Nothing' for anything the browser follows itself
-- (a link elsewhere, a download, a click with a modifier key, no link at
-- all).
--
-- It is pure so that a click's handler decides inside the listener, while
-- the browser dispatches the click and can still be stopped from following
-- the link ('Halogen.HTML.Events.preventingDefault'). Asked later, from the
-- component's action, the browser may have followed it already. The
-- answer is read from the click as it is at that moment, so the listener
-- forces it, which deciding between 'Nothing' and 'Just' does.
articleLink :: Router Route -> Event -> Maybe ArticleLink
articleLink router event = case (routeOfHref router href, T.stripPrefix "#" href) of
  _ | T.null href -> Nothing
  (Just r, _) -> Just (ToRoute r)
  (Nothing, Just fragment) -> Just (ToFragment (decodeComponent fragment))
  (Nothing, Nothing) -> Nothing
  where
    href = fromJSText (js_clicked_href event)

-- | Follow a link 'articleLink' found: through the router, or by scrolling
-- to the place on the page. Preventing the click's default is the
-- listener's job.
followArticleLink :: (MonadIO m) => Router Route -> ArticleLink -> m ()
followArticleLink router = \case
  ToRoute r -> Router.navigate router r
  ToFragment fragment -> liftIO (js_scroll_to (toJSText fragment))

-- | Set the title of the browser's tab and of its history entry.
setDocumentTitle :: (MonadIO m) => Text -> m ()
setDocumentTitle = liftIO . js_set_title . toJSText

-- | The number of the session history's current entry. The entries the
-- shell has seen are numbered in order, so that 'historyGo' can return to
-- one. The router keeps no such number, nor any state of its own in the
-- entry. Natively always 0.
historyEntry :: (MonadIO m) => m Int
historyEntry = liftIO js_history_entry

-- | Go this many entries forward in the session history (back, if
-- negative), as the browser's buttons do: the router receives it as it
-- receives them.
historyGo :: (MonadIO m) => Int -> m ()
historyGo = liftIO . js_history_go

-- | Put text on the clipboard, given the element that shows it, and say
-- whether it worked. If the browser will not copy it, the element's text
-- is left selected, for the reader to copy with the keyboard. This waits
-- for the browser, so a component calls it off its loop ('liftIO' in
-- 'Halogen.HalogenM', not 'Halogen.liftEffect'). Natively nothing is
-- copied.
copyText :: (MonadIO m) => Element -> Text -> m Bool
copyText element text =
  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced.
  liftIO (evaluate =<< js_copy_text element (toJSText text))

-- | An application address (as 'Router.href' writes it) as a full URL,
-- with the scheme and host the page was loaded from: what a link sent in
-- a mail or a message needs. Natively there is no page, and the address
-- is returned unchanged.
absoluteUrl :: (MonadIO m) => Text -> m Text
absoluteUrl path
  | not inBrowser = pure path
  | otherwise = liftIO (fromJSText <$> js_absolute_url (toJSText path))

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

-- | Give bytes to the browser to save as a file with this name and media
-- type. Natively nothing is saved.
download :: (MonadIO m) => Text -> Text -> ByteString -> m ()
download name mediaType bytes = liftIO . when inBrowser $ js_download (toJSText name) (toJSText mediaType) =<< toJSBytes bytes

-- | A time as the reader reads it: in their time zone, written the way
-- their browser's language writes a date and a time. Natively, where there
-- is no reader, in UTC, saying so.
localTime :: (MonadIO m) => UTCTime -> m Text
localTime t
  | inBrowser = liftIO (fromJSText <$> js_local_time (realToFrac (utcTimeToPOSIXSeconds t) * 1000))
  | otherwise = pure (toS (formatTime defaultTimeLocale "%-d %B %Y, %H:%M UTC" t))

-- | A warning on the browser's console, for whoever looks there, about
-- something the program carried on without. Natively nothing.
consoleWarn :: (MonadIO m) => Text -> m ()
consoleWarn message = when inBrowser (liftIO (js_console_warn (toJSText message)))

-- | Which backend the page says to use: the in-memory one, which keeps
-- the wiki in the browser like the demo, or the HTTP one, which talks to
-- the server that served the page.
data PageBackend = DemoBackend | ServerBackend
  deriving stock (Eq, Show)

-- | What the page's @\<meta name="wiki-backend">@ says: @server@ for the
-- server's build (written by @wiki-app-prerender --server@), and anything
-- else, or nothing, for the demo, which is what a page from before there
-- was a choice means. Natively, the demo.
pageBackend :: (MonadIO m) => m PageBackend
pageBackend = liftIO $ (\b -> if fromJSText b == "server" then ServerBackend else DemoBackend) <$> js_page_backend

--------------------------------------------------------------------------------
-- Comments

-- | Text the reader has selected in a page, as the anchor of a comment
-- about it ("Wiki.Core.Anchor"), and where a button to comment on it can
-- go, under the selection: in pixels from the top left corner of the
-- element the page's article is in.
data Selected = Selected
  { anchor :: Anchor
  , top :: Double
  , left :: Double
  }
  deriving stock (Eq, Show)

instance FromJSON Selected where
  parseJSON = withObject "Selected" $ \o ->
    Selected <$> (Anchor <$> o .: "exact" <*> o .: "prefix" <*> o .: "suffix") <*> o .: "top" <*> o .: "left"

-- | What the reader has selected of the article inside this element, read
-- as "Wiki.Core.Anchor" reads the page's text (see jsbits/comments.js), if
-- anything is selected; natively, nothing.
readSelection :: (MonadIO m) => Element -> m (Maybe Selected)
readSelection element
  | not inBrowser = pure Nothing
  | otherwise = liftIO $ decodeStrict' . encodeUtf8 . fromJSText <$> js_comment_selection element

-- | The thread whose highlighted quote a click landed on, if any: what
-- the page checks in the click's listener.
clickedThread :: Event -> Maybe CommentThreadId
clickedThread event = case fromJSText (js_clicked_thread event) of
  "" -> Nothing
  thread -> Just (CommentThreadId thread)

-- | Scroll what a CSS selector picks into view, if it is not in view.
reveal :: (MonadIO m) => Text -> m ()
reveal selector = when inBrowser (liftIO (js_reveal (toJSText selector)))

-- | Keep the heights of the sticky header and of the page's action bar as
-- CSS variables, which the stylesheet uses to stack the bar, the editor's
-- toolbar and the comments panel under the header, and mark a bar that is
-- stuck under the header (see @jsbits/layout.js@). Calling it once is
-- enough: it follows the document from then on. Natively there is no
-- layout, and it does nothing.
keepHeights :: (MonadIO m) => m ()
keepHeights = liftIO js_keep_heights

-- | Highlight the section being read in the page's lists of its headings,
-- and remember in this browser whether its "Contents" panel is folded (see
-- @jsbits/toc.js@). Calling it once is enough, as for 'keepHeights'.
-- Natively there is nothing to read, and it does nothing.
keepContents :: (MonadIO m) => m ()
keepContents = liftIO js_keep_contents

-- | Scroll to the heading the address's fragment names, if it is shown:
-- what the browser does in a page it loaded, for a page the program
-- renders. Natively nothing.
revealFragment :: (MonadIO m) => m ()
revealFragment = liftIO js_reveal_fragment
