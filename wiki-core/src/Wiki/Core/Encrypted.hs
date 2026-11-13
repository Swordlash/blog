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
-- = The chain of versions
--
-- Each version written since WP5.74b3 also names where it stands in its
-- page's history ('Chain'): its number, one more than the version before
-- it, and the tag of that version. Both are in the additional data of its
-- ciphertexts (format 2, 'contentData'), so the server can neither change
-- them nor move a version elsewhere in the history without the browser
-- noticing. A browser remembers the latest version of each page it has
-- read ('Seen'), and finds out when the server later sends an older one,
-- one forked from it, or a history with a version missing ('judgeHead',
-- 'linkedFrom', 'gapIn'). What it remembers only moves forward
-- ('keepIn'). A version of format 1, written before, has no
-- chain: its order is the server's word.
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
  , encryptedPageTitle
  , VersionTag (..)

    -- * The chain of versions
  , Chain (..)
  , firstChain
  , isFirstChain
  , chainAfter
  , Seen (..)
  , ChainProblem (..)
  , chainProblemText
  , Judged (..)
  , judgeHead
  , linkedFrom
  , gapIn
  , historyStart
  , Kept (..)
  , keepIn

    -- * Keys
  , KeyGrant (..)
  , PageKey (..)

    -- * Content
  , SealedContent (..)
  , SealedHeading (..)
  , headingOf
  , Field (..)

    -- * Comments and attachments
  , SealedComment (..)
  , SealedAnchor (..)
  , SealedMeta (..)

    -- * What each key and ciphertext is bound to
  , grantInfo
  , pageKeyData
  , fieldData
  , contentData
  , commentData
  , anchorData
  , attachmentMetaData
  , attachmentBytesData

    -- * Lengths
  , nonceBytes
  , keyIdBytes
  , encapsulatedBytes
  , sealedKeyBytes
  , maxTitleCiphertext
  , maxBodyCiphertext
  , maxCommentCiphertext
  , maxAnchorCiphertext
  , maxMetaCiphertext
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Text qualified as T
import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Core.Id (AttachmentId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), Sealed (..), WrappedKey (..))

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

-- | What a page of an encrypted space is named by where its title is not
-- decrypted: in a notification, which the server writes without being
-- able to read the title, and, in the browser, outside a space that asks
-- for a passkey or the password each time ('Wiki.Core.Space.ConfirmEach')
-- until the reader has confirmed.
encryptedPageTitle :: Text
encryptedPageTitle = "an encrypted page"

--------------------------------------------------------------------------------
-- The chain of versions

