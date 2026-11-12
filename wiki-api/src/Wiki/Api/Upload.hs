{-# LANGUAGE DeriveAnyClass #-}

-- | Upload forms: what the API's multipart forms carry, an attachment's
-- file or an archive to import.
--
-- Each form type takes servant-multipart's backend as a parameter: 'Tmp',
-- where the file part is a temporary file on disk, or 'Mem', where it is
-- bytes in memory. The server serves 'Tmp' forms, so that it writes an
-- upload to disk as it arrives rather than holding it in memory: an
-- attachment of up to 50 MB (decision 17 of the plan, @maxAttachmentSize@
-- in @wiki-app@), or an archive of a whole wiki to import. The browser
-- sends 'Mem' forms, since the bytes it uploads are in memory, and the
-- tests build and read 'Mem' forms too ("Wiki.Api", @ApiWith@). The
-- largest form the server accepts is the server's own setting
-- (servant-multipart's @MultipartOptions@), not part of the API's type.
-- Each instance says that the form's backend is the type's (@tag ~ form@)
-- rather than requiring them to be one variable, so that the backend of a
-- form is inferred from either.
--
-- The browser's client (servant-multipart-client) writes a form from the
-- 'ToMultipart' instances below, and the server reads it with the
-- 'FromMultipart' instances, so the parts sent are the parts read: for an attachment, one file part named 'attachmentPart'
-- with the file's name and media type; for an archive, one file part named
-- 'archivePart', plus, for an import's choices, a text part named
-- 'choicesPart' with the choices as JSON.
module Wiki.Api.Upload
  ( -- * Attachments
    AttachmentUpload (..)
  , attachmentPart
  , SealedAttachmentUpload (..)
  , SealedUpload (..)
  , sealedPart

    -- * Archives
  , ArchiveUpload (..)
  , archivePart
  , ImportApply (..)
  , choicesPart
  )
where

import Data.Aeson
  ( FromJSON
  , ToJSON
  , eitherDecodeStrict'
  , encode
  )
import Data.ByteString.Lazy qualified as BSL
import Data.Type.Equality (type (~))
import Protolude
import Servant.Multipart.API (FileData (..), FromMultipart (..), Input (..), Mem, MultipartData (..), MultipartResult, Tmp, ToMultipart (..), lookupFile, lookupInput)
import Wiki.Api.Import (ImportChoices)
import Wiki.Core.Encrypted (SealedMeta)
import Wiki.Core.Id (AttachmentId)

-- | 'AttachmentUpload': a file to attach to a page, with
-- @uploadAttachment@'s name, media type and bytes, sent as the form's one
-- file part, named 'attachmentPart'. The attachment's name is the part's
-- file name, and its media type the part's @Content-Type@. The bytes are
-- the 'payload': the path of a temporary file for a 'Tmp' form, the bytes
-- themselves for a 'Mem' one.
data AttachmentUpload tag = AttachmentUpload
  { name :: Text
  , mediaType :: Text
  , payload :: MultipartResult tag
  }

deriving stock instance Eq (AttachmentUpload Mem)

deriving stock instance Show (AttachmentUpload Mem)

deriving stock instance Eq (AttachmentUpload Tmp)

deriving stock instance Show (AttachmentUpload Tmp)

-- | The name of the form's part that holds an attachment's file.
attachmentPart :: Text
attachmentPart = "file"

instance (tag ~ form) => FromMultipart tag (AttachmentUpload form) where
  fromMultipart form = do
    file <- lookupFile attachmentPart form
    pure AttachmentUpload {name = fdFileName file, mediaType = fdFileCType file, payload = fdPayload file}

instance (tag ~ form) => ToMultipart tag (AttachmentUpload form) where
  toMultipart u =
    MultipartData
      { inputs = []
      , files = [FileData {fdInputName = attachmentPart, fdFileName = u.name, fdFileCType = u.mediaType, fdPayload = u.payload}]
      }

-- | 'SealedAttachmentUpload': an attachment of a page of an encrypted space
-- (WP5.74b3 of docs/PLAN.md): its bytes encrypted in the browser, sent as
-- the form's file part named 'attachmentPart', and, as JSON in the text
-- part named 'sealedPart', its id, chosen by the browser, its name and
-- media type, encrypted, with the nonce of its bytes, and the attachment
-- it replaces, if any (one of the same name, which only the browser can
-- tell). The file part's name and media type say nothing of the file.
data SealedAttachmentUpload tag = SealedAttachmentUpload
  { sealed :: SealedUpload
  , payload :: MultipartResult tag
  }

-- | The text part of a 'SealedAttachmentUpload'.
data SealedUpload = SealedUpload
  { id :: AttachmentId
  , meta :: SealedMeta
  , replaces :: Maybe AttachmentId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The name of the text part of a 'SealedAttachmentUpload'.
sealedPart :: Text
sealedPart = "sealed"

instance (tag ~ form) => FromMultipart tag (SealedAttachmentUpload form) where
  fromMultipart form = do
    file <- lookupFile attachmentPart form
    text <- lookupInput sealedPart form
    sealed <- eitherDecodeStrict' (encodeUtf8 text)
    pure SealedAttachmentUpload {sealed, payload = fdPayload file}

instance (tag ~ form) => ToMultipart tag (SealedAttachmentUpload form) where
  toMultipart u =
    MultipartData
      { inputs = [Input {iName = sealedPart, iValue = decodeUtf8 (BSL.toStrict (encode u.sealed))}]
      , files = [FileData {fdInputName = attachmentPart, fdFileName = "sealed", fdFileCType = "application/octet-stream", fdPayload = u.payload}]
      }

-- | 'ArchiveUpload': an archive ("Wiki.Core.Export", zipped) for an
-- import's preview, sent as the form's file part named 'archivePart'. Its
-- file name and media type are ignored. The archive is a temporary file's
-- path for a 'Tmp' form, the bytes for a 'Mem' one.
newtype ArchiveUpload tag = ArchiveUpload {archive :: MultipartResult tag}

deriving stock instance Eq (ArchiveUpload Mem)

deriving stock instance Show (ArchiveUpload Mem)

deriving stock instance Eq (ArchiveUpload Tmp)

deriving stock instance Show (ArchiveUpload Tmp)

-- | The name of the form's part that holds an archive.
archivePart :: Text
archivePart = "archive"

instance (tag ~ form) => FromMultipart tag (ArchiveUpload form) where
  fromMultipart form = ArchiveUpload . fdPayload <$> lookupFile archivePart form

instance (tag ~ form) => ToMultipart tag (ArchiveUpload form) where
  toMultipart u = MultipartData {inputs = [], files = [archiveFile u.archive]}

-- | 'ImportApply': an import to run. It holds the archive the preview was
-- made from, sent again (the server stores nothing between the two steps),
-- and the choices made in the dialog, as JSON in the form part named
-- 'choicesPart'.
data ImportApply tag = ImportApply
  { archive :: MultipartResult tag
  , choices :: ImportChoices
  }

deriving stock instance Eq (ImportApply Mem)

deriving stock instance Show (ImportApply Mem)

deriving stock instance Eq (ImportApply Tmp)

deriving stock instance Show (ImportApply Tmp)

-- | The name of the form's part that holds an import's choices.
choicesPart :: Text
choicesPart = "choices"

instance (tag ~ form) => FromMultipart tag (ImportApply form) where
  fromMultipart form = do
    file <- lookupFile archivePart form
    json <- lookupInput choicesPart form
    choices <- eitherDecodeStrict' (encodeUtf8 json)
    pure ImportApply {archive = fdPayload file, choices}

instance (tag ~ form) => ToMultipart tag (ImportApply form) where
  toMultipart u =
    MultipartData
      { inputs = [Input {iName = choicesPart, iValue = decodeUtf8 (BSL.toStrict (encode u.choices))}]
      , files = [archiveFile u.archive]
      }

-- | An archive as a form's file part.
archiveFile :: MultipartResult tag -> FileData tag
archiveFile payload = FileData {fdInputName = archivePart, fdFileName = "wiki.zip", fdFileCType = "application/zip", fdPayload = payload}
