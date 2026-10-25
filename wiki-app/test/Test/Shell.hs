-- | The application as it is rendered natively for a route
-- ("Wiki.App.Static"), which is also the HTML each prerendered page arrives
-- with: the shell around the route, with what the route shows loaded.
module Test.Shell (spec) where

import Data.IORef (readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Protolude
import Test.Hspec
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.Static (Rendered (..), renderRoute)
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space qualified as S

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)

-- | The demo as someone sees it: nobody, or one of its users.
as :: Maybe Text -> MemState
as who = (demoState demoNow) {current = UserId <$> who}

render :: MemState -> Route -> IO Rendered
render st = renderRoute st "/"

-- | The editor on the demo's first post.
helloEditor :: Route
helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])

-- | The demo's first post, as a wiki has it.
helloOf :: MemState -> P.Page
helloOf st = fromMaybe (panic "the demo has no Hello, world") (find (\p -> p.title == "Hello, world") (Map.elems st.pages))

-- | A draft of a page, by a user, of the version saved at a time, saved a
-- minute after the page.
draftOf :: P.Page -> Text -> UTCTime -> Draft
draftOf p author base =
  Draft
    { page = p.id
    , author = UserId author
    , title = "Hello, draft"
    , body = "Unsaved words"
    , base
    , savedAt = addUTCTime 60 p.updatedAt
    }

-- | The demo with its first post saved twice by the editor (a word and its
-- title, then a word), signed in as the editor; and the times of its three
-- versions, the first first.
savedTwice :: IO (MemState, [UTCTime])
savedTwice = do
  ref <- newMemWiki (as (Just "user-editor"))
  times <- runMemWiki ref $ do
    blog <- either (panic . show) identity <$> getSpace (slugs ["blog"])
    hello <- either (panic . show) identity <$> getPage blog.id (slugs ["hello-world"])
    let heading h = T.replace "# Hello, world" ("# Hello, " <> h) hello.body
    once <- either (panic . show) identity <$> savePage hello.id hello.updatedAt "Hello, again" (heading "wiki")
    twice <- either (panic . show) identity <$> savePage hello.id once.updatedAt "Hello, again" (heading "everyone")
    pure [hello.updatedAt, once.updatedAt, twice.updatedAt]
  (,times) <$> readIORef ref

contains :: Text -> Text -> Expectation
contains html part = (part, part `T.isInfixOf` html) `shouldBe` (part, True)

lacks :: Text -> Text -> Expectation
lacks html part = (part, part `T.isInfixOf` html) `shouldBe` (part, False)

