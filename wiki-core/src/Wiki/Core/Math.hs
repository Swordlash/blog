-- | Math macros: the macros a formula is rendered with, besides KaTeX's own
-- commands.
--
-- KaTeX has no @\\usepackage@: the commands it supports are fixed, so the
-- wiki extends it with macros, in three layers. Where two layers define
-- the same macro, the nearer one wins:
--
-- 1. __Built in__, for every page: @web/src/katex-macros.tex@, which the
--    page's @islands.js@ passes to KaTeX directly; or, once an
--    administrator has opened the editor's settings (WP5.41 of
--    docs/PLAN.md), the server's own copy of them, @mathMacros@ in the
--    server's settings, which the application passes as the first block,
--    marked by 'wikiMacros' so that the shipped ones are not read under it.
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

    -- * The wiki's own macros
  , wikiMacros
  , wikiMacrosMarker

    -- * Which macros a text defines and uses
  , definedMacros
  , removedMacros
  , usesMacro
  , onlyDefinitions
  )
where

import Data.List (lookup)
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

--------------------------------------------------------------------------------
-- The wiki's own macros

-- | 'wikiMacrosMarker' is the TeX comment that starts the block of the
-- wiki's built-in macros as the server's settings keep them ('wikiMacros').
-- @web/src/islands.js@ reads a run of blocks that starts with it on top of
-- nothing, in place of the macros it ships with
-- (@web/src/katex-macros.tex@), so that a macro an administrator removed is
-- gone. To KaTeX it is a comment.
wikiMacrosMarker :: Text
wikiMacrosMarker = "%wiki-macros\n"

-- | The block of the wiki's built-in macros as the server's settings keep
-- them, marked for the islands ('wikiMacrosMarker'). It comes first among
-- a formula's blocks.
wikiMacros :: Text -> Text
wikiMacros = (wikiMacrosMarker <>)

--------------------------------------------------------------------------------
-- Which macros a text defines and uses

-- | The commands that define a macro by name, with what each takes before
-- its body.
data Definer = NewCommand | Def | Let

definers :: [(Text, Definer)]
definers =
  [ ("\\newcommand", NewCommand)
  , ("\\renewcommand", NewCommand)
  , ("\\providecommand", NewCommand)
  , ("\\DeclareMathOperator", NewCommand)
  , ("\\def", Def)
  , ("\\gdef", Def)
  , ("\\edef", Def)
  , ("\\xdef", Def)
  , ("\\let", Let)
  ]

-- | The macros a block of TeX defines, by name with their backslash
-- (@\\Prob@), in the order of the block, each once: those of
-- @\\newcommand@ and its relatives, of @\\DeclareMathOperator@, of
-- @\\def@ and its relatives, and of @\\let@. A comment defines nothing.
definedMacros :: Text -> [Text]
definedMacros = ordNub . fst . definitionsAndRest . withoutComments

-- | The macros an old block of definitions has and a new one has not:
-- those whose removal may break a page that uses them ('usesMacro').
removedMacros :: Text -> Text -> [Text]
removedMacros old new = filter (`notElem` definedMacros new) (definedMacros old)

