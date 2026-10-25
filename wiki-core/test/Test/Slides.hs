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
