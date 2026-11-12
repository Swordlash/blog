{-# LANGUAGE TemplateHaskell #-}

-- | Tables of contents and templates (WP4.15 of docs/PLAN.md) in a browser,
-- over the demo's wiki: the "Contents" panel beside a long page, which
-- marks the section being read as the page scrolls and stays folded once
-- folded; @[[!toc]]@ placing the list in the page instead; a heading's link
-- to itself; a page made a template, listed apart from the tree; and "New
-- page" from a template, the space's and a built-in one, with its
-- placeholders filled in. And a footnote's number, titled with its note,
-- which scrolls to the note when followed.
module Test.Browser.Contents (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.IORef (IORef)
import Data.Text qualified as T
import Data.Time (getCurrentTime, utctDay)
import Data.Time.Format.ISO8601 (iso8601Show)
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, start, startWith)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (runMemWiki)
import Wiki.App.Backend.Mem.State (MemState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Page (Page (body, kind, template))
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Space (Space (id))

-- Where things are in the window (test/jsbits/test-layout.js).
$( browserJS
     ["jsbits/test-layout.js"]
     [ ("js_scroll_toPromise", "wiki_test_scroll_to", Safe, [t|Int -> IO (Promise ())|])
     , ("js_scroll_into_viewPromise", "wiki_test_scroll_into_view", Safe, [t|JSText -> IO (Promise ())|])
     , ("js_box", "wiki_test_box", Safe, [t|JSText -> IO JSText|])
     ]
 )

js_scroll_to :: Int -> IO ()
js_scroll_to a1 = if inBrowser then wait =<< js_scroll_toPromise a1 else pure inert

js_scroll_into_view :: JSText -> IO ()
js_scroll_into_view a1 = if inBrowser then wait =<< js_scroll_into_viewPromise a1 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
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
    deeper `shouldBe` ["Lists", "Tasks", "Tables", "Emoji"]
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

  it "shows no panel for a page with few headings, and the list where [[!toc]] is" $ runPage $ do
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
    -- A click copies the section's address rather than following it
    -- (WP5.53), and the page stays as it is: the browser may refuse the
    -- clipboard here, and the notice shows the address either way.
    click anchor
    eventually $ find ui ".link-copied-address" >>= textContent >>= (`shouldSatisfy` T.isSuffixOf "/#code")
    find ui ".link-copied-label" >>= textContent >>= (`shouldSatisfy` (`elem` ["Link copied:", "The link could not be copied. It is selected, to copy by hand:"]))
    getAttribute anchor "href" `shouldReturn` Just "#code"
    find ui ".page-body h2#code" >>= (`shouldHaveText` "Code")

  -- Back to the reference is the browser's, under the application's
  -- router (Wiki.App.Browser.followArticleLink); the test router keeps the
  -- route in the fragment, where no entry for the note can go.
  it "titles a footnote's number with its note, and scrolls to the note when the number is followed" $ runPage $ do
    ui <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    reference <- find ui ".page-body sup.footnote-ref a[href='#fn-1']"
    getAttribute reference "id" `shouldReturn` Just "fnref-1"
    getAttribute reference "title" `shouldReturn` Just "A path without a leading slash is read from this page's own address, as a browser reads a relative link."
    -- The note is at the end of a long page, out of sight from the top.
    scrollTop 0
    noteBox >>= (`shouldSatisfy` \(top, _, window) -> top > window)
    click reference
    eventually $ noteBox >>= (`shouldSatisfy` \(top, _, window) -> top >= 0 && top < window)

  it "makes a page a template, listed apart from the tree, and an ordinary page again" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"]))
    _ <- find ui ".page-actions .use-as-template"
    tree <- traverse textContent =<< findAll ui ".wiki-sidebar .page-tree a"
    tree `shouldBe` ["Markdown guide", "Diagrams", "Mathematics", "Presentations"]
    length <$> findAll ui ".sidebar-templates" `shouldReturn` 0
    toggle <- find ui ".page-actions .use-as-template"
    getAttribute toggle "aria-pressed" `shouldReturn` Just "false"
    click toggle
    find ui ".template-note" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "{{title}}")
    find ui ".page-actions .use-as-template" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    eventually $ (traverse textContent =<< findAll ui ".wiki-sidebar .sidebar-templates a") `shouldReturn` ["Diagrams"]
    (traverse textContent =<< findAll ui ".wiki-sidebar .page-tree a") `shouldReturn` ["Markdown guide", "Mathematics", "Presentations"]
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

  it "makes a presentation, offering a presentation's templates only, and starts a document again blank" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-editor") (NewPage (slugs ["blog"]) Nothing)
    kinds <- traverse textContent =<< findAll ui ".new-page-kind-choice"
    map (T.takeWhile (/= ' ') . T.strip) kinds `shouldBe` ["Document", "Presentation"]
    chooseKind ui "Presentation"
    eventually $ (map (T.takeWhile (/= ' ') . T.strip) <$> (traverse textContent =<< findAll ui ".new-page-choice")) `shouldReturn` ["Blank", "Starter"]
    chooseStart ui "Starter deck"
    -- Back to a document: its templates, and blank again.
    chooseKind ui "Document"
    eventually $ (map (T.takeWhile (/= ' ') . T.strip) <$> (traverse textContent =<< findAll ui ".new-page-choice")) `shouldReturn` ["Blank", "Meeting", "Decision", "How-to"]
    checked <- filterM (\c -> (== "true") <$> (findIn c "input" >>= (`getProperty` "checked"))) =<< findAll ui ".new-page-choice"
    traverse (fmap (T.takeWhile (/= ' ') . T.strip) . textContent) checked `shouldReturn` ["Blank"]
    chooseKind ui "Presentation"
    find ui ".new-page-title" >>= (`typeText` "Quarterly review")
    chooseStart ui "Starter deck"
    find ui ".new-page-view button.primary" >>= click
    find ui ".editor-heading" >>= (`shouldHaveText` "Editing Quarterly review")
    made <- readPage wiki ["blog"] ["quarterly-review"]
    made.kind `shouldBe` Kind.Presentation
    T.take 19 made.body `shouldBe` "# Quarterly review\n"
    made.body `shouldSatisfy` (not . T.isInfixOf "{{")

  it "makes a page a presentation, which is offered to be presented, and a document again" $ runPage $ do
    (ui, wiki) <- startWith m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"]))
    toggle <- find ui ".page-actions .page-kind"
    getAttribute toggle "aria-pressed" `shouldReturn` Just "false"
    length <$> findAll ui ".page-actions a.page-present" `shouldReturn` 0
    click toggle
    _ <- find ui ".page-actions a.page-present"
    find ui ".page-actions .page-kind" >>= (`getAttribute` "aria-pressed") >>= (`shouldBe` Just "true")
    (\p -> p.kind) <$> readPage wiki ["docs"] ["markdown-guide", "diagrams"] `shouldReturn` Kind.Presentation
    find ui ".page-actions .page-kind" >>= click
    eventually $ length <$> findAll ui ".page-actions a.page-present" `shouldReturn` 0
    (\p -> p.kind) <$> readPage wiki ["docs"] ["markdown-guide", "diagrams"] `shouldReturn` Kind.Document

  it "keeps a space's home page a document: it has no choice of kind" $ runPage $ do
    ui <- start m (Just "user-admin") (Space (slugs ["docs"]))
    _ <- find ui ".page-actions"
    length <$> findAll ui ".page-actions .page-kind" `shouldReturn` 0
  where
    -- The links marked as the section being read, in every list of the
    -- page's headings.
    current ui = do
      marked <- findAll ui ".toc-list a[data-current]"
      ordNub . catMaybes <$> traverse (`getAttribute` "href") marked
    scrollTo selector = unsafeIOToPageM (evaluate =<< js_scroll_into_view (toJSText selector))
    scrollTop y = unsafeIOToPageM (evaluate =<< js_scroll_to y)
    -- Where the first footnote is in the window: its top, its bottom and
    -- the window's height.
    noteBox = do
      found <- unsafeIOToPageM (fromJSText <$> js_box (toJSText ("#fn-1" :: Text)))
      case mapMaybe (readMaybe . T.unpack) (T.words found) of
        [top, bottom, window] -> pure (top, bottom, window :: Double)
        _ -> expectationFailure "no footnote" >> pure (0, 0, 0)
    chooseKind ui label = do
      choices <- findAll ui ".new-page-kind-choice"
      labelled <- filterM (fmap (T.isPrefixOf label . T.strip) . textContent) choices
      case labelled of
        c : _ -> findIn c "input" >>= click
        [] -> expectationFailure ("no kind says " <> toS label)
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
