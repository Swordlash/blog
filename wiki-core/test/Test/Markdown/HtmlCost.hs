-- | What reading and writing HTML costs ("Wiki.Core.Markdown.Html"): no
-- worse than in proportion to the HTML's length, for the inputs that would
-- make a careless reader or writer copy what it has so far at every step
-- (a style holding many end tags of other elements, many texts between
-- comments, deep nesting, a style never ended, many paragraphs). A page's
-- text has no limit of its own, and this code runs on the server for every
-- page (its render, its search text, its links), so one page must not
-- stall it.
--
-- Each input is read and written out again at four sizes, 50, 100, 200 and
-- 400 KB, each the best of three runs. Linear cost makes the largest about
-- eight times the smallest, quadratic cost sixty-four times; the test
-- fails above twenty-four, which a loaded machine does not reach. A run of
-- the largest under 50 ms passes whatever the ratio: there is too little
-- to time.
module Test.Markdown.HtmlCost (spec) where

import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Html

spec :: Spec
spec = describe "Markdown.Html, its cost" $ sequential $ do
  for_ shapes $ \(name, make, work) ->
    it ("grows no faster than the HTML: " <> toS name) $ do
      times <- for [50, 100, 200, 400] $ \kb ->
        -- Each run its own input, a space longer than the one before, made
        -- before the clock starts: the same input would be read once and
        -- the result kept.
        fmap minimum . for [0 .. 2] $ \i -> do
          let input = make (kb * 1024) <> T.replicate i " "
          _ <- evaluate (T.length input)
          timed (work input)
      let smallest = fromMaybe 0 (head times)
          largest = fromMaybe 0 (lastMay times)
      putStrLn (name <> ": " <> T.intercalate ", " [show (round (t * 1000) :: Int) <> " ms" | t <- times])
      (name, times, largest < 0.05 || largest / max smallest 0.001 < 24) `shouldSatisfy` (\(_, _, ok) -> ok)

  it "reads the reviewer's style of 100,000 end tags, 400 KB, in a few seconds even unoptimised" $ do
    let input = "<style>/* " <> T.replicate 100000 "</x>" <> " */</style><p>after</p>"
    _ <- evaluate (T.length input)
    seconds <- timed (frame input)
    putStrLn ("the reviewer's input: " <> show (round (seconds * 1000) :: Int) <> " ms" :: Text)
    seconds `shouldSatisfy` (< 5)
  where
    timed :: Int -> IO Double
    timed n = do
      start <- getCurrentTime
      _ <- evaluate n
      end <- getCurrentTime
      pure (realToFrac (diffUTCTime end start))

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
