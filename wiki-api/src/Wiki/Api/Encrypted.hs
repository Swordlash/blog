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

    -- * Encrypting a space that has pages, and turning encryption off
  , ConversionInfo (..)
  , ConversionPage (..)
  , StartEncrypting (..)
  , SpaceKeyStart (..)
  , StagedSealed (..)
  , StagedVersion (..)
  , StagedAnchor (..)
  , StagedComment (..)
  , StagedMeta (..)
  , StagedPlain (..)
  , PlainVersion (..)
  , PlainAnchor (..)
  , PlainComment (..)
  , PlainMeta (..)
  , StagedPage (..)
  , ConversionCommit (..)
  , SpaceEntry (..)
  , HeadingsQuery (..)
  , PageHeading (..)
  , maxHeadings
  , ConversionProgress (..)
  , notConvertedYet
  , StagedBlob (..)
  , LeaseToken (..)
  , LeaseRequest (..)
  , ConversionLease (..)
  , Converter (..)
  , leaseRefusal

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
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))
import Wiki.Api.Version (PageVersion (..))
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Encrypted (Encapsulated, KeyGrant, PageKey, SealedAnchor, SealedComment, SealedContent, SealedHeading, SealedMeta)
import Wiki.Core.Id (AttachmentId, BlobId, CommentId, CommentThreadId, PageId, SpaceId, UserId)
import Wiki.Core.PageKind (PageKind)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Conversion, Entry)
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
-- Encrypting a space that has pages, and turning encryption off

