-- | The routes' addresses: each route reads back from the address it is
-- written as, and the addresses are the ones the plan names.
module Test.Route (spec) where

import Halogen.Router qualified as Router
import Halogen.Router.Duplex (parse, print)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Protolude hiding (print)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, forAll, oneof, vectorOf, (===))
import Wiki.App.Route
import Wiki.Core.Slug (Slug, mkSlug)

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

slugs :: [Text] -> [Slug]
slugs = map slug

-- | Slugs, the route's own words among them, which have to be escaped.
genSlug :: Gen Slug
genSlug = slug <$> elements ["docs", "team", "p", "edit", "new-page", "new-space", "s", "not-found", "a-b", "x1"]

genPath :: Gen [Slug]
genPath = chooseInt (1, 4) >>= (`vectorOf` genSlug)

genRoute :: Gen Route
genRoute =
  oneof
    [ pure Home
    , Space <$> genPath
    , Page <$> genPath <*> genPath
    , EditPage <$> genPath <*> genPath
    , NewSpace <$> oneof [pure Nothing, Just <$> genPath]
    , pure Unknown
    , NewPage <$> genPath <*> oneof [pure Nothing, Just <$> genPath]
    ]

spec :: Spec
spec = describe "Wiki.App.Route" $ do
  describe "route" $ do
    prop "reads back every route it writes" $
      forAll genRoute $
        \r -> parse route (print route r) === Right r

    it "writes the addresses the plan names, as directories" $ do
      print route Home `shouldBe` "/"
      print route (Space (slugs ["team", "projects"])) `shouldBe` "/s/team/projects/"
      print route (Page (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"])) `shouldBe` "/s/docs/p/markdown-guide/diagrams/"
      print route (EditPage (slugs ["docs"]) (slugs ["tour"])) `shouldBe` "/s/docs/p/tour/edit/"
      print route (NewSpace Nothing) `shouldBe` "/new-space/"
      print route (NewSpace (Just (slugs ["team"]))) `shouldBe` "/new-space/team/"
      print route Unknown `shouldBe` "/not-found/"
      print route (NewPage (slugs ["docs"]) Nothing) `shouldBe` "/s/docs/new-page/"
      print route (NewPage (slugs ["team", "projects"]) (Just (slugs ["the-wiki"]))) `shouldBe` "/s/team/projects/new-page/the-wiki/"

    it "escapes a slug that is one of its words" $ do
      print route (Space (slugs ["p"])) `shouldBe` "/s/~p/"
      print route (Page (slugs ["a"]) (slugs ["b", "edit"])) `shouldBe` "/s/a/p/b/~edit/"
      parse route "/s/a/p/b/edit/" `shouldBe` Right (EditPage (slugs ["a"]) (slugs ["b"]))
      print route (Space (slugs ["new-page"])) `shouldBe` "/s/~new-page/"
      parse route "/s/new-page/" `shouldSatisfy` isLeft
      parse route "/s/a/new-page/b/" `shouldBe` Right (NewPage (slugs ["a"]) (Just (slugs ["b"])))

    it "reads an address without its last slash too" $ do
      parse route "/s/docs" `shouldBe` Right (Space (slugs ["docs"]))
      parse route "/s/docs/p/tour" `shouldBe` Right (Page (slugs ["docs"]) (slugs ["tour"]))
      parse route "/new-space" `shouldBe` Right (NewSpace Nothing)
      parse route "/s/docs/new-page" `shouldBe` Right (NewPage (slugs ["docs"]) Nothing)

    it "reads no route from what is not one" $ do
      parse route "/s/" `shouldSatisfy` isLeft
      parse route "/s/Docs/" `shouldSatisfy` isLeft
      parse route "/s/docs/p/" `shouldSatisfy` isLeft
      parse route "/elsewhere/" `shouldSatisfy` isLeft

  describe "routeOfHref" $ do
    it "reads the router's own addresses, under its base" $ do
      router <- runMemDOM (Router.newRouter "/wiki/" Unknown route)
      Router.href router (Space (slugs ["docs"])) `shouldBe` "/wiki/s/docs/"
      routeOfHref router "/wiki/s/docs/" `shouldBe` Just (Space (slugs ["docs"]))
      routeOfHref router "/wiki/s/docs/p/tour/#who-you-can-be" `shouldBe` Just (Page (slugs ["docs"]) (slugs ["tour"]))
      routeOfHref router "/wiki/" `shouldBe` Just Home

    it "leaves everything else alone" $ do
      router <- runMemDOM (Router.newRouter "/wiki/" Unknown route)
      routeOfHref router "/elsewhere/s/docs/" `shouldBe` Nothing
      routeOfHref router "/wikis/s/docs/" `shouldBe` Nothing
      routeOfHref router "#fn-1" `shouldBe` Nothing
      routeOfHref router "https://example.com/wiki/s/docs/" `shouldBe` Nothing
