-- | 'Wiki.Server.Storage.Conversion' is the statements of a conversion of
-- a space's pages (WP5.74b3 of docs/PLAN.md, item 4 of #213,
-- "Wiki.Core.Space"'s 'Conversion'): which spaces are being converted
-- (@spaces.conversion@) and which of their pages are converted already
-- (@pages.converted@), what a browser staged of a page before its commit
-- (the encrypted tables of "Wiki.Server.Storage.Sealed" while a space is
-- encrypted, @staged_plain@ while its encryption is turned off), and the
-- commit's own changes to the plain tables. "Wiki.Server.Storage" decides
-- who may do each, and when; this module only reads and writes rows.
module Wiki.Server.Storage.Conversion
  ( -- * Spaces and pages
    setConversion
  , clearSpaceKey
  , convertedIn
  , pageConverted
  , setPageConverted
  , clearConverted
  , unconvertedIn
  , draftsIn
  , templatesIn
  , webAttachmentsIn

    -- * What is staged while a space is encrypted
  , dropStagedSealed
  , replaceSealedVersion
  , replaceSealedThread
  , replaceSealedAttachment
  , setSealedStagedBlob
  , clearSealedStagedBlob
  , StagedSealedRows (..)
  , loadStagedSealed

    -- * What is staged while a space's encryption is turned off
  , upsertStagedPlain
  , setPlainStagedBlob
  , loadStagedPlain
  , dropStagedPlain

    -- * A page's commit
  , pageVersionTimes
  , pageThreads
  , pageComments
  , pageAttachmentIds
  , setVersionText
  , setThreadQuote
  , setCommentBody
  , setAttachmentFile
  , deletePageDrafts
  , hideNotificationsOf
  , dropSealedOf
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime)
import Database.Beam (all_, delete, filter_, in_, insert, insertValues, join_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (==.))
import Database.Beam qualified as Beam
import Protolude
import Wiki.Core.Encrypted (SealedAnchor (..), SealedComment (..), SealedContent, SealedMeta (..))
import Wiki.Core.Id (AttachmentId (..), BlobId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Space (Conversion, conversionName)
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), Sealed (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (markSpaceLinks, micro)
import Wiki.Server.Storage.Schema (Attachments (..), Comments (..), Drafts (..), Notifications (..), PageKeys (..), PageVersions (..), Pages (..), SealedAttachments (..), SealedComments (..), SealedThreads (..), SealedVersions (..), Spaces (..), StagedPlain (..), Threads (..), WikiDb (..), wikiDb)
import Wiki.Server.Storage.Sealed (contentOf, insertSealedThread, insertSealedVersion, loadSealedAnchors, loadSealedComments, loadSealedMetas)

--------------------------------------------------------------------------------
-- Spaces and pages

-- | Start a conversion of a space, or end it ('Nothing'). Written by this
-- alone: a space's other updates never write the column.
setConversion :: (Backend be) => SpaceId -> Maybe Conversion -> Db be ()
setConversion sid c = runUpdate (update wikiDb.spaces (\x -> x.conversion <-. val_ (conversionName <$> c)) (\x -> x.id ==. val_ sid.text))

-- | Make a space plain again, at the end of turning its encryption off.
clearSpaceKey :: (Backend be) => SpaceId -> Db be ()
clearSpaceKey sid = do
  runUpdate (update wikiDb.spaces (\x -> x.key_id <-. val_ Nothing) (\x -> x.id ==. val_ sid.text))
  -- Paths into the space read otherwise once it is plain, as when it was
  -- made encrypted ('Wiki.Server.Storage.Sealed.setSpaceKey').
  markSpaceLinks sid

-- | The pages of a space the running conversion has converted.
convertedIn :: (Backend be) => SpaceId -> Db be (Set PageId)
convertedIn sid = Set.fromList . map PageId <$> runSelectReturningList (select ((\p -> p.id) <$> filter_ (\p -> p.space_id ==. val_ sid.text &&. p.converted) (all_ wikiDb.pages)))

-- | Whether the running conversion has converted a page.
pageConverted :: (Backend be) => PageId -> Db be Bool
pageConverted pid = fromMaybe False <$> runSelectReturningOne (select ((\p -> p.converted) <$> filter_ (\p -> p.id ==. val_ pid.text) (all_ wikiDb.pages)))

setPageConverted :: (Backend be) => PageId -> Db be ()
setPageConverted pid = runUpdate (update wikiDb.pages (\p -> p.converted <-. val_ True) (\p -> p.id ==. val_ pid.text))

-- | Every page of a space unmarked, as no conversion runs.
clearConverted :: (Backend be) => SpaceId -> Db be ()
clearConverted sid = runUpdate (update wikiDb.pages (\p -> p.converted <-. val_ False) (\p -> p.space_id ==. val_ sid.text))

-- | The pages of these spaces not converted yet, each with its space, the
-- oldest first.
unconvertedIn :: (Backend be) => [SpaceId] -> Db be [(PageId, SpaceId)]
unconvertedIn sids
  | null sids = pure []
  | otherwise = do
      rows <- runSelectReturningList (select ((\p -> (p.id, p.space_id, p.created_at)) <$> filter_ (\p -> p.space_id `in_` map (\s -> val_ s.text) sids &&. Beam.not_ p.converted) (all_ wikiDb.pages)))
      pure [(PageId i, SpaceId s) | (i, s, _) <- sortOn (\(i, _, at) -> (at, i)) rows]

-- | The drafts kept of the pages of these spaces, each by its page and its
-- writer.
draftsIn :: (Backend be) => [SpaceId] -> Db be [(PageId, UserId)]
draftsIn sids
  | null sids = pure []
  | otherwise = do
      rows <- runSelectReturningList . select $ do
        d <- all_ wikiDb.drafts
        _ <- join_ wikiDb.pages (\p -> p.id ==. d.page_id &&. p.space_id `in_` map (\x -> val_ x.text) sids)
        pure (d.page_id, d.author)
      pure [(PageId p, UserId u) | (p, u) <- rows]

-- | The templates among the pages of these spaces.
templatesIn :: (Backend be) => [SpaceId] -> Db be [PageId]
templatesIn sids
  | null sids = pure []
  | otherwise = map PageId <$> runSelectReturningList (select ((\p -> p.id) <$> filter_ (\p -> p.space_id `in_` map (\x -> val_ x.text) sids &&. p.template) (all_ wikiDb.pages)))

-- | The pages of these spaces with an attachment on the web (a URL, not
-- bytes the wiki keeps).
webAttachmentsIn :: (Backend be) => [SpaceId] -> Db be [PageId]
webAttachmentsIn sids
  | null sids = pure []
  | otherwise = do
      rows <- runSelectReturningList . select $ do
        a <- filter_ (\a -> Beam.isJust_ a.url) (all_ wikiDb.attachments)
        _ <- join_ wikiDb.pages (\p -> p.id ==. a.page_id &&. p.space_id `in_` map (\x -> val_ x.text) sids)
        pure a.page_id
      pure (map PageId (ordNub rows))

--------------------------------------------------------------------------------
-- What is staged while a space is encrypted

-- | Forget what was staged of a page while its space is encrypted: its
-- keys and every ciphertext of it, so that a browser that starts the page
-- again with a new key leaves nothing of the first try. The rows of the
-- plain tables are untouched.
dropStagedSealed :: (Backend be) => PageId -> Db be ()
dropStagedSealed pid = do
  threads <- map (\(t, _) -> t) <$> pageThreads pid
  comments <- map fst <$> pageComments pid
  attachments <- map (\a -> a.text) <$> pageAttachmentIds pid
  runDelete (delete wikiDb.sealed_versions (\v -> v.page_id ==. val_ pid.text))
  runDelete (delete wikiDb.page_keys (\k -> k.page_id ==. val_ pid.text))
  unless (null threads) $ runDelete (delete wikiDb.sealed_threads (\s -> s.thread_id `in_` map (\t -> val_ t.text) threads))
  unless (null comments) $ runDelete (delete wikiDb.sealed_comments (\s -> s.comment_id `in_` map (\c -> val_ c.text) comments))
  unless (null attachments) $ runDelete (delete wikiDb.sealed_attachments (\s -> s.attachment_id `in_` map val_ attachments))

-- | A version's ciphertexts, in place of any staged before for it.
replaceSealedVersion :: (Backend be) => PageId -> UTCTime -> SealedContent -> Db be ()
replaceSealedVersion pid at c = do
  runDelete (delete wikiDb.sealed_versions (\v -> v.page_id ==. val_ pid.text &&. v.updated_at ==. val_ (micro at)))
  insertSealedVersion pid at c

-- | A thread's anchor, encrypted, in place of any staged before for it.
replaceSealedThread :: (Backend be) => CommentThreadId -> KeyId -> Maybe SealedAnchor -> Db be ()
replaceSealedThread tid k anchor = do
  runDelete (delete wikiDb.sealed_threads (\s -> s.thread_id ==. val_ tid.text))
  insertSealedThread tid k anchor

-- | An attachment's name and media type, encrypted, in place of any staged
-- before for it, with no bytes staged yet: new metadata comes with bytes
-- encrypted anew.
replaceSealedAttachment :: (Backend be) => AttachmentId -> SealedMeta -> Db be ()
replaceSealedAttachment aid m = do
  runDelete (delete wikiDb.sealed_attachments (\s -> s.attachment_id ==. val_ aid.text))
  runInsert . insert wikiDb.sealed_attachments $
    insertValues [SealedAttachmentRow {attachment_id = aid.text, key_id = m.keyId.text, meta_nonce = m.meta.nonce.text, meta = m.meta.ciphertext.text, bytes_nonce = m.bytesNonce.text, staged_blob = Nothing}]

-- | The blob of an attachment's encrypted bytes, staged.
setSealedStagedBlob :: (Backend be) => AttachmentId -> BlobId -> Db be ()
setSealedStagedBlob aid b = runUpdate (update wikiDb.sealed_attachments (\s -> s.staged_blob <-. val_ (Just b.text)) (\s -> s.attachment_id ==. val_ aid.text))

-- | No blob staged for an attachment any more: its commit put it in the
-- attachment's row.
clearSealedStagedBlob :: (Backend be) => AttachmentId -> Db be ()
clearSealedStagedBlob aid = runUpdate (update wikiDb.sealed_attachments (\s -> s.staged_blob <-. val_ Nothing) (\s -> s.attachment_id ==. val_ aid.text))

-- | 'StagedSealedRows' is what is staged of a page while its space is
-- encrypted, as stored: its versions' ciphertexts by time, the oldest
-- first, its threads' anchors, its comments' texts, and its attachments'
-- names and media types with their staged blobs.
data StagedSealedRows = StagedSealedRows
  { versions :: [(UTCTime, SealedContent)]
  , anchors :: Map CommentThreadId (Bool, Maybe SealedAnchor)
  , comments :: Map CommentId SealedComment
  , metas :: Map AttachmentId (SealedMeta, Maybe BlobId)
  }

-- | What is staged of a page while its space is encrypted.
loadStagedSealed :: (Backend be) => PageId -> Db be StagedSealedRows
loadStagedSealed pid = do
  versionRows <- runSelectReturningList (select (filter_ (\v -> v.page_id ==. val_ pid.text) (all_ wikiDb.sealed_versions)))
  anchors <- loadSealedAnchors pid
  comments <- loadSealedComments pid
  metas <- loadSealedMetas pid
  blobs <- Map.fromList <$> runSelectReturningList (select ((\x -> (x.attachment_id, x.staged_blob)) <$> filter_ (\x -> x.attachment_id `in_` map (\a -> val_ a.text) (Map.keys metas)) (all_ wikiDb.sealed_attachments)))
  pure
    StagedSealedRows
      { versions = [(r.updated_at, contentOf r) | r <- sortOn (\r -> r.updated_at) versionRows]
      , anchors
      , comments
      , metas = Map.mapWithKey (\aid m -> (m, BlobId <$> join (Map.lookup aid.text blobs))) metas
      }

--------------------------------------------------------------------------------
-- What is staged while a space's encryption is turned off

-- | A row of @staged_plain@, in place of the one there for the same item.
upsertStagedPlain :: (Backend be) => StagedPlain Identity -> Db be ()
upsertStagedPlain r = do
  runDelete (delete wikiDb.staged_plain (\x -> x.page_id ==. val_ r.page_id &&. x.kind ==. val_ r.kind &&. x.item ==. val_ r.item))
  runInsert (insert wikiDb.staged_plain (insertValues [r]))

-- | The blob of an attachment's decrypted bytes, staged.
setPlainStagedBlob :: (Backend be) => PageId -> AttachmentId -> BlobId -> Db be ()
setPlainStagedBlob pid aid b =
  runUpdate (update wikiDb.staged_plain (\x -> x.blob <-. val_ (Just b.text)) (\x -> x.page_id ==. val_ pid.text &&. x.kind ==. val_ "attachment" &&. x.item ==. val_ aid.text))

-- | What is staged of a page while its space's encryption is turned off.
loadStagedPlain :: (Backend be) => PageId -> Db be [StagedPlain Identity]
loadStagedPlain pid = sortOn (\r -> (r.kind, r.item)) <$> runSelectReturningList (select (filter_ (\x -> x.page_id ==. val_ pid.text) (all_ wikiDb.staged_plain)))

dropStagedPlain :: (Backend be) => PageId -> Db be ()
dropStagedPlain pid = runDelete (delete wikiDb.staged_plain (\x -> x.page_id ==. val_ pid.text))

--------------------------------------------------------------------------------
-- A page's commit

-- | The times of a page's versions, the oldest first.
pageVersionTimes :: (Backend be) => PageId -> Db be [UTCTime]
pageVersionTimes pid = sort <$> runSelectReturningList (select ((\v -> v.updated_at) <$> filter_ (\v -> v.page_id ==. val_ pid.text) (all_ wikiDb.page_versions)))

-- | A page's threads, each with whether its row has a quote.
pageThreads :: (Backend be) => PageId -> Db be [(CommentThreadId, Bool)]
pageThreads pid = map (\t -> (CommentThreadId t.id, isJust t.quote)) <$> runSelectReturningList (select (filter_ (\t -> t.page_id ==. val_ pid.text) (all_ wikiDb.threads)))

-- | A page's comments, each with its thread.
pageComments :: (Backend be) => PageId -> Db be [(CommentId, CommentThreadId)]
pageComments pid = do
  rows <- runSelectReturningList . select $ do
    c <- all_ wikiDb.comments
    _ <- join_ wikiDb.threads (\t -> t.id ==. c.thread_id &&. t.page_id ==. val_ pid.text)
    pure (c.id, c.thread_id)
  pure [(CommentId c, CommentThreadId t) | (c, t) <- rows]

-- | A page's attachments, by id.
pageAttachmentIds :: (Backend be) => PageId -> Db be [AttachmentId]
pageAttachmentIds pid = map AttachmentId <$> runSelectReturningList (select ((\a -> a.id) <$> filter_ (\a -> a.page_id ==. val_ pid.text) (all_ wikiDb.attachments)))

-- | A version's plain title and text.
setVersionText :: (Backend be) => PageId -> UTCTime -> Text -> Text -> Db be ()
setVersionText pid at title body =
  runUpdate (update wikiDb.page_versions (\v -> mconcat [v.title <-. val_ title, v.body <-. val_ body]) (\v -> v.page_id ==. val_ pid.text &&. v.updated_at ==. val_ (micro at)))

-- | A thread's quote with its context: none for a thread about the whole
-- page.
setThreadQuote :: (Backend be) => CommentThreadId -> Maybe (Text, Text, Text) -> Db be ()
setThreadQuote tid q =
  runUpdate (update wikiDb.threads (\t -> mconcat [t.quote <-. val_ ((\(x, _, _) -> x) <$> q), t.prefix <-. val_ ((\(_, x, _) -> x) <$> q), t.suffix <-. val_ ((\(_, _, x) -> x) <$> q)]) (\t -> t.id ==. val_ tid.text))

-- | A comment's text, its row's, leaving when it was edited as it was.
setCommentBody :: (Backend be) => CommentId -> Text -> Db be ()
setCommentBody cid body = runUpdate (update wikiDb.comments (\c -> c.body <-. val_ body) (\c -> c.id ==. val_ cid.text))

-- | An attachment's name, media type, size and blob.
setAttachmentFile :: (Backend be) => AttachmentId -> Text -> Text -> Int64 -> BlobId -> Db be ()
setAttachmentFile aid name mediaType size b =
  runUpdate (update wikiDb.attachments (\a -> mconcat [a.name <-. val_ name, a.media_type <-. val_ mediaType, a.size <-. val_ size, a.blob <-. val_ (Just b.text)]) (\a -> a.id ==. val_ aid.text))

-- | Every draft of a page, whoever wrote it.
deletePageDrafts :: (Backend be) => PageId -> Db be ()
deletePageDrafts pid = runDelete (delete wikiDb.drafts (\d -> d.page_id ==. val_ pid.text))

-- | The notifications of a page, named by what it is and with no excerpt,
-- as those of an encrypted page are made.
hideNotificationsOf :: (Backend be) => PageId -> Text -> Db be ()
hideNotificationsOf pid title = runUpdate (update wikiDb.notifications (\n -> mconcat [n.title <-. val_ title, n.excerpt <-. val_ ""]) (\n -> n.page_id ==. val_ pid.text))

-- | Every ciphertext and key of a page: its versions', threads',
-- comments' and attachments' rows of the encrypted tables, and its keys.
dropSealedOf :: (Backend be) => PageId -> Db be ()
dropSealedOf = dropStagedSealed
