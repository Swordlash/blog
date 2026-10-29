-- | The wiki's records as database rows: how each record is written into
-- the tables of "Wiki.Server.Storage.Schema" and read back, and the reads
-- and writes of whole records that the storage's operations
-- ("Wiki.Server.Storage") are made of. Nothing here checks a permission or
-- a rule: these run inside a transaction that has already checked them.
--
-- Every function here is a Beam statement of type @'Backend' be => … ->
-- 'Db' be a@, which runs on SQLite and on PostgreSQL alike
-- ("Wiki.Server.Storage.Backend").
module Wiki.Server.Storage.Rows
  ( -- * Columns
    micro
  , holds
  , orderText
  , readOrder
  , chunksOf

    -- * Pages without their text
  , PageNode (..)
  , nodeOf
  , pageNodes
  , pageNode
  , pageNodesWithIds
  , childPage
  , childPages
  , subtreeIds
  , SitemapNode (..)
  , loadSitemapNodes

    -- * Reads
  , loadSpaces
  , loadGrants
  , loadUser
  , loadUserByLogin
  , loadActiveUsersByLogin
  , loadActiveUser
  , loadUsers
  , loadGroupsOf
  , loadGroups
  , loadMembership
  , loadPage
  , loadPages
  , loadPageSummaries
  , loadAllPages
  , loadAttachment
  , loadAttachmentIn
  , loadDraft
  , VersionRow (..)
  , loadVersionsPage
  , loadFirstVersion
  , loadFirstVersions
  , loadPostBodies
  , loadCommentCounts
  , loadVersion
  , countPagesBySpace
  , countPagesIn
  , countRows
  , wikiIsEmpty
  , blobSizes
  , loadIcons
  , blobAttached
  , referencedBlobs

    -- * Accounts
  , loadAccount
  , loadAccountByLogin
  , loadAccountsWithAdministrators
  , loadAccountFlags
  , insertAccount
  , updatePasswordHash
  , passwordHashOf
  , updateDisabled
  , deleteSessionsOf
  , totpEnabled
  , deleteSecondFactor
  , loadSecondFactorUsers
  , loadEmails
  , verifiedEmail

    -- * Identities
  , IdentityRow (..)
  , identityOf
  , identitiesOf
  , insertIdentity
  , refreshIdentity
  , deleteIdentity
  , loadIdentityProviders
  , noPasswordToSet
  , providerNames

    -- * Password resets
  , insertResetToken
  , resetsSince

    -- * The permission context's generation
  , permissionsGeneration
  , bumpPermissions

    -- * Writes
  , insertUsers
  , insertGroup
  , insertMember
  , insertMembers
  , deleteMember
  , renameGroupRow
  , deleteGroupRows
  , setGlobalGrant
  , deleteGlobalGrant
  , deleteSpaceGrant
  , insertGrants
  , insertSpace
  , insertSpaces
  , updateSpace
  , updateSpaces
  , setSpacePositions
  , deleteSpaceRow
  , clearHomePage
  , insertPage
  , updatePageText
  , setPagePosition
  , placePage
  , setPageSpace
  , setPageTemplateRow
  , deletePageRow
  , insertVersion
  , insertAttachment
  , replaceAttachment
  , deleteAttachmentRow
  , deleteAttachmentsOf
  , saveDraftRow
  , deleteDraft
  , searchFold

    -- * Settings
  , settingValue
  , settingsLike
  , storeSetting
  , keepSetting
  , deleteSettingsLike
  , loadSettings
  , storeSettings
  , loadInvitations
  , insertInvitation
  , deleteInvitation
  , pendingInvitation
  , grantCreateSpaces

    -- * The server's own settings
  , loadServerSettings
  , storeServerSettings
  )
where

import Data.Aeson (decodeStrict', encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), diffTimeToPicoseconds, picosecondsToDiffTime)
import Database.Beam
  ( QExpr
  , aggregate_
  , all_
  , as_
  , asc_
  , countAll_
  , default_
  , delete
  , desc_
  , filter_
  , group_
  , in_
  , insert
  , insertExpressions
  , insertValues
  , isNothing_
  , join_
  , just_
  , leftJoin_'
  , like_
  , limit_
  , lower_
  , max_
  , orderBy_
  , runDelete
  , runInsert
  , runSelectReturningList
  , runSelectReturningOne
  , runUpdate
  , select
  , update
  , val_
  , (&&.)
  , (<-.)
  , (<.)
  , (==.)
  , (==?.)
  , (>.)
  )
import Database.Beam qualified as Beam
import Database.Beam.Backend.SQL (BeamSqlBackend)
import Database.Beam.Backend.SQL.BeamExtensions (anyConflict, conflictingFields, insertOnConflict, onConflictDoNothing, onConflictUpdateSet)
import Protolude
import Wiki.Api.Account (Account (..), InvitationInfo (..), LinkedIdentity (..), providerOnly)
import Wiki.Api.Admin (Invitation (..), WikiSettings (..), defaultSettings)
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsOf (..), defaultMailPort, kindName, readKind, readSecurity, securityFor, securityName)
import Wiki.Core.Access (Access (..), accessName, readAccess)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Sibling (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (bodyText, foldText)
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Group (..), Login (..), Membership, User (..))
import Wiki.Server.Secret (Kept, Secret (..), revealed)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

--------------------------------------------------------------------------------
-- Columns

-- | A time to the microsecond, as both databases keep a time: PostgreSQL
-- keeps no finer, and the storage writes no finer to SQLite either. A save
-- is checked against the time it started from by equality, so a time must
-- come back exactly as it went in. The storage makes its own times with
-- this, and writes every time with it.
micro :: UTCTime -> UTCTime
micro (UTCTime day t) = UTCTime day (picosecondsToDiffTime (diffTimeToPicoseconds t `div` 1000000 * 1000000))

-- | Whether a column that may be NULL holds this value: SQL's plain @=@,
-- which an index on the column answers. Beam's '==.' on a nullable column
-- is NULL-safe instead (two NULLs are equal), and writes it as a @CASE@
-- that no index answers, so that the database reads every row. The value
-- here is never NULL, so the NULL-safe comparison is not needed. It is
-- written as @IN@ with one value, which both databases treat as @=@.
holds :: (BeamSqlBackend be) => QExpr be s (Maybe a) -> QExpr be s a -> QExpr be s Bool
holds column value = column `in_` [just_ value]

infix 4 `holds`

-- | A slug read back from a column, through 'mkSlug'. A column holds only
-- slugs the storage made, so one that is not a slug means a database
-- written by something else.
slugOf :: Text -> Slug
slugOf t = either (\e -> panic ("not a slug in the database: " <> t <> ", " <> show e)) identity (mkSlug t)

-- | The word for an order, which the export format also writes.
orderText :: ChildOrder -> Text
orderText = \case
  ByName -> "name"
  NewestFirst -> "newest-first"
  OldestFirst -> "oldest-first"
  ByHand -> "by-hand"

-- | An order from its word; the schema's check guarantees it is one of
-- them.
readOrder :: Text -> ChildOrder
readOrder t = fromMaybe ByName (find (\o -> orderText o == t) [minBound .. maxBound])

globalText :: GlobalPermission -> Text
globalText = \case
  Administer -> "administer"
  CreateSpaces -> "create-spaces"

spaceText :: SpacePermission -> Text
spaceText = \case
  View -> "view"
  Edit -> "edit"
  AdministerSpace -> "administer"

subjectColumns :: Subject -> (Text, Text)
subjectColumns = \case
  SubjectUser u -> ("user", u.text)
  SubjectGroup g -> ("group", g.text)

-- | A subject from its two columns; 'Nothing' for a kind the schema's
-- check does not allow.
subjectFrom :: Text -> Text -> Maybe Subject
subjectFrom kind i = case kind of
  "user" -> Just (SubjectUser (UserId i))
  "group" -> Just (SubjectGroup (GroupId i))
  _ -> Nothing

-- | Values in groups of at most this many. A list of ids for an @IN (…)@
-- can be longer than a statement may have parameters.
chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs = case splitAt n xs of
  ([], _) -> []
  (now, rest) -> now : chunksOf n rest

-- | The rows of a query asked for each group of values in turn: an @IN
-- (…)@ of many values, in groups of 500. No values ask nothing: an empty
-- @IN ()@ would read every row.
inChunks :: (Monad m) => [a] -> ([a] -> m [b]) -> m [b]
inChunks xs f = concat <$> traverse f (chunksOf 500 xs)

--------------------------------------------------------------------------------
-- Pages without their text

-- | A page's place in its space's tree, without its body or attachments:
-- what finding a page by its path, choosing a slug or a position, or
-- finding a subtree needs, read without the text of every page of a
-- space.
data PageNode = PageNode
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , title :: Text
  , slug :: Slug
  , createdAt :: UTCTime
  , position :: Int
  , template :: Bool
  -- ^ Whether it is one of its space's templates, which a search that
  -- does not ask for templates leaves out.
  }

