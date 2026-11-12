-- | The editor folds spoilers (WP5.96 of docs/PLAN.md), in a browser, in
-- the shell, over the demo's wiki: a block spoiler and a heading spoiler
-- folded and unfolded by the gutter, by the mark a fold leaves and by the
-- keys, with no input event and the text saved as it is, each fold told
-- by a @wiki-folds@ event; folds that follow the text typed above, below
-- and at the end of their first line, still on the same lines of text; a
-- fold opened by an edit at its end, inside it, or by a line break at its
-- start; the component's own interface, which folds and unfolds ranges of
-- lines and reports the folds; and folding that makes no draft and leaves
-- nothing for Cancel to ask about.
module Test.Browser.Folds (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startWith)
import Test.Browser.Text (editorHost, editorText, foldsTold, inputsSeen, markdown, proposeText, selectText, setMarkdown, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Editor.Browser (foldLines, foldedLines, unfoldLines)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Editor (draftDelay)
import Wiki.Core.Draft (Draft)
import Wiki.Core.Markdown.Folds (Fold (..), FoldKind (..), folds)
import Wiki.Core.Page (Page (body, id))
import Wiki.Core.Space (Space (id))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "folds a block spoiler and a heading spoiler by the gutter, offers nothing else, tells of each fold and saves the text as it is" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    host <- editorHost ui
    -- Two markers: the spoilers'. The fence, the paragraphs and the other
    -- headings offer none.
    _ <- offered ui 2
    watchEditor ui
    offered ui 2 >>= traverse_ click . head
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11)]
    offered ui 1 >>= traverse_ click . head
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11), (13, 19)]
    -- Each fold is told, and no input event comes: the text did not change.
    foldsTold ui `shouldReturn` [[(5, 11)], [(5, 11), (13, 19)]]
    inputsSeen ui `shouldReturn` 0
    -- The hidden lines are not shown; the first lines are, each with its
    -- mark, which says how many lines it hides.
    shown <- editorText ui >>= textContent
    shown `shouldSatisfy` T.isInfixOf "[[!spoiler]]{answer}(The answer)"
    shown `shouldSatisfy` T.isInfixOf "## [[!spoiler]] Question"
    shown `shouldSatisfy` T.isInfixOf "After."
    shown `shouldSatisfy` (not . T.isInfixOf "Forty-two.")
    shown `shouldSatisfy` (not . T.isInfixOf "Hidden answer.")
    marks <- findAll ui ".editor-cm .cm-wiki-folded"
    labels <- traverse (`getAttribute` "aria-label") marks
    labels `shouldBe` [Just "6 lines hidden, click to show them", Just "6 lines hidden, click to show them"]
    -- The text is whole: what the component has, and what it saves.
    markdown ui `shouldReturn` page
    find ui ".editor-save" >>= click
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "Saved")
    saved <- readPage wiki ["blog"] ["hello-world"]
    saved.body `shouldBe` page
    -- A click on a mark unfolds its lines, and so does one on the gutter's
    -- marker of a folded line; each is told, with no input event.
    find ui ".editor-cm .cm-wiki-folded" >>= click
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    find ui ".editor-cm .cm-foldGutter .cm-gutterElement:not([style*=hidden]) .cm-wiki-fold-closed" >>= click
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    foldsTold ui `shouldReturn` [[(5, 11)], [(5, 11), (13, 19)], [(13, 19)], []]
    inputsSeen ui `shouldReturn` 0
    editorText ui >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Hidden answer.")
    markdown ui `shouldReturn` page

  it "keeps a fold on the same lines of text as text is typed above it, below it and at the end of its first line" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    host <- editorHost ui
    _ <- offered ui 2
    watchEditor ui
    -- Folded by the keys, on the heading's line, and told.
    selectText ui (lineStart page 13) (lineStart page 13)
    press "Control+Shift+BracketLeft"
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    foldsTold ui `shouldReturn` [[(13, 19)]]
    text <- editorText ui
    -- At the end of the heading, before the mark: in sight, and folded still.
    selectText ui (lineEnd page 13) (lineEnd page 13)
    typeText text " now"
    let renamed = T.replace "Question\n" "Question now\n" page
    markdown ui `shouldReturn` renamed
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    editorText ui >>= textContent >>= (`shouldSatisfy` T.isInfixOf "Question now")
    -- Below the fold, on the right line.
    selectText ui (T.length renamed) (T.length renamed)
    typeText text "\nTyped."
    markdown ui `shouldReturn` (renamed <> "\nTyped.")
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    -- Typed below or before the mark, the fold kept its lines: nothing new
    -- to tell.
    foldsTold ui `shouldReturn` [[(13, 19)]]
    -- Above it: the fold moves down with its lines, which are the same
    -- text, and the move is told.
    selectText ui (lineEnd page 3) (lineEnd page 3)
    typeText text "\nAbove."
    let typed = T.replace "Before.\n" "Before.\nAbove.\n" renamed <> "\nTyped."
    markdown ui `shouldReturn` typed
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(14, 20)]
    linesOf typed 14 20 `shouldBe` linesOf renamed 13 19
    foldsTold ui `shouldReturn` [[(13, 19)], [(14, 20)]]
    editorText ui >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "Hidden answer."))
    -- And the keys unfold it, on its line.
    selectText ui (lineStart typed 14) (lineStart typed 14)
    press "Control+Shift+BracketRight"
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    foldsTold ui `shouldReturn` [[(13, 19)], [(14, 20)], []]
    markdown ui `shouldReturn` typed
    inputsSeen ui `shouldReturn` T.length " now\nTyped.\nAbove."

  it "opens a fold that an edit changes, at its end, inside it or with a line break at its start, and Backspace after its mark deletes one character, in sight" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    host <- editorHost ui
    unsafeIOToPageM (foldLines host [(5, 11)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11)]
    -- Backspace at the start of the line after the fold would join it to
    -- the hidden end marker: the fold opens.
    selectText ui (lineStart page 12) (lineStart page 12)
    press "Backspace"
    markdown ui `shouldReturn` T.replace "[[/spoiler]]{answer}\n\n" "[[/spoiler]]{answer}\n" page
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    press "Control+z"
    eventually $ markdown ui `shouldReturn` page
    -- With the cursor just after the mark, at the end of the hidden last
    -- line, Backspace deletes the character before it, and the fold opens
    -- on it.
    unsafeIOToPageM (foldLines host [(5, 11)])
    selectText ui (lineEnd page 11) (lineEnd page 11)
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11)]
    press "Backspace"
    markdown ui `shouldReturn` T.replace "[[/spoiler]]{answer}\n" "[[/spoiler]]{answer\n" page
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    press "Control+z"
    eventually $ markdown ui `shouldReturn` page
    -- Enter at the end of the first line, before the mark, would start the
    -- fold on the new line: the fold opens.
    unsafeIOToPageM (foldLines host [(13, 19)])
    selectText ui (lineEnd page 13) (lineEnd page 13)
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    press "Enter"
    markdown ui `shouldReturn` T.replace "Question\n" "Question\n\n" page
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    press "Control+z"
    eventually $ markdown ui `shouldReturn` page
    -- An edit inside a fold that moves no cursor there (the assistant's)
    -- opens it too, rather than leave it on lines it no longer fits; the
    -- opening is told.
    unsafeIOToPageM (foldLines host [(13, 19)])
    watchEditor ui
    proposeText ui (lineEnd page 15) (lineEnd page 15) " Really."
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    foldsTold ui `shouldReturn` [[]]
    markdown ui `shouldReturn` T.replace "Hidden answer.\n" "Hidden answer. Really.\n" page

  it "opens a fold whose first line an edit makes another line, wherever the line break goes, and keeps it for other edits of that line" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    host <- editorHost ui
    let heading = lineStart page 13
        middle = heading + T.length "## [[!spoiler]] Quest"
        -- The page with this edit made, the heading folded before it, and
        -- the folds after it.
        foldedAfter edit = do
          setMarkdown ui page
          unsafeIOToPageM (foldLines host [(13, 19)])
          unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
          edit
          unsafeIOToPageM (foldedLines host)
        replaced start end new = T.take start page <> new <> T.drop end page
    -- Enter in the middle of the heading.
    foldedAfter (selectText ui middle middle >> press "Enter") `shouldReturn` []
    markdown ui `shouldReturn` replaced middle middle "\n"
    -- A line break put in its middle, at its start and at its end, by an
    -- edit that moves no cursor (the assistant's).
    foldedAfter (proposeText ui middle middle "\n") `shouldReturn` []
    foldedAfter (proposeText ui heading heading "\n") `shouldReturn` []
    foldedAfter (proposeText ui (lineEnd page 13) (lineEnd page 13) "\n") `shouldReturn` []
    -- A replacement from its middle over its end.
    foldedAfter (proposeText ui middle (lineEnd page 13 + 1) "ion") `shouldReturn` []
    markdown ui `shouldReturn` replaced middle (lineEnd page 13 + 1) "ion"
    -- The line joined to the one above.
    foldedAfter (proposeText ui (heading - 1) heading "") `shouldReturn` []
    -- Text replaced within the line, with no line break, keeps the fold on
    -- it, and a line break above moves the fold down with its line.
    foldedAfter (proposeText ui (heading + T.length "## [[!spoiler]] ") (lineEnd page 13) "Q") `shouldReturn` [(13, 19)]
    markdown ui `shouldReturn` T.replace "Question\n" "Q\n" page
    foldedAfter (proposeText ui (lineEnd page 11) (lineEnd page 11) "\n") `shouldReturn` [(14, 20)]

  it "folds and unfolds a heading's section and a spoiler from the component, reports the folds, and tells nothing of them" $ runPage $ do
    (ui, _) <- startWith m (Just "user-editor") helloEditor
    setMarkdown ui page
    host <- editorHost ui
    watchEditor ui
    -- The section of "## Next", as the component would find it.
    let named title = head [f | f <- folds page, lineAt page f.from == title]
    next <- maybe (expectationFailure "no section" >> pure (Fold 0 0 (Section 0))) pure (named "## Next")
    next.kind `shouldBe` Section 2
    unsafeIOToPageM (foldLines host [(next.from, next.to)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(21, 23)]
    editorText ui >>= textContent >>= (`shouldSatisfy` (not . T.isInfixOf "After."))
    unsafeIOToPageM (foldLines host [(5, 11), (13, 19)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11), (13, 19), (21, 23)]
    markdown ui `shouldReturn` page
    unsafeIOToPageM (unfoldLines host [(21, 23), (5, 11)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    unsafeIOToPageM (unfoldLines host [(13, 19)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    -- Lines the text does not have, and a range of one line, fold nothing.
    unsafeIOToPageM (foldLines host [(22, 40), (3, 3)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    -- Ranges in any order fold in the order of the text, and unfold so.
    unsafeIOToPageM (foldLines host [(21, 23), (13, 19), (5, 11)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 11), (13, 19), (21, 23)]
    unsafeIOToPageM (unfoldLines host [(21, 23), (5, 11), (13, 19), (13, 19)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` []
    -- The same range twice folds once; of two that nest, the outer one
    -- folds; of two that overlap, the first in the text; and a range that
    -- overlaps a fold made before does not.
    unsafeIOToPageM (foldLines host [(13, 19), (13, 19)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 19)]
    unsafeIOToPageM (foldLines host [(5, 15), (3, 11)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(3, 11), (13, 19)]
    unsafeIOToPageM (unfoldLines host [(3, 11), (13, 19)])
    unsafeIOToPageM (foldLines host [(15, 19), (13, 23)])
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(13, 23)]
    -- What the component folds it knows: no event, and no input.
    foldsTold ui `shouldReturn` []
    inputsSeen ui `shouldReturn` 0
  it "makes no change of the page by folding: no draft, and Cancel leaves without asking" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") helloEditor
    host <- editorHost ui
    original <- markdown ui
    watchEditor ui
    -- The section "## Why a wiki" of the page as it is, folded from the
    -- component and unfolded by its mark.
    let section = head [(f.from, f.to) | f <- folds original, lineAt original f.from == "## Why a wiki"]
    section `shouldSatisfy` isJust
    unsafeIOToPageM (foldLines host (maybeToList section))
    unsafeIOToPageM (foldedLines host) `shouldReturn` maybeToList section
    find ui ".editor-cm .cm-wiki-folded" >>= click
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    foldsTold ui `shouldReturn` [[]]
    inputsSeen ui `shouldReturn` 0
    -- Longer than the wait before a draft is saved: none is.
    unsafeIOToPageM (threadDelay (draftDelay + 500_000))
    hello <- readPage wiki ["blog"] ["hello-world"]
    draftOf wiki hello `shouldReturn` Nothing
    find ui ".editor-cancel" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Hello, world")
    length <$> findAll ui ".editor-cancel-confirm" `shouldReturn` 0
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

-- | A page with a block spoiler (lines 5 to 11), a heading spoiler (13 to
-- 19) and a section that is no spoiler (21 to 23).
page :: Text
page =
  T.intercalate
    "\n"
    [ "# Hello, world"
    , ""
    , "Before."
    , ""
    , "[[!spoiler]]{answer}(The answer)"
    , "Forty-two."
    , ""
    , "```"
    , "code"
    , "```"
    , "[[/spoiler]]{answer}"
    , ""
    , "## [[!spoiler]] Question"
    , ""
    , "Hidden answer."
    , ""
    , "### Deeper"
    , ""
    , "More."
    , ""
    , "## Next"
    , ""
    , "After."
    ]

-- | The gutter's markers of the lines that can be folded, once the editor
-- offers this many.
offered :: Mounted s q o m -> Int -> PageM s [Element s]
offered ui count = eventually $ do
  found <- findAll ui ".editor-cm .cm-foldGutter .cm-wiki-fold-open"
  length found `shouldBe` count
  pure found

-- | A line of a text, from 1.
lineAt :: Text -> Int -> Text
lineAt text n = fromMaybe "" (head (drop (n - 1) (T.splitOn "\n" text)))

-- | Some lines of a text, from the first to the last (from 1).
linesOf :: Text -> Int -> Int -> [Text]
linesOf text first' last' = take (last' - first' + 1) (drop (first' - 1) (T.splitOn "\n" text))

-- | Where a line of a text starts and ends, in characters (the texts here
-- are ASCII, so characters are UTF-16 units).
lineStart :: Text -> Int -> Int
lineStart text n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" text)))

lineEnd :: Text -> Int -> Int
lineEnd text n = lineStart text n + T.length (lineAt text n)

-- | A page of the demo's wiki as it is stored.
readPage :: IORef MemState -> [Text] -> [Text] -> PageM s Page
readPage wiki space path =
  unsafeIOToPageM . runMemWiki wiki $ do
    s <- either (panic . show) identity <$> getSpace (slugs space)
    either (panic . show) identity <$> getPage s.id (slugs path)

-- | The author's draft of a page, if there is one.
draftOf :: IORef MemState -> Page -> PageM s (Maybe Draft)
draftOf wiki p = unsafeIOToPageM (runMemWiki wiki (either (panic . show) identity <$> getDraft p.id))
