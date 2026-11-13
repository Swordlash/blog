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
  , Vaults (..)
  , VaultItems (..)
  , PublicKeys (..)

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
  , Stars (..)
  , Notifications (..)
  , PageLinks (..)

    -- * Encrypted spaces
  , KeyGrants (..)
  , PageKeys (..)
  , SealedVersions (..)
  , SealedThreads (..)
  , SealedComments (..)
  , SealedAttachments (..)
  , StagedPlain (..)

    -- * Settings and the log
  , Settings (..)
  , SignInProviders (..)
  , AuditLog (..)
  , PermissionsGeneration (..)

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
-- disabled, their e-mail address, how they are told of what happens, and
-- the secret of their feed of notifications (migration
-- @0006-notification-feed@), none until they ask for one, and their
-- avatar's blob and media type (migration @0008-avatars@), none until they
-- upload one, and their OPAQUE record with the stretching it was made with
-- (migration @0009-opaque@), none for an account without one.
-- @password_hash@ is the argon2id hash of an account from before OPAQUE,
-- kept until its next sign-in.
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
  , feed_token :: Columnar f (Maybe Text)
  , avatar_blob :: Columnar f (Maybe Text)
  , avatar_media_type :: Columnar f (Maybe Text)
  , opaque_record :: Columnar f (Maybe Text)
  , opaque_stretch :: Columnar f (Maybe Text)
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

