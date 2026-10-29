-- | A public blog's feeds and the sitemap ("Wiki.Server.Feed"): written
-- natively and checked against the Atom and RSS 2.0 schemas
-- (@test\/schemas\/@, with @xmllint@ where the machine has it, and the
-- rules the schemas cannot say checked here), a post's HTML through the
-- allowlist with its addresses absolute; then served over HTTP, to the
-- public and refused for what is not; and what the pages the server
-- renders say of themselves in their heads.
module Test.Server.Feed (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import System.Directory (findExecutable)
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Database (Backing)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Fixture
import Text.XML qualified as X
import Wiki.Api (AdminApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.Links (links)
import Wiki.Api.ServerSettings (ServerSettingsOf (..), noServerSettings)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..), SpaceProfile (..), profileOf)
import Wiki.Core.Url (Url (..))
import Wiki.Server.Feed

spec :: Backing -> Spec
spec backing = describe "feeds and the sitemap" $ do
  writing
  html
  served backing
  heads backing

--------------------------------------------------------------------------------
-- Written

time :: Int -> UTCTime
time day = UTCTime (fromGregorian 2026 9 day) 43200

feedHead :: FeedHead
feedHead = FeedHead {title = "Blog & more", description = "Posts <about> the wiki.", address = "https://wiki.example/s/blog/", updated = time 19}

entries :: [FeedEntry]
entries =
  [ FeedEntry
      { title = "Notes on \"Haskell\""
      , url = "https://wiki.example/s/blog/p/notes/"
      , published = time 19
      , updated = time 20
      , author = Just "Edgar & Ada"
      , summary = "Laziness, and <tags>."
      , html = "<div><p>A <b>bold</b> claim &amp; a control\x0001 character.</p></div>"
      }
  , FeedEntry
      { title = "Hello, world"
      , url = "https://wiki.example/s/blog/p/hello/"
      , published = time 1
      , updated = time 1
      , author = Nothing
      , summary = ""
      , html = "<div><p>Hi.</p></div>"
      }
  ]

-- | A document's elements by their local names, everywhere in it.
named :: Text -> X.Element -> [X.Element]
named n e = [e | X.nameLocalName (X.elementName e) == n] <> concat [named n c | X.NodeElement c <- X.elementNodes e]

-- | An element's children of a name, in its own namespace.
children :: Text -> X.Element -> [X.Element]
children n e = [c | X.NodeElement c <- X.elementNodes e, X.elementName c == (X.elementName e) {X.nameLocalName = n}]

textOf :: X.Element -> Text
textOf e = mconcat [t | X.NodeContent t <- X.elementNodes e]

attributeOf :: Text -> X.Element -> Maybe Text
attributeOf n e = Map.lookup (X.Name n Nothing Nothing) (X.elementAttributes e)

-- | The document a feed is, read as XML, or a failed test.
parsed :: (HasCallStack) => Text -> IO X.Element
parsed xml = either (\e -> assertFailure ("not XML: " <> show e)) (pure . X.documentRoot) (X.parseText X.def (toS xml))

-- | Whether xmllint finds a document valid against a schema, or 'Nothing'
-- where the machine has no xmllint.
validates :: FilePath -> Text -> IO (Maybe (Either Text ()))
validates schema xml =
  findExecutable "xmllint" >>= \case
    Nothing -> pure Nothing
    Just xmllint -> withSystemTempDirectory "feed" $ \dir -> do
      let file = dir <> "/feed.xml"
      BS.writeFile file (encodeUtf8 xml)
      (code, _, err) <- readProcessWithExitCode xmllint ["--noout", "--relaxng", schema, file] ""
      pure (Just (if code == ExitSuccess then Right () else Left (toS err)))

-- | Valid against the schema, where xmllint can say; pending where not.
shouldValidate :: (HasCallStack) => Text -> FilePath -> IO ()
shouldValidate xml schema =
  validates schema xml >>= \case
    Nothing -> pendingWith "xmllint is not installed (apt install libxml2-utils): the schema is not checked here"
    Just result -> result `shouldBe` Right ()

