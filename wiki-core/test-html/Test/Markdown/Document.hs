-- | The authors' guide, @docs/markdown.md@, which is written in everything
-- it describes: it parses, and a few of its constructs come out as the guide
-- says they do.
module Test.Markdown.Document (spec) where

import Data.Text qualified as T
import Data.Text.IO qualified as T
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Markdown

-- | Where the guide is from the package's directory, which is where cabal
-- runs a test suite.
guidePath :: FilePath
guidePath = "../docs/markdown.md"

spec :: Spec
spec = describe "docs/markdown.md" $ do
  it "parses into every kind of block it describes" $ do
    doc <- either (panic . show) identity . parseMarkdown <$> T.readFile guidePath
    let kinds = map kind (universe doc)
    for_ ["heading", "para", "list", "task", "quote", "break", "code", "mermaid", "tikz", "math", "table", "footnotes", "alert", "div"] $ \k ->
      (k, k `elem` kinds) `shouldBe` (k, True)

  it "renders, with the constructs it shows" $ do
    html <- markdown =<< T.readFile guidePath
    for_
      [ "<h1 id=\"writing-pages\">Writing pages</h1>"
      , "<h2 id=\"images-video-and-attachments\">Images, video and attachments</h2>"
      , "<a href=\"#headings\">Headings</a>"
      , "<a class=\"wikilink\" href=\"onboarding\">our onboarding</a>"
      , "<a href=\"https://example.com\" rel=\"noopener\" title=\"and a title\">with a label</a>"
      , "<img alt=\"A diagram\" src=\"https://example.com/diagram.png\">"
      , "<pre><code class=\"language-haskell\">main :: IO ()"
      , "<span class=\"math inline\">e^{i\\pi} + 1 = 0</span>"
      , "prices such as $5 and $10 stay text"
      , "<div class=\"math display\">\n\\int_0^1"
      , "<span class=\"math inline\">\\ce{2 H2 + O2 -&gt; 2 H2O}</span>"
      , "<td><span class=\"math inline\">\\abs{x}</span>, <span class=\"math inline\">\\norm{x}</span></td>"
      , "<div class=\"math display\">\n\\newcommand{\\dist}[2]{d\\left(#1, #2\\right)}"
      , "<pre class=\"mermaid\">graph LR"
      , "<pre class=\"tikz\">\\draw[-&gt;] (0,0) -- (2,0) node[right] {$x$};"
      , "<th style=\"text-align: center\">Syntax</th>"
      , "<input checked disabled type=\"checkbox\"> write the page"
      , "<section class=\"footnotes\"><ol><li id=\"fn-1\">"
      , "<div class=\"alert alert-warning\">"
      , "<div class=\"summary\">"
      , "<kbd>Ctrl</kbd>+<kbd>S</kbd>"
      , "<abbr title=\"HyperText Markup Language\">HTML</abbr>"
      , "<mark>this is <em>emphasised</em></mark>"
      , "<span class=\"c-red\">red</span>"
      , "<mark class=\"h-green\"><span class=\"c-blue\">both</span></mark>"
      , "<td><mark class=\"h-purple\">Purple</mark></td>"
      , "<details>\n<summary>A part of the page that opens on a click</summary>\nWritten in HTML, so <b>this is bold</b> and **this is not**.\n</details>"
      ]
      $ \fragment -> html `shouldSatisfy` T.isInfixOf fragment
    html `shouldNotSatisfy` T.isInfixOf "Like this one. -->"

-- | Every block of a document, nested ones too.
universe :: [Block] -> [Block]
universe = concatMap $ \b -> b : universe (children b)
  where
    children = \case
      BlockQuote bs -> bs
      List _ items -> concat [bs | ListItem _ bs <- items]
      Div _ bs -> bs
      Alert _ bs -> bs
      Footnotes notes -> concat [bs | Footnote _ _ bs <- notes]
      _ -> []

kind :: Block -> Text
kind = \case
  Para _ -> "para"
  Plain _ -> "plain"
  Heading {} -> "heading"
  ThematicBreak -> "break"
  BlockQuote _ -> "quote"
  CodeBlock {} -> "code"
  Mermaid _ -> "mermaid"
  Tikz _ -> "tikz"
  MathBlock _ -> "math"
  List _ items
    | any (\(ListItem task _) -> isJust task) items -> "task"
    | otherwise -> "list"
  Table {} -> "table"
  Div {} -> "div"
  Alert {} -> "alert"
  Footnotes _ -> "footnotes"
  RawHtmlBlock _ -> "raw"