instance TreeNode PageNode where
  type NodeId PageNode = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

instance Sibling PageNode where
  siblingName p = p.title
  siblingCreatedAt p = p.createdAt
  siblingPosition p = p.position

-- | A page's node from its columns.
nodeOf :: S.PageNodes Identity -> PageNode
nodeOf r =
  PageNode
    { id = PageId r.id
    , space = SpaceId r.space_id
    , parent = PageId <$> r.parent
    , title = r.title
    , slug = slugOf r.slug
    , createdAt = r.created_at
    , position = fromIntegral r.position
    , template = r.template
    }

-- | The nodes of the pages a condition picks.
nodesWhere :: (Backend be) => (forall s. S.Pages (QExpr be s) -> QExpr be s Bool) -> Db be [PageNode]
nodesWhere cond = map nodeOf <$> runSelectReturningList (select (S.nodeColumns <$> filter_ cond (all_ wikiDb.pages)))

-- | The pages of a space, as nodes.
pageNodes :: (Backend be) => SpaceId -> Db be [PageNode]
pageNodes sid = nodesWhere (\p -> p.space_id ==. val_ sid.text)

-- | One page, as a node.
pageNode :: (Backend be) => PageId -> Db be (Maybe PageNode)
pageNode pid = head <$> nodesWhere (\p -> p.id ==. val_ pid.text)

-- | The pages with these ids, as nodes, in no particular order. An id that
-- names no page is left out.
pageNodesWithIds :: (Backend be) => [PageId] -> Db be [PageNode]
pageNodesWithIds pids = inChunks (ordNub pids) $ \ids -> nodesWhere (\p -> p.id `in_` map (\x -> val_ x.text) ids)

-- | The condition that a page is under a parent: one page, or the top
-- level of its space for 'Nothing'. Written as @parent = ?@ or @parent IS
-- NULL@, which the index @pages_place@ serves.
under :: (Backend be) => Maybe PageId -> S.Pages (QExpr be s) -> QExpr be s Bool
under parent p = maybe (isNothing_ p.parent) (\x -> p.parent `holds` val_ x.text) parent

