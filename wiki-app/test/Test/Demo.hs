-- | The demo's content: well-formed, and showing what it says it shows.
module Test.Demo (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, parsePath, pathOf, resolvePath)
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
          , ("a mermaid diagram", "```mermaid")
          , ("an image by URL", "](https://upload.wikimedia.org/wikipedia/commons/thumb/")
          , ("a video by URL", ".webm)")
          , ("an attachment", "](attachment:")
          ]
            :: [(Text, Text)]
    for_ features $ \(feature, marker) ->
      (feature, marker `T.isInfixOf` everything) `shouldBe` (feature, True)

  it "attaches every file a page refers to" $
    for_ pages $ \p ->
      for_ (mapMaybe (T.stripPrefix "attachment:") (linkTargets p.body)) $ \name ->
        ((p.title, name), (\a -> a.name) <$> findAttachment name p.attachments) `shouldBe` ((p.title, name), Just name)

  it "links pages to pages that are there, by their paths from the page" $ do
    let relative t = not (any (`T.isPrefixOf` t) ["https://", "http://", "attachment:", "<", "#"])
        links = [(p, t) | p <- pages, t <- linkTargets p.body, relative t]
    links `shouldSatisfy` (not . null)
    for_ links $ \(p, t) -> case parsePath t of
      Left e -> expectationFailure (show (p.title, t, e))
      Right target -> do
        let resolved = take (length (pagePath p) - 1) (pagePath p) <> target
            inSpace = filter (\q -> q.space == p.space) pages
        ((p.title, t), isRight (resolvePath (findChild inSpace) resolved)) `shouldBe` ((p.title, t), True)
