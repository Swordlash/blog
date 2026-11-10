-- | Where a link written in a page leads: the rule the demo's pages are
-- written to ("Test.Demo"), a browser's reading of a path from the page's
-- address.
module Test.Link (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route
import Wiki.App.View.LinkDialog (pageAddress)
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Markdown (Destination (..), classifyDestination)
import Wiki.Core.Page (Page (body, id, space, title))
import Wiki.Core.Path (pathOf)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (id, slug))
import Wiki.Core.Space qualified as S

demo :: MemState
demo = demoState demoNow

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)

spaces :: [Space]
spaces = Map.elems demo.spaces

-- | Where a destination leads from the page at this path of @docs@.
fromDocs :: [Text] -> Text -> Maybe PageLink
fromDocs page = resolvePageLink spaces (slugs ["docs"]) (rootOf "docs") (pagesOf "docs") (slugs page)

-- | The root of a space's pages, its home page.
rootOf :: Text -> Maybe PageId
rootOf s = S.rootPage =<< find (\sp -> sp.slug == mkSlug' s) spaces

mkSlug' :: Text -> Slug
mkSlug' = either (panic . show) identity . mkSlug

pagesOf :: Text -> [Page]
pagesOf s = [p | p <- Map.elems demo.pages, Just p.space == ((\sp -> sp.id) <$> find (\sp -> sp.slug == mkSlug' s) spaces)]

-- | Where a link leads that leads to Docs itself: its home page.
docsSpace :: Maybe PageLink
docsSpace = Just (PageLink (Space (slugs ["docs"])) "")

docsPage :: [Text] -> Maybe PageLink
docsPage path = Just (PageLink (Page (slugs ["docs"]) (slugs path)) "")

spec :: Spec
spec = describe "resolvePageLink" $ do
  -- The tour is the home page of Docs, the root of its pages: its path is
  -- empty, and the Markdown guide is under it (WP5.78 of docs/PLAN.md).
  it "reads a relative path from the page's parent, as a browser does" $ do
    fromDocs [] "markdown-guide" `shouldBe` docsPage ["markdown-guide"]
    fromDocs [] "markdown-guide/diagrams" `shouldBe` docsPage ["markdown-guide", "diagrams"]
    fromDocs ["markdown-guide", "diagrams"] "mathematics" `shouldBe` docsPage ["markdown-guide", "mathematics"]
    fromDocs ["markdown-guide", "diagrams"] "./mathematics" `shouldBe` docsPage ["markdown-guide", "mathematics"]

  it "goes up with .., but not above the pages under the home page" $ do
    fromDocs ["markdown-guide", "diagrams"] ".." `shouldBe` docsSpace
    fromDocs ["markdown-guide", "diagrams"] "." `shouldBe` docsPage ["markdown-guide"]
    fromDocs [] "." `shouldBe` docsSpace
    fromDocs [] "../markdown-guide" `shouldBe` Nothing

  it "reads an old address, with the home page's slug first, as the page's address now" $ do
    fromDocs ["markdown-guide", "diagrams"] "../tour" `shouldBe` docsSpace
    fromDocs [] "tour/markdown-guide" `shouldBe` docsPage ["markdown-guide"]
    fromDocs ["markdown-guide"] "/docs/tour/markdown-guide/diagrams" `shouldBe` docsPage ["markdown-guide", "diagrams"]

  it "keeps the fragment, and drops the query" $
    fromDocs [] "markdown-guide?x=1#links" `shouldBe` Just (PageLink (Page (slugs ["docs"]) (slugs ["markdown-guide"])) "#links")

  it "reads a title as a slug, for a wiki link" $ do
    fromDocs [] "Markdown guide" `shouldBe` docsPage ["markdown-guide"]
    fromDocs ["markdown-guide"] "Tour" `shouldBe` docsSpace

  it "leads nowhere for a page the space does not have" $ do
    fromDocs [] "no-such-page" `shouldBe` Nothing
    fromDocs [] "diagrams" `shouldBe` Nothing

  it "reads a path from / as a space's path and a page's" $ do
    fromDocs [] "/docs" `shouldBe` docsSpace
    fromDocs [] "/team/projects" `shouldBe` Just (PageLink (Space (slugs ["team", "projects"])) "")
    fromDocs [] "/docs/markdown-guide/diagrams" `shouldBe` docsPage ["markdown-guide", "diagrams"]
    fromDocs [] "/docs/no-such-page" `shouldBe` Nothing
    fromDocs [] "/blog/hello-world" `shouldBe` Just (PageLink (Page (slugs ["blog"]) (slugs ["hello-world"])) "")
    fromDocs [] "/nowhere/at-all" `shouldBe` Nothing

  it "leads to each of the demo's pages from the address \"Link to a page\" writes, from anywhere" $
    for_ (Map.elems demo.pages) $ \p -> do
      let spacePath = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) p.space)
          pagePath = fromMaybe [] (find (\s -> s.id == p.space) spaces >>= \s -> S.pagePath s (`Map.lookup` demo.pages) p.id)
          address = pageAddress spacePath pagePath
          expected = if null pagePath then Space spacePath else Page spacePath pagePath
      (address, fromDocs [] (address <> "#intro")) `shouldBe` (address, Just (PageLink expected "#intro"))

  it "writes a page's own address for \"Link to a page\", without the router's prefix or mode" $
    pageAddress (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"]) `shouldBe` "/s/docs/p/markdown-guide/diagrams/"

  it "reads a page's own address as that page, and a path as the longest space path, when a subspace has the page's slug" $ do
    let docs = fromMaybe (panic "no docs") (find (\sp -> sp.slug == mkSlug' "docs") spaces)
        -- A subspace of Docs with the slug of one of Docs' pages.
        sub = docs {S.id = SpaceId "space-guide", S.name = "Guide", S.slug = mkSlug' "markdown-guide", S.parent = Just docs.id}
        resolve = resolvePageLink (sub : spaces) (slugs ["docs"]) (rootOf "docs") (pagesOf "docs") []
    resolve (pageAddress (slugs ["docs"]) (slugs ["markdown-guide"]) <> "#links") `shouldBe` Just (PageLink (Page (slugs ["docs"]) (slugs ["markdown-guide"])) "#links")
    resolve "/docs/markdown-guide" `shouldBe` Just (PageLink (Space (slugs ["docs", "markdown-guide"])) "")
    -- A page of this space it does not have is a broken link.
    resolve (pageAddress (slugs ["docs"]) (slugs ["no-such-page"])) `shouldBe` Nothing
    -- Nor does a space nobody can see have pages.
    resolve (pageAddress (slugs ["nowhere"]) (slugs ["at-all"])) `shouldBe` Nothing

  it "leads to a page of this space by its id at its address now, and to any other id at the permanent address" $ do
    let idOf path = fromMaybe (panic "no page") (find (\p -> S.pagePath docs (`Map.lookup` demo.pages) p.id == Just (slugs path)) (pagesOf "docs"))
        docs = fromMaybe (panic "no docs") (find (\sp -> sp.slug == mkSlug' "docs") spaces)
        diagrams = (idOf ["markdown-guide", "diagrams"]).id
        tour = (idOf []).id
    fromDocs [] ("/l/" <> diagrams.text <> "/#flowcharts") `shouldBe` Just (PageLink (Page (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"])) "#flowcharts")
    fromDocs ["markdown-guide"] ("/l/" <> tour.text) `shouldBe` docsSpace
    -- A page of another space, or one the reader may not view, or no page
    -- at all: the permanent address, asked about when it is followed, and
    -- never a broken link.
    fromDocs [] "/l/no-such-page/#x" `shouldBe` Just (PageLink (PermanentLink (PageId "no-such-page")) "#x")
    let blogPost = fromMaybe (panic "no post") (head (pagesOf "blog"))
    fromDocs [] ("/l/" <> blogPost.id.text <> "/") `shouldBe` Just (PageLink (PermanentLink blogPost.id) "")

  it "reads /l/ and a segment as a permanent address, even where a top-level space has the slug l" $ do
    let docs = fromMaybe (panic "no docs") (find (\sp -> sp.slug == mkSlug' "docs") spaces)
        el = docs {S.id = SpaceId "space-l", S.name = "L", S.slug = mkSlug' "l", S.parent = Nothing}
        resolve = resolvePageLink (el : spaces) (slugs ["docs"]) (rootOf "docs") (pagesOf "docs") []
    resolve "/l/notes" `shouldBe` Just (PageLink (PermanentLink (PageId "notes")) "")
    -- Its pages are reached by the space's own address, or by a longer path.
    resolve "/s/l/p/notes/" `shouldBe` Just (PageLink (Page (slugs ["l"]) (slugs ["notes"])) "")
    resolve "/l/notes/more" `shouldBe` Just (PageLink (Page (slugs ["l"]) (slugs ["notes", "more"])) "")

  it "resolves every link between the demo's pages" $
    for_ (Map.elems demo.pages) $ \p -> do
      let space = fromMaybe (panic "no space") (find (\s -> s.id == p.space) spaces)
          spacePath = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) space.id)
          pagePath = fromMaybe [] (S.pagePath space (`Map.lookup` demo.pages) p.id)
          siblings = filter (\q -> q.space == p.space) (Map.elems demo.pages)
      for_ (filter (not . T.isPrefixOf "<") (linkTargets p.body)) $ \t -> case classifyDestination t of
        ToPath _ -> (p.title, t, isJust (resolvePageLink spaces spacePath (S.rootPage space) siblings pagePath t)) `shouldBe` (p.title, t, True)
        _ -> pass

-- | The targets of the Markdown links and images in a body, and of its wiki
-- links, but for the markers of the wiki's own blocks, @[[!toc]]@,
-- @[[!spoiler]]@ and the others, and their end markers, @[[/spoiler]]@ and
-- the others, which are no links, and of @[[toc]]@ and @[[/name]]@, which
-- the guide shows in code.
linkTargets :: Text -> [Text]
linkTargets body =
  map (T.takeWhile (/= ')')) (drop 1 (T.splitOn "](" body))
    <> filter (\t -> not ("!" `T.isPrefixOf` t) && t `notElem` ["toc", "/name", "/spoiler", "/notes", "/incremental", "/div"]) (map (T.takeWhile (`notElem` ['|', ']'])) (drop 1 (T.splitOn "[[" body)))
