-- | A presentation read as slides: where it is cut, what each slide's title, body
-- and notes are, and what the deck's options say. These run on both
-- backends: the browser cuts the deck too.
module Test.Slides (spec, aDeck, aMove) where

import Data.Text qualified as T
import Protolude
import System.Mem (getAllocationCounter, setAllocationCounter)
import Test.Hspec
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck (Gen, choose, conjoin, counterexample, elements, forAll, listOf, suchThat, vectorOf, (.&&.), (===), (==>))
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Folds qualified as Folds
import Wiki.Core.Markdown.Problems (Checked (..), Problem (..), checkText, kindProblems)
import Wiki.Core.PageKind (PageKind (..))
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

    prop "and the editor's warnings agree: a look it reads and a heading it opens a slide at are never warned of" $
      forAll (listOf aPiece) $ \pieces ->
        let numbered = zip [0 :: Int ..] pieces
            texts = [render i p | (i, p) <- numbered]
            source = T.intercalate "\n\n" texts
            -- The line each piece starts on.
            starts = scanl (\l t -> l + length (T.lines t) + 1) 1 texts
            atStart = zip starts pieces
            d = deck source
            warned = [(p.from, p.message) | p <- kindProblems Presentation source]
            openerLines = sort [l | (l, m) <- warned, "A heading of level one or two" `T.isPrefixOf` m]
            styleLines = sort [l | (l, m) <- warned, "[[!style]]" `T.isInfixOf` m]
            topStyles = [(l, t) | (l, Look t) <- atStart]
            expectedOptions = maybe defaultDeckOptions (\(_, t) -> DeckOptions {theme = t, aspect = Standard}) (head topStyles)
         in conjoin
              [ [plainText t.text | s <- d.slides, Just t <- [s.title]] === [w | (_, Opener _ w) <- atStart]
              , openerLines === sort [l | (l, Nested) <- atStart]
              , d.options === expectedOptions
              , styleLines === sort (map fst (drop 1 topStyles) <> [l | (l, NestedLook) <- atStart])
              ]

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

    it "reads a pause among a paragraph's words, shown from the next step with what follows" $ do
      let s = slide "## A\n\nOne [[!pause]] two\n\nThree"
      s.steps `shouldBe` 2
      atStep 1 s `shouldBe` [Para [Str "One "]]
      atStep 2 s `shouldBe` [Para [Str "One ", Str " two"], Para [Str "Three"]]
      (showingStep 1 s).body
        `shouldBe` [Para [Str "One ", Marked [("class", "slide-step slide-step-later"), ("data-step", "2")] [Str " two"]], Div [("class", "slide-step slide-step-later"), ("data-step", "2")] [Para [Str "Three"]]]
      -- In a list item's text, the items after it wait too.
      let t = slide "- a [[!pause]] b\n- c\n"
      t.steps `shouldBe` 2
      map (plainOf . (`atStep` t)) [1, 2] `shouldBe` [["a "], ["a  b", "c"]]

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

  describe "slideSpans" $ do
    it "finds each slide's lines, its level and its title, and what comes before the first" $ do
      let spans = slideSpans "Notes first.\n\n# Deck\n\nBy me.\n\n## One\n\nText.\n\n\nTwo\n---\n- a\n"
      map (\sp -> (sp.from, sp.to, sp.level, sp.title)) spans
        `shouldBe` [(1, 1, Nothing, ""), (3, 5, Just 1, "Deck"), (7, 9, Just 2, "One"), (12, 14, Just 2, "Two")]
      fixedSlides spans `shouldBe` 2
      map (slideAtLine spans) [1, 2, 6, 7, 15] `shouldBe` [Just 0, Just 0, Just 1, Just 2, Just 3]

    it "opens a slide inside a heading spoiler, as 'deckOf' does, and none at a quoted heading" $
      map (\sp -> sp.title) (slideSpans "# [[!spoiler]] A\n\n## Inside\n\n[[!style]]{theme=dark}\n\n# B\n\n> ## Quoted\n")
        `shouldBe` ["A", "Inside", "B"]

    prop "has the slides 'deckOf' has, with the same titles" $
      forAll aDeck $ \source ->
        let slides = (deck source).slides
            blankDeck = case slides of
              [s] -> isNothing s.title && null s.body && null s.notes
              _ -> False
         in [sp.title <$ sp.level | sp <- slideSpans source]
              === if blankDeck then [] else [plainText . (.text) <$> s.title | s <- slides]

    prop "are what the editor's check finds, from its one parse, for a presentation, and none for a document" $
      forAll aDeck $ \source ->
        (checkText Presentation source).slides === slideSpans source
          .&&. (checkText Document source).slides === []

    it "makes no slide of a look, footnotes or a pause alone before the first opener" $
      map (\sp -> sp.title) (slideSpans "[[!style]]{theme=dark}\n\n[^n]: A note.\n\n[[!pause]]\n\n## A\n\nSee[^n].\n")
        `shouldBe` ["A"]

    prop "starts a slide where the editor's fold of a page's section, or of a heading spoiler's, of level one or two starts" $
      forAll aDeck $ \source ->
        let starts = map (\sp -> sp.from) (slideSpans source)
            level f = case f.kind of
              Folds.Section n -> Just n
              Folds.HeadingSpoiler n -> Just n
              Folds.BlockSpoiler -> Nothing
         in [f.from | f <- Folds.folds source, Just n <- [level f], n <= 2, f.from `notElem` starts] === []

    it "has the slides of a text with carriage returns on CodeMirror's lines, a line feed ending a line" $ do
      -- \r\n: the parser's lines and CodeMirror's are the same.
      [(sp.from, sp.to, sp.title) | sp <- slideSpans "## A\r\n\r\nText\r\n\r\n## B\r\n"] `shouldBe` [(1, 3, "A"), (5, 5, "B")]
      -- \r\n\n is one line break for the parser and two for CodeMirror;
      -- a lone \r ends a line for the parser only.
      [(sp.from, sp.title) | sp <- slideSpans "## A\r\n\nText\r\n\n## B\rMore\n\n## C\n"] `shouldBe` [(1, "A"), (5, "B"), (7, "C")]
      -- The same slides as the text with line feeds alone.
      let returns = "# Deck\r\n\r\nBy me.\r\n\r\n## One\r\n\r\nFirst.\r\n\r\n## Two\r\nSecond.\r\n"
      slideSpans returns `shouldBe` slideSpans (T.replace "\r\n" "\n" returns)

    it "has no slides when two would start on one line of CodeMirror's, what comes before the first heading too" $ do
      slideSpans "## A\r## B\r\nText\n" `shouldBe` []
      slideSpans "Intro.\r## A\n\nText" `shouldBe` []

    prop "never puts two slides on one line of CodeMirror's, nor ends one before it starts, line breaks made lone carriage returns or not" $
      forAll ((,) <$> aDeck <*> listOf (elements [False, True])) $ \(source, lone) ->
        let pieces = T.splitOn "\n" (T.replace "\r" "" source)
            breaks = take (length pieces - 1) (lone <> repeat False)
            text = T.concat (zipWith (\line r -> line <> (if r then "\r" else "\n")) pieces breaks) <> fromMaybe "" (lastMay pieces)
            spans = slideSpans text
         in counterexample (show (text, spans)) $
              and (zipWith (<) (map (\sp -> sp.from) spans) (drop 1 (map (\sp -> sp.from) spans))) && all (\sp -> sp.to >= sp.from) spans

    prop "has the slides of a text with \\r\\n line breaks that the text with \\n has" $
      forAll aDeck $ \source ->
        let plain = T.replace "\r" "" source
         in slideSpans (T.replace "\n" "\r\n" plain) === slideSpans plain

    it "fixes nothing but the preamble when the first opener is of level two" $
      fixedSlides (slideSpans "## A\n\n# B\n") `shouldBe` 0

    prop "cuts the text into chunks that are the text again" $
      forAll aDeck $ \source ->
        let (lead, chunks) = slideChunks source
         in lead <> T.concat chunks === source

    prop "cuts the text where finding each slide's first character in the text's lines, slide by slide, cut it" $
      forAll aDeckWithBreaks $ \source ->
        let lineStart n = sum (map ((+ 1) . T.length) (take (n - 1) (T.splitOn "\n" source)))
            oracle = case slideSpans source of
              [] -> (source, [])
              spans ->
                let offsets = map (lineStart . (.from)) spans <> [T.length source]
                 in (T.take (fromMaybe 0 (head offsets)) source, zipWith (\a b -> T.take (b - a) (T.drop a source)) offsets (drop 1 offsets))
         in slideChunks source === oracle

  describe "moveSlide" $ do
    it "moves a slide's whole text, blank lines included" $
      moveSlide 1 0 "## A\n\nOne.\n\n## B\n\nTwo.\n" `shouldBe` "## B\n\nTwo.\n## A\n\nOne.\n\n"

    it "ends the last slide's text with a line break when another comes after it, and adds nothing else" $
      moveSlide 1 0 "## A\n\nOne.\n\n## B\nTwo." `shouldBe` "## B\nTwo.\n## A\n\nOne.\n\n"

    it "puts a blank line before a setext title that would end the paragraph above it" $
      moveSlide 1 2 "## A\n\nB\n---\n## C\nText." `shouldBe` "## A\n\n## C\nText.\n\nB\n---\n"

    it "moves neither the preamble nor the title slide, nor any slide before them" $ do
      let source = "Notes.\n\n# Deck\n\n## A\n\n## B\n"
      map (\(i, j) -> moveSlide i j source) [(0, 2), (1, 3), (3, 1), (2, 0), (2, 2), (2, 4), (4, 2)]
        `shouldBe` replicate 7 source
      moveSlide 3 2 source `shouldBe` "Notes.\n\n# Deck\n\n## B\n## A\n\n"

    it "moves nothing in a text with a carriage return" $
      moveSlide 1 0 "## A\r\n\r\n## B\r\n" `shouldBe` "## A\r\n\r\n## B\r\n"

    it "makes no move that would put slides in a fence or a box left open at the end" $ do
      let source = "## A\n\nOne.\n\n## B\n\n```\nopen"
      moveSlide 1 0 source `shouldBe` source
      let boxed = "## A\n\nOne.\n\n## B\n\n[[!notes]]\nopen"
      moveSlide 1 0 boxed `shouldBe` boxed
      moveSlide 0 1 source `shouldBe` source

    prop "puts the same slides in the new order, each slide's lines as they were, or makes no move" $
      forAll aMove $ \(source, i, j) ->
        let spans = slideSpans source
            (lead, chunks) = slideChunks source
            moved = moveSlide i j source
            spansAfter = slideSpans moved
            linesOf text sp = take (sp.to - sp.from + 1) (drop (sp.from - 1) (T.splitOn "\n" text))
            key sp = (sp.level, sp.title)
         in counterexample (show moved) $
              if i < fixedSlides spans || j < fixedSlides spans || i == j || i >= length spans || j >= length spans || moved == source
                then moved === source
                else
                  conjoin
                    [ map key spansAfter === map key (reorderAt i j spans)
                    , map (linesOf moved) spansAfter === map (linesOf source) (reorderAt i j spans)
                    , T.filter (/= '\n') moved === T.filter (/= '\n') (lead <> T.concat (reorderAt i j chunks))
                    ]

    prop "leaves the preamble and the title slide where and as they were" $
      forAll aMove $ \(source, i, j) ->
        let spans = slideSpans source
            fixed = take (fixedSlides spans) spans
            kept = take (length fixed) (slideSpans (moveSlide i j source))
            linesOf text sp = take (sp.to - sp.from + 1) (drop (sp.from - 1) (T.splitOn "\n" text))
         in map (linesOf (moveSlide i j source)) kept === map (linesOf source) fixed
              .&&. map (\sp -> sp.from) kept === map (\sp -> sp.from) fixed

    prop "adds at most one line break, and one more before a setext title at each of the three places a move joins slides" $
      forAll aMove $ \(source, i, j) ->
        let added = T.length (moveSlide i j source) - T.length source
            firstLine sp = fromMaybe "" (atMay (T.splitOn "\n" source) (sp.from - 1))
            setextTitles = [sp | sp <- slideSpans source, isJust sp.level, not ("#" `T.isPrefixOf` T.stripStart (firstLine sp))]
         in counterexample (show added) $
              added >= 0 && added <= (if null setextTitles then 1 else 4)

    prop "moves every slide of a deck whose blocks are all closed" $
      forAll aClosedMove $ \(source, i, j) ->
        let spans = slideSpans source
            texts = snd (slideChunks source)
         in i >= fixedSlides spans && j >= fixedSlides spans && i /= j && max i j < length spans && ordNub texts == texts ==>
              moveSlide i j source /= source

  describe "fitOf" $ do
    it "fits with half a line to spare, is tight up to a line cut, and overflows beyond" $ do
      map (`fitOf` 0) [-3, -0.5, -0.49, 0, 1, 1.01] `shouldBe` [Fits, Fits, Tight, Tight, Tight, Overflowing]

    it "is tight for any width beyond the body's, and overflows beyond a line" $ do
      map (fitOf (-3)) [0, 0.1, 1, 1.5] `shouldBe` [Fits, Tight, Tight, Overflowing]

    it "fits with two lines to spare, and with the room the guide's slide of keys has at its foot" $ do
      fitOf (-2) 0 `shouldBe` Fits
      -- The guide's "Presenting" slide, at 1024 pixels: its text ends 0.78
      -- of a line above the bottom of its body's padding, where the body
      -- cuts it, and 0.21 of a line above the top of that padding, the
      -- edge it was measured against before (WP5.102).
      (fitOf (-0.78) 0, fitOf (-0.21) 0) `shouldBe` (Fits, Tight)

  describe "fitsNow" $ do
    let measuredText = "# Deck\n\n## A\n\nOne.\n\n## B\n\nTwo.\n"
        measures = Just (measuresFor measuredText [Fits, Tight, Overflowing])
        now text = fitsNow measures text (slideSpans text)
    it "keeps each slide's fit for the text measured" $
      now measuredText `shouldBe` [Fits, Tight, Overflowing]

    it "forgets the fit of a slide whose lines changed, and keeps the others'" $
      now (T.replace "Two." "Two, longer." measuredText) `shouldBe` [Fits, Tight, Unmeasured]

    it "forgets every fit when the look changes, or nothing was measured" $ do
      now ("[[!style]]{aspect=4:3}\n\n" <> measuredText) `shouldSatisfy` all (== Unmeasured)
      fitsNow Nothing measuredText (slideSpans measuredText) `shouldBe` [Unmeasured, Unmeasured, Unmeasured]

    it "forgets the fits of the slides after one put before them" $
      now (T.replace "## A" "## New\n\n## A" measuredText) `shouldBe` [Fits, Unmeasured, Unmeasured, Unmeasured]

    -- WP5.108: the text is split once, not once for each slide; the
    -- fits are those the split for each slide gave.
    -- Counted in bytes allocated, not timed: four times the slides, about
    -- four times the work. Splitting the whole text for each slide made it
    -- about sixteen times.
    it "grows with the text's length and no faster: four times the slides, less than six times the bytes allocated" $ do
      ratios <- for [measuresWork, fitsWork, oldFitsWork] $ \work -> do
        small <- work 20
        large <- work 80
        pure (fromIntegral large / fromIntegral small :: Double)
      case ratios of
        [measuring, fitting, old] -> do
          (measuring, fitting) `shouldSatisfy` (\(a, b) -> a < 6 && b < 6)
          -- The count tells the two growths apart: the old split, once
          -- for each slide, grows more than ten times.
          old `shouldSatisfy` (> 10)
        _ -> expectationFailure "three measures"

    -- Fifty decks: each parses its text five times.
    modifyMaxSuccess (const 50) . prop "says what splitting the text for each slide said, the measures made from the text's slides or found again" $
      forAll ((,,) <$> aDeckWithBreaks <*> listOf (elements [Fits, Tight, Overflowing, Unmeasured]) <*> choose (0, length edits - 1)) $ \(source, fits, e) ->
        let later = maybe source ($ source) (atMay edits e)
            spansLater = slideSpans later
            oracle = oldFitsNow (Just (oldMeasuresFor source fits)) later spansLater
         in conjoin
              [ fitsNow (Just (measuresFor source fits)) later spansLater === oracle
              , fitsNow (Just (measuresWith source (slideSpans source) fits)) later spansLater === oracle
              , measuresWith source (slideSpans source) fits === measuresFor source fits
              ]

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

