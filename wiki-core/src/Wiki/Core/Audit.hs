-- | The wiki's audit log (WP4.10 of docs/PLAN.md): who changed the wiki's
-- administration, when, what they changed, and from which address. The
-- server writes one entry for each administration write, in the write's
-- transaction. The administration's "Activity" page lists the entries,
-- newest first. An export of the wiki includes them ("Wiki.Core.Export"'s
-- @audit.json@), so that the log moves with the wiki.
--
-- An entry stores every user, space or other subject by name as well as
-- by id, as the names were when the entry was written. The log is read
-- long afterwards, when the user who acted, or the space that was deleted,
-- may no longer exist, and an import may have brought in entries from
-- another wiki, whose ids mean nothing here.
--
-- What a write changed is in the entry's 'detail': text for a person to
-- read, by field. A secret is never stored there: a changed password,
-- client secret or configuration is recorded as changed, without its new
-- value.
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
import Wiki.Core.User (Login (..))

-- | 'AuditEntry': one administration write.
data AuditEntry = AuditEntry
  { id :: Text
  -- ^ Its own id: a UUID, which an import keeps, so that importing the
  -- same entry twice stores it once.
  , at :: UTCTime
  , actor :: Actor
  , action :: Text
  -- ^ What was done, as a dotted name: @space.delete@, @user.password@
  -- ('actionText' turns it into words).
  , subject :: Subject
  , detail :: Map Text Text
  -- ^ What changed, by field, as text: never a secret.
  , address :: Text
  -- ^ The network address the request came from, or @console@ for the
  -- server's console; empty when unknown.
  }
  deriving stock (Eq, Show)

-- | 'Actor': who made the write. Either a user, by id and login, or the
-- server's operator (on the admin listener or the console), whose id
-- belongs to no user.
data Actor = Actor
  { id :: UserId
  , login :: Login
  }
  deriving stock (Eq, Ord, Show)

-- | 'Subject': what the write changed. Its kind (@space@, @page@, @user@,
-- @group@, @invitation@, @settings@, @wiki@), its id if it has one, and
-- its name at the time.
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

-- | An action in words, for the administration's list. An action this
-- program does not know (one an archive brought from a newer version of
-- the program) is shown as its dotted name.
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
        , ("user.remove", "Removed a user's account")
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
        , ("guide.install", "Installed the guide")
        , ("guide.update", "Updated the guide's pages")
        ]

-- | @{"id", "at", "actor": {"id", "login"}, "action", "subject": {"kind",
-- "id", "name"}, "detail": {…}, "address"}@, written by hand as every
-- record of an archive is ("Wiki.Core.Export"). The subject's @id@ is
-- @null@ for a subject without one, @detail@ is an object of texts (empty
-- if missing), and @address@ is empty if missing.
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
