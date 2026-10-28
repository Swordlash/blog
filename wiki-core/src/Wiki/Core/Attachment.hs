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
import Wiki.Core.Id
import Wiki.Core.Url (Url (..))

-- | 'Attachment': one file attached to a page.
data Attachment = Attachment
  { id :: AttachmentId
  , name :: Text
  -- ^ The file name, as the page's Markdown refers to it; unique among the
  -- page's attachments.
  , mediaType :: Text
  -- ^ The media (MIME) type, such as @image/png@, as the upload declared it.
  , size :: Natural
  -- ^ The size in bytes.
  , source :: Source
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

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
mediaKind :: Text -> MediaKind
mediaKind mediaType = case T.splitOn "/" essence of
  [top, sub] | not (T.null sub) -> case top of
    "image" -> MediaImage
    "video" -> MediaVideo
    "audio" -> MediaAudio
    _ -> MediaOther
  _ -> MediaOther
  where
    essence = T.toLower (T.strip (T.takeWhile (/= ';') mediaType))

-- | The kind of an attachment, by its media type.
attachmentKind :: Attachment -> MediaKind
attachmentKind a = mediaKind a.mediaType

-- | The attachment with this name, the name a page's Markdown refers to it by.
findAttachment :: Text -> [Attachment] -> Maybe Attachment
findAttachment n = find (\a -> a.name == n)
