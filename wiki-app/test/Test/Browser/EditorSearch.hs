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
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, startOn, startWith)
import Test.Browser.Text (completing, editorHost, editorSelection, editorText, inputsSeen, markdown, selectText, setMarkdown, utf16Length, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Editor.Browser (foldLines, foldedLines)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page (Page (id, updatedAt))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Space (Space (id))

$( browserJS
     ["jsbits/test-search.js"]
     [ ("js_search_focus", "wiki_test_search_focus", Safe, [t|IO JSText|])
     , ("js_search_marks", "wiki_test_search_marks", Safe, [t|IO JSText|])
     , ("js_master_selection_seen", "wiki_test_master_selection_seen", Safe, [t|IO Bool|])
     , ("js_search_field_selection", "wiki_test_search_field_selection", Safe, [t|IO JSText|])
     , ("js_scroll_text_late", "wiki_test_scroll_text_late", Safe, [t|IO ()|])
     , ("js_framesPromise", "wiki_test_frames", Safe, [t|IO (Promise ())|])
     ]
 )

-- | Two of the browser's frames from now.
js_frames :: IO ()
js_frames = if inBrowser then wait =<< js_framesPromise else pure inert

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

  -- One sequence of matches for everything: for each query of a table and
  -- each text, in the raw Markdown and slide by slide, the steps visit
  -- exactly the matches counted, each once, in the order of the text, and
  -- come back to the first; and Replace, once for the first step and once
  -- for each match, ends where Replace all ends. The queries: matches of
  -- no length at a line's start, its end, a word's edge, before a
  -- character and on an empty line; one that may be empty; white space
  -- across lines, whose first match is in the title line's guarded "# ";
  -- a look behind across a line; one across lines or not; one whose
  -- first match is in the guarded "# " and the others not; and words that
  -- end a longer word. Each without and with whole word, which leaves
  -- none of "#|x": then nothing is stepped to or replaced.
  for_ [False, True] $ \bySlide ->
    it ("visits each match counted once in order and replaces as Replace all does, for every query of a table" <> (if bySlide then ", slide by slide" else ", in the raw Markdown")) $ runPage $ do
      ui <- if bySlide then openDeck m "# Title\n\nax" else fst <$> startWith m (Just "user-editor") helloEditor
      let case' text (whole, pattern') = do
            setMarkdown ui text
            selectText ui 2 2
            toggle <- find ui ".editor-search-word"
            pressed <- getAttribute toggle "aria-pressed"
            when (pressed /= Just (if whole then "true" else "false")) (click toggle)
            field <- find ui ".editor-search-find"
            clear field
            typeText field pattern'
            let asked = pattern' <> (if whole then " (whole word)" else "")
            n <- eventually $ do
              shown <- said ui
              if shown == "No matches"
                then pure 0
                else maybe (expectationFailure (toS ("no count for " <> asked <> ": " <> shown)) >> pure 0) pure (lastMay (mapMaybe (readMaybe . T.unpack) (T.words shown)))
            -- None only where none is a whole word: "x" after "a".
            (asked, n == 0) `shouldBe` (asked, (pattern', whole) == ("#|x", True))
            when (n == 0) $ do
              find ui ".editor-search-replace-all" >>= click
              ((asked,) <$> markdown ui) `shouldReturn` (asked, text)
            unless (n == 0) $ caseFound text asked (whole || any (`T.isInfixOf` pattern') ["(?<", "(?=", "(?!", "\\b", "\\B"]) n
          -- A query whose matches look at their neighbours (whole word, a
          -- look behind or ahead, a word's edge) may match otherwise once
          -- a replacement is next to them: for it, each Replace replaces a
          -- match of the text as it then is, and Replace all may end
          -- elsewhere. For any other query, each Replace replaces one, and
          -- once for each match ends where Replace all ends.
          caseFound text pattern' neighbours n = do
            next <- find ui ".editor-search-next"
            visited <- replicateM (n + 1) (click next >> editorSelection ui)
            let distinct = ordNub (take n visited)
            (pattern', text, length distinct, atMay visited n) `shouldBe` (pattern', text, n, head visited)
            -- In the order of the text, once the steps are taken from the
            -- first match on: past the end, they go on from the start.
            let steps = take n visited
                (afterEnd, fromStart) = break (== minimum steps) steps
            (pattern', text, fromStart <> afterEnd) `shouldBe` (pattern', text, sort steps)
            -- Replace: the first press after a step replaces.
            setMarkdown ui text
            selectText ui 2 2
            click next
            replaceButton <- find ui ".editor-search-replace"
            changed <- for [1 .. n] $ \_ -> do
              was <- markdown ui
              click replaceButton
              (/= was) <$> markdown ui
            byOne <- markdown ui
            setMarkdown ui text
            selectText ui 2 2
            find ui ".editor-search-replace-all" >>= click
            every <- markdown ui
            -- Each Replace replaced a match; for a query whose matches look
            -- at their neighbours, the first did, the others replacing what
            -- the text as it then was still matches.
            (pattern', text, if neighbours then take 1 changed else changed) `shouldBe` (pattern', text, if neighbours then [True] else replicate n True)
            unless neighbours $ (pattern', text, byOne) `shouldBe` (pattern', text, every)
            (pattern', text, every /= text) `shouldBe` (pattern', text, True)
      -- Slide by slide the text is hidden: Ctrl+F on a row's header.
      if bySlide then find ui ".editor-slides .slide-row-toggle" >>= focus else selectText ui 2 2
      press "Control+f"
      find ui ".editor-search-regexp" >>= click
      find ui ".editor-search-replacement" >>= (`typeText` "X")
      for_
        [ ("# Title\n\nax\nax\nax", ["^", "$", "\\b", "(?=x)", "a|", "^$", "#|x"])
        , ("# T\n\nword word\nword", ["\\s+", "word"])
        , ("# T\n\na\nb\n\nab b", ["(?<=a\\n)b", "a\\nb|b"])
        , ("# T\n\nscat cat\ncat", ["cat\\s*", "cat"])
        ]
        $ \(text, patterns) -> for_ [(whole, p') | p' <- patterns, whole <- [False, True]] (case' text)

  -- A regular expression's replacement, by Replace and by Replace all: "$&"
  -- the match, "$1" a group (nothing for one that did not take part), "$$"
  -- a dollar, a group the expression does not have written as it is (and
  -- of two digits, the first alone when there is no group of both); a
  -- plain query's replacement written as it is.
  it "expands a regular expression's replacement as JavaScript does, a group that did not take part as nothing, and writes a plain query's as it is" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    selectText ui 2 2
    press "Control+f"
    for_
      [ (True, "(a)?b", "<$1>", "b ab", "<> <a>")
      , (True, "(x)|(b)", "[$1|$2]", "b x", "[|b] [x|]")
      , (True, "b", "[$&$$]", "b", "[b$]")
      , (True, "(b)", "$5$1", "b", "$5b")
      , (True, "(b)", "$12", "b", "b2")
      , (False, "b", "$1$&$$", "b", "$1$&$$")
      ]
      $ \(regexp, pattern', replacement, body, expected) -> do
        let text = "# T\n\n" <> body
            asked = (pattern', replacement)
        setMarkdown ui text
        selectText ui 2 2
        toggle <- find ui ".editor-search-regexp"
        pressed <- getAttribute toggle "aria-pressed"
        when (pressed /= Just (if regexp then "true" else "false")) (click toggle)
        find ui ".editor-search-find" >>= clear
        find ui ".editor-search-find" >>= (`typeText` pattern')
        find ui ".editor-search-replacement" >>= clear
        find ui ".editor-search-replacement" >>= (`typeText` replacement)
        n <- eventually $ do
          shown <- said ui
          maybe (expectationFailure (toS ("no count: " <> shown)) >> pure 0) pure (lastMay (mapMaybe (readMaybe . T.unpack) (T.words shown)))
        find ui ".editor-search-next" >>= click
        replaceButton <- find ui ".editor-search-replace"
        replicateM_ n (click replaceButton)
        ((asked,) <$> markdown ui) `shouldReturn` (asked, "# T\n\n" <> expected)
        setMarkdown ui text
        selectText ui 2 2
        find ui ".editor-search-replace-all" >>= click
        ((asked,) <$> markdown ui) `shouldReturn` (asked, "# T\n\n" <> expected)

  -- Replace replaces only a match of the search as it is now: after the
  -- search changed, nothing is remembered of the one before; and with the
  -- groups the match has in the text as it then is.
  it "replaces only a match of the search as it is now, with its groups in the text as it then is" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# T\n\ncat cat"
    selectText ui 2 2
    press "Control+f"
    find ui ".editor-search-find" >>= (`typeText` "cat")
    find ui ".editor-search-replacement" >>= (`typeText` "dog")
    replaceButton <- find ui ".editor-search-replace"
    click replaceButton
    click replaceButton
    markdown ui `shouldReturn` "# T\n\ndog cat"
    -- Another search, which has no match: Replace writes nothing.
    find ui ".editor-search-find" >>= clear
    find ui ".editor-search-find" >>= (`typeText` "wolf")
    find ui ".editor-search-replacement" >>= clear
    find ui ".editor-search-replacement" >>= (`typeText` "fox")
    eventually $ said ui `shouldReturn` "No matches"
    click replaceButton
    markdown ui `shouldReturn` "# T\n\ndog cat"
    -- A look behind: the second "b" follows an "a" once the first is
    -- replaced, and is replaced with the group that match has.
    setMarkdown ui "# T\n\nbb"
    selectText ui 2 2
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-find" >>= clear
    find ui ".editor-search-find" >>= (`typeText` "(?<=a)(b)|(b)")
    find ui ".editor-search-replacement" >>= clear
    find ui ".editor-search-replacement" >>= (`typeText` "$1a")
    replicateM_ 3 (click replaceButton)
    markdown ui `shouldReturn` "# T\n\naba"
    setMarkdown ui "# T\n\nbb"
    find ui ".editor-search-replace-all" >>= click
    markdown ui `shouldReturn` "# T\n\naa"

  -- The search is the editor's: CodeMirror put in place again (a draft
  -- discarded, which loads the page again) keeps it open, its panel
  -- showing what it searches, which is what it runs.
  it "keeps the search open through the text loaded again, the panel showing what it searches and runs" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# Hello, world\n\nHello again."
    find ui ".editor-cancel" >>= click
    keep <- eventually (findAll ui ".editor-cancel-confirm button") >>= filterM (fmap (T.isInfixOf "Keep the draft") . textContent)
    maybe (expectationFailure "no Keep the draft") click (head keep)
    eventually $ find ui ".page-view .actions a[href$='/edit/']" >>= click
    eventually $ find ui ".editor-draft-found" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Restored your unsaved draft")
    selectText ui 2 2
    press "Control+f"
    find ui ".editor-search-regexp" >>= click
    find ui ".editor-search-find" >>= (`typeText` "Hel+o")
    find ui ".editor-search-replacement" >>= (`typeText` "Bye")
    eventually $ said ui `shouldReturn` "2 matches"
    -- Back to the page as saved: CodeMirror is put in place again.
    find ui ".editor-draft-discard" >>= click
    eventually $ markdown ui >>= (`shouldSatisfy` (not . T.isInfixOf "Hello again."))
    find ui ".editor-search-find" >>= (`getProperty` "value") >>= (`shouldBe` "Hel+o")
    find ui ".editor-search-replacement" >>= (`getProperty` "value") >>= (`shouldBe` "Bye")
    find ui ".editor-search-regexp" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    eventually $ said ui >>= (`shouldSatisfy` \shown -> " match" `T.isInfixOf` shown && shown /= "No matches")
    find ui ".editor-search-replace-all" >>= click
    eventually $ markdown ui >>= (`shouldSatisfy` \text -> not ("Hello" `T.isInfixOf` text) && "Bye" `T.isInfixOf` text)

  -- Escape closes the search from anywhere in the editor, after whatever
  -- is more inside has taken it: a completion's list open in the text
  -- closes first.
  it "closes the search on Escape in the text and on the toolbar, after a completion's list open in the text" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui "# T\n\nA needle."
    let opened = do
          press "Control+f"
          eventually $ length <$> findAll ui ".editor-search" `shouldReturn` 1
        closed = eventually $ length <$> findAll ui ".editor-search" `shouldReturn` 0
    selectText ui 2 2
    opened
    find ui ".editor-search-find" >>= (`typeText` "needle")
    -- In the text.
    selectText ui 2 2
    press "Escape"
    closed
    searchFocus `shouldReturn` "master"
    -- On the toolbar.
    opened
    find ui ".editor-toolbar button.tool" >>= focus
    press "Escape"
    closed
    -- A completion's list first, then the search.
    opened
    let end = T.length "# T\n\nA needle."
    selectText ui end end
    editorText ui >>= (`typeText` " :smi")
    eventually $ completing ui `shouldReturn` "active"
    press "Escape"
    eventually $ completing ui `shouldReturn` ""
    length <$> findAll ui ".editor-search" `shouldReturn` 1
    press "Escape"
    closed

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

  -- The browser tells of a scroll of the text in its next frame: an
  -- editor closed in between gets it late, and reports it to nothing (its
  -- live preview's channel is closed then). A page error fails the suite.
  it "reports nothing of a scroll of its text that comes after it closed" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    unsafeIOToPageM js_scroll_text_late
    unmount ui
    unsafeIOToPageM js_frames

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

-- | The demo's "Hello, world" made a presentation with this text, open in
-- the editor, CodeMirror in place.
openDeck :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Text -> PageM s (Mounted s Shell.Query Void m)
openDeck m text = do
  (opener, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
  unmount opener
  unsafeIOToPageM . runMemWiki wiki $ do
    blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
    hello <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
    made <- either (panic . show) identity <$> setPageKind hello.id Kind.Presentation
    void (either (panic . show) identity <$> savePage made.id made.updatedAt "Deck" text)
  ui <- startOn m wiki (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
  _ <- editorText ui
  pure ui

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
