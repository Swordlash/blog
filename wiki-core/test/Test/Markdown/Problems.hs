-- | The problems the editor marks (WP5.65 of docs/PLAN.md), as
-- "Wiki.Core.Markdown.Problems" finds them: the parser's own, each at the
-- right line, and the place of each island that can fail, by the key the
-- renderer gives it.
module Test.Markdown.Problems (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Folds (Fold (..), spoilerFolds)
import Wiki.Core.Markdown.Problems
import Wiki.Core.Markdown.Render (IslandKey (..))
import Wiki.Core.PageKind (PageKind (..))

-- | The parser's problems of a text, without their messages.
placed :: Text -> [(Int, Int, ProblemKind)]
placed source = [(p.from, p.to, p.kind) | p <- parserProblems source]

-- | The place of each island of a text, by its source (without the white
-- space at either end) and its occurrence.
places :: Text -> [((Text, Int), (Int, Int, ProblemKind))]
places source = [((T.strip k.source, k.occurrence), (p.from, p.to, p.kind)) | (k, p) <- Map.toList (islandPlaces source)]

spec :: Spec
spec = describe "Wiki.Core.Markdown.Problems" $ do
  describe "the parser's problems" $ do
    it "finds nothing in a page without mistakes" $
      parserProblems "# Title\n\n[[!spoiler]]{a}(A)\nText.\n[[/spoiler]]{a}\n\n> [!TIP] Title\n> Text.\n\n> A quotation." `shouldBe` []

    it "marks a spoiler's broken marker line, with its reason" $ do
      placed "# Title\n\nText.\n\n[[!spoiler]]\nMore." `shouldBe` [(5, 5, Spoiler)]
      map (.message) (parserProblems "[[!spoiler]]{a}\nText.")
        `shouldBe` ["A spoiler needs a description in parentheses after its name, as in [[!spoiler]]{name}(Description)"]

    it "marks an end marker that ends no spoiler inside another spoiler, and leaves one with none open text" $ do
      let source = "[[!spoiler]]{a}(A)\n[[/spoiler]]{b}\n[[/spoiler]]{a}\n\n[[/spoiler]]{c}"
      placed source `shouldBe` [(2, 2, Spoiler)]
      map (.message) (parserProblems source) `shouldBe` ["No open spoiler of this name"]

    it "marks a spoiler that is not closed at its start marker" $ do
      let source = "# Title\n\n[[!spoiler]]{answer}(The answer)\nForty-two.\n\nMore."
      placed source `shouldBe` [(3, 3, Spoiler)]
      map (.message) (parserProblems source) `shouldBe` ["Spoiler “answer” is not closed: add [[/spoiler]]{answer}"]

    it "marks a spoiler that cuts a section at its start marker" $ do
      let source = "## One\n\nText.\n\n[[!spoiler]]{s}(S)\nHidden.\n\n## Two\n\nMore.\n[[/spoiler]]{s}\n"
      placed source `shouldBe` [(5, 5, Spoiler)]
      map (T.take 26 . (.message)) (parserProblems source) `shouldBe` ["Spoiler “s” cuts a section"]

    it "marks a spoiler not closed inside a quotation, at its own line" $
      placed "Text.\n\n> Quoted.\n>\n> [[!spoiler]]{q}(Q)\n> Inside." `shouldBe` [(5, 5, Spoiler)]

    it "marks a quotation that starts like a box's marker but is not a box" $ do
      placed "Text.\n\n> [!]\n> Body." `shouldBe` [(3, 3, Box)]
      placed "> [!Two words]\n> Body." `shouldBe` [(1, 1, Box)]
      placed "> [!TIP]Title\n> Body." `shouldBe` [(1, 1, Box)]
      map (.message) (parserProblems "> [!]") `shouldBe` ["A box's marker needs a kind, as in [!NOTE]: this quotation is not a box"]
      -- A box, a starred box, and quotations that do not start so.
      placed "> [!NOTE]\n> Body.\n\n> [!TIP*] Title\n\n> [link](x)\n\n> [x] and [!y]" `shouldBe` []

    it "takes a heading spoiler, which has no end marker, as closed, and marks a marker pair that crosses its end" $ do
      parserProblems "# Title\n\n## [[!spoiler]] Question\n\nAnswer.\n\n## [[!spoiler]]{named} Another\n\nText.\n\n## Next\n\nMore." `shouldBe` []
      -- A pair that starts in a heading spoiler's section and ends after
      -- it cuts that section.
      placed "## One\n\n### [[!spoiler]] Q\n\n[[!spoiler]]{s}(S)\nHidden.\n\n### Two\n\nMore.\n[[/spoiler]]{s}\n" `shouldBe` [(5, 5, Spoiler)]
      -- A pair that holds a heading spoiler and the text after its section.
      placed "[[!spoiler]]{s}(S)\n## [[!spoiler]] Q\n\nAnswer.\n\n# Top\n\nMore.\n[[/spoiler]]{s}\n" `shouldBe` [(1, 1, Spoiler)]

    it "finds, from the same parse, the problems and islands the parser and the islands' places find apart, and the spoilers' folds" $ do
      let source = "# T\n\n> [!]\n\n[[!spoiler]]{a}(A)\n$x$\n[[/spoiler]]{a}\n\n## [[!spoiler]] Q\n\nAnswer $y$.\n\n[[!pause]] x\n"
          checked = checkText source
      checked.problems `shouldBe` parserProblems source
      checked.islands `shouldBe` islandPlaces source
      checked.folds `shouldBe` spoilerFolds source
      map (\f -> (f.from, f.to)) checked.folds `shouldBe` [(5, 7), (9, 13)]

    it "lists the problems in the order of their lines" $
      placed "> [!]\n\n[[!pause]] x\n\n[[!spoiler]]{b}(B)\nText." `shouldBe` [(1, 1, Box), (3, 3, Marker), (5, 5, Spoiler)]

  describe "the islands' places" $ do
    it "places a fence of the page at its lines, the fences included" $ do
      let source = "# Title\n\n```mermaid\ngraph LR\n  a -->\n```\n\nText.\n\n```tikz\n\\draw (0,0);\n```\n"
      places source `shouldBe` [(("\\draw (0,0);", 0), (10, 12, Picture)), (("graph LR\n  a -->", 0), (3, 6, Diagram))]

    it "places a latex fence as a math fence, at its lines, and leaves an html fence and a listing made with norender out" $ do
      let source = "```latex\n\\frac{1}{\n```\n\n```html\n<script>alert(1)</script>\n<p onclick=\"x()\">p</p>\n```\n\n```mermaid {.norender}\ngraph\n```\n"
      places source `shouldBe` [(("\\frac{1}{", 0), (1, 3, Formula))]
      parserProblems source `shouldBe` []

    it "places a formula on its line of a paragraph, and display math in a paragraph" $ do
      let source = "Intro line,\nthen $x^$ here\nand $$y +$$ after."
      places source `shouldBe` [(("x^", 0), (2, 2, Formula)), (("y +", 0), (3, 3, Formula))]

    it "places islands inside a spoiler, a box's title and a list at their lines" $ do
      let source = "[[!spoiler]]{s}(Show $z$)\nInside:\n\n```tikz\n\\draw (0,0);\n```\n[[/spoiler]]{s}\n\n> [!TIP] About $t$\n> Text.\n\n- item\n- with $u$"
      places source
        `shouldBe` [ (("\\draw (0,0);", 0), (5, 5, Picture))
                   , (("t", 0), (9, 9, Formula))
                   , (("u", 0), (13, 13, Formula))
                   , (("z", 0), (1, 1, Formula))
                   ]

    it "places islands in a heading spoiler's heading and section at their lines" $ do
      let source = "# T\n\n## [[!spoiler]] About $q$\n\nAnswer:\n\n```mermaid\ngraph LR\n```\n\n## Next\n\n$r$"
      places source
        `shouldBe` [ (("graph LR", 0), (8, 8, Diagram))
                   , (("q", 0), (3, 3, Formula))
                   , (("r", 0), (13, 13, Formula))
                   ]

    it "gives islands of the same source the renderer's occurrences, and leaves listings out" $ do
      let source = "$a$ first.\n\n```\na\n```\n\nSecond $a$.\n\n```mermaid\na\n```"
      -- A fence's source ends with its line break, so the listing and
      -- the diagram share a count of their own, and the listing, which
      -- cannot fail, takes the first.
      places source `shouldBe` [(("a", 0), (1, 1, Formula)), (("a", 1), (7, 7, Formula)), (("a", 1), (9, 11, Diagram))]

    it "places two islands of the same source on one line both on it, and the next on its own line" $ do
      let source = "Intro.\n\n$\\bad$ and $\\bad$\nthen $\\bad$ again."
      places source
        `shouldBe` [ (("\\bad", 0), (3, 3, Formula))
                   , (("\\bad", 1), (3, 3, Formula))
                   , (("\\bad", 2), (4, 4, Formula))
                   ]

    it "places formulas of one source written with different delimiters in the order they are written" $
      places "\\(\\bad\\)\n$\\bad$"
        `shouldBe` [ (("\\bad", 0), (1, 1, Formula))
                   , (("\\bad", 1), (2, 2, Formula))
                   ]

    it "places a formula by its whole source between its delimiters, not by a longer formula it starts" $ do
      places "Good $\\frac{1}{2}$\nBad $\\frac{1}$" `shouldBe` [(("\\frac{1}", 0), (2, 2, Formula)), (("\\frac{1}{2}", 0), (1, 1, Formula))]
      -- Display math holds the inline delimiters, and is one formula.
      places "$$x$$ and $x$\n\\[x\\]" `shouldBe` [(("x", 0), (1, 1, Formula)), (("x", 1), (1, 1, Formula)), (("x", 2), (2, 2, Formula))]

    it "does not take a formula's source written in code for the formula" $ do
      places "Example: `$\\frac{1}$`\nActual: $\\frac{1}$" `shouldBe` [(("\\frac{1}", 0), (2, 2, Formula))]
      -- A longer run of backticks holds a shorter one; a run never closed
      -- is text, and the formula after it is found.
      places "``a ` $y$`` and $y$\n`` $y$ here" `shouldBe` [(("y", 0), (1, 1, Formula)), (("y", 1), (2, 2, Formula))]
      -- A list item's math fence is still found by its source.
      places "- item\n\n  ```math\n  \\frac{\n  ```" `shouldBe` [(("\\frac{", 0), (4, 4, Formula))]

    it "counts a block of macro definitions, which shows nothing, as the renderer does" $
      places "$$\\newcommand{\\R}{\\mathbb{R}}$$\n\nThen $\\R$ and $\\R$." `shouldBe` [(("\\R", 0), (3, 3, Formula)), (("\\R", 1), (3, 3, Formula))]

    it "turns an island's failure into a problem at its place, and drops one no longer in the text" $ do
      let checked = checkText Document "# T\n\n```mermaid\nbad\n```\n\n[[!spoiler]]{a}(A)"
          gone = IslandKey "old\n" 0
          failed = Map.fromList [(IslandKey "bad\n" 0, "Parse error on line 1"), (gone, "Parse error")]
      [(p.from, p.to, p.kind, p.message) | p <- allProblems checked failed]
        `shouldBe` [(3, 5, Diagram, "Parse error on line 1"), (7, 7, Spoiler, "Spoiler “a” is not closed: add [[/spoiler]]{a}")]

  describe "the warnings of a page's kind" $ do
    let warned kind source = [(p.from, p.severity, p.message) | p <- kindProblems kind source]
        deck = "# Talk\n\n[[!style]]{theme=dark}\n\n## One\n\n[[!pause]]\n\nMore.\n\n[[!notes]]\nSay so.\n[[/notes]]\n\n{.incremental}\n- a\n- b\n"
    it "warns of each marker of presentations in a document, and in a presentation of none" $ do
      map (\(l, sev, _) -> (l, sev)) (warned Document deck) `shouldBe` [(3, Warning), (7, Warning), (11, Warning), (16, Warning)]
      warned Presentation deck `shouldBe` []
      -- A page of a kind this program does not know is read as a document.
      length (warned (OtherKind "calendar") deck) `shouldBe` 4
    it "warns in a presentation of a heading that opens no slide, below the top level" $ do
      map (\(l, _, m) -> (l, T.take 33 m)) (warned Presentation "# T\n\n## One\n\n> ## Quoted\n\n- ## In a list\n\n### Deeper is fine\n")
        `shouldBe` [(5, "A heading of level one or two ope"), (7, "A heading of level one or two ope")]
      -- A heading spoiler's section is the top level, as a deck reads it.
      warned Presentation "# T\n\n## [[!spoiler]] Q\n\nA.\n\n## Next\n" `shouldBe` []
    it "warns in a presentation of a look after the first, and of one not at the top level" $
      map (\(l, _, m) -> (l, T.take 17 m)) (warned Presentation "[[!style]]{theme=dark}\n\n[[!style]]{theme=light}\n\n> [[!style]]\n")
        `shouldBe` [(3, "Only the first [["), (5, "[[!style]] is rea")]
    it "puts the warnings beside the parser's errors when the editor checks a text" $
      [(p.from, p.severity) | p <- (checkText Document "[[!pause]]\n\n[[!oops]]\n").problems] `shouldBe` [(1, Warning), (3, Error)]
