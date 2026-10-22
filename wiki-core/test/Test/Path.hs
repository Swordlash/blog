module Test.Path (spec) where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Gen (genSlugs)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
import Wiki.Core.Id
import Wiki.Core.Page
import Wiki.Core.Path
import Wiki.Core.Slug
import Wiki.Core.Space

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

slugs :: [Text] -> [Slug]
slugs = map slug

space :: Text -> Text -> Maybe Text -> Space
space i s parent = Space {id = SpaceId i, name = s, slug = slug s, parent = SpaceId <$> parent, public = False, mathMacros = ""}

-- | Two trees, with a slug (@backend@) under two parents.
eng, backend, api, blog, blogBackend :: Space
eng = space "1" "eng" Nothing
backend = space "2" "backend" (Just "1")
api = space "3" "api" (Just "2")
blog = space "4" "blog" Nothing
blogBackend = space "5" "backend" (Just "4")

spaces :: [Space]
spaces = [eng, backend, api, blog, blogBackend]

spaceById :: SpaceId -> Maybe Space
spaceById i = Map.lookup i (Map.fromList [(s.id, s) | s <- spaces])

page :: Text -> Text -> Text -> Maybe Text -> Page
page sp i s parent =
  Page
    { id = PageId i
    , space = SpaceId sp
    , parent = PageId <$> parent
    , title = s
    , slug = slug s
    , body = ""
    , attachments = []
    , createdAt = epoch
    , updatedAt = epoch
    }
  where
    epoch = UTCTime (fromGregorian 2026 1 1) 0

-- | Pages in two spaces, with the same paths in both.
pages :: [Page]
pages =
  [ page "1" "p1" "onboarding" Nothing
  , page "1" "p2" "first-week" (Just "p1")
  , page "4" "p3" "onboarding" Nothing
  , page "4" "p4" "first-week" (Just "p3")
  ]

pagesOf :: Space -> [Page]
pagesOf s = filter (\p -> p.space == s.id) pages

spec :: Spec
spec = describe "Path" $ do
  describe "resolvePath" $ do
    let resolve = resolvePath (findChild spaces)
    it "walks from a top-level space down" $
      resolve (slugs ["eng", "backend", "api"]) `shouldBe` Right [eng, backend, api]
    it "tells siblings' children with the same slug apart" $ do
      resolve (slugs ["eng", "backend"]) `shouldBe` Right [eng, backend]
      resolve (slugs ["blog", "backend"]) `shouldBe` Right [blog, blogBackend]
    it "resolves the empty path to no nodes" $
      resolve [] `shouldBe` Right []
    it "reports the first missing slug and what it got through" $
      resolve (slugs ["eng", "frontend", "api"])
        `shouldBe` Left PathError {resolved = [eng], missing = slug "frontend"}
    it "starts at the roots, not anywhere in the tree" $
      resolve (slugs ["backend"]) `shouldBe` Left PathError {resolved = [], missing = slug "backend"}
    it "resolves a page within its space only" $ do
      let resolvePage s = resolvePath (findChild (pagesOf s))
      map (\p -> p.id) <$> resolvePage eng (slugs ["onboarding", "first-week"])
        `shouldBe` Right [PageId "p1", PageId "p2"]
      map (\p -> p.id) <$> resolvePage blog (slugs ["onboarding", "first-week"])
        `shouldBe` Right [PageId "p3", PageId "p4"]
      map (\p -> p.id) <$> resolvePage backend (slugs ["onboarding"])
        `shouldBe` Left PathError {resolved = [], missing = slug "onboarding"}

  describe "resolvePathM" $
    it "asks for one level at a time and stops at the first miss" $ do
      let child parent s = do
            modify (<> [(parent, s)])
            pure (findChild spaces parent s)
          (result, asked) = runState (resolvePathM child (slugs ["eng", "nope", "api"])) []
      result `shouldBe` Left PathError {resolved = [eng], missing = slug "nope"}
      asked `shouldBe` [(Nothing, slug "eng"), (Just eng.id, slug "nope")]

  describe "ancestry" $ do
    it "gives a node and its ancestors, root first" $
      ancestry spaceById api.id `shouldBe` Just [eng, backend, api]
    it "gives a top-level node alone" $
      ancestry spaceById blog.id `shouldBe` Just [blog]
    it "gives nothing for an unknown node" $
      ancestry spaceById (SpaceId "9") `shouldBe` Nothing
    it "gives nothing when an ancestor is missing" $ do
      let orphan = space "6" "orphan" (Just "9")
          byId i = find (\s -> s.id == i) (orphan : spaces)
      ancestry byId orphan.id `shouldBe` Nothing
    it "gives nothing when parents go round in a circle" $ do
      let a = space "a" "a" (Just "b")
          b = space "b" "b" (Just "a")
          byId i = find (\s -> s.id == i) [a, b]
      ancestry byId a.id `shouldBe` Nothing

  describe "pathOf" $ do
    it "is the slugs from the root" $
      pathOf spaceById api.id `shouldBe` Just (slugs ["eng", "backend", "api"])
    it "resolves back to the node's ancestry, for every node" $
      for_ spaces $ \s ->
        (rightToMaybe . resolvePath (findChild spaces) =<< pathOf spaceById s.id)
          `shouldBe` ancestry spaceById s.id

  describe "childrenOf" $ do
    it "lists the roots" $
      childrenOf spaces Nothing `shouldBe` [eng, blog]
    it "lists a node's children" $
      childrenOf spaces (Just eng.id) `shouldBe` [backend]

  describe "as text" $ do
    it "is slugs between slashes" $
      renderPath (slugs ["eng", "backend", "api"]) `shouldBe` "eng/backend/api"
    it "renders the empty path as the empty text" $
      renderPath [] `shouldBe` ""
    it "parses slugs between slashes" $
      parsePath "eng/backend" `shouldBe` Right (slugs ["eng", "backend"])
    it "ignores a slash at either end" $
      parsePath "/eng/backend/" `shouldBe` Right (slugs ["eng", "backend"])
    it "parses the empty text and a lone slash as the empty path" $ do
      parsePath "" `shouldBe` Right []
      parsePath "/" `shouldBe` Right []
    it "refuses an empty segment" $
      parsePath "eng//backend" `shouldBe` Left SlugEmpty
    it "refuses a segment that is not a slug" $
      parsePath "eng/Backend" `shouldBe` Left (SlugBadCharacter 'B')
    prop "parses what it renders" $
      forAll genSlugs $
        \path -> parsePath (renderPath path) === Right path
