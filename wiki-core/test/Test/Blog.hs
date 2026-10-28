-- | A space shown as a blog ("Wiki.Core.Blog"): which pages are its posts
-- and in what order, their pages of ten, their neighbours, and the
-- excerpt each is listed with.
module Test.Blog (spec) where

import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (chooseInt, forAll, listOf)
import Wiki.Core.Blog
import Wiki.Core.Id
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (PageSummary (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

day :: Int -> UTCTime
day n = addUTCTime (fromIntegral n * 86400) (UTCTime (fromGregorian 2026 1 1) 0)

-- | A page of the space @s@: id, its parent's id, the day it was made.
page :: Text -> Maybe Text -> Int -> PageSummary
page i parent made =
  PageSummary
    { id = PageId i
    , space = SpaceId "s"
    , parent = PageId <$> parent
    , title = "Title " <> i
    , slug = slug i
    , createdAt = day made
    , updatedAt = day 100
    , position = 0
    , template = False
    }

blogSpace :: Maybe Text -> Space
blogSpace home =
  Space
    { id = SpaceId "s"
    , name = "Blog"
    , slug = slug "blog"
    , parent = Nothing
    , public = True
    , mathMacros = ""
    , createdAt = day 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = PageId <$> home
    , icon = Nothing
    , description = ""
    , blog = True
    }

ids :: [PageSummary] -> [Text]
ids = map (\p -> p.id.text)

spec :: Spec
spec = describe "Wiki.Core.Blog" $ do
  let pages =
        [ page "about" Nothing 1
        , page "first" Nothing 2
        , page "third" Nothing 9
        , page "second" Nothing 5
        , page "notes" (Just "second") 6
        ]

  describe "posts" $ do
    it "are the top-level pages but the home page, the newest first by when each was made" $
      ids (posts (blogSpace (Just "about")) pages) `shouldBe` ["third", "second", "first"]
    it "take the home page in when there is none, whatever order the space lists its pages in" $ do
      ids (posts (blogSpace Nothing) pages) `shouldBe` ["third", "second", "first", "about"]
      ids (posts (blogSpace Nothing) {pageOrder = OldestFirst} pages) `shouldBe` ["third", "second", "first", "about"]
    it "leave a page under a post out" $
      isPost (blogSpace Nothing) (page "notes" (Just "second") 6) `shouldBe` False
    it "take two made at once by title" $
      ids (posts (blogSpace Nothing) [(page "b" Nothing 3) {title = "Beta"}, (page "a" Nothing 3) {title = "Alpha"}])
        `shouldBe` ["a", "b"]

  describe "neighbours" $ do
    let space = blogSpace (Just "about")
    it "are the older post and the newer one" $ do
      neighbours space pages (PageId "second")
        `shouldBe` Just Neighbours {older = Just (page "first" Nothing 2), newer = Just (page "third" Nothing 9)}
      neighbours space pages (PageId "third") `shouldBe` Just Neighbours {older = Just (page "second" Nothing 5), newer = Nothing}
      neighbours space pages (PageId "first") `shouldBe` Just Neighbours {older = Nothing, newer = Just (page "second" Nothing 5)}
    it "are none for a page that is no post" $ do
      neighbours space pages (PageId "about") `shouldBe` Nothing
      neighbours space pages (PageId "notes") `shouldBe` Nothing

  describe "pages of posts" $ do
    it "hold ten posts each" $ do
      onPage 1 [1 .. 25 :: Int] `shouldBe` (1, [1 .. 10])
      onPage 3 [1 .. 25 :: Int] `shouldBe` (3, [21 .. 25])
      pageCount 25 `shouldBe` 3
      pageCount 20 `shouldBe` 2
      pageCount 0 `shouldBe` 1
    it "bring a number outside them to the nearest" $ do
      onPage 0 [1 .. 25 :: Int] `shouldBe` (1, [1 .. 10])
      onPage 9 [1 .. 25 :: Int] `shouldBe` (3, [21 .. 25])
      onPage 2 ([] :: [Int]) `shouldBe` (1, [])
    prop "show every post once, in order, across the pages" $
      forAll (listOf (chooseInt (0, 100))) $ \xs ->
        concat [snd (onPage n xs) | n <- [1 .. pageCount (length xs)]] `shouldBe` xs

  describe "excerpt" $ do
    it "is the first paragraph's text, without its markup" $
      excerptOf "# Title\n\nSome *emphasis*, a [link](elsewhere) and `code` here.\n\nThe second paragraph."
        `shouldBe` "Some emphasis, a link and here."
    it "skips images, code blocks, lists and paragraphs with no text" $
      excerptOf "![a picture](tree.png)\n\n```haskell\nmain = pure ()\n```\n\n- an item\n\nThe text at last,\nover two lines."
        `shouldBe` "The text at last, over two lines."
    it "keeps a formula as its TeX, and leaves footnote marks out" $
      excerptOf "For every $n$ there is one.[^1]\n\n[^1]: A note." `shouldBe` "For every n there is one."
    it "is cut on a word, with an ellipsis, at 300 characters" $ do
      let long = T.unwords (replicate 100 "word")
          cut = excerptOf long
      T.length cut `shouldSatisfy` (<= maxExcerpt)
      cut `shouldSatisfy` T.isSuffixOf "word…"
      T.dropEnd 1 cut `shouldSatisfy` (`T.isPrefixOf` long)
    it "is cut where the room ends for a word longer than it" $
      T.length (excerptOf (T.replicate 400 "x")) `shouldBe` maxExcerpt
    it "is empty for a page with no paragraph" $
      excerptOf "# Only a title" `shouldBe` ""

  describe "firstImage" $
    it "is the destination of the first image, wherever it is" $ do
      (firstImage =<< rightToMaybe (parseMarkdown "Text.\n\n> ![one](attachment:one.png)\n\n![two](two.png)")) `shouldBe` Just "attachment:one.png"
      (firstImage =<< rightToMaybe (parseMarkdown "No pictures.")) `shouldBe` Nothing