-- | The page of a space with this slug under this parent ('Nothing' for
-- the space's top level), as a node: one step of finding a page by its
-- path, through the index @pages_place@.
childPage :: (Backend be) => SpaceId -> Maybe PageId -> Slug -> Db be (Maybe PageNode)
childPage sid parent slug = head <$> nodesWhere (\p -> p.space_id ==. val_ sid.text &&. under parent p &&. p.slug ==. val_ (slugText slug))

-- | The pages of a space under this parent ('Nothing' for the space's top
-- level), as nodes, in no particular order: what choosing a new page's
-- slug and position needs. Found through the same index as 'childPage'.
childPages :: (Backend be) => SpaceId -> Maybe PageId -> Db be [PageNode]
childPages sid parent = nodesWhere (\p -> p.space_id ==. val_ sid.text &&. under parent p)

-- | A page and the pages under it, at any depth, by id. The pages are
-- read one level at a time, each level in one query through the index on
-- a page's parent, so the reads grow with the subtree's depth and read
-- nothing else of the space. A page already found is not followed again,
-- so even a loop of parents, which a page tree never has, ends.
subtreeIds :: (Backend be) => PageId -> Db be (Set PageId)
subtreeIds pid = go (Set.singleton pid) [pid]
  where
    go found [] = pure found
    go found level = do
      children <- inChunks level $ \ps ->
        runSelectReturningList . select $ (\p -> p.id) <$> filter_ (\p -> p.parent `in_` map (\x -> just_ (val_ x.text)) ps) (all_ wikiDb.pages)
      let new = [PageId c | c <- ordNub children, Set.notMember (PageId c) found]
      go (found <> Set.fromList new) new

-- | 'SitemapNode' is a page as the sitemap lists it: its place in its
-- space's tree, and when it last changed. It has no title and no text,
-- so a sitemap of a large wiki reads little of each page's row.
data SitemapNode = SitemapNode
  { id :: PageId
  , space :: SpaceId
  , parent :: Maybe PageId
  , slug :: Slug
  , updatedAt :: UTCTime
  }

instance TreeNode SitemapNode where
  type NodeId SitemapNode = PageId
  nodeId p = p.id
  nodeParent p = p.parent
  nodeSlug p = p.slug

-- | The pages of these spaces, as the sitemap lists them, in no
-- particular order.
loadSitemapNodes :: (Backend be) => [SpaceId] -> Db be [SitemapNode]
loadSitemapNodes spaces = inChunks spaces $ \chunk -> do
  rows <- runSelectReturningList . select $ do
    p <- filter_ (\p -> p.space_id `in_` map (\s -> val_ s.text) chunk) (all_ wikiDb.pages)
    pure (p.id, p.space_id, p.parent, p.slug, p.updated_at)
  pure [SitemapNode {id = PageId i, space = SpaceId s, parent = PageId <$> parent, slug = slugOf slug, updatedAt} | (i, s, parent, slug, updatedAt) <- rows]

--------------------------------------------------------------------------------
-- Reads

spaceOf :: S.Spaces Identity -> Space
spaceOf r =
  Space
    { id = SpaceId r.id
    , parent = SpaceId <$> r.parent
    , name = r.name
    , slug = slugOf r.slug
    , public = r.public
    , mathMacros = r.math_macros
    , createdAt = r.created_at
    , position = fromIntegral r.position
    , subspaceOrder = readOrder r.subspace_order
    , pageOrder = readOrder r.page_order
    , homePage = PageId <$> r.home_page
    , -- An icon that does not parse (one written by a later program) is
      -- read as the default, as the export reads it.
      icon = r.icon >>= decodeStrict' . encodeUtf8
    , description = r.description
    , blog = r.blog
    }

spaceRow :: Space -> S.Spaces Identity
spaceRow s =
  S.SpaceRow
    { id = s.id.text
    , parent = (\p -> p.text) <$> s.parent
    , name = s.name
    , slug = slugText s.slug
    , public = s.public
    , math_macros = s.mathMacros
    , created_at = micro s.createdAt
    , position = fromIntegral s.position
    , subspace_order = orderText s.subspaceOrder
    , page_order = orderText s.pageOrder
    , home_page = (\p -> p.text) <$> s.homePage
    , icon = decodeUtf8 . BSL.toStrict . encode <$> s.icon
    , description = s.description
    , blog = s.blog
    }

-- | Every space, by id. A wiki has tens of them, and every permission is
-- a question about a space's chain of ancestors, so each operation reads
-- them all.
loadSpaces :: (Backend be) => Db be (Map SpaceId Space)
loadSpaces = Map.fromList . map (\r -> (SpaceId r.id, spaceOf r)) <$> runSelectReturningList (select (all_ wikiDb.spaces))

-- | Every global grant, in the order they were given.
loadGlobalGrants :: (Backend be) => Db be [GlobalGrant]
loadGlobalGrants = do
  rows <- runSelectReturningList (select (orderBy_ (\g -> asc_ g.seq) (all_ wikiDb.global_grants)))
  pure
    [ GlobalGrant {subject, permission}
    | g <- rows
    , Just subject <- [subjectFrom g.subject_kind g.subject_id]
    , Just permission <- [find (\x -> globalText x == g.permission) [minBound .. maxBound]]
    ]

-- | Grants on spaces from their rows.
spaceGrantsOf :: [S.SpaceGrants Identity] -> [SpaceGrant]
spaceGrantsOf rows =
  [ SpaceGrant {space = SpaceId g.space_id, subject, permission}
  | g <- rows
  , Just subject <- [subjectFrom g.subject_kind g.subject_id]
  , Just permission <- [find (\x -> spaceText x == g.permission) [minBound .. maxBound]]
  ]

-- | Every grant, global and on spaces, in the order they were given. The
-- wiki's access setting, which the storage adds to the grants where it is
-- needed ("Wiki.Server.Storage"), is not stored in the grants' rows.
loadGrants :: (Backend be) => Db be Grants
loadGrants = do
  global <- loadGlobalGrants
  spaces <- spaceGrantsOf <$> runSelectReturningList (select (orderBy_ (\g -> asc_ g.seq) (all_ wikiDb.space_grants)))
  pure Grants {global, spaces, access = Open}

userOf :: S.Users Identity -> User
userOf r = User {id = UserId r.id, login = Login r.login, displayName = r.display_name}

-- | The users a condition picks, as the application sees them.
usersWhere :: (Backend be) => (forall s. S.Users (QExpr be s) -> QExpr be s Bool) -> Db be [User]
usersWhere cond = map userOf <$> runSelectReturningList (select (orderBy_ (\u -> asc_ u.id) (filter_ cond (all_ wikiDb.users))))

-- | A user by id.
loadUser :: (Backend be) => UserId -> Db be (Maybe User)
loadUser u = head <$> usersWhere (\r -> r.id ==. val_ u.text)

-- | A user by id who may act: not one whose login is disabled.
loadActiveUser :: (Backend be) => UserId -> Db be (Maybe User)
loadActiveUser u = head <$> usersWhere (\r -> r.id ==. val_ u.text &&. r.disabled ==. val_ False)

-- | A user by login, as it is written.
loadUserByLogin :: (Backend be) => Text -> Db be (Maybe User)
loadUserByLogin login = head <$> usersWhere (\r -> r.login ==. val_ login)

-- | The users with these logins who may act, not those whose login is
-- disabled, through the unique index on the login.
loadActiveUsersByLogin :: (Backend be) => [Text] -> Db be [User]
loadActiveUsersByLogin logins = inChunks (ordNub logins) $ \chunk ->
  usersWhere (\r -> r.disabled ==. val_ False &&. r.login `in_` map val_ chunk)

-- | Every user, by id.
loadUsers :: (Backend be) => Db be [User]
loadUsers = usersWhere (const (val_ True))

-- | The groups a user is in.
loadGroupsOf :: (Backend be) => UserId -> Db be (Set GroupId)
loadGroupsOf u =
  Set.fromList . map GroupId <$> runSelectReturningList (select ((\m -> m.group_id) <$> filter_ (\m -> m.user_id ==. val_ u.text) (all_ wikiDb.group_members)))

-- | Every group, by id.
loadGroups :: (Backend be) => Db be [Group]
loadGroups = map (\g -> Group {id = GroupId g.id, name = g.name}) <$> runSelectReturningList (select (orderBy_ (\g -> asc_ g.id) (all_ wikiDb.groups)))

-- | Every group's members.
loadMembership :: (Backend be) => Db be Membership
loadMembership = do
  rows <- runSelectReturningList (select (all_ wikiDb.group_members))
  pure (Map.fromListWith (<>) [(GroupId m.group_id, Set.singleton (UserId m.user_id)) | m <- rows])

-- | A page's row, waiting for its attachments.
pageOf :: S.Pages Identity -> [Attachment] -> Page
pageOf r attachments =
  Page
    { id = PageId r.id
    , space = SpaceId r.space_id
    , parent = PageId <$> r.parent
    , title = r.title
    , slug = slugOf r.slug
    , body = r.body
    , attachments
    , createdAt = r.created_at
    , updatedAt = r.updated_at
    , position = fromIntegral r.position
    , template = r.template
    }

-- | An attachment's row, with the page it is on.
attachmentOf :: S.Attachments Identity -> (PageId, Attachment)
attachmentOf r =
  ( PageId r.page_id
  , Attachment
      { id = AttachmentId r.id
      , name = FileName r.name
      , mediaType = MimeType r.media_type
      , size = fromIntegral r.size
      , source = maybe (SourceBlob (BlobId (fromMaybe "" r.blob))) (SourceUrl . Url) r.url
      }
  )

-- | Pages with their attachments, each page's attachments in order.
withAttachments :: [S.Pages Identity] -> [S.Attachments Identity] -> [Page]
withAttachments rows attached = [pageOf p (Map.findWithDefault [] (PageId p.id) byPage) | p <- rows]
  where
    byPage = Map.fromListWith (flip (<>)) [(pid, [a]) | r <- sortOn (\a -> a.ordinal) attached, let (pid, a) = attachmentOf r]

-- | The attachments of these pages.
attachmentsOf :: (Backend be) => [PageId] -> Db be [S.Attachments Identity]
attachmentsOf pids = inChunks pids $ \chunk ->
  runSelectReturningList (select (filter_ (\a -> a.page_id `in_` map (\p -> val_ p.text) chunk) (all_ wikiDb.attachments)))

-- | A page with its attachments.
loadPage :: (Backend be) => PageId -> Db be (Maybe Page)
loadPage pid = do
  rows <- runSelectReturningList (select (filter_ (\p -> p.id ==. val_ pid.text) (all_ wikiDb.pages)))
  attached <- if null rows then pure [] else attachmentsOf [pid]
  pure (head (withAttachments rows attached))

-- | The pages of a space with their attachments, in no particular order.
loadPages :: (Backend be) => SpaceId -> Db be [Page]
loadPages sid = do
  rows <- runSelectReturningList (select (filter_ (\p -> p.space_id ==. val_ sid.text) (all_ wikiDb.pages)))
  attached <- runSelectReturningList . select $ do
    a <- all_ wikiDb.attachments
    _ <- join_ wikiDb.pages (\p -> p.id ==. a.page_id &&. p.space_id ==. val_ sid.text)
    pure a
  pure (withAttachments rows attached)

-- | The summaries of a space's pages, in no particular order: the pages
-- without their bodies and attachments, which a list of pages does not
-- carry.
loadPageSummaries :: (Backend be) => SpaceId -> Db be [PageSummary]
loadPageSummaries sid = do
  rows <- runSelectReturningList . select $ do
    p <- filter_ (\p -> p.space_id ==. val_ sid.text) (all_ wikiDb.pages)
    pure (S.nodeColumns p, p.updated_at)
  pure
    [ PageSummary {id = n.id, space = n.space, parent = n.parent, title = n.title, slug = n.slug, createdAt = n.createdAt, updatedAt, position = n.position, template = n.template}
    | (r, updatedAt) <- rows
    , let n = nodeOf r
    ]

-- | Every page of the wiki with its attachments, by id.
loadAllPages :: (Backend be) => Db be [Page]
loadAllPages = do
  rows <- runSelectReturningList (select (orderBy_ (\p -> asc_ p.id) (all_ wikiDb.pages)))
  attached <- runSelectReturningList (select (all_ wikiDb.attachments))
  pure (withAttachments rows attached)

-- | An attachment, with the page it is on.
loadAttachment :: (Backend be) => AttachmentId -> Db be (Maybe (PageId, Attachment))
loadAttachment aid = fmap attachmentOf <$> runSelectReturningOne (select (filter_ (\a -> a.id ==. val_ aid.text) (all_ wikiDb.attachments)))

-- | An attachment, with the space its page is in, in one query: what
-- serving its bytes needs to check whether the reader may see it.
loadAttachmentIn :: (Backend be) => AttachmentId -> Db be (Maybe (SpaceId, Attachment))
loadAttachmentIn aid = do
  row <- runSelectReturningOne . select $ do
    a <- filter_ (\a -> a.id ==. val_ aid.text) (all_ wikiDb.attachments)
    p <- join_ wikiDb.pages (\p -> p.id ==. a.page_id)
    pure (a, p.space_id)
  pure ((\(a, s) -> (SpaceId s, snd (attachmentOf a))) <$> row)

-- | A user's draft of a page.
loadDraft :: (Backend be) => PageId -> UserId -> Db be (Maybe Draft)
loadDraft page author =
  fmap (\d -> Draft {page, author, title = d.title, body = d.body, base = d.base, savedAt = d.saved_at})
    <$> runSelectReturningOne (select (filter_ (\d -> d.page_id ==. val_ page.text &&. d.author ==. val_ author.text) (all_ wikiDb.drafts)))

-- | A version of a page as its row has it, with the display name of its
-- author if the author is a user.
data VersionRow = VersionRow
  { updatedAt :: UTCTime
  , title :: Text
  , body :: Text
  , author :: Maybe UserId
  , authorName :: Maybe Text
  }

-- | A page of a page's history: at most this many of its versions saved
-- before the time given (of all of them, for 'Nothing'), the latest
-- first, without their bodies, which a history's list does not show; and
-- how many versions there are before that time, which is the number of
-- the first of them. Both are read through the primary key of
-- @page_versions@, which holds a page's versions in time order.
loadVersionsPage :: forall be. (Backend be) => PageId -> Maybe UTCTime -> Int -> Db be (Int, [VersionRow])
loadVersionsPage page before most = do
  let earlier :: forall s. S.PageVersions (QExpr be s) -> QExpr be s Bool
      earlier v = v.page_id ==. val_ page.text &&. maybe (val_ True) (\t -> v.updated_at <. val_ (micro t)) before
  counted <- runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ earlier (all_ wikiDb.page_versions))))
  rows <- runSelectReturningList . select . limit_ (fromIntegral most) . orderBy_ (\(t, _, _, _) -> desc_ t) $ do
    v <- filter_ earlier (all_ wikiDb.page_versions)
    u <- leftJoin_' (all_ wikiDb.users) (\u -> just_ u.id ==?. v.author)
    pure (v.updated_at, v.title, v.author, u.display_name)
  pure (maybe 0 fromIntegral counted, [VersionRow {updatedAt, title, body = "", author = UserId <$> author, authorName} | (updatedAt, title, author, authorName) <- rows])

