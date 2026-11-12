-- | 'Wiki.Server.Storage.Sealed' is the statements of encrypted spaces
-- (WP5.74 of docs/PLAN.md, "Wiki.Core.Encrypted"): the grants of a space's
-- key (@key_grants@), the pages' keys (@page_keys@) and their encrypted
-- versions (@sealed_versions@), and an encrypted space's current key id
-- (@spaces.key_id@). "Wiki.Server.Storage" decides who may read and write
-- them; this module only reads and writes rows. Nothing here can read what
-- the rows hold: they are ciphertexts the browsers made.
module Wiki.Server.Storage.Sealed
  ( -- * Spaces
    setSpaceKey
  , spaceKind

    -- * Grants
  , grantsOfKey
  , insertGrant
  , deleteSpaceGrants
  , deleteGrantsOfSpace
  , currentPublicKeys

    -- * Pages
  , insertPageKey
  , loadPageKey
  , loadPageKeys
  , loadSpacePageKeys
  , loadSpaceAllPageKeys
  , replacePageKeys
  , insertSealedVersion
  , loadSealedVersion
  , loadSealedLatest
  , contentOf

    -- * Comments and attachments
  , insertSealedThread
  , loadSealedAnchors
  , insertSealedComment
  , replaceSealedComment
  , loadSealedComments
  , insertSealedAttachment
  , loadSealedMetas
  )
