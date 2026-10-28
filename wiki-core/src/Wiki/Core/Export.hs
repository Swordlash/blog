-- | Export and import of a whole wiki as one archive: what the demo
-- exports and imports as a zip file, and what the server imports and
-- exports too, so that a wiki moves between them as one file.
-- docs/export.md describes the format for people who read the files.
--
-- = The archive
--
-- An archive is a set of files, by path. 'writeArchive' produces them, and
-- 'readArchive' consumes them; the zip container is the caller's business.
-- 'archiveFiles' gives the same files with each attachment's and icon's
-- bytes named by their blob, for a caller that keeps blobs on disk and
-- copies them into the zip file one at a time (the server).
-- Version 2 of the format, the one written now, is a tree of directories:
--
-- * @manifest.json@: @{"format": "wiki-export", "formatVersion": 2,
--   "createdAt": …, "app": …}@: what the archive is, which version of this
--   format it is written in, when, and by which program.
-- * @users.json@, @groups.json@ (each group with its @members@) and
--   @grants.json@ (@{"global": […], "spaces": […]}@): a list of records
--   each.
-- * @audit.json@: the audit log ("Wiki.Core.Audit"), oldest first, written
--   only when it has entries; an archive without it has none.
-- * @spaces\/\<slug>\/@: a directory per top-level space. It holds
--   @space.json@ (the space's record, without its parent, which the
--   directory gives), @icon.\<ext>@ (the image of an icon that is one),
--   @pages\/\<slug>\/@ (a directory per top-level page) and
--   @spaces\/\<slug>\/@ (a directory per subspace, of the same shape).
-- * A page's directory holds @page.json@ (the page's record, without its
--   space, parent and body, with its attachments' records), @page.md@ (the
--   body, byte for byte), @attachments\/\<name>@ (the bytes of each
--   attachment the wiki keeps), @comments.json@ (the page's comment
--   threads, when it has any) and @pages\/\<slug>\/@ (a directory per
--   subpage, of the same shape).
--
-- A directory is named by the slug of its space or page ('safeDirectoryName'),
-- and an attachment's file by its name ('safeFileName'). The records keep
-- the slugs, names and ids; the directory names only say where a record
-- is. Every record is a JSON object with named fields, written and read by
-- the functions here rather than derived from the Haskell types, so that
-- renaming a field in the code cannot change the format by accident. The
-- demo keeps its records in the browser's IndexedDB with the same
-- functions ("Wiki.App.Backend.Mem.Persist" in @wiki-app@): a space's and
-- a page's record there are the records of version 1, with the parent, the
-- space and the body that version 2 takes from the tree.
--
-- = Compatibility
--
-- The format changes in two ways, and this module keeps to both:
--
-- * __Additions need no new version.__ A reader ignores the fields and the
--   files it does not know, and a field that may be missing has a default
--   (a space is private and has no math macros, lists its children by name
--   and was created with its first page; a page has an empty body; a child
--   ordered by hand is at position 0; a group has no members; unless the
--   record says otherwise). So an older program reads a newer archive of
--   the same version, and a newer program an older archive.
-- * __Anything else bumps 'currentVersion'__: a field or a file removed,
--   renamed or moved, or one whose meaning changes. The reader then brings
--   an archive of every older version to the current one, one version at a
--   time ('migrations'), before reading it, so every archive ever written
--   can still be imported. Version 1 kept every kind of record in one file
--   (@spaces.json@, @pages.json@, @attachments.json@); its step reads those
--   files, checks them as version 1 was checked, and writes the same wiki
--   as version 2. An archive of a version newer than this program knows is
--   refused, with a message that says so, never read in part.
--
-- 'readArchive' checks the whole archive before it returns anything: every
-- file is there and parses, every id is unique, everything a record refers
-- to is in the archive, no two siblings share a slug, and every
-- attachment's file is there with as many bytes as its record says. A
-- refusal comes with the reason, naming the file and the record.
module Wiki.Core.Export
  ( -- * Archives
    Archive (..)
  , currentVersion
  , writeArchive
  , ArchiveFile (..)
  , archiveFiles
  , readArchive
  , safeDirectoryName
  , safeFileName

    -- * Comments
  , threadsAmong

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
import Data.Aeson (Key, ToJSON, Value (..), eitherDecodeStrict', encode, object, parseJSON, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Pair, Parser, parseEither, parseMaybe)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Numeric (showHex)
import Protolude
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Audit (AuditEntry (..), encodeAuditEntry, parseAuditEntry)
import Wiki.Core.Comment (Comment (..), Thread (..), absentAuthor, formerAuthor, formerAuthorName)
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (Group (..), Login (..), Membership, User (..))
import Wiki.Core.Version (Author (..))

-- | A whole wiki: its users, its grants, its spaces and pages (each page
-- with its attachments' records), its pages' comments, and the bytes of
-- the attachments and icons it stores, by the blob each one names.
data Archive = Archive
  { createdAt :: UTCTime
  , app :: Text
  -- ^ The program that wrote it, for a person to read: its name and
  -- version.
  , users :: [User]
  , groups :: [Group]
  , membership :: Membership
  , grants :: Grants
  , spaces :: [Space]
  , pages :: [Page]
  , threads :: Map PageId [Thread]
  -- ^ Each page's comment threads, in the order they were opened, for the
  -- pages that have any. A comment's author is one of 'users', one of
  -- 'commentAuthors', or a person who is neither (an archive names them by
  -- their name only). 'threadsAmong' gives the authors as a wiki with
  -- other users knows them.
  , commentAuthors :: [User]
  -- ^ The people who wrote comments and are not in 'users', with the
  -- login and name the archive gives for them. The server's built-in
  -- administrator is one: it has no record among the users. An import
  -- matches them by login with its own users.
  , blobs :: Map BlobId ByteString
  , audit :: [AuditEntry]
  -- ^ The audit log, oldest first: who did what in the wiki's
  -- administration (WP4.10 of docs/PLAN.md).
  }
  deriving stock (Eq, Show)

-- | The version of the format this module writes, and the newest it reads.
currentVersion :: Int
currentVersion = 2

-- | What the manifest says an archive is.
formatName :: Text
formatName = "wiki-export"

--------------------------------------------------------------------------------
-- Writing

-- | The archive's files, by path: the manifest first, then the people and
-- the grants, then the tree of spaces and pages.
--
-- A space is written in the directory of its parent space, and a page in
-- the directory of its parent page. A space whose parent is not in the
-- archive, or is under the space itself, is written at the top, and so is
-- a page whose parent is not one of its space's pages: the wiki's backends
-- never hold such records, and writing them at the top keeps them in the
-- archive. A page whose space is not in the archive has no directory to be
-- in, and is left out.
writeArchive :: Archive -> [(Text, ByteString)]
writeArchive a = [(path, bytes) | (path, file) <- archiveFiles a, Just bytes <- [contents file]]
  where
    contents = \case
      FileBytes bytes -> Just bytes
      FileBlob blob -> Map.lookup blob a.blobs

-- | 'ArchiveFile' is what one file of an archive holds, as 'archiveFiles'
-- gives it: bytes, or the bytes of a blob, named by its id.
data ArchiveFile
  = FileBytes ByteString
  | FileBlob BlobId
  deriving stock (Eq, Show)

-- | The archive's files, by path, in the order 'writeArchive' gives them.
-- The file of an attachment or an icon names its blob instead of holding
-- its bytes, and is there whether or not the archive's 'blobs' has them.
-- So an archive whose 'blobs' is empty gives every file, and the caller
-- fetches each blob's bytes as it writes the file: the server copies them
-- from the blob store into the zip file ("Wiki.Core.Export.Zip"), so that
-- an export never holds every attachment in memory. The list is made as
-- it is consumed.
archiveFiles :: Archive -> [(Text, ArchiveFile)]
archiveFiles a =
  [ ("manifest.json", FileBytes (encodeJson manifest))
  , ("users.json", FileBytes (encodeJson [encodeUser u | u <- a.users]))
  , ("groups.json", FileBytes (encodeJson [encodeGroup g (Map.findWithDefault mempty g.id a.membership) | g <- a.groups]))
  , ("grants.json", FileBytes (encodeJson (encodeGrants a.grants)))
  ]
    <> [("audit.json", FileBytes (encodeJson (map encodeAuditEntry a.audit))) | not (null a.audit)]
    <> concatMap (spaceFiles "") [s | s <- a.spaces, not (spaceUnderParent s)]
  where
    manifest =
      object
        [ "format" .= formatName
        , "formatVersion" .= currentVersion
        , "createdAt" .= a.createdAt
        , "app" .= a.app
        ]

    spacesById = Map.fromList [(s.id, s) | s <- a.spaces]
    pagesById = Map.fromList [(p.id, p) | p <- a.pages]

    spaceUnderParent s = isJust s.parent && endsAtTop (\i -> (\x -> x.parent) <$> Map.lookup i spacesById) s.id
    pageUnderParent p = isJust p.parent && endsAtTop pageParent p.id
    -- A page's parent, if the page is there; a parent in another space
    -- counts as missing.
    pageParent i =
      Map.lookup i pagesById >>= \p -> case p.parent of
        Nothing -> Just Nothing
        Just q
          | fmap (\x -> x.space) (Map.lookup q pagesById) == Just p.space -> Just (Just q)
          | otherwise -> Nothing

    subspaces = Map.fromListWith (flip (<>)) [(parent, [s]) | s <- a.spaces, spaceUnderParent s, Just parent <- [s.parent]]
    topPages = Map.fromListWith (flip (<>)) [(p.space, [p]) | p <- a.pages, not (pageUnderParent p)]
    subpages = Map.fromListWith (flip (<>)) [(parent, [p]) | p <- a.pages, pageUnderParent p, Just parent <- [p.parent]]

    spaceFiles above s =
      let dir = above <> "spaces/" <> safeDirectoryName (slugText s.slug) <> "/"
       in (dir <> "space.json", FileBytes (encodeJson (object (spaceFields (iconFileName <$> imageOf s) s))))
            : [(dir <> iconFileName mediaType, FileBlob blob) | Just (IconImage blob mediaType) <- [s.icon]]
              <> concatMap (pageFiles dir) (Map.findWithDefault [] s.id topPages)
              <> concatMap (spaceFiles dir) (Map.findWithDefault [] s.id subspaces)

    pageFiles above p =
      let dir = above <> "pages/" <> safeDirectoryName (slugText p.slug) <> "/"
          discussed = Map.findWithDefault [] p.id a.threads
       in [ (dir <> "page.json", FileBytes (encodeJson (object (pageFields p <> ["attachments" .= map (\x -> object (attachmentFields (attachmentPath x) x)) p.attachments]))))
          , (dir <> "page.md", FileBytes (encodeUtf8 p.body))
          ]
            <> [(dir <> attachmentPath x, FileBlob blob) | x <- p.attachments, SourceBlob blob <- [x.source]]
            <> [(dir <> "comments.json", FileBytes (encodeJson (map (encodeThread authorRecord) discussed))) | not (null discussed)]
            <> concatMap (pageFiles dir) (Map.findWithDefault [] p.id subpages)

    -- The users win over the comment authors of the same id: they are the
    -- wiki's own records.
    people = Map.fromList [(u.id, u) | u <- a.commentAuthors <> a.users]
    authorRecord :: Author -> Value
    authorRecord author = case Map.lookup author.id people of
      Just u -> object ["id" .= u.id.text, "login" .= u.login, "displayName" .= u.displayName]
      Nothing -> object ["id" .= author.id.text, "displayName" .= fromMaybe author.name (formerAuthorName author.id)]

    imageOf s = case s.icon of
      Just (IconImage _ mediaType) -> Just mediaType
      _ -> Nothing

-- | Whether following a record's parents ends at a record without one,
-- rather than at a record that is not there, or back at itself. The
-- function gives a record's parent ('Just' 'Nothing' for a record at the
-- top), or 'Nothing' for a record that is not there.
endsAtTop :: (Ord k) => (k -> Maybe (Maybe k)) -> k -> Bool
endsAtTop parentOf = climb mempty
  where
    climb seen k
      | Set.member k seen = False
      | otherwise = case parentOf k of
          Nothing -> False
          Just Nothing -> True
          Just (Just parent) -> climb (Set.insert k seen) parent

-- | Where an attachment's bytes are, in its page's directory.
attachmentPath :: Attachment -> Text
attachmentPath x = "attachments/" <> safeFileName x.name

-- | The name of a space's icon image, in its space's directory: @icon.@
-- with the extension of the image's media type.
iconFileName :: Text -> Text
iconFileName mediaType = "icon." <> maybe "bin" snd (find (\(known, _) -> known == T.toLower mediaType) extensions)
  where
    extensions = [("image/png", "png"), ("image/jpeg", "jpg"), ("image/gif", "gif"), ("image/webp", "webp"), ("image/avif", "avif")]

-- | The directory name for a slug. A slug is lowercase ASCII letters,
-- digits and dashes ("Wiki.Core.Slug"), which every file system takes,
-- except the names Windows keeps for its devices (@con@, @nul@, @com1@
-- and the others), which it cannot extract a directory under. Those get a
-- @_@ at the end. No slug has a @_@, so the name cannot be another
-- sibling's.
safeDirectoryName :: Text -> Text
safeDirectoryName slug
  | windowsDevice slug = slug <> "_"
  | otherwise = slug

-- | The file name for an attachment's name. An attachment's name is any
-- text its uploader gave, so the characters a zip file or a file system
-- refuses are written as @%@ and the two hex digits of each of their UTF-8
-- bytes, as in a URL: control characters, @\/ \\ : * ? " \< > |@, and @%@
-- itself. So are a name made only of dots (@.@ and @..@ name directories),
-- a dot or a space at the end (which Windows drops), and the first letter
-- of a Windows device name (@con.txt@ becomes @%63on.txt@). An empty name
-- becomes @%@. Two different names never give the same file name, since
-- the escapes can be undone. Letters outside ASCII are kept: zip files
-- name their entries in UTF-8.
safeFileName :: Text -> Text
safeFileName name
  | T.null name = "%"
  | T.all (== '.') name = T.concatMap escape name
  | otherwise = deviceSafe (endSafe (T.concatMap plain name))
  where
    plain c
      | isControl c || c `elem` ("/\\:*?\"<>|%" :: [Char]) = escape c
      | otherwise = T.singleton c
    endSafe t = case T.unsnoc t of
      Just (rest, c) | c == '.' || c == ' ' -> rest <> escape c
      _ -> t
    deviceSafe t = case T.uncons t of
      Just (c, rest) | windowsDevice (T.takeWhile (/= '.') t) -> escape c <> rest
      _ -> t
    escape c = T.concat ["%" <> hex b | b <- BS.unpack (encodeUtf8 (T.singleton c))]
    hex b = T.toUpper (T.justifyRight 2 '0' (T.pack (showHex b "")))

-- | Whether a name is one Windows keeps for a device, in any case.
windowsDevice :: Text -> Bool
windowsDevice t = T.toLower t `elem` (["con", "prn", "aux", "nul"] <> [d <> show n | d <- ["com", "lpt"], n <- [1 .. 9 :: Int]])

-- | JSON, compact.
encodeJson :: (ToJSON a) => a -> ByteString
encodeJson = BSL.toStrict . encode

-- | A value parsed from JSON with one of this module's parsers, or why not.
decodeJson :: (Value -> Parser a) -> ByteString -> Either Text a
decodeJson parse bytes = first toS (eitherDecodeStrict' bytes >>= parseEither parse)

--------------------------------------------------------------------------------
-- Reading

-- | An archive's files, by path.
type Files = Map Text ByteString

-- | What an archive's @manifest.json@ says: the version of the format it
-- is written in, when it was written, and by which program.
data Manifest = Manifest
  { version :: Int
  , createdAt :: UTCTime
  , app :: Text
  }

-- | How an archive of each older version becomes one of the next version,
-- by the version it starts from. A change that increments 'currentVersion'
-- adds the step from the previous version, and every older archive then
-- goes through each step after its own, in turn.
migrations :: Map Int (Manifest -> Files -> Either Text Files)
migrations =
  Map.fromList
    [ -- Version 1 to 2: the flat files read and checked as version 1 was,
      -- and the same wiki written as a tree.
      (1, \manifest files -> Map.fromList . writeArchive <$> readVersion1 manifest files)
    ]

-- | The wiki an archive's files hold, checked in full, or why it is
-- refused.
readArchive :: Files -> Either Text Archive
readArchive entries = do
  manifestBytes <- note "It has no manifest.json, so it is not a wiki export." (Map.lookup "manifest.json" entries)
  manifest <- inFile "manifest.json" (decodeJson parseManifest manifestBytes)
  when (manifest.version > currentVersion) $
    Left
      ( "It is written in version "
          <> show manifest.version
          <> " of the export format, by a newer version of the wiki; this one reads version "
          <> show currentVersion
          <> " and older."
      )
  when (manifest.version < 1) $
    Left ("Its manifest.json gives the format version " <> show manifest.version <> ", which there has never been.")
  current <- migrate manifest manifest.version entries
  readVersion2 manifest current
  where
    migrate manifest version files
      | version >= currentVersion = Right files
      | otherwise = case Map.lookup version migrations of
          Nothing -> Left ("There is no way from version " <> show version <> " of the export format to the next.")
          Just step -> step manifest files >>= migrate manifest (version + 1)

parseManifest :: Value -> Parser Manifest
parseManifest = withObject "manifest" $ \o -> do
  format <- o .: "format"
  unless (format == formatName) $ fail ("this is not a wiki export but " <> show (format :: Text))
  Manifest <$> o .: "formatVersion" <*> o .: "createdAt" <*> o .:? "app" .!= ""

-- | The people and grants of an archive, in the files both versions have.
readPeople :: Files -> Either Text ([User], [(Group, Set UserId)], Grants, [AuditEntry])
readPeople entries = do
  users <- records "users.json" parseUser =<< jsonAt entries "users.json"
  groups <- records "groups.json" parseGroup =<< jsonAt entries "groups.json"
  grants <- inFile "grants.json" . parsed parseGrants =<< jsonAt entries "grants.json"
  -- Optional: an archive written before there was an audit log, or of a
  -- wiki whose log is empty, has none.
  audit <- case Map.lookup "audit.json" entries of
    Nothing -> Right []
    Just bytes -> records "audit.json" parseAuditEntry =<< jsonOf "audit.json" bytes
  pure (users, groups, grants, audit)

-- | A JSON file of an archive, parsed but not yet read as records.
jsonAt :: Files -> Text -> Either Text Value
jsonAt entries path = note ("It has no " <> path <> ".") (Map.lookup path entries) >>= jsonOf path

jsonOf :: Text -> ByteString -> Either Text Value
jsonOf path bytes = inFile path (first toS (eitherDecodeStrict' bytes))

-- | A file's list of records, each parsed.
records :: Text -> (Value -> Parser a) -> Value -> Either Text [a]
records path parse =
  inFile path . \case
    Array values -> traverse (parsed parse) (toList values)
    _ -> Left "it is not a list of records"

parsed :: (Value -> Parser a) -> Value -> Either Text a
parsed parse = first toS . parseEither parse

inFile :: Text -> Either Text a -> Either Text a
inFile path = first (\why -> path <> ": " <> why)

-- | The bytes an attachment's record names, checked against its size.
-- @named@ says which record names the file.
attachmentBytes :: Files -> Text -> AttachmentRecord -> Text -> Either Text (BlobId, ByteString)
attachmentBytes entries named r file = do
  blob <- case r.attachment.source of
    SourceBlob b -> Right b
    SourceUrl _ -> Left (named <> ": the attachment " <> show r.attachment.id.text <> " has both a URL and a file.")
  bytes <-
    note
      ("The file " <> show file <> ", which " <> named <> " names for the attachment " <> show r.attachment.id.text <> ", is not in the archive.")
      (Map.lookup file entries)
  unless (fromIntegral (BS.length bytes) == r.attachment.size) $
    Left ("The file " <> show file <> " has " <> show (BS.length bytes) <> " bytes, where " <> named <> " says " <> show r.attachment.size <> ".")
  pure (blob, bytes)

-- | The bytes of each blob, from the files of the attachments and icons
-- that name it. Two attachments may share a blob: the server keeps bytes
-- under their hash, so two uploads of the same file are one blob, and its
-- archive has a file for each of them. Their files must then hold the same
-- bytes.
oneBytesPerBlob :: [(BlobId, ByteString)] -> Either Text (Map BlobId ByteString)
oneBytesPerBlob = foldlM add mempty
  where
    add found (blob, bytes) = case Map.lookup blob found of
      Just other | other /= bytes -> Left ("Two files hold the blob " <> show blob.text <> ", with different bytes.")
      _ -> Right (Map.insert blob bytes found)

-- | An archive of version 1, checked as it was: every kind of record in a
-- file of its own, the attachments' bytes under @attachments\/\<id>\/@, and
-- the icons' images under @icons\/@. Version 1 has no comments.
readVersion1 :: Manifest -> Files -> Either Text Archive
readVersion1 manifest entries = do
  (users, groupsAndMembers, grants, audit) <- readPeople entries
  pages <- records "pages.json" parsePage =<< jsonAt entries "pages.json"
  spaces <- records "spaces.json" (parseSpace (spaceCreatedDefault manifest.createdAt pages)) =<< jsonAt entries "spaces.json"
  attachments <- records "attachments.json" parseAttachment =<< jsonAt entries "attachments.json"
  attached <- for [(r, file) | r@AttachmentRecord {file = Just file} <- attachments] $ \(r, file) ->
    attachmentBytes entries "attachments.json" r file
  icons <- for [(s, blob) | s <- spaces, Just (IconImage blob _) <- [s.icon]] $ \(s, blob) -> do
    let file = "icons/" <> s.id.text
    bytes <-
      note
        ("The file " <> show file <> ", which spaces.json names for the icon of the space " <> show s.id.text <> ", is not in the archive.")
        (Map.lookup file entries)
    pure (blob, bytes)
  blobs <- oneBytesPerBlob (attached <> icons)
  let attachedTo pid = [x | AttachmentRecord {page, attachment = x} <- attachments, page == pid]
      archive =
        Archive
          { createdAt = manifest.createdAt
          , app = manifest.app
          , users
          , groups = map fst groupsAndMembers
          , membership = Map.fromList [(g.id, members) | (g, members) <- groupsAndMembers]
          , grants
          , spaces
          , pages = [p {attachments = attachedTo p.id} | p <- pages]
          , threads = mempty
          , commentAuthors = []
          , blobs
          , audit
          }
      naming =
        Naming
          { spaceAt = const "spaces.json"
          , pageAt = const "pages.json"
          , attachmentsAt = const "attachments.json"
          , commentsAt = const "comments"
          }
  checkArchive naming archive attachments
  pure archive

-- | One space or page found in a version 2 archive's tree.
data Found
  = -- | A space: where its record is, the record (read again once the
    -- pages are known, if it gives no creation time), the space, and
    -- where its icon's image is, if it has one.
    FoundSpace Text Value Space (Maybe Text)
  | -- | A page: where its record is, the page without its attachments,
    -- its attachments' records (with each file's whole path), its threads
    -- with where they are, and the comment authors who are not users.
    FoundPage Text Page [AttachmentRecord] (Text, [Thread]) [User]

-- | An archive of version 2: the tree of spaces and pages under
-- @spaces\/@.
readVersion2 :: Manifest -> Files -> Either Text Archive
readVersion2 manifest entries = do
  (users, groupsAndMembers, grants, audit) <- readPeople entries
  let byLogin = Map.fromList [(u.login, u) | u <- users]
      userIds = Set.fromList (map (\u -> u.id) users)
  found <- spacesUnder (authorFrom byLogin userIds) "" Nothing
  let foundSpaces = [(path, s, icon) | FoundSpace path _ s icon <- found]
      foundPages = [(path, p, xs, discussed, authors) | FoundPage path p xs discussed authors <- found]
      attachments = concat [xs | (_, _, xs, _, _) <- foundPages]
  -- A space whose record gives no creation time was created with its
  -- first page, which only the whole tree tells.
  spaces <- for [(path, value, s) | FoundSpace path value s _ <- found] $ \(path, value, s) ->
    if hasField "createdAt" value
      then Right s
      else inFile path (parsed (parseSpace (spaceCreatedDefault manifest.createdAt [p | (_, p, _, _, _) <- foundPages])) value)
  attached <- for [(path, r, file) | (path, _, xs, _, _) <- foundPages, r@AttachmentRecord {file = Just file} <- xs] $ \(path, r, file) ->
    attachmentBytes entries path r file
  icons <- for [(path, blob, file) | (path, s, Just file) <- foundSpaces, Just (IconImage blob _) <- [s.icon]] $ \(path, blob, file) -> do
    bytes <-
      note
        ("The file " <> show file <> ", which " <> path <> " names for the space's icon, is not in the archive.")
        (Map.lookup file entries)
    pure (blob, bytes)
  blobs <- oneBytesPerBlob (attached <> icons)
  let archive =
        Archive
          { createdAt = manifest.createdAt
          , app = manifest.app
          , users
          , groups = map fst groupsAndMembers
          , membership = Map.fromList [(g.id, members) | (g, members) <- groupsAndMembers]
          , grants
          , spaces = sortOn (\s -> s.id) spaces
          , pages = sortOn (\p -> p.id) [p {attachments = map (\r -> r.attachment) xs} | (_, p, xs, _, _) <- foundPages]
          , threads = Map.fromList [(p.id, ts) | (_, p, _, (_, ts), _) <- foundPages, not (null ts)]
          , commentAuthors = Map.elems (Map.fromList [(u.id, u) | (_, _, _, _, authors) <- foundPages, u <- authors])
          , blobs
          , audit
          }
      located :: (Ord k) => [(k, Text)] -> k -> Text
      located paths = \k -> Map.findWithDefault "the archive" k byKey
        where
          byKey = Map.fromListWith (\later earlier -> earlier <> " and " <> later) paths
      naming =
        Naming
          { spaceAt = located [(s.id, path) | (path, s, _) <- foundSpaces]
          , pageAt = located [(p.id, path) | (path, p, _, _, _) <- foundPages]
          , attachmentsAt = located [(p.id, path) | (path, p, _, _, _) <- foundPages]
          , commentsAt = located [(p.id, path) | (_, p, _, (path, _), _) <- foundPages]
          }
  checkArchive naming archive attachments
  pure archive
  where
    -- The directories just under a directory, each with its slash.
    directoriesIn :: Text -> [Text]
    directoriesIn dir =
      Set.toList . Set.fromList $
        [ dir <> name <> "/"
        | path <- Map.keys (Map.takeWhileAntitone (dir `T.isPrefixOf`) (Map.dropWhileAntitone (< dir) entries))
        , let (name, rest) = T.breakOn "/" (T.drop (T.length dir) path)
        , not (T.null rest)
        ]

    spacesUnder :: (Named -> (Author, Maybe User)) -> Text -> Maybe SpaceId -> Either Text [Found]
    spacesUnder author above parent = fmap concat . for (directoriesIn (above <> "spaces/")) $ \dir -> do
      let path = dir <> "space.json"
      value <- withFields ["parent" .= fmap (\p -> p.text) parent] <$> jsonAt entries path
      space <- inFile path (parsed (parseSpace (const manifest.createdAt)) value)
      icon <- case space.icon of
        Just (IconImage _ mediaType) -> do
          named <- inFile path (parsed (withObject "space" (\o -> (o .:? "icon" :: Parser (Maybe Value)) >>= maybe (pure Nothing) (withObject "icon" (.:? "file")))) value)
          pure (Just (dir <> fromMaybe (iconFileName mediaType) named))
        _ -> pure Nothing
      here <- pagesUnder author dir space.id Nothing
      below <- spacesUnder author dir (Just space.id)
      pure (FoundSpace path value space icon : here <> below)

    pagesUnder :: (Named -> (Author, Maybe User)) -> Text -> SpaceId -> Maybe PageId -> Either Text [Found]
    pagesUnder author above space parent = fmap concat . for (directoriesIn (above <> "pages/")) $ \dir -> do
      let path = dir <> "page.json"
          bodyPath = dir <> "page.md"
          commentsPath = dir <> "comments.json"
      body <- for (Map.lookup bodyPath entries) $ \bytes ->
        inFile bodyPath (first (const "it is not UTF-8 text") (decodeUtf8' bytes))
      value <-
        withFields (["space" .= space.text, "parent" .= fmap (\p -> p.text) parent] <> ["body" .= b | Just b <- [body]])
          <$> jsonAt entries path
      page <- inFile path (parsed parsePage value)
      attached <- inFile path (parsed (withObject "page" (\o -> o .:? "attachments" .!= [])) value)
      xs <- traverse (inFile path . parsed parseAttachment . withFields ["page" .= page.id.text]) attached
      discussed <- case Map.lookup commentsPath entries of
        Nothing -> Right []
        Just bytes -> records commentsPath (parseThread author page.id) =<< jsonOf commentsPath bytes
      below <- pagesUnder author dir space (Just page.id)
      pure
        ( FoundPage
            path
            page
            [r {file = (dir <>) <$> r.file} | r <- xs]
            (commentsPath, map fst discussed)
            (catMaybes (concatMap snd discussed))
            : below
        )

    -- A comment's author as the archive names them: the user with their
    -- login, if there is one; otherwise the person by the id and name the
    -- archive gives, with their login for an import to match, if it gives
    -- one. An id that is one of the users' is not kept for another person:
    -- such an author is kept by their name ('formerAuthor').
    authorFrom :: Map Login User -> Set UserId -> Named -> (Author, Maybe User)
    authorFrom byLogin userIds n = case n.login >>= (`Map.lookup` byLogin) of
      Just u -> (Author {id = u.id, name = u.displayName}, Nothing)
      Nothing ->
        let i = case n.id of
              Just kept | Set.notMember kept userIds -> kept
              _ -> formerAuthor n.displayName
            author = if isJust (formerAuthorName i) then absentAuthor i else Author {id = i, name = n.displayName}
         in (author, (\login -> User {id = i, login, displayName = n.displayName}) <$> n.login)

-- | A JSON object with these fields set, in place of any it had.
withFields :: [Pair] -> Value -> Value
withFields pairs = \case
  Object o -> Object (KeyMap.union (KeyMap.fromList pairs) o)
  other -> other

hasField :: Key -> Value -> Bool
hasField key = \case
  Object o -> KeyMap.member key o
  _ -> False

-- | Where each kind of record is in an archive, for the reasons a refusal
-- gives: the file of a space's record, of a page's, of a page's
-- attachments' records, and of a page's comments.
data Naming = Naming
  { spaceAt :: SpaceId -> Text
  , pageAt :: PageId -> Text
  , attachmentsAt :: PageId -> Text
  , commentsAt :: PageId -> Text
  }

-- | Whatever in a parsed archive does not fit together: duplicates,
-- references to nothing, cycles, siblings with one slug, an attachment's
-- name twice on a page, bytes without a file.
checkArchive :: Naming -> Archive -> [AttachmentRecord] -> Either Text ()
checkArchive naming a attachments = do
  unique "user" [(u.id.text, "users.json") | u <- a.users]
  unique "login" [(u.login.text, "users.json") | u <- a.users]
  unique "group" [(g.id.text, "groups.json") | g <- a.groups]
  unique "space" [(s.id.text, naming.spaceAt s.id) | s <- a.spaces]
  unique "page" [(p.id.text, naming.pageAt p.id) | p <- a.pages]
  unique "attachment" [(r.attachment.id.text, naming.attachmentsAt r.page) | r <- attachments]
  unique "entry" [(e.id, "audit.json") | e <- a.audit]
  unique "thread" [(t.id.text, naming.commentsAt p) | (p, ts) <- Map.toList a.threads, t <- ts]
  unique "comment" [(c.id.text, naming.commentsAt p) | (p, ts) <- Map.toList a.threads, t <- ts, c <- t.comments]
  for_ (Map.toList a.membership) $ \(g, members) -> for_ members $ \u ->
    unless (Set.member u userIds) $
      Left ("groups.json: the group " <> show g.text <> " has the member " <> show u.text <> ", who is not in users.json.")
  for_ a.grants.global $ \g -> subject "a global grant" g.subject
  for_ a.grants.spaces $ \g -> do
    unless (Map.member g.space spacesById) $
      Left ("grants.json: a grant is on the space " <> show g.space.text <> ", which is not in the archive.")
    subject ("a grant on " <> show g.space.text) g.subject
  for_ a.spaces $ \s -> for_ s.parent $ \parent ->
    unless (Map.member parent spacesById) $
      Left (naming.spaceAt s.id <> ": the space " <> show s.id.text <> " is under " <> show parent.text <> ", which is not in the archive.")
  acyclic (\s -> naming.spaceAt s) "space" (\s -> s.parent) (\k -> k.text) spacesById
  siblings "spaces" [((s.parent, s.slug), naming.spaceAt s.id) | s <- a.spaces]
  for_ a.pages $ \p -> do
    unless (Map.member p.space spacesById) $
      Left (naming.pageAt p.id <> ": the page " <> show p.id.text <> " is in the space " <> show p.space.text <> ", which is not in the archive.")
    for_ p.parent $ \parent -> case Map.lookup parent pagesById of
      Nothing -> Left (naming.pageAt p.id <> ": the page " <> show p.id.text <> " is under " <> show parent.text <> ", which is not in the archive.")
      Just q -> unless (q.space == p.space) $ Left (naming.pageAt p.id <> ": the page " <> show p.id.text <> " is under a page of another space.")
  acyclic (\p -> naming.pageAt p) "page" (\p -> p.parent) (\k -> k.text) pagesById
  for_ a.spaces $ \s -> for_ s.homePage $ \home ->
    unless (fmap (\p -> p.space) (Map.lookup home pagesById) == Just s.id) $
      Left (naming.spaceAt s.id <> ": the space " <> show s.id.text <> " has the home page " <> show home.text <> ", which is not one of its pages.")
  siblings "pages" [(((p.space, p.parent), p.slug), naming.pageAt p.id) | p <- a.pages]
  for_ attachments $ \r -> do
    unless (Map.member r.page pagesById) $
      Left (naming.attachmentsAt r.page <> ": the attachment " <> show r.attachment.id.text <> " is on the page " <> show r.page.text <> ", which is not in the archive.")
    case (r.attachment.source, r.file) of
      (SourceBlob _, Nothing) -> Left (naming.attachmentsAt r.page <> ": the attachment " <> show r.attachment.id.text <> " names no file for its bytes.")
      _ -> Right ()
  for_ a.pages $ \p -> unique ("attachment name on the page " <> show p.id.text <> ",") [(x.name, naming.attachmentsAt p.id) | x <- p.attachments]
  for_ (Map.toList a.threads) $ \(p, ts) -> do
    unless (Map.member p pagesById) $
      Left (naming.commentsAt p <> ": there are comments on the page " <> show p.text <> ", which is not in the archive.")
    for_ ts $ \t -> do
      when (null t.comments) $
        Left (naming.commentsAt p <> ": the thread " <> show t.id.text <> " has no comments.")
      unless (t.page == p && all (\c -> c.thread == t.id) t.comments) $
        Left (naming.commentsAt p <> ": the thread " <> show t.id.text <> " is not one of this page's.")
  where
    userIds = Set.fromList (map (\u -> u.id) a.users)
    groupIds = Set.fromList (map (\g -> g.id) a.groups)
    spacesById = Map.fromList [(s.id, s) | s <- a.spaces]
    pagesById = Map.fromList [(p.id, p) | p <- a.pages]

    -- Each key once; a key given twice is refused, with where it is.
    unique :: Text -> [(Text, Text)] -> Either Text ()
    unique what keyed = case [(k, places) | (k, places) <- Map.toList (Map.fromListWith (flip (<>)) [(k, [place]) | (k, place) <- keyed]), length places > 1] of
      [] -> Right ()
      (k, places) : _ -> case ordNub places of
        [place] -> Left (place <> ": there are two of the " <> what <> " " <> show k <> ".")
        different -> Left ("There are two of the " <> what <> " " <> show k <> ", in " <> T.intercalate " and in " different <> ".")

    subject :: Text -> Subject -> Either Text ()
    subject which = \case
      SubjectUser u ->
        unless (Set.member u userIds) $
          Left ("grants.json: " <> which <> " names the user " <> show u.text <> ", who is not in users.json.")
      SubjectGroup g ->
        unless (Set.member g groupIds) $
          Left ("grants.json: " <> which <> " names the group " <> show g.text <> ", which is not in groups.json.")

    siblings :: (Ord k) => Text -> [((k, Slug), Text)] -> Either Text ()
    siblings what keyed =
      case [(slug, place) | ((_, slug), (n, place)) <- Map.toList (Map.fromListWith (\(m, _) (n, place) -> (n + m, place)) [(key, (1 :: Int, place)) | (key, place) <- keyed]), n > 1] of
        [] -> Right ()
        (slug, place) : _ -> Left (place <> ": two " <> what <> " side by side have the slug " <> show (slugText slug) <> ".")

    acyclic :: (Ord k) => (k -> Text) -> Text -> (v -> Maybe k) -> (k -> Text) -> Map k v -> Either Text ()
    acyclic placeOf what parentOf named byId = for_ (Map.keys byId) (climb mempty)
      where
        climb seen k
          | Set.member k seen = Left (placeOf k <> ": the " <> what <> " " <> show (named k) <> " is under itself.")
          | otherwise = for_ (Map.lookup k byId >>= parentOf) (climb (Set.insert k seen))

--------------------------------------------------------------------------------
-- Comments

-- | The archive's comment threads, with each comment's author as a wiki
-- with these users knows them. An author whose login (from the archive's
-- users or its 'commentAuthors') is one of these users' becomes that user.
-- Any other author becomes a 'formerAuthor', kept by the name the archive
-- gives. An import into a wiki that takes the archive's users passes the
-- archive's users; the server's merge passes its own.
threadsAmong :: [User] -> Archive -> Map PageId [Thread]
threadsAmong here a = map (map thread) a.threads
  where
    archived = Map.fromList [(u.id, u) | u <- a.commentAuthors <> a.users]
    byLogin = Map.fromList [(u.login, u) | u <- here]
    thread t = t {comments = map (\c -> c {author = author c.author}) t.comments}
    author given = case Map.lookup given.id archived of
      Just person
        | Just u <- Map.lookup person.login byLogin -> Author {id = u.id, name = u.displayName}
        | otherwise -> absentAuthor (formerAuthor person.displayName)
      Nothing -> absentAuthor (formerAuthor (fromMaybe given.name (formerAuthorName given.id)))

-- | A comment's author as a @comments.json@ record names them: the id they
-- had in the wiki the archive came from, their login (for a person who is
-- not a user there, none), and their name.
data Named = Named
  { id :: Maybe UserId
  , login :: Maybe Login
  , displayName :: Text
  }

-- | @{"id", "author": {"id", "login", "displayName"}, "body", "createdAt",
-- "editedAt"}@ for a comment, in a thread's @comments@; @editedAt@ only for
-- a comment that was edited.
encodeComment :: (Author -> Value) -> Comment -> Value
encodeComment author c =
  object $
    ["id" .= c.id.text, "author" .= author c.author, "body" .= c.body, "createdAt" .= c.createdAt]
      <> ["editedAt" .= at | Just at <- [c.editedAt]]

-- | @{"id", "anchor": {"exact", "prefix", "suffix"}, "resolved",
-- "createdAt", "comments": […]}@ for a thread, its first comment the one
-- that opened it and the rest replies, in order. @anchor@ is written only
-- for an inline thread (one about a quote of the page), and @resolved@
-- only when true.
encodeThread :: (Author -> Value) -> Thread -> Value
encodeThread author t =
  object $
    ["id" .= t.id.text, "createdAt" .= t.createdAt, "comments" .= map (encodeComment author) t.comments]
      <> ["anchor" .= object ["exact" .= x.exact, "prefix" .= x.prefix, "suffix" .= x.suffix] | Just x <- [t.anchor]]
      <> ["resolved" .= True | t.resolved]

-- | Parse a thread of a page, with each author as the function names
-- them, and the people it gives who are not users. A thread is resolved
-- only if it is inline; a missing @createdAt@ is its first comment's.
parseThread :: (Named -> (Author, Maybe User)) -> PageId -> Value -> Parser (Thread, [Maybe User])
parseThread named page = withObject "thread" $ \o -> do
  id <- CommentThreadId <$> o .: "id"
  anchor <- traverse parseAnchor =<< o .:? "anchor"
  resolved <- o .:? "resolved" .!= False
  written <- traverse (parseComment named id) =<< o .: "comments"
  createdAt <- o .:? "createdAt" >>= maybe (maybe (fail "a thread has at least one comment") (pure . (\(c, _) -> c.createdAt)) (head written)) pure
  pure (Thread {id, page, anchor, resolved = resolved && isJust anchor, createdAt, comments = map fst written}, map snd written)
  where
    parseAnchor = withObject "anchor" $ \o -> Anchor <$> o .: "exact" <*> o .:? "prefix" .!= "" <*> o .:? "suffix" .!= ""

parseComment :: (Named -> (Author, Maybe User)) -> CommentThreadId -> Value -> Parser (Comment, Maybe User)
parseComment named thread = withObject "comment" $ \o -> do
  id <- CommentId <$> o .: "id"
  (author, person) <- named <$> (parseNamed =<< o .: "author")
  body <- o .: "body"
  createdAt <- o .: "createdAt"
  editedAt <- o .:? "editedAt"
  pure (Comment {id, thread, author, body, createdAt, editedAt}, person)

-- | An author's record: the display name is the login, or the id, if
-- missing.
parseNamed :: Value -> Parser Named
parseNamed = withObject "author" $ \o -> do
  id <- fmap UserId <$> o .:? "id"
  login <- fmap Login <$> o .:? "login"
  given <- o .:? "displayName"
  displayName <- maybe (fail "an author has a displayName, a login or an id") pure (given <|> fmap (\l -> l.text) login <|> fmap (\u -> u.text) id)
  pure Named {id, login, displayName}

--------------------------------------------------------------------------------
-- Records

-- | @{"id", "name", "slug", "parent", "public", "createdAt", "mathMacros",
-- "position", "subspaceOrder", "pageOrder"}@: @parent@ is @null@ or
-- missing for a top-level space, @public@ false if missing. The rest were
-- added after version 1 was first written, as additive fields, so no new
-- version: @mathMacros@ (the space's TeX macros) is the empty text if
-- missing; @createdAt@, if missing, is the time the reader is given for
-- the space (an archive's reader gives the time of the earliest page in
-- it, or the archive's own); @position@ (among its siblings, by hand) is 0
-- if missing; @subspaceOrder@ and @pageOrder@ (@"name"@, @"newest-first"@,
-- @"oldest-first"@ or @"by-hand"@) are by name if missing, or if they name
-- an order this program does not know. Fields that have a default are
-- written only when they differ from it, so that the record of a space
-- that does not use them is what it was before they were added. The same
-- goes for @homePage@ (the id of the page it opens at, one of its own;
-- none if missing), @icon@ (@{"emoji": …}@, @{"colour": …}@, or
-- @{"image": blob, "mediaType": …, "file": …}@, the file being where the
-- image's bytes are; the default if missing, or of a kind this program
-- does not know), @description@ (empty if missing) and @blog@ (whether it
-- is shown as a blog, "Wiki.Core.Blog"; false if missing).
--
-- This is the record of version 1 and of the demo's IndexedDB, where an
-- image's file is @icons\/\<space id>@. In version 2, @space.json@ is the
-- same record without @parent@, and an image's file is named in the
-- space's directory.
encodeSpace :: Space -> Value
encodeSpace s = object (("parent" .= fmap (\p -> p.text) s.parent) : spaceFields (Just ("icons/" <> s.id.text)) s)

-- | A space's fields but its parent, with the file of its icon's image, if
-- it has one.
spaceFields :: Maybe Text -> Space -> [Pair]
spaceFields iconFile s =
  [ "id" .= s.id.text
  , "name" .= s.name
  , "slug" .= s.slug
  , "public" .= s.public
  , "createdAt" .= s.createdAt
  ]
    <> ["mathMacros" .= s.mathMacros | not (T.null s.mathMacros)]
    <> ["position" .= s.position | s.position /= 0]
    <> ["subspaceOrder" .= orderText s.subspaceOrder | s.subspaceOrder /= ByName]
    <> ["pageOrder" .= orderText s.pageOrder | s.pageOrder /= ByName]
    <> ["homePage" .= home.text | Just home <- [s.homePage]]
    <> ["icon" .= encodeIcon iconFile icon | Just icon <- [s.icon]]
    <> ["description" .= s.description | not (T.null s.description)]
    <> ["blog" .= True | s.blog]

-- | A space's icon as its record writes it: an image names the archive
-- file its bytes are in.
encodeIcon :: Maybe Text -> Icon -> Value
encodeIcon file icon = case (icon, toJSON icon, file) of
  (IconImage _ _, Object o, Just named) -> Object (KeyMap.insert "file" (toJSON named) o)
  (_, v, _) -> v

-- | Parse a space. A record without a @createdAt@ (one written before
-- spaces had one) gets the time the function gives for its id.
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
  blog <- o .:? "blog" .!= False
  pure Space {id, name, slug, parent, public, mathMacros, createdAt, position, subspaceOrder, pageOrder, homePage, icon, description, blog}

-- | An order as the archive writes it.
orderText :: ChildOrder -> Text
orderText = \case
  ByName -> "name"
  NewestFirst -> "newest-first"
  OldestFirst -> "oldest-first"
  ByHand -> "by-hand"

-- | Parse an order. One this program does not know (a later one's) is
-- read as by name, so that the archive still imports, as it would without
-- the field.
readOrder :: Text -> ChildOrder
readOrder t = fromMaybe ByName (find (\o -> orderText o == t) [minBound .. maxBound])

-- | When a space read without a @createdAt@ is taken to have been created:
-- when the earliest of its pages was, or, if it has none, at the given
-- time. That may be later than the real creation, but it is the nearest
-- time a record without one gives.
spaceCreatedDefault :: UTCTime -> [Page] -> SpaceId -> UTCTime
spaceCreatedDefault fallback pages sid = Map.findWithDefault fallback sid earliest
  where
    earliest = Map.fromListWith min [(p.space, p.createdAt) | p <- pages]

-- | @{"id", "space", "parent", "title", "slug", "body", "createdAt",
-- "updatedAt"}@, without the page's attachments, which are records of
-- their own ('encodeAttachment'): @parent@ is @null@ or missing for a
-- top-level page, @body@ empty if missing, @updatedAt@ the creation time
-- if missing. @position@, among its siblings by hand, was added after
-- version 1 was first written (an additive field): 0 if missing, and
-- written only when not 0. @template@, whether the page is one of its
-- space's templates, is another (WP4.15): false if missing, and written
-- only when true.
--
-- This is the record of version 1 and of the demo's IndexedDB. In version
-- 2, @page.json@ is the same record without @space@, @parent@ and @body@,
-- which the tree and @page.md@ give, and with the page's attachments'
-- records in a field @attachments@.
encodePage :: Page -> Value
encodePage p =
  object $
    [ "space" .= p.space.text
    , "parent" .= fmap (\q -> q.text) p.parent
    , "body" .= p.body
    ]
      <> pageFields p

-- | A page's fields but its space, its parent, its body and its
-- attachments.
pageFields :: Page -> [Pair]
pageFields p =
  [ "id" .= p.id.text
  , "title" .= p.title
  , "slug" .= p.slug
  , "createdAt" .= p.createdAt
  , "updatedAt" .= p.updatedAt
  ]
    <> ["position" .= p.position | p.position /= 0]
    <> ["template" .= True | p.template]

-- | Parse a page, with no attachments yet.
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
  template <- o .:? "template" .!= False
  pure Page {id, space, parent, title, slug, body, attachments = [], createdAt, updatedAt, position, template}

-- | An attachment's record as it was parsed: the page it is attached to,
-- the attachment, and the archive file its bytes are in, if it names one.
data AttachmentRecord = AttachmentRecord
  { page :: PageId
  , attachment :: Attachment
  , file :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | @{"id", "page", "name", "mediaType", "size"}@ and where the bytes are:
-- @"url"@ for a file on the web, or @"blob"@, the id the wiki stores the
-- bytes under, with @"file"@, where they are in an archive. A missing
-- media type is @application/octet-stream@.
--
-- This is the record of version 1 and of the demo's IndexedDB, where the
-- file is @attachments\/\<attachment id>\/\<name>@. In version 2, a page's
-- @page.json@ holds the same records without @page@, each file named in
-- the page's directory.
encodeAttachment :: PageId -> Attachment -> Value
encodeAttachment page x = object (("page" .= page.text) : attachmentFields ("attachments/" <> x.id.text <> "/" <> x.name) x)

-- | An attachment's fields but its page, with the file its bytes are in,
-- for one whose bytes the wiki keeps.
attachmentFields :: Text -> Attachment -> [Pair]
attachmentFields file x =
  [ "id" .= x.id.text
  , "name" .= x.name
  , "mediaType" .= x.mediaType
  , "size" .= x.size
  ]
    <> case x.source of
      SourceUrl url -> ["url" .= url]
      SourceBlob blob -> ["blob" .= blob.text, "file" .= file]

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
    -- From a program that stores bytes under no id of its own: the
    -- attachment's id stands in for one.
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
  pure User {id, login = Login login, displayName}

-- | @{"id", "name", "members"}@, the members by user id; none if missing.
encodeGroup :: Group -> Set UserId -> Value
encodeGroup g members = object ["id" .= g.id.text, "name" .= g.name, "members" .= map (\u -> u.text) (Set.toList members)]

parseGroup :: Value -> Parser (Group, Set UserId)
parseGroup = withObject "group" $ \o -> do
  id <- GroupId <$> o .: "id"
  name <- o .: "name"
  members <- o .:? "members" .!= []
  pure (Group {id, name}, Set.fromList (map UserId members))

-- | @{"global": […], "spaces": […]}@, a missing list being empty. Whom
-- the wiki is open to is not in an archive: it is a setting of the server
-- the archive is imported into, and is read back as 'Open', the default.
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
