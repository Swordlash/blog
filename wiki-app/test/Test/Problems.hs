-- | The editor's problems as CodeMirror marks them
-- ("Wiki.App.Editor.Problems"): a problem's source lines turned into the
-- characters of the editor's text it underlines, clamped to the text.
module Test.Problems (spec) where

import Data.Map.Strict qualified as Map
import Protolude
import Test.Hspec
import Wiki.App.Editor.Problems (ProblemRange (..), problemRanges)
import Wiki.Core.Markdown.Problems (Checked (..), Problem (..), ProblemKind (..), allProblems, checkText)

-- | The characters each problem underlines in a text.
spans :: Text -> [(Int, Int)] -> [(Int, Int)]
spans text ranges = [(r.from, r.to) | r <- problemRanges text [Problem {from = a, to = b, kind = Formula, message = "bad"} | (a, b) <- ranges]]

spec :: Spec
spec = describe "Wiki.App.Editor.Problems.problemRanges" $ do
  let text = "ab\ncd\n\nef"
  it "underlines a line from its start to its end, without the line break" $
    spans text [(1, 1), (2, 2), (4, 4)] `shouldBe` [(0, 2), (3, 5), (7, 9)]
  it "underlines several lines from the first's start to the last's end" $
    spans text [(1, 4), (2, 3)] `shouldBe` [(0, 9), (3, 6)]
  it "marks an empty line where it is, with nothing underlined" $
    spans text [(3, 3)] `shouldBe` [(6, 6)]
  it "clamps lines outside the text to its first and last lines" $ do
    spans text [(9, 12)] `shouldBe` [(7, 9)]
    spans text [(0, 1)] `shouldBe` [(0, 2)]
    spans "" [(3, 5)] `shouldBe` [(0, 0)]
  it "counts the empty line after a final line break, as CodeMirror does" $
    spans "a\n" [(2, 2)] `shouldBe` [(2, 2)]
  it "counts characters, not bytes or UTF-16 units" $
    spans "é😀\nx" [(2, 2)] `shouldBe` [(3, 4)]
  it "takes a range written backwards as the same range" $
    spans text [(2, 1)] `shouldBe` [(0, 5)]
  it "keeps the kind's name and the message" $
    problemRanges text [Problem {from = 1, to = 1, kind = Diagram, message = "Parse error"}]
      `shouldBe` [ProblemRange {from = 0, to = 2, kind = "diagram", message = "Parse error"}]
  it "marks an island's failure at the island's lines in the text checked, the parser's problems beside it" $ do
    let source = "# Title\n\n[[spoiler]]{a}(A)\nText $x^$ here.\n"
        checked = checkText source
        failed = Map.fromList [(key, "KaTeX parse error") | key <- Map.keys checked.islands]
    [(r.from, r.to, r.kind) | r <- problemRanges source (allProblems checked failed)]
      `shouldBe` [(9, 26, "spoiler"), (27, 42, "formula")]
