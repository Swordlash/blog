-- | What the API's multipart forms carry: an attachment's file, and an
-- archive to import.
--
-- Each form is read into memory (servant-multipart's 'Mem'): an attachment
-- is at most 50 MB (decision 17 of the plan, @maxAttachmentSize@ in
-- @wiki-app@), and @MonadWiki@'s @uploadAttachment@ takes the bytes anyway.
-- How large a form the server accepts is its own setting (servant-multipart's
-- @MultipartOptions@), not part of the API's type.
--
-- A browser sends either with @fetch@ and a @FormData@: for an attachment,
-- @form.append(\"file\", blob, name)@, which gives the part the file's name
-- and the blob's media type; for an archive, @form.append(\"archive\", zip)@,
-- and for an import's choices also @form.append(\"choices\",
-- JSON.stringify(choices))@.
module Wiki.Api.Upload
  ( -- * Attachments
    AttachmentUpload (..)
  , attachmentPart

    -- * Archives
  , ArchiveUpload (..)
  , archivePart
  , ImportApply (..)
  , choicesPart
  )
where

import Data.Aeson (eitherDecodeStrict', encode)
import Data.ByteString.Lazy qualified as BSL
import Protolude
import Servant.Multipart.API (FileData (..), FromMultipart (..), Input (..), Mem, MultipartData (..), ToMultipart (..), lookupFile, lookupInput)
import Wiki.Api.Import (ImportChoices)

-- | A file to attach to a page: @uploadAttachment@'s name, media type and
-- bytes, sent as the form's one file part, named 'attachmentPart'. The
-- attachment's name is the file name of that part, and its media type the
-- part's @Content-Type@.
data AttachmentUpload = AttachmentUpload
  { name :: Text
  , mediaType :: Text
  , bytes :: LByteString
  }
  deriving stock (Eq, Show)

-- | The name of the form's part that holds an attachment's file.
attachmentPart :: Text
attachmentPart = "file"

instance FromMultipart Mem AttachmentUpload where
  fromMultipart form = do
    file <- lookupFile attachmentPart form
    pure AttachmentUpload {name = fdFileName file, mediaType = fdFileCType file, bytes = fdPayload file}

instance ToMultipart Mem AttachmentUpload where
  toMultipart u =
    MultipartData
      { inputs = []
      , files = [FileData {fdInputName = attachmentPart, fdFileName = u.name, fdFileCType = u.mediaType, fdPayload = u.bytes}]
      }

-- | An archive ("Wiki.Core.Export", zipped) for an import's preview, sent as
-- the form's file part named 'archivePart'. Its file name and media type are
-- not looked at.
newtype ArchiveUpload = ArchiveUpload {archive :: LByteString}
  deriving stock (Eq, Show)

-- | The name of the form's part that holds an archive.
archivePart :: Text
archivePart = "archive"

instance FromMultipart Mem ArchiveUpload where
  fromMultipart form = ArchiveUpload . fdPayload <$> lookupFile archivePart form

instance ToMultipart Mem ArchiveUpload where
  toMultipart u = MultipartData {inputs = [], files = [archiveFile u.archive]}

-- | An import to carry out: the archive the preview was made from, sent
-- again (the server keeps nothing between the two steps), and the choices
-- made in the dialog, as JSON in the form's part named 'choicesPart'.
data ImportApply = ImportApply
  { archive :: LByteString
  , choices :: ImportChoices
  }
  deriving stock (Eq, Show)

-- | The name of the form's part that holds an import's choices.
choicesPart :: Text
choicesPart = "choices"

instance FromMultipart Mem ImportApply where
  fromMultipart form = do
    file <- lookupFile archivePart form
    json <- lookupInput choicesPart form
    choices <- eitherDecodeStrict' (encodeUtf8 json)
    pure ImportApply {archive = fdPayload file, choices}

instance ToMultipart Mem ImportApply where
  toMultipart u =
    MultipartData
      { inputs = [Input {iName = choicesPart, iValue = decodeUtf8 (BSL.toStrict (encode u.choices))}]
      , files = [archiveFile u.archive]
      }

-- | An archive as a form's file part.
archiveFile :: LByteString -> FileData Mem
archiveFile bytes = FileData {fdInputName = archivePart, fdFileName = "wiki.zip", fdFileCType = "application/zip", fdPayload = bytes}
