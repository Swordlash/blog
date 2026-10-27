-- | The zip media type, for servant: the content type of an archive's zip
-- file, which @GET \/api\/v1\/export@ responds with.
module Wiki.Api.Zip
  ( Zip
  )
where

import Network.HTTP.Media ((//))
import Protolude
import Servant.API (Accept (..), MimeRender (..), MimeUnrender (..))

-- | 'Zip': @application\/zip@, the bytes unchanged.
data Zip

instance Accept Zip where
  contentType _ = "application" // "zip"

instance MimeRender Zip LByteString where
  mimeRender _ = identity

instance MimeUnrender Zip LByteString where
  mimeUnrender _ = Right
