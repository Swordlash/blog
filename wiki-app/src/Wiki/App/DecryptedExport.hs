-- | The export of an encrypted space decrypted in the browser (item 3 of
-- issue #213, WP5.74b3 of docs/PLAN.md): an archive in the wiki's own
-- format ("Wiki.Core.Export") of an encrypted space and of those of its
-- subspaces whose keys this browser can open, with their pages decrypted.
--
-- The server cannot make this export, since it holds no key: the browser
-- reads the space's ciphertexts, decrypts them ("Wiki.App.Backend.Http"'s
-- 'Wiki.App.Backend.Encrypted.exportDecrypted'), and builds the archive
-- here. The plain text exists only in the browser's memory and in the file
-- the reader saves; nothing of it is sent to the server.
--
-- The archive holds spaces alone: each space, its pages' latest titles
-- and texts, their attachments' names, media types and bytes, and their
-- comment threads with each author's name. It holds no versions, users,
-- groups, grants or audit log ('leftOutOfExport'). An import of it, the
-- server's merge or the demo's, brings the spaces in as plain spaces. A
-- password reset that deletes a user's keys loses the encrypted spaces
-- nobody else can open, and this export is the way to keep them.
--
-- Before the file is handed over, its bytes are unzipped and read again
-- ('readArchive'), and what was read is compared with what was decrypted
-- ('archiveMismatch'): a file the wiki would refuse, or one that lost
-- something on the way, is never saved.
module Wiki.App.DecryptedExport
  ( -- * What was decrypted
    ExportedSpace (..)
  , LeftOut (..)
  , DecryptedExport (..)
  , leftOutOfExport

    -- * The archive
  , decryptedArchive
  , archiveMismatch
  , checkedZip
  , exportFileName
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Protolude
import Wiki.App.Browser (unzipFiles, zipFiles)
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..), formerAuthorName)
import Wiki.Core.Export (Archive (..), readArchive, writeArchive)
import Wiki.Core.Id (BlobId, PageId)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))

-- | 'ExportedSpace': one space of the export, decrypted: the space's
-- record, its pages with their attachments (each attachment's bytes under
-- its blob in 'blobs'), and each page's comment threads.
data ExportedSpace = ExportedSpace
  { space :: Space
  , pages :: [Page]
  , threads :: Map PageId [Thread]
  , blobs :: Map BlobId ByteString
  }

-- | 'LeftOut': a subspace the export leaves out, by its name, and why:
-- this browser cannot open its key, or the space above it is left out.
data LeftOut = LeftOut
  { name :: Text
  , why :: Text
  }
  deriving stock (Eq, Show)

-- | 'DecryptedExport': the file to save, under its name, with the archive
-- it holds and the subspaces it leaves out.
data DecryptedExport = DecryptedExport
  { fileName :: Text
  , bytes :: ByteString
  , archive :: Archive
  , leftOut :: [LeftOut]
  }

-- | What such an export does not hold, as the export's dialog says it.
leftOutOfExport :: Text
leftOutOfExport = "older versions of the pages, drafts, the wiki's users and groups, and who may read or edit the spaces"

