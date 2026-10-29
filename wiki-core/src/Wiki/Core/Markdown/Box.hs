-- | Boxes: the kinds of @> [!KIND]@ block a page may hold, and the kinds an
-- administrator defines in the server's settings (WP5.29 of docs/PLAN.md).
--
-- GitHub's five kinds (note, tip, important, warning, caution) are built
-- in, and each has its own look in the stylesheet. Any other kind,
-- @> [!EXERCISE]@, is a box too: its class is @alert-exercise@ and its
-- title is the kind's name, capitalised ('kindTitle'). Such a box looks
-- plain until an administrator defines the kind ('BoxKind'): a label for
-- its title, a colour from the theme's palette and an icon from a fixed
-- set. The renderer ("Wiki.Core.Markdown.Render") puts the colour and the
-- icon on the box as CSS custom properties ('boxStyle'), so the
-- stylesheet has one rule for every defined kind and needs no change when
-- an administrator adds one.
module Wiki.Core.Markdown.Box
  ( -- * Kinds of box
    AlertKind (..)
  , builtInKinds
  , alertKindName
  , readAlertKind
  , validKindName
  , kindTitle

    -- * Kinds an administrator defines
  , BoxKind (..)
  , BoxColour (..)
  , colourName
  , readColour
  , BoxIcon (..)
  , iconName
  , readIcon
  , checkBoxKinds
  , boxStyle
  , definedKind
  , boxLabel
  , maxLabelLength
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Char (isAsciiLower)
import Data.Text qualified as T
import Protolude

-- | 'AlertKind' is the kind of a box, @> [!KIND]@: one of GitHub's five,
-- or any other name, kept in lower case.
data AlertKind = Note | Tip | Important | Warning | Caution | Custom Text
  deriving stock (Eq, Ord, Show)

-- | GitHub's five kinds, which the stylesheet draws each in its own way.
builtInKinds :: [AlertKind]
builtInKinds = [Note, Tip, Important, Warning, Caution]

-- | A kind's name, in lower case: @note@, @exercise@. The box's class is
-- @alert-@ and this name.
alertKindName :: AlertKind -> Text
alertKindName = \case
  Note -> "note"
  Tip -> "tip"
  Important -> "important"
  Warning -> "warning"
  Caution -> "caution"
  Custom name -> name

-- | The kind a marker names, in any case (@NOTE@, @Exercise@), if it is a
-- name a kind may have ('validKindName').
readAlertKind :: Text -> Maybe AlertKind
readAlertKind written
  | Just k <- find ((== name) . alertKindName) builtInKinds = Just k
  | validKindName name = Just (Custom name)
  | otherwise = Nothing
  where
    name = T.toLower written

-- | Whether a name may be a kind of box of its own: lower-case ASCII
-- letters and dashes, starting with a letter, at most 32 characters, and
-- neither one of the five nor a name the box's own parts use. The box's
-- class is @alert-@ and the name, and the parts of a box have the classes
-- @alert-title@ (its title) and @alert-icon@ (its icon), so a kind called
-- @title@ or @icon@ would style its whole box as that part. The parser
-- ("Wiki.Core.Markdown.Ast") and the server's settings ('checkBoxKinds')
-- both take a name by this rule, so a kind the settings accept is one a
-- page can write.
validKindName :: Text -> Bool
validKindName name =
  maybe False (isAsciiLower . fst) (T.uncons name)
    && T.length name <= 32
    && T.all (\c -> isAsciiLower c || c == '-') name
    && name `notElem` (reservedNames <> map alertKindName builtInKinds)

-- | The names of a box's parts, which no kind may have ('validKindName').
reservedNames :: [Text]
reservedNames = ["title", "icon"]

-- | The title a box of a kind nobody defined gets: its name, capitalised,
-- with spaces for its dashes (@exercise@ gives @Exercise@, @fun-fact@
-- gives @Fun fact@).
kindTitle :: Text -> Text
kindTitle name = case T.uncons (T.replace "-" " " name) of
  Just (c, rest) -> T.cons (toUpper c) rest
  Nothing -> name

----------------------------------------------------------------------
-- Kinds an administrator defines

-- | 'BoxKind' is a kind of box an administrator defined in the server's
-- settings: its name (what follows @[!@ in the Markdown, in lower case),
-- the title its boxes show, and its colour and icon.
data BoxKind = BoxKind
  { name :: Text
  , label :: Text
  -- ^ The title of its boxes, unless a box gives its own after the
  -- marker.
  , colour :: BoxColour
  , icon :: BoxIcon
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON BoxKind where
  toJSON b = object ["name" .= b.name, "label" .= b.label, "colour" .= b.colour, "icon" .= b.icon]

-- | Read by hand so that a kind without an icon reads as having none.
instance FromJSON BoxKind where
  parseJSON = withObject "BoxKind" $ \o ->
    BoxKind
      <$> o
      .: "name"
      <*> o .:? "label" .!= ""
      <*> o .: "colour"
      <*> o .:? "icon" .!= NoIcon

-- | 'BoxColour' is the colour of a kind of box, by name. Each is one of the
-- theme's colours, which the stylesheet sets for the light and the dark
-- scheme and for each slide theme, so a box is legible in all of them. The
-- first five are the colours of GitHub's five kinds.
data BoxColour = Blue | Green | Purple | Amber | Red | Teal | Orange | Pink | Grey
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | A colour's name in the settings: @blue@, @green@ and so on.
colourName :: BoxColour -> Text
colourName = T.toLower . show

readColour :: Text -> Maybe BoxColour
readColour t = find ((== t) . colourName) [minBound .. maxBound]

instance ToJSON BoxColour where
  toJSON = toJSON . colourName

instance FromJSON BoxColour where
  parseJSON = withText "a colour" $ \t -> maybe (fail ("not a colour of the theme: " <> toS t)) pure (readColour t)

-- | The stylesheet's variable a colour is: the five kinds' own for the
-- first five, and colours of the editor's palette for the rest.
colourVariable :: BoxColour -> Text
colourVariable = \case
  Blue -> "--note"
  Green -> "--tip"
  Purple -> "--important"
  Amber -> "--warning"
  Red -> "--caution"
  Teal -> "--c-teal"
  Orange -> "--c-orange"
  Pink -> "--c-pink"
  Grey -> "--muted"

-- | 'BoxIcon' is the icon at the start of a kind's title, from a fixed set
-- the stylesheet draws, or none.
data BoxIcon = NoIcon | Info | Lightbulb | Pencil | Question | Check | Star | Book | Flag
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | An icon's name in the settings: @none@, @info@, @pencil@ and so on.
iconName :: BoxIcon -> Text
iconName = \case
  NoIcon -> "none"
  other -> T.toLower (show other)

readIcon :: Text -> Maybe BoxIcon
readIcon t = find ((== t) . iconName) [minBound .. maxBound]

instance ToJSON BoxIcon where
  toJSON = toJSON . iconName

instance FromJSON BoxIcon where
  parseJSON = withText "an icon" $ \t -> maybe (fail ("not one of the icons: " <> toS t)) pure (readIcon t)

-- | The longest label a kind may have.
maxLabelLength :: Int
maxLabelLength = 60

-- | The kinds as they are stored, or the first reason they are invalid:
-- names and labels trimmed, a name in lower case, an empty label replaced
-- by the name capitalised ('kindTitle').
checkBoxKinds :: [BoxKind] -> Either Text [BoxKind]
checkBoxKinds kinds = do
  checked <- traverse checkOne kinds
  case [n | n <- ordNub (map (\k -> k.name) checked), length (filter ((== n) . (\k -> k.name)) checked) > 1] of
    n : _ -> Left ("There are two kinds of box named " <> n <> ".")
    [] -> pure checked
  where
    checkOne k = do
      let name = T.toLower (T.strip k.name)
          label = T.strip k.label
      when (T.null name) $ Left "A kind of box needs its name: what follows [! in the Markdown."
      when (name `elem` map alertKindName builtInKinds) $
        Left ("The kind of box " <> name <> " is one of GitHub's five (note, tip, important, warning, caution), which keep their own look.")
      unless (validKindName name) $
        Left ("A kind of box's name is letters and dashes, starting with a letter, at most 32 characters, and neither title nor icon: " <> name)
      when (T.length label > maxLabelLength) $
        Left ("The label of the kind of box " <> name <> " is longer than " <> show maxLabelLength <> " characters.")
      pure BoxKind {name, label = if T.null label then kindTitle name else label, colour = k.colour, icon = k.icon}

-- | The CSS custom properties a box of a defined kind carries, in its
-- @style@ attribute: its colour (@--box-colour@) and, when it has one, its
-- icon (@--box-icon@). The values are the stylesheet's own variables, so
-- the box follows the theme it is shown in.
boxStyle :: BoxKind -> Text
boxStyle k =
  T.intercalate "; " $
    ["--box-colour: var(" <> colourVariable k.colour <> ")"]
      <> ["--box-icon: var(--box-icon-" <> iconName k.icon <> ")" | k.icon /= NoIcon]

-- | The definition of a kind among those the administrator gave: none for
-- GitHub's five, which keep their own look, nor for a kind nobody defined.
definedKind :: [BoxKind] -> AlertKind -> Maybe BoxKind
definedKind defined = \case
  Custom name -> find (\k -> k.name == name) defined
  _ -> Nothing

-- | The title a box shows when it gives none of its own, from its kind and
-- the kind's definition ('definedKind'): a defined kind's label, or else
-- the kind's name capitalised (@Note@, @Exercise@).
boxLabel :: Maybe BoxKind -> AlertKind -> Text
boxLabel defined kind = case defined of
  Just k | not (T.null (T.strip k.label)) -> k.label
  _ -> kindTitle (alertKindName kind)
