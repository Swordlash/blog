-- | A whole wiki as one archive: what the demo exports and imports as a zip
-- file, and what the server of Phase 2 will import and export too, so that a
-- wiki moves between them as one file.
--
-- = The archive
--
-- An archive is a set of files, by path ('writeArchive' gives them, and
-- 'readArchive' takes them; the zip container around them is the caller's):
--
-- * @manifest.json@: @{"format": "wiki-export", "formatVersion": 1,
--   "createdAt": …, "app": …}@, what the archive is, which version of this
--   format it is written in, when and by what.
-- * @users.json@, @groups.json@ (each group with its @members@),
--   @grants.json@ (@{"global": […], "spaces": […]}@), @spaces.json@,
--   @pages.json@: a list of records each, in the order of their ids.
-- * @attachments.json@: every attachment's record, with the page it is
--   attached to, in each page's order; one whose bytes the wiki keeps names
--   its file, @attachments/\<attachment id>/\<name>@, which holds the bytes.
-- * @icons/\<space id>@: the image a space is pictured with, for a space
--   whose icon is one (its record names the file, 'iconFile').
--
-- Every record is a JSON object with named fields, written and read by the
-- functions here rather than derived from the Haskell types, so that
-- renaming a field in the code cannot change the format by accident. The
-- same functions write the demo's records in the browser's IndexedDB
-- ("Wiki.App.Backend.Mem.Persist" in @wiki-app@), so a record kept and a
-- record exported are one format.
--
-- = Compatibility
--
-- The format changes in two ways, and this module keeps to both:
--
-- * __Additions need no new version.__ A reader ignores the fields it does
--   not know, and a field that may be missing has a default (a space is
--   private and has no math macros, lists its children by name and was
--   made with its first page, a page has no parent and an empty body, a
--   child put by hand is at position 0, a group has no members, unless the
--   record says otherwise). So an older program reads a newer
--   archive of the same version, and a newer one an older archive.
-- * __Anything else bumps 'formatVersion'__: a field removed or renamed, or
--   one whose meaning changes. The reader then migrates an archive of every
--   older version to the current one, a version at a time ('migrations'),
--   before reading it, so every archive ever written keeps importing. An
--   archive of a version newer than this program knows is refused, with a
--   message that says so, never read in part.
--
-- 'readArchive' checks the whole archive before it gives anything back:
-- every file is there and reads, every id is unique, everything a record
-- refers to is in the archive, the trees of spaces and pages have no cycles
-- and no two siblings share a slug, and every attachment's file is there
-- with as many bytes as its record says. What it refuses, it refuses with
-- the reason, naming the file and the record.
module Wiki.Core.Export
  ( -- * Archives
    Archive (..)
  , currentVersion
  , writeArchive
  , readArchive
  , attachmentFile
  , iconFile

    -- * Records
  , encodeSpace
  , parseSpace
  , spaceCreatedDefault
  , encodePage
  , parsePage
  , encodeAttachment
  , parseAttachment
  , AttachmentRecord (..)
  , encodeUser
  , parseUser
  , encodeGroup
  , parseGroup
  , encodeGrants
  , parseGrants
  , encodeSpaceGrant
  , parseSpaceGrant
  , encodeGlobalGrant
  , parseGlobalGrant
  , encodeJson
  , decodeJson
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (ToJSON, Value (..), eitherDecodeStrict', encode, object, parseJSON, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (Group (..), Membership, User (..))

-- | A whole wiki: its people, its grants, its spaces and pages (each page
-- with its attachments' records), and the bytes of the attachments it
-- keeps, by the blob each attachment names.
data Archive = Archive
  { createdAt :: UTCTime
  , app :: Text
  -- ^ What wrote it, for a person to read: the program and its version.
  , users :: [User]
  , groups :: [Group]
  , membership :: Membership
  , grants :: Grants
  , spaces :: [Space]
  , pages :: [Page]
  , blobs :: Map BlobId ByteString
  }
  deriving stock (Eq, Show)

-- | The version of the format this module writes, and the newest it reads.
currentVersion :: Int
currentVersion = 1

-- | What the manifest says an archive is.
formatName :: Text
formatName = "wiki-export"

--------------------------------------------------------------------------------
-- Writing

-- | The archive's files, by path: the manifest first, then the records,
-- then the attachments' bytes.
writeArchive :: Archive -> [(Text, ByteString)]
writeArchive a =
  [ ("manifest.json", encodeJson manifest)
  , ("users.json", encodeJson [encodeUser u | u <- a.users])
  , ("groups.json", encodeJson [encodeGroup g (Map.findWithDefault mempty g.id a.membership) | g <- a.groups])
  , ("grants.json", encodeJson (encodeGrants a.grants))
  , ("spaces.json", encodeJson (map encodeSpace a.spaces))
  , ("pages.json", encodeJson (map encodePage a.pages))
  , ("attachments.json", encodeJson [encodeAttachment p.id x | p <- a.pages, x <- p.attachments])
  ]
    <> [ (attachmentFile x, bytes)
       | p <- a.pages
       , x <- p.attachments
       , SourceBlob blob <- [x.source]
       , Just bytes <- [Map.lookup blob a.blobs]
       ]
    <> [ (iconFile s, bytes)
       | s <- a.spaces
       , Just (IconImage blob _) <- [s.icon]
       , Just bytes <- [Map.lookup blob a.blobs]
       ]
  where
    manifest =
      object
        [ "format" .= formatName
        , "formatVersion" .= currentVersion
        , "createdAt" .= a.createdAt
        , "app" .= a.app
        ]

-- | Where an attachment's bytes are in an archive.
attachmentFile :: Attachment -> Text
attachmentFile x = "attachments/" <> x.id.text <> "/" <> x.name

-- | Where the image a space is pictured with is in an archive.
iconFile :: Space -> Text
iconFile s = "icons/" <> s.id.text

-- | JSON, compact.
encodeJson :: (ToJSON a) => a -> ByteString
encodeJson = BSL.toStrict . encode

-- | A value read from JSON with a parser of this module's, or why not.
decodeJson :: (Value -> Parser a) -> ByteString -> Either Text a
decodeJson parse bytes = first toS (eitherDecodeStrict' bytes >>= parseEither parse)

--------------------------------------------------------------------------------
-- Reading

-- | The JSON files of an archive, by path, parsed but not yet read as
-- records: what a migration works on.
type Files = Map Text Value

-- | The files of records every archive of the current version has.
recordFiles :: [Text]
recordFiles = ["users.json", "groups.json", "grants.json", "spaces.json", "pages.json", "attachments.json"]

-- | How an archive of each older version becomes one of the next, by the
-- version it starts from: a function of its parsed JSON files. Version 1
-- is the first, so there are none yet. A change that bumps
-- 'currentVersion' adds the step from the version before, and every older
-- archive then goes through each step after its own, in turn.
migrations :: Map Int (Files -> Either Text Files)
migrations = mempty

-- | The wiki an archive's files hold, checked whole, or why it is refused.
readArchive :: Map Text ByteString -> Either Text Archive
readArchive entries = do
  manifestBytes <- note "It has no manifest.json, so it is not a wiki export." (Map.lookup "manifest.json" entries)
  (version, createdAt, app) <- inFile "manifest.json" (decodeJson parseManifest manifestBytes)
  when (version > currentVersion) $
    Left
      ( "It is written in version "
          <> show version
          <> " of the export format, by a newer version of the wiki; this one reads version "
          <> show currentVersion
          <> " and older."
      )
  when (version < 1) $
    Left ("Its manifest.json gives the format version " <> show version <> ", which there has never been.")
  files <- Map.fromList <$> traverse (\path -> (path,) <$> jsonFile path) recordFiles
  current <- migrate version files
  users <- records current "users.json" parseUser
  groupsAndMembers <- records current "groups.json" parseGroup
  grants <- inFile "grants.json" (parsed parseGrants (Map.findWithDefault Null "grants.json" current))
  pages <- records current "pages.json" parsePage
  spaces <- records current "spaces.json" (parseSpace (spaceCreatedDefault createdAt pages))
  attachments <- records current "attachments.json" parseAttachment
  blobs <- fmap Map.fromList . for [(x, file) | AttachmentRecord {attachment = x, file = Just file} <- attachments] $ \(x, file) -> do
    blob <- case x.source of
      SourceBlob b -> Right b
      SourceUrl _ -> Left ("attachments.json: the attachment " <> show x.id.text <> " has both a URL and a file.")
    bytes <-
      note
        ("The file " <> show file <> ", which attachments.json names for the attachment " <> show x.id.text <> ", is not in the archive.")
        (Map.lookup file entries)
    unless (fromIntegral (BS.length bytes) == x.size) $
      Left ("The file " <> show file <> " has " <> show (BS.length bytes) <> " bytes, where attachments.json says " <> show x.size <> ".")
    pure (blob, bytes)
  icons <- for [(s, blob) | s <- spaces, Just (IconImage blob _) <- [s.icon]] $ \(s, blob) -> do
    bytes <-
      note
        ("The file " <> show (iconFile s) <> ", which spaces.json names for the icon of the space " <> show s.id.text <> ", is not in the archive.")
        (Map.lookup (iconFile s) entries)
    pure (blob, bytes)
  let attachedTo pid = [x | AttachmentRecord {page, attachment = x} <- attachments, page == pid]
      archive =
        Archive
          { createdAt
          , app
          , users
          , groups = map fst groupsAndMembers
          , membership = Map.fromList [(g.id, members) | (g, members) <- groupsAndMembers]
          , grants
          , spaces
          , pages = [p {attachments = attachedTo p.id} | p <- pages]
          , blobs = blobs <> Map.fromList icons
          }
  checkArchive archive attachments
  pure archive
  where
    jsonFile path = do
      bytes <- note ("It has no " <> path <> ".") (Map.lookup path entries)
      inFile path (first toS (eitherDecodeStrict' bytes))

    migrate :: Int -> Files -> Either Text Files
    migrate version files
      | version >= currentVersion = Right files
      | otherwise = case Map.lookup version migrations of
          Nothing -> Left ("There is no way from version " <> show version <> " of the export format to the next.")
          Just step -> step files >>= migrate (version + 1)

    records :: Files -> Text -> (Value -> Parser a) -> Either Text [a]
    records files path parse = inFile path $ case Map.lookup path files of
      Just (Array values) -> traverse (parsed parse) (toList values)
      Just _ -> Left "it is not a list of records"
      Nothing -> Left "it is missing"

    parsed :: (Value -> Parser a) -> Value -> Either Text a
    parsed parse = first toS . parseEither parse

    inFile :: Text -> Either Text a -> Either Text a
    inFile path = first (\why -> path <> ": " <> why)

parseManifest :: Value -> Parser (Int, UTCTime, Text)
parseManifest = withObject "manifest" $ \o -> do
  format <- o .: "format"
  unless (format == formatName) $ fail ("this is not a wiki export but " <> show (format :: Text))
  (,,) <$> o .: "formatVersion" <*> o .: "createdAt" <*> o .:? "app" .!= ""

-- | Whatever in an archive that reads does not fit together: duplicates,
-- references to nothing, cycles, siblings with one slug, an attachment's
-- name twice on a page, bytes with no file.
checkArchive :: Archive -> [AttachmentRecord] -> Either Text ()
checkArchive a attachments = do
  unique "users.json" "user" (map (\u -> u.id.text) a.users)
  unique "users.json" "login" (map (\u -> u.login) a.users)
  unique "groups.json" "group" (map (\g -> g.id.text) a.groups)
  unique "spaces.json" "space" (map (\s -> s.id.text) a.spaces)
  unique "pages.json" "page" (map (\p -> p.id.text) a.pages)
  unique "attachments.json" "attachment" [r.attachment.id.text | r <- attachments]
  unique "attachments.json" "blob" [b.text | r <- attachments, SourceBlob b <- [r.attachment.source]]
  for_ (Map.toList a.membership) $ \(g, members) -> for_ members $ \u ->
    unless (Set.member u userIds) $
      Left ("groups.json: the group " <> show g.text <> " has the member " <> show u.text <> ", who is not in users.json.")
  for_ a.grants.global $ \g -> subject "a global grant" g.subject
  for_ a.grants.spaces $ \g -> do
    unless (Map.member g.space spacesById) $
      Left ("grants.json: a grant is on the space " <> show g.space.text <> ", which is not in spaces.json.")
    subject ("a grant on " <> show g.space.text) g.subject
  for_ a.spaces $ \s -> for_ s.parent $ \parent ->
    unless (Map.member parent spacesById) $
      Left ("spaces.json: the space " <> show s.id.text <> " is under " <> show parent.text <> ", which is not in spaces.json.")
  acyclic "spaces.json" "space" (\s -> s.parent) (\k -> k.text) spacesById
  siblings "spaces.json" "spaces" [(s.parent, s.slug) | s <- a.spaces]
  for_ a.pages $ \p -> do
    unless (Map.member p.space spacesById) $
      Left ("pages.json: the page " <> show p.id.text <> " is in the space " <> show p.space.text <> ", which is not in spaces.json.")
    for_ p.parent $ \parent -> case Map.lookup parent pagesById of
      Nothing -> Left ("pages.json: the page " <> show p.id.text <> " is under " <> show parent.text <> ", which is not in pages.json.")
      Just q -> unless (q.space == p.space) $ Left ("pages.json: the page " <> show p.id.text <> " is under a page of another space.")
  acyclic "pages.json" "page" (\p -> p.parent) (\k -> k.text) pagesById
  for_ a.spaces $ \s -> for_ s.homePage $ \home ->
    unless (fmap (\p -> p.space) (Map.lookup home pagesById) == Just s.id) $
      Left ("spaces.json: the space " <> show s.id.text <> " has the home page " <> show home.text <> ", which is not one of its pages in pages.json.")
  siblings "pages.json" "pages" [((p.space, p.parent), p.slug) | p <- a.pages]
  for_ attachments $ \r -> do
    unless (Map.member r.page pagesById) $
      Left ("attachments.json: the attachment " <> show r.attachment.id.text <> " is on the page " <> show r.page.text <> ", which is not in pages.json.")
    case (r.attachment.source, r.file) of
      (SourceBlob _, Nothing) -> Left ("attachments.json: the attachment " <> show r.attachment.id.text <> " names no file for its bytes.")
      _ -> Right ()
  for_ a.pages $ \p -> unique "attachments.json" ("attachment name on the page " <> show p.id.text <> ",") (map (\x -> x.name) p.attachments)
  where
    userIds = Set.fromList (map (\u -> u.id) a.users)
    groupIds = Set.fromList (map (\g -> g.id) a.groups)
    spacesById = Map.fromList [(s.id, s) | s <- a.spaces]
    pagesById = Map.fromList [(p.id, p) | p <- a.pages]

    unique :: Text -> Text -> [Text] -> Either Text ()
    unique path what keys = case Map.keys (Map.filter (> (1 :: Int)) (Map.fromListWith (+) [(k, 1) | k <- keys])) of
      [] -> Right ()
      k : _ -> Left (path <> ": there are two of the " <> what <> " " <> show k <> ".")

    subject :: Text -> Subject -> Either Text ()
    subject which = \case
      SubjectUser u ->
        unless (Set.member u userIds) $
          Left ("grants.json: " <> which <> " names the user " <> show u.text <> ", who is not in users.json.")
      SubjectGroup g ->
        unless (Set.member g groupIds) $
          Left ("grants.json: " <> which <> " names the group " <> show g.text <> ", which is not in groups.json.")

    siblings :: (Ord k) => Text -> Text -> [(k, Slug)] -> Either Text ()
    siblings path what keyed =
      case [slug | ((_, slug), n) <- Map.toList (Map.fromListWith (+) [(key, 1 :: Int) | key <- keyed]), n > 1] of
        [] -> Right ()
        slug : _ -> Left (path <> ": two " <> what <> " side by side have the slug " <> show (slugText slug) <> ".")

    acyclic :: (Ord k) => Text -> Text -> (v -> Maybe k) -> (k -> Text) -> Map k v -> Either Text ()
    acyclic path what parentOf named byId = for_ (Map.keys byId) (climb mempty)
      where
        climb seen k
          | Set.member k seen = Left (path <> ": the " <> what <> " " <> show (named k) <> " is under itself.")
          | otherwise = for_ (Map.lookup k byId >>= parentOf) (climb (Set.insert k seen))

--------------------------------------------------------------------------------
-- Records

-- | @{"id", "name", "slug", "parent", "public", "createdAt", "mathMacros",
-- "position", "subspaceOrder", "pageOrder"}@: @parent@ is @null@ or
-- missing for a top-level space, @public@ false if missing. The rest were
-- added after version 1 was first written, as additive fields, so no new
-- version: @mathMacros@ (the space's TeX macros) is the empty text if
-- missing; @createdAt@, if missing, is the time the reader is given for the
-- space (an archive's reader gives the time of the earliest page in it, or
-- the archive's own); @position@ (among its siblings, by hand) is 0 if
-- missing; @subspaceOrder@ and @pageOrder@ (@"name"@, @"newest-first"@,
-- @"oldest-first"@ or @"by-hand"@) are by name if missing, or if they name
-- an order this program does not know. Those that have a default are
-- written only when they are not it, so that the record of a space that
-- does not use them is what it was before they were added. So are
-- @homePage@ (the id of the page it opens at, one of its own; none if
-- missing), @icon@ (@{"emoji": …}@, @{"colour": …}@, or @{"image": blob,
-- "mediaType": …, "file": …}@ with the image's bytes in the archive's file
-- 'iconFile'; the default if missing, or of a kind this program does not
-- know) and @description@ (empty if missing).
encodeSpace :: Space -> Value
encodeSpace s =
  object $
    [ "id" .= s.id.text
    , "name" .= s.name
    , "slug" .= s.slug
    , "parent" .= fmap (\p -> p.text) s.parent
    , "public" .= s.public
    , "createdAt" .= s.createdAt
    ]
      <> ["mathMacros" .= s.mathMacros | not (T.null s.mathMacros)]
      <> ["position" .= s.position | s.position /= 0]
      <> ["subspaceOrder" .= orderText s.subspaceOrder | s.subspaceOrder /= ByName]
      <> ["pageOrder" .= orderText s.pageOrder | s.pageOrder /= ByName]
      <> ["homePage" .= home.text | Just home <- [s.homePage]]
      <> ["icon" .= encodeIcon s icon | Just icon <- [s.icon]]
      <> ["description" .= s.description | not (T.null s.description)]

-- | A space's icon as its record has it: an image names the file of the
-- archive its bytes are in.
encodeIcon :: Space -> Icon -> Value
encodeIcon s icon = case (icon, toJSON icon) of
  (IconImage _ _, Object o) -> Object (KeyMap.insert "file" (toJSON (iconFile s)) o)
  (_, v) -> v

-- | A space read back. A record without a @createdAt@ (one written before
-- spaces had one) is given the time the function says for its id.
parseSpace :: (SpaceId -> UTCTime) -> Value -> Parser Space
parseSpace createdBefore = withObject "space" $ \o -> do
  id <- SpaceId <$> o .: "id"
  name <- o .: "name"
  slug <- o .: "slug"
  parent <- fmap SpaceId <$> o .:? "parent"
  public <- o .:? "public" .!= False
  createdAt <- o .:? "createdAt" .!= createdBefore id
  mathMacros <- o .:? "mathMacros" .!= ""
  position <- o .:? "position" .!= 0
  subspaceOrder <- maybe ByName readOrder <$> o .:? "subspaceOrder"
  pageOrder <- maybe ByName readOrder <$> o .:? "pageOrder"
  homePage <- fmap PageId <$> o .:? "homePage"
  icon <- (>>= parseMaybe parseJSON) <$> (o .:? "icon" :: Parser (Maybe Value))
  description <- o .:? "description" .!= ""
  pure Space {id, name, slug, parent, public, mathMacros, createdAt, position, subspaceOrder, pageOrder, homePage, icon, description}

-- | An order as the archive writes it.
orderText :: ChildOrder -> Text
orderText = \case
  ByName -> "name"
  NewestFirst -> "newest-first"
  OldestFirst -> "oldest-first"
  ByHand -> "by-hand"

-- | An order read back; one this program does not know (a later one's) is
-- by name, so that the archive still imports, as it would without the
-- field.
readOrder :: Text -> ChildOrder
readOrder t = fromMaybe ByName (find (\o -> orderText o == t) [minBound .. maxBound])

-- | When a space read without a @createdAt@ is taken to have been made:
-- when the earliest of its pages was, or, if it has none, at the time
-- given. Not before it, as the space was made, but the nearest a record
-- written without the time tells.
spaceCreatedDefault :: UTCTime -> [Page] -> SpaceId -> UTCTime
spaceCreatedDefault fallback pages sid = Map.findWithDefault fallback sid earliest
  where
    earliest = Map.fromListWith min [(p.space, p.createdAt) | p <- pages]

-- | @{"id", "space", "parent", "title", "slug", "body", "createdAt",
-- "updatedAt"}@, without the page's attachments, which are records of their
-- own ('encodeAttachment'): @parent@ is @null@ or missing for a top-level
-- page, @body@ empty if missing, @updatedAt@ the creation if missing.
-- @position@, among its siblings by hand, was added after version 1 was
-- first written (an additive field): 0 if missing, and written only when it
-- is not.
encodePage :: Page -> Value
encodePage p =
  object $
    [ "id" .= p.id.text
    , "space" .= p.space.text
    , "parent" .= fmap (\q -> q.text) p.parent
    , "title" .= p.title
    , "slug" .= p.slug
    , "body" .= p.body
    , "createdAt" .= p.createdAt
    , "updatedAt" .= p.updatedAt
    ]
      <> ["position" .= p.position | p.position /= 0]

-- | A page read back, with no attachments yet.
parsePage :: Value -> Parser Page
parsePage = withObject "page" $ \o -> do
  id <- PageId <$> o .: "id"
  space <- SpaceId <$> o .: "space"
  parent <- fmap PageId <$> o .:? "parent"
  title <- o .: "title"
  slug <- o .: "slug"
  body <- o .:? "body" .!= ""
  createdAt <- o .: "createdAt"
  updatedAt <- o .:? "updatedAt" .!= createdAt
  position <- o .:? "position" .!= 0
  pure Page {id, space, parent, title, slug, body, attachments = [], createdAt, updatedAt, position}

-- | An attachment's record as it was read: the page it is attached to, the
-- attachment, and the file of the archive its bytes are in, if it names
-- one.
data AttachmentRecord = AttachmentRecord
  { page :: PageId
  , attachment :: Attachment
  , file :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @{"id", "page", "name", "mediaType", "size"}@ and where the bytes are:
-- @"url"@ for a file on the web, or @"blob"@, the id the wiki keeps the
-- bytes under, with @"file"@, where they are in an archive
-- ('attachmentFile'). A media type missing is
-- @application/octet-stream@.
encodeAttachment :: PageId -> Attachment -> Value
encodeAttachment page x =
  object $
    [ "id" .= x.id.text
    , "page" .= page.text
    , "name" .= x.name
    , "mediaType" .= x.mediaType
    , "size" .= x.size
    ]
      <> case x.source of
        SourceUrl url -> ["url" .= url]
        SourceBlob blob -> ["blob" .= blob.text, "file" .= attachmentFile x]

parseAttachment :: Value -> Parser AttachmentRecord
parseAttachment = withObject "attachment" $ \o -> do
  id <- AttachmentId <$> o .: "id"
  page <- PageId <$> o .: "page"
  name <- o .: "name"
  mediaType <- o .:? "mediaType" .!= "application/octet-stream"
  size <- o .:? "size" .!= 0
  url <- o .:? "url"
  blob <- o .:? "blob"
  file <- o .:? "file"
  source <- case (url, blob, file) of
    (Just u, Nothing, _) -> pure (SourceUrl u)
    (Nothing, Just b, _) -> pure (SourceBlob (BlobId b))
    -- From a program that keeps bytes under no id of its own: the
    -- attachment's stands for one.
    (Nothing, Nothing, Just _) -> pure (SourceBlob (BlobId ("blob-of-" <> id.text)))
    _ -> fail "an attachment has a url, or a file with its bytes"
  pure AttachmentRecord {page, attachment = Attachment {id, name, mediaType, size, source}, file}

-- | @{"id", "login", "displayName"}@; the display name is the login if
-- missing.
encodeUser :: User -> Value
encodeUser u = object ["id" .= u.id.text, "login" .= u.login, "displayName" .= u.displayName]

parseUser :: Value -> Parser User
parseUser = withObject "user" $ \o -> do
  id <- UserId <$> o .: "id"
  login <- o .: "login"
  displayName <- o .:? "displayName" .!= login
  pure User {id, login, displayName}

-- | @{"id", "name", "members"}@, the members by user id; none if missing.
encodeGroup :: Group -> Set UserId -> Value
encodeGroup g members = object ["id" .= g.id.text, "name" .= g.name, "members" .= map (\u -> u.text) (Set.toList members)]

parseGroup :: Value -> Parser (Group, Set UserId)
parseGroup = withObject "group" $ \o -> do
  id <- GroupId <$> o .: "id"
  name <- o .: "name"
  members <- o .:? "members" .!= []
  pure (Group {id, name}, Set.fromList (map UserId members))

-- | @{"global": […], "spaces": […]}@, a missing list empty. Whom the wiki
-- is open to is not in an archive: it is the setting of the server an
-- archive is imported into, and is read back as 'Open', the default.
encodeGrants :: Grants -> Value
encodeGrants g = object ["global" .= map encodeGlobalGrant g.global, "spaces" .= map encodeSpaceGrant g.spaces]

parseGrants :: Value -> Parser Grants
parseGrants = withObject "grants" $ \o -> do
  global <- traverse parseGlobalGrant =<< o .:? "global" .!= []
  spaces <- traverse parseSpaceGrant =<< o .:? "spaces" .!= []
  pure Grants {global, spaces, access = Open}

-- | @{"subject", "permission"}@, the permission @"administer"@ or
-- @"create-spaces"@.
encodeGlobalGrant :: GlobalGrant -> Value
encodeGlobalGrant g =
  object
    [ "subject" .= encodeSubject g.subject
    , "permission" .= case g.permission of
        Administer -> "administer" :: Text
        CreateSpaces -> "create-spaces"
    ]

parseGlobalGrant :: Value -> Parser GlobalGrant
parseGlobalGrant = withObject "global grant" $ \o -> do
  subject <- parseSubject =<< o .: "subject"
  name <- o .: "permission"
  permission <- case name :: Text of
    "administer" -> pure Administer
    "create-spaces" -> pure CreateSpaces
    other -> fail ("no global permission is called " <> show other)
  pure GlobalGrant {subject, permission}

-- | @{"space", "subject", "permission"}@, the permission @"view"@, @"edit"@
-- or @"administer"@.
encodeSpaceGrant :: SpaceGrant -> Value
encodeSpaceGrant g =
  object
    [ "space" .= g.space.text
    , "subject" .= encodeSubject g.subject
    , "permission" .= case g.permission of
        View -> "view" :: Text
        Edit -> "edit"
        AdministerSpace -> "administer"
    ]

parseSpaceGrant :: Value -> Parser SpaceGrant
parseSpaceGrant = withObject "space grant" $ \o -> do
  space <- SpaceId <$> o .: "space"
  subject <- parseSubject =<< o .: "subject"
  name <- o .: "permission"
  permission <- case name :: Text of
    "view" -> pure View
    "edit" -> pure Edit
    "administer" -> pure AdministerSpace
    other -> fail ("no space permission is called " <> show other)
  pure SpaceGrant {space, subject, permission}

-- | @{"user": id}@ or @{"group": id}@.
encodeSubject :: Subject -> Value
encodeSubject = \case
  SubjectUser u -> object ["user" .= u.text]
  SubjectGroup g -> object ["group" .= g.text]

parseSubject :: Value -> Parser Subject
parseSubject = withObject "subject" $ \o -> do
  user <- o .:? "user"
  inGroup <- o .:? "group"
  case (user, inGroup) of
    (Just u, Nothing) -> pure (SubjectUser (UserId u))
    (Nothing, Just g) -> pure (SubjectGroup (GroupId g))
    _ -> fail "a subject is either a user or a group"
