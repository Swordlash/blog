{-# LANGUAGE DeriveAnyClass #-}

-- | The API of encrypted spaces (WP5.74 of docs/PLAN.md,
-- "Wiki.Core.Encrypted"): the requests and responses of the routes under
-- @encrypted\/@ ('Wiki.Api.EncryptedApi').
--
-- Every title and text in these types is a ciphertext the browser made
-- ('Wiki.Core.Vault.Sealed'), never 'Text': there is no field here where a
-- page's plain title or text could be sent. The plain routes of pages
-- ('Wiki.Api.PagesApi', 'Wiki.Api.SpacesApi') take and give plain text,
-- and the server refuses them for a page of an encrypted space with
-- 'Wiki.Api.Error.Conflict'. So a page of an encrypted space can only be
-- written through these routes, as ciphertext.
module Wiki.Api.Encrypted
  ( -- * A space's keys
    SpaceEncryption (..)
  , PendingMember (..)
  , EncryptSpace (..)
  , NewGrant (..)
  , NewGrants (..)

    -- * Pages
  , SealedSummary (..)
  , SealedPage (..)
  , NewSealedPage (..)
  , SealedEdit (..)
  , SealedVersionInfo (..)
  , SealedVersion (..)
  , sealedVersion
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Api.Version (PageVersion (..))
import Wiki.Core.Encrypted (Encapsulated, KeyGrant, PageKey, SealedContent, SealedHeading)
import Wiki.Core.Id (PageId, SpaceId, UserId)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Vault (Ciphertext, KeyId, PublicKey)
import Wiki.Core.Version (Author)

--------------------------------------------------------------------------------
-- A space's keys

-- | 'SpaceEncryption': an encrypted space's key as one of its readers
-- sees it: the id of its current key, the reader's own grant of that key
-- (none when nobody has shared it with them yet, or when it was sealed to a
-- public key a password reset retired), and, for a reader who holds the
-- key, who is waiting for it.
data SpaceEncryption = SpaceEncryption
  { keyId :: KeyId
  , grant :: Maybe KeyGrant
  , pending :: [PendingMember]
  -- ^ The readers of the space who have a public key but no grant of the
  -- current key: a browser that holds the key seals it to each. Empty for a
  -- reader who holds no grant.
  , waiting :: [UserId]
  -- ^ The readers of the space without a public key yet (they have not
  -- signed in since the wiki gave its users keys), who cannot be given
  -- the key until they do. Empty for a reader who holds no grant.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PendingMember': a reader of an encrypted space whose browser is
-- waiting for the space's key, with the public key to seal it to.
data PendingMember = PendingMember
  { user :: UserId
  , keyId :: KeyId
  , publicKey :: PublicKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'EncryptSpace': turn a space into an encrypted one, with the id of its
-- new key and that key sealed to the caller's own public key.
data EncryptSpace = EncryptSpace
  { keyId :: KeyId
  , grant :: NewGrant
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewGrant': a space's key sealed by a browser to one user's public key.
data NewGrant = NewGrant
  { recipient :: UserId
  , recipientKeyId :: KeyId
  , enc :: Encapsulated
  , sealed :: Ciphertext
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewGrants': grants of a space's key (the one whose id is 'keyId') to
-- the readers waiting for it.
data NewGrants = NewGrants
  { keyId :: KeyId
  , grants :: [NewGrant]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- Pages

-- | 'SealedSummary': a page of an encrypted space in a list of its pages:
-- its place in the tree, its key, and its encrypted title.
data SealedSummary = SealedSummary
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , slug :: Slug
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  , position :: Int
  , pageKey :: PageKey
  , heading :: SealedHeading
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedPage': a page of an encrypted space with its latest version,
-- encrypted, and who wrote its first and latest versions.
data SealedPage = SealedPage
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , slug :: Slug
  , createdAt :: UTCTime
  , updatedAt :: UTCTime
  , position :: Int
  , pageKey :: PageKey
  , content :: SealedContent
  , createdBy :: Maybe Author
  , updatedBy :: Maybe Author
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewSealedPage': a new page of an encrypted space. Its id is chosen by
-- the browser (a UUID), since the additional data its key and content are
-- encrypted with names it. Its slug is chosen by the server, at random,
-- since a slug made from the title would show the title.
data NewSealedPage = NewSealedPage
  { id :: PageId
  , parent :: Maybe PageId
  , pageKey :: PageKey
  , content :: SealedContent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedEdit': a new version of a page of an encrypted space, encrypted
-- with the page's key.
newtype SealedEdit = SealedEdit
  { content :: SealedContent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedVersionInfo': a version in the list of a page's versions: its
-- time, its number, who saved it, and its encrypted title.
data SealedVersionInfo = SealedVersionInfo
  { page :: PageId
  , updatedAt :: UTCTime
  , heading :: SealedHeading
  , author :: Maybe Author
  , number :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedVersion': one version of a page, encrypted.
data SealedVersion = SealedVersion
  { page :: PageId
  , updatedAt :: UTCTime
  , content :: SealedContent
  , author :: Maybe Author
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The version of a page of an encrypted space, as its @ETag@ carries it.
sealedVersion :: SealedPage -> PageVersion
sealedVersion p = PageVersion p.updatedAt
