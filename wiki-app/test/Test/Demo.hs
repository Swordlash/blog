-- | The demo's content: well-formed, and showing what it says it shows.
module Test.Demo (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Wiki.Api.ServerSettings (ServerSettingsOf (homePage))
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoDatabase, demoNow, demoState)
import Wiki.App.Route qualified as Route
import Wiki.Core.Attachment (Attachment (..), FileName (..), findAttachment)
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Markdown.Render (linkDestinations)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, pathOf, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Space qualified as S

demo :: MemState
demo = demoState demoNow

pages :: [Page]
pages = Map.elems demo.pages

-- | A page's space.
spaceOf :: Page -> Maybe Space
spaceOf p = Map.lookup p.space demo.spaces

-- | A page's path within its space, from under its home page.
pagePath :: Page -> [Slug]
pagePath p = fromMaybe [] (spaceOf p >>= \s -> S.pagePath s (`Map.lookup` demo.pages) p.id)

-- | The destinations of the Markdown links and embeds in a body, as written,
-- as the wiki reads them ('Wiki.Core.Markdown.Render.linkDestinations'):
-- not those in code, which a page shows as examples (the guide's
-- interactive SVG), and nothing of a body that does not parse.
linkTargets :: Text -> [Text]
linkTargets body = either (const []) linkDestinations (parseMarkdown body)

spec :: Spec
spec = describe "Wiki.App.Demo" $ do
  -- IndexedDB is per origin, and the demo on GitHub Pages shares
  -- swordlash.github.io with every other site published there: a name as
  -- plain as "wiki" could be another's.
  it "keeps its wiki in an IndexedDB database named for it" $
    demoDatabase.name `shouldBe` "wiki-demo"

  it "has the spaces the tour describes" $
    sort [s.name | s <- Map.elems demo.spaces, not (Home.isHomeSpace demo.server.homePage s.id)] `shouldBe` ["Blog", "Docs", "Projects", "Team"]

  it "puts the tour in Docs, as its home page and the root of its pages" $ do
    let docs = find (\s -> s.name == "Docs") (Map.elems demo.spaces)
    [p.title | p <- pages, Just p.space == ((\s -> s.id) <$> docs), p.parent == Nothing] `shouldBe` ["Tour"]

  it "has one page with no parent in each space, its home page" $
    for_ (Map.elems demo.spaces) $ \s ->
      (s.name, [Just p.id | p <- pages, p.space == s.id, isNothing p.parent]) `shouldBe` (s.name, [S.rootPage s | S.hasHome s])

  it "gives every page a path that leads back to it" $
    for_ pages $ \p -> case spaceOf p of
      Nothing -> expectationFailure ("no space for " <> show p.title)
      Just s -> case S.pagesAt s (filter (\q -> q.space == p.space) pages) (pagePath p) of
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
          , ("a latex fence", "```latex")
          , ("an html fence", "```html\n<style>")
          , ("a fence kept a listing", "{.norender}")
          , ("an alert", "> [!NOTE]")
          , ("a wiki link", "[[")
          , ("a mermaid diagram", "```mermaid")
          , ("a TikZ picture", "```tikz")
          , ("a TikZ library loaded", "\\usetikzlibrary{")
          , ("a table of contents", "\n[[!toc]]\n")
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
        ((p.title, name), (\a -> a.name.text) <$> findAttachment name p.attachments) `shouldBe` ((p.title, name), Just name)

  it "links pages to spaces and pages that are there, as the application reads the links" $ do
    let internal t = not (any (`T.isPrefixOf` t) ["https://", "http://", "attachment:", "<", "#"])
        links = [(p, t) | p <- pages, t <- linkTargets p.body, internal t]
        spaces = Map.elems demo.spaces
    links `shouldSatisfy` (not . null)
    for_ links $ \(p, t) -> do
      let inSpace sid = filter (\q -> q.space == sid) pages
          target =
            Route.resolvePageLink spaces (spacePath p.space) (S.rootPage =<< spaceOf p) (inSpace p.space) (pagePath p) t >>= \case
              Route.PageLink (Route.Space path) _ -> void (spaceAt path)
              -- A page in another space is not checked by the link: check
              -- it here.
              Route.PageLink (Route.Page path pagePath') _ -> do
                s <- spaceAt path
                void (S.pageAt s (inSpace s.id) pagePath')
              Route.PageLink _ _ -> Nothing
      ((p.title, t), isJust target) `shouldBe` ((p.title, t), True)

  -- Not to the private ones: someone not signed in, who reads the tour
  -- first, would see those links as broken.
  it "links the tour to the public spaces, and to a page in each" $ do
    let tour = find (\p -> p.title == "Tour") pages
        targets = foldMap (\p -> linkTargets p.body) tour
    targets `shouldSatisfy` all (\t -> not ("/team" `T.isPrefixOf` t))
    for_ ["/blog", "/docs", "/blog/hello-world", "markdown-guide"] $ \t ->
      (t, t `elem` targets) `shouldBe` (t, True)
  where
    spacePath sid = fromMaybe [] (pathOf (`Map.lookup` demo.spaces) sid)
    spaceAt path = rightToMaybe (resolvePath (findChild (Map.elems demo.spaces)) path) >>= lastMay
