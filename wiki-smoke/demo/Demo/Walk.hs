-- | The second part of the demo's smoke test: one long walk in one page, as
-- someone would take it. The front page, every root space and a page in
-- each, a page's source and back, the editor as admin with a save, a new
-- page made from its title and saved with Ctrl+S and with Save and close,
-- a page from a template, search, then back through the whole history and
-- forward again, each step checked by its address and what is on screen.
-- Then leaving the editor with changes by the back button (Stay, then
-- Leave), a page saved twice more with its history, a version's diff and
-- the version restored; a reload on a page that keeps the edit (the demo
-- keeps its content in IndexedDB); the administration's export (a zip
-- file of directories, one per space and page, the edited page's body in
-- its page.md), its reset taking the edit away for good and its import
-- bringing it back; a reload on a page's source; 404.html for an address
-- with no file, the administration's and an editor's among them; a page's
-- permanent address; and a link to another page's section.
--
-- No click may load a page: the walk marks the window, and the shell the
-- page arrived with must stay ('samePage').
module Demo.Walk (Walk, newWalk, spec) where

import Codec.Archive.Zip (filesInArchive, findEntryByPath, fromEntry, toArchive)
import Control.Monad (forM_, unless, when)
import Data.Aeson (Value (..), decode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isDigit)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.Encoding.Error qualified as Text
import Data.Time (getCurrentTime, utctDay)
import Demo.Site
import GHC.Stack (HasCallStack)
import Halogen.Playwright
import Halogen.Playwright.Hspec
import System.Directory (getFileSize)
import System.FilePath ((</>))
import Wiki.Smoke.Adoption
import Wiki.Smoke.Demo

-- | What the walk's examples share beside the page.
data Walk = Walk
  { site :: Site
  , chain :: Chain
  , gate :: ProgramGate
  , visits :: IORef [Visit]
  -- ^ Every entry of the history the walk makes, and what it shows, the
  -- latest last.
  , exported :: IORef (Maybe (Text, ByteString))
  -- ^ The export's file name and bytes, for the import.
  }

newWalk :: Site -> IO Walk
newWalk site = do
  chain <- newChain
  gate <- newProgramGate
  visits <- newIORef []
  exported <- newIORef Nothing
  pure Walk {site, chain, gate, visits, exported}

-- | An entry of the history: the route, the view it is in, its
-- breadcrumb, a text the content has, and the step that made it.
data Visit = Visit
  { visitPath :: Text
  , visitView :: Text
  , visitCrumb :: Maybe Text
  , visitText :: Maybe Text
  , visitStep :: Text
  }

at :: Text -> Text -> Visit
at visitPath visitView = Visit {visitPath, visitView, visitCrumb = Nothing, visitText = Nothing, visitStep = ""}

named :: Text -> Visit -> Visit
named c v = v {visitCrumb = Just c}

saying :: Text -> Visit -> Visit
saying t v = v {visitText = Just t}

