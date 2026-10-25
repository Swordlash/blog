-- | The pages the server renders ("Wiki.Server.Render"), over the demo's
-- wiki, driven over HTTP: each route's page complete before any program
-- runs, as the listener's principal sees it, with its status; the data the
-- render read written into the page, the API's answers exactly; the admin
-- listener's pages under its own place; and the build's own page when a
-- render fails.
--
-- That the program adopts these pages with nothing to repair is
-- @wiki-app@'s @Test.Hydrate@ (the same render, natively) and the smoke
-- test's (the built pages, in a browser).
module Test.Server.Render (spec) where

import Data.Aeson (FromJSON, eitherDecodeStrict')
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.Text qualified as T
import Database.SQLite.Simple (execute_, withConnection)
import Network.HTTP.Types (Header)
import Protolude
import System.FilePath ((</>))
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Error (errorStatus)
import Wiki.Api.Links (links, searchUrl)
import Wiki.App.Backend.Http.Preload
import Wiki.App.Route (Against (..), Route (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Render (routeOf)
import Wiki.Server.Storage.Layout (databaseFile)

spec :: Spec
spec = describe "the pages the server renders" $ do
  anonymous
  administrator
  adminListener
  basePathAndLoad
  preloads
  addresses
  failures

bodyText :: Reply -> Text
bodyText reply = decodeUtf8 (BSL.toStrict reply.body)

-- | A page's status and text.
page :: Running -> Text -> Text -> IO (Int, Text)
page r = pageAs r []

-- | A page's status and text, asked for with these headers (a session's
-- cookie).
pageAs :: Running -> [Header] -> Text -> Text -> IO (Int, Text)
pageAs r hs root path = (\reply -> (reply.status, bodyText reply)) <$> getUrlWith r (root <> path) hs

-- | What a page carries for the program, as its script holds it.
preloadIn :: (HasCallStack) => Text -> IO Preload
preloadIn html = do
  let opening = "<script type=\"application/json\" id=\"" <> preloadId <> "\">"
  carried <- case T.breakOn opening html of
    (_, rest) | not (T.null rest) -> pure (fst (T.breakOn "</script>" (T.drop (T.length opening) rest)))
    _ -> assertFailure "the page carries no preload"
  when (T.any (== '<') carried) $ assertFailure "the preload has a < in it"
  either (\e -> assertFailure ("the preload is not one: " <> e)) pure (eitherDecodeStrict' (encodeUtf8 carried))

-- | The application's part of a page, which is what a reader without the
-- program sees: what is inside its mount point.
appIn :: Text -> Text
appIn html = fst (T.breakOn "<script" (snd (T.breakOn "<div id=\"app\">" html)))

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

anonymous :: Spec
anonymous = describe "for someone not signed in" $ do
  it "renders the front page with the public spaces" $ withDemoRunning identity $ \r -> do
    (status, html) <- page r r.public "/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<title>Wiki</title>"
    appIn html `shouldSatisfy` T.isInfixOf "<h1>Spaces</h1>"
    appIn html `shouldSatisfy` T.isInfixOf "<p class=\"space-card-meta\">5 pages <span class=\"badge badge-public\">Public</span></p>"
    appIn html `shouldSatisfy` T.isInfixOf "Docs"
    appIn html `shouldSatisfy` T.isInfixOf "class=\"sign-in-toggle\""
    appIn html `shouldNotSatisfy` T.isInfixOf "Team"
    appIn html `shouldNotSatisfy` T.isInfixOf "Loading…"

  it "renders a space, a page, its source and a search with what they show" $ withDemoRunning identity $ \r -> do
    (spaceStatus, space) <- page r r.public "/s/docs/"
    spaceStatus `shouldBe` 200
    appIn space `shouldSatisfy` T.isInfixOf "Markdown guide"
    space `shouldSatisfy` T.isInfixOf "<title>Docs · Wiki</title>"
    -- A space opens at its home page, the tour, in a sidebar of its own.
    appIn space `shouldSatisfy` T.isInfixOf "<h1 id=\"tour\">Tour</h1>"
    appIn space `shouldSatisfy` T.isInfixOf "class=\"wiki-sidebar space-sidebar\""
    -- No other space in the sidebar (the tour links to the blog itself).
    appIn space `shouldNotSatisfy` T.isInfixOf "class=\"space-link\" href=\"/s/blog/\""
    (pagesStatus, pages) <- page r r.public "/s/docs/pages/"
    pagesStatus `shouldBe` 200
    pages `shouldSatisfy` T.isInfixOf "<title>Pages and settings · Docs · Wiki</title>"
    appIn pages `shouldSatisfy` T.isInfixOf "<h1>Docs</h1>"
    appIn pages `shouldSatisfy` T.isInfixOf "<p class=\"space-description\">How to use this wiki: a guided tour, and everything its Markdown can do.</p>"
    (tourStatus, tour) <- page r r.public "/s/docs/p/tour/"
    tourStatus `shouldBe` 200
    tour `shouldSatisfy` T.isInfixOf "<title>Tour · Docs · Wiki</title>"
    appIn tour `shouldSatisfy` T.isInfixOf "anyone may read them, signed in or not."
    (sourceStatus, source) <- page r r.public "/s/docs/p/tour/source/"
    sourceStatus `shouldBe` 200
    appIn source `shouldSatisfy` T.isInfixOf "| nobody (not signed in)   | read the public spaces, **Blog** and **Docs**        |"
    (historyStatus, history) <- page r r.public "/s/docs/p/tour/history/"
    historyStatus `shouldBe` 200
    history `shouldSatisfy` T.isInfixOf "<title>History · Tour · Wiki</title>"
    appIn history `shouldSatisfy` T.isInfixOf "Version 1 (current)"
    appIn history `shouldSatisfy` T.isInfixOf "<td class=\"diff-text\"># Tour</td>"
    (slidesStatus, slides) <- page r r.public "/s/docs/p/markdown-guide/presentations/slides/?slide=3"
    slidesStatus `shouldBe` 200
    slides `shouldSatisfy` T.isInfixOf "<title>Slides · Presentations · Wiki</title>"
    appIn slides `shouldSatisfy` T.isInfixOf "<div class=\"slide-frame current\" data-slide=\"3\">"
    appIn slides `shouldSatisfy` T.isInfixOf ">3 / 7</span>"
    (searchStatus, search) <- page r r.public "/search/?q=tour"
    searchStatus `shouldBe` 200
    appIn search `shouldSatisfy` T.isInfixOf "class=\"search-hit\""
    appIn search `shouldNotSatisfy` T.isInfixOf "Searching…"

  it "renders nothing of a private space but that it is private, with a 403" $ withDemoRunning identity $ \r -> do
    for_ ["/s/team/", "/s/team/pages/", "/s/team/projects/", "/s/team/p/team-handbook/", "/s/team/p/team-handbook/source/", "/s/team/p/team-handbook/history/", "/s/team/p/team-handbook/slides/"] $ \path -> do
      (status, html) <- page r r.public path
      status `shouldBe` 403
      html `shouldNotSatisfy` T.isInfixOf "handbook"
      html `shouldNotSatisfy` T.isInfixOf "Handbook"
      appIn html `shouldSatisfy` T.isInfixOf "error-forbidden"

  it "renders what is not there with a 404: an address, a space, a page, a version" $ withDemoRunning identity $ \r -> do
    for_ ["/nowhere/at/all", "/s/nowhere/", "/s/nowhere/pages/", "/s/docs/p/nowhere/", "/s/docs/p/nowhere/history/", "/s/docs/p/nowhere/slides/", "/s/docs/p/tour/history/?version=2020-01-01T00%3A00%3A00Z"] $ \path -> do
      (status, html) <- page r r.public path
      (path, status) `shouldBe` (path, 404)
      appIn html `shouldSatisfy` \a -> "Not found" `T.isInfixOf` a || "error-not-found" `T.isInfixOf` a
      appIn html `shouldSatisfy` T.isInfixOf "wiki-sidebar"

  it "renders the editor's address with why it cannot edit" $ withDemoRunning identity $ \r -> do
    (status, html) <- page r r.public "/s/blog/p/hello-world/edit/"
    status `shouldBe` 200
    appIn html `shouldSatisfy` T.isInfixOf "class=\"editor\""
    appIn html `shouldNotSatisfy` T.isInfixOf "<textarea"

administrator :: Spec
administrator = describe "for an administrator signed in" $ do
  it "renders the private spaces with their pages, and the administration" $ withAdminSession identity $ \r session -> do
    (status, html) <- pageAs r [session] r.public "/s/team/p/team-handbook/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<title>Team handbook · Team · Wiki</title>"
    appIn html `shouldSatisfy` T.isInfixOf "Ada Admin"
    appIn html `shouldSatisfy` T.isInfixOf "Sign out"
    (adminStatus, admin) <- pageAs r [session] r.public "/admin/"
    adminStatus `shouldBe` 200
    appIn admin `shouldSatisfy` T.isInfixOf "class=\"user-table\""
    appIn admin `shouldSatisfy` T.isInfixOf "Edgar Editor"
    -- The same address, to nobody: neither the space nor the administration.
    (.status) <$> getUrl r (r.public <> "/s/team/p/team-handbook/") `shouldReturn` 403
    (_, refused) <- page r r.public "/admin/"
    appIn refused `shouldNotSatisfy` T.isInfixOf "user-table"

  it "renders the editor with the page's Markdown in it" $ withAdminSession identity $ \r session -> do
    (status, html) <- pageAs r [session] r.public "/s/blog/p/hello-world/edit/"
    status `shouldBe` 200
    appIn html `shouldSatisfy` T.isInfixOf "<textarea"
    appIn html `shouldSatisfy` T.isInfixOf "Editing Hello, world"
    preload <- preloadIn html
    map (\d -> d.draft) preload.drafts `shouldBe` [Gave Nothing]

adminListener :: Spec
adminListener = describe "on the admin listener" $ do
  it "renders as the administrator, with its links and its base below /admin/" $ withDemoRunning identity $ \r -> do
    (status, html) <- page r r.admin "/admin/s/team/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<base href=\"/admin/\">"
    appIn html `shouldSatisfy` T.isInfixOf "href=\"/admin/s/team/p/team-handbook/\""
    appIn html `shouldNotSatisfy` T.isInfixOf "href=\"/s/"

basePathAndLoad :: Spec
basePathAndLoad = describe "under a base path, and many at once" $ do
  it "renders under the public listener's base path, with its links below it" $ withDemoRunning (\o -> o {basePath = "/wiki"}) $ \r -> do
    (status, html) <- page r r.public "/wiki/s/docs/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<base href=\"/wiki/\">"
    appIn html `shouldSatisfy` T.isInfixOf "href=\"/wiki/s/docs/p/tour/\""
    appIn html `shouldNotSatisfy` T.isInfixOf "href=\"/s/"

  it "renders pages asked for at once as it renders them one by one" $ withAdminSession identity $ \r session -> do
    let paths = concat (replicate 4 ["/", "/s/docs/", "/s/docs/p/tour/", "/s/team/p/team-handbook/", "/search/?q=haskell", "/s/blog/p/hello-world/edit/", "/nowhere"])
    alone <- traverse (pageAs r [session] r.public) paths
    together <- runConcurrently (traverse (Concurrently . pageAs r [session] r.public) paths)
    together `shouldBe` alone

preloads :: Spec
preloads = describe "what a page carries for the program" $ do
  it "is the API's answers to the same reader, exactly" $ withDemoRunning identity $ \r -> do
    for_ ["/", "/s/docs/", "/s/docs/p/markdown-guide/diagrams/", "/s/team/", "/s/nowhere/", "/search/?q=haskell", "/s/blog/p/hello-world/edit/"] $ \path -> do
      (_, html) <- page r r.public path
      p <- preloadIn html
      let api :: (FromJSON a) => Text -> IO a
          api address = ok200 (getUrl r (r.public <> "/" <> address))
          refusedAs :: Text -> Int -> IO ()
          refusedAs address code = (.status) <$> getUrl r (r.public <> "/" <> address) `shouldReturn` code
          answers :: (FromJSON a, Eq a, Show a) => Text -> Answer a -> IO ()
          answers address = \case
            Gave a -> api address `shouldReturn` a
            Refused e -> refusedAs address (errorStatus e)
      for_ p.session $ \s -> api links.session `shouldReturn` s
      for_ p.spaces $ \ss -> api links.spaces.list `shouldReturn` ss
      for_ p.spacesAt $ \s -> answers (links.spaces.atPath s.path) s.space
      for_ p.pages $ \s -> answers (links.spaces.listPages s.space) s.pages
      for_ p.pagesAt $ \x -> answers (links.spaces.pageAt x.space x.path) x.page
      for_ p.drafts $ \d -> answers (links.pages.draft d.page) d.draft
      for_ p.searches $ \s -> api (searchUrl s.query) `shouldReturn` s.hits

  it "holds what the route shows, and no page twice" $ withDemoRunning identity $ \r -> do
    (_, html) <- page r r.public "/s/docs/p/tour/"
    p <- preloadIn html
    (isJust p.session, map (\s -> s.path) p.spacesAt, length p.pages) `shouldBe` (True, [slugs "docs"], 1)
    -- The page is in its space's list, so not carried again by itself.
    p.pagesAt `shouldBe` []

addresses :: Spec
addresses = describe "a request's address" $ do
  it "is read as the program's router reads it, below the listener's place" $ do
    routeOf "/" "/s/docs/p/tour/" `shouldReturn` Page (slugs "docs") (slugs "tour")
    routeOf "/admin/" "/admin/s/docs/p/tour/source/" `shouldReturn` PageSource (slugs "docs") (slugs "tour")
    routeOf "/" "/s/docs/p/tour/history/?against=current" `shouldReturn` PageHistory (slugs "docs") (slugs "tour") Nothing AgainstCurrent
    routeOf "/" "/s/docs/p/tour/slides/?slide=2" `shouldReturn` PageSlides (slugs "docs") (slugs "tour") 2
    routeOf "/wiki/" "/wiki/search/?q=a%20b&only" `shouldReturn` Search (Just "a b") Nothing False
    routeOf "/" "/s/docs" `shouldReturn` Space (slugs "docs")
    routeOf "/" "/elsewhere/" `shouldReturn` Unknown
    routeOf "/wiki/" "/s/docs/" `shouldReturn` Unknown

failures :: Spec
failures = describe "when a render fails" $ do
  it "sends the build's own page, and says why in the log" $ withDemoRunning identity $ \r -> do
    -- The storage failing under the API: every read of a space fails.
    withConnection (databaseFile r.dataDir) $ \c -> execute_ c "ALTER TABLE spaces RENAME TO spaces_gone"
    (frontStatus, front) <- page r r.public "/"
    (frontStatus, front) `shouldSatisfy` (\(s, b) -> s == 200 && "<title>front</title>" `T.isInfixOf` b)
    (spaceStatus, space) <- page r r.public "/s/docs/"
    (spaceStatus, space) `shouldSatisfy` (\(s, b) -> s == 404 && "<title>missing</title>" `T.isInfixOf` b)
    logged <- readIORef r.logged
    filter (\l -> "level=error event=render" `T.isPrefixOf` l) logged `shouldSatisfy` ((>= 2) . length)

  it "sends the build's own page for a template it cannot fill" $ withDemoRunning identity $ \r -> do
    writeFile (r.staticDir </> "template.html") "<html><body>no mount point</body></html>"
    (status, html) <- page r r.public "/s/docs/"
    (status, html) `shouldSatisfy` (\(s, b) -> s == 404 && "<title>missing</title>" `T.isInfixOf` b)