writing :: Spec
writing = describe "written" $ do
  it "is an Atom feed valid against RFC 4287's schema, every entry with an author" $ do
    let atom = atomFeed feedHead entries
    root <- parsed atom
    X.elementName root `shouldBe` X.Name "feed" (Just "http://www.w3.org/2005/Atom") Nothing
    map textOf (children "id" root) `shouldBe` ["https://wiki.example/s/blog/"]
    map textOf (children "title" root) `shouldBe` ["Blog & more"]
    map textOf (children "updated" root) `shouldBe` ["2026-09-19T12:00:00Z"]
    -- The feed's author stands for an entry's that is not known (RFC 4287,
    -- 4.1.1).
    map textOf (concatMap (children "name") (children "author" root)) `shouldBe` ["Blog & more"]
    [(attributeOf "rel" l, attributeOf "href" l) | l <- children "link" root]
      `shouldBe` [(Just "alternate", Just "https://wiki.example/s/blog/"), (Just "self", Just "https://wiki.example/s/blog/feed.xml")]
    let es = children "entry" root
    length es `shouldBe` 2
    map (map textOf . children "title") es `shouldBe` [["Notes on \"Haskell\""], ["Hello, world"]]
    map (map textOf . children "published") es `shouldBe` [["2026-09-19T12:00:00Z"], ["2026-09-01T12:00:00Z"]]
    map (map textOf . concatMap (children "name") . children "author") es `shouldBe` [["Edgar & Ada"], []]
    -- The HTML as text, which a reader parses, without what XML cannot hold.
    [(attributeOf "type" c, textOf c) | e <- take 1 es, c <- children "content" e]
      `shouldBe` [(Just "html", "<div><p>A <b>bold</b> claim &amp; a control character.</p></div>")]
    atom `shouldValidate` "test/schemas/atom.rng"

  it "is an RSS 2.0 feed valid against the specification's elements, its dates RFC 822's" $ do
    let rss = rssFeed feedHead entries
    root <- parsed rss
    X.elementName root `shouldBe` "rss"
    attributeOf "version" root `shouldBe` Just "2.0"
    channel <- maybe (assertFailure "no channel") pure (head (children "channel" root))
    map (\n -> map textOf (children n channel)) ["title", "link", "description", "lastBuildDate"]
      `shouldBe` [["Blog & more"], ["https://wiki.example/s/blog/"], ["Posts <about> the wiki."], ["Sat, 19 Sep 2026 12:00:00 +0000"]]
    let items = children "item" channel
    map (map textOf . children "guid") items `shouldBe` [["https://wiki.example/s/blog/p/notes/"], ["https://wiki.example/s/blog/p/hello/"]]
    map (map textOf . children "pubDate") items `shouldBe` [["Sat, 19 Sep 2026 12:00:00 +0000"], ["Tue, 01 Sep 2026 12:00:00 +0000"]]
    map (map textOf . named "creator") items `shouldBe` [["Edgar & Ada"], []]
    -- Every item has a title or a description; these have both.
    map (\i -> (length (children "title" i), length (children "description" i))) items `shouldBe` [(1, 1), (1, 1)]
    rss `shouldValidate` "test/schemas/rss.rng"

  it "is checked by schemas that refuse what is not a feed" $ do
    let atom = atomFeed feedHead entries
        rss = rssFeed feedHead entries
        broken xml was now = validates (if "<rss" `T.isInfixOf` xml then "test/schemas/rss.rng" else "test/schemas/atom.rng") (T.replace was now xml)
    for_
      [ broken atom "<id>https://wiki.example/s/blog/</id>" ""
      , broken atom "<updated>2026-09-19T12:00:00Z</updated>" "<updated>19 September</updated>"
      , broken rss "<link>https://wiki.example/s/blog/</link>" ""
      , broken rss "Sat, 19 Sep 2026 12:00:00 +0000" "2026-09-19"
      ]
      $ \checked ->
        checked >>= \case
          Nothing -> pendingWith "xmllint is not installed (apt install libxml2-utils)"
          Just result -> result `shouldSatisfy` isLeft

  it "is a sitemap of addresses and when they changed" $ do
    let xml = sitemapXml [SitemapUrl {loc = "https://wiki.example/s/blog/?a&b", lastmod = time 2}]
    root <- parsed xml
    X.elementName root `shouldBe` X.Name "urlset" (Just "http://www.sitemaps.org/schemas/sitemap/0.9") Nothing
    map textOf (named "loc" root) `shouldBe` ["https://wiki.example/s/blog/?a&b"]
    map textOf (named "lastmod" root) `shouldBe` ["2026-09-02T12:00:00Z"]

--------------------------------------------------------------------------------
-- A post's HTML

slugOf :: Text -> Slug
slugOf = either (panic . show) identity . mkSlug