-- | The archive of the spaces decrypted, made at a time by a program (the
-- manifest's @createdAt@ and @app@).
--
-- Each space's record is made one an archive without users can hold:
-- plain ('encryption' is not written anyway), private, nobody's personal
-- space, shown, and under its parent only when the parent is exported too
-- (the space the export starts from goes to the top). A home page is
-- kept when it is one of the space's pages. A thread with no comments,
-- which an archive refuses, has nothing to lose and is left out.
decryptedArchive :: UTCTime -> Text -> [ExportedSpace] -> Archive
decryptedArchive at app exported =
  Archive
    { createdAt = at
    , app
    , users = []
    , groups = []
    , membership = mempty
    , grants = mempty
    , spaces = map (plainSpace . (\e -> e.space)) exported
    , pages = [p {template = False, createdBy = Nothing, updatedBy = Nothing} | e <- exported, p <- e.pages]
    , threads = Map.filter (not . null) (Map.unions [map (filter (\t -> not (null t.comments))) e.threads | e <- exported])
    , commentAuthors = []
    , blobs = Map.unions (map (\e -> e.blobs) exported)
    , homeVersions = []
    , homePage = Nothing
    , audit = []
    }
  where
    ids = Set.fromList [e.space.id | e <- exported]
    pagesOf = Map.fromList [(e.space.id, Set.fromList (map (\p -> p.id) e.pages)) | e <- exported]
    plainSpace s =
      s
        { encryption = Nothing
        , public = False
        , owner = Nothing
        , personalContainer = False
        , active = True
        , parent = mfilter (`Set.member` ids) s.parent
        , homePage = mfilter (\h -> maybe False (Set.member h) (Map.lookup s.id pagesOf)) s.homePage
        }

-- | What an archive read back from the file lacks of the archive written,
-- or 'Nothing' when it holds it all: every space with its name, slug and
-- parent; every page with its title, text, kind, space and parent; every
-- attachment with its name, media type and bytes; every thread with its
-- quote and its comments' texts and authors' names.
archiveMismatch :: Archive -> Archive -> Maybe Text
archiveMismatch written back =
  head $
    [ "the space " <> s.name <> " is not read back as it was written"
    | s <- written.spaces
    , Map.lookup s.id backSpaces /= Just (spaceShape s)
    ]
      <> [ "the page " <> show p.title <> " is not read back as it was written"
         | p <- written.pages
         , Map.lookup p.id backPages /= Just (pageShape written p)
         ]
      <> [ "the comments of the page " <> show p.title <> " are not read back as they were written"
         | p <- written.pages
         , map threadShape (Map.findWithDefault [] p.id written.threads) /= map threadShape (Map.findWithDefault [] p.id back.threads)
         ]
      <> ["it holds more spaces or pages than were decrypted" | Map.size backSpaces /= length written.spaces || Map.size backPages /= length written.pages]
  where
    backSpaces = Map.fromList [(s.id, spaceShape s) | s <- back.spaces]
    backPages = Map.fromList [(p.id, pageShape back p) | p <- back.pages]
    spaceShape s = (s.name, slugText s.slug, s.parent)
    pageShape a p = (p.title, p.body, p.kind, p.space, p.parent, [(x.name.text, x.mediaType.text, bytesOf a x) | x <- p.attachments])
    bytesOf a x = case x.source of
      SourceBlob blob -> Map.lookup blob a.blobs
      SourceUrl _ -> Nothing
    threadShape :: Thread -> (Maybe Anchor, Bool, [(Text, Text)])
    threadShape t = (t.anchor, t.resolved, [(c.body, authorName c.author) | c <- t.comments])
    -- The name an archive gives an author it has no user for.
    authorName a = fromMaybe a.name (formerAuthorName a.id)

-- | The archive's files zipped, as the demo's export zips them, unzipped
-- again and read back ('readArchive'), and compared with the archive
-- ('archiveMismatch'): the zip file's bytes, or why they are not saved.
-- The bytes checked are the very bytes returned.
checkedZip :: (MonadIO m) => Archive -> m (Either Text ByteString)
checkedZip a = do
  zipped <- zipFiles (writeArchive a)
  unzipFiles zipped <&> \case
    Left why -> Left ("The file made could not be read back (" <> why <> "): nothing was saved.")
    Right files -> case readArchive files of
      Left why -> Left ("The file made is not one the wiki could import, so nothing was saved: " <> why)
      Right back -> case archiveMismatch a back of
        Just what -> Left ("The file made does not hold what was decrypted (" <> what <> "), so nothing was saved.")
        Nothing -> Right zipped

-- | The name of the file an export of a space is saved under: the space's
-- slug, "decrypted", and the day.
exportFileName :: Space -> UTCTime -> Text
exportFileName s at = slugText s.slug <> "-decrypted-" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" at) <> ".zip"
