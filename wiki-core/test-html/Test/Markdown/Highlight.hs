-- | Inline comments' quotes marked in a rendered page ("Wiki.Core.Anchor"):
-- the markup the marks make, cut out of text nodes, never across an
-- element's boundary.
module Test.Markdown.Highlight (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Anchor
import Wiki.Core.Id (CommentThreadId (..))
import Wiki.Core.Markdown (defaultOptions)

-- | A page's markup with these phrases marked for these threads, each
-- phrase found as an anchor taken where it first is.
marked :: Text -> [(Text, Text, Bool)] -> IO Text
marked source quotes = do
  doc <- renderMarkdownOr defaultOptions source :: IO [Html]
  let text = renderedText doc
      marking (thread, phrase, focused) = case T.breakOn phrase text of
        (ahead, rest)
          | not (T.null rest) ->
              case locate text (anchorAt text (Range (T.length ahead) (T.length ahead + T.length phrase))) of
                Found range -> pure Marking {thread = CommentThreadId thread, range, focused}
                Orphaned -> panic ("orphaned: " <> phrase)
        _ -> panic ("no " <> phrase <> " in " <> text)
  markings <- traverse marking quotes
  renderHtml (highlight markings doc)

spec :: Spec
spec = describe "Anchor.highlight" $ do
  it "marks a quote inside a text node, cutting it in three" $
    marked "Some words here." [("t1", "words", False)]
      `shouldReturn` "<p>Some <mark class=\"comment-mark\" data-thread=\"t1\">words</mark> here.</p>"

  it "marks a quote across elements with a mark in each text node" $
    marked "One *two three* four." [("t1", "two three four", False)]
      `shouldReturn` "<p>One <em><mark class=\"comment-mark\" data-thread=\"t1\">two three</mark></em><mark class=\"comment-mark\" data-thread=\"t1\"> four</mark>.</p>"

  it "never crosses a block's boundary: a quote across paragraphs is marked in each" $
    marked "First para.\n\nSecond para." [("t1", "para.Second", False)]
      `shouldReturn` "<p>First <mark class=\"comment-mark\" data-thread=\"t1\">para.</mark></p><p><mark class=\"comment-mark\" data-thread=\"t1\">Second</mark> para.</p>"

  it "marks the focused thread's quote as focused" $
    marked "Alpha beta." [("t1", "beta", True)]
      `shouldReturn` "<p>Alpha <mark class=\"comment-mark comment-mark-focused\" data-thread=\"t1\">beta</mark>.</p>"

  it "marks where quotes overlap once, for the quote that starts last" $
    marked "abcdef" [("outer", "abcdef", False), ("inner", "cd", False)]
      `shouldReturn` ( "<p><mark class=\"comment-mark\" data-thread=\"outer\">ab</mark>"
                         <> "<mark class=\"comment-mark\" data-thread=\"inner\">cd</mark>"
                         <> "<mark class=\"comment-mark\" data-thread=\"outer\">ef</mark></p>"
                     )

  it "leaves a page with no quotes as it was" $ do
    plain <- markdown "Text with `code` and a [link](https://example.com)."
    marked "Text with `code` and a [link](https://example.com)." [] `shouldReturn` plain

  it "keeps the page's text: the marked page reads the same" $ do
    doc <- renderMarkdownOr defaultOptions "A list:\n\n- one\n- two *three*" :: IO [Html]
    let text = renderedText doc
    renderedText (highlight [Marking (CommentThreadId "t") (Range 3 12) False] doc) `shouldBe` text
