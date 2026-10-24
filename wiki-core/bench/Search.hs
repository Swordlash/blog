-- | How long a search takes over a wiki of a thousand pages of a few KiB
-- each, and how much it allocates: see README.md beside this file for the
-- command and the numbers.
module Main (main) where

import Criterion.Main (bench, bgroup, defaultMain, whnf)
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..), searchPlain, searchQuery)
import Wiki.Core.Slug (Slug, mkSlug)

main :: IO ()
main = do
  -- The wiki is made and forced once, before anything is measured.
  candidates <- evaluate (force' wiki)
  let searching text = whnf (checksum . searchPlain (inTheBox text)) candidates
  -- How big the wiki is and how many pages each query matches, for the
  -- README.
  putText (show (sum [T.length p.body | (p, _, _) <- candidates]) <> " characters of Markdown in " <> show (length candidates) <> " pages")
  for_ [oneWord, threeWords] $ \text ->
    putText (show text <> " matches " <> show (length (searchPlain (searchQuery text) {limit = 1000} candidates)) <> " pages")
  defaultMain
    [ bgroup
        "search"
        [ bench "one word" (searching oneWord)
        , bench "three words" (searching threeWords)
        ]
    ]
  where
    force' ps = sum [T.length p.title + T.length p.body | (p, _, _) <- ps] `seq` ps

-- | A query as the search box in the header makes it, on every keystroke:
-- the eight best hits.
inTheBox :: Text -> SearchQuery
inTheBox text = (searchQuery text) {limit = 8}

-- | A word found in about a third of the pages.
oneWord :: Text
oneWord = "zolwiowa"

-- | Three words, each narrowing the hits, the last one typed halfway.
threeWords :: Text
threeWords = "zolwiowa strasse dia"

-- | Something that depends on every character of every hit, so that
-- forcing it forces the whole result.
checksum :: [SearchHit] -> Int
checksum hits = sum [T.length piece.text + fromEnum piece.match | h <- hits, Snippet pieces <- [h.title, h.snippet], piece <- pieces]

-- | A thousand pages in ten spaces, each a few KiB of Markdown: headings,
-- paragraphs, a list, emphasis, a link and a fence, in words of which some
-- are Polish and German, so that folding has diacritics and @ß@ to do.
wiki :: [(Page, [Slug], [Slug])]
wiki = [page n | n <- [1 .. 1000]]

page :: Int -> (Page, [Slug], [Slug])
page n =
  ( Page
      { id = PageId ("page-" <> show n)
      , space = SpaceId ("space-" <> show (n `mod` 10))
      , parent = Nothing
      , title
      , slug = slug ("page-" <> show n)
      , body
      , attachments = []
      , createdAt = epoch
      , updatedAt = epoch
      , position = n
      }
  , [slug ("space-" <> show (n `mod` 10))]
  , [slug ("page-" <> show n)]
  )
  where
    stream = randoms (n * 7919 + 17)
    title = T.unwords (map capitalise (take 3 (wordsFrom stream)))
    body = T.intercalate "\n\n" (take 14 (blocks (drop 3 stream)))
    epoch = UTCTime (fromGregorian 2026 1 1) 0

-- | Markdown blocks, made from a stream of numbers.
blocks :: [Int] -> [Text]
blocks (r : rs) = block : blocks rest
  where
    (used, rest) = splitAt 60 rs
    ws = wordsFrom used
    block = case r `mod` 7 of
      0 -> "## " <> T.unwords (map capitalise (take 4 ws))
      1 -> T.unlines ["- " <> T.unwords (take 6 (drop i ws)) | i <- [0, 6 .. 30]]
      2 -> "```haskell\n" <> T.unlines [w <> " = " <> v | (w, v) <- zip (take 6 ws) (drop 6 ws)] <> "```"
      _ -> sentence ws
    sentence xs =
      let (a, b) = splitAt 20 xs
       in capitalise (T.unwords a) <> " **" <> T.unwords (take 3 b) <> "** " <> T.unwords (drop 3 b) <> ", [" <> fromMaybe "link" (head b) <> "](https://example.org/" <> fromMaybe "x" (head b) <> ")."
blocks [] = []

-- | Words from a vocabulary, the first ones far more often than the last,
-- as words are.
wordsFrom :: [Int] -> [Text]
wordsFrom = map (\r -> let h = r `div` 65536 in vocabulary `index` ((h `mod` vocabularySize) * (h `div` vocabularySize `mod` vocabularySize) `div` vocabularySize))
  where
    index xs i = fromMaybe "" (head (drop i xs))

vocabularySize :: Int
vocabularySize = length vocabulary

vocabulary :: [Text]
vocabulary = common <> take 200 made <> diacritics <> drop 200 made
  where
    common =
      [ "the"
      , "a"
      , "of"
      , "and"
      , "to"
      , "in"
      , "is"
      , "page"
      , "space"
      , "wiki"
      , "with"
      , "for"
      , "that"
      , "on"
      , "as"
      , "by"
      , "diagram"
      , "formula"
      , "code"
      , "table"
      , "list"
      , "link"
      , "image"
      , "draft"
      , "editor"
      , "preview"
      , "search"
      , "result"
      , "mermaid"
      , "katex"
      , "highlight"
      , "markdown"
      , "heading"
      , "paragraph"
      , "emphasis"
      , "fence"
      , "attachment"
      , "version"
      , "alpha"
      , "beta"
      , "gamma"
      , "delta"
      , "epsilon"
      , "zeta"
      , "theta"
      , "lambda"
      , "sigma"
      , "omega"
      , "river"
      , "mountain"
      , "forest"
      , "meadow"
      , "harbour"
      , "lantern"
      , "compass"
      , "anchor"
      , "voyage"
      , "island"
      ]
    -- Rarer, so that a query for one of them matches some of the pages.
    diacritics = ["zażółć", "gęślą", "jaźń", "źdźbło", "łódź", "żółwiowa", "pięść", "Straße", "Grüße", "Mädchen", "naïve", "café"]
    made = [T.pack [c, v, d, w] | c <- "bdkmpst", v <- "aeiou", d <- "lnr", w <- "aio"]

capitalise :: Text -> Text
capitalise t = case T.uncons t of
  Just (c, rest) -> T.cons (toUpper c) rest
  Nothing -> t

-- | A deterministic stream of numbers (a linear congruential generator), so
-- that every run measures the same wiki.
randoms :: Int -> [Int]
randoms = drop 1 . iterate (\x -> (x * 6364136223846793005 + 1442695040888963407) `mod` 9223372036854775807)

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug
