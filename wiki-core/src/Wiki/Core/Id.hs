-- | The identifiers of the things the wiki stores.
--
-- Each is a newtype over 'Text', so a page's id cannot be passed where a
-- space's is expected, and each is written in JSON as the bare string, also
-- as an object key (membership is a map keyed by 'GroupId'). What the text
-- is, and how a new one is made, is the backend's business: the in-memory
-- backend counts, the server may use UUIDs. Nothing here looks inside one, so
-- the constructors are exported for the backends to make them. In a URL (a
-- path segment or a query parameter of the server's API) each is the bare
-- text too.
module Wiki.Core.Id
  ( SpaceId (..)
  , PageId (..)
  , AttachmentId (..)
  , BlobId (..)
  , UserId (..)
  , GroupId (..)
  , InvitationId (..)
  , CommentThreadId (..)
  , CommentId (..)
  , NotificationId (..)
  )
where

import Data.Aeson (FromJSON, FromJSONKey, ToJSON, ToJSONKey)
import Protolude
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)

-- | A space's identity, which stays when the space is renamed or moved.
newtype SpaceId = SpaceId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A page's identity, which stays when the page is renamed or moved.
newtype PageId = PageId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | An attachment's identity, unique within the wiki.
newtype AttachmentId = AttachmentId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | Where the server keeps an attachment's bytes (a content hash, once there
-- is a server). The demo has no blobs: its attachments are URLs.
newtype BlobId = BlobId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A user's identity, which stays when they change their login or name.
newtype UserId = UserId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A group's identity, which stays when the group is renamed.
newtype GroupId = GroupId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | An invitation's identity, by which the administration lists and
-- revokes it: not the secret its link carries, which only the person
-- invited is given.
newtype InvitationId = InvitationId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A thread of comments on a page ("Wiki.Core.Comment"), unique within the
-- wiki.
newtype CommentThreadId = CommentThreadId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A comment in a thread, unique within the wiki.
newtype CommentId = CommentId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | A notification of something that happened to a page someone watches
-- ("Wiki.Core.Notification"), unique within the wiki.
newtype NotificationId = NotificationId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)
