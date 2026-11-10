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

import Data.Aeson (FromJSON, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Network.HTTP.Types (Header, hContentType, methodPost, methodPut)
import Numeric (showHex)
import Protolude
import System.FilePath ((</>))
import Test.Database (Backing, withConnectionTo)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (demoArchive)
import Wiki.Api (PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.ContentPolicy (headerPolicy, pagePolicy)
import Wiki.Api.Encrypted (EncryptSpace (..), NewGrant (..), NewSealedPage (..), SealedPage (..))
import Wiki.Api.Links (links, searchUrl)
import Wiki.Api.Types qualified as Api
import Wiki.Api.Vault (NewPublicKey (..), VaultChange (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Http.Cache (Cache (..), CachedDraft (..), draftAnswer)
import Wiki.App.Backend.Http.Client (sessionInfo)
import Wiki.App.Backend.Http.Preload
import Wiki.App.Route (Against (..), Route (..))
import Wiki.Core.Encrypted (Encapsulated (..), PageKey (..), SealedContent (..), VersionTag (..))
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Id (PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space qualified as S
import Wiki.Core.Vault
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Options qualified as Options
import Wiki.Server.Render (routeAddress, routeOf)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Vault (keyIdOf)
import Wiki.Server.WebAuthn (toBase64Url)

spec :: Backing -> Spec
spec backing = describe "the pages the server renders" $ do
  anonymous backing
  administrator backing
  adminListener backing
  basePathAndLoad backing
  preloads backing
  addresses
  permanentAddresses backing
  failures backing
  encrypted backing

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
preloadIn :: (HasCallStack) => Text -> IO Cache
preloadIn html = do
  let opening = "<script type=\"application/json\" id=\"" <> preloadId <> "\">"
  carried <- case T.breakOn opening html of
    (_, rest) | not (T.null rest) -> pure (fst (T.breakOn "</script>" (T.drop (T.length opening) rest)))
    _ -> assertFailure "the page carries no preload"
  when (T.any (== '<') carried) $ assertFailure "the preload has a < in it"
  either (\e -> assertFailure ("the preload is not one: " <> toS e)) pure (decodePreload carried)

-- | The application's part of a page, which is what a reader without the
-- program sees: what is inside its mount point.
appIn :: Text -> Text
appIn html = fst (T.breakOn "<script" (snd (T.breakOn "<div id=\"app\">" html)))

slugs :: Text -> [Slug]
slugs = either (panic . show) identity . parsePath

anonymous :: Backing -> Spec
anonymous backing = describe "for someone not signed in" $ do
  it "renders the front page with the public spaces" $ withDemoRunning backing identity $ \r -> do
    (status, html) <- page r r.public "/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<title>Wiki</title>"
    appIn html `shouldSatisfy` T.isInfixOf "<h1 class=\"page-title\">Spaces</h1>"
    appIn html `shouldSatisfy` T.isInfixOf "<p class=\"space-card-meta\">5 pages <span class=\"badge badge-public\">Public</span></p>"
    appIn html `shouldSatisfy` T.isInfixOf "Docs"
    appIn html `shouldSatisfy` T.isInfixOf "class=\"sign-in-toggle\""
    appIn html `shouldNotSatisfy` T.isInfixOf "Team"
    appIn html `shouldNotSatisfy` T.isInfixOf "Loading…"

  it "sends a rendered page with its Content Security Policy, in the header and the page alike" $
    withDemoRunning backing (\o -> o {Options.assistantHosts = ["http://localhost:11434"]}) $ \r -> do
      reply <- getUrl r (r.public <> "/")
      reply.status `shouldBe` 200
      header "Content-Security-Policy" reply `shouldBe` Just (encodeUtf8 (headerPolicy ["http://localhost:11434"]))
      decodeUtf8 (BSL.toStrict reply.body) `shouldSatisfy` T.isInfixOf ("<meta http-equiv=\"Content-Security-Policy\" content=\"" <> pagePolicy ["http://localhost:11434"] <> "\">")

  it "renders a space, a page, its source and a search with what they show" $ withDemoRunning backing identity $ \r -> do
    (spaceStatus, space) <- page r r.public "/s/docs/"
    spaceStatus `shouldBe` 200
    appIn space `shouldSatisfy` T.isInfixOf "Markdown guide"
    space `shouldSatisfy` T.isInfixOf "<title>Docs · Wiki</title>"
    -- A space opens at its home page, the tour, in a sidebar of its own.
    appIn space `shouldSatisfy` T.isInfixOf "<h1 id=\"tour\">Tour<a aria-label=\"Link to this section\" class=\"heading-anchor\" href=\"#tour\"></a></h1>"
    appIn space `shouldSatisfy` T.isInfixOf "class=\"wiki-sidebar space-sidebar\""
    -- No other space in the sidebar (the tour links to the blog itself).
    appIn space `shouldNotSatisfy` T.isInfixOf "class=\"space-link\" href=\"/s/blog/\""
    (pagesStatus, pages) <- page r r.public "/s/docs/pages/"
    pagesStatus `shouldBe` 200
    pages `shouldSatisfy` T.isInfixOf "<title>Space settings · Docs · Wiki</title>"
    appIn pages `shouldSatisfy` T.isInfixOf "<h1>Docs</h1>"
    appIn pages `shouldSatisfy` T.isInfixOf "<p class=\"space-description\">How to use this wiki: a guided tour, and everything its Markdown can do.</p>"
    -- The tour is Docs' home page, at the space's address; its old address
    -- still shows it.
    (tourStatus, tour) <- page r r.public "/s/docs/p/tour/"
    tourStatus `shouldBe` 200
    tour `shouldSatisfy` T.isInfixOf "<title>Docs · Wiki</title>"
    appIn tour `shouldSatisfy` T.isInfixOf "anyone may read them, signed in or not."
    (guideStatus, guide) <- page r r.public "/s/docs/p/markdown-guide/"
    guideStatus `shouldBe` 200
    guide `shouldSatisfy` T.isInfixOf "<title>Markdown guide · Docs · Wiki</title>"
    (sourceStatus, source) <- page r r.public "/s/docs/source/"
    sourceStatus `shouldBe` 200
    appIn source `shouldSatisfy` T.isInfixOf "| nobody (not signed in)   | read the public spaces, **Blog** and **Docs**        |"
    (historyStatus, history) <- page r r.public "/s/docs/history/"
    historyStatus `shouldBe` 200
    history `shouldSatisfy` T.isInfixOf "<title>History · Docs · Wiki</title>"
    appIn history `shouldSatisfy` T.isInfixOf "Version 1 (current)"
    appIn history `shouldSatisfy` T.isInfixOf "<td class=\"diff-text\"># Tour</td>"
    (slidesStatus, slides) <- page r r.public "/s/docs/p/markdown-guide/presentations/slides/?slide=3"
    slidesStatus `shouldBe` 200
    slides `shouldSatisfy` T.isInfixOf "<title>Slides · Presentations · Wiki</title>"
    appIn slides `shouldSatisfy` T.isInfixOf "<div class=\"slide-frame current\" data-slide=\"3\">"
    appIn slides `shouldSatisfy` T.isInfixOf ">3 / 9</span>"
    -- A slide at a step: what the steps after it show is there, hidden.
    (_, stepped) <- page r r.public "/s/docs/p/markdown-guide/presentations/slides/?slide=7&step=2"
    appIn stepped `shouldSatisfy` T.isInfixOf "<div class=\"slide-frame current\" data-slide=\"7\">"
    appIn stepped `shouldSatisfy` T.isInfixOf "<div class=\"slide-step\"><p>Like this line"
    appIn stepped `shouldSatisfy` T.isInfixOf "<div class=\"slide-step slide-step-later\"><p>On the page itself"
    (searchStatus, search) <- page r r.public "/search/?q=tour"
    searchStatus `shouldBe` 200
    appIn search `shouldSatisfy` T.isInfixOf "class=\"search-hit\""
    appIn search `shouldNotSatisfy` T.isInfixOf "Searching…"

  it "renders a private space as not there, with a 404, and nothing of it" $ withDemoRunning backing identity $ \r -> do
    for_ ["/s/team/", "/s/team/pages/", "/s/team/projects/", "/s/team/p/team-handbook/", "/s/team/p/team-handbook/source/", "/s/team/p/team-handbook/history/", "/s/team/p/team-handbook/slides/", "/s/team/p/nowhere/"] $ \path -> do
      (status, html) <- page r r.public path
      (path, status) `shouldBe` (path, 404)
      html `shouldNotSatisfy` T.isInfixOf "handbook"
      html `shouldNotSatisfy` T.isInfixOf "Handbook"
      appIn html `shouldSatisfy` T.isInfixOf "error-not-found"
      appIn html `shouldNotSatisfy` T.isInfixOf "error-forbidden"

  it "renders what is not there with a 404: an address, a space, a page, a version" $ withDemoRunning backing identity $ \r -> do
    for_ ["/nowhere/at/all", "/s/nowhere/", "/s/nowhere/pages/", "/s/docs/p/nowhere/", "/s/docs/p/nowhere/history/", "/s/docs/p/nowhere/slides/", "/s/docs/history/?version=2020-01-01T00%3A00%3A00Z", "/s/docs/p/tour/history/?version=2020-01-01T00%3A00%3A00Z"] $ \path -> do
      (status, html) <- page r r.public path
      (path, status) `shouldBe` (path, 404)
      appIn html `shouldSatisfy` \a -> "Not found" `T.isInfixOf` a || "error-not-found" `T.isInfixOf` a
      appIn html `shouldSatisfy` T.isInfixOf "wiki-sidebar"

  it "renders the editor's address with why it cannot edit" $ withDemoRunning backing identity $ \r -> do
    (status, html) <- page r r.public "/s/blog/p/hello-world/edit/"
    status `shouldBe` 200
    appIn html `shouldSatisfy` T.isInfixOf "class=\"editor\""
    appIn html `shouldNotSatisfy` T.isInfixOf "<textarea"

administrator :: Backing -> Spec
administrator backing = describe "for an administrator signed in" $ do
  it "renders the private spaces with their pages, and the administration" $ withAdminSession backing identity $ \r session -> do
    (status, html) <- pageAs r [session] r.public "/s/team/p/on-call/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<title>On-call · Team · Wiki</title>"
    appIn html `shouldSatisfy` T.isInfixOf "Ada Admin"
    appIn html `shouldSatisfy` T.isInfixOf "Sign out"
    -- The administration's first section at /admin/, and the users at
    -- their own address, a page of them, with the page carrying them.
    (overviewStatus, overview) <- pageAs r [session] r.public "/admin/"
    overviewStatus `shouldBe` 200
    appIn overview `shouldSatisfy` T.isInfixOf "<h1>Overview</h1>"
    appIn overview `shouldSatisfy` T.isInfixOf "class=\"admin-nav\""
    (adminStatus, admin) <- pageAs r [session] r.public "/admin/users/?q=edgar"
    adminStatus `shouldBe` 200
    appIn admin `shouldSatisfy` T.isInfixOf "class=\"user-table\""
    appIn admin `shouldSatisfy` T.isInfixOf "Edgar Editor"
    appIn admin `shouldNotSatisfy` T.isInfixOf "Rita Reader"
    preload <- preloadIn admin
    Map.size preload.userPages `shouldBe` 1
    -- The same address, to nobody: neither the space nor the administration.
    (.status) <$> getUrl r (r.public <> "/s/team/p/on-call/") `shouldReturn` 404
    (_, refused) <- page r r.public "/admin/users/"
    appIn refused `shouldNotSatisfy` T.isInfixOf "user-table"

  it "renders the editor with the page's Markdown in it" $ withAdminSession backing identity $ \r session -> do
    (status, html) <- pageAs r [session] r.public "/s/blog/p/hello-world/edit/"
    status `shouldBe` 200
    appIn html `shouldSatisfy` T.isInfixOf "<textarea"
    appIn html `shouldSatisfy` T.isInfixOf "Editing Hello, world"
    preload <- preloadIn html
    Map.elems preload.drafts `shouldBe` [NoDraft]

adminListener :: Backing -> Spec
adminListener backing = describe "on the admin listener" $ do
  it "renders as the administrator, with its links and its base below /admin/" $ withDemoRunning backing identity $ \r -> do
    (status, html) <- page r r.admin "/admin/s/team/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<base href=\"/admin/\">"
    appIn html `shouldSatisfy` T.isInfixOf "href=\"/admin/s/team/p/on-call/\""
    appIn html `shouldNotSatisfy` T.isInfixOf "href=\"/s/"

basePathAndLoad :: Backing -> Spec
basePathAndLoad backing = describe "under a base path, and many at once" $ do
  it "renders under the public listener's base path, with its links below it" $ withDemoRunning backing (\o -> o {basePath = "/wiki"}) $ \r -> do
    (status, html) <- page r r.public "/wiki/s/docs/"
    status `shouldBe` 200
    html `shouldSatisfy` T.isInfixOf "<base href=\"/wiki/\">"
    appIn html `shouldSatisfy` T.isInfixOf "href=\"/wiki/s/docs/p/markdown-guide/\""
    appIn html `shouldNotSatisfy` T.isInfixOf "href=\"/s/"

  it "renders pages asked for at once as it renders them one by one" $ withAdminSession backing identity $ \r session -> do
    let paths = concat (replicate 4 ["/", "/s/docs/", "/s/docs/p/tour/", "/s/team/p/team-handbook/", "/search/?q=haskell", "/s/blog/p/hello-world/edit/", "/nowhere"])
    alone <- traverse (pageAs r [session] r.public) paths
    together <- runConcurrently (traverse (Concurrently . pageAs r [session] r.public) paths)
    together `shouldBe` alone

preloads :: Backing -> Spec
preloads backing = describe "what a page carries for the program" $ do
  it "is the API's answers to the same reader, exactly" $ withDemoRunning backing identity $ \r -> do
    for_ ["/", "/s/docs/", "/s/docs/p/markdown-guide/diagrams/", "/s/team/", "/s/nowhere/", "/search/?q=haskell", "/s/blog/p/hello-world/edit/"] $ \path -> do
      (_, html) <- page r r.public path
      p <- preloadIn html
      let api :: (FromJSON a) => Text -> IO a
          api address = ok200 (getUrl r (r.public <> "/" <> address))
          refusedAs :: Text -> Int -> IO ()
          refusedAs address code = (.status) <$> getUrl r (r.public <> "/" <> address) `shouldReturn` code
          -- Only these two refusals are kept ('Wiki.App.Backend.Http.Cache.kept').
          answers :: (FromJSON a, Eq a, Show a) => Text -> Either WikiError a -> IO ()
          answers address = \case
            Right a -> api address `shouldReturn` a
            Left NotFound -> refusedAs address 404
            Left Forbidden -> refusedAs address 403
            Left e -> assertFailure ("a refusal the preload does not keep: " <> show e)
      for_ p.session $ \s -> api links.session `shouldReturn` sessionInfo s
      for_ p.spaces $ \ss -> api links.spaces.list `shouldReturn` ss
      for_ (Map.toList p.spaceAt) $ \(at, s) -> answers (links.spaces.atPath at) s
      for_ (Map.toList p.pages) $ \(space, ps) -> answers (links.spaces.listPages space) ps
      for_ (Map.toList p.pageAt) $ \((space, at), x) -> answers (links.spaces.pageAt space at) x
      for_ (Map.toList p.drafts) $ \(pageId, d) -> answers (links.pages.draft pageId) (draftAnswer d)
      for_ p.searches $ \(query, hits) -> api (searchUrl query) `shouldReturn` hits

  it "holds what the route shows: its space's list of pages, and the page shown" $ withDemoRunning backing identity $ \r -> do
    (_, html) <- page r r.public "/s/docs/p/markdown-guide/"
    p <- preloadIn html
    (isJust p.session, Map.keys p.spaceAt, Map.size p.pages) `shouldBe` (True, [slugs "docs"], 1)
    -- The list of pages has no bodies, so the page shown is carried by
    -- itself, once.
    map snd (Map.keys p.pageAt) `shouldBe` [slugs "markdown-guide"]
    -- The home page at its old address is read at its address now, the
    -- space's.
    (_, home) <- page r r.public "/s/docs/p/tour/"
    homeLoad <- preloadIn home
    map snd (Map.keys homeLoad.pageAt) `shouldBe` [[]]

addresses :: Spec
addresses = describe "a request's address" $ do
  it "is read as the program's router reads it, below the listener's place" $ do
    routeOf "/" "/s/docs/p/tour/" `shouldReturn` Page (slugs "docs") (slugs "tour")
    routeOf "/admin/" "/admin/s/docs/p/tour/source/" `shouldReturn` PageSource (slugs "docs") (slugs "tour")
    routeOf "/" "/s/docs/p/tour/history/?against=current" `shouldReturn` PageHistory (slugs "docs") (slugs "tour") Nothing AgainstCurrent
    routeOf "/" "/s/docs/p/tour/slides/?slide=2" `shouldReturn` PageSlides (slugs "docs") (slugs "tour") 2 1
    routeOf "/wiki/" "/wiki/search/?q=a%20b&only" `shouldReturn` Search (Just "a b") Nothing False
    routeOf "/" "/s/docs" `shouldReturn` Space (slugs "docs")
    routeOf "/" "/elsewhere/" `shouldReturn` Unknown
    routeOf "/wiki/" "/s/docs/" `shouldReturn` Unknown
    routeOf "/" "/l/17/" `shouldReturn` PermanentLink (PageId "17") Nothing

-- | A page's permanent address (@\/l\/\<page id>\/@, WP5.81): a redirect
-- to the page's own address for a reader who may view the page, and for
-- anyone else exactly the page an address that names nothing gets.
permanentAddresses :: Backing -> Spec
permanentAddresses backing = describe "a page's permanent address" $ do
  it "redirects to the page's own address, for a while, on each listener" $ withDemoRunning backing identity $ \r -> do
    diagrams <- pageIdAt r [] "docs" "markdown-guide/diagrams"
    reply <- getUrl r (r.public <> "/l/" <> diagrams.text <> "/")
    (reply.status, header "Location" reply) `shouldBe` (302, Just "/s/docs/p/markdown-guide/diagrams/")
    -- It depends on who asks: no shared cache keeps it.
    (header "Cache-Control" reply, header "Vary" reply) `shouldBe` (Just "private, no-cache", Just "Cookie")
    -- Without its last slash, and with a query, which it drops.
    (header "Location" <$> getUrl r (r.public <> "/l/" <> diagrams.text <> "?x=1")) `shouldReturn` Just "/s/docs/p/markdown-guide/diagrams/"
    -- A space's home page is the space's address.
    tour <- pageIdAt r [] "docs" ""
    (header "Location" <$> getUrl r (r.public <> "/l/" <> tour.text <> "/")) `shouldReturn` Just "/s/docs/"
    -- The wiki's own home page is the front page.
    (_, home) :: (S.Space, P.Page) <- ok200 (getUrl r (r.public <> "/" <> links.homeDocument))
    (header "Location" <$> getUrl r (r.public <> "/l/" <> home.id.text <> "/")) `shouldReturn` Just "/"
    -- The admin listener sends its reader to its own place.
    (header "Location" <$> getUrl r (r.admin <> "/admin/l/" <> diagrams.text <> "/")) `shouldReturn` Just "/admin/s/docs/p/markdown-guide/diagrams/"

  it "redirects an address with a version to that version, shown as the page was, and a version the page does not have to not found" $ withDemoRunning backing identity $ \r -> do
    docs <- ok200 (getUrl r (r.public <> "/" <> links.spaces.atPath (slugs "docs"))) :: IO S.Space
    diagrams <- ok200 (getUrl r (r.public <> "/" <> links.spaces.pageAt docs.id (slugs "markdown-guide/diagrams"))) :: IO P.Page
    -- The addresses as the application's router writes them.
    let permanent t = routeAddress "/" (PermanentLink diagrams.id (Just t))
        versionAt t = routeAddress "/" (PageAtVersion (slugs "docs") (slugs "markdown-guide/diagrams") t)
    pinned <- permanent diagrams.updatedAt
    there <- versionAt diagrams.updatedAt
    there `shouldSatisfy` T.isPrefixOf "/s/docs/p/markdown-guide/diagrams/?version="
    reply <- getUrl r (r.public <> pinned)
    (reply.status, header "Location" reply) `shouldBe` (302, Just (encodeUtf8 there))
    (status, html) <- page r r.public there
    status `shouldBe` 200
    appIn html `shouldSatisfy` T.isInfixOf "This is the page as it was saved on"
    appIn html `shouldSatisfy` T.isInfixOf "<h1 id=\"diagrams\">Diagrams"
    -- The page may be viewed, so it is led there; the version is not there.
    let later = addUTCTime 1 diagrams.updatedAt
    nowhere <- versionAt later
    (header "Location" <$> (getUrl r . (r.public <>) =<< permanent later)) `shouldReturn` Just (encodeUtf8 nowhere)
    (missingStatus, missing) <- page r r.public nowhere
    missingStatus `shouldBe` 404
    appIn missing `shouldSatisfy` T.isInfixOf "error-not-found"

  -- A page's id is any text: an archive imported into an empty server
  -- keeps its ids, whatever they hold. The address is read from the raw
  -- path, never as a file's path.
  it "leads to a page whose id a path segment cannot hold, and answers a hidden one as a missing one, byte for byte" $
    withArchiveRunning backing awkwardDemo $ \r -> do
      let address pid = routeAddress "/" (PermanentLink (PageId pid) Nothing)
          request pid = address pid >>= getRawPath r r.public . encodeUtf8
      for_ visibleIds $ \(_, pid) -> do
        reply <- request pid
        (pid, reply.status, maybe False ("/s/docs/" `BS.isPrefixOf`) (header "Location" reply)) `shouldBe` (pid, 302, True)
        -- The API takes the id as its other addresses of a page do.
        located <- getRawPath r r.public ("/api/v1/pages/" <> encodeUtf8 (pathSegment pid) <> "/location")
        (pid, located.status) `shouldBe` (pid, 200)
      for_ hiddenIds $ \(_, pid) -> do
        -- An id no page has, as long and with the same characters.
        let missing = T.reverse pid <> "-gone"
        hiddenAddress <- address pid
        missingAddress <- address missing
        hidden <- request pid
        nothing <- request missing
        (pid, hidden.status, nothing.status) `shouldBe` (pid, 404, 404)
        -- The id is in the address, as it is, and in the preload's JSON.
        let inJson i = T.dropEnd 1 (T.drop 1 (decodeUtf8 (BSL.toStrict (encode i))))
            pageOf addr i reply = T.replace (inJson i) "ID" (T.replace i "ID" (T.replace addr "ADDRESS" (decodeUtf8 (BSL.toStrict reply.body))))
        appIn (pageOf hiddenAddress pid hidden) `shouldSatisfy` T.isInfixOf "error-not-found"
        (pid, pageOf hiddenAddress pid hidden) `shouldBe` (pid, pageOf missingAddress missing nothing)
        hiddenAnswer <- getRawPath r r.public ("/api/v1/pages/" <> encodeUtf8 (pathSegment pid) <> "/location")
        missingAnswer <- getRawPath r r.public ("/api/v1/pages/" <> encodeUtf8 (pathSegment missing) <> "/location")
        (pid, hiddenAnswer.status, hiddenAnswer.body) `shouldBe` (pid, 404, missingAnswer.body)

  it "follows a page moved to another space" $ withAdminSession backing identity $ \r session -> do
    diagrams <- pageIdAt r [session] "docs" "markdown-guide/diagrams"
    blog <- ok200 (getUrlWith r (r.public <> "/" <> links.spaces.atPath (slugs "blog")) [session]) :: IO S.Space
    moved <- send r methodPost (r.public <> "/" <> links.pages.move diagrams) [session, (hContentType, "application/json")] (encode Api.PageMove {Api.space = blog.id, Api.parent = Nothing})
    moved.status `shouldBe` 200
    (header "Location" <$> getUrl r (r.public <> "/l/" <> diagrams.text <> "/")) `shouldReturn` Just "/s/blog/p/diagrams/"

  it "renders a page someone may not view exactly as an id no page has: not found, with nothing of the page" $ withAdminSession backing identity $ \r session -> do
    handbook <- pageIdAt r [session] "team" "on-call"
    -- The administrator is sent there.
    (header "Location" <$> getUrlWith r (r.public <> "/l/" <> handbook.text <> "/") [session]) `shouldReturn` Just "/s/team/p/on-call/"
    -- Nobody else learns that it is there. The ids are the same length, so
    -- that the pages can be compared byte for byte, the id aside.
    let missing = T.map (const 'x') handbook.text
    (hiddenStatus, hidden) <- page r r.public ("/l/" <> handbook.text <> "/")
    (missingStatus, nothing) <- page r r.public ("/l/" <> missing <> "/")
    (hiddenStatus, missingStatus) `shouldBe` (404, 404)
    appIn hidden `shouldSatisfy` T.isInfixOf "error-not-found"
    hidden `shouldNotSatisfy` T.isInfixOf "On-call"
    T.replace handbook.text "ID" hidden `shouldBe` T.replace missing "ID" nothing
    -- And the API's answer is the same, status, headers and body.
    hiddenAnswer <- getUrl r (r.public <> "/" <> links.pages.location handbook)
    missingAnswer <- getUrl r (r.public <> "/" <> links.pages.location (PageId missing))
    let shown reply = (reply.status, header "Content-Type" reply, header "Cache-Control" reply, reply.body)
    shown hiddenAnswer `shouldBe` shown missingAnswer
    hiddenAnswer.status `shouldBe` 404

  it "carries the refusal for the program, which shows the same page" $ withDemoRunning backing identity $ \r -> do
    (_, html) <- page r r.public "/l/no-such-page/"
    p <- preloadIn html
    p.pageLocations `shouldBe` Map.fromList [(PageId "no-such-page", Left NotFound)]
  where
    -- The id of the page at a path of a space, as the API reads it for
    -- whoever the headers say.
    pageIdAt r hs space path = do
      found <- ok200 (getUrlWith r (r.public <> "/" <> links.spaces.atPath (slugs space)) hs) :: IO S.Space
      p <- ok200 (getUrlWith r (r.public <> "/" <> links.spaces.pageAt found.id (if T.null path then [] else slugs path)) hs) :: IO P.Page
      pure p.id

-- | Pages of the demo's Docs, which anyone reads, with ids a path segment
-- cannot hold as they are: a slash, a percent sign, a question mark, a
-- hash, a space, a backslash, two dots, a control character, text
-- outside ASCII, and a long one. (Not a NUL: PostgreSQL's text holds none.)
visibleIds :: [(Text, Text)]
visibleIds = [("Diagrams", "a/b"), ("Mathematics", "x y%?#\\é"), ("Presentations", ".."), ("Markdown guide", "t\1u"), ("Tour", T.replicate 300 "l")]

-- | Pages of the private Team, with ids of the same kinds.
hiddenIds :: [(Text, Text)]
hiddenIds = [("On-call", "c/d"), ("Team handbook", "..\\%é? #\1")]

-- | The demo's wiki with those pages' ids changed, everywhere the archive
-- names them.
awkwardDemo :: Archive
awkwardDemo = either (panic . ("the demo with other ids: " <>)) identity (readArchive (Map.fromList [(path, if ".json" `T.isSuffixOf` path then renamed bytes else bytes) | (path, bytes) <- writeArchive demoArchive]))
  where
    renamed bytes = encodeUtf8 (foldl' (\t (old, new) -> T.replace (quoted old) (quoted new) t) (decodeUtf8 bytes) changes)
    changes = [(idOf title, PageId new) | (title, new) <- visibleIds <> hiddenIds]
    idOf title = maybe (panic ("no page " <> title)) (\p -> p.id) (find (\p -> p.title == title) demoArchive.pages)
    quoted (PageId t) = decodeUtf8 (BSL.toStrict (encode t))

-- | A page's id as one segment of an API address, percent-encoded.
pathSegment :: Text -> Text
pathSegment = T.concatMap (\c -> if isAscii c && isAlphaNum c then T.singleton c else T.concat [toS ('%' : hex b) | b <- BS.unpack (encodeUtf8 (T.singleton c))])
  where
    hex b = let h = showHex b "" in if length h == 1 then '0' : h else h

failures :: Backing -> Spec
failures backing = describe "when a render fails" $ do
  it "sends the build's own page, and says why in the log" $ withDemoRunning backing identity $ \r -> do
    -- The storage failing under the API: every read of a space fails.
    withConnectionTo r.place $ \c -> do
      begin True c
      runScript c "ALTER TABLE spaces RENAME TO spaces_gone"
      commitTransaction c
    (frontStatus, front) <- page r r.public "/"
    (frontStatus, front) `shouldSatisfy` (\(s, b) -> s == 200 && "<title>front</title>" `T.isInfixOf` b)
    (spaceStatus, space) <- page r r.public "/s/docs/"
    (spaceStatus, space) `shouldSatisfy` (\(s, b) -> s == 404 && "<title>missing</title>" `T.isInfixOf` b)
    logged <- readIORef r.logged
    filter (\l -> "level=error event=render" `T.isPrefixOf` l) logged `shouldSatisfy` ((>= 2) . length)

  it "sends the build's own page for a template it cannot fill" $ withDemoRunning backing identity $ \r -> do
    writeFile (r.staticDir </> "template.html") "<html><body>no mount point</body></html>"
    (status, html) <- page r r.public "/s/docs/"
    (status, html) `shouldSatisfy` (\(s, b) -> s == 404 && "<title>missing</title>" `T.isInfixOf` b)

-- | An encrypted space's page (WP5.74b2 of docs/PLAN.md), which the server
-- cannot decrypt: rendered as the program renders it before it has
-- decrypted anything, with none of the page's ciphertext, in the page or
-- in the data it carries.
encrypted :: Backing -> Spec
encrypted backing = describe "an encrypted space" $ do
  it "renders an encrypted space's page with no title, text or ciphertext of it" $ withAdminSession backing identity $ \r session -> do
    let as' method path body = send r method (r.public <> "/" <> path) [session, (hContentType, "application/json")] body
        bytesOf n c = toBase64Url (BS.replicate n c)
        public = PublicKey (bytesOf 32 65)
        keyId = fromMaybe (KeyId "") (keyIdOf public)
        vault = Vault {format = vaultFormat, salt = Salt (bytesOf 32 1), items = Map.singleton identityItem Item {keyId = Just keyId, sealed = Sealed (Nonce (bytesOf 12 2)) (Ciphertext (bytesOf 64 3))}, wraps = Map.singleton ByPassword (WrappedKey (Nonce (bytesOf 12 4)) (Ciphertext (bytesOf 48 5)))}
    (.status) <$> as' methodPut "api/v1/assistant/vault" (encode VaultChange {vault, publicKey = Just NewPublicKey {keyId, publicKey = public}}) `shouldReturn` 200
    made :: S.Space <- as' methodPost "api/v1/spaces" (encode Api.NewSpace {parent = Nothing, name = "Vault room"}) >>= jsonAs 201
    let spaceKey = KeyId (bytesOf 16 6)
    (.status) <$> as' methodPost ("api/v1/encrypted/spaces/" <> made.id.text) (encode EncryptSpace {keyId = spaceKey, grant = NewGrant {recipient = UserId "user-admin", recipientKeyId = keyId, enc = Encapsulated (bytesOf 32 7), sealed = Ciphertext (bytesOf 48 8)}}) `shouldReturn` 200
    let title = Ciphertext (bytesOf 40 9)
        body = Ciphertext (bytesOf 300 10)
        content = SealedContent {tag = VersionTag (bytesOf 16 11), keyId = KeyId (bytesOf 16 12), title = Sealed (Nonce (bytesOf 12 13)) title, body = Sealed (Nonce (bytesOf 12 14)) body}
        pageKey = PageKey {keyId = KeyId (bytesOf 16 12), spaceKeyId = spaceKey, wrapped = WrappedKey (Nonce (bytesOf 12 15)) (Ciphertext (bytesOf 48 16))}
    sealedPage :: SealedPage <- as' methodPost ("api/v1/encrypted/spaces/" <> made.id.text <> "/pages") (encode NewSealedPage {id = PageId "3b0f5c1e-2d4a-4e6b-8c9d-0a1b2c3d4e5f", parent = Nothing, pageKey, content}) >>= jsonAs 201
    (_, html) <- pageAs r [session] r.public ("/s/" <> slugText made.slug <> "/p/" <> slugText sealedPage.slug <> "/")
    filter (`T.isInfixOf` html) [title.text, body.text, pageKey.wrapped.key.text] `shouldBe` []
    appIn html `shouldSatisfy` T.isInfixOf "decrypted in your browser"
    -- Its permanent address leads to it as any page's does: its path is
    -- made of the random slugs the server gave it.
    (header "Location" <$> getUrlWith r (r.public <> "/l/" <> sealedPage.id.text <> "/") [session])
      `shouldReturn` Just (encodeUtf8 ("/s/" <> slugText made.slug <> "/p/" <> slugText sealedPage.slug <> "/"))
