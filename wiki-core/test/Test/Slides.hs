-- | A presentation read as slides: where it is cut, what each slide's title, body
-- and notes are, and what the deck's options say. These run on both
-- backends: the browser cuts the deck too.
module Test.Slides (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf, (===))
import Wiki.Core.Markdown.Ast
import Wiki.Core.Slides

deck :: Text -> Deck
deck source = either (panic . show) deckOf (parseMarkdown source)

-- | The only slide of a page.
slide :: Text -> Slide
slide source = case (deck source).slides of
  [s] -> s
  ss -> panic ("not one slide: " <> show (length ss))

-- | The text of each paragraph and list item of some blocks, in order.
plainOf :: [Block] -> [Text]
plainOf = concatMap $ \case
  Para xs -> [plainText xs]
  Plain xs -> [plainText xs]
  Div _ bs -> plainOf bs
  List _ items -> concat [plainOf bs | ListItem _ bs <- items]
  _ -> []

-- | Each slide's title text, body and notes, the easier to compare.
outline :: Deck -> [(Maybe Text, [Block], [Block])]
outline d = [(plainText . (\t -> t.text) <$> s.title, s.body, s.notes) | s <- d.slides]

spec :: Spec
spec = describe "Slides" $ do
  describe "deckOf" $ do
    it "makes a page without a heading of level one or two one slide" $
      outline (deck "Some text.\n\n### A small heading\n\nMore.") `shouldBe` [(Nothing, [Para [Str "Some text."], Heading 3 [("id", "a-small-heading")] [Str "A small heading"], Para [Str "More."]], [])]

    it "opens a slide at each heading of level one or two, the heading its title" $
      map (\(t, _, _) -> t) (outline (deck "# Talk\n\nBy me.\n\n## One\n\nA.\n\n## Two\n\n# Part two\n\n## Three"))
        `shouldBe` [Just "Talk", Just "One", Just "Two", Just "Part two", Just "Three"]

    it "takes a setext heading of level two for an opener, as an ATX one" $
      outline (deck "Title\n---\n\nText") `shouldBe` [(Just "Title", [Para [Str "Text"]], [])]

    it "leaves a thematic break a rule on its slide" $
      outline (deck "## One\n\nA\n\n---\n\nB")
        `shouldBe` [(Just "One", [Para [Str "A"], ThematicBreak, Para [Str "B"]], [])]

    it "keeps a heading of level three or more, and a heading below the top level, on its slide" $ do
      outline (deck "## Title\n\n### Sub\n\nMore.")
        `shouldBe` [(Just "Title", [Heading 3 [("id", "sub")] [Str "Sub"], Para [Str "More."]], [])]
      length (deck "## A\n\n> ## Quoted\n\n- ## Listed\n\n[[!div]]{.warning}\n## Boxed\n[[/div]]\n").slides `shouldBe` 1
      -- Nor is a line with two hashes in code an opener.
      length (deck "## A\n\n```\n## not a heading\n```\n").slides `shouldBe` 1

    it "makes what comes before the first opener a slide without a title" $
      outline (deck "Intro text.\n\n## Title\n\nMore.")
        `shouldBe` [(Nothing, [Para [Str "Intro text."]], []), (Just "Title", [Para [Str "More."]], [])]

    it "reads a heading spoiler of level one or two as its heading, opening a slide, and its section as the slide" $ do
      map (\(t, _, _) -> t) (outline (deck "## [[!spoiler]] Q\n\nA.\n\n## [[!spoiler]]{r} R\n\nB.\n\n## Plain"))
        `shouldBe` [Just "Q", Just "R", Just "Plain"]
      -- A level-one heading spoiler's section holds the openers after it,
      -- which open their slides all the same.
      map (\(t, _, _) -> t) (outline (deck "# [[!spoiler]] Part\n\n## One\n\n## Two"))
        `shouldBe` [Just "Part", Just "One", Just "Two"]

    it "keeps the title's level and attributes" $
      map (\s -> (\t -> (t.level, t.attributes)) <$> s.title) (deck "# Start {#begin .big}\n\n## Next").slides
        `shouldBe` [Just (1, [("id", "begin"), ("class", "big")]), Just (2, [("id", "next")])]

    it "takes notes out of the slide, all of them, in order" $
      outline (deck "## Title\n\n[[!notes]]\nSay hello.\n[[/notes]]\n\nShown.\n\n[[!div]]{.notes}\nThen this.\n[[/div]]")
        `shouldBe` [(Just "Title", [Para [Str "Shown."]], [Para [Str "Say hello."], Para [Str "Then this."]])]

    it "keeps a box of another class on the slide" $
      outline (deck "[[!div]]{.warning}\nCareful.\n[[/div]]")
        `shouldBe` [(Nothing, [Div [("class", "warning")] [Para [Str "Careful."]]], [])]

    it "makes no slide of nothing before the first opener, nor of the look alone" $
      map (\(t, _, _) -> t) (outline (deck "[[!style]]{theme=dark}\n\n## A\n\n## B"))
        `shouldBe` [Just "A", Just "B"]

    it "keeps a slide that has only notes" $
      outline (deck "[[!notes]]\nPause here.\n[[/notes]]\n\n## A")
        `shouldBe` [(Nothing, [], [Para [Str "Pause here."]]), (Just "A", [], [])]

    it "makes an empty page one empty slide" $
      outline (deck "") `shouldBe` [(Nothing, [], [])]

    prop "has, one for one and in order, the page's openers as its slides' titles" $
      forAll (listOf piece) $ \pieces ->
        let source = T.intercalate "\n\n" (map fst pieces)
            openers = [t | (_, Just t) <- pieces]
            titled = [plainText t.text | s <- (deck source).slides, Just t <- [s.title]]
         in titled === openers

    it "puts each footnote on the first slide that refers to it, and the rest on the last" $ do
      let d = deck "## A\n\nOne[^1].\n\n## B\n\nTwo[^2] and one again[^1].\n\n## C\n\nNone.\n\n[^1]: First.\n\n[^2]: Second.\n"
          notesOn s = [n | Footnotes ns <- s.body, Footnote n _ _ <- ns]
      map notesOn d.slides `shouldBe` [[1], [2], []]

    it "puts a footnote referred to only in a box's title with the slide" $ do
      let d = deck "## A\n\n> [!TIP] See[^n]\n> Text.\n\n## B\n\n[^n]: The note.\n"
          notesOn s = [n | Footnotes ns <- s.body, Footnote n _ _ <- ns]
      map notesOn d.slides `shouldBe` [[1], []]

    it "puts a footnote referred to only in the notes with the slide" $ do
      let d = deck "## A\n\n[[!notes]]\nSee[^n].\n[[/notes]]\n\n## B\n\n[^n]: The note.\n"
      [n | s <- d.slides, Footnotes ns <- s.body, Footnote n _ _ <- ns] `shouldBe` [1]
      map (\s -> length [() | Footnotes _ <- s.body]) d.slides `shouldBe` [1, 0]

  describe "steps" $ do
    it "leaves a deck without pauses or incremental lists one step a slide, unmarked" $ do
      let d = deck "## A\n\nText.\n\n- one\n- two\n\n## B\n\n[[!div]]{.warning}\nCareful.\n[[/div]]"
      map (\s -> s.steps) d.slides `shouldBe` [1, 1]
      map (atStep 1) d.slides `shouldBe` map (\s -> s.body) d.slides
      (head d.slides <&> \s -> s.body) `shouldBe` Just [Para [Str "Text."], List BulletList [ListItem Nothing [Plain [Str "one"]], ListItem Nothing [Plain [Str "two"]]]]

    it "cuts a slide at each pause, each step showing everything up to it" $ do
      let s = slide "## A\n\nOne\n\n[[!pause]]\n\nTwo\n\n[[!pause]]\n\nThree"
      s.steps `shouldBe` 3
      s.body `shouldBe` [Para [Str "One"], stepMark 2 [Para [Str "Two"]], stepMark 3 [Para [Str "Three"]]]
      map (`atStep` s) [1, 2, 3] `shouldBe` [[Para [Str "One"]], [Para [Str "One"], Para [Str "Two"]], [Para [Str "One"], Para [Str "Two"], Para [Str "Three"]]]

    it "reads a line of attributes with the class incremental before a list as an incremental box" $ do
      let s = slide "Intro\n\n{.incremental}\n- a\n- b\n"
      s.steps `shouldBe` 2
      map (plainOf . (`atStep` s)) [1, 2] `shouldBe` [["Intro", "a"], ["Intro", "a", "b"]]

    it "shows an incremental list one item at a time, the first with what comes before it" $ do
      let s = slide "Intro\n\n[[!incremental]]\n- a\n- b\n- c\n[[/incremental]]\n"
          upTo n = [Para [Str "Intro"], Div [("class", "incremental")] [List BulletList [ListItem Nothing [Plain [Str x]] | x <- take n ["a", "b", "c"]]]]
      s.steps `shouldBe` 3
      map (`atStep` s) [1, 2, 3] `shouldBe` map upTo [1, 2, 3]

    it "counts steps as Beamer does around an incremental list" $ do
      -- What follows the list without a pause shows with its first item;
      -- a pause after it starts the step after its last item.
      let s = slide "[[!incremental]]\n- a\n- b\n[[/incremental]]\n\nAfter\n\n[[!pause]]\n\nEnd"
      s.steps `shouldBe` 3
      plainOf (atStep 1 s) `shouldBe` ["a", "After"]
      plainOf (atStep 2 s) `shouldBe` ["a", "b", "After"]
      plainOf (atStep 3 s) `shouldBe` ["a", "b", "After", "End"]
      -- A list after a pause starts at the pause's step.
      let t = slide "One\n\n[[!pause]]\n\n[[!incremental]]\n- a\n- b\n[[/incremental]]\n"
      t.steps `shouldBe` 3
      map (plainOf . (`atStep` t)) [1, 2, 3] `shouldBe` [["One"], ["One", "a"], ["One", "a", "b"]]

    it "steps through nested lists' items in order, and not in a nonincremental box" $ do
      let s = slide "[[!incremental]]\n- a\n  - a1\n  - a2\n- b\n\n[[!div]]{.nonincremental}\n- c\n- d\n[[/div]]\n[[/incremental]]\n"
      s.steps `shouldBe` 4
      map (plainOf . (`atStep` s)) [1, 2, 3, 4]
        `shouldBe` [["a", "c", "d"], ["a", "a1", "c", "d"], ["a", "a1", "a2", "c", "d"], ["a", "a1", "a2", "b", "c", "d"]]

    it "reads a pause in a box and in a list item, and goes on from it after them" $ do
      let s = slide "[[!div]]{.warning}\nFirst\n\n[[!pause]]\n\nSecond\n[[/div]]\n\nAfter"
      s.steps `shouldBe` 2
      atStep 1 s `shouldBe` [Div [("class", "warning")] [Para [Str "First"]]]
      atStep 2 s `shouldBe` [Div [("class", "warning")] [Para [Str "First"], Para [Str "Second"]], Para [Str "After"]]
      s.body `shouldBe` [Div [("class", "warning")] [Para [Str "First"], stepMark 2 [Para [Str "Second"]]], stepMark 2 [Para [Str "After"]]]
      let t = slide "- a\n\n  [[!pause]]\n\n  more\n\n- b\n"
      t.steps `shouldBe` 2
      map (plainOf . (`atStep` t)) [1, 2] `shouldBe` [["a"], ["a", "more", "b"]]
      t.body `shouldBe` [List BulletList [ListItem Nothing [Para [Str "a"], stepMark 2 [Para [Str "more"]]], ListItem Nothing [Para [Str "b"], itemMark 2]]]

    it "reads a pause in a quotation, and goes on from it after the quotation" $ do
      let s = slide "> First\n>\n> [[!pause]]\n>\n> Second\n\nAfter"
      s.steps `shouldBe` 2
      atStep 1 s `shouldBe` [BlockQuote [Para [Str "First"]]]
      atStep 2 s `shouldBe` [BlockQuote [Para [Str "First"], Para [Str "Second"]], Para [Str "After"]]

    it "reads no pause in code or a footnote, nor three dots anywhere" $ do
      let s = slide "```\n[[!pause]]\n```\n\nSee[^1].\n\n[^1]: [[!pause]]\n\n. . .\n"
          why = "a pause is not read in a footnote, which a presentation shows whole"
      s.steps `shouldBe` 1
      [b | b@(CodeBlock {}) <- s.body] `shouldBe` [CodeBlock [] Nothing "[[!pause]]\n"]
      [bs | Footnotes ns <- s.body, Footnote _ _ bs <- ns] `shouldBe` [[MarkerError "[[!pause]]" why]]
      [b | b@(Para [Str ". . ."]) <- s.body] `shouldBe` [Para [Str ". . ."]]

    it "does not cut the notes, nor count a pause that nothing follows" $ do
      let s = slide "One\n\n[[!notes]]\nSay this.\n\n[[!pause]]\n\nThen that.\n[[/notes]]\n\n[[!pause]]\n"
      s.steps `shouldBe` 1
      s.body `shouldBe` [Para [Str "One"]]
      s.notes `shouldBe` [Para [Str "Say this."], Pause, Para [Str "Then that."]]

    it "drops a slide that has nothing but pauses" $
      length (deck "[[!pause]]\n\n## A\n\n## B").slides `shouldBe` 2

    it "marks the pieces shown later with a class that hides them, keeping them in place" $ do
      let s = slide "One\n\n[[!pause]]\n\n- a\n\n[[!pause]]\n\n[[!incremental]]\n- b\n- c\n[[/incremental]]\n"
          later = ("class", "slide-step slide-step-later")
      s.steps `shouldBe` 4
      (showingStep 4 s).body `shouldBe` s.body
      (showingStep 1 s).body
        `shouldBe` [ Para [Str "One"]
                   , Div [later, ("data-step", "2")] [List BulletList [ListItem Nothing [Plain [Str "a"]]]]
                   , Div [later, ("data-step", "3")] [Div [("class", "incremental")] [List BulletList [ListItem Nothing [Plain [Str "b"]], ListItem Nothing [Plain [Str "c"], Div [("class", "slide-step-item slide-step-later"), ("data-step", "4")] []]]]]
                   ]
      atStep 3 (showingStep 1 s) `shouldBe` atStep 3 s

  describe "options" $ do
    it "are Beamer's look on a wide slide unless the page says otherwise" $
      (deck "## A\n\n## B").options `shouldBe` DeckOptions {theme = Beamer, aspect = Wide}

    it "are read from the line [[!style]], which shows nothing" $ do
      let d = deck "[[!style]]{theme=dark aspect=4:3}\n\n## A\n\n## B"
      d.options `shouldBe` DeckOptions {theme = Dark, aspect = Standard}
      map (\(t, b, _) -> (t, b)) (outline d) `shouldBe` [(Just "A", []), (Just "B", [])]

    it "are read from the first look only, and not from a box of another name" $ do
      (deck "[[!style]]{theme=light}\n\n[[!style]]{theme=dark}").options `shouldBe` DeckOptions {theme = Light, aspect = Wide}
      (deck "[[!div]]{.slides theme=dark}\n[[/div]]\n\n[[!div]]{.style theme=dark}\n[[/div]]").options `shouldBe` defaultDeckOptions

    it "read a theme and an aspect written in other ways" $ do
      (deck "[[!style]]{theme=\"Light\" aspect=\"4/3\"}").options `shouldBe` DeckOptions {theme = Light, aspect = Standard}
      (deck "[[!style]]{aspect=16:9}").options `shouldBe` DeckOptions {theme = Beamer, aspect = Wide}

    it "fall back to the default for a name they do not know" $
      (deck "[[!style]]{theme=madrid aspect=21:9}").options `shouldBe` defaultDeckOptions

    it "are named as the attributes write them" $ do
      map themeName [minBound .. maxBound] `shouldBe` ["beamer", "light", "dark"]
      map aspectName [minBound .. maxBound] `shouldBe` ["16:9", "4:3"]

-- | A piece of a page, its Markdown and, when it opens a slide, its
-- title: the openers in every way they are written, and blocks that look
-- like openers and are not (a heading inside a quotation, a list or a
-- box, two hashes in code, a level-three heading, a thematic break, text
-- under it that is a paragraph).
piece :: Gen (Text, Maybe Text)
piece = do
  word <- elements ["Alpha", "Beta", "Gamma", "Delta"]
  elements
    [ ("# " <> word, Just word)
    , ("## " <> word, Just word)
    , (word <> "\n---", Just word)
    , ("## [[!spoiler]] " <> word <> "\n\nInside.", Just word)
    , ("### " <> word, Nothing)
    , ("> ## " <> word, Nothing)
    , ("- ## " <> word, Nothing)
    , ("[[!div]]{.box}\n## " <> word <> "\n[[/div]]", Nothing)
    , ("```\n## " <> word <> "\n```", Nothing)
    , ("Text of " <> word <> ".", Nothing)
    , ("---", Nothing)
    , ("[[!pause]]", Nothing)
    , ("[[!notes]]\n## " <> word <> "\n[[/notes]]", Nothing)
    ]
