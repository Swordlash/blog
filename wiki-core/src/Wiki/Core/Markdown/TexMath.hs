-- | Math between LaTeX's own delimiters, @\\(…\\)@ inline and @\\[…\\]@
-- display, beside commonmark-extensions' @$…$@ and @$$…$$@: pandoc's
-- @tex_math_single_backslash@, as a commonmark syntax spec.
--
-- The spec makes the same 'CME.inlineMath' and 'CME.displayMath' as
-- @mathSpec@, so whatever reads math (the renderer, the search's text,
-- slides, a page's macros) cannot tell which delimiters a formula was
-- written with.
--
-- CommonMark reads a backslash before any punctuation as an escape, so
-- @\\[@ was a literal bracket. Here, as in pandoc, @\\(@ and @\\[@ start
-- math when a @\\)@ or @\\]@ closes them later in the same paragraph; one
-- that nothing closes is the escape it always was.
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
-- The backslash is claimed before the core syntax reads it as an escape
-- because inline parsers are tried in the order the specs are combined in:
-- this spec has to come before @defaultSyntaxSpec@, as the other extensions
-- do. Its parser backs off without consuming anything when the delimiter is
-- not closed, and the core's escape then reads it.
texMathSpec :: (Monad m, CME.HasMath il) => CM.SyntaxSpec m il bl
texMathSpec = mempty {CM.syntaxInlineParsers = [texMath]}

-- | A formula: the opener, the TeX up to the matching closer, the closer.
--
-- In the TeX, a backslash and the token after it go together, so that
-- @\\\\@ (TeX's line break, common in display math) is not read as the
-- start of a closer: @\\[ a \\\\ b \\]@ is one formula. The first closer
-- ends the formula however its braces stand, rather than counting braces
-- as @$…$@ does: a closer is a sequence TeX math has no other use for, and
-- a formula whose braces do not pair then reaches KaTeX, which shows the
-- error, instead of quietly staying text. A paragraph may hold a formula
-- across its lines, as @$$…$$@ may; a blank line ends the paragraph, and
-- with it any formula not yet closed. A pair with nothing but white space
-- between is not a formula, and stays text.
texMath :: (Monad m, CME.HasMath a) => CM.InlineParser m a
texMath = try $ do
  _ <- CM.symbol '\\'
  (closer, made) <- (')', CME.inlineMath) <$ CM.symbol '(' <|> (']', CME.displayMath) <$ CM.symbol '['
  tex <- CM.untokenize . concat <$> manyTill piece (try (CM.symbol '\\' *> CM.symbol closer))
  guard (not (T.all isSpace tex))
  pure (made tex)
  where
    piece = (\b t -> [b, t]) <$> CM.symbol '\\' <*> CM.anyTok <|> pure <$> CM.anyTok