-- | 'APiece' is a piece of a presentation as the agreement of the slides
-- and the editor's warnings is tested with: what it is written as, and
-- what the slides and the warnings make of it.
data APiece
  = -- | A heading that opens a slide, written in one of its ways, and its
    -- title.
    Opener Text Text
  | -- | A heading of level one or two inside a block: warned of.
    Nested
  | -- | The look at the top level, with its theme.
    Look Theme
  | -- | The look inside a quotation: warned of, never read.
    NestedLook
  | -- | Anything else: text, a rule, code, a pause.
    Other Text
  deriving stock (Eq, Show)

-- | The pieces, with an opener's or a look's own in each.
aPiece :: Gen APiece
aPiece = do
  word <- elements ["Alpha", "Beta", "Gamma", "Delta"]
  theme <- elements [Light, Dark]
  elements
    [ Opener ("# " <> word) word
    , Opener ("## " <> word) word
    , Opener (word <> "\n---") word
    , Opener ("## [[!spoiler]] " <> word <> "\n\nInside.") word
    , Opener ("# [[!spoiler]] " <> word) word
    , Nested
    , Look theme
    , NestedLook
    , Other ("### " <> word)
    , Other ("Text of " <> word <> ".")
    , Other "---"
    , Other "```\n## not a heading\n```"
    , Other "[[!pause]]"
    ]