-- | A user's vault (@vaults@, "Wiki.Server.Vault"), sealed by their
-- browser: the salt, the vault key wrapped by the password's key when
-- the user chose that, and the revision that is its tag. Its items are
-- 'VaultItems'; its passkeys' wraps are in 'Passkeys'.
data Vaults f = VaultRow
  { user_id :: Columnar f Text
  , salt :: Columnar f Text
  , password_nonce :: Columnar f (Maybe Text)
  , password_key :: Columnar f (Maybe Text)
  , revision :: Columnar f Int64
  , updated_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Vaults where
  newtype PrimaryKey Vaults f = VaultKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = VaultKey r.user_id

-- | One sealed item of a user's vault (@vault_items@), by name, with the
-- id of the key pair it holds, if it holds one.
data VaultItems f = VaultItemRow
  { user_id :: Columnar f Text
  , name :: Columnar f Text
  , key_id :: Columnar f (Maybe Text)
  , nonce :: Columnar f Text
  , ciphertext :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table VaultItems where
  data PrimaryKey VaultItems f = VaultItemKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = VaultItemKey r.user_id r.name

-- | A user's public key in the directory (@public_keys@): the public half
-- of their key pair, by its id. The current one has no @retired_at@; one
-- replaced keeps its row, with when and why.
data PublicKeys f = PublicKeyRow
  { key_id :: Columnar f Text
  , user_id :: Columnar f Text
  , public_key :: Columnar f Text
  , created_at :: Columnar f UTCTime
  , retired_at :: Columnar f (Maybe UTCTime)
  , retired_because :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PublicKeys where
  newtype PrimaryKey PublicKeys f = PublicKeyKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PublicKeyKey r.key_id

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
  , box_numbering :: Columnar f Text
  -- ^ How its boxes are numbered, by 'Wiki.Core.Markdown.Box.numberingName'.
  , sealed :: Columnar f Bool
  -- ^ Whether it is private from its parent (migration
  -- @0007-sealed-and-personal-spaces@, as are the three below).
  , owner :: Columnar f (Maybe Text)
  -- ^ The user whose personal space it is.
  , active :: Columnar f Bool
  -- ^ Whether a personal space is shown.
  , personal_container :: Columnar f Bool
  -- ^ Whether it is the container of personal spaces.
  , key_id :: Columnar f (Maybe Text)
  -- ^ The id of an encrypted space's current key (migration
  -- @0011-encrypted-spaces@), none for a space of plain pages.
  , conversion :: Columnar f (Maybe Text)
  -- ^ The conversion of its pages under way, by
  -- 'Wiki.Core.Space.conversionName' (step 20), none when none runs.
  , confirm_entry :: Columnar f Bool
  -- ^ Whether a reader confirms with a passkey or the password each time
  -- the space is opened ('Wiki.Core.Space.ConfirmEach', step 21).
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
  , kind :: Columnar f Text
  -- ^ The page's kind by its name ("Wiki.Core.PageKind"), step 19.
  , converted :: Columnar f Bool
  -- ^ Whether the conversion of its space under way has converted it
  -- (step 20): false when none runs.
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

-- | A page a user starred (@stars@, migration @0005-stars@), at its
-- place in the user's list.
data Stars f = StarRow
  { user_id :: Columnar f Text
  , page_id :: Columnar f Text
  , position :: Columnar f Int32
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table Stars where
  data PrimaryKey Stars f = StarKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = StarKey r.user_id r.page_id

-- | A link on a page (@page_links@, migration @0014-page-links@): the
-- page, the link's place among its links, its destination as written,
-- the name a page must have for the link to lead to it once created or
-- moved ('Wiki.App.Route.linkName', its first 200 characters), the page
-- it leads to now, and whether it is to be resolved again before the
-- transaction commits. What a page's backlinks are read from.
data PageLinks f = PageLinkRow
  { source_id :: Columnar f Text
  , ordinal :: Columnar f Int32
  , destination :: Columnar f Text
  , name :: Columnar f (Maybe Text)
  , target_id :: Columnar f (Maybe Text)
  , pending :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PageLinks where
  data PrimaryKey PageLinks f = PageLinkKey (Columnar f Text) (Columnar f Int32)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PageLinkKey r.source_id r.ordinal

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

-- | 'PermissionsGeneration' is the generation of the permission context
-- (@permissions_generation@): one row, with @id@ 1. Its number goes up in
-- every write transaction that changes what a permission check reads, so
-- that a server that keeps the permission context in memory can tell
-- whether the copy in memory is still the database's
-- ("Wiki.Server.Storage", WP5.24 of docs/PLAN.md).
data PermissionsGeneration f = GenerationRow
  { id :: Columnar f Int32
  , generation :: Columnar f Int64
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PermissionsGeneration where
  newtype PrimaryKey PermissionsGeneration f = GenerationKey (Columnar f Int32)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = GenerationKey r.id

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

deriving stock instance Eq (Vaults Identity)

deriving stock instance Show (Vaults Identity)

deriving stock instance Eq (VaultItems Identity)

deriving stock instance Show (VaultItems Identity)

deriving stock instance Eq (PublicKeys Identity)

deriving stock instance Show (PublicKeys Identity)

deriving stock instance Eq (KeyGrants Identity)

deriving stock instance Show (KeyGrants Identity)

deriving stock instance Eq (PageKeys Identity)

deriving stock instance Show (PageKeys Identity)

deriving stock instance Eq (SealedVersions Identity)

deriving stock instance Show (SealedVersions Identity)

deriving stock instance Eq (SealedThreads Identity)

deriving stock instance Show (SealedThreads Identity)

deriving stock instance Eq (SealedComments Identity)

deriving stock instance Show (SealedComments Identity)

deriving stock instance Eq (SealedAttachments Identity)

deriving stock instance Show (SealedAttachments Identity)

deriving stock instance Eq (StagedPlain Identity)

deriving stock instance Show (StagedPlain Identity)

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

deriving stock instance Eq (Stars Identity)

deriving stock instance Show (Stars Identity)

deriving stock instance Eq (PageLinks Identity)

deriving stock instance Show (PageLinks Identity)

deriving stock instance Eq (Notifications Identity)

deriving stock instance Show (Notifications Identity)

deriving stock instance Eq (Settings Identity)

deriving stock instance Show (Settings Identity)

deriving stock instance Eq (SignInProviders Identity)

deriving stock instance Show (SignInProviders Identity)

deriving stock instance Eq (AuditLog Identity)

deriving stock instance Show (AuditLog Identity)

deriving stock instance Eq (PermissionsGeneration Identity)

deriving stock instance Show (PermissionsGeneration Identity)

deriving stock instance Eq (WikiSchema Identity)

deriving stock instance Show (WikiSchema Identity)

--------------------------------------------------------------------------------
-- Encrypted spaces

-- | A key sealed to one user's public key (@key_grants@,
-- "Wiki.Core.Encrypted"'s 'Wiki.Core.Encrypted.KeyGrant'): for now a
-- space's key (@resource_kind@ @space@), by the space's id.
data KeyGrants f = KeyGrantRow
  { resource_kind :: Columnar f Text
  , resource_id :: Columnar f Text
  , key_id :: Columnar f Text
  , recipient :: Columnar f Text
  , recipient_key_id :: Columnar f Text
  , enc :: Columnar f Text
  , sealed :: Columnar f Text
  , created_at :: Columnar f UTCTime
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table KeyGrants where
  data PrimaryKey KeyGrants f = KeyGrantKey (Columnar f Text) (Columnar f Text) (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = KeyGrantKey r.resource_kind r.resource_id r.key_id r.recipient_key_id

-- | A key of a page of an encrypted space (@page_keys@), encrypted with
-- the space's key @space_key_id@. A page has every key it has had, one a
-- rotation of the space's key (migration @0017-space-key-rotation@);
-- @current@ marks the one its next version is encrypted with.
data PageKeys f = PageKeyRow
  { page_id :: Columnar f Text
  , key_id :: Columnar f Text
  , space_key_id :: Columnar f Text
  , nonce :: Columnar f Text
  , wrapped :: Columnar f Text
  , current :: Columnar f Bool
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table PageKeys where
  data PrimaryKey PageKeys f = PageKeyKey (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = PageKeyKey r.page_id r.key_id

-- | A version of a page of an encrypted space, encrypted
-- (@sealed_versions@), beside its row of 'PageVersions', whose title and
-- text are empty. @chain_number@ and @previous_tag@ (migration
-- @0016-chained-versions@) are where it stands in its page's history
-- ("Wiki.Core.Encrypted"'s 'Wiki.Core.Encrypted.Chain'), both none for a
-- version written before versions were chained.
data SealedVersions f = SealedVersionRow
  { page_id :: Columnar f Text
  , updated_at :: Columnar f UTCTime
  , tag :: Columnar f Text
  , key_id :: Columnar f Text
  , title_nonce :: Columnar f Text
  , title :: Columnar f Text
  , body_nonce :: Columnar f Text
  , body :: Columnar f Text
  , chain_number :: Columnar f (Maybe Int64)
  , previous_tag :: Columnar f (Maybe Text)
  , origin_tag :: Columnar f (Maybe Text)
  -- ^ Which chain it is of ('Wiki.Core.Encrypted.Chain''s @origin@, step
  -- 22), none for a version written before origins.
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SealedVersions where
  data PrimaryKey SealedVersions f = SealedVersionKey (Columnar f Text) (Columnar f UTCTime)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SealedVersionKey r.page_id r.updated_at

-- | A thread's anchor in an encrypted space, encrypted (@sealed_threads@,
-- migration @0018-sealed-comments-and-attachments@), beside its row of
-- 'Threads', which has no quote: none for a thread about the whole page.
data SealedThreads f = SealedThreadRow
  { thread_id :: Columnar f Text
  , key_id :: Columnar f Text
  , anchored :: Columnar f Bool
  , anchor_nonce :: Columnar f (Maybe Text)
  , anchor :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SealedThreads where
  newtype PrimaryKey SealedThreads f = SealedThreadKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SealedThreadKey r.thread_id

-- | A comment's text in an encrypted space, encrypted (@sealed_comments@),
-- beside its row of 'Comments', whose body is empty.
data SealedComments f = SealedCommentRow
  { comment_id :: Columnar f Text
  , key_id :: Columnar f Text
  , tag :: Columnar f Text
  , nonce :: Columnar f Text
  , body :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SealedComments where
  newtype PrimaryKey SealedComments f = SealedCommentKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SealedCommentKey r.comment_id

-- | An attachment's name and media type in an encrypted space, encrypted,
-- and the nonce of its bytes (@sealed_attachments@), beside its row of
-- 'Attachments', named by its id, whose blob holds the encrypted bytes.
-- @staged_blob@ is the blob of an attachment encrypted while its space is
-- being encrypted, not yet in its row's place.
data SealedAttachments f = SealedAttachmentRow
  { attachment_id :: Columnar f Text
  , key_id :: Columnar f Text
  , meta_nonce :: Columnar f Text
  , meta :: Columnar f Text
  , bytes_nonce :: Columnar f Text
  , staged_blob :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table SealedAttachments where
  newtype PrimaryKey SealedAttachments f = SealedAttachmentKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = SealedAttachmentKey r.attachment_id

-- | What a browser turning a space's encryption off staged of a page,
-- decrypted (@staged_plain@, step 20), before the page's commit puts it in
-- place of the ciphertexts: one row for each version (@kind@ "version",
-- @item@ its time, which @updated_at@ holds, with its @title@ and
-- @body@), thread ("thread", its id, with its @quote@, @prefix@ and
-- @suffix@, the quote none for a thread about the whole page), comment
-- ("comment", its id, its @body@) and attachment ("attachment", its id,
-- its @name@, @media_type@ and @blob@).
data StagedPlain f = StagedPlainRow
  { page_id :: Columnar f Text
  , kind :: Columnar f Text
  , item :: Columnar f Text
  , updated_at :: Columnar f (Maybe UTCTime)
  , title :: Columnar f (Maybe Text)
  , body :: Columnar f (Maybe Text)
  , quote :: Columnar f (Maybe Text)
  , prefix :: Columnar f (Maybe Text)
  , suffix :: Columnar f (Maybe Text)
  , name :: Columnar f (Maybe Text)
  , media_type :: Columnar f (Maybe Text)
  , blob :: Columnar f (Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table StagedPlain where
  data PrimaryKey StagedPlain f = StagedPlainKey (Columnar f Text) (Columnar f Text) (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = StagedPlainKey r.page_id r.kind r.item

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
  , vaults :: f (TableEntity Vaults)
  , vault_items :: f (TableEntity VaultItems)
  , public_keys :: f (TableEntity PublicKeys)
  , spaces :: f (TableEntity Spaces)
  , pages :: f (TableEntity Pages)
  , page_versions :: f (TableEntity PageVersions)
  , attachments :: f (TableEntity Attachments)
  , drafts :: f (TableEntity Drafts)
  , threads :: f (TableEntity Threads)
  , comments :: f (TableEntity Comments)
  , watches :: f (TableEntity Watches)
  , stars :: f (TableEntity Stars)
  , notifications :: f (TableEntity Notifications)
  , page_links :: f (TableEntity PageLinks)
  , settings :: f (TableEntity Settings)
  , sign_in_providers :: f (TableEntity SignInProviders)
  , audit_log :: f (TableEntity AuditLog)
  , permissions_generation :: f (TableEntity PermissionsGeneration)
  , key_grants :: f (TableEntity KeyGrants)
  , page_keys :: f (TableEntity PageKeys)
  , sealed_versions :: f (TableEntity SealedVersions)
  , sealed_threads :: f (TableEntity SealedThreads)
  , sealed_comments :: f (TableEntity SealedComments)
  , sealed_attachments :: f (TableEntity SealedAttachments)
  , staged_plain :: f (TableEntity StagedPlain)
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
