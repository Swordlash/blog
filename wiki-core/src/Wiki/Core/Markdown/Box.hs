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
--
-- Boxes are numbered per kind (WP5.40 of docs/PLAN.md): the third tip of
-- a page is "Tip 3", and its examples are counted apart from its tips. A
-- space chooses how ('BoxNumbering'): within the page (@3@), after the
-- page's own number (@2.3@), or after the page's number and the section's
-- (@2.1.3@, where a section starts at each @##@ heading). A box written
-- with a star, @> [!TIP*]@, has no number and is not counted, as LaTeX's
-- @equation*@. 'BoxCounter' does the counting, in the order a page shows
-- its boxes.
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
  , themeColours
  , colourName
  , readColour
  , readHexColour
  , BoxIcon (..)
  , iconName
  , readIcon
  , checkBoxKinds
  , boxStyle
  , definedKind
  , boxLabel
  , maxLabelLength

    -- * Numbers
  , BoxNumbering (..)
  , numberings
  , numberingName
  , numberingLabel
  , readNumbering
  , Numbering (..)
  , noNumbers
  , BoxCounter
  , startCounting
  , countSection
  , countBox
  , boxCaption
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.!=), (.:), (.:?), (.=))
import Data.Char (isAsciiLower)
import Data.Map.Strict qualified as Map
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

-- | 'BoxColour' is the colour of a kind of box. Most are one of the
-- theme's colours, by name, which the stylesheet sets for the light and
-- the dark scheme and for each slide theme, so a box is legible in all of
-- them. The first five are the colours of GitHub's five kinds.
-- 'CustomColour' is any other colour, chosen with a colour picker: a hex
-- colour, @#rrggbb@ in lower case ('readHexColour'). It is the same in
-- every scheme, so the administrator who picks it checks that it reads
-- well on a light and on a dark page.
data BoxColour = Blue | Green | Purple | Amber | Red | Teal | Orange | Pink | Grey | CustomColour Text
  deriving stock (Eq, Ord, Show)

-- | The theme's colours, in the order the settings offer them.
themeColours :: [BoxColour]
themeColours = [Blue, Green, Purple, Amber, Red, Teal, Orange, Pink, Grey]

-- | A colour's name in the settings: @blue@, @green@ and so on, and a
-- custom colour's hex code, @#1a7f37@.
colourName :: BoxColour -> Text
colourName = \case
  CustomColour hex -> hex
  c -> T.toLower (show c)

-- | The colour a name in the settings names: one of the theme's, or a hex
-- colour ('readHexColour').
readColour :: Text -> Maybe BoxColour
readColour t = find ((== t) . colourName) themeColours <|> (CustomColour <$> readHexColour t)

-- | A hex colour as a custom colour keeps it: @#@ and six hexadecimal
-- digits, in lower case, which is what a colour picker
-- (@\<input type="color">@) gives. Nothing else is taken, since the
-- colour is written into the box's @style@ attribute ('boxStyle').
readHexColour :: Text -> Maybe Text
readHexColour t = case T.uncons (T.strip t) of
  Just ('#', digits) | T.length digits == 6, T.all isHexDigit digits -> Just ("#" <> T.toLower digits)
  _ -> Nothing

instance ToJSON BoxColour where
  toJSON = toJSON . colourName

instance FromJSON BoxColour where
  parseJSON = withText "a colour" $ \t -> maybe (fail ("not a colour of the theme, nor a hex colour: " <> toS t)) pure (readColour t)

-- | The CSS value of a colour: the stylesheet's variable for each of the
-- theme's colours (the five kinds' own for the first five, and colours of
-- the editor's palette for the rest), and a custom colour as it is.
colourValue :: BoxColour -> Text
colourValue = \case
  Blue -> "var(--note)"
  Green -> "var(--tip)"
  Purple -> "var(--important)"
  Amber -> "var(--warning)"
  Red -> "var(--caution)"
  Teal -> "var(--c-teal)"
  Orange -> "var(--c-orange)"
  Pink -> "var(--c-pink)"
  Grey -> "var(--muted)"
  CustomColour hex -> fromMaybe "inherit" (readHexColour hex)

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
      colour <- case k.colour of
        CustomColour hex -> maybe (Left ("The colour of the kind of box " <> name <> " is not a hex colour such as #1a7f37: " <> hex)) (Right . CustomColour) (readHexColour hex)
        theme -> Right theme
      pure BoxKind {name, label = if T.null label then kindTitle name else label, colour, icon = k.icon}

-- | The CSS custom properties a box of a defined kind carries, in its
-- @style@ attribute: its colour (@--box-colour@) and, when it has one, its
-- icon (@--box-icon@). The values are the stylesheet's own variables, so
-- the box follows the theme it is shown in, except a custom colour, which
-- is written as its hex code.
boxStyle :: BoxKind -> Text
boxStyle k =
  T.intercalate "; " $
    ["--box-colour: " <> colourValue k.colour]
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

----------------------------------------------------------------------
-- Numbers