-- | A piece's Markdown, by its place among the pieces (a list's bullet
-- changes from one piece to the next, so that two lists in a row are
-- two lists).
render :: Int -> APiece -> Text
render i = \case
  Opener t _ -> t
  Nested -> case i `mod` 3 of
    0 -> "> ## Quoted"
    1 -> (if even i then "- " else "* ") <> "## Listed"
    _ -> "[[!div]]{.box}\n## Boxed\n[[/div]]"
  Look t -> "[[!style]]{theme=" <> themeName t <> " aspect=4:3}"
  NestedLook -> "> [[!style]]{theme=dark}"
  Other t -> t

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

-- | A presentation's source to move slides in: what may come before the
-- first opener, then the pieces of 'piece', apart by one, two or three
-- line breaks, and with or without a line break at the end.
aDeck :: Gen Text
aDeck = do
  preamble <- elements ["", "Notes first.\n\n", "\n\n"]
  title <- elements ["", "# Deck\n\nBy me.\n\n"]
  pieces <- listOf ((,) <$> piece <*> elements ["\n", "\n\n", "\n\n\n"])
  end <- elements ["", "\n", "\n```\nleft open", "\n[[!notes]]\nleft open"]
  pure (preamble <> title <> T.concat [t <> sep | ((t, _), sep) <- pieces] <> end)

