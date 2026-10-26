-- | A space shown as a blog, as it is rendered natively for a route
-- ("Wiki.App.Static"), which is the HTML its prerendered and served pages
-- arrive with: its posts and their pages of ten ("Wiki.App.View.Blog"), a
-- post's date and its neighbours ("Wiki.App.View.Page"), and what a page
-- says about itself in its head ("Wiki.App.Head").
module Test.Blog (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (addUTCTime)
import Protolude
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..), Saved (..), insertPage)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Head (Feeds (..), Head (..), Preview (..), PreviewImage (..), Site (..), headTags)
import Wiki.App.Route (Route (..))
import Wiki.App.Static (Rendered (..), renderRoute)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space qualified as S

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)

blogPath :: [Slug]
blogPath = slugs ["blog"]

-- | The demo as someone sees it: nobody, or one of its users.
as :: Maybe Text -> MemState
as who = (demoState demoNow) {current = UserId <$> who}

render :: MemState -> Route -> IO Rendered
render st = renderRoute st "/"

contains :: Text -> Text -> Expectation
contains html part = (part, part `T.isInfixOf` html) `shouldBe` (part, True)

lacks :: Text -> Text -> Expectation
lacks html part = (part, part `T.isInfixOf` html) `shouldBe` (part, False)

-- | Whether one piece of the page comes before another.
comesBefore :: Text -> Text -> Text -> Expectation
comesBefore html a b = (a, b, T.length (fst (T.breakOn a html)) < T.length (fst (T.breakOn b html))) `shouldBe` (a, b, True)

-- | The demo's blog.
blogOf :: MemState -> S.Space
blogOf st = fromMaybe (panic "the demo has no blog") (find (\s -> s.name == "Blog") (Map.elems st.spaces))

-- | The demo with twelve more posts in its blog, an hour apart after the
-- demo's time, the twelfth the newest.
withTwelve :: MemState -> MemState
withTwelve st = foldl' add st [1 .. 12 :: Int]
  where
    add s n = fst (insertPage (blogOf st).id Nothing ("Post " <> show n) ("The text of post " <> show n <> ".") (addUTCTime (fromIntegral n * 3600) demoNow) s)

-- | The demo's blog with a home page: its second post.
withHome :: MemState -> MemState
withHome st = st {spaces = Map.adjust (\s -> S.withProfile S.SpaceProfile {S.description = s.description, S.icon = s.icon, S.homePage = (\p -> p.id) <$> notes, S.blog = s.blog} s) (blogOf st).id st.spaces}
  where
    notes = find (\p -> p.title == "Notes on Haskell") (Map.elems st.pages) :: Maybe P.Page

