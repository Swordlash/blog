-- | The wiki's guide ("Wiki.App.Guide"): the space a server installs, with
-- the server's tour, and the same pages in the demo's Docs, with the
-- demo's own tour. Every page parses, every link between them leads to a
-- page of the guide, and the Markdown guide shows the boxes
-- ("Wiki.Core.Markdown.Box"): the five kinds, one of its own and a title.
module Test.Guide (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Guide
import Wiki.App.Route qualified as Route
import Wiki.Core.Attachment (Attachment (..), FileName (..))
import Wiki.Core.Markdown.Ast (Block (..), parseMarkdown)
import Wiki.Core.Markdown.Box (AlertKind (..), BoxKind (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, pathOf, resolvePath)
import Wiki.Core.Space (Space (..), SpaceProfile (..))

guide :: MemState
guide = guideState (UTCTime (fromGregorian 2026 10 29) 0)

pages :: [Page]
pages = Map.elems guide.pages

titled :: MemState -> Text -> Maybe Page
titled st t = find (\p -> p.title == t) (Map.elems st.pages)

-- | The targets of the Markdown links and images in a body.
linkTargets :: Text -> [Text]
linkTargets body = map (T.takeWhile (/= ')')) (drop 1 (T.splitOn "](" body))

-- | Every box of a document, nested ones too, with its kind and title.
boxes :: [Block] -> [(AlertKind, Maybe Text)]
boxes = concatMap $ \case
  Alert kind title bs -> (kind, title) : boxes bs
  BlockQuote bs -> boxes bs
  Div _ bs -> boxes bs
  _ -> []

spec :: Spec
spec = describe "Wiki.App.Guide" $ do
  it "is one public space, Guide, that opens at the server's tour" $ do
    [(s.name, s.public) | s <- Map.elems guide.spaces] `shouldBe` [("Guide", True)]
    let tour = titled guide "Tour"
    [s.homePage | s <- Map.elems guide.spaces] `shouldBe` [(\p -> p.id) <$> tour]
    sort (map (\p -> p.title) pages) `shouldBe` sort ["Tour", "Markdown guide", "Diagrams", "Mathematics", "Presentations"]

  it "has every page parse, and attaches what the Markdown guide shows" $ do
    for_ pages $ \p -> (p.title, isRight (parseMarkdown p.body)) `shouldBe` (p.title, True)
    (map (\a -> a.name.text) . (\p -> p.attachments) <$> titled guide "Markdown guide") `shouldBe` Just ["tree.png", "earth.jpg"]

  it "links its pages to pages of the guide only" $ do
    let internal t = not (any (`T.isPrefixOf` t) ["https://", "http://", "attachment:", "<", "#"])
        links = [(p, t) | p <- pages, t <- linkTargets p.body, internal t]
        spaces = Map.elems guide.spaces
        pathIn p = fromMaybe [] (pathOf (`Map.lookup` guide.pages) p.id)
    links `shouldSatisfy` (not . null)
    for_ links $ \(p, t) -> do
      let found = case Route.resolvePageLink spaces [s.slug | s <- spaces] pages (pathIn p) t of
            Just (Route.PageLink (Route.Page _ target) _) -> isRight (resolvePath (findChild pages) target)
            _ -> False
      ((p.title, t), found) `shouldBe` ((p.title, t), True)

  it "has a server's tour that links the Markdown guide and says where the administration is" $ do
    let body = maybe "" (\p -> p.body) (titled guide "Tour")
    linkTargets body `shouldSatisfy` elem "markdown-guide"
    body `shouldSatisfy` T.isInfixOf "**Administration** link at the top right"
    body `shouldSatisfy` T.isInfixOf "Sign in"
    body `shouldNotSatisfy` T.isInfixOf "Reset the demo"

  it "is in the demo's Docs, with the demo's own tour" $ do
    let demo = demoState demoNow
        docs = find (\s -> s.name == "Docs") (Map.elems demo.spaces)
        tour = titled demo "Tour"
    (\p -> p.space) <$> tour `shouldBe` (\s -> s.id) <$> docs
    maybe "" (\p -> p.body) tour `shouldSatisfy` T.isInfixOf "Reset the demo"
    (\s -> s.homePage) <$> docs `shouldBe` Just ((\p -> p.id) <$> tour)
    for_ ["Markdown guide", "Diagrams", "Mathematics", "Presentations"] $ \t ->
      ((\p -> p.body) <$> titled demo t) `shouldBe` ((\p -> p.body) <$> titled guide t)
    (\s -> (guideProfile (maybe (panic "no tour") (\p -> p.id) tour)).description == s.description) <$> docs `shouldBe` Just True

  it "shows the boxes in the Markdown guide: the five, a kind of its own and a title" $ do
    let shown = either (const []) boxes . parseMarkdown . (\p -> p.body) =<< maybeToList (titled guide "Markdown guide")
    for_ [Note, Tip, Important, Warning, Caution, Custom "exercise"] $ \k ->
      (k, k `elem` map fst shown) `shouldBe` (k, True)
    shown `shouldSatisfy` elem (Custom "exercise", Just "Exercise 2")

  it "has the demo define the kind of box the Markdown guide shows" $ do
    (demoState demoNow).server.boxes `shouldBe` [exerciseBox]
    exerciseBox.name `shouldBe` "exercise"
