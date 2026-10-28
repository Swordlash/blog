{-# LANGUAGE TemplateHaskell #-}

-- | One space at a time (WP4.6 of docs/PLAN.md) in a browser, over the
-- demo's wiki: the directory of spaces and the spaces visited last, the
-- sidebar of one space and switching to another, a subspace and the way up
-- from it, a page made the space's home page, the space's settings with an
-- emoji and an uploaded image for its icon; a space shown as a blog
-- (WP4.14), its posts and a post's neighbours; and the page's actions, which
-- stay under the header while a long page scrolls (the owner's request).
module Test.Browser.Spaces (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

-- The page has no file dialog the harness can answer, so a test hands the
-- file input a file the way the browser would (test/jsbits/test-files.js);
-- and reads where things are drawn (test/jsbits/test-layout.js,
-- test/jsbits/test-style.js).
$( browserJS
     ["jsbits/test-files.js", "jsbits/test-layout.js", "jsbits/test-style.js"]
     [ ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_scroll_to", "wiki_test_scroll_to", Safe, [t|Int -> IO ()|])
     , ("js_box", "wiki_test_box", Unsafe, [t|JSText -> IO JSText|])
     , ("js_computed_style", "wiki_test_computed_style", Unsafe, [t|JSText -> JSText -> IO JSText|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "lists the spaces as cards, and the ones visited last, the latest first" $ runPage $ do
    ui <- start m (Just "user-admin") Home
    _ <- find ui ".space-card"
    names <- traverse textContent =<< findAll ui ".space-card-name"
    names `shouldBe` ["Blog", "Docs", "Team"]
    find ui ".space-card[data-space] .space-card-description" >>= (`shouldHaveText` "Posts about this wiki and about writing it in Haskell.")
    metas <- traverse textContent =<< findAll ui ".space-card-meta"
    metas `shouldBe` ["2 pages Public", "5 pages Public", "2 pages · 1 subspace Private"]
    -- Nothing visited yet: the section is there, hidden.
    find ui ".recent-spaces" >>= shouldBeHidden
    find ui ".space-card-link[href$='#/s/docs/']" >>= click
    _ <- find ui ".sidebar-space-name"
    find ui ".all-spaces" >>= click
    find ui ".space-card-link[href$='#/s/team/']" >>= click
    find ui ".wiki-sidebar .sidebar-subspaces a[href$='#/s/team/projects/']" >>= click
    find ui ".sidebar-space-name" >>= (`shouldHaveText` "Projects")
    find ui ".all-spaces" >>= click
    find ui ".recent-spaces" >>= shouldBeVisible
    recent <- traverse textContent =<< findAll ui ".recent-space-name"
    recent `shouldBe` ["Team / Projects", "Team", "Docs"]
    find ui ".recent-space[href$='#/s/docs/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Tour")

  it "shows one space in the sidebar, and switches to another" $ runPage $ do
    ui <- start m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["tour"]))
    find ui ".sidebar-space-name" >>= (`shouldHaveText` "Docs")
    tree <- traverse textContent =<< findAll ui ".wiki-sidebar .page-tree a"
    tree `shouldBe` ["Markdown guide", "Diagrams", "Mathematics", "Presentations", "Tour"]
    -- Nothing of the other spaces, but in the switcher, closed.
    length <$> findAll ui ".wiki-sidebar a[href$='#/s/blog/']" `shouldReturn` 0
    toggle <- find ui ".space-switcher-toggle"
    getAttribute toggle "aria-expanded" `shouldReturn` Just "false"
    click toggle
    options <- traverse textContent =<< findAll ui ".space-switcher-option"
    map T.strip options `shouldBe` ["✍️Blog", "📘Docs", "🧭Team"]
    _ <- find ui ".space-switcher-option[aria-current=true][href$='#/s/docs/']"
    find ui ".space-switcher-option[href$='#/s/blog/']" >>= click
    find ui ".sidebar-space-name" >>= (`shouldHaveText` "Blog")
    find ui ".blog-view h1" >>= (`shouldHaveText` "Blog")
    -- Closed again on arriving.
    length <$> findAll ui ".space-switcher-menu" `shouldReturn` 0
    find ui ".breadcrumbs li a" >>= (`shouldHaveText` "Spaces")

  it "enters a subspace from the sidebar, and goes up to the space it is in" $ runPage $ do
    ui <- start m (Just "user-admin") (Space (slugs ["team"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Team handbook")
    find ui ".wiki-sidebar .sidebar-subspaces a[href$='#/s/team/projects/']" >>= click
    find ui ".sidebar-space-name" >>= (`shouldHaveText` "Projects")
    crumbs <- traverse textContent =<< findAll ui ".breadcrumbs li"
    crumbs `shouldBe` ["Spaces", "Team", "Projects"]
    find ui ".sidebar-up" >>= (`shouldHaveText` "Up to Team")
    find ui ".sidebar-up" >>= click
    find ui ".sidebar-space-name" >>= (`shouldHaveText` "Team")
    length <$> findAll ui ".sidebar-up" `shouldReturn` 0

  it "makes a page the space's home page, which the space then opens at" $ runPage $ do
    ui <- start m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    find ui ".page-view .set-home" >>= click
    eventually (length <$> findAll ui ".page-view .set-home" `shouldReturn` 0)
    find ui ".wiki-sidebar .sidebar-space" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Markdown guide")
    find ui ".space-home-link" >>= (`shouldHaveText` "Markdown guide")
    -- Nobody who does not administer the space is offered it.
    unmount ui
    visitor <- start m Nothing (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    _ <- find visitor ".page-view .actions"
    length <$> findAll visitor ".set-home" `shouldReturn` 0

  it "sets a space's description and emoji, and an uploaded image for its icon" $ runPage $ do
    ui <- start m (Just "user-admin") (SpacePages (slugs ["blog"]))
    find ui ".space-settings-toggle" >>= click
    description <- find ui ".space-settings .space-description-field"
    clear description
    typeText description "Notes, newest first."
    find ui ".icon-kind-emoji input" >>= click
    -- The blog's emoji is in the field already.
    emoji <- find ui ".icon-emoji"
    getProperty emoji "value" `shouldReturn` "✍️"
    clear emoji
    typeText emoji "🦉"
    find ui ".space-profile-form button.primary" >>= click
    find ui ".settings-saved" >>= (`shouldHaveText` "Saved")
    find ui ".sidebar-space .space-icon-emoji" >>= (`shouldHaveText` "🦉")
    find ui ".space-view .space-description" >>= (`shouldHaveText` "Notes, newest first.")
    -- An image: used at once, everywhere the space is shown.
    unsafeIOToPageM (chooseFile ".space-settings .icon-upload input" "owl.png" "image/png" dotPng)
    image <- find ui ".sidebar-space img.space-icon-image"
    getAttribute image "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    _ <- find ui ".icon-kind-image input:checked"
    -- And an SVG is refused, saying so.
    unsafeIOToPageM (chooseFile ".space-settings .icon-upload input" "owl.svg" "image/svg+xml" "PHN2Zy8+")
    find ui ".space-settings .error-invalid" >>= (`shouldHaveText` "A space's icon has to be a PNG, JPEG, GIF, WebP or AVIF image.")
    find ui ".all-spaces" >>= click
    _ <- find ui ".space-card-link[href$='#/s/blog/'] img.space-icon-image"
    find ui ".space-card-link[href$='#/s/blog/'] ~ .space-card-description" >>= (`shouldHaveText` "Notes, newest first.")

  it "lists a blog's posts, the newest first, and goes from a post to the next and back" $ runPage $ do
    ui <- start m Nothing (Space (slugs ["blog"]))
    titles <- traverse textContent =<< findAll ui ".post-list .post-title"
    titles `shouldBe` ["Notes on Haskell", "Hello, world"]
    metas <- traverse textContent =<< findAll ui ".post-list .post-meta"
    metas `shouldBe` ["19 September 2026 · No comments", "1 September 2026 · 5 comments"]
    find ui ".post-card[data-page] .post-excerpt" >>= (`shouldSatisfy'` "WebAssembly")
    find ui ".post-link[href$='#/s/blog/p/hello-world/']" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    find ui ".post-date" >>= (`shouldHaveText` "Posted 1 September 2026")
    length <$> findAll ui ".post-previous" `shouldReturn` 0
    find ui ".post-next" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Notes on Haskell")
    length <$> findAll ui ".post-next" `shouldReturn` 0
    find ui ".post-previous" >>= click
    find ui ".page-body h1" >>= (`shouldHaveText` "Hello, world")
    -- The space's own link goes back to the posts.
    find ui ".wiki-sidebar .sidebar-space" >>= click
    _ <- find ui ".blog-view .post-list"
    find ui ".breadcrumbs [aria-current=page]" >>= (`shouldHaveText` "Blog")

  it "shows a space as a blog, under its home page, once its administrator says so" $ runPage $ do
    ui <- start m (Just "user-admin") (SpacePages (slugs ["docs"]))
    find ui ".space-settings-toggle" >>= click
    switch <- find ui ".space-settings .space-blog"
    getProperty switch "checked" `shouldReturn` "false"
    click switch
    find ui ".space-profile-form button.primary" >>= click
    find ui ".settings-saved" >>= (`shouldHaveText` "Saved")
    find ui ".wiki-sidebar .sidebar-space" >>= click
    find ui ".blog-view .blog-home h1" >>= (`shouldHaveText` "Tour")
    -- Its home page is above the posts, and not among them; the pages
    -- under the guide are not posts either.
    titles <- traverse textContent =<< findAll ui ".post-list .post-title"
    titles `shouldBe` ["Markdown guide"]
    find ui ".new-post" >>= (`shouldHaveText` "New post")
    find ui ".post-link" >>= click
    find ui ".post-date" >>= (`shouldSatisfy'` "Posted")
    -- And back: the space opens at its home page again.
    find ui ".space-pages-link" >>= click
    find ui ".space-settings-toggle" >>= click
    find ui ".space-settings .space-blog" >>= click
    find ui ".space-profile-form button.primary" >>= click
    find ui ".settings-saved" >>= (`shouldHaveText` "Saved")
    find ui ".wiki-sidebar .sidebar-space" >>= click
    find ui ".page-view .page-body h1" >>= (`shouldHaveText` "Tour")
    length <$> findAll ui ".blog-view" `shouldReturn` 0

  it "renames a space in its settings, keeping its address" $ runPage $ do
    ui <- start m (Just "user-admin") (SpacePages (slugs ["blog"]))
    find ui ".space-settings-toggle" >>= click
    name <- find ui ".space-settings .space-name-field"
    clear name
    typeText name "Weblog"
    find ui ".space-profile-form button.primary" >>= click
    find ui ".space-view h1" >>= (`shouldHaveText` "Weblog")
    find ui ".sidebar-space[href$='#/s/blog/'] .sidebar-space-name" >>= (`shouldHaveText` "Weblog")

  it "keeps a page's actions under the header while a long page scrolls" $ runPage $ do
    ui <- start m (Just "user-admin") (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    _ <- find ui ".page-view .page-actions"
    before <- box ".page-actions"
    header <- box ".wiki-header"
    -- At the top, the bar is where the page puts it, below the header.
    (\(top, _, _) -> top) before `shouldSatisfy` (> (\(_, bottom, _) -> bottom) header + 4)
    getAttribute' ui ".page-actions" "data-stuck" `shouldReturn` Nothing
    unsafeIOToPageM (evaluate =<< js_scroll_to 100000)
    eventually $ do
      (headerTop, headerBottom, _) <- box ".wiki-header"
      (top, bottom, window) <- box ".page-actions"
      headerTop `shouldSatisfy` (\t -> abs t < 1)
      top `shouldSatisfy` (\t -> abs (t - headerBottom) < 1.5)
      bottom `shouldSatisfy` (<= window)
      getAttribute' ui ".page-actions" "data-stuck" `shouldReturn` Just ""
    -- The article went on under it.
    (_, titleBottom, _) <- box ".page-body h1"
    (_, barBottom, _) <- box ".page-actions"
    titleBottom `shouldSatisfy` (< barBottom)
    -- Its buttons still work from there.
    find ui ".page-actions .comments-toggle" >>= click
    _ <- find ui ".comments-panel"
    -- The editor's toolbar sticks the same way.
    unsafeIOToPageM (evaluate =<< js_scroll_to 0)
    unmount ui
    editor <- start m (Just "user-admin") (EditPage (slugs ["docs"]) (slugs ["markdown-guide"]))
    _ <- find editor ".editor-toolbar"
    unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText ".editor-toolbar") (toJSText "position")) `shouldReturn` "sticky"
  where
    box :: Text -> PageM s (Double, Double, Double)
    box selector = do
      found <- unsafeIOToPageM (fromJSText <$> js_box (toJSText selector))
      case mapMaybe (readMaybe . T.unpack) (T.words found) of
        [top, bottom, window] -> pure (top, bottom, window)
        _ -> expectationFailure ("no box for " <> toS selector) >> pure (0, 0, 0)
    getAttribute' ui selector name = find ui selector >>= (`getAttribute` name)
    shouldSatisfy' element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

chooseFile :: Text -> Text -> Text -> Text -> IO ()
chooseFile selector name mediaType base64 = evaluate =<< js_choose_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64)

-- | A PNG of one pixel, as base64.
dotPng :: Text
dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
