-- | Tasks ticked in a page: where the parser finds each task's box, the
-- text with ticks written into it ('applyTicks'), and the rules for the
-- tasks under a task ('tick'). These run on both backends: the browser
-- writes the ticks.
module Test.Markdown.Tasks (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Tasks

-- | The tasks of a text, as the page would number them.
tasksIn :: Text -> [Task]
tasksIn source = either (const []) tasksOf (parseMarkdown source)

-- | Each task's label and state, in the order of the tree.
flat :: Text -> [(Text, Bool)]
flat = map (\t -> (t.label, t.done)) . allTasks . tasksIn

-- | The text with these ticks written, which must succeed.
ticked :: [(Int, Bool)] -> Text -> Text
ticked ticks source = either (panic . show) identity (applyTicks (Map.fromList ticks) source)

-- | The tree of a text with every task to do: what ticks must leave as it
-- is.
undone :: Text -> Either ParseError [Block]
undone = fmap (map go) . parseMarkdown
  where
    go = \case
      BlockQuote bs -> BlockQuote (map go bs)
      List kind items -> List kind [ListItem (False <$ task) (map go bs) | ListItem task bs <- items]
      Div attrs bs -> Div attrs (map go bs)
      Alert kind h bs -> Alert kind h (map go bs)
      Spoiler h bs -> Spoiler h (map go bs)
      Footnotes notes -> Footnotes [Footnote n l (map go bs) | Footnote n l bs <- notes]
      other -> other

-- | A page with tasks in all the places they can be, and things that look
-- like tasks and are not: in code, in HTML, after a number, in text. Its
-- boxes are all written @[ ]@ or @[x]@, so that ticking and unticking a
-- box gives the text back.
genPage :: Gen Text
genPage = do
  ending <- elements ["\n", "\r\n", "\r"]
  parts <- resize 4 (listOf1 genPart)
  pure (T.intercalate (ending <> ending) (map (T.intercalate ending) parts) <> ending)

genPart :: Gen [Text]
genPart =
  frequency
    [ (4, genList 2)
    , (1, map ("> " <>) <$> genList 1)
    , (1, ("> [!NOTE]" :) . map ("> " <>) <$> genList 1)
    , (1, (\ls -> ["[[!spoiler]]{s}(Hidden)"] <> ls <> ["[[/spoiler]]"]) <$> genList 1)
    , (1, (\ls -> ["[[!div]]{.sorted}"] <> ls <> ["[[/div]]"]) <$> genList 1)
    , (1, ("{.sorted}" :) <$> genList 1)
    , (1, (\name ls -> ["See[^" <> name <> "].", "", "[^" <> name <> "]: A note.", ""] <> map ("    " <>) ls) <$> elements ["a", "b"] <*> genList 1)
    , (1, pure ["```", "- [ ] in code", "```"])
    , (1, pure ["    - [ ] indented code"])
    , (1, pure ["<div>", "- [ ] in html", "</div>"])
    , (1, pure ["1. [ ] numbered, no task"])
    , (1, pure ["Text with - [x] and [ ] in it."])
    ]

genList :: Int -> Gen [Text]
genList depth = concat <$> resize 3 (listOf1 (genItem depth))

genItem :: Int -> Gen [Text]
genItem depth = do
  bullet <- elements ["-", "*", "+"]
  gap <- elements [" ", "  ", "\t"]
  box <- elements ["[ ] ", "[x] ", ""]
  text <- elements ["one", "two **bold**", "`[ ]` code", "[x] again", "a $[x]$ formula", ""]
  nested <- if depth > 0 then frequency [(3, pure []), (1, genList (depth - 1))] else pure []
  pure ((bullet <> gap <> box <> text) : map ("    " <>) nested)

-- | Some ticks for the tasks of a text: any of its tasks, either way.
genTicks :: Text -> Gen [(Int, Bool)]
genTicks source = case length (allTasks (tasksIn source)) of
  0 -> pure []
  n -> listOf ((,) <$> choose (0, n - 1) <*> arbitrary)

spec :: Spec
spec = describe "Markdown.Tasks" $ do
  describe "the tasks of a page (tasksOf)" $ do
    it "numbers the tasks in the order of the tree, each before the tasks under it" $
      flat "- [ ] a\n  - [x] b\n  - c\n    - [ ] d\n- [ ] e\n"
        `shouldBe` [("a", False), ("b", True), ("d", False), ("e", False)]
    it "puts the tasks under a task, through an item that is no task" $
      map (\t -> map (\u -> u.label) t.under) (tasksIn "- [ ] a\n  - [x] b\n  - c\n    - [ ] d\n- [ ] e\n")
        `shouldBe` [["b", "d"], []]
    it "finds tasks in a quotation, a box, a spoiler and a div" $
      map fst (flat "> - [ ] q\n\n> [!NOTE]\n> - [ ] n\n\n[[!spoiler]]{s}(D)\n- [ ] s\n[[/spoiler]]\n\n[[!div]]{.x}\n- [ ] d\n[[/div]]\n")
        `shouldBe` ["q", "n", "s", "d"]
    it "puts a footnote's tasks after the page's, where the footnotes are" $
      map fst (flat "See[^1].\n\n[^1]: A note.\n\n    - [ ] in the note\n\n- [ ] after\n")
        `shouldBe` ["after", "in the note"]
    it "finds no task in code, in HTML, after a number or in text" $
      flat "```\n- [ ] code\n```\n\n<div>\n- [ ] html\n</div>\n\n1. [ ] numbered\n\nText - [x] here\n"
        `shouldBe` []

  describe "writing ticks (applyTicks)" $ do
    it "ticks and unticks the tasks named, by their index" $
      ticked [(0, True), (1, False)] "- [ ] a\n- [x] b\n- [ ] c\n" `shouldBe` "- [x] a\n- [ ] b\n- [ ] c\n"
    it "changes the box of the task in a footnote, not the one after it" $
      ticked [(1, True)] "See[^1].\n\n[^1]: A note.\n\n    - [ ] in the note\n\n- [ ] after\n"
        `shouldBe` "See[^1].\n\n[^1]: A note.\n\n    - [x] in the note\n\n- [ ] after\n"
    it "keeps the line endings, the indentation and a tab after the bullet" $
      ticked [(0, True), (1, True)] "-\t[ ] a\r\n    *   [ ] b\r\n" `shouldBe` "-\t[x] a\r\n    *   [x] b\r\n"
    it "finds the box of a task nested with a tab" $
      ticked [(1, True)] "- [ ] a\n\t- [ ] b\n" `shouldBe` "- [ ] a\n\t- [x] b\n"
    it "finds a box in a quotation after a tab" $
      ticked [(0, True)] ">\t- [ ] a\n" `shouldBe` ">\t- [x] a\n"
    it "leaves a box already in the state named as written, a capital X too" $
      ticked [(0, True), (1, False)] "- [X] a\n- [ ] b\n" `shouldBe` "- [X] a\n- [ ] b\n"
    it "writes an unticked capital X as a space and a ticked box of spaces as an x" $
      ticked [(0, False), (1, True), (2, True)] "- [X] a\n- [   ] b\n- [\t] c\n" `shouldBe` "- [ ] a\n- [x] b\n- [x] c\n"
    it "ticks a task after a code block that holds a task's text" $
      ticked [(0, True)] "```\n- [ ] code\n```\n\n- [ ] real\n" `shouldBe` "```\n- [ ] code\n```\n\n- [x] real\n"
    it "ticks a task in a sorted list as the source has it" $
      ticked [(1, True)] "{.sorted}\n- [x] a\n- [ ] b\n" `shouldBe` "{.sorted}\n- [x] a\n- [x] b\n"
    it "refuses a task the text does not have" $
      applyTicks (Map.fromList [(2, True)]) "- [ ] a\n- [ ] b\n" `shouldBe` Left (NoSuchTask 2)
    it "refuses rather than guess where the columns of the source and the parser's differ" $
      -- The parser reads the text in Unicode's composed form, so a label
      -- written decomposed before the bullet moves its column.
      applyTicks (Map.fromList [(0, True)]) "x[^e\x301]\n\n[^e\x301]: - [ ] a\n" `shouldSatisfy` isLeft
    prop "changes nothing for no ticks, and for ticks of the states the text has" $
      forAll genPage $ \source ->
        let same = Map.fromList [(t.index, t.done) | t <- allTasks (tasksIn source)]
         in applyTicks mempty source === Right source .&&. applyTicks same source === Right source
    prop "changes only the boxes named: the same tree but for their states" $
      forAll genPage $ \source -> forAll (genTicks source) $ \ticks ->
        let wanted = Map.fromList ticks
            result = applyTicks wanted source
            expected = [Map.findWithDefault t.done t.index wanted | t <- allTasks (tasksIn source)]
         in case result of
              Left e -> counterexample (show e) False
              Right new ->
                map (\t -> t.done) (allTasks (tasksIn new)) === expected
                  .&&. undone new === undone source
                  .&&. T.length new === T.length source
                  .&&. all (\(a, b) -> a == b || (a, b) `elem` [(' ', 'x'), ('x', ' ')]) (T.zip source new)
    prop "gives the text back after ticking and unticking" $
      forAll genPage $ \source -> forAll (genTicks source) $ \ticks ->
        let wanted = Map.fromList ticks
            back = Map.fromList [(i, t.done) | (i, _) <- ticks, t <- allTasks (tasksIn source), t.index == i]
         in (applyTicks wanted source >>= applyTicks back) === Right source

  describe "the rules of ticking (tick)" $ do
    let page = tasksIn "- [ ] a\n  - [ ] b\n    - [ ] c\n    - [ ] d\n  - [ ] e\n- [ ] f\n"
        clicks = foldl' (\ticks (i, v) -> tick page ticks i v) mempty
    it "ticks one task alone" $
      clicks [(5, True)] `shouldBe` Map.fromList [(5, True)]
    it "ticks the tasks under a task with it, at every depth" $
      clicks [(0, True)] `shouldBe` Map.fromList [(i, True) | i <- [0 .. 4]]
    it "unticks the tasks under a task with it" $
      tick (tasksIn "- [x] a\n  - [x] b\n    - [x] c\n- [x] f\n") mempty 0 False `shouldBe` Map.fromList [(0, False), (1, False), (2, False)]
    it "ticks a task when the last task under it is ticked, at every depth" $ do
      clicks [(2, True)] `shouldBe` Map.fromList [(2, True)]
      clicks [(2, True), (3, True)] `shouldBe` Map.fromList [(1, True), (2, True), (3, True)]
      clicks [(2, True), (3, True), (4, True)] `shouldBe` Map.fromList [(i, True) | i <- [0 .. 4]]
    it "unticks every task above a task unticked" $
      clicks [(0, True), (3, False)] `shouldBe` Map.fromList [(2, True), (4, True)]
    it "counts the tasks under a task through an item that is no task" $ do
      let through = tasksIn "- [ ] a\n  - b\n    - [ ] c\n"
      tick through mempty 1 True `shouldBe` Map.fromList [(0, True), (1, True)]
    it "leaves a tick that returns a box to the text's state out" $
      clicks [(5, True), (5, False)] `shouldBe` mempty
    it "leaves the boxes off the path as they are, though they disagree with the rules" $ do
      let odd' = tasksIn "- [x] a\n  - [ ] b\n- [ ] c\n"
      tick odd' mempty 2 True `shouldBe` Map.fromList [(2, True)]
    it "changes nothing for an index the page has no task of" $
      tick page mempty 9 True `shouldBe` mempty

  describe "moving ticks to a new text (rebaseTicks)" $ do
    it "moves them when the tasks are the same" $
      rebaseTicks (tasksIn "- [ ] a\n- [ ] b\n") (tasksIn "Intro\n\n- [ ] a\n- [x] b\n") (Map.fromList [(0, True), (1, True)])
        `shouldBe` Just (Map.fromList [(0, True)])
    it "does not when a task was added, removed or changed" $ do
      rebaseTicks (tasksIn "- [ ] a\n- [ ] b\n") (tasksIn "- [ ] new\n- [ ] a\n- [ ] b\n") (Map.fromList [(0, True)]) `shouldBe` Nothing
      rebaseTicks (tasksIn "- [ ] a\n- [ ] b\n") (tasksIn "- [ ] a\n- [ ] c\n") (Map.fromList [(0, True)]) `shouldBe` Nothing