-- | 'BoxNumbering' is how a space numbers the boxes of its pages, a
-- setting of the space ('Wiki.Core.Space.boxNumbering'). Each kind is
-- counted on its own: a page's tips are Tip 1, Tip 2, and its first
-- example is Example 1.
data BoxNumbering
  = -- | No box has a number.
    NoNumbers
  | -- | Numbered within the page: @3@. The default.
    InPage
  | -- | After the page's number, its position under its parent: @2.3@.
    WithPage
  | -- | After the page's number and the section's: @2.1.3@. A section
    -- starts at each @##@ heading (the page's title is its @#@ line), and
    -- the boxes of each section are counted from 1. Boxes before the first
    -- @##@ are in section 0.
    WithSection
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Every way of numbering, in the order the space's settings offer them.
numberings :: [BoxNumbering]
numberings = [minBound .. maxBound]

-- | A way of numbering's name, as the API and the database write it.
numberingName :: BoxNumbering -> Text
numberingName = \case
  NoNumbers -> "none"
  InPage -> "in-page"
  WithPage -> "with-page"
  WithSection -> "with-section"

-- | A way of numbering as the space's settings describe it.
numberingLabel :: BoxNumbering -> Text
numberingLabel = \case
  NoNumbers -> "No numbers"
  InPage -> "Within the page: Tip 3"
  WithPage -> "With the page's number: Tip 2.3"
  WithSection -> "With the page's and the section's numbers: Tip 2.1.3"

readNumbering :: Text -> Maybe BoxNumbering
readNumbering t = find ((== t) . numberingName) numberings

instance ToJSON BoxNumbering where
  toJSON = toJSON . numberingName

-- | A space written before the setting existed (an older client's, a
-- demo's stored state) numbers within the page.
instance FromJSON BoxNumbering where
  parseJSON = withText "a way of numbering boxes" $ \t -> maybe (fail ("not a way of numbering boxes: " <> toS t)) pure (readNumbering t)
  omittedField = Just InPage

-- | 'Numbering' is how one page's boxes are numbered: its space's way
-- ('BoxNumbering'), and the page's own number, its position under its
-- parent from 1 ('Wiki.Core.Page.pageNumber'). A page whose number is not
-- known (a preview of something that is not a page of the space) numbers
-- within the page whatever the space says.
data Numbering = Numbering
  { form :: BoxNumbering
  , number :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | No numbers: what is rendered outside a page (a comment, the front
-- page, the administration's preview of a kind).
noNumbers :: Numbering
noNumbers = Numbering {form = NoNumbers, number = Nothing}

-- | 'BoxCounter' counts a page's boxes in the order the page shows them:
-- the section it is in, and how many boxes of each kind (by name) came
-- before, in the page or in the section.
data BoxCounter = BoxCounter
  { numbering :: Numbering
  , section :: Int
  , counts :: Map Text Int
  }
  deriving stock (Eq, Show)

-- | The counter at the start of a page. Without the page's number, the
-- boxes are numbered within the page.
startCounting :: Numbering -> BoxCounter
startCounting numbering = BoxCounter {numbering = known, section = 0, counts = mempty}
  where
    known = case numbering.number of
      Nothing | numbering.form `elem` [WithPage, WithSection] -> numbering {form = InPage}
      _ -> numbering

-- | The counter after a @##@ heading: the next section, whose boxes are
-- counted from 1 again when sections are numbered.
countSection :: BoxCounter -> BoxCounter
countSection c = case c.numbering.form of
  WithSection -> c {section = c.section + 1, counts = mempty}
  _ -> c {section = c.section + 1}

-- | The number of the next box of a kind, as it is shown (@3@, @2.3@,
-- @2.1.3@), or none when the page numbers no boxes; and the counter after
-- it. A starred box (@> [!TIP*]@) is not counted at all.
countBox :: AlertKind -> BoxCounter -> (Maybe Text, BoxCounter)
countBox kind c = case c.numbering.form of
  NoNumbers -> (Nothing, c)
  numbered -> (Just (shown numbered), c {counts = Map.insert name n c.counts})
  where
    name = alertKindName kind
    n = Map.findWithDefault 0 name c.counts + 1
    page = maybe "" (\p -> show p <> ".") c.numbering.number
    shown = \case
      WithPage -> page <> show n
      WithSection -> page <> show c.section <> "." <> show n
      _ -> show n

-- | What a box's title starts with, before the title written after its
-- marker: the label and the number of a numbered box (@Tip 3@, and
-- @Tip 3: @ before a title of its own), and the label alone for a box
-- without a number and without a title. A box without a number but with a
-- title shows the title alone, as it did before boxes had numbers.
boxCaption :: Maybe BoxKind -> AlertKind -> Maybe Text -> Bool -> Text
boxCaption defined kind number titled = case number of
  Just n -> boxLabel defined kind <> " " <> n <> (if titled then ": " else "")
  Nothing
    | titled -> ""
    | otherwise -> boxLabel defined kind