spec :: Spec
spec = describe "a space shown as a blog, rendered" $ do
  it "opens at its posts, the newest first, each with its date, its comments and its first paragraph" $ do
    Rendered {html, title} <- render (as Nothing) (Space blogPath)
    title `shouldBe` "Blog · Wiki"
    html `contains` "<section class=\"blog-view\">"
    html `contains` "<h1>Blog</h1>"
    html `contains` "<ol class=\"space-cards post-list\">"
    html `contains` "<a class=\"space-card-link post-link\" href=\"/s/blog/p/hello-world/\"><span class=\"space-card-name post-title\">Hello, world</span></a>"
    html `contains` "<time class=\"post-date\" datetime=\"2026-09-01T12:00:00Z\">1 September 2026</time> · <span class=\"post-comments\">5 comments</span>"
    html `contains` "<time class=\"post-date\" datetime=\"2026-09-19T12:00:00Z\">19 September 2026</time> · <span class=\"post-comments\">No comments</span>"
    html `contains` "<p class=\"space-card-description post-excerpt\">This is the first post of a blog that is also a wiki. Every page is Markdown, written in a split view with the page rendered next to it as you type.</p>"
    comesBefore html "Notes on Haskell</span>" "Hello, world</span></a>"
    -- Two posts make one page, with no way to another.
    html `lacks` "class=\"pager\""
    -- Nobody signed in writes no post.
    html `lacks` "New post"

  it "offers a new post to whoever may edit the space" $ do
    Rendered {html} <- render (as (Just "user-editor")) (Space blogPath)
    html `contains` "<a class=\"button new-post\" href=\"/s/blog/new-page/\">New post</a>"

  it "names a post's author where one is known" $ do
    let st = as Nothing
        authored = st {versions = Map.map (Map.map (\v -> Saved {title = v.title, body = v.body, author = Just (UserId "user-editor")})) st.versions}
    Rendered {html} <- render authored (Space blogPath)
    html `contains` "1 September 2026</time> · <span class=\"post-author\">Edgar Editor</span> · <span class=\"post-comments\">5 comments</span>"

  it "shows ten posts a page, with the way to the older ones and back" $ do
    let st = withTwelve (as Nothing)
    Rendered {html} <- render st (Space blogPath)
    length (T.breakOnAll "class=\"space-card post-card\"" html) `shouldBe` 10
    html `contains` "Post 12</span>"
    html `contains` "Post 3</span>"
    html `lacks` "Post 2</span>"
    html `contains` "<span class=\"pager-at\">Page 1 of 2</span>"
    html `contains` "<a class=\"button pager-older\" href=\"/s/blog/?page=2\">Older posts →</a>"
    html `lacks` "pager-newer"
    Rendered {html = older, title} <- render st (Posts blogPath 2)
    title `shouldBe` "Page 2 · Blog · Wiki"
    length (T.breakOnAll "class=\"space-card post-card\"" older) `shouldBe` 4
    comesBefore older "Post 1</span>" "Notes on Haskell</span>"
    older `contains` "<a class=\"button pager-newer\" href=\"/s/blog/\">← Newer posts</a>"
    older `contains` "<span class=\"pager-at\">Page 2 of 2</span>"
    older `lacks` "pager-older"
    -- A page past the last shows the last.
    Rendered {html = past} <- render st (Posts blogPath 9)
    past `contains` "<span class=\"pager-at\">Page 2 of 2</span>"

  it "shows its home page above its posts, and not among them" $ do
    Rendered {html} <- render (withHome (as Nothing)) (Space blogPath)
    html `contains` "<div class=\"blog-home\"><article class=\"page-body\"><h1 id=\"notes-on-haskell\">Notes on Haskell</h1>"
    html `lacks` "Notes on Haskell</span></a>"
    html `contains` "Hello, world</span></a>"
    comesBefore html "class=\"blog-home\"" "class=\"space-cards post-list\""

  it "says when a post was posted, and links to the posts before and after it" $ do
    Rendered {html = hello} <- render (as Nothing) (Page blogPath (slugs ["hello-world"]))
    hello `contains` "<div class=\"post-info\"><p class=\"post-date\">Posted <time datetime=\"2026-09-01T12:00:00Z\">1 September 2026</time></p>"
    hello `contains` "<a class=\"post-next\" href=\"/s/blog/p/notes-on-haskell/\" rel=\"next\"><span class=\"post-nav-label\">Next</span><span class=\"post-nav-title\">Notes on Haskell</span></a>"
    hello `lacks` "post-previous"
    Rendered {html = notes} <- render (as Nothing) (Page blogPath (slugs ["notes-on-haskell"]))
    notes `contains` "<a class=\"post-previous\" href=\"/s/blog/p/hello-world/\" rel=\"prev\"><span class=\"post-nav-label\">Previous</span><span class=\"post-nav-title\">Hello, world</span></a>"
    notes `lacks` "post-next"
    -- A page of a space that is no blog is no post.
    Rendered {html = tour} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["tour"]))
    tour `lacks` "post-info"

  it "opens a space that is no blog, asked for a page of posts, as it opens anyway" $ do
    Rendered {html} <- render (as Nothing) (Posts (slugs ["docs"]) 2)
    html `contains` "<h1 id=\"tour\">"
    html `lacks` "blog-view"

  describe "the head" $ do
    let siteWith feeds = Site {address = ("https://wiki.example" <>), feeds, attachmentAddress = \a -> Just ("https://wiki.example/files/" <> a.name), iconAddress = const Nothing}
        site = siteWith True

    it "describes a public post to a link preview, with its first image, and announces the blog's feeds" $ do
      Rendered {meta} <- render (as Nothing) (Page blogPath (slugs ["hello-world"]))
      meta.title `shouldBe` "Hello, world · Blog · Wiki"
      meta.feeds `shouldBe` Just Feeds {address = "/s/blog/", name = "Blog"}
      (\p -> (p.title, p.url, p.kind)) <$> meta.preview `shouldBe` Just ("Hello, world", "/s/blog/p/hello-world/", "article")
      (\p -> T.isPrefixOf "This is the first post of a blog" p.description) <$> meta.preview `shouldBe` Just True
      (\p -> case p.image of Just (WebImage url) -> "https://upload.wikimedia.org/" `T.isPrefixOf` url; _ -> False) <$> meta.preview `shouldBe` Just True
      let tags = headTags site meta
      tags `contains` "<meta name=\"description\" content=\"This is the first post of a blog that is also a wiki."
      tags `contains` "<meta property=\"og:title\" content=\"Hello, world\">"
      tags `contains` "<meta property=\"og:type\" content=\"article\">"
      tags `contains` "<meta property=\"og:url\" content=\"https://wiki.example/s/blog/p/hello-world/\">"
      tags `contains` "<meta property=\"og:image\" content=\"https://upload.wikimedia.org/"
      tags `contains` "<link rel=\"alternate\" type=\"application/atom+xml\" title=\"Blog (Atom)\" href=\"/s/blog/feed.xml\">"
      tags `contains` "<link rel=\"alternate\" type=\"application/rss+xml\" title=\"Blog (RSS)\" href=\"/s/blog/feed.rss\">"
      headTags (siteWith False) meta `lacks` "alternate"

    it "describes a public space by its description, a page's attachment by its address" $ do
      Rendered {meta} <- render (as Nothing) (Space (slugs ["docs"]))
      (\p -> (p.title, p.url, p.kind, p.description)) <$> meta.preview
        `shouldBe` Just ("Docs", "/s/docs/", "website", "How to use this wiki: a guided tour, and everything its Markdown can do.")
      meta.feeds `shouldBe` Nothing
      let st = as Nothing
          pictured = st {pages = Map.map (\p -> if p.title == "Markdown guide" then p {P.body = "Text first.\n\n![A tree](attachment:tree.png)"} else p) st.pages}
      Rendered {meta = guide} <- render pictured (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
      headTags site guide `contains` "<meta property=\"og:image\" content=\"https://wiki.example/files/tree.png\">"

    it "says nothing of a private page, even to someone who may read it" $ do
      Rendered {meta} <- render (as (Just "user-admin")) (Page (slugs ["team"]) (slugs ["team-handbook"]))
      meta.title `shouldBe` "Team handbook · Team · Wiki"
      meta.preview `shouldBe` Nothing
      headTags site meta `shouldBe` ""

    it "escapes what it writes" $
      headTags site (Head {title = "x", feeds = Nothing, preview = Just Preview {title = "A \"quote\" & <tag>", description = "", url = "/", kind = "website", image = Nothing}})
        `contains` "content=\"A &quot;quote&quot; &amp; &lt;tag&gt;\""