-- | The bytes allocated in forcing a value: what its work costs, counted
-- rather than timed, so that a slow or a busy machine changes nothing.
allocated :: Bool -> IO Int64
allocated value = do
  setAllocationCounter 0
  _ <- evaluate value
  negate <$> getAllocationCounter

-- | A presentation of so many slides of thirty lines each.
longDeck :: Int -> Text
longDeck count = T.intercalate "\n" ("# Long" : "" : concat [["## Slide " <> show n, ""] <> ["Line " <> show k <> " of slide " <> show n <> ": the quick brown fox." | k <- [1 .. 27 :: Int]] <> [""] | n <- [1 .. count]])

-- | The work of measuring a deck of so many slides, of finding its fits
-- again after an edit, and of finding them as before WP5.108.
measuresWork, fitsWork, oldFitsWork :: Int -> IO Int64
measuresWork count = do
  (source, spans, fits) <- deckToMeasure count
  allocated (let m = measuresWith source spans fits in m == m)
fitsWork count = do
  (source, spans, fits) <- deckToMeasure count
  m <- evaluate (measuresWith source spans fits)
  _ <- evaluate (m == m)
  allocated (let f = fitsNow (Just m) source spans in f == f)
oldFitsWork count = do
  (source, spans, fits) <- deckToMeasure count
  m <- evaluate (oldMeasuresFor source fits)
  _ <- evaluate (m == m)
  allocated (let f = oldFitsNow (Just m) source spans in f == f)

