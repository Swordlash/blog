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
    Rendered {html} <- render (as Nothing) (Space (slugs ["team"]))
    html `contains` "class=\"error error-forbidden\""

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

  it "writes its links under the base path" $ do
    Rendered {html} <- renderRoute (as Nothing) "/wiki/" Home
    html `contains` "href=\"/wiki/s/docs/\""
    html `contains` "href=\"/wiki/\""
