-- | A @tikz@ fence as the TeX that draws it.
--
-- An author writes either the body of a @tikzpicture@ (the commands alone)
-- or the whole environment, @\\begin{tikzpicture}…\\end{tikzpicture}@, or a
-- @tikzcd@ diagram, which is a picture of its own. Lines at the top that
-- load packages or libraries (@\\usepackage@, @\\usetikzlibrary@,
-- @\\usepgfplotslibrary@) belong before @\\begin{document}@, where LaTeX
-- wants them; the rest is the picture. A @tikzcd@ diagram or a pgfplots
-- axis loads its package by itself, so that the commonest pictures need no
-- preamble.
--
-- The browser draws it with TikZJax (@web/src/tikz.js@), whose TeX input is
-- the preamble and @\\begin{document}@ on its first line and the picture on
-- the lines after. The picture keeps the author's lines where they were (a
-- preamble line becomes an empty one, and the @\\begin{tikzpicture}@ that
-- wraps a body goes at the start of its first line), so the line TeX names
-- in an error is the author's, one further down.
module Wiki.Core.Markdown.Tikz
  ( TikzDocument (..)
  , tikzDocument
  )
where

import Data.List (span)
import Data.Text qualified as T
import Protolude

-- | What goes before @\\begin{document}@, and what after.
data TikzDocument = TikzDocument
  { preamble :: Text
  , picture :: Text
  }
  deriving stock (Eq, Show)

-- | The TeX that draws a @tikz@ fence's source.
tikzDocument :: Text -> TikzDocument
tikzDocument source =
  TikzDocument
    { preamble = T.concat (loaded <> implied)
    , picture = T.intercalate "\n" (map (const "") top <> wrapped)
    }
  where
    sourceLines = T.lines source
    (top, rest) = span (\l -> isPreamble l || isBlank l) sourceLines
    loaded = map T.strip (filter isPreamble top)
    body = T.intercalate "\n" rest
    whole = any (`T.isInfixOf` body) ["\\begin{tikzpicture}", "\\begin{tikzcd}"]
    wrapped
      | whole = rest
      | otherwise = case rest of
          [] -> ["\\begin{tikzpicture}", "\\end{tikzpicture}"]
          opening : more -> ("\\begin{tikzpicture}" <> opening) : more <> ["\\end{tikzpicture}"]
    implied =
      ["\\usepackage{tikz-cd}" | "\\begin{tikzcd}" `T.isInfixOf` body, not (loads "tikz-cd")]
        <> [ "\\usepackage{pgfplots}\\pgfplotsset{compat=1.18}"
           | any (`T.isInfixOf` body) axes
           , not (loads "pgfplots")
           ]
    loads package = any (\l -> "\\usepackage" `T.isPrefixOf` l && ("{" <> package <> "}") `T.isInfixOf` l) loaded
    axes = ["\\begin{" <> a <> "}" | a <- ["axis", "semilogxaxis", "semilogyaxis", "loglogaxis"]]

isPreamble :: Text -> Bool
isPreamble l = any (`T.isPrefixOf` T.stripStart l) ["\\usepackage", "\\usetikzlibrary", "\\usepgfplotslibrary"]

isBlank :: Text -> Bool
isBlank = T.all isSpace
