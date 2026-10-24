{-# LANGUAGE TemplateHaskell #-}

-- | What the editor ("Wiki.App.View.Editor") asks of the browser that
-- Halogen does not say: the files a drop, a paste or a file input brings
-- and their bytes, CodeMirror put in place of the textarea, the text and selection,
-- read and written as an edit the browser can undo, which of the editor's
-- keys was pressed, and the browser's warning before a reload or a close
-- loses unsaved changes. See @jsbits/editor.js@, and @web/src/editor.js@
-- for CodeMirror.
--
-- Natively there is no browser: no event brings a file, no key is one of
-- the editor's, the textarea is empty, CodeMirror never comes, and the rest
-- does nothing.
module Wiki.App.Editor.Browser
  ( -- * Files
    Files
  , droppedFiles
  , pastedFiles
  , chosenFiles
  , PickedFile (..)
  , pickedFiles
  , readPickedFile

    -- * The text
  , attachEditor
  , detachEditor
  , typedText
  , applyCommand
  , insertAtCursor
  , focusText
  , focusElement
  , clickElement
  , EditorKey (..)
  , editorKey

    -- * Leaving the page
  , guardUnload
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Text qualified as T
import Halogen.JSBits (JSText, JSVal, Safety (..), browserJS, fromJSText, toJSText)
import Numeric.Natural (Natural)
import Protolude
import System.IO.Error qualified as IOError
-- With their constructors: the FFI passes the value inside each newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..))
import Wiki.Core.Markdown.Edit (Command (..), Selection (..), apply, cursor)

-- Reading a file waits for the browser, so that binding is a safe import,
-- which waits for the promise; the rest return on the spot. The key and a
-- drop's or a paste's files are read in the event's listener, which is pure
-- (the event does not change while it is being dispatched), so those are
-- pure.
$( browserJS
     ["jsbits/editor.js"]
     [ ("js_drop_files", "wiki_editor_drop_files", Unsafe, [t|Event -> JSVal|])
     , ("js_paste_files", "wiki_editor_paste_files", Unsafe, [t|Event -> JSVal|])
     , ("js_paste_file_count", "wiki_editor_paste_file_count", Unsafe, [t|Event -> Int|])
     , ("js_chosen_files", "wiki_editor_chosen_files", Unsafe, [t|Event -> IO JSVal|])
     , ("js_file_count", "wiki_editor_file_count", Unsafe, [t|JSVal -> IO Int|])
     , ("js_file_name", "wiki_editor_file_name", Unsafe, [t|JSVal -> Int -> IO JSText|])
     , ("js_file_type", "wiki_editor_file_type", Unsafe, [t|JSVal -> Int -> IO JSText|])
     , ("js_file_size", "wiki_editor_file_size", Unsafe, [t|JSVal -> Int -> IO Double|])
     , ("js_read_file", "wiki_editor_read_file", Safe, [t|JSVal -> Int -> IO JSText|])
     , ("js_attach", "wiki_editor_attach", Unsafe, [t|Element -> JSText -> IO ()|])
     , ("js_detach", "wiki_editor_detach", Unsafe, [t|Element -> IO ()|])
     , ("js_typed", "wiki_editor_typed", Unsafe, [t|Event -> JSText|])
     , ("js_value", "wiki_editor_value", Unsafe, [t|Element -> IO JSText|])
     , ("js_selection_start", "wiki_editor_selection_start", Unsafe, [t|Element -> IO Int|])
     , ("js_selection_end", "wiki_editor_selection_end", Unsafe, [t|Element -> IO Int|])
     , ("js_write", "wiki_editor_write", Unsafe, [t|Element -> JSText -> Int -> Int -> IO ()|])
     , ("js_key", "wiki_editor_key", Unsafe, [t|Event -> JSText|])
     , ("js_focus", "wiki_editor_focus", Unsafe, [t|Element -> IO ()|])
     , ("js_focus_text", "wiki_editor_focus_text", Unsafe, [t|Element -> IO ()|])
     , ("js_click", "wiki_editor_click", Unsafe, [t|Element -> IO ()|])
     , ("js_guard_unload", "wiki_editor_guard_unload", Unsafe, [t|Bool -> IO ()|])
     ]
 )

-- | Files an event brought, not yet looked at.
newtype Files = Files JSVal

