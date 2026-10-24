-- | The name a space or a page has in an address: @/s/engineering/p/onboarding@
-- is made of slugs.
--
-- A slug is lowercase ASCII letters, digits and single dashes between them, so
-- that it reads the same in an address bar, a link and a file name, needs no
-- escaping anywhere, and two slugs that look alike are alike. The rules are
-- checked once, by 'mkSlug', and a 'Slug' is proof that they hold: there is no
-- other way to make one ('slugify' and 'freshSlug' build on what 'mkSlug'
-- accepts).
module Wiki.Core.Slug
  ( Slug
  , SlugError (..)
  , mkSlug
  , slugText
  , slugify
  , freshSlug
  , foldLetter
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Char (GeneralCategory (..), generalCategory, isAsciiLower)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

-- | A string that keeps the slug rules. Its constructor is not exported.
newtype Slug = Slug Text
  deriving stock (Eq, Ord, Show)

-- | Written as the bare string; read back through 'mkSlug', so JSON cannot
-- smuggle in a slug that breaks the rules.
instance ToJSON Slug where
  toJSON = toJSON . slugText
  toEncoding = toEncoding . slugText

instance FromJSON Slug where
  parseJSON = withText "Slug" $ \t ->
    either (\e -> fail ("not a slug: " <> show t <> ", " <> show e)) pure (mkSlug t)

-- | In a URL (a segment of a path, in the server's API), as in JSON: the
-- bare string, read back through 'mkSlug'.
instance ToHttpApiData Slug where
  toUrlPiece = slugText

instance FromHttpApiData Slug where
  parseUrlPiece t = first (\e -> "not a slug: " <> show t <> ", " <> show e) (mkSlug t)

-- | Why a string is not a slug: the first rule it breaks, in the order they
-- are listed here.
data SlugError
  = -- | A slug names something, so it has at least one character.
    SlugEmpty
  | -- | The character is not a lowercase ASCII letter, a digit or a dash.
    SlugBadCharacter Char
  | -- | A slug starts and ends with a letter or a digit.
    SlugEdgeDash
  | -- | Dashes separate words, one at a time.
    SlugDoubleDash
  deriving stock (Eq, Show)

-- | The slug this text is, or the first rule it breaks. The text is taken as
-- it is: making a slug out of a title (lowercasing, replacing spaces) is
-- 'slugify', since it has choices to make.
mkSlug :: Text -> Either SlugError Slug
mkSlug t
  | T.null t = Left SlugEmpty
  | Just c <- T.find (not . allowed) t = Left (SlugBadCharacter c)
  | "-" `T.isPrefixOf` t || "-" `T.isSuffixOf` t = Left SlugEdgeDash
  | "--" `T.isInfixOf` t = Left SlugDoubleDash
  | otherwise = Right (Slug t)
  where
    allowed c = isAsciiLower c || isDigit c || c == '-'

-- | The slug as it is written in an address.
slugText :: Slug -> Text
slugText (Slug t) = t

-- | The slug a title suggests, or 'Nothing' when nothing of the title
-- survives (a title of punctuation, or in a script with no ASCII fold).
--
-- The title is lowercased. A letter with an obvious ASCII spelling is
-- written so: diacritics go (@ż@ is @z@, @é@ is @e@, also when the accent is
-- a separate combining mark), and a few letters become two (@ß@ is @ss@, @æ@
-- is @ae@). Apostrophes are dropped, so that @Mateusz's notes@ is
-- @mateuszs-notes@ rather than a word @s@. Everything else, spaces and
-- punctuation and letters with no fold, separates words: it becomes a dash,
-- and dashes are collapsed and trimmed.
--
-- A slug is its own slug: @slugify (slugText s) == Just s@.
slugify :: Text -> Maybe Slug
slugify title =
  rightToMaybe (mkSlug (T.intercalate "-" (filter (not . T.null) (T.split (== '-') folded))))
  where
    folded = T.concatMap toAscii (T.toLower title)
    toAscii c
      | isAsciiLower c || isDigit c = T.singleton c
      | Just ascii <- Map.lookup c asciiFolds = ascii
      | c `elem` apostrophes = ""
      | isMark c = ""
      | otherwise = "-"
    apostrophes = ['\'', '\x2019', '\x02BC'] :: [Char]

-- | A character as 'slugify' folds a letter: lowercased, a letter with an
-- obvious ASCII spelling written so (@Ż@ is @z@, @ß@ is @ss@), a combining
-- mark dropped. Everything else is only lowercased, so that the fold of a
-- text keeps its spaces and punctuation, and a script with no ASCII spelling
-- folds to itself.
--
-- It is what makes search ("Wiki.Core.Search") find @zazolc@ in @Zażółć@ the
-- way the slug of a title does, one character at a time, so that a match in
-- the fold can be traced back to the characters it came from.
foldLetter :: Char -> Text
foldLetter c
  | isMark c = ""
  | otherwise = T.concatMap (\l -> fromMaybe (T.singleton l) (Map.lookup l asciiFolds)) (T.toLower (T.singleton c))

isMark :: Char -> Bool
isMark c = generalCategory c `elem` [NonSpacingMark, SpacingCombiningMark, EnclosingMark]

-- | The ASCII spelling of the lowercase letters of Latin-1 and Latin
-- Extended-A that have an obvious one: Polish first, since that is what the
-- owner writes, and the rest of the European Latin alphabets with it.
asciiFolds :: Map Char Text
asciiFolds =
  Map.fromList
    [ (c, ascii)
    | (letters, ascii) <-
        [ ("ąàáâãäåāă", "a")
        , ("æ", "ae")
        , ("ćçĉċč", "c")
        , ("ďđð", "d")
        , ("ęèéêëēĕėě", "e")
        , ("ĝğġģ", "g")
        , ("ĥħ", "h")
        , ("ìíîïĩīĭįı", "i")
        , ("ĳ", "ij")
        , ("ĵ", "j")
        , ("ķ", "k")
        , ("łĺļľŀ", "l")
        , ("ńñņň", "n")
        , ("óòôõöøōŏő", "o")
        , ("œ", "oe")
        , ("ŕŗř", "r")
        , ("śŝşšș", "s")
        , ("ß", "ss")
        , ("ţťŧț", "t")
        , ("þ", "th")
        , ("ùúûüũūŭůűų", "u")
        , ("ŵ", "w")
        , ("ýÿŷ", "y")
        , ("źżž", "z")
        ]
          :: [([Char], Text)]
    , c <- letters
    ]

-- | The slug itself if it is free, and otherwise the first of @slug-2@,
-- @slug-3@, … that is: how a backend names a new page whose title's slug a
-- sibling already has. The predicate says whether a slug is taken.
freshSlug :: (Slug -> Bool) -> Slug -> Slug
freshSlug taken base
  | not (taken base) = base
  | otherwise = go (2 :: Int)
  where
    -- A slug ends in a letter or a digit, so a dash and a number after it
    -- keep every rule.
    go n =
      let candidate = Slug (slugText base <> "-" <> show n)
       in if taken candidate then go (n + 1) else candidate
