-- | 'Wiki.Server.Storage.Check' reads every row of every table of the
-- database through the storage's own row decoders: the first half of
-- @wiki-server check@, which the deploy runs after a migration to find a
-- row the new program cannot read before the new server serves it (WP5.73
-- of docs/PLAN.md). The second half, the wiki's records built from those
-- rows, is "Wiki.Server.Storage"'s 'Wiki.Server.Storage.checkDatabase'.
--
-- Each table is read on its own, so that a table that does not read is
-- named with why, and the others are still read and counted.
module Wiki.Server.Storage.Check
  ( TableRead (..)
  , readEveryTable
  )
where

import Database.Beam (Beamable, DatabaseEntity, FromBackendRow, TableEntity, all_, runSelectReturningList, select)
import Protolude
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Schema (WikiDb (..), wikiDb)

-- | 'TableRead' is one table as the check read it: its name, and how many
-- rows it read, or why a row did not read (the decoder's or the database's
-- message).
data TableRead = TableRead
  { table :: Text
  , rows :: Either Text Int
  }
  deriving stock (Eq, Show)

-- | Every table of the wiki's schema, each read whole on the connection.
-- The schema's own table of versions is not among them: the check reads it
-- first, to know the database is at this program's version.
readEveryTable :: forall be. (Backend be) => Connection be -> IO [TableRead]
readEveryTable c =
  sequence
    [ counted "users" wikiDb.users
    , counted "groups" wikiDb.groups
    , counted "group_members" wikiDb.group_members
    , counted "global_grants" wikiDb.global_grants
    , counted "space_grants" wikiDb.space_grants
    , counted "sessions" wikiDb.sessions
    , counted "invitations" wikiDb.invitations
    , counted "identities" wikiDb.identities
    , counted "totp" wikiDb.totp
    , counted "recovery_codes" wikiDb.recovery_codes
    , counted "reset_tokens" wikiDb.reset_tokens
    , counted "email_verifications" wikiDb.email_verifications
    , counted "passkeys" wikiDb.passkeys
    , counted "assistant_vaults" wikiDb.assistant_vaults
    , counted "spaces" wikiDb.spaces
    , counted "pages" wikiDb.pages
    , counted "page_versions" wikiDb.page_versions
    , counted "attachments" wikiDb.attachments
    , counted "drafts" wikiDb.drafts
    , counted "threads" wikiDb.threads
    , counted "comments" wikiDb.comments
    , counted "watches" wikiDb.watches
    , counted "stars" wikiDb.stars
    , counted "notifications" wikiDb.notifications
    , counted "settings" wikiDb.settings
    , counted "sign_in_providers" wikiDb.sign_in_providers
    , counted "audit_log" wikiDb.audit_log
    , counted "permissions_generation" wikiDb.permissions_generation
    ]
  where
    counted
      :: (Beamable t, FromBackendRow be (t Identity))
      => Text
      -> DatabaseEntity be WikiDb (TableEntity t)
      -> IO TableRead
    counted name entity =
      TableRead name . first (toS . displayException) <$> try @SomeException (runDb c (length <$> runSelectReturningList (select (all_ entity))))