-- | 'Chain': where a version stands in its page's history. 'number' is one
-- more than the number of the version before it, and 'previous' is that
-- version's tag; the first version of a page is number 1 and names none.
-- The first version written after versions of format 1 is number 1 too,
-- and names the tag of the version of format 1 before it.
data Chain = Chain
  { number :: Int
  , previous :: Maybe VersionTag
  , origin :: Maybe VersionTag
  -- ^ Which chain this is: a random id the browser that starts the chain
  -- picks (a new page, or each page of a space encrypted page by page,
  -- again after its encryption was turned off), carried by every version
  -- after it and bound by each one's encryption ('contentData'), so that
  -- the server, which holds no page key, cannot make a chain of its own.
  -- A page encrypted again starts a new chain under the same page id,
  -- which a reader who read the old one tells from a fork by its origin
  -- ('judgeHead'). 'Nothing' for a chain started before origins.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Chain where
  toJSON c = object (["number" .= c.number, "previous" .= c.previous] <> ["origin" .= o | Just o <- [c.origin]])

instance FromJSON Chain where
  parseJSON = withObject "Chain" $ \o -> Chain <$> o .: "number" <*> o .:? "previous" <*> o .:? "origin"

-- | The chain of a new page's first version, with the origin the browser
-- picked for it (a random id, as a tag is).
firstChain :: VersionTag -> Chain
firstChain origin = Chain {number = 1, previous = Nothing, origin = Just origin}

-- | Whether a chain is a chain's first version: number 1, after nothing,
-- with an origin.
isFirstChain :: Chain -> Bool
isFirstChain c = c.number == 1 && isNothing c.previous && isJust c.origin

-- | The chain of the version saved on top of a version with this tag and
-- this chain ('Nothing' for one of format 1).
chainAfter :: VersionTag -> Maybe Chain -> Chain
chainAfter tag = \case
  Just c -> Chain {number = c.number + 1, previous = Just tag, origin = c.origin}
  Nothing -> Chain {number = 1, previous = Just tag, origin = Nothing}

-- | 'Seen': the latest version of a page that a browser has read and
-- checked: its number in the chain and its tag. The browser keeps one for
-- each page it has read, to compare what the server sends next with.
data Seen = Seen
  { number :: Int
  , tag :: VersionTag
  , origin :: Maybe VersionTag
  -- ^ The chain it is of ('Chain''s @origin@). A browser keeps one 'Seen'
  -- for each chain of a page it read, in the order it first read them:
  -- the latest is the page's chain now, and an earlier one shown again is
  -- a page shown as it was before it was encrypted again.
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Seen where
  toJSON s = object ["number" .= s.number, "tag" .= s.tag, "origin" .= s.origin]

-- | A record without an origin (written before origins) is of the chain
-- without one.
instance FromJSON Seen where
  parseJSON = withObject "Seen" $ \o -> Seen <$> o .: "number" <*> o .: "tag" <*> o .:? "origin"

-- | 'ChainProblem': what a browser found wrong with the versions the
-- server sent, against the chain and what the browser saw before.
data ChainProblem
  = -- | The latest version sent is older than the latest this browser saw:
    -- the numbers of the two, 0 for a version of format 1.
    Older {seen :: Int, served :: Int}
  | -- | The version sent as number n is not the one this browser saw as
    -- number n.
    Forked {at :: Int}
  | -- | In a run of versions, the one after the version numbered so is not
    -- the next of the chain: a version is missing, or out of order. 0 for a
    -- version of format 1.
    Gap {after :: Int}
  | -- | The latest version sent (numbered so) is not joined, version by
    -- version, to the one this browser read before (numbered so): the
    -- history the server sent does not hold it, or stops before the
    -- version read.
    Unlinked {seen :: Int, served :: Int}
  | -- | The version sent is of a chain this browser read the page under
    -- before the one it read last: the page as it was before it was
    -- encrypted again.
    Superseded
  | -- | A page's whole history, as the server sent it, does not begin
    -- where its chain begins: its oldest version is numbered so, and is
    -- not a chain's first ('historyStart'). The server left the oldest
    -- versions out.
    Truncated {oldest :: Int}
  deriving stock (Eq, Show)

-- | What a reader is told of a problem, in a banner over the page.
chainProblemText :: ChainProblem -> Text
chainProblemText = \case
  Older seen served ->
    "The server sent an older version of this page ("
      <> (if served == 0 then "one from before versions were numbered" else "version " <> show served)
      <> ") than this browser has read before (version "
      <> show seen
      <> "). What is shown may not be the latest, so the page cannot be edited here until it is reloaded."
  Forked at ->
    "The server sent a version " <> show at <> " of this page that is not the version " <> show at <> " this browser has read before: its history may have been changed. The page cannot be edited here until it is reloaded."
  Gap after ->
    "This page's history has a version missing, or out of order, after "
      <> (if after == 0 then "the versions from before versions were numbered" else "version " <> show after)
      <> ": the server may have removed one. The page cannot be edited here until it is reloaded."
  Unlinked seen served ->
    "The server sent a version "
      <> show served
      <> " of this page that its history does not join to the version "
      <> show seen
      <> " this browser has read before: its history may have been changed. The page cannot be edited here until it is reloaded."
  Superseded ->
    "The server sent this page as it was before it was encrypted again, which this browser has read since: what is shown is not the latest, so the page cannot be edited here until it is reloaded."
  Truncated oldest ->
    "This page's history as the server sent it begins at version "
      <> show oldest
      <> ", not at the page's first: the server may have left the oldest versions out. The page cannot be edited here until it is reloaded."

-- | 'Judged': how the latest version the server sent stands against the
-- latest this browser saw, when nothing is wrong with it: the same one, or
-- so many versions later, whose links down to the one seen are still to
-- be checked ('linkedFrom').
data Judged = Agrees | Advanced Int
  deriving stock (Eq, Show)

-- | The latest version of a page, as the server sent it (its tag and its
-- chain, both checked by the decryption of its title), against the latest
-- version this browser saw of it.
--
-- What the browser saw is a 'Seen' for each chain of the page it read, in
-- the order it first read them ('keepIn'). The version is judged against
-- the latest of its own chain: a chain this browser has not read is a
-- page encrypted again since (its origin made by a browser that held the
-- page's key), and agrees; the chain read last is judged as always; an
-- earlier chain, or a version of no chain after one with an origin, is
-- the page as it was before ('Superseded').
judgeHead :: [Seen] -> VersionTag -> Maybe Chain -> Either ChainProblem Judged
judgeHead seens tag chain = case lastMay seens of
  Nothing -> Right Agrees
  Just latest
    | latest.origin == origin -> judgeIn latest
    | isNothing origin || any (\s -> s.origin == origin) seens -> Left Superseded
    | otherwise -> Right Agrees
  where
    origin = chain >>= (\c -> c.origin)
    judgeIn s = case chain of
      Nothing -> Left (Older s.number 0)
      Just c
        | c.number < s.number -> Left (Older s.number c.number)
        | c.number == s.number -> if tag == s.tag then Right Agrees else Left (Forked c.number)
        | otherwise -> Right (Advanced (c.number - s.number))

-- | Whether a version (its tag and chain) follows directly on another, in
-- the chain: it names the other's tag, and its number is one more; a
-- version of format 1 follows on another of format 1, whose order the
-- chain cannot check.
follows :: (VersionTag, Maybe Chain) -> (VersionTag, Maybe Chain) -> Bool
follows (_, newer) (olderTag, older) = case (newer, older) of
  (Just n, Just o) -> n.previous == Just olderTag && n.number == o.number + 1 && n.origin == o.origin
  (Just n, Nothing) -> n.previous == Just olderTag && n.number == 1
  (Nothing, Nothing) -> True
  (Nothing, Just _) -> False

-- | The number of a version in the chain, 0 for one of format 1.
numberOf :: Maybe Chain -> Int
numberOf = maybe 0 (\c -> c.number)

-- | The latest version of a page the server sent, which is later than the
-- one this browser read before ('judgeHead''s 'Advanced'), checked against
-- the page's history: 'Right' only when the history holds that very
-- version (its tag and chain as its own decryption gave them) and joins
-- it, version by version, down to the version read. What the history
-- holds above it, saved since the page was read, is not this check's
-- business: the next read checks it. A history that does not hold the
-- version, has a break below it, stops above the version read, or
-- reaches its number with another version, is the problem it is. The
-- history is the latest first, its titles decrypted, so that its tags and
-- chains are the browser's; it may be several pages of the history, in
-- order.
linkedFrom :: Seen -> (VersionTag, Maybe Chain) -> [(VersionTag, Maybe Chain)] -> Either ChainProblem ()
linkedFrom seen latest history = case dropWhile (/= latest) history of
  [] -> Left unlinked
  run -> go run
  where
    unlinked = Unlinked seen.number (numberOf (snd latest))
    go = \case
      [] -> Left unlinked
      v@(tag, chain) : rest
        | numberOf chain == seen.number -> if tag == seen.tag then Right () else Left (Forked seen.number)
        | numberOf chain < seen.number -> Left unlinked
        | otherwise -> case rest of
            older : _ | not (v `follows` older) -> Left (Gap (numberOf (snd older)))
            _ -> go rest

-- | 'Kept': what remembering a version seen did, against what was
-- remembered at that moment ('keepIn').
data Kept
  = -- | It is remembered now.
    KeptNow
  | -- | A later version was remembered already: nothing changed, since what
    -- is remembered only moves forward.
    KeptLater
  | -- | Another version under the same number was remembered: a fork, which
    -- is not remembered over.
    KeptFork
  deriving stock (Eq, Show)

-- | Remember a version seen over what is remembered, only forward: the
-- outcome, and what is remembered after. A chain not remembered yet is
-- added as the latest (a page encrypted again); one remembered before the
-- latest stays as it is, as a version of the chain without origin does
-- after one with an origin ('KeptLater'); in the latest chain, only a
-- later version moves it on.
keepIn :: [Seen] -> Seen -> (Kept, [Seen])
keepIn remembered new = case break (\s -> s.origin == new.origin) remembered of
  (_, []) | isNothing new.origin && not (null remembered) -> (KeptLater, remembered)
  (_, []) -> (KeptNow, remembered <> [new])
  (before, r : after)
    | not (null after) -> (KeptLater, remembered)
    | r.number > new.number -> (KeptLater, remembered)
    | r.number == new.number -> if r.tag == new.tag then (KeptNow, remembered) else (KeptFork, remembered)
    | otherwise -> (KeptNow, before <> [new])

-- | Whether a page's whole history, the latest first, begins where its
-- chain begins. 'gapIn' checks each version against the next; this checks
-- the end, which no neighbour vouches for. The oldest version must be a
-- chain's first: numbered 1 and after nothing ('firstChain', and the
-- first version of a page written before chains had origins). A version
-- numbered 1 that names a version before it (the first of a chain begun
-- on a page written before versions were chained, 'chainAfter') needs that
-- version below it, which 'follows' checks: as the oldest it is a
-- problem. A version of format 1 (before chains) as the oldest is taken
-- as it is: nothing tells whether versions of format 1 before it are
-- missing. With the links checked, a history that begins at 1 holds as
-- many chained versions as its latest one's number says.
historyStart :: [(VersionTag, Maybe Chain)] -> Maybe ChainProblem
historyStart versions = case lastMay versions of
  Just (_, Just c) | c.number /= 1 || isJust c.previous -> Just (Truncated c.number)
  _ -> Nothing

-- | The first break in a run of a page's versions, the latest first: a
-- version that does not follow on the next one.
gapIn :: [(VersionTag, Maybe Chain)] -> Maybe ChainProblem
gapIn versions = listToMaybe [Gap (numberOf (snd older)) | (newer, older) <- zip versions (drop 1 versions), not (newer `follows` older)]

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
-- the page key it is encrypted with, where it stands in the page's history
-- ('Chain'; 'Nothing' for a version of format 1, written before versions
-- were chained), and its title and text.
data SealedContent = SealedContent
  { tag :: VersionTag
  , keyId :: KeyId
  , chain :: Maybe Chain
  , title :: Sealed
  , body :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedContent where
  showsPrec _ _ rest = "SealedContent <ciphertext>" <> rest

instance ToJSON SealedContent where
  toJSON c = object (["tag" .= c.tag, "keyId" .= c.keyId, "title" .= c.title, "body" .= c.body] <> ["chain" .= x | Just x <- [c.chain]])

instance FromJSON SealedContent where
  parseJSON = withObject "SealedContent" $ \o -> SealedContent <$> o .: "tag" <*> o .: "keyId" <*> o .:? "chain" <*> o .: "title" <*> o .: "body"

-- | 'SealedHeading': a version's title alone, encrypted, as a list of pages
-- or of versions carries it, with the version's place in the history,
-- which the title's additional data names.
data SealedHeading = SealedHeading
  { tag :: VersionTag
  , keyId :: KeyId
  , chain :: Maybe Chain
  , title :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedHeading where
  showsPrec _ _ rest = "SealedHeading <ciphertext>" <> rest

instance ToJSON SealedHeading where
  toJSON c = object (["tag" .= c.tag, "keyId" .= c.keyId, "title" .= c.title] <> ["chain" .= x | Just x <- [c.chain]])

instance FromJSON SealedHeading where
  parseJSON = withObject "SealedHeading" $ \o -> SealedHeading <$> o .: "tag" <*> o .: "keyId" <*> o .:? "chain" <*> o .: "title"

-- | A version's heading: its title without its text.
headingOf :: SealedContent -> SealedHeading
headingOf c = SealedHeading {tag = c.tag, keyId = c.keyId, chain = c.chain, title = c.title}

-- | 'Field': which part of a version a ciphertext is.
data Field = TitleField | BodyField
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- Comments and attachments

-- | 'SealedComment': a comment's Markdown, encrypted with the key of its
-- page's that 'keyId' names (the page's current key when it was written:
-- one from before a renewal of the space's key stays that one), under a
-- tag the browser picks at each writing of it ('commentData').
data SealedComment = SealedComment
  { keyId :: KeyId
  , tag :: VersionTag
  , body :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedComment where
  showsPrec _ _ rest = "SealedComment <ciphertext>" <> rest

instance ToJSON SealedComment where
  toJSON c = object ["keyId" .= c.keyId, "tag" .= c.tag, "body" .= c.body]

instance FromJSON SealedComment where
  parseJSON = withObject "SealedComment" $ \o -> SealedComment <$> o .: "keyId" <*> o .: "tag" <*> o .: "body"

-- | 'SealedAnchor': the quote a thread is about, with its context
-- ("Wiki.Core.Anchor"'s 'Wiki.Core.Anchor.Anchor' as JSON), encrypted with
-- the key of its page's that 'keyId' names ('anchorData').
data SealedAnchor = SealedAnchor
  { keyId :: KeyId
  , anchor :: Sealed
  }
  deriving stock (Eq, Generic)

instance Show SealedAnchor where
  showsPrec _ _ rest = "SealedAnchor <ciphertext>" <> rest

instance ToJSON SealedAnchor where
  toJSON a = object ["keyId" .= a.keyId, "anchor" .= a.anchor]

instance FromJSON SealedAnchor where
  parseJSON = withObject "SealedAnchor" $ \o -> SealedAnchor <$> o .: "keyId" <*> o .: "anchor"

-- | 'SealedMeta': an attachment's name and media type (JSON @{name,
-- mediaType}@), encrypted with the key of its page's that 'keyId' names
-- ('attachmentMetaData'), and the nonce its bytes are encrypted with under
-- the same key ('attachmentBytesData'). The bytes themselves are the
-- attachment's blob.
data SealedMeta = SealedMeta
  { keyId :: KeyId
  , meta :: Sealed
  , bytesNonce :: Nonce
  }
  deriving stock (Eq, Generic)

instance Show SealedMeta where
  showsPrec _ _ rest = "SealedMeta <ciphertext>" <> rest

instance ToJSON SealedMeta where
  toJSON m = object ["keyId" .= m.keyId, "meta" .= m.meta, "bytesNonce" .= m.bytesNonce]

instance FromJSON SealedMeta where
  parseJSON = withObject "SealedMeta" $ \o -> SealedMeta <$> o .: "keyId" <*> o .: "meta" <*> o .: "bytesNonce"

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

-- | The additional data of one field of one version of a page of format
-- 1, with no chain ('contentData').
fieldData :: SpaceId -> PageId -> KeyId -> VersionTag -> Field -> Text
fieldData sid pid k tag field = "wiki-page/1 " <> sid.text <> " " <> pid.text <> " " <> k.text <> " " <> tag.text <> " " <> fieldName field

-- | The additional data of one field of one version, as its format has it:
-- 'fieldData' for a version of format 1, with no chain; for one of format
-- 2, the same with its chain's number and the previous version's tag (@-@
-- for none), under its own prefix, so that neither format's ciphertext
-- opens as the other's.
contentData :: SpaceId -> PageId -> KeyId -> VersionTag -> Maybe Chain -> Field -> Text
contentData sid pid k tag chain field = case chain of
  Nothing -> fieldData sid pid k tag field
  Just c@Chain {origin = Just o} ->
    T.unwords ["wiki-page/3", sid.text, pid.text, k.text, tag.text, show c.number, maybe "-" (\t -> t.text) c.previous, o.text, fieldName field]
  Just c ->
    "wiki-page/2 "
      <> sid.text
      <> " "
      <> pid.text
      <> " "
      <> k.text
      <> " "
      <> tag.text
      <> " "
      <> show c.number
      <> " "
      <> maybe "-" (\t -> t.text) c.previous
      <> " "
      <> fieldName field

-- | The additional data of a comment's text: the space, the page, the page
-- key, the thread, the comment and the tag of this writing of it.
commentData :: SpaceId -> PageId -> KeyId -> CommentThreadId -> CommentId -> VersionTag -> Text
commentData sid pid k tid cid tag = T.unwords ["wiki-comment/1", sid.text, pid.text, k.text, tid.text, cid.text, tag.text]

-- | The additional data of a thread's anchor: the space, the page, the
-- page key and the thread.
anchorData :: SpaceId -> PageId -> KeyId -> CommentThreadId -> Text
anchorData sid pid k tid = T.unwords ["wiki-anchor/1", sid.text, pid.text, k.text, tid.text]

-- | The additional data of an attachment's name and media type.
attachmentMetaData :: SpaceId -> PageId -> KeyId -> AttachmentId -> Text
attachmentMetaData sid pid k aid = T.unwords ["wiki-attachment-meta/1", sid.text, pid.text, k.text, aid.text]

-- | The additional data of an attachment's bytes.
attachmentBytesData :: SpaceId -> PageId -> KeyId -> AttachmentId -> Text
attachmentBytesData sid pid k aid = T.unwords ["wiki-attachment/1", sid.text, pid.text, k.text, aid.text]

-- | A field's name in the additional data.
fieldName :: Field -> Text
fieldName = \case
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

-- | The longest encrypted comment, in base64url characters: a comment of
-- 20,000 characters ('Wiki.Core.Comment.maxCommentLength') of up to four
-- bytes each, and the tag.
maxCommentCiphertext :: Int
maxCommentCiphertext = 128 * 1024

-- | The longest encrypted anchor: a quote and its context.
maxAnchorCiphertext :: Int
maxAnchorCiphertext = 128 * 1024

-- | The longest encrypted name and media type of an attachment.
maxMetaCiphertext :: Int
maxMetaCiphertext = 8 * 1024
