-- | The wiki's records as database rows: how each column is written and
-- read, and the reads and writes of whole records that the storage's
-- operations ("Wiki.Server.Storage") are made of. Nothing here checks a
-- permission or a rule: these run inside a transaction that has already
-- checked them.
module Wiki.Server.Storage.Rows
  ( -- * Columns
    Stamp (..)
  , stamp
  , orderText
  , readOrder

    -- * Pages without their text
  , PageNode (..)
  , pageNodes
  , allPageNodes
  , pageNode
  , pageNodesWithIds
  , childPage
  , childPages
  , subtreeIds
  , SitemapNode (..)
  , loadSitemapNodes

    -- * Reads
  , loadSpaces
  , loadChain
  , loadGrants
  , loadGrantsOn
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
  , SearchRow (..)
  , loadSearchMatches

    -- * Accounts
  , AccountRow
  , accountFromRow
  , selectAccounts
  , loadAccount
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
  , updatePageText
  , fillSearchFolds
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
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Database.SQLite.Simple (Connection, Only (..), Query (..), SQLData, changes, execute, execute_, query, queryWith, queryWith_, query_)
import Database.SQLite.Simple.FromField (FieldParser, FromField (..), ResultError (..), returnError)
import Database.SQLite.Simple.FromRow (RowParser, field, fieldWith)
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude
import Wiki.Api.Account (Account (..), InvitationInfo (..), LinkedIdentity (..), providerOnly)
import Wiki.Api.Admin (Invitation (..), WikiSettings (..), defaultSettings)
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsOf (..), defaultMailPort, kindName, readKind, readSecurity, securityFor, securityName)
import Wiki.Core.Access (Access (..), accessName, readAccess)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Sibling (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (bodyText, foldText)
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Membership, User (..))
import Wiki.Server.Secret (Kept, Secret (..), revealed)

--------------------------------------------------------------------------------
-- Columns

-- | A time as a column: ISO 8601 text in UTC with every digit of the
-- fraction of a second. Not sqlite-simple's own 'UTCTime' columns: a save
-- is checked against the time it started from by equality, so a time must
-- come back exactly as it went in, which only writing every digit
-- guarantees.
newtype Stamp = Stamp UTCTime

instance ToField Stamp where
  toField (Stamp t) = toField (T.pack (iso8601Show t))

instance FromField Stamp where
  fromField f =
    fromField f >>= \t -> case iso8601ParseM (T.unpack t) of
      Just time -> pure (Stamp time)
      Nothing -> returnError ConversionFailed f ("not a time: " <> T.unpack t)

-- | A time column's time.
stamp :: RowParser UTCTime
stamp = (\(Stamp t) -> t) <$> field

-- | A slug column, read back through 'mkSlug', so that what is read is a
-- valid slug.
slugField :: RowParser Slug
slugField = fieldWith parse
  where
    parse :: FieldParser Slug
    parse f = fromField f >>= \t -> either (\e -> returnError ConversionFailed f ("not a slug: " <> show e)) pure (mkSlug t)

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

-- | A subject from its two columns; 'Nothing' for a kind the schema's
-- check does not allow.
subjectFrom :: Text -> Text -> Maybe Subject
subjectFrom kind i = case kind of
  "user" -> Just (SubjectUser (UserId i))
  "group" -> Just (SubjectGroup (GroupId i))
  _ -> Nothing

--------------------------------------------------------------------------------
-- Pages without their text

-- | A page's place in its space's tree, without its title, body or
-- attachments: what finding a page by its path, choosing a slug or a
-- position, or finding a subtree needs, read without the text of every
-- page of a space.
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

