{-# LANGUAGE TemplateHaskell #-}

-- | What the editor ("Wiki.App.View.Editor") asks of the browser that
-- Halogen does not say: the files a drop or a file input brings and their
-- bytes, text put in at a textarea's cursor, which of the editor's keys was
-- pressed, and the browser's warning before a reload or a close loses
-- unsaved changes. See @jsbits/editor.js@.
--
-- Natively there is no browser: no event brings a file, no key is one of
-- the editor's, and the rest does nothing.
module Wiki.App.Editor.Browser
  ( -- * Files
    PickedFile (..)
  , takeFiles
  , readPickedFile

    -- * The textarea
  , insertAtCursor
  , EditorKey (..)
  , editorKey

    -- * Leaving the page
  , guardUnload
  )
where

import Data.ByteString.Base64 qualified as Base64
import Halogen.JSBits (JSText, JSVal, Safety (..), browserJS, fromJSText, toJSText)
import Numeric.Natural (Natural)
import Protolude
import System.IO.Error qualified as IOError
-- With their constructors: the FFI passes the value inside each newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..))

-- Reading a file waits for the browser, so that binding is a safe import,
-- which waits for the promise; the rest return on the spot.
$( browserJS
     ["jsbits/editor.js"]
     [ ("js_take_files", "wiki_editor_take_files", Unsafe, [t|Event -> IO JSVal|])
     , ("js_file_count", "wiki_editor_file_count", Unsafe, [t|JSVal -> IO Int|])
     , ("js_file_name", "wiki_editor_file_name", Unsafe, [t|JSVal -> Int -> IO JSText|])
     , ("js_file_type", "wiki_editor_file_type", Unsafe, [t|JSVal -> Int -> IO JSText|])
     , ("js_file_size", "wiki_editor_file_size", Unsafe, [t|JSVal -> Int -> IO Double|])
     , ("js_read_file", "wiki_editor_read_file", Safe, [t|JSVal -> Int -> IO JSText|])
     , ("js_insert", "wiki_editor_insert", Unsafe, [t|Element -> JSText -> IO ()|])
     , ("js_key", "wiki_editor_key", Unsafe, [t|Event -> IO JSText|])
     , ("js_guard_unload", "wiki_editor_guard_unload", Unsafe, [t|Bool -> IO ()|])
     ]
 )

-- | A file a drop or a file input brought, before its bytes are read: what
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

-- | The files an event brings: a drop's, or a file input's change's. To be
-- run in 'Halogen.liftEffect', while the event is being dispatched: a drop's
-- files are gone once it has been.
takeFiles :: (MonadIO m) => Event -> m [PickedFile]
takeFiles event = liftIO $ do
  files <- js_take_files event
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

-- | Put text in at a textarea's cursor, in place of the selection, as typing
-- it would: the textarea dispatches an input event, which its handler sees
-- before this returns. To be run in 'Halogen.liftEffect'.
insertAtCursor :: (MonadIO m) => Element -> Text -> m ()
insertAtCursor textarea = liftIO . js_insert textarea . toJSText

-- | The keys the editor answers to itself.
data EditorKey
  = -- | Ctrl+S, or Cmd+S on a Mac.
    SaveKey
  | -- | Tab in the textarea, without a modifier.
    IndentKey
  | OtherKey
  deriving stock (Eq, Show)

-- | Which key a keydown is. To be run in 'Halogen.liftEffect', so that the
-- handler can still prevent what the browser would do with it.
editorKey :: (MonadIO m) => Event -> m EditorKey
editorKey event =
  liftIO $
    js_key event <&> \key -> case fromJSText key of
      "save" -> SaveKey
      "indent" -> IndentKey
      _ -> OtherKey

-- | Whether a reload or closing the tab should first be warned about, as
-- browsers do for a page with unsaved changes.
guardUnload :: (MonadIO m) => Bool -> m ()
guardUnload = liftIO . js_guard_unload
