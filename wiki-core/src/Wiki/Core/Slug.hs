-- | The name a space or a page has in an address: @/s/engineering/p/onboarding@
-- is made of slugs.
--
-- A slug is lowercase ASCII letters, digits and single dashes between them, so
-- that it reads the same in an address bar, a link and a file name, needs no
-- escaping anywhere, and two slugs that look alike are alike. The rules are
-- checked once, by 'mkSlug', and a 'Slug' is proof that they hold: there is no
-- other way to make one.
module Wiki.Core.Slug
  ( Slug
  , SlugError (..)
  , mkSlug
  , slugText
  )
where

import Data.Text qualified as T
import Protolude

-- | A string that keeps the slug rules. Its constructor is not exported.
newtype Slug = Slug Text
  deriving stock (Eq, Ord, Show)

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
-- it is: making a slug out of a title (lowercasing, replacing spaces) is a
-- different function, since it has choices to make.
mkSlug :: Text -> Either SlugError Slug
mkSlug t
  | T.null t = Left SlugEmpty
  | Just c <- T.find (not . allowed) t = Left (SlugBadCharacter c)
  | "-" `T.isPrefixOf` t || "-" `T.isSuffixOf` t = Left SlugEdgeDash
  | "--" `T.isInfixOf` t = Left SlugDoubleDash
  | otherwise = Right (Slug t)
  where
    allowed c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'

-- | The slug as it is written in an address.
slugText :: Slug -> Text
slugText (Slug t) = t
