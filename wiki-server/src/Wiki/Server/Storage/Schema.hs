{-# LANGUAGE DeriveAnyClass #-}

-- | 'Schema' is the wiki's database schema as Beam sees it: one record
-- type per table, and 'WikiDb', the database of all of them. Every query of
-- the storage is written against these types, so a query that names a
-- column that is not there, or compares a column with a value of another
-- type, does not compile.
--
-- The tables themselves are made by the schema files
-- (@migrations\/0001-initial.sqlite.sql@ and
-- @migrations\/0001-initial.postgres.sql@, "Wiki.Server.Storage.Migrate").
-- A table here has the columns of the table there, in any order, with
-- the types Beam reads and writes on both backends: 'Text', 'Int32' for
-- an @INTEGER@, 'Int64' for a @BIGINT@ (and SQLite's 64-bit integers),
-- 'Bool' and 'UTCTime'. A nullable column is a 'Maybe'.
--
-- A field is named as its column is, in snake case, because Beam names a
-- column after its field: a field with an underscore in its name is a
-- column of that very name. Each table type is named after its table, and
-- its constructor after one of its rows (@Users@, @UserRow@), so that a
-- row is not taken for the domain's record of the same thing
-- ("Wiki.Core.User"'s 'Wiki.Core.User.User').
--
-- Beam needs a primary key for each table. Where the table has none, as
-- the grants and the watches, the key given here is only what Beam asks
-- for: the storage never looks a row up by it.
module Wiki.Server.Storage.Schema
  ( -- * The database
    WikiDb (..)
  , wikiDb

    -- * People
  , Users (..)
  , Groups (..)
  , GroupMembers (..)
  , GlobalGrants (..)
  , SpaceGrants (..)
  , Sessions (..)
  , Invitations (..)
  , Identities (..)
  , Totp (..)
  , RecoveryCodes (..)
  , ResetTokens (..)
  , EmailVerifications (..)
  , Passkeys (..)
  , AssistantVaults (..)

    -- * The wiki
  , Spaces (..)
  , Pages (..)
  , PageNodes (..)
  , nodeColumns
  , PageVersions (..)
  , Attachments (..)
  , Drafts (..)
  , Threads (..)
  , Comments (..)
  , Watches (..)
  , Notifications (..)

    -- * Settings and the log
  , Settings (..)
  , SignInProviders (..)
  , AuditLog (..)

    -- * Bookkeeping
  , WikiSchema (..)
  , SchemaDb (..)
  , schemaDb
  , PrimaryKey (..)
  )
where

import Data.Time (UTCTime)
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Generic, Table (..), TableEntity, defaultDbSettings)
import Protolude hiding (Generic)

--------------------------------------------------------------------------------
-- People

-- | A user (@users@): their login, name, password hash, whether they are
-- disabled, their e-mail address, and how they are told of what happens.
data Users f = UserRow
  { id :: Columnar f Text
  , login :: Columnar f Text
  , display_name :: Columnar f Text
  , password_hash :: Columnar f (Maybe Text)
  , disabled :: Columnar f Bool
  , email :: Columnar f (Maybe Text)
  , email_verified_at :: Columnar f (Maybe UTCTime)
  , notification_mail :: Columnar f (Maybe Text)
  , watch_own :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Users where
  newtype PrimaryKey Users f = UserKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = UserKey r.id

-- | A group (@groups@).
data Groups f = GroupRow
  { id :: Columnar f Text
  , name :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Groups where
  newtype PrimaryKey Groups f = GroupKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = GroupKey r.id

-- | A user's membership of a group (@group_members@).
data GroupMembers f = MemberRow
  { group_id :: Columnar f Text
  , user_id :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table GroupMembers where
  data PrimaryKey GroupMembers f = MemberKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = MemberKey r.group_id r.user_id

-- | A global grant (@global_grants@), to a user or a group. @seq@ is the
-- order the grants were given in; the database numbers a new grant.
data GlobalGrants f = GlobalGrantRow
  { seq :: Columnar f Int64
  , subject_kind :: Columnar f Text
  , subject_id :: Columnar f Text
  , permission :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table GlobalGrants where
  newtype PrimaryKey GlobalGrants f = GlobalGrantKey (Columnar f Int64)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = GlobalGrantKey r.seq

-- | A grant on a space (@space_grants@), numbered as a global grant is.
data SpaceGrants f = SpaceGrantRow
  { seq :: Columnar f Int64
  , space_id :: Columnar f Text
  , subject_kind :: Columnar f Text
  , subject_id :: Columnar f Text
  , permission :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SpaceGrants where
  newtype PrimaryKey SpaceGrants f = SpaceGrantKey (Columnar f Int64)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SpaceGrantKey r.seq

-- | A session (@sessions@), by the hash of its cookie's id.
data Sessions f = SessionRow
  { id_hash :: Columnar f Text
  , user_id :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , last_seen_at :: Columnar f UTCTime
  , expires_at :: Columnar f UTCTime
  , public_id :: Columnar f Text
  , address :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Sessions where
  newtype PrimaryKey Sessions f = SessionKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SessionKey r.id_hash

-- | An invitation (@invitations@), by the hash of its link's secret.
data Invitations f = InvitationRow
  { id :: Columnar f Text
  , email :: Columnar f Text
  , token_hash :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , expires_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Invitations where
  newtype PrimaryKey Invitations f = InvitationKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = InvitationKey r.id

-- | An account at a provider that signs a user in (@identities@).
data Identities f = IdentityRow
  { provider :: Columnar f Text
  , subject :: Columnar f Text
  , user_id :: Columnar f Text
  , email :: Columnar f (Maybe Text)
  , display_name :: Columnar f (Maybe Text)
  , linked_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Identities where
  data PrimaryKey Identities f = IdentityKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = IdentityKey r.provider r.subject

-- | A user's TOTP second factor (@totp@).
data Totp f = TotpRow
  { user_id :: Columnar f Text
  , secret :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , enabled_at :: Columnar f (Maybe UTCTime)
  , last_counter :: Columnar f (Maybe Int64)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Totp where
  newtype PrimaryKey Totp f = TotpKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = TotpKey r.user_id

-- | A recovery code of a second factor (@recovery_codes@), by its hash.
data RecoveryCodes f = RecoveryCodeRow
  { user_id :: Columnar f Text
  , code_hash :: Columnar f Text
  , used_at :: Columnar f (Maybe UTCTime)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table RecoveryCodes where
  data PrimaryKey RecoveryCodes f = RecoveryCodeKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = RecoveryCodeKey r.user_id r.code_hash

-- | A password reset's link (@reset_tokens@), by the hash of its secret.
data ResetTokens f = ResetTokenRow
  { token_hash :: Columnar f Text
  , user_id :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , expires_at :: Columnar f UTCTime
  , used_at :: Columnar f (Maybe UTCTime)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table ResetTokens where
  newtype PrimaryKey ResetTokens f = ResetTokenKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = ResetTokenKey r.token_hash

-- | A link that verifies an e-mail address (@email_verifications@).
data EmailVerifications f = EmailVerificationRow
  { token_hash :: Columnar f Text
  , user_id :: Columnar f Text
  , email :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , expires_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table EmailVerifications where
  newtype PrimaryKey EmailVerifications f = EmailVerificationKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = EmailVerificationKey r.token_hash

-- | A user's passkey (@passkeys@), by its credential's id in base64url,
-- with its public key (base64url too) and the vault key wrapped for it
-- ("Wiki.Server.Vault").
data Passkeys f = PasskeyRow
  { credential_id :: Columnar f Text
  , user_id :: Columnar f Text
  , public_key :: Columnar f Text
  , algorithm :: Columnar f Int32
  , sign_count :: Columnar f Int64
  , name :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , last_used_at :: Columnar f (Maybe UTCTime)
  , wrapped_nonce :: Columnar f (Maybe Text)
  , wrapped_key :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Passkeys where
  newtype PrimaryKey Passkeys f = PasskeyKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PasskeyKey r.credential_id

-- | A user's vault of the writing assistant's settings
-- (@assistant_vaults@), sealed by their browser.
data AssistantVaults f = VaultRow
  { user_id :: Columnar f Text
  , format :: Columnar f Int32
  , salt :: Columnar f Text
  , nonce :: Columnar f Text
  , ciphertext :: Columnar f Text
  , revision :: Columnar f Int64
  , updated_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table AssistantVaults where
  newtype PrimaryKey AssistantVaults f = VaultKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = VaultKey r.user_id

--------------------------------------------------------------------------------
-- The wiki

-- | A space (@spaces@): its place in the tree, its settings and its
-- profile. @icon@ is the icon as JSON.
data Spaces f = SpaceRow
  { id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , name :: Columnar f Text
  , slug :: Columnar f Text
  , public :: Columnar f Bool
  , math_macros :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , subspace_order :: Columnar f Text
  , page_order :: Columnar f Text
  , home_page :: Columnar f (Maybe Text)
  , icon :: Columnar f (Maybe Text)
  , description :: Columnar f Text
  , blog :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Spaces where
  newtype PrimaryKey Spaces f = SpaceKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SpaceKey r.id

-- | A page as it is now (@pages@), with the text a search reads.
-- PostgreSQL's table has one more column, @search_words@, which the
-- database makes from @search_fold@; only PostgreSQL's search reads it
-- ("Wiki.Server.Storage.Postgres").
data Pages f = PageRow
  { id :: Columnar f Text
  , space_id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , title :: Columnar f Text
  , slug :: Columnar f Text
  , body :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , updated_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , template :: Columnar f Bool
  , search_text :: Columnar f Text
  , search_fold :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Pages where
  newtype PrimaryKey Pages f = PageKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PageKey r.id

-- | 'PageNodes' is a page's columns without its text: its place in its
-- space's tree, its title, and whether it is a template. A query that
-- needs to know where pages are, not what they say, reads these
-- ('nodeColumns') instead of whole rows, whose bodies may be large.
data PageNodes f = PageNodeCols
  { id :: Columnar f Text
  , space_id :: Columnar f Text
  , parent :: Columnar f (Maybe Text)
  , title :: Columnar f Text
  , slug :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , position :: Columnar f Int32
  , template :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

-- | A page's 'PageNodes' columns.
nodeColumns :: Pages f -> PageNodes f
nodeColumns p =
  PageNodeCols
    { id = p.id
    , space_id = p.space_id
    , parent = p.parent
    , title = p.title
    , slug = p.slug
    , created_at = p.created_at
    , position = p.position
    , template = p.template
    }

-- | A version of a page (@page_versions@), by its page and its time.
data PageVersions f = VersionRow
  { page_id :: Columnar f Text
  , updated_at :: Columnar f UTCTime
  , title :: Columnar f Text
  , body :: Columnar f Text
  , author :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PageVersions where
  data PrimaryKey PageVersions f = VersionKey (Columnar f Text) (Columnar f UTCTime)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = VersionKey r.page_id r.updated_at

-- | An attachment (@attachments@): on the web (@url@) or in the blob
-- store (@blob@).
data Attachments f = AttachmentRow
  { id :: Columnar f Text
  , page_id :: Columnar f Text
  , name :: Columnar f Text
  , media_type :: Columnar f Text
  , size :: Columnar f Int64
  , url :: Columnar f (Maybe Text)
  , blob :: Columnar f (Maybe Text)
  , ordinal :: Columnar f Int32
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Attachments where
  newtype PrimaryKey Attachments f = AttachmentKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = AttachmentKey r.id

-- | An author's draft of a page (@drafts@).
data Drafts f = DraftRow
  { page_id :: Columnar f Text
  , author :: Columnar f Text
  , title :: Columnar f Text
  , body :: Columnar f Text
  , base :: Columnar f UTCTime
  , saved_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Drafts where
  data PrimaryKey Drafts f = DraftKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = DraftKey r.page_id r.author

-- | A thread of comments on a page (@threads@).
data Threads f = ThreadRow
  { id :: Columnar f Text
  , page_id :: Columnar f Text
  , quote :: Columnar f (Maybe Text)
  , prefix :: Columnar f (Maybe Text)
  , suffix :: Columnar f (Maybe Text)
  , resolved :: Columnar f Bool
  , created_at :: Columnar f UTCTime
  , seq :: Columnar f Int32
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Threads where
  newtype PrimaryKey Threads f = ThreadKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = ThreadKey r.id

-- | A comment in a thread (@comments@).
data Comments f = CommentRow
  { id :: Columnar f Text
  , thread_id :: Columnar f Text
  , author :: Columnar f Text
  , body :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , edited_at :: Columnar f (Maybe UTCTime)
  , seq :: Columnar f Int32
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Comments where
  newtype PrimaryKey Comments f = CommentKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = CommentKey r.id

-- | A user's choice to watch a page or a space, or not to (@watches@).
data Watches f = WatchRow
  { user_id :: Columnar f Text
  , page_id :: Columnar f (Maybe Text)
  , space_id :: Columnar f (Maybe Text)
  , watching :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Watches where
  data PrimaryKey Watches f = WatchKey (Columnar f Text) (Columnar f (Maybe Text)) (Columnar f (Maybe Text))
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = WatchKey r.user_id r.page_id r.space_id

-- | A notification (@notifications@). @seq@ is its place among all
-- notifications; the database numbers a new one.
data Notifications f = NotificationRow
  { seq :: Columnar f Int64
  , id :: Columnar f Text
  , user_id :: Columnar f Text
  , kind :: Columnar f Text
  , page_id :: Columnar f Text
  , thread_id :: Columnar f (Maybe Text)
  , actor :: Columnar f Text
  , actor_name :: Columnar f Text
  , title :: Columnar f Text
  , excerpt :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , read_at :: Columnar f (Maybe UTCTime)
  , mail :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Notifications where
  newtype PrimaryKey Notifications f = NotificationKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = NotificationKey r.id

--------------------------------------------------------------------------------
-- Settings and the log

-- | A setting (@settings@), by its name.
data Settings f = SettingRow
  { key :: Columnar f Text
  , value :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Settings where
  newtype PrimaryKey Settings f = SettingKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SettingKey r.key

-- | A provider people sign in with (@sign_in_providers@).
data SignInProviders f = ProviderRow
  { name :: Columnar f Text
  , position :: Columnar f Int32
  , kind :: Columnar f Text
  , client_id :: Columnar f Text
  , issuer :: Columnar f (Maybe Text)
  , secret :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SignInProviders where
  newtype PrimaryKey SignInProviders f = ProviderKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = ProviderKey r.name

-- | An entry of the audit log (@audit_log@). @detail@ is a JSON object.
data AuditLog f = AuditRow
  { id :: Columnar f Text
  , at :: Columnar f UTCTime
  , actor_id :: Columnar f Text
  , actor_login :: Columnar f Text
  , action :: Columnar f Text
  , subject_kind :: Columnar f Text
  , subject_id :: Columnar f (Maybe Text)
  , subject_name :: Columnar f Text
  , detail :: Columnar f Text
  , address :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table AuditLog where
  newtype PrimaryKey AuditLog f = AuditKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = AuditKey r.id


--------------------------------------------------------------------------------
-- Rows as values

-- A row read back is a plain value. Tests compare rows and show the ones
-- that differ, so each table's row type can be compared and shown.
deriving stock instance Eq (Users Identity)

deriving stock instance Show (Users Identity)

deriving stock instance Eq (Groups Identity)

deriving stock instance Show (Groups Identity)

deriving stock instance Eq (GroupMembers Identity)

deriving stock instance Show (GroupMembers Identity)

deriving stock instance Eq (GlobalGrants Identity)

deriving stock instance Show (GlobalGrants Identity)

deriving stock instance Eq (SpaceGrants Identity)

deriving stock instance Show (SpaceGrants Identity)

deriving stock instance Eq (Sessions Identity)

deriving stock instance Show (Sessions Identity)

deriving stock instance Eq (Invitations Identity)

deriving stock instance Show (Invitations Identity)

deriving stock instance Eq (Identities Identity)

deriving stock instance Show (Identities Identity)

deriving stock instance Eq (Totp Identity)

deriving stock instance Show (Totp Identity)

deriving stock instance Eq (RecoveryCodes Identity)

deriving stock instance Show (RecoveryCodes Identity)

deriving stock instance Eq (ResetTokens Identity)

deriving stock instance Show (ResetTokens Identity)

deriving stock instance Eq (Passkeys Identity)

deriving stock instance Show (Passkeys Identity)

deriving stock instance Eq (AssistantVaults Identity)

deriving stock instance Show (AssistantVaults Identity)

deriving stock instance Eq (EmailVerifications Identity)

deriving stock instance Show (EmailVerifications Identity)

deriving stock instance Eq (Spaces Identity)

deriving stock instance Show (Spaces Identity)

deriving stock instance Eq (Pages Identity)

deriving stock instance Show (Pages Identity)

deriving stock instance Eq (PageVersions Identity)

deriving stock instance Show (PageVersions Identity)

deriving stock instance Eq (Attachments Identity)

deriving stock instance Show (Attachments Identity)

deriving stock instance Eq (Drafts Identity)

deriving stock instance Show (Drafts Identity)

deriving stock instance Eq (Threads Identity)

deriving stock instance Show (Threads Identity)

deriving stock instance Eq (Comments Identity)

deriving stock instance Show (Comments Identity)

deriving stock instance Eq (Watches Identity)

deriving stock instance Show (Watches Identity)

deriving stock instance Eq (Notifications Identity)

deriving stock instance Show (Notifications Identity)

deriving stock instance Eq (Settings Identity)

deriving stock instance Show (Settings Identity)

deriving stock instance Eq (SignInProviders Identity)

deriving stock instance Show (SignInProviders Identity)

deriving stock instance Eq (AuditLog Identity)

deriving stock instance Show (AuditLog Identity)

deriving stock instance Eq (WikiSchema Identity)

deriving stock instance Show (WikiSchema Identity)

--------------------------------------------------------------------------------
-- The database

-- | 'WikiDb' is every table of the wiki's database, as Beam sees it.
data WikiDb f = WikiDb
  { users :: f (TableEntity Users)
  , groups :: f (TableEntity Groups)
  , group_members :: f (TableEntity GroupMembers)
  , global_grants :: f (TableEntity GlobalGrants)
  , space_grants :: f (TableEntity SpaceGrants)
  , sessions :: f (TableEntity Sessions)
  , invitations :: f (TableEntity Invitations)
  , identities :: f (TableEntity Identities)
  , totp :: f (TableEntity Totp)
  , recovery_codes :: f (TableEntity RecoveryCodes)
  , reset_tokens :: f (TableEntity ResetTokens)
  , email_verifications :: f (TableEntity EmailVerifications)
  , passkeys :: f (TableEntity Passkeys)
  , assistant_vaults :: f (TableEntity AssistantVaults)
  , spaces :: f (TableEntity Spaces)
  , pages :: f (TableEntity Pages)
  , page_versions :: f (TableEntity PageVersions)
  , attachments :: f (TableEntity Attachments)
  , drafts :: f (TableEntity Drafts)
  , threads :: f (TableEntity Threads)
  , comments :: f (TableEntity Comments)
  , watches :: f (TableEntity Watches)
  , notifications :: f (TableEntity Notifications)
  , settings :: f (TableEntity Settings)
  , sign_in_providers :: f (TableEntity SignInProviders)
  , audit_log :: f (TableEntity AuditLog)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

-- | The wiki's tables, named as the schema files name them.
wikiDb :: DatabaseSettings be WikiDb
wikiDb = defaultDbSettings

--------------------------------------------------------------------------------
-- Bookkeeping

-- | The versions of the schema a database has had (@wiki_schema@), one row
-- for each step "Wiki.Server.Storage.Migrate" applied. Its name is not the
-- @schema_version@ of the wiki-servers before WP5.22 of docs/PLAN.md, so
-- that a database of theirs is told apart from a database of this one.
data WikiSchema f = SchemaRow
  { version :: Columnar f Int32
  , applied_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table WikiSchema where
  newtype PrimaryKey WikiSchema f = SchemaKey (Columnar f Int32)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SchemaKey r.version

-- | 'SchemaDb' is the one table that records the schema's versions. It is
-- apart from 'WikiDb' because it exists before the wiki's tables do.
newtype SchemaDb f = SchemaDb
  { wiki_schema :: f (TableEntity WikiSchema)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

schemaDb :: DatabaseSettings be SchemaDb
schemaDb = defaultDbSettings
