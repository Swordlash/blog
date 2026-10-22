-- | The application as it is rendered natively for a route
-- ("Wiki.App.Static"), which is also the HTML each prerendered page arrives
-- with: the shell around the route, with what the route shows loaded.
module Test.Shell (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route (..))
import Wiki.App.Static (Rendered (..), renderRoute)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Slug (Slug, mkSlug)

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)

-- | The demo as someone sees it: nobody, or one of its users.
as :: Maybe Text -> MemState
as who = (demoState demoNow) {current = UserId <$> who}

render :: MemState -> Route -> IO Rendered
render st = renderRoute st "/"

contains :: Text -> Text -> Expectation
contains html part = (part, part `T.isInfixOf` html) `shouldBe` (part, True)

lacks :: Text -> Text -> Expectation
lacks html part = (part, part `T.isInfixOf` html) `shouldBe` (part, False)

spec :: Spec
spec = describe "Wiki.App.Shell, rendered" $ do
  it "lists the public spaces on the front page for someone not signed in" $ do
    Rendered {html, title} <- render (as Nothing) Home
    title `shouldBe` "Wiki"
    html `contains` "<a href=\"/s/blog/\">Blog</a>"
    html `contains` "<a href=\"/s/docs/\">Docs</a>"
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

  it "shows a private space to someone it is granted to, with what they may do" $ do
    Rendered {html} <- render (as (Just "user-admin")) (Space (slugs ["team"]))
    html `contains` "<h1>Team</h1>"
    html `contains` ">Team handbook</a>"
    html `contains` ">Rename</button>"
    html `contains` ">Delete</button>"

  it "greys out a space whose subspace is all a user may see" $ do
    Rendered {html} <- render (as (Just "user-reader")) Home
    html `contains` "<span class=\"unviewable\""
    html `contains` "<a class=\"space-link\" href=\"/s/team/projects/\">Projects</a>"

  it "offers no actions on a space to someone who may only read it" $ do
    Rendered {html} <- render (as Nothing) (Space (slugs ["docs"]))
    html `contains` "<h1>Docs</h1>"
    html `lacks` ">Rename</button>"
    html `lacks` ">New page</button>"

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

  it "opens the editor on a new page, under a page or at the space's top level" $ do
    Rendered {html, title} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) Nothing)
    title `shouldBe` "New page · Blog · Wiki"
    html `contains` "<h1 class=\"editor-heading\">New page in Blog</h1>"
    html `contains` "<textarea"
    html `contains` "Save the page first; then files can be attached to it."
    Rendered {html = under} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) (Just (slugs ["hello-world"])))
    under `contains` "<h1 class=\"editor-heading\">New page under Hello, world</h1>"
    Rendered {html = nowhere} <- render (as (Just "user-editor")) (NewPage (slugs ["blog"]) (Just (slugs ["no-such-page"])))
    nowhere `contains` "class=\"error error-not-found\""

  it "offers to write a new page in a space, and under a page" $ do
    Rendered {html} <- render (as (Just "user-editor")) (Space (slugs ["blog"]))
    html `contains` "href=\"/s/blog/new-page/\">New page</a>"
    Rendered {html = page} <- render (as (Just "user-editor")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    page `contains` "href=\"/s/blog/new-page/hello-world/\">New subpage</a>"
    page `contains` "href=\"/s/blog/p/hello-world/edit/\">Edit</a>"

  it "offers every reader of a page its source, and only an editor the rest" $ do
    Rendered {html} <- render (as Nothing) (Page (slugs ["docs"]) (slugs ["tour"]))
    html `contains` "<div class=\"actions\"><a class=\"button\" href=\"/s/docs/p/tour/source/\">View source</a></div>"
    html `lacks` ">Edit</a>"
    Rendered {html = asReader} <- render (as (Just "user-reader")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    asReader `contains` "href=\"/s/blog/p/hello-world/source/\">View source</a>"
    asReader `lacks` ">Edit</a>"
    Rendered {html = asEditor} <- render (as (Just "user-editor")) (Page (slugs ["blog"]) (slugs ["hello-world"]))
    asEditor `contains` "href=\"/s/blog/p/hello-world/edit/\">Edit</a><a class=\"button\" href=\"/s/blog/p/hello-world/source/\">View source</a>"

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

  it "ends every page with the footer, linking to haskell-halogen" $ do
    let footer = "<footer class=\"wiki-footer\">Built with <a href=\"https://github.com/Swordlash/haskell-halogen\">haskell-halogen</a></footer>"
    for_ [Home, Unknown, Space (slugs ["docs"]), Page (slugs ["docs"]) (slugs ["tour"]), EditPage (slugs ["docs"]) (slugs ["tour"]), PageSource (slugs ["docs"]) (slugs ["tour"])] $ \r -> do
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
