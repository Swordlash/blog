module Test.Diff (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, elements, forAll, listOf, vectorOf, (===))
import Wiki.Core.Diff

-- | Texts of a few lines over a small alphabet, so that two of them have
-- lines and words in common, empty lines and a final line break included.
text :: Gen Text
text = do
  ls <- listOf line
  end <- elements ["", "\n"]
  pure (T.intercalate "\n" ls <> if null ls then "" else end)
  where
    line = T.unwords <$> listOf (elements ["a", "b", "c", "a,", "(b)", ""])

-- | A text and the same with one word replaced.
oneWordChanged :: Gen (Text, Text, Text, Text)
oneWordChanged = do
  front <- vectorOf 3 word
  back <- vectorOf 3 word
  here <- elements ["alpha", "beta"]
  there <- elements ["gamma", "delta"]
  let line w = T.unwords (front <> [w] <> back)
  others <- listOf (T.unwords <$> vectorOf 2 word)
  pure (T.unlines (others <> [line here] <> others), T.unlines (others <> [line there] <> others), here, there)
  where
    word = elements ["x", "y", "z"]

changedParts :: LineKind -> Diff -> [Text]
changedParts kind d = [s.text | l <- d.rows, l.kind == kind, s <- l.segments, s.changed]

spec :: Spec
spec = describe "Wiki.Core.Diff" $ do
  prop "has both texts' lines in it, each in its order" $
    forAll text $ \a -> forAll text $ \b ->
      let d = diffText a b in (oldSide d, newSide d) === (splitLines a, splitLines b)

  prop "numbers the lines of each side from 1, in order" $
    forAll text $ \a -> forAll text $ \b ->
      let d = diffText a b
       in (mapMaybe (\l -> l.old) d.rows, mapMaybe (\l -> l.new) d.rows) === ([1 .. length (splitLines a)], [1 .. length (splitLines b)])

  prop "finds no change between a text and itself" $
    forAll text $ \a -> let d = diffText a a in (unchanged d, d.gaveUp) === (True, False)

  prop "keeps as many lines as the longest sequence the texts have in common" $
    forAll text $ \a -> forAll text $ \b ->
      let kept = length [l | l <- (diffText a b).rows, l.kind == Unchanged]
       in kept === lcsLength (splitLines a) (splitLines b)

  prop "marks only the word that changed in a line" $
    forAll oneWordChanged $ \(a, b, here, there) ->
      let d = diffText a b in (changedParts Removed d, changedParts Added d) === ([here], [there])

  it "takes lines out before it puts the ones in their place" $
    map (\l -> (l.kind, l.old, l.new)) (diffText "a\nb\nc\n" "a\nB\nc\nd\n").rows
      `shouldBe` [ (Unchanged, Just 1, Just 1)
                 , (Removed, Just 2, Nothing)
                 , (Added, Nothing, Just 2)
                 , (Unchanged, Just 3, Just 3)
                 , (Added, Nothing, Just 4)
                 ]

  it "changes two lines with no word in common whole" $ do
    let d = diffText "one two\n" "three four\n"
    map (\l -> l.segments) d.rows
      `shouldBe` [[Segment True "one two"], [Segment True "three four"]]

  it "marks a word in a long paragraph, and keeps the rest of it" $ do
    let paragraph w = T.unwords (replicate 500 "words" <> [w] <> replicate 500 "more")
        d = diffText (paragraph "old") (paragraph "new")
    changedParts Removed d `shouldBe` ["old"]
    changedParts Added d `shouldBe` ["new"]

  describe "hunks" $ do
    it "shows the changes with the lines around them, and counts the rest" $ do
      let older = T.unlines (map show [1 .. 20 :: Int])
          newer = T.unlines (map show [1 .. 9 :: Int] <> ["ten"] <> map show [11 .. 20 :: Int])
          shown = map (\case Shown ls -> Right (length ls); Hidden n -> Left n) (hunks 3 (diffText older newer).rows)
      shown `shouldBe` [Left 6, Right 8, Left 7]

    it "leaves everything out of a diff with no change" $
      hunks 3 (diffText "a\nb\n" "a\nb\n").rows `shouldBe` [Hidden 2]

    prop "leaves out nothing that changed, and loses no line" $
      forAll text $ \a -> forAll text $ \b ->
        let rows = (diffText a b).rows
            hs = hunks 2 rows
         in (sum (map (\case Shown ls -> length ls; Hidden n -> n) hs), length [() | Shown ls <- hs, l <- ls, l.kind /= Unchanged])
              === (length rows, length [() | l <- rows, l.kind /= Unchanged])

  describe "on a page of 100 KB" $ do
    let page = T.unlines [T.unwords ["line", show i, "of", "the", "page", "with", "some", "words", "in", "it"] | i <- [1 .. 2500 :: Int]]
        edited = T.replace "line 10 of" "line ten of" (T.replace "line 2400 of" "line 2,400 of" page)
    it "finds two edits far apart" $ do
      let d = diffText page edited
      d.gaveUp `shouldBe` False
      length [l | l <- d.rows, l.kind /= Unchanged] `shouldBe` 4
      changedParts Added d `shouldBe` ["ten", "2,400"]

    it "gives up on a page with nothing in common, as a whole replace" $ do
      let other = T.unlines [T.unwords ["other", show i] | i <- [1 .. 2500 :: Int]]
          d = diffText page other
      d.gaveUp `shouldBe` True
      (oldSide d, newSide d) `shouldBe` (splitLines page, splitLines other)

    prop "finds a change wherever it is" $
      forAll (chooseInt (1, 2500)) $ \i ->
        let changedLine = T.replace ("line " <> show i <> " of") "line changed of" page
            d = diffText page changedLine
         in (map (\l -> l.old) (filter (\l -> l.kind == Removed) d.rows), changedParts Removed d) === ([Just i], [show i])

-- | The length of the longest common subsequence, the slow way, for small
-- inputs: what the shortest edit script keeps.
lcsLength :: [Text] -> [Text] -> Int
lcsLength xs ys = atDef 0 (foldl' row (replicate (length ys + 1) 0) xs) (length ys)
  where
    row prev x = scanl step 0 (zip ys (zip prev (drop 1 prev)))
      where
        step left (y, (diag, up)) = if x == y then diag + 1 else max left up