spec :: Spec
spec = describe "Wiki.App.Shell, rendered" $ do
  it "lists the public spaces on the front page for someone not signed in" $ do
    Rendered {html, title} <- render (as Nothing) Home
    title `shouldBe` "Wiki"
    html `contains` "<h1>Spaces</h1>"
    html `contains` "<a class=\"space-card-link\" href=\"/s/blog/\"><span aria-hidden=\"true\" class=\"space-icon space-icon-emoji\">✍️</span><span class=\"space-card-name\">Blog</span></a>"
    html `contains` "<span class=\"space-card-name\">Docs</span>"
    html `lacks` "Team"
    html `contains` "<a href=\"/s/docs/p/tour/\">Take the tour</a>"
    html `contains` "Not signed in"
    html `lacks` "New space"

  it "shows a page with its breadcrumbs, its page tree and its islands as their sources" $ do
    Rendered {html, title} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["markdown-guide", "mathematics"]))
    title `shouldBe` "Mathematics · Markdown guide · Wiki"
    html `contains` "<h1 id=\"mathematics\">Mathematics</h1>"
    html `contains` "<span aria-current=\"page\">Mathematics</span>"
    html `contains` "<a href=\"/s/docs/p/markdown-guide/\">Markdown guide</a>"
    html `contains` "<span class=\"wiki-math wiki-math-inline\">"
    html `contains` "class=\"page-tree\""

  it "resolves links between pages to their routes, and attachments to their URLs" $ do
    Rendered {html} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["tour"]))
    html `contains` "href=\"/s/docs/p/markdown-guide/diagrams/\""
    Rendered {html = guide} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["markdown-guide"]))
    guide `contains` "<h2>Attachments</h2>"
    guide `contains` "<a download=\"tree.png\" href=\"data:image/png;base64,"
    guide `contains` "<a download=\"earth.jpg\" href=\"https://upload.wikimedia.org/"

  it "says in place that a private space is not for someone not signed in" $ do
    Rendered {html, title} <- render (as Nothing) (Space (slugs ["team"]))
    html `contains` "class=\"error error-forbidden\""
    title `shouldBe` "Private · Wiki"
    Rendered {html = handbook, title = handbookTitle} <- render (as Nothing) (Page (slugs ["team"]) (slugs ["team-handbook"]))
    handbook `contains` "class=\"error error-forbidden\""
    handbook `lacks` "Ada"
    handbookTitle `shouldBe` "Private · Wiki"

  it "shows a private space's pages to someone it is granted to, with what they may do" $ do
    Rendered {html, title} <- render (as (Just "user-admin")) (SpacePages (slugs ["team"]))
    title `shouldBe` "Pages and settings · Team · Wiki"
    html `contains` "<h1>Team</h1>"
    html `contains` "<p class=\"space-description\">How the team works: its handbook, who is on call, and its projects.</p>"
    html `contains` ">Team handbook</a>"
    html `contains` ">Space settings</button>"
    html `contains` ">Delete</button>"
    html `lacks` ">Rename</button>"

  it "opens a space at its home page, in the space's sidebar" $ do
    Rendered {html, title} <- render (as (Just "user-admin")) (Space (slugs ["team"]))
    title `shouldBe` "Team · Wiki"
    html `contains` "<h1 id=\"team-handbook\">Team handbook</h1>"
    html `contains` "<nav aria-label=\"Space\" class=\"wiki-sidebar space-sidebar\">"
    html `contains` "<a aria-current=\"page\" class=\"sidebar-space\" href=\"/s/team/\"><span aria-hidden=\"true\" class=\"space-icon space-icon-emoji\">🧭</span><span class=\"sidebar-space-name\">Team</span></a>"
    html `contains` "<a class=\"space-pages-link\" href=\"/s/team/pages/\">Pages and settings</a>"
    -- The sidebar has this space alone: its subspaces, and no other space.
    html `contains` "<h2>Subspaces</h2>"
    html `contains` "<a class=\"space-link\" href=\"/s/team/projects/\">"
    html `lacks` "href=\"/s/blog/\""
    -- The breadcrumbs start at the directory.
    html `contains` "<li><a href=\"/\">Spaces</a></li><li><span aria-current=\"page\">Team</span></li>"

  it "opens a subspace with the way up to the space it is in" $ do
    Rendered {html} <- render (as (Just "user-admin")) (Space (slugs ["team", "projects"]))
    html `contains` "<a class=\"sidebar-up\" href=\"/s/team/\">Up to Team</a>"
    html `contains` "<h1 id=\"the-wiki\">The wiki</h1>"
    html `contains` "<span aria-hidden=\"true\" class=\"space-icon space-icon-teal\">P</span>"
    Rendered {html = asReader} <- render (as (Just "user-reader")) (Space (slugs ["team", "projects"]))
    asReader `lacks` "sidebar-up"

  it "opens a space without a home page at its pages" $ do
    let st = as (Just "user-admin")
        withoutHome = st {spaces = Map.map (\x -> if x.name == "Docs" then S.withProfile S.SpaceProfile {S.description = x.description, S.icon = x.icon, S.homePage = Nothing} x else x) st.spaces}
    Rendered {html} <- render withoutHome (Space (slugs ["docs"]))
    html `contains` "<h1>Docs</h1>"
    html `contains` ">Space settings</button>"
    html `lacks` "space-home-link"

  it "offers a new space to an administrator, who holds no create-spaces grant of their own" $ do
    -- The demo's administrator holds the global administer only, which
    -- implies it.
    Rendered {html} <- render (as (Just "user-admin")) Home
    html `contains` "New space"
    Rendered {html = asReader} <- render (as (Just "user-reader")) Home
    asReader `lacks` "New space"

  it "greys out a space whose subspace is all a user may see, and leads to the subspace" $ do
    Rendered {html} <- render (as (Just "user-reader")) Home
    html `contains` "<span class=\"space-card-link unviewable\""
    html `contains` "You may open <a href=\"/s/team/projects/\">Team / Projects</a>."

  it "offers no actions on a space to someone who may only read it" $ do
    Rendered {html} <- render (as Nothing) (SpacePages (slugs ["docs"]))
    html `contains` "<h1>Docs</h1>"
    html `lacks` ">Space settings</button>"
    html `lacks` ">New page</a>"
    Rendered {html = home} <- render (as Nothing) (Space (slugs ["docs"]))
    home `lacks` ">Set as home page</button>"

  it "shows that an address is nothing" $ do
    Rendered {html, title} <- render (as Nothing) Unknown
    title `shouldBe` "Not found · Wiki"
    html `contains` "There is nothing at this address."

  it "shows a missing page as missing" $ do
    Rendered {html} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["no-such-page"]))
    html `contains` "class=\"error error-not-found\""

  it "opens the editor on a page with its Markdown in the textarea, alone, under a toolbar" $ do
    Rendered {html, title} <- render (as (Just "user-editor")) (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    title `shouldBe` "Edit · Hello, world · Wiki"
    html `contains` "<h1 class=\"editor-heading\">Editing Hello, world</h1>"
    html `contains` "class=\"editor-text\"># Hello, world\n\nThis is the first post"
    html `contains` "</div><div aria-label=\"Formatting\" class=\"editor-toolbar\" role=\"toolbar\">"
    html `contains` "<button aria-label=\"Bold\" class=\"tool\" title=\"Bold (Ctrl+B)\" type=\"button\">"
    html `contains` "<span>Show preview</span>"
    -- The preview is drawn the first time it is asked for.
    html `lacks` "<div class=\"preview\">"
    html `contains` "<form class=\"editor-form\">"
    html `contains` "href=\"/s/blog/p/hello-world/\">Cancel</a>"

  it "asks someone not signed in to choose who they are before editing" $ do
    Rendered {html} <- render (as Nothing) (EditPage (slugs ["docs"]) (slugs ["tour"]))
    html `contains` "class=\"error sign-in-hint\""
    html `lacks` "<textarea"

  it "says in place that a reader may not edit a page" $ do
    Rendered {html} <- render (as (Just "user-reader")) (EditPage (slugs ["blog"]) (slugs ["hello-world"]))
    html `contains` "class=\"error error-forbidden\""
    html `lacks` "<textarea"

  it "asks a new page's title first, under a page or at the space's top level" $ do
    Rendered {html, title} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) Nothing)
    title `shouldBe` "New page · Blog · Wiki"
    html `contains` "<section class=\"new-page-view\"><h1>New page in Blog</h1>"
    html `contains` "class=\"new-page-title\""
    html `contains` ">Create and edit</button>"
    html `contains` "href=\"/s/blog/\">Cancel</a>"
    html `lacks` "<textarea"
    html `lacks` "Save the page first"
    Rendered {html = under} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) (Just (slugs ["hello-world"])))
    under `contains` "<h1>New page under Hello, world</h1>"
    under `contains` "href=\"/s/blog/p/hello-world/\">Cancel</a>"
    Rendered {html = nowhere} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) (Just (slugs ["no-such-page"])))
    nowhere `contains` "class=\"error error-not-found\""
    Rendered {html = refused} <- render (as (Just "user-reader")) (NewPage (slugs ["blog"]) Nothing)
    refused `contains` "class=\"error error-forbidden\""
    refused `lacks` "new-page-title"

  it "offers Save, Save and close, and Cancel in the editor, and an empty notice of saves" $ do
    Rendered {html} <- render (as (Just "user-editor")) helloEditor
    html `contains` ">Save</button>"
    html `contains` ">Save and close</button>"
    html `contains` "<div class=\"editor-saved-notice\" role=\"status\"></div>"
    html `contains` "<span class=\"editor-draft-status\"></span>"
    html `lacks` "editor-draft-found"

  it "takes up the author's draft of the page as it is, and says so" $ do
    let st = as (Just "user-editor")
        hello = helloOf st
        draft = draftOf hello "user-editor" hello.updatedAt
    Rendered {html} <- render st {drafts = Map.singleton (hello.id, UserId "user-editor") draft} helloEditor
    html `contains` "Restored your unsaved draft from "
    html `contains` ">Discard it and go back to the saved page</button>"
    html `contains` ">Unsaved words</textarea>"
    html `contains` "value=\"Hello, draft\""
    -- Cancel asks what becomes of the draft rather than leaving.
    html `lacks` "href=\"/s/blog/p/hello-world/\">Cancel</a>"

  it "only offers a draft of an older version of the page" $ do
    let st = as (Just "user-editor")
        hello = helloOf st
        draft = draftOf hello "user-editor" (addUTCTime (-3600) hello.updatedAt)
    Rendered {html} <- render st {drafts = Map.singleton (hello.id, UserId "user-editor") draft} helloEditor
    html `contains` "You have an unsaved draft from "
    html `contains` ">Open the draft</button>"
    html `contains` "class=\"editor-text\"># Hello, world"
    html `lacks` "Unsaved words"

  it "shows nobody else's draft" $ do
    let st = as (Just "user-editor")
        hello = helloOf st
        draft = draftOf hello "user-admin" hello.updatedAt
    Rendered {html} <- render st {drafts = Map.singleton (hello.id, UserId "user-admin") draft} helloEditor
    html `lacks` "editor-draft-found"
    html `lacks` "Unsaved words"
    Rendered {html = page} <- render st {drafts = Map.singleton (hello.id, UserId "user-editor") (draftOf hello "user-editor" hello.updatedAt)} (Page (slugs ["blog"]) (slugs ["hello-world"]))
    page `lacks` "Unsaved words"

  it "offers to write a new page in a space, and under a page" $ do
    Rendered {html} <- render (as (Just "user-editor")) (SpacePages (slugs ["blog"]))
    html `contains` "href=\"/s/blog/new-page/\">New page</a>"
    Rendered {html = page} <- render (as (Just "user-editor")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    page `contains` "href=\"/s/blog/new-page/hello-world/\">New subpage</a>"
    page `contains` "href=\"/s/blog/p/hello-world/edit/\">Edit</a>"

  it "offers every reader of a page its source, and only an editor the rest" $ do
    Rendered {html} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["tour"]))
    html `contains` "<div class=\"actions page-actions\"><a class=\"button\" href=\"/s/docs/p/tour/source/\">View source</a><a class=\"button\" href=\"/s/docs/p/tour/history/\">History</a><button aria-expanded=\"false\" class=\"button comments-toggle\" type=\"button\">Comments (0)</button></div>"
    html `lacks` ">Edit</a>"
    Rendered {html = asReader} <- render (as (Just "user-reader")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    asReader `contains` "href=\"/s/blog/p/hello-world/source/\">View source</a>"
    asReader `lacks` ">Edit</a>"
    Rendered {html = asEditor} <- render (as (Just "user-editor")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    asEditor `contains` "href=\"/s/blog/p/hello-world/edit/\">Edit</a><a class=\"button\" href=\"/s/blog/p/hello-world/source/\">View source</a><a class=\"button\" href=\"/s/blog/p/hello-world/history/\">History</a><button aria-expanded=\"false\" class=\"button comments-toggle\" type=\"button\">Comments (2)</button>"

  it "marks a page's quotes that are found, shows its page threads under it, and keeps the panel closed" $ do
    Rendered {html} <- render (as Nothing) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    html `contains` "first post of <mark class=\"comment-mark\" data-thread=\"thread-hello-1\">a blog that is also a wiki</mark>. Every page is"
    -- The orphaned thread's quote is nowhere to be marked.
    html `lacks` "data-thread=\"thread-hello-2\""
    html `lacks` "comments-panel"
    html `contains` "<section aria-label=\"Comments on the page\" class=\"page-comments\"><h2>Comments</h2>"
    html `contains` "<span class=\"comment-author\">Ada Admin</span>"
    html `contains` "<p>Welcome! Comments here are about the whole post; select some of its text to comment on that.</p>"
    html `contains` "<p class=\"sign-in-to-comment\">Sign in to comment.</p>"
    html `lacks` "comment-form"
    Rendered {html = asReader} <- render (as (Just "user-reader")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    asReader `contains` "<span>New comment</span>"
    asReader `lacks` "sign-in-to-comment"
    -- A reply, by someone who may reply.
    asReader `contains` "comment-reply"

  it "shows a page's Markdown to someone not signed in, with the way back to the page" $ do
    Rendered {html, title} <- render (as Nothing) (PageSource (slugs ["docs"]) (slugs ["tour"]))
    title `shouldBe` "Source · Tour · Wiki"
    html `contains` "<div class=\"source-view\"><header class=\"view-header\"><h1>Tour</h1>"
    html `contains` "<a class=\"button source-back\" href=\"/s/docs/p/tour/\">Back</a><button class=\"source-copy\" type=\"button\">Copy</button>"
    html `contains` "<pre class=\"source-text\"># Tour\n\nThis is the demo of a wiki"
    -- The Markdown as it is written, not rendered: a table's pipes, a
    -- callout's marker, and markup escaped as text.
    html `contains` "&gt; [!NOTE]"
    html `contains` "| Who "
    html `lacks` "<article"
    html `contains` "<a href=\"/s/docs/p/tour/\">Tour</a>"
    html `contains` "<span aria-current=\"page\">Source</span>"

  it "shows the source to a reader who may not edit the page" $ do
    Rendered {html} <- render (as (Just "user-reader")) (PageSource (slugs ["team", "projects"]) (slugs ["the-wiki"]))
    html `contains` "<pre class=\"source-text\">"
    html `lacks` ">Edit</a>"

  it "refuses the source where the page is refused, for the same reasons" $ do
    Rendered {html, title} <- render (as Nothing) (PageSource (slugs ["team"]) (slugs ["team-handbook"]))
    html `contains` "class=\"error error-forbidden\""
    html `contains` "Switch to someone who has, at the top right."
    html `lacks` "source-text"
    title `shouldBe` "Private · Wiki"
    Rendered {html = missing} <- render (as Nothing) (PageSource (slugs ["docs"]) (slugs ["no-such-page"]))
    missing `contains` "class=\"error error-not-found\""
    missing `lacks` "source-text"
    Rendered {html = projects} <- render (as Nothing) (PageSource (slugs ["team", "projects"]) (slugs ["the-wiki"]))
    projects `contains` "class=\"error error-forbidden\""

  it "shows a page's history to someone not signed in: its one version, all of its text new" $ do
    Rendered {html, title} <- render (as Nothing) (PageHistory (slugs ["docs"]) (slugs ["tour"]) Nothing AgainstPrevious)
    title `shouldBe` "History · Tour · Wiki"
    html `contains` "<div class=\"history-view\"><header class=\"view-header\"><h1>Tour</h1><span class=\"badge\">History</span></header>"
    html `contains` "<a class=\"button history-back\" href=\"/s/docs/p/tour/\">Back</a>"
    html `contains` "<a aria-current=\"true\" href=\"/s/docs/p/tour/history/\">Version 1 (current)</a>"
    html `contains` "<time class=\"wiki-time\" datetime=\"2026-09-30T12:00:00Z\">"
    html `contains` "The first version: all of its text is new."
    html `contains` "<tr class=\"diff-line diff-added\"><td class=\"diff-number\"></td><td class=\"diff-number\">1</td><td aria-hidden=\"true\" class=\"diff-sign\">+</td><td class=\"diff-text\"># Tour</td></tr>"
    html `contains` "<span aria-current=\"page\">History</span>"
    html `lacks` "Restore this version"

  it "shows what a version changed, word by word, and offers an editor to restore it" $ do
    (st, [v1, v2, v3]) <- savedTwice
    let history v against = PageHistory (slugs ["blog"]) (slugs ["hello-world"]) v against
    Rendered {html} <- render st (history (Just v2) AgainstPrevious)
    html `contains` "Version 2</a>"
    html `contains` "Version 3 (current)</a>"
    html `contains` "<a aria-current=\"true\" href=\"/s/blog/p/hello-world/history/?version="
    html `contains` "What it changed from version 1."
    html `contains` "<p class=\"diff-title\">The title: <del>Hello, world</del> <ins>Hello, again</ins></p>"
    html `contains` "<tr class=\"diff-line diff-removed\"><td class=\"diff-number\">1</td><td class=\"diff-number\"></td><td aria-hidden=\"true\" class=\"diff-sign\">−</td><td class=\"diff-text\"># Hello, <del>world</del></td></tr>"
    html `contains` "<tr class=\"diff-line diff-added\"><td class=\"diff-number\"></td><td class=\"diff-number\">1</td><td aria-hidden=\"true\" class=\"diff-sign\">+</td><td class=\"diff-text\"># Hello, <ins>wiki</ins></td></tr>"
    html `contains` "by <!---->Edgar Editor</p>"
    html `contains` "<button class=\"restore\" type=\"button\">Restore this version</button>"
    html `contains` "<strong aria-current=\"true\" class=\"diff-against-chosen\">the version before</strong>"
    html `contains` "&amp;against=current\">the current version</a>"
    Rendered {html = since} <- render st (history (Just v2) AgainstCurrent)
    since `contains` "What has changed since, up to the current version."
    since `contains` "<td class=\"diff-text\"># Hello, <ins>everyone</ins></td>"
    -- The current version is the page: nothing to restore, nor to compare
    -- with itself.
    Rendered {html = latest} <- render st (history (Just v3) AgainstCurrent)
    latest `contains` "<h2>Version 3 (current)</h2>"
    latest `contains` "What it changed from version 2."
    latest `lacks` "Restore this version"
    latest `lacks` "diff-against"
    -- A reader who may not edit is shown no restore.
    Rendered {html = asReader} <- render st {current = Just (UserId "user-reader")} (history (Just v1) AgainstPrevious)
    asReader `contains` "The first version"
    asReader `lacks` "Restore this version"

  it "refuses a history where the page is refused, and a version the page does not have" $ do
    Rendered {html, title} <- render (as Nothing) (PageHistory (slugs ["team"]) (slugs ["team-handbook"]) Nothing AgainstPrevious)
    html `contains` "class=\"error error-forbidden\""
    html `lacks` "history-view"
    title `shouldBe` "Private · Wiki"
    Rendered {html = missing} <- render (as Nothing) (PageHistory (slugs ["docs"]) (slugs ["tour"]) (Just demoNow) AgainstPrevious)
    missing `contains` "class=\"error error-not-found\""

  it "ends every page with the footer, linking to haskell-halogen" $ do
    let footer = "<footer class=\"wiki-footer\">Built with <a href=\"https://github.com/Swordlash/haskell-halogen\">haskell-halogen</a></footer>"
    for_ [Home, Unknown, Admin, Space (slugs ["docs"]), Page (slugs ["docs"]) (slugs ["tour"]), EditPage (slugs ["docs"]) (slugs ["tour"]), PageSource (slugs ["docs"]) (slugs ["tour"])] $ \r -> do
      Rendered {html} <- render (as Nothing) r
      html `contains` footer
      -- The frame's last element, after its body.
      (footer <> "</div>") `T.isSuffixOf` html `shouldBe` True

  it "writes its links under the base path" $ do
    Rendered {html} <- renderRoute (as Nothing) "/wiki/" Home
    html `contains` "href=\"/wiki/s/docs/\""
    html `contains` "href=\"/wiki/\""

  it "has a search box in its header" $ do
    Rendered {html} <- render (as Nothing) Home
    html `contains` "<div class=\"wiki-search\" role=\"search\">"
    html `contains` "placeholder=\"Search pages… (/)\""
    html `contains` "<option selected value=\"\">All spaces</option>"

  it "offers to search only the spaces someone may view" $ do
    Rendered {html} <- render (as (Just "user-reader")) Home
    html `contains` ">Team / Projects</option>"
    html `lacks` ">Team</option>"

  it "shows the search route with nothing to search for" $ do
    Rendered {html, title} <- render (as Nothing) (Search Nothing Nothing True)
    title `shouldBe` "Search · Wiki"
    html `contains` "<h1>Search</h1>"
    html `contains` "Type what to look for in the search box"

  it "lists the results of a search, the matches marked" $ do
    Rendered {html} <- render (as Nothing) (Search (Just "mermaid") Nothing True)
    html `contains` "pages for “mermaid” in every space."
    html `contains` "<a class=\"search-hit\" href=\"/s/docs/p/markdown-guide/diagrams/\">"
    html `contains` "<span class=\"search-hit-space\">Docs</span>"
    html `contains` "<mark>mermaid</mark>"
    html `lacks` "Team"

  it "keeps a search to a space, and its subspaces only when asked" $ do
    Rendered {html = only} <- render (as (Just "user-admin")) (Search (Just "the") (Just (slugs ["team"])) False)
    only `contains` "in Team."
    only `contains` "href=\"/s/team/p/team-handbook/\""
    only `lacks` "href=\"/s/team/projects/p/"
    Rendered {html = all'} <- render (as (Just "user-admin")) (Search (Just "the") (Just (slugs ["team"])) True)
    all' `contains` "in Team and its subspaces."
    all' `contains` "href=\"/s/team/projects/p/the-wiki/\""

  it "says when a search finds nothing" $ do
    Rendered {html} <- render (as Nothing) (Search (Just "handbook") Nothing True)
    html `contains` "No results for “handbook” in every space."

  it "says so when the space searched is not one" $ do
    Rendered {html} <- render (as Nothing) (Search (Just "the") (Just []) True)
    html `contains` "There is no such space to search in"
    Rendered {html = team} <- render (as Nothing) (Search (Just "the") (Just (slugs ["team"])) False)
    team `contains` "There is no such space to search in"

  it "links an administrator to the administration, whose first section is the wiki's data" $ do
    Rendered {html = home} <- render (as (Just "user-admin")) Home
    home `contains` "<a class=\"admin-link\" href=\"/admin/\">Administration</a>"
    Rendered {html, title} <- render (as (Just "user-admin")) Admin
    title `shouldBe` "Administration · Wiki"
    html `contains` "<a aria-current=\"page\" class=\"admin-link\" href=\"/admin/\">Administration</a>"
    html `contains` "<section class=\"admin-view\"><h1>Administration</h1><section class=\"admin-section admin-data\"><h2>Wiki data</h2>"
    html `contains` ">Export the wiki</button>"
    html `contains` "Import a wiki…"
    html `contains` ">Reset the demo content…</button>"
    -- In the menu no longer: it only switches users.
    html `lacks` "user-menu"

  it "lists the users and the groups for an administrator, after the wiki's data, but no switch for their own" $ do
    Rendered {html} <- render (as (Just "user-admin")) Admin
    html `contains` "</section><div class=\"admin-people\"><section class=\"admin-section admin-users\"><h2>Users</h2>"
    html `contains` "<section class=\"admin-section admin-groups\"><h2>Groups</h2>"
    html `lacks` "Loading…"
    T.count "<tr class=\"user-row\"" html `shouldBe` 3
    -- Ada may not demote herself from here; she may anyone else.
    html `contains` "aria-checked=\"true\" aria-label=\"Ada Admin is an administrator\" class=\"switch administrator-switch\" disabled"
    html `contains` "That is you"
    html `contains` "aria-checked=\"false\" aria-label=\"Edgar Editor is an administrator\" class=\"switch administrator-switch\" role=\"switch\""
    html `contains` "<h3 class=\"group-name\">writers</h3><span class=\"group-count\">1 member</span>"
    html `contains` "<li class=\"group-member\" data-login=\"editor\">"

  it "shows nobody else the way to the administration, nor its controls there" $
    for_ [Nothing, Just "user-reader", Just "user-editor"] $ \who -> do
      Rendered {html = home} <- render (as who) Home
      home `lacks` "admin-link"
      Rendered {html, title} <- render (as who) Admin
      title `shouldBe` "Administration · Wiki"
      html `contains` "<section class=\"admin-view\"><h1>Administration</h1><div class=\"error error-forbidden\" role=\"alert\">This page is for the wiki's administrators"
      html `contains` "at the top right."
      html `lacks` "admin-link"
      html `lacks` "Export the wiki"
      html `lacks` "demo-"
      html `lacks` "admin-users"