-- | A drop's files. To be called in the drop's listener, while the browser
-- dispatches it (the drop's handler), and forced there: once the dispatch
-- is over, the drop has no files any more.
droppedFiles :: Event -> Files
droppedFiles = Files . js_drop_files

-- | A paste's files, if it brought any: a screenshot or an image copied in
-- a browser, or files copied in a file manager. To be called in the paste's
-- listener and forced there, as 'droppedFiles' is. A paste of text alone
-- brings none, and is the editor's to put in.
pastedFiles :: Event -> Maybe Files
pastedFiles ev
  | js_paste_file_count ev > 0 = Just (Files (js_paste_files ev))
  | otherwise = Nothing

-- | A file input's files, from its change event; the input is emptied, so
-- that choosing the same file again is a change too.
chosenFiles :: (MonadIO m) => Event -> m Files
chosenFiles = liftIO . fmap Files . js_chosen_files

-- | A file a drop, a paste or a file input brought, before its bytes are read: what
-- the browser says of it, and where to read it from.
data PickedFile = PickedFile
  { name :: Text
  , mediaType :: Text
  -- ^ As the browser guesses it from the name; empty when it cannot.
  , size :: Natural
  -- ^ In bytes, so that a file too large is refused before it is read.
  , files :: JSVal
  , index :: Int
  }

-- | What the browser says of each file.
pickedFiles :: (MonadIO m) => Files -> m [PickedFile]
pickedFiles (Files files) = liftIO $ do
  n <- js_file_count files
  for [0 .. n - 1] $ \index -> do
    name <- fromJSText <$> js_file_name files index
    mediaType <- fromJSText <$> js_file_type files index
    size <- fromIntegral @Integer . round <$> js_file_size files index
    pure PickedFile {name, mediaType, size, files, index}

-- | A file's bytes. This waits for the browser to read them, so a component
-- calls it with 'lift', off its loop.
readPickedFile :: (MonadIO m) => PickedFile -> m ByteString
readPickedFile file = liftIO $ do
  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced.
  base64 <- evaluate . fromJSText =<< js_read_file file.files file.index
  either (\e -> throwIO (IOError.userError ("the browser read a file as malformed base64: " <> e))) pure (Base64.decode (encodeUtf8 base64))

-- | Put CodeMirror in the host element (the element the editor renders, with
-- no children, just before its textarea) in place of the textarea, with the
-- Markdown the textarea was made with (or what has been typed into it since,
-- if anything has), once the page has loaded CodeMirror; it returns at once.
-- A CodeMirror already there for an earlier textarea (before a reload) is
-- replaced. The text is then CodeMirror's, which tells of each change by a
-- @wiki-input@ event on the host ('typedText'); until then, it is the
-- textarea's.
--
-- The functions here that edit the text take the host, and act on
-- CodeMirror if it is there and on the textarea if not.
attachEditor :: (MonadIO m) => Element -> Text -> m ()
attachEditor host original = liftIO (js_attach host (toJSText original))

-- | Let go of the host's CodeMirror, if it has one.
detachEditor :: (MonadIO m) => Element -> m ()
detachEditor = liftIO . js_detach

-- | The whole text a @wiki-input@ event says the editor has now. Pure, as
-- the event does not change.
typedText :: Event -> Text
typedText = fromJSText . js_typed

-- | Apply a toolbar command to the editor's text: read its text and selection,
-- make the change ("Wiki.Core.Markdown.Edit"), and write the part that
-- changed back as one edit the undo takes back, with its input event (the
-- textarea's, or CodeMirror's @wiki-input@), which the component's handler
-- sees before this returns. To be run in 'Halogen.liftEffect'.
applyCommand :: (MonadIO m) => Element -> Command -> m ()
applyCommand host command = edit host (apply command)

-- | Put text in at the editor's cursor, in place of the selection, as typing
-- it would, and leave the cursor after it. To be run in
-- 'Halogen.liftEffect'.
insertAtCursor :: (MonadIO m) => Element -> Text -> m ()
insertAtCursor host text = edit host $ \old (Selection s e) ->
  (T.take s old <> text <> T.drop e old, cursor (s + T.length text))

edit :: (MonadIO m) => Element -> (Text -> Selection -> (Text, Selection)) -> m ()
edit host change = liftIO $ do
  old <- fromJSText <$> js_value host
  selection <- Selection <$> js_selection_start host <*> js_selection_end host
  let (new, Selection s e) = change old selection
  js_write host (toJSText new) s e

-- | Give the text the focus, at its selection, without scrolling to it.
focusText :: (MonadIO m) => Element -> m ()
focusText = liftIO . js_focus_text

-- | Give an element the focus, without scrolling to it.
focusElement :: (MonadIO m) => Element -> m ()
focusElement = liftIO . js_focus

-- | Click an element, as the user would.
clickElement :: (MonadIO m) => Element -> m ()
clickElement = liftIO . js_click

-- | The keys the editor answers to itself.
data EditorKey
  = -- | Ctrl+S, or Cmd+S on a Mac, anywhere in the editor.
    SaveKey
  | -- | Ctrl+Alt+P (Cmd+Option+P), anywhere in the editor: the preview, or
    -- back to editing.
    PreviewKey
  | -- | Escape, anywhere in the editor, which closes a menu that is open.
    EscapeKey
  | -- | Tab in the text, without a modifier.
    IndentKey
  | -- | A toolbar command's shortcut in the text.
    CommandKey Command
  deriving stock (Eq, Show)

-- | Which of the editor's keys a keydown is, if any. Pure, so that a
-- handler can decide in the event's listener, while the browser can still
-- be kept from doing what it does with the key
-- ('Halogen.HTML.Events.preventingDefault').
editorKey :: Event -> Maybe EditorKey
editorKey event = case fromJSText (js_key event) of
  "save" -> Just SaveKey
  "preview" -> Just PreviewKey
  "escape" -> Just EscapeKey
  "indent" -> Just IndentKey
  "bold" -> Just (CommandKey Bold)
  "italic" -> Just (CommandKey Italic)
  "link" -> Just (CommandKey Link)
  "code" -> Just (CommandKey InlineCode)
  "numbered" -> Just (CommandKey NumberedList)
  "bulleted" -> Just (CommandKey BulletList)
  _ -> Nothing

-- | Whether a reload or closing the tab should first be warned about, as
-- browsers do for a page with unsaved changes.
guardUnload :: (MonadIO m) => Bool -> m ()
guardUnload = liftIO . js_guard_unload
