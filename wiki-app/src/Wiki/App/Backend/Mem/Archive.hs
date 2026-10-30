-- | Conversion between the in-memory wiki and an export archive
-- ("Wiki.Core.Export"): what the demo's "Export the wiki" writes and
-- "Import a wiki" reads.
module Wiki.App.Backend.Mem.Archive
  ( toArchive
  , fromArchive
  , replaceFromArchive
  , nextCounter
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.ServerSettings (ServerSettingsOf (..), noServerSettings)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.App.Backend.Mem.State (MemState (..), Saved (..), completeVersions, prepareSearch, versionOf)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Attachment qualified as A
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Export (Archive (..), threadsAmong, withoutHomeDocument)
import Wiki.Core.HomePage (HomeDocument (..), HomePage (..))
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.Space qualified as S
import Wiki.Core.User (Group (..), User (..))
import Wiki.Core.Version (Author (..), Version (..))

-- | The whole wiki, as written at this time by this program.
toArchive :: UTCTime -> Text -> MemState -> Archive
toArchive createdAt app st =
  Archive
    { createdAt
    , app
    , users = Map.elems st.users
    , groups = Map.elems st.groups
    , membership = st.membership
    , grants = st.grants
    , spaces = Map.elems st.spaces
    , pages = Map.elems st.pages
    , threads = st.threads
    , -- The authors of the demo's comments are its users.
      commentAuthors = []
    , blobs = st.blobs
    , -- The demo keeps no audit log (WP4.10 of docs/PLAN.md): its
      -- administration has one user, in this browser.
      audit = []
    , homeVersions = case st.server.homePage.document of
        Nothing -> []
        Just d -> [versionOf st d.page at saved | (at, saved) <- Map.toList (Map.findWithDefault mempty d.page st.versions)]
    , homePage = Just st.server.homePage
    }

-- | The wiki an archive holds, with nobody signed in. Its ids are the
-- archive's, and the counter for new ids starts after the largest of them
-- ('nextCounter'). An archive has no history: each page's history starts
-- with the page as the archive has it ('completeVersions'). The comments
-- come with the pages, each author being the archive's user with the
-- author's login, or else a person who is not a user here, kept by their
-- name ('threadsAmong'). The archive's audit log is left out, since the
-- demo keeps none.
fromArchive :: Archive -> MemState
fromArchive a =
  completeVersions (prepareSearch st {counter = nextCounter st})
  where
    st =
      MemState
        { users = Map.fromList [(u.id, u) | u <- a.users]
        , groups = Map.fromList [(g.id, g) | g <- a.groups]
        , membership = a.membership
        , grants = a.grants
        , spaces = Map.fromList [(s.id, s) | s <- a.spaces]
        , pages = Map.fromList [(p.id, p) | p <- a.pages]
        , blobs = a.blobs
        , unreadBlobs = mempty
        , objectUrls = mempty
        , -- An archive has no drafts: drafts belong to their authors, and
          -- were written for other pages than these.
          drafts = mempty
        , versions = Map.fromListWith (<>) [(v.page, Map.singleton v.updatedAt Saved {title = v.title, body = v.body, author = (\author -> author.id) <$> v.author}) | v <- a.homeVersions]
        , unreadVersions = mempty
        , searchText = mempty
        , -- Nor account flags: its users come with neither a disabled
          -- login nor a password, as the server imports them.
          disabled = mempty
        , passwords = mempty
        , -- Its users are all there: an export names a removed account's
          -- content by the login already ('Wiki.Core.Comment.formerAuthor').
          removed = mempty
        , -- Nor the wiki's settings, which are the demo's own, nor its
          -- invitations.
          newAccountsCreateSpaces = False
        , adminCreatesPasswordAccounts = True
        , invitations = mempty
        , server = noServerSettings {SS.homePage = fromMaybe noServerSettings.homePage a.homePage}
        , threads = threadsAmong a.users a
        , -- Nor notifications, watches or notification choices: they
          -- belong to each user, and are about the pages of the wiki that
          -- was exported.
          notices = mempty
        , watches = mempty
        , choices = mempty
        , current = Nothing
        , counter = 1
        }

-- | Replace user content while importing the root into its existing identity.
-- An older or space-only archive leaves the root, its attachments and history.
replaceFromArchive :: UTCTime -> MemState -> Archive -> Either Text MemState
replaceFromArchive time old a = do
  for_ root.attachments $ \attachment -> case attachment.source of
    SourceBlob b | Map.notMember b sourceBlobs -> Left ("The home attachment " <> attachment.name.text <> " has no stored bytes.")
    _ -> pure ()
  pure (completeVersions (prepareSearch finished))
  where
    base = fromArchive (withoutHomeDocument a)
    counter = max (nextCounter old) (nextCounter base)
    oldHome = old.server.homePage
    incoming = fromMaybe oldHome a.homePage
    oldRoot = oldHome.document >>= \d -> (,) <$> Map.lookup d.space old.spaces <*> Map.lookup d.page old.pages
    archived = a.homePage >>= (\h -> h.document) >>= \d -> find (\p -> p.id == d.page) a.pages
    -- User records from the imported wiki can happen to use this demo's
    -- old IDs. In that case allocate fresh root IDs, as ordinary imports do.
    freeSpace = case oldHome.document of
      Just d | Map.notMember d.space base.spaces -> d.space
      _ -> SpaceId ("home-space-" <> show counter)
    freePage = case oldHome.document of
      Just d | Map.notMember d.page base.pages -> d.page
      _ -> PageId ("home-page-" <> show counter)
    document = HomeDocument {space = freeSpace, page = freePage}
    slug = either (panic . show) identity (mkSlug ("wiki-home-" <> freeSpace.text))
    (createdSpace, createdPage) = Home.makeHomeDocument document slug time incoming
    space = maybe createdSpace (\(s, _) -> s {S.id = freeSpace, S.homePage = Just freePage}) oldRoot
    previous = maybe createdPage snd oldRoot
    source = fromMaybe previous archived
    content = if isJust a.homePage then source {P.title = maybe incoming.title (\p -> p.title) archived, P.body = maybe incoming.body (\p -> p.body) archived} else source
    root = content {P.id = freePage, P.space = freeSpace, P.parent = Nothing, P.slug = previous.slug, P.template = False, P.body = content.body}
    sourceBlobs = if isJust archived then a.blobs else old.blobs
    -- Reassign attachment and blob IDs, keeping the imported user's IDs free.
    attach (items, bytes, n) attachment =
      let id = AttachmentId ("attachment-" <> show n)
          blob = BlobId ("blob-" <> show n)
          (source', bytes') = case attachment.source of
            SourceBlob b -> (SourceBlob blob, Map.insert blob (fromMaybe (panic "checked home attachment bytes") (Map.lookup b sourceBlobs)) bytes)
            url -> (url, bytes)
       in (items <> [attachment {A.id = id, A.source = source'}], bytes', n + 1)
    allocatedRoot = maybe True (\d -> d.space /= freeSpace || d.page /= freePage) oldHome.document
    (attachments, blobs, next) = foldl' attach ([], base.blobs, counter + if allocatedRoot then 1 else 0) root.attachments
    keptVersions = maybe mempty (\(_, p) -> Map.findWithDefault mempty p.id old.versions) oldRoot
    importedVersions = Map.fromList [(v.updatedAt, Saved {title = v.title, body = v.body, author = (\author -> author.id) <$> v.author}) | v <- a.homeVersions]
    versions = if isJust archived then importedVersions else keptVersions
    -- Legacy settings change the text but must retain an existing history.
    changedLegacy = isJust a.homePage && isNothing archived && (root.title /= previous.title || root.body /= previous.body)
    page = if changedLegacy then P.savedAs time root.title root.body previous {P.id = freePage, P.space = freeSpace, P.attachments = attachments} else root {P.attachments = attachments}
    home = incoming {Home.document = Just document, Home.title = page.title, Home.body = page.body}
    finished =
      base
        { spaces = Map.insert freeSpace space base.spaces
        , pages = Map.insert freePage page base.pages
        , versions = Map.insert freePage versions base.versions
        , blobs
        , counter = next
        , current = old.current
        , server = old.server {SS.homePage = home}
        }

-- | The number after the largest number that ends one of the wiki's ids.
-- The in-memory wiki makes ids like @space-7@ and @page-8@, and a new id
-- must not equal one an imported record has. Ids made some other way (a
-- server's) end in no number and do not count.
nextCounter :: MemState -> Natural
nextCounter st = 1 + foldl' max 0 (mapMaybe numbered ids)
  where
    ids =
      map (\u -> u.text) (Map.keys st.users)
        <> map (\g -> g.text) (Map.keys st.groups)
        <> map (\s -> s.text) (Map.keys st.spaces)
        <> map (\p -> p.text) (Map.keys st.pages)
        <> [x.id.text | p <- Map.elems st.pages, x <- p.attachments]
        <> [b.text | p <- Map.elems st.pages, x <- p.attachments, SourceBlob b <- [x.source]]
        <> [b.text | s <- Map.elems st.spaces, Just (IconImage b _) <- [s.icon]]
        <> [t.id.text | ts <- Map.elems st.threads, t <- ts]
        <> [c.id.text | ts <- Map.elems st.threads, t <- ts, c <- t.comments]
    numbered i = case T.breakOnEnd "-" i of
      (prefix, digits) | not (T.null prefix), not (T.null digits), T.all isDigit digits -> readMaybe (T.unpack digits)
      _ -> Nothing