deckToMeasure :: Int -> IO (Text, [SlideSpan], [Fit])
deckToMeasure count = do
  let source = longDeck count
      spans = slideSpans source
      fits = map (const Overflowing) spans
  _ <- evaluate (T.length source + length spans + sum [sp.to | sp <- spans] + length fits)
  pure (source, spans, fits)

-- | 'aDeck', its line breaks line feeds, carriage returns or both.
aDeckWithBreaks :: Gen Text
aDeckWithBreaks = do
  source <- aDeck
  let ls = T.splitOn "\n" source
  endings <- vectorOf (length ls - 1) (elements ["\n", "\n", "\r\n", "\r"])
  pure (T.concat (zipWith (<>) ls (endings <> [""])))

-- | Changes after which some slides' fits hold and others' do not.
edits :: [Text -> Text]
edits = [identity, T.replace "a" "b", ("[[!style]]{aspect=4:3}\n\n" <>), ("## New\n\n" <>), T.replace "\n\n" "\n\nMore.\n\n"]

-- | The measures as they were first written ('measuresFor' and
-- 'fitsNow' before WP5.108), splitting the whole text for each slide: the
-- oracle the measures made from one split are held to.
data OldMeasures = OldMeasures [Text] [([Text], Fit)]
  deriving stock (Eq)