html :: Spec
html = describe "a post's HTML" $
  it "is the wiki's render, through the allowlist, its links and attachments under the public address" $ do
    let blog =
          Space
            { id = SpaceId "s1"
            , name = "Blog"
            , slug = slugOf "blog"
            , parent = Nothing
            , public = True
            , mathMacros = ""
            , createdAt = time 1
            , position = 0
            , subspaceOrder = ByName
            , pageOrder = ByName
            , homePage = Nothing
            , icon = Nothing
            , description = ""
            , blog = True
            }
        pageOf i t body attachments = Page {id = PageId i, space = blog.id, parent = Nothing, title = t, slug = slugOf i, body, attachments, createdAt = time 1, updatedAt = time 1, position = 0, template = False}
        tree = Attachment {id = AttachmentId "a1", name = FileName "tree.png", mediaType = MimeType "image/png", size = 3, source = SourceBlob (BlobId "b1")}
        post =
          pageOf
            "post"
            "Post"
            ( T.unlines
                [ "Hello <script>alert(1)</script><b onclick=\"steal()\">there</b>."
                , ""
                , "![A tree](attachment:tree.png) and [the other post](other#top) and [away](https://example.org/)."
                , ""
                , "```haskell"
                , "main = pure ()"
                , "```"
                ]
            )
            [tree]
        other = pageOf "other" "Other" "" []
    out <- postHtml "https://wiki.example/" [] [blog] blog [post, other] post
    out `shouldNotSatisfy` T.isInfixOf "<script"
    out `shouldNotSatisfy` T.isInfixOf "alert"
    out `shouldNotSatisfy` T.isInfixOf "onclick"
    out `shouldSatisfy` T.isInfixOf "<b>there</b>"
    out `shouldSatisfy` T.isInfixOf "src=\"https://wiki.example/api/v1/attachments/a1/tree.png\""
    out `shouldSatisfy` T.isInfixOf "href=\"https://wiki.example/s/blog/p/other/#top\""
    out `shouldSatisfy` T.isInfixOf "href=\"https://example.org/\""
    out `shouldSatisfy` T.isInfixOf "<code class=\"language-haskell\">main = pure ()"

--------------------------------------------------------------------------------
-- Served

served :: Backing -> Spec
served backing = describe "served" $ do
  it "serves a public blog's Atom and RSS feeds, with its posts whole and its addresses the request's" $ withDemoRunning backing identity $ \r -> do
    atom <- getUrl r (r.public <> "/s/blog/feed.xml")
    atom.status `shouldBe` 200
    header "Content-Type" atom `shouldBe` Just "application/atom+xml; charset=utf-8"
    -- Anyone may read it, and keep it for the minute the server does.
    header "Cache-Control" atom `shouldBe` Just "public, max-age=60"
    let atomText = decodeUtf8 (BSL.toStrict atom.body)
    root <- parsed atomText
    map (map textOf . children "title") (children "entry" root) `shouldBe` [["Notes on Haskell"], ["Hello, world"]]
    map (map textOf . children "id") (children "entry" root) `shouldBe` [[r.public <> "/s/blog/p/notes-on-haskell/"], [r.public <> "/s/blog/p/hello-world/"]]
    -- The post whole, its HTML as the wiki renders it.
    [textOf c | e <- children "entry" root, c <- children "content" e] `shouldSatisfy` any (T.isInfixOf "<h2 id=\"why-a-wiki\">Why a wiki</h2>")
    atomText `shouldValidate` "test/schemas/atom.rng"
    rss <- getUrl r (r.public <> "/s/blog/feed.rss")
    rss.status `shouldBe` 200
    header "Content-Type" rss `shouldBe` Just "application/rss+xml; charset=utf-8"
    decodeUtf8 (BSL.toStrict rss.body) `shouldValidate` "test/schemas/rss.rng"

  it "gives its addresses under the public address the panel sets" $ withDemoRunning backing identity $ \r -> do
    _ <- setServer r noServerSettings {publicUrl = Just (Url "https://wiki.example.org/")}
    atom <- getUrl r (r.public <> "/s/blog/feed.xml")
    root <- parsed (decodeUtf8 (BSL.toStrict atom.body))
    map textOf (children "id" root) `shouldBe` ["https://wiki.example.org/s/blog/"]
    mapped <- getUrl r (r.public <> "/sitemap.xml")
    decodeUtf8 (BSL.toStrict mapped.body) `shouldSatisfy` T.isInfixOf "<loc>https://wiki.example.org/s/blog/p/hello-world/</loc>"

  it "has no feed for a space that is not a blog, not public or not there, whoever asks" $ withDemoRunning backing identity $ \r -> do
    for_ ["/s/docs/feed.xml", "/s/docs/feed.rss", "/s/team/feed.xml", "/s/nowhere/feed.xml", "/s/blog/p/hello-world/feed.xml"] $ \path ->
      ((.status) <$> getUrl r (r.public <> path)) `shouldReturn` 404
    -- Shown as a blog, a private space still has none, even for the
    -- administrator.
    team <- getUrl r (r.admin <> "/admin/" <> links.spaces.atPath [slugOf "team"]) >>= jsonAs 200
    _ :: Space <- ok200 (sendJson r "PUT" (r.admin <> "/admin/" <> links.spaces.setProfile team.id) (asBlog (profileOf team)))
    ((.status) <$> getUrl r (r.admin <> "/admin/s/team/feed.xml")) `shouldReturn` 404
    ((.status) <$> getUrl r (r.public <> "/s/team/feed.xml")) `shouldReturn` 404

  it "lists the public spaces and pages in the sitemap, with when each changed" $ withDemoRunning backing identity $ \r -> do
    reply <- getUrl r (r.public <> "/sitemap.xml")
    reply.status `shouldBe` 200
    header "Content-Type" reply `shouldBe` Just "application/xml; charset=utf-8"
    header "Cache-Control" reply `shouldBe` Just "public, max-age=60"
    root <- parsed (decodeUtf8 (BSL.toStrict reply.body))
    let locs = map textOf (named "loc" root)
    locs `shouldSatisfy` elem (r.public <> "/s/blog/")
    locs `shouldSatisfy` elem (r.public <> "/s/blog/p/hello-world/")
    locs `shouldSatisfy` elem (r.public <> "/s/docs/p/markdown-guide/diagrams/")
    locs `shouldSatisfy` all (not . T.isInfixOf "/s/team")
    length (named "lastmod" root) `shouldBe` length locs

  it "has neither in a closed wiki" $ withDemoRunning backing identity $ \r -> do
    answered :: WikiSettings <- sendJson r "PUT" (r.admin <> "/admin/" <> links.admin.setSettings) WikiSettings {access = Closed, newAccountsCreateSpaces = False, adminCreatesPasswordAccounts = True} >>= jsonAs 200
    answered.access `shouldBe` Closed
    for_ ["/s/blog/feed.xml", "/s/blog/feed.rss", "/sitemap.xml"] $ \path ->
      ((.status) <$> getUrl r (r.public <> path)) `shouldReturn` 404