spec :: Walk -> SpecWith Playwright
spec walk = describe "the walk" $ onOnePage demoContext (holdProgram walk.gate) $ do
  let site = walk.site
      step' = step walk.chain

  step' "starts at the front page, which no click after loads again" $ \page -> do
    gate <- gateOf walk.gate
    _ <- load site gate page "/"
    -- No click from here on may load a page: a mark on the window would
    -- go, and so would the shell the page arrived with.
    _ :: Bool <- evaluate page "window.stillTheSamePage = true"
    arrive walk page (at "/" "wiki-home") "the front page"
    nothingWrong page

  step' "takes the tour from the front page's invitation, at Docs' address" $ \page -> do
    click (withText "Take the tour" (locator page "#app .directory a"))
    -- The tour is Docs' home page, at the space's address.
    arrive walk page (named "Docs" (at "/s/docs/" "page-view")) "the tour"
    nothingWrong page

  -- Who one is, from the menu at the top right. The demo starts as admin;
  -- nobody sees no private space, and admin every one.
  step' "shows nobody the public spaces to switch to, and admin every one" $ \page -> do
    click (locator page "#app .user-switcher-toggle")
    click (locator page "#app .user-menu button[data-login='']")
    waitQuiet page
    textContent (locator page "#app .user-switcher-toggle") >>= (`shouldSatisfy` Text.isInfixOf "Not signed in")
    switchable walk page `shouldReturn` ["/s/blog/", "/s/docs/"]
    click (locator page "#app .user-switcher-toggle")
    click (locator page "#app .user-menu button[data-login=admin]")
    waitQuiet page
    textContent (locator page "#app .user-switcher-toggle") >>= (`shouldSatisfy` Text.isInfixOf "Ada Admin")
    switchable walk page `shouldReturn` ["/s/blog/", "/s/docs/", "/s/team/"]
    nothingWrong page

  -- Every root space, from its card in the directory, which opens it at
  -- its home page with a sidebar of its own; and a page of each from there.
  step' "opens every root space and a page in each by clicking, and the directory remembers them" $ \page -> do
    click (locator page "#app .all-spaces")
    arrive walk page (at "/" "wiki-home") "the directory"
    roots :: [(Text, Text)] <-
      evaluateAll
        (locator page "#app .space-card-link")
        "(links) => links.map((a) => [a.getAttribute('href'), a.querySelector('.space-card-name').textContent])"
        ()
    map snd roots `shouldBe` ["Blog", "Docs", "Team"]
    forM_ roots $ \(href', name) -> do
      let href = localOf walk href'
      now <- here site page
      when (now /= "/") $ do
        click (locator page "#app .all-spaces")
        arrive walk page (at "/" "wiki-home") ("the directory, for " <> name)
      click (locator page ("#app .space-card-link[href='" <> href' <> "']"))
      -- The blog opens at its posts (WP4.14), the others at their home
      -- pages.
      let opensAt = if name == "Blog" then "blog-view" else "page-view"
      arrive walk page (named name (at href opensAt)) ("the space " <> name)
      textContent (locator page "#app .sidebar-space-name") `shouldReturn` name
      let firstPage = first (locator page "#app .wiki-sidebar .page-tree a")
      target <- localOf walk . fromMaybe "" <$> getAttribute firstPage "href"
      title' <- textContent firstPage
      click firstPage
      arrive walk page (named title' (at target "page-view")) ("the page " <> title')
    click (locator page "#app .wiki-brand")
    arrive walk page (at "/" "wiki-home") "the directory again"
    -- The spaces visited last, the latest first.
    allTextContents (locator page "#app .recent-space-name") `shouldReturn` ["Team", "Docs", "Blog"]
    samePage page "going through the spaces"
    nothingWrong page

  -- The blog: its posts the newest first, each with its date and comments,
  -- and from a post to the one before it.
  step' "lists the blog's posts the newest first, and a post its date" $ \page -> do
    click (locator page ("#app .space-card-link[href='" <> under walk "/s/blog/" <> "']"))
    arrive walk page (named "Blog" (at "/s/blog/" "blog-view")) "Blog again"
    allTextContents (locator page "#app .post-list .post-title") `shouldReturn` ["Notes on Haskell", "Hello, world"]
    allTextContents (locator page "#app .post-list .post-meta") `shouldReturn` ["19 September 2026 · No comments", "1 September 2026 · 5 comments"]
    click (locator page ("#app .post-link[href='" <> under walk "/s/blog/p/notes-on-haskell/" <> "']"))
    arrive walk page (saying "Posted 19 September 2026" (named "Notes on Haskell" (at "/s/blog/p/notes-on-haskell/" "page-view"))) "a post"
    count (locator page "#app .post-next") `shouldReturn` 0
    nothingWrong page

  step' "opens a page's source from the page, and its link leads back" $ \page -> do
    click (locator page "#app .post-previous")
    arrive walk page (named "Hello, world" (at "/s/blog/p/hello-world/" "page-view")) "Hello, world"
    click (withText "View source" (locator page "#app .page-view .actions a"))
    arrive walk page (saying "# Hello, world" (named "Source" (at "/s/blog/p/hello-world/source/" "source-view"))) "Hello, world's source"
    click (locator page "#app .source-view a.source-back")
    arrive walk page (named "Hello, world" (at "/s/blog/p/hello-world/" "page-view")) "back from the source"
    nothingWrong page

  -- The editor, as admin, with a save.
  step' "formats from a shortcut in the editor, previews what is typed with its formulas, and saves it" $ \page -> do
    click (withText "Edit" (locator page "#app .page-view .actions a"))
    arrive walk page (named "Edit" (at "/s/blog/p/hello-world/edit/" "editor")) "the editor"
    editorReady page
    let text = editorText page
    pressOn text "Control+End"
    typeText text "\n\n## Smoke test\n\nWritten by "
    -- A toolbar shortcut, whose placeholder is selected for the typing.
    pressOn text "Control+b"
    typeText text "Ada"
    pressOn text "End"
    typeText text " with $x^2$."
    waitQuiet page
    -- CodeMirror shows it as it will look: the new heading larger, Ada
    -- bold. Its decorations are CodeMirror's.
    waitFor (first (withText "Smoke test" (locator page "#app .editor-cm .cm-md-h2"))) Visible
    waitFor (first (withText "Ada" (locator page "#app .editor-cm .cm-md-strong"))) Visible
    settle page
    typed <- fromMaybe "" <$> markdownIn page
    expect ("\n\n## Smoke test\n\nWritten by **Ada** with $x^2$." `Text.isSuffixOf` typed) ("the Markdown typed: " <> show typed)
    editorBytes <- getFileSize (site.demo.dir </> "islands" </> "editor.js")
    report ("the editor fetched islands/editor.js, " <> tshow (editorBytes `div` 1024) <> " KiB")
    -- The Markdown is shown alone until the preview is asked for, which
    -- replaces it; Save is still there.
    isVisible (locator page "#app .editor-preview") `shouldReturn` False
    click (locator page "#app .editor-show-preview")
    waitQuiet page
    count (withText "Smoke test" (locator page "#app .editor-preview h2")) `shouldReturn` 1
    count (withText "Ada" (locator page "#app .editor-preview strong")) `shouldReturn` 1
    -- KaTeX sets the formula: a condition on its work.
    waitFor (lastOf (locator page "#app .editor-preview .wiki-math-inline .katex")) Visible
    settle page
    isVisible text `shouldReturn` False
    click (locator page "#app .editor-save-close")
    arrive walk page (saying "Smoke test" (named "Hello, world" (at "/s/blog/p/hello-world/" "page-view"))) "the page saved"
    samePage page "editing"
    nothingWrong page

  -- A new page: its title first, in a small form, which makes the page and
  -- opens the editor on it; Ctrl+S saves and stays there, saying so, and
  -- Save and close shows the page.
  step' "makes a new page from its title; Ctrl+S saves it and stays, and Save and close shows it" $ \page -> do
    click (locator page "#app .space-pages-link")
    arrive walk page (named "Space settings" (at "/s/blog/pages/" "space-view")) "Blog's pages, for a new page"
    click (withText "New page" (locator page "#app .space-view .actions a"))
    arrive walk page (named "New page" (at "/s/blog/new-page/" "new-page-view")) "the new page's form"
    typeText (locator page "#app .new-page-title") "Smoke page"
    click (locator page "#app .new-page-view button.primary")
    arrive walk page (named "Edit" (at "/s/blog/p/smoke-page/edit/" "editor")) "the new page's editor"
    editorReady page
    -- Only its title line, which the editor puts in, with the cursor under
    -- it.
    markdownIn page `shouldReturn` Just "# Smoke page\n\n"
    typeText (editorText page) "Made through the *new* flow."
    pressOn (editorText page) "Control+s"
    waitQuiet page
    -- The notice's timer is H.delay: it is still shown once the save is
    -- done.
    textContent (locator page "#app .editor-saved-notice") >>= (`shouldSatisfy` Text.isInfixOf "Saved")
    here site page `shouldReturn` "/s/blog/p/smoke-page/edit/"
    click (locator page "#app .editor-save-close")
    arrive walk page (saying "Made through the new flow." (named "Smoke page" (at "/s/blog/p/smoke-page/" "page-view"))) "the new page saved"
    samePage page "making a page"
    nothingWrong page

  -- A page from a template: the team's own, listed apart from its tree, is
  -- offered by "New page" beside the built-in ones; the new page has its
  -- title, today's date and its maker's name where the template has
  -- {{title}}, {{date}} and {{author}}.
  step' "offers the space's template and the built-in ones for a new page, and fills in the one chosen" $ \page -> do
    click (locator page "#app .wiki-brand")
    arrive walk page (at "/" "wiki-home") "the front page, for the team's space"
    click (locator page ("#app .space-card-link[href='" <> under walk "/s/team/" <> "']"))
    arrive walk page (saying "Team handbook" (at "/s/team/" "page-view")) "the team's space"
    count (withText "Weekly sync" (locator page "#app .wiki-sidebar .sidebar-templates a")) `shouldReturn` 1
    click (locator page "#app .space-pages-link")
    arrive walk page (named "Space settings" (at "/s/team/pages/" "space-view")) "Team's pages, for a page from a template"
    click (withText "New page" (locator page "#app .space-view .actions a"))
    arrive walk page (named "New page" (at "/s/team/new-page/" "new-page-view")) "the new page's form, with templates"
    starts <- allTextContents (locator page "#app .new-page-choice")
    map (head' . Text.words) starts `shouldBe` ["Blank", "Weekly", "Meeting", "Decision", "How-to"]
    typeText (locator page "#app .new-page-title") "Smoke sync"
    check (locator (withText "Weekly sync" (locator page "#app .new-page-choice")) "input")
    click (locator page "#app .new-page-view button.primary")
    arrive walk page (named "Edit" (at "/s/team/p/smoke-sync/edit/" "editor")) "the editor on a page from a template"
    editorReady page
    today <- Text.pack . show . utctDay <$> getCurrentTime
    made <- fromMaybe "" <$> markdownIn page
    expect ("# Smoke sync\n" `Text.isPrefixOf` made) ("the template's title not filled in: " <> show made)
    expect (("Weekly sync of " <> today <> ", notes by Ada Admin.") `Text.isInfixOf` made) ("the date and the author not filled in: " <> show made)
    click (locator page "#app .editor-save-close")
    arrive walk page (saying "notes by Ada Admin" (named "Smoke sync" (at "/s/team/p/smoke-sync/" "page-view"))) "the page made from a template"
    samePage page "making a page from a template"
    nothingWrong page

  -- Search from the keyboard: "/" to the box, words, an arrow and Enter.
  -- "/" is a character to type in a field, so nothing is focused first.
  step' "focuses the search box with /; a hit opens with the keyboard, Enter alone the page of results" $ \page -> do
    _ :: Maybe Bool <- evaluate page "(() => { document.activeElement?.blur(); return null; })()"
    settle page
    press page "/"
    typeKeys page "handbook"
    -- The search follows the typing after a pause (a debounce) and reads
    -- the demo's IndexedDB.
    waitQuiet page
    count (withText "Team handbook" (locator page "#app .search-results .search-hit")) >>= (`shouldSatisfy` (>= 1))
    inputValue (locator page "#app .search-input") `shouldReturn` "handbook"
    press page "ArrowDown"
    press page "Enter"
    -- The handbook is Team's home page, at the space's address.
    arrive walk page (named "Team" (at "/s/team/" "page-view")) "a search's hit"
    -- Enter with no hit chosen: the page of every result, at an address of
    -- its own.
    press page "/"
    typeKeys page "mermaid"
    waitQuiet page
    count (locator page "#app .search-results .search-hit") >>= (`shouldSatisfy` (>= 1))
    press page "Enter"
    arrive walk page (saying "Diagrams" (named "Search" (at "/search/?q=mermaid" "search-view"))) "the results"
    samePage page "searching"
    nothingWrong page

  step' "goes back through the whole history and forward again, each entry showing its route" $ \page -> do
    visits <- readIORef walk.visits
    let n = length visits
    forM_ (reverse (take (n - 1) visits)) $ \v -> do
      goBack page
      checkAt walk page v ("back to " <> v.visitStep)
    forM_ (drop 1 visits) $ \v -> do
      goForward page
      checkAt walk page v ("forward to " <> v.visitStep)
    samePage page "going back and forward"
    report ("back through all " <> tshow n <> " entries of the history and forward again")
    nothingWrong page

  -- Leaving the editor with changes by the back button asks first. Staying
  -- goes back to the editor's entry, so the history is as long as before,
  -- and the next back asks again; leaving then shows the page as it was.
  step' "asks before the back button leaves the editor with changes; Stay returns to its entry, Leave drops the draft" $ \page -> do
    click (locator page ("#app .search-view a.search-hit[href='" <> under walk "/s/docs/p/markdown-guide/diagrams/" <> "']"))
    checkAt walk page (named "Diagrams" (at "/s/docs/p/markdown-guide/diagrams/" "page-view")) "Diagrams"
    click (withText "Edit" (locator page "#app .page-view .actions a"))
    checkAt walk page (named "Edit" (at "/s/docs/p/markdown-guide/diagrams/edit/" "editor")) "editing Diagrams"
    editorReady page
    pressOn (editorText page) "Control+End"
    typeText (editorText page) "\nNot to be kept."
    waitQuiet page
    entries :: Int <- evaluate page "history.length"
    goBack page
    count (locator page "#app .leave-confirm") `shouldReturn` 1
    click (withText "Stay" (locator page "#app .leave-confirm button"))
    checkAt walk page (at "/s/docs/p/markdown-guide/diagrams/edit/" "editor") "staying in the editor"
    kept <- fromMaybe "" <$> markdownIn page
    expect ("Not to be kept." `Text.isSuffixOf` kept) "staying lost the draft"
    evaluate page "history.length" `shouldReturn` entries
    goBack page
    click (withText "Leave" (locator page "#app .leave-confirm button"))
    checkAt walk page (named "Diagrams" (at "/s/docs/p/markdown-guide/diagrams/" "page-view")) "leaving the editor"
    textContent (locator page "#app .page-body") >>= (`shouldSatisfy` (not . Text.isInfixOf "Not to be kept."))
    samePage page "leaving the editor"
    nothingWrong page

  -- A page's history: the new page saved twice more, its versions listed
  -- the latest first with what the last save changed, an earlier version
  -- chosen and restored, which saves it as a new version on top.
  step' "lists a page's versions with the last diff, and restoring version 2 makes a new version" $ \page -> do
    toSpace walk page "/s/blog/"
    click (locator page ("#app .wiki-sidebar .page-tree a[href='" <> under walk "/s/blog/p/smoke-page/" <> "']"))
    checkAt walk page (named "Smoke page" (at "/s/blog/p/smoke-page/" "page-view")) "the new page again"
    forM_ ["A second line.", "A third line."] $ \line -> do
      click (withText "Edit" (locator page "#app .page-view .actions a"))
      checkAt walk page (at "/s/blog/p/smoke-page/edit/" "editor") ("editing for " <> line)
      editorReady page
      pressOn (editorText page) "Control+End"
      typeText (editorText page) ("\n\n" <> line)
      click (locator page "#app .editor-save-close")
      checkAt walk page (saying line (at "/s/blog/p/smoke-page/" "page-view")) (line <> " saved")
    click (withText "History" (locator page "#app .page-view .actions a"))
    checkAt walk page (named "History" (at "/s/blog/p/smoke-page/history/" "history-view")) "the page's history"
    before <- allTextContents (locator page "#app .version-list li > a")
    expect (length before >= 4) ("the history lists " <> show (length before) <> " versions")
    take 1 before `shouldBe` ["Version " <> tshow (length before) <> " (current)"]
    textContent (lastOf (locator page "#app .diff-added .diff-text")) `shouldReturn` "A third line."
    -- The time is written in by the browser, in the reader's zone, as the
    -- version is rendered.
    textContent (first (locator page "#app .version-meta time")) >>= (`shouldSatisfy` (not . Text.null))
    click (withTextExact "Version 2" (locator page "#app .version-list li > a"))
    waitQuiet page
    count (withText "Version 2" (locator page "#app .version-detail h2")) `shouldReturn` 1
    here site page >>= (`shouldSatisfy` Text.isPrefixOf "/s/blog/p/smoke-page/history/?version=")
    click (locator page "#app button.restore")
    click (withText "Restore" (locator page "#app .restore-confirm button"))
    checkAt walk page (saying "Made through the new flow." (at "/s/blog/p/smoke-page/" "page-view")) "the version restored"
    textContent (locator page "#app .page-body") >>= (`shouldSatisfy` (not . Text.isInfixOf "A second line."))
    click (withText "History" (locator page "#app .page-view .actions a"))
    checkAt walk page (at "/s/blog/p/smoke-page/history/" "history-view") "the history after the restore"
    after <- allTextContents (locator page "#app .version-list li > a")
    length after `shouldBe` length before + 1
    take 1 after `shouldBe` ["Version " <> tshow (length after) <> " (current)"]
    samePage page "the page's history"
    report ("a page saved twice more lists " <> tshow (length before) <> " versions, and restoring version 2 makes version " <> tshow (length after))
    nothingWrong page

  -- A reload arrives at the same page, with the edit kept in the browser
  -- (IndexedDB), as admin again: who one was is not kept, and the demo
  -- starts as admin.
  step' "reloads a page edited in the browser, repaired into what the browser keeps" $ \page -> do
    gate <- gateOf walk.gate
    toSpace walk page "/s/blog/"
    click (locator page ("#app .wiki-sidebar .page-tree a[href='" <> under walk "/s/blog/p/hello-world/" <> "']"))
    checkAt walk page (saying "Smoke test" (at "/s/blog/p/hello-world/" "page-view")) "the edited page"
    -- The prerendered page shows the demo's own content, so adopting it
    -- repairs the edited page into what the browser keeps.
    edited <- reloadAdopted gate page
    expect (not (noRepairs edited)) "a page edited in the browser was adopted with nothing to repair"
    checkAt walk page (saying "Smoke test" (named "Hello, world" (at "/s/blog/p/hello-world/" "page-view"))) "the reload"
    textContent (locator page "#app .user-switcher-toggle") >>= (`shouldSatisfy` Text.isInfixOf "Ada Admin")
    nothingWrong page

  -- The user menu only switches users: the wiki's data is the
  -- administration's, linked from the header for an administrator, under
  -- the backups. Exporting downloads a zip file of it, edit and all, which
  -- is version 2 of docs/export.md: a directory per space and per page,
  -- the page's body as page.md, its comments beside it.
  step' "exports a zip file of the wiki from the administration, the edited page in it" $ \page -> do
    click (locator page "#app .user-switcher-toggle")
    count (locator page "#app .user-menu button[data-login=admin]") `shouldReturn` 1
    count (locator page "#app .user-menu .demo-export") `shouldReturn` 0
    click (locator page "#app .user-switcher-toggle")
    click (locator page "#app .wiki-header a.admin-link")
    checkAt walk page (named "Overview" (at "/admin/overview/" "admin-view")) "the administration"
    click (locator page "#app .admin-nav-link[data-section=backups]")
    checkAt walk page (named "Backups and data" (at "/admin/backups/" "admin-view")) "the administration's backups and data"
    textContent (locator page "#app .admin-view .demo-kept") >>= (`shouldSatisfy` Text.isInfixOf "kept in this browser")
    exported <- download page (click (locator page "#app .admin-view .demo-export"))
    expect (exportName exported.suggestedFilename) ("the export's name: " <> show exported.suggestedFilename)
    bytes <- downloadBytes exported
    ByteString.take 2 bytes `shouldBe` "PK"
    waitQuiet page
    textContent (locator page "#app .admin-view .demo-told") >>= (`shouldSatisfy` Text.isInfixOf ("Exported the wiki as " <> exported.suggestedFilename <> "."))
    let archive = toArchive (LazyByteString.fromStrict bytes)
        file name = fromEntry <$> findEntryByPath name archive
    formatVersion (file "manifest.json") `shouldBe` Just 2
    -- The page is under the blog's home page, the root of its pages, and
    -- its directory under the home page's.
    let hello = "spaces/blog/pages/home/pages/hello-world/"
    forM_ ["page.json", "page.md", "comments.json"] $ \name ->
      expect ((hello <> name) `elem` filesInArchive archive) ("the export has no " <> hello <> name)
    let body = maybe "" (Text.decodeUtf8With Text.lenientDecode . LazyByteString.toStrict) (file (hello <> "page.md"))
    expect ("Smoke test" `Text.isInfixOf` body) "the export's page.md is not the edited page"
    expect ("pages.json" `notElem` filesInArchive archive) "the export still has version 1's pages.json"
    writeIORef walk.exported (Just (exported.suggestedFilename, bytes))
    nothingWrong page

  -- Resetting the demo's content, from the administration and after asking,
  -- takes the edit away, and a reload does not bring it back.
  step' "resets the demo's content, after asking, for good" $ \page -> do
    gate <- gateOf walk.gate
    click (locator page "#app .admin-view .demo-reset-ask")
    click (withText "Reset" (locator page "#app .demo-reset-confirm button"))
    waitQuiet page
    textContent (locator page "#app .admin-view .demo-told") >>= (`shouldSatisfy` Text.isInfixOf "back as it was at the start")
    toHelloWorld walk page "the page after the reset" Nothing
    textContent (locator page "#app .page-body") >>= (`shouldSatisfy` (not . Text.isInfixOf "Smoke test"))
    -- The demo's own content again, which the prerendered page shows as it
    -- is.
    reset <- reloadAdopted gate page
    unless (noRepairs reset) $ expectationFailure ("the page after a reset needed repairs:\n" <> describeRepairs reset.repairs)
    checkAt walk page (named "Hello, world" (at "/s/blog/p/hello-world/" "page-view")) "the reload after the reset"
    textContent (locator page "#app .page-body") >>= (`shouldSatisfy` (not . Text.isInfixOf "Smoke test"))
    nothingWrong page

  -- Importing the export brings it back, after asking; and a reload works
  -- on a page's source, which a reader not signed in may read too.
  step' "imports the export back, after asking, and reloads a page's source" $ \page -> do
    gate <- gateOf walk.gate
    (name, bytes) <- readIORef walk.exported >>= maybe (fail "nothing was exported") pure
    click (locator page "#app .wiki-header a.admin-link")
    click (locator page "#app .admin-nav-link[data-section=backups]")
    checkAt walk page (named "Backups and data" (at "/admin/backups/" "admin-view")) "the administration again"
    setInputFiles (locator page "#app .admin-view .demo-import input") [UploadBytes {name, mimeType = "application/zip", bytes}]
    click (withText "Replace" (locator page "#app .demo-import-confirm button"))
    waitQuiet page
    textContent (locator page "#app .admin-view .demo-told") >>= (`shouldSatisfy` Text.isInfixOf "Imported")
    toHelloWorld walk page "the import" (Just "Smoke test")
    click (withText "View source" (locator page "#app .page-view .actions a"))
    checkAt walk page (named "Source" (at "/s/blog/p/hello-world/source/" "source-view")) "the source"
    _ <- reloadAdopted gate page
    checkAt walk page (saying "# Hello, world" (named "Source" (at "/s/blog/p/hello-world/source/" "source-view"))) "the source reloaded"
    nothingWrong page

  -- An address with no file: 404.html, which the program reads as its own.
  -- Nor has the administration's, which the program opens for an
  -- administrator, as the demo starts, at its first section, whose address
  -- it puts in the place of /admin/; nor an editor's.
  step' "stands in 404.html for an address with no file, the administration's and an editor's, and shows its route" $ \page -> do
    gate <- gateOf walk.gate
    (status, missing) <- fetchText site "/no/such/address/"
    status `shouldBe` 404
    expect (footerHtml `Text.isInfixOf` missing) "404.html has no footer"
    notFound <- load site gate page "/no/such/address/"
    unless (noRepairs notFound) $ expectationFailure ("404.html: adopting the page repaired it:\n" <> describeRepairs notFound.repairs)
    checkAt walk page (at "/no/such/address/" "not-found") "an address the wiki does not have"
    footerShown page "404.html"
    fst <$> fetchText site "/admin/" `shouldReturn` 404
    _ <- load site gate page "/admin/"
    checkAt walk page (named "Overview" (at "/admin/overview/" "admin-view")) "the administration's address"
    _ <- load site gate page "/admin/backups/"
    checkAt walk page (named "Backups and data" (at "/admin/backups/" "admin-view")) "a section's address"
    count (locator page "#app .admin-view .demo-export") `shouldReturn` 1
    _ <- load site gate page "/admin/users/?q=rita"
    -- The users' search follows its field after a pause, and reads the
    -- demo's IndexedDB: the check's waitQuiet waits for both.
    checkAt walk page (named "Users" (at "/admin/users/?q=rita" "admin-view")) "the users' address"
    count (locator page "#app .user-row") `shouldReturn` 1
    -- 404.html is the page of no route, so the program repairs it into the
    -- editor's: the shell is kept, what differs is built afresh.
    fst <$> fetchText site "/s/blog/p/hello-world/edit/" `shouldReturn` 404
    _ <- load site gate page "/s/blog/p/hello-world/edit/"
    checkAt walk page (named "Edit" (at "/s/blog/p/hello-world/edit/" "editor")) "an editor's address"
    -- The demo starts as admin, who may edit it: CodeMirror comes.
    editorReady page
    nothingWrong page

  -- A page's permanent address, as "Copy permanent link" gives it (the
  -- notice shows it whether the clipboard took it or not), has no file
  -- either: the program asks where the page is and puts the address of the
  -- version it names in its place, the fragment kept (WP5.81).
  step' "leads a page's permanent address to the version it was copied from, its fragment kept" $ \page -> do
    gate <- gateOf walk.gate
    _ <- load site gate page "/s/docs/p/markdown-guide/mathematics/"
    checkAt walk page (named "Mathematics" (at "/s/docs/p/markdown-guide/mathematics/" "page-view")) "Mathematics"
    click (locator page "#app .page-actions .copy-permanent-link")
    waitQuiet page
    permanent <- Text.strip <$> textContent (locator page "#app .link-copied-address")
    let (pathPart, search) = Text.breakOn "?" (localPath site.demo permanent)
    expect ("/l/" `Text.isPrefixOf` pathPart) ("not a permanent address: " <> show permanent)
    expect ("?version=" `Text.isPrefixOf` search) ("no version in " <> show permanent)
    _ <- load site gate page (pathPart <> search <> "#macros")
    checkAt walk page (named "Version" (at ("/s/docs/p/markdown-guide/mathematics/" <> search) "page-view")) "a permanent address"
    fragment <$> url page `shouldReturn` "#macros"
    count (locator page "#app .version-note") `shouldReturn` 1
    nothingWrong page

  -- A link in a page to a section of another page of the same space arrives
  -- at the section: the page view is given the other page, and scrolls once
  -- it has loaded it. The demo has no such link, so one is put in the
  -- tour's text for the length of a click, as a page's Markdown would write
  -- it: the application reads the link as the click is dispatched.
  step' "arrives at another page's section by a link, without loading a page" $ \page -> do
    gate <- gateOf walk.gate
    _ <- load site gate page "/s/docs/"
    checkAt walk page (named "Docs" (at "/s/docs/" "page-view")) "the tour"
    _ :: Bool <- evaluate page "window.stillTheSamePage = true"
    _ :: Maybe Bool <-
      evaluateOn
        (first (locator page "#app .page-body p"))
        "(paragraph, href) => {\
        \  const link = document.createElement('a');\
        \  link.setAttribute('href', href);\
        \  link.textContent = 'the macros';\
        \  paragraph.append(link);\
        \  link.click();\
        \  link.remove();\
        \  return null;\
        \}"
        (under walk "/s/docs/p/markdown-guide/mathematics/#macros")
    -- The click was the script's: the program has not been waited for.
    settle page
    checkAt walk page (named "Mathematics" (at "/s/docs/p/markdown-guide/mathematics/" "page-view")) "a link to another page's section"
    fragment <$> url page `shouldReturn` "#macros"
    top :: Double <- evaluateOn (locator page "#app #macros") "(heading) => heading.getBoundingClientRect().top" ()
    expect (top >= -2 && top < 200) ("the section is not scrolled to: its top is at " <> show top)
    evaluate page "window.stillTheSamePage === true" `shouldReturn` True
    nothingWrong page
  where
    head' = \case
      (w : _) -> w
      [] -> ""
    fragment = Text.dropWhile (/= '#')
    exportName name = case Text.stripPrefix "wiki-" name >>= Text.stripSuffix ".zip" of
      Just date -> Text.length date == 10 && Text.all (\c -> isDigit c || c == '-') date
      Nothing -> False
    formatVersion :: Maybe LazyByteString.ByteString -> Maybe Int
    formatVersion manifest = case manifest >>= decode of
      Just (Object o) | Just (Number n) <- KeyMap.lookup "formatVersion" o -> Just (round n)
      _ -> Nothing

-- | The address of a route under the site's base path, as the page's
-- links write it: @/blog/s/docs/@ for @/s/docs/@.
under :: Walk -> Text -> Text
under walk path = basePath walk.site.demo <> Text.dropWhile (== '/') path

-- | The route a link's address names, the base path taken out.
localOf :: Walk -> Text -> Text
localOf walk href = maybe href ("/" <>) (Text.stripPrefix (basePath walk.site.demo) href)

-- | Check a route once the program is quiet: the address, the view, the
-- breadcrumb and the text the visit says. The program has rendered what
-- the action led to (the action settled) and has read what it shows from
-- the demo's IndexedDB ('waitQuiet'), so each is read once.
checkAt :: (HasCallStack) => Walk -> Page -> Visit -> Text -> IO ()
checkAt walk page entry what = do
  waitQuiet page
  let at' problem = Text.unpack (what <> " at " <> entry.visitPath <> ": " <> problem)
  now <- here walk.site page
  expect (now == entry.visitPath) (at' ("the address is " <> now))
  viewNow <- (\s -> s.view) <$> shown page
  expect (viewNow == Just entry.visitView) (at' ("the view is " <> tshow viewNow))
  forM_ entry.visitCrumb $ \c -> do
    crumbNow <- crumb page
    expect (crumbNow == c) (at' ("the breadcrumb is " <> crumbNow))
  forM_ entry.visitText $ \t -> do
    shownText <- contentText page
    expect (t `Text.isInfixOf` shownText) (at' ("no " <> tshow t))

-- | Arrive at a route: check it, check that no page was loaded, and keep
-- it as an entry of the history.
arrive :: (HasCallStack) => Walk -> Page -> Visit -> Text -> IO ()
arrive walk page entry what = do
  checkAt walk page entry what
  samePage page what
  modifyIORef' walk.visits (<> [entry {visitStep = what}])

-- | No click since the walk began has loaded a page: the mark on the
-- window is there, and the shell the page arrived with.
samePage :: (HasCallStack) => Page -> Text -> IO ()
samePage page what = do
  still <- evaluate page "window.stillTheSamePage === true"
  expect still (Text.unpack what <> " loaded a page")
  stillPrerendered page

-- | The spaces the sidebar's menu offers to switch to.
switchable :: Walk -> Page -> IO [Text]
switchable walk page = do
  click (locator page "#app .space-switcher-toggle")
  hrefs :: [Text] <- evaluateAll (locator page "#app .space-switcher-option") "(links) => links.map((a) => a.getAttribute('href'))" ()
  click (locator page "#app .space-switcher-toggle")
  pure (map (localOf walk) hrefs)

-- | A space from anywhere: the directory, by the site's name, and the
-- space's card there; the space opens at its home page.
--
-- The directory's element must stay where it is from the moment its cards
-- show until the front page has loaded. A render that takes the element
-- out and puts it back (a move) under a press on a card makes the browser
-- send no click, which lost the click here now and then. A removed element
-- that is connected again by the time the observer is told was moved. The
-- watch starts once the cards show, because the element is put in place
-- once as it is first built: after the click on the name, which renders
-- the directory with the cards the shell has, and before the front page's
-- own content, which the program reads from IndexedDB.
toSpace :: (HasCallStack) => Walk -> Page -> Text -> IO ()
toSpace walk page space = do
  let card = locator page ("#app .space-card-link[href='" <> under walk space <> "']")
  click (locator page "#app .wiki-brand")
  count card `shouldReturn` 1
  _ :: Maybe Bool <-
    evaluate
      page
      "(() => {\
      \  window.smokeDirectoryMoves = 0;\
      \  window.smokeCountMoves = (records) => {\
      \    for (const record of records) {\
      \      for (const node of record.removedNodes) {\
      \        if (node.nodeType === Node.ELEMENT_NODE && node.matches('.directory') && node.isConnected) window.smokeDirectoryMoves += 1;\
      \      }\
      \    }\
      \  };\
      \  window.smokeDirectoryWatch = new MutationObserver(window.smokeCountMoves);\
      \  window.smokeDirectoryWatch.observe(document.getElementById('app'), { subtree: true, childList: true });\
      \  return null;\
      \})()"
  waitQuiet page
  count (withText "Spaces" (locator page "#app .wiki-home .page-view h1")) `shouldReturn` 1
  moves :: Int <-
    evaluate
      page
      "(() => {\
      \  window.smokeCountMoves(window.smokeDirectoryWatch.takeRecords());\
      \  window.smokeDirectoryWatch.disconnect();\
      \  return window.smokeDirectoryMoves;\
      \})()"
  expect (moves == 0) "the directory's element was moved while the front page loaded"
  click card
  waitQuiet page
  count (locator page ("#app .sidebar-space[href='" <> under walk space <> "']")) `shouldReturn` 1

-- | Hello, world, from the blog's sidebar.
toHelloWorld :: (HasCallStack) => Walk -> Page -> Text -> Maybe Text -> IO ()
toHelloWorld walk page what says = do
  toSpace walk page "/s/blog/"
  click (locator page ("#app .wiki-sidebar .page-tree a[href='" <> under walk "/s/blog/p/hello-world/" <> "']"))
  checkAt walk page ((named "Hello, world" (at "/s/blog/p/hello-world/" "page-view")) {visitText = says}) what

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