oldMeasuresFor :: Text -> [Fit] -> OldMeasures
oldMeasuresFor text fits = OldMeasures (oldLookLines text) (zip (map (oldSlideLines text) (slideSpans text)) (fits <> repeat Unmeasured))

oldFitsNow :: Maybe OldMeasures -> Text -> [SlideSpan] -> [Fit]
oldFitsNow measures text spans = case measures of
  Just (OldMeasures look measured) | look == oldLookLines text -> [current (atMay measured i) sp | (i, sp) <- zip [0 ..] spans]
  _ -> map (const Unmeasured) spans
  where
    current found sp = case found of
      Just (written, f) | written == oldSlideLines text sp -> f
      _ -> Unmeasured

oldLookLines :: Text -> [Text]
oldLookLines = filter ("[[!style]]" `T.isPrefixOf`) . map T.stripStart . T.splitOn "\n"

oldSlideLines :: Text -> SlideSpan -> [Text]
oldSlideLines text sp = take (sp.to - sp.from + 1) (drop (sp.from - 1) (T.splitOn "\n" text))

-- | A move in a deck of 'aDeck' whose blocks are all closed: no fence or
-- box left open at its end.
aClosedMove :: Gen (Text, Int, Int)
aClosedMove = aMove `suchThat` (\(source, _, _) -> not ("left open" `T.isInfixOf` source))

-- | A source with slides and two of its slides' indices, the first among
-- the slides there are, the second one more, so that a move out of range
-- comes up too.
aMove :: Gen (Text, Int, Int)
aMove = do
  source <- aDeck
  let count = length (slideSpans source)
  i <- choose (0, max 0 count)
  j <- choose (0, max 0 count)
  pure (source, i, j)

-- | A list with the element at one index taken out and put back at
-- another, as 'moveSlide' moves slides.
reorderAt :: Int -> Int -> [a] -> [a]
reorderAt i j xs = take j rest <> take 1 (drop i xs) <> drop j rest
  where
    rest = take i xs <> drop (i + 1) xs
