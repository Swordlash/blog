-- | The built application's files as both listeners serve them: as the
-- demo's static server did (pages, 404.html, precompressed siblings, media
-- types, revalidation, nothing outside the directory), each page with its
-- listener's @\<base href>@.
module Test.Server.Static (spec) where

import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Network.HTTP.Types (methodHead, methodPost)
import Protolude
import System.Directory (createFileLink)
import System.FilePath ((</>))
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Static (withBaseHref)

spec :: Spec
spec = describe "the application's files" $ do
  publicListener
  adminListener
  basePath
  baseHref

bodyText :: Reply -> Text
bodyText reply = decodeUtf8 (BSL.toStrict reply.body)

publicListener :: Spec
publicListener = describe "on the public listener" $ do
  it "serves a directory's index.html as a page, revalidated by its ETag" $ withRunning $ \r -> do
    reply <- getUrl r (r.public <> "/")
    (reply.status, header "Content-Type" reply) `shouldBe` (200, Just "text/html; charset=utf-8")
    bodyText reply `shouldSatisfy` T.isInfixOf "<title>front</title>"
    (header "Cache-Control" reply, header "X-Content-Type-Options" reply, header "Vary" reply) `shouldBe` (Just "no-cache", Just "nosniff", Just "Accept-Encoding")
    again <- getUrlWith r (r.public <> "/") [("If-None-Match", fromMaybe "" (header "ETag" reply))]
    (again.status, again.body) `shouldBe` (304, "")

  it "redirects a directory's address without its slash, and serves a prerendered route" $ withRunning $ \r -> do
    redirect <- getUrl r (r.public <> "/s/blog?x=1")
    (redirect.status, header "Location" redirect) `shouldBe` (301, Just "/s/blog/?x=1")
    page <- getUrl r (r.public <> "/s/blog/")
    (page.status, bodyText page) `shouldSatisfy` (\(s, b) -> s == 200 && "<title>blog</title>" `T.isInfixOf` b)

  it "serves 404.html with a 404 for an address with no file, as the application's own route" $ withRunning $ \r -> do
    reply <- getUrl r (r.public <> "/s/made-since/p/a-page/")
    (reply.status, header "Content-Type" reply) `shouldBe` (404, Just "text/html; charset=utf-8")
    bodyText reply `shouldSatisfy` T.isInfixOf "<title>missing</title>"

  it "serves app.wasm with its type, brotli'd to a client that takes it" $ withRunning $ \r -> do
    compressed <- getUrlWith r (r.public <> "/app.wasm") [("Accept-Encoding", "gzip, br")]
    (compressed.status, header "Content-Type" compressed, header "Content-Encoding" compressed, compressed.body)
      `shouldBe` (200, Just "application/wasm", Just "br", "brotli bytes")
    raw <- getUrlWith r (r.public <> "/app.wasm") [("Accept-Encoding", "identity")]
    (header "Content-Encoding" raw, raw.body) `shouldBe` (Nothing, "\0asm\1\0\0\0")
    gzipped <- getUrlWith r (r.public <> "/index.js") [("Accept-Encoding", "br;q=0, gzip")]
    (header "Content-Type" gzipped, header "Content-Encoding" gzipped, gzipped.body) `shouldBe` (Just "text/javascript; charset=utf-8", Just "gzip", "gzip bytes")

  it "sends a file that is compressed itself as its own bytes, never its sibling" $ withRunning $ \r -> do
    reply <- getUrlWith r (r.public <> "/tikzjax/core.dump.gz") [("Accept-Encoding", "gzip, br")]
    (header "Content-Type" reply, header "Content-Encoding" reply, reply.body) `shouldBe` (Just "application/gzip", Nothing, "a dump, compressed")

  it "answers HEAD without a body, and refuses other methods" $ withRunning $ \r -> do
    headed <- send r methodHead (r.public <> "/style.css") [] ""
    (headed.status, headed.body, header "Content-Type" headed) `shouldBe` (200, "", Just "text/css; charset=utf-8")
    (.status) <$> send r methodPost (r.public <> "/style.css") [] "" `shouldReturn` 405
    -- The API's check on writes is the API's: a file refuses the method.
    (.status) <$> sendBare r methodPost (r.public <> "/") [] "" `shouldReturn` 405

  it "serves nothing outside its directory, by .. or by a link" $ withRunning $ \r -> do
    (.status) <$> getUrl r (r.public <> "/%2e%2e/data/wiki.sqlite") `shouldReturn` 403
    (.status) <$> getUrl r (r.public <> "/s/%2e%2e/%2e%2e/index.html") `shouldReturn` 403
    (.status) <$> getRawPath r r.public "/%zz" `shouldReturn` 400
    createFileLink (r.dataDir </> "wiki.sqlite") (r.staticDir </> "leak.sqlite")
    leaked <- getUrl r (r.public <> "/leak.sqlite")
    leaked.status `shouldBe` 404
    bodyText leaked `shouldSatisfy` T.isInfixOf "<title>missing</title>"

  it "serves the service worker, the manifest and the offline page as files, at the worker's scope" $ withRunning $ \r -> do
    worker <- getUrl r (r.public <> "/sw.js")
    (worker.status, header "Content-Type" worker, header "Cache-Control" worker) `shouldBe` (200, Just "text/javascript; charset=utf-8", Just "no-cache")
    -- At the place the site is served at, which is the scope it asks for:
    -- nothing has to allow it a wider one.
    header "Service-Worker-Allowed" worker `shouldBe` Nothing
    manifest <- getUrl r (r.public <> "/manifest.webmanifest")
    (manifest.status, header "Content-Type" manifest) `shouldBe` (200, Just "application/manifest+json")
    offline <- getUrl r (r.public <> "/offline.html")
    (offline.status, bodyText offline) `shouldSatisfy` (\(s, b) -> s == 200 && "<base href=\"/\"><title>offline</title>" `T.isInfixOf` b)

  it "is the API's below api/v1, even where a file would be" $ withRunning $ \r -> do
    ok200 (getUrl r (r.public <> "/api/v1/info")) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}

