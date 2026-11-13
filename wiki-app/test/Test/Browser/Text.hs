{-# LANGUAGE TemplateHaskell #-}

-- | The editor's text in a browser test. It is CodeMirror (see
-- "Wiki.App.View.Editor"), which takes the place of the textarea the
-- editor is rendered with once the page has loaded it: what one types into
-- is its content, an element with no value, so the Markdown and the
-- selection are read from CodeMirror itself (test/jsbits/test-editor.js),
-- here and nowhere else.
module Test.Browser.Text
  ( editorText
  , markdown
  , editorSelection
  , utf16Length
  , movedBy
  , completing
  , setMarkdown
  , insertText
  , clearBody
  , mathIn
  , problemsMarked
  , editorHost
  , selectText
  , watchEditor
  , inputsSeen
  , proposeText
  )
where

import Data.Aeson (FromJSON (..), decodeStrict, withObject, (.:))
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Protolude hiding (find)
import Test.Hspec.Halogen
import Web.DOM.Internal.Types qualified as Web

$( browserJS
     ["jsbits/test-editor.js"]
     [ ("js_text", "wiki_test_editor_text", Safe, [t|IO JSText|])
     , ("js_selection_start", "wiki_test_editor_selection_start", Safe, [t|IO Int|])
     , ("js_selection_end", "wiki_test_editor_selection_end", Safe, [t|IO Int|])
     , ("js_jump", "wiki_test_editor_jump", Safe, [t|IO JSText|])
     , ("js_completing", "wiki_test_editor_completing", Safe, [t|IO JSText|])
     , ("js_set", "wiki_test_editor_set", Safe, [t|JSText -> IO ()|])
     , ("js_insert", "wiki_test_editor_insert", Safe, [t|Int -> JSText -> IO ()|])
     , ("js_clear_body", "wiki_test_editor_clear_body", Safe, [t|IO ()|])
     , ("js_math", "wiki_test_editor_math", Safe, [t|IO JSText|])
     , ("js_problems", "wiki_test_editor_problems", Safe, [t|IO JSText|])
     , ("js_host", "wiki_test_editor_host", Safe, [t|IO Web.Element|])
     , ("js_select", "wiki_test_editor_select", Safe, [t|Int -> Int -> IO ()|])
     , ("js_watch", "wiki_test_editor_watch", Safe, [t|IO ()|])
     , ("js_inputs", "wiki_test_editor_inputs", Safe, [t|IO Int|])
     , ("js_propose", "wiki_test_editor_propose", Safe, [t|Int -> Int -> JSText -> IO ()|])
     ]
 )

-- | What one types into: CodeMirror's content, found once CodeMirror has
-- taken the textarea's place.
editorText :: Mounted s q o m -> PageM s (Element s)
editorText ui = find ui ".editor-cm .cm-content"

-- | The Markdown in the editor now.
markdown :: Mounted s q o m -> PageM s Text
markdown ui = do
  _ <- editorText ui
  unsafeIOToPageM (fromJSText <$> js_text)

-- | The editor's selection, in UTF-16 units, as the browser counts (and as
-- the textarea's was).
editorSelection :: Mounted s q o m -> PageM s (Int, Int)
editorSelection ui = do
  _ <- editorText ui
  unsafeIOToPageM ((,) <$> js_selection_start <*> js_selection_end)

-- | The length of a text in UTF-16 units, as the browser counts it and
-- 'editorSelection' reports it: a character outside the Basic Multilingual
-- Plane (most emoji, such as 🤔) is two units, every other one is one.
-- 'Data.Text.length' counts characters, so the two differ in a text with
-- such a character.
utf16Length :: Text -> Int
utf16Length t = sum [if c > '\xFFFF' then 2 else 1 | c <- toS t :: [Char]]

-- | How CodeMirror's box differs from the textarea's it took the place of:
-- nothing (the empty text) if the page did not move as it took over.
movedBy :: Mounted s q o m -> PageM s Text
movedBy ui = do
  _ <- editorText ui
  unsafeIOToPageM (fromJSText <$> js_jump)

