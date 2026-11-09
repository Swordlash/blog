-- | Encrypted spaces (WP5.74 of docs/PLAN.md): the format of what the
-- browser encrypts and the server stores without being able to read it.
--
-- = Keys
--
-- An encrypted space has a key of its own, the space key: 32 random bytes
-- (AES-256), named by a random 16-byte id ('KeyId'). The space's record
-- carries the id of its current key ('Wiki.Core.Space.encryption'); the
-- key itself never reaches the server. Each member of the space holds the
-- key through a 'KeyGrant': the key sealed to the member's public key with
-- HPKE (RFC 9180, base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
-- AES-256-GCM), with 'grantInfo' as HPKE's @info@. Only a member's browser,
-- which holds the space key, can make a grant: the server cannot.
--
-- Each page has a key of its own too, the page key ('PageKey'): 32 random
-- bytes, with an id, encrypted with the space key (AES-256-GCM, the
-- additional data 'pageKeyData'), and stored with the page. So a page can
-- later be shared alone, by sealing its key to someone, without the space
-- key.
--
-- = Content
--
-- A version of a page is its title and its text, each encrypted with the
-- page key (AES-256-GCM, a random 12-byte nonce), as 'SealedContent'. The
-- additional data of each ('fieldData') names the space, the page, the
-- page key, the version and the field, so that the server cannot move a
-- ciphertext to another page, another field or another version without the
-- browser noticing. The version is named by a random 'VersionTag' the
-- browser picks for each save, since the time a version is known by is the
-- server's to set and is not known when the browser encrypts.
--
-- The server stores the rest of a page as for any page (its place in the
-- tree, its slug, its times, who saved it), with an empty title and text.
-- What the server does with a page's text therefore finds nothing in an
-- encrypted page, and the server refuses it there with a reason.
--
-- The cryptography runs in the browser (@wiki-app\/jsbits\/encrypted.js@);
-- this module is the format, pure.
module Wiki.Core.Encrypted
  ( -- * Bytes as the browser writes them
    Encapsulated (..)
  , VersionTag (..)

    -- * Keys
  , KeyGrant (..)
  , PageKey (..)

    -- * Content
  , SealedContent (..)
  , SealedHeading (..)
  , headingOf
  , Field (..)

    -- * What each key and ciphertext is bound to
  , grantInfo
  , pageKeyData
  , fieldData

    -- * Lengths
  , nonceBytes
  , keyIdBytes
  , encapsulatedBytes
  , sealedKeyBytes
  , maxTitleCiphertext
  , maxBodyCiphertext
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Core.Id (PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Sealed (..), WrappedKey (..))

--------------------------------------------------------------------------------
-- Bytes as the browser writes them

-- | 'Encapsulated': HPKE's encapsulated key (@enc@), the ephemeral X25519
-- public key a grant was sealed with, 32 bytes in base64url.
newtype Encapsulated = Encapsulated {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, IsString)

-- | 'VersionTag': 16 random bytes in base64url that the browser picks for
-- each version it encrypts, and that the version's additional data names.
newtype VersionTag = VersionTag {text :: Text}
  deriving stock (Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON, IsString)

--------------------------------------------------------------------------------
-- Keys

-- | 'KeyGrant': a symmetric key sealed to one user's public key. For a
-- space ('Wiki.Core.Encrypted' header), the space key whose id is
-- 'keyId'; 'recipientKeyId' names the public key in the directory it is
-- sealed to. A grant to a public key that is no longer the user's current
-- one (retired by a password reset) opens for nobody, and its user is
-- waiting for a grant again.
data KeyGrant = KeyGrant
  { keyId :: KeyId
  , recipient :: UserId
  , recipientKeyId :: KeyId
  , enc :: Encapsulated
  , sealed :: Ciphertext
  -- ^ The key, 32 bytes, and AES-GCM's tag: 48 bytes.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON KeyGrant where
  toJSON g = object ["keyId" .= g.keyId, "recipient" .= g.recipient, "recipientKeyId" .= g.recipientKeyId, "enc" .= g.enc, "sealed" .= g.sealed]

instance FromJSON KeyGrant where
  parseJSON = withObject "KeyGrant" $ \o -> KeyGrant <$> o .: "keyId" <*> o .: "recipient" <*> o .: "recipientKeyId" <*> o .: "enc" <*> o .: "sealed"

-- | 'PageKey': a page's key, encrypted with its space's key: the page key's
-- id, the id of the space key it is encrypted with, and the encrypted key
-- (32 bytes and the tag).
data PageKey = PageKey
  { keyId :: KeyId
  , spaceKeyId :: KeyId
  , wrapped :: WrappedKey
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PageKey where
  toJSON k = object ["keyId" .= k.keyId, "spaceKeyId" .= k.spaceKeyId, "wrapped" .= k.wrapped]

instance FromJSON PageKey where
  parseJSON = withObject "PageKey" $ \o -> PageKey <$> o .: "keyId" <*> o .: "spaceKeyId" <*> o .: "wrapped"

--------------------------------------------------------------------------------
-- Content

-- | 'SealedContent': one version of a page, encrypted: its tag, the id of
-- the page key it is encrypted with, and its title and text.
data SealedContent = SealedContent
  { tag :: VersionTag
  , keyId :: KeyId
  , title :: Sealed
  , body :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedContent where
  showsPrec _ _ rest = "SealedContent <ciphertext>" <> rest

instance ToJSON SealedContent where
  toJSON c = object ["tag" .= c.tag, "keyId" .= c.keyId, "title" .= c.title, "body" .= c.body]

instance FromJSON SealedContent where
  parseJSON = withObject "SealedContent" $ \o -> SealedContent <$> o .: "tag" <*> o .: "keyId" <*> o .: "title" <*> o .: "body"

-- | 'SealedHeading': a version's title alone, encrypted, as a list of pages
-- or of versions carries it.
data SealedHeading = SealedHeading
  { tag :: VersionTag
  , keyId :: KeyId
  , title :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedHeading where
  showsPrec _ _ rest = "SealedHeading <ciphertext>" <> rest

instance ToJSON SealedHeading where
  toJSON c = object ["tag" .= c.tag, "keyId" .= c.keyId, "title" .= c.title]

instance FromJSON SealedHeading where
  parseJSON = withObject "SealedHeading" $ \o -> SealedHeading <$> o .: "tag" <*> o .: "keyId" <*> o .: "title"

-- | A version's heading: its title without its text.
headingOf :: SealedContent -> SealedHeading
headingOf c = SealedHeading {tag = c.tag, keyId = c.keyId, title = c.title}

-- | 'Field': which part of a version a ciphertext is.
data Field = TitleField | BodyField
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- What each key and ciphertext is bound to

-- | HPKE's @info@ for the grant of a space's key: the kind of key, the
-- space and the key's id. A grant moved to another space or key does not
-- open.
grantInfo :: SpaceId -> KeyId -> Text
grantInfo sid k = "wiki-grant/1 space " <> sid.text <> " " <> k.text

-- | The additional data a page key is encrypted with under its space's
-- key: the space, the page and the page key's id.
pageKeyData :: SpaceId -> PageId -> KeyId -> Text
pageKeyData sid pid k = "wiki-page-key/1 " <> sid.text <> " " <> pid.text <> " " <> k.text

-- | The additional data of one field of one version of a page.
fieldData :: SpaceId -> PageId -> KeyId -> VersionTag -> Field -> Text
fieldData sid pid k tag field = "wiki-page/1 " <> sid.text <> " " <> pid.text <> " " <> k.text <> " " <> tag.text <> " " <> fieldName
  where
    fieldName = case field of
      TitleField -> "title"
      BodyField -> "body"

--------------------------------------------------------------------------------
-- Lengths

-- | AES-GCM's nonce: 12 bytes.
nonceBytes :: Int
nonceBytes = 12

-- | A key's id, and a version's tag: 16 bytes.
keyIdBytes :: Int
keyIdBytes = 16

-- | HPKE's encapsulated key for X25519: 32 bytes.
encapsulatedBytes :: Int
encapsulatedBytes = 32

-- | A 32-byte key encrypted with AES-GCM (a grant's, a page key's): the key
-- and the 16-byte tag.
sealedKeyBytes :: Int
sealedKeyBytes = 48

-- | The longest encrypted title, in base64url characters: a title of a few
-- hundred characters, which is what a title is.
maxTitleCiphertext :: Int
maxTitleCiphertext = 8 * 1024

-- | The longest encrypted text, in base64url characters: 8 MiB of them,
-- some 6 MiB of Markdown.
maxBodyCiphertext :: Int
maxBodyCiphertext = 8 * 1024 * 1024
