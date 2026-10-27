-- | Identifiers of the records the wiki stores.
--
-- Each is a newtype over 'Text', so a page's id cannot be passed where a
-- space's id is expected. Each is encoded in JSON as the bare text, also
-- as an object key (membership is a map keyed by 'GroupId'). The format of
-- the text, and how a new one is generated, is up to the backend: the
-- in-memory backend uses a counter, the server may use UUIDs. Nothing here
-- parses an id, so the constructors are exported for the backends to
-- construct them. In a URL (a path segment or a query parameter of the
-- server's API) each is also the bare text.
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

-- | 'SpaceId': a space's id, which stays the same when the space is renamed or moved.
newtype SpaceId = SpaceId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'PageId': a page's id, which stays the same when the page is renamed or moved.
newtype PageId = PageId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'AttachmentId': an attachment's id, unique within the wiki.
newtype AttachmentId = AttachmentId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'BlobId': the name an attachment's bytes are stored under. On the
-- server it is the bytes' SHA-256 hash ("Wiki.Server.Storage.Blobs"); the
-- in-memory backend uses a counter.
newtype BlobId = BlobId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'UserId': a user's id, which stays the same when they change their login or name.
newtype UserId = UserId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'GroupId': a group's id, which stays the same when the group is renamed.
newtype GroupId = GroupId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'InvitationId': an invitation's id, which the administration lists and
-- revokes it by. It is not the secret in the invitation's link, which only
-- the invited person receives.
newtype InvitationId = InvitationId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'CommentThreadId': the id of a thread of comments on a page
-- ("Wiki.Core.Comment"), unique within the wiki.
newtype CommentThreadId = CommentThreadId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'CommentId': the id of a comment in a thread, unique within the wiki.
newtype CommentId = CommentId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)

-- | 'NotificationId': the id of a notification about a change to a page a
-- user watches ("Wiki.Core.Notification"), unique within the wiki.
newtype NotificationId = NotificationId {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromJSONKey, ToJSONKey, FromHttpApiData, ToHttpApiData)
