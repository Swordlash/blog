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
import Wiki.Core.Id (SpaceId (..))
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
fromDocs page = resolvePageLink spaces (slugs ["docs"]) (pagesOf "docs") (slugs page)

mkSlug' :: Text -> Slug
mkSlug' = either (panic . show) identity . mkSlug

pagesOf :: Text -> [Page]
pagesOf s = [p | p <- Map.elems demo.pages, Just p.space == ((\sp -> sp.id) <$> find (\sp -> sp.slug == mkSlug' s) spaces)]

docsPage :: [Text] -> Maybe PageLink
docsPage path = Just (PageLink (Page (slugs ["docs"]) (slugs path)) "")

spec :: Spec
spec = describe "resolvePageLink" $ do
  it "reads a relative path from the page's parent, as a browser does" $ do
    fromDocs ["tour"] "markdown-guide" `shouldBe` docsPage ["markdown-guide"]
    fromDocs ["tour"] "markdown-guide/diagrams" `shouldBe` docsPage ["markdown-guide", "diagrams"]
    fromDocs ["markdown-guide", "diagrams"] "mathematics" `shouldBe` docsPage ["markdown-guide", "mathematics"]
    fromDocs ["markdown-guide", "diagrams"] "./mathematics" `shouldBe` docsPage ["markdown-guide", "mathematics"]

  it "goes up with .., but not above the space's pages" $ do
    fromDocs ["markdown-guide", "diagrams"] "../tour" `shouldBe` docsPage ["tour"]
    fromDocs ["markdown-guide", "diagrams"] "." `shouldBe` docsPage ["markdown-guide"]
    fromDocs ["tour"] "." `shouldBe` Just (PageLink (Space (slugs ["docs"])) "")
    fromDocs ["tour"] "../tour" `shouldBe` Nothing

  it "keeps the fragment, and drops the query" $
    fromDocs ["tour"] "markdown-guide?x=1#links" `shouldBe` Just (PageLink (Page (slugs ["docs"]) (slugs ["markdown-guide"])) "#links")

  it "reads a title as a slug, for a wiki link" $
    fromDocs ["markdown-guide"] "Tour" `shouldBe` docsPage ["tour"]

  it "leads nowhere for a page the space does not have" $ do
    fromDocs ["tour"] "no-such-page" `shouldBe` Nothing
    fromDocs ["tour"] "diagrams" `shouldBe` Nothing

  it "reads a path from / as a space's path and a page's" $ do
    fromDocs ["tour"] "/docs" `shouldBe` Just (PageLink (Space (slugs ["docs"])) "")
    fromDocs ["tour"] "/team/projects" `shouldBe` Just (PageLink (Space (slugs ["team", "projects"])) "")
    fromDocs ["tour"] "/docs/markdown-guide/diagrams" `shouldBe` docsPage ["markdown-guide", "diagrams"]
    fromDocs ["tour"] "/docs/no-such-page" `shouldBe` Nothing
    fromDocs ["tour"] "/blog/hello-world" `shouldBe` Just (PageLink (Page (slugs ["blog"]) (slugs ["hello-world"])) "")
    fromDocs ["tour"] "/nowhere/at-all" `shouldBe` Nothing

  it "leads to each of the demo's pages from the address \"Link to a page\" writes, from anywhere" $
    for_ (Map.elems demo.pages) $ \p -> do
      let spacePath = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) p.space)
          pagePath = fromMaybe [] (pathOf (`Map.lookup` demo.pages) p.id)
          address = pageAddress spacePath pagePath
          expected = if null pagePath then Space spacePath else Page spacePath pagePath
      (address, fromDocs ["tour"] (address <> "#intro")) `shouldBe` (address, Just (PageLink expected "#intro"))

  it "writes a page's own address for \"Link to a page\", without the router's prefix or mode" $
    pageAddress (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"]) `shouldBe` "/s/docs/p/markdown-guide/diagrams/"

  it "reads a page's own address as that page, and a path as the longest space path, when a subspace has the page's slug" $ do
    let docs = fromMaybe (panic "no docs") (find (\sp -> sp.slug == mkSlug' "docs") spaces)
        -- A subspace of Docs with the slug of one of Docs' pages.
        sub = docs {S.id = SpaceId "space-guide", S.name = "Guide", S.slug = mkSlug' "markdown-guide", S.parent = Just docs.id}
        resolve = resolvePageLink (sub : spaces) (slugs ["docs"]) (pagesOf "docs") (slugs ["tour"])
    resolve (pageAddress (slugs ["docs"]) (slugs ["markdown-guide"]) <> "#links") `shouldBe` Just (PageLink (Page (slugs ["docs"]) (slugs ["markdown-guide"])) "#links")
    resolve "/docs/markdown-guide" `shouldBe` Just (PageLink (Space (slugs ["docs", "markdown-guide"])) "")
    -- A page of this space it does not have is a broken link.
    resolve (pageAddress (slugs ["docs"]) (slugs ["no-such-page"])) `shouldBe` Nothing
    -- Nor does a space nobody can see have pages.
    resolve (pageAddress (slugs ["nowhere"]) (slugs ["at-all"])) `shouldBe` Nothing

  it "resolves every link between the demo's pages" $
    for_ (Map.elems demo.pages) $ \p -> do
      let space = fromMaybe (panic "no space") (find (\s -> s.id == p.space) spaces)
          spacePath = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) space.id)
          pagePath = fromMaybe [] (pathOf (`Map.lookup` demo.pages) p.id)
          siblings = filter (\q -> q.space == p.space) (Map.elems demo.pages)
      for_ (filter (not . T.isPrefixOf "<") (linkTargets p.body)) $ \t -> case classifyDestination t of
        ToPath _ -> (p.title, t, isJust (resolvePageLink spaces spacePath siblings pagePath t)) `shouldBe` (p.title, t, True)
        _ -> pass

-- | The targets of the Markdown links and images in a body, and of its wiki
-- links, but for @[[toc]]@, which is where the page's table of contents
-- goes rather than a link, and a block spoiler's markers, @[[spoiler]]@
-- and @[[/spoiler]]@.
linkTargets :: Text -> [Text]
linkTargets body =
  map (T.takeWhile (/= ')')) (drop 1 (T.splitOn "](" body))
    <> filter (\t -> T.toLower t `notElem` ["toc", "spoiler", "/spoiler"]) (map (T.takeWhile (`notElem` ['|', ']'])) (drop 1 (T.splitOn "[[" body)))
