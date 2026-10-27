{-# LANGUAGE BlockArguments #-}

-- | The wiki's records as the database's rows: how each column is written
-- and read, and the reads and writes of whole records that the storage's
-- operations ("Wiki.Server.Storage") are made of. Nothing here checks a
-- permission or a rule: these run inside a transaction that has.
--
-- The users, their accounts and identities, the groups and the grants are
-- read and written through persistent and esqueleto ('Sql', over the
-- entities of "Wiki.Server.Storage.Entities"), so that they run alike on
-- SQLite and PostgreSQL (WP5.7 of docs/PLAN.md, a spike); the rest is
-- sqlite-simple's, on the same connection ("Wiki.Server.Storage.Sql").
module Wiki.Server.Storage.Rows
  ( -- * Columns
    Stamp (..)
  , Sql
  , stamp
  , orderText
  , readOrder

    -- * Pages without their text
  , PageNode (..)
  , pageNodes
  , allPageNodes
  , pageNode

    -- * Reads
  , loadSpaces
  , loadGrants
  , loadUser
  , loadUserByLogin
  , loadActiveUser
  , loadUsers
  , loadGroupsOf
  , loadGroups
  , loadMembership
  , loadPage
  , loadPages
  , loadAllPages
  , loadAttachment
  , loadDraft
  , VersionRow (..)
  , loadVersions
  , loadSpaceVersions
  , loadCommentCounts
  , loadVersion
  , SearchRow (..)
  , loadSearchRows

    -- * Accounts
  , loadAccount
  , loadAccountByLogin
  , loadAccountList
  , loadPasswordHash
  , loadAccountFlags
  , insertAccount
  , updatePasswordHash
  , updateDisabled
  , deleteSessionsOf
  , totpEnabled
  , deleteSecondFactor
  , loadSecondFactorUsers
  , loadEmails

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

    -- * Writes
  , insertUser
  , insertGroup
  , insertMember
  , deleteMember
  , renameGroupRow
  , deleteGroupRows
  , deleteGlobalGrant
  , deleteSpaceGrant
  , insertGrants
  , insertSpace
  , updateSpace
  , insertPage
  , insertVersion
  , insertAttachment

    -- * Whom the wiki lets in
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
import Data.Time (UTCTime)
import Database.Esqueleto.Experimental
  ( Entity (..)
  , SqlExpr
  , Value (..)
  , asc
  , delete
  , deleteCount
  , exists
  , from
  , isNothing_
  , just
  , leftJoin
  , limit
  , lower_
  , not_
  , on
  , orderBy
  , select
  , table
  , val
  , where_
  , (&&.)
  , (:&) (..)
  , (==.)
  , (?.)
  , (^.)
  )
import Database.Esqueleto.Internal.Internal (veryUnsafeCoerceSqlExprValue)
import Database.Persist qualified as P
import Database.SQLite.Simple (Connection, Only (..), Query (..), SQLData, changes, execute, query, queryWith, queryWith_, query_)
import Database.SQLite.Simple.FromField (FieldParser, FromField (..), ResultError (..), returnError)
import Database.SQLite.Simple.FromRow (RowParser, field, fieldWith)
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude hiding (from, on)
import Wiki.Api.Account (Account (..), InvitationInfo (..), LinkedIdentity (..), providerOnly)
import Wiki.Api.Admin (Invitation (..), WikiSettings (..), defaultSettings)
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsOf (..), defaultMailPort, kindName, readKind, readSecurity, securityFor, securityName)
import Wiki.Core.Access (Access (..), accessName, readAccess)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Sibling (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (bodyText)
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Membership, User (..))
import Wiki.Server.Secret (Kept, Secret (..), revealed)
import Wiki.Server.Storage.Entities
import Wiki.Server.Storage.Sql (Sql)

--------------------------------------------------------------------------------
-- Columns

-- | A time column's time.
stamp :: RowParser UTCTime
stamp = (\(Stamp t) -> t) <$> field

-- | A slug column, read back through 'mkSlug', so that a slug read is one.
slugField :: RowParser Slug
slugField = fieldWith parse
  where
    parse :: FieldParser Slug
    parse f = fromField f >>= \t -> either (\e -> returnError ConversionFailed f ("not a slug: " <> show e)) pure (mkSlug t)

-- | The words for an order, which the export format writes too.
orderText :: ChildOrder -> Text
orderText = \case
  ByName -> "name"
  NewestFirst -> "newest-first"
  OldestFirst -> "oldest-first"
  ByHand -> "by-hand"

-- | An order from its word; the schema's check keeps it one of them.
readOrder :: Text -> ChildOrder
readOrder t = fromMaybe ByName (find (\o -> orderText o == t) [minBound .. maxBound])

orderField :: RowParser ChildOrder
orderField = readOrder <$> field

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

-- | A subject from its two columns; 'Nothing' for a kind the schema's check
-- does not let in.
subjectFrom :: Text -> Text -> Maybe Subject
subjectFrom kind i = case kind of
  "user" -> Just (SubjectUser (UserId i))
  "group" -> Just (SubjectGroup (GroupId i))
  _ -> Nothing

--------------------------------------------------------------------------------
-- Pages without their text

-- | A page's place in its space's tree, without its title's version, body
-- or attachments: what finding a page by its path, giving a slug, a
-- position or a subtree needs, read without the text of every page of a
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
  -- ^ Whether it is one of its space's templates: what a search that does
  -- not ask for them leaves out.
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

nodeColumns :: Text
nodeColumns = "id, space_id, parent, title, slug, created_at, position, template"

nodeRow :: RowParser PageNode
nodeRow = do
  id <- PageId <$> field
  space <- SpaceId <$> field
  parent <- fmap PageId <$> field
  title <- field
  slug <- slugField
  createdAt <- stamp
  position <- field
  template <- field
  pure PageNode {id, space, parent, title, slug, createdAt, position, template}

-- | The pages of a space, as nodes.
pageNodes :: Connection -> SpaceId -> IO [PageNode]
pageNodes c sid = queryWith nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages WHERE space_id = ?")) (Only sid.text)

-- | Every page of the wiki, as nodes.
allPageNodes :: Connection -> IO [PageNode]
allPageNodes c = queryWith_ nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages"))

-- | One page, as a node.
pageNode :: Connection -> PageId -> IO (Maybe PageNode)
pageNode c pid = head <$> queryWith nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages WHERE id = ?")) (Only pid.text)

--------------------------------------------------------------------------------
-- Reads

-- | A query put together from pieces of text.
sql :: Text -> Query
sql = Query

spaceColumns :: Text
spaceColumns = "id, parent, name, slug, public, math_macros, created_at, position, subspace_order, page_order, home_page, icon, description, blog"

spaceRow :: RowParser Space
spaceRow = do
  id <- SpaceId <$> field
  parent <- fmap SpaceId <$> field
  name <- field
  slug <- slugField
  public <- field
  mathMacros <- field
  createdAt <- stamp
  position <- field
  subspaceOrder <- orderField
  pageOrder <- orderField
  homePage <- fmap PageId <$> field
  -- An icon that does not read (one a later program wrote) is the
  -- default, as the export reads it.
  icon <- (>>= decodeStrict' . encodeUtf8) <$> (field :: RowParser (Maybe Text))
  description <- field
  blog <- field
  pure Space {id, parent, name, slug, public, mathMacros, createdAt, position, subspaceOrder, pageOrder, homePage, icon, description, blog}

-- | Every space, by id: a wiki has tens of them, and every permission is a
-- question about a space's chain of ancestors, so each operation reads them
-- all.
loadSpaces :: Connection -> IO (Map SpaceId Space)
loadSpaces c = Map.fromList . map (\s -> (s.id, s)) <$> queryWith_ spaceRow c (sql ("SELECT " <> spaceColumns <> " FROM spaces"))

-- | Every grant, global and on spaces, in the order they were given.
loadGrants :: Sql Grants
loadGrants = do
  globals <- select do
    g <- from (table @GlobalGrantRow)
    orderBy [asc (g ^. GlobalGrantRowId)]
    pure g
  spaceGrants <- select do
    g <- from (table @SpaceGrantRow)
    orderBy [asc (g ^. SpaceGrantRowId)]
    pure g
  pure
    Grants
      { global =
          [ GlobalGrant {subject, permission}
          | Entity _ g <- globals
          , Just subject <- [subjectFrom g.subjectKind g.subjectId]
          , Just permission <- [find (\x -> globalText x == g.permission) [minBound .. maxBound]]
          ]
      , spaces =
          [ SpaceGrant {space = SpaceId g.spaceId, subject, permission}
          | Entity _ g <- spaceGrants
          , Just subject <- [subjectFrom g.subjectKind g.subjectId]
          , Just permission <- [find (\x -> spaceText x == g.permission) [minBound .. maxBound]]
          ]
      , -- The wiki's setting, which the storage reads with the grants
        -- where it is asked about (Wiki.Server.Storage), is not a row of
        -- theirs.
        access = Open
      }

-- | A user's row's key.
userKey :: UserId -> Key UserRow
userKey u = UserRowKey u.text

-- | A user from their row.
userOf :: Entity UserRow -> User
userOf (Entity (UserRowKey id) r) = User {id = UserId id, login = r.login, displayName = r.displayName}

-- | A user by id.
loadUser :: UserId -> Sql (Maybe User)
loadUser u = fmap userOf <$> P.getEntity (userKey u)

-- | A user by id who may act: not one whose login is disabled.
loadActiveUser :: UserId -> Sql (Maybe User)
loadActiveUser u =
  fmap userOf . head <$> select do
    r <- from (table @UserRow)
    where_ (r ^. UserRowId ==. val (userKey u) &&. not_ (r ^. UserRowDisabled))
    pure r

-- | A user by login.
loadUserByLogin :: Text -> Sql (Maybe User)
loadUserByLogin login = fmap userOf <$> P.getBy (UniqueLogin login)

-- | Every user, by id.
loadUsers :: Sql [User]
loadUsers =
  map userOf <$> select do
    r <- from (table @UserRow)
    orderBy [asc (r ^. UserRowId)]
    pure r

-- | The groups a user is in.
loadGroupsOf :: UserId -> Sql (Set GroupId)
loadGroupsOf u =
  Set.fromList . map (\(Value (GroupRowKey g)) -> GroupId g) <$> select do
    m <- from (table @GroupMemberRow)
    where_ (m ^. GroupMemberRowUserId ==. val (userKey u))
    pure (m ^. GroupMemberRowGroupId)

-- | Every group, by id.
loadGroups :: Sql [Group]
loadGroups =
  map (\(Entity (GroupRowKey id) g) -> Group {id = GroupId id, name = g.name}) <$> select do
    g <- from (table @GroupRow)
    orderBy [asc (g ^. GroupRowId)]
    pure g

-- | Every group's members.
loadMembership :: Sql Membership
loadMembership = do
  rows <- select (from (table @GroupMemberRow))
  pure (Map.fromListWith (<>) [(GroupId g, Set.singleton (UserId u)) | Entity _ GroupMemberRow {groupId = GroupRowKey g, userId = UserRowKey u} <- rows])

pageColumns :: Text
pageColumns = "id, space_id, parent, title, slug, body, created_at, updated_at, position, template"

-- | A page's row, waiting for its attachments.
pageRow :: RowParser ([Attachment] -> Page)
pageRow = do
  id <- PageId <$> field
  space <- SpaceId <$> field
  parent <- fmap PageId <$> field
  title <- field
  slug <- slugField
  body <- field
  createdAt <- stamp
  updatedAt <- stamp
  position <- field
  template <- field
  pure (\attachments -> Page {id, space, parent, title, slug, body, attachments, createdAt, updatedAt, position, template})

attachmentColumns :: Text
attachmentColumns = "a.id, a.name, a.media_type, a.size, a.url, a.blob"

-- | An attachment's row, with the page it is on.
attachmentRow :: RowParser (PageId, Attachment)
attachmentRow = do
  id <- AttachmentId <$> field
  name <- field
  mediaType <- field
  size <- fromIntegral @Int64 <$> field
  url <- field
  blob <- field
  page <- PageId <$> field
  let source = maybe (SourceBlob (BlobId (fromMaybe "" blob))) SourceUrl url
  pure (page, Attachment {id, name, mediaType, size, source})

-- | Pages with their attachments, each page's in their order.
withAttachments :: [[Attachment] -> Page] -> [(PageId, Attachment)] -> [Page]
withAttachments rows attached = [p (Map.findWithDefault [] (p []).id byPage) | p <- rows]
  where
    byPage = Map.fromListWith (flip (<>)) [(pid, [a]) | (pid, a) <- attached]

-- | A page with its attachments.
loadPage :: Connection -> PageId -> IO (Maybe Page)
loadPage c pid = do
  rows <- queryWith pageRow c (sql ("SELECT " <> pageColumns <> " FROM pages WHERE id = ?")) (Only pid.text)
  attached <- queryWith attachmentRow c (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a WHERE a.page_id = ? ORDER BY a.ordinal")) (Only pid.text)
  pure (head (withAttachments rows attached))

-- | The pages of a space with their attachments, in no particular order.
loadPages :: Connection -> SpaceId -> IO [Page]
loadPages c sid = do
  rows <- queryWith pageRow c (sql ("SELECT " <> pageColumns <> " FROM pages WHERE space_id = ?")) (Only sid.text)
  attached <-
    queryWith
      attachmentRow
      c
      (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a JOIN pages p ON p.id = a.page_id WHERE p.space_id = ? ORDER BY a.ordinal"))
      (Only sid.text)
  pure (withAttachments rows attached)

-- | Every page of the wiki with its attachments, by id.
loadAllPages :: Connection -> IO [Page]
loadAllPages c = do
  rows <- queryWith_ pageRow c (sql ("SELECT " <> pageColumns <> " FROM pages ORDER BY id"))
  attached <- queryWith_ attachmentRow c (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a ORDER BY a.ordinal"))
  pure (withAttachments rows attached)

-- | An attachment, with the page it is on.
loadAttachment :: Connection -> AttachmentId -> IO (Maybe (PageId, Attachment))
loadAttachment c aid = head <$> queryWith attachmentRow c (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a WHERE a.id = ?")) (Only aid.text)

-- | A user's draft of a page.
loadDraft :: Connection -> PageId -> UserId -> IO (Maybe Draft)
loadDraft c page author = head <$> queryWith row c "SELECT title, body, base, saved_at FROM drafts WHERE page_id = ? AND author = ?" (page.text, author.text)
  where
    row = do
      title <- field
      body <- field
      base <- stamp
      savedAt <- stamp
      pure Draft {page, author, title, body, base, savedAt}

-- | A version of a page as its row has it, with the display name of its
-- author if they are one of the users.
data VersionRow = VersionRow
  { updatedAt :: UTCTime
  , title :: Text
  , body :: Text
  , author :: Maybe UserId
  , authorName :: Maybe Text
  }

-- | Every version of a page, in no particular order: the times are text,
-- whose order is not the times' (a time without a fraction sorts after one
-- with), so the caller orders them. Without their bodies, which a history's
-- list does not show.
loadVersions :: Connection -> PageId -> IO [VersionRow]
loadVersions c page =
  queryWith
    versionRow
    c
    "SELECT v.updated_at, v.title, '', v.author, u.display_name FROM page_versions v LEFT JOIN users u ON u.id = v.author WHERE v.page_id = ?"
    (Only page.text)

-- | Every version of every page of a space, without their bodies, by
-- page: what the first author of each is read from. In no particular
-- order, as 'loadVersions'.
loadSpaceVersions :: Connection -> SpaceId -> IO [(PageId, VersionRow)]
loadSpaceVersions c space =
  queryWith
    ((,) <$> (PageId <$> field) <*> versionRow)
    c
    "SELECT v.page_id, v.updated_at, v.title, '', v.author, u.display_name FROM page_versions v JOIN pages p ON p.id = v.page_id LEFT JOIN users u ON u.id = v.author WHERE p.space_id = ?"
    (Only space.text)

-- | How many comments each page of a space has, in all its threads; a page
-- with none is left out.
loadCommentCounts :: Connection -> SpaceId -> IO [(PageId, Int)]
loadCommentCounts c space =
  map (first PageId)
    <$> query
      c
      "SELECT t.page_id, count(*) FROM comments m JOIN threads t ON t.id = m.thread_id JOIN pages p ON p.id = t.page_id WHERE p.space_id = ? GROUP BY t.page_id"
      (Only space.text)

-- | One version of a page, whole, by its time.
loadVersion :: Connection -> PageId -> UTCTime -> IO (Maybe VersionRow)
loadVersion c page at =
  head
    <$> queryWith
      versionRow
      c
      "SELECT v.updated_at, v.title, v.body, v.author, u.display_name FROM page_versions v LEFT JOIN users u ON u.id = v.author WHERE v.page_id = ? AND v.updated_at = ?"
      (page.text, Stamp at)

versionRow :: RowParser VersionRow
versionRow = VersionRow <$> stamp <*> field <*> field <*> (fmap UserId <$> field) <*> field

-- | A page as the search reads it: its place, its title, and its text
-- prepared when it was saved.
data SearchRow = SearchRow
  { node :: PageNode
  , text :: Text
  }

-- | Every page, as the search reads it.
loadSearchRows :: Connection -> IO [SearchRow]
loadSearchRows c = queryWith_ row c (sql ("SELECT " <> nodeColumns <> ", search_text FROM pages"))
  where
    row = SearchRow <$> nodeRow <*> field

--------------------------------------------------------------------------------
-- Writes

-- | Add a user, with no password.
insertUser :: User -> Sql ()
insertUser u = P.insertKey (userKey u.id) (newUser u Nothing)

-- | A new user's row, with the hash of their password if they have one. An
-- entity is written whole, so the schema's defaults for the other columns
-- (migrations/0002, 0008 and 0011) are said again here.
newUser :: User -> Maybe Text -> UserRow
newUser u phc =
  UserRow
    { login = u.login
    , displayName = u.displayName
    , passwordHash = phc
    , disabled = False
    , email = Nothing
    , emailVerifiedAt = Nothing
    , notificationMail = Nothing
    , watchOwn = True
    }

-- | Add a group.
insertGroup :: Group -> Sql ()
insertGroup g = P.insertKey (GroupRowKey g.id.text) GroupRow {name = g.name}

-- | Put a user in a group, if they are not in it.
insertMember :: GroupId -> UserId -> Sql ()
insertMember g u = do
  let key = GroupMemberRowKey (GroupRowKey g.text) (userKey u)
  there <- P.get key
  when (isNothing there) (P.insertKey key GroupMemberRow {groupId = GroupRowKey g.text, userId = userKey u})

-- | Take a user out of a group.
deleteMember :: GroupId -> UserId -> Sql ()
deleteMember g u = P.delete (GroupMemberRowKey (GroupRowKey g.text) (userKey u))

-- | Give a group another name.
renameGroupRow :: GroupId -> Text -> Sql ()
renameGroupRow g name = P.update (GroupRowKey g.text) [GroupRowName P.=. name]

-- | Delete a group: its members go with it (a foreign key), and so must
-- the grants to it, which name it in a column that is no foreign key.
deleteGroupRows :: GroupId -> Sql ()
deleteGroupRows g = do
  delete do
    r <- from (table @GlobalGrantRow)
    where_ (r ^. GlobalGrantRowSubjectKind ==. val "group" &&. r ^. GlobalGrantRowSubjectId ==. val g.text)
  delete do
    r <- from (table @SpaceGrantRow)
    where_ (r ^. SpaceGrantRowSubjectKind ==. val "group" &&. r ^. SpaceGrantRowSubjectId ==. val g.text)
  P.delete (GroupRowKey g.text)

-- | Take back a global grant, if it was given.
deleteGlobalGrant :: GlobalGrant -> Sql ()
deleteGlobalGrant g =
  let (kind, i) = subjectColumns g.subject
   in P.deleteBy (UniqueGlobalGrant kind i (globalText g.permission))

deleteSpaceGrant :: SpaceGrant -> Sql ()
deleteSpaceGrant g =
  let (kind, i) = subjectColumns g.subject
   in P.deleteBy (UniqueSpaceGrant g.space.text kind i (spaceText g.permission))

-- | Give these grants, in their order; one already given is left as it is
-- (and keeps its place).
insertGrants :: Grants -> Sql ()
insertGrants grants = do
  for_ grants.global $ \g ->
    let (kind, i) = subjectColumns g.subject
     in void (P.insertUnique GlobalGrantRow {subjectKind = kind, subjectId = i, permission = globalText g.permission})
  for_ grants.spaces $ \g ->
    let (kind, i) = subjectColumns g.subject
     in void (P.insertUnique SpaceGrantRow {spaceId = g.space.text, subjectKind = kind, subjectId = i, permission = spaceText g.permission})

spaceValues :: Space -> [SQLData]
spaceValues s =
  [ toField s.id.text
  , toField (fmap (\p -> p.text) s.parent)
  , toField s.name
  , toField (slugText s.slug)
  , toField s.public
  , toField s.mathMacros
  , toField (Stamp s.createdAt)
  , toField s.position
  , toField (orderText s.subspaceOrder)
  , toField (orderText s.pageOrder)
  , toField (fmap (\p -> p.text) s.homePage)
  , toField (fmap (decodeUtf8 . BSL.toStrict . encode) s.icon :: Maybe Text)
  , toField s.description
  , toField s.blog
  ]

-- | Add a space.
insertSpace :: Connection -> Space -> IO ()
insertSpace c s = execute c (sql ("INSERT INTO spaces (" <> spaceColumns <> ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")) (spaceValues s)

-- | Write a space over the one with its id: every column of it.
updateSpace :: Connection -> Space -> IO ()
updateSpace c s =
  execute
    c
    "UPDATE spaces SET parent = ?, name = ?, slug = ?, public = ?, math_macros = ?, created_at = ?, position = ?, subspace_order = ?, page_order = ?, home_page = ?, icon = ?, description = ?, blog = ? WHERE id = ?"
    (drop 1 (spaceValues s) <> [toField s.id.text])

-- | Add a page, without its attachments, with the text the search compares
-- queries with prepared from its body.
insertPage :: Connection -> Page -> IO ()
insertPage c p =
  execute
    c
    (sql ("INSERT INTO pages (" <> pageColumns <> ", search_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"))
    [ toField p.id.text
    , toField p.space.text
    , toField (fmap (\x -> x.text) p.parent)
    , toField p.title
    , toField (slugText p.slug)
    , toField p.body
    , toField (Stamp p.createdAt)
    , toField (Stamp p.updatedAt)
    , toField p.position
    , toField p.template
    , toField (bodyText p.body)
    ]

-- | Keep a version of a page: its title and body as of its @updatedAt@, and
-- who saved it, if anyone is known to have.
insertVersion :: Connection -> Page -> Maybe UserId -> IO ()
insertVersion c p author =
  execute
    c
    "INSERT INTO page_versions (page_id, updated_at, title, body, author) VALUES (?, ?, ?, ?, ?)"
    (p.id.text, Stamp p.updatedAt, p.title, p.body, fmap (\u -> u.text) author)

-- | Attach an attachment to a page, at a place among the page's.
insertAttachment :: Connection -> PageId -> Int -> Attachment -> IO ()
insertAttachment c page ordinal a =
  execute
    c
    "INSERT INTO attachments (id, page_id, name, media_type, size, url, blob, ordinal) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    [ toField a.id.text
    , toField page.text
    , toField a.name
    , toField a.mediaType
    , toField (fromIntegral a.size :: Int64)
    , toField url
    , toField blob
    , toField ordinal
    ]
  where
    (url, blob) = case a.source of
      SourceUrl u -> (Just u, Nothing)
      SourceBlob b -> (Nothing, Just b.text)

--------------------------------------------------------------------------------
-- Accounts

-- | A user's account from their row.
accountOf :: Entity UserRow -> Account
accountOf e@(Entity _ r) = Account {user = userOf e, hasPassword = isJust r.passwordHash, disabled = r.disabled}

-- | A user's account, by id.
loadAccount :: UserId -> Sql (Maybe Account)
loadAccount u = fmap accountOf <$> P.getEntity (userKey u)

-- | Logins compared without case: SQLite's @lower@ folds ASCII letters
-- only, as the @COLLATE NOCASE@ this replaced did; PostgreSQL's folds every
-- letter its locale knows.
sameLogin :: SqlExpr (Value Text) -> Text -> SqlExpr (Value Bool)
sameLogin column login = lower_ column ==. lower_ (val login)

-- | A user's account, by login compared without case, with the hash of
-- their password if they have one: what someone types to sign in.
loadAccountByLogin :: Text -> Sql (Maybe (Account, Maybe Text))
loadAccountByLogin login =
  fmap (\e@(Entity _ r) -> (accountOf e, r.passwordHash)) . head <$> select do
    r <- from (table @UserRow)
    where_ (r ^. UserRowLogin `sameLogin` login)
    pure r

-- | Every user's account, by login compared without case, with whether they
-- are an administrator (hold the global @administer@ themselves).
loadAccountList :: Sql [(Account, Bool)]
loadAccountList =
  map (\(e, Value admin) -> (accountOf e, admin)) <$> select do
    r <- from (table @UserRow)
    orderBy [asc (lower_ (r ^. UserRowLogin))]
    let administrator = exists do
          g <- from (table @GlobalGrantRow)
          where_
            ( g ^. GlobalGrantRowSubjectKind ==. val "user"
                &&. g ^. GlobalGrantRowSubjectId ==. unKey (r ^. UserRowId)
                &&. g ^. GlobalGrantRowPermission ==. val (globalText Administer)
            )
    pure (r, administrator)
  where
    -- A user's key as the text a grant names them by. A grant's subject is
    -- a user's id or a group's, by its kind, which no foreign key and so no
    -- type of esqueleto's says; the key is text in the database, and the
    -- comparison is made there, with esqueleto's own escape hatch.
    unKey :: SqlExpr (Value (Key UserRow)) -> SqlExpr (Value Text)
    unKey = veryUnsafeCoerceSqlExprValue

-- | The users who are disabled, and those who have a password.
loadAccountFlags :: Sql (Set UserId, Set UserId)
loadAccountFlags = do
  rows <- select do
    r <- from (table @UserRow)
    pure (r ^. UserRowId, r ^. UserRowDisabled, not_ (isNothing_ (r ^. UserRowPasswordHash)))
  pure
    ( Set.fromList [UserId u | (Value (UserRowKey u), Value True, _) <- rows]
    , Set.fromList [UserId u | (Value (UserRowKey u), _, Value True) <- rows]
    )

-- | A user's password's hash, if they are there: 'Nothing' for a user who
-- is not, @Just Nothing@ for one without a password.
loadPasswordHash :: UserId -> Sql (Maybe (Maybe Text))
loadPasswordHash u = fmap (\r -> r.passwordHash) <$> P.get (userKey u)

-- | A new user with a login no other user has, whatever its case, or a
-- 'Left' with the login that is taken; the login and the password's hash
-- are as they are to be kept.
insertAccount :: UserId -> Text -> Text -> Maybe Text -> Sql (Either Text Account)
insertAccount u login displayName phc = do
  taken <- select do
    r <- from (table @UserRow)
    where_ (r ^. UserRowLogin `sameLogin` login)
    limit 1
    pure (r ^. UserRowId)
  if not (null taken)
    then pure (Left login)
    else do
      P.insertKey (userKey u) (newUser User {id = u, login, displayName} phc)
      maybe (Left login) Right <$> loadAccount u

-- | A user's password, as its hash, in place of the one they had.
updatePasswordHash :: UserId -> Text -> Sql ()
updatePasswordHash u phc = P.update (userKey u) [UserRowPasswordHash P.=. Just phc]

-- | Whether a user is disabled.
updateDisabled :: UserId -> Bool -> Sql ()
updateDisabled u disabled = P.update (userKey u) [UserRowDisabled P.=. disabled]

-- | End every session of a user.
deleteSessionsOf :: UserId -> Sql ()
deleteSessionsOf u = P.deleteWhere [SessionRowUserId P.==. userKey u]

-- | Whether a user has a second factor that signing in asks for: one that
-- they have confirmed (migrations/0008-account-hygiene.sql).
totpEnabled :: UserId -> Sql Bool
totpEnabled u =
  not . null <$> select do
    t <- from (table @TotpRow)
    where_ (t ^. TotpRowUserId ==. val (userKey u) &&. not_ (isNothing_ (t ^. TotpRowEnabledAt)))
    pure (t ^. TotpRowUserId)

-- | Take a user's second factor away, begun or on, with its recovery
-- codes: whether they had one on.
deleteSecondFactor :: UserId -> Sql Bool
deleteSecondFactor u = do
  had <- totpEnabled u
  P.deleteWhere [TotpRowUserId P.==. userKey u]
  P.deleteWhere [RecoveryCodeRowUserId P.==. userKey u]
  pure had

-- | The users who have a second factor.
loadSecondFactorUsers :: Sql (Set UserId)
loadSecondFactorUsers =
  Set.fromList . map (\(Value (UserRowKey u)) -> UserId u) <$> select do
    t <- from (table @TotpRow)
    where_ (not_ (isNothing_ (t ^. TotpRowEnabledAt)))
    pure (t ^. TotpRowUserId)

-- | The e-mail addresses users have given, and whether each is verified.
loadEmails :: Sql (Map UserId AccountEmail)
loadEmails = do
  rows <- P.selectList [UserRowEmail P.!=. Nothing] []
  pure
    ( Map.fromList
        [ (UserId u, AccountEmail {email, verified = isJust r.emailVerifiedAt})
        | Entity (UserRowKey u) r <- rows
        , Just email <- [r.email]
        ]
    )

--------------------------------------------------------------------------------
-- Identities

-- | An identity as its row has it (migrations/0004-identities.sql).
data IdentityRow = IdentityRow
  { provider :: Text
  , subject :: Text
  , user :: UserId
  , identity :: LinkedIdentity
  }

-- | The identity a provider's account is, if it is anyone's.
identityOf :: Text -> Text -> Sql (Maybe IdentityRow)
identityOf provider subject = fmap identityRow <$> P.get (IdentityEntityKey provider subject)

-- | A user's identities, by provider.
identitiesOf :: UserId -> Sql [IdentityRow]
identitiesOf u =
  map (\(Entity _ i) -> identityRow i) <$> select do
    i <- from (table @IdentityEntity)
    where_ (i ^. IdentityEntityUserId ==. val (userKey u))
    orderBy [asc (i ^. IdentityEntityProvider)]
    pure i

identityRow :: IdentityEntity -> IdentityRow
identityRow i =
  let Stamp linkedAt = i.linkedAt
      UserRowKey u = i.userId
   in IdentityRow
        { provider = i.provider
        , subject = i.subject
        , user = UserId u
        , identity = LinkedIdentity {provider = i.provider, email = i.email, name = i.displayName, linkedAt}
        }

-- | Connect a provider's account to a user. The caller has made sure that
-- it is no one's, and that the user has none at that provider.
insertIdentity :: UTCTime -> UserId -> Text -> Text -> Maybe Text -> Maybe Text -> Sql ()
insertIdentity now u provider subject email name =
  P.insert_ IdentityEntity {provider, subject, userId = userKey u, email, displayName = name, linkedAt = Stamp now}

-- | What a provider says of an account now, kept for the next time it is
-- shown.
refreshIdentity :: Text -> Text -> Maybe Text -> Maybe Text -> Sql ()
refreshIdentity provider subject email name =
  P.update (IdentityEntityKey provider subject) [IdentityEntityEmail P.=. email, IdentityEntityDisplayName P.=. name]

-- | Disconnect a user's account at a provider: whether they had one.
deleteIdentity :: UserId -> Text -> Sql Bool
deleteIdentity u provider =
  fmap (> 0) . deleteCount $ do
    i <- from (table @IdentityEntity)
    where_ (i ^. IdentityEntityUserId ==. val (userKey u) &&. i ^. IdentityEntityProvider ==. val provider)

-- | The providers each user has an identity at, by user.
loadIdentityProviders :: Sql (Map UserId [Text])
loadIdentityProviders = do
  rows <- select do
    i <- from (table @IdentityEntity)
    orderBy [asc (i ^. IdentityEntityProvider)]
    pure (i ^. IdentityEntityUserId, i ^. IdentityEntityProvider)
  pure (Map.fromListWith (flip (<>)) [(UserId u, [p]) | (Value (UserRowKey u), Value p) <- rows])

-- | The names of the providers the server's settings sign people in with.
providerNames :: Kept -> [Text]
providerNames kept = map (\p -> p.name) kept.providers

-- | Whether a user has no password to set (WP5.6 of docs/PLAN.md,
-- 'Wiki.Api.Account.providerOnly'): they have none, and an identity at one
-- of these providers, the ones the server's settings have. One read: the
-- user with each of their identities, or with none.
noPasswordToSet :: [Text] -> UserId -> Sql Bool
noPasswordToSet configured u = do
  rows <- select do
    (r :& i) <-
      from $
        table @UserRow
          `leftJoin` table @IdentityEntity
            `on` (\(r :& i) -> just (r ^. UserRowId) ==. i ?. IdentityEntityUserId)
    where_ (r ^. UserRowId ==. val (userKey u))
    pure (r ^. UserRowPasswordHash, i ?. IdentityEntityProvider)
  pure (providerOnly configured (any (\(Value phc, _) -> isJust phc) rows) [p | (_, Value (Just p)) <- rows])

--------------------------------------------------------------------------------
-- Password resets

-- | Keep a reset's link for a user (migrations/0008-account-hygiene.sql):
-- the hash of its secret, when it was made, and when it expires.
insertResetToken :: Connection -> UserId -> Text -> UTCTime -> UTCTime -> IO ()
insertResetToken c u secretHash made expires =
  execute c "INSERT INTO reset_tokens (token_hash, user_id, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, NULL)" (secretHash, u.text, Stamp made, Stamp expires)

-- | How many reset links a user has been given since a time, used or not.
resetsSince :: Connection -> UserId -> UTCTime -> IO Int
resetsSince c u since = maybe 0 fromOnly . head <$> query c "SELECT count(*) FROM reset_tokens WHERE user_id = ? AND created_at > ?" (u.text, Stamp since)

--------------------------------------------------------------------------------
-- Whom the wiki lets in

-- | The wiki's settings, each from its row, or its default for one that
-- has none (migrations/0003-settings.sql), or a value this program does
-- not know.
loadSettings :: Connection -> IO WikiSettings
loadSettings c = do
  rows :: [(Text, Text)] <- query_ c "SELECT key, value FROM settings"
  let valueOf key = snd <$> find ((== key) . fst) rows
  pure
    WikiSettings
      { access = fromMaybe defaultSettings.access (valueOf "access" >>= readAccess)
      , newAccountsCreateSpaces = maybe defaultSettings.newAccountsCreateSpaces (== "1") (valueOf "new-accounts-create-spaces")
      }

-- | Keep the wiki's settings, each in its row.
storeSettings :: Connection -> WikiSettings -> IO ()
storeSettings c s =
  for_ [("access", accessName s.access), ("new-accounts-create-spaces", if s.newAccountsCreateSpaces then "1" else "0")] $ \(key, value :: Text) ->
    execute c "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value" (key :: Text, value)

-- | Every invitation, the latest first, as at a time (which decides which
-- have expired).
loadInvitations :: Connection -> UTCTime -> IO [Invitation]
loadInvitations c now = do
  rows <- query_ c "SELECT id, email, created_at, expires_at FROM invitations"
  pure
    ( sortOn
        (\i -> (Down i.createdAt, i.id))
        [ Invitation {id = InvitationId i, email, createdAt, expiresAt, expired = expiresAt <= now}
        | (i, email, Stamp createdAt, Stamp expiresAt) <- rows
        ]
    )

-- | Keep an invitation, under the hash of its link's secret, in place of
-- any its address had.
insertInvitation :: Connection -> Invitation -> Text -> IO ()
insertInvitation c i secretHash = do
  execute c "DELETE FROM invitations WHERE email = ? COLLATE NOCASE" (Only i.email)
  execute c "INSERT INTO invitations (id, email, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)" (i.id.text, i.email, secretHash, Stamp i.createdAt, Stamp i.expiresAt)

-- | Delete an invitation: whether there was one.
deleteInvitation :: Connection -> InvitationId -> IO Bool
deleteInvitation c i = do
  execute c "DELETE FROM invitations WHERE id = ?" (Only i.text)
  (> 0) <$> changes c

-- | The invitation whose link's secret has this hash, if it may be used at
-- this time (it has not expired): its id, and whom it is for.
pendingInvitation :: Connection -> UTCTime -> Text -> IO (Maybe (InvitationId, InvitationInfo))
pendingInvitation c now secretHash = do
  rows <- query c "SELECT id, email, expires_at FROM invitations WHERE token_hash = ?" (Only secretHash)
  pure $ case rows of
    [(i, email, Stamp expiresAt)] | expiresAt > now -> Just (InvitationId i, InvitationInfo {email, expiresAt})
    _ -> Nothing

-- | Grant a user the global create-spaces themself.
grantCreateSpaces :: UserId -> Sql ()
grantCreateSpaces u = insertGrants Grants {global = [GlobalGrant {subject = SubjectUser u, permission = CreateSpaces}], spaces = [], access = Open}

--------------------------------------------------------------------------------
-- The server's own settings

-- | The server's settings (migrations/0005-server-settings.sql): none
-- where nothing is set. A provider of a kind this program does not know
-- is left out, and a mail server without its host is none.
loadServerSettings :: Connection -> IO Kept
loadServerSettings c = do
  rows :: [(Text, Text)] <- query_ c "SELECT key, value FROM settings WHERE key = 'public-url' OR key LIKE 'mail-%'"
  providerRows :: [(Text, Text, Text, Maybe Text, Maybe Text)] <- query_ c "SELECT name, kind, client_id, issuer, secret FROM sign_in_providers ORDER BY position, name"
  let valueOf key = mfilter (not . T.null) (snd <$> find ((== key) . fst) rows)
      port = fromMaybe defaultMailPort (valueOf "mail-port" >>= readMaybe)
  pure
    ServerSettings
      { publicUrl = valueOf "public-url"
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
          [ ProviderSettings {name, kind, clientId, issuer, secret = Secret <$> mfilter (not . T.null) secret}
          | (name, k, clientId, issuer, secret) <- providerRows
          , Just kind <- [readKind k]
          ]
      }

-- | Keep the server's settings, in place of those kept before.
storeServerSettings :: Connection -> Kept -> IO ()
storeServerSettings c s = do
  execute_' "DELETE FROM settings WHERE key = 'public-url' OR key LIKE 'mail-%'"
  let rows =
        [("public-url", u) | Just u <- [s.publicUrl]]
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
  for_ rows $ \(key :: Text, value :: Text) -> execute c "INSERT INTO settings (key, value) VALUES (?, ?)" (key, value)
  execute_' "DELETE FROM sign_in_providers"
  for_ (zip [0 :: Int ..] s.providers) $ \(position, p) ->
    execute
      c
      "INSERT INTO sign_in_providers (name, position, kind, client_id, issuer, secret) VALUES (?, ?, ?, ?, ?, ?)"
      (p.name, position, kindName p.kind, p.clientId, p.issuer, revealed <$> p.secret)
  where
    execute_' q = execute c q ()