-- | Whether a text (a page's Markdown, a formula) uses a macro: whether it
-- holds the macro's name not followed by a letter, so that @\\E@ is not
-- found in @\\Earth@. A name that is one other character (@\\,@) is
-- found wherever it is.
usesMacro :: Text -> Text -> Bool
usesMacro name text = any follows (drop 1 (T.splitOn name text))
  where
    wordName = T.all isAlpha (T.drop 1 name)
    follows rest = not wordName || maybe True (not . isAlpha . fst) (T.uncons rest)

-- | Whether a formula does nothing but define macros: what is left of it
-- without its definitions and its comments is white space. Such a formula
-- shows nothing on a page (a page's block of macros, WP5.41 of
-- docs/PLAN.md), as the export already leaves it out.
onlyDefinitions :: Text -> Bool
onlyDefinitions tex = case definitionsAndRest (withoutComments tex) of
  ([], _) -> False
  (_, rest) -> T.all isSpace rest

-- | A text without its TeX comments: from a @%@ that is not escaped to the
-- end of its line.
withoutComments :: Text -> Text
withoutComments = T.intercalate "\n" . map uncomment . T.lines
  where
    uncomment line = go "" line
      where
        go before rest = case T.breakOn "%" rest of
          (a, b)
            | T.null b -> before <> a
            | "\\" `T.isSuffixOf` a && not ("\\\\" `T.isSuffixOf` a) -> go (before <> a <> "%") (T.drop 1 b)
            | otherwise -> before <> a

-- | The names a text defines, and the text without the definitions it could
-- read whole. A definition it cannot read whole (an unclosed brace) is left
-- in the text, and its name is not counted.
definitionsAndRest :: Text -> ([Text], Text)
definitionsAndRest = go [] ""
  where
    go names kept text = case T.breakOn "\\" text of
      (before, rest)
        | T.null rest -> (reverse names, kept <> before)
        | Just (name, after) <- definition rest -> go (name : names) (kept <> before) after
        | otherwise ->
            let (command, after) = controlSequence rest
             in go names (kept <> before <> command) after
    -- A definition at the start of the text, and the text after it.
    definition t = do
      (command, after) <- Just (controlSequence t)
      kind <- lookup command definers
      case kind of
        NewCommand -> do
          let starred = fromMaybe after (T.stripPrefix "*" after)
          (name, afterName) <- macroName (T.stripStart starred)
          let afterArgs = optionalBracket (optionalBracket (T.stripStart afterName))
          (_, afterBody) <- braced (T.stripStart afterArgs)
          pure (name, afterBody)
        Def -> do
          (name, afterName) <- controlName (T.stripStart after)
          let params = T.takeWhile (/= '{') afterName
          guard (T.all (\c -> c == '#' || isDigit c || isSpace c) params)
          (_, afterBody) <- braced (T.drop (T.length params) afterName)
          pure (name, afterBody)
        Let -> do
          (name, afterName) <- controlName (T.stripStart after)
          let afterEquals = T.stripStart (fromMaybe afterName (T.stripPrefix "=" (T.stripStart afterName)))
          afterValue <- case T.uncons afterEquals of
            Just ('\\', _) -> Just (snd (controlSequence afterEquals))
            Just (_, more) -> Just more
            Nothing -> Nothing
          pure (name, afterValue)
    -- A macro's name, braced (@{\\x}@) or not (@\\x@).
    macroName t = case T.uncons t of
      Just ('{', inside) -> do
        (name, after) <- controlName (T.stripStart inside)
        rest <- T.stripPrefix "}" (T.stripStart after)
        pure (name, rest)
      _ -> controlName t
    controlName t
      | "\\" `T.isPrefixOf` t = let (name, after) = controlSequence t in if T.length name > 1 then Just (name, after) else Nothing
      | otherwise = Nothing
    optionalBracket t = case T.uncons t of
      Just ('[', inside) | (_, after) <- T.breakOn "]" inside, not (T.null after) -> T.stripStart (T.drop 1 after)
      _ -> t
    -- A group in braces, with the braces in it matched, and what follows.
    braced t = case T.uncons t of
      Just ('{', inside) -> closing (1 :: Int) "" inside
      _ -> Nothing
      where
        closing depth acc rest = case T.uncons rest of
          Nothing -> Nothing
          Just ('\\', more) -> closing depth (acc <> "\\" <> T.take 1 more) (T.drop 1 more)
          Just ('{', more) -> closing (depth + 1) (acc <> "{") more
          Just ('}', more)
            | depth == 1 -> Just (acc, more)
            | otherwise -> closing (depth - 1) (acc <> "}") more
          Just (c, more) -> closing depth (T.snoc acc c) more

-- | The control sequence at the start of a text that starts with a
-- backslash, and what follows: @\\name@ (letters) or a backslash and one
-- other character.
controlSequence :: Text -> (Text, Text)
controlSequence t = case T.uncons (T.drop 1 t) of
  Just (c, _)
    | isAlpha c ->
        let letters = T.takeWhile isAlpha (T.drop 1 t)
         in T.splitAt (1 + T.length letters) t
  Just _ -> T.splitAt 2 t
  Nothing -> (t, "")
