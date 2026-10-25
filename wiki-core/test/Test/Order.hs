-- | The order a space lists its children in ("Wiki.Core.Order"): natural
-- order of names, each mode, the tree as one list, and positions moved by
-- hand.
module Test.Order (spec) where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Gen (genSpace)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, forAll, listOf, shuffle, (===))
import Wiki.Core.Id
import Wiki.Core.Order
import Wiki.Core.Page (Page (..), childPages, pageTreeOrder, positionPage)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..), spaceTreeOrder, subspaceOrderOf, subspacesOf)

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

-- | A time some days after a fixed one.
day :: Int -> UTCTime
day n = addUTCTime (fromIntegral n * 86400) (UTCTime (fromGregorian 2026 1 1) 0)

-- | A page: id, title, its parent's id, the day it was made, its position.
page :: Text -> Text -> Maybe Text -> Int -> Int -> Page
page i title parent made position =
  Page
    { id = PageId i
    , space = SpaceId "s"
    , parent = PageId <$> parent
    , title
    , slug = slug i
    , body = ""
    , attachments = []
    , createdAt = day made
    , updatedAt = day made
    , position
    }

-- | A space: id, name, its parent's id, the day it was made, its position,
-- and the order of its subspaces.
space :: Text -> Text -> Maybe Text -> Int -> Int -> ChildOrder -> Space
space i name parent made position subspaceOrder =
  Space
    { id = SpaceId i
    , name
    , slug = slug i
    , parent = SpaceId <$> parent
    , public = False
    , mathMacros = ""
    , createdAt = day made
    , position
    , subspaceOrder
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    }

titles :: [Page] -> [Text]
titles = map (\p -> p.title)

names :: [Space] -> [Text]
names = map (\s -> s.name)

sortedNaturally :: [Text] -> [Text]
sortedNaturally = sortBy naturalCompare