adminListener :: Spec
adminListener = describe "on the admin listener" $ do
  it "serves the same application under /admin/, with that base" $ withRunning $ \r -> do
    page <- getUrl r (r.admin <> "/admin/")
    page.status `shouldBe` 200
    bodyText page `shouldSatisfy` T.isInfixOf "<base href=\"/admin/\"><title>front</title>"
    route <- getUrl r (r.admin <> "/admin/s/blog/")
    bodyText route `shouldSatisfy` T.isInfixOf "<base href=\"/admin/\"><title>blog</title>"
    missing <- getUrl r (r.admin <> "/admin/s/nowhere/")
    (missing.status, bodyText missing) `shouldSatisfy` (\(s, b) -> s == 404 && "<base href=\"/admin/\"><title>missing</title>" `T.isInfixOf` b)
    wasm <- getUrlWith r (r.admin <> "/admin/app.wasm") [("Accept-Encoding", "br")]
    (wasm.status, header "Content-Encoding" wasm) `shouldBe` (200, Just "br")
    -- The service worker too, whose scope is then /admin/.
    (.status) <$> getUrl r (r.admin <> "/admin/sw.js") `shouldReturn` 200

  it "redirects its root and its place without the slash there, and nothing else" $ withRunning $ \r -> do
    for_ [("/", "/admin/"), ("/admin", "/admin/")] $ \(asked, target) -> do
      redirect <- getUrl r (r.admin <> asked)
      (redirect.status, header "Location" redirect) `shouldBe` (302, Just target)
    -- Its pages' links are written below /admin/ (Test.Server.Render), so
    -- an address below the public base path is none of its own.
    for_ ["/s/blog/", "/app.wasm?v=2"] $ \asked ->
      (.status) <$> getUrl r (r.admin <> asked) `shouldReturn` 404
    (.status) <$> send r methodPost (r.admin <> "/s/blog/") [] "" `shouldReturn` 404

basePath :: Spec
basePath = describe "under a base path" $ do
  it "serves the application and the API below it, and redirects the root to it" $
    withRunningAs (\o -> o {basePath = "/wiki"}) $ \r -> do
      page <- getUrl r (r.public <> "/wiki/")
      bodyText page `shouldSatisfy` T.isInfixOf "<base href=\"/wiki/\"><title>front</title>"
      ok200 (getUrl r (r.public <> "/wiki/api/v1/info")) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}
      (.status) <$> getUrl r (r.public <> "/wiki/sw.js") `shouldReturn` 200
      for_ [("/", "/wiki/"), ("/wiki", "/wiki/")] $ \(asked, target) -> do
        redirect <- getUrl r (r.public <> asked)
        (redirect.status, header "Location" redirect) `shouldBe` (302, Just target)
      (.status) <$> getUrl r (r.public <> "/api/v1/info") `shouldReturn` 404
      (.status) <$> getUrl r (r.admin <> "/wiki/s/blog/") `shouldReturn` 404

baseHref :: Spec
baseHref = describe "a page's <base href>" $ do
  it "is replaced when it is another, and left alone when it is the same" $ do
    withBaseHref "/admin/" "<head><base href=\"/\"><title>x</title>" `shouldBe` "<head><base href=\"/admin/\"><title>x</title>"
    withBaseHref "/" "<head><base href=\"/\">" `shouldBe` "<head><base href=\"/\">"

  it "is added first in the head of a page without one" $
    withBaseHref "/a&b/" "<html><head><title>x</title></head>" `shouldBe` "<html><head>\n    <base href=\"/a&amp;b/\"><title>x</title></head>"
