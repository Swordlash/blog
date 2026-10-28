-- | A page read as slides: where it is cut, what each slide's title, body
-- and notes are, and what the deck's options say. These run on both
-- backends: the browser cuts the deck too.
module Test.Slides (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Ast
import Wiki.Core.Slides

deck :: Text -> Deck
deck source = either (panic . show) deckOf (parseMarkdown source)

blocks :: Text -> [Block]
blocks = either (panic . show) identity . parseMarkdown

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
    it "makes a page without a break one slide" $
      outline (deck "# Title\n\nSome text.") `shouldBe` [(Just "Title", [Para [Str "Some text."]], [])]

    it "cuts the page at each thematic break, whichever way it is written" $
      map (\(t, _, _) -> t) (outline (deck "## One\n\n---\n\n## Two\n\n***\n\n## Three\n\n___\n\n## Four"))
        `shouldBe` [Just "One", Just "Two", Just "Three", Just "Four"]

    it "leaves a break inside a list, a quotation or a box on its slide" $ do
      let d = deck "Before\n\n> quoted\n>\n> ---\n\n::: warning\n---\n:::\n\n- a\n\n  ***\n"
      length d.slides `shouldBe` 1
      isDeck (blocks "> a\n>\n> ---\n") `shouldBe` False

    it "does not take a setext heading's underline for a break" $ do
      outline (deck "Title\n---\n\nText") `shouldBe` [(Just "Title", [Para [Str "Text"]], [])]
      isDeck (blocks "Title\n---\n\nText") `shouldBe` False

    it "takes the first heading of a slide as its title, wherever it is, and only that one" $
      outline (deck "Intro text.\n\n## Title\n\n### Sub\n\nMore.")
        `shouldBe` [(Just "Title", [Para [Str "Intro text."], Heading 3 [("id", "sub")] [Str "Sub"], Para [Str "More."]], [])]

    it "keeps the title's level and attributes" $
      map (\s -> (\t -> (t.level, t.attributes)) <$> s.title) (deck "# Start {#begin .big}\n\n---\n\n## Next").slides
        `shouldBe` [Just (1, [("id", "begin"), ("class", "big")]), Just (2, [("id", "next")])]

    it "leaves a slide without a heading untitled" $
      outline (deck "Just text.") `shouldBe` [(Nothing, [Para [Str "Just text."]], [])]

    it "takes notes out of the slide, all of them, in order" $
      outline (deck "## Title\n\n::: notes\nSay hello.\n:::\n\nShown.\n\n::: {.notes}\nThen this.\n:::")
        `shouldBe` [(Just "Title", [Para [Str "Shown."]], [Para [Str "Say hello."], Para [Str "Then this."]])]

    it "keeps a box of another class on the slide" $
      outline (deck "::: warning\nCareful.\n:::")
        `shouldBe` [(Nothing, [Div [("class", "warning")] [Para [Str "Careful."]]], [])]

    it "drops the empty slides a break at the start, the end or twice in a row makes" $
      map (\(t, _, _) -> t) (outline (deck "---\n\n## A\n\n---\n\n---\n\n## B\n\n---\n"))
        `shouldBe` [Just "A", Just "B"]

    it "keeps a slide that has only notes" $
      outline (deck "## A\n\n---\n\n::: notes\nPause here.\n:::")
        `shouldBe` [(Just "A", [], []), (Nothing, [], [Para [Str "Pause here."]])]

    it "makes an empty page one empty slide" $ do
      outline (deck "") `shouldBe` [(Nothing, [], [])]
      outline (deck "---\n\n---") `shouldBe` [(Nothing, [], [])]

    it "puts each footnote on the first slide that refers to it, and the rest on the last" $ do
      let d = deck "## A\n\nOne[^1].\n\n---\n\n## B\n\nTwo[^2] and one again[^1].\n\n---\n\n## C\n\nNone.\n\n[^1]: First.\n\n[^2]: Second.\n"
          notesOn s = [n | Footnotes ns <- s.body, Footnote n _ _ <- ns]
      map notesOn d.slides `shouldBe` [[1], [2], []]

    it "puts a footnote referred to only in the notes with the slide" $ do
      let d = deck "## A\n\n::: notes\nSee[^n].\n:::\n\n---\n\n## B\n\n[^n]: The note.\n"
      [n | s <- d.slides, Footnotes ns <- s.body, Footnote n _ _ <- ns] `shouldBe` [1]
      map (\s -> length [() | Footnotes _ <- s.body]) d.slides `shouldBe` [1, 0]

  describe "steps" $ do
    it "leaves a deck without pauses or incremental lists one step a slide, unmarked" $ do
      let d = deck "## A\n\nText.\n\n- one\n- two\n\n---\n\n## B\n\n::: warning\nCareful.\n:::"
      map (\s -> s.steps) d.slides `shouldBe` [1, 1]
      map (atStep 1) d.slides `shouldBe` map (\s -> s.body) d.slides
      (head d.slides <&> \s -> s.body) `shouldBe` Just [Para [Str "Text."], List BulletList [ListItem Nothing [Plain [Str "one"]], ListItem Nothing [Plain [Str "two"]]]]

    it "cuts a slide at each pause, each step showing everything up to it" $ do
      let s = slide "## A\n\nOne\n\n. . .\n\nTwo\n\n.  .  .\n\nThree"
      s.steps `shouldBe` 3
      s.body `shouldBe` [Para [Str "One"], stepMark 2 [Para [Str "Two"]], stepMark 3 [Para [Str "Three"]]]
      map (`atStep` s) [1, 2, 3] `shouldBe` [[Para [Str "One"]], [Para [Str "One"], Para [Str "Two"]], [Para [Str "One"], Para [Str "Two"], Para [Str "Three"]]]

    it "shows an incremental list one item at a time, the first with what comes before it" $ do
      let s = slide "Intro\n\n::: incremental\n- a\n- b\n- c\n:::\n"
          upTo n = [Para [Str "Intro"], Div [("class", "incremental")] [List BulletList [ListItem Nothing [Plain [Str x]] | x <- take n ["a", "b", "c"]]]]
      s.steps `shouldBe` 3
      map (`atStep` s) [1, 2, 3] `shouldBe` map upTo [1, 2, 3]

    it "counts steps as Beamer does around an incremental list" $ do
      -- What follows the list without a pause shows with its first item;
      -- a pause after it starts the step after its last item.
      let s = slide "::: incremental\n- a\n- b\n:::\n\nAfter\n\n. . .\n\nEnd"
      s.steps `shouldBe` 3
      plainOf (atStep 1 s) `shouldBe` ["a", "After"]
      plainOf (atStep 2 s) `shouldBe` ["a", "b", "After"]
      plainOf (atStep 3 s) `shouldBe` ["a", "b", "After", "End"]
      -- A list after a pause starts at the pause's step.
      let t = slide "One\n\n. . .\n\n::: incremental\n- a\n- b\n:::\n"
      t.steps `shouldBe` 3
      map (plainOf . (`atStep` t)) [1, 2, 3] `shouldBe` [["One"], ["One", "a"], ["One", "a", "b"]]

    it "steps through nested lists' items in order, and not in a nonincremental box" $ do
      let s = slide "::: incremental\n- a\n  - a1\n  - a2\n- b\n\n::: nonincremental\n- c\n- d\n:::\n:::\n"
      s.steps `shouldBe` 4
      map (plainOf . (`atStep` s)) [1, 2, 3, 4]
        `shouldBe` [["a", "c", "d"], ["a", "a1", "c", "d"], ["a", "a1", "a2", "c", "d"], ["a", "a1", "a2", "b", "c", "d"]]

    it "reads a pause in a box and in a list item, and goes on from it after them" $ do
      let s = slide "::: warning\nFirst\n\n. . .\n\nSecond\n:::\n\nAfter"
      s.steps `shouldBe` 2
      atStep 1 s `shouldBe` [Div [("class", "warning")] [Para [Str "First"]]]
      atStep 2 s `shouldBe` [Div [("class", "warning")] [Para [Str "First"], Para [Str "Second"]], Para [Str "After"]]
      s.body `shouldBe` [Div [("class", "warning")] [Para [Str "First"], stepMark 2 [Para [Str "Second"]]], stepMark 2 [Para [Str "After"]]]
      let t = slide "- a\n\n  . . .\n\n  more\n\n- b\n"
      t.steps `shouldBe` 2
      map (plainOf . (`atStep` t)) [1, 2] `shouldBe` [["a"], ["a", "more", "b"]]
      t.body `shouldBe` [List BulletList [ListItem Nothing [Para [Str "a"], stepMark 2 [Para [Str "more"]]], ListItem Nothing [Para [Str "b"], itemMark 2]]]

    it "leaves three dots in code, a quotation or a footnote alone" $ do
      let s = slide "```\n. . .\n```\n\n> . . .\n\nSee[^1].\n\n[^1]: . . .\n"
      s.steps `shouldBe` 1
      [b | b@(CodeBlock {}) <- s.body] `shouldBe` [CodeBlock [] Nothing ". . .\n"]
      [b | b@(BlockQuote _) <- s.body] `shouldBe` [BlockQuote [Para [Str ". . ."]]]
      [bs | Footnotes ns <- s.body, Footnote _ _ bs <- ns] `shouldBe` [[Para [Str ". . ."]]]

    it "does not cut the notes, nor count a pause that nothing follows" $ do
      let s = slide "One\n\n::: notes\nSay this.\n\n. . .\n\nThen that.\n:::\n\n. . .\n"
      s.steps `shouldBe` 1
      s.body `shouldBe` [Para [Str "One"]]
      s.notes `shouldBe` [Para [Str "Say this."], Pause, Para [Str "Then that."]]

    it "drops a slide that has nothing but pauses" $
      length (deck "## A\n\n---\n\n. . .\n\n---\n\n## B").slides `shouldBe` 2

    it "marks the pieces shown later with a class that hides them, keeping them in place" $ do
      let s = slide "One\n\n. . .\n\n- a\n\n. . .\n\n::: incremental\n- b\n- c\n:::\n"
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
      (deck "## A\n\n---\n\n## B").options `shouldBe` DeckOptions {theme = Beamer, aspect = Wide}

    it "are read from a slides div's attributes, which shows nothing" $ do
      let d = deck "::: {.slides theme=dark aspect=4:3}\n:::\n\n## A\n\n---\n\n## B"
      d.options `shouldBe` DeckOptions {theme = Dark, aspect = Standard}
      map (\(t, b, _) -> (t, b)) (outline d) `shouldBe` [(Just "A", []), (Just "B", [])]

    it "read a theme and an aspect written in other ways" $ do
      (deck "::: {.slides theme=\"Light\" aspect=\"4/3\"}\n:::").options `shouldBe` DeckOptions {theme = Light, aspect = Standard}
      (deck "::: {.slides aspect=16:9}\n:::").options `shouldBe` DeckOptions {theme = Beamer, aspect = Wide}

    it "fall back to the default for a name they do not know" $
      (deck "::: {.slides theme=madrid aspect=21:9}\n:::").options `shouldBe` defaultDeckOptions

    it "are named as the attributes write them" $ do
      map themeName [minBound .. maxBound] `shouldBe` ["beamer", "light", "dark"]
      map aspectName [minBound .. maxBound] `shouldBe` ["16:9", "4:3"]

  describe "isDeck" $ do
    it "is a page with a break at its top level" $ do
      isDeck (blocks "a\n\n---\n\nb") `shouldBe` True
      isDeck (blocks "# Just a page\n\nText.") `shouldBe` False

    it "is a page that says how its slides look, even as one slide" $
      isDeck (blocks "::: slides\n:::\n\n# One slide") `shouldBe` True
