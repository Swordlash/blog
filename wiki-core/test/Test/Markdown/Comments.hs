-- | Comments, @<!-- … -->@, in a page's Markdown (issue #197, WP5.77 of
-- docs/PLAN.md): the page leaves them out, and so does every text the wiki
-- makes of a page without showing it, the search's text, a blog's
-- excerpt, the table of contents and a notification's excerpt. The
-- exports have theirs in "Test.Server.Export". These run on both
-- backends.
module Test.Markdown.Comments (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Blog qualified as Blog
import Wiki.Core.Markdown.Ast
import Wiki.Core.Markdown.Toc (Entry (..), tableOfContents)
import Wiki.Core.Notification qualified as Notification
import Wiki.Core.Search (bodyText)

-- | A page with comments of every shape: among a paragraph's text, on a
-- line of their own, over several lines, and around blocks to keep them
-- out of the page. Each comment holds the word "secret".
commented :: Text
commented =
  T.unlines
    [ "One <!-- secret one --> line."
    , ""
    , "<!-- secret two -->"
    , ""
    , "<!--"
    , "secret three"
    , "-->"
    , ""
    , "Before <!-- secret four"
    , "over two lines --> after."
    , ""
    , "<!--"
    , "## A secret heading"
    , ""
    , "A secret paragraph."
    , ""
    , "- a secret item"
    , "-->"
    , ""
    , "## Shown"
    , ""
    , "- item <!-- secret five -->"
    ]

-- | The titles of a table of contents' entries, nested ones too.
titles :: [Entry] -> [Text]
titles = concatMap (\e -> e.text : titles e.below)

spec :: Spec
spec = describe "comments, <!-- … -->" $ do
  it "keeps no comment's text in the search's text" $ do
    bodyText commented `shouldNotSatisfy` T.isInfixOf "secret"
    bodyText commented `shouldSatisfy` T.isInfixOf "One line."
  it "keeps no comment's text in a blog's excerpt, even when the first paragraph is a comment" $ do
    Blog.excerptOf commented `shouldBe` "One line."
    Blog.excerptOf "<!-- secret -->\n\nThe first words." `shouldBe` "The first words."
    Blog.excerptOf "Starts <!-- secret\nover lines --> here." `shouldNotSatisfy` T.isInfixOf "secret"
  it "lists no heading inside a comment in the table of contents" $
    titles (either (panic . show) tableOfContents (parseMarkdown commented)) `shouldBe` ["Shown"]
  it "keeps no comment's text in a notification's excerpt" $ do
    Notification.excerptOf commented `shouldNotSatisfy` T.isInfixOf "secret"
    Notification.excerptOf "Look <!-- secret --> here, @ada." `shouldBe` "Look here, @ada."