asBlog :: SpaceProfile -> SpaceProfile
asBlog p = SpaceProfile {description = p.description, icon = p.icon, homePage = p.homePage, blog = True}

--------------------------------------------------------------------------------
-- Heads

heads :: Backing -> Spec
heads backing = describe "the head of a page the server renders" $ do
  it "describes a public post to a link preview, and announces its blog's feeds" $ withDemoRunning backing identity $ \r -> do
    reply <- getUrl r (r.public <> "/s/blog/p/hello-world/")
    let page = decodeUtf8 (BSL.toStrict reply.body)
        head' = fst (T.breakOn "</head>" page)
    head' `shouldSatisfy` T.isInfixOf "<title>Hello, world · Blog · Wiki</title>"
    head' `shouldSatisfy` T.isInfixOf "<meta name=\"description\" content=\"This is the first post of a blog that is also a wiki."
    head' `shouldSatisfy` T.isInfixOf "<meta property=\"og:title\" content=\"Hello, world\">"
    head' `shouldSatisfy` T.isInfixOf "<meta property=\"og:type\" content=\"article\">"
    head' `shouldSatisfy` T.isInfixOf ("<meta property=\"og:url\" content=\"" <> r.public <> "/s/blog/p/hello-world/\">")
    head' `shouldSatisfy` T.isInfixOf "<meta property=\"og:image\" content=\"https://upload.wikimedia.org/"
    head' `shouldSatisfy` T.isInfixOf "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"Blog (Atom)\" href=\"/s/blog/feed.xml\">"
    head' `shouldSatisfy` T.isInfixOf "<link rel=\"alternate\" type=\"application/rss+xml\" title=\"Blog (RSS)\" href=\"/s/blog/feed.rss\">"

  it "describes the blog's own page, a page of its posts, and a public space without its feeds" $ withDemoRunning backing identity $ \r -> do
    blogPage <- decodeUtf8 . BSL.toStrict . (.body) <$> getUrl r (r.public <> "/s/blog/?page=2")
    blogPage `shouldSatisfy` T.isInfixOf "<meta property=\"og:type\" content=\"website\">"
    blogPage `shouldSatisfy` T.isInfixOf "<meta property=\"og:description\" content=\"Posts about this wiki and about writing it in Haskell.\">"
    blogPage `shouldSatisfy` T.isInfixOf "href=\"/s/blog/feed.xml\""
    docs <- decodeUtf8 . BSL.toStrict . (.body) <$> getUrl r (r.public <> "/s/docs/p/tour/")
    docs `shouldSatisfy` T.isInfixOf "<meta property=\"og:title\" content=\"Tour\">"
    docs `shouldNotSatisfy` T.isInfixOf "feed.xml"

  it "says nothing of a private page, even to its administrator" $ withDemoRunning backing identity $ \r -> do
    handbook <- decodeUtf8 . BSL.toStrict . (.body) <$> getUrl r (r.admin <> "/admin/s/team/p/team-handbook/")
    handbook `shouldSatisfy` T.isInfixOf "<title>Team handbook · Team · Wiki</title>"
    handbook `shouldNotSatisfy` T.isInfixOf "og:"
    handbook `shouldNotSatisfy` T.isInfixOf "name=\"description\""