where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Database.Beam (all_, delete, filter_, in_, insert, insertValues, isNothing_, join_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Protolude
import Wiki.Core.Encrypted (Chain (..), Encapsulated (..), KeyGrant (..), PageKey (..), SealedAnchor (..), SealedComment (..), SealedContent (..), SealedMeta (..), VersionTag (..))
import Wiki.Core.Id (AttachmentId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), PublicKey (..), Sealed (..), WrappedKey (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (markSpaceLinks, micro)
import Wiki.Server.Storage.Schema (Attachments (..), Comments (..), KeyGrants (..), PageKeys (..), Pages (..), PublicKeys (..), SealedAttachments (..), SealedComments (..), SealedThreads (..), SealedVersions (..), Spaces (..), Threads (..), WikiDb (..), wikiDb)

--------------------------------------------------------------------------------
-- Spaces

-- | Make a space encrypted, with its current key's id. Nothing else of the
-- space changes; a space's other updates never write this column, so that
-- none of them can make an encrypted space plain again.
setSpaceKey :: (Backend be) => SpaceId -> KeyId -> Db be ()
setSpaceKey sid k = do
  runUpdate (update wikiDb.spaces (\x -> x.key_id <-. val_ (Just k.text)) (\x -> x.id ==. val_ sid.text))
  -- An encrypted space has no root, so paths into it read otherwise, and
  -- its pages are no longer linked ("Wiki.Server.Storage.Rows", "Links").
  markSpaceLinks sid

-- | The kind of resource a space's grants are of.
spaceKind :: Text
spaceKind = "space"

--------------------------------------------------------------------------------
-- Grants

-- | The grants of one key of a resource: of a space's key, by the space's
-- id and the key's.
grantsOfKey :: (Backend be) => Text -> Text -> KeyId -> Db be [KeyGrant]
grantsOfKey kind resource k = do
  rows <- runSelectReturningList (select (filter_ (\g -> g.resource_kind ==. val_ kind &&. g.resource_id ==. val_ resource &&. g.key_id ==. val_ k.text) (all_ wikiDb.key_grants)))
  pure [KeyGrant {keyId = KeyId g.key_id, recipient = UserId g.recipient, recipientKeyId = KeyId g.recipient_key_id, enc = Encapsulated g.enc, sealed = Ciphertext g.sealed} | g <- rows]

-- | Store a grant of a resource's key. One there already for the same key
-- and public key is kept as it is: the caller checks first.
insertGrant :: (Backend be) => Text -> Text -> UTCTime -> KeyGrant -> Db be ()
insertGrant kind resource at g =
  runInsert . insert wikiDb.key_grants $
    insertValues
      [ KeyGrantRow
          { resource_kind = kind
          , resource_id = resource
          , key_id = g.keyId.text
          , recipient = g.recipient.text
          , recipient_key_id = g.recipientKeyId.text
          , enc = g.enc.text
          , sealed = g.sealed.text
          , created_at = micro at
          }
      ]

-- | Delete the grants of these spaces' keys: the spaces are being deleted.
deleteSpaceGrants :: (Backend be) => [SpaceId] -> Db be ()
deleteSpaceGrants sids =
  unless (null sids) $
    runDelete (delete wikiDb.key_grants (\g -> g.resource_kind ==. val_ spaceKind &&. g.resource_id `in_` map (\s -> val_ s.text) sids))

-- | Delete every grant of every key of a space: a rotation of its key
-- makes them again, of the new key alone.
deleteGrantsOfSpace :: (Backend be) => SpaceId -> Db be ()
deleteGrantsOfSpace sid = runDelete (delete wikiDb.key_grants (\g -> g.resource_kind ==. val_ spaceKind &&. g.resource_id ==. val_ sid.text))

-- | The current public key of each of these users who has one, with its id.
currentPublicKeys :: (Backend be) => [UserId] -> Db be (Map UserId (KeyId, PublicKey))
currentPublicKeys users
  | null users = pure mempty
  | otherwise = do
      rows <- runSelectReturningList (select (filter_ (\k -> isNothing_ k.retired_at &&. k.user_id `in_` map (\u -> val_ u.text) users) (all_ wikiDb.public_keys)))
      pure (Map.fromList [(UserId k.user_id, (KeyId k.key_id, PublicKey k.public_key)) | k <- rows])

--------------------------------------------------------------------------------
-- Pages

-- | Store a page's key, the one its next version is encrypted with.
insertPageKey :: (Backend be) => PageId -> PageKey -> Db be ()
insertPageKey pid k = runInsert . insert wikiDb.page_keys $ insertValues [pageKeyRow pid True k]

pageKeyRow :: PageId -> Bool -> PageKey -> PageKeys Identity
pageKeyRow pid current k = PageKeyRow {page_id = pid.text, key_id = k.keyId.text, space_key_id = k.spaceKeyId.text, nonce = k.wrapped.nonce.text, wrapped = k.wrapped.key.text, current}

pageKeyOf :: PageKeys Identity -> PageKey
pageKeyOf r = PageKey {keyId = KeyId r.key_id, spaceKeyId = KeyId r.space_key_id, wrapped = WrappedKey {nonce = Nonce r.nonce, key = Ciphertext r.wrapped}}

-- | A page's current key, if the page has one (if it is a page of an
-- encrypted space).
loadPageKey :: (Backend be) => PageId -> Db be (Maybe PageKey)
loadPageKey pid = fmap pageKeyOf <$> runSelectReturningOne (select (filter_ (\k -> k.page_id ==. val_ pid.text &&. k.current) (all_ wikiDb.page_keys)))

-- | Every key a page has had, its current one first: the versions written
-- before a rotation of its space's key are encrypted with older ones.
loadPageKeys :: (Backend be) => PageId -> Db be [PageKey]
loadPageKeys pid = do
  rows <- runSelectReturningList (select (filter_ (\k -> k.page_id ==. val_ pid.text) (all_ wikiDb.page_keys)))
  pure (map pageKeyOf (sortOn (\r -> (not r.current, r.key_id)) rows))

-- | The current keys of a space's pages, by page.
loadSpacePageKeys :: (Backend be) => SpaceId -> Db be (Map PageId PageKey)
loadSpacePageKeys sid = Map.mapMaybe head <$> loadSpaceAllPageKeys sid

-- | Every key of each page of a space, by page, each page's current key
-- first.
loadSpaceAllPageKeys :: (Backend be) => SpaceId -> Db be (Map PageId [PageKey])
loadSpaceAllPageKeys sid = do
  rows <- runSelectReturningList . select $ do
    k <- all_ wikiDb.page_keys
    _ <- join_ wikiDb.pages (\p -> p.id ==. k.page_id &&. p.space_id ==. val_ sid.text)
    pure k
  pure (map pageKeyOf . sortOn (\r -> (not r.current, r.key_id)) <$> Map.fromListWith (<>) [(PageId r.page_id, [r]) | r <- rows])

-- | Replace every key of a page: the keys it had, wrapped again by a new
-- space key, and its new current key.
replacePageKeys :: (Backend be) => PageId -> PageKey -> [PageKey] -> Db be ()
replacePageKeys pid current older = do
  runDelete (delete wikiDb.page_keys (\k -> k.page_id ==. val_ pid.text))
  runInsert . insert wikiDb.page_keys $ insertValues (pageKeyRow pid True current : map (pageKeyRow pid False) older)

-- | Store a version's ciphertexts, beside its row of @page_versions@.
insertSealedVersion :: (Backend be) => PageId -> UTCTime -> SealedContent -> Db be ()
insertSealedVersion pid at c =
  runInsert . insert wikiDb.sealed_versions $
    insertValues
      [ SealedVersionRow
          { page_id = pid.text
          , updated_at = micro at
          , tag = c.tag.text
          , key_id = c.keyId.text
          , title_nonce = c.title.nonce.text
          , title = c.title.ciphertext.text
          , body_nonce = c.body.nonce.text
          , body = c.body.ciphertext.text
          , chain_number = (\x -> fromIntegral x.number) <$> c.chain
          , previous_tag = (\x -> (\t -> t.text) <$> x.previous) =<< c.chain
          }
      ]

contentOf :: SealedVersions Identity -> SealedContent
contentOf r =
  SealedContent
    { tag = VersionTag r.tag
    , keyId = KeyId r.key_id
    , chain = (\n -> Chain {number = fromIntegral n, previous = VersionTag <$> r.previous_tag}) <$> r.chain_number
    , title = Sealed {nonce = Nonce r.title_nonce, ciphertext = Ciphertext r.title}
    , body = Sealed {nonce = Nonce r.body_nonce, ciphertext = Ciphertext r.body}
    }

-- | A version's ciphertexts.
loadSealedVersion :: (Backend be) => PageId -> UTCTime -> Db be (Maybe SealedContent)
loadSealedVersion pid at = fmap contentOf <$> runSelectReturningOne (select (filter_ (\v -> v.page_id ==. val_ pid.text &&. v.updated_at ==. val_ (micro at)) (all_ wikiDb.sealed_versions)))

-- | The latest version of each page of a space, encrypted, by page: the
-- version whose time is the page's.
loadSealedLatest :: (Backend be) => SpaceId -> Db be (Map PageId SealedContent)
loadSealedLatest sid = do
  rows <- runSelectReturningList . select $ do
    v <- all_ wikiDb.sealed_versions
    _ <- join_ wikiDb.pages (\p -> p.id ==. v.page_id &&. p.updated_at ==. v.updated_at &&. p.space_id ==. val_ sid.text)
    pure v
  pure (Map.fromList [(PageId r.page_id, contentOf r) | r <- rows])

--------------------------------------------------------------------------------
-- Comments and attachments

-- | Store a thread's anchor, encrypted, beside its row of @threads@: none
-- for a thread about the whole page.
insertSealedThread :: (Backend be) => CommentThreadId -> KeyId -> Maybe SealedAnchor -> Db be ()
insertSealedThread tid k anchor =
  runInsert . insert wikiDb.sealed_threads $
    insertValues [SealedThreadRow {thread_id = tid.text, key_id = maybe k.text (\a -> a.keyId.text) anchor, anchored = isJust anchor, anchor_nonce = (\a -> a.anchor.nonce.text) <$> anchor, anchor = (\a -> a.anchor.ciphertext.text) <$> anchor}]

-- | The threads of a page with an encrypted row, by thread: whether each is
-- about a quote, and the quote, encrypted.
loadSealedAnchors :: (Backend be) => PageId -> Db be (Map CommentThreadId (Bool, Maybe SealedAnchor))
loadSealedAnchors pid = do
  rows <- runSelectReturningList . select $ do
    s <- all_ wikiDb.sealed_threads
    _ <- join_ wikiDb.threads (\t -> t.id ==. s.thread_id &&. t.page_id ==. val_ pid.text)
    pure s
  pure (Map.fromList [(CommentThreadId r.thread_id, (r.anchored, SealedAnchor (KeyId r.key_id) <$> (Sealed <$> (Nonce <$> r.anchor_nonce) <*> (Ciphertext <$> r.anchor)))) | r <- rows])

sealedCommentRow :: CommentId -> SealedComment -> SealedComments Identity
sealedCommentRow cid c = SealedCommentRow {comment_id = cid.text, key_id = c.keyId.text, tag = c.tag.text, nonce = c.body.nonce.text, body = c.body.ciphertext.text}

-- | Store a comment's text, encrypted, beside its row of @comments@.
insertSealedComment :: (Backend be) => CommentId -> SealedComment -> Db be ()
insertSealedComment cid c = runInsert . insert wikiDb.sealed_comments $ insertValues [sealedCommentRow cid c]

-- | A comment's text written again, encrypted.
replaceSealedComment :: (Backend be) => CommentId -> SealedComment -> Db be ()
replaceSealedComment cid c = do
  runDelete (delete wikiDb.sealed_comments (\r -> r.comment_id ==. val_ cid.text))
  insertSealedComment cid c

-- | The encrypted texts of a page's comments, by comment.
loadSealedComments :: (Backend be) => PageId -> Db be (Map CommentId SealedComment)
loadSealedComments pid = do
  rows <- runSelectReturningList . select $ do
    s <- all_ wikiDb.sealed_comments
    c <- join_ wikiDb.comments (\c -> c.id ==. s.comment_id)
    _ <- join_ wikiDb.threads (\t -> t.id ==. c.thread_id &&. t.page_id ==. val_ pid.text)
    pure s
  pure (Map.fromList [(CommentId r.comment_id, SealedComment {keyId = KeyId r.key_id, tag = VersionTag r.tag, body = Sealed (Nonce r.nonce) (Ciphertext r.body)}) | r <- rows])

-- | Store an attachment's name and media type, encrypted, and the nonce of
-- its bytes, beside its row of @attachments@.
insertSealedAttachment :: (Backend be) => AttachmentId -> SealedMeta -> Db be ()
insertSealedAttachment aid m =
  runInsert . insert wikiDb.sealed_attachments $
    insertValues [SealedAttachmentRow {attachment_id = aid.text, key_id = m.keyId.text, meta_nonce = m.meta.nonce.text, meta = m.meta.ciphertext.text, bytes_nonce = m.bytesNonce.text, staged_blob = Nothing}]

-- | The encrypted names and media types of a page's attachments, by
-- attachment.
loadSealedMetas :: (Backend be) => PageId -> Db be (Map AttachmentId SealedMeta)
loadSealedMetas pid = do
  rows <- runSelectReturningList . select $ do
    s <- all_ wikiDb.sealed_attachments
    _ <- join_ wikiDb.attachments (\a -> a.id ==. s.attachment_id &&. a.page_id ==. val_ pid.text)
    pure s
  pure (Map.fromList [(AttachmentId r.attachment_id, SealedMeta {keyId = KeyId r.key_id, meta = Sealed (Nonce r.meta_nonce) (Ciphertext r.meta), bytesNonce = Nonce r.bytes_nonce}) | r <- rows])
