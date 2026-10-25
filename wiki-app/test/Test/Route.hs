-- | The routes' addresses: each route reads back from the address it is
-- written as, and the addresses are the ones the plan names.
module Test.Route (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
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
genSlug = slug <$> elements ["docs", "team", "p", "edit", "source", "history", "slides", "new-page", "new-space", "s", "not-found", "admin", "a-b", "x1"]

genPath :: Gen [Slug]
genPath = chooseInt (1, 4) >>= (`vectorOf` genSlug)

genRoute :: Gen Route
genRoute =
  oneof
    [ pure Home
    , Space <$> genPath
    , Page <$> genPath <*> genPath
    , EditPage <$> genPath <*> genPath
    , PageSource <$> genPath <*> genPath
    , NewSpace <$> oneof [pure Nothing, Just <$> genPath]
    , pure Unknown
    , NewPage <$> genPath <*> oneof [pure Nothing, Just <$> genPath]
    , Search
        <$> oneof [pure Nothing, Just <$> elements ["mermaid", "mermaid flow", "", "a&b=c", "100% ?#/", "zażółć", "+x+"]]
        <*> oneof [pure Nothing, pure (Just []), Just <$> genPath]
        <*> elements [False, True]
    , pure Admin
    , PageHistory
        <$> genPath
        <*> genPath
        <*> oneof [pure Nothing, Just <$> elements [demoTime, addUTCTime 0.000123456789 demoTime, addUTCTime 86399.5 demoTime]]
        <*> elements [AgainstPrevious, AgainstCurrent]
    , PageSlides <$> genPath <*> genPath <*> oneof [pure 1, chooseInt (-3, 40)]
    ]

-- | A time with no fraction of a second: the others are made from it.
demoTime :: UTCTime
demoTime = UTCTime (fromGregorian 2026 10 24) 34212

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
      print route (PageSource (slugs ["docs"]) (slugs ["tour"])) `shouldBe` "/s/docs/p/tour/source/"
      print route (PageSource (slugs ["docs"]) (slugs ["markdown-guide", "diagrams"])) `shouldBe` "/s/docs/p/markdown-guide/diagrams/source/"
      print route (NewSpace Nothing) `shouldBe` "/new-space/"
      print route (NewSpace (Just (slugs ["team"]))) `shouldBe` "/new-space/team/"
      print route Unknown `shouldBe` "/not-found/"
      print route Admin `shouldBe` "/admin/"
      print route (NewPage (slugs ["docs"]) Nothing) `shouldBe` "/s/docs/new-page/"
      print route (NewPage (slugs ["team", "projects"]) (Just (slugs ["the-wiki"]))) `shouldBe` "/s/team/projects/new-page/the-wiki/"
      print route (Search Nothing Nothing True) `shouldBe` "/search/"
      print route (Search (Just "mermaid flow") (Just (slugs ["team", "projects"])) True)
        `shouldBe` "/search/?q=mermaid%20flow&space=team%2Fprojects"
      print route (Search (Just "x") (Just (slugs ["team"])) False) `shouldBe` "/search/?q=x&space=team&only"

    it "escapes a slug that is one of its words" $ do
      print route (Space (slugs ["p"])) `shouldBe` "/s/~p/"
      print route (Page (slugs ["a"]) (slugs ["b", "edit"])) `shouldBe` "/s/a/p/b/~edit/"
      parse route "/s/a/p/b/edit/" `shouldBe` Right (EditPage (slugs ["a"]) (slugs ["b"]))
      print route (Space (slugs ["new-page"])) `shouldBe` "/s/~new-page/"
      parse route "/s/new-page/" `shouldSatisfy` isLeft
      parse route "/s/a/new-page/b/" `shouldBe` Right (NewPage (slugs ["a"]) (Just (slugs ["b"])))

    it "keeps a page called source apart from a page's source" $ do
      print route (Page (slugs ["a"]) (slugs ["source"])) `shouldBe` "/s/a/p/~source/"
      print route (Page (slugs ["a"]) (slugs ["b", "source"])) `shouldBe` "/s/a/p/b/~source/"
      print route (PageSource (slugs ["a"]) (slugs ["source"])) `shouldBe` "/s/a/p/~source/source/"
      print route (Space (slugs ["source"])) `shouldBe` "/s/~source/"
      parse route "/s/a/p/b/source/" `shouldBe` Right (PageSource (slugs ["a"]) (slugs ["b"]))
      parse route "/s/a/p/b/~source/" `shouldBe` Right (Page (slugs ["a"]) (slugs ["b", "source"]))
      parse route "/s/a/p/~source/source/" `shouldBe` Right (PageSource (slugs ["a"]) (slugs ["source"]))
      parse route "/s/a/p/b/source/edit/" `shouldSatisfy` isLeft
      parse route "/s/a/p/source/" `shouldSatisfy` isLeft

    it "writes a page's history, with the version and what it is compared with as parameters" $ do
      print route (PageHistory (slugs ["docs"]) (slugs ["tour"]) Nothing AgainstPrevious) `shouldBe` "/s/docs/p/tour/history/"
      print route (PageHistory (slugs ["docs"]) (slugs ["tour"]) (Just (addUTCTime 0.5 demoTime)) AgainstCurrent)
        `shouldBe` "/s/docs/p/tour/history/?version=2026-10-24T09%3A30%3A12.5Z&against=current"
      print route (Page (slugs ["a"]) (slugs ["history"])) `shouldBe` "/s/a/p/~history/"
      parse route "/s/a/p/~history/history/" `shouldBe` Right (PageHistory (slugs ["a"]) (slugs ["history"]) Nothing AgainstPrevious)
      parse route "/s/a/p/history/" `shouldSatisfy` isLeft
      -- A version that is not a time is the latest, and a comparison that
      -- is not the current version's is with the version before.
      parse route "/s/a/p/b/history/?version=yesterday&against=tomorrow" `shouldBe` Right (PageHistory (slugs ["a"]) (slugs ["b"]) Nothing AgainstPrevious)
      parse route "/s/a/p/b/history" `shouldBe` Right (PageHistory (slugs ["a"]) (slugs ["b"]) Nothing AgainstPrevious)

    it "writes a page's slides, with the slide shown as a parameter unless it is the first" $ do
      print route (PageSlides (slugs ["docs"]) (slugs ["presentations"]) 1) `shouldBe` "/s/docs/p/presentations/slides/"
      print route (PageSlides (slugs ["docs"]) (slugs ["presentations"]) 3) `shouldBe` "/s/docs/p/presentations/slides/?slide=3"
      parse route "/s/docs/p/presentations/slides" `shouldBe` Right (PageSlides (slugs ["docs"]) (slugs ["presentations"]) 1)
      parse route "/s/docs/p/presentations/slides/?slide=12" `shouldBe` Right (PageSlides (slugs ["docs"]) (slugs ["presentations"]) 12)
      print route (Page (slugs ["a"]) (slugs ["slides"])) `shouldBe` "/s/a/p/~slides/"
      parse route "/s/a/p/~slides/slides/" `shouldBe` Right (PageSlides (slugs ["a"]) (slugs ["slides"]) 1)
      parse route "/s/a/p/slides/" `shouldSatisfy` isLeft
      -- A slide that is not a number is the first; one beyond the deck is
      -- the view's to bring back into it.
      parse route "/s/a/p/b/slides/?slide=last" `shouldBe` Right (PageSlides (slugs ["a"]) (slugs ["b"]) 1)
      parse route "/s/a/p/b/slides/?slide=99" `shouldBe` Right (PageSlides (slugs ["a"]) (slugs ["b"]) 99)

    it "reads an address without its last slash too" $ do
      parse route "/s/docs" `shouldBe` Right (Space (slugs ["docs"]))
      parse route "/s/docs/p/tour" `shouldBe` Right (Page (slugs ["docs"]) (slugs ["tour"]))
      parse route "/s/docs/p/tour/source" `shouldBe` Right (PageSource (slugs ["docs"]) (slugs ["tour"]))
      parse route "/new-space" `shouldBe` Right (NewSpace Nothing)
      parse route "/search?q=x" `shouldBe` Right (Search (Just "x") Nothing True)
      parse route "/s/docs/new-page" `shouldBe` Right (NewPage (slugs ["docs"]) Nothing)
      parse route "/admin" `shouldBe` Right Admin

    it "keeps a space called admin apart from the administration" $ do
      print route (Space (slugs ["admin"])) `shouldBe` "/s/admin/"
      parse route "/s/admin/" `shouldBe` Right (Space (slugs ["admin"]))
      parse route "/admin/" `shouldBe` Right Admin

    it "reads a search's parameters in any order, and leaves out what is not there" $ do
      parse route "/search/?space=docs&q=a+b" `shouldBe` Right (Search (Just "a+b") (Just (slugs ["docs"])) True)
      parse route "/search/?only&space=docs" `shouldBe` Right (Search Nothing (Just (slugs ["docs"])) False)
      parse route "/search/?q=x&utm_source=elsewhere" `shouldBe` Right (Search (Just "x") Nothing True)

    it "reads a search's space that is not a path as the empty path, which names no space" $ do
      parse route "/search/?q=x&space=Not%20a%20slug" `shouldBe` Right (Search (Just "x") (Just []) True)
      parse route "/search/?q=x&space=" `shouldBe` Right (Search (Just "x") (Just []) True)

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
      routeOfHref router "/wiki/search/?q=x" `shouldBe` Just (Search (Just "x") Nothing True)

    it "leaves everything else alone" $ do
      router <- runMemDOM (Router.newRouter "/wiki/" Unknown route)
      routeOfHref router "/elsewhere/s/docs/" `shouldBe` Nothing
      routeOfHref router "/wikis/s/docs/" `shouldBe` Nothing
      routeOfHref router "#fn-1" `shouldBe` Nothing
      routeOfHref router "https://example.com/wiki/s/docs/" `shouldBe` Nothing