-- | Where the editor's completion of mentions is: @"active"@ with its list
-- open, @"pending"@ from a key that asks for one until CodeMirror has the
-- answer, or @""@ for neither.
completing :: Mounted s q o m -> PageM s Text
completing ui = do
  _ <- editorText ui
  unsafeIOToPageM (fromJSText <$> js_completing)

-- | Make the editor's text this, as one edit.
setMarkdown :: Mounted s q o m -> Text -> PageM s ()
setMarkdown ui text = do
  _ <- editorText ui
  unsafeIOToPageM (js_set (toJSText text))
  settle

-- | Put text into the editor's text at a position (in UTF-16 units), as
-- one small edit.
insertText :: Mounted s q o m -> Int -> Text -> PageM s ()
insertText ui at text = do
  _ <- editorText ui
  unsafeIOToPageM (js_insert at (toJSText text))
  settle

-- | Empty the editor's text but for its title line and a blank line after
-- it, with the cursor at the end: what a test types the page's text after.
-- The title line stays (WP5.39 of docs/PLAN.md), so a test no longer
-- clears the whole text.
clearBody :: Mounted s q o m -> PageM s ()
clearBody ui = do
  _ <- editorText ui
  unsafeIOToPageM js_clear_body
  settle

-- | The pieces of TeX math the editor's syntax tree has, each with its
-- delimiters, in the order of the text.
mathIn :: Mounted s q o m -> PageM s [Text]
mathIn ui = do
  _ <- editorText ui
  found <- unsafeIOToPageM (fromJSText <$> js_math)
  pure (fromMaybe [] (decodeStrict (encodeUtf8 found)))

-- | The problems the editor marks in its text (WP5.65 of docs/PLAN.md):
-- each one's range, in UTF-16 units, and its message, in the order of the
-- text.
problemsMarked :: Mounted s q o m -> PageM s [(Int, Int, Text)]
problemsMarked ui = do
  _ <- editorText ui
  found <- unsafeIOToPageM (fromJSText <$> js_problems)
  pure [(start, end, message) | Marked start end message <- fromMaybe [] (decodeStrict (encodeUtf8 found))]

-- | A problem as CodeMirror marks it.
data Marked = Marked Int Int Text

instance FromJSON Marked where
  parseJSON = withObject "problem" $ \o -> Marked <$> o .: "from" <*> o .: "to" <*> o .: "message"

-- | The element the open editor's CodeMirror is in, its host: what the
-- application's functions on the editor take ("Wiki.App.Editor.Browser").
editorHost :: Mounted s q o m -> PageM s Web.Element
editorHost ui = do
  _ <- editorText ui
  unsafeIOToPageM js_host

-- | Select from one position to another (in UTF-16 units) in the editor's
-- text, and give it the focus, changing nothing: where a test then presses
-- a key.
selectText :: Mounted s q o m -> Int -> Int -> PageM s ()
selectText ui start end = do
  _ <- editorText ui
  unsafeIOToPageM (js_select start end)
  settle

-- | Count the editor's input events from now on.
watchEditor :: Mounted s q o m -> PageM s ()
watchEditor ui = do
  _ <- editorText ui
  unsafeIOToPageM js_watch

-- | How many input events the editor made since 'watchEditor': one for
-- each change of its text.
inputsSeen :: Mounted s q o m -> PageM s Int
inputsSeen ui = do
  _ <- editorText ui
  unsafeIOToPageM js_inputs

-- | Replace the editor's text from one position to another (in UTF-16
-- units) with this, as the writing assistant's tracked change, which
-- leaves the selection where it is.
proposeText :: Mounted s q o m -> Int -> Int -> Text -> PageM s ()
proposeText ui start end text = do
  _ <- editorText ui
  unsafeIOToPageM (js_propose start end (toJSText text))
  settle
