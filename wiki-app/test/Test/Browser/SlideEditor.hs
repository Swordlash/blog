{-# LANGUAGE TemplateHaskell #-}

-- | The editor of a presentation (WP5.97 of docs/PLAN.md), in a browser,
-- in the shell, over the demo's wiki with its "Hello, world" made a
-- presentation: slide by slide, every slide folded but the cursor's when
-- the editor opens, one opened at a time by its button and more with
-- Ctrl; the switch to the raw Markdown and back, which the browser keeps
-- and which changes no byte, of a text with carriage returns too; a slide
-- moved by Alt+Up and Alt+Down and by its handle, before or after the
-- slide it is dropped on, as one edit that one undo takes back; a new slide; and the preview, which shows the cursor's
-- slide, or the whole deck.
module Test.Browser.SlideEditor (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startOn, startWith)
import Test.Browser.Text (editorHost, editorText, inputsSeen, markdown, selectText, setMarkdown, watchEditor)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Editor.Browser (foldedLines)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Shell qualified as Shell
import Wiki.Core.Page (Page (id, updatedAt))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Slides (moveSlide)
import Wiki.Core.Space (Space (id))

$( browserJS
     ["jsbits/test-slides.js"]
     [ ("js_ctrl_click", "wiki_test_ctrl_click", Safe, [t|JSText -> Int -> IO Bool|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "folds every slide but the cursor's as the editor opens, and opens one at a time by its button, more with Ctrl" $ runPage $ do
    (ui, _) <- openDeck
    host <- editorHost ui
    -- The cursor starts under the title line, on the title slide.
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- Each slide has its button; each but the title slide its handle.
    length <$> findAll ui ".editor-cm .cm-wiki-slide-toggle" `shouldReturn` 4
    length <$> findAll ui ".editor-cm .cm-wiki-slide-handle" `shouldReturn` 3
    watchEditor ui
    toggles ui >>= traverse_ click . (`atMay` 2)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    unsafeIOToPageM (js_ctrl_click (toJSText ".editor-cm .cm-wiki-slide-toggle") 3) `shouldReturn` True
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7)]
    -- An open slide's button closes it.
    toggles ui >>= traverse_ click . (`atMay` 3)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    -- Folds change what is shown, never the text.
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck

  it "opens one slide and closes the others by its fold's mark and by the keys too, keeps them open with Ctrl, and leaves them as they are when an edit opens one" $ runPage $ do
    (ui, _) <- openDeck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- The marks of "One", "Two" and "Three", in the order of the text.
    findAll ui ".editor-cm .cm-wiki-folded" >>= traverse_ click . (`atMay` 1)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (13, 15)]
    -- Now the title slide's, "One"'s and "Three"'s: Ctrl on the click on
    -- "Three"'s keeps "Two" open.
    unsafeIOToPageM (js_ctrl_click (toJSText ".editor-cm .cm-wiki-folded") 2) `shouldReturn` True
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7)]
    -- The key that unfolds the cursor's line.
    selectText ui (lineStart deck 5) (lineStart deck 5)
    press "Control+Shift+BracketRight"
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (9, 11), (13, 15)]
    -- Backspace at the start of the line after "Two" joins it to the
    -- hidden last line: an edit opens the fold, and the others stay.
    selectText ui (lineStart deck 12) (lineStart deck 12)
    press "Backspace"
    eventually $ markdown ui `shouldReturn` T.replace "Second.\n\n" "Second.\n" deck
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (12, 14)]
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "switches to the raw Markdown and back, which the browser keeps, changing no byte, of a text with carriage returns and no final line break too" $ runPage $ do
    (ui, wiki) <- openDeck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    watchEditor ui
    modeButton ui "Raw" >>= click
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` []
    eventually $ length <$> findAll ui ".editor-cm .cm-wiki-slide-toggle" `shouldReturn` 0
    modeButton ui "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    inputsSeen ui `shouldReturn` 0
    markdown ui `shouldReturn` deck
    -- The browser keeps the mode: the editor opened again is in it.
    again <- startOn m wiki helloEditor
    againHost <- editorHost again
    modeButton again "Raw" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    unsafeIOToPageM (foldedLines againHost) `shouldReturn` []
    modeButton again "Slides" >>= click
    eventually $ unsafeIOToPageM (foldedLines againHost) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    markdown again `shouldReturn` deck
    -- A text with carriage returns has no slides to fold or move: the
    -- editor says so, and either mode leaves every byte as it is.
    let returns = T.replace "\n" "\r\n" deck
    setMarkdown again returns
    watchEditor again
    find again ".editor-slides-note" >>= (`shouldHaveText` "This text has carriage returns, so its slides cannot be folded or moved here.")
    eventually $ length <$> findAll again ".editor-cm .cm-wiki-slide-toggle" `shouldReturn` 0
    modeButton again "Raw" >>= click
    modeButton again "Slides" >>= click
    unsafeIOToPageM (foldedLines againHost) `shouldReturn` []
    inputsSeen again `shouldReturn` 0
    markdown again `shouldReturn` returns

  it "moves the cursor's slide with Alt+Up and Alt+Down as one edit that one undo takes back, the title slide staying first" $ runPage $ do
    (ui, _) <- openDeck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    selectText ui (lineStart deck 9) (lineStart deck 9)
    press "Alt+ArrowUp"
    let moved = moveSlide 2 1 deck
    eventually $ markdown ui `shouldReturn` moved
    moved `shouldBe` T.intercalate "\n" ["# Deck", "", "By me.", "", "## Two", "", "Second.", "", "## One", "", "First.", "", "## Three", "", "Third."]
    -- The slides folded before ("One" and "Three") are folded at their new
    -- places; the slide moved is open, with the cursor in it, and the
    -- title slide, open before, is still.
    unsafeIOToPageM (foldedLines host) `shouldReturn` [(9, 11), (13, 15)]
    -- Up again would put it before the title slide: no move.
    press "Alt+ArrowUp"
    markdown ui `shouldReturn` moved
    press "Alt+ArrowDown"
    eventually $ markdown ui `shouldReturn` deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` moved
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck

  it "moves a slide dragged by its handle onto another, and adds a new slide at the end, its title selected" $ runPage $ do
    (ui, _) <- openDeck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    -- Dropped on another slide's first line, the slide goes before it.
    handles <- findAll ui ".editor-cm .cm-wiki-slide-handle"
    target <- lineWith ui "## Three"
    traverse_ (`dragTo` target) (head handles)
    eventually $ markdown ui `shouldReturn` moveSlide 1 2 deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    -- Dropped below a slide's first line, a slide goes after it. The
    -- controls of the slides the undo rewrote come back with the check of
    -- the text.
    eventually $ length <$> toggles ui `shouldReturn` 4
    toggles ui >>= traverse_ click . (`atMay` 3)
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (9, 11)]
    below <- lineWith ui "Third."
    findAll ui ".editor-cm .cm-wiki-slide-handle" >>= traverse_ (`dragTo` below) . head
    eventually $ markdown ui `shouldReturn` moveSlide 1 3 deck
    press "Control+z"
    eventually $ markdown ui `shouldReturn` deck
    find ui ".editor-new-slide" >>= click
    eventually $ markdown ui `shouldReturn` (deck <> "\n\n## New slide\n")
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(1, 3), (5, 7), (9, 11), (13, 15)]
    editorText ui >>= (`typeText` "Four")
    markdown ui `shouldReturn` (deck <> "\n\n## Four\n")

  it "shows the cursor's slide in the preview, and in the raw Markdown the whole deck or one slide" $ runPage $ do
    (ui, _) <- openDeck
    host <- editorHost ui
    eventually $ unsafeIOToPageM (foldedLines host) `shouldReturn` [(5, 7), (9, 11), (13, 15)]
    find ui ".editor-side-by-side" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck"]
    selectText ui (lineStart deck 9) (lineStart deck 9)
    eventually $ cardTitles ui `shouldReturn` ["Two"]
    find ui ".editor-preview .slide-number" >>= (`shouldHaveText` "3 / 4")
    modeButton ui "Raw" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Deck", "One", "Two", "Three"]
    find ui ".editor-one-slide" >>= click
    eventually $ cardTitles ui `shouldReturn` ["Two"]
  where
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

    -- The demo's "Hello, world", made a presentation with the deck as its
    -- text, open in the editor.
    openDeck :: forall s. PageM s (Mounted s Shell.Query Void m, IORef MemState)
    openDeck = do
      (_, wiki) <- startWith m (Just "user-editor") (Page (slugs ["blog"]) (slugs ["hello-world"]))
      unsafeIOToPageM . runMemWiki wiki $ do
        blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
        hello <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
        made <- either (panic . show) identity <$> setPageKind hello.id Kind.Presentation
        void (either (panic . show) identity <$> savePage made.id made.updatedAt "Deck" deck)
      ui <- startOn m wiki helloEditor
      _ <- editorText ui
      pure (ui, wiki)

