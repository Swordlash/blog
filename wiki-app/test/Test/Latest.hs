-- | The one rule for answers that come late ("Wiki.App.View.Latest"): an
-- answer of a kind is taken only if no newer answer of that kind was
-- taken already, newer by the order of the asks.
module Test.Latest (spec) where

import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, chooseInt, counterexample, forAllBlind, shuffle, (.&&.), (===))
import Wiki.App.View.Latest

-- | Asks made and answered, by the number of each ask, in the order the
-- answers come: which of them are taken.
takenOf :: Int -> [Int] -> [Int]
takenOf made comeIn = go asks0 comeIn
  where
    (tickets, asks0) = foldl' (\(ts, a) _ -> let (t, a') = newAsk a in (ts <> [t], a')) ([], noAsks) [1 .. made]
    go _ [] = []
    go a (n : rest) = case tickets `atMay` (n - 1) >>= \t -> takes t a of
      Just a' -> n : go a' rest
      Nothing -> go a rest

-- | Some asks, and the order their answers come in.
genAnswers :: Gen (Int, [Int])
genAnswers = do
  made <- chooseInt (1, 8)
  (made,) <$> shuffle [1 .. made]

spec :: Spec
spec = describe "Wiki.App.View.Latest" $ do
  it "takes the answer to a later ask, and drops an earlier one that comes after it" $ do
    takenOf 2 [1, 2] `shouldBe` [1, 2]
    takenOf 2 [2, 1] `shouldBe` [2]
    takenOf 3 [2, 1, 3] `shouldBe` [2, 3]

  prop "takes answers in the order of their asks, and always the latest ask's" $
    forAllBlind genAnswers $ \(made, comeIn) ->
      let taken = takenOf made comeIn
       in counterexample (show (comeIn, taken)) $
            (sort taken === taken) .&&. (lastMay taken === Just made)

  it "takes none of the answers out when something newer was put in their place" $ do
    let (first', a1) = newAsk noAsks
        (second', a2) = newAsk a1
        later = supersede a2
    takes first' later `shouldBe` Nothing
    takes second' later `shouldBe` Nothing
    let (third, a3) = newAsk later
    isJust (takes third a3) `shouldBe` True

  it "takes and marks an answer in one step of the state, and leaves the state alone for one it drops" $ do
    let start = (noAsks, "nothing" :: Text)
        run = do
          firstAsk <- asking fst (\a (_, s) -> (a, s))
          secondAsk <- asking fst (\a (_, s) -> (a, s))
          tookTwo <- answered fst (\a (_, s) -> (a, s)) secondAsk (second (const "second"))
          tookOne <- answered fst (\a (_, s) -> (a, s)) firstAsk (second (const "first"))
          pure (tookTwo, tookOne)
    evalState run start `shouldBe` (True, False)
    snd (execState run start) `shouldBe` "second"
