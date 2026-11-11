{-# LANGUAGE TemplateHaskell #-}

-- | The few browser features the shell needs that Halogen does not
-- provide: the link a click in a rendered page landed on, scrolling to a
-- heading or a footnote, the document's title and favicon, the position in
-- the session history, the clipboard, a modal dialog, a file saved or
-- opened in a tab, and a
-- time written in the reader's time zone and language. They are read and
-- called through the Web types' fields ("Web.HTML.Window" and the rest);
-- only the demo's zip files (making and reading them, @jsbits/archive.js@),
-- the reader's selection in a page (@jsbits/comments.js@) and what follows
-- the page's layout (@jsbits/layout.js@, @jsbits/toc.js@) have JavaScript
-- of their own. Natively there is no browser: no click lands on a link,
-- every history entry is the first, nothing is copied, no dialog is shown,
-- and the rest does nothing.
module Wiki.App.Browser
  ( ArticleLink (..)
  , articleLink
  , followArticleLink
  , markFragment
  , redirectKeepingFragment
  , setDocumentTitle
  , setFavicon
  , EntryState (..)
  , readEntryState
  , writeEntryState
  , historyEntry
  , historyGo
  , replacingEntry
  , pushPreviewEntry
  , onPreviewEntry
  , forgetPreviewEntry
  , historyBack
  , copyText
  , absoluteUrl
  , zipFiles
  , unzipFiles
  , download
  , openInTab
  , localTime
  , consoleWarn
  , keepHeights
  , keepContents
  , revealFragment
  , showDialog
  , closeDialog
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
import Data.Foreign (foreignToBool, foreignToInt, stringToForeign)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.MediaType (MediaType (..))
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Halogen.JSBits (Inert, JSText, JSVal, Safety (..), browserJS, fromJSBytes, fromJSText, inBrowser, isNull, jsValText, toJSBytes, toJSText)
import Halogen.JSBits.Fields (Member (..), inlineJS, jsFields)
import Halogen.JSBits.Promise (JSError, waitCatch)
import Halogen.Router (Router)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (decodeComponent, encodeComponent)
import Protolude hiding (waitCatch)
import System.IO.Unsafe (unsafePerformIO)
import Web.DOM.Element qualified as Element
-- With their constructors: the FFI passes the value inside a newtype.
import Web.DOM.Internal.Types (Element (..), toNode)
import Web.Event.Event (Event (..))
import Web.Event.Event qualified as Event
import Web.File.Blob qualified as Blob
import Web.HTML.HTMLDialogElement qualified as HTMLDialogElement
import Web.HTML.HTMLElement qualified as HTMLElement
import Web.HTML.HTMLInputElement qualified as HTMLInputElement
import Web.HTML.Window qualified as Window
import Web.UIEvent.MouseEvent (MouseEvent (..))
import Web.URL qualified as URL
import Wiki.App.Route (Route, routeOfHref)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Id (CommentThreadId (..))

-- The zip files are the page's archive library's (archive.js), the
-- reader's selection is read as "Wiki.Core.Anchor" reads a page
-- (comments.js), and the heights and the contents follow the page's layout
-- (layout.js, toc.js): logic of their own, which stays JavaScript.
$( browserJS
     ["jsbits/archive.js", "jsbits/comments.js", "jsbits/layout.js", "jsbits/toc.js"]
     [ ("js_archive_new", "wiki_archive_new", Safe, [t|IO JSVal|])
     , ("js_archive_add", "wiki_archive_add", Safe, [t|JSVal -> JSText -> JSVal -> IO ()|])
     , ("js_archive_zip", "wiki_archive_zip", Safe, [t|JSVal -> IO JSVal|])
     , ("js_archive_unzip", "wiki_archive_unzip", Safe, [t|JSVal -> IO JSVal|])
     , ("js_archive_error", "wiki_archive_error", Safe, [t|JSVal -> IO JSText|])
     , ("js_archive_count", "wiki_archive_count", Safe, [t|JSVal -> IO Int|])
     , ("js_archive_path", "wiki_archive_path", Safe, [t|JSVal -> Int -> IO JSText|])
     , ("js_archive_bytes", "wiki_archive_bytes", Safe, [t|JSVal -> Int -> IO JSVal|])
     , ("js_comment_selection", "wiki_comment_selection", Safe, [t|Element -> IO JSText|])
     , ("js_keep_heights", "wiki_keep_heights", Safe, [t|IO ()|])
     , ("js_keep_contents", "wiki_keep_contents", Safe, [t|IO ()|])
     , ("js_reveal_fragment", "wiki_reveal_fragment", Safe, [t|IO ()|])
     ]
 )

-- A new tab at an address, and whether the browser opened it:
-- @window.open@ answers @null@ when it blocked the tab. The window's Web
-- type has no @open@ field.
$(inlineJS "js_open_tab" "window.open($1, \"_blank\") !== null" [t|JSText -> IO Bool|])

-- A time written as the reader's language writes a date and a time, in
-- their time zone: the one call with an options object, which no field
-- takes.
$(inlineJS "js_local_time" "new Date($1).toLocaleString(undefined, { dateStyle: \"medium\", timeStyle: \"short\" })" [t|Double -> IO JSText|])

-- | An entry's state as the versions before WP5.47 wrote it: an object
-- with the number as @wikiEntry@ and the preview's mark as @wikiPreview@.
-- A tab open across the deployment still has such entries in its session
-- history, and they are read so that they keep their numbers, which
-- 'historyGo' counts by. The text written now has neither member.
newtype PreviousEntry = PreviousEntry JSVal
  deriving newtype (Inert)

$( jsFields
     ''PreviousEntry
     [ Fixed "wikiEntry" [t|Maybe JSVal|]
     , Fixed "wikiPreview" [t|Maybe JSVal|]
     ]
 )

-- | Where a click on a link leads, in HTML the application did not build
-- element by element (a page's Markdown, rendered by
-- "Wiki.Core.Markdown"), when the application should follow it rather
-- than the browser.
data ArticleLink
  = -- | One of the router's own addresses, followed without loading a
    -- page, and the fragment the link names there (with its @#@, or
    -- empty), which the address keeps once there ('keepFragment').
    ToRoute Route Text
  | -- | A place on the page (@#intro@), by its id. Without this, the
    -- page's @\<base href>@ would send the browser to the base address.
    ToFragment Text
  | -- | A footnote, from a reference to it: the note's id (@fn-1@) and the
    -- reference's own (@fnref-1@), which the browser's Back returns to.
    ToNote Text Text
  | -- | The @#@ a heading or a box's title ends with
    -- ("Wiki.Core.Markdown.Render"), by the id it links to. The page view
    -- copies the section's address to the clipboard instead of following
    -- it ("Wiki.App.View.Page"); anywhere else, it is followed as a
    -- 'ToFragment' is.
    CopyAnchor Text

-- | Which of the application's links a click landed on, given an element
-- around them, if any. 'Nothing' for anything the browser follows itself
-- (a link elsewhere, a download, a click with a modifier key, no link at
-- all).
--
-- It is pure so that a click's handler decides inside the listener, while
-- the browser dispatches the click and can still be stopped from following
-- the link ('Halogen.HTML.Events.preventingDefault'). Asked later, from the
-- component's action, the browser may have followed it already. The
-- answer is read from the click as it is at that moment
-- ('Element.closestNow'), so the listener forces it, which deciding
-- between 'Nothing' and 'Just' does.
articleLink :: Router Route -> Event -> Maybe ArticleLink
articleLink router event = do
  anchor <- clickedLink event
  let href = fromMaybe "" (Element.getAttributeNow anchor "href")
  guard (not (T.null href))
  case (routeOfHref router href, T.stripPrefix "#" href) of
    (Just r, _) -> Just (ToRoute r (fragmentAfter r href))
    (Nothing, Just fragment)
      | isJust (Element.closestNow anchor "a.heading-anchor") -> Just (CopyAnchor (decodeComponent fragment))
      | otherwise -> case noteReference anchor of
          Just reference -> Just (ToNote (decodeComponent fragment) reference)
          Nothing -> Just (ToFragment (decodeComponent fragment))
    (Nothing, Nothing) -> Nothing
  where
    -- The fragment written after the route's own address, if any.
    fragmentAfter r href = case T.stripPrefix (Router.href router r) href of
      Just rest | "#" `T.isPrefixOf` rest -> rest
      _ -> ""
    -- A footnote's reference is the link's own id (@fnref-1@, or
    -- @fnref-1-2@ for the second reference to the note). The renderer
    -- writes the class @footnote-ref@ on references only, so the link is
    -- taken by it and not by its target's name: on "What's new?" every id
    -- starts with its entry's prefix (@#pr-158-fn-1@).
    noteReference anchor = do
      _ <- Element.closestNow anchor "sup.footnote-ref > a"
      mfilter (not . T.null) (Element.getAttributeNow anchor "id")

-- | The link a plain click landed on: the main button with no modifier
-- key, on a link that opens in its own tab and is not a download. Read as
-- the click is dispatched, purely, as 'articleLink' is.
clickedLink :: Event -> Maybe Element
clickedLink event = do
  let click = MouseEvent event
  guard (not (Event.defaultPreventedNow event) && click.button == 0)
  guard (not (click.metaKey || click.ctrlKey || click.shiftKey || click.altKey))
  target <- Event.target event >>= Element.fromEventTarget
  anchor <- Element.closestNow target "a[href]"
  guard (isNothing (Element.getAttributeNow anchor "download"))
  guard (maybe True (`elem` ["", "_self"]) (Element.getAttributeNow anchor "target"))
  pure anchor

-- | Follow a link 'articleLink' found: through the router, or by scrolling
-- to the place on the page. A footnote's reference also adds an entry to
-- the session history, as a link to a place on an ordinary page does, so
-- that the browser's Back returns to the reference (issue #120): the entry
-- left gets the reference's address (@#fnref-1@), and the shell scrolls
-- to the place an address names when Back or Forward arrives at an entry
-- of the page it shows ('revealFragment'). Preventing the click's default
-- is the listener's job.
--
-- A link to a route with a fragment (@\/l\/17\/#setup@,
-- @\/s\/docs\/p\/guide\/#setup@) keeps the fragment in the address it
-- goes to, since the router writes the route's address alone: the page
-- shown scrolls to it once loaded ('revealFragment', in the page view's
-- start and when it is given another page), and a permanent address passes
-- it on to the page's own ('redirectKeepingFragment'). A link to a place
-- on the page shown is scrolled to at once.
followArticleLink :: (MonadIO m) => Router Route -> ArticleLink -> m ()
followArticleLink router = \case
  ToRoute r fragment -> liftIO $ do
    -- A place on the page shown, by its full address: scrolled to, as a
    -- link to @#place@ is, since the router goes nowhere for the route
    -- the page is at already.
    now <- Router.current router
    if now == r && T.length fragment > 1
      then scrollTo (decodeComponent (T.drop 1 fragment))
      else Router.navigate router r >> keepFragment fragment
  ToFragment fragment -> liftIO (scrollTo fragment)
  CopyAnchor fragment -> liftIO (scrollTo fragment)
  ToNote footnote reference -> liftIO (followNote footnote reference)

-- Scroll to an element of the page by its id, as following a link to
-- @#id@ would, and put @#id@ in the address bar, so that the address shown
-- is the place's, to copy and pass on. The entry is replaced rather than a
-- new one pushed (the router hears nothing of it, and Back leaves the
-- page), with its state kept ('historyEntry''s number); the address is
-- written out from the path, since a bare @#id@ would be read against the
-- page's @\<base href>@. Under a router that keeps the route in the
-- fragment (@#/s/...@, the browser tests'), the fragment is the router's,
-- and is left.
scrollTo :: Text -> IO ()
scrollTo place = do
  w <- Window.window
  found <- w.document.getElementById place
  for_ found $ \element -> do
    element.scrollIntoView
    markFragment place

-- | Put @#id@ in the address bar, as 'scrollTo' does, without scrolling:
-- what a click on a heading's @#@ does besides copying the section's
-- address, so that the address shown is the section's too. Natively
-- nothing.
markFragment :: (MonadIO m) => Text -> m ()
markFragment place = when inBrowser . liftIO $ do
  w <- Window.window
  fragment <- w.location.hash
  unless ("#/" `T.isPrefixOf` fragment) $ do
    kept <- w.history.state
    here <- (<>) <$> w.location.pathname <*> w.location.search
    w.history.replaceState kept "" (Just (here <> "#" <> encodeComponent place))

-- | Go to a route in place of the address the page is at
-- ('Router.redirect'), keeping the entry's number ('replacingEntry')
-- and the address's fragment: a page's
-- permanent address (@\/l\/17\/#setup@) becomes the page's own
-- (@\/s\/docs\/p\/guide\/#setup@), and the page scrolls to the place
-- once shown ('revealFragment'). The router writes the route's address
-- without a fragment, so the fragment is put back after, in the same
-- history entry, with its state kept. Under a router that keeps the route
-- in the fragment (@#/l/17/@, the browser tests'), there is no fragment of
-- the page's own to keep. Natively the route alone is gone to.
redirectKeepingFragment :: (MonadIO m) => Router Route -> Route -> m ()
redirectKeepingFragment router r = liftIO $ do
  fragment <- if inBrowser then Window.window >>= \w -> w.location.hash else pure ""
  -- The router writes no state into the entry it replaces: the entry's
  -- number, which 'historyGo' counts the history by, is written back.
  replacingEntry (Router.redirect router r)
  keepFragment fragment

-- | Put a fragment (@#setup@) on the address the page is at now, in the
-- same history entry, with its state kept: after the router has gone to a
-- route, whose address it writes without one. Nothing for an empty
-- fragment, and nothing under a router that keeps the route in the
-- fragment (@#\/s\/…@, the browser tests'), where the fragment is the
-- router's. Natively nothing.
keepFragment :: Text -> IO ()
keepFragment fragment = when (inBrowser && T.length fragment > 1 && not ("#/" `T.isPrefixOf` fragment)) $ do
  w <- Window.window
  now <- w.location.hash
  unless ("#/" `T.isPrefixOf` now) $ do
    kept <- w.history.state
    here <- (<>) <$> w.location.pathname <*> w.location.search
    w.history.replaceState kept "" (Just (here <> fragment))

-- Go from a footnote's reference to its note, as following a link to
-- @#fn-1@ on an ordinary page does: a new entry in the session history, so
-- that the browser's Back returns to the reference. The entry left gets
-- the reference's own address (@#fnref-1@), which is where Back returns:
-- the shell scrolls to what an address names when it arrives at an entry
-- of the page it shows ('revealFragment'). The new entry is numbered as
-- 'historyEntry' numbers entries, the one after the entry left, and the
-- router hears nothing of it, as of a push of its own. Under a router that
-- keeps the route in the fragment (the browser tests'), the fragment is
-- the router's, and the note is only scrolled to; so it is in the editor's
-- preview, whose own entry ('pushPreviewEntry') "Back to edit" goes back
-- from, one entry, which a note's entry on top of it would take.
followNote :: Text -> Text -> IO ()
followNote footnote reference = do
  w <- Window.window
  found <- w.document.getElementById footnote
  for_ found $ \element -> do
    fragment <- w.location.hash
    inPreview <- onPreviewEntry
    unless ("#/" `T.isPrefixOf` fragment || inPreview) $ do
      here <- (<>) <$> w.location.pathname <*> w.location.search
      entry <- historyEntry
      unless (T.null reference) $ do
        kept <- w.history.state
        w.history.replaceState kept "" (Just (here <> "#" <> encodeComponent reference))
      w.history.pushState (writeEntryState EntryState {number = Just (entry + 1), preview = False}) "" (Just (here <> "#" <> encodeComponent footnote))
      writeIORef lastEntry (entry + 1)
    element.scrollIntoView

-- | Show a @\<dialog>@ element as a modal dialog (@showModal@): above the
-- page, with a backdrop, the rest of the page inert, closed by Escape, and
-- the focus given back to where it was when the dialog closes. The element
-- then fires @close@. Natively nothing happens.
showDialog :: (MonadIO m) => Element -> m ()
showDialog element = liftIO $ for_ (HTMLDialogElement.fromElement element) $ \dialog -> unlessM dialog.open dialog.showModal

-- | Close a dialog 'showDialog' showed. It fires @close@.
closeDialog :: (MonadIO m) => Element -> m ()
closeDialog element = liftIO $ for_ (HTMLDialogElement.fromElement element) $ \dialog -> whenM dialog.open dialog.close

-- | Set the title of the browser's tab and of its history entry.
setDocumentTitle :: (MonadIO m) => Text -> m ()
setDocumentTitle title = liftIO $ Window.window >>= \w -> w.document.title_set title

-- | Set the favicon of the browser's tab ("Wiki.App.Favicon"): the page's
-- @\<link rel="icon">@, given its address and its media type. The link is
-- changed only when its address or type differ, so that the browser does
-- not fetch the same icon again at every route. Natively nothing happens.
setFavicon :: (MonadIO m) => Text -> Text -> m ()
setFavicon href mediaType = liftIO $ do
  w <- Window.window
  found <- w.document.querySelector "link[rel~=\"icon\"]"
  iconLink <- case found of
    Just iconLink -> pure iconLink
    Nothing -> do
      iconLink <- w.document.createElement "link"
      iconLink.setAttribute "rel" "icon"
      _ <- (HTMLElement.toElement w.document.head).appendChild (toNode iconLink)
      pure iconLink
  for_ [("href", href), ("type", mediaType)] $ \(name, value) -> do
    current <- iconLink.getAttribute name
    when (current /= Just value) (iconLink.setAttribute name value)

-- | What the shell keeps in an entry of the session history, as the
-- entry's state: the entry's number ('historyEntry'), and whether the
-- entry is the editor's preview's ('pushPreviewEntry'). It is written as
-- text, @"12"@, @"12+preview"@, or @"+preview"@ for an entry not yet
-- numbered, since the history keeps a string as it is. An entry nobody
-- wrote to has @null@: the router's own pushes write no state.
data EntryState = EntryState
  { number :: Maybe Int
  , preview :: Bool
  }
  deriving (Eq, Show)

readEntryState :: JSVal -> EntryState
readEntryState value
  | isNull value = EntryState {number = Nothing, preview = False}
  | Just number <- previous.wikiEntry = EntryState {number = Just (foreignToInt number), preview = marked}
  | marked = EntryState {number = Nothing, preview = True}
  | otherwise =
      let (digits, rest) = T.span isDigit (jsValText value)
       in EntryState {number = readMaybe digits, preview = rest == "+preview"}
  where
    previous = PreviousEntry value
    marked = maybe False foreignToBool previous.wikiPreview

writeEntryState :: EntryState -> JSVal
writeEntryState EntryState {number, preview} =
  stringToForeign (maybe "" show number <> if preview then "+preview" else "")

-- The number of the last entry seen, and, while the router replaces the
-- current entry ('replacingEntry'), the number that entry had. One page
-- has one history, so they are the page's, as the numbers in the entries
-- are.
{-# NOINLINE lastEntry #-}
lastEntry :: IORef Int
lastEntry = unsafePerformIO (newIORef 0)

{-# NOINLINE replacedEntry #-}
replacedEntry :: IORef (Maybe Int)
replacedEntry = unsafePerformIO (newIORef Nothing)

-- | The number of the session history's current entry, written into the
-- entry's state the first time the shell sees it: the one after the last
-- entry seen, since an entry the shell has not seen is one just pushed
-- (the router's own pushes write no state). An entry keeps its number when
-- the page is reloaded or gone back to, so that the numbers of two entries
-- tell how far apart they are, which 'historyGo' wants. The router keeps
-- no such number. Natively always 0.
historyEntry :: (MonadIO m) => m Int
historyEntry
  | not inBrowser = pure 0
  | otherwise = liftIO $ do
      w <- Window.window
      kept <- readEntryState <$> w.history.state
      case kept.number of
        Just entry -> entry <$ writeIORef lastEntry entry
        Nothing -> do
          -- Whoever asks while the router replaces the entry gets the
          -- number the entry had, not a new one.
          entry <-
            readIORef replacedEntry >>= \case
              Just replaced -> pure replaced
              Nothing -> do
                next <- (+ 1) <$> readIORef lastEntry
                next <$ writeIORef lastEntry next
          w.history.replaceState (writeEntryState kept {number = Just entry}) "" Nothing
          pure entry

-- | Run something that replaces the current entry of the session history
-- (the router's redirect), keeping the entry's number: the entry is the
-- same one, at the same place in the history, which 'historyGo' counts
-- by, also to whoever asks for the entry's number while the router
-- replaces it (the shell, which the router tells at once). Natively there
-- is no history, and the action only runs.
replacingEntry :: (MonadIO m) => m () -> m ()
replacingEntry replacement
  | inBrowser = do
      entry <- historyEntry
      liftIO (writeIORef replacedEntry (Just entry))
      replacement
      -- The number is written into the entry before 'replacedEntry' is
      -- cleared. The other order leaves a moment when the entry has no
      -- number and 'replacedEntry' none either, and a 'historyEntry' then
      -- (the shell's, from another thread) gives the entry a new number.
      liftIO $ do
        replaced <- readIORef replacedEntry
        for_ replaced $ \number -> do
          w <- Window.window
          kept <- readEntryState <$> w.history.state
          w.history.replaceState (writeEntryState kept {number = Just number}) "" Nothing
        writeIORef replacedEntry Nothing
  | otherwise = replacement

-- | Go this many entries forward in the session history (back, if
-- negative), as the browser's buttons do: the router receives it as it
-- receives them.
historyGo :: (MonadIO m) => Int -> m ()
historyGo delta = liftIO $ Window.window >>= \w -> w.history.go delta

-- | Push the preview's entry onto the session history (WP5.38 of
-- docs/PLAN.md): "Show preview" in the editor pushes an entry at the
-- editor's own address, marked as the preview's, so that the browser's
-- Back returns to the text rather than leaving the editor. The shell sees
-- the same route and only numbers the entry; the editor, watching the
-- history, shows the text or the preview as the entry says
-- ('onPreviewEntry').
pushPreviewEntry :: (MonadIO m) => m ()
pushPreviewEntry = when inBrowser . liftIO $ do
  w <- Window.window
  w.history.pushState (writeEntryState EntryState {number = Nothing, preview = True}) "" Nothing

-- | Whether the session history's current entry is the preview's.
onPreviewEntry :: (MonadIO m) => m Bool
onPreviewEntry
  | not inBrowser = pure False
  | otherwise = liftIO $ Window.window >>= \w -> (.preview) . readEntryState <$> w.history.state

-- | Take the preview's mark off the current entry: an editor opened on
-- the preview's entry (after a reload, or back from another page) starts
-- with the text.
forgetPreviewEntry :: (MonadIO m) => m ()
forgetPreviewEntry = when inBrowser . liftIO $ do
  w <- Window.window
  kept <- readEntryState <$> w.history.state
  when kept.preview $ w.history.replaceState (writeEntryState kept {preview = False}) "" Nothing

-- | Go back one entry in the session history, as the browser's Back does.
historyBack :: (MonadIO m) => m ()
historyBack = when inBrowser . liftIO $ Window.window >>= \w -> w.history.back

-- | Put text on the clipboard, given the element that shows it, and say
-- whether it worked. The asynchronous clipboard first; where there is none
-- (a page served over plain HTTP from another machine) or it refuses, the
-- element's text is selected and copied the old way, and if even that
-- fails it stays selected, for the reader to copy with the keyboard. An
-- @\<input>@'s text is its value, not text inside the element, so an
-- input is selected with its own @select@; any other element is selected
-- whole with a range. This waits for the browser, so a component calls it
-- off its loop ('liftIO' in 'Halogen.HalogenM', not 'Halogen.liftEffect').
-- Natively nothing is copied.
copyText :: (MonadIO m) => Element -> Text -> m Bool
copyText element text = liftIO $ do
  w <- Window.window
  copied <- case w.navigator.clipboard of
    Nothing -> pure False
    Just clipboard -> isRight <$> (clipboard.writeText text >>= waitCatch)
  if copied
    then pure True
    else do
      case HTMLInputElement.fromElement element of
        Just input -> input.select
        Nothing -> do
          range <- w.document.createRange
          range.selectNodeContents (toNode element)
          found <- w.getSelection
          for_ found $ \selection -> do
            selection.removeAllRanges
            selection.addRange range
      either (const False) identity <$> try @JSError (w.document.execCommand "copy")

-- | An application address (as 'Router.href' writes it) as a full URL,
-- with the scheme and host the page was loaded from: what a link sent in
-- a mail or a message needs. Natively there is no page, and the address
-- is returned unchanged.
absoluteUrl :: (MonadIO m) => Text -> m Text
absoluteUrl path
  | not inBrowser = pure path
  | otherwise = liftIO $ do
      w <- Window.window
      base <- w.document.baseURI
      URL.parse path (Just base) >>= maybe (pure path) URL.href

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
-- type: a link with a @download@ attribute, clicked. The object URL the
-- link points at is let go once the browser has had time to start saving.
-- Natively nothing is saved.
download :: (MonadIO m) => Text -> Text -> ByteString -> m ()
download name mediaType bytes = liftIO . when inBrowser $ do
  url <- URL.createObjectURL =<< Blob.fromBytes bytes (MediaType mediaType)
  w <- Window.window
  anchor <- w.document.createElement "a"
  anchor.setAttribute "href" url
  anchor.setAttribute "download" name
  anchor.setAttribute "hidden" ""
  w.document.body >>= traverse_ (\body -> (HTMLElement.toElement body).appendChild (toNode anchor))
  for_ (HTMLElement.fromElement anchor) (.click)
  anchor.remove
  void . forkIO $ threadDelay 60_000_000 >> URL.revokeObjectURL url

-- | Open bytes in a new tab of the browser, as a document of this media
-- type: a PDF export ("Wiki.App.View.Export"). The tab shows an object URL,
-- which is let go after a minute, once the tab has loaded it. The result
-- says whether the browser opened the tab. A browser opens one only shortly
-- after the click that asked for it, and a slow export can come too late;
-- the caller then saves the document instead. Natively nothing is opened.
openInTab :: (MonadIO m) => Text -> ByteString -> m Bool
openInTab mediaType bytes
  | not inBrowser = pure False
  | otherwise = liftIO $ do
      url <- URL.createObjectURL =<< Blob.fromBytes bytes (MediaType mediaType)
      opened <- js_open_tab (toJSText url)
      if opened
        then void . forkIO $ threadDelay 60_000_000 >> URL.revokeObjectURL url
        else URL.revokeObjectURL url
      pure opened

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
consoleWarn message = liftIO $ Window.window >>= \w -> w.console.warn message

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
pageBackend = liftIO $ do
  w <- Window.window
  said <- w.document.querySelector "meta[name=\"wiki-backend\"]" >>= traverse (`Element.getAttribute` "content")
  pure (if join said == Just "server" then ServerBackend else DemoBackend)

--------------------------------------------------------------------------------
-- Comments

-- | Text the reader has selected in a page, as the link of a comment
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
-- the page checks in the click's listener, purely, as 'articleLink' is.
clickedThread :: Event -> Maybe CommentThreadId
clickedThread event = do
  target <- Event.target event >>= Element.fromEventTarget
  mark <- Element.closestNow target "mark.comment-mark[data-thread]"
  CommentThreadId <$> Element.getAttributeNow mark "data-thread"

-- | Scroll what a CSS selector picks into view, if it is not in view.
reveal :: (MonadIO m) => Text -> m ()
reveal selector = liftIO $ do
  w <- Window.window
  w.document.querySelector selector >>= traverse_ (`Element.scrollIntoViewBlock` Element.ToNearest)

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
