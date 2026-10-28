{-# LANGUAGE DeriveAnyClass #-}

-- | Attachments: files attached to a page, such as images, video and audio.
--
-- A page's Markdown refers to its attachments by name
-- (@![diagram](attachment:diagram.png)@), and the renderer picks the
-- element that shows an attachment from its media type ('mediaKind'). The
-- location of the bytes is a 'Source': a URL, or a blob stored by the
-- backend (the server's blob store, or the in-memory backend's state).
module Wiki.Core.Attachment
  ( Attachment (..)
  , FileName (..)
  , parseFileName
  , MimeType (..)
  , uploadedMimeType
  , mimeEssence
  , Source (..)
  , MediaKind (..)
  , mediaKind
  , attachmentKind
  , findAttachment
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Numeric.Natural (Natural)
import Protolude
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import Wiki.Core.Id
import Wiki.Core.Url (Url (..))

-- | 'Attachment': one file attached to a page.
data Attachment = Attachment
  { id :: AttachmentId
  , name :: FileName
  -- ^ The file name, as the page's Markdown refers to it; unique among the
  -- page's attachments.
  , mediaType :: MimeType
  -- ^ The media (MIME) type, such as @image/png@, as the upload declared it.
  , size :: Natural
  -- ^ The size in bytes.
  , source :: Source
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'FileName': an attachment's file name, such as @diagram.png@. A page's
-- Markdown refers to the attachment by it. 'parseFileName' checks the
-- name of a new attachment. The JSON and URL instances are the bare text
-- and check nothing: a stored name was checked when the file was
-- uploaded. A name is not escaped for a file system here; an export does
-- that when it writes the file ("Wiki.Core.Export").
newtype FileName = FileName {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | A new attachment's name as it is stored, or why it is invalid: trimmed
-- of white space, not blank, and without a slash, a backslash or a
-- control character, which would make it a path or hide part of it.
parseFileName :: Text -> Either Text FileName
parseFileName raw
  | T.null name = Left "An attachment's name cannot be blank."
  | T.any (\ch -> ch == '/' || ch == '\\' || isControl ch) name = Left "An attachment's name cannot have slashes or control characters in it."
  | otherwise = Right (FileName name)
  where
    name = T.strip raw

-- | 'MimeType': a media type, such as @image\/png@ or @text\/plain;
-- charset=utf-8@, as an upload declared it. Nothing refuses a media type:
-- one that is unknown or does not parse makes the attachment a link
-- ('mediaKind'), and the server sends it as @application\/octet-stream@.
-- The JSON is the bare text.
newtype MimeType = MimeType {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | The media type an upload declared, as it is stored: trimmed of white
-- space, and @application\/octet-stream@ (bytes of no known type) when
-- the upload declared none.
uploadedMimeType :: Text -> MimeType
uploadedMimeType declared = case T.strip declared of
  "" -> MimeType "application/octet-stream"
  t -> MimeType t

-- | A media type without its parameters (@; codecs=…@), trimmed and in
-- lower case, as browsers compare media types: @Image\/PNG; x=y@ gives
-- @image\/png@.
mimeEssence :: MimeType -> Text
mimeEssence (MimeType t) = T.toLower (T.strip (T.takeWhile (/= ';') t))

-- | 'Source': where an attachment's bytes are.
data Source
  = -- | A URL anywhere on the web, such as the demo's sample image
    -- ("Wiki.App.Demo"). Uploads are always stored as blobs.
    SourceUrl Url
  | -- | A blob stored by the backend, which serves it at a URL of its own.
    SourceBlob BlobId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'MediaKind': the element a page shows an attachment as.
data MediaKind
  = -- | An @\<img\>@.
    MediaImage
  | -- | A @\<video\>@ with controls.
    MediaVideo
  | -- | An @\<audio\>@ with controls.
    MediaAudio
  | -- | A link to the file.
    MediaOther
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The kind of a media type, by its top-level type: @image\/…@, @video\/…@,
-- @audio\/…@, and anything else, including a type that does not parse. Case
-- and parameters (@; codecs=…@) are ignored, as browsers ignore them.
mediaKind :: MimeType -> MediaKind
mediaKind mediaType = case T.splitOn "/" (mimeEssence mediaType) of
  [top, sub] | not (T.null sub) -> case top of
    "image" -> MediaImage
    "video" -> MediaVideo
    "audio" -> MediaAudio
    _ -> MediaOther
  _ -> MediaOther

-- | The kind of an attachment, by its media type.
attachmentKind :: Attachment -> MediaKind
attachmentKind a = mediaKind a.mediaType

-- | The attachment with this name, the name a page's Markdown refers to it by.
findAttachment :: Text -> [Attachment] -> Maybe Attachment
findAttachment n = find (\a -> a.name.text == n)
