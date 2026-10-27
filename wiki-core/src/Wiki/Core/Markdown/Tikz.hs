-- | TikZ fences: the TeX document that draws a @tikz@ fence.
--
-- An author writes either the body of a @tikzpicture@ (the commands only),
-- or the whole environment, @\\begin{tikzpicture}…\\end{tikzpicture}@, or a
-- @tikzcd@ diagram, which is a picture by itself. Lines at the top that
-- load packages or libraries (@\\usepackage@, @\\usetikzlibrary@,
-- @\\usepgfplotslibrary@) go before @\\begin{document}@, where LaTeX
-- expects them; the rest is the picture. A @tikzcd@ diagram or a pgfplots
-- axis loads its own package, so that the most common pictures need no
-- preamble.
--
-- The browser draws the picture with TikZJax (@web/src/tikz.js@). Its TeX
-- input is the preamble and @\\begin{document}@ on the first line, then the
-- picture on the following lines. The picture keeps the author's lines in
-- their positions (a preamble line becomes an empty line, and the
-- @\\begin{tikzpicture}@ added around a body goes at the start of its first
-- line), so the line number TeX gives in an error is the author's line
-- number plus one.
module Wiki.Core.Markdown.Tikz
  ( TikzDocument (..)
  , tikzDocument
  )
where

import Data.List (span)
import Data.Text qualified as T
import Protolude

-- | 'TikzDocument': the TeX before @\\begin{document}@, and the TeX after it.
data TikzDocument = TikzDocument
  { preamble :: Text
  , picture :: Text
  }
  deriving stock (Eq, Show)

-- | The TeX document that draws a @tikz@ fence's source.
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
