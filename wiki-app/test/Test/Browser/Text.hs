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
  , movedBy
  )
where

import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Protolude hiding (find)
import Test.Hspec.Halogen

$( browserJS
     ["jsbits/test-editor.js"]
     [ ("js_text", "wiki_test_editor_text", Unsafe, [t|IO JSText|])
     , ("js_selection_start", "wiki_test_editor_selection_start", Unsafe, [t|IO Int|])
     , ("js_selection_end", "wiki_test_editor_selection_end", Unsafe, [t|IO Int|])
     , ("js_jump", "wiki_test_editor_jump", Unsafe, [t|IO JSText|])
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

-- | How CodeMirror's box differs from the textarea's it took the place of:
-- nothing (the empty text) if the page did not move as it took over.
movedBy :: Mounted s q o m -> PageM s Text
movedBy ui = do
  _ <- editorText ui
  unsafeIOToPageM (fromJSText <$> js_jump)
