-- | The ranges of lines the editor folds (WP5.96 of docs/PLAN.md), as
-- "Wiki.Core.Markdown.Folds" finds them: block spoilers from marker to
-- marker, heading spoilers' and other headings' sections down to the next
-- heading of the same or a higher level, or to the end of the block they
-- are in.
module Test.Markdown.Folds (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Folds

-- | A text's folds as (first line, last line, kind).
ranges :: Text -> [(Int, Int, FoldKind)]
ranges source = [(f.from, f.to, f.kind) | f <- folds source]

spoilers :: Text -> [(Int, Int, FoldKind)]
spoilers source = [(f.from, f.to, f.kind) | f <- spoilerFolds source]

spec :: Spec
spec = describe "Wiki.Core.Markdown.Folds" $ do
  it "folds a block spoiler from its start marker to its end marker" $ do
    spoilers "# T\n\n[[!spoiler]]{a}(The answer)\nForty-two.\n\n```\ncode\n```\n[[/spoiler]]{a}\n\nAfter."
      `shouldBe` [(3, 9, BlockSpoiler)]
    -- Nested spoilers fold each, the outer first.
    spoilers "[[!spoiler]]{hint}(A hint)\nThink.\n\n[[!spoiler]]{solution}(Then)\nForty-two.\n[[/spoiler]]{solution}\n[[/spoiler]]{hint}\n"
      `shouldBe` [(1, 7, BlockSpoiler), (4, 6, BlockSpoiler)]

  it "folds no spoiler that is not closed or whose marker is broken" $ do
    spoilers "[[!spoiler]]{a}(A)\nText." `shouldBe` []
    spoilers "[[!spoiler]]{a}(A)\n[[/spoiler]]" `shouldBe` [(1, 2, BlockSpoiler)]
    spoilers "[[!spoiler]]\nText.\n[[/spoiler]]" `shouldBe` []

  it "folds a block spoiler in a quotation by its markers' lines" $
    spoilers "> Quoted.\n>\n> [[!spoiler]]{q}(Q)\n> Inside.\n> [[/spoiler]]\n\nAfter." `shouldBe` [(3, 5, BlockSpoiler)]

  it "folds a heading spoiler's section down to the next heading of the same or a higher level" $ do
    let source = "# T\n\n## [[!spoiler]] Question\n\nAnswer.\n\n### Deeper\n\nMore.\n\n## Next\n\nText."
    spoilers source `shouldBe` [(3, 9, HeadingSpoiler 2)]
    ranges source `shouldBe` [(1, 13, Section 1), (3, 9, HeadingSpoiler 2), (7, 9, Section 3), (11, 13, Section 2)]

  it "folds a deeper heading spoiler inside a heading spoiler's section, each to its own end" $ do
    let source = "### [[!spoiler]] What is X?\n\nX.\n\n#### [[!spoiler]]{x-why} Why?\n\nBecause.\n\n\n### Then\n"
    spoilers source `shouldBe` [(1, 7, HeadingSpoiler 3), (5, 7, HeadingSpoiler 4)]

  it "ends a section at the end of the page, without the blank lines there" $
    ranges "## [[!spoiler]] Q\n\nAnswer.\n\n\n" `shouldBe` [(1, 3, HeadingSpoiler 2)]

  it "gives an empty section no fold" $ do
    ranges "## [[!spoiler]] Q\n\n## Next" `shouldBe` []
    ranges "## A\n## B\nText." `shouldBe` [(2, 3, Section 2)]

  it "ends a section at the end of the block spoiler or div it is in" $ do
    let source = "[[!spoiler]]{s}(S)\n## [[!spoiler]] Q\n\nAnswer.\n\n[[/spoiler]]{s}\n\nOutside."
    ranges source `shouldBe` [(1, 6, BlockSpoiler), (2, 4, HeadingSpoiler 2)]
    ranges "[[!div]]{.box}\n### Inside\n\nText.\n[[/div]]\n\nOutside.\n" `shouldBe` [(2, 4, Section 3)]

  it "ends a section at a block spoiler that wraps a section of the same level" $
    ranges "## A\n\nText.\n\n[[!spoiler]]{b}(B)\n## B\n\nMore.\n[[/spoiler]]{b}\n"
      `shouldBe` [(1, 3, Section 2), (5, 9, BlockSpoiler), (6, 8, Section 2)]

  it "takes no heading in a fence or a quotation, and reads a setext heading" $ do
    ranges "## A\n\n```\n# not a heading\n```\n\n> ## Quoted\n> Text.\n\nEnd." `shouldBe` [(1, 10, Section 2)]
    -- A setext heading's fold starts at its underline, the line the
    -- parser places it at: its text and the underline stay in sight.
    ranges "Title\n=====\n\nText.\n\nSub\n---\nMore." `shouldBe` [(2, 8, Section 1), (7, 8, Section 2)]

  it "starts a heading's fold at the heading, after a line of attributes before it" $
    ranges "Intro.\n\n{#a}\n## [[!spoiler]] Q\n\nAnswer." `shouldBe` [(4, 6, HeadingSpoiler 2)]

  it "folds nothing in a text with a carriage return, whose lines the parser and the editor count differently" $
    ranges "## [[!spoiler]] Q\r\n\r\nAnswer.\r\n" `shouldBe` []
