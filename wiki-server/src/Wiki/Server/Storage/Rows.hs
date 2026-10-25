-- | The wiki's records as the database's rows: how each column is written
-- and read, and the reads and writes of whole records that the storage's
-- operations ("Wiki.Server.Storage") are made of. Nothing here checks a
-- permission or a rule: these run inside a transaction that has.
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
  , loadVersion
  , SearchRow (..)
  , loadSearchRows

    -- * Writes
  , insertUser
  , insertGroup
  , insertMember
  , deleteMember
  , renameGroupRow
  , deleteGroupRows
  , deleteGlobalGrant
  , insertGrants
  , insertSpace
  , updateSpace
  , insertPage
  , insertVersion
  , insertAttachment
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Database.SQLite.Simple (Connection, Only (..), Query (..), SQLData, execute, query, queryWith, queryWith_, query_)
import Database.SQLite.Simple.FromField (FieldParser, FromField (..), ResultError (..), returnError)
import Database.SQLite.Simple.FromRow (RowParser, field, fieldWith)
import Database.SQLite.Simple.ToField (ToField (..))
import Protolude
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

--------------------------------------------------------------------------------
-- Columns

-- | A time as a column: ISO 8601 text in UTC with every digit of the
-- fraction of a second there is. Not sqlite-simple's own 'UTCTime' columns,
-- because a save is checked against the time it started from by equality,
-- so a time must come back exactly as it went in, which nothing but every
-- digit promises.
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
nodeColumns = "id, space_id, parent, title, slug, created_at, position"

nodeRow :: RowParser PageNode
nodeRow = do
  id <- PageId <$> field
  space <- SpaceId <$> field
  parent <- fmap PageId <$> field
  title <- field
  slug <- slugField
  createdAt <- stamp
  position <- field
  pure PageNode {id, space, parent, title, slug, createdAt, position}

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
spaceColumns = "id, parent, name, slug, public, math_macros, created_at, position, subspace_order, page_order"

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
  pure Space {id, parent, name, slug, public, mathMacros, createdAt, position, subspaceOrder, pageOrder}

-- | Every space, by id: a wiki has tens of them, and every permission is a
-- question about a space's chain of ancestors, so each operation reads them
-- all.
loadSpaces :: Connection -> IO (Map SpaceId Space)
loadSpaces c = Map.fromList . map (\s -> (s.id, s)) <$> queryWith_ spaceRow c (sql ("SELECT " <> spaceColumns <> " FROM spaces"))

-- | Every grant, global and on spaces, in the order they were given.
loadGrants :: Connection -> IO Grants
loadGrants c = do
  globals <- query_ c "SELECT subject_kind, subject_id, permission FROM global_grants ORDER BY rowid"
  spaceGrants <- query_ c "SELECT space_id, subject_kind, subject_id, permission FROM space_grants ORDER BY rowid"
  pure
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
pageColumns = "id, space_id, parent, title, slug, body, created_at, updated_at, position"

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
  pure (\attachments -> Page {id, space, parent, title, slug, body, attachments, createdAt, updatedAt, position})

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

-- | Give a group another name.
renameGroupRow :: Connection -> GroupId -> Text -> IO ()
renameGroupRow c g name = execute c "UPDATE groups SET name = ? WHERE id = ?" (name, g.text)

-- | Delete a group: its members go with it (a foreign key), and so must
-- the grants to it, which name it in a column that is no foreign key.
deleteGroupRows :: Connection -> GroupId -> IO ()
deleteGroupRows c g = do
  execute c "DELETE FROM global_grants WHERE subject_kind = 'group' AND subject_id = ?" (Only g.text)
  execute c "DELETE FROM space_grants WHERE subject_kind = 'group' AND subject_id = ?" (Only g.text)
  execute c "DELETE FROM groups WHERE id = ?" (Only g.text)

-- | Take back a global grant, if it was given.
deleteGlobalGrant :: Connection -> GlobalGrant -> IO ()
deleteGlobalGrant c g =
  let (kind, i) = subjectColumns g.subject
   in execute c "DELETE FROM global_grants WHERE subject_kind = ? AND subject_id = ? AND permission = ?" (kind, i, globalText g.permission)

-- | Give these grants, in their order; one already given is left as it is.
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
  ]

-- | Add a space.
insertSpace :: Connection -> Space -> IO ()
insertSpace c s = execute c (sql ("INSERT INTO spaces (" <> spaceColumns <> ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")) (spaceValues s)

-- | Write a space over the one with its id: every column of it.
updateSpace :: Connection -> Space -> IO ()
updateSpace c s =
  execute
    c
    "UPDATE spaces SET parent = ?, name = ?, slug = ?, public = ?, math_macros = ?, created_at = ?, position = ?, subspace_order = ?, page_order = ? WHERE id = ?"
    (drop 1 (spaceValues s) <> [toField s.id.text])

-- | Add a page, without its attachments, with the text the search compares
-- queries with prepared from its body.
insertPage :: Connection -> Page -> IO ()
insertPage c p =
  execute
    c
    (sql ("INSERT INTO pages (" <> pageColumns <> ", search_text) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"))
    [ toField p.id.text
    , toField p.space.text
    , toField (fmap (\x -> x.text) p.parent)
    , toField p.title
    , toField (slugText p.slug)
    , toField p.body
    , toField (Stamp p.createdAt)
    , toField (Stamp p.updatedAt)
    , toField p.position
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
