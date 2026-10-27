{-# LANGUAGE TemplateHaskell #-}

-- | Tables of contents and templates (WP4.15 of docs/PLAN.md) in a browser,
-- over the demo's wiki: the "Contents" panel beside a long page, which
-- marks the section being read as the page scrolls and stays folded once
-- folded; @[[toc]]@ placing the list in the page instead; a heading's link
-- to itself; a page made a template, listed apart from the tree; and "New
-- page" from a template, the space's and a built-in one, with its
-- placeholders filled in.
module Test.Browser.Contents (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Data.Time (getCurrentTime, utctDay)
import Data.Time.Format.ISO8601 (iso8601Show)
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start, startWith)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Page (Page (body, template))
import Wiki.Core.Space (Space (id))

-- Where things are in the window (test/jsbits/test-layout.js).
$( browserJS
     ["jsbits/test-layout.js"]
     [ ("js_scroll_to", "wiki_test_scroll_to", Safe, [t|Int -> IO ()|])
     , ("js_scroll_into_view", "wiki_test_scroll_into_view", Safe, [t|JSText -> IO ()|])
     ]
 )

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "lists a long page's headings beside it, and marks the section being read as it scrolls" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    panel <- find ui ".page-side .page-contents"
    getAttribute panel "open" `shouldReturn` Just ""
    titles <- traverse textContent =<< findAll ui ".page-contents nav > .toc-list > li > a"
    titles `shouldBe` ["Markdown guide"]
    nested <- traverse textContent =<< findAll ui ".page-contents nav > .toc-list > li > .toc-list > li > a"
    take 3 nested `shouldBe` ["Text", "Code", "Mathematics"]
    deeper <- traverse textContent =<< findAll ui ".page-contents a[href='#text'] + .toc-list > li > a"
    deeper `shouldBe` ["Lists", "Tasks", "Tables"]
    -- Nothing of the panel's in the page's text.
    length <$> findAll ui ".page-text .toc" `shouldReturn` 0
    -- At the top, the first section is the one read.
    eventually $ current ui `shouldReturn` ["#markdown-guide"]
    scrollTo "#tables"
    eventually $ current ui `shouldReturn` ["#tables"]
    scrollTo "#mathematics"
    eventually $ current ui `shouldReturn` ["#mathematics"]
    -- A section's link scrolls to it: the last, at the end of the page,
    -- which cannot be scrolled to the top of the window.
    find ui ".page-contents a[href='#images-video-and-attachments']" >>= click
    eventually $ current ui `shouldReturn` ["#images-video-and-attachments"]
    scrollTop 0
    eventually $ current ui `shouldReturn` ["#markdown-guide"]

  it "folds the panel, and keeps it folded on the next long page" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    find ui ".page-contents-title" >>= click
    eventually $ find ui ".page-contents" >>= (`getAttribute` "open") >>= (`shouldBe` Nothing)
    find ui ".page-contents .toc-list" >>= shouldBeHidden
    unmount ui
    again <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    eventually $ find again ".page-contents" >>= (`getAttribute` "open") >>= (`shouldBe` Nothing)
    -- Unfolded again, for whatever comes next in this browser.
    find again ".page-contents-title" >>= click
    eventually $ find again ".page-contents .toc-list" >>= shouldBeVisible

  it "shows no panel for a page with few headings, and the list where [[toc]] is" $ runPage $ do
    ui <- start m (Just "user-admin") (Page (slugs ["team"]) (slugs ["team-handbook", "on-call"]))
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "On-call")
    length <$> findAll ui ".page-contents" `shouldReturn` 0
    unmount ui
    handbook <- start m (Just "user-admin") (Page (slugs ["team"]) (slugs ["team-handbook"]))
    _ <- find handbook ".page-body nav.toc"
    inline <- traverse textContent =<< findAll handbook ".page-body nav.toc .toc-list a"
    inline `shouldBe` ["Team handbook", "The week", "Before your first day", "Meetings"]
    length <$> findAll handbook ".page-contents" `shouldReturn` 0
    -- Its links are followed in the page, and mark the section too.
    find handbook ".page-body nav.toc a[href='#meetings']" >>= click
    eventually $ current handbook `shouldReturn` ["#meetings"]

  it "ends each heading with a link to itself" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    anchor <- find ui ".page-body h2#code > a.heading-anchor"
    getAttribute anchor "href" `shouldReturn` Just "#code"
    -- It adds nothing to the heading's text.
    find ui ".page-body h2#code" >>= (`shouldHaveText` "Code")
    -- Shown on hover only, by the stylesheet.
    getAttribute anchor "aria-label" `shouldReturn` Just "Link to this section"
    click anchor
    eventually $ current ui `shouldReturn` ["#code"]

  it "makes a page a template, listed apart from the tree, and an ordinary page again" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"]))
    _ <- find ui ".page-actions .use-as-template"
    tree <- traverse textContent =<< findAll ui ".wiki-sidebar .page-tree a"
    tree `shouldBe` ["Markdown guide", "Diagrams", "Mathematics", "Presentations", "Tour"]
    length <$> findAll ui ".sidebar-templates" `shouldReturn` 0
    toggle <- find ui ".page-actions .use-as-template"
    getAttribute toggle "aria-pressed" `shouldReturn` Just "false"
    click toggle
    find ui ".template-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "{{title}}")
    find ui ".page-actions .use-as-template" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    eventually $ (traverse textContent =<< findAll ui ".wiki-sidebar .sidebar-templates a") `shouldReturn` ["Diagrams"]
    (traverse textContent =<< findAll ui ".wiki-sidebar .page-tree a") `shouldReturn` ["Markdown guide", "Mathematics", "Presentations", "Tour"]
    (\p -> p.template) <$> readPage wiki ["docs"] ["markdown-guide", "diagrams"] `shouldReturn` True
    find ui ".page-actions .use-as-template" >>= click
    eventually $ length <$> findAll ui ".sidebar-templates" `shouldReturn` 0
    length <$> findAll ui ".template-note" `shouldReturn` 0
    (\p -> p.template) <$> readPage wiki ["docs"] ["markdown-guide", "diagrams"] `shouldReturn` False

  it "makes a new page from the space's template, its placeholders filled in" $ runPage $ do
    ui <- start m (Just "user-admin") (Space (slugs ["team"]))
    _ <- find ui ".wiki-sidebar .sidebar-templates a"
    (traverse textContent =<< findAll ui ".wiki-sidebar .sidebar-templates a") `shouldReturn` ["Weekly sync"]
    unmount ui
    (form, wiki) <- startWith m (Just "user-admin") (NewPage (slugs ["team"]) Nothing)
    _ <- find form ".new-page-choice"
    choices <- traverse textContent =<< findAll form ".new-page-choice"
    map (T.takeWhile (/= ' ') . T.strip) choices `shouldBe` ["Blank", "Weekly", "Meeting", "Decision", "How-to"]
    find form ".new-page-title" >>= (`typeText` "Sync of the 26th")
    chooseStart form "Weekly sync"
    find form ".new-page-view button.primary" >>= click
    find form ".editor-heading" >>= (`shouldHaveText` "Editing Sync of the 26th")
    today <- unsafeIOToPageM (toS . iso8601Show . utctDay <$> getCurrentTime)
    made <- readPage wiki ["team"] ["sync-of-the-26th"]
    T.lines made.body
      `shouldSatisfy` (\ls -> take 3 ls == ["# Sync of the 26th", "", "Weekly sync of " <> today <> ", notes by Ada Admin."])
    -- The template keeps its placeholders.
    (\p -> T.take 11 p.body) <$> readPage wiki ["team"] ["weekly-sync"] `shouldReturn` "# {{title}}"

  it "makes a new page from a built-in template, and a blank one" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (NewPage (slugs ["blog"]) Nothing)
    find ui ".new-page-title" >>= (`typeText` "Pick a database")
    chooseStart ui "Decision record"
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Pick a database")
    made <- readPage wiki ["blog"] ["pick-a-database"]
    T.take 18 made.body `shouldBe` "# Pick a database\n"
    made.body `shouldSatisfy` T.isInfixOf "| **Written by** | Edgar Editor |"
    made.body `shouldSatisfy` (not . T.isInfixOf "{{")
  where
    -- The links marked as the section being read, in every list of the
    -- page's headings.
    current ui = do
      marked <- findAll ui ".toc-list a[data-current]"
      ordNub . catMaybes <$> traverse (`getAttribute` "href") marked
    scrollTo selector = unsafeIOToPageM (evaluate =<< js_scroll_into_view (toJSText selector))
    scrollTop y = unsafeIOToPageM (evaluate =<< js_scroll_to y)
    chooseStart ui label = do
      choices <- findAll ui ".new-page-choice"
      labelled <- filterM (fmap (T.isPrefixOf label . T.strip) . textContent) choices
      case labelled of
        c : _ -> findIn c "input" >>= click
        [] -> expectationFailure ("no choice says " <> toS label)

readPage :: IORef MemState -> [Text] -> [Text] -> PageM s Page
readPage wiki space path =
  unsafeIOToPageM . runMemWiki wiki $ do
    s <- either (panic . show) identity <$> getSpace (slugs space)
    either (panic . show) identity <$> getPage s.id (slugs path)