-- | The pages with these ids, as nodes, in no particular order. An id that
-- names no page is left out.
pageNodesWithIds :: Connection -> [PageId] -> IO [PageNode]
pageNodesWithIds c pids =
  concat <$> for (chunksOf 500 (ordNub pids)) (\ids -> queryWith nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages WHERE id IN (" <> marks ids <> ")")) (map (\p -> p.text) ids))

-- | The page of a space with this slug under this parent ('Nothing' for
-- the space's top level), as a node: one step of finding a page by its
-- path. The condition is written as the unique index
-- @pages_sibling_slug@ is, @coalesce(parent, '')@, so that SQLite finds
-- the page through the index instead of reading the space's pages.
childPage :: Connection -> SpaceId -> Maybe PageId -> Slug -> IO (Maybe PageNode)
childPage c sid parent slug =
  head
    <$> queryWith nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages WHERE space_id = ? AND coalesce(parent, '') = ? AND slug = ?")) (sid.text, maybe "" (\p -> p.text) parent, slugText slug)

-- | The pages of a space under this parent ('Nothing' for the space's top
-- level), as nodes, in no particular order: what choosing a new page's
-- slug and position needs. Found through the same index as 'childPage'.
childPages :: Connection -> SpaceId -> Maybe PageId -> IO [PageNode]
childPages c sid parent =
  queryWith nodeRow c (sql ("SELECT " <> nodeColumns <> " FROM pages WHERE space_id = ? AND coalesce(parent, '') = ?")) (sid.text, maybe "" (\p -> p.text) parent)

-- | A page and the pages under it, at any depth, by id: one recursive
-- query that follows the index on a page's parent, so it reads the
-- subtree and nothing else of the space. UNION rather than UNION ALL
-- keeps each page once, so even a loop of parents, which a page tree
-- never has, ends.
subtreeIds :: Connection -> PageId -> IO (Set PageId)
subtreeIds c pid =
  Set.fromList
    . map (PageId . fromOnly)
    <$> query c "WITH RECURSIVE below(id) AS (SELECT ? UNION SELECT p.id FROM pages p JOIN below b ON p.parent = b.id) SELECT id FROM below" (Only pid.text)

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
loadSitemapNodes :: Connection -> [SpaceId] -> IO [SitemapNode]
loadSitemapNodes c spaces =
  concat <$> for (chunksOf 500 spaces) (\chunk -> queryWith row c (sql ("SELECT id, space_id, parent, slug, updated_at FROM pages WHERE space_id IN (" <> marks chunk <> ")")) (map (\s -> s.text) chunk))
  where
    row = do
      id <- PageId <$> field
      space <- SpaceId <$> field
      parent <- fmap PageId <$> field
      slug <- slugField
      updatedAt <- stamp
      pure SitemapNode {id, space, parent, slug, updatedAt}

-- | Values for a query in groups of at most this many. SQLite limits the
-- number of parameters one statement may have, and a list of ids can be
-- longer than that limit.
chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs = case splitAt n xs of
  ([], _) -> []
  (now, rest) -> now : chunksOf n rest

-- | One parameter mark for each of the values, separated by commas: the
-- inside of an @IN (…)@.
marks :: [a] -> Text
marks vs = T.intercalate ", " (map (const "?") vs)

--------------------------------------------------------------------------------
-- Reads

-- | A query built from pieces of text.
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
  -- An icon that does not parse (one written by a later program) is read
  -- as the default, as the export reads it.
  icon <- (>>= decodeStrict' . encodeUtf8) <$> (field :: RowParser (Maybe Text))
  description <- field
  blog <- field
  pure Space {id, parent, name, slug, public, mathMacros, createdAt, position, subspaceOrder, pageOrder, homePage, icon, description, blog}

-- | Every space, by id. A wiki has tens of them, and every permission is
-- a question about a space's chain of ancestors, so each operation reads
-- them all.
loadSpaces :: Connection -> IO (Map SpaceId Space)
loadSpaces c = Map.fromList . map (\s -> (s.id, s)) <$> queryWith_ spaceRow c (sql ("SELECT " <> spaceColumns <> " FROM spaces"))

-- | A space and the spaces above it, by id: a space's chain, which is all
-- a permission rule about the space looks at. One recursive query, each
-- step by a space's primary key. UNION keeps each space once, so a loop of
-- parents ends.
loadChain :: Connection -> SpaceId -> IO (Map SpaceId Space)
loadChain c sid =
  Map.fromList
    . map (\s -> (s.id, s))
    <$> queryWith
      spaceRow
      c
      (sql ("WITH RECURSIVE chain(id) AS (SELECT ? UNION SELECT s.parent FROM spaces s JOIN chain ON s.id = chain.id WHERE s.parent IS NOT NULL) SELECT " <> spaceColumns <> " FROM spaces WHERE id IN (SELECT id FROM chain)"))
      (Only sid.text)

-- | Every grant, global and on spaces, in the order they were given.
loadGrants :: Connection -> IO Grants
loadGrants c = grantsOf <$> query_ c "SELECT subject_kind, subject_id, permission FROM global_grants ORDER BY rowid" <*> query_ c "SELECT space_id, subject_kind, subject_id, permission FROM space_grants ORDER BY rowid"

-- | Every global grant, and the grants on these spaces, in the order they
-- were given: the grants the rules about these spaces look at.
loadGrantsOn :: Connection -> [SpaceId] -> IO Grants
loadGrantsOn c sids =
  grantsOf
    <$> query_ c "SELECT subject_kind, subject_id, permission FROM global_grants ORDER BY rowid"
    <*> (concat <$> for (chunksOf 500 sids) (\chunk -> query c (sql ("SELECT space_id, subject_kind, subject_id, permission FROM space_grants WHERE space_id IN (" <> marks chunk <> ") ORDER BY rowid")) (map (\s -> s.text) chunk)))

-- | Grants from their rows: the global ones, and those on spaces.
grantsOf :: [(Text, Text, Text)] -> [(Text, Text, Text, Text)] -> Grants
grantsOf globals spaceGrants =
  Grants
    { global =
        [ GlobalGrant {subject, permission}
        | (kind, i, p) <- globals
        , Just subject <- [subjectFrom kind i]
        , Just permission <- [find (\x -> globalText x == p) [minBound .. maxBound]]
        ]
    , spaces =
        [ SpaceGrant {space = SpaceId s, subject, permission}
        | (s, kind, i, p) <- spaceGrants
        , Just subject <- [subjectFrom kind i]
        , Just permission <- [find (\x -> spaceText x == p) [minBound .. maxBound]]
        ]
    , -- The wiki's access setting, which the storage adds to the grants
      -- where it is needed (Wiki.Server.Storage), is not stored in the
      -- grants' rows.
      access = Open
    }

userRow :: RowParser User
userRow = do
  id <- UserId <$> field
  login <- field
  displayName <- field
  pure User {id, login, displayName}

-- | A user by id.
loadUser :: Connection -> UserId -> IO (Maybe User)
loadUser c u = head <$> queryWith userRow c "SELECT id, login, display_name FROM users WHERE id = ?" (Only u.text)

-- | A user by id who may act: not one whose login is disabled.
loadActiveUser :: Connection -> UserId -> IO (Maybe User)
loadActiveUser c u = head <$> queryWith userRow c "SELECT id, login, display_name FROM users WHERE id = ? AND disabled = 0" (Only u.text)

-- | A user by login.
loadUserByLogin :: Connection -> Text -> IO (Maybe User)
loadUserByLogin c login = head <$> queryWith userRow c "SELECT id, login, display_name FROM users WHERE login = ?" (Only login)

-- | The users with these logins who may act, not those whose login is
-- disabled, through the unique index on the login.
loadActiveUsersByLogin :: Connection -> [Text] -> IO [User]
loadActiveUsersByLogin c logins =
  concat <$> for (chunksOf 500 (ordNub logins)) (\chunk -> queryWith userRow c (sql ("SELECT id, login, display_name FROM users WHERE disabled = 0 AND login IN (" <> marks chunk <> ")")) chunk)

-- | Every user, by id.
loadUsers :: Connection -> IO [User]
loadUsers c = queryWith_ userRow c "SELECT id, login, display_name FROM users ORDER BY id"

-- | The groups a user is in.
loadGroupsOf :: Connection -> UserId -> IO (Set GroupId)
loadGroupsOf c u = Set.fromList . map (GroupId . fromOnly) <$> query c "SELECT group_id FROM group_members WHERE user_id = ?" (Only u.text)

-- | Every group, by id.
loadGroups :: Connection -> IO [Group]
loadGroups c = map (\(i, name) -> Group {id = GroupId i, name}) <$> query_ c "SELECT id, name FROM groups ORDER BY id"

-- | Every group's members.
loadMembership :: Connection -> IO Membership
loadMembership c = do
  rows <- query_ c "SELECT group_id, user_id FROM group_members"
  pure (Map.fromListWith (<>) [(GroupId g, Set.singleton (UserId u)) | (g, u) <- rows])

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

-- | Pages with their attachments, each page's attachments in order.
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

-- | The summaries of a space's pages, in no particular order: the pages
-- without their bodies and attachments, which a list of pages does not
-- carry.
loadPageSummaries :: Connection -> SpaceId -> IO [PageSummary]
loadPageSummaries c sid = queryWith row c "SELECT id, space_id, parent, title, slug, created_at, updated_at, position, template FROM pages WHERE space_id = ?" (Only sid.text)
  where
    row = do
      id <- PageId <$> field
      space <- SpaceId <$> field
      parent <- fmap PageId <$> field
      title <- field
      slug <- slugField
      createdAt <- stamp
      updatedAt <- stamp
      position <- field
      template <- field
      pure PageSummary {id, space, parent, title, slug, createdAt, updatedAt, position, template}

-- | Every page of the wiki with its attachments, by id.
loadAllPages :: Connection -> IO [Page]
loadAllPages c = do
  rows <- queryWith_ pageRow c (sql ("SELECT " <> pageColumns <> " FROM pages ORDER BY id"))
  attached <- queryWith_ attachmentRow c (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a ORDER BY a.ordinal"))
  pure (withAttachments rows attached)

-- | An attachment, with the page it is on.
loadAttachment :: Connection -> AttachmentId -> IO (Maybe (PageId, Attachment))
loadAttachment c aid = head <$> queryWith attachmentRow c (sql ("SELECT " <> attachmentColumns <> ", a.page_id FROM attachments a WHERE a.id = ?")) (Only aid.text)

-- | An attachment, with the space its page is in, in one query: what
-- serving its bytes needs to check whether the reader may see it.
loadAttachmentIn :: Connection -> AttachmentId -> IO (Maybe (SpaceId, Attachment))
loadAttachmentIn c aid =
  head
    <$> queryWith
      ((\(_, a) s -> (SpaceId s, a)) <$> attachmentRow <*> field)
      c
      (sql ("SELECT " <> attachmentColumns <> ", a.page_id, p.space_id FROM attachments a JOIN pages p ON p.id = a.page_id WHERE a.id = ?"))
      (Only aid.text)

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
-- the first of them.
--
-- A time is stored as text, and the text does not sort in time order: a
-- time without a fraction of a second sorts after one with, since the
-- @Z@ at its end sorts after the dot. Without the @Z@ it does, and the
-- index @page_versions_order@ of migration @0015-version-order.sql@ holds
-- each version under its time written so. Both queries name the index's
-- expression exactly as it is written there, so SQLite reads the page of
-- versions from the index rather than every version of the page.
loadVersionsPage :: Connection -> PageId -> Maybe UTCTime -> Int -> IO (Int, [VersionRow])
loadVersionsPage c page before limit = do
  counted <- query c (sql ("SELECT count(*) FROM page_versions v WHERE v.page_id = ?" <> earlier)) params
  rows <-
    queryWith
      versionRow
      c
      (sql ("SELECT v.updated_at, v.title, '', v.author, u.display_name FROM page_versions v LEFT JOIN users u ON u.id = v.author WHERE v.page_id = ?" <> earlier <> " ORDER BY rtrim(v.updated_at, 'Z') DESC LIMIT ?"))
      (params <> [toField limit])
  pure (maybe 0 fromOnly (head counted), rows)
  where
    earlier = maybe "" (const " AND rtrim(v.updated_at, 'Z') < rtrim(?, 'Z')") before
    params = toField page.text : [toField (Stamp t) | t <- toList before]

-- | The first version of a page, without its body: the version saved when
-- the page was created, so the one whose time is the page's creation
-- time. The primary key of @page_versions@ finds it at once. A page an
-- import made has its first version at another time, with no author, so
-- it has none here, and no first author either way.
loadFirstVersion :: Connection -> PageId -> IO (Maybe VersionRow)
loadFirstVersion c page =
  head
    <$> queryWith
      versionRow
      c
      "SELECT v.updated_at, v.title, '', v.author, u.display_name FROM pages p JOIN page_versions v ON v.page_id = p.id AND v.updated_at = p.created_at LEFT JOIN users u ON u.id = v.author WHERE p.id = ?"
      (Only page.text)

-- | The first version of every page of a space, without its body, by
-- page, as 'loadFirstVersion' finds it: one version for each page, each
-- found through the primary key, instead of every version of the space.
loadFirstVersions :: Connection -> SpaceId -> IO [(PageId, VersionRow)]
loadFirstVersions c space =
  queryWith
    ((,) <$> (PageId <$> field) <*> versionRow)
    c
    "SELECT v.page_id, v.updated_at, v.title, '', v.author, u.display_name FROM pages p JOIN page_versions v ON v.page_id = p.id AND v.updated_at = p.created_at LEFT JOIN users u ON u.id = v.author WHERE p.space_id = ?"
    (Only space.text)

-- | The bodies of the pages of a space that can be posts of a blog: the
-- pages at its top level that are not templates ("Wiki.Core.Blog"'s
-- 'isPost' decides the rest). A blog's list shows an excerpt of each.
loadPostBodies :: Connection -> SpaceId -> IO [(PageId, Text)]
loadPostBodies c space = map (first PageId) <$> query c "SELECT id, body FROM pages WHERE space_id = ? AND parent IS NULL AND template = 0" (Only space.text)

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

-- | The pages of these spaces whose fold ('searchFold') contains every one
-- of these words, as the search reads them. The words must be folded as
-- the fold is ('foldText'). Templates are left out unless asked for. Only
-- the rows of the spaces given are read, through the index on a page's
-- space, and of those only the matching ones are returned. The search
-- then folds the title and text of these rows alone, which is where its
-- time goes.
loadSearchMatches :: Connection -> [SpaceId] -> Bool -> [Text] -> IO [SearchRow]
loadSearchMatches c spaces templates ws =
  concat <$> for (chunksOf 500 spaces) (\chunk -> queryWith row c (statement chunk) (map (\s -> toField s.text) chunk <> map toField ws))
  where
    row = SearchRow <$> nodeRow <*> field
    -- instr finds a word anywhere in the fold, as the matcher's
    -- 'T.isInfixOf' does, with no character that means something else, as
    -- LIKE's @%@ and @_@ would.
    statement chunk =
      sql
        ( "SELECT "
            <> nodeColumns
            <> ", search_text FROM pages WHERE space_id IN ("
            <> marks chunk
            <> ")"
            <> (if templates then "" else " AND template = 0")
            <> T.concat [" AND instr(search_fold, ?) > 0" | _ <- ws]
        )

--------------------------------------------------------------------------------
-- Writes

-- | Add a user.
insertUser :: Connection -> User -> IO ()
insertUser c u = execute c "INSERT INTO users (id, login, display_name) VALUES (?, ?, ?)" (u.id.text, u.login, u.displayName)

-- | Add a group.
insertGroup :: Connection -> Group -> IO ()
insertGroup c g = execute c "INSERT INTO groups (id, name) VALUES (?, ?)" (g.id.text, g.name)

-- | Put a user in a group.
insertMember :: Connection -> GroupId -> UserId -> IO ()
insertMember c g u = execute c "INSERT OR IGNORE INTO group_members (group_id, user_id) VALUES (?, ?)" (g.text, u.text)

-- | Take a user out of a group.
deleteMember :: Connection -> GroupId -> UserId -> IO ()
deleteMember c g u = execute c "DELETE FROM group_members WHERE group_id = ? AND user_id = ?" (g.text, u.text)

-- | Rename a group.
renameGroupRow :: Connection -> GroupId -> Text -> IO ()
renameGroupRow c g name = execute c "UPDATE groups SET name = ? WHERE id = ?" (name, g.text)

-- | Delete a group. Its memberships are deleted with it (by a foreign
-- key), and so must the grants to it be, which name it in a column that is
-- not a foreign key.
deleteGroupRows :: Connection -> GroupId -> IO ()
deleteGroupRows c g = do
  execute c "DELETE FROM global_grants WHERE subject_kind = 'group' AND subject_id = ?" (Only g.text)
  execute c "DELETE FROM space_grants WHERE subject_kind = 'group' AND subject_id = ?" (Only g.text)
  execute c "DELETE FROM groups WHERE id = ?" (Only g.text)

-- | Remove a global grant, if it exists.
deleteGlobalGrant :: Connection -> GlobalGrant -> IO ()
deleteGlobalGrant c g =
  let (kind, i) = subjectColumns g.subject
   in execute c "DELETE FROM global_grants WHERE subject_kind = ? AND subject_id = ? AND permission = ?" (kind, i, globalText g.permission)

deleteSpaceGrant :: Connection -> SpaceGrant -> IO ()
deleteSpaceGrant c g =
  let (kind, i) = subjectColumns g.subject
   in execute c "DELETE FROM space_grants WHERE space_id = ? AND subject_kind = ? AND subject_id = ? AND permission = ?" (g.space.text, kind, i, spaceText g.permission)

-- | Add these grants, in order; a grant that already exists is left as it
-- is.
insertGrants :: Connection -> Grants -> IO ()
insertGrants c grants = do
  for_ grants.global $ \g ->
    let (kind, i) = subjectColumns g.subject
     in execute c "INSERT OR IGNORE INTO global_grants (subject_kind, subject_id, permission) VALUES (?, ?, ?)" (kind, i, globalText g.permission)
  for_ grants.spaces $ \g ->
    let (kind, i) = subjectColumns g.subject
     in execute
          c
          "INSERT OR IGNORE INTO space_grants (space_id, subject_kind, subject_id, permission) VALUES (?, ?, ?, ?)"
          (g.space.text, kind, i, spaceText g.permission)

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

-- | Overwrite the space with this id: every column of it.
updateSpace :: Connection -> Space -> IO ()
updateSpace c s =
  execute
    c
    "UPDATE spaces SET parent = ?, name = ?, slug = ?, public = ?, math_macros = ?, created_at = ?, position = ?, subspace_order = ?, page_order = ?, home_page = ?, icon = ?, description = ?, blog = ? WHERE id = ?"
    (drop 1 (spaceValues s) <> [toField s.id.text])

-- | Add a page, without its attachments, with its search text and its
-- fold prepared from its title and body.
insertPage :: Connection -> Page -> IO ()
insertPage c p =
  execute
    c
    (sql ("INSERT INTO pages (" <> pageColumns <> ", search_text, search_fold) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"))
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
    , toField searchText
    , toField (searchFold p.title searchText)
    ]
  where
    searchText = bodyText p.body

-- | Change a page's title and body, as a save does, with its search text
-- and its fold made again from them, and its @updated_at@.
updatePageText :: Connection -> PageId -> Text -> Text -> UTCTime -> IO ()
updatePageText c pid title body updatedAt =
  execute
    c
    "UPDATE pages SET title = ?, body = ?, updated_at = ?, search_text = ?, search_fold = ? WHERE id = ?"
    (title, body, Stamp updatedAt, searchText, searchFold title searchText, pid.text)
  where
    searchText = bodyText body

-- | The fold a search matches a page against: its title and its search
-- text ('bodyText' of its body), each folded as the search folds them
-- ('foldText'), with a line break between them. A query's words have no
-- blanks, so no word can match across the line break.
searchFold :: Text -> Text -> Text
searchFold title searchText = foldText title <> "\n" <> foldText searchText

-- | Fill in the fold of every page that has none: the pages a database
-- held before it had the column (migration
-- @0014-search-fold.sql@). The fold is made from the title and the
-- search text already stored, so no page's Markdown is parsed again.
-- Called when the storage opens, before anything searches. The pages are
-- read a few hundred at a time, so that a large wiki's text is not held
-- in memory all at once.
fillSearchFolds :: Connection -> IO ()
fillSearchFolds c = do
  -- Through the index of the pages with no fold, which is empty once all
  -- are filled in, so a storage that opens a filled database takes no
  -- write lock here.
  missing <- query_ c "SELECT count(*) FROM (SELECT id FROM pages WHERE search_fold IS NULL LIMIT 1)"
  when (missing /= [Only (0 :: Int)]) $ do
    execute_ c "BEGIN IMMEDIATE"
    flip onException (execute_ c "ROLLBACK") $ do
      let batch = do
            rows <- query_ c "SELECT id, title, search_text FROM pages WHERE search_fold IS NULL LIMIT 500"
            for_ rows $ \(i, title, searchText) ->
              execute c "UPDATE pages SET search_fold = ? WHERE id = ?" (searchFold title searchText, i :: Text)
            unless (null rows) batch
      batch
      execute_ c "COMMIT"

-- | Store a version of a page: its title and body as of its @updatedAt@,
-- and who saved it, if known.
insertVersion :: Connection -> Page -> Maybe UserId -> IO ()
insertVersion c p author =
  execute
    c
    "INSERT INTO page_versions (page_id, updated_at, title, body, author) VALUES (?, ?, ?, ?, ?)"
    (p.id.text, Stamp p.updatedAt, p.title, p.body, fmap (\u -> u.text) author)

-- | Attach an attachment to a page, at a position among the page's
-- attachments.
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

-- | A user's account as its row has it: id, login, display name, the hash
-- of their password if they have one, and whether they are disabled.
type AccountRow = (Text, Text, Text, Maybe Text, Int)

accountFromRow :: AccountRow -> Account
accountFromRow (uid, login, displayName, phc, disabled) =
  Account
    { user = User {id = UserId uid, login, displayName}
    , hasPassword = isJust phc
    , disabled = disabled /= 0
    }

-- | A query of account rows, from the users table, with the rest of the
-- query given.
selectAccounts :: Text -> Query
selectAccounts rest = Query ("SELECT id, login, display_name, password_hash, disabled FROM users " <> rest)

-- | A user's account, by id.
loadAccount :: Connection -> UserId -> IO (Maybe Account)
loadAccount c u = fmap accountFromRow . head <$> query c (selectAccounts "WHERE id = ?") (Only u.text)

-- | The users who are disabled, and those who have a password.
loadAccountFlags :: Connection -> IO (Set UserId, Set UserId)
loadAccountFlags c = do
  rows <- query_ c "SELECT id, disabled, password_hash IS NOT NULL FROM users"
  pure
    ( Set.fromList [UserId u | (u, disabled, _) <- rows, disabled /= (0 :: Int)]
    , Set.fromList [UserId u | (u, _, hashed) <- rows, hashed /= (0 :: Int)]
    )

-- | Add a user with a login no other user has, ignoring case, or return a
-- 'Left' with the login that is taken. The login and the password hash are
-- stored as given.
insertAccount :: Connection -> UserId -> Text -> Text -> Maybe Text -> IO (Either Text Account)
insertAccount c u login displayName phc = do
  taken <- query c "SELECT count(*) FROM users WHERE login = ? COLLATE NOCASE" (Only login)
  if taken /= [Only (0 :: Int)]
    then pure (Left login)
    else do
      execute c "INSERT INTO users (id, login, display_name, password_hash, disabled) VALUES (?, ?, ?, ?, 0)" (u.text, login, displayName, phc)
      maybe (Left login) Right <$> loadAccount c u

-- | Replace a user's password hash.
updatePasswordHash :: Connection -> UserId -> Text -> IO ()
updatePasswordHash c u phc = execute c "UPDATE users SET password_hash = ? WHERE id = ?" (phc, u.text)

-- | Set whether a user is disabled.
updateDisabled :: Connection -> UserId -> Bool -> IO ()
updateDisabled c u disabled = execute c "UPDATE users SET disabled = ? WHERE id = ?" (fromEnum disabled, u.text)

-- | End every session of a user.
deleteSessionsOf :: Connection -> UserId -> IO ()
deleteSessionsOf c u = execute c "DELETE FROM sessions WHERE user_id = ?" (Only u.text)

-- | Whether a user has a second factor that signing in asks for: one they
-- have confirmed (migrations/0008-account-hygiene.sql).
totpEnabled :: Connection -> UserId -> IO Bool
totpEnabled c u = not . null <$> (query c "SELECT 1 FROM totp WHERE user_id = ? AND enabled_at IS NOT NULL" (Only u.text) :: IO [Only Int])

-- | Remove a user's second factor, started or on, with its recovery codes.
-- The result is whether they had one on.
deleteSecondFactor :: Connection -> UserId -> IO Bool
deleteSecondFactor c u = do
  had <- totpEnabled c u
  execute c "DELETE FROM totp WHERE user_id = ?" (Only u.text)
  execute c "DELETE FROM recovery_codes WHERE user_id = ?" (Only u.text)
  pure had

-- | The users who have a second factor.
loadSecondFactorUsers :: Connection -> IO (Set UserId)
loadSecondFactorUsers c = Set.fromList . map (UserId . fromOnly) <$> query_ c "SELECT user_id FROM totp WHERE enabled_at IS NOT NULL"

-- | The e-mail addresses users have given, and whether each is verified.
loadEmails :: Connection -> IO (Map UserId AccountEmail)
loadEmails c = do
  rows <- query_ c "SELECT id, email, email_verified_at IS NOT NULL FROM users WHERE email IS NOT NULL"
  pure (Map.fromList [(UserId u, AccountEmail {email, verified = verified /= (0 :: Int)}) | (u, email, verified) <- rows])

--------------------------------------------------------------------------------
-- Identities

-- | An identity as its row has it (migrations/0004-identities.sql).
data IdentityRow = IdentityRow
  { provider :: Text
  , subject :: Text
  , user :: UserId
  , identity :: LinkedIdentity
  }

-- | The identity row of a provider's account, if it belongs to anyone.
identityOf :: Connection -> Text -> Text -> IO (Maybe IdentityRow)
identityOf c provider subject =
  head
    . map identityRow
    <$> query c "SELECT provider, subject, user_id, email, display_name, linked_at FROM identities WHERE provider = ? AND subject = ?" (provider, subject)

-- | A user's identities, by provider.
identitiesOf :: Connection -> UserId -> IO [IdentityRow]
identitiesOf c u =
  map identityRow
    <$> query c "SELECT provider, subject, user_id, email, display_name, linked_at FROM identities WHERE user_id = ? ORDER BY provider" (Only u.text)

identityRow :: (Text, Text, Text, Maybe Text, Maybe Text, Stamp) -> IdentityRow
identityRow (provider, subject, uid, email, name, Stamp linkedAt) =
  IdentityRow {provider, subject, user = UserId uid, identity = LinkedIdentity {provider, email, name, linkedAt}}

-- | Connect a provider's account to a user. The caller has made sure that
-- it belongs to nobody, and that the user has none at that provider.
insertIdentity :: Connection -> UTCTime -> UserId -> Text -> Text -> Maybe Text -> Maybe Text -> IO ()
insertIdentity c now u provider subject email name =
  execute
    c
    "INSERT INTO identities (provider, subject, user_id, email, display_name, linked_at) VALUES (?, ?, ?, ?, ?, ?)"
    (provider, subject, u.text, email, name, Stamp now)

-- | Store what a provider now says about an account, for the next time it
-- is shown.
refreshIdentity :: Connection -> Text -> Text -> Maybe Text -> Maybe Text -> IO ()
refreshIdentity c provider subject email name =
  execute c "UPDATE identities SET email = ?, display_name = ? WHERE provider = ? AND subject = ?" (email, name, provider, subject)

-- | Disconnect a user's account at a provider. The result is whether they
-- had one.
deleteIdentity :: Connection -> UserId -> Text -> IO Bool
deleteIdentity c u provider = do
  execute c "DELETE FROM identities WHERE user_id = ? AND provider = ?" (u.text, provider)
  (> 0) <$> changes c

-- | The providers each user has an identity at, by user.
loadIdentityProviders :: Connection -> IO (Map UserId [Text])
loadIdentityProviders c = do
  rows <- query_ c "SELECT user_id, provider FROM identities ORDER BY provider"
  pure (Map.fromListWith (flip (<>)) [(UserId u, [p]) | (u, p) <- rows])

-- | The names of the providers in the server's settings.
providerNames :: Kept -> [Text]
providerNames kept = map (\p -> p.name) kept.providers

-- | Whether a user has no password to set (WP5.6 of docs/PLAN.md,
-- 'Wiki.Api.Account.providerOnly'): they have none, and an identity at one
-- of these providers, the ones in the server's settings.
noPasswordToSet :: Connection -> [Text] -> UserId -> IO Bool
noPasswordToSet c configured u = do
  hashed :: [Only Int] <- query c "SELECT password_hash IS NOT NULL FROM users WHERE id = ?" (Only u.text)
  providers <- map fromOnly <$> query c "SELECT provider FROM identities WHERE user_id = ?" (Only u.text)
  pure (providerOnly configured (any ((/= 0) . fromOnly) hashed) providers)

--------------------------------------------------------------------------------
-- Password resets

-- | Store a reset link for a user (migrations/0008-account-hygiene.sql):
-- the hash of its secret, when it was made, and when it expires.
insertResetToken :: Connection -> UserId -> Text -> UTCTime -> UTCTime -> IO ()
insertResetToken c u secretHash made expires =
  execute c "INSERT INTO reset_tokens (token_hash, user_id, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, NULL)" (secretHash, u.text, Stamp made, Stamp expires)

-- | How many reset links a user has been given since a time, used or not.
resetsSince :: Connection -> UserId -> UTCTime -> IO Int
resetsSince c u since = maybe 0 fromOnly . head <$> query c "SELECT count(*) FROM reset_tokens WHERE user_id = ? AND created_at > ?" (u.text, Stamp since)

--------------------------------------------------------------------------------
-- Whom the wiki lets in

-- | The wiki's settings, each from its row, or its default for a setting
-- that has no row (migrations/0003-settings.sql) or a value this program
-- does not know.
loadSettings :: Connection -> IO WikiSettings
loadSettings c = do
  rows :: [(Text, Text)] <- query_ c "SELECT key, value FROM settings"
  let valueOf key = snd <$> find ((== key) . fst) rows
  pure
    WikiSettings
      { access = fromMaybe defaultSettings.access (valueOf "access" >>= readAccess)
      , newAccountsCreateSpaces = maybe defaultSettings.newAccountsCreateSpaces (== "1") (valueOf "new-accounts-create-spaces")
      }

-- | Store the wiki's settings, each in its row.
storeSettings :: Connection -> WikiSettings -> IO ()
storeSettings c s =
  for_ [("access", accessName s.access), ("new-accounts-create-spaces", if s.newAccountsCreateSpaces then "1" else "0")] $ \(key, value :: Text) ->
    execute c "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value" (key :: Text, value)

-- | Every invitation, the latest first, as of a given time (which decides
-- which have expired).
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

-- | Store an invitation, under the hash of its link's secret, replacing
-- any invitation for the same address.
insertInvitation :: Connection -> Invitation -> Text -> IO ()
insertInvitation c i secretHash = do
  execute c "DELETE FROM invitations WHERE email = ? COLLATE NOCASE" (Only i.email)
  execute c "INSERT INTO invitations (id, email, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)" (i.id.text, i.email, secretHash, Stamp i.createdAt, Stamp i.expiresAt)

-- | Delete an invitation. The result is whether there was one.
deleteInvitation :: Connection -> InvitationId -> IO Bool
deleteInvitation c i = do
  execute c "DELETE FROM invitations WHERE id = ?" (Only i.text)
  (> 0) <$> changes c

-- | The invitation whose link's secret has this hash, if it may be used at
-- this time (it has not expired): its id, and who it is for.
pendingInvitation :: Connection -> UTCTime -> Text -> IO (Maybe (InvitationId, InvitationInfo))
pendingInvitation c now secretHash = do
  rows <- query c "SELECT id, email, expires_at FROM invitations WHERE token_hash = ?" (Only secretHash)
  pure $ case rows of
    [(i, email, Stamp expiresAt)] | expiresAt > now -> Just (InvitationId i, InvitationInfo {email, expiresAt})
    _ -> Nothing

-- | Grant a user the global create-spaces directly.
grantCreateSpaces :: Connection -> UserId -> IO ()
grantCreateSpaces c u = execute c "INSERT OR IGNORE INTO global_grants (subject_kind, subject_id, permission) VALUES ('user', ?, ?)" (u.text, globalText CreateSpaces)

--------------------------------------------------------------------------------
-- The server's own settings

-- | The server's settings (migrations/0005-server-settings.sql): none
-- where nothing is set. A provider of a kind this program does not know
-- is left out, and a mail server without a host counts as none.
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

-- | Store the server's settings, replacing those stored before.
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