-- | 'ConversionInfo': a space's conversion ("Wiki.Core.Space"'s
-- 'Conversion') as one who may view the space sees it: the one under way,
-- if any, from the space it started at ('root'), with the pages it has not
-- converted yet; and, when none runs, why one could not start now, each
-- way ('cannotEncrypt', 'cannotDecrypt'; empty when it could, or when the
-- space is not of that kind).
data ConversionInfo = ConversionInfo
  { running :: Maybe Conversion
  , root :: Maybe SpaceId
  , spaces :: [SpaceId]
  -- ^ The spaces the conversion covers, or would cover: the space and the
  -- spaces below it, the space first.
  , left :: [ConversionPage]
  -- ^ The pages not converted yet, the oldest first.
  , cannotEncrypt :: [Text]
  , cannotDecrypt :: [Text]
  , nothingWritten :: Bool
  -- ^ Whether the space has nothing written in it, its home page as it
  -- was made: such a space is encrypted at once
  -- ('Wiki.Api.EncryptedApi''s @encrypt@), any other by a conversion.
  , clearing :: Bool
  -- ^ Whether the plain text a conversion deleted is still in SQLite's
  -- files: the truncating checkpoint after its last commit was held back
  -- by a reader of the database, and runs again after the next write
  -- (and at the server's start). Always false on PostgreSQL, whose old
  -- rows stay in its files until it is vacuumed, whatever this says.
  , converter :: Maybe Converter
  -- ^ The browser converting the space now, while its lease runs
  -- ('ConversionLease'): none when no browser holds one, or when it has
  -- run out.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ConversionPage': a page a conversion has still to convert, with its
-- space.
data ConversionPage = ConversionPage
  { page :: PageId
  , space :: SpaceId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StartEncrypting': the keys of the spaces a conversion encrypts, the
-- space and each plain space below it, each sealed to the caller, made in
-- the caller's browser.
newtype StartEncrypting = StartEncrypting
  { keys :: [SpaceKeyStart]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceKeyStart': one space's new key, by its id, sealed to the caller.
data SpaceKeyStart = SpaceKeyStart
  { space :: SpaceId
  , keyId :: KeyId
  , grant :: NewGrant
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedSealed': ciphertexts of a page staged while its space is
-- encrypted, made in the browser from the plain page: its key the first
-- time ('pageKey', which starts the page anew, forgetting anything staged
-- of it before), and any of its versions (each as a chain from 1, in the
-- chained format), threads' anchors, comments and attachments' names and
-- media types. A request that sends the page's key carries its latest
-- version too, so that no page has a key without one.
data StagedSealed = StagedSealed
  { pageKey :: Maybe PageKey
  , versions :: [StagedVersion]
  , threads :: [StagedAnchor]
  , comments :: [StagedComment]
  , attachments :: [StagedMeta]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedVersion': a version of a page, by its time, encrypted.
data StagedVersion = StagedVersion
  { updatedAt :: UTCTime
  , content :: SealedContent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedAnchor': a thread's quote, encrypted; none for a thread about
-- the whole page.
data StagedAnchor = StagedAnchor
  { id :: CommentThreadId
  , anchor :: Maybe SealedAnchor
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedComment': a comment's text, encrypted.
data StagedComment = StagedComment
  { id :: CommentId
  , content :: SealedComment
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedMeta': an attachment's name and media type, encrypted, with the
-- nonce of its bytes, which are staged by a request of their own.
data StagedMeta = StagedMeta
  { id :: AttachmentId
  , meta :: SealedMeta
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedPlain': a page staged while its space's encryption is turned
-- off, decrypted in the browser: any of its versions' titles and texts,
-- threads' quotes, comments and attachments' names and media types.
data StagedPlain = StagedPlain
  { versions :: [PlainVersion]
  , threads :: [PlainAnchor]
  , comments :: [PlainComment]
  , attachments :: [PlainMeta]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PlainVersion = PlainVersion
  { updatedAt :: UTCTime
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PlainAnchor = PlainAnchor
  { id :: CommentThreadId
  , anchor :: Maybe Anchor
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PlainComment = PlainComment
  { id :: CommentId
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data PlainMeta = PlainMeta
  { id :: AttachmentId
  , name :: Text
  , mediaType :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedPage': what is staged of a page now, as the browser reads it
-- back before it commits the page: the page's keys and its ciphertexts
-- while its space is encrypted ('sealed'), or its texts decrypted while
-- its encryption is turned off ('plain'), and the blob of each
-- attachment's bytes staged. 'digest' names exactly this; the commit
-- carries it back, and is refused if what is staged has changed since.
data StagedPage = StagedPage
  { digest :: Text
  , pageKeys :: [PageKey]
  , sealed :: StagedSealed
  , plain :: StagedPlain
  , blobs :: [StagedBlob]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'StagedBlob': the bytes staged for an attachment of a page: their
-- blob, which is their SHA-256, and their size. The browser compares both
-- with the bytes it sent, and reads the bytes back
-- ('Wiki.Api.EncryptedApi''s @stagedBytes@) before it commits the page.
data StagedBlob = StagedBlob
  { id :: AttachmentId
  , blob :: BlobId
  , size :: Integer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ConversionCommit': the commit of a page, of what was staged as the
-- browser read it back ('StagedPage''s digest).
newtype ConversionCommit = ConversionCommit
  { digest :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceEntry': what a space's administrator sets of how readers come
-- into it ('Wiki.Core.Space.Entry'): at once, or after a passkey or the
-- password each time.
newtype SpaceEntry = SpaceEntry
  { entry :: Entry
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'HeadingsQuery': the pages whose encrypted titles a browser asks for,
-- by their ids alone, at most 'maxHeadings': those under the bell, or
-- starred.
newtype HeadingsQuery = HeadingsQuery
  { pages :: [PageId]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The most pages one 'HeadingsQuery' asks for.
maxHeadings :: Int
maxHeadings = 100

-- | 'PageHeading': the encrypted title of a page's latest version, with
-- every key the page has had, its current one first, so that the browser
-- opens it with the key it names; and the page's space, whose key opens
-- the page's.
data PageHeading = PageHeading
  { page :: PageId
  , space :: SpaceId
  , pageKeys :: [PageKey]
  , heading :: SealedHeading
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ConversionProgress': after a page's commit, how many pages are left;
-- none once the conversion has ended.
newtype ConversionProgress = ConversionProgress
  { left :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LeaseToken': the token of a lease on a conversion
-- ('ConversionLease'), which each request that stages, reads back or
-- commits a page carries in the @Wiki-Conversion-Lease@ header.
newtype LeaseToken = LeaseToken {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

instance ToHttpApiData LeaseToken where
  toUrlPiece t = t.text

instance FromHttpApiData LeaseToken where
  parseUrlPiece = Right . LeaseToken

-- | 'LeaseRequest': a browser asks for the lease on a conversion, to
-- convert its pages. 'takeOver' asks for it even while another browser of
-- the same user holds it: that browser's requests are refused from then
-- on.
newtype LeaseRequest = LeaseRequest
  { takeOver :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ConversionLease': the right of one browser to convert a space's
-- pages. A conversion has one converter at a time: the server refuses to
-- stage, read back or commit a page with any token but the lease's
-- ('leaseRefusal'). The lease runs until 'expiresAt', and each page
-- staged or committed renews it; once it has run out, another browser may
-- take it, and the old token is refused from then on.
data ConversionLease = ConversionLease
  { token :: LeaseToken
  , expiresAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Converter': who converts a space now, as 'ConversionInfo' says it:
-- whether it is the caller (in another browser, or this one), and until
-- when the lease runs unless it is renewed.
data Converter = Converter
  { yours :: Bool
  , heldUntil :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The start of the reason the server gives to a request of a conversion
-- that does not carry the lease's token: another browser converts the
-- space, or took the lease over since.
leaseRefusal :: Text
leaseRefusal = "Another browser is converting this space"

-- | The start of the reason the server gives when a page is read by the
-- encrypted routes while a conversion has not encrypted it yet, or has
-- decrypted it already: the browser then reads it by the plain ones.
notConvertedYet :: Text
notConvertedYet = "This page is read as plain text while its space is converted"

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
  , kind :: PageKind
  -- ^ A document or a presentation ("Wiki.Core.PageKind"), in the clear,
  -- as the page's place in the tree is. Missing, from an older server, it
  -- is a document.
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
  , kind :: PageKind
  -- ^ A document or a presentation, in the clear.
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
  , kind :: PageKind
  -- ^ A document or a presentation, in the clear. Missing, from an older
  -- client, it is a document.
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
