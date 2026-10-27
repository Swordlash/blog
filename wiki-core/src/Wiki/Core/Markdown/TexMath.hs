-- | TeX math delimiters: math between LaTeX's own delimiters, @\\(…\\)@
-- inline and @\\[…\\]@ display, in addition to commonmark-extensions'
-- @$…$@ and @$$…$$@. This is pandoc's @tex_math_single_backslash@, as a
-- commonmark syntax spec.
--
-- The spec produces the same 'CME.inlineMath' and 'CME.displayMath' as
-- @mathSpec@, so code that reads math (the renderer, the search text,
-- slides, a page's macros) cannot tell which delimiters a formula was
-- written with.
--
-- CommonMark reads a backslash before any punctuation as an escape, so
-- @\\[@ used to be a literal bracket. Here, as in pandoc, @\\(@ and @\\[@
-- start math when a @\\)@ or @\\]@ closes them later in the same
-- paragraph. An opener without a closer is still an escape.
module Wiki.Core.Markdown.TexMath
  ( texMathSpec
  )
where

import Commonmark.Extensions qualified as CME
import Commonmark.Inlines qualified as CM
import Commonmark.Syntax qualified as CM
import Commonmark.TokParsers qualified as CM
import Commonmark.Tokens qualified as CM
import Data.Text qualified as T
import Protolude hiding (try)
import Text.Parsec (manyTill, try)

-- | @\\(…\\)@ and @\\[…\\]@.
--
-- This parser must see the backslash before the core syntax reads it as an
-- escape. Inline parsers are tried in the order the specs are combined in,
-- so this spec has to come before @defaultSyntaxSpec@, as the other
-- extensions do. When the delimiter is not closed, the parser fails
-- without consuming input, and the core's escape parser then reads it.
texMathSpec :: (Monad m, CME.HasMath il) => CM.SyntaxSpec m il bl
texMathSpec = mempty {CM.syntaxInlineParsers = [texMath]}

-- | A formula: the opener, the TeX up to the matching closer, the closer.
--
-- In the TeX, a backslash and the token after it are read together, so
-- that @\\\\@ (TeX's line break, common in display math) is not taken as
-- the start of a closer: @\\[ a \\\\ b \\]@ is one formula. The first
-- closer ends the formula regardless of braces, rather than counting
-- braces as @$…$@ does: a closer is a sequence TeX math has no other use
-- for. A formula with unbalanced braces then reaches KaTeX, which shows
-- the error, instead of silently staying text. A formula may span the
-- lines of a paragraph, as @$$…$$@ may; a blank line ends the paragraph,
-- and with it any formula not yet closed. A pair of delimiters with only
-- white space between them is not a formula, and stays text.
texMath :: (Monad m, CME.HasMath a) => CM.InlineParser m a
texMath = try $ do
  _ <- CM.symbol '\\'
  (closer, made) <- (')', CME.inlineMath) <$ CM.symbol '(' <|> (']', CME.displayMath) <$ CM.symbol '['
  tex <- CM.untokenize . concat <$> manyTill piece (try (CM.symbol '\\' *> CM.symbol closer))
  guard (not (T.all isSpace tex))
  pure (made tex)
  where
    piece = (\b t -> [b, t]) <$> CM.symbol '\\' <*> CM.anyTok <|> pure <$> CM.anyTok
