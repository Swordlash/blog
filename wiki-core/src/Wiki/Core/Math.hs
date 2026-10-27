-- | Math macros: the macros a formula is rendered with, besides KaTeX's own
-- commands.
--
-- KaTeX has no @\\usepackage@: the commands it supports are fixed, so the
-- wiki extends it with macros, in three layers. Where two layers define
-- the same macro, the nearer one wins:
--
-- 1. __Built in__, for every page: @web/src/katex-macros.tex@, which the
--    page's @islands.js@ passes to KaTeX directly. Haskell never reads it.
-- 2. __A space's macros__ ('Wiki.Core.Space.mathMacros'), inherited by its
--    subspaces: 'spaceMacros' returns the blocks of a space's chain, its
--    top-level ancestor's first and its own last.
-- 3. __A page's macros__: a definition in one formula applies to every
--    later formula of the same page, as in a LaTeX document. The renderer
--    ("Wiki.Core.Markdown.Render") passes each formula the earlier formulas,
--    in document order, that define something ('definesMacros').
--
-- So a formula gets a list of blocks of TeX ('Macros'), from the farthest
-- to the nearest, and the list depends only on the page and its space. A
-- formula renders the same whatever order the islands are rendered in.
-- KaTeX parses the blocks, in the browser (@web/src/islands.js@). Each
-- block is parsed on top of the blocks before it, and a @\\newcommand@ of
-- a macro an earlier block defined replaces it rather than failing, so
-- that the nearer definition wins. A block KaTeX cannot parse keeps the
-- definitions before the error, and the page is rendered regardless.
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

-- | 'Macros': blocks of TeX definitions, the farthest first. Each block is
-- parsed on top of the ones before it, so a later block overrides an
-- earlier block's macro of the same name. A space's blocks come before its
-- page's formulas.
newtype Macros = Macros [Text]
  deriving stock (Eq, Ord, Show)
  deriving newtype (Semigroup, Monoid)

-- | The macros for a space's pages, among the given spaces: the macros of
-- the space's top-level ancestor first and its own last, skipping the
-- spaces that have none. A space that is not in the list, or whose
-- ancestors are not, has none.
spaceMacros :: [Space] -> SpaceId -> Macros
spaceMacros spaces sid =
  Macros
    [ s.mathMacros
    | s <- fromMaybe [] (ancestry (\i -> find (\s -> s.id == i) spaces) sid)
    , not (T.null (T.strip s.mathMacros))
    ]

-- | Whether a formula may define a macro for the formulas after it: whether
-- it contains one of TeX's defining commands. A formula that only contains
-- one by accident (@\\definecolor@ contains @\\def@) is passed on too,
-- which costs KaTeX a parse and changes nothing. A formula that defines a
-- macro inside braces is passed on, and KaTeX forgets the definition at
-- the closing brace, as TeX does.
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