-- | The presentation the tests edit: a title slide and three others,
-- with no line break at the end.
deck :: Text
deck = T.intercalate "\n" ["# Deck", "", "By me.", "", "## One", "", "First.", "", "## Two", "", "Second.", "", "## Three", "", "Third."]

-- | The slides' buttons, in the order of the text.
toggles :: Mounted s q o m -> PageM s [Element s]
toggles ui = findAll ui ".editor-cm .cm-wiki-slide-toggle"

-- | One of the two buttons of the switch between slide by slide and the
-- raw Markdown, by its text.
modeButton :: Mounted s q o m -> Text -> PageM s (Element s)
modeButton ui label = eventually $ do
  buttons <- findAll ui ".editor-slides-mode button"
  named <- filterM (fmap (== label) . textContent) buttons
  maybe (expectationFailure ("no button " <> label)) pure (head named)

-- | The editor's line shown with this text.
lineWith :: Mounted s q o m -> Text -> PageM s (Element s)
lineWith ui text = eventually $ do
  lines' <- findAll ui ".editor-cm .cm-line"
  named <- filterM (fmap (T.isInfixOf text) . textContent) lines'
  maybe (expectationFailure ("no line with " <> text)) pure (head named)

-- | The titles of the slides the preview shows.
cardTitles :: Mounted s q o m -> PageM s [Text]
cardTitles ui = findAll ui ".editor-preview .slides-preview .slide-title" >>= traverse textContent

-- | Where a line of a text starts, in characters (the text is ASCII, so
-- characters are UTF-16 units).
lineStart :: Text -> Int -> Int
lineStart text n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" text)))
