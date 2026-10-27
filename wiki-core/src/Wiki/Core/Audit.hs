-- | The wiki's audit log (WP4.10 of docs/PLAN.md): who did what to the
-- wiki's administration, when, to what, and from where. The server writes
-- one entry for each administration write, in the transaction of the
-- write; the administration's "Activity" lists them, newest first; and an
-- export of the wiki carries them ("Wiki.Core.Export"'s @audit.json@), so
-- that the log moves with the wiki.
--
-- An entry names everything it is about by name as well as by id, as they
-- were when it was written: the log is read long after, when the user who
-- acted, or the space that was deleted, may be gone, and when an import has
-- brought in entries of another wiki, whose ids mean nothing here.
--
-- What a write changed is in the entry's 'detail', words for a person to
-- read, by field. A secret is never one of them: a password, a client
-- secret or a configuration that was changed is recorded as changed, not
-- as what it became.
module Wiki.Core.Audit
  ( -- * Entries
    AuditEntry (..)
  , Actor (..)
  , Subject (..)

    -- * Actions
  , actionText

    -- * Records
  , encodeAuditEntry
  , parseAuditEntry
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id (UserId (..))

-- | One administration write.
data AuditEntry = AuditEntry
  { id :: Text
  -- ^ Its own id: a UUID, which an import keeps, so that the same entry
  -- brought in twice is there once.
  , at :: UTCTime
  , actor :: Actor
  , action :: Text
  -- ^ What was done, as a dotted name: @space.delete@, @user.password@
  -- ('actionText' puts it in words).
  , subject :: Subject
  , detail :: Map Text Text
  -- ^ What changed, by field, in words: never a secret.
  , address :: Text
  -- ^ The network address the request came from, or @console@ for the
  -- server's console; empty where it is not known.
  }
  deriving stock (Eq, Show)

-- | Who did it: a user by id and login, or the server's operator (the
-- admin listener's, and the console's), whose id is no user's.
data Actor = Actor
  { id :: UserId
  , login :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | What it was done to: its kind (@space@, @page@, @user@, @group@,
-- @invitation@, @settings@, @wiki@), its id if it has one, and its name as
-- it was.
data Subject = Subject
  { kind :: Text
  , id :: Maybe Text
  , name :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON AuditEntry where
  toJSON = encodeAuditEntry

instance FromJSON AuditEntry where
  parseJSON = parseAuditEntry

instance ToJSON Actor where
  toJSON a = object ["id" .= a.id.text, "login" .= a.login]

instance FromJSON Actor where
  parseJSON = withObject "actor" $ \o -> Actor <$> (UserId <$> o .: "id") <*> o .: "login"

-- | An action in words, for the administration's list: the action's own
-- name for one this program does not know (one an archive brought from a
-- newer program).
actionText :: Text -> Text
actionText a = Map.findWithDefault a a actions
  where
    actions =
      Map.fromList
        [ ("space.delete", "Deleted a space")
        , ("space.public", "Changed whether a space is public")
        , ("space.profile", "Changed a space's description, icon, home page or blog")
        , ("space.grant", "Granted a permission on a space")
        , ("space.revoke", "Took a permission on a space away")
        , ("page.delete", "Deleted a page")
        , ("user.create", "Made a user")
        , ("user.register", "Made themself an account")
        , ("user.administrator", "Changed whether a user is an administrator")
        , ("user.create-spaces", "Changed whether a user creates spaces")
        , ("user.password", "Gave a user a new password")
        , ("user.password-link", "Mailed a user a link to choose a password")
        , ("user.disable", "Disabled a user's login")
        , ("user.enable", "Enabled a user's login")
        , ("user.second-factor-remove", "Removed a user's second factor")
        , ("user.identity-remove", "Disconnected a user's account at a provider")
        , ("group.create", "Made a group")
        , ("group.rename", "Renamed a group")
        , ("group.delete", "Deleted a group")
        , ("group.member-add", "Put a user in a group")
        , ("group.member-remove", "Took a user out of a group")
        , ("settings.wiki", "Changed whom the wiki lets in")
        , ("settings.server", "Changed the server's settings")
        , ("settings.backups", "Changed the backups' settings")
        , ("invitation.create", "Invited someone")
        , ("invitation.revoke", "Revoked an invitation")
        , ("invitation.accept", "Accepted an invitation")
        , ("wiki.import", "Imported a wiki")
        ]

-- | @{"id", "at", "actor": {"id", "login"}, "action", "subject": {"kind",
-- "id", "name"}, "detail": {…}, "address"}@, written by hand as every
-- record of an archive is ("Wiki.Core.Export"): the subject's @id@ is
-- @null@ for what has none, @detail@ an object of texts (empty if
-- missing), @address@ empty if missing.
encodeAuditEntry :: AuditEntry -> Value
encodeAuditEntry e =
  object
    [ "id" .= e.id
    , "at" .= e.at
    , "actor" .= e.actor
    , "action" .= e.action
    , "subject" .= object ["kind" .= e.subject.kind, "id" .= e.subject.id, "name" .= e.subject.name]
    , "detail" .= e.detail
    , "address" .= e.address
    ]

parseAuditEntry :: Value -> Parser AuditEntry
parseAuditEntry = withObject "audit entry" $ \o -> do
  id <- o .: "id"
  at <- o .: "at"
  actor <- o .: "actor"
  action <- o .: "action"
  subject <- o .: "subject" >>= withObject "subject" (\s -> Subject <$> s .: "kind" <*> s .:? "id" <*> s .:? "name" .!= "")
  detail <- o .:? "detail" .!= mempty
  address <- o .:? "address" .!= ""
  pure AuditEntry {id, at, actor, action, subject, detail, address}
