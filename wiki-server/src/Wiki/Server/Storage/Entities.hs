{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The users, groups and grants as @persistent@ entities (WP5.7 of
-- docs/PLAN.md, a spike): the same tables the migrations make, described
-- once, so that the reads and writes of them ("Wiki.Server.Storage.Rows")
-- are written against a 'Database.Persist.Sql.SqlBackend' and run alike on
-- SQLite and PostgreSQL.
--
-- The entities describe tables that exist; nothing here makes or changes
-- one. The schema stays the hand-written, numbered migrations
-- ("Wiki.Server.Storage.Migrate"), and no @mkMigrate@ is generated, so
-- persistent never compares or alters it.
--
-- Fields are not prefixed with their entity's name, so a row reads as
-- @row.login@ with @OverloadedRecordDot@ and @NoFieldSelectors@ as the rest
-- of the server does; the fields' constructors, which esqueleto and the
-- filters name, keep their prefix (@UserRowLogin@). Entities are named
-- @…Row@ so as not to take the names of the domain's types ('User',
-- 'Group'), which the reads build from them.
module Wiki.Server.Storage.Entities
  ( -- * Columns
    Stamp (..)

    -- * The entities
  , UserRow (..)
  , GroupRow (..)
  , GroupMemberRow (..)
  , GlobalGrantRow (..)
  , SpaceGrantRow (..)
  , IdentityEntity (..)
  , SessionRow (..)
  , TotpRow (..)
  , RecoveryCodeRow (..)
  , EntityField (..)
  , Key (..)
  , Unique (..)
  )
where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Database.Persist (EntityField, Key, PersistField (..), PersistValue (..), Unique)
import Database.Persist.Sql (PersistFieldSql (..), SqlType (..))
import Database.Persist.TH (MkPersistSettings (..), mkPersistWith, persistLowerCase, share, sqlSettings)
import Database.SQLite.Simple.FromField (FromField (..), ResultError (..), returnError)
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude

--------------------------------------------------------------------------------
-- Columns

-- | A time as a column: ISO 8601 text in UTC with every digit of the
-- fraction of a second there is. Not sqlite-simple's own 'UTCTime' columns,
-- because a save is checked against the time it started from by equality,
-- so a time must come back exactly as it went in, which nothing but every
-- digit promises. The same text on PostgreSQL, whose @timestamptz@ keeps
-- microseconds only.
newtype Stamp = Stamp UTCTime
  deriving stock (Eq, Show)

instance ToField Stamp where
  toField (Stamp t) = toField (T.pack (iso8601Show t))

instance FromField Stamp where
  fromField f =
    fromField f >>= \t -> case iso8601ParseM (T.unpack t) of
      Just time -> pure (Stamp time)
      Nothing -> returnError ConversionFailed f ("not a time: " <> T.unpack t)

instance PersistField Stamp where
  toPersistValue (Stamp t) = PersistText (T.pack (iso8601Show t))
  fromPersistValue = \case
    PersistText t -> maybe (Left ("not a time: " <> t)) (Right . Stamp) (iso8601ParseM (T.unpack t))
    other -> Left ("not a time: " <> show other)

instance PersistFieldSql Stamp where
  sqlType _ = SqlString

--------------------------------------------------------------------------------
-- The entities

-- The settings: unprefixed fields (see the module's Haddock), and no lenses
-- or JSON instances, which nothing here uses.
share
  [mkPersistWith sqlSettings {mpsFieldLabelModifier = \_ field -> field} []]
  [persistLowerCase|
-- migrations/0001-initial.sql, 0002-accounts.sql, 0008-account-hygiene.sql,
-- 0011-notifications.sql. A user's id is the domain's UserId, text.
UserRow sql=users
  Id Text sql=id
  login Text
  displayName Text
  passwordHash Text Maybe
  disabled Bool
  email Text Maybe
  emailVerifiedAt Stamp Maybe
  notificationMail Text Maybe
  watchOwn Bool
  UniqueLogin login

GroupRow sql=groups
  Id Text sql=id
  name Text

GroupMemberRow sql=group_members
  groupId GroupRowId
  userId UserRowId
  Primary groupId userId

-- A grant's key is its row's place among the grants: SQLite's rowid, which
-- the table has without naming it, and a column of that name on PostgreSQL
-- (migrations/postgresql/0001-initial.sql). Grants are read in that order,
-- the order they were given in, which the application shows. The subject is
-- one of two tables (a kind and an id), so no foreign key.
GlobalGrantRow sql=global_grants
  Id sql=rowid
  subjectKind Text
  subjectId Text
  permission Text
  UniqueGlobalGrant subjectKind subjectId permission

-- The space is a foreign key in the schema, to a table that is no entity
-- of the spike's: here its id is text.
SpaceGrantRow sql=space_grants
  Id sql=rowid
  spaceId Text
  subjectKind Text
  subjectId Text
  permission Text
  UniqueSpaceGrant spaceId subjectKind subjectId permission

-- migrations/0004-identities.sql. Rows' IdentityRow is the record the
-- callers read, so this one is the entity.
IdentityEntity sql=identities
  provider Text
  subject Text
  userId UserRowId
  email Text Maybe
  displayName Text Maybe
  linkedAt Stamp
  Primary provider subject
  UniqueIdentityOfUser userId provider

-- migrations/0002-accounts.sql and 0008-account-hygiene.sql: what the
-- accounts' reads and writes touch of a user's sessions and second factor.
SessionRow sql=sessions
  Id Text sql=id_hash
  userId UserRowId
  createdAt Stamp
  lastSeenAt Stamp
  expiresAt Stamp
  publicId Text Maybe
  address Text

TotpRow sql=totp
  userId UserRowId
  secret Text
  createdAt Stamp
  enabledAt Stamp Maybe
  lastCounter Int64 Maybe
  Primary userId

RecoveryCodeRow sql=recovery_codes
  userId UserRowId
  codeHash Text
  usedAt Stamp Maybe
  Primary userId codeHash
|]
