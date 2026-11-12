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
  , NewEncryptedSubspace (..)
  , NewGrant (..)
  , NewGrants (..)

    -- * A new key for a space
  , RotationInfo (..)
  , RotationPage (..)
  , Rotation (..)
  , RotatedPage (..)
  , maxRotatedKeys
  , maxRotatedGrants

    -- * Comments and attachments
  , SealedThreads (..)
  , SealedThread (..)
  , SealedCommentInfo (..)
  , NewSealedThread (..)
  , NewSealedComment (..)
  , SealedCommentEdit (..)
  , SealedAttachment (..)

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
import Wiki.Core.Encrypted (Encapsulated, KeyGrant, PageKey, SealedAnchor, SealedComment, SealedContent, SealedHeading, SealedMeta)
import Wiki.Core.Id (AttachmentId, CommentId, CommentThreadId, PageId, SpaceId, UserId)
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
  , rotationDue :: Bool
  -- ^ Whether the key must be renewed before anything more is written in
  -- the space: someone who holds it can no longer read the space (a reader
  -- removed, disabled or deleted, or a public key retired), and nothing
  -- is sealed under it until an administrator of the space who holds it
  -- renews it ('Rotation').
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
-- new key, that key sealed to the caller's own public key, and its home
-- page, written and encrypted by the caller's browser in place of the
-- plain one it was made with.
data EncryptSpace = EncryptSpace
  { keyId :: KeyId
  , grant :: NewGrant
  , homePage :: NewSealedPage
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewEncryptedSubspace': a subspace of an encrypted space, made
-- encrypted: its id, chosen by the browser, which every key and text of it
-- is bound to; its name, which is plain, as every space's; its key, sealed
-- to the caller; and its home page, written and encrypted by the browser.
data NewEncryptedSubspace = NewEncryptedSubspace
  { id :: SpaceId
  , name :: Text
  , keyId :: KeyId
  , grant :: NewGrant
  , homePage :: NewSealedPage
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
-- A new key for a space

-- | 'RotationInfo': what a browser needs to give a space a new key: the
-- current key's id, the readers to seal the new one to (each with a
-- current public key), and each page's keys with its latest version's
-- title, which the browser decrypts with a page key wrapped again before
-- it sends it, to check the new wrap.
data RotationInfo = RotationInfo
  { keyId :: KeyId
  , readers :: [PendingMember]
  , pages :: [RotationPage]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RotationPage': a page's keys, its current one first, and its latest
-- version's title.
data RotationPage = RotationPage
  { page :: PageId
  , keys :: [PageKey]
  , latest :: SealedHeading
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Rotation': a space's new key, from the current one ('from'): sealed
-- to every reader, and every page's keys wrapped again with it, with a
-- new key for each page.
data Rotation = Rotation
  { from :: KeyId
  , keyId :: KeyId
  , grants :: [NewGrant]
  , pages :: [RotatedPage]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RotatedPage': a page's new key, which its next version is encrypted
-- with, and its keys so far, each wrapped again by the space's new key.
data RotatedPage = RotatedPage
  { page :: PageId
  , current :: PageKey
  , rewrapped :: [PageKey]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The most page keys one rotation carries, its new keys and those
-- wrapped again together: some 3 MB of JSON. The server reads a request's
-- JSON whole, with no limit of its own, so a rotation sets this one; a
-- space with more keys than this is refused, with a message saying so.
maxRotatedKeys :: Int
maxRotatedKeys = 20000

-- | The most readers one rotation seals the new key to: some 1 MB.
maxRotatedGrants :: Int
maxRotatedGrants = 5000

--------------------------------------------------------------------------------
-- Comments and attachments

-- | 'SealedThreads': the comment threads of a page of an encrypted space,
-- with every key of the page's, each wrapped by the space's current key:
-- each anchor and comment names the key it was encrypted with, which may
-- be one older than the page's current key, and the keys are read with
-- the threads so that the browser opens them whatever it read before.
data SealedThreads = SealedThreads
  { pageKeys :: [PageKey]
  , threads :: [SealedThread]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedThread': a comment thread of a page of an encrypted space: whether
-- it is about a quote of the page ('anchored') and that quote, encrypted,
-- and its comments, encrypted, oldest first.
data SealedThread = SealedThread
  { id :: CommentThreadId
  , page :: PageId
  , anchored :: Bool
  , anchor :: Maybe SealedAnchor
  , resolved :: Bool
  , createdAt :: UTCTime
  , comments :: [SealedCommentInfo]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedCommentInfo': a comment of a thread, its text encrypted, with who
-- wrote it and when.
data SealedCommentInfo = SealedCommentInfo
  { id :: CommentId
  , thread :: CommentThreadId
  , author :: Author
  , createdAt :: UTCTime
  , editedAt :: Maybe UTCTime
  , content :: SealedComment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewSealedThread': a new thread, with its id, its anchor (none for a
-- thread about the whole page) and its first comment.
data NewSealedThread = NewSealedThread
  { id :: CommentThreadId
  , anchor :: Maybe SealedAnchor
  , comment :: NewSealedComment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewSealedComment': a new comment, with its id.
data NewSealedComment = NewSealedComment
  { id :: CommentId
  , content :: SealedComment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedCommentEdit': a comment written again.
newtype SealedCommentEdit = SealedCommentEdit
  { content :: SealedComment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SealedAttachment': an attachment of a page of an encrypted space: its
-- id, the size of its encrypted bytes, and its name and media type,
-- encrypted, with the nonce of its bytes.
data SealedAttachment = SealedAttachment
  { id :: AttachmentId
  , size :: Int
  , meta :: SealedMeta
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
  , pageKeys :: [PageKey]
  -- ^ Every key the page has had, its current one ('pageKey') first: its
  -- latest version is encrypted with an older one when nothing was saved
  -- since its space's key was renewed.
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
  , pageKeys :: [PageKey]
  -- ^ Every key the page has had, its current one ('pageKey') first: its
  -- versions written before a rotation of its space's key are encrypted
  -- with older ones.
  , attachments :: [SealedAttachment]
  -- ^ Its attachments, in their order.
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
