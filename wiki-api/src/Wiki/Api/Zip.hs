-- | The media type of an archive's zip file, for servant: what
-- @GET \/api\/v1\/export@ answers with.
module Wiki.Api.Zip
  ( Zip
  )
where

import Network.HTTP.Media ((//))
import Protolude
import Servant.API (Accept (..), MimeRender (..), MimeUnrender (..))

-- | @application\/zip@, the bytes as they are.
data Zip

instance Accept Zip where
  contentType _ = "application" // "zip"

instance MimeRender Zip LByteString where
  mimeRender _ = identity

instance MimeUnrender Zip LByteString where
  mimeUnrender _ = Right
