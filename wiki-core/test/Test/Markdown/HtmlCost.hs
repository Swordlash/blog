-- | What reading and writing HTML costs ("Wiki.Core.Markdown.Html"): no
-- worse than in proportion to the HTML's length, for the inputs that would
-- make a careless reader or writer copy what it has so far at every step
-- (a style holding many end tags of other elements, many texts between
-- comments, deep nesting, a style never ended, many paragraphs). A page's
-- text has no limit of its own, and this code runs on the server for every
-- page (its render, its search text, its links), so one page must not
-- stall it.
--
-- The cost is counted, not timed: the bytes the work allocates, which GHC
-- counts for the thread that does it ('getAllocationCounter'), and which
-- are the same however loaded the machine is. The regressions the test was
-- written against (commit cd882171) show in it. A text appended to at
-- every step is copied, so a scan that keeps what it has passed, a builder
-- that joins each text to the one before and a writer that nests its
-- appends allocate the square of the length. The walk down the open
-- elements at every tag shows too: with the depth's bound taken away,
-- "elements nested deep" allocates 54 times as much at 40 KB as at 5 KB,
-- where linear is eight (10 with the bound, at those small sizes). Timed,
-- the test failed now and then on a loaded machine, on a pull request that
-- changed none of this.
--
-- Each input is read and written out again at four sizes, 50, 100, 200
-- and 400 KB. Linear cost makes the largest allocate about eight times the
-- smallest, quadratic cost sixty-four times; the test fails above sixteen.
module Test.Markdown.HtmlCost (spec) where

import Data.Text qualified as T
import Protolude
import System.Mem (getAllocationCounter, setAllocationCounter)
import Test.Hspec
import Wiki.Core.Markdown.Html

spec :: Spec
spec = describe "Markdown.Html, its cost" $ do
  for_ shapes $ \(name, make, work) ->
    it ("grows no faster than the HTML: " <> toS name) $ do
      counts <- for [50, 100, 200, 400] $ \kb -> do
        -- The input is made before the count starts: only the work is
        -- counted.
        let input = make (kb * 1024)
        _ <- evaluate (T.length input)
        allocated (work input)
      let smallest = fromMaybe 0 (head counts)
          largest = fromMaybe 0 (lastMay counts)
          ratio = fromIntegral largest / fromIntegral (max smallest 1) :: Double
      putStrLn (name <> ": " <> T.intercalate ", " [show (c `div` 1024) <> " KiB" | c <- counts] <> " allocated, " <> show (round ratio :: Int) <> " times from the smallest to the largest")
      (name, counts, ratio) `shouldSatisfy` (\(_, _, r) -> r < 16)

  it "reads the reviewer's style of 100,000 end tags, 400 KB, allocating in proportion to it" $ do
    let input = "<style>/* " <> T.replicate 100000 "</x>" <> " */</style><p>after</p>"
    _ <- evaluate (T.length input)
    bytes <- allocated (frame input)
    putStrLn ("the reviewer's input: " <> show (bytes `div` 1024) <> " KiB allocated" :: Text)
    -- Quadratic copying of 400 KB is tens of gigabytes; linear work is a
    -- few hundred bytes for each byte of input.
    bytes `shouldSatisfy` (< 1000 * T.length input)
  where
    -- The bytes the thread allocates while the work's result is forced.
    allocated :: Int -> IO Int
    allocated n = do
      setAllocationCounter 0
      _ <- evaluate n
      left <- getAllocationCounter
      pure (fromIntegral (negate left))

-- | Each input by its name, made at about a length, and the work it is
-- given: read and written out again, its length forced.
shapes :: [(Text, Int -> Text, Text -> Int)]
shapes =
  [ ("a style holding end tags of other elements, in a frame", \n -> "<style>/* " <> T.replicate (n `div` 4) "</x>" <> " */</style><p>after</p>", frame)
  , ("a style holding end tags of other elements, in a page", \n -> "<style>/* " <> T.replicate (n `div` 4) "</x>" <> " */</style><p>after</p>", page)
  , ("texts between comments", \n -> T.replicate (n `div` 8) "a<!---->", page)
  , ("elements nested deep", \n -> T.replicate (n `div` 5) "<div>", page)
  , ("a style never ended, holding </styleX", \n -> "<style>" <> T.replicate (n `div` 8) "</stylex", frame)
  , ("many paragraphs, as text", \n -> T.replicate (n `div` 8) "<p>x</p>", T.length . htmlText . parseHtml)
  , ("many elements side by side", \n -> T.replicate (n `div` 8) "<b>x</b>", page)
  ]

frame :: Text -> Int
frame = T.length . renderHtml . parseFrameHtml

page :: Text -> Int
page = T.length . renderHtml . parseHtml
