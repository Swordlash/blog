{-# LANGUAGE TemplateHaskell #-}

-- | The browser features the editor ("Wiki.App.View.Editor") needs that
-- Halogen does not provide: the files a drop, a paste or a file input
-- brings, and their bytes; CodeMirror, put in place of the textarea; the
-- text and selection, read and written as an edit the browser can undo;
-- which of the editor's keys was pressed; the browser's warning before a
-- reload or a close loses unsaved changes; the writing assistant's
-- edits, as changes the author accepts or rejects; the questions
-- CodeMirror asks to complete a mention or an emoji, with their answers;
-- and the folds of its text. The files, the keys and the events
-- CodeMirror sends are read through the Web types' fields; what works on the text itself (CodeMirror, or the
-- textarea's selection in UTF-16 code units) is @jsbits/editor.js@, and
-- CodeMirror is @web/src/editor.js@.
--
-- The editor's text is the textarea the component renders until
-- CodeMirror has taken its place, in the element just before it, the host,
-- which is what the component holds and hands these functions; from then
-- on the host carries CodeMirror ('Host'), and the text, the selection
-- and the writes are CodeMirror's.
--
-- Natively there is no browser: no event brings a file, no key is one of
-- the editor's, the textarea is empty, CodeMirror never loads, and the
-- rest does nothing.
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
  , editorAvailable
  , typedText
  , applyCommand
  , insertAtCursor
  , focusText
  , goToTitleLine
  , focusElement
  , focusInView
  , LiveFeed
  , listenLive
  , stopLive
  , followLine
  , announceUpload
  , paneShown
  , previewEntries
  , pushPreviewEntry
  , onPreviewEntry
  , forgetPreviewEntry
  , historyBack
  , previewShowing
  , previewShown
  , textShown
  , clearField
  , clickElement
  , EditorKey (..)
  , editorKey
  , GridKey (..)
  , gridKey

    -- * The assistant's edits
  , currentText
  , selectedSpan
  , changesLeft
  , decision
  , trackedChanges
  , proposeEdit
  , settleChanges

    -- * Problems
  , showProblems
  , nextProblem

    -- * Folds
  , offerFolds
  , foldLines
  , unfoldLines
  , foldedLines

    -- * Slides
  , cursorLine
  , cursorLineOf
  , readyFocused

    -- * A presentation's rows
  , attachRow
  , detachRow
  , Layout (..)
  , rowsLayout
  , setRows
  , slidesModeIn
  , holdFocus
  , restoreFocus
  , RowWanted (..)
  , rowWanted
  , historyKey
  , undoIn
  , moveKey
  , rowKeyOf
  , stepIn
  , focusHeader
  , dragCarries
  , markDragged
  , pointerAfter

    -- * Mentions
  , mentionAsked
  , answerMention

    -- * Emoji
  , emojiAsked
  , answerEmoji

    -- * Leaving the page
  , guardUnload
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Data.Aeson (FromJSON (..), ToJSON (..), decodeStrict, eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.ByteString.Lazy qualified as BSL
import Data.Coerce (coerce)
import Data.Foreign (foreignToInt)
import Data.List (lookup)
import Data.Text qualified as T
import Halogen.JSBits (Callback, Inert (..), JSText, JSVal, Safety (..), browserJS, freeCallback, fromJSText, inBrowser, isNull, jsValText, mkSyncCallback, toJSText)
import Halogen.JSBits.Fields (Member (..), inlineJS, jsFields)
import Halogen.JSBits.Promise (wait)
import Halogen.Query.Event.Window qualified as WindowEvent
import Halogen.Subscription (Emitter)
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Numeric.Natural (Natural)
import Protolude hiding (wait)
import Web.Clipboard.ClipboardEvent (ClipboardEvent (..))
import Web.DOM.Element qualified as Element
-- With their constructors: the FFI passes the value inside each newtype.
import Web.DOM.Internal.Types (Element (..), HTMLElement (..))
import Web.Event.CustomEvent (CustomEvent (..))
import Web.Event.Event (Event (..), EventType (..))
import Web.Event.Event qualified as Event
import Web.File.File (File)
import Web.File.FileList qualified as FileList
import Web.HTML.Event.DragEvent (DragEvent (..))
import Web.HTML.HTMLElement qualified as HTMLElement
import Web.HTML.HTMLInputElement qualified as HTMLInputElement
import Web.HTML.HTMLTextAreaElement (HTMLTextAreaElement)
import Web.HTML.HTMLTextAreaElement qualified as HTMLTextAreaElement
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Wiki.App.Browser (forgetPreviewEntry, historyBack, onPreviewEntry, pushPreviewEntry)
import Wiki.App.Editor.Problems (ProblemRange)
import Wiki.Core.Assistant.Edit (Change (..), Decision (..), Edit, Refusal, Replacement (..), plan, propose, settle)
import Wiki.Core.Assistant.Prompt (Span (..))
import Wiki.Core.Markdown.Edit (Command (..), Selection (..), apply, cursor)
import Wiki.Core.Markdown.Folds (Fold (..))
import Wiki.Core.SlideRows (Row (..), RowKey (..), Rows (..), rowStarts)
import Wiki.Core.SlideRows qualified as SlideRows
import Wiki.Core.User (Login (..), User (..))

-- What works on the text as CodeMirror and the textarea count it, in
-- UTF-16 code units, and the live preview's channel between windows: logic
-- of its own, which stays JavaScript.
$( browserJS
     ["jsbits/editor.js"]
     [ ("js_attach", "wiki_editor_attach", Safe, [t|Element -> JSText -> IO ()|])
     , ("js_attach_row", "wiki_editor_attach_row", Safe, [t|Element -> Element -> Int -> Bool -> IO ()|])
     , ("js_detach_row", "wiki_editor_detach_row", Safe, [t|Element -> IO ()|])
     , ("js_available", "wiki_editor_available", Safe, [t|IO Bool|])
     , ("js_rows", "wiki_editor_rows", Safe, [t|Element -> IO JSText|])
     , ("js_set_rows", "wiki_editor_set_rows", Safe, [t|Element -> JSText -> JSText -> IO Bool|])
     , ("js_slides_mode", "wiki_editor_slides_mode", Safe, [t|Element -> Bool -> IO ()|])
     , ("js_hold_focus", "wiki_editor_hold_focus", Safe, [t|Element -> IO ()|])
     , ("js_restore_focus", "wiki_editor_restore_focus", Safe, [t|Element -> IO ()|])
     , ("js_history", "wiki_editor_history", Safe, [t|Element -> Bool -> IO ()|])
     , ("js_step", "wiki_editor_step", Safe, [t|Element -> JSText -> JSText -> IO Bool|])
     , ("js_focus_header", "wiki_editor_focus_header", Safe, [t|Element -> Int -> IO ()|])
     , ("js_selection_start", "wiki_editor_selection_start", Safe, [t|Element -> IO Int|])
     , ("js_selection_end", "wiki_editor_selection_end", Safe, [t|Element -> IO Int|])
     , ("js_write", "wiki_editor_write", Safe, [t|Element -> JSText -> Int -> Int -> IO ()|])
     , ("js_live_listen", "wiki_live_listen", Safe, [t|JSText -> Callback -> IO Int|])
     , ("js_live_stop", "wiki_live_stop", Safe, [t|Int -> IO ()|])
     , ("js_live_follow", "wiki_live_follow", Safe, [t|Element -> Int -> IO ()|])
     , ("js_guard_unload", "wiki_editor_guard_unload", Safe, [t|Bool -> IO ()|])
     , ("js_changes", "wiki_editor_changes", Safe, [t|Element -> IO JSText|])
     , ("js_propose", "wiki_editor_propose", Safe, [t|Element -> Int -> Int -> JSText -> Int -> JSText -> IO ()|])
     , ("js_settle", "wiki_editor_settle", Safe, [t|Element -> JSText -> JSText -> IO ()|])
     , ("js_mentioned", "wiki_editor_mentioned", Safe, [t|Element -> Int -> JSText -> IO ()|])
     , ("js_emojied", "wiki_editor_emojied", Safe, [t|Element -> Int -> JSText -> IO ()|])
     , ("js_title_line", "wiki_editor_title_line", Safe, [t|Element -> IO ()|])
     , ("js_problems", "wiki_editor_problems", Safe, [t|Element -> JSText -> IO ()|])
     , ("js_next_problem", "wiki_editor_next_problem", Safe, [t|Element -> IO ()|])
     , ("js_offer_folds", "wiki_editor_offer_folds", Safe, [t|Element -> JSText -> JSText -> IO ()|])
     ]
 )

-- A drag's data and the pointer's place, read in a drag's listeners, for
-- a slide's row dragged by its handle: what the Web types do not read.
$(inlineJS "js_drag_carries" "Array.from($1.dataTransfer?.types ?? []).includes($2)" [t|Event -> JSText -> Bool|])

$(inlineJS "js_mark_dragged" "(() => { if (!$1.dataTransfer) return false; $1.dataTransfer.setData(\"application/x-wiki-slide\", String($2)); $1.dataTransfer.effectAllowed = \"move\"; return true; })()" [t|Event -> Int -> Bool|])

$(inlineJS "js_pointer_after" "(() => { const r = $1.currentTarget?.getBoundingClientRect?.(); return r ? $1.clientY > r.top + r.height / 2 : false; })()" [t|Event -> Bool|])

-- | The host element, as @web/src/editor.js@ adds to it: the CodeMirror
-- put in it, once the page's islands have loaded the editor.
newtype Host = Host Element
  deriving newtype (Inert)

-- | The CodeMirror in a host, as @web/src/editor.js@ makes it: the text
-- it holds, the focus, and what the preview beside it or shown alone asks
-- of it.
newtype CodeMirror = CodeMirror JSVal
  deriving newtype (Inert)

$( jsFields
     ''Host
     [ Live "wikiEditor" [t|Maybe CodeMirror|]
     ]
 )

$( jsFields
     ''CodeMirror
     [ -- The whole text.
       Method "text" [t|IO Text|]
     , -- Let go of the editor, as the component goes.
       Method "destroy" [t|IO ()|]
     , -- Give the text the focus, at its selection, without scrolling.
       Method "focus" [t|IO ()|]
     , -- Scroll the preview beside the text, just shown, to the line
       -- followed.
       Method "paneShown" [t|IO ()|]
     , -- The preview is about to be shown alone: keep where the window is.
       Method "previewShowing" [t|IO ()|]
     , -- The preview was shown alone: scroll to the block being edited.
       Method "previewShown" [t|IO ()|]
     , -- The text was shown again: the window goes back to where it was.
       Method "textShown" [t|IO ()|]
     , -- Tell the window of the page that a file was uploaded to it.
       Method "uploaded" [t|IO ()|]
     , -- Fold ranges of lines, JSON [[first, last]] (from 1), each first
       -- line staying in sight.
       Method "fold" [t|Text -> IO ()|]
     , -- Unfold the folds that start on these ranges' first lines.
       Method "unfold" [t|Text -> IO ()|]
     , -- The folds, as JSON: [[first, last]], lines from 1.
       Method "foldedLines" [t|IO Text|]
     , -- The cursor's line, from 1.
       Method "cursorLine" [t|IO Int|]
     ]
 )

-- | The detail of a @wiki-selection@ event: the selection, in characters.
newtype SelectionDetail = SelectionDetail JSVal
  deriving newtype (Inert)

-- | The detail of a @wiki-decide@ event: a decision on a change.
newtype DecisionDetail = DecisionDetail JSVal
  deriving newtype (Inert)

-- | The detail of a @wiki-row-wanted@ event: the row a change took the
-- editor's cursor to.
newtype RowWantedDetail = RowWantedDetail JSVal
  deriving newtype (Inert)

$( jsFields
     ''RowWantedDetail
     [ Fixed "key" ''Int
     , Fixed "left" ''Int
     , Fixed "close" ''Bool
     , Fixed "focus" ''Bool
     , Fixed "reason" ''Text
     ]
 )

-- | The detail of a @wiki-mention@ or @wiki-emoji@ event: a question
-- about the letters typed of a mention or of an emoji's name.
newtype QuestionDetail = QuestionDetail JSVal
  deriving newtype (Inert)

$( jsFields
     ''SelectionDetail
     [ Fixed "from" ''Int
     , Fixed "to" ''Int
     ]
 )

$( jsFields
     ''DecisionDetail
     [ Fixed "accept" ''Bool
     , Fixed "id" ''Int
     ]
 )

$( jsFields
     ''QuestionDetail
     [ Fixed "id" ''Int
     , Fixed "letters" ''Text
     ]
 )

-- | The detail of one of CodeMirror's events on the host, if the event
-- carries one: a value of the event's own shape, read purely, since the
-- event does not change.
detailOf :: Event -> Maybe JSVal
detailOf event = let detail = (CustomEvent event).detail in if isNull detail then Nothing else Just detail

-- | The CodeMirror in the host, if the page's islands have put one there.
codeMirror :: Element -> IO (Maybe CodeMirror)
codeMirror host = (Host host).wikiEditor

-- | The textarea beside the host, until CodeMirror has taken its place.
textareaOf :: Element -> IO (Maybe HTMLTextAreaElement)
textareaOf host = (>>= HTMLTextAreaElement.fromElement) <$> host.nextElementSibling

-- | The files an event brought, not yet read.
newtype Files = Files [File]

-- | A drop's files. Call it in the drop's listener, while the browser
-- dispatches the drop (the drop's handler), and force it there: once the
-- dispatch is over, the drop has no files any more, while the files taken
-- from it stay readable ('FileList.now').
droppedFiles :: Event -> Files
droppedFiles event = Files (maybe [] (FileList.now . (.files)) (DragEvent event).dataTransfer)

-- | A paste's files, if it brought any: a screenshot, an image copied in a
-- browser, or files copied in a file manager. Call it in the paste's
-- listener and force it there, as for 'droppedFiles'. A paste of text
-- alone brings no files, and the editor inserts the text itself.
pastedFiles :: Event -> Maybe Files
pastedFiles event = case maybe [] (FileList.now . (.files)) (ClipboardEvent event).clipboardData of
  [] -> Nothing
  files -> Just (Files files)

-- | A file input's files, from its change event. The input is emptied, so
-- that choosing the same file again is also a change.
chosenFiles :: (MonadIO m) => Event -> m Files
chosenFiles event = liftIO $ case Event.target event >>= Element.fromEventTarget >>= HTMLInputElement.fromElement of
  Nothing -> pure (Files [])
  Just input -> do
    files <- input.files >>= maybe (pure []) FileList.items
    input.value_set ""
    pure (Files files)

-- | A file a drop, a paste or a file input brought, before its bytes are
-- read: what the browser says about it, and the file to read.
data PickedFile = PickedFile
  { name :: Text
  , mediaType :: Text
  -- ^ As the browser guesses it from the name; empty when it cannot.
  , size :: Natural
  -- ^ In bytes, so that a file that is too large is refused before it is
  -- read.
  , file :: File
  }

-- | What the browser says about each file.
pickedFiles :: (MonadIO m) => Files -> m [PickedFile]
pickedFiles (Files files) =
  pure [PickedFile {name = file.name, mediaType = file.type_, size = fromIntegral @Integer (round file.size), file} | file <- files]

-- | A file's bytes. This waits for the browser to read them, so a
-- component calls it with 'lift', off its loop.
readPickedFile :: (MonadIO m) => PickedFile -> m ByteString
readPickedFile picked = liftIO (evaluate =<< wait =<< picked.file.bytes)

-- | Put CodeMirror in the host element (an empty element the editor
-- renders just before its textarea) in place of the textarea, once the
-- page has loaded CodeMirror. It starts with the Markdown the textarea was
-- made with, or with what has been typed into the textarea since. The call
-- returns at once. A CodeMirror already there for an earlier textarea
-- (before a reload) is replaced. From then on the text is CodeMirror's,
-- which reports each change with a @wiki-input@ event on the host
-- ('typedText'); until then, it is the textarea's.
--
-- The functions here that edit the text take the host, and act on
-- CodeMirror if it is there and on the textarea if not.
attachEditor :: (MonadIO m) => Element -> Text -> m ()
attachEditor host original = liftIO (js_attach host (toJSText original))

-- | Remove the host's CodeMirror, if it has one.
detachEditor :: (MonadIO m) => Element -> m ()
detachEditor host = liftIO $ codeMirror host >>= traverse_ (.destroy)

-- | Whether the page can put CodeMirror in place of the textarea: its
-- islands' script is there, with the editor. Natively, never.
editorAvailable :: (MonadIO m) => m Bool
editorAvailable = liftIO js_available

-- | The whole text a @wiki-input@ event says the editor now has. Pure,
-- since the event does not change.
typedText :: Event -> Text
typedText = maybe "" jsValText . detailOf

-- | Apply a toolbar command to the editor's text: read its text and
-- selection, make the change ("Wiki.Core.Markdown.Edit"), and write the
-- part that changed back as one edit that undo reverts. The edit fires its
-- input event (the textarea's, or CodeMirror's @wiki-input@), which the
-- component's handler receives before this returns. Run it in
-- 'Halogen.liftEffect'.
applyCommand :: (MonadIO m) => Element -> Command -> m ()
applyCommand host command = edit host (apply command)

-- | Insert text at the editor's cursor, replacing the selection, as typing
-- it would, and leave the cursor after it. Run it in
-- 'Halogen.liftEffect'.
insertAtCursor :: (MonadIO m) => Element -> Text -> m ()
insertAtCursor host text = edit host $ \old (Selection s e) ->
  (T.take s old <> text <> T.drop e old, cursor (s + T.length text))

edit :: (MonadIO m) => Element -> (Text -> Selection -> (Text, Selection)) -> m ()
edit host change = liftIO $ do
  old <- currentText host
  selection <- Selection <$> js_selection_start host <*> js_selection_end host
  let (new, Selection s e) = change old selection
  js_write host (toJSText new) s e

-- | Give the text the focus, at its selection, without scrolling to it.
focusText :: (MonadIO m) => Element -> m ()
focusText host =
  liftIO $
    codeMirror host >>= \case
      Just editor -> editor.focus
      Nothing -> textareaOf host >>= traverse_ (HTMLElement.focusWithoutScrolling . coerce)

-- | Put the caret at the end of the text's first line, the page's title
-- line (after its @# @), scroll the line into view, and give the text the
-- focus: what a click on the editor's title does. Run it in
-- 'Halogen.liftEffect'.
goToTitleLine :: (MonadIO m) => Element -> m ()
goToTitleLine = liftIO . js_title_line

-- | Give an element the focus, without scrolling to it.
focusElement :: (MonadIO m) => Element -> m ()
focusElement = liftIO . HTMLElement.focusWithoutScrolling . coerce

-- | Give an element the focus, and scroll it into view by the least
-- amount, in the box that scrolls it and in the window, only where it is
-- not already seen: an entry of a grid that scrolls (the "Emoji" menu's),
-- reached with the arrow keys, which do not scroll the way Tab does.
focusInView :: (MonadIO m) => Element -> m ()
focusInView element = liftIO $ do
  HTMLElement.focusWithoutScrolling (coerce element)
  Element.scrollIntoViewBlock element Element.ToNearest

-- | 'LiveFeed' is a window's subscription to what the editor of a page
-- sends on the browser's channel between the wiki's windows (WP5.36 of
-- docs/PLAN.md, "Wiki.App.View.LivePreview"): the channel's number in
-- @jsbits/editor.js@ and the callback its messages come through, freed
-- when it stops.
data LiveFeed = LiveFeed Int (Maybe Callback)

-- | Listen for the editor of the page the key names; each message for it,
-- as JSON, is given to the handler. Natively there is no browser, and
-- nothing is heard.
listenLive :: (MonadIO m) => Text -> (Text -> IO ()) -> m LiveFeed
listenLive key heard
  | inBrowser = liftIO $ do
      callback <- mkSyncCallback (heard . jsValText)
      channel <- js_live_listen (toJSText key) callback
      pure (LiveFeed channel (Just callback))
  | otherwise = pure (LiveFeed 0 Nothing)

-- | Stop listening, and free the callback.
stopLive :: (MonadIO m) => LiveFeed -> m ()
stopLive (LiveFeed channel callback) = liftIO $ do
  when inBrowser (js_live_stop channel)
  traverse_ freeCallback callback

-- | Scroll rendered Markdown with line markers ("Wiki.Core.Markdown.Render"'s
-- @renderLines@) to the block of a source line.
followLine :: (MonadIO m) => Element -> Int -> m ()
followLine element = liftIO . js_live_follow element

-- | Tell the window of the page in the editor (the host) that a file was
-- uploaded to the page. The window fetches the page's attachments again,
-- so that a reference to the new file resolves there too.
announceUpload :: (MonadIO m) => Element -> m ()
announceUpload host = liftIO $ codeMirror host >>= traverse_ (.uploaded)

-- | Scroll the preview beside the text in the editor (the host), just
-- switched on, to the line the editor follows.
paneShown :: (MonadIO m) => Element -> m ()
paneShown host = liftIO $ codeMirror host >>= traverse_ (.paneShown)

-- | The browser's Back and Forward (@popstate@), each saying whether the
-- entry reached is the preview's (WP5.38 of docs/PLAN.md): the editor
-- shows the text or the preview as the entry says. Natively there is no
-- history, and nothing is told.
previewEntries :: (MonadBrowserDOM n, MonadUnliftIO n) => n (Emitter IO Bool)
previewEntries = do
  HS.Emitter register <- WindowEvent.windowEvent (EventType "popstate") (const (Just ()))
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \() -> onPreviewEntry >>= push
    pure stop

-- | Keep where the window is, with the text, before the preview is shown
-- alone: where 'textShown' returns it.
previewShowing :: (MonadIO m) => Element -> m ()
previewShowing host = liftIO $ codeMirror host >>= traverse_ (.previewShowing)

-- | Scroll the window to the block of the line the editor (the host)
-- follows, in the preview shown alone.
previewShown :: (MonadIO m) => Element -> m ()
previewShown host = liftIO $ codeMirror host >>= traverse_ (.previewShown)

-- | Scroll the window back to where it was before the preview was shown.
textShown :: (MonadIO m) => Element -> m ()
textShown host = liftIO $ codeMirror host >>= traverse_ (.textShown)

-- | Empty a form field the component does not control, such as a password
-- once it has been sent: what was typed in it would otherwise stay there.
clearField :: (MonadIO m) => Element -> m ()
clearField element = liftIO $ for_ (HTMLInputElement.fromElement element) (\input -> input.value_set "")

-- | Click an element, as the user would.
clickElement :: (MonadIO m) => Element -> m ()
clickElement element = liftIO (coerce element :: HTMLElement).click

-- | Mark the page's problems in the editor's text (the host's), replacing
-- the ones marked before: CodeMirror underlines each range, puts a marker
-- in its gutter and shows the message on hover. Before CodeMirror has
-- loaded, the problems are kept on the host and marked once it has. The
-- textarea marks nothing.
showProblems :: (MonadIO m) => Element -> [ProblemRange] -> m ()
showProblems host ranges = liftIO (js_problems host (jsonText ranges))

-- | Move the editor's cursor to the next problem after it, or to the first
-- after the last one, show its message and give the text the focus. Run
-- it in 'Halogen.liftEffect'.
nextProblem :: (MonadIO m) => Element -> m ()
nextProblem = liftIO . js_next_problem

-- | Offer the spoilers' folds found in a text ("Wiki.Core.Markdown.Folds")
-- in the editor's gutter and keys (WP5.96 of docs/PLAN.md), in place of
-- the ones offered before. CodeMirror takes them only while it holds that
-- text: folds of another text would fold the wrong lines. Before
-- CodeMirror has loaded, they are kept on the host and offered once it
-- has, if it holds that text. The textarea folds nothing.
offerFolds :: (MonadIO m) => Element -> Text -> [Fold] -> m ()
offerFolds host text found =
  liftIO (js_offer_folds host (toJSText text) (jsonText [object ["from" .= f.from, "to" .= f.to] | f <- found]))

-- | Fold ranges of the editor's lines, each its first and last line (from
-- 1, both included, as "Wiki.Core.Markdown.Folds" counts them), in any
-- order: the first stays in sight, with a mark that unfolds the rest. Any
-- ranges, offered in the gutter or not: a heading's section, say. A range
-- the text does not have, or of one line, folds nothing. The ranges are
-- taken in the order of the text, the longer first of two that start on
-- one line; one that overlaps or lies inside a fold made before it, by
-- this call or already, is left out, and so is the same range twice. Folding changes what is shown,
-- never the text: no input event comes of it.
foldLines :: (MonadIO m) => Element -> [(Int, Int)] -> m ()
foldLines host ranges = liftIO $ codeMirror host >>= traverse_ (\cm -> cm.fold (encodeRanges ranges))

-- | Unfold the editor's folds that start on the first line of one of these
-- ranges, in any order (the last line is not compared, so a range read
-- before is enough).
unfoldLines :: (MonadIO m) => Element -> [(Int, Int)] -> m ()
unfoldLines host ranges = liftIO $ codeMirror host >>= traverse_ (\cm -> cm.unfold (encodeRanges ranges))

-- | The editor's folds, as their first and last lines, in the order of the
-- text: those made in the gutter, with the keys, by the mark or by
-- 'foldLines'. None before CodeMirror has loaded.
foldedLines :: (MonadIO m) => Element -> m [(Int, Int)]
foldedLines host = liftIO $ do
  found <- codeMirror host >>= traverse (.foldedLines)
  pure (fromMaybe [] (found >>= decodeRanges))

-- | The line the editor's cursor is on, from 1: the first line before
-- CodeMirror has loaded.
cursorLine :: (MonadIO m) => Element -> m Int
cursorLine host = liftIO $ maybe (pure 1) (.cursorLine) =<< codeMirror host

-- | The line a @wiki-cursor-line@ event says the cursor is now on.
cursorLineOf :: Event -> Maybe Int
cursorLineOf = fmap foreignToInt . detailOf

-- | Whether the text had the focus when CodeMirror took its place, as the
-- @wiki-ready@ event says (@web/src/editor.js@).
readyFocused :: Event -> Bool
readyFocused = maybe False ((== 1) . foreignToInt) . detailOf

-- | Ranges of lines as CodeMirror's side reads and writes them: JSON,
-- @[[first, last]]@.
encodeRanges :: [(Int, Int)] -> Text
encodeRanges = decodeUtf8 . BSL.toStrict . encode

decodeRanges :: Text -> Maybe [(Int, Int)]
decodeRanges = decodeStrict . encodeUtf8

-- | The keys the editor handles itself.
data EditorKey
  = -- | Ctrl+S, or Cmd+S on a Mac, anywhere in the editor.
    SaveKey
  | -- | Ctrl+Alt+P (Cmd+Option+P), anywhere in the editor: show the preview,
    -- or go back to editing.
    PreviewKey
  | -- | Escape, anywhere in the editor: closes an open menu.
    EscapeKey
  | -- | Tab in the text, without a modifier.
    IndentKey
  | -- | A toolbar command's shortcut in the text.
    CommandKey Command
  | -- | Ctrl+Shift+K (Cmd+Shift+K) in the text: "Link to a page", which
    -- opens a dialog rather than running a command.
    LinkPageKey
  | -- | Alt+Up (-1) or Alt+Down (1) in the text: move a presentation's
    -- slide, the cursor's, one place up or down.
    MoveSlideKey Int
  deriving stock (Eq, Show)

-- | Which of the editor's keys a keydown is, if any. Pure, so that a
-- handler can decide in the event's listener, while the browser can still
-- be stopped from acting on the key
-- ('Halogen.HTML.Events.preventingDefault'). Saving, the preview and
-- Escape are the form's, wherever the focus is in it; the rest are the
-- text's (the textarea's, or CodeMirror's content), not the assistant's
-- message box, which is a textarea of the form too, where Tab and the
-- shortcuts are its own. Shift+7, Shift+8 and Shift+K are read by the key's place
-- (its code), since the character they type differs between layouts, as
-- is P with Alt, which types a character of its own on a Mac. A key the
-- list of a mention's completion acts on (Tab, Enter, Escape) never
-- reaches the form: CodeMirror stops it (@web/src/editor.js@).
editorKey :: Event -> Maybe EditorKey
editorKey event
  | pressed.isComposing = Nothing
  | command && not pressed.altKey && not pressed.shiftKey && key == "s" = Just SaveKey
  | command && pressed.altKey && not pressed.shiftKey && pressed.code == "KeyP" = Just PreviewKey
  | plain && key == "Escape" = Just EscapeKey
  | not inText = Nothing
  | plain && key == "Tab" = Just IndentKey
  | command && not pressed.altKey && not pressed.shiftKey = CommandKey <$> lookup key [("b", Bold), ("i", Italic), ("k", Link), ("e", InlineCode)]
  | command && not pressed.altKey && pressed.shiftKey && pressed.code == "KeyK" = Just LinkPageKey
  | command && not pressed.altKey && pressed.shiftKey = CommandKey <$> lookup pressed.code [("Digit7", NumberedList), ("Digit8", BulletList)]
  | pressed.altKey && not command && not pressed.shiftKey = MoveSlideKey <$> lookup pressed.key [("ArrowUp", -1), ("ArrowDown", 1)]
  | otherwise = Nothing
  where
    pressed = KeyboardEvent event
    command = pressed.ctrlKey || pressed.metaKey
    plain = not (command || pressed.altKey || pressed.shiftKey)
    key = if T.length pressed.key == 1 then T.toLower pressed.key else pressed.key
    inText = isJust (Event.target event >>= Element.fromEventTarget >>= (`Element.closestNow` "textarea.editor-text, .cm-content"))

-- | 'GridKey' is a key pressed in a menu with a grid of entries (the
-- toolbar's "Emoji" menu), as 'gridKey' reads it.
data GridKey = GridKey
  { key :: Text
  -- ^ The key's name: @ArrowDown@, @Enter@, @a@.
  , plain :: Bool
  -- ^ Whether no modifier (Shift, Ctrl, Alt, Meta) was held.
  , entry :: Maybe Int
  -- ^ The number of the entry the key was pressed on, from the entry's
  -- @data-index@, or 'Nothing' when it was pressed elsewhere in the menu
  -- (its field).
  }

-- | The key a keydown in a menu with a grid of entries is, or 'Nothing'
-- while an input method composes text: that key (an Enter that ends the
-- composition, too) is the input method's, and the menu leaves it alone.
-- Pure, so that the listener can decide whether the browser's own action
-- is to be stopped.
gridKey :: Event -> Maybe GridKey
gridKey event
  | pressed.isComposing || pressed.key == "Process" = Nothing
  | otherwise = Just GridKey {key = pressed.key, plain, entry}
  where
    pressed = KeyboardEvent event
    plain = not (pressed.ctrlKey || pressed.metaKey || pressed.altKey || pressed.shiftKey)
    entry = Event.target event >>= Element.fromEventTarget >>= (`Element.getAttributeNow` "data-index") >>= readMaybe . T.unpack

-- | The editor's current text: CodeMirror's, or the textarea's.
currentText :: (MonadIO m) => Element -> m Text
currentText host =
  liftIO $
    codeMirror host >>= \case
      Just editor -> editor.text
      Nothing -> textareaOf host >>= maybe (pure "") (.value)

-- | The selection a @wiki-selection@ event reports, in characters, if
-- anything is selected. Pure, since the event does not change.
selectedSpan :: Event -> Maybe Span
selectedSpan event = do
  detail <- SelectionDetail <$> detailOf event
  guard (detail.to > detail.from)
  Just (Span detail.from detail.to)

-- | How many of the assistant's changes a @wiki-changes@ event says are
-- still undecided.
changesLeft :: Event -> Int
changesLeft = maybe 0 foreignToInt . detailOf

-- | The decision a @wiki-decide@ event reports, made with a change's own
-- buttons: accept or reject, and which change.
decision :: Event -> Maybe (Decision, Int)
decision event = do
  detail <- DecisionDetail <$> detailOf event
  Just (if detail.accept then Accept else Reject, detail.id)

-- | The assistant's undecided changes, as CodeMirror tracks them, at their
-- current positions.
trackedChanges :: (MonadIO m) => Element -> m [Change]
trackedChanges host = liftIO $ do
  text <- fromJSText <$> js_changes host
  pure (either (const []) (map (\(Tracked c) -> c)) (eitherDecodeStrict (encodeUtf8 text)))

-- | Make the assistant's edit in the current text, tracked as the change
-- with the given id, merging any changes it overlaps
-- ("Wiki.Core.Assistant.Edit"). The result is where the edit went and the
-- ids of the changes it merged, or why it cannot be made. Its input event
-- brings the change into the component's state before this returns, as a
-- toolbar command's does. Run it in 'Halogen.liftEffect'.
proposeEdit :: (MonadIO m) => Element -> Int -> Edit -> m (Either Refusal (Replacement, [Int]))
proposeEdit host i change = liftIO $ do
  text <- currentText host
  case plan change text of
    Left why -> pure (Left why)
    Right r -> do
      pending <- trackedChanges host
      let (_, taken) = propose i r text pending
      js_propose host r.from r.to (toJSText r.text) i (jsonText taken)
      pure (Right (r, taken))

-- | Accept or reject the change with the given id, or all of them.
-- Rejecting restores what each change replaced, as one edit that undo
-- reverts; accepting only stops tracking them. The result is the ids of
-- the changes decided. Run it in 'Halogen.liftEffect'.
settleChanges :: (MonadIO m) => Element -> Decision -> Maybe Int -> m [Int]
settleChanges host d which = liftIO $ do
  pending <- trackedChanges host
  let chosen = maybe pending (\i -> filter (\c -> c.id == i) pending) which
      ids = map (\c -> c.id) chosen
  unless (null chosen) $
    js_settle host (jsonText ids) (jsonText [object ["from" .= r.from, "to" .= r.to, "text" .= r.text] | r <- settle d chosen])
  pure ids

-- | A change as @jsbits/editor.js@ gives it.
newtype Tracked = Tracked Change

instance FromJSON Tracked where
  parseJSON = withObject "Change" $ \o -> do
    c <- Change <$> o .: "id" <*> o .: "from" <*> o .: "to" <*> o .: "removed"
    pure (Tracked c)

jsonText :: (ToJSON a) => a -> JSText
jsonText = toJSText . decodeUtf8 . BSL.toStrict . encode

-- | The question a @wiki-mention@ event asks: its number, and the letters
-- typed after an \@, which the users a completion offers start with.
-- CodeMirror asks it a moment after the letters are typed
-- (@web/src/editor.js@), and waits for 'answerMention'. Pure, since the
-- event does not change.
mentionAsked :: Event -> Maybe (Int, Text)
mentionAsked = questionOf

-- | The question a @wiki-mention@ or @wiki-emoji@ event asks: its number,
-- and the letters typed.
questionOf :: Event -> Maybe (Int, Text)
questionOf event = do
  detail <- QuestionDetail <$> detailOf event
  guard (detail.id > 0)
  Just (detail.id, detail.letters)

-- | Answer the question with this number: the users a mention that starts
-- with its letters may name, display name first, or 'Nothing' when they
-- could not be found. CodeMirror shows them as a list to choose from, and
-- keeps the answer for the same letters until the editor goes; it does not
-- keep 'Nothing', and asks again.
answerMention :: (MonadIO m) => Element -> Int -> Maybe [User] -> m ()
answerMention host i people =
  liftIO . js_mentioned host i $
    maybe (toJSText "") (\us -> jsonText [object ["login" .= u.login.text, "name" .= u.displayName] | u <- us]) people

-- | The question a @wiki-emoji@ event asks: its number, and the letters
-- typed of an emoji's name after a colon (none, for a colon alone).
-- CodeMirror asks it a moment after the letters are typed
-- (@web/src/editor.js@), and waits for 'answerEmoji'. Pure, since the
-- event does not change.
emojiAsked :: Event -> Maybe (Int, Text)
emojiAsked = questionOf

-- | Answer the question with this number: the emoji whose names match its
-- letters, as (name, emoji) pairs, best first
-- ("Wiki.Core.Markdown.Emoji"'s 'Wiki.Core.Markdown.Emoji.emojiMatches').
-- CodeMirror shows them as a list to choose from, and keeps the answer for
-- the same letters until the editor goes.
answerEmoji :: (MonadIO m) => Element -> Int -> [(Text, Text)] -> m ()
answerEmoji host i found =
  liftIO . js_emojied host i $ jsonText [object ["name" .= name, "emoji" .= emoji] | (name, emoji) <- found]

----------------------------------------------------------------------
-- A presentation's rows

-- | Put a row of a presentation's slide mode (WP5.103) in an element: a
-- CodeMirror over the range the editor's CodeMirror, the master, gives
-- the row with this key in its layout ('setRows'). The row's edits are the
-- master's: one text, one history. With 'True', the row takes the focus.
-- Nothing before the master is in place, for a key its layout does not
-- have, nor natively.
attachRow :: (MonadIO m) => Element -> Element -> RowKey -> Bool -> m ()
attachRow master row (RowKey key) focus = liftIO (js_attach_row master row key focus)

-- | Let go of the row in an element, as its slide is closed or goes.
detachRow :: (MonadIO m) => Element -> m ()
detachRow = liftIO . js_detach_row

-- | 'Layout' is the master's text as it is now, its cursor, and its rows'
-- starts, mapped through every change since the layout was last set: what
-- "Wiki.Core.SlideRows" cuts again ('fromLayout'). Offsets in characters.
data Layout = Layout
  { text :: Text
  , anchor :: Int
  -- ^ Where the selection starts, the cursor being where it ends.
  , cursor :: Int
  , focused :: Maybe RowKey
  -- ^ The row whose editor had the focus last. It may have been closed
  -- since: a use that needs an editor asks whether the row is open.
  , starts :: [(RowKey, Int)]
  }

instance FromJSON Layout where
  parseJSON = withObject "Layout" $ \o -> do
    text <- o .: "text"
    at <- o .: "head"
    from' <- o .: "anchor"
    pairs <- o .: "rows"
    lastFocused <- o .: "focused"
    pure Layout {text, anchor = from', cursor = at, focused = if lastFocused < 0 then Nothing else Just (RowKey lastFocused), starts = [(RowKey k, s) | (k, s) <- pairs]}

-- | The master's 'Layout', once CodeMirror is in place.
rowsLayout :: (MonadIO m) => Element -> m (Maybe Layout)
rowsLayout host = liftIO $ do
  json <- fromJSText <$> js_rows host
  pure (decodeStrict (encodeUtf8 json))

-- | Give the master the rows a text was cut into. The master takes them
-- only while it holds that text, so that a cut of an older text is
-- dropped: whether they were taken.
setRows :: (MonadIO m) => Element -> Text -> Rows -> m Bool
setRows host text rows =
  liftIO . js_set_rows host (toJSText text) . jsonText $
    [(k, s, s + T.length row.text) | (row, s) <- zip rows.rows (rowStarts rows), let RowKey k = row.key]

-- | Tell the master whether the presentation is edited slide by slide: its
-- own completion is off then, and its focus goes to the row its cursor is
-- in.
slidesModeIn :: (MonadIO m) => Element -> Bool -> m ()
slidesModeIn host bySlide = liftIO (js_slides_mode host bySlide)

-- | Keep what has the focus in the rows' list, if anything, before a
-- change of the list, for 'restoreFocus'.
holdFocus :: (MonadIO m) => Element -> m ()
holdFocus = liftIO . js_hold_focus

-- | Give the focus back to what had it in the rows' list before the
-- change ('holdFocus'), when the list's patch moved that element and the
-- focus went nowhere. Run it after a render that may have moved a row.
restoreFocus :: (MonadIO m) => Element -> m ()
restoreFocus = liftIO . js_restore_focus

-- | 'RowWanted' is a row that a change the author did not make in the row
-- with the focus took the editor's cursor to (an undo, a redo, the next
-- problem, the toolbar writing elsewhere), or that the assistant wrote in:
-- the row to open, the row that had the focus, if any, whether that one
-- closes, which it does when the author went to the other row and not when
-- something was written there, and whether the row opened takes the focus,
-- which it does unless the assistant wrote in it.
data RowWanted = RowWanted
  { key :: RowKey
  , left :: Maybe RowKey
  , close :: Bool
  , focus :: Bool
  , reason :: Text
  -- ^ What took the cursor there: @undo@, @redo@, @problem@ (the next
  -- problem), @write@ (the toolbar) or @assistant@.
  }

-- | The row a @wiki-row-wanted@ event asks for. Pure, since the event does
-- not change.
rowWanted :: Event -> Maybe RowWanted
rowWanted event = do
  detail <- RowWantedDetail <$> detailOf event
  Just RowWanted {key = RowKey detail.key, left = if detail.left < 0 then Nothing else Just (RowKey detail.left), close = detail.close, focus = detail.focus, reason = detail.reason}

-- | Whether a keydown is the editor's undo ('True': Ctrl+Z, Cmd+Z) or redo
-- ('False': Ctrl+Y, Ctrl+Shift+Z, Cmd+Shift+Z), pressed where CodeMirror
-- does not take it (a row's header). Pure, as 'editorKey' is.
historyKey :: Event -> Maybe Bool
historyKey event
  | pressed.isComposing || not command || pressed.altKey = Nothing
  | key == "z" = Just (not pressed.shiftKey)
  | key == "y" && not pressed.shiftKey = Just False
  | otherwise = Nothing
  where
    pressed = KeyboardEvent event
    command = pressed.ctrlKey || pressed.metaKey
    key = T.toLower pressed.key

-- | The editor's undo ('True') or redo ('False'), run on the master: the
-- whole text's history.
undoIn :: (MonadIO m) => Element -> Bool -> m ()
undoIn host undoing = liftIO (js_history host undoing)

-- | Whether a keydown is Alt+Up (-1) or Alt+Down (1), with no other
-- modifier: a slide moved one place. Pure, as 'editorKey' is.
moveKey :: Event -> Maybe Int
moveKey event
  | pressed.isComposing || not pressed.altKey || pressed.ctrlKey || pressed.metaKey || pressed.shiftKey = Nothing
  | otherwise = lookup pressed.key [("ArrowUp", -1), ("ArrowDown", 1)]
  where
    pressed = KeyboardEvent event

-- | The key of the presentation's row an event happened in: the
-- @data-row-key@ of the nearest element around its target that has one.
-- Pure, read in the event's listener.
rowKeyOf :: Event -> Maybe RowKey
rowKeyOf event = do
  target <- Event.target event >>= Element.fromEventTarget
  row <- Element.closestNow target "[data-row-key]"
  RowKey <$> (readMaybe . T.unpack =<< Element.getAttributeNow row "data-row-key")

-- | Make a structural step of a presentation's rows on the master's text,
-- which "Wiki.Core.SlideRows" computed it for (a slide moved, deleted or
-- added): the history's user event (@move.slide@, @delete.slide@ or
-- @input.slide@), the edits of the text, the rows after it, and what to
-- select then, in characters of the text after it. One entry of the
-- history, with its layout. The master takes it only while it holds that
-- text: whether it was taken.
stepIn :: (MonadIO m) => Element -> Text -> Text -> [SlideRows.Edit] -> Rows -> Maybe (Int, Int) -> m Bool
stepIn host text event edits after select =
  liftIO . js_step host (toJSText text) . jsonText $
    object
      [ "event" .= event
      , "edits" .= [(e.from, e.to, e.insert) | e <- edits]
      , "rows" .= [(k, s, s + T.length row.text) | (row, s) <- zip after.rows (rowStarts after), let RowKey k = row.key]
      , "select" .= fmap (\(a, b) -> [a, b]) select
      ]

-- | Give the focus to the header of a row in the rows' list, once the
-- render that puts it there is done.
focusHeader :: (MonadIO m) => Element -> RowKey -> m ()
focusHeader rowsList (RowKey k) = liftIO (js_focus_header rowsList k)

-- | Whether a drag carries data of this type: @Files@ for files, or
-- 'slideType' for a slide's row. Pure, read in the drag's listener.
dragCarries :: Text -> Event -> Bool
dragCarries kind event = js_drag_carries event (toJSText kind)

-- | Mark the drag a dragstart starts as a slide's row's, with the row's
-- key, and the drag as a move, as browsers want a drag's data set in its
-- dragstart's listener. It does this when it is forced, so force it there:
-- it is pure only to be called from the listener ('HE.handler'').
markDragged :: Event -> RowKey -> Bool
markDragged event (RowKey k) = js_mark_dragged event k

-- | Whether a drag's pointer is in the lower half of the element the
-- listener is on: a row dropped there goes after that row. Pure, read in
-- the listener.
pointerAfter :: Event -> Bool
pointerAfter = js_pointer_after

-- | Whether the browser should warn before a reload or closing the tab,
-- as browsers do for a page with unsaved changes.
guardUnload :: (MonadIO m) => Bool -> m ()
guardUnload = liftIO . js_guard_unload
