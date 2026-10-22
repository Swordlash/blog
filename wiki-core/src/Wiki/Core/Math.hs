-- | The macros a formula is set with, besides KaTeX's own commands.
--
-- KaTeX has no @\\usepackage@: what it supports is fixed, so the wiki
-- extends it with macros, in three layers, the nearest winning:
--
-- 1. __Built in__, for every page: @web/src/katex-macros.tex@, which the
--    page's @islands.js@ hands to KaTeX itself. Haskell never reads it.
-- 2. __A space's__ ('Wiki.Core.Space.mathMacros'), inherited by its
--    subspaces: 'spaceMacros' gives the blocks of a space's chain, its
--    top-level ancestor's first and its own last.
-- 3. __A page's__: a definition in one formula holds in every later formula
--    of the same page, as in a LaTeX document. The renderer
--    ("Wiki.Core.Markdown.Render") hands each formula the formulas before
--    it, in the document's order, that define something ('definesMacros').
--
-- What a formula gets is therefore a list of blocks of TeX ('Macros'), from
-- the farthest to the nearest, and it is a function of the page and its
-- space alone: a formula is set the same however its island happens to be
-- drawn, first or last, and whatever was drawn before it. Reading the
-- blocks is KaTeX's work, in the browser (@web/src/islands.js@): each block
-- is read on top of those before it, a @\\newcommand@ of a macro an earlier
-- block defined replacing it rather than failing, so that nearer wins; a
-- block KaTeX cannot read keeps what it defined before the error, and the
-- page is drawn regardless.
module Wiki.Core.Math
  ( Macros (..)
  , spaceMacros
  , definesMacros
  )
where

import Data.Text qualified as T
import Protolude
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Path (ancestry)
import Wiki.Core.Space (Space (..))

-- | Blocks of TeX definitions, the farthest first: each is read on top of
-- the ones before it, so a later one overrides an earlier one's macro of
-- the same name. A space's blocks come before its page's formulas.
newtype Macros = Macros [Text]
  deriving stock (Eq, Ord, Show)
  deriving newtype (Semigroup, Monoid)

-- | The macros of a space's pages: those of the space's top-level ancestor
-- first and its own last, leaving out the spaces that have none, among the
-- spaces given. A space that is not among them, or whose ancestors are
-- not, has none.
spaceMacros :: [Space] -> SpaceId -> Macros
spaceMacros spaces sid =
  Macros
    [ s.mathMacros
    | s <- fromMaybe [] (ancestry (\i -> find (\s -> s.id == i) spaces) sid)
    , not (T.null (T.strip s.mathMacros))
    ]

-- | Whether a formula may define a macro for the formulas after it: whether
-- it names one of TeX's ways of defining one. A formula that only mentions
-- one (@\\definecolor@ has @\\def@ in it) is passed on too, which costs
-- KaTeX a read and changes nothing; one that defines a macro inside braces
-- is passed on, and KaTeX forgets the definition at the closing brace, as
-- TeX does.
definesMacros :: Text -> Bool
definesMacros tex = any (`T.isInfixOf` tex) definitions
  where
    definitions =
      [ "\\newcommand"
      , "\\renewcommand"
      , "\\providecommand"
      , "\\def"
      , "\\gdef"
      , "\\edef"
      , "\\xdef"
      , "\\let"
      , "\\futurelet"
      ]
