{-# LANGUAGE TemplateHaskell #-}

-- | What the editor ("Wiki.App.View.Editor") asks of the browser that
-- Halogen does not say: the files a drop, a paste or a file input brings
-- and their bytes, CodeMirror put in place of the textarea, the text and selection,
-- read and written as an edit the browser can undo, which of the editor's
-- keys was pressed, the browser's warning before a reload or a close
-- loses unsaved changes, and the writing assistant's edits as changes the
-- author accepts or rejects. See @jsbits/editor.js@, and
-- @web/src/editor.js@ for CodeMirror.
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

    -- * The assistant's edits
  , currentText
  , selectedSpan
  , changesLeft
  , decision
  , trackedChanges
  , proposeEdit
  , settleChanges

    -- * Leaving the page
  , guardUnload
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Halogen.JSBits (JSText, JSVal, Safety (..), browserJS, fromJSText, toJSText)
import Numeric.Natural (Natural)
import Protolude
import System.IO.Error qualified as IOError
-- With their constructors: the FFI passes the value inside each newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..))
import Wiki.Core.Assistant.Edit (Change (..), Decision (..), Edit, Refusal, Replacement (..), plan, propose, settle)
import Wiki.Core.Assistant.Prompt (Span (..))
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
     , ("js_selected", "wiki_editor_selected", Unsafe, [t|Event -> JSText|])
     , ("js_change_count", "wiki_editor_change_count", Unsafe, [t|Event -> Int|])
     , ("js_decided", "wiki_editor_decided", Unsafe, [t|Event -> JSText|])
     , ("js_changes", "wiki_editor_changes", Unsafe, [t|Element -> IO JSText|])
     , ("js_propose", "wiki_editor_propose", Unsafe, [t|Element -> Int -> Int -> JSText -> Int -> JSText -> IO ()|])
     , ("js_settle", "wiki_editor_settle", Unsafe, [t|Element -> JSText -> JSText -> IO ()|])
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

-- | The editor's text as it is now: CodeMirror's, or the textarea's.
currentText :: (MonadIO m) => Element -> m Text
currentText host = liftIO (fromJSText <$> js_value host)

-- | The selection a @wiki-selection@ event tells of, in characters, if
-- anything is selected. Pure, as the event does not change.
selectedSpan :: Event -> Maybe Span
selectedSpan event = case T.splitOn ":" (fromJSText (js_selected event)) of
  [a, b] | Just f <- readMaybe a, Just t <- readMaybe b -> Just (Span f t)
  _ -> Nothing

-- | How many of the assistant's changes a @wiki-changes@ event says are
-- left to decide.
changesLeft :: Event -> Int
changesLeft = js_change_count

-- | The decision a @wiki-decide@ event tells of, made with a change's own
-- control: accept or reject, and which change.
decision :: Event -> Maybe (Decision, Int)
decision event = case T.splitOn ":" (fromJSText (js_decided event)) of
  ["accept", i] -> (Accept,) <$> readMaybe i
  ["reject", i] -> (Reject,) <$> readMaybe i
  _ -> Nothing

-- | The assistant's changes not yet decided, as CodeMirror keeps them,
-- where they are now.
trackedChanges :: (MonadIO m) => Element -> m [Change]
trackedChanges host = liftIO $ do
  text <- fromJSText <$> js_changes host
  pure (either (const []) (map (\(Tracked c) -> c)) (eitherDecodeStrict (encodeUtf8 text)))

-- | The assistant's edit, made in the text as it is now and tracked as the
-- change of the id given, taking in the changes it touches
-- ("Wiki.Core.Assistant.Edit"); or why it cannot be made. Its input event
-- brings the change into the work before this returns, as a toolbar
-- command's does. To be run in 'Halogen.liftEffect'.
proposeEdit :: (MonadIO m) => Element -> Int -> Edit -> m (Either Refusal Replacement)
proposeEdit host i change = liftIO $ do
  text <- fromJSText <$> js_value host
  case plan change text of
    Left why -> pure (Left why)
    Right r -> do
      pending <- trackedChanges host
      let (_, taken) = propose i r text pending
      js_propose host r.from r.to (toJSText r.text) i (jsonText taken)
      pure (Right r)

-- | Accept or reject the change of the id given, or all of them: rejecting
-- puts back what each replaced, as one edit the undo takes back; accepting
-- only stops tracking them. To be run in 'Halogen.liftEffect'.
settleChanges :: (MonadIO m) => Element -> Decision -> Maybe Int -> m ()
settleChanges host d which = liftIO $ do
  pending <- trackedChanges host
  let chosen = maybe pending (\i -> filter (\c -> c.id == i) pending) which
  unless (null chosen) $
    js_settle host (jsonText (map (\c -> c.id) chosen)) (jsonText [object ["from" .= r.from, "to" .= r.to, "text" .= r.text] | r <- settle d chosen])

-- | A change as @jsbits/editor.js@ gives it.
newtype Tracked = Tracked Change

instance FromJSON Tracked where
  parseJSON = withObject "Change" $ \o -> do
    c <- Change <$> o .: "id" <*> o .: "from" <*> o .: "to" <*> o .: "removed"
    pure (Tracked c)

jsonText :: (ToJSON a) => a -> JSText
jsonText = toJSText . decodeUtf8 . BSL.toStrict . encode

-- | Whether a reload or closing the tab should first be warned about, as
-- browsers do for a page with unsaved changes.
guardUnload :: (MonadIO m) => Bool -> m ()
guardUnload = liftIO . js_guard_unload
