-- | A presentation's text as the slide mode's rows: where it is cut, how
-- an edit of one row re-cuts that row alone, and what a move, a delete and
-- a new row write.
module Test.SlideRows (spec) where

import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, checkCoverage, choose, conjoin, counterexample, cover, elements, forAll, oneof, property, suchThat, vectorOf, (.&&.), (===))
import Test.Slides (aDeck, aMove)
import Wiki.Core.SlideRows
import Wiki.Core.Slides (SlideSpan (..), fixedSlides, moveSlide, slideSpans)

spec :: Spec
spec = describe "SlideRows" $ do
  describe "cutRows" $ do
    it "starts a row at each opener's first line, the line break before it a separator" $ do
      let r = cut "Notes first.\n\n# Deck\n\nBy me.\n\n## One\n\nText.\n\n\nTwo\n---\n- a\n"
      textsOf r `shouldBe` ["Notes first.\n", "# Deck\n\nBy me.\n", "## One\n\nText.\n\n", "Two\n---\n- a\n"]
      r.separators `shouldBe` ["\n", "\n", "\n"]
      keysOf r `shouldBe` map RowKey [0 .. 3]
      snd (cutRows (RowKey 7) "## A\n## B\n") `shouldBe` RowKey 9

    it "has no preamble when the text starts with an opener, and one row for a text without one" $ do
      textsOf (cut "## A\nOne.\n## B") `shouldBe` ["## A\nOne.", "## B"]
      textsOf (cut "Just text.\n") `shouldBe` ["Just text.\n"]
      textsOf (cut "") `shouldBe` [""]
      textsOf (cut "\n## A\n") `shouldBe` ["", "## A\n"]

    it "cuts a text with carriage returns where the parser's lines are" $ do
      let crlf = cut "## A\r\n\r\n## B\r\n"
      textsOf crlf `shouldBe` ["## A\r\n", "## B\r\n"]
      crlf.separators `shouldBe` ["\r\n"]
      textsOf (cut "## A\r## B\r") `shouldBe` ["## A", "## B\r"]
      -- To commonmark 0.3.1, @\r\n\n@ is one line break: B is on the
      -- parser's second line, and the row starts where the parser says.
      let mixed = cut "## A\r\n\n## B"
      textsOf mixed `shouldBe` ["## A\r\n", "## B"]
      mixed.separators `shouldBe` ["\n"]

    prop "gives the text back, byte for byte, with line feeds, carriage returns or both" $
      forAll anyDeck $
        \source -> assemble (cut source) === source

    prop "starts a row at each slide 'slideSpans' finds, and at the text's start" $
      forAll aDeck $ \source ->
        let r = cut source
            lineOf c = 1 + T.count "\n" (T.take c source)
         in [lineOf s | (row, s) <- zip r.rows (rowStarts r), isJust (rowHeading row)]
              === [sp.from | sp <- slideSpans source, isJust sp.level]
              .&&. take 1 (rowStarts r) === [0]

    prop "makes rows that each start with their opener and hold no other, cut alone" $
      forAll anyDeck (wellCut . cut)

    prop "is not changed by a re-cut of every row, keys included" $
      forAll anyDeck $ \source ->
        let r = cut source
         in forAll (choose (0, T.length source)) $ \c ->
              fst (recut (nextOf source) (Just c) (keysOf r) r) === r
                .&&. fst (recut (nextOf source) Nothing (keysOf r) r) === r

  describe "fromLayout" $ do
    prop "gives a fresh cut's rows back from their keys and starts" $
      forAll anyDeck $ \source ->
        let r = cut source in fromLayout source (zip (keysOf r) (rowStarts r)) === Just r

    it "drops a start that does not follow a line break, comes twice or splits a CR LF, and starts the first row at the text's start" $ do
      let layout = fromLayout "# T\n## A ## B\r\n## C" [(RowKey 0, 2), (RowKey 1, 4), (RowKey 2, 9), (RowKey 3, 4), (RowKey 5, 14), (RowKey 4, 15)]
      map textsOf layout `shouldBe` Just ["# T", "## A ## B", "## C"]
      map keysOf layout `shouldBe` Just [RowKey 0, RowKey 1, RowKey 4]
      fromLayout "" [] `shouldBe` Nothing

    prop "gives rows that a re-cut of the changed ones makes rows as a fresh cut makes them, from any starts" $
      forAll anyDeck $ \source ->
        let rows0 = cut source
         in forAll (anEditOf rows0) $ \(_, edited, cursor) ->
              let text = assemble edited
               in forAll (shiftedStarts (T.length text) (zip (keysOf edited) (rowStarts edited))) $ \layout ->
                    case fromLayout text layout of
                      Nothing -> counterexample "no rows" False
                      Just laid ->
                        let (rows1, _) = recut (nextOf source) cursor (changedSince rows0 laid) laid
                         in counterexample (show (layout, textsOf laid, textsOf rows1)) $
                              assemble laid === text
                                .&&. assemble rows1 === text
                                .&&. wellCut rows1
                                .&&. ordNub (keysOf rows1) === keysOf rows1

  describe "recut" $ do
    prop "keeps every other row's key and text when a row leaves a fence, a spoiler box or an HTML comment open" $
      checkCoverage $
        forAll ((,,) <$> aDeck `suchThat` ((>= 3) . length . (.rows) . cut) <*> elements openBlocks <*> elements [False, True]) $ \(source, block, focused) ->
          let rows0 = cut source
           in forAll (choose (1, length rows0.rows - 2)) $ \k ->
                let key = keyAt k rows0
                    opened = withRowText k (<> ("\n\n" <> block)) rows0
                    cursor = if focused then Just (rowStarts opened `nth` k + T.length (textAt k opened)) else Nothing
                    rows1 = fst (recut (nextOf source) cursor [key] opened)
                    others r = [row | row <- r.rows, row.key /= key]
                 in cover 90 (not (null (swallowed rows1))) "the whole text runs the open block into the rows below"
                      $ counterexample (show (textsOf rows1))
                      $ others rows1 === others opened
                        .&&. [row.text | row <- rows1.rows, row.key == key] === [textAt k opened]

    it "splits a row where an opener is typed, the cursor's part keeping the row's key" $ do
      let rows0 = cut "# T\n\n## A\n\nOne.\n"
          typed = withRowText 1 (<> "## X") rows0
          (rows1, next) = recut (RowKey 2) (Just (T.length (assemble typed))) [RowKey 1] typed
      textsOf rows1 `shouldBe` ["# T\n", "## A\n\nOne.", "## X"]
      keysOf rows1 `shouldBe` [RowKey 0, RowKey 2, RowKey 1]
      next `shouldBe` RowKey 3
      -- Without a cursor, the upper part keeps the key.
      keysOf (fst (recut (RowKey 2) Nothing [RowKey 1] typed)) `shouldBe` [RowKey 0, RowKey 1, RowKey 2]

    it "joins a row whose heading was deleted to the row above, which takes the key of the row with the cursor" $ do
      let rows0 = cut "# T\n\n## A\n\nOne.\n\n## B\n\nTwo.\n"
          deleted = withRowText 2 (T.drop 5) rows0
          start = rowStarts deleted `nth` 2
      textsOf (fst (recut (RowKey 3) (Just start) [RowKey 2] deleted)) `shouldBe` ["# T\n", "## A\n\nOne.\n\n\nTwo.\n"]
      keysOf (fst (recut (RowKey 3) (Just start) [RowKey 2] deleted)) `shouldBe` [RowKey 0, RowKey 2]
      keysOf (fst (recut (RowKey 3) Nothing [RowKey 2] deleted)) `shouldBe` [RowKey 0, RowKey 1]

    it "cuts the joined row again, where the joined text makes a setext heading" $ do
      let rows0 = cut "## A\n\nfoo\n## B\n---\nbar\n"
          deleted = withRowText 1 (T.drop 5) rows0
          cursor = rowStarts deleted `nth` 1
          (rows1, _) = recut (RowKey 2) (Just cursor) [RowKey 1] deleted
      textsOf rows0 `shouldBe` ["## A\n\nfoo", "## B\n---\nbar\n"]
      textsOf rows1 `shouldBe` ["## A\n", "foo\n---\nbar\n"]
      keysOf rows1 `shouldBe` [RowKey 0, RowKey 1]

    it "gives the preamble a row whose opener is gone" $ do
      let rows0 = cut "Intro.\n\n## A\nText\n"
          demoted = withRowText 1 (T.drop 3) rows0
      textsOf (fst (recut (RowKey 2) Nothing [RowKey 1] demoted)) `shouldBe` ["Intro.\n\nA\nText\n"]

    it "takes the key of a row whose start is gone to the first row inside it" $ do
      let rows0 = cut "# T\n## A\nOne.\n"
          pushed = withRowText 1 ("x\n" <>) rows0
          (rows1, _) = recut (RowKey 2) Nothing [RowKey 1] pushed
      textsOf rows1 `shouldBe` ["# T\nx", "## A\nOne.\n"]
      keysOf rows1 `shouldBe` [RowKey 0, RowKey 1]

    prop "after an edit of one row: the same text, rows cut as a fresh cut cuts them, new keys from the counter, the others kept" $
      forAll anyDeck $ \source ->
        let rows0 = cut source
         in forAll (anEditOf rows0) $ \(k, edited, cursor) ->
              let next = nextOf source
                  (rows1, next') = recut next cursor [keyAt k rows0] edited
                  keys = keysOf rows1
                  untouched = [row | (i, row) <- zip [0 ..] edited.rows, i /= k, i /= k - 1]
               in counterexample (show (textsOf edited, textsOf rows1)) $
                    conjoin
                      [ assemble rows1 === assemble edited
                      , wellCut rows1
                      , ordNub keys === keys
                      , counterexample "a new key not from the counter" $
                          all (\x -> x `elem` keysOf edited || (x >= next && x < next')) keys
                      , counterexample "a row other than the edited one and the one above it changed" $
                          all (`elem` rows1.rows) untouched
                      , counterexample "the cursor's row changed its key" $
                          all (\c -> keyAt (rowAt rows1 c) rows1 == keyAt (rowAt edited c) edited) cursor
                      , fst (recut next' Nothing keys rows1) === rows1
                      ]

  describe "moveRow, deleteRow and newRow" $ do
    it "move a row's text with the separator after it, keeping its key" $ do
      let r = cut "## A\n\nOne.\n\n## B\n\nTwo.\n"
      map (first assemble) (moveRow 1 0 r)
        `shouldBe` Just ("## B\n\nTwo.\n## A\n\nOne.\n\n", [Edit 0 0 "## B\n\nTwo.\n", Edit 12 23 ""])
      map (keysOf . fst) (moveRow 1 0 r) `shouldBe` Just [RowKey 1, RowKey 0]
      map (assemble . fst) (moveRow 0 1 (cut "## A\n\nOne.\n\n## B\nTwo.")) `shouldBe` Just "## B\nTwo.\n## A\n\nOne.\n\n"

    it "put a blank line after a preamble that is not a slide, where 'moveSlide' puts none" $ do
      let source = "[[!pause]]\nS\n---\n## A\nM\n---\nbar\n## B\n"
      moveSlide 2 0 source `shouldBe` "[[!pause]]\nM\n---\nbar\n\nS\n---\n## A\n## B\n"
      map (assemble . fst) (moveRow 3 1 (cut source)) `shouldBe` Just "[[!pause]]\n\nM\n---\nbar\n\nS\n---\n## A\n## B\n"

    it "move a row whose block is left open, where 'moveSlide' does not" $ do
      let source = "## A\n\nOne.\n\n## B\n\n```\nopen"
      moveSlide 1 0 source `shouldBe` source
      map (assemble . fst) (moveRow 1 0 (cut source)) `shouldBe` Just "## B\n\n```\nopen\n## A\n\nOne.\n\n"

    it "delete a row with the separator after it, or the last row alone" $ do
      let r = cut "# T\n\n## A\n\nOne.\n\n## B\n"
      map (first assemble) (deleteRow 1 r) `shouldBe` Just ("# T\n\n## B\n", [Edit 5 17 ""])
      map (keysOf . fst) (deleteRow 1 r) `shouldBe` Just [RowKey 0, RowKey 2]
      map (assemble . fst) (deleteRow 2 r) `shouldBe` Just "# T\n\n## A\n\nOne.\n\n"
      map fst (deleteRow 0 r) `shouldBe` Nothing
      map fst (deleteRow 0 (cut "## A\n")) `shouldBe` Nothing

    it "put a blank line before a setext title that would join the row above" $
      map (assemble . fst) (deleteRow 1 (cut "## A\n\nfoo\n## B\n\nC\n---\n")) `shouldBe` Just "## A\n\nfoo\n\nC\n---\n"

    it "put a new row apart by blank lines, after the rows that stay first" $ do
      let r = cut "# T\n\n## A\nOne."
      map (assemble . fst) [newRow (RowKey 5) "New slide" at r | at <- [3, 2, 1, 0]]
        `shouldBe` [ "# T\n\n## A\nOne.\n\n## New slide\n"
                   , "# T\n\n## A\nOne.\n\n## New slide\n"
                   , "# T\n\n## New slide\n\n## A\nOne."
                   , "# T\n\n## New slide\n\n## A\nOne."
                   ]
      keysOf (fst (newRow (RowKey 5) "New slide" 1 r)) `shouldBe` [RowKey 0, RowKey 5, RowKey 1]
      snd (newRow (RowKey 5) "New slide" 1 r) `shouldBe` [Edit 5 5 "## New slide\n\n"]
      assemble (fst (newRow (RowKey 1) "X" 1 (cut "# T\r\n"))) `shouldBe` "# T\r\n\r\n## X\r\n"

    prop "are each edits of the old text that give the new, rows cut as a fresh cut cuts them" $
      forAll anyDeck $ \source ->
        let r = cut source
            n = length r.rows
         in forAll ((,,) <$> choose (0, n) <*> choose (0, n) <*> elements ["New slide", "X"]) $ \(i, j, title) ->
              let step r' es = applyEdits es (assemble r) === assemble r' .&&. ordered es .&&. wellCut r'
               in cover 30 (isJust (moveRow i j r)) "moved"
                    $ cover 30 (isJust (deleteRow i r)) "deleted"
                    $ conjoin
                      [ maybe (property True) (\(r', es) -> step r' es .&&. keysOf r' === reorderAt i j (keysOf r)) (moveRow i j r)
                      , maybe (property True) (\(r', es) -> step r' es .&&. keysOf r' === take i (keysOf r) <> drop (i + 1) (keysOf r)) (deleteRow i r)
                      , let (r', es) = newRow (nextOf source) title i r
                            at' = max (fixedRows r) (min n i)
                         in step r' es
                              .&&. keysOf r' === take at' (keysOf r) <> [nextOf source] <> drop at' (keysOf r)
                              .&&. map rowHeading (take 1 (drop at' r'.rows)) === [Just (2, title)]
                      ]

    prop "move as 'moveSlide' moves, wherever it moves, but for a blank line after a preamble that is not a slide" $
      checkCoverage $
        forAll aMove $ \(source, i, j) ->
          let r = cut source
              spans = slideSpans source
              -- A preamble that is not a slide is a row all the same.
              offset = fromEnum (any (isNothing . rowHeading) (take 1 r.rows)) - fromEnum (any (isNothing . (.level)) spans)
              moved = moveSlide i j source
              afterPreamble = rowStarts r `nth` 1
              apart = T.take afterPreamble moved <> "\n" <> T.drop afterPreamble moved
              expected = if offset == 1 then [Just moved, Just apart] else [Just moved]
              got = map (assemble . fst) (moveRow (i + offset) (j + offset) r)
           in cover 30 (moved /= source) "moveSlide moves" $
                fixedRows r === fixedSlides spans + offset
                  .&&. counterexample (show got) (moved == source || got `elem` expected)

    prop "never move or delete the rows that stay first, and put nothing before them" $
      forAll anyDeck $ \source ->
        let r = cut source
            fixed = fixedRows r
            n = length r.rows
            kept r' = map trimmed (take fixed r'.rows) == map trimmed (take fixed r.rows)
            trimmed row = (row.key, T.dropWhileEnd (\c -> c == '\n' || c == '\r') row.text)
         in forAll ((,) <$> choose (0, n) <*> choose (0, n)) $ \(i, j) ->
              conjoin
                [ counterexample "a move of a row that stays first" $ min i j >= fixed || isNothing (moveRow i j r)
                , counterexample "a delete of a row that stays first" $ i >= fixed || isNothing (deleteRow i r)
                , counterexample "the rows that stay first changed" $
                    all (kept . fst) (catMaybes [moveRow i j r, deleteRow i r, Just (newRow (nextOf source) "X" i r)])
                ]

  describe "reading rows" $ do
    it "reads a row's level and title from its opener alone" $ do
      map rowHeading (cut "Intro.\n\n# The *big* `idea`\n\nAlpha\n---\nText.\n").rows
        `shouldBe` [Nothing, Just (1, "The big idea"), Just (2, "Alpha")]
      rowTitle (Row (RowKey 0) "##\n") `shouldBe` ""

    it "finds the row a character is in, a row's end included" $ do
      let r = cut "# T\n## A\n"
      map (rowAt r) [0, 3, 4, 8, 9] `shouldBe` [0, 0, 1, 1, 1]

    it "counts the characters in each row of a layout, a row's start its own" $
      countPerRow [(RowKey 3, 0), (RowKey 1, 10), (RowKey 7, 20)] [25, 0, 9, 10, 10, 30]
        `shouldBe` [(RowKey 3, 2), (RowKey 1, 2), (RowKey 7, 2)]

    prop "counts each character once, in the row 'rowAt' finds" $
      forAll aDeck $ \source ->
        let (r, _) = cutRows (RowKey 0) source
            at = [0, 3 .. T.length source]
         in countPerRow (zip [row.key | row <- r.rows] (rowStarts r)) at
              === [(row.key, length [c | c <- at, rowAt r c == i]) | (i, row) <- zip [0 ..] r.rows]

    it "fixes the preamble and a title slide that comes first" $ do
      map (fixedRows . cut) ["Intro.\n# T\n## A\n", "Intro.\n## A\n# T\n", "# T\n## A\n", "## A\n# T\n", "Text.\n"] `shouldBe` [2, 1, 1, 0, 1]

    it "says which rows a block left open takes in, and which row's slide it is" $ do
      let rows0 = cut "# T\n\n## A\n\n## B\n\n## C\n"
          opened = fst (recut (RowKey 4) Nothing [RowKey 1] (withRowText 1 (<> "\n```\n") rows0))
      swallowed rows0 `shouldBe` []
      swallowed opened `shouldBe` [(2, 1), (3, 1)]

    it "finds the line that opens the block a row leaves open, past a block opened and closed before it" $ do
      map (\t -> leftOpenAt (Row (RowKey 0) t)) ["## A\n\nText.\n\n```\nopen", "## A\n```\nclosed\n```\n\n<!--\nopen\n", "## A\n\n[[!spoiler]]{x}(Q)\nopen", "## A\n\nText.\n", "## A\n\n<div>\nopen"]
        `shouldBe` [Just 13, Just 21, Just 6, Nothing, Nothing]

    prop "finds the same line as reading the row line by line, whose time grows with the square of its length" $
      forAll ((,,) <$> aDeck <*> elements openBlocks <*> elements ["", "\n\nAfter.\n\n```\nclosed\n```\n"]) $ \(source, block, earlier) ->
        conjoin
          [ leftOpenAt row === lineByLine row
          | row <- (cut source).rows <> [Row (RowKey 0) (t <> earlier <> "\n\n" <> block <> "\nmore\n\n## Not a slide") | Row _ t <- take 2 (cut source).rows]
          ]

    -- A fence left open with 4000 lines after it: read line by line, each
    -- line's prefix parsed again, this took minutes; read once, it takes a
    -- few hundredths of a second. The bound leaves room for a slow machine.
    it "finds the line of a fence left open with thousands of lines after it in time linear in the row" $ do
      let row = Row (RowKey 0) (T.intercalate "\n" (["## Code", "", "Text.", "", "```haskell"] <> ["x = " <> show k | k <- [1 .. 4000 :: Int]]))
      started <- getCurrentTime
      leftOpenAt row `shouldBe` Just 16
      done <- getCurrentTime
      diffUTCTime done started `shouldSatisfy` (< 3)

    prop "says no row is taken in exactly when the rows are where a fresh cut puts them" $
      checkCoverage $
        forAll anyDeck $ \source ->
          let rows0 = cut source
              -- Half the time, a block left open in a row with rows below.
              opening = do
                k <- choose (0, max 0 (length rows0.rows - 2))
                block <- elements openBlocks
                pure (k, withRowText k (<> ("\n\n" <> block)) rows0, Nothing)
           in forAll (oneof [anEditOf rows0, opening]) $ \(k, edited, cursor) ->
                let rows1 = fst (recut (nextOf source) cursor [keyAt k rows0] edited)
                    fresh = rowStarts (cut (assemble rows1)) == rowStarts rows1
                 in cover 20 (not fresh) "rows a fresh cut would not make"
                      $ cover 40 fresh "rows as a fresh cut makes them"
                      $ null (swallowed rows1) === fresh

----------------------------------------------------------------------
-- Helpers

-- | The rows of a text, cut fresh with keys from 0.
cut :: Text -> Rows
cut = fst . cutRows (RowKey 0)

-- | 'leftOpenAt' as it was first written: each line's prefix of the row
-- parsed with a heading after it, and the lines at the end whose prefixes
-- all take the heading in. Right, and quadratic: the model the one parse
-- is checked against.
lineByLine :: Row -> Maybe Int
lineByLine row = case reverse run of
  (at, _) : _ | length run < length flags -> Just at
  _ -> Nothing
  where
    flags = zip starts (map (swallows . (`T.take` row.text)) ends)
    run = takeWhile snd (reverse flags)
    starts = scanl (+) 0 (map ((+ 1) . T.length) lines')
    ends = [s + T.length l | (s, l) <- zip starts lines']
    lines' = T.splitOn "\n" row.text
    swallows prefix = let probe = prefix <> "\n\n## Probe\n" in (T.length prefix + 2) `notElem` openerStarts probe

-- | The counter after a fresh cut's keys.
nextOf :: Text -> RowKey
nextOf = snd . cutRows (RowKey 0)

keysOf :: Rows -> [RowKey]
keysOf r = map (.key) r.rows

textsOf :: Rows -> [Text]
textsOf r = map (.text) r.rows

keyAt :: Int -> Rows -> RowKey
keyAt k r = maybe (RowKey (-1)) (.key) (atMay r.rows k)

textAt :: Int -> Rows -> Text
textAt k r = maybe "" (.text) (atMay r.rows k)

nth :: [Int] -> Int -> Int
nth xs k = fromMaybe 0 (atMay xs k)

-- | The rows with one row's text changed, as the browser's editor would
-- hand them over after an edit in that row.
withRowText :: Int -> (Text -> Text) -> Rows -> Rows
withRowText k f r = r {rows = [if i == k then row {text = f row.text} else row | (i, row) <- zip [0 ..] r.rows]}

-- | Whether each row but the first starts with an opener and holds no
-- other, cut alone, and the first holds none or starts with its one.
wellCut :: Rows -> Property
wellCut r =
  counterexample (show (textsOf r)) $
    conjoin
      ( [counterexample "the first row" (openerStarts row.text `elem` [[], [0]]) | row <- take 1 r.rows]
          <> [openerStarts row.text === [0] | row <- drop 1 r.rows]
      )

-- | Whether edits are in order and do not overlap.
ordered :: [Edit] -> Bool
ordered es = and [e.from <= e.to | e <- es] && and [e.to <= e'.from | (e, e') <- zip es (drop 1 es)]

-- | A list with the element at one index taken out and put back at
-- another.
reorderAt :: Int -> Int -> [a] -> [a]
reorderAt i j xs = take j rest <> take 1 (drop i xs) <> drop j rest
  where
    rest = take i xs <> drop (i + 1) xs

-- | Rows' starts as an edit the rows did not make can leave them: the
-- first as it is, each other kept, dropped or moved by up to two
-- characters, and a few more at any character, in order, some of them
-- twice.
shiftedStarts :: Int -> [(RowKey, Int)] -> Gen [(RowKey, Int)]
shiftedStarts total layout = do
  shifted <- forM layout $ \(key, s) -> do
    change <- elements [Just 0, Just 0, Just 0, Nothing, Just (-2), Just (-1), Just 1, Just 2]
    pure [(key, max 0 (min total (s + d))) | Just d <- [change]]
  extra <- forM [100 .. 102 :: Int] $ \k -> do
    s <- choose (0, total)
    elements [[], [(RowKey k, s)]]
  -- The editor always holds the first row.
  pure (take 1 layout <> sortOn snd (concat (drop 1 shifted) <> concat extra))

-- | A block left open: everything after it, to the end of the text, is in
-- it. A bare @[[!spoiler]]@ is not a box (it takes nothing in); a named one
-- is.
openBlocks :: [Text]
openBlocks = ["```\nopen", "[[!spoiler]]{x}(Q)\nopen", "<!--\nopen"]

-- | A presentation's source from 'aDeck', or the same with each line
-- break written as @\\n@, @\\r\\n@ or @\\r@, chosen line by line: mixed,
-- so that @\\r\\n\\n@, one line break to the parser, comes up too.
anyDeck :: Gen Text
anyDeck = oneof [aDeck, mixed]
  where
    mixed = do
      source <- aDeck
      let ls = T.splitOn "\n" source
      endings <- vectorOf (length ls - 1) (elements ["\n", "\r\n", "\r"])
      pure (T.concat (zipWith (<>) ls (endings <> [""])))

-- | An edit of one row, as an author typing in it or an undo makes one: a
-- piece put in at the start of one of its lines (an opener, a setext
-- underline, a block's opening or closing line, text), its first line
-- taken out, a hash or a letter put before it, or all of its text
-- deleted. With the row's index, the rows after the edit, and maybe a
-- cursor in the edited row.
anEditOf :: Rows -> Gen (Int, Rows, Maybe Int)
anEditOf r = do
  k <- choose (0, length r.rows - 1)
  f <-
    oneof
      [ atLine <$> elements pieces <*> choose (0, 1000)
      , pure (T.drop 1 . T.dropWhile (\c -> c /= '\n' && c /= '\r'))
      , pure ("#" <>)
      , pure ("x" <>)
      , pure (const "")
      ]
  let edited = withRowText k f r
      start = rowStarts edited `nth` k
  cursor <- oneof [pure Nothing, Just <$> choose (start, start + T.length (textAt k edited))]
  pure (k, edited, cursor)
  where
    pieces = ["## X\n", "# X\n", "X\n---\n", "```\n", "<!--\n", "-->\n", "[[!spoiler]]{x}(Q)\n", "[[!notes]]\n", "[[/notes]]\n", "### X\n", "Text.\n", "\n", "---\n", "<div>\n"]
    atLine piece n t =
      let starts = 0 : [i + 1 | (i, c) <- zip [0 ..] (T.unpack t), c == '\n'] <> [T.length t]
          p = starts `nth` (n `mod` length starts)
       in T.take p t <> piece <> T.drop p t