-- | The first versions of the pages a condition picks, without their
-- bodies, by page: the version saved when each page was created, so the
-- one whose time is the page's creation time, found through the primary
-- key of @page_versions@. A page an import made has its first version at
-- another time, with no author, so it has none here, and no first author
-- either way.
firstVersionsWhere :: (Backend be) => (forall s. S.Pages (QExpr be s) -> QExpr be s Bool) -> Db be [(PageId, VersionRow)]
firstVersionsWhere cond = do
  rows <- runSelectReturningList . select $ do
    p <- filter_ cond (all_ wikiDb.pages)
    v <- join_ wikiDb.page_versions (\v -> v.page_id ==. p.id &&. v.updated_at ==. p.created_at)
    u <- leftJoin_' (all_ wikiDb.users) (\u -> just_ u.id ==?. v.author)
    pure (v.page_id, v.updated_at, v.title, v.author, u.display_name)
  pure [(PageId pid, VersionRow {updatedAt, title, body = "", author = UserId <$> author, authorName}) | (pid, updatedAt, title, author, authorName) <- rows]

-- | The first version of a page ('firstVersionsWhere').
loadFirstVersion :: (Backend be) => PageId -> Db be (Maybe VersionRow)
loadFirstVersion page = fmap snd . head <$> firstVersionsWhere (\p -> p.id ==. val_ page.text)

-- | The first version of every page of a space ('firstVersionsWhere'):
-- one version for each page, instead of every version of the space.
loadFirstVersions :: (Backend be) => SpaceId -> Db be [(PageId, VersionRow)]
loadFirstVersions space = firstVersionsWhere (\p -> p.space_id ==. val_ space.text)

-- | The bodies of the pages of a space that can be posts of a blog: the
-- pages at its top level that are not templates ("Wiki.Core.Blog"'s
-- 'isPost' decides the rest). A blog's list shows an excerpt of each.
loadPostBodies :: (Backend be) => SpaceId -> Db be [(PageId, Text)]
loadPostBodies space =
  map (first PageId)
    <$> runSelectReturningList (select ((\p -> (p.id, p.body)) <$> filter_ (\p -> p.space_id ==. val_ space.text &&. isNothing_ p.parent &&. p.template ==. val_ False) (all_ wikiDb.pages)))

-- | How many comments each page of a space has, in all its threads; a page
-- with none is left out.
loadCommentCounts :: (Backend be) => SpaceId -> Db be [(PageId, Int)]
loadCommentCounts space = do
  rows <- runSelectReturningList . select . aggregate_ (\(page, _) -> (group_ page, as_ @Int64 countAll_)) $ do
    m <- all_ wikiDb.comments
    t <- join_ wikiDb.threads (\t -> t.id ==. m.thread_id)
    _ <- join_ wikiDb.pages (\p -> p.id ==. t.page_id &&. p.space_id ==. val_ space.text)
    pure (t.page_id, m.id)
  pure [(PageId p, fromIntegral n) | (p, n) <- rows]

-- | One version of a page, whole, by its time.
loadVersion :: (Backend be) => PageId -> UTCTime -> Db be (Maybe VersionRow)
loadVersion page at = do
  row <- runSelectReturningOne . select $ do
    v <- filter_ (\v -> v.page_id ==. val_ page.text &&. v.updated_at ==. val_ (micro at)) (all_ wikiDb.page_versions)
    u <- leftJoin_' (all_ wikiDb.users) (\u -> just_ u.id ==?. v.author)
    pure (v, u.display_name)
  pure ((\(v, name) -> VersionRow {updatedAt = v.updated_at, title = v.title, body = v.body, author = UserId <$> v.author, authorName = name}) <$> row)

-- | The number of pages in each space that has any, not counting
-- templates, through the index @pages_space_template@.
countPagesBySpace :: (Backend be) => Db be (Map SpaceId Int)
countPagesBySpace = do
  rows <- runSelectReturningList . select . aggregate_ (\p -> (group_ p.space_id, as_ @Int64 countAll_)) $ filter_ (\p -> p.template ==. val_ False) (all_ wikiDb.pages)
  pure (Map.fromList [(SpaceId s, fromIntegral n) | (s, n) <- rows])

-- | The number of pages in a space, templates included.
countPagesIn :: (Backend be) => SpaceId -> Db be Int
countPagesIn sid = maybe 0 fromIntegral <$> runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ (\p -> p.space_id ==. val_ sid.text) (all_ wikiDb.pages))))

-- | How many rows a table has.
countAll :: (Backend be, Beam.Table t) => Beam.DatabaseEntity be S.WikiDb (Beam.TableEntity t) -> Db be Int
countAll table = maybe 0 fromIntegral <$> runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (all_ table)))

-- | How many spaces, pages, attachments and users the wiki has, in that
-- order: what the server's status and metrics show.
countRows :: (Backend be) => Db be [(Text, Int)]
countRows =
  sequence
    [ ("spaces",) <$> countAll wikiDb.spaces
    , ("pages",) <$> countAll wikiDb.pages
    , ("attachments",) <$> countAll wikiDb.attachments
    , ("users",) <$> countAll wikiDb.users
    ]

-- | Whether the wiki has no users, no groups and no spaces: one an archive
-- may be imported into whole.
wikiIsEmpty :: (Backend be) => Db be Bool
wikiIsEmpty = all (== 0) <$> sequence [countAll wikiDb.users, countAll wikiDb.groups, countAll wikiDb.spaces]

-- | Each blob the attachments name, with its size as their rows record
-- it: two attachments with the same bytes share one blob, of one size.
blobSizes :: (Backend be) => Db be [(BlobId, Int64)]
blobSizes = do
  rows <- runSelectReturningList . select . aggregate_ (\a -> (group_ a.blob, max_ a.size)) $ filter_ (\a -> Beam.isJust_ a.blob) (all_ wikiDb.attachments)
  pure [(BlobId b, fromMaybe 0 n) | (Just b, n) <- rows]

-- | The icons of the spaces that have one, as their JSON.
loadIcons :: (Backend be) => Db be [Text]
loadIcons = catMaybes <$> runSelectReturningList (select ((\s -> s.icon) <$> filter_ (\s -> Beam.isJust_ s.icon) (all_ wikiDb.spaces)))

-- | Whether an attachment names this blob.
blobAttached :: (Backend be) => BlobId -> Db be Bool
blobAttached b = isJust <$> runSelectReturningOne (select (limit_ 1 ((\a -> a.id) <$> filter_ (\a -> a.blob `holds` val_ b.text) (all_ wikiDb.attachments))))

