{-# LANGUAGE TemplateHaskell #-}

-- | The editor's search over the whole text (WP5.103b of docs/PLAN.md), in
-- a browser, in the shell, over the demo's wiki, in a page's raw Markdown:
-- Ctrl+F from the text or from anywhere in the editor opens the panel with
-- the selection, Enter and F3 step through the matches into a folded
-- spoiler, which opens, and far down the text, which scrolls, past the end
-- to the start and back; Escape gives the focus back, at the match after a
-- step; the toggles for case, regular expressions and whole words; a
-- regular expression that is not one; the count's limit; and Replace and
-- Replace all, with a regular expression's groups, Replace all one step
-- that Ctrl+Z takes back. A presentation's rows are
-- "Test.Browser.SlideEditor"'s.
module Test.Browser.EditorSearch (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (decodeStrict)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startWith)
import Test.Browser.Text (editorHost, editorSelection, inputsSeen, markdown, selectText, setMarkdown, utf16Length, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Editor.Browser (foldLines, foldedLines)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

$( browserJS
     ["jsbits/test-search.js"]
     [ ("js_search_focus", "wiki_test_search_focus", Safe, [t|IO JSText|])
     , ("js_search_marks", "wiki_test_search_marks", Safe, [t|IO JSText|])
     , ("js_master_selection_seen", "wiki_test_master_selection_seen", Safe, [t|IO Bool|])
     , ("js_search_field_selection", "wiki_test_search_field_selection", Safe, [t|IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "finds from the text with Ctrl+F, the selection the text to find, and steps with Enter into a folded spoiler, which opens, and far down, the text scrolling to it, past the end and back; Escape gives the focus back at the match" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    host <- editorHost ui
    unsafeIOToPageM (foldLines host [(5, 7)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7)]
    watchEditor ui
    (atFirst, atHidden, atLast) <- case needles page of
      [a, b, c] -> pure (a, b, c)
      found -> expectationFailure ("needles at " <> show found) >> pure (0, 0, 0)
    selectText ui atFirst (atFirst + 6)
    press "Control+f"
    field <- find ui ".editor-search-find"
    getProperty field "value" `shouldReturn` "needle"
    searchFocus `shouldReturn` "find"
    fieldSelection `shouldReturn` [0, 6, 6]
    eventually $ said ui `shouldReturn` "1 of 3"
    -- The match in sight is marked as the current one; the others are not
    -- drawn.
    eventually $ marks `shouldReturn` [(-1, "needle", True)]
    -- Into the folded spoiler, which opens; the focus stays in the field.
    press "Enter"
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    editorSelection ui `shouldReturn` (atHidden, atHidden + 6)
    eventually $ said ui `shouldReturn` "2 of 3"
    searchFocus `shouldReturn` "find"
    -- Far down: the text scrolls to it.
    press "Enter"
    editorSelection ui `shouldReturn` (atLast, atLast + 6)
    eventually $ said ui `shouldReturn` "3 of 3"
    eventually $ unsafeIOToPageM js_master_selection_seen `shouldReturn` True
    -- Past the end to the start, and back with Shift+Enter and Shift+F3.
    press "Enter"
    editorSelection ui `shouldReturn` (atFirst, atFirst + 6)
    eventually $ said ui `shouldReturn` "1 of 3, from the start"
    press "Shift+Enter"
    editorSelection ui `shouldReturn` (atLast, atLast + 6)
    eventually $ said ui `shouldReturn` "3 of 3, from the end"
    press "Shift+F3"
    editorSelection ui `shouldReturn` (atHidden, atHidden + 6)
    -- Escape: the panel goes, the text has the focus at the match.
    press "Escape"
    eventually $ length <$> findAll ui ".editor-search" `shouldReturn` 0
    searchFocus `shouldReturn` "master"
    editorSelection ui `shouldReturn` (atHidden, atHidden + 6)
    marks `shouldReturn` []
    -- The search changed nothing.
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` page

  it "opens with Ctrl+F anywhere in the editor and gives the focus back there when no step was made; Ctrl+F in its field selects the field's text; F3 opens it too" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    -- From the editor's "Save and close": the browser's find does not
    -- open, the editor's does, with the text to find empty (nothing is
    -- selected).
    find ui ".editor-save-close" >>= focus
    press "Control+f"
    field <- find ui ".editor-search-find"
    searchFocus `shouldReturn` "find"
    getProperty field "value" `shouldReturn` ""
    typeText field "needle"
    eventually $ said ui `shouldReturn` "3 matches"
    -- Ctrl+F again in the field: the text is selected, to type over.
    press "Control+f"
    fieldSelection `shouldReturn` [0, 6, 6]
    press "Escape"
    eventually $ length <$> findAll ui ".editor-search" `shouldReturn` 0
    searchFocus `shouldReturn` "elsewhere editor-save-close"
    -- A selection over two lines is not taken: the text to find stays.
    selectText ui 2 20
    press "F3"
    field' <- find ui ".editor-search-find"
    getProperty field' "value" `shouldReturn` "needle"
    searchFocus `shouldReturn` "find"
    press "Escape"
    searchFocus `shouldReturn` "master"
    editorSelection ui `shouldReturn` (2, 20)

  it "steps through matches of no length, line by line, and leaves Ctrl+F to the browser while the preview is shown alone" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# Hello, world\n\nA\nB\nC"
    selectText ui 2 2
    press "Control+f"
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-find" >>= (`typeText` "^")
    -- Four: the line's start before the title line's "# " is none.
    eventually $ said ui `shouldReturn` "4 matches"
    for_ [15, 16, 18, 20] $ \at -> do
      press "Enter"
      editorSelection ui `shouldReturn` (at, at)
    press "Escape"
    -- The preview shown alone: the text and the panel are hidden, and
    -- Ctrl+F is not the editor's.
    find ui ".editor-show-preview" >>= click
    eventually $ find ui ".editor-back" >>= shouldBeVisible
    press "Control+f"
    length <$> findAll ui ".editor-search" `shouldReturn` 0

  -- Replace, once for each match, ends where Replace all ends: for
  -- matches of no length at a line's start, its end, a word's edge, before
  -- a character, and for a match that may be empty.
  it "ends where Replace all ends when Replace is pressed once for each match, matches of no length included" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let text = "# Title\n\nax\nax\nax"
        start = do
          setMarkdown ui text
          -- The last "x": no match of any of these.
          selectText ui (T.length text - 1) (T.length text)
          press "Control+f"
    -- Each time from the same text and selection, the search opened with
    -- Ctrl+F (which takes the selection as its text) and asked again.
    let asking pattern' = do
          start
          field <- find ui ".editor-search-find"
          clear field
          typeText field pattern'
    start
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-replacement" >>= (`typeText` "X")
    press "Escape"
    for_ ["^", "$", "\\b", "(?=x)", "a|"] $ \pattern' -> do
      asking pattern'
      n <- eventually $ do
        shown <- said ui
        maybe (expectationFailure ("no count: " <> show shown) >> pure 0) pure (head (mapMaybe (readMaybe . T.unpack) (T.words shown)))
      -- The first press selects the first match after the selection; each
      -- of the others replaces one and selects the next.
      replaceButton <- find ui ".editor-search-replace"
      replicateM_ (n + 1) (click replaceButton)
      byOne <- markdown ui
      press "Escape"
      asking pattern'
      find ui ".editor-search-replace-all" >>= click
      every <- markdown ui
      (pattern', byOne) `shouldBe` (pattern', every)
      every `shouldNotBe` text
      press "Escape"

  it "counts no match in the title line's guarded \"# \", steps to none and replaces none, and finds the title's own text, in the raw Markdown" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let text = "# T\n\nA T here."
    setMarkdown ui text
    selectText ui (T.length text) (T.length text)
    press "Control+f"
    find ui ".editor-search-replacement" >>= (`typeText` "U")
    let asking regexp asked = do
          toggle <- find ui ".editor-search-regexp"
          pressed <- getAttribute toggle "aria-pressed"
          when (pressed /= Just (if regexp then "true" else "false")) (click toggle)
          field <- find ui ".editor-search-find"
          clear field
          typeText field asked
    for_ [(True, "^# T"), (False, "# "), (True, "#\\s*T"), (True, "^#")] $ \(regexp, asked) -> do
      asking regexp asked
      eventually $ ((asked,) <$> said ui) `shouldReturn` (asked, "No matches")
      press "Enter"
      editorSelection ui `shouldReturn` (T.length text, T.length text)
      find ui ".editor-search-replace" >>= click
      find ui ".editor-search-replace-all" >>= click
      markdown ui `shouldReturn` text
    -- "T", the title's own text, is a match: the title's and the text's.
    asking False "T"
    eventually $ said ui `shouldReturn` "2 matches"
    press "Enter"
    editorSelection ui `shouldReturn` (2, 3)
    eventually $ said ui `shouldReturn` "1 of 2, from the start"
    find ui ".editor-search-replace" >>= click
    markdown ui `shouldReturn` "# U\n\nA T here."

  it "replaces matches of no length one after the other, and steps past the count's limit, both ways" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# Hello, world\n\nA\nB\nC"
    selectText ui 16 16
    press "Control+f"
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-find" >>= (`typeText` "^")
    find ui ".editor-search-replacement" >>= (`typeText` "X")
    -- The cursor is a match, at the start of "A": each Replace writes there
    -- and goes on to the next line, not to the same place again.
    replaceButton <- find ui ".editor-search-replace"
    replicateM_ 3 (click replaceButton)
    markdown ui `shouldReturn` "# Hello, world\n\nXA\nXB\nXC"
    press "Escape"
    -- Past the thousandth line: a step goes on to the next, and back.
    setMarkdown ui ("# Hello, world\n\n" <> T.replicate 1100 "x\n")
    let lineAt k = 16 + 2 * (k - 2)
    selectText ui (lineAt 999) (lineAt 999)
    press "Control+f"
    eventually $ said ui `shouldReturn` "1000+ matches"
    press "Enter"
    editorSelection ui `shouldReturn` (lineAt 1000, lineAt 1000)
    press "Enter"
    editorSelection ui `shouldReturn` (lineAt 1001, lineAt 1001)
    press "Shift+Enter"
    editorSelection ui `shouldReturn` (lineAt 1000, lineAt 1000)

  it "says a regular expression that is not one and matches nothing, matches case and whole words when asked, and stops counting at 1000" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# Hello, world\n\nCat cat category CAT.\n"
    selectText ui 2 2
    press "Control+f"
    field <- find ui ".editor-search-find"
    typeText field "cat"
    eventually $ said ui `shouldReturn` "4 matches"
    find ui ".editor-search-case" >>= click
    eventually $ said ui `shouldReturn` "2 matches"
    find ui ".editor-search-case" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    find ui ".editor-search-word" >>= click
    eventually $ said ui `shouldReturn` "1 match"
    find ui ".editor-search-case" >>= click
    eventually $ said ui `shouldReturn` "3 matches"
    eventually $ marks `shouldReturn` [(-1, "Cat", False), (-1, "cat", False), (-1, "CAT", False)]
    -- "cat(" as a regular expression is not one: said, marked on the field,
    -- and nothing is marked or selected.
    find ui ".editor-search-word" >>= click
    find ui ".editor-search-regexp" >>= click
    typeText field "("
    eventually $ said ui `shouldReturn` "Not a valid regular expression"
    getAttribute field "aria-invalid" `shouldReturn` Just "true"
    eventually $ marks `shouldReturn` []
    press "Enter"
    editorSelection ui `shouldReturn` (2, 2)
    -- A thousand matches and more: counted to a thousand.
    press "Escape"
    setMarkdown ui ("# Hello, world\n\n" <> T.replicate 1100 "x ")
    selectText ui 16 17
    press "Control+f"
    eventually $ said ui `shouldReturn` "1 of 1000+"
    press "Enter"
    eventually $ said ui `shouldReturn` "2 of 1000+"

  it "replaces one match, then the next, and every match with a regular expression's groups, past an emoji, Replace all one step that Ctrl+Z takes back" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    let mails = "# Hello, world\n\n😀 a@example.org and b@example.org, not c@example.com.\n"
        firstAt = utf16Length "# Hello, world\n\n😀 "
        secondAt = utf16Length "# Hello, world\n\n😀 a@example.org and "
    setMarkdown ui mails
    selectText ui 2 2
    press "Control+f"
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-find" >>= (`typeText` "(\\w+)@example\\.org")
    find ui ".editor-search-replacement" >>= (`typeText` "[[people/$1]]")
    eventually $ said ui `shouldReturn` "2 matches"
    -- No match selected: Replace selects the next one and replaces nothing.
    find ui ".editor-search-replace" >>= click
    editorSelection ui `shouldReturn` (firstAt, firstAt + 13)
    eventually $ said ui `shouldReturn` "1 of 2"
    markdown ui `shouldReturn` mails
    -- Now it replaces it, and selects the next.
    find ui ".editor-search-replace" >>= click
    let once = T.replace "a@example.org" "[[people/a]]" mails
    markdown ui `shouldReturn` once
    editorSelection ui `shouldReturn` (secondAt - 1, secondAt - 1 + 13)
    eventually $ said ui `shouldReturn` "1 of 1"
    -- Escape after a step: the text has the focus at the match, and
    -- Ctrl+Z there takes the replacement back. Replace all: every match,
    -- one step of the history. (Opened with nothing selected, the search
    -- keeps its regular expression.)
    press "Escape"
    searchFocus `shouldReturn` "master"
    press "Control+z"
    eventually $ markdown ui `shouldReturn` mails
    selectText ui 2 2
    press "Control+f"
    eventually $ said ui `shouldReturn` "2 matches"
    find ui ".editor-search-replace-all" >>= click
    let all' = T.replace "b@example.org" "[[people/b]]" (T.replace "a@example.org" "[[people/a]]" mails)
    markdown ui `shouldReturn` all'
    eventually $ said ui `shouldReturn` "No matches, 2 replaced"
    press "Escape"
    searchFocus `shouldReturn` "master"
    press "Control+z"
    eventually $ markdown ui `shouldReturn` mails
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

-- | A page with "needle" three times: on its third line, inside a block
-- spoiler (lines 5 to 7), and after two hundred lines.
page :: Text
page =
  T.intercalate "\n" $
    ["# Hello, world", "", "The needle starts here.", "", "[[!spoiler]]{answer}(The answer)", "A needle hidden.", "[[/spoiler]]{answer}", ""]
      <> ["Filler line " <> show n <> "." | n <- [1 .. 200 :: Int]]
      <> ["", "The last needle."]

-- | Where each "needle" of a text starts, in UTF-16 units (the text is
-- ASCII).
needles :: Text -> [Int]
needles text = [T.length before | (before, _) <- T.breakOnAll "needle" text]

-- | What the panel says of the matches.
said :: Mounted s q o m -> PageM s Text
said ui = find ui ".editor-search-count" >>= textContent

-- | Where the focus is (test-search.js's wiki_test_search_focus).
searchFocus :: PageM s Text
searchFocus = unsafeIOToPageM (fromJSText <$> js_search_focus)

-- | The marks of the matches drawn: where (-1, the editor's own text),
-- the text marked, and whether it is the current match.
marks :: PageM s [(Int, Text, Bool)]
marks = fromMaybe [] . decodeStrict . encodeUtf8 <$> unsafeIOToPageM (fromJSText <$> js_search_marks)

-- | The selection in the panel's text to find, and the field's length.
fieldSelection :: PageM s [Int]
fieldSelection = fromMaybe [] . decodeStrict . encodeUtf8 <$> unsafeIOToPageM (fromJSText <$> js_search_field_selection)