spec :: Spec
spec = describe "Wiki.Core.Order" $ do
  describe "natural order" $ do
    it "compares a run of digits as the number it writes" $ do
      sortedNaturally ["a11", "a2", "a1"] `shouldBe` ["a1", "a2", "a11"]
      sortedNaturally ["Part 10", "Part 9", "Part 100", "Part 1"] `shouldBe` ["Part 1", "Part 9", "Part 10", "Part 100"]
      naturalCompare "2" "11" `shouldBe` LT

    it "compares numbers in every place of the name, not only the first" $
      sortedNaturally ["v1.10", "v1.9", "v1.2", "v0.12"] `shouldBe` ["v0.12", "v1.2", "v1.9", "v1.10"]

    it "compares numbers longer than any machine integer" $
      naturalCompare "x123456789012345678901234567890" "x99999999999999999999999999999" `shouldBe` GT

    it "ignores case, but for a tie" $ do
      sortedNaturally ["beta", "Alpha", "gamma", "Beta"] `shouldBe` ["Alpha", "Beta", "beta", "gamma"]
      naturalCompare "Alpha" "alpha" `shouldNotBe` EQ

    it "takes a number with leading zeros as the number, fewer zeros first" $ do
      sortedNaturally ["a010", "a9", "a07", "a7"] `shouldBe` ["a7", "a07", "a9", "a010"]
      naturalCompare "007" "7" `shouldBe` GT

    it "puts digits before letters" $
      sortedNaturally ["b", "1", "a"] `shouldBe` ["1", "a", "b"]

    it "is equal only for the same name" $ do
      naturalCompare "chapter 2" "chapter 2" `shouldBe` EQ
      naturalCompare "chapter 2" "chapter 02" `shouldNotBe` EQ

    prop "is a total order: sorting does not depend on the order it starts from" $
      forAll (listOf genName) $ \xs ->
        forAll (shuffle xs) $ \ys -> sortedNaturally xs === sortedNaturally ys

  describe "siblings" $ do
    let pages =
          [ page "p1" "Part 11" Nothing 3 0
          , page "p2" "Part 2" Nothing 1 2
          , page "p3" "part 1" Nothing 2 1
          ]
    it "by name, in natural order" $
      titles (orderSiblings ByName pages) `shouldBe` ["part 1", "Part 2", "Part 11"]

    it "by date, the newest first" $
      titles (orderSiblings NewestFirst pages) `shouldBe` ["Part 11", "part 1", "Part 2"]

    it "by date, the oldest first" $
      titles (orderSiblings OldestFirst pages) `shouldBe` ["Part 2", "part 1", "Part 11"]

    it "by hand, by position" $
      titles (orderSiblings ByHand pages) `shouldBe` ["Part 11", "part 1", "Part 2"]

    it "breaks a tie of dates or positions by name, then by slug" $ do
      let tied = [page "z" "B" Nothing 1 0, page "y" "A" Nothing 1 0, page "x" "A" Nothing 1 0]
      for_ [minBound .. maxBound] $ \order ->
        map (\p -> p.id) (orderSiblings order tied) `shouldBe` map PageId ["x", "y", "z"]

    prop "orders the same whatever order they come in, and ordering twice is ordering once" $
      forAll (listOf genSpace) $ \spaces -> forAll (elements [minBound .. maxBound]) $ \order ->
        forAll (shuffle spaces) $ \shuffled ->
          (orderSiblings order shuffled, orderSiblings order (orderSiblings order spaces)) === (orderSiblings order spaces, orderSiblings order spaces)

  describe "a tree" $ do
    let spaces =
          [ space "t" "Team" Nothing 1 0 NewestFirst
          , space "b" "Blog" Nothing 5 0 ByName
          , space "old" "Old" (Just "t") 1 0 ByName
          , space "new" "New" (Just "t") 4 0 ByHand
          , space "n2" "Second" (Just "new") 1 0 ByName
          , space "n1" "First" (Just "new") 2 1 ByName
          , space "n0" "Zeroth" (Just "new") 3 (-1) ByName
          ]
    it "lists the top-level spaces by name: nothing chooses their order" $ do
      subspaceOrderOf spaces Nothing `shouldBe` ByName
      names (subspacesOf spaces Nothing) `shouldBe` ["Blog", "Team"]

    it "lists a space's subspaces in its order" $ do
      names (subspacesOf spaces (Just (SpaceId "t"))) `shouldBe` ["New", "Old"]
      names (subspacesOf spaces (Just (SpaceId "new"))) `shouldBe` ["Zeroth", "Second", "First"]

    it "is one list, each space followed by its subspaces in its order" $
      names (spaceTreeOrder spaces) `shouldBe` ["Blog", "Team", "New", "Zeroth", "Second", "First", "Old"]

    it "takes a space whose parent is not listed as a top-level one" $
      names (spaceTreeOrder (drop 1 spaces)) `shouldBe` ["Blog", "New", "Zeroth", "Second", "First", "Old"]

    it "orders the pages under each page in the space's page order" $ do
      let pages =
            [ page "a" "A 10" Nothing 1 0
            , page "b" "A 9" Nothing 2 0
            , page "c" "C" (Just "a") 1 0
            , page "d" "B" (Just "a") 2 0
            ]
      titles (childPages ByName pages (Just (PageId "a"))) `shouldBe` ["B", "C"]
      titles (pageTreeOrder ByName pages) `shouldBe` ["A 9", "A 10", "B", "C"]
      titles (pageTreeOrder NewestFirst pages) `shouldBe` ["A 9", "A 10", "B", "C"]
      titles (pageTreeOrder OldestFirst pages) `shouldBe` ["A 10", "C", "B", "A 9"]

  describe "positions, by hand" $ do
    let xs = ["a", "b", "c", "d"] :: [Text]
        moved how k = reposition identity how k xs
    it "move one up and down" $ do
      moved ShiftUp "c" `shouldBe` ["a", "c", "b", "d"]
      moved ShiftDown "b" `shouldBe` ["a", "c", "b", "d"]

    it "move one to the top and the bottom" $ do
      moved ShiftToTop "c" `shouldBe` ["c", "a", "b", "d"]
      moved ShiftToBottom "b" `shouldBe` ["a", "c", "d", "b"]

    it "leave the siblings as they are at either end, or for one that is not there" $ do
      moved ShiftUp "a" `shouldBe` xs
      moved ShiftToTop "a" `shouldBe` xs
      moved ShiftDown "d" `shouldBe` xs
      moved ShiftToBottom "d" `shouldBe` xs
      moved ShiftUp "z" `shouldBe` xs

    prop "keep every sibling, once" $
      forAll (elements [minBound .. maxBound]) $ \how -> forAll (elements xs) $ \k ->
        sort (moved how k) === sort xs

    it "are numbered from 0 in the order given" $
      renumber identity ["c", "a", "b" :: Text] `shouldBe` Map.fromList [("c", 0), ("a", 1), ("b", 2)]

    it "put a new child after its siblings" $ do
      nextPosition ([] :: [Page]) `shouldBe` 0
      nextPosition [page "a" "A" Nothing 1 4, page "b" "B" Nothing 1 1] `shouldBe` 5

    it "of moved siblings, renumbered, order them as moved" $ do
      let pages = [page "a" "A" Nothing 1 0, page "b" "B" Nothing 1 0, page "c" "C" Nothing 1 0]
          shown = orderSiblings ByHand pages
          numbers = renumber (\p -> p.id) (reposition (\p -> p.id) ShiftUp (PageId "c") shown)
          renumbered = [positionPage (Map.findWithDefault 0 p.id numbers) p | p <- pages]
      titles (orderSiblings ByHand renumbered) `shouldBe` ["A", "C", "B"]
  where
    genName :: Gen Text
    genName = do
      n <- chooseInt (0, 4)
      toS . concat <$> replicateM n (elements ["a", "B", "b", "0", "1", "01", "2", "10", " ", "x"])