-- | The blobs the attachments and the spaces' icons name: the files of
-- the blob store a database refers to ("Wiki.Server.Storage.Blobs").
referencedBlobs :: (Backend be) => Db be (Set BlobId)
referencedBlobs = do
  attached <- map fst <$> blobSizes
  icons <- loadIcons
  pure (Set.fromList (attached <> [b | t <- icons, Just (IconImage b _) <- [decodeStrict' (encodeUtf8 t)]]))

--------------------------------------------------------------------------------
-- Accounts

accountOf :: S.Users Identity -> Account
accountOf r = Account {user = userOf r, hasPassword = isJust r.password_hash, disabled = r.disabled}

-- | A user's account, by id.
loadAccount :: (Backend be) => UserId -> Db be (Maybe Account)
loadAccount u = fmap accountOf <$> runSelectReturningOne (select (filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))

-- | A user's account by login, compared ignoring the case of ASCII letters
-- (through the index @users_login_folded@), with the hash of their
-- password if they have one: what someone types to sign in. Logins are
-- ASCII ("Wiki.Core.User"'s 'Wiki.Core.User.parseLogin'), so the two
-- databases' @lower@ agree on them.
loadAccountByLogin :: (Backend be) => Text -> Db be (Maybe (Account, Maybe Text))
loadAccountByLogin login =
  fmap (\r -> (accountOf r, r.password_hash))
    . head
    <$> runSelectReturningList (select (orderBy_ (\r -> asc_ r.login) (filter_ (\r -> lower_ r.login ==. lower_ (val_ login)) (all_ wikiDb.users))))

-- | Every user's account, by login ignoring case, with whether they are an
-- administrator (hold the global @administer@ themselves).
loadAccountsWithAdministrators :: (Backend be) => Db be [(Account, Bool)]
loadAccountsWithAdministrators = do
  users <- runSelectReturningList (select (all_ wikiDb.users))
  admins <- Set.fromList <$> runSelectReturningList (select ((\g -> g.subject_id) <$> filter_ (\g -> g.subject_kind ==. val_ "user" &&. g.permission ==. val_ "administer") (all_ wikiDb.global_grants)))
  pure (sortOn (\(a, _) -> (T.toLower a.user.login.text, a.user.login.text)) [(accountOf u, Set.member u.id admins) | u <- users])

-- | The users who are disabled, and those who have a password.
loadAccountFlags :: (Backend be) => Db be (Set UserId, Set UserId)
loadAccountFlags = do
  rows <- runSelectReturningList (select ((\u -> (u.id, u.disabled, isNothing_ u.password_hash)) <$> all_ wikiDb.users))
  pure
    ( Set.fromList [UserId u | (u, disabled, _) <- rows, disabled]
    , Set.fromList [UserId u | (u, _, none) <- rows, not none]
    )

-- | Add a user with a login no other user has, ignoring case, or return a
-- 'Left' with the login that is taken. The login and the password hash are
-- stored as given.
insertAccount :: (Backend be) => UserId -> Login -> Text -> Maybe Text -> Db be (Either Login Account)
insertAccount u login displayName phc =
  loadAccountByLogin login.text >>= \case
    Just _ -> pure (Left login)
    Nothing -> do
      runInsert . insert wikiDb.users $
        insertValues
          [ S.UserRow
              { id = u.text
              , login = login.text
              , display_name = displayName
              , password_hash = phc
              , disabled = False
              , email = Nothing
              , email_verified_at = Nothing
              , notification_mail = Nothing
              , watch_own = True
              }
          ]
      bumpPermissions
      maybe (Left login) Right <$> loadAccount u

-- | Replace a user's password hash.
updatePasswordHash :: (Backend be) => UserId -> Text -> Db be ()
updatePasswordHash u phc = runUpdate (update wikiDb.users (\r -> r.password_hash <-. val_ (Just phc)) (\r -> r.id ==. val_ u.text))

-- | A user's password hash, if they exist: 'Nothing' for a user who does
-- not, @Just Nothing@ for one without a password.
passwordHashOf :: (Backend be) => UserId -> Db be (Maybe (Maybe Text))
passwordHashOf u = runSelectReturningOne (select ((\r -> r.password_hash) <$> filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))

-- | Set whether a user is disabled.
updateDisabled :: (Backend be) => UserId -> Bool -> Db be ()
updateDisabled u disabled = do
  runUpdate (update wikiDb.users (\r -> r.disabled <-. val_ disabled) (\r -> r.id ==. val_ u.text))
  bumpPermissions

-- | End every session of a user.
deleteSessionsOf :: (Backend be) => UserId -> Db be ()
deleteSessionsOf u = runDelete (delete wikiDb.sessions (\s -> s.user_id ==. val_ u.text))

-- | Whether a user has a second factor that signing in asks for: one they
-- have confirmed.
totpEnabled :: (Backend be) => UserId -> Db be Bool
totpEnabled u = isJust <$> runSelectReturningOne (select ((\t -> t.user_id) <$> filter_ (\t -> t.user_id ==. val_ u.text &&. Beam.isJust_ t.enabled_at) (all_ wikiDb.totp)))

-- | Remove a user's second factor, started or on, with its recovery codes.
-- The result is whether they had one on.
deleteSecondFactor :: (Backend be) => UserId -> Db be Bool
deleteSecondFactor u = do
  had <- totpEnabled u
  runDelete (delete wikiDb.totp (\t -> t.user_id ==. val_ u.text))
  runDelete (delete wikiDb.recovery_codes (\r -> r.user_id ==. val_ u.text))
  pure had

-- | The users who have a second factor.
loadSecondFactorUsers :: (Backend be) => Db be (Set UserId)
loadSecondFactorUsers = Set.fromList . map UserId <$> runSelectReturningList (select ((\t -> t.user_id) <$> filter_ (\t -> Beam.isJust_ t.enabled_at) (all_ wikiDb.totp)))

-- | The e-mail addresses users have given, and whether each is verified.
loadEmails :: (Backend be) => Db be (Map UserId AccountEmail)
loadEmails = do
  rows <- runSelectReturningList (select ((\u -> (u.id, u.email, u.email_verified_at)) <$> filter_ (\u -> Beam.isJust_ u.email) (all_ wikiDb.users)))
  pure (Map.fromList [(UserId u, AccountEmail {email = Email e, verified = isJust at}) | (u, Just e, at) <- rows])

-- | A user's address, if it is verified.
verifiedEmail :: (Backend be) => UserId -> Db be (Maybe Email)
verifiedEmail u = do
  row <- runSelectReturningOne (select ((\r -> (r.email, r.email_verified_at)) <$> filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))
  pure $ case row of
    Just (Just e, Just _) -> Just (Email e)
    _ -> Nothing

--------------------------------------------------------------------------------
-- Identities

-- | An identity as its row has it.
data IdentityRow = IdentityRow
  { provider :: Text
  , subject :: Text
  , user :: UserId
  , identity :: LinkedIdentity
  }

identityRow :: S.Identities Identity -> IdentityRow
identityRow r =
  IdentityRow
    { provider = r.provider
    , subject = r.subject
    , user = UserId r.user_id
    , identity = LinkedIdentity {provider = r.provider, email = Email <$> r.email, name = r.display_name, linkedAt = r.linked_at}
    }

-- | The identity row of a provider's account, if it belongs to anyone.
identityOf :: (Backend be) => Text -> Text -> Db be (Maybe IdentityRow)
identityOf provider subject = fmap identityRow <$> runSelectReturningOne (select (filter_ (\i -> i.provider ==. val_ provider &&. i.subject ==. val_ subject) (all_ wikiDb.identities)))

-- | A user's identities, by provider.
identitiesOf :: (Backend be) => UserId -> Db be [IdentityRow]
identitiesOf u = map identityRow <$> runSelectReturningList (select (orderBy_ (\i -> asc_ i.provider) (filter_ (\i -> i.user_id ==. val_ u.text) (all_ wikiDb.identities))))

-- | Connect a provider's account to a user. The caller has made sure that
-- it belongs to nobody, and that the user has none at that provider.
insertIdentity :: (Backend be) => UTCTime -> UserId -> Text -> Text -> Maybe Email -> Maybe Text -> Db be ()
insertIdentity now u provider subject email name =
  runInsert . insert wikiDb.identities $
    insertValues [S.IdentityRow {provider, subject, user_id = u.text, email = (\e -> e.text) <$> email, display_name = name, linked_at = micro now}]

-- | Store what a provider now says about an account, for the next time it
-- is shown.
refreshIdentity :: (Backend be) => Text -> Text -> Maybe Email -> Maybe Text -> Db be ()
refreshIdentity provider subject email name =
  runUpdate $
    update
      wikiDb.identities
      (\i -> (i.email <-. val_ ((\e -> e.text) <$> email)) <> (i.display_name <-. val_ name))
      (\i -> i.provider ==. val_ provider &&. i.subject ==. val_ subject)

-- | Disconnect a user's account at a provider. The result is whether they
-- had one.
deleteIdentity :: (Backend be) => UserId -> Text -> Db be Bool
deleteIdentity u provider = do
  had <- any (\i -> i.provider == provider) <$> identitiesOf u
  runDelete (delete wikiDb.identities (\i -> i.user_id ==. val_ u.text &&. i.provider ==. val_ provider))
  pure had

-- | The providers each user has an identity at, by user.
loadIdentityProviders :: (Backend be) => Db be (Map UserId [Text])
loadIdentityProviders = do
  rows <- runSelectReturningList (select (orderBy_ (\(_, p) -> asc_ p) ((\i -> (i.user_id, i.provider)) <$> all_ wikiDb.identities)))
  pure (Map.fromListWith (flip (<>)) [(UserId u, [p]) | (u, p) <- rows])

-- | The names of the providers in the server's settings.
providerNames :: Kept -> [Text]
providerNames kept = map (\p -> p.name) kept.providers

-- | Whether a user has no password to set (WP5.6 of docs/PLAN.md,
-- 'Wiki.Api.Account.providerOnly'): they have none, and an identity at one
-- of these providers, the ones in the server's settings.
noPasswordToSet :: (Backend be) => [Text] -> UserId -> Db be Bool
noPasswordToSet configured u = do
  hashed <- passwordHashOf u
  providers <- map (\i -> i.provider) <$> identitiesOf u
  pure (providerOnly configured (any isJust hashed) providers)

--------------------------------------------------------------------------------
-- Password resets

-- | Store a reset link for a user: the hash of its secret, when it was
-- made, and when it expires.
insertResetToken :: (Backend be) => UserId -> Text -> UTCTime -> UTCTime -> Db be ()
insertResetToken u secretHash made expires =
  runInsert (insert wikiDb.reset_tokens (insertValues [S.ResetTokenRow {token_hash = secretHash, user_id = u.text, created_at = micro made, expires_at = micro expires, used_at = Nothing}]))

-- | How many reset links a user has been given since a time, used or not.
resetsSince :: (Backend be) => UserId -> UTCTime -> Db be Int
resetsSince u since =
  maybe 0 fromIntegral <$> runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ (\r -> r.user_id ==. val_ u.text &&. r.created_at >. val_ (micro since)) (all_ wikiDb.reset_tokens))))

--------------------------------------------------------------------------------
-- The permission context's generation

-- | The generation of the permission context, as the database has it now
-- (@permissions_generation@). The permission context is every space and
-- grant, and each user with their groups: what a permission check reads.
-- A read transaction reads the generation first, and takes the permission
-- context from the storage's memory when the generation there is the same
-- ("Wiki.Server.Storage").
permissionsGeneration :: (Backend be) => Db be Int64
permissionsGeneration = maybe 0 (\r -> r.generation) <$> runSelectReturningOne (select (all_ wikiDb.permissions_generation))

-- | Bump the generation of the permission context, in the running
-- transaction. A server's copy of the permission context in memory is
-- then read again from the database at the next read, whichever process
-- made the change: the server, or the console's @wiki-server users …@
-- beside it.
--
-- The permission context holds these columns, and a write that changes
-- any of them must bump the generation in the same transaction:
--
-- * every column of @spaces@;
-- * every column of @global_grants@ and @space_grants@;
-- * @users@: a row added or deleted, and @id@, @login@, @display_name@
--   and @disabled@ (a rename, which WP5.25 brings, is such a change);
-- * every column of @group_members@.
--
-- The writes here that change them call it: 'insertAccount',
-- 'insertUsers', 'updateDisabled', 'insertMembers', 'deleteMember',
-- 'deleteGroupRows', 'deleteGlobalGrant', 'deleteSpaceGrant',
-- 'insertGrants', 'insertSpaces', 'updateSpaces', 'setSpacePositions',
-- 'deleteSpaceRow' and 'clearHomePage', once for each call, however many
-- rows the call writes. Code that writes those columns with statements
-- of its own must call it too. A write to the other columns of @users@
-- (the password, the e-mail address and its verification, the
-- notification settings: "Wiki.Server.Storage.Notifications",
-- "Wiki.Server.Reset") does not change the permission context, and does
-- not bump it.
--
-- A write that bumps the generation and is then rolled back leaves it as
-- it was.
bumpPermissions :: (Backend be) => Db be ()
bumpPermissions = runUpdate (update wikiDb.permissions_generation (\r -> r.generation <-. Beam.current_ r.generation + val_ 1) (\r -> r.id ==. val_ 1))

--------------------------------------------------------------------------------
-- Writes

-- | Add users, as an import brings them: no password, enabled. The
-- permission context's generation is bumped once for all of them.
insertUsers :: (Backend be) => [User] -> Db be ()
insertUsers us = unless (null us) $ do
  bumpPermissions
  for_ (chunksOf 500 us) $ \chunk ->
    runInsert . insert wikiDb.users $
      insertValues
        [ S.UserRow
            { id = u.id.text
            , login = u.login.text
            , display_name = u.displayName
            , password_hash = Nothing
            , disabled = False
            , email = Nothing
            , email_verified_at = Nothing
            , notification_mail = Nothing
            , watch_own = True
            }
        | u <- chunk
        ]

-- | Add a group.
insertGroup :: (Backend be) => Group -> Db be ()
insertGroup g = runInsert (insert wikiDb.groups (insertValues [S.GroupRow {id = g.id.text, name = g.name}]))

-- | Put a user in a group; one who is in it already stays.
insertMember :: (Backend be) => GroupId -> UserId -> Db be ()
insertMember g u = insertMembers [(g, u)]

-- | Put users in groups, each pair a group and a user; a user who is in a
-- group already stays. The permission context's generation is bumped once
-- for all of them.
insertMembers :: (Backend be) => [(GroupId, UserId)] -> Db be ()
insertMembers pairs = unless (null pairs) $ do
  bumpPermissions
  for_ pairs $ \(g, u) ->
    runInsert (insertOnConflict wikiDb.group_members (insertValues [S.MemberRow {group_id = g.text, user_id = u.text}]) anyConflict onConflictDoNothing)

-- | Take a user out of a group.
deleteMember :: (Backend be) => GroupId -> UserId -> Db be ()
deleteMember g u = do
  runDelete (delete wikiDb.group_members (\m -> m.group_id ==. val_ g.text &&. m.user_id ==. val_ u.text))
  bumpPermissions

-- | Rename a group.
renameGroupRow :: (Backend be) => GroupId -> Text -> Db be ()
renameGroupRow g name = runUpdate (update wikiDb.groups (\r -> r.name <-. val_ name) (\r -> r.id ==. val_ g.text))

-- | Delete a group. Its memberships are deleted with it (by a foreign
-- key), and so must the grants to it be, which name it in a column that is
-- not a foreign key.
deleteGroupRows :: (Backend be) => GroupId -> Db be ()
deleteGroupRows g = do
  runDelete (delete wikiDb.global_grants (\r -> r.subject_kind ==. val_ "group" &&. r.subject_id ==. val_ g.text))
  runDelete (delete wikiDb.space_grants (\r -> r.subject_kind ==. val_ "group" &&. r.subject_id ==. val_ g.text))
  runDelete (delete wikiDb.groups (\r -> r.id ==. val_ g.text))
  bumpPermissions

-- | Grant a global permission, or take it away.
setGlobalGrant :: (Backend be) => Bool -> GlobalGrant -> Db be ()
setGlobalGrant granted g
  | granted = insertGrants Grants {global = [g], spaces = [], access = Open}
  | otherwise = deleteGlobalGrant g

-- | Remove a global grant, if it exists.
deleteGlobalGrant :: (Backend be) => GlobalGrant -> Db be ()
deleteGlobalGrant g =
  let (kind, i) = subjectColumns g.subject
   in do
        runDelete (delete wikiDb.global_grants (\r -> r.subject_kind ==. val_ kind &&. r.subject_id ==. val_ i &&. r.permission ==. val_ (globalText g.permission)))
        bumpPermissions

-- | Remove a grant on a space, if it exists.
deleteSpaceGrant :: (Backend be) => SpaceGrant -> Db be ()
deleteSpaceGrant g =
  let (kind, i) = subjectColumns g.subject
   in do
        runDelete
          ( delete
              wikiDb.space_grants
              (\r -> r.space_id ==. val_ g.space.text &&. r.subject_kind ==. val_ kind &&. r.subject_id ==. val_ i &&. r.permission ==. val_ (spaceText g.permission))
          )
        bumpPermissions

-- | Add these grants, in order, each numbered after the last; a grant that
-- already exists is left as it is.
insertGrants :: (Backend be) => Grants -> Db be ()
insertGrants grants = do
  unless (null grants.global && null grants.spaces) bumpPermissions
  for_ grants.global $ \g ->
    let (kind, i) = subjectColumns g.subject
     in runInsert $
          insertOnConflict
            wikiDb.global_grants
            (insertExpressions [S.GlobalGrantRow {seq = default_, subject_kind = val_ kind, subject_id = val_ i, permission = val_ (globalText g.permission)}])
            anyConflict
            onConflictDoNothing
  for_ grants.spaces $ \g ->
    let (kind, i) = subjectColumns g.subject
     in runInsert $
          insertOnConflict
            wikiDb.space_grants
            (insertExpressions [S.SpaceGrantRow {seq = default_, space_id = val_ g.space.text, subject_kind = val_ kind, subject_id = val_ i, permission = val_ (spaceText g.permission)}])
            anyConflict
            onConflictDoNothing

-- | Add a space.
insertSpace :: (Backend be) => Space -> Db be ()
insertSpace s = insertSpaces [s]

-- | Add spaces, in the order given, so that a space can come after its
-- parent. The permission context's generation is bumped once for all of
-- them.
insertSpaces :: (Backend be) => [Space] -> Db be ()
insertSpaces ss = unless (null ss) $ do
  bumpPermissions
  for_ ss $ \s -> runInsert (insert wikiDb.spaces (insertValues [spaceRow s]))

-- | Overwrite the space with this id: every column of it.
updateSpace :: (Backend be) => Space -> Db be ()
updateSpace s = updateSpaces [s]

-- | Overwrite these spaces, each by its id. The permission context's
-- generation is bumped once for all of them.
updateSpaces :: (Backend be) => [Space] -> Db be ()
updateSpaces ss = unless (null ss) $ do
  bumpPermissions
  for_ ss $ \s -> do
    let r = spaceRow s
    runUpdate $
      update
        wikiDb.spaces
        ( \x ->
            mconcat
              [ x.parent <-. val_ r.parent
              , x.name <-. val_ r.name
              , x.slug <-. val_ r.slug
              , x.public <-. val_ r.public
              , x.math_macros <-. val_ r.math_macros
              , x.created_at <-. val_ r.created_at
              , x.position <-. val_ r.position
              , x.subspace_order <-. val_ r.subspace_order
              , x.page_order <-. val_ r.page_order
              , x.home_page <-. val_ r.home_page
              , x.icon <-. val_ r.icon
              , x.description <-. val_ r.description
              , x.blog <-. val_ r.blog
              ]
        )
        (\x -> x.id ==. val_ r.id)

-- | Give spaces their positions among their siblings. The permission
-- context's generation is bumped once for all of them.
setSpacePositions :: (Backend be) => [(SpaceId, Int)] -> Db be ()
setSpacePositions placed = unless (null placed) $ do
  bumpPermissions
  for_ placed $ \(sid, n) -> runUpdate (update wikiDb.spaces (\x -> x.position <-. val_ (fromIntegral n)) (\x -> x.id ==. val_ sid.text))

-- | Delete a space: its subspaces, their pages, the pages' versions,
-- attachments and drafts, and the grants on all of them go with it, as the
-- schema's foreign keys cascade.
deleteSpaceRow :: (Backend be) => SpaceId -> Db be ()
deleteSpaceRow sid = runDelete (delete wikiDb.spaces (\x -> x.id ==. val_ sid.text)) >> bumpPermissions

-- | Make the spaces whose home page is one of these pages have none. The
-- caller gives only pages that are a space's home page, so that a page
-- that is none does not bump the permission context's generation.
clearHomePage :: (Backend be) => [PageId] -> Db be ()
clearHomePage pids = do
  unless (null pids) bumpPermissions
  for_ (chunksOf 500 pids) $ \chunk -> runUpdate (update wikiDb.spaces (\x -> x.home_page <-. val_ Nothing) (\x -> x.home_page `in_` map (\p -> just_ (val_ p.text)) chunk))

-- | The fold a search matches a page against: its title and its search
-- text ('bodyText' of its body), each folded as the search folds them
-- ('foldText'), with a line break between them. A query's words have no
-- blanks, so no word can match across the line break.
searchFold :: Text -> Text -> Text
searchFold title searchText = foldText title <> "\n" <> foldText searchText

-- | Add a page, without its attachments, with its search text and its
-- fold prepared from its title and body.
insertPage :: (Backend be) => Page -> Db be ()
insertPage p =
  runInsert . insert wikiDb.pages $
    insertValues
      [ S.PageRow
          { id = p.id.text
          , space_id = p.space.text
          , parent = (\x -> x.text) <$> p.parent
          , title = p.title
          , slug = slugText p.slug
          , body = p.body
          , created_at = micro p.createdAt
          , updated_at = micro p.updatedAt
          , position = fromIntegral p.position
          , template = p.template
          , search_text = searchText
          , search_fold = searchFold p.title searchText
          }
      ]
  where
    searchText = bodyText p.body

-- | Change a page's title and body, as a save does, with its search text
-- and its fold made again from them, and its @updated_at@.
updatePageText :: (Backend be) => PageId -> Text -> Text -> UTCTime -> Db be ()
updatePageText pid title body updatedAt =
  runUpdate $
    update
      wikiDb.pages
      ( \p ->
          mconcat
            [ p.title <-. val_ title
            , p.body <-. val_ body
            , p.updated_at <-. val_ (micro updatedAt)
            , p.search_text <-. val_ searchText
            , p.search_fold <-. val_ (searchFold title searchText)
            ]
      )
      (\p -> p.id ==. val_ pid.text)
  where
    searchText = bodyText body

-- | Give a page a position among its siblings.
setPagePosition :: (Backend be) => PageId -> Int -> Db be ()
setPagePosition pid n = runUpdate (update wikiDb.pages (\p -> p.position <-. val_ (fromIntegral n)) (\p -> p.id ==. val_ pid.text))

-- | Put a page in a space, under a parent, with a slug and a position:
-- where a move takes it.
placePage :: (Backend be) => PageId -> SpaceId -> Maybe PageId -> Slug -> Int -> Db be ()
placePage pid sid parent slug position =
  runUpdate $
    update
      wikiDb.pages
      ( \p ->
          mconcat
            [ p.space_id <-. val_ sid.text
            , p.parent <-. val_ ((\x -> x.text) <$> parent)
            , p.slug <-. val_ (slugText slug)
            , p.position <-. val_ (fromIntegral position)
            ]
      )
      (\p -> p.id ==. val_ pid.text)

-- | Move these pages to a space, where they keep their places: the pages
-- under a page that moves.
setPageSpace :: (Backend be) => SpaceId -> [PageId] -> Db be ()
setPageSpace sid pids = for_ (chunksOf 500 pids) $ \chunk ->
  runUpdate (update wikiDb.pages (\p -> p.space_id <-. val_ sid.text) (\p -> p.id `in_` map (\x -> val_ x.text) chunk))

-- | Make a page one of its space's templates, or not.
setPageTemplateRow :: (Backend be) => PageId -> Bool -> Db be ()
setPageTemplateRow pid template = runUpdate (update wikiDb.pages (\p -> p.template <-. val_ template) (\p -> p.id ==. val_ pid.text))

-- | Delete a page: the pages under it, and the versions, attachments and
-- drafts of all of them, go with it, as the schema's foreign keys
-- cascade.
deletePageRow :: (Backend be) => PageId -> Db be ()
deletePageRow pid = runDelete (delete wikiDb.pages (\p -> p.id ==. val_ pid.text))

-- | Store a version of a page: its title and body as of its @updatedAt@,
-- and who saved it, if known.
insertVersion :: (Backend be) => Page -> Maybe UserId -> Db be ()
insertVersion p author =
  runInsert (insert wikiDb.page_versions (insertValues [S.VersionRow {page_id = p.id.text, updated_at = micro p.updatedAt, title = p.title, body = p.body, author = (\u -> u.text) <$> author}]))

-- | Attach an attachment to a page, at a position among the page's
-- attachments.
insertAttachment :: (Backend be) => PageId -> Int -> Attachment -> Db be ()
insertAttachment page ordinal a =
  runInsert . insert wikiDb.attachments $
    insertValues
      [ S.AttachmentRow
          { id = a.id.text
          , page_id = page.text
          , name = a.name.text
          , media_type = a.mediaType.text
          , size = fromIntegral a.size
          , url = url
          , blob = blob
          , ordinal = fromIntegral ordinal
          }
      ]
  where
    (url, blob) = case a.source of
      SourceUrl u -> (Just u.text, Nothing)
      SourceBlob b -> (Nothing, Just b.text)

-- | Attach an attachment to a page, in place of the page's attachment of
-- the same name if it has one (at its position), else after the page's
-- last.
replaceAttachment :: (Backend be) => PageId -> Attachment -> Db be ()
replaceAttachment pid a = do
  replaced <- runSelectReturningOne (select ((\x -> (x.id, x.ordinal)) <$> filter_ (\x -> x.page_id ==. val_ pid.text &&. x.name ==. val_ a.name.text) (all_ wikiDb.attachments)))
  ordinal <- case replaced of
    Just (old, at) -> deleteAttachmentRow (AttachmentId old) $> fromIntegral at
    Nothing ->
      maybe 0 ((+ 1) . fromIntegral)
        . join
        <$> runSelectReturningOne (select (aggregate_ (\x -> max_ x.ordinal) (filter_ (\x -> x.page_id ==. val_ pid.text) (all_ wikiDb.attachments))))
  insertAttachment pid ordinal a

-- | Remove an attachment.
deleteAttachmentRow :: (Backend be) => AttachmentId -> Db be ()
deleteAttachmentRow aid = runDelete (delete wikiDb.attachments (\x -> x.id ==. val_ aid.text))

-- | Remove every attachment of a page.
deleteAttachmentsOf :: (Backend be) => PageId -> Db be ()
deleteAttachmentsOf pid = runDelete (delete wikiDb.attachments (\x -> x.page_id ==. val_ pid.text))

-- | Keep an author's draft of a page, in place of the one they had.
saveDraftRow :: (Backend be) => Draft -> Db be ()
saveDraftRow d =
  runInsert $
    insertOnConflict
      wikiDb.drafts
      (insertValues [S.DraftRow {page_id = d.page.text, author = d.author.text, title = d.title, body = d.body, base = micro d.base, saved_at = micro d.savedAt}])
      (conflictingFields (\x -> (x.page_id, x.author)))
      (onConflictUpdateSet (\x new -> mconcat [x.title <-. new.title, x.body <-. new.body, x.base <-. new.base, x.saved_at <-. new.saved_at]))

-- | Discard an author's draft of a page, if they have one.
deleteDraft :: (Backend be) => PageId -> UserId -> Db be ()
deleteDraft pid u = runDelete (delete wikiDb.drafts (\d -> d.page_id ==. val_ pid.text &&. d.author ==. val_ u.text))

--------------------------------------------------------------------------------
-- Settings

-- | A setting's value, by its name ('Nothing' for a setting that has no
-- row).
settingValue :: (Backend be) => Text -> Db be (Maybe Text)
settingValue key = runSelectReturningOne (select ((\r -> r.value) <$> filter_ (\r -> r.key ==. val_ key) (all_ wikiDb.settings)))

-- | The settings whose names start with this, by name.
settingsLike :: (Backend be) => Text -> Db be [(Text, Text)]
settingsLike prefix = runSelectReturningList (select ((\r -> (r.key, r.value)) <$> filter_ (\r -> r.key `like_` val_ (prefix <> "%")) (all_ wikiDb.settings)))

-- | Store a setting, in place of what it was.
storeSetting :: (Backend be) => Text -> Text -> Db be ()
storeSetting key value =
  runInsert $
    insertOnConflict
      wikiDb.settings
      (insertValues [S.SettingRow {key, value}])
      (conflictingFields (\r -> r.key))
      (onConflictUpdateSet (\r new -> r.value <-. new.value))

-- | Store a setting unless it has a value already. The result is its value
-- then.
keepSetting :: (Backend be) => Text -> Text -> Db be Text
keepSetting key value = do
  runInsert (insertOnConflict wikiDb.settings (insertValues [S.SettingRow {key, value}]) anyConflict onConflictDoNothing)
  fromMaybe value <$> settingValue key

-- | Delete the settings whose names start with this, but those named.
deleteSettingsLike :: (Backend be) => Text -> [Text] -> Db be ()
deleteSettingsLike prefix keep =
  runDelete (delete wikiDb.settings (\r -> r.key `like_` val_ (prefix <> "%") &&. Beam.not_ (r.key `in_` map val_ keep)))

-- | The wiki's settings, each from its row, or its default for a setting
-- that has no row or a value this program does not know:
--
-- > access                           open | closed
-- > new-accounts-create-spaces       0 | 1
-- > admin-creates-password-accounts  0 | 1
loadSettings :: (Backend be) => Db be WikiSettings
loadSettings = do
  rows <- runSelectReturningList (select ((\r -> (r.key, r.value)) <$> all_ wikiDb.settings))
  let valueOf key = snd <$> find ((== key) . fst) rows
      flag key def = maybe def (== "1") (valueOf key)
  pure
    WikiSettings
      { access = fromMaybe defaultSettings.access (valueOf "access" >>= readAccess)
      , newAccountsCreateSpaces = flag "new-accounts-create-spaces" defaultSettings.newAccountsCreateSpaces
      , adminCreatesPasswordAccounts = flag "admin-creates-password-accounts" defaultSettings.adminCreatesPasswordAccounts
      }

-- | Store the wiki's settings, each in its row.
storeSettings :: (Backend be) => WikiSettings -> Db be ()
storeSettings s =
  traverse_
    (uncurry storeSetting)
    [ ("access", accessName s.access)
    , ("new-accounts-create-spaces", oneOrZero s.newAccountsCreateSpaces)
    , ("admin-creates-password-accounts", oneOrZero s.adminCreatesPasswordAccounts)
    ]
  where
    oneOrZero b = if b then "1" else "0"

-- | Every invitation, the latest first, as of a given time (which decides
-- which have expired).
loadInvitations :: (Backend be) => UTCTime -> Db be [Invitation]
loadInvitations now = do
  rows <- runSelectReturningList (select (all_ wikiDb.invitations))
  pure
    ( sortOn
        (\i -> (Down i.createdAt, i.id))
        [ Invitation {id = InvitationId r.id, email = Email r.email, createdAt = r.created_at, expiresAt = r.expires_at, expired = r.expires_at <= now}
        | r <- rows
        ]
    )

-- | Store an invitation, under the hash of its link's secret, replacing
-- any invitation for the same address, whatever the case of its letters.
insertInvitation :: (Backend be) => Invitation -> Text -> Db be ()
insertInvitation i secretHash = do
  runDelete (delete wikiDb.invitations (\r -> lower_ r.email ==. lower_ (val_ i.email.text)))
  runInsert . insert wikiDb.invitations $
    insertValues [S.InvitationRow {id = i.id.text, email = i.email.text, token_hash = secretHash, created_at = micro i.createdAt, expires_at = micro i.expiresAt}]

-- | Delete an invitation. The result is the address it was for, if there
-- was one.
deleteInvitation :: (Backend be) => InvitationId -> Db be (Maybe Email)
deleteInvitation i = do
  email <- runSelectReturningOne (select ((\r -> r.email) <$> filter_ (\r -> r.id ==. val_ i.text) (all_ wikiDb.invitations)))
  runDelete (delete wikiDb.invitations (\r -> r.id ==. val_ i.text))
  pure (Email <$> email)

-- | The invitation whose link's secret has this hash, if it may be used at
-- this time (it has not expired): its id, and who it is for.
pendingInvitation :: (Backend be) => UTCTime -> Text -> Db be (Maybe (InvitationId, InvitationInfo))
pendingInvitation now secretHash = do
  row <- runSelectReturningOne (select (filter_ (\r -> r.token_hash ==. val_ secretHash) (all_ wikiDb.invitations)))
  pure $ case row of
    Just r | r.expires_at > now -> Just (InvitationId r.id, InvitationInfo {email = Email r.email, expiresAt = r.expires_at})
    _ -> Nothing

-- | Grant a user the global create-spaces directly.
grantCreateSpaces :: (Backend be) => UserId -> Db be ()
grantCreateSpaces u = setGlobalGrant True GlobalGrant {subject = SubjectUser u, permission = CreateSpaces}

--------------------------------------------------------------------------------
-- The server's own settings

-- | The server's settings: none where nothing is set. The address and the
-- mail server are rows of @settings@, absent when unset:
--
-- > public-url      https://wiki.example.org/
-- > mail-host       mail.example.org        (no mail without it)
-- > mail-port       587
-- > mail-security   tls | starttls | plain
-- > mail-user       the account, if the server wants one
-- > mail-password   its password
-- > mail-from       Wiki <wiki@example.org>
--
-- > assistant-hosts the writing assistant's hosts (WP5.21), one per line
--
-- The providers are rows of @sign_in_providers@, in the order their
-- buttons show. A provider of a kind this program does not know is left
-- out, and a mail server without a host counts as none.
loadServerSettings :: (Backend be) => Db be Kept
loadServerSettings = do
  rows <- concat <$> sequence [settingsLike "public-url", settingsLike "assistant-hosts", settingsLike "mail-"]
  providerRows <- runSelectReturningList (select (orderBy_ (\p -> (asc_ p.position, asc_ p.name)) (all_ wikiDb.sign_in_providers)))
  let valueOf key = mfilter (not . T.null) (snd <$> find ((== key) . fst) rows)
      port = fromMaybe defaultMailPort (valueOf "mail-port" >>= readMaybe)
  pure
    ServerSettings
      { publicUrl = Url <$> valueOf "public-url"
      , mail =
          valueOf "mail-host" <&> \host ->
            MailSettings
              { host
              , port
              , security = fromMaybe (securityFor port) (valueOf "mail-security" >>= readSecurity)
              , user = valueOf "mail-user"
              , password = Secret <$> valueOf "mail-password"
              , from = fromMaybe "" (valueOf "mail-from")
              }
      , providers =
          [ ProviderSettings {name = p.name, kind, clientId = p.client_id, issuer = Url <$> p.issuer, secret = Secret <$> mfilter (not . T.null) p.secret}
          | p <- providerRows
          , Just kind <- [readKind p.kind]
          ]
      , assistantHosts = maybe [] (filter (not . T.null) . map T.strip . T.lines) (valueOf "assistant-hosts")
      }

-- | Store the server's settings, replacing those stored before.
storeServerSettings :: (Backend be) => Kept -> Db be ()
storeServerSettings s = do
  deleteSettingsLike "public-url" []
  deleteSettingsLike "assistant-hosts" []
  deleteSettingsLike "mail-" []
  let rows =
        [("public-url", u.text) | Just u <- [s.publicUrl]]
          <> [("assistant-hosts", T.unlines s.assistantHosts) | not (null s.assistantHosts)]
          <> case s.mail of
            Nothing -> []
            Just m ->
              [ ("mail-host", m.host)
              , ("mail-port", show m.port)
              , ("mail-security", securityName m.security)
              , ("mail-from", m.from)
              ]
                <> [("mail-user", u) | Just u <- [m.user]]
                <> [("mail-password", revealed p) | Just p <- [m.password]]
  traverse_ (uncurry storeSetting) rows
  runDelete (delete wikiDb.sign_in_providers (\_ -> val_ True))
  for_ (zip [0 :: Int32 ..] s.providers) $ \(position, p) ->
    runInsert . insert wikiDb.sign_in_providers $
      insertValues [S.ProviderRow {name = p.name, position, kind = kindName p.kind, client_id = p.clientId, issuer = (\u -> u.text) <$> p.issuer, secret = revealed <$> p.secret}]
