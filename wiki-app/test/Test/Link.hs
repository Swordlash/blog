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
import Wiki.Core.Markdown (Destination (..), classifyDestination)
import Wiki.Core.Page (Page (body, id, space, title))
import Wiki.Core.Path (pathOf)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (id, slug))

demo :: MemState
demo = demoState demoNow

slugs :: [Text] -> [Slug]
slugs = map (either (panic . show) identity . mkSlug)

spaces :: [Space]
spaces = Map.elems demo.spaces

-- | Where a destination leads from the page at this path of @docs@.
fromDocs :: [Text] -> Text -> Maybe PageLink
fromDocs page = resolvePageLink spaces (slugs ["docs"]) (pagesOf "docs") (slugs page)

pagesOf :: Text -> [Page]
pagesOf s = [p | p <- Map.elems demo.pages, Just p.space == ((\sp -> sp.id) <$> find (\sp -> sp.slug == mkSlug' s) spaces)]
  where
    mkSlug' = either (panic . show) identity . mkSlug

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
-- goes rather than a link.
linkTargets :: Text -> [Text]
linkTargets body =
  map (T.takeWhile (/= ')')) (drop 1 (T.splitOn "](" body))
    <> filter (\t -> T.toLower t /= "toc") (map (T.takeWhile (`notElem` ['|', ']'])) (drop 1 (T.splitOn "[[" body)))
