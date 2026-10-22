-- | A @tikz@ fence as the TeX TikZJax runs: both forms the author may
-- write, the preamble taken from the top, packages a picture implies, and
-- the author's lines kept where TeX will count them.
module Test.Markdown.Tikz (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.Markdown.Tikz

spec :: Spec
spec = describe "Wiki.Core.Markdown.Tikz" $ do
  describe "a body" $ do
    it "is wrapped in a tikzpicture, which starts on its first line" $
      tikzDocument "\\draw (0,0) -- (1,1);\n\\draw (1,0) -- (0,1);\n"
        `shouldBe` TikzDocument
          { preamble = ""
          , picture = "\\begin{tikzpicture}\\draw (0,0) -- (1,1);\n\\draw (1,0) -- (0,1);\n\\end{tikzpicture}"
          }
    it "is an empty picture when there is nothing" $
      (tikzDocument "").picture `shouldBe` "\\begin{tikzpicture}\n\\end{tikzpicture}"

  describe "a whole environment" $ do
    it "is the picture as written" $
      tikzDocument "\\begin{tikzpicture}[scale=2]\n\\draw (0,0) circle (1);\n\\end{tikzpicture}"
        `shouldBe` TikzDocument
          { preamble = ""
          , picture = "\\begin{tikzpicture}[scale=2]\n\\draw (0,0) circle (1);\n\\end{tikzpicture}"
          }
    it "can be a tikz-cd diagram, which loads its package" $
      tikzDocument "\\begin{tikzcd}\nA \\arrow[r] & B\n\\end{tikzcd}"
        `shouldBe` TikzDocument
          { preamble = "\\usepackage{tikz-cd}"
          , picture = "\\begin{tikzcd}\nA \\arrow[r] & B\n\\end{tikzcd}"
          }

  describe "the preamble" $ do
    it "takes the lines at the top that load packages and libraries, leaving them empty" $
      tikzDocument "\\usetikzlibrary{arrows.meta}\n  \\usepackage[x]{y}\n\n\\draw[-Stealth] (0,0) -- (1,0);"
        `shouldBe` TikzDocument
          { preamble = "\\usetikzlibrary{arrows.meta}\\usepackage[x]{y}"
          , picture = "\n\n\n\\begin{tikzpicture}\\draw[-Stealth] (0,0) -- (1,0);\n\\end{tikzpicture}"
          }
    it "keeps such a line below the top in the picture" $
      (tikzDocument "\\draw (0,0);\n\\usetikzlibrary{calc}").preamble `shouldBe` ""
    it "loads pgfplots for an axis, unless the author did" $ do
      (tikzDocument "\\begin{tikzpicture}\\begin{axis}\\end{axis}\\end{tikzpicture}").preamble
        `shouldBe` "\\usepackage{pgfplots}\\pgfplotsset{compat=1.18}"
      (tikzDocument "\\begin{loglogaxis}\\end{loglogaxis}").preamble
        `shouldBe` "\\usepackage{pgfplots}\\pgfplotsset{compat=1.18}"
      (tikzDocument "\\usepackage{pgfplots}\n\\begin{tikzpicture}\\begin{axis}\\end{axis}\\end{tikzpicture}").preamble
        `shouldBe` "\\usepackage{pgfplots}"
    it "does not load tikz-cd twice" $
      (tikzDocument "\\usepackage{tikz-cd}\n\\begin{tikzcd}A\\end{tikzcd}").preamble `shouldBe` "\\usepackage{tikz-cd}"

  -- TeX names the line of an error; the browser counts it back to the
  -- author's, which it can only do if every line stays where it was.
  it "keeps every line of the picture on the line the author wrote it on" $
    for_ sources $ \source ->
      for_ (zip (T.lines source) (T.lines (tikzDocument source).picture)) $ \(written, drawn) ->
        if "\\use" `T.isPrefixOf` written
          then drawn `shouldBe` ""
          else drawn `shouldSatisfy` T.isSuffixOf written
  where
    sources =
      [ "\\draw (0,0);"
      , "\\usetikzlibrary{calc}\n\\draw (0,0);\n\\draw (1,1);"
      , "\\begin{tikzpicture}\n\\draw (0,0);\n\\end{tikzpicture}"
      , "\\usepackage{tikz-cd}\n\n\\begin{tikzcd}\nA\n\\end{tikzcd}"
      ]
