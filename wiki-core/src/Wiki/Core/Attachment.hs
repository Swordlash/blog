{-# LANGUAGE DeriveAnyClass #-}

-- | Files attached to a page: images, video, audio and anything else.
--
-- A page's Markdown refers to its attachments by name (@![diagram](diagram.png)@),
-- and the renderer picks the element to show one with from its media type
-- ('mediaKind'). Where the bytes are is a 'Source': a URL in the serverless
-- demo, where nothing is stored, and a blob the server keeps once there is
-- one.
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

-- | One file attached to a page.
data Attachment = Attachment
  { id :: AttachmentId
  , name :: Text
  -- ^ The file name, as the page's Markdown refers to it; unique among the
  -- page's attachments.
  , mediaType :: Text
  -- ^ The media (MIME) type, such as @image/png@, as the upload declared it.
  , size :: Natural
  -- ^ In bytes.
  , source :: Source
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where an attachment's bytes are.
data Source
  = -- | Anywhere on the web, or an object URL for a file uploaded into the
    -- demo, which lives as long as the tab does.
    SourceUrl Text
  | -- | In the server's blob store, which serves it at an address of its own.
    SourceBlob BlobId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | What a page shows an attachment as.
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
-- and parameters (@; codecs=…@) do not matter, since browsers ignore them
-- too.
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

-- | The attachment with this name, as a page's Markdown refers to it.
findAttachment :: Text -> [Attachment] -> Maybe Attachment
findAttachment n = find (\a -> a.name == n)
