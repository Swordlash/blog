-- | The demo's pages brought into the server, as its owner would: the
-- demo's build served at the server's address (so that the demo leaves its
-- wiki in this origin's IndexedDB, as it does when the server takes the
-- demo's address and port) and exported; then the server's administration
-- imports that export through "What to migrate", with a page left out and
-- a conflict (a page the server made first) resolved "take the imported";
-- then imports again, from the demo's data in this browser, and finds
-- everything merged, nothing twice. Then two of the pages it brought, as
-- the server renders them: a long page with its "Contents" panel and an
-- embedded presentation, and a page with @[[!toc]]@.
module Server.Migrate (spec) where

import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TextIO
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Halogen.Playwright.Serve (mediaType)
import Network.HTTP.Client (RequestBody (..))
import Network.HTTP.Types.URI (urlDecode)
import Server.Site
import System.Directory (doesFileExist)
import System.FilePath (normalise, (</>))
import Wiki.Smoke.Adoption (presentationsEmbedded, viewerAsks)
import Wiki.Smoke.Api
import Wiki.Smoke.Server
import Wiki.Smoke.Walk

spec :: Smoke -> SpecWith Playwright
spec smoke = describe "the demo's pages brought into the server" $ do
  let step' = step smoke.chain
      demoDir = smoke.build.built.demo

  step' "imports the demo's export through the dialog, a page left out and a conflict taking the imported page, and again from the demo's data in this browser, everything merged and nothing twice" $ \pw ->
    inBrowser smoke pw Admin $ \page -> do
      -- The demo's photograph and video, answered here, as the network
      -- may be out of reach.
      _ <- route page "https://upload.wikimedia.org/**" (\_ -> pure (fulfill 204 Nothing ""))
      -- The demo, at the server's address: it keeps its wiki in this
      -- origin's IndexedDB, and its administration exports it. It is
      -- served under the base path it was built for, which its pages'
      -- <base href> says (/ for a build for the root, GitHub Pages' /blog/
      -- in CI); IndexedDB is the origin's whatever the path, so the server
      -- finds the demo's wiki all the same.
      demoBase <- baseOf <$> TextIO.readFile (demoDir </> "index.html")
      demoRoute <- route page (smoke.origin <> demoBase <> "**") (serveTheDemo demoDir demoBase)
      visit page (address smoke demoBase)
      -- The demo reads its wiki from IndexedDB once started.
      waitQuiet page
      hasText (locator page "#app .user-switcher-toggle") "Ada Admin"
      click (locator page "#app .wiki-header a.admin-link")
      click (locator page "#app .admin-nav-link[data-section=backups]")
      waitQuiet page
      exported <- download page (click (locator page "#app .admin-view .demo-export"))
      demoExport <- downloadBytes exported
      -- Taken away with the page at rest, after the download.
      unroute demoRoute
      report ("the demo, served at the server's address, keeps its wiki in this browser and exports it as " <> exported.suggestedFilename)

      -- A write without the application's header is another site's, and
      -- refused even with the administrator's cookie.
      s <- adminSession smoke
      forged <- fetchAs smoke.wiki (Just s) True "POST" "/api/v1/spaces" [("Content-Type", "application/json")] (Just (bodyOf (object ["parent" .= Null, "name" .= ("Forged" :: Text)])))
      forged.status `shouldBe` 403

      -- A page the server has at a path the demo's export has too: a
      -- conflict.
      blog <- asAdmin smoke "POST" "spaces" (Just (object ["parent" .= Null, "name" .= ("Blog" :: Text)])) >>= expectStatus 201 "the server's Blog" >>= apiJson
      blogId <- text (blog .! "id")
      made <- asAdmin smoke "POST" ("spaces/" <> escape blogId <> "/pages") (Just (object ["parent" .= Null, "title" .= ("Hello, world" :: Text), "body" .= ("Written on the server." :: Text)])) >>= expectStatus 201 "the server's Hello, world" >>= apiJson
      made .! "slug" `shouldBe` String "hello-world"

      -- The server's administration offers both sources: a zip file, and
      -- the demo's data, since the demo left it in this origin.
      visit page (address smoke "/")
      waitQuiet page
      hasText (locator page "#app .user-name") adminName
      count (locator page "#app .sign-out") `shouldReturn` 1
      click (locator page "#app .wiki-header a.admin-link")
      click (locator page "#app .admin-nav-link[data-section=backups]")
      waitQuiet page
      count (locator page "#app .admin-view .import-sources .import-demo") `shouldReturn` 1

      -- The export first: Notes on Haskell left out, and the demo's Hello,
      -- world taken over the server's.
      setInputFiles (locator page "#app .import-file input[type=file]") [UploadBytes {name = "demo-export.zip", mimeType = "application/zip", bytes = demoExport}]
      waitQuiet page
      let dialog = locator page "#app .import-dialog"
          spaceRow path = locator dialog (".import-space[data-path='" <> path <> "'] > .import-row")
          pageItem space path = locator dialog (".import-space[data-path='" <> space <> "'] .import-page[data-path='" <> path <> "']")
          badge l = Text.strip <$> textContent (first (locator l ".badge"))
      hasText (locator dialog "h3") "What to migrate"
      badge (spaceRow "blog") `shouldReturn` "Already here: merged"
      badge (spaceRow "docs") `shouldReturn` "New"
      badge (pageItem "blog" "hello-world") `shouldReturn` "In conflict"
      count (locator dialog "input.import-check:not(:checked)") `shouldReturn` 0
      uncheck (locator (pageItem "blog" "notes-on-haskell") "input.import-check")
      check (locator (pageItem "blog" "hello-world") "input.import-take")
      click (locator dialog ".import-apply")
      waitQuiet page
      told <- textContent (locator page "#app .import-summary")
      forM_ ["3 spaces created", "1 space merged with the server's", "9 pages created", "1 page replaced by the imported one", "1 page left out"] $ \line ->
        includes told line "the summary"
      -- The shell has reloaded the tree of spaces, with the demo's in it:
      -- the search box offers Docs (the sidebar is the administration's
      -- here).
      expect' (count (withText "Docs" (locator page "#app .search-space option"))) (> 0) "the search box offers no Docs"
      hello <- pageAt smoke "blog" "hello-world"
      helloBody <- text (hello .! "body")
      expect (not ("Written on the server." `Text.isInfixOf` helloBody)) "the server's Hello, world was not replaced"
      -- The server's Blog was made with its home page, the root of its
      -- pages, listed first; Notes on Haskell, left out, is not there.
      slugsOf smoke "blog" `shouldReturn` ["home", "hello-world"]
      -- The tour is Docs' home page, at the space's address.
      visit page (address smoke "/s/docs/")
      waitQuiet page
      hasText (locator page "#app .page-view h1") "Tour"
      report "the demo's export is imported through the dialog, a page left out and a conflict taking the imported page, and its summary shown"

      -- Again, from the demo's data in this browser: everything is merged,
      -- and nothing is there twice; the page left out comes in now. The
      -- pages kept are the ten the first import brought, and the Blog's
      -- home page: the demo's and the server's are both the one a new Blog
      -- is made with, the same title and text at the same path.
      click (locator page "#app .wiki-header a.admin-link")
      click (locator page "#app .admin-nav-link[data-section=backups]")
      waitQuiet page
      click (locator page "#app .admin-view .import-demo")
      waitQuiet page
      hasText (locator dialog "h3") "What to migrate"
      from <- textContent (locator dialog ".import-from")
      expect ("From this browser's demo data: 4 spaces (4 already here)" `Text.isPrefixOf` from) ("the second import's source: " <> show from)
      count (locator dialog ".import-space.import-new") `shouldReturn` 0
      count (locator dialog ".import-choice") `shouldReturn` 0
      badge (pageItem "blog" "notes-on-haskell") `shouldReturn` "New"
      click (locator dialog ".import-apply")
      waitQuiet page
      again <- textContent (locator page "#app .import-summary")
      forM_ ["4 spaces merged with the server's", "1 page created", "11 pages kept as the server had them"] $ \line ->
        includes again line "the second summary"
      spaces <- asAdmin smoke "GET" "spaces" Nothing >>= apiJson >>= list >>= traverse (text . (.! "slug"))
      let paths = sort spaces
      paths `shouldBe` nub paths
      sort <$> slugsOf smoke "blog" `shouldReturn` ["hello-world", "home", "notes-on-haskell"]
      counts <- forM ["blog", "docs", "team", "team/projects"] $ \space -> do
        spacePages <- pagesOf smoke space
        slugs <- forM spacePages $ \p -> (\parent slug -> parent <> "/" <> slug) <$> pure (textOr "" (p .! "parent")) <*> text (p .! "slug")
        unless (slugs == nub slugs) $ expectationFailure ("a page of " <> Text.unpack space <> " is there twice: " <> show slugs)
        pure (length slugs)
      sum counts `shouldBe` 12
      -- The team's template came in as one: listed apart, and offered.
      team <- pagesOf smoke "team"
      templates <- forM [p | p <- team, p .! "template" == Bool True] (text . (.! "slug"))
      templates `shouldBe` ["weekly-sync"]
      report "imported again from the demo's data in this browser, everything is merged and nothing is there twice"

  -- A long page with its "Contents" panel, and a page with [[!toc]], as
  -- the server renders them: adopted with nothing to repair or ask, while
  -- the section being read is marked by the script alone.
  step' "renders a page's contents and [[!toc]], adopted with nothing to repair, and scrolls to and marks an address's #heading" $ \pw ->
    inBrowser smoke pw Admin $ \reader -> do
      loads <- holdLoads reader
      -- The guide embeds its presentation: the viewer's read of it, once
      -- the program has started, is not of what the page carries.
      docs <- get smoke.wiki Nothing "/api/v1/spaces/at/docs" >>= apiJson
      docsId <- text (docs .! "id")
      guide <- get smoke.wiki Nothing ("/api/v1/spaces/" <> docsId <> "/pages/at/markdown-guide") >>= apiJson
      guideBody <- text (guide .! "body")
      let embedded = presentationsEmbedded guideBody "markdown-guide"
      embedded `shouldBe` ["markdown-guide/presentations"]
      forM_ [("/s/docs/p/markdown-guide/", "Contents"), ("/s/team/", "Before your first day")] $ \(path, expected) -> do
        loaded <- loadAdopted smoke loads reader path
        loaded.status `shouldBe` Just 200
        includes loaded.shown expected (Text.unpack path <> " before app.wasm")
        unless (null loaded.repairs) $ expectationFailure (Text.unpack path <> ": adopting it repaired it:\n" <> unlines (map (Text.unpack . describeRepair) loaded.repairs))
        filter (not . (`viewerAsks` embedded)) loaded.asked `shouldBe` []
        when (path == "/s/docs/p/markdown-guide/") $ do
          -- The embed, far down the page, is the link until it comes near
          -- the window; scrolled to, it is the viewer, which reads its page
          -- once. The browser says when it comes near (an
          -- IntersectionObserver): a condition, on the viewer's first slide
          -- drawn; then the program is quiet.
          _ :: Value <- evaluateOn (locator reader "#app article.page-body > p > a[href$='markdown-guide/presentations/']:only-child") "(link) => { link.scrollIntoView(); return null; }" ()
          waitFor (first (locator reader "#app article.page-body .deck-embed .slide-title")) Visible
          waitQuiet reader
          viewer <- filter (`viewerAsks` embedded) <$> askedSince reader
          length viewer `shouldBe` 1
      count (locator reader "#app .page-body nav.toc") `shouldReturn` 1
      count (locator reader "#app .page-contents") `shouldReturn` 0
      visit reader (address smoke "/s/docs/p/markdown-guide/#mathematics")
      -- The section being read is marked by the contents' own script
      -- (wiki-app/jsbits/toc.js), as the window scrolls there: a
      -- condition.
      waitFor (locator reader "#app .page-contents .toc-list a[href='#mathematics'][data-current]") Attached
      settle reader
  where
    bodyOf = RequestBodyLBS . Aeson.encode
    expect' get' holds message = get' >>= \v -> expect (holds v) message

-- | A space's pages' slugs, as the API lists them.
slugsOf :: Smoke -> Text -> IO [Text]
slugsOf smoke space = pagesOf smoke space >>= traverse (text . (.! "slug"))

-- | The base path a built page names in its @<base href>@ (@/@ without one).
baseOf :: Text -> Text
baseOf index = case Text.breakOn "<base href=\"" index of
  (_, rest) | not (Text.null rest) -> Text.takeWhile (/= '"') (Text.drop (Text.length "<base href=\"") rest)
  _ -> "/"

-- | Serve the demo's build in the server's place, as a static host serves
-- it: a file by its path under the base path, a directory's
-- @index.html@, and the demo's @404.html@ with a 404 for an address with
-- no file; nothing kept by the browser.
serveTheDemo :: FilePath -> Text -> RoutedRequest -> IO Answer
serveTheDemo dir base request = do
  let path = Text.decodeUtf8Lenient (urlDecode False (Text.encodeUtf8 (pathOf request.url)))
      relative = Text.unpack (Text.drop (Text.length base) path)
      file = normalise (dir </> (if null relative || last relative == '/' then relative <> "index.html" else relative))
      headers = [("Cache-Control", "no-store")]
  isFile <- doesFileExist file
  if isFile
    then do
      bytes <- ByteString.readFile file
      pure (Fulfill Response {status = 200, headers, contentType = Just (Text.decodeUtf8 (mediaType file)), body = bytes})
    else do
      bytes <- ByteString.readFile (dir </> "404.html")
      pure (Fulfill Response {status = 404, headers, contentType = Just "text/html", body = bytes})
  where
    pathOf whole =
      let afterScheme = snd (Text.breakOnEnd "://" whole)
       in Text.takeWhile (\c -> c /= '?' && c /= '#') (Text.dropWhile (/= '/') afterScheme)
