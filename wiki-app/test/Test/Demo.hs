-- | The demo's content: well-formed, and showing what it says it shows.
module Test.Demo (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route qualified as Route
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, pathOf, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))

demo :: MemState
demo = demoState demoNow

pages :: [Page]
pages = Map.elems demo.pages

-- | A page's path within its space.
pagePath :: Page -> [Slug]
pagePath p = fromMaybe [] (pathOf (`Map.lookup` demo.pages) p.id)

-- | The targets of the Markdown links and images in a body: what is between
-- the parentheses of @](…)@.
linkTargets :: Text -> [Text]
linkTargets body = map (T.takeWhile (/= ')')) (drop 1 (T.splitOn "](" body))

spec :: Spec
spec = describe "Wiki.App.Demo" $ do
  it "has the spaces the tour describes" $
    sort [s.name | s <- Map.elems demo.spaces] `shouldBe` ["Blog", "Docs", "Projects", "Team"]

  it "puts the tour in Docs" $ do
    let docs = find (\s -> s.name == "Docs") (Map.elems demo.spaces)
    [p.title | p <- pages, Just p.space == ((\s -> s.id) <$> docs), p.parent == Nothing] `shouldSatisfy` elem "Tour"

  it "gives every page a path that leads back to it" $
    for_ pages $ \p ->
      case resolvePath (findChild (filter (\q -> q.space == p.space) pages)) (pagePath p) of
        Right chain -> (\q -> q.id) <$> lastMay chain `shouldBe` Just p.id
        Left e -> expectationFailure (show e)

  it "shows every Markdown feature somewhere" $ do
    let everything = T.unlines (map (\p -> p.body) pages)
        features =
          [ ("a heading", "\n## ")
          , ("a list", "\n- ")
          , ("a numbered list", "\n1. ")
          , ("a table", "| --")
          , ("a task list", "- [x] ")
          , ("a footnote", "[^")
          , ("inline code", " `")
          , ("a fence with a language", "```haskell")
          , ("inline math", " $")
          , ("display math", "$$")
          , ("a math fence", "```math")
          , ("an alert", "> [!NOTE]")
          , ("a wiki link", "[[")
          , ("a mermaid diagram", "```mermaid")
          , ("an image by URL", "](https://upload.wikimedia.org/wikipedia/commons/thumb/")
          , ("a video by URL", ".webm)")
          , ("an attachment", "](attachment:")
          ]
            :: [(Text, Text)]
    for_ features $ \(feature, marker) ->
      (feature, marker `T.isInfixOf` everything) `shouldBe` (feature, True)

  it "is Markdown every page of which parses" $
    for_ pages $
      \p -> (p.title, isRight (parseMarkdown p.body)) `shouldBe` (p.title, True)

  it "attaches every file a page refers to" $
    for_ pages $ \p ->
      for_ (mapMaybe (T.stripPrefix "attachment:") (linkTargets p.body)) $ \name ->
        ((p.title, name), (\a -> a.name) <$> findAttachment name p.attachments) `shouldBe` ((p.title, name), Just name)

  it "links pages to spaces and pages that are there, as the application reads the links" $ do
    let internal t = not (any (`T.isPrefixOf` t) ["https://", "http://", "attachment:", "<", "#"])
        links = [(p, t) | p <- pages, t <- linkTargets p.body, internal t]
        spaces = Map.elems demo.spaces
    links `shouldSatisfy` (not . null)
    for_ links $ \(p, t) -> do
      let inSpace sid = filter (\q -> q.space == sid) pages
          target =
            Route.resolvePageLink spaces (spacePath p.space) (inSpace p.space) (pagePath p) t >>= \case
              Route.PageLink (Route.Space path) _ -> void (spaceAt path)
              -- A page in another space is not checked by the link: check
              -- it here.
              Route.PageLink (Route.Page path pagePath') _ -> do
                s <- spaceAt path
                void (rightToMaybe (resolvePath (findChild (inSpace s.id)) pagePath'))
              Route.PageLink _ _ -> Nothing
      ((p.title, t), isJust target) `shouldBe` ((p.title, t), True)

  it "links the tour to every space, and to a page in each public one" $ do
    let tour = find (\p -> p.title == "Tour") pages
        targets = foldMap (\p -> linkTargets p.body) tour
    for_ ["/blog", "/docs", "/team", "/team/projects", "/blog/hello-world", "markdown-guide"] $ \t ->
      (t, t `elem` targets) `shouldBe` (t, True)
  where
    spacePath sid = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) sid)
    spaceAt path = rightToMaybe (resolvePath (findChild (Map.elems demo.spaces)) path) >>= lastMay
