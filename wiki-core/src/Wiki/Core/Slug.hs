-- | Slugs: the names of spaces and pages in addresses. The address
-- @/s/engineering/p/onboarding@ is made of slugs.
--
-- A slug is lowercase ASCII letters, digits and single dashes between them,
-- so that it reads the same in an address bar, a link and a file name,
-- needs no escaping anywhere, and two slugs that look alike are equal. The
-- rules are checked in one place, 'mkSlug', and a 'Slug' value is proof
-- that they hold: there is no other way to construct one ('slugify' and
-- 'freshSlug' build on 'mkSlug').
module Wiki.Core.Slug
  ( Slug
  , SlugError (..)
  , mkSlug
  , slugText
  , slugify
  , freshSlug
  , foldLetter

    -- * Headings
  , headingSlug
  , freshName
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Char (GeneralCategory (..), generalCategory, isAsciiLower)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

-- | 'Slug': a text that follows the slug rules. Its constructor is not exported.
newtype Slug = Slug Text
  deriving stock (Eq, Ord, Show)

-- | Encoded as the bare text; decoded through 'mkSlug', so that JSON cannot
-- carry a slug that breaks the rules.
instance ToJSON Slug where
  toJSON = toJSON . slugText
  toEncoding = toEncoding . slugText

instance FromJSON Slug where
  parseJSON = withText "Slug" $ \t ->
    either (\e -> fail ("not a slug: " <> show t <> ", " <> show e)) pure (mkSlug t)

-- | In a URL (a path segment in the server's API), as in JSON: the bare
-- text, parsed through 'mkSlug'.
instance ToHttpApiData Slug where
  toUrlPiece = slugText

instance FromHttpApiData Slug where
  parseUrlPiece t = first (\e -> "not a slug: " <> show t <> ", " <> show e) (mkSlug t)

-- | Why a text is not a slug: the first rule it breaks, in the order the
-- rules are listed here.
data SlugError
  = -- | A slug names something, so it has at least one character.
    SlugEmpty
  | -- | The character is not a lowercase ASCII letter, a digit or a dash.
    SlugBadCharacter Char
  | -- | A slug starts and ends with a letter or a digit.
    SlugEdgeDash
  | -- | Dashes separate words, one dash at a time.
    SlugDoubleDash
  deriving stock (Eq, Show)

-- | The slug for this text, or the first rule the text breaks. The text is
-- checked as it is. Making a slug from a title (lowercasing, replacing
-- spaces) is 'slugify', since that involves choices.
mkSlug :: Text -> Either SlugError Slug
mkSlug t
  | T.null t = Left SlugEmpty
  | Just c <- T.find (not . allowed) t = Left (SlugBadCharacter c)
  | "-" `T.isPrefixOf` t || "-" `T.isSuffixOf` t = Left SlugEdgeDash
  | "--" `T.isInfixOf` t = Left SlugDoubleDash
  | otherwise = Right (Slug t)
  where
    allowed c = isAsciiLower c || isDigit c || c == '-'

-- | The slug's text, as written in an address.
slugText :: Slug -> Text
slugText (Slug t) = t

-- | The slug made from a title, or 'Nothing' when no character of the
-- title is left (a title of punctuation, or in a script with no ASCII
-- spelling).
--
-- The title is lowercased. A letter with an obvious ASCII spelling is
-- replaced by it: diacritics are removed (@ż@ becomes @z@, @é@ becomes
-- @e@, also when the accent is a separate combining mark), and a few
-- letters become two (@ß@ becomes @ss@, @æ@ becomes @ae@). Apostrophes are
-- dropped, so that @Mateusz's notes@ becomes @mateuszs-notes@ rather than
-- having a word @s@. Every other character (spaces, punctuation, letters
-- with no ASCII spelling) separates words: it becomes a dash, and dashes
-- are collapsed and trimmed.
--
-- A slug's text gives the slug back: @slugify (slugText s) == Just s@.
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

-- | One character as 'slugify' converts it: lowercased, a letter with an
-- obvious ASCII spelling replaced by it (@Ż@ becomes @z@, @ß@ becomes
-- @ss@), a combining mark dropped. Every other character is only
-- lowercased, so that the converted text keeps its spaces and punctuation,
-- and a script with no ASCII spelling stays as it is.
--
-- Search ("Wiki.Core.Search") uses it to find @zazolc@ in @Zażółć@, as a
-- title's slug would. It works one character at a time, so that a match in
-- the converted text can be traced back to the original characters.
foldLetter :: Char -> Text
foldLetter c
  | isMark c = ""
  | otherwise = T.concatMap (\l -> fromMaybe (T.singleton l) (Map.lookup l asciiFolds)) (T.toLower (T.singleton c))

isMark :: Char -> Bool
isMark c = generalCategory c `elem` [NonSpacingMark, SpacingCombiningMark, EnclosingMark]

-- | The ASCII spelling of the lowercase letters of Latin-1 and Latin
-- Extended-A that have an obvious one: Polish first, since the owner
-- writes Polish, and the rest of the European Latin alphabets with it.
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

-- | The slug itself if it is free, and otherwise the first free one of
-- @slug-2@, @slug-3@, …: how a backend names a new page when a sibling
-- already has its title's slug. The predicate says whether a slug is taken.
freshSlug :: (Slug -> Bool) -> Slug -> Slug
freshSlug taken base
  | not (taken base) = base
  | otherwise = go (2 :: Int)
  where
    -- A slug ends in a letter or a digit, so adding a dash and a number
    -- breaks no rule.
    go n =
      let candidate = Slug (slugText base <> "-" <> show n)
       in if taken candidate then go (n + 1) else candidate

--------------------------------------------------------------------------------
-- Headings

-- | The @id@ a page's heading gets from its text. A link to a part of the
-- page names that id after the @#@ (@\/s\/docs\/p\/tour\/#getting-started@).
--
-- Not a 'Slug': a heading's id is only read within its own page, never
-- typed into a path or a file name. So it keeps the letters of every script
-- as written rather than converting them to ASCII ('slugify'): @Zażółć
-- gęślą@ becomes @zażółć-gęślą@, as GitHub and pandoc write it. The text is
-- lowercased; letters, digits, combining marks, @-@ and @_@ are kept; white
-- space becomes a dash; every other character (punctuation, symbols, emoji)
-- is dropped; and dashes are collapsed and trimmed, so that @A – B@ becomes
-- @a-b@. A heading with no character left becomes @section@.
--
-- Every renderer takes a heading's id from the parsed document
-- ("Wiki.Core.Markdown.Ast"), which calls this one function. So the
-- editor's preview, the page, the prerender and the server's render give a
-- heading the same id, and a link to it works in all of them.
headingSlug :: Text -> Text
headingSlug heading = case T.intercalate "-" (filter (not . T.null) (T.split (== '-') kept)) of
  "" -> "section"
  ident -> ident
  where
    kept = T.concatMap keep (T.toLower heading)
    keep c
      | isAlphaNum c || isMark c || c == '_' = T.singleton c
      | isSpace c || c == '-' = "-"
      | otherwise = ""

-- | The name itself if it is free, and otherwise the first free one of
-- @name-2@, @name-3@, …, as 'freshSlug' does for slugs: how a heading gets
-- a different id when an earlier heading already has the same one.
freshName :: (Text -> Bool) -> Text -> Text
freshName taken base
  | not (taken base) = base
  | otherwise = fromMaybe base (find (not . taken) [base <> "-" <> show n | n <- [2 :: Int ..]])
